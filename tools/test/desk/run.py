#!/usr/bin/env python3
"""Axiom's desktop in QEMU: windows, the bar, shells, by keyboard and mouse.

    python tools/test/desk/run.py

Boots build/esp from a USB stick, with a USB tablet (an absolute pointer) and checks, from the
serial log ('win' lists the windows) and from screenshots:
  - at the start: four windows (shell 1 with the keys, System, Processors,
    the Mandelbrot), the bar across the top;
  - 'win move' and its clamps (a title bar stays on the screen, under the
    bar), 'win size', 'win raise', 'win min';
  - a window dragged by its title bar, resized from its corner;
  - '+ shell' on the bar: shell 2 opens with the keys and what is typed goes
    there; a click on shell 1 gives them back; shell 2 closed by its close
    button; the 'shell' command opens another, 'win close' closes it;
  - System minimised by its title bar button, shown again from the bar, and
    not closed by 'win close';
  - the wheel over a shell scrolls it back, a key there brings it home;
  - the Mandelbrot held by a right click (its frame count stays);
  - on the screen: the bar, and the desktop where System was;
  - a program's window: 'run paint' opens one with the keys; strokes drawn
    with the mouse land in its pixels, a key changes the colour and its
    title, its close button ends the program and the window goes; ctrl+C
    in its shell kills it, and the window goes too.
Outputs go to build/test/desk/.
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "test"))
from qemu import boot_all  # noqa: E402

OUT = ROOT / "build" / "test" / "desk"
FAILS = 0
SCR_W, SCR_H = 2560, 1600                       # QEMU's screen, as Axiom sets it
BAR = 60                                        # the bar's height
TITLE = 45                                      # a title bar (1.5 cells)
BORDER = 1
BTN = 45                                        # a title bar button (3 cells)
TABLET = "-device qemu-xhci,id=ux -device usb-tablet,bus=ux.0"
COL_BG = (0x0A, 0x0D, 0x13)                     # the desktop
COL_PANEL = (0x10, 0x15, 0x1F)                  # the bar, a window's client
# System, once moved, sized, dragged and resized: its frame's corner, its
# client's size
SX, SY = 100 + 400, 200 + 600
SW, SH = 600 + 100, 300 + 50
# the bar: AXIOM, then '+ shell', then a button per window (2 cells more than
# its title, 16 at most), 2 pixels apart
PLUS = (105 + 240) // 2
SYSTEM_BTN = 379 + 120 // 2
SHELL1 = (400, 1300)                            # a point in shell 1, once moved
SHELL4 = (1000, 800)                            # in the shell opened for paint
PX, PY = 1300, 200                              # paint's frame, once moved
PW, PH = 600, 400
INK, RED, PAPER = (0x1B, 0x1F, 0x27), (0xD9, 0x48, 0x3B), (0xF4, 0xF1, 0xE8)


def client(x, y):
    """A point in paint's window, on the screen."""
    return PX + BORDER + x, PY + BORDER + TITLE + y


def at(x, y):
    """A point on the screen, as the tablet's 0..32767."""
    return f"{(x * 32768 + SCR_W // 2) // SCR_W} {(y * 32768 + SCR_H // 2) // SCR_H}"


def result(ok, text):
    global FAILS
    FAILS += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + text)
    return ok


WIN = re.compile(r"^desk: (\d+) '([^'\n]*)' at (-?\d+),(-?\d+), (\d+)x(\d+), (\w+)"
                 r"(?:, (\d+) lines, (\d+) back)?$", re.M)


def listing(log, mark):
    """The windows, by title (the Mandelbrot's cut at its first ' · '), as
    'win' listed them after the line 'desk: -- mark'."""
    m = re.search(rf"^desk: -- {re.escape(mark)}$", log, re.M)
    if not m:
        return {}
    n = re.compile(r"^desk: -- ", re.M).search(log, m.end())
    wins = {}
    for w in WIN.finditer(log, m.end(), n.start() if n else len(log)):
        if w.group(2).split(" · ")[0] in wins:
            break                               # what the next command said
        wins[w.group(2).split(" · ")[0]] = {
            "id": int(w.group(1)), "title": w.group(2), "x": int(w.group(3)),
            "y": int(w.group(4)), "w": int(w.group(5)), "h": int(w.group(6)),
            "state": w.group(7), "lines": int(w.group(8)) if w.group(8) else None,
            "back": int(w.group(9)) if w.group(9) else None}
    return wins


def win(mark):
    """'win', marked so its listing can be found."""
    return [f"type echo desk: -- {mark}\\n", "wait 0.3", "type win\\n", "wait 0.6"]


def script():
    tx, ty = 100 + 300, 200 + BORDER + TITLE // 2       # on System's title bar
    gx, gy = 100 + 400 + BORDER + 600 - 3, 200 + 600 + BORDER + TITLE + 300 - 3   # its grip
    return [
        "until log: kept in", "wait 1.5",
        *win("start"),
        "shot build/test/desk/start.png",
        "type win move 2 0 0\\n", "wait 0.3", *win("clamp low"),
        "type win move 2 9000 9000\\n", "wait 0.3", *win("clamp high"),
        "type win move 2 100 200\\n", "wait 0.3",
        "type win size 2 600 300\\n", "wait 0.3", *win("moved"),
        # (a press on System gives it the keys: a click on shell 1 takes
        # them back)
        f"drag {at(tx, ty)} {at(tx + 400, ty + 600)}", "wait 0.5",
        f"abs {at(*SHELL1)} left", "wait 0.3", *win("dragged"),
        f"drag {at(gx, gy)} {at(gx + 100, gy + 50)}", "wait 0.5",
        f"abs {at(*SHELL1)} left", "wait 0.3", *win("resized"),
        # a new shell, from the bar
        f"abs {at(PLUS, BAR // 2)} left", "until desk: shell 2 opens", "wait 0.5",
        "type echo typed in two\\n", "wait 0.5", *win("two"),
        "type win move 5 300 300\\n", "wait 0.3",
        "type win size 5 1260 720\\n", "wait 0.3",
        "type win move 1 0 1000\\n", "wait 0.5",
        "shot build/test/desk/two.png",
        # shell 1, where nothing covers it: the keys back
        f"abs {at(*SHELL1)} left", "wait 0.5",
        "type echo typed in one\\n", "wait 0.5", *win("one"),
        # shell 2's close button, at the right of its title bar
        "type win raise 5\\n", "wait 0.3",
        f"abs {at(300 + BORDER + 1260 - BTN // 2, 300 + BORDER + TITLE // 2)} left",
        "until desk: shell 2 closes", "wait 0.5", *win("closed"),
        # System's minimise button (it has no close button), then its button
        # on the bar
        f"abs {at(SX + BORDER + SW - BTN // 2, SY + BORDER + TITLE // 2)} left", "wait 0.5",
        *win("minimised"),
        "shot build/test/desk/minimised.png",
        f"abs {at(SYSTEM_BTN, BAR // 2)} left", "wait 0.5",
        f"abs {at(*SHELL1)} left", "wait 0.3", *win("restored"),
        "type win close 2\\n", "wait 0.5",
        # the Mandelbrot held by a right click: its frame count stays
        f"abs {at(1000, 400)} right", "wait 0.5",
        f"abs {at(*SHELL1)} left", "wait 0.3",
        *win("held"), "wait 1", *win("still held"),
        # shell 1 filled, then another shell, out of the way, to watch it
        "type help\\n", "wait 0.5", "type help\\n", "wait 0.5",
        "type shell\\n", "until desk: shell 3 opens", "wait 0.5",
        "type win move 6 1300 900\\n", "wait 0.3",
        f"wheel {at(*SHELL1)} 3", "wait 0.5", *win("wheel"),
        f"abs {at(*SHELL1)} left", "wait 0.3",
        "type x", "wait 0.3", "sendkey backspace", "wait 0.3", *win("home"),
        "type win close 6\\n", "until desk: shell 3 closes", "wait 0.3",
        # a program's window: paint, then a shell to work from
        "type run paint 600 400\\n", "until paint: a window", "wait 0.5",
        f"abs {at(PLUS, BAR // 2)} left", "until desk: shell 4 opens", "wait 0.5",
        "type win move 8 100 100\\n", "wait 0.3",
        "type win move 7 1300 200\\n", "wait 0.3", *win("paint"),
        f"drag {at(*client(100, 100))} {at(*client(400, 300))}", "wait 0.5",
        "type 2", "wait 0.3",
        f"drag {at(*client(100, 350))} {at(*client(400, 350))}", "wait 0.5",
        f"abs {at(*SHELL4)} left", "wait 0.3", *win("painted"),
        "shot build/test/desk/paint.png",
        f"abs {at(PX + BORDER + PW - BTN // 2, PY + BORDER + TITLE // 2)} left",
        "until run: PAINT exited", "wait 0.5", *win("paint closed"),
        # again, killed by ctrl+C in its shell
        "type run paint\\n", "until paint: a window", "wait 0.5",
        f"abs {at(*SHELL4)} left", "wait 0.3", "sendkey ctrl-c", "until run: PAINT", "wait 0.5",
        f"abs {at(*SHELL1)} left", "wait 0.3", *win("paint killed"),
        "type objects\\n", "wait 0.5",
        "type poweroff\\n", "ended",
    ]


def pixel(name, x, y):
    from PIL import Image
    try:
        return Image.open(OUT / name).convert("RGB").getpixel((x, y))
    except OSError:
        return None


def near(a, b, by=2):
    return abs(a - b) <= by


def check(log, err):
    s = listing(log, "start")
    result(list(s) == ["shell 1", "System", "Processors", "Mandelbrot"],
           f"at the start: {', '.join(s) or 'no windows'}")
    result(s.get("shell 1", {}).get("state") == "focused", "shell 1 has the keys")
    result(all(w["state"] == "shown" for t, w in s.items() if t != "shell 1"),
           "the others shown")
    result(all(w["y"] >= BAR for w in s.values()), "all of them under the bar")
    result(s.get("shell 1", {}).get("lines", 0) > 5, "shell 1 has the boot's lines")
    result(re.search(r"frame \d+", s.get("Mandelbrot", {}).get("title", "")) is not None,
           "the Mandelbrot's title has its frame")

    w = listing(log, "clamp low").get("System", {})
    result((w.get("x"), w.get("y")) == (0, BAR), f"win move 2 0 0: at {w.get('x')},{w.get('y')}"
                                                   " (under the bar)")
    w = listing(log, "clamp high").get("System", {})
    result((w.get("x"), w.get("y")) == (SCR_W - 90, SCR_H - TITLE - BORDER),
           f"win move 2 9000 9000: at {w.get('x')},{w.get('y')} (its title bar on the screen)")
    w = listing(log, "moved").get("System", {})
    result((w.get("x"), w.get("y"), w.get("w"), w.get("h")) == (100, 200, 600, 300),
           f"win move, win size: {w.get('x')},{w.get('y')}, {w.get('w')}x{w.get('h')}")
    w = listing(log, "dragged").get("System", {})
    result(w and near(w["x"], SX) and near(w["y"], SY) and w["w"] == 600,
           f"dragged by its title bar to {w.get('x')},{w.get('y')}")
    w = listing(log, "resized").get("System", {})
    result(w and near(w["w"], SW) and near(w["h"], SH) and near(w["x"], SX),
           f"resized from its corner to {w.get('w')}x{w.get('h')}")

    two = listing(log, "two")
    result("desk: shell 2 opens" in log and two.get("shell 2", {}).get("state") == "focused",
           "'+ shell' opened shell 2, with the keys")
    result(re.search(r"^typed in two$", log, re.M) is not None, "shell 2 ran what was typed")
    # three commands in shell 2, the last saying how many lines shell 1 has
    a = two.get("shell 1", {}).get("lines")
    m = re.search(r"^desk: 1 'shell 1' at 0,1000, \d+x\d+, \w+, (\d+) lines", log, re.M)
    result(a and m and int(m.group(1)) == a,
           f"shell 1 got none of it ({a} lines, then {m.group(1) if m else '?'})")
    one = listing(log, "one")
    result(one.get("shell 1", {}).get("state") == "focused"
           and one.get("shell 2", {}).get("state") == "shown", "a click on shell 1: its keys")
    c = one.get("shell 2", {}).get("lines", 0)
    d = listing(log, "closed")
    result(c and two.get("shell 2", {}).get("lines", 0) <= c, "shell 2 kept its lines")
    result("shell 2" not in d and len(d) == 4, "shell 2's close button closed it")

    m = listing(log, "minimised").get("System", {})
    result(m.get("state") == "minimised", "System's minimise button: " + str(m.get("state")))
    m = listing(log, "restored").get("System", {})
    result(m.get("state") in ("focused", "shown") and near(m.get("x", 0), SX),
           "its button on the bar showed it again, where it was")
    result("desk: 'System' can be minimised, not closed" in log, "win close 2: not closed")

    f1 = re.search(r"frame (\d+)", listing(log, "held").get("Mandelbrot", {}).get("title", ""))
    f2 = re.search(r"frame (\d+)", listing(log, "still held").get("Mandelbrot", {})
                   .get("title", ""))
    f0 = re.search(r"frame (\d+)", s.get("Mandelbrot", {}).get("title", ""))
    result(f0 and f1 and f2 and f1.group(1) == f2.group(1) and f0.group(1) != f1.group(1),
           "a right click held the Mandelbrot (frame " +
           (f"{f1.group(1)}, a second later {f2.group(1)})" if f1 and f2 else "?)"))

    result("desk: shell 3 opens" in log, "'shell' opened shell 3")
    w = listing(log, "wheel")
    result(w.get("shell 3", {}).get("state") == "focused"
           and w.get("shell 1", {}).get("back") == 9,
           f"the wheel over shell 1 scrolled it back {w.get('shell 1', {}).get('back')} lines")
    w = listing(log, "home").get("shell 1", {})
    result(w.get("back") == 0 and w.get("state") == "focused", "a key there brought it home")
    result("desk: shell 3 closes" in log, "win close 6 closed shell 3")

    pw = listing(log, "paint").get("paint", {})
    result("paint: a window 600x400" in log and pw.get("id") == 7, "run paint: its window, 7")
    result((pw.get("x"), pw.get("y"), pw.get("w"), pw.get("h")) == (PX, PY, PW, PH),
           f"win move 7: at {pw.get('x')},{pw.get('y')}, {pw.get('w')}x{pw.get('h')}")
    result(pw.get("title") == "paint · ink", f"titled by the program: {pw.get('title')!r}")
    w = listing(log, "painted").get("paint", {})
    result(w.get("title") == "paint · red", f"a key to it: {w.get('title')!r}")
    for what, (x, y), want in (("the first stroke", (250, 200), INK),
                               ("the second, red", (250, 350), RED),
                               ("paper elsewhere", (500, 50), PAPER)):
        p = pixel("paint.png", *client(x, y))
        result(p == want, f"paint: {what} ({p})")
    result(re.search(r"^paint: 2 strokes$", log, re.M) is not None,
           "its close button: it ended, 2 strokes")
    result("run: PAINT exited with 0" in log, "and returned 0")
    result(listing(log, "paint closed") and "paint" not in listing(log, "paint closed"),
           "its window went")
    result(listing(log, "paint killed") and "paint" not in listing(log, "paint killed")
           and "run: PAINT stopped" in log, "ctrl+C: killed, its window gone")
    result(re.search(r"^\s+desktop\s+\d+", log, re.M) is not None, "'objects': the desktop")

    p = pixel("start.png", 1500, 3)
    result(p == COL_PANEL, f"the bar on the screen ({p})")
    p, q = pixel("two.png", 915, 1100), pixel("minimised.png", 915, 1100)
    result(p is not None and p != COL_BG and q == COL_BG,
           f"System on the screen ({p}), then the desktop where it was ({q})")
    result("AXIOM PANIC" not in log, "no panic")
    result("QEMU ended by itself" in err, "powered off")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    stick = OUT / "stick.img"                   # paint is run from it
    subprocess.run([sys.executable, str(ROOT / "tools" / "mkstick.py"), str(stick)], cwd=ROOT,
                   check=True, capture_output=True)
    logs = boot_all(OUT, {"desk": (script(), ["--smp", "4", "--extra", TABLET, "--stick",
                                              stick.relative_to(ROOT).as_posix()], 120)})
    check(*logs["desk"])
    print(f"{'all passed' if not FAILS else f'{FAILS} FAILED'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
