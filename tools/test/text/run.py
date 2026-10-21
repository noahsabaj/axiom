#!/usr/bin/env python3
"""The kernel's text.asm on the host, in Rust now (src/rust/src/text.rs),
held against the assembly it was (tools/test/text/reference.asm).

    python tools/test/text/run.py [--seed N] [--cases N] [--cc PATH]

First cargo's own tests of the Rust. Then the Rust, built for the host as a
DLL, called through text.asm's wrappers (a DLL of NASM's, -f win64, with
gcc), and the assembly, in a DLL of its own, on the same cases: glyph_of on
every code point (and some past U+10FFFF; and the Rust with RAX's upper half
set, which the assembly's Latin-1 table read did not allow),
utf8_step on every one and two byte sequence, on three and four byte ones
from a set of bytes that covers each range, and on --cases bytes at
random, one after another. Each pair must give the same answer (EAX, where
there is one), the same CF from utf8_step, the same 8 bytes of state after
each byte, and keep every register but RAX.
"""
import argparse
import ctypes
import os
import pathlib
import random
import re
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
HERE = pathlib.Path(__file__).resolve().parent
OUT = ROOT / "build" / "test" / "text"
RUST = ROOT / "src" / "rust"
GCC = str(pathlib.Path(os.environ.get("LOCALAPPDATA", "")) / "Microsoft" / "WinGet" / "Packages" /
          "BrechtSanders.WinLibs.POSIX.UCRT_Microsoft.Winget.Source_8wekyb3d8bbwe" /
          "mingw64" / "bin" / "gcc.exe")      # WinLibs' gcc, as winget puts it; else --cc or CC
# bytes for the second to fourth of a sequence: each edge of the ranges
EDGES = [0x00, 0x41, 0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0, 0xC2, 0xE0, 0xF0, 0xF4, 0xFF]

failures = []
passed = 0


def result(ok, text):
    global passed
    if ok:
        passed += 1
        print("PASS " + text)
    else:
        failures.append(text)
        if len(failures) <= 40:
            print("FAIL " + text)
    return ok


class Shim:
    def __init__(self, path):
        self.dll = ctypes.CDLL(str(path))
        self.dll.kc.restype = None
        self.dll.kc.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
        self.a = (ctypes.c_uint64 * 9)()
        self.out = (ctypes.c_uint64 * 4)()
        self.state = (ctypes.c_uint64 * 1)()
        self.at = {name: ctypes.cast(getattr(self.dll, name), ctypes.c_void_p).value
                   for name in ("utf8_step", "glyph_of")}

    def call(self, name, rax=0, rdi=0):
        """-> RAX, RFLAGS, the mask of registers changed"""
        a = self.a
        a[0], a[8] = rdi, rax
        a[1], a[2], a[3] = 0x5151515151515151, 0x5252525252525252, 0x5353535353535353
        a[4], a[5], a[6], a[7] = 0x5454545454545454, 0x5555, 0x5656, 0x5757575757575757
        self.dll.kc(self.at[name], a, self.out)
        return self.out[0], self.out[1], self.out[2]

    def glyph(self, c):
        rax, _, mask = self.call("glyph_of", rax=c)
        return rax, mask

    def step(self, byte):
        """utf8_step on the shim's own state -> what it did, comparable."""
        rax, flags, mask = self.call("utf8_step", rax=byte, rdi=ctypes.addressof(self.state))
        cf = flags & 1
        return (cf, None if cf else rax, self.state[0], mask)


def glyphs(ref, new):
    every = list(range(0x110000))
    more = [0x110000, 0x1000000 | 0xA0, 0x10000A0, 0x80000041, 0xFFFFFFFF, 0xFFFFFFFE]
    bad = 0
    for c in every + more:
        a, b = ref.glyph(c), new.glyph(c)
        if a != b or a[1]:
            bad += 1
            result(False, f"glyph_of(U+{c:04X}): assembly {a[0]:#x} (registers {a[1]:#x}), "
                          f"Rust {b[0]:#x} (registers {b[1]:#x})")
    result(bad == 0, f"glyph_of on {len(every) + len(more)} code points: {bad} differ")
    rng = random.Random(1)
    bad = 0
    for _ in range(20000):
        c = rng.choice([rng.randrange(0x80), rng.randrange(0x80, 0x3000), rng.randrange(0x110000)])
        high = rng.getrandbits(32) << 32
        if new.glyph(c | high) != ref.glyph(c):  # (the assembly's table read used all of RAX)
            bad += 1
    result(bad == 0, f"glyph_of with RAX's upper half set, 20000 times: {bad} differ")


def sequence(ref, new, data):
    ref.state[0] = new.state[0] = 0
    for i, byte in enumerate(data):
        a, b = ref.step(byte), new.step(byte)
        if a != b or a[3]:
            return result(False, f"utf8_step on {bytes(data).hex(' ')}, byte {i}: assembly {a}, "
                                 f"Rust {b}")
    return True


def steps(ref, new, cases, rng):
    count = bad = 0
    seqs = [[a] for a in range(256)] + [[a, b] for a in range(256) for b in range(256)]
    seqs += [[a, b, c] for a in range(0xE0, 0x100) for b in EDGES for c in EDGES]
    seqs += [[a, b, c, d] for a in range(0xF0, 0x100) for b in EDGES for c in EDGES for d in EDGES]
    for data in seqs:
        count += 1
        bad += not sequence(ref, new, data)
    result(bad == 0, f"utf8_step on {count} sequences of 1 to 4 bytes: {bad} differ")
    # one long run: valid text, broken text, and noise, the state carried on
    data = bytearray()
    while len(data) < cases:
        r = rng.random()
        if r < 0.5:
            data += chr(rng.choice([rng.randrange(0x80), rng.randrange(0x80, 0x800),
                                    rng.randrange(0x800, 0xD800),
                                    rng.randrange(0x10000, 0x110000)])).encode()
        elif r < 0.8:
            s = chr(rng.randrange(0x80, 0x110000)).encode("utf-8", "surrogatepass")
            data += s[:rng.randrange(1, len(s))] if len(s) > 1 else s
        else:
            data.append(rng.randrange(256))
    for byte in (0x41 | (0x77 << 8), 0xE2 | (0xFFFF << 16)):    # AL only: the rest set
        result(ref.step(byte) == new.step(byte), f"utf8_step with RAX {byte:#x}")
    result(sequence(ref, new, data), f"utf8_step on {len(data)} bytes, one after another")


# -- building ----------------------------------------------------------------

def run(cmd, what, cwd=ROOT):
    r = subprocess.run([str(c) for c in cmd], cwd=cwd, capture_output=True, text=True)
    out = (r.stdout + r.stderr).strip()
    if r.returncode:
        print(out)
        sys.exit(f"{what} failed ({r.returncode})")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=3629)
    ap.add_argument("--cases", type=int, default=200_000, help="random bytes, one after another")
    ap.add_argument("--cc", default=os.environ.get("CC", GCC))
    opts = ap.parse_args()
    sys.stdout.reconfigure(line_buffering=True)
    nasm = shutil.which("nasm")
    if not nasm:
        sys.exit("nasm not found on PATH")
    cc = opts.cc if os.path.exists(opts.cc) else shutil.which(opts.cc) or shutil.which("gcc")
    if not cc:
        sys.exit(f"compiler not found: {opts.cc}")
    OUT.mkdir(parents=True, exist_ok=True)
    target = OUT / "rust"

    said = run(["cargo", "+nightly", "test", "--target-dir", target], "cargo test", cwd=RUST)
    tests = [line for line in said.splitlines() if line.startswith("test result:")]
    result(bool(tests) and all(" 0 failed" in t for t in tests), f"cargo test: {'; '.join(tests)}")
    run(["cargo", "+nightly", "rustc", "--release", "--lib", "--crate-type", "cdylib",
         "--target-dir", target], "cargo rustc (the Rust, for the host)", cwd=RUST)
    rust = ctypes.CDLL(str(target / "release" / "axiom_kernel.dll"))

    font = (ROOT / "src" / "kernel" / "gen" / "font.inc").read_text()
    (OUT / "glyphs.inc").write_bytes("".join(f"{m.group(0)}\n" for m in
                                             re.finditer(r"^G_\w+\s+equ\s+\d+", font, re.M)).encode())
    kinc, here, out = (str(p) + os.sep for p in (ROOT / "src" / "kernel", HERE, OUT))
    shims = {}
    for name, defs in (("reference", ["-DREFERENCE"]), ("rust", [])):
        obj, dll = OUT / f"{name}.obj", OUT / f"{name}.dll"
        run([nasm, "-f", "win64", *defs, "-I", kinc, "-I", here, "-I", out, "-o", obj,
             HERE / "shim.asm"], f"nasm -f win64 ({name})")
        run([cc, "-shared", "-o", dll, obj], f"gcc -shared ({name})")
        shims[name] = Shim(dll)
    ref, new = shims["reference"], shims["rust"]
    for name in ("utf8_step", "glyph_of"):
        entry = ctypes.cast(getattr(rust, "rs_" + name), ctypes.c_void_p).value
        ctypes.c_uint64.in_dll(new.dll, f"rs_{name}_at").value = entry

    glyphs(ref, new)
    steps(ref, new, opts.cases, random.Random(opts.seed))
    if failures:
        print(f"text: {len(failures)} failed, {passed} passed")
        sys.exit(1)
    print(f"text: all {passed} passed")


main()
