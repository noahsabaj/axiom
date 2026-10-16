#!/usr/bin/env python3
"""Check the FAT32 volume in a GPT image after Axiom has written to it.

    python tools/fatcheck.py [disk.img] [--part N] [--show PATH ...] [--tree]

Prints problems (shared, lost or short chains, long-name damage, FAT copies
that differ) and, with --show, a file's contents.
"""
import argparse
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import fat32  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image", nargs="?", default=str(ROOT / "build" / "disk.img"))
    ap.add_argument("--part", type=int, default=1)
    ap.add_argument("--show", nargs="*", default=[])
    ap.add_argument("--tree", action="store_true")
    opts = ap.parse_args()
    img = bytearray(pathlib.Path(opts.image).read_bytes())
    parts = fat32.read_gpt(img)
    _, first, last, _ = parts[opts.part - 1]
    fs = fat32.Fat32(img, first, last - first + 1).mount()
    files, problems = fat32.check(fs)
    if opts.tree:
        for p, data in sorted(files.items()):
            print(f"  {'<dir>' if data is None else len(data):>8}  {p}")
    for p in opts.show:
        data = files.get(p)
        print(f"--- {p}: " + ("missing" if data is None else f"{len(data)} bytes"))
        if data:
            print(data.decode("latin-1"), end="" if data.endswith(b"\n") else "\n")
    used = sum(1 for c in range(2, fs.maxcl + 1) if fs.fat[c])
    print(f"{len(files)} entries, {used} clusters used, FSInfo next free {fs.fsinfo_next}, "
          f"{len(problems)} problems")
    for p in problems:
        print("  ", p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
