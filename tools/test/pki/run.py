#!/usr/bin/env python3
"""Host tests for what checks certificates: src/kernel/sha512.asm (SHA-384,
SHA-512), bignum.asm (Montgomery arithmetic), pubkey.asm (RSA PKCS #1 v1.5
and PSS, ECDSA P-256 and P-384, and signing with P-256) and x509.asm
(certificates, chains, names, dates, with Mozilla's roots in
gen/roots.asm).

    python tools/test/pki/run.py [--seed N] [--cc PATH] [--offline]

Assembles the modules the way kernel.asm does (-f bin, to prove they
assemble there) and into a DLL with shim.asm and host.c, then checks them
against independent references: hashlib; Python's own integers for the
arithmetic; RSA and ECDSA written here from RFC 8017 and FIPS 186-5 (the
curves' numbers taken from the openssl tool), first checked against
signatures the openssl tool makes; certificate chains the openssl tool
signs, good ones and every kind of bad one; and, unless --offline, the
chains real servers send, against the built-in roots. Then register
preservation and speeds. Outputs go to build/test/pki/. Exit status 0 only
if every test passed.
"""
import argparse
import calendar
import ctypes
import hashlib
import os
import pathlib
import random
import re
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[3]
HERE = pathlib.Path(__file__).resolve().parent
OUT = ROOT / "build" / "test" / "pki"
GCC = (r"C:\Users\noahs\AppData\Local\Microsoft\WinGet\Packages"
       r"\BrechtSanders.WinLibs.POSIX.UCRT_Microsoft.Winget.Source_8wekyb3d8bbwe"
       r"\mingw64\bin\gcc.exe")
MODULES = ("sha256.asm", "sha512.asm", "rand.asm", "bignum.asm", "pubkey.asm", "x509.asm")
sys.path.insert(0, str(ROOT / "tools"))
import mkroots  # noqa: E402
sys.path.insert(0, str(ROOT / "tools" / "test"))
import rusthost  # noqa: E402
RUST = ["rs_x509_parse", "rs_x509_unix", "rs_x509_name"]       # x509.asm's, in Rust

FN = {n: i for i, n in enumerate(
    "sha384 sha512 mont_setup mont_mul mont_in mont_out mont_add mont_sub mont_exp "
    "bn_load bn_store sig_verify x509_chain x509_leaf x509_parse x509_unix sig_sign ec_public".split())}
MONT_CTX = 32 + 3 * 512
MC_L, MC_N0, MC_BITS, MC_N, MC_RR, MC_ONE = 0, 8, 16, 32, 32 + 512, 32 + 1024
KT_RSA, KT_P256, KT_P384 = 1, 2, 3
X5E = ["OK", "MALFORMED", "ALGORITHM", "KEY", "EXPIRED", "NOTYET", "NAME", "ISSUER",
       "SIGNATURE", "NOTCA", "PATHLEN", "PURPOSE", "CRITICAL", "CLOCK"]
HASHES = {4: hashlib.sha256, 5: hashlib.sha384, 6: hashlib.sha512}
DIGESTINFO = {4: "3031300d060960864801650304020105000420",
              5: "3041300d060960864801650304020205000430",
              6: "3051300d060960864801650304020305000440"}

passes = fails = 0


def result(ok, text):
    global passes, fails
    print(("PASS  " if ok else "FAIL  ") + text)
    if ok:
        passes += 1
    else:
        fails += 1


def run(cmd, what, check=True):
    r = subprocess.run([str(c) for c in cmd], cwd=ROOT, capture_output=True, text=True)
    out = (r.stdout + r.stderr).strip()
    if r.returncode and check:
        print(out)
        sys.exit(f"{what} failed ({r.returncode})")
    return out


def find_openssl():
    for c in (shutil.which("openssl"), r"C:\Program Files\Git\usr\bin\openssl.exe"):
        if c and os.path.exists(c):
            return c
    sys.exit("the openssl tool is needed")


OSSL = None


def ossl(*a, check=True):
    return run([OSSL, *a], "openssl " + str(a[0]), check)


# ---- the DLL ------------------------------------------------------------------


class Kernel:
    def __init__(self, path):
        d = self.d = ctypes.CDLL(str(path))
        d.h_k.argtypes = [ctypes.c_int] + [ctypes.c_uint64] * 6 + [ctypes.POINTER(ctypes.c_int)]
        d.h_k.restype = ctypes.c_uint64
        d.h_regs.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_uint64),
                             ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_uint64)]
        d.h_set_extra.argtypes = [ctypes.c_void_p]
        d.h_anchor.restype = ctypes.c_char_p
        d.h_key.argtypes = [ctypes.c_char_p]
        d.h_roots.restype = ctypes.c_void_p
        d.h_error_text.restype = ctypes.c_char_p
        self.keep = []

    @staticmethod
    def arg(x):
        if isinstance(x, ctypes.Array):
            return ctypes.addressof(x)
        return int(x) & (2 ** 64 - 1)

    def __call__(self, fn, *args):
        a = [self.arg(x) for x in args] + [0] * (6 - len(args))
        cf = ctypes.c_int()
        r = self.d.h_k(FN[fn], *a, ctypes.byref(cf))
        return r, cf.value

    def regs(self, fn, *args):
        a = (ctypes.c_uint64 * 6)(*([self.arg(x) for x in args] + [0] * (6 - len(args))))
        cf = ctypes.c_int()
        r = (ctypes.c_uint64 * 32)()
        self.d.h_regs(FN[fn], a, ctypes.byref(cf), r)
        return list(r[:16]), list(r[16:]), cf.value


def buf(data, size=None):
    if isinstance(data, int):
        return ctypes.create_string_buffer(data)
    return ctypes.create_string_buffer(bytes(data), size or max(len(data), 1))


def limbs(x, n):
    return buf(x.to_bytes(n * 8, "little"))


def value(b, n):
    return int.from_bytes(b.raw[:n * 8], "little")


# ---- references -----------------------------------------------------------------


def mgf1(seed, n, h):
    out, c = b"", 0
    while len(out) < n:
        out += h(seed + c.to_bytes(4, "big")).digest()
        c += 1
    return out[:n]


def rsa_sign_pkcs1(key, msg, hid):
    n, d = key["n"], key["d"]
    k = (n.bit_length() + 7) // 8
    t = bytes.fromhex(DIGESTINFO[hid]) + HASHES[hid](msg).digest()
    em = b"\0\1" + b"\xff" * (k - len(t) - 3) + b"\0" + t
    return pow(int.from_bytes(em, "big"), d, n).to_bytes(k, "big")


def rsa_sign_pss(key, msg, hid, rng, slen=None):
    n, d = key["n"], key["d"]
    h = HASHES[hid]
    hl = h().digest_size
    slen = hl if slen is None else slen
    embits = n.bit_length() - 1
    emlen = (embits + 7) // 8
    salt = rng.randbytes(slen)
    hh = h(b"\0" * 8 + h(msg).digest() + salt).digest()
    db = b"\0" * (emlen - slen - hl - 2) + b"\1" + salt
    masked = bytearray(a ^ b for a, b in zip(db, mgf1(hh, len(db), h)))
    masked[0] &= 0xFF >> (8 * emlen - embits)
    em = bytes(masked) + hh + b"\xbc"
    k = (n.bit_length() + 7) // 8
    return pow(int.from_bytes(em, "big"), d, n).to_bytes(k, "big")


class Curve:
    def __init__(self, name, size, kt):
        self.name, self.size, self.kt = name, size, kt
        t = ossl("ecparam", "-name", name, "-param_enc", "explicit", "-noout", "-text")
        parts, cur = {}, None
        for line in t.splitlines():
            m = re.match(r"^(\w[\w ()]*):", line)
            if m and not line.startswith(" "):
                cur = m.group(1).split()[0]
                parts[cur] = ""
            elif cur and line.startswith(" "):
                parts[cur] += line.strip().replace(":", "")
        self.p, self.b = int(parts["Prime"], 16), int(parts["B"], 16)
        self.n = int(parts["Order"], 16)
        g = parts["Generator"][2:]
        self.g = (int(g[:2 * size], 16), int(g[2 * size:], 16))

    def add(self, a, b):
        if a is None:
            return b
        if b is None:
            return a
        p = self.p
        if a[0] == b[0]:
            if (a[1] + b[1]) % p == 0:
                return None
            lam = (3 * a[0] * a[0] - 3) * pow(2 * a[1], -1, p) % p
        else:
            lam = (b[1] - a[1]) * pow(b[0] - a[0], -1, p) % p
        x = (lam * lam - a[0] - b[0]) % p
        return x, (lam * (a[0] - x) - a[1]) % p

    def mul(self, k, pt):
        r = None
        while k:
            if k & 1:
                r = self.add(r, pt)
            pt = self.add(pt, pt)
            k >>= 1
        return r

    def e(self, h):
        nb = self.n.bit_length()
        return int.from_bytes(h, "big") >> max(0, 8 * len(h) - nb)

    def sign(self, d, h, rng):
        while True:
            k = rng.randrange(1, self.n)
            r = self.mul(k, self.g)[0] % self.n
            s = pow(k, -1, self.n) * (self.e(h) + r * d) % self.n
            if r and s:
                return r, s

    def point(self, q):
        return b"\4" + q[0].to_bytes(self.size, "big") + q[1].to_bytes(self.size, "big")


def der_int(x):
    b = x.to_bytes(max(1, (x.bit_length() + 7) // 8), "big")
    if b[0] & 0x80:
        b = b"\0" + b
    return b"\2" + bytes([len(b)]) + b


def der_sig(r, s):
    body = der_int(r) + der_int(s)
    return b"\x30" + bytes([len(body)]) + body


# ---- keys and signatures from the openssl tool ------------------------------------------


def pkcs8(path):
    """(kind, numbers) from a PKCS #8 DER private key."""
    der = path.read_bytes()
    _, s, e = mkroots.tlv(der, 0)
    top = mkroots.children(der, s, e)
    num = lambda x: int.from_bytes(der[x[1]:x[2]], "big")
    if top[1][0] == 2:                          # RSAPrivateKey (PKCS #1)
        return "rsa", {"n": num(top[1]), "e": num(top[2]), "d": num(top[3])}
    if top[1][0] == 4:                          # ECPrivateKey (RFC 5915)
        params = next(x for x in top if x[0] == 0xA0)
        curve = der[params[1] + 2:params[2]]
        return ("p256" if curve == mkroots.OID_P256 else "p384"), {"d": num(top[1])}
    ver, alg, octets = top[:3]
    a = mkroots.children(der, alg[1], alg[2])
    oid = der[a[0][1]:a[0][2]]
    inner = der[octets[1]:octets[2]]
    _, s, e = mkroots.tlv(inner, 0)
    f = mkroots.children(inner, s, e)
    num = lambda x: int.from_bytes(inner[x[1]:x[2]], "big")
    if oid == mkroots.OID_RSA:
        return "rsa", {"n": num(f[1]), "e": num(f[2]), "d": num(f[3])}
    curve = der[a[1][1]:a[1][2]]
    return ("p256" if curve == mkroots.OID_P256 else "p384"), {"d": num(f[1])}


def make_keys(d):
    d.mkdir(parents=True, exist_ok=True)
    keys = {}
    for name, opts in (("rsa2048", ["-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048"]),
                       ("rsa2049", ["-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2049"]),
                       ("rsa3072", ["-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:3072"]),
                       ("rsa4096", ["-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:4096"]),
                       ("rsa2048e3", ["-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048",
                                      "-pkeyopt", "rsa_keygen_pubexp:3"]),
                       ("rsa1024", ["-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:1024"]),
                       ("p256", ["-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256"]),
                       ("p384", ["-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-384"])):
        f = d / f"{name}.der"
        if not f.exists():
            ossl("genpkey", *opts, "-outform", "DER", "-out", f)
        keys[name] = (f, *pkcs8(f))
    return keys


# ---- the tests ------------------------------------------------------------------------


def test_sha(k, rng):
    bad = 0
    lens = list(range(0, 300)) + [rng.randrange(300, 9000) for _ in range(60)] + [100000]
    for n in lens:
        m = rng.randbytes(n)
        src = buf(m)
        for name, h in (("sha384", hashlib.sha384), ("sha512", hashlib.sha512)):
            out = buf(64)
            k(name, out, src, n)
            want = h(m).digest()
            if out.raw[:len(want)] != want:
                bad += 1
                if bad < 5:
                    print(f"      {name} of {n} bytes: {out.raw[:len(want)].hex()[:32]}..., want {want.hex()[:32]}...")
    out = buf(64)
    k("sha512", out, buf(b"abc"), 3)
    abc = out.raw.hex().startswith("ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a")
    result(bad == 0 and abc, f"SHA-384 and SHA-512 against hashlib, {len(lens)} lengths up to "
           f"100000 bytes, and FIPS 180-4's 'abc': {bad} wrong")


def mont_case(k, rng, n, problems):
    nb = (n.bit_length() + 7) // 8
    lead = rng.choice([0, 0, 1, 3])                # leading zero bytes are allowed
    ctx = buf(MONT_CTX)
    _, cf = k("mont_setup", ctx, buf(b"\0" * lead + n.to_bytes(nb, "big")), 0, nb + lead)
    if cf:
        problems.append(f"mont_setup refused a {n.bit_length()}-bit modulus")
        return
    L = (nb + 7) // 8
    R = 1 << (64 * L)
    raw = ctx.raw
    got = [int.from_bytes(raw[MC_L:MC_L + 8], "little"), int.from_bytes(raw[MC_N0:MC_N0 + 8], "little"),
           int.from_bytes(raw[MC_BITS:MC_BITS + 8], "little"),
           int.from_bytes(raw[MC_RR:MC_RR + 8 * L], "little"),
           int.from_bytes(raw[MC_ONE:MC_ONE + 8 * L], "little")]
    want = [L, (-pow(n, -1, 2 ** 64)) % 2 ** 64, n.bit_length(), R * R % n, R % n]
    if got != want:
        problems.append(f"context for a {n.bit_length()}-bit modulus: {got[:3]} want {want[:3]}"
                        f"{'' if got[3:] == want[3:] else ', R^2 or R wrong'}")
        return
    ri = pow(R, -1, n)
    for _ in range(3):
        a, b = rng.randrange(n), rng.randrange(n)
        if rng.random() < 0.2:
            a = n - 1
        A, B, O = limbs(a, L), limbs(b, L), buf(8 * L)
        checks = [("mont_mul", (O, A, B, ctx), a * b * ri % n),
                  ("mont_add", (O, A, B, ctx), (a + b) % n),
                  ("mont_sub", (O, A, B, ctx), (a - b) % n),
                  ("mont_in", (O, A, ctx), a * R % n),
                  ("mont_out", (O, A, ctx), a * ri % n)]
        for name, args, w in checks:
            # mont_in/out take (out, a, ctx) as RDI, RSI, RCX
            if name in ("mont_in", "mont_out"):
                k(name, args[0], args[1], 0, args[2])
            else:
                k(name, *args)
            if value(O, L) != w:
                problems.append(f"{name} wrong for a {n.bit_length()}-bit modulus")
        k("mont_mul", A, A, B, ctx)                # out = a
        if value(A, L) != a * b * ri % n:
            problems.append(f"mont_mul into its own input, {n.bit_length()} bits")
        el = rng.choice([1, 1, 2, 3])
        e = rng.getrandbits(64 * el) >> rng.randrange(0, 64)
        if rng.random() < 0.1:
            e = 0
        am = limbs(a * R % n, L)
        k("mont_exp", O, am, limbs(e, el), ctx, el)
        if value(O, L) != pow(a, e, n) * R % n:
            problems.append(f"mont_exp, {n.bit_length()}-bit modulus, {e.bit_length()}-bit exponent")


def test_bignum(k, rng):
    problems = []
    cases = 0
    p256 = Curve("prime256v1", 32, KT_P256)
    p384 = Curve("secp384r1", 48, KT_P384)
    special = [3, 5, 2 ** 64 - 1, 2 ** 64 + 1, 2 ** 127 - 1, 2 ** 521 - 1, 2 ** 4096 - 1,
               p256.p, p256.n, p384.p, p384.n, 2 ** 4095 + 1, (2 ** 2048 - 1) // 3]
    for n in special:
        mont_case(k, rng, n, problems)
        cases += 1
    for limb in range(1, 65):
        for _ in range(2):
            bits = 64 * limb - rng.choice([0, 0, 1, 7, 13, 63])
            n = rng.getrandbits(bits) | (1 << (bits - 1)) | 1
            mont_case(k, rng, n, problems)
            cases += 1
    refused = []
    for label, data in (("even", b"\x01\x00"), ("one", b"\x01"), ("zero", b"\0\0"),
                        ("513 bytes", b"\x01" + b"\0" * 511 + b"\x01")):
        _, cf = k("mont_setup", buf(MONT_CTX), buf(data), 0, len(data))
        if not cf:
            refused.append(label)
    big, cf = k("bn_load", buf(16), buf(b"\1" + b"\0" * 16), 2, 17)
    _, cf2 = k("bn_load", buf(16), buf(b"\0" * 3 + b"\1" * 16), 2, 19)
    if not cf or cf2:
        problems.append("bn_load: a number too big taken, or leading zeros refused")
    if refused:
        problems.append("mont_setup took moduli it should refuse: " + ", ".join(refused))
    result(not problems, f"Montgomery arithmetic: {cases} moduli from 2 to 4096 bits, every "
           "operation against Python's integers" + ("" if not problems else ": " + "; ".join(problems[:6])))
    return p256, p384


def key_struct(kt, data, e=0):
    kb = buf(data)
    return buf(struct.pack("<IIQQ", kt, len(data), e, ctypes.addressof(kb))), kb


def verify(k, key, scheme, msg, sig):
    m, s = buf(msg), buf(sig)
    _, cf = k("sig_verify", key[0], scheme, m, len(msg), s, len(sig))
    return cf == 0


def rsa_key(info):
    n = info["n"]
    return key_struct(KT_RSA, n.to_bytes((n.bit_length() + 7) // 8, "big"), info["e"])


def test_rsa(k, rng, keys, tmp):
    problems = []
    good = 0
    # the reference against the openssl tool first: what it signs, we must take
    msg = rng.randbytes(1000)
    (tmp / "msg").write_bytes(msg)
    for name in ("rsa2048", "rsa2049", "rsa3072", "rsa4096", "rsa2048e3"):
        f, _, info = keys[name]
        key = rsa_key(info)
        for hid, hn in ((4, "sha256"), (5, "sha384"), (6, "sha512")):
            for pss in (False, True):
                opts = ["-sigopt", "rsa_padding_mode:pss", "-sigopt", "rsa_pss_saltlen:digest"] if pss else []
                ossl("dgst", f"-{hn}", "-keyform", "DER", "-sign", f, *opts, "-out", tmp / "sig", tmp / "msg")
                sig = (tmp / "sig").read_bytes()
                scheme = (0x0800 | hid) if pss else (hid << 8 | 1)
                if verify(k, key, scheme, msg, sig):
                    good += 1
                else:
                    problems.append(f"openssl's {name} {'PSS' if pss else 'PKCS#1'} {hn} refused")
                ref = rsa_sign_pss(info, msg, hid, rng) if pss else rsa_sign_pkcs1(info, msg, hid)
                if not pss and ref != sig:
                    problems.append(f"the PKCS#1 reference differs from openssl ({name} {hn})")
    result(not problems, f"RSA: {good} signatures the openssl tool made (PKCS#1 v1.5 and PSS, "
           "SHA-256/384/512, 2048-4096 bits, e = 65537 and 3) verify" +
           ("" if not problems else ": " + "; ".join(problems[:5])))

    problems = []
    count = 0
    for name in ("rsa2048", "rsa2049", "rsa3072", "rsa4096"):
        info = keys[name][2]
        key = rsa_key(info)
        for _ in range(4):
            m = rng.randbytes(rng.randrange(0, 3000))
            hid = rng.choice([4, 5, 6])
            for pss in (False, True):
                sig = rsa_sign_pss(info, m, hid, rng) if pss else rsa_sign_pkcs1(info, m, hid)
                scheme = (0x0800 | hid) if pss else (hid << 8 | 1)
                count += 1
                if not verify(k, key, scheme, m, sig):
                    problems.append(f"{name} {scheme:#06x} refused")
                bad = bytearray(sig)
                bad[rng.randrange(len(bad))] ^= 1 << rng.randrange(8)
                tamper = [("a flipped signature bit", scheme, m, bytes(bad))]
                if m:
                    mm = bytearray(m)
                    mm[rng.randrange(len(mm))] ^= 0x10
                    tamper.append(("a changed message", scheme, bytes(mm), sig))
                other = 4 + (hid - 3) % 3
                tamper.append(("another hash", (0x0800 | other) if pss else (other << 8 | 1), m, sig))
                tamper.append(("the other padding", (hid << 8 | 1) if pss else (0x0800 | hid), m, sig))
                tamper.append(("a byte short", scheme, m, sig[1:]))
                tamper.append(("the modulus itself", scheme, m,
                               info["n"].to_bytes(len(sig), "big")))
                for what, sc, mm, ss in tamper:
                    count += 1
                    if verify(k, key, sc, mm, ss):
                        problems.append(f"{name}: taken with {what}")
    info = keys["rsa2048"][2]
    m = b"salt"
    for slen in (0, 20, 64):
        count += 1
        if verify(k, rsa_key(info), 0x0804, m, rsa_sign_pss(info, m, 4, rng, slen)):
            problems.append(f"PSS with a {slen}-byte salt taken (TLS wants the hash's 32)")
    weak = keys["rsa1024"][2]
    count += 1
    if verify(k, rsa_key(weak), 0x0401, m, rsa_sign_pkcs1(weak, m, 4)):
        problems.append("a 1024-bit key taken")
    even = dict(info, e=65536)
    count += 1
    if verify(k, rsa_key(even), 0x0401, m, rsa_sign_pkcs1(info, m, 4)):
        problems.append("an even exponent taken")
    for scheme in (0x0402, 0x0701, 0x0807, 0x0000, 0x0301):
        count += 1
        if verify(k, rsa_key(info), scheme, m, rsa_sign_pkcs1(info, m, 4)):
            problems.append(f"scheme {scheme:#06x} taken")
    result(not problems, f"RSA: {count} cases against the reference, good and bad (flipped bits, "
           "other hash or padding, short, >= n, PSS salts, 1024 bits, even e, unknown schemes)" +
           ("" if not problems else ": " + "; ".join(problems[:5])))


def test_ecdsa(k, rng, keys, curves, tmp):
    problems = []
    good = 0
    msg = rng.randbytes(777)
    (tmp / "msg").write_bytes(msg)
    for name, c in (("p256", curves[0]), ("p384", curves[1])):
        f, _, info = keys[name]
        q = c.mul(info["d"], c.g)
        key = key_struct(c.kt, c.point(q))
        for hid, hn in ((4, "sha256"), (5, "sha384"), (6, "sha512")):
            ossl("dgst", f"-{hn}", "-keyform", "DER", "-sign", f, "-out", tmp / "sig", tmp / "msg")
            sig = (tmp / "sig").read_bytes()
            if verify(k, key, hid << 8 | 3, msg, sig):
                good += 1
            else:
                problems.append(f"openssl's {name} {hn} refused")
            r, s = c.sign(info["d"], HASHES[hid](msg).digest(), rng)
            (tmp / "ref").write_bytes(der_sig(r, s))
            ossl("pkey", "-inform", "DER", "-in", f, "-pubout", "-out", tmp / "pub.pem")
            out = ossl("dgst", f"-{hn}", "-verify", tmp / "pub.pem", "-signature", tmp / "ref",
                       tmp / "msg", check=False)
            if "Verified OK" not in out:
                problems.append(f"openssl refuses the reference's {name} {hn}: {out[:60]}")
    result(not problems, f"ECDSA: {good} signatures the openssl tool made (P-256, P-384; SHA-256/"
           "384/512) verify, and it takes the reference's" +
           ("" if not problems else ": " + "; ".join(problems[:5])))

    problems = []
    count = 0
    for c in curves:
        for _ in range(12):
            d = rng.randrange(1, c.n)
            q = c.mul(d, c.g)
            key = key_struct(c.kt, c.point(q))
            m = rng.randbytes(rng.randrange(0, 500))
            hid = rng.choice([4, 5, 6])
            r, s = c.sign(d, HASHES[hid](m).digest(), rng)
            scheme = hid << 8 | 3
            for what, rr, ss, want in (("good", r, s, True), ("n - s", r, c.n - s, True),
                                       ("r + 1", (r + 1) % c.n, s, False), ("s + 1", r, (s + 1) % c.n, False),
                                       ("r = 0", 0, s, False), ("s = 0", r, 0, False),
                                       ("r = n", c.n, s, False), ("s = n", r, c.n, False),
                                       ("r + n", r + c.n, s, False)):
                count += 1
                if verify(k, key, scheme, m, der_sig(rr, ss)) != want:
                    problems.append(f"{c.name} {what}: {'refused' if want else 'taken'}")
            good_sig = der_sig(r, s)
            for what, kk, mm, sg in (
                    ("a changed message", key, m + b"x", good_sig),
                    ("another hash", key, m, None),
                    ("a point off the curve", key_struct(c.kt, c.point((q[0], (q[1] + 1) % c.p))), m, good_sig),
                    ("x >= p", key_struct(c.kt, c.point((q[0] + c.p, q[1])) if q[0] + c.p < 2 ** (8 * c.size)
                                          else c.point((2 ** (8 * c.size) - 1, q[1]))), m, good_sig),
                    ("the other curve", key_struct(KT_P384 if c.kt == KT_P256 else KT_P256, c.point(q)), m, good_sig),
                    ("a compressed point", key_struct(c.kt, b"\2" + c.point(q)[1:]), m, good_sig),
                    ("a byte after it", key, m, good_sig + b"\0"),
                    ("a negative r", key, m, b"\x30" + bytes([good_sig[1]]) + b"\2" + bytes([good_sig[3]]) +
                     bytes([good_sig[4] | 0x80]) + good_sig[5:]),
                    ("a cut-off signature", key, m, good_sig[:-1])):
                count += 1
                sc = scheme if sg is not None else (4 + (hid - 3) % 3) << 8 | 3
                if verify(k, kk, sc, mm, sg if sg is not None else good_sig):
                    problems.append(f"{c.name}: taken with {what}")
    # the same point twice: Q = G, so u1 G + u2 Q adds a point to itself
    for c in curves:
        m = b"generator"
        r, s = c.sign(1, hashlib.sha256(m).digest(), rng)
        count += 1
        if not verify(k, key_struct(c.kt, c.point(c.g)), 0x0403, m, der_sig(r, s)):
            problems.append(f"{c.name}: the key d = 1 (Q = G) refused")
        r, s = c.sign(c.n - 1, hashlib.sha256(m).digest(), rng)
        count += 1
        if not verify(k, key_struct(c.kt, c.point(c.mul(c.n - 1, c.g))), 0x0403, m, der_sig(r, s)):
            problems.append(f"{c.name}: the key d = n - 1 (Q = -G) refused")
    result(not problems, f"ECDSA: {count} cases against the reference (n - s, off by one, 0 and n, "
           "off-curve and wrong-curve keys, bad DER, Q = G and -G)" +
           ("" if not problems else ": " + "; ".join(problems[:5])))


def parse_sig(sig):
    """(r, s) from a DER signature, or None unless it is strict DER."""
    if len(sig) < 8 or sig[0] != 0x30 or sig[1] != len(sig) - 2:
        return None
    out, i = [], 2
    for _ in range(2):
        if sig[i] != 2 or i + 2 + sig[i + 1] > len(sig):
            return None
        n, body = sig[i + 1], sig[i + 2:i + 2 + sig[i + 1]]
        if not n or body[0] & 0x80 or (n > 1 and body[0] == 0 and not body[1] & 0x80):
            return None
        out.append(int.from_bytes(body, "big"))
        i += 2 + n
    return tuple(out) if i == len(sig) else None


def ref_verify(c, q, h, r, s):
    if not (0 < r < c.n and 0 < s < c.n):
        return False
    w = pow(s, -1, c.n)
    pt = c.add(c.mul(c.e(h) * w % c.n, c.g), c.mul(r * w % c.n, q))
    return pt is not None and pt[0] % c.n == r


def sign(k, d, msg):
    out, m = buf(80), buf(msg)
    n, cf = k("sig_sign", out, buf(d.to_bytes(32, "big")), m, len(msg))
    return None if cf else out.raw[:n]


def public(k, d, size=32):
    out = buf(65)
    _, cf = k("ec_public", out, buf(d.to_bytes(size, "big")))
    return None if cf else out.raw


def test_sign(k, rng, keys, curves, tmp):
    c = curves[0]
    problems = []
    count = 0
    # RFC 6979 A.2.5's P-256 key and its public key
    d = 0xC9AFA9D845BA75166B5C215767B1D6934E50C3DB36E89B127B8A622B120F6721
    want = bytes.fromhex("04" "60FED4BA255A9D31C961EB74C6356D68C049B8923B61FA6CE669622E60F29FB6"
                         "7903FE1008B8BC99A41AE9E95628BC64F2F1B20C2D7E9F5177A3C294D4462299")
    count += 1
    if public(k, d) != want:
        problems.append("RFC 6979's key gives the wrong public key")
    for d in [1, 2, 3, c.n - 1, c.n - 2, 2 ** 255, 2 ** 128 + 1] + [rng.randrange(1, c.n) for _ in range(40)]:
        count += 1
        if public(k, d) != c.point(c.mul(d, c.g)):
            problems.append(f"ec_public({d:#x}) is wrong")
    for d in (0, c.n, c.n + 1, 2 ** 256 - 1):
        count += 1
        if public(k, d) is not None:
            problems.append(f"ec_public takes the key {d:#x}")
    result(not problems, f"ec_public: {count} keys (RFC 6979's, 1, 2, n - 1, random) give the "
           "reference's point, and 0, n and above are refused" +
           ("" if not problems else ": " + "; ".join(problems[:5])))

    problems = []
    count = 0
    sigs = set()
    for i in range(60):
        d = rng.choice([1, c.n - 1, rng.randrange(1, c.n)]) if i < 6 else rng.randrange(1, c.n)
        q = c.mul(d, c.g)
        m = rng.randbytes(rng.randrange(0, 600))
        sig = sign(k, d, m)
        count += 1
        if sig is None:
            problems.append(f"no signature for the key {d:#x}")
            continue
        rs = parse_sig(sig)
        if rs is None or der_sig(*rs) != sig:
            problems.append(f"not strict DER: {sig.hex()}")
            continue
        sigs.add(sig)
        if not ref_verify(c, q, hashlib.sha256(m).digest(), *rs):
            problems.append(f"the reference refuses a signature by {d:#x}")
        if not verify(k, key_struct(c.kt, c.point(q)), 0x0403, m, sig):
            problems.append(f"sig_verify refuses a signature by {d:#x}")
        if verify(k, key_struct(c.kt, c.point(q)), 0x0403, m + b"!", sig):
            problems.append("a signature verifies for another message")
    d = rng.randrange(1, c.n)
    again = {sign(k, d, b"the same message") for _ in range(8)}
    count += 1
    if len(again) != 8:
        problems.append("signing the same message twice gave the same signature (the nonce repeats)")
    for d in (0, c.n, 2 ** 256 - 1):
        count += 1
        if sign(k, d, b"x") is not None:
            problems.append(f"sig_sign takes the key {d:#x}")
    f, _, info = keys["p256"]
    ossl("pkey", "-inform", "DER", "-in", f, "-pubout", "-out", tmp / "pub256.pem")
    for i in range(4):
        m = rng.randbytes(100 + i)
        (tmp / "smsg").write_bytes(m)
        sig = sign(k, info["d"], m) or b""
        (tmp / "ssig").write_bytes(sig)
        out = ossl("dgst", "-sha256", "-verify", tmp / "pub256.pem", "-signature", tmp / "ssig",
                   tmp / "smsg", check=False)
        count += 1
        if "Verified OK" not in out:
            problems.append(f"openssl refuses a signature: {out[:60]}")
    result(not problems, f"sig_sign: {count} cases: P-256 SHA-256 signatures in strict DER that "
           "the reference, sig_verify and the openssl tool take, a fresh nonce each time, bad keys "
           "refused" + ("" if not problems else ": " + "; ".join(problems[:5])))


# ---- certificates ----------------------------------------------------------------------------

EXTS = """\
[ca]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
[ca0]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
[notca]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyCertSign
[noku]
basicConstraints = critical, CA:TRUE
keyUsage = critical, digitalSignature
[leaf]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = DNS:axiom.test, DNS:*.wild.axiom.test, IP:10.0.2.2
certificatePolicies = 2.23.140.1.2.1
[client]
extendedKeyUsage = clientAuth
subjectAltName = DNS:axiom.test
[kenc]
keyUsage = critical, keyEncipherment
subjectAltName = DNS:axiom.test
[crit]
subjectAltName = DNS:axiom.test
1.3.6.1.4.1.55555.1 = critical, DER:05:00
[noncrit]
subjectAltName = DNS:axiom.test
1.3.6.1.4.1.55555.1 = DER:05:00
[nosan]
basicConstraints = CA:FALSE
[plain]
subjectAltName = DNS:axiom.test
"""


class Pki:
    """Test CAs and certificates, made with the openssl tool."""

    def __init__(self, d):
        self.d = d
        d.mkdir(parents=True, exist_ok=True)
        (d / "ext.cnf").write_text(EXTS)
        self.serial = 1
        done = d / "done"
        self.fresh = not done.exists()
        if self.fresh:
            self.build()
            done.write_text("ok\n")

    def key(self, name, kind):
        f = self.d / f"{name}.key"
        if kind.startswith("rsa"):
            ossl("genpkey", "-algorithm", "RSA", "-pkeyopt", f"rsa_keygen_bits:{kind[3:]}", "-out", f)
        else:
            ossl("genpkey", "-algorithm", "EC", "-pkeyopt", f"ec_paramgen_curve:{kind}", "-out", f)

    def cert(self, name, kind, cn, issuer, ext, md="sha256", days=3650):
        self.key(name, kind)
        d = self.d
        ossl("req", "-new", "-key", d / f"{name}.key", "-subj", f"/CN={cn}", "-out", d / f"{name}.csr")
        sign = (["-signkey", d / f"{name}.key"] if issuer is None else
                ["-CA", d / f"{issuer}.pem", "-CAkey", d / f"{issuer}.key"])
        self.serial += 1
        ossl("x509", "-req", "-in", d / f"{name}.csr", *sign, "-set_serial", str(self.serial),
             "-days", str(days), f"-{md}", "-extfile", d / "ext.cnf", "-extensions", ext,
             "-out", d / f"{name}.pem")

    def build(self):
        c = self.cert
        c("rootR", "rsa2048", "Axiom Test Root R", None, "ca")
        c("rootE", "P-384", "Axiom Test Root E", None, "ca", md="sha384")
        c("interR", "P-256", "Axiom Test Inter R", "rootR", "ca")
        c("interE", "rsa3072", "Axiom Test Inter E", "rootE", "ca", md="sha384")
        c("leafRsa", "rsa2048", "axiom.test", "interR", "leaf")
        c("leafP256", "P-256", "axiom.test", "interE", "leaf", md="sha512")
        c("leafP384", "P-384", "axiom.test", "rootE", "leaf", md="sha384")
        c("leaf4096", "rsa4096", "axiom.test", "interR", "leaf", md="sha384")
        c("client", "P-256", "axiom.test", "interR", "client")
        c("kenc", "rsa2048", "axiom.test", "interR", "kenc")
        c("crit", "P-256", "axiom.test", "interR", "crit")
        c("noncrit", "P-256", "axiom.test", "interR", "noncrit")
        c("nosan", "P-256", "axiom.test", "interR", "nosan")
        c("interN", "P-256", "Axiom Test Not A CA", "rootR", "notca")
        c("leafN", "P-256", "axiom.test", "interN", "leaf")
        c("interK", "P-256", "Axiom Test No keyCertSign", "rootR", "noku")
        c("leafK", "P-256", "axiom.test", "interK", "leaf")
        c("interP0", "P-256", "Axiom Test Pathlen 0", "rootR", "ca0")
        c("interP1", "P-256", "Axiom Test Under Pathlen 0", "interP0", "ca")
        c("leafP", "P-256", "axiom.test", "interP1", "leaf")
        c("leafP0", "P-256", "axiom.test", "interP0", "leaf")
        c("sha1", "P-256", "axiom.test", "interR", "leaf", md="sha1")
        c("weak", "rsa1024", "axiom.test", "interR", "leaf")
        c("rootX", "P-256", "Axiom Untrusted Root", None, "ca")
        c("leafX", "P-256", "axiom.test", "rootX", "leaf")
        c("self", "P-256", "axiom.test", None, "leaf")
        c("interR2", "P-256", "Axiom Test Inter R", "rootR", "ca")    # same name, another key

    def der(self, name):
        pem = (self.d / f"{name}.pem").read_text()
        return next(mkroots.pem_certs(pem))

    def dates(self, name):
        info = ossl("x509", "-in", self.d / f"{name}.pem", "-noout", "-startdate", "-enddate")
        t = {}
        for line in info.splitlines():
            k, v = line.split("=", 1)
            t[k] = calendar.timegm(time.strptime(v.replace(" GMT", ""), "%b %d %H:%M:%S %Y"))
        return t["notBefore"], t["notAfter"]


def chain(k, ders, host, now):
    bufs = [buf(d) for d in ders]
    lst = (ctypes.c_uint64 * (2 * max(1, len(ders))))()
    for i, b in enumerate(bufs):
        lst[2 * i] = ctypes.addressof(b)
        lst[2 * i + 1] = len(ders[i])
    hb = buf(host.encode() + b"\0") if host is not None else None
    r, cf = k("x509_chain", 0, lst, hb if hb is not None else 0, len(ders), now)
    code = (r & 0xFFFFFFFF) if cf else 0
    anchor = k.d.h_anchor() if not cf else None
    return code, (anchor.decode() if anchor else None), k.d.h_depth()


def test_x509(k, rng, tmp):
    pki = Pki(tmp / "pki")
    D = pki.der
    extra = buf(mkroots.table([mkroots.parse(D("rootR")), mkroots.parse(D("rootE"))]))
    k.d.h_set_extra(ctypes.addressof(extra))
    nb, na = pki.dates("leafRsa")
    now = int(time.time())
    problems = []
    cases = [
        ("an RSA leaf, P-256 intermediate, RSA root", ["leafRsa", "interR"], "axiom.test", "OK"),
        ("a P-256 leaf, RSA-3072 intermediate signed with P-384", ["leafP256", "interE"], "axiom.test", "OK"),
        ("a P-384 leaf straight from the root", ["leafP384"], "axiom.test", "OK"),
        ("an RSA-4096 leaf, signed with SHA-384 on P-256", ["leaf4096", "interR"], "axiom.test", "OK"),
        ("the root sent too", ["leafRsa", "interR", "rootR"], "axiom.test", "OK"),
        ("out of order, with strangers", ["leafRsa", "rootX", "leafP384", "interR"], "axiom.test", "OK"),
        ("an intermediate by the same name with another key first",
         ["leafRsa", "interR2", "interR"], "axiom.test", "OK"),
        ("the wildcard", ["leafRsa", "interR"], "a.wild.axiom.test", "OK"),
        ("the wildcard, in capitals, with the root's dot", ["leafRsa", "interR"], "Q.WILD.Axiom.Test.", "OK"),
        ("the wildcard is one label only", ["leafRsa", "interR"], "a.b.wild.axiom.test", "NAME"),
        ("the wildcard needs a label", ["leafRsa", "interR"], "wild.axiom.test", "NAME"),
        ("the IP address", ["leafRsa", "interR"], "10.0.2.2", "OK"),
        ("another IP address", ["leafRsa", "interR"], "10.0.2.3", "NAME"),
        ("another name", ["leafRsa", "interR"], "example.com", "NAME"),
        ("a longer name", ["leafRsa", "interR"], "axiom.test.evil", "NAME"),
        ("no name at all", ["leafRsa", "interR"], None, "NAME"),
        ("no subjectAltName (only a CN)", ["nosan", "interR"], "axiom.test", "NAME"),
        ("the intermediate missing", ["leafRsa"], "axiom.test", "ISSUER"),
        ("an untrusted root", ["leafX", "rootX"], "axiom.test", "ISSUER"),
        ("self-signed", ["self"], "axiom.test", "ISSUER"),
        ("for clients only", ["client", "interR"], "axiom.test", "PURPOSE"),
        ("keyUsage without digitalSignature", ["kenc", "interR"], "axiom.test", "PURPOSE"),
        ("an unknown critical extension", ["crit", "interR"], "axiom.test", "CRITICAL"),
        ("an unknown extension, not critical", ["noncrit", "interR"], "axiom.test", "OK"),
        ("signed by a certificate that is not a CA", ["leafN", "interN"], "axiom.test", "NOTCA"),
        ("signed by a CA without keyCertSign", ["leafK", "interK"], "axiom.test", "NOTCA"),
        ("one intermediate under pathLen 0", ["leafP", "interP1", "interP0"], "axiom.test", "PATHLEN"),
        ("straight under pathLen 0", ["leafP0", "interP0"], "axiom.test", "OK"),
        ("signed with SHA-1", ["sha1", "interR"], "axiom.test", "ALGORITHM"),
        ("an RSA-1024 key", ["weak", "interR"], "axiom.test", "KEY"),
    ]
    for label, names, host, want in cases:
        code, anchor, depth = chain(k, [D(n) for n in names], host, now)
        ok = X5E[code] == want
        if ok and want == "OK" and anchor not in ("Axiom Test Root R", "Axiom Test Root E"):
            ok = False
        if not ok:
            problems.append(f"{label}: {X5E[code]} (anchor {anchor}), want {want}")
    leaf, inter = D("leafRsa"), D("interR")
    t = bytearray(leaf)
    t[-10] ^= 1
    more = [("a flipped bit in the leaf's signature", [bytes(t), inter], now, "SIGNATURE"),
            ("a flipped bit in what the leaf signs", [leaf[:200] + bytes([leaf[200] ^ 4]) + leaf[201:], inter],
             now, "SIGNATURE"),
            ("cut short", [leaf[:-1], inter], now, "MALFORMED"),
            ("a byte after it", [leaf + b"\0", inter], now, "MALFORMED"),
            ("garbage", [rng.randbytes(500), inter], now, "MALFORMED"),
            ("nothing", [b"", inter], now, "MALFORMED"),
            ("expired, two days ago", [leaf, inter], na + 2 * 86400, "EXPIRED"),
            ("expired only twelve hours ago", [leaf, inter], na + 12 * 3600, "OK"),
            ("valid in two days", [leaf, inter], nb - 2 * 86400, "NOTYET"),
            ("valid in twelve hours", [leaf, inter], nb - 12 * 3600, "OK"),
            ("the clock in 2024", [leaf, inter], 1717200000, "CLOCK")]
    for label, ders, when, want in more:
        code, anchor, depth = chain(k, ders, "axiom.test", when)
        if X5E[code] != want:
            problems.append(f"{label}: {X5E[code]}, want {want}")
    code, anchor, depth = chain(k, [leaf, inter], "axiom.test", now)
    key = ctypes.create_string_buffer(24)
    k.d.h_key(key)
    kt, kl, ke, kp = struct.unpack("<IIQQ", key.raw)
    want_key = mkroots.parse(leaf)
    got = ctypes.string_at(kp, kl) if kp else b""
    if (kt, got, ke) != (KT_RSA, want_key["key"], want_key["e"]) or depth != 1:
        problems.append(f"x509_key or x509_depth wrong after a good chain (type {kt}, depth {depth})")
    r, cf = k("x509_leaf", 0, buf(D("leafP384")), 0, len(D("leafP384")))
    k.d.h_key(key)
    kt, kl, ke, kp = struct.unpack("<IIQQ", key.raw)
    if cf or kt != KT_P384 or ctypes.string_at(kp, kl) != mkroots.parse(D("leafP384"))["key"]:
        problems.append("x509_leaf did not give the P-384 key")
    # random damage: never a crash, never accepted
    damaged = 0
    for i in range(400):
        b = bytearray(leaf)
        for _ in range(rng.choice([1, 1, 2, 8])):
            b[rng.randrange(len(b))] = rng.randrange(256)
        if bytes(b) == leaf:
            continue
        code, _, _ = chain(k, [bytes(b), inter], "axiom.test", now)
        if code == 0:
            damaged += 1
    if damaged:
        problems.append(f"{damaged} randomly damaged leaves accepted")
    result(not problems, f"X.509: {len(cases) + len(more) + 2} chains the openssl tool signed, good "
           "and bad, and 400 damaged ones" + ("" if not problems else ":\n      " + "\n      ".join(problems)))
    k.d.h_set_extra(None)
    return pki, extra


def test_unix(k, rng):
    bad = 0
    for _ in range(3000):
        t = rng.randrange(0, 7258118400)           # 1970-2200
        g = time.gmtime(t)
        r, _ = k("x509_unix", g.tm_year, g.tm_mon, g.tm_mday, g.tm_hour, g.tm_min, g.tm_sec)
        if r != t:
            bad += 1
    result(bad == 0, f"x509_unix against Python for 3000 times from 1970 to 2200: {bad} wrong")


def test_roots(k):
    """The table in the kernel is the one mkroots.py makes from certifi."""
    try:
        import certifi
    except ImportError:
        result(True, "built-in roots: certifi not installed, not compared")
        return
    infos = [i for i in map(mkroots.parse, mkroots.pem_certs(pathlib.Path(certifi.where()).read_text()))
             if i["type"]]
    want = mkroots.table(infos)
    got = ctypes.string_at(k.d.h_roots(), len(want))
    result(got == want, f"built-in roots: {len(infos)} from certifi {certifi.__version__}, the same "
           "bytes as gen/roots.asm" + ("" if got == want else " -- NOT; run tools/mkroots.py"))


SITES = ["example.com", "www.google.com", "github.com", "www.cloudflare.com", "en.wikipedia.org",
         "www.amazon.com", "www.microsoft.com", "www.apple.com", "www.mozilla.org", "letsencrypt.org",
         "www.python.org", "www.nasa.gov", "www.bbc.co.uk", "stackoverflow.com", "www.reddit.com",
         "www.digicert.com", "www.sectigo.com", "www.globalsign.com", "www.ssl.com", "www.nytimes.com"]


def test_live(k, sites):
    ctx = ssl.create_default_context()
    ok = bad = skipped = 0
    for host in sites:
        try:
            with socket.create_connection((host, 443), timeout=8) as s:
                with ctx.wrap_socket(s, server_hostname=host) as t:
                    ders = t.get_unverified_chain()
                    proto = t.version()
        except OSError as e:
            skipped += 1
            print(f"      {host}: not reached ({e.__class__.__name__})")
            continue
        code, anchor, depth = chain(k, ders, host, int(time.time()))
        kinds = []
        for d in ders[:3]:
            info = mkroots.parse(d)
            kinds.append({KT_RSA: f"RSA-{len(info['key']) * 8}", KT_P256: "P-256",
                          KT_P384: "P-384"}.get(info["type"], "?"))
        line = f"      {host}: {len(ders)} sent ({', '.join(kinds)}), {proto}: "
        if code == 0:
            ok += 1
            print(line + f"verified, {depth} intermediate(s), root {anchor}")
        else:
            bad += 1
            print(line + f"{X5E[code]}: {k.d.h_error_text(code).decode()}")
        wrong, _, _ = chain(k, ders, host + ".invalid", int(time.time()))
        if X5E[wrong] != "NAME":
            bad += 1
            print(f"      {host}: under another name {X5E[wrong]}, want NAME")
    result(bad == 0 and ok > 0, f"real servers' chains against the built-in roots: {ok} verified, "
           f"{bad} wrong, {skipped} not reached")


def test_regs(k, keys, curves, pki, extra):
    problems = []
    info = keys["rsa2048"][2]
    rk = rsa_key(info)
    m = buf(b"registers")
    rs = buf(rsa_sign_pss(info, b"registers", 4, random.Random(1)))
    c = curves[1]
    d = 12345678901234567890
    ek = key_struct(c.kt, c.point(c.mul(d, c.g)))
    r, s = c.sign(d, hashlib.sha384(b"registers").digest(), random.Random(2))
    es = buf(der_sig(r, s))
    k.d.h_set_extra(ctypes.addressof(extra))
    leaf, inter = pki.der("leafRsa"), pki.der("interR")
    lb, ib = buf(leaf), buf(inter)
    lst = (ctypes.c_uint64 * 4)(ctypes.addressof(lb), len(leaf), ctypes.addressof(ib), len(inter))
    host = buf(b"axiom.test\0")
    ctx = buf(MONT_CTX)
    k("mont_setup", ctx, buf(info["n"].to_bytes(256, "big")), 0, 256)
    a = limbs(5, 32)
    sk = buf((98765432109876543210).to_bytes(32, "big"))
    calls = [("sig_verify RSA-PSS", "sig_verify", (rk[0], 0x0804, m, 9, rs, 256), 0),
             ("sig_sign", "sig_sign", (buf(80), sk, m, 9), 0),
             ("ec_public", "ec_public", (buf(65), sk), 0),
             ("sig_verify ECDSA P-384", "sig_verify", (ek[0], 0x0503, m, 9, es, len(es.raw)), 0),
             ("x509_chain", "x509_chain", (0, lst, host, 2, int(time.time())), 0),
             ("mont_exp", "mont_exp", (a, a, limbs(65537, 1), ctx, 1), None),
             ("sha512", "sha512", (buf(64), m, 9), None)]
    for label, fn, args, want_cf in calls:
        before, after, cf = k.regs(fn, *args)
        changed = [n for i, n in enumerate("rax rcx rdx rbx rsp rbp rsi rdi r8 r9 r10 r11 r12 r13 r14 r15".split())
                   if i and before[i] != after[i]]
        if changed:
            problems.append(f"{label} changed {', '.join(changed)}")
        if want_cf is not None and cf != want_cf:
            problems.append(f"{label}: CF {cf}")
    k.d.h_set_extra(None)
    result(not problems, "registers: everything but RAX kept (" + ", ".join(c[0] for c in calls) + ")" +
           ("" if not problems else ": " + "; ".join(problems)))


def test_speed(k, keys, curves, pki, extra):
    rng = random.Random(3)
    out = []

    def rate(label, f, n):
        f()
        t = time.perf_counter()
        for _ in range(n):
            f()
        dt = (time.perf_counter() - t) / n
        out.append(f"{label} {dt * 1e6:.0f} us")

    for name in ("rsa2048", "rsa4096"):
        info = keys[name][2]
        key = rsa_key(info)
        sig = rsa_sign_pss(info, b"speed", 4, rng)
        rate(f"{name[3:]}-bit RSA", lambda: verify(k, key, 0x0804, b"speed", sig), 50)
    for c in curves:
        d = rng.randrange(1, c.n)
        key = key_struct(c.kt, c.point(c.mul(d, c.g)))
        sig = der_sig(*c.sign(d, hashlib.sha256(b"speed").digest(), rng))
        rate(c.name, lambda: verify(k, key, 0x0403, b"speed", sig), 50)
    d = rng.randrange(1, curves[0].n)
    rate("signing, P-256", lambda: sign(k, d, b"speed"), 50)
    k.d.h_set_extra(ctypes.addressof(extra))
    ders = [pki.der("leafRsa"), pki.der("interR")]
    now = int(time.time())
    rate("a chain of two", lambda: chain(k, ders, "axiom.test", now), 30)
    k.d.h_set_extra(None)
    result(True, "speed, one verification (or signature): " + ", ".join(out))


def main():
    global OSSL
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=5280)
    ap.add_argument("--cc", default=os.environ.get("CC", GCC))
    ap.add_argument("--offline", action="store_true", help="skip the real servers")
    opts = ap.parse_args()
    sys.stdout.reconfigure(line_buffering=True)
    OSSL = find_openssl()
    nasm = shutil.which("nasm")
    if not nasm:
        sys.exit("nasm not found on PATH")
    cc = opts.cc if os.path.exists(opts.cc) else shutil.which(opts.cc)
    if not cc:
        sys.exit(f"compiler not found: {opts.cc}")
    OUT.mkdir(parents=True, exist_ok=True)
    kinc = str(ROOT / "src" / "kernel") + os.sep
    stub = OUT / "kernel_like.asm"
    stub.write_text("bits 64\ndefault rel\norg 0xFFFFFFFF80000000\n"
                    "section .text progbits align=16\n"
                    "section .rodata progbits align=64 follows=.text\n"
                    "section .data progbits align=64 follows=.rodata\n"
                    "section .bss nobits align=64\nsection .text\n%include \"macros.inc\"\n" +
                    "".join(f'%include "{m}"\n' for m in MODULES) +
                    "".join(f"{name}:\n" for name in RUST) + "    ret\n")   # (the Rust: not here)
    run([nasm, "-f", "bin", "-w-reloc-abs-qword", "-w-reloc-abs-dword", "-w-reloc-rel-dword",
         "-I", kinc, "-o", OUT / "kernel_like.bin", stub], "nasm -f bin (kernel layout)")
    print("kernel layout: " + ", ".join(MODULES) + " assemble")
    obj = OUT / "shim.obj"
    dll = OUT / "pki.dll"
    run([nasm, "-f", "win64", "-I", kinc, "-I", str(HERE.parent) + os.sep, "-o", obj,
         HERE / "shim.asm"], "nasm -f win64")
    run([cc, "-O2", "-Wall", "-Wextra", "-shared", "-static", "-o", dll, HERE / "host.c", obj], "gcc")
    print(f"references: Python {sys.version.split()[0]}, {ossl('version')}")
    k = Kernel(dll)
    rusthost.forward(rusthost.build(OUT), k.d, RUST)
    rng = random.Random(opts.seed)
    tmp = OUT / "work"
    tmp.mkdir(exist_ok=True)
    keys = make_keys(OUT / "keys")

    print("-- hashes and arithmetic")
    test_sha(k, rng)
    curves = test_bignum(k, rng)
    print("-- signatures")
    test_rsa(k, rng, keys, tmp)
    test_ecdsa(k, rng, keys, curves, tmp)
    test_sign(k, rng, keys, curves, tmp)
    print("-- certificates")
    test_unix(k, rng)
    pki, extra = test_x509(k, rng, OUT)
    test_roots(k)
    if not opts.offline:
        test_live(k, SITES)
    print("-- registers and speed")
    test_regs(k, keys, curves, pki, extra)
    test_speed(k, keys, curves, pki, extra)
    print(f"-- {passes} passed, {fails} failed")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
