#!/usr/bin/env python3
"""Host tests for the TLS crypto: src/kernel/sha256.asm (SHA-256, HMAC, HKDF,
TLS 1.3 HKDF-Expand-Label), aesgcm.asm (AES-128-GCM) and x25519.asm.

    python tools/test/tls/run.py [--seed N] [--cc PATH]

Assembles the three the way kernel.asm does (-f bin, just to prove they
assemble there) and inside shim.asm as a win64 object, links that with
driver.c, writes the published vectors plus random cases from independent
references (hashlib and hmac; a pure-Python AES-GCM and X25519 written from
SP 800-38D and RFC 7748, each checked against the published vectors first)
and runs the driver. Outputs go to build/test/tls/. Exit status 0 only if
every test passed.
"""
import argparse
import hashlib
import hmac
import importlib.util
import os
import pathlib
import random
import re
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
HERE = pathlib.Path(__file__).resolve().parent
OUT = ROOT / "build" / "test" / "tls"
GCC = (r"C:\Users\noahs\AppData\Local\Microsoft\WinGet\Packages"
       r"\BrechtSanders.WinLibs.POSIX.UCRT_Microsoft.Winget.Source_8wekyb3d8bbwe"
       r"\mingw64\bin\gcc.exe")
MODULES = ("sha256.asm", "aesgcm.asm", "x25519.asm")

# the FIPS-197 AES of the Bluetooth crypto tests
_spec = importlib.util.spec_from_file_location("crypto_run", HERE.parent / "crypto" / "run.py")
_crypto = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_crypto)
aes128_encrypt = _crypto.aes128_encrypt

h = bytes.fromhex

# ---- references --------------------------------------------------------------


def hkdf_extract(salt, ikm):
    return hmac.new(salt, ikm, hashlib.sha256).digest()


def hkdf_expand(prk, info, n):
    out, t, i = b"", b"", 1
    while len(out) < n:
        t = hmac.new(prk, t + info + bytes([i]), hashlib.sha256).digest()
        out += t
        i += 1
    return out[:n]


def expand_label(secret, label, ctx, n):
    full = b"tls13 " + label
    info = n.to_bytes(2, "big") + bytes([len(full)]) + full + bytes([len(ctx)]) + ctx
    return hkdf_expand(secret, info, n)


def _gf_mul(x, y):
    """GF(2^128) product of SP 800-38D, blocks as big-endian integers."""
    r = 0xE1 << 120
    z, v = 0, y
    for i in range(127, -1, -1):
        if (x >> i) & 1:
            z ^= v
        v = (v >> 1) ^ r if v & 1 else v >> 1
    return z


def _ghash(hk, data):
    x = 0
    for i in range(0, len(data), 16):
        blk = data[i:i + 16].ljust(16, b"\0")
        x = _gf_mul(x ^ int.from_bytes(blk, "big"), hk)
    return x


def gcm_seal(key, iv, aad, pt):
    hk = int.from_bytes(aes128_encrypt(key, bytes(16)), "big")
    j0 = iv + b"\0\0\0\1"
    ct = bytearray()
    for i in range(0, len(pt), 16):
        ks = aes128_encrypt(key, iv + (2 + i // 16).to_bytes(4, "big"))
        ct += bytes(a ^ b for a, b in zip(pt[i:i + 16], ks))
    ct = bytes(ct)
    pad = lambda b: b + bytes(-len(b) % 16)
    s = _ghash(hk, pad(aad) + pad(ct) + (8 * len(aad)).to_bytes(8, "big")
               + (8 * len(ct)).to_bytes(8, "big"))
    tag = bytes(a ^ b for a, b in zip(aes128_encrypt(key, j0), s.to_bytes(16, "big")))
    return ct, tag


P25519 = 2 ** 255 - 19


def x25519(k, u):
    """RFC 7748 section 5, as written there."""
    k = bytearray(k)
    k[0] &= 248
    k[31] &= 127
    k[31] |= 64
    k = int.from_bytes(k, "little")
    u = int.from_bytes(u, "little") & ((1 << 255) - 1)
    x1, x2, z2, x3, z3, swap = u, 1, 0, u, 1, 0
    for t in range(254, -1, -1):
        kt = (k >> t) & 1
        swap ^= kt
        if swap:
            x2, x3, z2, z3 = x3, x2, z3, z2
        swap = kt
        A = (x2 + z2) % P25519
        AA = A * A % P25519
        B = (x2 - z2) % P25519
        BB = B * B % P25519
        E = (AA - BB) % P25519
        C = (x3 + z3) % P25519
        D = (x3 - z3) % P25519
        DA = D * A % P25519
        CB = C * B % P25519
        x3 = (DA + CB) ** 2 % P25519
        z3 = x1 * (DA - CB) ** 2 % P25519
        x2 = AA * BB % P25519
        z2 = E * (AA + 121665 * E) % P25519
    if swap:
        x2, z2 = x3, z3
    return (x2 * pow(z2, P25519 - 2, P25519) % P25519).to_bytes(32, "little")


# ---- the published vectors ---------------------------------------------------

GCM_K3 = "feffe9928665731c6d6a8f9467308308"
GCM_IV3 = "cafebabefacedbaddecaf888"
GCM_P3 = ("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a72"
          "1c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255")
GCM_C3 = ("42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e"
          "21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091473f5985")


def published():
    """(kind, args) lines with the published answers: from FIPS 180-4 examples,
    RFC 4231, RFC 5869, RFC 8448, the GCM spec's test cases 1-4, RFC 7748."""
    abc448 = b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
    L = []
    L.append(("sha", "-", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"))
    L.append(("sha", b"abc".hex(),
              "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
    L.append(("sha", abc448.hex(),
              "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"))
    L.append(("sharep", "61", "1000000",
              "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"))
    L.append(("hmac", "0b" * 20, b"Hi There".hex(),
              "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"))
    L.append(("hmac", b"Jefe".hex(), b"what do ya want for nothing?".hex(),
              "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"))
    L.append(("hmac", "aa" * 131, b"Test Using Larger Than Block-Size Key - Hash Key First".hex(),
              "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"))
    L.append(("hkdf", "000102030405060708090a0b0c", "0b" * 22, "f0f1f2f3f4f5f6f7f8f9", "42",
              "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5",
              "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf"
              "34007208d5b887185865"))
    # RFC 8448 3: the early secret (HKDF-Extract of zeros) and Derive-Secret(., "derived", "")
    L.append(("hkdf", "-", "00" * 32, "-", "1",
              "33ad0a1c607ec03b09e6cd9893680ce210adf300aa1f2660e1b22e10f170f92a",
              hkdf_expand(h("33ad0a1c607ec03b09e6cd9893680ce210adf300aa1f2660e1b22e10f170f92a"),
                          b"", 1).hex()))
    L.append(("label", "33ad0a1c607ec03b09e6cd9893680ce210adf300aa1f2660e1b22e10f170f92a",
              b"derived".hex(), hashlib.sha256(b"").hexdigest(), "32",
              "6f2615a108c702c5678f54fc9dbab69716c076189c48250cebeac3576c3611ba"))
    L.append(("gcm", "00" * 16, "00" * 12, "-", "-", "-", "58e2fccefa7e3061367f1d57a4e7455a"))
    L.append(("gcm", "00" * 16, "00" * 12, "-", "00" * 16, "0388dace60b6a392f328c2b971b2fe78",
              "ab6e47d42cec13bdf53a67b21257bddf"))
    L.append(("gcm", GCM_K3, GCM_IV3, "-", GCM_P3, GCM_C3, "4d5c2af327cd64a62cf35abd2ba6fab4"))
    L.append(("gcm", GCM_K3, GCM_IV3, "feedfacedeadbeeffeedfacedeadbeefabaddad2",
              GCM_P3[:120], GCM_C3[:120], "5bc94fbc3221a5db94fae95ae7121a47"))
    L.append(("x25519", "a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4",
              "e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c",
              "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552"))
    alice = "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"
    bob = "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb"
    alice_pub = "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"
    bob_pub = "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f"
    shared = "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"
    L.append(("x25519base", alice, alice_pub))
    L.append(("x25519base", bob, bob_pub))
    L.append(("x25519", alice, bob_pub, shared))
    L.append(("x25519", bob, alice_pub, shared))
    L.append(("x25519iter", "1", "422c8e7a6227d7bca1350b3e2bb7279f7897b87bb6854b783c60e80311ae3079"))
    L.append(("x25519iter", "1000",
              "684cf59ba83309552800ef566f2f4d3c1c3887c49360e3875f2eb94d99532c51"))
    return L


def x25519_iter(n):
    k = u = (9).to_bytes(32, "little")
    for _ in range(n):
        k, u = x25519(k, u), k
    return k


def self_check(lines):
    """Every reference must reproduce every published answer before it is trusted."""
    def unh(s):
        return b"" if s == "-" else h(s)
    for kind, *a in lines:
        if kind == "sha":
            got = hashlib.sha256(unh(a[0])).hexdigest()
        elif kind == "sharep":
            got = hashlib.sha256(h(a[0]) * int(a[1])).hexdigest()
        elif kind == "hmac":
            got = hmac.new(unh(a[0]), unh(a[1]), hashlib.sha256).hexdigest()
        elif kind == "hkdf":
            prk = hkdf_extract(unh(a[0]), unh(a[1]))
            okm = hkdf_expand(prk, unh(a[2]), int(a[3]))
            assert prk.hex() == a[4], f"reference HKDF-Extract fails: {a}"
            got, a = okm.hex(), [a[5]]
        elif kind == "label":
            got = expand_label(h(a[0]), h(a[1]), unh(a[2]), int(a[3])).hex()
        elif kind == "gcm":
            ct, tag = gcm_seal(h(a[0]), h(a[1]), unh(a[2]), unh(a[3]))
            got, a = ct.hex() + tag.hex(), [("" if a[4] == "-" else a[4]) + a[5]]
        elif kind == "x25519":
            got = x25519(h(a[0]), h(a[1])).hex()
        elif kind == "x25519base":
            got = x25519(h(a[0]), (9).to_bytes(32, "little")).hex()
        elif kind == "x25519iter":
            got = x25519_iter(int(a[0])).hex()
        assert got == a[-1], f"reference {kind} fails its published vector: {got} != {a[-1]}"


def random_cases(rng):
    L = []
    for n in list(range(0, 200)) + [rng.randrange(200, 5000) for _ in range(60)]:
        m = rng.randbytes(n)
        L.append(("sha", m.hex() or "-", hashlib.sha256(m).hexdigest()))
    for kn in list(range(0, 140, 3)) + [rng.randrange(0, 300) for _ in range(20)]:
        k, m = rng.randbytes(kn), rng.randbytes(rng.randrange(0, 600))
        L.append(("hmac", k.hex() or "-", m.hex() or "-",
                  hmac.new(k, m, hashlib.sha256).hexdigest()))
    for i in range(80):
        salt, ikm = rng.randbytes(rng.randrange(0, 80)), rng.randbytes(rng.randrange(0, 80))
        info = rng.randbytes(rng.randrange(0, 60))
        n = [1, 31, 32, 33, 64, 65][i] if i < 6 else rng.randrange(1, 400)
        prk = hkdf_extract(salt, ikm)
        L.append(("hkdf", salt.hex() or "-", ikm.hex() or "-", info.hex() or "-", str(n),
                  prk.hex(), hkdf_expand(prk, info, n).hex()))
    labels = [b"derived", b"c hs traffic", b"s hs traffic", b"c ap traffic", b"s ap traffic",
              b"key", b"iv", b"finished", b"exp master", b"res master", b"traffic upd"]
    for i in range(60):
        sec = rng.randbytes(32)
        lab = labels[i % len(labels)] if i < 40 else rng.randbytes(rng.randrange(1, 60)) \
            .replace(b"\0", b"x")
        ctx = rng.choice([b"", rng.randbytes(32), rng.randbytes(rng.randrange(0, 65))])
        n = rng.choice([12, 16, 32, rng.randrange(1, 100)])
        L.append(("label", sec.hex(), lab.hex(), ctx.hex() or "-", str(n),
                  expand_label(sec, lab, ctx, n).hex()))
    eights = list(range(112, 146)) + list(range(250, 262)) + [383, 384, 385, 1024, 1039, 16384, 16385]
    for i, n in enumerate(list(range(0, 70)) + [rng.randrange(70, 2000) for _ in range(40)] + eights):
        key, iv = rng.randbytes(16), rng.randbytes(12)       # the last ones 128 bytes at a time with VAES
        aad = rng.randbytes(rng.choice([0, 5, 13, 16, 17, rng.randrange(0, 50)]) if i % 4
                            else rng.choice([127, 128, 129, 300]))
        pt = rng.randbytes(n)
        ct, tag = gcm_seal(key, iv, aad, pt)
        L.append(("gcm", key.hex(), iv.hex(), aad.hex() or "-", pt.hex() or "-",
                  ct.hex() or "-", tag.hex()))
    edge_u = [bytes(32), (1).to_bytes(32, "little"), (P25519 - 1).to_bytes(32, "little"),
              P25519.to_bytes(32, "little"), (P25519 + 1).to_bytes(32, "little"),
              (2 ** 255 - 1).to_bytes(32, "little"), b"\xff" * 32]
    for i in range(80):
        k = rng.randbytes(32)
        u = edge_u[i] if i < len(edge_u) else rng.randbytes(32)
        L.append(("x25519", k.hex(), u.hex(), x25519(k, u).hex()))
    for _ in range(10):
        k = rng.randbytes(32)
        L.append(("x25519base", k.hex(), x25519(k, (9).to_bytes(32, "little")).hex()))
    return L


# ---- build and run -----------------------------------------------------------

KERNEL_LIKE = """\
; generated by tools/test/tls/run.py: the TLS crypto in the kernel's layout
bits 64
default rel
org 0xFFFFFFFF80000000
section .text progbits align=16
section .rodata progbits align=64 follows=.text
section .data progbits align=64 follows=.rodata
section .bss nobits align=64
[map sections {map}]
section .text
{includes}
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
    ap.add_argument("--seed", type=int, default=8446)
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
    mapfile = OUT / "kernel_like.map"
    stub.write_text(KERNEL_LIKE.format(map=mapfile.as_posix(), includes="\n".join(
        f'%include "{m}"' for m in MODULES)))
    run([nasm, "-f", "bin", "-w-reloc-abs-qword", "-w-reloc-abs-dword", "-w-reloc-rel-dword",
         "-I", kinc, "-o", OUT / "kernel_like.bin", stub], "nasm -f bin (kernel layout)")
    sizes = {name: int(length, 16) for length, name in re.findall(
        r"^[0-9A-F]+\s+[0-9A-F]+\s+[0-9A-F]+\s+([0-9A-F]+)\s+\w+\s+(\.\w+)\s*$",
        mapfile.read_text(), re.M)}
    print("kernel layout: " + ", ".join(MODULES) + " assemble; " +
          ", ".join(f"{n} {sizes[n]} bytes" for n in (".text", ".rodata", ".data", ".bss")
                    if n in sizes))

    obj = OUT / "shim.obj"
    exe = OUT / "tls_test.exe"
    run([nasm, "-f", "win64", "-I", kinc, "-o", obj, HERE / "shim.asm"], "nasm -f win64")
    run([cc, "-O2", "-Wall", "-Wextra", "-static", "-o", exe, HERE / "driver.c", obj], "gcc")

    pub = published()
    self_check(pub)
    rand = random_cases(random.Random(opts.seed))
    vec = OUT / "cases.txt"
    vec.write_text("".join(" ".join(c) + "\n" for c in pub + rand))
    print(f"cases: {len(pub)} published vectors (the references reproduce them all) + "
          f"{len(rand)} random, seed {opts.seed}")

    r = subprocess.run([str(exe), str(vec)], cwd=ROOT)
    if r.returncode:
        code = r.returncode & 0xFFFFFFFF
        if code >= 0xC0000000:
            print(f"tls_test.exe crashed: exception 0x{code:08X}, in the test after the "
                  "last line above (0xC0000005: a fault, e.g. a read past a buffer)")
        sys.exit(1)


if __name__ == "__main__":
    main()
