#!/usr/bin/env python3
"""A bootable USB stick image for QEMU: build/stick.img, GPT, one FAT32
EFI system partition holding build/esp (so EFI/BOOT/BOOTX64.EFI).

    python tools/mkstick.py [out.img] [--serial HEX] [--file NAME=PATH ...]
                            [--linux build/linux]

Boot it with run.py --stick build/stick.img. Axiom keeps its log in
/AXIOM.LOG there; fatcheck.py --show /AXIOM.LOG prints it afterwards.
--file puts more files at the top of it (CLAUDE.KEY, for instance).
--linux puts a Linux root from mkroot.py at /LINUX (META, ROOT/...), on a
stick large enough for it, with 4 KiB clusters.
"""
import argparse
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import fat32  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent


def tree(path):
    out = {}
    for p in sorted(path.iterdir()):
        out[p.name] = tree(p) if p.is_dir() else p.read_bytes()
    return out


def size_of(t):
    return sum(size_of(v) if isinstance(v, dict) else len(v) + 4096 for v in t.values())


def build(out, serial, mib=64, extra=None, linux=None):
    spc = 1
    if linux:
        extra = dict(extra or {})
        extra["LINUX"] = {"META": (linux / "META").read_bytes(), "ROOT": tree(linux / "ROOT")}
        need = size_of(extra) // (1 << 20) * 5 // 4 + 64
        mib, spc = max(mib, need, 300), 8
    total = mib * 1024 * 1024 // fat32.SECTOR
    img = bytearray(total * fat32.SECTOR)
    part = (2048, total - 34)
    fat32.write_gpt(img, total, [(fat32.ESP_TYPE, *part, "AXIOM BOOT")])
    fs = fat32.Fat32(img, part[0], part[1] - part[0] + 1)
    fs.format(spc=spc, label=b"AXIOM BOOT ", serial=serial)
    files = tree(ROOT / "build" / "esp")
    files.update(extra or {})
    fs.add_tree(files)
    fs.flush_fat()
    out.write_bytes(img)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("out", nargs="?", default=str(ROOT / "build" / "stick.img"))
    ap.add_argument("--serial", default="5354494B", help="FAT volume serial, hex")
    ap.add_argument("--file", action="append", default=[], metavar="NAME=PATH",
                    help="one more file at the top")
    ap.add_argument("--linux", metavar="DIR", help="a Linux root from mkroot.py, at /LINUX")
    opts = ap.parse_args()
    extra = {}
    for f in opts.file:
        name, _, path = f.partition("=")
        extra[name] = pathlib.Path(path).read_bytes()
    build(pathlib.Path(opts.out), int(opts.serial, 16), extra=extra,
          linux=pathlib.Path(opts.linux) if opts.linux else None)
    print(opts.out)
