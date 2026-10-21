#!/usr/bin/env python3
"""Linux programs on Axiom, timed by bash itself ($EPOCHREALTIME).

    python tools/test/bench/linux.py [--esp DIR] [--root build/linux]
                                     [--label NAME]

Boots a USB stick made of build/esp (or --esp DIR) and the Linux root
(from tools/mkroot.py) at /LINUX, as mkstick.py --linux does, and runs one
'linux bash -c' that
times, each many times over: a program run (fork and exec of
/usr/bin/true), a pipeline in a command substitution (echo x | cat), 200000
lines through a pipe (seq | wc -l), and a loop of bash alone. Prints each
and writes them to build/test/bench/<label>-linux.json.
"""
import argparse
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "test"))
sys.path.insert(0, str(ROOT / "tools"))
import fat32  # noqa: E402
from qemu import boot_all  # noqa: E402

OUT = ROOT / "build" / "test" / "bench"
NL = "\\n"
N = 100
NOW = "${EPOCHREALTIME/./}"
BASH = ("bash -c '"
        f"T={NOW}; for i in $(seq {N}); do /usr/bin/true; done; "
        f"echo lxb exec $(( ({NOW}-T)/{N} )); "
        f"T={NOW}; for i in $(seq {N}); do y=$(echo x | cat); done; "
        f"echo lxb pipe $(( ({NOW}-T)/{N} )); "
        f"T={NOW}; n=$(seq 200000 | wc -l); "
        f"echo lxb lines $(( {NOW}-T )) $n; "
        f"T={NOW}; for i in $(seq 10000); do :; done; "
        f"echo lxb loop $(( {NOW}-T ))'")
NAMES = {"exec": "fork+exec /usr/bin/true", "pipe": "$(echo x | cat)",
         "lines": "seq 200000 | wc -l", "loop": "bash loop, 10000 turns"}


def typed(text):
    """text as a 'type' step has it (as tools/test/linux/run.py)"""
    return text.replace("\\", "\\\\").replace(";", "\\x3b")


def tree(path):
    out = {}
    for p in sorted(path.iterdir()):
        out[p.name] = tree(p) if p.is_dir() else p.read_bytes()
    return out


def stick(esp, linux, out):
    """a boot stick: the ESP, and the root at /LINUX"""
    files = tree(esp)
    files["LINUX"] = {"META": (linux / "META").read_bytes(), "ROOT": tree(linux / "ROOT")}
    mib = 300
    total = mib * 1024 * 1024 // fat32.SECTOR
    img = bytearray(total * fat32.SECTOR)
    part = (2048, total - 34)
    fat32.write_gpt(img, total, [(fat32.ESP_TYPE, *part, "AXIOM BOOT")])
    fs = fat32.Fat32(img, part[0], part[1] - part[0] + 1)
    fs.format(spc=8, label=b"AXIOM BOOT ", serial=0x5354494B)
    fs.add_tree(files)
    fs.flush_fat()
    out.write_bytes(img)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--esp", default=str(ROOT / "build" / "esp"))
    ap.add_argument("--root", default=str(ROOT / "build" / "linux"))
    ap.add_argument("--label", default="last")
    args = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    img = OUT / "linux-stick.img"
    stick(pathlib.Path(args.esp), pathlib.Path(args.root), img)
    script = ["until Type 'help'", "wait 1", f"type linux {typed(BASH)}{NL}",
              "until linux: bash", "wait 0.5", "type poweroff" + NL, "ended"]
    extra = ["--smp", "4", "--stick", img.relative_to(ROOT).as_posix()]
    log, _ = boot_all(OUT, {args.label + "-linux": (script, extra, 300, 1)})[args.label + "-linux"]
    found = {}
    for m in re.finditer(r"^lxb (\w+) (\d+)", log, re.M):
        found[NAMES[m.group(1)]] = int(m.group(2)) * 1000       # ns
    if len(found) != len(NAMES):
        print("not all of it ran: build/test/bench/" + args.label + "-linux.log")
        return 1
    for k, v in found.items():
        print(f"  {k:<26} {v / 1e3:12.1f} us")
    (OUT / f"{args.label}-linux.json").write_text(json.dumps(found, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
