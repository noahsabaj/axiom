#!/usr/bin/env python3
"""browse in QEMU: pages from a server here on the host, in its window.

    python tools/test/browse/run.py

First, on the host (render.py: the same html.inc, layout.inc and draw.inc,
in a DLL): links resolved against a page's URL, and the test pages laid
out, which says where their links are and what browse's window should
show. Then one boot, from a USB stick, with a USB tablet and an RTL8139 on
QEMU's user network (the host is 10.0.2.2), serving tools/test/browse/site
and a few answers of its own over plain HTTP:
  - 'run browse http://10.0.2.2:<port>/': the log line (status, bytes,
    elements, links), the window's title (from <title>, its whitespace
    collapsed) and its page drawn as on the host, pixel for pixel;
  - a click on a link: the second page loaded and drawn; Backspace: back;
  - a link to /redirect: the redirect followed to the second page;
    /chain: two of them; /loop: stopped after 8, an error page;
  - a link to "#notes": scrolled to its anchor, nothing fetched; the
    wheel and space scroll, drawn as on the host at those places;
  - ctrl+L and an address typed, Enter: text/plain shown as pre;
    Windows-1252 by the Content-Type, and by <meta charset>; a 404 page;
    a port where nothing listens: an error page, and its log line;
  - about:start: the start page; the close button: browse ends.
Outputs go to build/test/browse/.
"""
import http.server
import pathlib
import re
import subprocess
import sys
import threading

ROOT = pathlib.Path(__file__).resolve().parents[3]
HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "tools" / "test"))
sys.path.insert(0, str(HERE))
from qemu import boot_all  # noqa: E402
import render  # noqa: E402

OUT = ROOT / "build" / "test" / "browse"
SITE = HERE / "site"
FAILS = 0
NL = "\\n"
SCR_W, SCR_H = 2560, 1600                       # QEMU's screen, as Axiom sets it
BAR = 60                                        # the desktop's bar
TITLE = 45                                      # a title bar
BORDER = 1
BTN = 45                                        # a title bar button
PLUS = (105 + 240) // 2                         # '+ shell' on the bar
TABLET = "-device qemu-xhci,id=ux -device usb-tablet,bus=ux.0"
BX, BY = 1100, 80                               # browse's frame, once moved
WIN_W, WIN_H = 1400, 1000
TB_H, SB_H = 56, 32                             # its toolbar, its status line
VIEW_W, VIEW_H = WIN_W - 14, WIN_H - TB_H - SB_H
VX, VY = BX + BORDER, BY + BORDER + TITLE + TB_H   # its page, on the screen
SHELL2 = (300, 1300)                            # a point in shell 2, once moved
BLANK = (VX + 1300, VY + 700)                   # nothing there on the first page
LATIN = (b"<html><head><title>Latin-1</title></head><body><h1>Caf\xe9 cr\xe8me</h1>"
         b"<p>\x93Quoted\x94 \x96 \xa3 5, \xbd off, na\xefve.</p></body></html>")
META = (b"<html><head><meta charset=\"windows-1252\"><title>By meta</title></head>"
        b"<body><p>Na\xefve r\xe9sum\xe9 \x85 \x80 9</p></body></html>")
MISSING = b"<html><head><title>Not found</title></head><body><h1>404</h1><p>Nothing here.</p>"


def result(ok, text):
    global FAILS
    FAILS += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + text)
    return ok


def at(x, y):
    """A point on the screen, as the tablet's 0..32767."""
    return f"{(x * 32768 + SCR_W // 2) // SCR_W} {(y * 32768 + SCR_H // 2) // SCR_H}"


# -- the server ---------------------------------------------------------------

hits = {}


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def answer(self, code, body, kind="text/html", extra=()):
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path
        hits[path] = hits.get(path, 0) + 1
        if path == "/":
            self.answer(200, (SITE / "index.html").read_bytes(), "text/html; charset=utf-8")
        elif path == "/page2.html":
            self.answer(200, (SITE / "page2.html").read_bytes())
        elif path == "/plain.txt":
            self.answer(200, (SITE / "plain.txt").read_bytes(), "text/plain")
        elif path == "/latin1.html":
            self.answer(200, LATIN, "text/html; charset=ISO-8859-1")
        elif path == "/meta.html":
            self.answer(200, META, "text/html")
        elif path == "/redirect":
            self.answer(302, b"moved", extra=[("Location", "/page2.html")])
        elif path == "/chain":
            self.answer(301, b"", extra=[("Location", f"http://10.0.2.2:{PORT}/redirect")])
        elif path == "/loop":
            self.answer(302, b"", extra=[("Location", "loop")])
        else:
            self.answer(404, MISSING)


def serve():
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv.server_address[1]


PORT = serve()
U = f"http://10.0.2.2:{PORT}"


# -- the host's view of the pages --------------------------------------------

def link_at(pages, text):
    """Where on the screen to click a link, on the page as rendered last."""
    for kind, font, flags, x, y, w, colour, t, link in pages.items():
        if link and t.startswith(text):
            return VX + x + 12, VY + y - 7
    return None


def host_checks(pages):
    base = "http://10.0.2.2:8000/dir/page.html?q=1#f"
    for href, want in (("page2.html", "http://10.0.2.2:8000/dir/page2.html"),
                       ("/abs", "http://10.0.2.2:8000/abs"),
                       ("../up.html", "http://10.0.2.2:8000/up.html"),
                       ("./x/../y", "http://10.0.2.2:8000/dir/y"),
                       ("?q=2", "http://10.0.2.2:8000/dir/page.html?q=2"),
                       ("#frag", "http://10.0.2.2:8000/dir/page.html?q=1#frag"),
                       ("", "http://10.0.2.2:8000/dir/page.html?q=1"),
                       ("//other.org/p", "http://other.org/p"),
                       ("HTTPS://Example.COM:443", "https://example.com/"),
                       ("http://u:p@h.com:81/a", "http://h.com:81/a"),
                       ("a b.html", "http://10.0.2.2:8000/dir/a%20b.html"),
                       ("../../../z", "http://10.0.2.2:8000/z"),
                       ("s/./a/../b?x=../y#k", "http://10.0.2.2:8000/dir/s/b?x=../y#k"),
                       ("mailto:a@b.c", None), ("javascript:void(0)", None)):
        got = pages.resolve(href, base)
        result(got == want, f"host: {href!r} -> {got}")

    _, c = pages.render(b"<p>a<table><tr><td>one<td>two<tr><td>three</table>"
                        b"<p>x &copy=1 &amp &ampx &#x41;&#66;&#xD800;")
    items = pages.items()
    cells = {t: (x, y) for _, _, _, x, y, _, _, t, _ in items}
    result(cells.get("one", (0, 0))[0] == cells.get("three", (1, 0))[0]
           and cells.get("one", (0, 0))[1] == cells.get("two", (0, 1))[1]
           and cells.get("two", (0, 0))[0] > cells.get("one", (0, 0))[0],
           f"host: a table's cells in rows and columns {cells}")
    result("x &copy=1 & &ampx AB�" in cells, "host: references, and what is not one: " +
           repr([t for t in cells if t.startswith("x")]))
    _, c = pages.render(b"<ul><li>a<li>b<ol><li>c<li>d</ol></ul>")
    marks = [t for _, _, _, x, y, _, _, t, _ in pages.items()]
    result(marks == ["•", "a", "•", "b", "1.", "c", "2.", "d"],
           f"host: list markers {marks}")


# -- the boot -----------------------------------------------------------------

def win(mark):
    return [f"type echo desk: -- {mark}" + NL, "wait 0.3", "type win" + NL, "wait 0.6"]


def click(point):
    return f"abs {at(*point)} left"


def address(url):
    """ctrl+L, the URL typed, Enter (into browse, which has the keys)."""
    return ["type \\x0c", "wait 0.3", "type " + url + NL]


def script(links):
    to2, redirect, notes = links
    return [
        "until log: kept in", "until dhcp: address", "wait 0.5",
        "type run browse " + U + "/" + NL, f"until browse: {U}/: 200", "wait 1",
        # a shell to work from, browse moved to where its page is known
        click((PLUS, BAR // 2)), "until desk: shell 2 opens", "wait 0.5",
        "type win size 6 1000 400" + NL, "wait 0.3",
        "type win move 6 0 1150" + NL, "wait 0.3",
        f"type win move 5 {BX} {BY}" + NL, "wait 0.5", *win("loaded"),
        click(BLANK), "wait 0.5",                # the keys to browse
        "shot build/test/browse/index.png",
        click(to2), f"until browse: {U}/page2.html: 200", "wait 0.8",
        "shot build/test/browse/page2.png",
        "type \\x08", f"until browse: {U}/: 200", "wait 0.8",
        click(redirect), f"until browse: {U}/page2.html: 200", "wait 0.8",
        "type \\x08", f"until browse: {U}/: 200", "wait 0.8",
        click(notes), "wait 1",
        "shot build/test/browse/notes.png",
        f"wheel {at(*BLANK)} 2", "wait 0.8",
        "shot build/test/browse/wheel.png",
        "type \\x20", "wait 0.8",
        "shot build/test/browse/space.png",
        *address(U + "/plain.txt"), f"until browse: {U}/plain.txt: 200", "wait 0.8",
        "shot build/test/browse/plain.png",
        *address(U + "/latin1.html"), f"until browse: {U}/latin1.html: 200", "wait 0.8",
        "shot build/test/browse/latin1.png",
        *address(U + "/meta.html"), f"until browse: {U}/meta.html: 200", "wait 0.8",
        "shot build/test/browse/meta.png",
        *address(U + "/missing"), f"until browse: {U}/missing: 404", "wait 0.5",
        *address(U + "/chain"), f"until browse: {U}/page2.html: 200", "wait 0.5",
        *address(U + "/loop"), "until more than 8 times", "wait 0.5",
        "shot build/test/browse/loop.png",
        *address("http://10.0.2.2:1/"), "until browse: http://10.0.2.2:1/: ", "wait 1",
        "shot build/test/browse/refused.png",
        *address("about:start"), "wait 1.5",
        "shot build/test/browse/start.png",
        click(SHELL2), "wait 0.5", *win("end"),
        click((BX + BORDER + WIN_W - BTN // 2, BY + BORDER + TITLE // 2)),
        "until run: BROWSE exited", "wait 0.5",
        "type poweroff" + NL, "ended",
    ]


WIN = re.compile(r"^desk: (\d+) '([^'\n]*)' at (-?\d+),(-?\d+), (\d+)x(\d+), (\w+)", re.M)


def listing(log, mark):
    m = re.search(rf"^desk: -- {re.escape(mark)}$", log, re.M)
    if not m:
        return {}
    n = re.compile(r"^desk: -- ", re.M).search(log, m.end())
    return {int(w.group(1)): {"title": w.group(2), "x": int(w.group(3)), "y": int(w.group(4)),
                              "w": int(w.group(5)), "h": int(w.group(6))}
            for w in WIN.finditer(log, m.end(), n.start() if n else len(log))}


def page_shot(name):
    """The page's part of a screenshot."""
    from PIL import Image
    try:
        img = Image.open(OUT / name).convert("RGB")
    except OSError:
        return None
    return img.crop((VX, VY, VX + VIEW_W, VY + VIEW_H))


def same(name, want, what):
    """A screenshot's page against the host's drawing of it: all but a few
    pixels (the pointer) the same."""
    from PIL import ImageChops
    got = page_shot(name)
    if got is None:
        return result(False, f"{what}: no screenshot {name}")
    diff = ImageChops.difference(got, want).convert("L").point(lambda v: 255 if v > 8 else 0)
    bad = diff.histogram()[255]
    if bad > 1500:
        want.save(OUT / ("want-" + name))
        diff.save(OUT / ("diff-" + name))
    return result(bad <= 1500, f"{what}: drawn as on the host ({bad} pixels differ)")


def check(log, err, pages, views):
    result("AXIOM PANIC" not in log, "no panic")
    m = re.search(rf"^browse: {re.escape(U)}/: 200, (\d+) bytes, (\d+) elements, (\d+) links$",
                  log, re.M)
    size = len((SITE / "index.html").read_bytes())
    result(m is not None and int(m.group(1)) == size and int(m.group(2)) == views["index"][1]
           ["elements"] and int(m.group(3)) == views["index"][1]["links"],
           "the log line: " + (m.group(0) if m else "none") +
           f" (want {size} bytes, {views['index'][1]['elements']} elements, "
           f"{views['index'][1]['links']} links)")
    w = listing(log, "loaded").get(5, {})
    result(w.get("title") == "Axiom test page · browse", f"its window's title: {w.get('title')!r}")
    result((w.get("x"), w.get("y"), w.get("w"), w.get("h")) == (BX, BY, WIN_W, WIN_H),
           f"its window: {w.get('w')}x{w.get('h')} at {w.get('x')},{w.get('y')}")
    same("index.png", views["index"][0], "the first page")
    same("page2.png", views["page2"][0], "a link clicked: the second page")
    result(hits.get("/page2.html", 0) >= 3, f"the second page fetched {hits.get('/page2.html', 0)}"
           " times (by the link, the redirect, the chain)")
    result(re.search(rf"^browse: {re.escape(U)}/redirect: 302, to /page2.html$", log, re.M)
           is not None and hits.get("/redirect") == 2, "/redirect: followed "
           f"({hits.get('/redirect')} requests: the link, the chain)")
    result(re.search(rf"^browse: {re.escape(U)}/chain: 301, to {re.escape(U)}/redirect$", log,
                     re.M) is not None, "/chain: two redirects followed")
    result(hits.get("/loop") == 9 and "browse: " + U + "/loop: It redirected more than 8 times."
           in log, f"/loop: given up after 8 redirects ({hits.get('/loop')} requests)")
    result(hits.get("/", 0) == 3, f"the first page fetched {hits.get('/', 0)} times (and not for"
           " #notes)")
    same("notes.png", views["notes"][0], f"#notes: scrolled to {views['notes'][2]}")
    same("wheel.png", views["wheel"][0], f"the wheel: up to {views['wheel'][2]}")
    same("space.png", views["space"][0], f"space: down to {views['space'][2]}")
    same("plain.png", views["plain"][0], "text/plain, as pre")
    same("latin1.png", views["latin1"][0], "ISO-8859-1 by the Content-Type")
    same("meta.png", views["meta"][0], "windows-1252 by <meta charset>")
    result(re.search(rf"^browse: {re.escape(U)}/missing: 404, {len(MISSING)} bytes", log, re.M)
           is not None, "a 404 page shown")
    m = re.search(r"^browse: http://10\.0\.2\.2:1/: ([^\d].*)$", log, re.M)
    result(m is not None, "nothing listening: " + (m.group(1) if m else "no line"))
    shot = page_shot("refused.png")
    dark = shot and shot.crop((0, 0, 800, 80)).convert("L").point(
        lambda v: 255 if v < 67 else 0).histogram()[255]
    result(bool(dark), f"and an error page ({dark} dark pixels where its heading is)")
    e = listing(log, "end").get(5, {})
    result(e.get("title") == "Start · browse", f"about:start: titled {e.get('title')!r}")
    same("start.png", views["start"][0], "the start page")
    result(re.search(r"^browse: closed$", log, re.M) is not None
           and "run: BROWSE exited with 0" in log, "its close button: it ended, 0")
    result("QEMU ended by itself" in err, "powered off")


def main():
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    OUT.mkdir(parents=True, exist_ok=True)
    pages = render.Pages()
    host_checks(pages)
    views = {}

    def view(name, html, scroll=0, latin1=False):
        img, counts = pages.render(html, scroll=scroll, latin1=latin1)
        views[name] = (img, counts, scroll)
        return counts

    index = (SITE / "index.html").read_bytes()
    counts = view("index", index)
    links = (link_at(pages, "The second page"), link_at(pages, "a redirect"),
             link_at(pages, "the notes"))
    anchors = pages.anchors()
    most = max(0, counts["height"] - VIEW_H)
    notes = min(anchors.get("notes", 0), most)
    view("notes", index, notes)
    view("wheel", index, max(0, notes - 2 * 72))
    view("space", index, min(most, max(0, notes - 2 * 72) + VIEW_H - 48))
    view("page2", (SITE / "page2.html").read_bytes())
    text = (SITE / "plain.txt").read_bytes()
    view("plain", b"<pre>" + text.replace(b"&", b"&amp;").replace(b"<", b"&lt;"))
    view("latin1", LATIN, latin1=True)
    view("meta", META, latin1=True)
    start = re.search(rb"start_page:\n(.*?)start_page_end:",
                      (ROOT / "src" / "user" / "browse.asm").read_bytes(), re.S).group(1)
    view("start", start_page_bytes(start))
    result(None not in links and anchors.get("notes") is not None,
           f"host: the first page's links at {links}, #notes at {anchors.get('notes')}")

    stick = OUT / "stick.img"
    subprocess.run([sys.executable, str(ROOT / "tools" / "mkstick.py"), str(stick)], cwd=ROOT,
                   check=True, capture_output=True)
    logs = boot_all(OUT, {"browse": (script(links), [
        "--smp", "4", "--nic", "rtl8139", "--extra", TABLET,
        "--stick", stick.relative_to(ROOT).as_posix()], 300, 1)})     # it mostly waits
    check(*logs["browse"], pages, views)
    print(f"{'all passed' if not FAILS else f'{FAILS} FAILED'}")
    return 1 if FAILS else 0


def start_page_bytes(src):
    """browse.asm's start page, from its db lines: the bytes they make."""
    out = bytearray()
    for line in src.decode().splitlines():
        line = line.strip()
        if not line.startswith("db "):
            continue
        for part in re.findall(r"'[^']*'|\"[^\"]*\"|0x[0-9A-Fa-f]+|\d+", line[3:]):
            if part[0] in "'\"":
                out += part[1:-1].encode()
            else:
                out.append(int(part, 0))
    return bytes(out)


if __name__ == "__main__":
    sys.exit(main())
