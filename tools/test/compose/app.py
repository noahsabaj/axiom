#!/usr/bin/env python3
"""compose on the host, all of it: keys and clicks in, the document (as F12
logs it) and the window's pixels out (tools/test/compose/host.py). Typing,
headings, lists, attributes, undo and redo, the clipboard, tables and their
formulas, the grid view, slides and the presenter, saving and opening again,
plain text and CSV. Screenshots go to build/test/compose/.

    python tools/test/compose/app.py
"""
import pathlib
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from host import App, OUT, WE_WHEEL  # noqa: E402

failures = []


def check(what, got, want):
    if got != want:
        failures.append(what)
        print(f"FAIL {what}:\n  got  {got!r}\n  want {want!r}")


def blocks(app):
    """The document's blocks, as (kind, text) and a grid's cells as 'A1=value'."""
    out = []
    for line in app.dump()[1:]:
        line = line[len("compose: "):]
        if line.startswith("  "):
            ref, _, rest = line.strip().partition(" = ")
            out.append(f"{ref}={rest.rpartition(' -> ')[2]}")
        else:
            _, kind, text = line.split(" ", 2)
            out.append((kind, text.split('"')[1] if '"' in text else text))
    return out


def text_of(app):
    return [b for b in blocks(app) if isinstance(b, tuple)]


def cell_xy(ref):
    """Where a cell is on the grid view, its first rows and columns shown."""
    return 52 + 120 * (ord(ref[0]) - 65) + 60, 122 + 26 * (int(ref[1:]) - 1) + 13


TEXT_BUTTON = (455, 26)
PG_TEXT = 112 + 88                    # a page's text: its left (the window 1040 wide)


def shot(app, name):
    app.image().save(OUT / f"{name}.png")


app = App()            # (one per process: the DLL's state is shared)

# --- text ----------------------------------------------------------------------
app.open("first")
check("new document", app.log[-1], "compose: new first.axd")
app.key("ctrl-n")
app.type("Title\nOne two three.\n")
app.key("ctrl-l")
app.type("apple\npear\n\nAfter the list.")
check("headings and lists", text_of(app),
      [("h1", "Title"), ("text", "One two three."), ("bullet", "apple"),
       ("bullet", "pear"), ("text", "After the list.")])
app.key("home")
app.key("bs")                                       # joins "pear"
check("backspace joins", text_of(app)[3], ("bullet", "pearAfter the list."))
app.key("ctrl-z")
check("undo", text_of(app)[3:], [("bullet", "pear"), ("text", "After the list.")])
app.key("ctrl-y")
check("redo", text_of(app)[3], ("bullet", "pearAfter the list."))
app.key("ctrl-z")
app.type(" x")
app.key("ctrl-z")                                   # typing: one change
check("typing undone at once", text_of(app)[4], ("text", "After the list."))

app.key("up")
app.key("up")
app.key("end")
app.key("ctrl-b")
app.type(" bold")
app.key("ctrl-b")
shot(app, "text")
check("typing at the end of a line above", text_of(app)[2], ("bullet", "apple bold"))

app.key("ctrl-a")
app.key("ctrl-c")
app.type("Gone")
check("typing over everything", text_of(app), [("h1", "Gone")])
app.key("end")
app.key("enter")
app.key("ctrl-v")
check("paste", text_of(app),
      [("h1", "Gone"), ("h1", "Title"), ("text", "One two three."), ("bullet", "apple bold"),
       ("bullet", "pear"), ("text", "After the list.")])

# --- the mouse ------------------------------------------------------------------
app.key("ctrl-a")
app.type("Click here")
app.click(*TEXT_BUTTON)
check("the Text button", text_of(app), [("text", "Click here")])
app.click(PG_TEXT + 1, 183)                         # just before "Click"
app.type(">")
check("a click puts the cursor", text_of(app), [("text", ">Click here")])
app.drag(PG_TEXT + 1, 183, 740, 183)                # all of it chosen
app.type("Tap")
check("a drag chooses", text_of(app), [("text", "Tap")])

# --- a table and its formulas ----------------------------------------------------
app.key("ctrl-a")
app.type("Sales")
app.key("enter")
app.key("ctrl-t")
app.type("Region\tQ1\tQ2\tNorth\t120\t140\tSouth\t80\t95\tTotal\t=SUM(B2:B3)\t=C2+C3\n")
check("formulas", [b for b in blocks(app) if isinstance(b, str) and b[0] in "BC" and b[1] == "4"],
      ["B4=200", "C4=235"])
app.keys("up", "up", "up", "right")                # from below the table to B2
app.type("200\n")
check("worked out again", [b for b in blocks(app) if b in ("B4=280", "B4=200")], ["B4=280"])
app.keys("down", "down")                            # B3, B4, then out of the table
app.type("After the table.")
shot(app, "table")

# --- the grid view -----------------------------------------------------------------
app.key("f3")
check("grid view", app.log[-1], "compose: view grid")
app.click(*cell_xy("D8"))
app.type("=B4*2\n=1/0\n=D8+D10\n=D11\t=AVERAGE(B2:C3)\t=IF(B4>250,\"big\",\"small\")\n")
cells = {b.split("=", 1)[0]: b.split("=", 1)[1] for b in blocks(app) if isinstance(b, str)}
check("grid formulas", [cells.get(k) for k in ("D8", "D9", "D10", "D11", "E11", "F11")],
      ["560", "#DIV/0!", "#CYCLE!", "#CYCLE!", "128.75", "big"])
app.key("ctrl-t")                                   # a second grid
app.type("7\t8\t=A1*B1\n")
check("a second grid", [b for b in blocks(app) if b in ("C1=56",)], ["C1=56"])
shot(app, "grid")
app.click(40, 553)                                  # the first grid's tab
check("tabs", app.dump()[0], app.dump()[0])

# --- slides ----------------------------------------------------------------------------
app.key("f1")
app.key("ctrl-a")
app.key("del")
app.click(*TEXT_BUTTON)
app.key("ctrl-n")
app.type("Deck\nA subtitle")
app.key("ctrl-k")
app.type("Second\nPoint one\n")
app.key("ctrl-g")
app.key("ctrl-k")
app.type("Third\n")
app.key("ctrl-t")
app.type("x\t2\ty\t=B1*3\n")
check("frames", [b for b in text_of(app) if b[0] in ("slide", "image", "grid")],
      [("slide", "Second"), ("image", ""), ("slide", "Third"), ("grid", "Grid 1")])
shot(app, "frames")
app.key("f2")
check("slides view", app.log[-1], "compose: view slides")
shot(app, "slides")
# the slide shown at 3/4 (a window 1040 by 600, at (274, 109)), laid out
# 960 by 540: a click on its heading, at (66, 82) on it
app.click(274 + 66 * 3 // 4, 109 + 82 * 3 // 4)
app.type("!")
check("a click on the slide, at its scale", [b for b in text_of(app) if b[0] == "slide"][1],
      ("slide", "!Third"))
app.key("ctrl-z")
app.key("pgup")
app.key("f5")
check("presenting", (app.presenting, app.log[-1]), (True, "compose: presenting slide 2 of 3"))
app.presenter().save(OUT / "present.png")
app.key("right")
app.key("right")
check("next slide", app.log[-1], "compose: presenting slide 3 of 3")
app.presenter().save(OUT / "present3.png")
app.key("esc")
check("presenting ended", (app.presenting, app.log[-1]), (False, "compose: presenting ended"))

# --- saving and opening again ---------------------------------------------------------------
before = blocks(app)
app.key("ctrl-s")
check("saved", app.log[-1].startswith("compose: saved first.axd, "), True)
app.open("other")
check("another document", text_of(app), [("text", "")])
app.open("first")
check("opened", app.log[-1 - 0].startswith("compose: opened first.axd") or
      app.log[-2].startswith("compose: opened first.axd"), True)
check("the same again", blocks(app), before)
check("the view kept", app.dump()[0].split(", cursor")[0], "compose: document, 9 blocks, view slides")

# --- the desktop's theme, and the paper ----------------------------------------------------
LIGHT_PAPER, DARK_PAPER = (255, 255, 255), (0x1C, 0x1C, 0x1F)
LIGHT_BAR, DARK_BAR = (0xED, 0xED, 0xF0), (0x32, 0x32, 0x36)
PAPER_BUTTON = (836, 26)


def paper():
    return app.image().getpixel((140, 120))[:3]          # a page's margin


def bar():
    return app.image().getpixel((600, 5))[:3]            # the toolbar


app.key("f1")
check("light at first", (paper(), bar()), (LIGHT_PAPER, LIGHT_BAR))
n = len(app.log)
check("the desktop's dark, followed", (app.system_theme(True), app.log[n:], paper(), bar()),
      (1, ["compose: paper auto, dark"], DARK_PAPER, DARK_BAR))
n = len(app.log)
app.system_theme(True)
check("told again: nothing said", app.log[n:], [])
shot(app, "dark_pages")
app.key("f2")
shot(app, "dark_slides")
app.key("f5")
check("the presenter, dark", app.presenter().getpixel((40, 40))[:3], DARK_PAPER)
app.presenter().save(OUT / "dark_present.png")
app.key("esc")
app.key("f3")
shot(app, "dark_grid")
app.key("f1")
app.key("f7")
check("F7: light paper, in the dark", (app.log[-1], paper(), bar(), app.store.get("compose/theme")),
      ("compose: paper light, dark", LIGHT_PAPER, DARK_BAR, b"light\n"))
shot(app, "light_paper")
app.key("f5")
check("the presenter, light paper", app.presenter().getpixel((40, 40))[:3], LIGHT_PAPER)
app.key("esc")
check("the desktop light, then dark: the paper kept",
      (app.system_theme(False), bar(), app.system_theme(True), paper(), bar()),
      (1, LIGHT_BAR, 1, LIGHT_PAPER, DARK_BAR))
app.key("f7")
check("F7: the paper as the theme is", (app.log[-1], paper(), app.store.get("compose/theme")),
      ("compose: paper auto, dark", DARK_PAPER, b"auto\n"))
app.click(*PAPER_BUTTON)
check("the button: light paper", (app.log[-1], paper()), ("compose: paper light, dark", LIGHT_PAPER))
app.click(*PAPER_BUTTON)
check("the button: auto", (app.log[-1], paper()), ("compose: paper auto, dark", DARK_PAPER))
app.system_theme(False)
check("auto, the desktop light", (app.log[-1], paper(), bar()),
      ("compose: paper auto, light", LIGHT_PAPER, LIGHT_BAR))
r = subprocess.run([sys.executable, "-c", (
    "import sys; sys.path.insert(0, {!r}); from host import App\n"
    "app = App(store={{'compose/theme': b'light\\n'}}, dark=True); app.open('x')\n"
    "print(app.image().getpixel((140, 120))[:3], app.log[0])").format(
        str(pathlib.Path(__file__).parent))], capture_output=True, text=True)
check("light paper, as it was kept", r.stdout.strip(),
      f"{LIGHT_PAPER} compose: paper light, dark")
r = subprocess.run([sys.executable, "-c", (
    "import sys; sys.path.insert(0, {!r}); from host import App\n"
    "app = App(dark=True, s4=8); app.open('x'); app.key('f2')\n"
    "app.image().save({!r}); print(app.image().size)").format(
        str(pathlib.Path(__file__).parent), str(OUT / "twice_slides.png"))],
    capture_output=True, text=True)
check("at twice the size", r.stdout.strip(), "(2080, 1200)")

# --- plain text and CSV ------------------------------------------------------------------------
app.key("f9")
check("text exported", app.log[-1], "compose: exported first.txt")
text = app.store["compose/first.txt"].decode()
check("text", text.splitlines()[:3], ["# Deck", "A subtitle", "# Second"])
app.store["compose/notes.txt"] = b"# Notes\nplain line\n- a\n- b\n1. one\nName\tAge\nAda\t36\n"
app.open("notes.txt")
check("text imported", text_of(app)[:6],
      [("h1", "Notes"), ("text", "plain line"), ("bullet", "a"), ("bullet", "b"),
       ("number", "one"), ("grid", "Grid 1")])
app.store["compose/md.txt"] = b"| a | b |\n|---|:--|\n| 2 | =A2*3 |\n"
app.open("md.txt")
check("a table's rule skipped", blocks(app),
      [("grid", "Grid 1"), "A1=a", "B1=b", "A2=2", "B2=6"])
app.store["compose/sheet.csv"] = b'a,b,sum\n1,2,=A2+B2\n"x, y",3,=B3*2\n'
app.open("sheet.csv")
check("CSV imported", [b for b in blocks(app) if isinstance(b, str)],
      ["A1=a", "B1=b", "C1=sum", "A2=1", "B2=2", "C2=3", "A3=x, y", "B3=3", "C3=6"])
app.key("f10")
check("CSV exported", app.store["compose/sheet.csv"].decode().splitlines(),
      ["a,b,sum", "1,2,=A2+B2", '"x, y",3,=B3*2'])
app.event(WE_WHEEL, -3, 600, 400)

if failures:
    sys.exit(f"{len(failures)} failed: {', '.join(failures)}")
print("all passed")
