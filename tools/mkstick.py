#!/usr/bin/env python3
"""A bootable USB stick image for QEMU: build/stick.img, GPT, one FAT32
EFI system partition holding build/esp (so EFI/BOOT/BOOTX64.EFI).

    python tools/mkstick.py [out.img] [--serial HEX]

Boot it with run.py --stick build/stick.img. Axiom keeps its log in
/AXIOM.LOG there; fatcheck.py --show /AXIOM.LOG prints it afterwards.
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


def build(out, serial, mib=64):
    total = mib * 1024 * 1024 // fat32.SECTOR
    img = bytearray(total * fat32.SECTOR)
    part = (2048, total - 34)
    fat32.write_gpt(img, total, [(fat32.ESP_TYPE, *part, "AXIOM BOOT")])
    fs = fat32.Fat32(img, part[0], part[1] - part[0] + 1)
    fs.format(spc=1, label=b"AXIOM BOOT ", serial=serial)
    fs.add_tree(tree(ROOT / "build" / "esp"))
    fs.flush_fat()
    out.write_bytes(img)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("out", nargs="?", default=str(ROOT / "build" / "stick.img"))
    ap.add_argument("--serial", default="5354494B", help="FAT volume serial, hex")
    opts = ap.parse_args()
    build(pathlib.Path(opts.out), int(opts.serial, 16))
    print(opts.out)
