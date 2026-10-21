#!/usr/bin/env python3
"""What of the kernel's x509.asm is in Rust now (src/rust/src/x509.rs),
held against the assembly it was (tools/test/x509/reference.asm).

    python tools/test/x509/run.py [--seed N] [--cases N] [--cc PATH]

First cargo's own tests of the Rust. Then the Rust, built for the host as a
DLL, called through x509.asm's wrappers (a DLL of NASM's, -f win64, with
gcc), and the assembly, in a DLL of its own, on the same cases:

  - x509_parse on the certificates in Windows' ROOT and CA stores; on
    --cases certificates made here, field by field, each part well formed
    or not (versions, serials, signature algorithms with and without NULL
    parameters, names, UTCTime and GeneralizedTime at their edges, RSA and
    EC keys of every size and shape, unique IDs, the extensions x509.asm
    reads and others, critical or not); and on --cases of either changed
    (bytes flipped, cut short, lengths made long-form, too long or too
    short). The answer (CF, EAX), the CERT (128 bytes, pointers into the
    same DER) and every register but RAX kept, must be the same;
  - x509_unix on dates near the ones certificates have and on any 32-bit
    numbers at all, the registers' upper halves set;
  - x5_name on the certificates made here, with hosts made from their
    names (the same, in other cases, a wildcard's label, a trailing dot,
    IPv4 addresses, near misses, 254 and 255 bytes long, empty, none): the
    same CF, EAX where it fails, and RBX, RBP, RDI, R12-R15 kept.
"""
import argparse
import ctypes
import os
import pathlib
import random
import shutil
import ssl
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
HERE = pathlib.Path(__file__).resolve().parent
OUT = ROOT / "build" / "test" / "x509"
RUST = ROOT / "src" / "rust"
sys.path.insert(0, str(HERE.parent))
import rusthost  # noqa: E402

GCC = str(pathlib.Path(os.environ.get("LOCALAPPDATA", "")) / "Microsoft" / "WinGet" / "Packages" /
          "BrechtSanders.WinLibs.POSIX.UCRT_Microsoft.Winget.Source_8wekyb3d8bbwe" /
          "mingw64" / "bin" / "gcc.exe")      # WinLibs' gcc, as winget puts it; else --cc or CC
CERT = 128
KEPT_BY_NAME = 0b11110000001011         # RBX RBP RDI R12-R15: what x5_name keeps

failures = []
passed = 0


def result(ok, text, quiet=False):
    global passed
    if ok:
        passed += 1
        if not quiet:
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
        self.at = {name: ctypes.cast(getattr(self.dll, name), ctypes.c_void_p).value
                   for name in ("x509_parse", "x509_unix", "name_check")}

    def call(self, name, rdi=0, rsi=0, rdx=0, rcx=0, r8=0, r9=0, rax=0):
        """-> RAX, CF, the mask of registers changed"""
        a = self.a
        a[0], a[1], a[2], a[3], a[4], a[5], a[8] = rdi, rsi, rdx, rcx, r8, r9, rax
        a[6], a[7] = 0x5A5A5A5A5A5A5A5A, 0x5B5B5B5B5B5B5B5B
        self.dll.kc(self.at[name], a, self.out)
        return self.out[0], self.out[1] & 1, self.out[2]


# -- DER, made ----------------------------------------------------------------

def tlv(tag, body, form=None):
    """A TLV; form 'long' writes a short length the long way, as der_tlv
    takes it."""
    n = len(body)
    if form == "long" and n < 0x100:
        length = bytes([0x81, n])
    elif n < 0x80:
        length = bytes([n])
    elif n < 0x100:
        length = bytes([0x81, n])
    elif n < 0x10000:
        length = bytes([0x82]) + n.to_bytes(2, "big")
    else:
        length = bytes([0x83]) + n.to_bytes(3, "big")
    return bytes([tag]) + length + body


def seq(*parts):
    return tlv(0x30, b"".join(parts))


def oid(dotted):
    nums = [int(x) for x in dotted.split(".")]
    out = bytearray([nums[0] * 40 + nums[1]])
    for n in nums[2:]:
        chunk = [n & 0x7F]
        n >>= 7
        while n:
            chunk.append(0x80 | (n & 0x7F))
            n >>= 7
        out += bytes(reversed(chunk))
    return tlv(6, bytes(out))


SIG_ALGS = ["1.2.840.113549.1.1.11", "1.2.840.113549.1.1.12", "1.2.840.113549.1.1.13",
            "1.2.840.10045.4.3.2", "1.2.840.10045.4.3.3", "1.2.840.10045.4.3.4",
            "1.2.840.113549.1.1.5", "1.2.840.113549.1.1.10", "1.3.101.112"]
LABELS = ["example", "axiom", "test", "www", "a", "b-c", "xn--bcher-kva", "Mail", "API", "x1"]


def sig_alg(rng):
    o = oid(rng.choice(SIG_ALGS))
    r = rng.random()
    params = b"" if r < 0.45 else b"\x05\x00" if r < 0.9 else rng.choice([b"\x05\x01\x00", b"\x04\x00",
                                                                          b"\x05\x00\x05\x00"])
    return seq(o, params)


def name(rng):
    rdns = []
    for _ in range(rng.choice([0, 1, 2, 3])):
        attr = rng.choice(["2.5.4.3", "2.5.4.10", "2.5.4.6", "2.5.4.11"])
        value = rng.choice(LABELS).encode()
        rdns.append(tlv(0x31, seq(oid(attr), tlv(rng.choice([0x0C, 0x13]), value))))
    return seq(*rdns)


def a_time(rng):
    year = rng.choice([1950, 1999, 2000, 2025, 2049, 2050, 2100, 9999, 0, 1970,
                       rng.randrange(1950, 2050)])
    parts = [rng.randrange(1, 13), rng.randrange(1, 32), rng.randrange(24), rng.randrange(60),
             rng.randrange(61)]
    if rng.random() < 0.15:
        i = rng.randrange(5)
        parts[i] = rng.choice([0, 13, 32, 24, 60, 61, 99])
    body = "".join(f"{p:02d}" for p in parts) + "Z"
    if rng.random() < 0.5 and 1950 <= year < 2050:
        text, tag = f"{year % 100:02d}" + body, 0x17
    else:
        text, tag = f"{year:04d}" + body, 0x18
    t = text.encode()
    if rng.random() < 0.06:
        t = t[:-1] + rng.choice([b"+", b"z", b"0"])
    if rng.random() < 0.06:
        i = rng.randrange(len(t))
        t = t[:i] + rng.choice([b"a", b" ", b"/", b":"]) + t[i + 1:]
    if rng.random() < 0.04:
        t = t[:-1] if rng.random() < 0.5 else t + b"0"
    if rng.random() < 0.03:
        tag = rng.choice([0x17, 0x18, 0x04])
    return tlv(tag, t)


def integer(value_bytes):
    return tlv(2, value_bytes)


def spki(rng):
    r = rng.random()
    if r < 0.4:                                                     # RSA
        bits = rng.choice([1024, 2040, 2048, 3072, 4096, 4104, 8192, 2048, 2048])
        n = bytearray(rng.randbytes(bits // 8))
        n[0] |= 0x80
        lead = rng.choice([b"\x00", b"\x00", b"", b"\x00\x00\x00"])
        if rng.random() < 0.05:
            n = bytearray(len(n))
        e = rng.choice([b"\x01\x00\x01", b"\x03", b"\x81", b"\x00\x81", b"\x01" * 8, b"\x01" * 9, b""])
        inner = seq(integer(lead + bytes(n)), integer(e))
        if rng.random() < 0.05:
            inner = seq(integer(lead + bytes(n)), integer(e), integer(b"\x01"))
        if rng.random() < 0.05:
            inner = seq(integer(lead + bytes(n)))
        if rng.random() < 0.03:
            inner += b"\x00"
        alg = seq(oid("1.2.840.113549.1.1.1"), b"\x05\x00" if rng.random() < 0.9 else b"")
        key = inner
    elif r < 0.85:                                                  # EC
        curve = rng.choice(["1.2.840.10045.3.1.7", "1.3.132.0.34", "1.3.132.0.35", None])
        size = {"1.2.840.10045.3.1.7": 65, "1.3.132.0.34": 97}.get(curve, 133)
        if rng.random() < 0.1:
            size += rng.choice([-1, 1, -32])
        point = bytes([rng.choice([4, 4, 4, 2])]) + rng.randbytes(max(size - 1, 0))
        params = oid(curve) if curve else rng.choice([b"\x05\x00", b"", seq()])
        alg = seq(oid("1.2.840.10045.2.1"), params)
        key = point
    else:                                                           # another
        alg = seq(oid(rng.choice(["1.3.101.112", "1.2.840.10040.4.1"])))
        key = rng.randbytes(32)
    unused = b"\x00" if rng.random() < 0.95 else b"\x01"
    bits = tlv(3, unused + key) if rng.random() < 0.97 else tlv(3, b"")
    return seq(alg, bits)


def san(rng):
    names = []
    for _ in range(rng.choice([0, 1, 2, 3, 5])):
        r = rng.random()
        if r < 0.6:
            labels = [rng.choice(LABELS) for _ in range(rng.choice([1, 2, 3]))]
            if rng.random() < 0.35:
                labels = ["*"] + labels
            names.append(tlv(0x82, ".".join(labels).encode()))
        elif r < 0.85:
            names.append(tlv(0x87, bytes(rng.choice([[10, 0, 2, 2], [127, 0, 0, 1],
                                                      [rng.randrange(256) for _ in range(4)]]))))
        elif r < 0.92:
            names.append(tlv(0x87, rng.randbytes(16)))
        else:
            names.append(tlv(0x81, b"someone@example.test"))
    return seq(*names)


def extension(rng):
    critical = rng.random() < 0.3
    r = rng.random()
    if r < 0.15:
        ident = "2.5.29.15"
        value = tlv(3, bytes([rng.randrange(8)]) + rng.randbytes(rng.choice([0, 1, 1, 2])))
    elif r < 0.35:
        ident, value = "2.5.29.17", san(rng)
    elif r < 0.5:
        ident = "2.5.29.19"
        parts = []
        if rng.random() < 0.7:
            parts.append(tlv(1, rng.choice([b"\xff", b"\x00", b"\x01", b"\xff\xff"])))
        if rng.random() < 0.5:
            parts.append(integer(rng.choice([b"\x00", b"\x03", b"\x7f\xff", b"\x00\x00\x00\x01",
                                             b"\x01\x02\x03\x04\x05", b"\x80", b""])))
        value = seq(*parts)
    elif r < 0.65:
        ident = "2.5.29.37"
        value = seq(*[oid(rng.choice(["1.3.6.1.5.5.7.3.1", "1.3.6.1.5.5.7.3.2", "2.5.29.37.0",
                                      "1.3.6.1.5.5.7.3.4"])) for _ in range(rng.choice([0, 1, 2, 3]))])
    elif r < 0.75:
        ident, value = rng.choice(["2.5.29.32", "2.5.29.36", "2.5.29.54"]), seq()
    else:
        ident = rng.choice(["2.5.29.14", "2.5.29.35", "2.5.29.30", "1.3.6.1.5.5.7.1.1", "2.5.29.31"])
        value = seq(tlv(4, rng.randbytes(8)))
    if rng.random() < 0.05:
        value = rng.randbytes(rng.choice([0, 1, 3]))
    flag = b""
    if critical:
        flag = tlv(1, b"\xff")
    elif rng.random() < 0.1:
        flag = tlv(1, rng.choice([b"\x00", b"\x01\x00"]))
    return seq(oid(ident), flag, tlv(4, value))


def certificate(rng):
    alg = sig_alg(rng)
    tbs = []
    if rng.random() < 0.9:
        tbs.append(tlv(0xA0, integer(b"\x02")))
    tbs.append(integer(rng.randbytes(rng.choice([1, 8, 16, 20]))))
    tbs += [alg, name(rng), seq(a_time(rng), a_time(rng)), name(rng), spki(rng)]
    if rng.random() < 0.05:
        tbs.append(tlv(rng.choice([0x81, 0xA1, 0x82, 0xA2]), rng.randbytes(4)))
    if rng.random() < 0.85:
        exts = [extension(rng) for _ in range(rng.choice([0, 1, 2, 3, 5, 8]))]
        tbs.append(tlv(0xA3, seq(*exts)))
    if rng.random() < 0.03:
        tbs.append(tlv(rng.choice([0xA4, 0x04]), b""))
    outer_alg = alg if rng.random() < 0.95 else sig_alg(rng)
    sig = tlv(3, (b"\x00" if rng.random() < 0.97 else b"\x01") + rng.randbytes(rng.choice([64, 72, 256])))
    return seq(seq(*tbs), outer_alg, sig)


def mutate(rng, der):
    b = bytearray(der)
    if len(b) < 2:
        return bytes(b) + rng.randbytes(2)
    r = rng.random()
    if r < 0.3:
        for _ in range(rng.randint(1, 4)):
            b[rng.randrange(len(b))] = rng.randrange(256)
    elif r < 0.45:
        b = b[:rng.randrange(len(b))]
    elif r < 0.6:
        i = rng.randrange(len(b))
        b[i] ^= 1 << rng.randrange(8)
    elif r < 0.75:                                     # a length nudged
        i = rng.randrange(1, len(b))
        if b[i] < 0x80:
            b[i] = (b[i] + rng.choice([-1, 1, 2])) & 0x7F
    elif r < 0.85:                                     # bytes after
        b += rng.randbytes(rng.choice([1, 2, 5]))
    else:                                              # a long length form
        i = rng.randrange(1, len(b))
        b[i:i + 1] = bytes([rng.choice([0x80, 0x84, 0x81, 0x82])]) + bytes([b[i]])
    return bytes(b)


# -- the cases ------------------------------------------------------------------

def parse_once(k, buf, n, cert):
    ctypes.memset(cert, 0xEE, CERT)
    rax, cf, mask = k.call("x509_parse", rdi=ctypes.addressof(cert), rsi=ctypes.addressof(buf),
                           rcx=n | 0xDEAD00000000)
    return cf, rax & 0xFFFFFFFF, cert.raw, mask


def parse_case(ref, new, der, what, cert_a, cert_b):
    buf = ctypes.create_string_buffer(der, len(der) + 16)
    a = parse_once(ref, buf, len(der), cert_a)
    b = parse_once(new, buf, len(der), cert_b)
    if a == b and not a[3]:
        return True
    return result(False, f"x509_parse({what}, {len(der)} bytes {der[:24].hex()}...): assembly "
                         f"CF {a[0]} EAX {a[1]} regs {a[3]:#x}, Rust CF {b[0]} EAX {b[1]} regs {b[3]:#x}"
                         + ("" if a[2] == b[2] else f"; CERTs differ at "
                            f"{[i for i in range(CERT) if a[2][i] != b[2][i]][:8]}"))


def store_certs():
    seen = []
    for store in ("ROOT", "CA"):
        try:
            for der, kind, _ in ssl.enum_certificates(store):
                if kind == "x509_asn" and der not in seen:
                    seen.append(der)
        except (AttributeError, OSError):
            pass
    return seen


def parses(ref, new, rng, cases):
    cert_a = ctypes.create_string_buffer(CERT)
    cert_b = ctypes.create_string_buffer(CERT)
    real = store_certs()
    bad = sum(not parse_case(ref, new, der, "a store's", cert_a, cert_b) for der in real)
    oks = sum(parse_once(ref, ctypes.create_string_buffer(d, len(d)), len(d), cert_a)[0] == 0 for d in real)
    result(bad == 0 and len(real) > 0,
           f"x509_parse on {len(real)} certificates from Windows' stores ({oks} read whole): {bad} differ")
    made = [certificate(rng) for _ in range(cases)]
    bad = sum(not parse_case(ref, new, der, "made", cert_a, cert_b) for der in made)
    oks = sum(parse_once(ref, ctypes.create_string_buffer(d, len(d)), len(d), cert_a)[0] == 0 for d in made)
    result(bad == 0, f"x509_parse on {len(made)} certificates made here ({oks} read whole): {bad} differ")
    pool = real + made
    bad = 0
    for _ in range(cases):
        der = mutate(rng, rng.choice(pool))
        if rng.random() < 0.3:
            der = mutate(rng, der)
        bad += not parse_case(ref, new, der, "changed", cert_a, cert_b)
    result(bad == 0, f"x509_parse on {cases} certificates changed: {bad} differ")
    bad = 0
    for der in [b"", b"\x30", b"\x30\x00", b"\x30\x80", b"\x30\x84\x00\x00\x00\x00", b"\x1f\x00",
                seq(), seq(seq()), seq(seq(), seq(), tlv(3, b"\x00"))]:
        bad += not parse_case(ref, new, der, "written", cert_a, cert_b)
    result(bad == 0, f"x509_parse on bits of DER: {bad} differ")
    return made


def unixes(ref, new, rng):
    bad = 0
    count = 0
    for _ in range(60000):
        if rng.random() < 0.7:
            args = [rng.randrange(1900, 2200), rng.randrange(0, 14), rng.randrange(0, 33),
                    rng.randrange(0, 25), rng.randrange(0, 61), rng.randrange(0, 61)]
        else:
            args = [rng.choice([0, 1, 2, 3, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, rng.getrandbits(32)])
                    for _ in range(6)]
        high = [rng.getrandbits(32) << 32 for _ in range(6)]
        regs = dict(zip(["rdi", "rsi", "rdx", "rcx", "r8", "r9"], [a | h for a, h in zip(args, high)]))
        a, b = ref.call("x509_unix", **regs), new.call("x509_unix", **regs)
        count += 1
        if a[0] != b[0] or a[2] or b[2]:                # (its flags say nothing)
            bad += 1
            if bad <= 5:
                result(False, f"x509_unix{tuple(args)}: assembly {a[0]} regs {a[2]:#x}, "
                              f"Rust {b[0]} regs {b[2]:#x}")
    result(bad == 0, f"x509_unix on {count} dates, wild ones too, upper halves set: {bad} differ")


def hosts_for(rng, der):
    """Hosts to try against a certificate: from the names in it, and not."""
    found = []
    i = 0
    while True:
        j = der.find(b"\x82", i)
        if j < 0 or j + 2 > len(der):
            break
        n = der[j + 1]
        if n < 0x80 and j + 2 + n <= len(der):
            found.append(der[j + 2:j + 2 + n])
        i = j + 1
    hosts = [b"", b".", b"10.0.2.2", b"127.0.0.1", b"10.0.2.2.", b"10.0.2", b"010.000.002.002",
             b"256.0.0.1", b"1.2.3.4.5", b"example", b"a" * 254, b"a" * 255, b"x." * 127]
    for f in found[:4]:
        hosts += [f, f.upper(), f + b".", f[1:], f + b"x"]
        if f.startswith(b"*."):
            hosts += [rng.choice(LABELS).encode() + f[1:], f[2:], b"a.b" + f[1:], b"." + f[1:]]
    return [h for h in hosts if b"\x00" not in h]


def names(ref, new, rng, made):
    cert = ctypes.create_string_buffer(CERT)
    bad = count = matched = 0
    for der in made:
        buf = ctypes.create_string_buffer(der, len(der) + 16)
        parse_once(ref, buf, len(der), cert)
        cert_raw = bytearray(cert.raw)
        for host in hosts_for(rng, der) + [None]:
            ctypes.memmove(cert, bytes(cert_raw), CERT)
            h = ctypes.create_string_buffer(host) if host is not None else None
            p = ctypes.addressof(h) if h is not None else 0
            ra, ca, ma = ref.call("name_check", rdi=ctypes.addressof(cert), rsi=p)
            rb, cb, mb = new.call("name_check", rdi=ctypes.addressof(cert), rsi=p)
            count += 1
            matched += not ca
            same = ca == cb and (not ca or (ra & 0xFFFFFFFF) == (rb & 0xFFFFFFFF))
            if not same or (ma | mb) & KEPT_BY_NAME:
                bad += 1
                if bad <= 5:
                    result(False, f"x5_name({host!r}) on {der[:24].hex()}...: assembly CF {ca} EAX "
                                  f"{ra & 0xFFFFFFFF} regs {ma:#x}, Rust CF {cb} EAX {rb & 0xFFFFFFFF} "
                                  f"regs {mb:#x}")
    result(bad == 0, f"x5_name on {count} certificates and hosts ({matched} named): {bad} differ")


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
    ap.add_argument("--seed", type=int, default=5280)
    ap.add_argument("--cases", type=int, default=20000, help="certificates made, and changed")
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

    said = run(["cargo", "+nightly", "test", "--target-dir", OUT / "rust"], "cargo test", cwd=RUST)
    tests = [line for line in said.splitlines() if line.startswith("test result:")]
    result(bool(tests) and all(" 0 failed" in t for t in tests), f"cargo test: {'; '.join(tests)}")
    rust = rusthost.build(OUT)

    inc = [arg for p in (ROOT / "src" / "kernel", HERE, HERE.parent) for arg in ("-I", str(p) + os.sep)]
    shims = {}
    for name, defs in (("reference", ["-DREFERENCE"]), ("rust", [])):
        obj, dll = OUT / f"{name}.obj", OUT / f"{name}.dll"
        run([nasm, "-f", "win64", *defs, *inc, "-o", obj, HERE / "shim.asm"], f"nasm -f win64 ({name})")
        run([cc, "-shared", "-Wl,--export-all-symbols", "-o", dll, obj], f"gcc -shared ({name})")
        shims[name] = Shim(dll)
    ref, new = shims["reference"], shims["rust"]
    rusthost.forward(rust, new.dll, ["rs_x509_parse", "rs_x509_unix", "rs_x509_name"])

    rng = random.Random(opts.seed)
    made = parses(ref, new, rng, opts.cases)
    unixes(ref, new, rng)
    names(ref, new, rng, made)
    if failures:
        print(f"x509: {len(failures)} failed, {passed} passed")
        sys.exit(1)
    print(f"x509: all {passed} passed")


main()
