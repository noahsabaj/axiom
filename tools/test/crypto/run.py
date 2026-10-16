#!/usr/bin/env python3
"""Host tests for src/kernel/crypto.asm (AES-128, AES-CMAC, Bluetooth SMP).

    python tools/test/crypto/run.py [--seed N] [--cases N] [--cc PATH]

Assembles crypto.asm twice: once the way kernel.asm does (-f bin, same
sections and warning flags, just to prove it assembles there), once inside
shim.asm as a win64 object. Links that with driver.c, generates random
AES / AES-CMAC cases from an independent pure-Python AES (and the
`cryptography` package too, when it is installed), and runs the driver.
Outputs go to build/test/crypto/. Exit status 0 only if every test passed.
"""
import argparse
import os
import pathlib
import random
import re
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
HERE = pathlib.Path(__file__).resolve().parent
OUT = ROOT / "build" / "test" / "crypto"
GCC = (r"C:\Users\noahs\AppData\Local\Microsoft\WinGet\Packages"
       r"\BrechtSanders.WinLibs.POSIX.UCRT_Microsoft.Winget.Source_8wekyb3d8bbwe"
       r"\mingw64\bin\gcc.exe")

# ---- reference AES-128 and AES-CMAC, written from FIPS-197 / RFC 4493 ------


def _xtime(a):
    a <<= 1
    return (a ^ 0x11B) if a & 0x100 else a


def _gmul(a, b):
    r = 0
    while b:
        if b & 1:
            r ^= a
        a = _xtime(a)
        b >>= 1
    return r


def _sbox():
    inv = [0] * 256
    for a in range(1, 256):
        for b in range(1, 256):
            if _gmul(a, b) == 1:
                inv[a] = b
                break
    box = []
    for a in range(256):
        x = inv[a]
        s = x
        for _ in range(4):
            x = ((x << 1) | (x >> 7)) & 0xFF
            s ^= x
        box.append(s ^ 0x63)
    return box


SBOX = _sbox()


def aes128_encrypt(key, block):
    w = [list(key[i:i + 4]) for i in range(0, 16, 4)]
    rcon = 1
    for i in range(4, 44):
        t = list(w[i - 1])
        if i % 4 == 0:
            t = [SBOX[b] for b in t[1:] + t[:1]]
            t[0] ^= rcon
            rcon = _xtime(rcon)
        w.append([a ^ b for a, b in zip(w[i - 4], t)])
    rk = [sum(w[r * 4:r * 4 + 4], []) for r in range(11)]
    s = [b ^ k for b, k in zip(block, rk[0])]
    for r in range(1, 11):
        s = [SBOX[b] for b in s]
        # ShiftRows: byte (row, col) is s[row + 4 * col]; row r rotates left by r
        s = [s[i % 4 + 4 * ((i // 4 + i % 4) % 4)] for i in range(16)]
        if r != 10:
            m = []
            for c in range(4):
                a = s[4 * c:4 * c + 4]
                m += [_gmul(a[0], 2) ^ _gmul(a[1], 3) ^ a[2] ^ a[3],
                      a[0] ^ _gmul(a[1], 2) ^ _gmul(a[2], 3) ^ a[3],
                      a[0] ^ a[1] ^ _gmul(a[2], 2) ^ _gmul(a[3], 3),
                      _gmul(a[0], 3) ^ a[1] ^ a[2] ^ _gmul(a[3], 2)]
            s = m
        s = [b ^ k for b, k in zip(s, rk[r])]
    return bytes(s)


def _dbl(b):
    n = int.from_bytes(b, "big") << 1
    if n >> 128:
        n ^= (1 << 128) | 0x87
    return n.to_bytes(16, "big")


def aes_cmac(key, msg):
    k1 = _dbl(aes128_encrypt(key, bytes(16)))
    k2 = _dbl(k1)
    blocks = [msg[i:i + 16] for i in range(0, len(msg), 16)] or [b""]
    last = blocks[-1]
    if len(last) == 16:
        last = bytes(a ^ b for a, b in zip(last, k1))
    else:
        last = last + b"\x80" + bytes(15 - len(last))
        last = bytes(a ^ b for a, b in zip(last, k2))
    x = bytes(16)
    for blk in blocks[:-1] + [last]:
        x = aes128_encrypt(key, bytes(a ^ b for a, b in zip(x, blk)))
    return x


def self_check():
    """The reference must reproduce the published vectors before it is trusted."""
    h = bytes.fromhex
    assert aes128_encrypt(h("000102030405060708090a0b0c0d0e0f"),
                          h("00112233445566778899aabbccddeeff")) == \
        h("69c4e0d86a7b0430d8cdb78070b4c55a"), "reference AES fails FIPS-197 C.1"
    key = h("2b7e151628aed2a6abf7158809cf4f3c")
    msg = h("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51"
            "30c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710")
    for n, tag in ((0, "bb1d6929e95937287fa37d129b756746"),
                   (16, "070a16b46b4d4144f79bdd9dd04a287c"),
                   (40, "dfa66747de9ae63030ca32611497c827"),
                   (64, "51f0bebf7e3b9d92fc49741779363cfe")):
        assert aes_cmac(key, msg[:n]) == h(tag), f"reference CMAC fails RFC 4493, {n} bytes"


def library_cmac():
    """AES-CMAC from the `cryptography` package, or None if it isn't installed."""
    try:
        from cryptography.hazmat.primitives.ciphers import algorithms
        from cryptography.hazmat.primitives.cmac import CMAC
    except ImportError:
        return None

    def mac(key, msg):
        c = CMAC(algorithms.AES(key))
        c.update(msg)
        return c.finalize()
    return mac


def make_cases(path, seed, count):
    rng = random.Random(seed)
    lib = library_cmac()
    lengths = list(range(0, 97))                       # every short length
    lengths += [16 * k + d for k in range(7, 17) for d in (-1, 0, 1)]
    while len(lengths) < count:
        lengths.append(rng.randrange(0, 1001))
    lines = []
    for n in lengths:
        key = rng.randbytes(16)
        msg = rng.randbytes(n)
        tag = aes_cmac(key, msg)
        if lib and lib(key, msg) != tag:
            sys.exit(f"reference CMAC disagrees with cryptography: len {n}")
        lines.append(f"cmac {key.hex()} {msg.hex() or '-'} {tag.hex()}")
    for _ in range(100):
        key, pt = rng.randbytes(16), rng.randbytes(16)
        lines.append(f"aes {key.hex()} {pt.hex()} {aes128_encrypt(key, pt).hex()}")
    path.write_text("\n".join(lines) + "\n")
    return len(lengths), 100, lib is not None


# ---- build and run -----------------------------------------------------------

KERNEL_LIKE = """\
; generated by tools/test/crypto/run.py: crypto.asm in the kernel's layout
bits 64
default rel
org 0xFFFFFFFF80000000
section .text progbits align=16
section .rodata progbits align=64 follows=.text
section .data progbits align=64 follows=.rodata
section .bss nobits align=64
[map sections {map}]
section .text
%include "crypto.asm"
"""


def run(cmd, what):
    r = subprocess.run([str(c) for c in cmd], cwd=ROOT, capture_output=True, text=True)
    out = (r.stdout + r.stderr).strip()
    if out:
        print(out)
    if r.returncode:
        sys.exit(f"{what} failed ({r.returncode})")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=4493)
    ap.add_argument("--cases", type=int, default=400, help="random AES-CMAC cases")
    ap.add_argument("--cc", default=os.environ.get("CC", GCC))
    opts = ap.parse_args()
    sys.stdout.reconfigure(line_buffering=True)     # keep our lines ahead of the driver's

    nasm = shutil.which("nasm")
    if not nasm:
        sys.exit("nasm not found on PATH")
    cc = opts.cc if os.path.exists(opts.cc) else shutil.which(opts.cc)
    if not cc:
        sys.exit(f"compiler not found: {opts.cc}")
    OUT.mkdir(parents=True, exist_ok=True)
    kinc = str(ROOT / "src" / "kernel") + os.sep

    # 1. the kernel's own format and warning flags
    stub = OUT / "kernel_like.asm"
    mapfile = OUT / "kernel_like.map"
    stub.write_text(KERNEL_LIKE.format(map=mapfile.as_posix()))
    run([nasm, "-f", "bin", "-w-reloc-abs-qword", "-w-reloc-abs-dword", "-w-reloc-rel-dword",
         "-I", kinc, "-o", OUT / "kernel_like.bin", stub], "nasm -f bin (kernel layout)")
    # the map's section summary: Vstart Start Stop Length Class Name
    sizes = {name: int(length, 16) for length, name in re.findall(
        r"^[0-9A-F]+\s+[0-9A-F]+\s+[0-9A-F]+\s+([0-9A-F]+)\s+\w+\s+(\.\w+)\s*$",
        mapfile.read_text(), re.M)}
    print("kernel layout: crypto.asm assembles; " +
          ", ".join(f"{n} {sizes[n]} bytes" for n in (".text", ".rodata", ".data", ".bss")
                    if n in sizes))

    # 2. the host test program
    obj = OUT / "shim.obj"
    exe = OUT / "crypto_test.exe"
    run([nasm, "-f", "win64", "-I", kinc, "-o", obj, HERE / "shim.asm"], "nasm -f win64")
    run([cc, "-O2", "-Wall", "-Wextra", "-Wno-missing-field-initializers", "-static",
         "-o", exe, HERE / "driver.c", obj], "gcc")

    # 3. random cases from the reference implementation
    self_check()
    vec = OUT / "random_cases.txt"
    ncmac, naes, lib = make_cases(vec, opts.seed, opts.cases)
    print(f"random cases: {ncmac} AES-CMAC + {naes} AES, seed {opts.seed}, reference "
          f"pure-Python AES{' + cryptography' if lib else ' (cryptography not installed)'}")

    r = subprocess.run([str(exe), "--vectors", str(vec)], cwd=ROOT)
    if r.returncode:
        code = r.returncode & 0xFFFFFFFF
        if code >= 0xC0000000:
            print(f"crypto_test.exe crashed: exception 0x{code:08X}, in the test after "
                  "the last line above (0xC0000005: a fault, e.g. a read past a buffer)")
        sys.exit(1)


if __name__ == "__main__":
    main()
