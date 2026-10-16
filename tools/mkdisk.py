#!/usr/bin/env python3
"""A test disk for Axiom's NVMe and FAT32 code: build/disk.img, 96 MiB, GPT.

    partition 1  EFI system, 64 MiB, FAT32 (one sector per cluster, so
                 directories and files cross cluster boundaries quickly)
    partition 2  basic data, 16 MiB, left blank

    python tools/mkdisk.py [out.img]

Boot it with run.py --extra "-drive file=build/disk.img,if=none,id=nvm,format=raw
-device nvme,serial=axiom0,drive=nvm".
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import fat32  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent


def tree():
    lines = b"".join(b"line %03d of a file that spans many clusters\n" % i for i in range(150))
    many = {}
    for i in range(24):
        many[f"file{i:02d}.txt"] = b"short name %d\n" % i
        many[f"Long Name Number {i:02d}.txt"] = b"long name %d\n" % i
    return {
        "README.TXT": b"Hello from the disk image.\nAxiom reads FAT32 now.\n",
        "notes.txt": b"lowercase 8.3 name\n",
        "A long file name.txt": b"This file has a long name.\nSecond line.\n",
        "big.txt": lines,
        "docs": {
            "inner.txt": b"inside docs\n",
            "deep": {"x.txt": b"deep inside\n"},
        },
        "many": many,
        "empty.dat": b"",
    }


def tree_big():
    """For 64 KiB clusters: transfers of a whole cluster, and files past 64 KiB."""
    pattern = bytes((i * 7 + (i >> 8)) & 0xFF for i in range(60000))
    huge = bytes((i * 13 + (i >> 9)) & 0xFF for i in range(200000))
    return {"pattern.bin": pattern, "huge.bin": huge, "text.txt": b"64 KiB clusters\n"}


def build(out, spc=1, big=False):
    mib = 1024 * 1024
    total = 96 * mib // fat32.SECTOR
    img = bytearray(total * fat32.SECTOR)
    p1 = (2048, 2048 + 64 * mib // 512 - 1)
    p2 = (p1[1] + 1, p1[1] + 16 * mib // 512)
    fat32.write_gpt(img, total, [(fat32.ESP_TYPE, *p1, "AXIOM TEST"),
                                 (fat32.BASIC_TYPE, *p2, "spare")])
    fs = fat32.Fat32(img, p1[0], p1[1] - p1[0] + 1)
    fs.format(spc=spc)
    fs.add_tree(tree_big() if big else tree())
    fs.flush_fat()
    out.write_bytes(img)
    return img


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("out", nargs="?", default=str(ROOT / "build" / "disk.img"))
    ap.add_argument("--spc", type=int, default=1, help="sectors per cluster")
    ap.add_argument("--big", action="store_true", help="large files instead of the tree")
    opts = ap.parse_args()
    out = pathlib.Path(opts.out)
    img = build(out, opts.spc, opts.big)
    parts = fat32.read_gpt(img)
    fs = fat32.Fat32(img, parts[0][1], parts[0][2] - parts[0][1] + 1).mount()
    files, problems = fat32.check(fs)
    print(f"{out}: {len(files)} files and directories, {len(problems)} problems")
    for p in problems:
        print("  ", p)
