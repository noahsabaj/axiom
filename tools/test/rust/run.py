#!/usr/bin/env python3
"""Axiom's Rust programs in QEMU: sdk/rust built (tools/rust.py) onto a
stick, then run from the shell and checked from the serial log and the
screen.

    python tools/test/rust/run.py

  - rhello (no std): its arguments; the heap (3000 allocations of every
    size, a third kept and checked, 12 MiB at once, a vector grown to 16 MiB,
    a page-aligned one); the volumes; its own .AXE read back whole and found
    in its folder's listing at that size; 50 ms slept by the clock; exit 0;
  - rdemo (std): println, std::env::args, a window that can be resized
    (640x400, its stride the screen's width), drawn each frame: its ground
    and its square on the screen; keys (a letter, ctrl+A, F5), a drag (the
    press where it began, the square where it ended), the wheel, then its
    close button: it ends, 0, having counted what happened.
Skipped (passing) if there is no nightly toolchain. Outputs go to
build/test/rust/.
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "test"))
from qemu import boot_all  # noqa: E402

OUT = ROOT / "build" / "test" / "rust"
FAILS = 0
SCR_W, SCR_H = 2560, 1600
PT = 2
TITLE = 28 * PT
TABLET = "-device qemu-xhci,id=ux -device usb-tablet,bus=ux.0"
CX, CY = 472, 448                       # rdemo's window, where the desktop puts it
GROUND, MARK = (0x20, 0x30, 0x40), (0xE0, 0xA0, 0x30)
FROM, TO = (300, 200), (420, 260)       # the drag, in the window


def at(x, y):
    """A point on the screen, as the tablet's 0..32767."""
    return f"{(x * 32768 + SCR_W // 2) // SCR_W} {(y * 32768 + SCR_H // 2) // SCR_H}"


def win(x, y):
    return at(CX + x, CY + y)


def result(ok, text):
    global FAILS
    FAILS += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + text)
    return ok


def script():
    return [
        "until log: kept in", "wait 1.5",
        'type rhello one "two words"\\n', "until run: RHELLO exited", "wait 0.3",
        "type rdemo\\n", "until rdemo: first frame", "wait 0.5",
        "shot build/test/rust/open.png",
        "type x", "wait 0.2", "sendkey ctrl-a", "wait 0.2", "sendkey f5", "wait 0.5",
        f"drag {win(*FROM)} {win(*TO)}", "wait 0.8",
        f"wheel {win(*TO)} 2", "wait 0.3",
        "shot build/test/rust/dragged.png",
        f"abs {at(CX + 14 * PT, CY - TITLE // 2)} left",   # its close button
        "until run: RDEMO exited", "wait 0.3",
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

    # rhello
    result(has('rhello: 2 args ["one", "two words"]') or has('rhello: 3 args ["one", "two", "words"]'),
           "rhello: its arguments")
    m = re.search(r"rhello: heap (\d+) bytes, (\d+) kept, (\w+), big (\d+), grown (\w+), aligned (\w+)", log)
    result(bool(m) and m.group(2) == "1000" and m.group(3) == "intact" and
           m.group(4) == str(7 * (3 << 20)) and m.group(5) == "true" and m.group(6) == "true",
           f"rhello: the heap ({m.group(0) if m else 'no line'})")
    m = re.search(r"rhello: read (\d+) bytes of vol\d+:/EFI/AXIOM/RHELLO.AXE, magic AXIOMEX2", log)
    size = (ROOT / "build" / "esp" / "EFI" / "AXIOM" / "RHELLO.AXE").stat().st_size
    result(bool(m) and int(m.group(1)) == size, f"rhello: its own file read back ({size} bytes)")
    result(has(f"RHELLO.AXE {size}"), "rhello: and found in its folder at that size")
    result(bool(re.search(r"rhello: vol\d+ 'AXIOM BOOT' \d+ MiB flags \d+", log)), "rhello: the volumes")
    m = re.search(r"rhello: slept (\d+) ms", log)
    result(bool(m) and 50 <= int(m.group(1)) < 500, f"rhello: the clock ({m.group(0) if m else 'no line'})")
    result(has("run: RHELLO exited with 0"), "rhello: exit 0")

    # rdemo
    result(has("rdemo: std says hello, 1 args"), "rdemo: std's println and args")
    result(has("rdemo: first frame 640x400, stride 2560"), "rdemo: its window, and its stride")
    result(has("rdemo: key Char('x')"), "rdemo: a letter")
    result(has("rdemo: key Char('a') ctrl"), "rdemo: ctrl+A")
    result(has("rdemo: key F(5)"), "rdemo: F5")
    m = re.search(r"rdemo: press Left at (\d+),(\d+)", log)        # (the tablet's rounding: a pixel)
    result(bool(m) and abs(int(m.group(1)) - FROM[0]) <= 1 and abs(int(m.group(2)) - FROM[1]) <= 1,
           f"rdemo: the press, where the drag began ({m.group(0) if m else 'no line'})")
    m = re.search(r"rdemo: (\d+) frames in [\d.]+ s; \[(.*)\]", log)
    kinds = dict(re.findall(r'\("(\w+)", (\d+)\)', m.group(2))) if m else {}
    result(bool(m) and int(m.group(1)) >= 10 and "move" in kinds and "wheel" in kinds and
           "release" in kinds, f"rdemo: its count ({m.group(0) if m else 'no line'})")
    result(has("run: RDEMO exited with 0"), "rdemo: its close button ends it, 0")
    p = pixel("open.png", CX + 10, CY + 200)
    result(p == GROUND, f"rdemo: its ground on the screen ({p})")
    p = pixel("open.png", CX + 100, CY + 100)
    result(p == MARK, f"rdemo: its square ({p})")
    p = pixel("dragged.png", CX + TO[0] - 12, CY + TO[1] - 12)      # up and left of the pointer
    result(p == MARK, f"rdemo: the square where the drag ended ({p})")
    p = pixel("dragged.png", CX + 100, CY + 100)
    result(p == GROUND, f"rdemo: and gone from where it was ({p})")
    for line in log.splitlines():
        if "panicked" in line or "ended by a fault" in line or "PANIC" in line:
            result(False, f"no panics, no faults: {line}")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    built = subprocess.run([sys.executable, str(ROOT / "tools" / "rust.py")], cwd=ROOT,
                           capture_output=True, text=True)
    if built.returncode == 3:
        print("SKIP " + built.stdout.strip())
        print("all passed (skipped)")
        return 0
    if built.returncode:
        print(built.stdout + built.stderr)
        print("FAIL the Rust programs did not build")
        return 1
    stick = OUT / "stick.img"
    subprocess.run([sys.executable, str(ROOT / "tools" / "mkstick.py"), str(stick)], cwd=ROOT,
                   check=True, capture_output=True)
    logs = boot_all(OUT, {"rust": (script(), ["--smp", "4", "--demo", "--extra", TABLET, "--stick",
                                              stick.relative_to(ROOT).as_posix()], 120, 2)})
    check(*logs["rust"])
    print(f"{'all passed' if not FAILS else f'{FAILS} FAILED'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
