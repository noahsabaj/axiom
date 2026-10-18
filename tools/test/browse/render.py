#!/usr/bin/env python3
"""browse's pages drawn on the host: web/html.inc, layout.inc and draw.inc,
assembled inside shim.asm as a win64 object and linked into a DLL, driven
with ctypes. The same code draws them in Axiom, so what it draws here is
what browse's window shows.

    python tools/test/browse/render.py page.html [-o out.png] [--width 1386]
                                       [--height 912] [--scroll 0] [--latin1]

As a module: Pages().render(html) -> (image, counts); Pages().resolve(href,
base) -> the URL, or None. The DLL goes to build/test/browse/.
"""
import argparse
import ctypes
import os
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
HERE = pathlib.Path(__file__).resolve().parent
OUT = ROOT / "build" / "test" / "browse"
GCC = (r"C:\Users\noahs\AppData\Local\Microsoft\WinGet\Packages"
       r"\BrechtSanders.WinLibs.POSIX.UCRT_Microsoft.Winget.Source_8wekyb3d8bbwe"
       r"\mingw64\bin\gcc.exe")
VIEW_W, VIEW_H = 1400 - 14, 1000 - 56 - 32      # browse's page, in its window
ARENA = 64 << 20
DL = 16 << 20


def build(cc=None):
    """The DLL, made again if any of its sources is newer."""
    cc = cc or os.environ.get("CC") or (GCC if pathlib.Path(GCC).exists() else "gcc")
    OUT.mkdir(parents=True, exist_ok=True)
    dll = OUT / "pages.dll"
    sources = [HERE / "shim.asm", *(ROOT / "src" / "user" / "web").glob("*.inc"),
               ROOT / "src" / "user" / "gen" / "webfont.bin"]
    if dll.exists() and all(s.stat().st_mtime < dll.stat().st_mtime for s in sources):
        return dll
    nasm = shutil.which("nasm")
    if not nasm:
        sys.exit("nasm not found on PATH")
    obj = OUT / "shim.obj"
    for cmd in ([nasm, "-f", "win64", "-I", str(ROOT / "src" / "kernel") + os.sep,
                 "-I", str(ROOT / "src" / "user") + os.sep, "-o", str(obj), str(HERE / "shim.asm")],
                [cc, "-shared", "-static", "-Wl,--image-base,0x10000000",
                 "-Wl,--disable-dynamicbase", "-Wl,--disable-high-entropy-va",
                 "-Wl,--export-all-symbols", "-o", str(dll), str(obj)]):
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode:
            sys.exit((r.stdout + r.stderr).strip() + f"\n{cmd[0]} failed")
    return dll


class Pages:
    def __init__(self, cc=None):
        d = self.d = ctypes.CDLL(str(build(cc)))
        d.t_render.restype = ctypes.c_int64
        d.t_render.argtypes = [ctypes.c_char_p, ctypes.c_int64, ctypes.c_void_p, ctypes.c_int64,
                               ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int64, ctypes.c_int64,
                               ctypes.c_int64, ctypes.c_int64]
        d.t_resolve.restype = ctypes.c_int64
        d.t_resolve.argtypes = [ctypes.c_char_p, ctypes.c_int64, ctypes.c_char_p, ctypes.c_void_p]
        self.arena = ctypes.create_string_buffer(ARENA)
        self.dl = ctypes.create_string_buffer(DL)

    def _int(self, name, kind=ctypes.c_uint32):
        return kind.in_dll(self.d, name).value

    def render(self, html, width=VIEW_W, height=VIEW_H, scroll=0, latin1=False):
        """html (bytes) -> (a PIL image of it, {height, elements, links, anchors,
        title, items})"""
        from PIL import Image
        px = ctypes.create_string_buffer(width * height * 4)
        h = self.d.t_render(html, len(html), ctypes.addressof(self.arena), ARENA,
                            ctypes.addressof(self.dl), ctypes.addressof(px), width, height, scroll,
                            1 if latin1 else 0)
        img = Image.frombuffer("RGBX", (width, height), px.raw, "raw", "BGRX", 0, 1).convert("RGB")
        title = ctypes.string_at(ctypes.addressof(ctypes.c_char.in_dll(self.d, "doc_title")))
        items = (self._int("dl_top", ctypes.c_uint64) - self._int("dl_base", ctypes.c_uint64)) // 40
        return img, {"height": h, "elements": self._int("html_elements", ctypes.c_uint64),
                     "links": self._int("lk_count"), "anchors": self._int("an_count"),
                     "title": title.decode("utf-8", "replace"), "items": items}

    def items(self):
        """The display list of the last render: (kind, font, flags, x, y, w, colour, text,
        link)."""
        base = self._int("dl_base", ctypes.c_uint64)
        top = self._int("dl_top", ctypes.c_uint64)
        out = []
        for a in range(base, top, 40):
            raw = ctypes.string_at(a, 40)
            kind, font, flags = raw[0], raw[1], int.from_bytes(raw[2:4], "little")
            n, x, y, w, colour = (int.from_bytes(raw[i:i + 4], "little", signed=True)
                                  for i in (4, 8, 12, 16, 20))
            ptr = int.from_bytes(raw[24:32], "little")
            link = int.from_bytes(raw[32:36], "little")
            text = ctypes.string_at(ptr, n).decode("utf-8", "replace") if kind == 1 else ""
            out.append((kind, font, flags, x, y, w, colour, text, link))
        return out

    def anchors(self):
        """The anchors of the last render: {name: y}."""
        base = ctypes.addressof(ctypes.c_char.in_dll(self.d, "an_table"))
        out = {}
        for i in range(self._int("an_count")):
            raw = ctypes.string_at(base + 16 * i, 16)
            name = ctypes.string_at(int.from_bytes(raw[:8], "little"),
                                    int.from_bytes(raw[8:12], "little"))
            out.setdefault(name.decode("utf-8", "replace"), int.from_bytes(raw[12:16], "little"))
        return out

    def resolve(self, href, base):
        out = ctypes.create_string_buffer(4096)
        h = href.encode()
        if self.d.t_resolve(h, len(h), base.encode(), ctypes.addressof(out)):
            return None
        return out.value.decode()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("page")
    ap.add_argument("-o", "--out", default=str(OUT / "render.png"))
    ap.add_argument("--width", type=int, default=VIEW_W)
    ap.add_argument("--height", type=int, default=VIEW_H)
    ap.add_argument("--scroll", type=int, default=0)
    ap.add_argument("--latin1", action="store_true")
    ap.add_argument("--items", action="store_true", help="print the display list")
    opts = ap.parse_args()
    pages = Pages()
    img, counts = pages.render(pathlib.Path(opts.page).read_bytes(), opts.width, opts.height,
                               opts.scroll, opts.latin1)
    img.save(opts.out)
    print(counts, "->", opts.out)
    if opts.items:
        for it in pages.items():
            print(it)


if __name__ == "__main__":
    main()
