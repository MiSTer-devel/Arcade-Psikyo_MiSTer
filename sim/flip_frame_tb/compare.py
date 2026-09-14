#!/usr/bin/env python3
"""Check one rendered frame pair from tb_flip_frame.sv.

    python sim/flip_frame_tb/compare.py sim/flip_frame_tb/run/gunbird_f02700

1. Flip Screen: core_flip1.ppm must equal core_flip0.ppm rotated 180
   degrees, exactly. This is the pass/fail result.
2. Harness sanity: core_flip0.ppm against MAME's snapshot of the same frame,
   as a percentage of matching pixels. It shows the capture, ROM regions and
   loader line up -- the core is not required to be MAME-exact here, and
   known differences (the edge-column mask, the screen-clear port) remain.

Writes core_flip0.png, core_flip1.png and flip_diff.png (differing pixels in
magenta) next to the inputs. Exit status 1 if the rotation check fails.
"""
import sys
from pathlib import Path

from PIL import Image


def read_ppm(path):
    tok = path.read_text().split()
    assert tok[0] == "P3"
    w, h, mx = int(tok[1]), int(tok[2]), int(tok[3])
    vals = list(map(int, tok[4:4 + 3 * w * h]))
    px = [tuple(vals[i:i + 3]) for i in range(0, len(vals), 3)]
    return w, h, px


def to_img(w, h, px):
    img = Image.new("RGB", (w, h))
    img.putdata([((r << 3) | (r >> 2), (g << 3) | (g >> 2), (b << 3) | (b >> 2)) for r, g, b in px])
    return img


def main():
    d = Path(sys.argv[1])
    w, h, f0 = read_ppm(d / "core_flip0.ppm")
    _, _, f1 = read_ppm(d / "core_flip1.ppm")
    to_img(w, h, f0).save(d / "core_flip0.png")
    to_img(w, h, f1).save(d / "core_flip1.png")

    rot = f0[::-1]                      # 180 degrees: reverse the raster
    bad = [i for i in range(w * h) if f1[i] != rot[i]]
    diff = to_img(w, h, f1)
    for i in bad:
        diff.putpixel((i % w, i // w), (255, 0, 255))
    diff.save(d / "flip_diff.png")
    lit = sum(1 for p in f0 if p != (0, 0, 0))

    # MAME's snapshot of a ROT270 set comes out turned 180 degrees relative to
    # the native raster (a ROT0 set matches directly), so take the better of
    # the two orientations and say which.
    mame = Image.open(d / "mame.png").convert("RGB")
    match = total = 0
    orient = ""
    if mame.size == (w, h):
        q = [(p[0] >> 3, p[1] >> 3, p[2] >> 3) for p in mame.getdata()]
        total = w * h
        direct = sum(1 for i in range(total) if q[i] == f0[i])
        turned = sum(1 for i in range(total) if q[total - 1 - i] == f0[i])
        match, orient = (direct, "as-is") if direct >= turned else (turned, "snapshot turned 180")

    print("%s: flip1 vs rotate180(flip0): %d of %d pixels differ (%d non-black in flip0)"
          % (d.name, len(bad), w * h, lit))
    if bad:
        xs = [i % w for i in bad]; ys = [i // w for i in bad]
        print("  differing bbox x %d-%d y %d-%d" % (min(xs), max(xs), min(ys), max(ys)))
    if total:
        print("  harness sanity: flip0 matches MAME snapshot (%s) on %.1f%% of pixels" % (orient, 100.0 * match / total))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
