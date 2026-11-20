#!/usr/bin/env python3
"""ppm2png.py out.png in.ppm [in.ppm ...] [--cols N] [--scale N]

Turns the P3 frames tb_face.v writes (2 bits per channel) into a PNG, as a
VGA monitor would show them: level n of 3 becomes n * 85.  Several frames
are tiled, --cols across.  Standard library only."""
import struct
import sys
import zlib


def read_ppm(path):
    t = open(path).read().split()
    assert t[0] == "P3" and t[3] == "3", path
    w, h = int(t[1]), int(t[2])
    px = bytes(int(v) * 85 for v in t[4:4 + w * h * 3])
    return w, h, [px[y * w * 3:(y + 1) * w * 3] for y in range(h)]


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


def main():
    args = sys.argv[1:]
    opt = {"--cols": 1, "--scale": 1}
    for k in opt:
        if k in args:
            i = args.index(k)
            opt[k] = int(args[i + 1])
            del args[i:i + 2]
    out, frames = args[0], [read_ppm(p) for p in args[1:]]
    cols, scale = min(opt["--cols"], len(frames)), opt["--scale"]
    w, h = frames[0][0], frames[0][1]
    rows = []
    for r in range(0, len(frames), cols):
        group = frames[r:r + cols]
        for y in range(h):
            line = b"".join(f[2][y] for f in group).ljust(cols * w * 3, b"\0")
            if scale > 1:
                line = b"".join(line[i:i + 3] * scale for i in range(0, len(line), 3))
            rows.extend([line] * scale)
    raw = b"".join(b"\0" + line for line in rows)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", cols * w * scale, len(rows), 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    open(out, "wb").write(png)


if __name__ == "__main__":
    main()
