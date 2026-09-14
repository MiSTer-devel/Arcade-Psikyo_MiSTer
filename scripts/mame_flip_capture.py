#!/usr/bin/env python3
"""Capture a Psikyo game with the Flip Screen DIP off and on, and compare.

    python scripts/mame_flip_capture.py gunbird
    python scripts/mame_flip_capture.py tengai --frames 600,1200,1800

Runs MAME headlessly twice through scripts/mame/flip_capture.lua, identical
except for the Flip Screen DIP. At each frame it dumps sprite RAM, palette,
both VRAMs, the vregs region and work RAM, and takes a snapshot.

Then it reports, per frame and region, whether the two runs differ. If the
game code ignores the DIP, every region matches at every frame and the whole
flip is the video hardware's job; any difference says what the game changes
itself.

Output: debug/flip/<game>/{off,on}/ (gitignored: ROM-derived).
"""
import argparse
import os
import subprocess
import sys
from pathlib import Path

MAME_DIR = Path(os.getenv("MAME_DIR", r"C:\Emulation\Emulators\MAME"))
MAME_EXE = MAME_DIR / os.getenv("MAME_EXE", "arcade64.exe")
REPO = Path(__file__).resolve().parent.parent
REGIONS = ["spriteram", "palette", "vram", "vregs", "workram"]


def run(game, frames, flip, out):
    out.mkdir(parents=True, exist_ok=True)
    for p in out.glob("*"):
        if p.is_file():
            p.unlink()
    env = dict(os.environ, PSK_OUT=out.as_posix(), PSK_FLIP="1" if flip else "0",
               PSK_FRAMES=",".join(str(f) for f in frames),
               PSK_SCRIPT=(REPO / "scripts" / "mame" / "flip_capture.lua").as_posix())
    cmd = [str(MAME_EXE), game, "-skip_gameinfo", "-nodebug", "-nothrottle",
           "-sound", "none", "-autoboot_delay", "0",
           "-autoboot_script", (REPO / "scripts" / "mame" / "run.lua").as_posix(),
           "-snapshot_directory", out.as_posix(), "-snapname", "snap%i",
           "-seconds_to_run", str(max(frames) // 60 + 30),
           "-video", "none", "-nowindow"]
    r = subprocess.run(cmd, cwd=str(MAME_DIR), env=env,
                       capture_output=True, text=True, timeout=1800)
    err = out / "lua_error.txt"
    if err.exists():
        sys.exit("Lua error: " + err.read_text().strip())
    lines = [l for l in (r.stdout or "").splitlines() if l.startswith("CAPTURE")]
    if not any("done" in l for l in lines):
        print("\n".join((r.stdout or "").splitlines()[-20:]))
        sys.exit("capture did not finish (MAME exit %d)" % r.returncode)
    # snapshots are numbered in capture order; name them by frame
    snaps = sorted(out.glob("snap*.png"), key=lambda p: int(p.stem[4:] or 0))
    for f, p in zip(frames, snaps):
        p.rename(out / ("f%05d.png" % f))
    return lines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game")
    ap.add_argument("--frames", default="300,600,900,1200,1500,1800,2100,2400,2700,3000,3300,3600")
    a = ap.parse_args()
    frames = sorted(int(x) for x in a.frames.split(","))
    base = REPO / "debug" / "flip" / a.game
    for flip in (False, True):
        lines = run(a.game, frames, flip, base / ("on" if flip else "off"))
        print("  %s: %s" % ("on " if flip else "off", lines[0]))

    print("\nframe  " + "  ".join("%-9s" % r for r in REGIONS))
    for f in frames:
        cells = []
        for r in REGIONS:
            x = (base / "off" / ("f%05d_%s.bin" % (f, r))).read_bytes()
            y = (base / "on" / ("f%05d_%s.bin" % (f, r))).read_bytes()
            nd = sum(1 for i in range(0, len(x), 2) if x[i:i + 2] != y[i:i + 2])
            cells.append("%-9s" % ("same" if nd == 0 else "%dw" % nd))
        print("%5d  %s" % (f, "  ".join(cells)))


if __name__ == "__main__":
    main()
