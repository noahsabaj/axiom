#!/usr/bin/env python3
"""HTTP/1.1 in QEMU: the client (http.asm, through 'http') against servers
here on the host, and the server ('httpd', httpd.asm) against clients here.

    python tools/test/http/run.py

One boot, an RTL8139 on QEMU's user network, from a stick image with a few
more files on it (a directory with an index.html, a name with a space, a
Markdown file).

The client: bodies by Content-Length, in chunks (random sizes, extensions,
a trailer, sent in random pieces), up to the close (HTTP/1.0), none (204),
after a 100 Continue; the connection kept between requests and used again,
over TLS too; a server that closes a kept connection just as it is used
(the request goes again, on a new one), one that says 'Connection: close',
one that closes while it is idle, one that cuts a body short and one whose
chunks are broken. Bodies are saved on the stick and compared afterwards,
and the host counts which requests came on which connection.

The server: files compared byte for byte with build/esp, their types and
lengths; HEAD; 404; a directory without its '/' sent there, its listing,
an index.html; %XX in a path; a POST passed over (405) on a connection that
goes on; requests sent together, answered in order; HTTP/1.0 closed, or
kept when asked; bad requests (400, 414, 431, 505, a path climbing out);
eight clients at once.
Outputs go to build/test/http/.
"""
import hashlib
import http.client
import pathlib
import random
import re
import socket
import ssl
import subprocess
import sys
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "test"))
sys.path.insert(0, str(ROOT / "tools"))
from qemu import boot_all  # noqa: E402
import fat32  # noqa: E402
import mkstick  # noqa: E402

OUT = ROOT / "build" / "test" / "http"
ESP = ROOT / "build" / "esp"
FAILS = 0
NL = "\\n"


def result(ok, text):
    global FAILS
    FAILS += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + text)
    return ok


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def text(n):
    """n bytes of numbered lines, the same each time"""
    out = bytearray()
    i = 0
    while len(out) < n:
        out += b"%07d the quick brown fox jumps over the lazy dog\n" % i
        i += 1
    return bytes(out[:n])


# -- the servers for the client ------------------------------------------------

conns = {"plain": [], "tls": []}             # the requests, connection by connection


def pieces(c, b, rng):
    while b:
        n = rng.randint(1, 3000)
        c.sendall(b[:n])
        b = b[n:]


def handle(c, kind):
    """One connection: requests until it ends; what each path asks for."""
    paths = []
    conns[kind].append(paths)
    rng = random.Random(len(conns[kind]))
    f = c.makefile("rb")
    once = False
    while True:
        line = f.readline()
        if not line:
            return
        if line in (b"\r\n", b"\n"):
            continue
        target = line.split()[1].decode()
        while f.readline() not in (b"\r\n", b"\n", b""):
            pass
        paths.append(target)
        if once:
            return                              # kept, but closed as it is used
        parts = target.split("/")
        what = parts[1]
        n = int(parts[2]) if len(parts) > 2 and parts[2] else 0
        body = text(n)
        if what == "len":
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\n\r\n" % n + body)
        elif what == "chunked":
            out = b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n"
            i = 0
            while i < n:
                k = min(rng.randint(1, 20000), n - i)
                ext = b";x=%d" % k if rng.random() < 0.3 else b""
                out += b"%x%s\r\n" % (k, ext) + body[i:i + k] + b"\r\n"
                i += k
            out += b"0\r\nX-Sum: " + hashlib.sha256(body).hexdigest().encode() + b"\r\n\r\n"
            pieces(c, out, rng)
        elif what == "close":
            c.sendall(b"HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\n" + body)
            return
        elif what == "bye":
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % n + body)
            return
        elif what == "204":
            c.sendall(b"HTTP/1.1 204 No Content\r\n\r\n")
        elif what == "continue":
            c.sendall(b"HTTP/1.1 100 Continue\r\n\r\n")
            time.sleep(0.1)
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n" % n + body)
        elif what == "once":
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n" % n + body)
            once = True
        elif what == "cut":
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n" % n + body[:n // 2])
            return
        elif what == "badchunks":
            c.sendall(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\nzz\r\n")
            time.sleep(2)
            return
        elif what == "idleclose":
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n" % n + body)
            time.sleep(0.5)
            return


def serve(port, kind, ctx=None):
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port))
    s.listen(16)

    def one(c):
        try:
            if ctx:
                c = ctx.wrap_socket(c, server_side=True)
            handle(c, kind)
        except (OSError, ssl.SSLError, ValueError, IndexError):
            pass
        finally:
            try:
                c.close()
            except OSError:
                pass

    def loop():
        while True:
            c, _ = s.accept()
            threading.Thread(target=one, args=(c,), daemon=True).start()
    threading.Thread(target=loop, daemon=True).start()


# -- the clients for the server -------------------------------------------------

checks = []                                     # (ok, text), from the clients' thread


def check(ok, what):
    checks.append((bool(ok), what))


def read_answer(f):
    """-> (status, headers, body) of one answer from a file of a socket"""
    line = f.readline()
    if not line:
        return None, {}, b""
    status = int(line.split()[1])
    headers = {}
    while True:
        h = f.readline().decode()
        if h in ("\r\n", "\n", ""):
            break
        k, _, v = h.partition(":")
        headers[k.strip().lower()] = v.strip()
    n = int(headers.get("content-length", 0))
    return status, headers, f.read(n) if n else b""


def raw(port, data, timeout=10):
    """data sent; -> the socket and a file to read it from"""
    s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    s.sendall(data)
    return s, s.makefile("rb")


def closed(s, f):
    try:
        return f.read(1) == b""
    except OSError:
        return True
    finally:
        s.close()


def clients(port, log_has):
    deadline = time.time() + 240
    while not log_has("httpd: serving") and time.time() < deadline:
        time.sleep(0.3)
    time.sleep(0.5)
    try:
        test_clients(port)
    except Exception as e:                      # noqa: BLE001 (any of it: a failure)
        check(False, f"the clients ran into {e!r}")
    try:
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        c.request("GET", "/__done__")
        c.getresponse().read()
    except OSError:
        pass


def test_clients(port):
    esp_axe = (ESP / "EFI" / "AXIOM" / "TEST.AXE").read_bytes()
    esp_efi = (ESP / "EFI" / "BOOT" / "BOOTX64.EFI").read_bytes()
    hello = (ESP / "EFI" / "AXIOM" / "HELLO.AXE").read_bytes()

    c = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
    c.request("GET", "/EFI/AXIOM/TEST.AXE")
    r = c.getresponse()
    body = r.read()
    s0 = c.sock
    check(r.status == 200 and body == esp_axe, f"GET TEST.AXE: {r.status}, {len(body)} bytes, the same as build/esp")
    check(r.getheader("Content-Type") == "application/octet-stream"
          and r.getheader("Content-Length") == str(len(esp_axe)), "  its type and length")
    c.request("GET", "/EFI/BOOT/BOOTX64.EFI")
    r = c.getresponse()
    body = r.read()
    check(r.status == 200 and body == esp_efi, f"GET BOOTX64.EFI: {len(body)} bytes, the same")
    c.request("HEAD", "/EFI/AXIOM/HELLO.AXE")
    r = c.getresponse()
    check(r.status == 200 and r.getheader("Content-Length") == str(len(hello)) and r.read() == b"",
          "HEAD HELLO.AXE: its length, no body")
    c.request("GET", "/nope.txt")
    r = c.getresponse()
    r.read()
    check(r.status == 404, f"a file not there: {r.status}")
    c.request("GET", "/EFI")
    r = c.getresponse()
    r.read()
    check(r.status == 301 and r.getheader("Location") == "/EFI/", f"a directory without its '/': {r.status} to {r.getheader('Location')}")
    c.request("GET", "/EFI/")
    r = c.getresponse()
    page = r.read().decode()
    check(r.status == 200 and 'href="AXIOM/"' in page and 'href="BOOT/"' in page
          and r.getheader("Content-Type").startswith("text/html"), "its listing, with links")
    c.request("GET", "/site/")
    r = c.getresponse()
    check(r.read() == INDEX, "a directory with an index.html: that")
    c.request("GET", "/site/a%20b.txt")
    r = c.getresponse()
    check(r.read() == SPACED and r.getheader("Content-Type").startswith("text/plain"), "%20 in a path; text/plain")
    c.request("POST", "/site/", body=b"x" * 10000)
    r = c.getresponse()
    r.read()
    check(r.status == 405 and r.getheader("Allow") == "GET, HEAD", f"POST: {r.status}, Allow: {r.getheader('Allow')}")
    c.request("GET", "/notes.md")
    r = c.getresponse()
    check(r.read() == NOTES and r.getheader("Content-Type").startswith("text/markdown"), "after it, on: notes.md, text/markdown")
    check(c.sock is s0, "all of that on one connection")
    c.close()

    reqs = b"".join(b"GET %s HTTP/1.1\r\nHost: x\r\n\r\n" % p for p in (b"/notes.md", b"/site/a%20b.txt", b"/nope"))
    s, f = raw(port, reqs)
    got = [read_answer(f) for _ in range(3)]
    s.close()
    check([g[0] for g in got] == [200, 200, 404] and got[0][2] == NOTES and got[1][2] == SPACED,
          f"three requests sent together: {[g[0] for g in got]}, in order")

    s, f = raw(port, b"GET /notes.md HTTP/1.0\r\n\r\n")
    st, h, b = read_answer(f)
    check(st == 200 and b == NOTES and closed(s, f), "HTTP/1.0: answered, then closed")
    s, f = raw(port, b"GET /notes.md HTTP/1.0\r\nConnection: keep-alive\r\n\r\n")
    st, h, b = read_answer(f)
    s.sendall(b"GET /site/a%20b.txt HTTP/1.0\r\n\r\n")
    st2, _, b2 = read_answer(f)
    check(h.get("connection") == "keep-alive" and b2 == SPACED and closed(s, f),
          "HTTP/1.0 with keep-alive: kept for the next, which closes it")

    for what, req, want in (
            ("not HTTP", b"BLAH\r\n\r\n", 400),
            ("a path climbing out", b"GET /site/../../x HTTP/1.1\r\n\r\n", 400),
            ("a target of 300 bytes", b"GET /" + b"a" * 300 + b" HTTP/1.1\r\n\r\n", 414),
            ("HTTP/2.0", b"GET / HTTP/2.0\r\n\r\n", 505),
            ("a head that does not end", b"GET / HTTP/1.1\r\nX: " + b"y" * 5000, 431)):
        s, f = raw(port, req)
        st, _, _ = read_answer(f)
        check(st == want and closed(s, f), f"{what}: {st}, closed")

    ok = []

    def many():
        try:
            k = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
            for _ in range(2):
                k.request("GET", "/EFI/AXIOM/TEST.AXE")
                ok.append(k.getresponse().read() == esp_axe)
            k.close()
        except OSError as e:
            ok.append(repr(e))
    ts = [threading.Thread(target=many) for _ in range(8)]
    for t in ts:
        t.start()
    for t in ts:
        t.join(60)
    check(ok == [True] * 16, f"eight clients at once, two each: {ok.count(True)} of 16 right")


INDEX = b"<!doctype html><title>site</title><p>the index\n"
SPACED = b"a name with a space in it\n" * 10
NOTES = b"# Notes\n\n- one\n- two\n"


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    plain, tls, serve_port = free_port(), free_port(), free_port()
    import httpsd
    cert, key = httpsd.certs()
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    ctx.load_cert_chain(cert, key)
    serve(plain, "plain")
    serve(tls, "tls", ctx)

    log_path = OUT / "http.log"
    started = time.time()

    def log_has(t):
        try:
            return t in log_path.read_text(errors="replace") and log_path.stat().st_mtime >= started
        except OSError:
            return False
    threading.Thread(target=clients, args=(serve_port, log_has), daemon=True).start()

    stick = OUT / "stick.img"
    mkstick.build(stick, 0x48545450, extra={"site": {"index.html": INDEX, "a b.txt": SPACED},
                                            "notes.md": NOTES})
    h = f"10.0.2.2:{plain}"
    get = lambda path, until, file="": ["type http " + h + path + (" " + file if file else "") + NL,
                                         "until " + until, "wait 0.3"]
    script = ["until log: kept in", "until dhcp: address", "wait 0.5", "type vol 0 rw" + NL, "wait 0.5"]
    script += get("/len/200000", "saved to LEN.TXT", "LEN.TXT")
    script += get("/chunked/300000", "saved to CHUNK.TXT", "CHUNK.TXT")
    script += get("/204", "204 No Content")
    script += get("/continue/5000", "saved to CONT.TXT", "CONT.TXT")
    script += get("/close/100000", "saved to CLOSE.TXT", "CLOSE.TXT")
    script += get("/len/1000", "saved to ONE.TXT", "ONE.TXT")
    script += get("/once/3000", "saved to ONCE.TXT", "ONCE.TXT")
    script += get("/len/4000", "saved to AFTER.TXT", "AFTER.TXT")
    script += get("/bye/2000", "saved to BYE.TXT", "BYE.TXT")
    script += get("/cut/10000", "closed before the end")
    script += get("/badchunks", "chunks are broken")
    script += get("/idleclose/100", "saved to IDLE.TXT", "IDLE.TXT")
    script += ["wait 2"]
    script += get("/len/100", "saved to LAST.TXT", "LAST.TXT")
    for i in (1, 2):
        script += [f"type http -k https://10.0.2.2:{tls}/len/50000 TLS{i}.TXT" + NL, f"until saved to TLS{i}.TXT", "wait 0.3"]
    script += ["type httpd 8080" + NL, "until /__done__", "wait 0.5", "type httpd" + NL, "wait 0.5",
               "type httpd stop" + NL, "wait 0.5", "type poweroff" + NL, "ended"]
    fwd = f"user,hostfwd=tcp:127.0.0.1:{serve_port}-:8080"
    logs = boot_all(OUT, {"http": (script, ["--smp", "4", "--nic", "rtl8139", "--netdev", fwd,
                                            "--stick", stick.relative_to(ROOT).as_posix()], 240, 1)})
    log, err = logs["http"]
    result("AXIOM PANIC" not in log, "no panic")
    result("QEMU ended by itself" in err, "powered off")

    print("the client:")
    img = bytearray(stick.read_bytes())
    _, first, last, _ = fat32.read_gpt(img)[0]
    files, problems = fat32.check(fat32.Fat32(img, first, last - first + 1).mount(), verbose=False)
    result(not problems, f"the stick's FAT, afterwards: {len(problems)} problems")
    for name, n in (("LEN", 200000), ("CHUNK", 300000), ("CONT", 5000), ("CLOSE", 100000), ("ONE", 1000),
                    ("ONCE", 3000), ("AFTER", 4000), ("BYE", 2000), ("IDLE", 100), ("LAST", 100),
                    ("TLS1", 50000), ("TLS2", 50000)):
        got = files.get(f"/{name}.TXT")
        result(got == text(n), f"{name}.TXT: {len(got) if got is not None else 'missing'} of {n} bytes, right")
    p = conns["plain"]
    want = [["/len/200000", "/chunked/300000", "/204", "/continue/5000", "/close/100000"],
            ["/len/1000", "/once/3000", "/len/4000"],
            ["/len/4000", "/bye/2000"], ["/cut/10000"], ["/badchunks"], ["/idleclose/100"], ["/len/100"]]
    result(p == want, "requests by connection: " + " | ".join(", ".join(x) for x in p))
    result(conns["tls"] == [["/len/50000", "/len/50000"]], f"over TLS, both on one: {conns['tls']}")
    kept = log.count("on the connection kept open")
    result(kept == 8, f"used again: {kept} times of 8 (4, 2, 1 plain; 1 over TLS)")
    result("http: the connection kept open had closed; again, on a new one" in log, "the retry, said")
    result("http: HTTP/1.1 204 No Content" in log, "204: no body")
    result("http: the connection closed before the end of the answer" in log, "a body cut short, said")
    result("http: the answer's chunks are broken" in log, "broken chunks, said")
    result("  Transfer-Encoding: chunked" in log, "the chunked one's header shown")

    print("the server:")
    for ok, what in checks:
        result(ok, what)
    result(len(checks) > 20, f"{len(checks)} checks made")
    served = re.findall(r"httpd: 10\.0\.2\.2 (\S+) (\S+): (\d+)", log)
    result(len(served) >= 30, f"{len(served)} requests logged")
    result(re.search(r"httpd: stopped \((\d+) request", log), "stopped")
    print(f"{'all passed' if not FAILS else f'{FAILS} FAILED'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
