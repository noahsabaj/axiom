#!/usr/bin/env python3
"""compose in QEMU: the host's tests (calc.py, app.py), then one boot.

    python tools/test/compose/run.py [--quick]

The boot has a blank NVMe drive (serial AXIOMTEST) for the store, the boot
stick, and a USB tablet. In it, by keyboard and mouse:
  - 'store format', then 'compose report &': a new document, its window;
  - a heading, text, a table typed cell by cell with formulas (=SUM,
    =C2+C3), checked from F12's log of the document; dark, as the
    desktop's theme is, then light after 'settings set display.theme light';
  - a slide frame; Slides (F2), PgUp to the first; F5 presents in a window
    of its own, full screen (over the bar and the dock), the arrow key
    moves on, Esc ends it;
  - Grid (F3), a click on a cell, a formula over the table's totals;
  - the desktop dark again, then F7: light paper, the window still dark;
  - ctrl+S saves into the store and commits; ctrl+Q closes it;
  - 'compose report &' again: the same document, the same values, the
    paper still light;
  - screenshots of each view and the presenter.
The screen is 2560x1600 at two pixels a point: compose's window is
1040x600 points, 2080x1200 pixels.
--quick skips the host's tests. Outputs go to build/test/compose/.
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "tools" / "test"))
from qemu import boot_all  # noqa: E402

OUT = ROOT / "build" / "test" / "compose"
FAILS = 0
SCR_W, SCR_H = 2560, 1600
TABLET = "-device qemu-xhci,id=ux -device usb-tablet,bus=ux.0"
WX, WY = 100, 100                               # compose's frame, once moved
BORDER, TITLE = 0, 56                           # its client, from the frame (pixels)
S = 2                                           # pixels a point
TITLE_BAR = (WX + 1040, WY + 28)                # its title bar's middle: the keys
SHELL1 = (150, 1400)                            # in shell 1, below compose's windows
ACCENT = (0x0A, 0x84, 0xFF)
DARK_PAPER = (0x1C, 0x1C, 0x1F)
DARK_BAR = (0x32, 0x32, 0x36)
LIGHT_BAR = (0xED, 0xED, 0xF0)
BAR_SPOT, DOCK_SPOT = (SCR_W - 10, 20), (SCR_W // 2, SCR_H - 15)  # the menu bar, the dock


def at(x, y):
    """A point on the screen, as the tablet's 0..32767."""
    return f"{(x * 32768 + SCR_W // 2) // SCR_W} {(y * 32768 + SCR_H // 2) // SCR_H}"


def client(x, y):
    """A point in compose's window (points), on the screen (pixels)."""
    return WX + BORDER + x * S, WY + TITLE + y * S


def cell(ref):
    """A cell on the grid view, its first rows and columns shown."""
    return client(52 + 120 * (ord(ref[0]) - 65) + 60, 122 + 26 * (int(ref[1:]) - 1) + 13)


def result(ok, text):
    global FAILS
    FAILS += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + text)
    return ok


def nvme(img):
    return (f"-drive file={img.as_posix()},if=none,id=nvm,format=raw "
            f"-device nvme,serial=AXIOMTEST,drive=nvm")


KEY = {" ": "spc", "\n": "ret", "\t": "tab", "-": "minus", ".": "dot", "/": "slash",
       ",": "comma", "=": "equal", "+": "shift-equal", "*": "shift-8", "(": "shift-9",
       ")": "shift-0", ":": "shift-semicolon", '"': "shift-apostrophe", ">": "shift-dot",
       "<": "shift-comma"}


def press(text):
    """Text on the keyboard, key by key: the same queue as the keys pressed
    around it, so nothing overtakes it (the serial port is read only as the
    kernel looks, 16 bytes at a time)."""
    out = []
    for ch in text:
        name = KEY.get(ch) or ("shift-" + ch.lower() if ch.isupper() else ch)
        out += [f"sendkey {name} 20", "wait 0.04"]
    return out


def script():
    shot = lambda name: f"shot build/test/compose/{name}.png"  # noqa: E731
    return [
        "until settings:", "wait 1",
        "type store format\\n", "until store: disk", "wait 0.5",
        "type compose report &\\n", "until compose: new report.axd", "wait 1",
        f"abs {at(*SHELL1)} left", "wait 0.5",               # the keys, to the shell
        "type win move 5 100 100\\n", "wait 0.5",
        "type win\\n", "until desk: 5 ", "wait 0.5",
        f"abs {at(*client(700, 300))} left", "wait 0.5",      # and to compose
        "sendkey ctrl-n", "wait 0.2",
        *press("Quarterly report\nSales grew this quarter.\n"),
        "sendkey ctrl-t", "wait 0.3",
        *press("Region\tQ1\tQ2\tNorth\t120\t140\tSouth\t80\t95\t"),
        *press("Total\t=SUM(B2:B3)\t=C2+C3\n"),
        *press("The grid works the totals out."), "wait 0.5",
        shot("pages"),
        "sendkey f12", "until compose: document", "wait 0.5",
        f"abs {at(*SHELL1)} left", "wait 0.5",               # the system's theme: light
        "type settings set display.theme light\\n", "until compose: paper auto, light",
        "wait 0.5", shot("pages_light"),
        f"abs {at(*TITLE_BAR)} left", "wait 0.5",      # compose's title: the keys back
        "sendkey ctrl-k", "wait 0.3",
        *press("Highlights\nRevenue up 12 percent\n"),
        "sendkey f2", "until compose: view slides", "wait 0.5",
        shot("slides"),
        "sendkey pgup", "wait 0.3",
        "sendkey f5", "until compose: presenting slide", "wait 1",
        shot("presenting"),                                  # full screen, with the keys
        "sendkey right", "until compose: presenting slide 2", "wait 0.5",
        "sendkey esc", "until compose: presenting ended", "wait 0.5",
        f"abs {at(*TITLE_BAR)} left", "wait 0.5",      # the keys back from where they went
        "sendkey f3", "until compose: view grid", "wait 0.5",
        f"abs {at(*cell('D2'))} left", "wait 0.3",
        *press("=B4+C4\n"), "wait 0.5",
        shot("grid"),
        "sendkey f12", "until compose: document", "wait 0.5",
        f"abs {at(*SHELL1)} left", "wait 0.5",               # the desktop dark again
        "type settings set display.theme dark\\n", "until compose: paper auto, dark",
        f"abs {at(*TITLE_BAR)} left", "wait 0.5",
        "sendkey f1", "until compose: view pages", "wait 0.3",
        "sendkey f7", "until compose: paper light, dark", "wait 0.5",  # the paper light
        shot("light_paper"),
        "sendkey f3", "until compose: view grid", "wait 0.3",
        "sendkey ctrl-s", "until compose: saved report.axd", "wait 0.5",
        "sendkey ctrl-q", "until run: COMPOSE exited", "wait 0.5",
        f"abs {at(*SHELL1)} left", "wait 0.3",
        "type compose report &\\n", "until compose: opened report.axd", "wait 1",
        "sendkey f12", "until compose: document", "wait 0.5",
        shot("reopened"),
        "sendkey ctrl-q", "until run: COMPOSE exited", "wait 0.5",
        f"abs {at(*SHELL1)} left", "wait 0.3",
        "type poweroff\\n", "ended",
    ]


def cells(log):
    """{ref: value} from each F12 dump, in turn: a list of them."""
    dumps = []
    for part in log.split("compose: document, ")[1:]:
        d = {}
        for m in re.finditer(r"^compose:   ([A-Z]\d+) = (.*) -> (.*)$", part, re.M):
            d[m.group(1)] = m.group(3)
        dumps.append(d)
    return dumps


def pixel(name, x, y):
    from PIL import Image
    try:
        return Image.open(OUT / name).convert("RGB").getpixel((x, y))
    except OSError:
        return None


def near(a, b, tol=24):
    return a is not None and all(abs(p - q) <= tol for p, q in zip(a, b))


def check(log, err):
    result("compose: new report.axd" in log, "a new document, its window")
    result(re.search(r"^desk: 5 'report\.axd .{1,3} Compose' at 100,100, 2080x1200", log, re.M)
           is not None, "its window: 1040x600 points, moved to 100,100")
    d = cells(log)
    first = d[0] if d else {}
    result((first.get("B4"), first.get("C4")) == ("200", "235"),
           f"the table's formulas: B4 {first.get('B4')}, C4 {first.get('C4')}")
    result(re.search(r'^compose: 0 h1 "Quarterly report"$', log, re.M) is not None,
           "a heading typed")
    result("compose: presenting slide 1 of 2" in log, "presenting, from the slide shown")
    shown = log[log.find("compose: view slides"):log.find("compose: presenting ended")]
    over = [pixel("presenting.png", *p) for p in (BAR_SPOT, DOCK_SPOT)]
    result("goes full screen" in shown and all(near(p, (0, 0, 0), 2) for p in over),
           f"the presenter's window: the screen, over the bar and the dock ({over})")
    result("compose: presenting slide 2 of 2" in log, "the next slide")
    result("compose: presenting ended" in log, "presenting ended")
    grid = d[1] if len(d) > 1 else {}
    result(grid.get("D2") == "435", f"a formula on the grid view: D2 {grid.get('D2')}")
    result(re.search(r"^compose: saved report\.axd, \d+ bytes, \d+ blocks$", log, re.M)
           is not None, "saved into the store")
    again = d[2] if len(d) > 2 else {}
    result(again == grid and again != {}, "opened again: the same cells and values")
    blocks = [re.findall(r"^compose: \d+ (\w+) ", part, re.M)
              for part in log.split("compose: document, ")[2:4]]
    result(len(blocks) == 2 and blocks[0] == blocks[1], "opened again: the same blocks")
    result("compose: closed" in log, "ctrl+Q closes it")
    result(near(pixel("pages.png", *client(894, 26)), ACCENT), "on the screen: its toolbar")
    result("compose: paper auto, dark" in log, "the desktop's theme, dark, followed")
    result(near(pixel("pages.png", *client(140, 120)), DARK_PAPER, 2) and
           near(pixel("pages.png", *client(600, 5)), DARK_BAR, 2), "a page and the toolbar, dark")
    result(near(pixel("pages_light.png", *client(140, 120)), (255, 255, 255), 2) and
           near(pixel("pages_light.png", *client(600, 5)), LIGHT_BAR, 2),
           "'settings set display.theme light': the page and the toolbar, light")
    result(near(pixel("light_paper.png", *client(140, 120)), (255, 255, 255), 2) and
           near(pixel("light_paper.png", *client(600, 5)), DARK_BAR, 2),
           "F7 in the dark: light paper, the toolbar dark")
    result(len(re.findall(r"^compose: paper light, dark$", log, re.M)) == 2,
           "opened again: light paper, as F7 left it")
    result(near(pixel("reopened.png", *client(800, 300)), (255, 255, 255), 2),
           "opened again: the grid's cells on light paper")
    result("AXIOM PANIC" not in log, "no panic")
    result("QEMU ended by itself" in err, "powered off")


def main():
    quick = "--quick" in sys.argv
    if not quick:
        for t in ("calc.py", "app.py"):
            r = subprocess.run([sys.executable, str(HERE / t)], cwd=ROOT, capture_output=True,
                               text=True)
            result(r.returncode == 0, f"host: {t}" + ("" if r.returncode == 0 else
                                                      "\n" + (r.stdout + r.stderr)[-2000:]))
    OUT.mkdir(parents=True, exist_ok=True)
    stick = OUT / "stick.img"
    subprocess.run([sys.executable, str(ROOT / "tools" / "mkstick.py"), str(stick)], cwd=ROOT,
                   check=True, capture_output=True)
    img = OUT / "nvme.img"
    img.write_bytes(bytes(64 << 20))
    logs = boot_all(OUT, {"compose": (script(), ["--smp", "4", "--mem", "2G", "--extra",
                                                 TABLET + " " + nvme(img), "--stick",
                                                 stick.relative_to(ROOT).as_posix()], 150, 2)})
    check(*logs["compose"])
    print(f"{'all passed' if not FAILS else f'{FAILS} FAILED'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
