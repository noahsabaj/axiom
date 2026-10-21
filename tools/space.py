#!/usr/bin/env python3
"""Room on the disk that build/ is on: the tools stop before they fill it.

    import space; space.check()     exits when that disk has less free than
                                    AXIOM_MIN_FREE_GB (20 when not set)
    python tools/space.py           how much is free, and what build/ holds
    python tools/space.py clean     deletes what build/ holds but the hardware
                                    logs (build/hw); the tools make it again

tools/build.py, tools/run.py and every QEMU suite (through tools/test/qemu.py)
check first, so a run never takes the last of the disk from the system and the
other programs on it. tools/test/all.py deletes a suite's disk images once the
suite passes; a suite that fails keeps them, to look at.
"""
import os
import pathlib
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"
KEEP = {"hw"}                           # logs from real machines: not made again
GB = 1 << 30


def floor():
    return float(os.environ.get("AXIOM_MIN_FREE_GB") or 20)


def free():
    """Bytes free on the disk build/ is on (or will be)."""
    at = BUILD if BUILD.exists() else ROOT
    return shutil.disk_usage(at).free


def check():
    left = free()
    if left < floor() * GB:
        sys.exit(f"only {left / GB:.1f} GB free on the disk build/ is on, under "
                 f"{floor():g} GB (AXIOM_MIN_FREE_GB): stopping before the disk fills. "
                 f"python tools/space.py clean deletes this tree's build output")


def size(path):
    if path.is_file():
        return path.stat().st_size
    return sum(f.stat().st_size for f in path.rglob("*") if f.is_file())


def clean():
    gone = 0
    for p in BUILD.iterdir() if BUILD.exists() else []:
        if p.name in KEEP:
            continue
        gone += size(p)
        if p.is_dir():
            shutil.rmtree(p)
        else:
            p.unlink()
    return gone


def main():
    if sys.argv[1:] == ["clean"]:
        print(f"deleted {clean() / GB:.2f} GB; {free() / GB:.1f} GB free")
    elif not sys.argv[1:]:
        held = size(BUILD) if BUILD.exists() else 0
        print(f"{free() / GB:.1f} GB free (the tools stop under {floor():g} GB); "
              f"build/ holds {held / GB:.2f} GB")
    else:
        sys.exit("python tools/space.py [clean]")


if __name__ == "__main__":
    main()
