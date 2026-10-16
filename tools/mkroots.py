#!/usr/bin/env python3
"""Make src/kernel/gen/roots.asm: the roots Axiom's https trusts.

    python tools/mkroots.py [BUNDLE.pem]

BUNDLE defaults to certifi's cacert.pem, which is Mozilla's list of CAs
trusted to identify websites (the one Firefox uses). For each root, what
x509.asm needs to check a signature it made: the SHA-256 of its subject
name (a certificate's issuer is matched against it), its public key and a
name to show. Roots with keys x509.asm cannot use (RSA outside 2048-4096
bits, curves but P-256 and P-384) are left out and listed.

Each entry, little-endian:
    +0  u16 entry bytes          +2  u8 key type (1 RSA, 2 P-256, 3 P-384)
    +3  u8 name bytes, with NUL  +4  u16 key bytes        +6  u16 0
    +8  u64 RSA exponent (0 for EC)
    +16 32 bytes SHA-256 of the subject Name, the whole DER element
    +48 the key: RSA's modulus, big-endian, no leading zeros; or the EC
        point, uncompressed (04, X, Y); then the name, NUL-terminated
and a u16 0 after the last. The tests import this file for its DER reader
and entry().
"""
import base64
import datetime
import hashlib
import pathlib
import re
import sys
import unicodedata

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "src" / "kernel" / "gen" / "roots.asm"

OID_RSA = bytes.fromhex("2a864886f70d010101")
OID_EC = bytes.fromhex("2a8648ce3d0201")
OID_P256 = bytes.fromhex("2a8648ce3d030107")
OID_P384 = bytes.fromhex("2b81040022")
OID_CN, OID_OU, OID_O = bytes.fromhex("550403"), bytes.fromhex("55040b"), bytes.fromhex("55040a")
KT_RSA, KT_P256, KT_P384 = 1, 2, 3


# ---- DER ------------------------------------------------------------------------


def tlv(b, i):
    """The element at b[i]: (tag, content start, content end)."""
    tag = b[i]
    n = b[i + 1]
    i += 2
    if n & 0x80:
        k = n & 0x7F
        n = int.from_bytes(b[i:i + k], "big")
        i += k
    if i + n > len(b):
        raise ValueError("DER element runs past the end")
    return tag, i, i + n


def children(b, start, end):
    """The elements between start and end: [(tag, cstart, cend, whole start)]."""
    out = []
    i = start
    while i < end:
        tag, s, e = tlv(b, i)
        out.append((tag, s, e, i))
        i = e
    return out


def pem_certs(text):
    for m in re.finditer(r"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", text, re.S):
        yield base64.b64decode("".join(m.group(1).split()))


def parse(der):
    """What a root entry needs from a certificate."""
    _, s, e = tlv(der, 0)
    tbs = children(der, s, e)[0]
    f = children(der, tbs[1], tbs[2])
    if f[0][0] == 0xA0:
        f = f[1:]
    subject = f[4]
    spki = f[5]
    alg, bits = children(der, spki[1], spki[2])
    alg_parts = children(der, alg[1], alg[2])
    oid = der[alg_parts[0][1]:alg_parts[0][2]]
    key = der[bits[1] + 1:bits[2]]
    kt, e = 0, 0
    if oid == OID_RSA:
        _, ks, ke = tlv(key, 0)
        n, ee = children(key, ks, ke)
        mod = key[n[1]:n[2]].lstrip(b"\0")
        e = int.from_bytes(key[ee[1]:ee[2]], "big")
        if 256 <= len(mod) <= 512:
            kt, key = KT_RSA, mod
    elif oid == OID_EC and len(alg_parts) > 1:
        curve = der[alg_parts[1][1]:alg_parts[1][2]]
        if curve == OID_P256 and len(key) == 65:
            kt = KT_P256
        elif curve == OID_P384 and len(key) == 97:
            kt = KT_P384
    names = {}
    for rdn in children(der, subject[1], subject[2]):
        for atv in children(der, rdn[1], rdn[2]):
            a, v = children(der, atv[1], atv[2])
            names.setdefault(der[a[1]:a[2]], der[v[1]:v[2]].decode("utf-8", "replace"))
    name = names.get(OID_CN) or names.get(OID_OU) or names.get(OID_O) or "?"
    name = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode() or "?"
    return {"subject": der[subject[3]:subject[2]], "type": kt, "key": key, "e": e, "name": name}


def entry(info):
    name = info["name"].encode()[:200] + b"\0"
    body = (bytes([info["type"], len(name)]) + len(info["key"]).to_bytes(2, "little") +
            b"\0\0" + info["e"].to_bytes(8, "little") + hashlib.sha256(info["subject"]).digest() +
            info["key"] + name)
    return (len(body) + 2).to_bytes(2, "little") + body


def table(infos):
    return b"".join(entry(i) for i in infos) + b"\0\0"


def default_bundle():
    try:
        import certifi
    except ImportError:
        sys.exit("give a PEM bundle, or pip install certifi")
    return pathlib.Path(certifi.where()), f"certifi {certifi.__version__}"


def main():
    if len(sys.argv) > 1:
        src = pathlib.Path(sys.argv[1])
        what = src.name
    else:
        src, what = default_bundle()
    infos, skipped = [], []
    for der in pem_certs(src.read_text()):
        info = parse(der)
        (infos if info["type"] else skipped).append(info)
    lines = [f"; gen/roots.asm - the trusted roots, made by tools/mkroots.py from {what}",
             f"; ({len(infos)} roots, {datetime.date.today()}). Do not edit; run it again.",
             "", f"X509_ROOTS      equ {len(infos)}", "", "section .rodata", "x509_roots:"]
    for info in infos:
        kind = {KT_RSA: f"RSA-{len(info['key']) * 8}", KT_P256: "P-256", KT_P384: "P-384"}[info["type"]]
        lines.append(f"; {info['name']} ({kind})")
        e = entry(info)
        for i in range(0, len(e), 24):
            lines.append("    db " + ",".join(f"0x{x:02x}" for x in e[i:i + 24]))
    lines += ["    dw 0", ""]
    OUT.write_text("\n".join(lines))
    print(f"{OUT.relative_to(ROOT)}: {len(infos)} roots, {sum(len(entry(i)) for i in infos)} bytes")
    for info in skipped:
        print(f"  left out (its key): {info['name']}")


if __name__ == "__main__":
    main()
