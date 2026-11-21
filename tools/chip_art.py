#!/usr/bin/env python3
# Chip art for GF180: a 1 bit bitmap into a Metal4-only GDS cell, one square
# of metal per white pixel, plus what the flow steps need to place it.
#
#   python3 tools/chip_art.py --image art/calvin.png --origin 25.765 5.27 \
#       --keepout 25.2 3.92 56.3 43.12 --out macros/CALVIN
#
# runs inside the LibreLane nix shell (PIL, klayout.db); `make art` does it.
# Outputs in --out: <cell>.gds (Metal4 46/0, and the dummy-fill exclusion
# markers over the keep-out; cell origin = the art's lower-left, so the
# cell is placed at --origin), <cell>.lef (for the record), art.json (what
# Project.ChipArt and Project.ArtKeepout read) and preview.png.
#
# The bitmap is used pixel for pixel (white = metal, row 0 at the top; empty
# border rows and columns are cropped).  Every pixel is --pixel um square
# (0.5 default), which meets the Metal4 rules by construction: width and
# space 0.28, space to wide metal 0.3, area 0.1444, and no metal 30 um wide
# without a slot.  Corner-only contacts are filled.  The rules are checked on
# the result and the script stops if one is broken.
import argparse
import json
import os

import klayout.db as kdb
from PIL import Image

LAYER_METAL4 = (46, 0)
# Dummy-fill exclusion over the keep-out, so nothing is added under or
# between the picture's lines: NDMY (COMP dummy exclusion) and PMNDMY (poly
# and metal dummy exclusion); both are in the precheck's list of valid
# layers.  Not the per-metal MetalN_BLK layers: Magic reads those as
# obstruction metal and checks them for spacing against the cells beside the
# keep-out (96 violations on the first try).
FILL_BLOCK = {"NDMY": (111, 5), "PMNDMY": (152, 5)}

def load_mask(path):
    """Rows of bools, row 0 at the BOTTOM, cropped to the metal's extent."""
    im = Image.open(path).convert("1")
    w, h = im.size
    rows = [[im.getpixel((x, y)) != 0 for x in range(w)] for y in range(h)]
    ys = [y for y in range(h) if any(rows[y])]
    xs = [x for x in range(w) if any(r[x] for r in rows)]
    rows = [r[xs[0]:xs[-1] + 1] for r in rows[ys[0]:ys[-1] + 1]]
    return rows[::-1]


def clean(m):
    """No two metal pixels touching only at a corner (a zero-width space to a
    DRC checker): fill the 2x2 checkerboards until none is left."""
    h, w = len(m), len(m[0])
    for _ in range(20):
        hits = [(y, x) for y in range(h - 1) for x in range(w - 1)
                if (m[y][x] and m[y + 1][x + 1] and not m[y][x + 1] and not m[y + 1][x])
                or (m[y][x + 1] and m[y + 1][x] and not m[y][x] and not m[y + 1][x + 1])]
        if not hits:
            break
        for y, x in hits:
            m[y][x] = m[y][x + 1] = m[y + 1][x] = m[y + 1][x + 1] = True
    return m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", required=True, help="1 bit bitmap, white = metal")
    ap.add_argument("--origin", nargs=2, type=float, required=True, metavar=("X", "Y"), help="the art's lower-left, die um")
    ap.add_argument("--keepout", nargs=4, type=float, required=True, metavar=("X0", "Y0", "X1", "Y1"),
                    help="the box emptied under the art (rows cut, fill blocked), die um; must contain the art")
    ap.add_argument("--pixel", type=float, default=0.5, help="pixel size, um (a multiple of the 0.005 grid)")
    ap.add_argument("--cell", default="tt_um_pettit_calvin")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    mask = clean(load_mask(a.image))
    h_px, w_px = len(mask), len(mask[0])
    x0, y0 = a.origin
    x1, y1 = round(x0 + w_px * a.pixel, 3), round(y0 + h_px * a.pixel, 3)
    kx0, ky0, kx1, ky1 = a.keepout
    if not (kx0 <= x0 and ky0 <= y0 and kx1 >= x1 and ky1 >= y1):
        raise SystemExit(f"the art ({x0}, {y0}, {x1}, {y1}) is not inside the keep-out {a.keepout}")

    os.makedirs(a.out, exist_ok=True)
    ly = kdb.Layout()
    ly.dbu = 0.001
    cell = ly.create_cell(a.cell)
    l_m4 = ly.layer(*LAYER_METAL4)
    # One rectangle per horizontal run of pixels, never merged polygons: a
    # merged plate has holes, which GDS writes as a boundary that visits
    # vertices twice, and the Tiny Tapeout 3D viewer's triangulator throws on
    # those.  The DRC merges touching shapes before it checks.
    px = int(round(a.pixel * 1000))
    rects = 0
    for y in range(h_px):
        x = 0
        while x < w_px:
            if mask[y][x]:
                e = x
                while e < w_px and mask[y][e]:
                    e += 1
                cell.shapes(l_m4).insert(kdb.Box(x * px, y * px, e * px, (y + 1) * px))
                rects += 1
                x = e
            else:
                x += 1
    u = lambda v: int(round(v * 1000))
    for ld in FILL_BLOCK.values():
        cell.shapes(ly.layer(*ld)).insert(kdb.Box(u(kx0 - x0), u(ky0 - y0), u(kx1 - x0), u(ky1 - y0)))
    gds = os.path.join(a.out, a.cell + ".gds")
    ly.write(gds)

    reg = kdb.Region(cell.begin_shapes_rec(l_m4))
    reg.merge()
    wide = reg.sized(-5000).sized(5000)       # the parts more than 10 um wide
    checks = {
        "Mn.1 width 0.28": reg.width_check(280, False, kdb.Region.Euclidian).count(),
        "Mn.2a space 0.28": reg.space_check(280, False, kdb.Region.Euclidian).count(),
        "Mn.2b space 0.3 to metal wider than 10": reg.separation_check(wide, 300, False, kdb.Region.Euclidian).count(),
        "Mn.3 area 0.1444": reg.with_area(0, 144400, False).count(),
        "MSLOT.1 no 30 um wide metal": reg.sized(-15000).count(),
    }
    for k, v in checks.items():
        print(f"  self-check {k}: {v} violations")
    if any(checks.values()):
        raise SystemExit("the art breaks a Metal4 rule it was meant to meet by construction")

    lef = os.path.join(a.out, a.cell + ".lef")
    with open(lef, "w") as f:
        f.write("VERSION 5.8 ;\nBUSBITCHARS \"[]\" ;\nDIVIDERCHAR \"/\" ;\n\n")
        f.write(f"MACRO {a.cell}\n  CLASS BLOCK ;\n  ORIGIN 0 0 ;\n  FOREIGN {a.cell} 0 0 ;\n")
        f.write(f"  SIZE {w_px * a.pixel:.3f} BY {h_px * a.pixel:.3f} ;\n  SYMMETRY X Y ;\n")
        f.write(f"  OBS\n      LAYER Metal4 ;\n        RECT 0 0 {w_px * a.pixel:.3f} {h_px * a.pixel:.3f} ;\n  END\nEND {a.cell}\n\nEND LIBRARY\n")
    metal = sum(sum(r) for r in mask)
    info = {
        "//": "tools/chip_art.py wrote this (make art); paths are relative to this file",
        "gds": os.path.basename(gds), "cell": a.cell, "lef": os.path.basename(lef), "image": a.image,
        "origin": [x0, y0], "box": [x0, y0, x1, y1], "keepout": [kx0, ky0, kx1, ky1],
        "pixel": a.pixel, "pixels": [w_px, h_px], "metal_pixels": metal, "rectangles": rects,
        "merged_polygons": reg.count(), "metal_area_um2": round(reg.area() * 1e-6, 2),
    }
    with open(os.path.join(a.out, "art.json"), "w") as f:
        json.dump(info, f, indent=2)
        f.write("\n")

    S = 6
    img = Image.new("L", (w_px * S, h_px * S), 0)
    for y in range(h_px):
        for x in range(w_px):
            if mask[y][x]:
                img.paste(235, (x * S, (h_px - 1 - y) * S, (x + 1) * S, (h_px - y) * S))
    img.save(os.path.join(a.out, "preview.png"))
    print(f"{a.cell}: {w_px} x {h_px} pixels of {a.pixel} um = {w_px * a.pixel:.2f} x {h_px * a.pixel:.2f} um, "
          f"box ({x0}, {y0}) to ({x1}, {y1}); {metal} metal pixels as {rects} rectangles, "
          f"{reg.count()} merged polygons, {reg.area() * 1e-6:.0f} um2 of Metal4")


if __name__ == "__main__":
    main()
