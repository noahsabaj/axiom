#!/usr/bin/env python3
"""Host tests for the WPA2 crypto: src/kernel/wpa.asm (SHA-1, HMAC-SHA1, the
802.11 PRF, PBKDF2, AES key unwrap, CCMP) over crypto.asm's AES-128.

    python tools/test/wpa/run.py [--seed N] [--cc PATH]

Assembles wpa.asm the way kernel.asm does (-f bin, just to prove it
assembles there), then inside shim.asm as a win64 object linked into a DLL,
and calls each entry point through ctypes: the published vectors (FIPS 180
SHA-1, RFC 2202 HMAC-SHA1, the 802.11 PSK vector, RFC 3394 4.1, the 802.11
CCMP vector), then random cases against independent references (hashlib and
hmac; a CCM written here from SP 800-38C and the 802.11 text over the pure-
Python AES of tools/test/crypto, checked against the vector first). Buffers
sit at odd addresses; every call must come back with each register but RAX
as it went in. Then the RTL8821CE station's handshakes, src/kernel/rtwwpa.asm
inside hs_shim.asm, against an access point played by handshake.py. Outputs
go to build/test/wpa/. Exit status 0 only if every test passed.
"""
import argparse
import ctypes
import hashlib
import hmac
import importlib.util
import os
import pathlib
import random
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
HERE = pathlib.Path(__file__).resolve().parent
OUT = ROOT / "build" / "test" / "wpa"
GCC = (r"C:\Users\noahs\AppData\Local\Microsoft\WinGet\Packages"
       r"\BrechtSanders.WinLibs.POSIX.UCRT_Microsoft.Winget.Source_8wekyb3d8bbwe"
       r"\mingw64\bin\gcc.exe")

_spec = importlib.util.spec_from_file_location("crypto_run", HERE.parent / "crypto" / "run.py")
_crypto = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_crypto)
_spec = importlib.util.spec_from_file_location("handshake", HERE / "handshake.py")
handshake = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(handshake)
aes = _crypto.aes128_encrypt

h = bytes.fromhex
failures = []
passed = 0


def result(ok, what):
    global passed
    if ok:
        passed += 1
    else:
        failures.append(what)
        print(f"FAIL {what}")


# ---- references --------------------------------------------------------------


def prf(key, label, data, n):
    out, i = b"", 0
    while len(out) < n:
        out += hmac.new(key, label + b"\0" + data + bytes([i]), hashlib.sha1).digest()
        i += 1
    return out[:n]


def aes_wrap(kek, data):
    n = len(data) // 8
    a, r = b"\xa6" * 8, [data[i * 8:i * 8 + 8] for i in range(n)]
    for j in range(6):
        for i in range(n):
            b = aes(kek, a + r[i])
            t = n * j + i + 1
            a = (int.from_bytes(b[:8], "big") ^ t).to_bytes(8, "big")
            r[i] = b[8:]
    return a + b"".join(r)


def ccm(key, nonce, aad, pt):
    """SP 800-38C with Tlen = 64, q = 2: (ciphertext, tag)."""
    b0 = bytes([0x40 | (3 << 3) | 1]) + nonce + len(pt).to_bytes(2, "big")
    a = len(aad).to_bytes(2, "big") + aad
    a += bytes(-len(a) % 16)
    blocks = b0 + a + pt + bytes(-len(pt) % 16)
    x = bytes(16)
    for i in range(0, len(blocks), 16):
        x = aes(key, bytes(p ^ q for p, q in zip(x, blocks[i:i + 16])))
    ctr = lambda i: aes(key, bytes([1]) + nonce + i.to_bytes(2, "big"))
    stream = b"".join(ctr(i) for i in range(1, len(pt) // 16 + 2))
    ct = bytes(p ^ s for p, s in zip(pt, stream))
    return ct, bytes(p ^ s for p, s in zip(x[:8], ctr(0)))


def ccmp_parts(hdr, pn):
    """The 802.11 CCMP nonce and additional data (802.11-2020 12.5.3.3.3-4)."""
    fc0, fc1 = hdr[0], hdr[1]
    kind = (fc0 >> 2) & 3
    qos = kind == 2 and fc0 & 0x80
    a4 = fc1 & 3 == 3
    aad = bytes([fc0 & 0x8F if kind == 2 else fc0,
                 (fc1 & ~0x38 & (0x7F if qos else 0xFF)) | 0x40])
    aad += hdr[4:22] + bytes([hdr[22] & 0x0F, 0])
    qc_at = 24
    if a4:
        aad += hdr[24:30]
        qc_at = 30
    prio = 0
    if qos:
        prio = hdr[qc_at] & 0x0F
        aad += bytes([prio, 0])
    if kind == 0:
        prio |= 0x10
    nonce = bytes([prio]) + hdr[10:16] + pn.to_bytes(6, "big")
    return nonce, aad


def ccmp_seal(tk, hdr, pn, keyid, body):
    nonce, aad = ccmp_parts(hdr, pn)
    ct, mic = ccm(tk, nonce, aad, body)
    p = pn.to_bytes(6, "little")
    return hdr + p[:2] + bytes([0, (keyid << 6) | 0x20]) + p[2:] + ct + mic


# ---- the DLL -----------------------------------------------------------------


class Kernel:
    def __init__(self, path):
        self.dll = ctypes.CDLL(str(path))
        self.kc = self.dll.kc
        self.kc.restype = None
        self.keep = []

    def addr(self, name):
        return ctypes.cast(getattr(self.dll, name), ctypes.c_void_p).value

    def fresh(self):
        """The buffers of the case before go."""
        self.keep.clear()

    def buf(self, data, room=0, odd=1):
        """A buffer holding data, at an odd address, with room after it."""
        b = ctypes.create_string_buffer(len(data) + room + 64)
        ctypes.memmove(ctypes.addressof(b) + odd, data, len(data))
        self.keep.append(b)
        return ctypes.addressof(b) + odd

    def read(self, addr, n):
        return ctypes.string_at(addr, n)

    def call(self, name, *args):
        a = (ctypes.c_uint64 * 7)(*[x & (2 ** 64 - 1) for x in args])
        out = (ctypes.c_uint64 * 3)()
        self.kc(ctypes.c_void_p(self.addr(name)), a, out)
        if out[2]:
            result(False, f"{name} changed registers (mask {out[2]:#x})")
        return out[0], out[1]


def sha1_of(k, m):
    k.fresh()
    d = k.buf(b"", 20)
    k.call("sha1", d, k.buf(m), len(m))
    return k.read(d, 20)


def sha1_pieces(k, m, rng):
    k.fresh()
    ctx, d = k.buf(b"", 104), k.buf(b"", 20)
    k.call("sha1_init", ctx)
    i = 0
    while i < len(m):
        n = rng.randrange(0, 150)
        k.call("sha1_update", ctx, k.buf(m[i:i + n]), len(m[i:i + n]))
        i += n
    k.call("sha1_final", ctx, d)
    return k.read(d, 20)


def hmac_of(k, key, m):
    k.fresh()
    d = k.buf(b"", 20)
    k.call("hmac_sha1", d, k.buf(key), len(key), k.buf(m), len(m))
    return k.read(d, 20)


def prf_of(k, key, label, data, n):
    k.fresh()
    d = k.buf(b"", n)
    k.call("prf_sha1", d, k.buf(key), len(key), k.buf(label + b"\0"), k.buf(data), len(data), n)
    return k.read(d, n)


def pbkdf2_of(k, pw, ssid):
    k.fresh()
    d = k.buf(b"", 32)
    k.call("pbkdf2_sha1", d, k.buf(pw), len(pw), k.buf(ssid), len(ssid))
    return k.read(d, 32)


def unwrap(k, kek, w):
    k.fresh()
    d = k.buf(b"", len(w))
    _, cf = k.call("aes_unwrap", d, k.buf(kek), k.buf(w), len(w))
    return None if cf else k.read(d, len(w) - 8)


def seal_of(k, tk, hdr, pn, keyid, body):
    k.fresh()
    f = k.buf(hdr + bytes(8) + body, 8)
    k.call("ccmp_seal", f, k.buf(tk), len(body), len(hdr), pn, keyid)
    return k.read(f, len(hdr) + 16 + len(body))


def open_of(k, tk, frame, hlen):
    k.fresh()
    f = k.buf(frame)
    n, cf = k.call("ccmp_open", f, k.buf(tk), len(frame), hlen)
    return None if cf else k.read(f + hlen + 8, n)


# ---- the tests ---------------------------------------------------------------


def published(k):
    for m, d in [(b"abc", "a9993e364706816aba3e25717850c26c9cd0d89d"),
                 (b"", "da39a3ee5e6b4b0d3255bfef95601890afd80709"),
                 (b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
                  "84983e441c3bd26ebaae4aa1f95129e5e54670f1")]:
        result(sha1_of(k, m).hex() == d, f"SHA-1 FIPS 180 vector {m[:8]!r}")
    for key, m, d in [(b"\x0b" * 20, b"Hi There", "b617318655057264e28bc0b6fb378c8ef146be00"),
                      (b"Jefe", b"what do ya want for nothing?", "effcdf6ae5eb2fa2d27416d5f184df9c259a7c79"),
                      (b"\xaa" * 80, b"Test Using Larger Than Block-Size Key - Hash Key First",
                       "aa4ae5e15272d00e95705637ce8a3b55ed402112")]:
        result(hmac_of(k, key, m).hex() == d, f"HMAC-SHA1 RFC 2202 vector {m[:8]!r}")
    result(pbkdf2_of(k, b"password", b"IEEE").hex() ==
           "f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e",
           "PBKDF2: the 802.11 PSK vector (password, IEEE)")
    kek = h("000102030405060708090A0B0C0D0E0F")
    w = h("1FA68B0A8112B447AEF34BD8FB5A7B829D3E862371D2CFE5")
    result(unwrap(k, kek, w) == h("00112233445566778899AABBCCDDEEFF"), "AES key unwrap: RFC 3394 4.1")
    result(unwrap(k, kek, w[:-1] + bytes([w[-1] ^ 1])) is None, "AES key unwrap: a changed bit refused")
    tk = h("c97c1f67ce371185514a8a19f2bdd52f")
    hdr = h("08 48 c3 2c 0f d2 e1 28 a5 7c 50 30 f1 84 44 08 ab ae a5 b8 fc ba 80 33")
    pt = h("f8 ba 1a 55 d0 2f 85 ae 96 7b b6 2f b6 cd a8 eb 7e 78 a0 50")
    want = hdr + h("0c e7 00 20 76 97 03 b5 f3 d0 a2 fe 9a 3d bf 23 42 a6 43 e4 32 46 e8 0c "
                   "3c 04 d0 19 78 45 ce 0b 16 f9 76 23")
    assert ccmp_seal(tk, hdr, 0xB5039776E70C, 0, pt) == want, "the reference CCMP fails the vector"
    assert aes_wrap(kek, h("00112233445566778899AABBCCDDEEFF")) == w, "the reference wrap fails"
    result(seal_of(k, tk, hdr, 0xB5039776E70C, 0, pt) == want, "CCMP: the 802.11 vector sealed")
    result(open_of(k, tk, want, 24) == pt, "CCMP: the 802.11 vector opened")
    bad = bytearray(want)
    bad[-1] ^= 0x80
    result(open_of(k, tk, bytes(bad), 24) is None, "CCMP: a changed MIC refused")


def headers(rng):
    a = lambda: rng.randbytes(6)
    sc = rng.randbytes(2)
    flags = rng.randrange(256) & ~3 & ~0x40 | 0x40
    yield "data", bytes([0x08, flags | 1]) + rng.randbytes(2) + a() + a() + a() + sc
    yield "QoS data", bytes([0x88, flags | 2]) + rng.randbytes(2) + a() + a() + a() + sc + rng.randbytes(2)
    yield "data, four addresses", bytes([0x08, flags | 3]) + rng.randbytes(2) + a() + a() + a() + sc + a()
    yield "QoS data, four addresses", bytes([0x88, flags | 3]) + rng.randbytes(2) + a() + a() + a() + sc + \
        a() + rng.randbytes(2)
    yield "management", bytes([0xD0, flags & ~3]) + rng.randbytes(2) + a() + a() + a() + sc


def randomly(k, rng):
    ok = True
    for n in list(range(0, 150)) + [rng.randrange(150, 3000) for _ in range(30)]:
        m = rng.randbytes(n)
        ok &= sha1_of(k, m) == hashlib.sha1(m).digest()
    result(ok, "SHA-1: 180 random messages")
    ok = True
    for _ in range(40):
        m = rng.randbytes(rng.randrange(0, 700))
        ok &= sha1_pieces(k, m, rng) == hashlib.sha1(m).digest()
    result(ok, "SHA-1: init, update in uneven pieces, final")
    ok = True
    for kn in list(range(0, 140, 3)) + [rng.randrange(0, 200) for _ in range(10)]:
        key, m = rng.randbytes(kn), rng.randbytes(rng.randrange(0, 300))
        ok &= hmac_of(k, key, m) == hmac.new(key, m, hashlib.sha1).digest()
    result(ok, "HMAC-SHA1: keys of 0 to 200 bytes")
    ok = True
    for n in [1, 16, 19, 20, 21, 40, 48, 64, 80] + [rng.randrange(1, 120) for _ in range(10)]:
        key, data = rng.randbytes(32), rng.randbytes(76)
        ok &= prf_of(k, key, b"Pairwise key expansion", data, n) == prf(key, b"Pairwise key expansion", data, n)
    result(ok, "PRF: the pairwise expansion, 1 to 120 bytes")
    ok = True
    for _ in range(3):
        pw = bytes(rng.choice(b"abcdefghijklmnopqrstuvwxyz0123456789 !") for _ in range(rng.randrange(8, 64)))
        ssid = rng.randbytes(rng.randrange(1, 33))
        ok &= pbkdf2_of(k, pw, ssid) == hashlib.pbkdf2_hmac("sha1", pw, ssid, 4096, 32)
    result(ok, "PBKDF2: random passphrases and SSIDs")
    ok = True
    for n in [16, 24, 32, 40, 56] + [8 * rng.randrange(2, 16) for _ in range(10)]:
        kek, data = rng.randbytes(16), rng.randbytes(n)
        w = aes_wrap(kek, data)
        ok &= unwrap(k, kek, w) == data
        bad = bytearray(w)
        bad[rng.randrange(len(w))] ^= 1 << rng.randrange(8)
        ok &= unwrap(k, kek, bytes(bad)) is None
    result(ok, "AES key unwrap: random keys, changed bits refused")
    for name, _ in headers(rng):
        ok = True
        for n in list(range(0, 40)) + [rng.randrange(40, 1600) for _ in range(12)] + [1500, 2304]:
            hdr = dict(headers(rng))[name]
            tk, body = rng.randbytes(16), rng.randbytes(n)
            pn, keyid = rng.randrange(2 ** 48), rng.randrange(4)
            want = ccmp_seal(tk, hdr, pn, keyid, body)
            ok &= seal_of(k, tk, hdr, pn, keyid, body) == want
            ok &= open_of(k, tk, want, len(hdr)) == body
            bad = bytearray(want)
            bad[rng.randrange(len(hdr) + 8, len(bad))] ^= 1 << rng.randrange(8)
            ok &= open_of(k, tk, bytes(bad), len(hdr)) is None
        result(ok, f"CCMP: {name} frames, sealed, opened, a changed bit refused")
    result(open_of(k, rng.randbytes(16), bytes(24 + 15), 24) is None, "CCMP: a frame too short refused")


# ---- build and run -----------------------------------------------------------

KERNEL_LIKE = """\
; generated by tools/test/wpa/run.py: the WPA2 crypto in the kernel's layout
bits 64
default rel
org 0xFFFFFFFF80000000
section .text progbits align=16
section .rodata progbits align=64 follows=.text
section .data progbits align=64 follows=.rodata
section .bss nobits align=64
section .text
%include "crypto.asm"
%include "wpa.asm"
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
    ap.add_argument("--seed", type=int, default=80211)
    ap.add_argument("--cc", default=os.environ.get("CC", GCC))
    opts = ap.parse_args()
    sys.stdout.reconfigure(line_buffering=True)
    nasm = shutil.which("nasm")
    if not nasm:
        sys.exit("nasm not found on PATH")
    cc = opts.cc if os.path.exists(opts.cc) else shutil.which(opts.cc)
    if not cc:
        sys.exit(f"compiler not found: {opts.cc}")
    OUT.mkdir(parents=True, exist_ok=True)
    kinc = str(ROOT / "src" / "kernel") + os.sep
    stub = OUT / "kernel_like.asm"
    stub.write_text(KERNEL_LIKE)
    run([nasm, "-f", "bin", "-w-reloc-abs-qword", "-w-reloc-abs-dword", "-w-reloc-rel-dword",
         "-I", kinc, "-o", OUT / "kernel_like.bin", stub], "nasm -f bin (kernel layout)")
    obj, dll = OUT / "shim.obj", OUT / "wpa.dll"
    run([nasm, "-f", "win64", "-I", kinc, "-o", obj, HERE / "shim.asm"], "nasm -f win64")
    run([cc, "-shared", "-o", dll, obj], "gcc -shared")
    k = Kernel(dll)
    rng = random.Random(opts.seed)
    published(k)
    randomly(k, rng)
    obj, dll = OUT / "hs_shim.obj", OUT / "hs.dll"
    run([nasm, "-f", "win64", "-I", kinc, "-I", str(HERE) + os.sep, "-o", obj,
         HERE / "hs_shim.asm"], "nasm -f win64 (handshakes)")
    run([cc, "-shared", "-o", dll, obj], "gcc -shared (handshakes)")
    handshake.run(Kernel(dll), rng, result, prf, aes_wrap, ccmp_seal)
    if failures:
        print(f"wpa: {len(failures)} failed, {passed} passed")
        sys.exit(1)
    print(f"wpa: all {passed} passed")


main()
