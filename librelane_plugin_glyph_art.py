"""
LibreLane plugin: the chip art (Calvin, in Metal4, on an emptied patch of the
tile).

LibreLane imports every module on the Python path whose name starts with
``librelane_plugin_`` (librelane/plugins.py).  ``python -m librelane`` puts
the current directory on that path, and both the Tiny Tapeout GDS action and
``make harden`` run it from the repository root, so this file is found
without installing anything.  src/config.json inserts the two steps through
``meta.substituting_steps``:

    "+OpenROAD.CutRows": "Project.ArtKeepout"   rows cut under the art, before the taps and the PDN
    "+Magic.WriteLEF":   "Project.ChipArt"      the art cell merged into the GDS, before the DRC

and names the art with CHIP_ART_JSON (macros/CALVIN/art.json, written by
tools/chip_art.py; `make art`).  The router is kept off the patch by the
ROUTING_OBSTRUCTIONS entries in src/config.json.
"""
import json
import os
import re
from typing import List, Optional

from librelane.common import Path
from librelane.config import Variable
from librelane.state import DesignFormat
from librelane.steps import Step
from librelane.steps.odb import OdbpyStep

HERE = os.path.dirname(os.path.abspath(__file__))
GDS_METAL4 = (46, 0)

CHIP_ART_VARS = [
    Variable("CHIP_ART_JSON", Optional[Path], "tools/chip_art.py's art.json: the art GDS, its cell, its die origin, its box and the keep-out under it; unset = no art.", default=None),
]


def load_art(path):
    info = json.load(open(path))
    info["gds"] = os.path.join(os.path.dirname(os.path.abspath(path)), info["gds"])
    return info


def merge_art(gds_in, gds_out, info):
    """The art cell placed at its die origin in a copy of a GDS view.
    Returns the number of Metal4 shapes added."""
    import klayout.db as kdb
    ly = kdb.Layout()
    ly.read(str(gds_in))
    top = ly.top_cell()                    # before the art cell exists (a second top until it is placed)
    art = kdb.Layout()
    art.read(str(info["gds"]))
    src = art.cell(info["cell"])
    if src is None:
        raise ValueError(f"cell {info['cell']} not in {info['gds']}")
    dst = ly.create_cell(info["cell"])
    dst.copy_tree(src)
    ox, oy = (int(round(v / ly.dbu)) for v in info["origin"])
    top.insert(kdb.CellInstArray(dst.cell_index(), kdb.Trans(kdb.Vector(ox, oy))))
    ly.write(str(gds_out))
    return dst.shapes(ly.layer(*GDS_METAL4)).size()


def patch_lef(lef_in, lef_out, design, box):
    """The art's box added to the tile LEF as a Metal4 obstruction, so the
    top-level router stays off it."""
    lines = open(lef_in).read().split("\n")
    rect = f"      LAYER Metal4 ;\n        RECT {box[0]:.3f} {box[1]:.3f} {box[2]:.3f} {box[3]:.3f} ;"
    obs = next((i for i, l in enumerate(lines) if re.match(r"^\s*OBS\s*$", l)), None)
    if obs is not None:
        end = next(i for i in range(obs + 1, len(lines)) if re.match(r"^\s*END\s*$", lines[i]))
        lines[end:end] = rect.split("\n")
    else:
        end = next(i for i, l in enumerate(lines) if re.match(rf"^END\s+{re.escape(design)}\s*$", l))
        lines[end:end] = ["  OBS"] + rect.split("\n") + ["  END"]
    with open(lef_out, "w") as f:
        f.write("\n".join(lines))


@Step.factory.register()
class ChipArt(Step):
    """Merges the Metal4-only art cell into every GDS view after stream-out
    and adds its box to the tile LEF as a Metal4 obstruction.  The art exists
    only in the GDS: not in the ODB, DEF or netlist, so LVS (extracted from
    the DEF) does not see it, while the DRC (run on the GDS) checks it in
    place."""
    id = "Project.ChipArt"
    name = "Chip Art into the GDS and the LEF"
    inputs = [DesignFormat.GDS, DesignFormat.LEF]
    outputs = [DesignFormat.GDS, DesignFormat.KLAYOUT_GDS, DesignFormat.MAG_GDS, DesignFormat.LEF]
    config_vars = CHIP_ART_VARS

    def run(self, state_in, **kwargs):
        if self.config["CHIP_ART_JSON"] is None:
            return {}, {}
        info = load_art(self.config["CHIP_ART_JSON"])
        design = self.config["DESIGN_NAME"]
        views = {}
        done = []
        for fmt in (DesignFormat.GDS, DesignFormat.KLAYOUT_GDS, DesignFormat.MAG_GDS):
            src = state_in.get(fmt.id)          # State.get takes the format's id, not the DesignFormat
            if src is None:
                continue
            out = os.path.join(self.step_dir, f"{design}.{fmt.extension}")
            n = merge_art(src, out, info)
            views[fmt] = Path(out)
            done.append(f"{fmt.extension}: {n} shapes")
        lef = state_in.get(DesignFormat.LEF.id)
        if lef is not None:
            out = os.path.join(self.step_dir, f"{design}.lef")
            patch_lef(lef, out, design, info["box"])
            views[DesignFormat.LEF] = Path(out)
            done.append("lef: Metal4 OBS added")
        with open(os.path.join(self.step_dir, "chip_art.log"), "w") as f:
            f.write(f"{info['cell']} at {info['origin']}, box {info['box']}: {'; '.join(done)}\n")
        return views, {}


@Step.factory.register()
class ArtKeepout(OdbpyStep):
    """Cuts the standard-cell rows under the art's keep-out right after
    OpenROAD.CutRows: nothing is placed there (taps, endcaps and filler
    included) and no Metal1 rails are drawn there."""
    id = "Project.ArtKeepout"
    name = "Chip Art Keep-out (cut rows)"
    config_vars = CHIP_ART_VARS

    def get_script_path(self):
        return os.path.join(HERE, "tools", "odb_art_keepout.py")

    def get_command(self) -> List[str]:
        box = load_art(self.config["CHIP_ART_JSON"])["keepout"]
        return super().get_command() + ["--box"] + [str(v) for v in box]

    def run(self, state_in, **kwargs):
        if self.config["CHIP_ART_JSON"] is None:
            return {}, {}
        return super().run(state_in, **kwargs)
