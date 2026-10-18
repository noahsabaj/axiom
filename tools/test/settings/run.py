#!/usr/bin/env python3
"""Axiom's settings in QEMU: the shell's 'settings', the Settings window,
and what is kept on the stick.

    python tools/test/settings/run.py

Two boots, one after the other, from the same USB stick:
  - the first: 'settings' as records (all of them, one, a category, a
    pattern, through '| where' and '| count'), 'settings set' for each kind
    and the errors that name what a setting takes, 'settings reset', 'help
    settings'; the look changed live (the bar's pixels, light then dark);
    then 'run settings': its window follows the shell ('settings set
    display.theme dark' repaints it), and clicks in it (a swatch, a slider,
    a switch, a stepper, a field typed into) change what the shell lists;
  - between them, SETTINGS.TXT on the stick holds what is not a default;
  - the second: those values, read at boot (the larger text from the very
    start), the keyboard laid out as Dvorak (keys pressed for 'jdpps' run
    hello), the power button doing what power.button says, and 'settings
    reset all' leaving SETTINGS.TXT without a setting.
The look is the desktop's theme (theme.asm): the shell's 'theme' and the
settings change the same thing, and each says what the other did.
Outputs go to build/test/settings/.
"""
import pathlib
import re
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "test"))
sys.path.insert(0, str(ROOT / "tools"))
from qemu import boot_all  # noqa: E402
import fat32  # noqa: E402

OUT = ROOT / "build" / "test" / "settings"
FAILS = 0
NL = "\\n"
TABLET = "-device qemu-xhci,id=ux -device usb-tablet,bus=ux.0"
SCR_W, SCR_H = 2560, 1600
SHELL1 = (100, 1300)                            # in shell 1, left of where Settings opens
WX, WY = 1200, 100                              # the Settings window's frame, once moved
BORDER, TITLE = 0, 28 * 2                       # its title bar, 28 points at 2 pixels
LIGHT_SIDE, DARK_SIDE = (0xE5, 0xE5, 0xEA), (0x0A, 0x0D, 0x13)
BAR_SPOT = (1500, 3)                            # an empty part of the menu bar
SIDE_SPOT = (20, 760)                           # the app's sidebar, under its categories
SETTINGS_N = 18


def result(ok, text):
    global FAILS
    FAILS += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + text)
    return ok


def table(lines):
    """A table's lines -> [{column: cell}], from its header (lines the log
    put between them, not indented, left out)."""
    lines = [l.strip() for l in lines if l.startswith("  ") and l.strip()]
    if not lines:
        return []
    head = re.split(r" {2,}", lines[0])
    return [dict(zip(head, re.split(r" {2,}", l))) for l in lines[1:]]


def record(lines):
    """One record's lines ('  field  value') -> {field: value}."""
    out = {}
    for l in lines:
        m = re.match(r"^ +(\S+) {2,}(.*)$", l)
        if m:
            out[m.group(1)] = m.group(2)
    return out


def said(text):
    return lambda lines: any(text in l for l in lines)


def values(lines):
    return {r.get("name"): r.get("value") for r in table(lines)}


def at(x, y):
    """A point on the screen, as the tablet's 0..32767."""
    return f"{(x * 32768 + SCR_W // 2) // SCR_W} {(y * 32768 + SCR_H // 2) // SCR_H}"


def app(x, y):
    """A point in the Settings window's client, on the screen."""
    return at(WX + BORDER + x, WY + BORDER + TITLE + y)


def cat(i):
    return app(150, 96 + 50 * i + 21)


# (typed, check, what): the first boot's shell steps
FIRST = [
    ("settings", lambda l: len(table(l)) == SETTINGS_N and
     list(table(l)[0]) == ["name", "value", "default", "kind", "about"] and
     table(l)[0]["name"] == "display.theme", "settings: every setting, as records"),
    ("settings display.theme", lambda l: record(l).get("value") == "dark" and
     record(l).get("takes") == "dark or light" and record(l).get("applies") == "now" and
     record(l).get("kind") == "choice", "settings <name>: one, with what it takes"),
    ("settings display.text-size", lambda l: record(l).get("applies") == "at the next start",
     "a setting for the next start says so"),
    ("settings display", lambda l: [r["name"] for r in table(l)] ==
     ["display.theme", "display.accent", "display.text-size"], "settings <category>"),
    ("settings keyboard.*", lambda l: [r["name"] for r in table(l)] ==
     ["keyboard.repeat-delay", "keyboard.repeat-rate", "keyboard.layout"], "settings <pattern>"),
    ("settings | where name ~ display*", lambda l: len(table(l)) == 3,
     "settings | where name ~ display*"),
    ("settings | count", said(str(SETTINGS_N)), "settings | count"),
    ("settings nope", said("settings: no setting is called 'nope' ('settings' lists them)"),
     "an unknown name"),
    ("settings set display.theme light", lambda l: table(l) == [
        {"name": "display.theme", "value": "light", "was": "dark"}], "set a choice"),
    ("settings set display.theme blue", said("display.theme takes dark or light, not 'blue'"),
     "a choice it does not take: what it takes"),
    ("settings set keyboard.repeat-delay 5000",
     said("keyboard.repeat-delay takes 150 to 2000 ms, not '5000'"), "a number out of range"),
    ("settings set keyboard.repeat-delay 300ms", lambda l: values(l).get(
        "keyboard.repeat-delay") == "300 ms", "a number, with its unit"),
    ("settings set desktop.demo off", lambda l: values(l).get("desktop.demo") == "off",
     "a switch"),
    ("settings set display.accent #ff9f0a", lambda l: values(l).get("display.accent") ==
     "orange", "a colour by #rrggbb, named when it is a swatch"),
    ("theme accent green", lambda l: record(l).get("accent") == "green",
     "theme accent: the desktop's theme"),
    ("settings display.accent", lambda l: record(l).get("value") == "green",
     "theme accent green: kept as display.accent"),
    ("settings set desktop.wallpaper dusk", lambda l: values(l).get("desktop.wallpaper") ==
     "dusk", "desktop.wallpaper: one of the theme's wallpapers"),
    ("theme light", lambda l: record(l).get("look") == "light", "theme light"),
    ("settings display.theme", lambda l: record(l).get("value") == "light",
     "theme light: kept as display.theme"),
    ("settings reset desktop.wallpaper", lambda l: values(l).get("desktop.wallpaper") ==
     "aurora", "the theme's own wallpaper, by default"),
    ("settings set time.zone -05:00", lambda l: values(l).get("time.zone") == "UTC-05:00",
     "a zone"),
    ("settings set network.name my-box", lambda l: values(l).get("network.name") == "my-box",
     "a word"),
    ("settings set network.name my_box!", said("network.name takes"), "a word it does not take"),
    ("settings set nope 1", said("no setting is called 'nope'"), "set: an unknown name"),
    ("settings reset desktop.demo", lambda l: values(l).get("desktop.demo") == "on",
     "reset: back to the default"),
    ("help settings", lambda l: [r["use"].split()[1] if len(r["use"].split()) > 1 and
                                 not r["use"].split()[1].startswith(("[", "<")) else ""
                                 for r in table(l)] == ["", "set", "reset"],
     "help settings: its actions"),
]

# after the window: what its clicks changed, as the shell lists them
AFTER_APP = {"display.accent": "blue", "keyboard.repeat-delay": "1100 ms",
             "pointer.natural-scrolling": "on", "time.zone": "UTC-04:30",
             "network.name": "my-box-2", "display.theme": "dark"}
# what the second boot reads
KEPT = dict(AFTER_APP, **{"display.theme": "light", "display.text-size": "large"})


def steps(items, start=0):
    script = []
    for i, (typed, _, _) in enumerate(items, start):
        script += [f"type {typed}{NL}", f"type echo mark''{i}{NL}", f"until mark{i}"]
    return script


def first_script():
    n = len(FIRST)
    s = ["until settings:", "wait 0.5", f"type echo mark''-1{NL}", "until mark-1"]
    s += steps(FIRST)
    s += ["wait 0.5", f"shot {(OUT / 'light.png').as_posix()}",
          # the window, then the keys back to shell 1, and the window moved
          f"type run settings &{NL}", "until in the background", "wait 4",
          f"abs {at(*SHELL1)} left", "wait 0.5",
          f"type win{NL}", f"type echo mark''{n}{NL}", f"until mark{n}",
          f"type win move 5 {WX} {WY}{NL}", "wait 1",
          f"shot {(OUT / 'app-light.png').as_posix()}",
          # the shell changes it: the window follows
          f"type settings set display.theme dark{NL}", "wait 1.5",
          f"shot {(OUT / 'app-dark.png').as_posix()}",
          # clicks in the window
          f"abs {cat(0)} left", "wait 0.5",
          f"abs {app(862 + 42, 280)} left", "wait 0.7",          # accent: blue
          f"abs {cat(2)} left", "wait 0.5",
          f"abs {app(950, 160)} left", "wait 0.7",               # repeat delay: 1100 ms
          f"abs {cat(3)} left", "wait 0.5",
          f"abs {app(1190, 280)} left", "wait 0.7",              # natural scrolling: on
          f"abs {cat(4)} left", "wait 0.5",
          f"abs {app(1200, 160)} left", "wait 0.7",              # time zone: +30 min
          f"abs {cat(5)} left", "wait 0.5",
          f"abs {app(1000, 160)} left", "wait 0.5",              # the name, typed into
          f"type -2{NL}", "wait 0.7",
          f"shot {(OUT / 'app.png').as_posix()}",
          f"abs {at(*SHELL1)} left", "wait 0.5",
          f"type echo mark''{n + 1}{NL}", f"until mark{n + 1}",
          f"type settings{NL}", f"type echo mark''{n + 2}{NL}", f"until mark{n + 2}",
          f"type settings set display.text-size large{NL}",
          f"type settings set display.theme light{NL}", "wait 2",
          f"type poweroff{NL}", "ended"]
    return s


SECOND = [
    ("settings", lambda l: all(values(l).get(k) == v for k, v in KEPT.items()),
     "the second boot: what was changed, kept"),
    ("settings set keyboard.layout dvorak", lambda l: values(l).get("keyboard.layout") ==
     "dvorak", "keyboard.layout dvorak"),
]


def second_script():
    s = ["until settings:", "wait 0.5", f"type echo mark''-1{NL}", "until mark-1"]
    s += steps(SECOND)
    n = len(SECOND)
    s += ["press jdpps\\n", "wait 2",                            # as Dvorak: hello
          f"type settings reset keyboard.layout{NL}",
          f"type settings set power.button nothing{NL}", "wait 1",
          "system_powerdown", "until power button: pressed", "wait 0.5",
          f"type settings reset all{NL}", f"type echo mark''{n}{NL}", f"until mark{n}",
          "wait 2", "system_powerdown", "ended"]
    return s


def outputs(log):
    """{n: the lines step n printed}, between the marks."""
    out, lines, at_ = {}, [], None
    for line in log.splitlines():
        m = re.fullmatch(r"mark(-?\d+)", line)
        if m:
            if at_ is not None:
                out[int(m.group(1))] = lines
            at_, lines = int(m.group(1)), []
        elif at_ is not None:
            lines.append(line)
    return out


def check(items, got, start=0):
    for i, (typed, test, what) in enumerate(items, start):
        lines = got.get(i)
        try:
            ok = lines is not None and bool(test(lines))
        except (KeyError, IndexError, ValueError):
            ok = False
        if not result(ok, what):
            print(f"      {typed!r} printed: {lines!r}")


def pixel(name, x, y):
    from PIL import Image
    try:
        return Image.open(OUT / name).convert("RGB").getpixel((x, y))
    except OSError:
        return None


def bright(p):
    """A pixel's brightness, 0..255 (the menu bar is glass: the wallpaper
    shows through it)."""
    return -1 if p is None else (p[0] * 299 + p[1] * 587 + p[2] * 114) // 1000


def kept(img_path):
    """SETTINGS.TXT on a stick image -> its 'name = value' lines, and the
    FAT's problems."""
    img = bytearray(img_path.read_bytes())
    _, first, last, _ = fat32.read_gpt(img)[0]
    fs = fat32.Fat32(img, first, last - first + 1).mount()
    files, problems = fat32.check(fs)
    text = (files.get("/SETTINGS.TXT") or b"").decode("latin-1")
    lines = {}
    for l in text.splitlines():
        if l.strip() and not l.startswith("#") and "=" in l:
            k, v = l.split("=", 1)
            lines[k.strip()] = v.strip()
    return lines, problems, "/SETTINGS.TXT" in files


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    stick = OUT / "stick.img"
    subprocess.run([sys.executable, str(ROOT / "tools" / "mkstick.py"), str(stick)],
                   cwd=ROOT, check=True, capture_output=True)
    args = ["--smp", "2", "--stick", stick.relative_to(ROOT).as_posix(), "--extra", TABLET]

    log, err = boot_all(OUT, {"first": (first_script(), args, 90, 1)})["first"]
    got = outputs(log)
    print("-- the shell")
    check(FIRST, got)
    result(bright(pixel("light.png", *BAR_SPOT)) > 200,
           f"display.theme light: the bar is light, at once ({pixel('light.png', *BAR_SPOT)})")
    print("-- the window")
    n = len(FIRST)
    wins = got.get(n) or []
    result(any(re.search(r"desk: 5 'Settings' at", l) for l in wins),
           "run settings: a window, 'Settings'")
    sx, sy = WX + BORDER + SIDE_SPOT[0], WY + BORDER + TITLE + SIDE_SPOT[1]
    result(pixel("app-light.png", sx, sy) == LIGHT_SIDE,
           f"it has the look: light ({pixel('app-light.png', sx, sy)})")
    result(pixel("app-dark.png", sx, sy) == DARK_SIDE,
           f"'settings set display.theme dark' in the shell: the window follows "
           f"({pixel('app-dark.png', sx, sy)})")
    result(bright(pixel("app-dark.png", *BAR_SPOT)) < 80,
           f"and so does the bar ({pixel('app-dark.png', *BAR_SPOT)})")
    after = values(got.get(n + 2) or [])
    for k, v in AFTER_APP.items():
        if k != "display.theme":
            result(after.get(k) == v, f"a click in the window: {k} {after.get(k)!r}")
    result("AXIOM PANIC" not in log, "no panic")
    result("QEMU ended by itself" in err, "powered off")

    print("-- the stick between the boots")
    shutil.copy(stick, OUT / "stick-first.img")
    lines, problems, there = kept(stick)
    result(not problems, "the FAT is whole" + (f": {problems}" if problems else ""))
    result(there and lines.get("display.theme") == "light" and
           lines.get("keyboard.repeat-delay") == "1100 ms" and
           lines.get("network.name") == "my-box-2" and "desktop.demo" not in lines,
           f"SETTINGS.TXT: what is not a default, and only that ({lines})")

    log, err = boot_all(OUT, {"second": (second_script(), args, 90, 1)})["second"]
    got = outputs(log)
    print("-- the second boot")
    check(SECOND, got)
    result(re.search(r"settings: \d+ read at boot", log) is not None,
           "read at boot, before anything was drawn")
    result("font 20x40" in log, "display.text-size large: the larger text from the start")
    result("Hello from ring 3!" in log, "Dvorak: the keys for 'jdpps' typed 'hello'")
    result("power button: pressed" in log, "power.button nothing: the button only said so")
    result("power button: powering off" in log and "QEMU ended by itself" in err,
           "power.button off (its default, after reset all): the button turned it off")
    result("AXIOM PANIC" not in log, "no panic")
    lines, problems, there = kept(stick)
    result(not problems, "the FAT is whole" + (f": {problems}" if problems else ""))
    result(there and not lines, f"settings reset all: SETTINGS.TXT holds none ({lines})")
    print(f"{'all passed' if not FAILS else f'{FAILS} FAILED'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
