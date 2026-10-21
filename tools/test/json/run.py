#!/usr/bin/env python3
"""The kernel's JSON on the host: src/kernel/json.asm, in Rust now
(src/rust/src/json.rs), held against the assembly it was
(tools/test/json/reference.asm).

    python tools/test/json/run.py [--seed N] [--cases N] [--cc PATH]

First cargo's own tests of the Rust. Then the Rust, built for the host as a
DLL, called through json.asm's wrappers (a DLL of NASM's, -f win64, with
gcc), and the assembly, in a DLL of its own, on the same cases: a few
written out and --cases of each routine made at random (JSON values, then
some cut short or with bytes changed; keys, room). Each pair must give the
same answer (RAX, where it is one), the same flags (CF; ZF for json_is),
RSI left in the same place, the same bytes out and none written past them;
and keep every register but RAX (and RSI, for the readers).
"""
import argparse
import ctypes
import os
import pathlib
import random
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
HERE = pathlib.Path(__file__).resolve().parent
OUT = ROOT / "build" / "test" / "json"
RUST = ROOT / "src" / "rust"
GCC = str(pathlib.Path(os.environ.get("LOCALAPPDATA", "")) / "Microsoft" / "WinGet" / "Packages" /
          "BrechtSanders.WinLibs.POSIX.UCRT_Microsoft.Winget.Source_8wekyb3d8bbwe" /
          "mingw64" / "bin" / "gcc.exe")      # WinLibs' gcc, as winget puts it; else --cc or CC
READERS = ["json_ws", "json_skip", "json_get", "json_is", "json_str", "json_num"]
RSI_BIT = 1 << 2

failures = []
passed = 0


def result(ok, text):
    global passed
    if ok:
        passed += 1
    else:
        failures.append(text)
        if len(failures) <= 40:
            print("FAIL " + text)
    return ok


class Shim:
    def __init__(self, path):
        self.dll = ctypes.CDLL(str(path))
        self.dll.kc.restype = None

    def addr(self, name):
        return ctypes.cast(getattr(self.dll, name), ctypes.c_void_p).value

    def call(self, name, rdi=0, rsi=0, rdx=0, rcx=0, r11=0):
        """-> RAX, RFLAGS, the mask of registers changed, RSI"""
        a = (ctypes.c_uint64 * 8)(*[x & (2 ** 64 - 1) for x in (rdi, rsi, rdx, rcx, 0, 0, 0, r11)])
        out = (ctypes.c_uint64 * 4)()
        self.dll.kc(ctypes.c_void_p(self.addr(name)), a, out)
        return tuple(out)


def read_once(k, name, text, at, arg, room):
    """name on text from at, in shim k -> what it did, comparable."""
    buf = ctypes.create_string_buffer(text, len(text) + 16)      # zeros after the end
    start = ctypes.addressof(buf)
    rdi = rcx = 0
    keep = []
    if name in ("json_get", "json_is"):
        key = ctypes.create_string_buffer(arg)
        keep.append(key)
        rdi = ctypes.addressof(key)
    out = None
    if name == "json_str":
        out = ctypes.create_string_buffer(b"\xee" * (room + 16), room + 16)
        rdi, rcx = ctypes.addressof(out), room
    rax, flags, mask, rsi = k.call(name, rdi=rdi, rsi=start + at, rcx=rcx, r11=start + len(text))
    cf, zf = flags & 1, flags >> 6 & 1
    seen = {"rsi": rsi - start, "regs": mask & ~RSI_BIT}
    if name in ("json_skip", "json_get", "json_str", "json_num"):
        seen["cf"] = cf
    if name == "json_is":
        seen["zf"] = zf
    if name == "json_num" or (name == "json_str" and not cf):
        seen["rax"] = rax
    if out is not None:
        seen["out"] = out.raw
    return seen


def read_case(ref, new, name, text, at=0, arg=b"", room=0):
    a = read_once(ref, name, text, at, arg, room)
    b = read_once(new, name, text, at, arg, room)
    detail = f"{name}({text[:60]!r}{'...' if len(text) > 60 else ''} at {at}" + \
             (f", {arg!r}" if name in ("json_get", "json_is") else "") + \
             (f", room {room}" if name == "json_str" else "") + ")"
    if a["regs"]:
        result(False, f"{detail}: the assembly changed registers ({a['regs']:#x})")
    return result(a == b, f"{detail}: assembly {short(a)}, Rust {short(b)}")


def escape_once(k, text, room):
    src = ctypes.create_string_buffer(text, len(text) + 1)
    out = ctypes.create_string_buffer(b"\xee" * (room + 16), room + 16)
    rax, flags, mask, rsi = k.call("json_escape", rdi=ctypes.addressof(out),
                                   rsi=ctypes.addressof(src), rdx=room, rcx=len(text))
    return {"rax": rax, "cf": flags & 1, "regs": mask, "out": out.raw}


def escape_case(ref, new, text, room):
    a, b = escape_once(ref, text, room), escape_once(new, text, room)
    return result(a == b, f"json_escape({text[:60]!r}, room {room}): assembly {short(a)}, "
                          f"Rust {short(b)}")


def short(seen):
    s = dict(seen)
    if "out" in s:
        s["out"] = s["out"].rstrip(b"\xee")[:48]
    return s


# -- cases -------------------------------------------------------------------

KEYS = [b"type", b"text", b"delta", b"a", b"b", b"usage", b"input_tokens", b"", b"t\\\"x",
        b"\xc3\xa9", b"stop_reason"]


def ws(rng):
    return rng.choice([b"", b"", b" ", b"\t", b"\n", b"\r\n  ", b"  \t"])


def string(rng):
    parts = [b'"']
    for _ in range(rng.choice([0, 1, 2, 3, 5, 8, 13])):
        r = rng.random()
        if r < 0.3:
            parts.append(bytes(rng.choice(b"abcxyz ABC012{}[]:,") for _ in range(rng.randint(1, 4))))
        elif r < 0.45:
            parts.append(b"\\" + bytes([rng.choice(b'"\\/ntrbfxu0')]))
        elif r < 0.7:
            cp = rng.choice([rng.randrange(0x20), rng.randrange(0x80, 0x800),
                             rng.randrange(0x800, 0x10000), rng.randrange(0xD800, 0xDC00),
                             rng.randrange(0xDC00, 0xE000), 0xFFFD, 0x41])
            h = f"{cp:04x}"
            if rng.random() < 0.3:
                h = h.upper()
            if rng.random() < 0.08:
                h = h[:rng.randrange(4)] + rng.choice("gG-\x10 ") + h[rng.randrange(4) + 1:]
            parts.append(b"\\u" + h.encode("latin-1"))
            if 0xD800 <= cp < 0xDC00 and rng.random() < 0.7:
                low = rng.choice([rng.randrange(0xDC00, 0xE000), rng.randrange(0xD800, 0xDC00), 0x41])
                parts.append(f"\\u{low:04x}".encode())
        elif r < 0.9:
            parts.append(chr(rng.choice([rng.randrange(0x80, 0x800), rng.randrange(0x800, 0xD800),
                                         rng.randrange(0x10000, 0x110000)])).encode())
        else:
            parts.append(bytes([rng.randrange(256)]))
    parts.append(b'"')
    return b"".join(parts)


def number(rng):
    digits = "".join(rng.choice("0123456789") for _ in range(rng.choice([1, 1, 2, 3, 6, 19, 21, 25])))
    s = rng.choice(["", "", "-"]) + digits
    if rng.random() < 0.2:
        s += "." + str(rng.randrange(1000))
    if rng.random() < 0.1:
        s += rng.choice(["e", "E"]) + rng.choice(["", "+", "-"]) + str(rng.randrange(30))
    return s.encode()


def value(rng, depth=0):
    r = rng.random()
    if depth < 4 and r < 0.25:
        members = [ws(rng) + b'"' + (rng.choice(KEYS) if rng.random() < 0.8 else string(rng)[1:-1])
                   + b'"' + ws(rng) + b":" + ws(rng) + value(rng, depth + 1) + ws(rng)
                   for _ in range(rng.choice([0, 1, 2, 3, 5]))]
        return b"{" + b",".join(members) + ws(rng) + b"}"
    if depth < 4 and r < 0.4:
        return b"[" + b",".join(ws(rng) + value(rng, depth + 1) + ws(rng)
                                for _ in range(rng.choice([0, 1, 2, 4]))) + b"]"
    if r < 0.7:
        return string(rng)
    if r < 0.9:
        return number(rng)
    return rng.choice([b"true", b"false", b"null", b"nul", b"tru"])


def mutate(rng, text):
    r = rng.random()
    if r < 0.2 and text:
        return text[:rng.randrange(len(text))]                  # cut short
    if r < 0.35 and text:
        b = bytearray(text)
        for _ in range(rng.randint(1, 3)):
            b[rng.randrange(len(b))] = rng.choice(b'"\\{}[]:, \tu0x\x00\xc3\xff')
        return bytes(b)
    return text


def some_text(rng):
    return mutate(rng, ws(rng) + value(rng) + ws(rng) + rng.choice([b"", b",", b"}", b" ]", b"x"]))


def written(rng, ref, new):
    """Cases picked by hand: edges of each routine."""
    S, R = ref, new
    for name in READERS:
        for text in [b"", b" ", b"\t\r\n x", b'"', b'"\\', b'"\\"', b'""', b"{", b"{}", b"[]",
                     b"]", b"}", b"0", b"x", b",", b'{"a":1}', b'{"a" : "b" , "b":[1,{"c":2}]}',
                     b'{"a":}', b'{"a",1}', b'{"a":1,}', b'{"a":1 "b":2}', b"18446744073709551617",
                     b'"\\ud83d\\ude00"', b'"\\ud83d"', b'"\\ud83d\\u"', b'"\\ude00\\ud83d"',
                     b'"\\u00e9\\u0041\\u20ac"', b'"\\u12"', b'"\\uABCD"', b'"\\u\x10\x11\x12\x13"']:
            for at in sorted({0, len(text) // 2, len(text)}):
                read_case(S, R, name, text, at, b"a", 3)
    for room in range(0, 14):
        for text in [b'"a\xc3\xa9b\xe2\x82\xacc\xf0\x9f\x98\x80d"', b'"a\\u00e9b\\u20acc\\ud83d\\ude00d"',
                     b'"\xc3"', b'"ab\xa9\xa9\xa9\xa9"', b'"\xf0\x9f\x98"', b'"x\\ud83dyz"']:
            read_case(S, R, "json_str", text, 0, b"", room)
    for text in [b"", b"a", b'"\\', b"\x00\x01\x1f\x7f\x80\xff", b"tab\there\nnew\rline\x08\x0c"]:
        for room in range(0, 3 * len(text) + 8):
            escape_case(S, R, text, room)


def randomly(rng, ref, new, cases):
    for name in READERS:
        for _ in range(cases):
            text = some_text(rng)
            at = 0 if rng.random() < 0.7 else rng.randrange(len(text) + 1)
            if name == "json_get":
                arg = rng.choice(KEYS)
            elif name == "json_is" and text.startswith(b'"') and rng.random() < 0.6:
                inner = text[1:text.find(b'"', 1)] if b'"' in text[1:] else text[1:]
                arg = inner[:rng.randrange(len(inner) + 1)] if rng.random() < 0.3 else inner
                arg = arg.replace(b"\x00", b"")
            else:
                arg = rng.choice(KEYS)
            room = rng.choice([0, 1, 2, 3, 5, 8, 16, 64, 256])
            read_case(ref, new, name, text, at, arg, room)
    alphabet = b'abc "\\/\n\t\r\x00\x01\x1f\x7f\x80\xc3\xa9\xff'
    for _ in range(cases):
        text = bytes(rng.choice(alphabet) for _ in range(rng.choice([0, 1, 2, 5, 9, 30])))
        escape_case(ref, new, text, rng.randrange(3 * len(text) + 8))


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
    ap.add_argument("--seed", type=int, default=8259)
    ap.add_argument("--cases", type=int, default=3000, help="random cases of each routine")
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

    kinc, here = str(ROOT / "src" / "kernel") + os.sep, str(HERE) + os.sep
    shims = {}
    for name, defs in (("reference", ["-DREFERENCE"]), ("rust", [])):
        obj, dll = OUT / f"{name}.obj", OUT / f"{name}.dll"
        run([nasm, "-f", "win64", *defs, "-I", kinc, "-I", here, "-o", obj, HERE / "shim.asm"],
            f"nasm -f win64 ({name})")
        run([cc, "-shared", "-o", dll, obj], f"gcc -shared ({name})")
        shims[name] = Shim(dll)
    ref, new = shims["reference"], shims["rust"]
    for name in READERS + ["json_escape"]:
        entry = ctypes.cast(getattr(rust, "rs_" + name), ctypes.c_void_p).value
        ctypes.c_uint64.in_dll(new.dll, f"rs_{name}_at").value = entry

    rng = random.Random(opts.seed)
    written(rng, ref, new)
    randomly(rng, ref, new, opts.cases)
    if failures:
        print(f"json: {len(failures)} failed, {passed} passed")
        sys.exit(1)
    print(f"json: all {passed} passed")


main()
