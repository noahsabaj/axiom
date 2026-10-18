#!/usr/bin/env python3
"""compose on the host: src/user/compose/*.inc assembled inside shim.asm as
a win64 object and linked into a DLL, driven with ctypes. The same code runs
in Axiom, so what it computes, saves and draws here is what COMPOSE.AXE does.

    from host import Compose
    c = Compose()
    g = c.grid()
    c.set(g, 0, 0, "=1+2"); c.show(g, 0, 0) -> "3"

The DLL goes to build/test/compose/.
"""
import ctypes
import os
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
HERE = pathlib.Path(__file__).resolve().parent
OUT = ROOT / "build" / "test" / "compose"
GCC = (r"C:\Users\noahs\AppData\Local\Microsoft\WinGet\Packages"
       r"\BrechtSanders.WinLibs.POSIX.UCRT_Microsoft.Winget.Source_8wekyb3d8bbwe"
       r"\mingw64\bin\gcc.exe")
MEMORY = 256 << 20


def build(cc=None):
    """The DLL, made again if any of its sources is newer."""
    cc = cc or os.environ.get("CC") or (GCC if pathlib.Path(GCC).exists() else "gcc")
    OUT.mkdir(parents=True, exist_ok=True)
    dll = OUT / "compose.dll"
    sources = [HERE / "shim.asm", *(ROOT / "src" / "user" / "compose").glob("*.inc"),
               *(ROOT / "src" / "user" / "web").glob("*.inc"), ROOT / "src" / "user" / "kit.inc",
               ROOT / "src" / "user" / "gen" / "docfont.pak", ROOT / "src" / "kernel" / "defs.inc",
               *(ROOT / "src" / "kernel" / "gen").glob("*font.*")]
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


class Compose:
    def __init__(self, cc=None):
        d = self.d = ctypes.CDLL(str(build(cc)))
        for name, res, args in (
                ("t_init", None, [ctypes.c_void_p, ctypes.c_int64]),
                ("t_grid_new", ctypes.c_uint64, []),
                ("t_cell_set", ctypes.c_int64, [ctypes.c_uint64, ctypes.c_int64, ctypes.c_int64,
                                                ctypes.c_char_p, ctypes.c_int64]),
                ("t_cell_show", ctypes.c_uint64, [ctypes.c_uint64, ctypes.c_int64,
                                                  ctypes.c_int64, ctypes.c_void_p]),
                ("t_num", ctypes.c_int64, [ctypes.c_char_p, ctypes.c_int64, ctypes.c_void_p])):
            f = getattr(d, name)
            f.restype = res
            f.argtypes = args
        self.mem = ctypes.create_string_buffer(MEMORY)
        d.t_init(ctypes.addressof(self.mem), MEMORY)
        self.buf = ctypes.create_string_buffer(64)

    def grid(self):
        return self.d.t_grid_new()

    def set(self, grid, row, col, text):
        """Types text into a cell -> how many cells were recalculated."""
        b = text.encode()
        return self.d.t_cell_set(grid, row, col, b, len(b))

    def show(self, grid, row, col):
        r = self.d.t_cell_show(grid, row, col, ctypes.addressof(self.buf))
        return self.buf.raw[:r & 0xFFFFFFFF].decode("utf-8", "replace")

    def num(self, text):
        b = text.encode()
        n = self.d.t_num(b, len(b), ctypes.addressof(self.buf))
        return None if n < 0 else self.buf.raw[:n].decode()


WIN_W, WIN_H = 1040, 600          # compose.asm's window, points: pixels here, at 1x
S4 = 4                            # the desktop's scale, quarters of a pixel a point
TH_DARK, TH_LIGHT = 0, 1
LOOK_BYTES = 4 << 20


def theme_colors():
    """theme.asm's colours for each TH_*, and its blue accent: what the
    kernel puts in the look."""
    text = (ROOT / "src" / "kernel" / "theme.asm").read_text()
    out = {}
    for mode, label in ((TH_DARK, "th_dark_c:"), (TH_LIGHT, "th_light_c:")):
        body = text[text.index(label) + len(label):]
        vals = []
        for line in body.splitlines()[1:]:
            line = line.split(";")[0].strip()
            if not line.startswith("dd "):
                break
            vals += [int(v, 0) for v in line[3:].split(",")]
        out[mode] = b"".join(v.to_bytes(4, "little") for v in vals)
    body = text[text.index("accent_colors:"):].splitlines()[1]
    blue = [int(v, 0) for v in body.split(";")[0].strip()[3:].split(",")]
    return out, {TH_DARK: blue[0], TH_LIGHT: blue[1]}
WE_KEY, WE_PRESS, WE_RELEASE, WE_MOVE, WE_WHEEL, WE_CLOSE = 1, 2, 3, 4, 5, 6
KEYS = {"up": 0x80, "down": 0x81, "left": 0x82, "right": 0x83, "home": 0x84,
        "end": 0x85, "pgup": 0x86, "pgdn": 0x87, "del": 0x89, "btab": 0x8A,
        "enter": 10, "tab": 9, "bs": 8, "esc": 27,
        **{f"f{i}": 0x8F + i for i in range(1, 13)},
        **{f"ctrl-{c}": i + 1 for i, c in enumerate("abcdefghijklmnopqrstuvwxyz")}}
SAVE_MAX = 1 << 20

LOGF = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_int64)
SAVEF = ctypes.CFUNCTYPE(ctypes.c_int64, ctypes.c_char_p, ctypes.c_int64)
LOADF = ctypes.CFUNCTYPE(ctypes.c_int64, ctypes.c_char_p)
PRESF = ctypes.CFUNCTYPE(ctypes.c_int64, ctypes.c_int64)


class App:
    """The whole program: events in, pixels out, a store in a dict."""

    def __init__(self, cc=None, store=None, dark=False, s4=S4):
        d = self.d = ctypes.CDLL(str(build(cc)))
        for name, res, args in (
                ("t_hooks", None, [ctypes.c_void_p] * 4),
                ("t_app", None, [ctypes.c_void_p, ctypes.c_int64, ctypes.c_void_p]),
                ("t_look", None, [ctypes.c_void_p, ctypes.c_int64, ctypes.c_char_p,
                                  ctypes.c_int64, ctypes.c_int64]),
                ("t_size", None, [ctypes.c_void_p, ctypes.c_int64, ctypes.c_int64]),
                ("t_open", None, [ctypes.c_char_p]),
                ("t_event", ctypes.c_int64, [ctypes.c_int64] * 5),
                ("t_paint", None, []),
                ("t_theme", ctypes.c_int64, [ctypes.c_int64]),
                ("t_pres", None, [ctypes.c_void_p, ctypes.c_int64, ctypes.c_int64])):
            f = getattr(d, name)
            f.restype = res
            f.argtypes = args
        self.log = []
        self.store = store if store is not None else {}
        self.presenting = False
        self._cbs = (LOGF(self._log), SAVEF(self._save), LOADF(self._load), PRESF(self._present))
        d.t_hooks(*[ctypes.cast(c, ctypes.c_void_p) for c in self._cbs])
        nbytes = ctypes.c_uint64.in_dll(d, "t_app_bytes").value + (1 << 16)
        self.mem = ctypes.create_string_buffer(nbytes)
        self.colors, self.accents = theme_colors()
        self.look = ctypes.create_string_buffer(LOOK_BYTES)
        assert ctypes.c_uint64.in_dll(d, "t_look_bytes").value <= LOOK_BYTES
        self.s4 = s4
        self.dark = dark
        self._look()
        self.save_buf = ctypes.create_string_buffer(SAVE_MAX)
        d.t_app(ctypes.addressof(self.mem), nbytes, ctypes.addressof(self.save_buf))
        self.w, self.h = WIN_W * s4 // 4, WIN_H * s4 // 4
        self.px = ctypes.create_string_buffer(self.w * self.h * 4)
        d.t_size(ctypes.addressof(self.px), self.w, self.h)
        self.d.t_theme(1 if dark else 0)            # as compose.asm starts

    def _look(self):
        mode = TH_DARK if self.dark else TH_LIGHT
        self.d.t_look(ctypes.addressof(self.look), mode, self.colors[mode], self.accents[mode],
                      self.s4)

    def _log(self, p, n):
        self.log.append(ctypes.string_at(p, n).decode("utf-8", "replace"))

    def _save(self, name, n):                    # (the capability's prefix, as in Axiom)
        self.store["compose/" + name.decode()] = self.save_buf.raw[:n]
        return 0

    def _load(self, name):
        b = self.store.get("compose/" + name.decode())
        if b is None:
            return -1
        ctypes.memmove(self.save_buf, b, len(b))
        return len(b)

    def _present(self, on):
        self.presenting = bool(on)
        return 1

    def open(self, name):
        self.d.t_open(name.encode())

    def event(self, kind, code=0, x=0, y=0, pres=0):
        return self.d.t_event(kind, code, x, y, pres)

    def system_theme(self, dark):
        """The desktop's theme changed: the look written again, then WE_LOOK,
        as compose.asm takes it."""
        self.dark = dark
        self._look()
        return self.d.t_theme(1 if dark else 0)

    def key(self, k):
        return self.event(WE_KEY, KEYS[k] if isinstance(k, str) else k)

    def type(self, text):
        for ch in text:
            if ch == "\n":
                self.key("enter")
            elif ch == "\t":
                self.key("tab")
            else:
                for b in ch.encode("latin-1"):
                    self.event(WE_KEY, b)

    def keys(self, *names):
        for k in names:
            self.key(k)

    def click(self, x, y, button=1):
        self.event(WE_PRESS, button, x, y)
        return self.event(WE_RELEASE, button, x, y)

    def drag(self, x0, y0, x1, y1):
        self.event(WE_PRESS, 1, x0, y0)
        self.event(WE_MOVE, 1, x1, y1)
        self.event(WE_RELEASE, 1, x1, y1)

    def dump(self):
        """The document as F12 logs it: lines after 'compose: '."""
        n = len(self.log)
        self.key("f12")
        return self.log[n:]

    def image(self):
        from PIL import Image
        self.d.t_paint()
        return Image.frombuffer("RGBX", (self.w, self.h), self.px.raw, "raw", "BGRX", 0,
                                1).convert("RGB")

    def presenter(self, w=1600, h=900):
        from PIL import Image
        buf = ctypes.create_string_buffer(w * h * 4)
        self.d.t_pres(ctypes.addressof(buf), w, h)
        return Image.frombuffer("RGBX", (w, h), buf.raw, "raw", "BGRX", 0, 1).convert("RGB")
