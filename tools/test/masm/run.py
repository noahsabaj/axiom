#!/usr/bin/env python3
"""Axiom's MASM programs in QEMU: sdk/masm built (tools/masm.py: ml64, link,
tools/mkaxe.py) onto a stick, then run from the shell and checked from the
serial log and the screen.

    python tools/test/masm/run.py

  - mhello: its arguments (the start block's SB_ARGS); 50 ms slept by the
    clock (RO_TIMEOUT); a thread of its own, joined (RO_JOIN), its result
    back; a window (WNF_KEYS) filled with its colour, on the screen; a key
    as text and down and up as its HID usage; q ends it, 0.
Skipped (passing) if there is no MSVC with ml64. Outputs go to
build/test/masm/.
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "test"))
from qemu import boot_all  # noqa: E402

OUT = ROOT / "build" / "test" / "masm"
FAILS = 0
CX, CY = 472, 448                       # its window, where the desktop puts it
COLOR = (0x30, 0x60, 0xA0)


def result(ok, text):
    global FAILS
    FAILS += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + text)
    return ok


SCRIPT = [
    "until log: kept in", "wait 1.5",
    "type mhello one two\\n", "until mhello: window open", "until ' opens", "wait 0.5",
    "shot build/test/masm/open.png",
    "sendkey a", "wait 0.4",
    "type q", "until run: MHELLO exited", "wait 0.3",
]


def pixel(name, x, y):
    from PIL import Image
    try:
        return Image.open(OUT / name).convert("RGB").getpixel((x, y))
    except OSError:
        return None


def check(log, err):
    def has(text):
        return text in log

    result(has("mhello: args [mhello one two]") or has("mhello: args [one two]"),
           "mhello: its arguments")
    m = re.search(r"mhello: slept (\d+) ms", log)
    result(bool(m) and 50 <= int(m.group(1)) < 500, f"mhello: the clock ({m.group(0) if m else 'no line'})")
    result(has("mhello: thread returned 42"), "mhello: a thread, joined, its result back")
    result(has("mhello: window open"), "mhello: its window")
    p = pixel("open.png", CX + 10, CY + 10)
    result(p == COLOR, f"mhello: its colour on the screen ({p})")
    result(has("mhello: key 97"), "mhello: a key as text")
    result(has("mhello: down 0x04") and has("mhello: up 0x04"), "mhello: and down and up, as its HID usage")
    result(has("mhello: bye") and has("run: MHELLO exited with 0"), "mhello: q ends it, 0")
    for line in log.splitlines():
        if "ended by a fault" in line or "PANIC" in line:
            result(False, f"no faults: {line}")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    built = subprocess.run([sys.executable, str(ROOT / "tools" / "masm.py")], cwd=ROOT,
                           capture_output=True, text=True)
    if built.returncode == 3:
        print("SKIP " + built.stdout.strip())
        print("all passed (skipped)")
        return 0
    if built.returncode:
        print(built.stdout + built.stderr)
        print("FAIL the MASM programs did not build")
        return 1
    stick = OUT / "stick.img"
    subprocess.run([sys.executable, str(ROOT / "tools" / "mkstick.py"), str(stick)], cwd=ROOT,
                   check=True, capture_output=True)
    logs = boot_all(OUT, {
        "masm": (SCRIPT, ["--smp", "2", "--demo", "--stick", stick.relative_to(ROOT).as_posix()], 90, 1)})
    check(*logs["masm"])
    print(f"{'all passed' if not FAILS else f'{FAILS} FAILED'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
