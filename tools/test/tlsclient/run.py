#!/usr/bin/env python3
"""Host tests for src/kernel/tls.asm, the TLS 1.3 client, against OpenSSL.

    python tools/test/tlsclient/run.py [--seed N] [--cc PATH] [--live]

Assembles tls.asm with what it stands on the way kernel.asm does (-f bin,
just to prove it assembles there) and into a DLL with shim.asm and host.c,
makes test certificates with the openssl tool, then runs the client against
Python's ssl module (OpenSSL) as the server, over memory buffers that
deliver the bytes in pieces of every size: handshakes with RSA and ECDSA
certificates, a chain too big for one record, no server name, data both
ways, close_notify both ways; then a tampered record, a tampered
ClientHello (so the Finished cannot match), a TLS 1.2-only server, a
server that wants a client certificate, one that wants another key
exchange, and a connection that will not take the bytes. Certificates are
checked throughout, the test CA trusted as an extra root; then a chain to
no trusted root, the wrong name, a stopped clock, and, from a hand-made
server with a real certificate, a good CertificateVerify, a forged one and
one in a scheme that does not suit the key. --live also fetches pages from
real servers over sockets, checked against the built-in roots. Outputs go
to build/test/tlsclient/. Exit status 0 only if every test passed.
"""
import argparse
import ctypes
import hashlib
import importlib.util
import os
import pathlib
import random
import shutil
import socket
import ssl
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[3]
HERE = pathlib.Path(__file__).resolve().parent
OUT = ROOT / "build" / "test" / "tlsclient"
GCC = (r"C:\Users\noahs\AppData\Local\Microsoft\WinGet\Packages"
       r"\BrechtSanders.WinLibs.POSIX.UCRT_Microsoft.Winget.Source_8wekyb3d8bbwe"
       r"\mingw64\bin\gcc.exe")
MODULES = ("sha256.asm", "sha512.asm", "aesgcm.asm", "x25519.asm", "rand.asm", "bignum.asm",
           "pubkey.asm", "x509.asm", "tls.asm")
sys.path.insert(0, str(ROOT / "tools"))
import mkroots  # noqa: E402

EV_READY, EV_CLOSED, EV_FAIL = 1, 2, 4
TLE = {1: "RNG", 2: "PROTO", 3: "VERSION", 4: "CIPHER", 5: "HRR", 6: "MAC", 7: "FINISHED",
       8: "ALERT", 9: "TOOBIG", 10: "CLIENTCERT", 11: "SEND", 12: "KEYSHARE", 13: "OVERFLOW",
       14: "CERT", 15: "VERIFY", 16: "SIGALG"}

passes = fails = 0


def result(ok, text):
    global passes, fails
    print(("PASS  " if ok else "FAIL  ") + text)
    if ok:
        passes += 1
    else:
        fails += 1


def run(cmd, what):
    r = subprocess.run([str(c) for c in cmd], cwd=ROOT, capture_output=True, text=True)
    out = (r.stdout + r.stderr).strip()
    if r.returncode:
        print(out)
        sys.exit(f"{what} failed ({r.returncode})")
    return out


# ---- certificates ----------------------------------------------------------------


def find_openssl():
    for c in (shutil.which("openssl"), r"C:\Program Files\Git\usr\bin\openssl.exe"):
        if c and os.path.exists(c):
            return c
    sys.exit("the openssl tool is needed to make test certificates")


def make_certs(d):
    ossl = find_openssl()
    d.mkdir(parents=True, exist_ok=True)
    if (d / "done2").exists():
        return
    o = lambda *a: run([ossl, *a], "openssl " + a[0])
    o("ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", d / "ca.key")
    o("req", "-x509", "-new", "-key", d / "ca.key", "-subj", "/CN=Axiom Test CA", "-days", "3650",
      "-out", d / "ca.pem")
    for kind in ("rsa", "ec"):
        if kind == "rsa":
            o("genrsa", "-out", d / "rsa.key", "2048")
        else:
            o("ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", d / "ec.key")
        o("req", "-new", "-key", d / f"{kind}.key", "-subj", "/CN=axiom.test", "-out", d / f"{kind}.csr")
        (d / "san.ext").write_text("subjectAltName=DNS:axiom.test,IP:10.0.2.2\n")
        o("x509", "-req", "-in", d / f"{kind}.csr", "-CA", d / "ca.pem", "-CAkey", d / "ca.key",
          "-CAcreateserial", "-days", "3650", "-extfile", d / "san.ext", "-out", d / f"{kind}.pem")
        (d / f"{kind}-chain.pem").write_text((d / f"{kind}.pem").read_text() +
                                             (d / "ca.pem").read_text())
    # a chain too big for one record: the RSA leaf and twenty more certificates
    extra = ""
    for i in range(20):
        o("req", "-x509", "-new", "-key", d / "rsa.key", "-subj", f"/CN=Axiom Filler {i}",
          "-days", "3650", "-out", d / f"filler{i}.pem")
        extra += (d / f"filler{i}.pem").read_text()
    (d / "big-chain.pem").write_text((d / "rsa.pem").read_text() + extra)
    (d / "done2").write_text("ok\n")


# ---- the client, through the DLL ---------------------------------------------


class Client:
    def __init__(self, dll):
        self.d = dll
        dll.h_start.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_uint64]
        dll.h_set_extra.argtypes = [ctypes.c_void_p]
        dll.h_anchor.restype = ctypes.c_char_p
        dll.h_input.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
        dll.h_write.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
        dll.h_reply_on_ready.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
        dll.h_take_out.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
        dll.h_take_out.restype = ctypes.c_size_t
        dll.h_take_app.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
        dll.h_take_app.restype = ctypes.c_size_t
        dll.h_out_len.restype = ctypes.c_size_t
        dll.h_app_len.restype = ctypes.c_size_t
        dll.h_error_text.restype = ctypes.c_char_p
        dll.h_info.argtypes = [ctypes.POINTER(ctypes.c_int)] * 3

    def start(self, host, insecure=False, now=None):
        return self.d.h_start(host.encode() if host is not None else None, int(insecure),
                              int(time.time()) if now is None else now)

    def checked(self):
        """How the certificate went: (verified, root name, X5E_* code)."""
        a = self.d.h_anchor() if self.d.h_verified() else None
        return self.d.h_verified(), (a.decode() if a else None), self.d.h_cert_err()

    def out(self):
        n = self.d.h_out_len()
        b = ctypes.create_string_buffer(max(n, 1))
        k = self.d.h_take_out(b, n)
        return b.raw[:k]

    def app(self):
        n = self.d.h_app_len()
        b = ctypes.create_string_buffer(max(n, 1))
        k = self.d.h_take_app(b, n)
        return b.raw[:k]

    def info(self):
        v = [ctypes.c_int() for _ in range(3)]
        self.d.h_info(*[ctypes.byref(x) for x in v])
        return [x.value for x in v]

    def fail_text(self):
        c = self.d.h_fail_code()
        return f"{TLE.get(c, c)}: {self.d.h_error_text(c).decode()}"


class Server:
    def __init__(self, ctx):
        self.inc, self.outg = ssl.MemoryBIO(), ssl.MemoryBIO()
        self.sni = "unset"

        def on_sni(sobj, name, c):
            self.sni = name
        ctx.sni_callback = on_sni
        self.obj = ctx.wrap_bio(self.inc, self.outg, server_side=True)
        self.done = False
        self.error = None

    def step(self):
        if not self.done and not self.error:
            try:
                self.obj.do_handshake()
                self.done = True
            except ssl.SSLWantReadError:
                pass
            except (ssl.SSLError, OSError) as e:
                self.error = e

    def read_all(self):
        data = b""
        while True:
            try:
                d = self.obj.read(65536)
            except (ssl.SSLWantReadError, ssl.SSLZeroReturnError):
                return data
            if not d:
                return data
            data += d


def feed(cl, data, rng, chunks):
    i = 0
    while i < len(data):
        if chunks == "whole":
            n = len(data)
        elif chunks == "bytes":
            n = 1
        else:
            n = rng.choice([1, 2, 3, 5, 7, 13, 64, 300, 1460, 4000, 20000])
        piece = data[i:i + n]
        cl.d.h_input(piece, len(piece))
        i += n


def pump(cl, sv, rng, chunks, c2s=None, s2c=None, rounds=20):
    for _ in range(rounds):
        moved = False
        b = cl.out()
        if b:
            if c2s:
                b = c2s(b)
            sv.inc.write(b)
            moved = True
        sv.step()
        b = sv.outg.read()
        if b:
            if s2c:
                b = s2c(b)
            feed(cl, b, rng, chunks)
            moved = True
        if not moved:
            break


def server_ctx(cert, key, tls12=False):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    if tls12:
        ctx.maximum_version = ssl.TLSVersion.TLSv1_2
    else:
        ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    ctx.load_cert_chain(cert, key)
    return ctx


# ---- the cases -----------------------------------------------------------------


def full_session(cl, rng, certs, chain, key, host, chunks, label, sigalg=None, nbig=200000):
    sv = Server(server_ctx(certs / chain, certs / key))
    if cl.start(host):
        result(False, f"{label}: tls_start failed")
        return
    pump(cl, sv, rng, chunks)
    ev = cl.d.h_events()
    if not (ev & EV_READY) or not sv.done:
        why = cl.fail_text() if ev & EV_FAIL else f"events {ev}"
        result(False, f"{label}: no handshake ({why}; server: {sv.error})")
        return
    problems = []
    if sv.obj.version() != "TLSv1.3" or sv.obj.cipher()[0] != "TLS_AES_128_GCM_SHA256":
        problems.append(f"negotiated {sv.obj.version()} {sv.obj.cipher()}")
    want_sni = host if host and not host.replace(".", "").isdigit() else None
    if sv.sni != want_sni:
        problems.append(f"server name {sv.sni!r}, want {want_sni!r}")
    certs_n, cert_bytes, alg = cl.info()
    if sigalg and alg != sigalg:
        problems.append(f"CertificateVerify algorithm {alg:#06x}, want {sigalg:#06x}")
    verified, anchor, _ = cl.checked()
    if not verified or anchor != "Axiom Test CA":
        problems.append(f"certificate not checked (verified {verified}, root {anchor})")
    req = b"GET / HTTP/1.0\r\nHost: axiom.test\r\n\r\n" * 3
    if cl.d.h_write(req, len(req)):
        problems.append("tls_write refused")
    pump(cl, sv, rng, chunks)
    got = sv.read_all()
    if got != req:
        problems.append(f"server read {len(got)} bytes, want {len(req)}")
    body = rng.randbytes(nbig)
    for i in range(0, len(body), 30000):
        sv.obj.write(body[i:i + 30000])
        pump(cl, sv, rng, chunks)
    app = cl.app()
    if app != body:
        problems.append(f"client read {len(app)} bytes, want {len(body)}"
                        + ("" if len(app) != len(body) else " (different)"))
    try:
        sv.obj.unwrap()                 # the server's close_notify
    except ssl.SSLWantReadError:
        pass
    pump(cl, sv, rng, chunks)
    if not (cl.d.h_events() & EV_CLOSED):
        problems.append("no CLOSED after the server's close_notify")
    cl.d.h_close()                       # ours
    sv.inc.write(cl.out())
    try:
        sv.obj.unwrap()
        closed = True
    except ssl.SSLError:
        closed = False
    if not closed:
        problems.append("the server did not take our close_notify")
    if cl.d.h_state() != 0:
        problems.append(f"state {cl.d.h_state()} after tls_close")
    result(not problems, f"{label}: {certs_n} certificate(s), {cert_bytes} bytes, checked, signed "
           f"with {alg:#06x}, {len(body)} bytes in, pieces '{chunks}'" +
           ("" if not problems else ": " + "; ".join(problems)))


def expect_failure(cl, rng, ctx, label, want, c2s=None, s2c=None, check_server=None):
    sv = Server(ctx)
    cl.start("axiom.test")
    pump(cl, sv, rng, "random", c2s=c2s, s2c=s2c)
    ev = cl.d.h_events()
    code = cl.d.h_fail_code()
    ok = bool(ev & EV_FAIL) and not (ev & EV_READY) and TLE.get(code) in want
    ok = ok and cl.d.h_state() == 0
    extra = ""
    if code == 8:
        extra = f" (alert {cl.d.h_alert()})"
    if check_server:
        sok, stext = check_server(sv)
        ok = ok and sok
        extra += "; " + stext
    result(ok, f"{label}: {cl.fail_text() if ev & EV_FAIL else f'events {ev}'}{extra}")


def mini_tests(cl, rng):
    """Against minisrv.MiniServer: what OpenSSL will not do on request."""
    import minisrv

    def session(label, data_steps=None, **knobs):
        sv = minisrv.MiniServer(rng, **knobs)
        cl.start("axiom.test", insecure="chain" not in knobs)
        for _ in range(4):
            b = cl.out()
            if not b:
                break
            feed(cl, sv.receive(b), rng, "random")
        sv.receive(cl.out())
        return sv

    def ok_open(sv):
        return cl.d.h_events() & EV_READY and "finished" in sv.events

    for label, knobs in (("one record for the flight", {}),
                         ("a record per message, 300 bytes of padding each",
                          {"split": "each", "pad": 300}),
                         ("messages cut across 37-byte records", {"split": 37}),
                         ("a byte of handshake per record, no CCS",
                          {"split": 1, "ccs": False, "cert_size": 100}),
                         ("a 60 KB certificate", {"cert_size": 60000})):
        sv = session(label, **knobs)
        good = ok_open(sv)
        if good:
            cl.d.h_write(b"ping", 4)
            sv.receive(cl.out())
            good = sv.app == b"ping"
        result(good, f"hand-made server, {label}: client events {cl.d.h_events()}, "
               f"server saw {sv.events}" + ("" if good else f"; {cl.fail_text()}"))
        cl.d.h_abort()

    sv = session("wrong Finished", bad_finished=True)
    ev = cl.d.h_events()
    result(ev & EV_FAIL and TLE.get(cl.d.h_fail_code()) == "FINISHED" and "alert 51" in sv.events
           and "finished" not in sv.events,
           f"hand-made server, a Finished that does not match: {cl.fail_text()}; "
           f"server saw {sv.events}")

    sv = session("after")
    problems = []
    stream = b""
    want = b""
    for step in ("ticket", "empty", "padded", "update0", "data", "update1", "data", "close"):
        if step == "ticket":
            stream += sv.ticket()
        elif step == "empty":
            stream += sv.empty_record()
        elif step == "padded":
            d = rng.randbytes(3000)
            want += d
            stream += sv.send_app(d, pad=900)
        elif step.startswith("update"):
            stream += sv.key_update(step == "update1")
        elif step == "data":
            d = rng.randbytes(20000)
            want += d
            stream += sv.send_app(d)
        else:
            stream += sv.close()
    feed(cl, stream, rng, "random")
    got = cl.app()
    if got != want:
        problems.append(f"client read {len(got)} bytes, want {len(want)}")
    if not cl.d.h_events() & EV_CLOSED:
        problems.append(f"no CLOSED (events {cl.d.h_events()}, {cl.fail_text()})")
    sv.receive(cl.out())
    if "keyupdate 0" not in sv.events:
        problems.append("no KeyUpdate in answer to update_requested")
    cl.d.h_close()
    sv.receive(cl.out())
    if sv.events[-1] != "alert 0":
        problems.append(f"no close_notify last: {sv.events[-3:]}")
    result(not problems, "hand-made server: a ticket, an empty record, padding, KeyUpdate both "
           "ways, close_notify" + ("" if not problems else ": " + "; ".join(problems)))

    sv = session("updated write")
    feed(cl, sv.key_update(True), rng, "random")
    cl.d.h_write(b"after the update", 16)
    sv.receive(cl.out())
    result(sv.app == b"after the update" and sv.events[-2:] == ["keyupdate 0", "data 16"],
           f"hand-made server: our records after our KeyUpdate use the new key ({sv.events[-2:]})")
    cl.d.h_abort()

    sv = session("overflow")
    feed(cl, bytes([23, 3, 3, 0x41, 0x01]), rng, "random")
    result(TLE.get(cl.d.h_fail_code()) == "OVERFLOW", "hand-made server, a record header "
           f"saying 16641 bytes: {cl.fail_text()}")
    sv = session("overflow inside")
    feed(cl, sv.send_app(b"") if False else sv.s.seal(23, bytes(16385)), rng, "whole")
    result(TLE.get(cl.d.h_fail_code()) == "OVERFLOW", "hand-made server, 16385 bytes of "
           f"plaintext in one record: {cl.fail_text()}")
    sv = session("plain")
    feed(cl, bytes([22, 3, 3, 0, 4, 4, 0, 0, 0]), rng, "random")
    result(TLE.get(cl.d.h_fail_code()) == "PROTO", "hand-made server, a handshake record in "
           f"the clear after the keys changed: {cl.fail_text()}")
    sv = session("alert")
    feed(cl, sv.s.seal(21, bytes([2, 80])), rng, "random")
    result(TLE.get(cl.d.h_fail_code()) == "ALERT" and cl.d.h_alert() == 80,
           f"hand-made server, a fatal alert: {cl.fail_text()} {cl.d.h_alert()}")


def cert_tests(cl, rng, certs, extra):
    """The chain refused, each for its own reason, and the alert the server hears."""
    rctx = lambda: server_ctx(certs / "rsa-chain.pem", certs / "rsa.key")
    for label, kw, want, alert in (
            ("a chain to no trusted root", {"trusted": False}, "ISSUER", "unknown ca"),
            ("another name", {"host": "other.test"}, "NAME", "bad certificate"),
            ("another address", {"host": "10.0.2.3"}, "NAME", "bad certificate"),
            ("twenty years on", {"now": int(time.time()) + 20 * 365 * 86400}, "EXPIRED",
             "certificate expired"),
            ("a clock in 2024", {"now": 1717200000}, "CLOCK", "certificate unknown")):
        cl.d.h_set_extra(None if kw.get("trusted") is False else ctypes.addressof(extra))
        sv = Server(rctx())
        cl.start(kw.get("host", "axiom.test"), now=kw.get("now"))
        pump(cl, sv, rng, "random")
        ev = cl.d.h_events()
        x5 = cl.d.h_cert_err()
        names = ["OK", "MALFORMED", "ALGORITHM", "KEY", "EXPIRED", "NOTYET", "NAME", "ISSUER",
                 "SIGNATURE", "NOTCA", "PATHLEN", "PURPOSE", "CRITICAL", "CLOCK"]
        ok = (ev & EV_FAIL and not ev & EV_READY and TLE.get(cl.d.h_fail_code()) == "CERT"
              and names[x5] == want and alert in str(sv.error).lower())
        result(ok, f"{label}: {cl.fail_text()} [{names[x5]}]; server: {str(sv.error)[:60]}")
    cl.d.h_set_extra(None)
    sv = Server(rctx())
    cl.start("axiom.test", insecure=True)
    pump(cl, sv, rng, "random")
    v, a, _ = cl.checked()
    result(cl.d.h_events() & EV_READY and not v and cl.d.h_sigalg_checked(),
           f"no trusted root, but told not to check (http -k): events {cl.d.h_events()}, "
           f"verified {v}, CertificateVerify still checked")
    cl.d.h_abort()
    cl.d.h_set_extra(ctypes.addressof(extra))


def cv_tests(cl, rng, certs):
    """A hand-made server with a real certificate: CertificateVerify good, forged, misnamed."""
    import minisrv
    spec = importlib.util.spec_from_file_location("pkirun", HERE.parent / "pki" / "run.py")
    pki = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(pki)
    pki.OSSL = find_openssl()
    run([pki.OSSL, "pkey", "-in", certs / "ec.key", "-outform", "DER", "-out", certs / "ec.der"],
        "openssl pkey")
    d = pki.pkcs8(certs / "ec.der")[1]["d"]
    c = pki.Curve("prime256v1", 32, 2)
    leaf = next(mkroots.pem_certs((certs / "ec.pem").read_text()))
    sign = lambda key, content: pki.der_sig(*c.sign(key, hashlib.sha256(content).digest(), rng))
    for label, signer, want, alert in (
            ("a good CertificateVerify", lambda m: (0x0403, sign(d, m)), None, None),
            ("a CertificateVerify signed with another key", lambda m: (0x0403, sign(d + 1, m)),
             "VERIFY", 51),
            ("a CertificateVerify over something else", lambda m: (0x0403, sign(d, m[:-1] + b"x")),
             "VERIFY", 51),
            ("P-256 signature called P-384 (0x0503)", lambda m: (0x0503, sign(d, m)), "SIGALG", 47),
            ("an ECDSA key's signature called RSA-PSS", lambda m: (0x0804, sign(d, m)), "SIGALG", 47),
            ("PKCS#1 v1.5, which TLS 1.3 forbids here", lambda m: (0x0401, sign(d, m)), "SIGALG", 47)):
        sv = minisrv.MiniServer(rng, chain=[leaf], signer=signer)
        cl.start("axiom.test")
        for _ in range(4):
            b = cl.out()
            if not b:
                break
            feed(cl, sv.receive(b), rng, "random")
        sv.receive(cl.out())
        ev = cl.d.h_events()
        if want is None:
            ok = ev & EV_READY and "finished" in sv.events and cl.checked()[0]
        else:
            ok = (ev & EV_FAIL and TLE.get(cl.d.h_fail_code()) == want and f"alert {alert}" in sv.events
                  and "finished" not in sv.events)
        result(ok, f"hand-made server, {label}: " + (cl.fail_text() if ev & EV_FAIL else f"events {ev}") +
               f"; server saw {sv.events}")
        cl.d.h_abort()


LIVE = ["example.com", "www.google.com", "github.com", "www.cloudflare.com", "en.wikipedia.org",
        "letsencrypt.org", "www.amazon.com", "www.microsoft.com"]


def live_tests(cl):
    """Real servers, over sockets, against the built-in roots."""
    cl.d.h_set_extra(None)
    for host in LIVE:
        try:
            s = socket.create_connection((host, 443), timeout=10)
        except OSError as e:
            result(True, f"{host}: not reached ({e.__class__.__name__}), skipped")
            continue
        req = f"GET / HTTP/1.0\r\nHost: {host}\r\nUser-Agent: axiom-test\r\n\r\n".encode()
        cl.d.h_reply_on_ready(req, len(req))
        t0 = time.perf_counter()
        cl.start(host)
        try:
            s.sendall(cl.out())
            while True:
                data = s.recv(65536)
                if not data:
                    break
                cl.d.h_input(data, len(data))
                out = cl.out()
                if out:
                    s.sendall(out)
                ev = cl.d.h_events()
                if ev & (EV_FAIL | EV_CLOSED):
                    break
        except OSError as e:
            print(f"      {host}: {e}")
        s.close()
        dt = time.perf_counter() - t0
        ev = cl.d.h_events()
        app = cl.app()
        v, anchor, _ = cl.checked()
        ok = ev & EV_READY and v and app.startswith(b"HTTP/")
        status = app.split(b"\r\n", 1)[0].decode(errors="replace")
        result(ok, f"{host}: " + (f"{status!r}, {len(app)} bytes, root {anchor}, signed with "
                                  f"{cl.info()[2]:#06x}, {dt * 1000:.0f} ms" if ok else
                                  (cl.fail_text() if ev & EV_FAIL else f"events {ev}")))
        cl.d.h_abort()
    cl.d.h_reply_on_ready(None, 0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=8446)
    ap.add_argument("--cc", default=os.environ.get("CC", GCC))
    ap.add_argument("--live", action="store_true", help="also fetch from real servers")
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
    stub.write_text("bits 64\ndefault rel\norg 0xFFFFFFFF80000000\n"
                    "section .text progbits align=16\n"
                    "section .rodata progbits align=64 follows=.text\n"
                    "section .data progbits align=64 follows=.rodata\n"
                    "section .bss nobits align=64\nsection .text\n" +
                    "".join(f'%include "{m}"\n' for m in MODULES))
    run([nasm, "-f", "bin", "-w-reloc-abs-qword", "-w-reloc-abs-dword", "-w-reloc-rel-dword",
         "-I", kinc, "-o", OUT / "kernel_like.bin", stub], "nasm -f bin (kernel layout)")
    print("kernel layout: " + ", ".join(MODULES) + " assemble")
    obj = OUT / "shim.obj"
    dll = OUT / "tls_client.dll"
    run([nasm, "-f", "win64", "-I", kinc, "-o", obj, HERE / "shim.asm"], "nasm -f win64")
    run([cc, "-O2", "-Wall", "-Wextra", "-shared", "-static", "-o", dll, HERE / "host.c", obj],
        "gcc")
    certs = OUT / "certs"
    make_certs(certs)
    print(f"server: Python {sys.version.split()[0]}, {ssl.OPENSSL_VERSION}")

    cl = Client(ctypes.CDLL(str(dll)))
    rng = random.Random(opts.seed)
    ca = mkroots.parse(next(mkroots.pem_certs((certs / "ca.pem").read_text())))
    extra = ctypes.create_string_buffer(mkroots.table([ca]))
    cl.d.h_set_extra(ctypes.addressof(extra))      # the test CA, trusted

    print("-- handshakes and data")
    full_session(cl, rng, certs, "rsa-chain.pem", "rsa.key", "axiom.test", "whole",
                 "RSA certificate", sigalg=0x0804)
    full_session(cl, rng, certs, "rsa-chain.pem", "rsa.key", "axiom.test", "bytes",
                 "RSA, a byte at a time", nbig=20000)
    full_session(cl, rng, certs, "ec-chain.pem", "ec.key", "axiom.test", "random",
                 "ECDSA certificate", sigalg=0x0403)
    full_session(cl, rng, certs, "big-chain.pem", "rsa.key", "axiom.test", "random",
                 "a 21-certificate chain")
    full_session(cl, rng, certs, "rsa-chain.pem", "rsa.key", "10.0.2.2", "random",
                 "an address, so no server name")
    bad = 0
    for i in range(40):
        sv = Server(server_ctx(certs / ("ec-chain.pem" if i & 1 else "rsa-chain.pem"),
                               certs / ("ec.key" if i & 1 else "rsa.key")))
        cl.start("axiom.test")
        msg = rng.randbytes(rng.randrange(1, 40000))
        cl.d.h_reply_on_ready(msg, len(msg))      # written from inside READY, as http does
        pump(cl, sv, rng, "random")
        got = sv.read_all()
        if not (cl.d.h_events() & EV_READY) or cl.d.h_reply_cf() != 0 or got != msg:
            bad += 1
            print(f"      run {i}: events {cl.d.h_events()}, reply cf {cl.d.h_reply_cf()}, "
                  f"server read {len(got)} of {len(msg)}; {cl.fail_text()}")
        cl.d.h_abort()
    cl.d.h_reply_on_ready(None, 0)
    result(bad == 0, f"40 more handshakes, each writing up to 40 KB from READY: {bad} failed")

    print("-- failures")

    def flip_late(b):          # a byte in the first encrypted record
        b = bytearray(b)
        i = 0
        while i + 5 <= len(b):
            n = int.from_bytes(b[i + 3:i + 5], "big")
            if b[i] == 23:
                b[i + 5 + n // 2] ^= 0x40
                break
            i += 5 + n
        return bytes(b)

    def server_alert(name):
        def check(sv):
            text = str(sv.error)
            return (name.lower() in text.lower(), f"server: {text[:70]}")
        return check

    rctx = lambda: server_ctx(certs / "rsa-chain.pem", certs / "rsa.key")
    expect_failure(cl, rng, rctx(), "a flipped bit in an encrypted record", {"MAC"}, s2c=flip_late)
    expect_failure(cl, rng, server_ctx(certs / "rsa-chain.pem", certs / "rsa.key", tls12=True),
                   "a server with TLS 1.2 at most", {"ALERT", "VERSION"})
    cctx = rctx()
    cctx.verify_mode = ssl.CERT_REQUIRED
    cctx.load_verify_locations(certs / "ca.pem")
    expect_failure(cl, rng, cctx, "a server that wants a client certificate", {"CLIENTCERT"})
    gctx = rctx()
    if hasattr(gctx, "set_groups"):
        gctx.set_groups("P-256")
    else:
        gctx.set_ecdh_curve("prime256v1")
    expect_failure(cl, rng, gctx, "a server that wants P-256, not X25519", {"HRR", "ALERT"})

    sv = Server(rctx())                 # a connection that stops taking bytes
    cl.start("axiom.test")
    pump(cl, sv, rng, "random")
    cl.d.h_refuse_send(1)
    cf = cl.d.h_write(b"x" * 100, 100)
    result(cf == 1 and cl.d.h_state() == 0 and cl.d.h_events() & EV_READY,
           f"tls_write into a full connection: CF {cf}, state {cl.d.h_state()} after")
    cl.d.h_refuse_send(0)

    sv = Server(rctx())                 # cut off halfway, then started again
    cl.start("axiom.test")
    b = cl.out()
    sv.inc.write(b)
    sv.step()
    half = sv.outg.read()
    feed(cl, half[:len(half) // 2], rng, "random")
    cl.d.h_abort()
    result(cl.d.h_state() == 0 and not cl.d.h_events(), "a handshake cut off halfway and abandoned")
    rc = cl.start("axiom.test")
    result(rc == 0 and cl.d.h_state() == 1 and len(cl.out()) > 100, "and a new one starts cleanly")
    cl.d.h_abort()

    print("-- certificates")
    cert_tests(cl, rng, certs, extra)
    print("-- against a hand-made server")
    sys.path.insert(0, str(HERE))
    mini_tests(cl, rng)
    cv_tests(cl, rng, certs)
    if opts.live:
        print("-- real servers")
        live_tests(cl)

    print(f"-- {passes} passed, {fails} failed")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
