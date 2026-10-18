#!/usr/bin/env python3
"""Sockets for ring-3 programs (socket.asm) in QEMU, through NET.AXE
(src/user/net.asm), with servers and clients here on the host.

    python tools/test/net/run.py

One boot, an RTL8139 on QEMU's user network, where the guest reaches the
host as 10.0.2.2. Here: an echo server, a TLS echo server with the test
certificate for axiom.test (a CA Axiom does not trust), a server that
answers once the client has finished, one that resets what it takes, a DNS
server on 127.0.0.1:53 if it can be had (the guest is then told to ask
10.0.2.2), and clients for the guest's 'net serve' on a forwarded port.

In the guest: 'net test' (narrower capabilities and what they refuse, bad
arguments, a failure and how it is told, the 32-socket limit, a reset
connection; QEMU's network never refuses a SYN, so a refused one is not
tried); 'net get' plain, then over TLS checked (refused: the certificate)
and unchecked; 'net echo' with eight connections at once, then four over
TLS at once, then eight by name if there is DNS; 'net serve' with three
clients one after another; 'sockets' at the end: none left.
Outputs go to build/test/net/.
"""
import hashlib
import pathlib
import random
import re
import socket
import ssl
import struct
import subprocess
import sys
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "test"))
sys.path.insert(0, str(ROOT / "tools"))
from qemu import boot_all  # noqa: E402

OUT = ROOT / "build" / "test" / "net"
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


def listener(port):
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port))
    s.listen(32)
    return s


def serve(s, handle, wrap=None):
    def loop():
        while True:
            try:
                c, _ = s.accept()
            except OSError:
                return
            threading.Thread(target=one, args=(c,), daemon=True).start()

    def one(c):
        try:
            if wrap:
                c = wrap.wrap_socket(c, server_side=True)
            handle(c)
        except (OSError, ssl.SSLError):
            pass
        finally:
            try:
                c.close()
            except OSError:
                pass
    threading.Thread(target=loop, daemon=True).start()


def echo(c):
    while True:
        b = c.recv(65536)
        if not b:
            return
        c.sendall(b)


heard = []                                  # what the answering server was sent


def answer(c):
    """Reads until the client has finished, then says what it heard."""
    got = b""
    while True:
        b = c.recv(65536)
        if not b:
            break
        got += b
    heard.append(got)
    c.sendall(b"you sent %d bytes\r\nsha256 %s\r\nbye\n" % (len(got), hashlib.sha256(got).hexdigest().encode()))


def tls_answer(c):
    """Over TLS: reads a line, says it back with a few more."""
    got = b""
    while not got.endswith(b"\n"):
        b = c.recv(4096)
        if not b:
            return
        got += b
    c.sendall(b"over TLS: " + got + b"line two\nline three\n")
    c.unwrap() if hasattr(c, "unwrap") else None


def reset(c):
    c.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))


def dns_server():
    """axiom.test and its names are 10.0.2.2; anything else does not exist.
    -> the socket, or None if port 53 cannot be had."""
    try:
        u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        u.bind(("127.0.0.1", 53))
    except OSError:
        return None
    asked = []

    def loop():
        while True:
            try:
                q, peer = u.recvfrom(512)
            except OSError:
                return
            qid, flags, qd = struct.unpack(">HHH", q[:6])
            i, labels = 12, []
            while q[i]:
                labels.append(q[i + 1:i + 1 + q[i]].decode())
                i += 1 + q[i]
            name = ".".join(labels).lower()
            asked.append(name)
            question = q[12:i + 5]
            if name == "axiom.test" or name.endswith(".axiom.test"):
                ans = b"\xc0\x0c" + struct.pack(">HHIH", 1, 1, 60, 4) + socket.inet_aton("10.0.2.2")
                r = struct.pack(">HHHHHH", qid, 0x8180, 1, 1, 0, 0) + question + ans
            else:
                r = struct.pack(">HHHHHH", qid, 0x8183, 1, 0, 0, 0) + question
            u.sendto(r, peer)
    threading.Thread(target=loop, daemon=True).start()
    return asked


ECHO, TLS_ECHO, ANSWER, TLS_ANSWER, RESET, SERVE = (free_port() for _ in range(6))
served = []


def serve_clients(log_count):
    """Three clients for the guest's 'net serve', one after another."""
    deadline = time.time() + 200
    # 'net test' listens on 7777 first, and says so too: wait for 'net serve'
    while log_count("listens on port 7777") < 2 and time.time() < deadline:
        time.sleep(0.3)
    for i in range(3):
        data = random.Random(i).randbytes([1000, 100_000, 300_000][i])
        try:
            c = socket.create_connection(("127.0.0.1", SERVE), timeout=20)
            back = bytearray()

            def reader():
                while True:
                    b = c.recv(65536)
                    if not b:
                        break
                    back.extend(b)
            t = threading.Thread(target=reader)
            t.start()
            c.sendall(data)
            c.shutdown(socket.SHUT_WR)
            t.join(30)
            served.append(bytes(back) == data)
            c.close()
        except OSError as e:
            served.append(repr(e))


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    import httpsd
    cert, key = httpsd.certs()
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    ctx.load_cert_chain(cert, key)
    serve(listener(ECHO), echo)
    serve(listener(ANSWER), answer)
    serve(listener(TLS_ECHO), echo, ctx)
    serve(listener(TLS_ANSWER), tls_answer, ctx)
    serve(listener(RESET), reset)
    dns = dns_server()
    print(f"DNS on 127.0.0.1:53: {'yes' if dns is not None else 'no (the lookups are not tried)'}")

    log_path = OUT / "net.log"
    started = time.time()

    def log_count(text):
        try:
            if log_path.stat().st_mtime < started:
                return 0
            return log_path.read_text(errors="replace").count(text)
        except OSError:
            return 0
    threading.Thread(target=serve_clients, args=(log_count,), daemon=True).start()

    run = lambda args: ["type run net " + args + NL, "until exited with", "wait 0.3"]
    stick = OUT / "stick.img"
    subprocess.run([sys.executable, str(ROOT / "tools" / "mkstick.py"), str(stick)],
                   cwd=ROOT, check=True, capture_output=True)
    script = ["until log: kept in", "until dhcp: address", "wait 0.5"]
    script += run(f"test {RESET}")
    # (typed through unicode_escape: "\\\\n" arrives as the two characters net.asm undoes)
    script += run(f"get 10.0.2.2 {ANSWER} hello\\\\r\\\\nfrom ring 3\\\\n")
    script += run(f"get 10.0.2.2 {TLS_ANSWER} tls hi")
    script += run(f"get 10.0.2.2 {TLS_ANSWER} insecure hi there\\\\n")
    script += run(f"echo 10.0.2.2 {ECHO} 8 200000")
    script += run(f"echo 10.0.2.2 {TLS_ECHO} 4 100000 insecure")
    if dns is not None:
        script += ["type ip 10.0.2.15/24 10.0.2.2 10.0.2.2" + NL, "wait 0.5"]
        script += run(f"echo axiom.test {ECHO} 8 20000")
        script += run(f"get nothing.here {ECHO} hi")
    script += run("serve 7777 3")
    script += ["wait 12", "type sockets" + NL, "wait 0.5", "type objects" + NL, "wait 0.5",
               "type poweroff" + NL, "ended"]
    fwd = f"user,hostfwd=tcp:127.0.0.1:{SERVE}-:7777"
    logs = boot_all(OUT, {"net": (script, ["--smp", "4", "--nic", "rtl8139", "--netdev", fwd,
                                            "--stick", stick.relative_to(ROOT).as_posix()], 300)})
    log, err = logs["net"]
    result("AXIOM PANIC" not in log, "no panic")
    result("QEMU ended by itself" in err, "powered off")

    m = re.search(r"net: all (\d+) checks passed\nrun: NET exited with 0", log)
    result(m, f"net test: {'all ' + m.group(1) + ' checks passed' if m else 'see the log'}")
    for line in re.findall(r"net: check .*", log):
        print("     " + line)

    sent = b"hello\r\nfrom ring 3\n"
    result(heard and heard[0] == sent, f"plain get: the server heard {heard[0] if heard else None!r}")
    want = f"net| you sent {len(sent)} bytes\nnet| sha256 {hashlib.sha256(sent).hexdigest()}\nnet| bye\nnet: 81 bytes, ended\nrun: NET exited with 0"
    want = want.replace("81", str(len(b"you sent %d bytes\r\nsha256 %s\r\nbye\n" % (len(sent), hashlib.sha256(sent).hexdigest().encode()))))
    quiet = "\n".join(l for l in log.split("\n") if not l.startswith("ip6: "))  # (said meanwhile)
    result(want in quiet, "plain get: its answer, a line at a time, then the end")
    result(re.search(r"net: failed, state 6, why 13, TLS error 14\nrun: NET exited with 3", log),
           "TLS checked: refused, the certificate (NETW_TLS, TLE_CERT)")
    n = len(b"over TLS: hi there\nline two\nline three\n")
    result(f"net| over TLS: hi there\nnet| line two\nnet| line three\nnet: {n} bytes, ended" in log,
           "TLS unchecked: the answer, then close_notify")
    result(re.search(r"net: echo: 8 of 8 right, 200000 bytes each\nrun: NET exited with 0", log),
           "eight plain connections at once, 200 KB each")
    result(re.search(r"net: echo: 4 of 4 right, 100000 bytes each\nrun: NET exited with 0", log),
           "four TLS sessions at once, 100 KB each")
    if dns is not None:
        result(re.search(r"net: echo: 8 of 8 right, 20000 bytes each\nrun: NET exited with 0", log),
               f"eight by name at once ({dns.count('axiom.test')} lookups of axiom.test)")
        result(re.search(r"net: failed, state 6, why 4, TLS error 0\nrun: NET exited with 3", log),
               "a name that does not exist: NETW_NOHOST")
    result(served == [True] * 3, f"'net serve': {served}")
    result(re.search(r"net: served 3: 300000 bytes back\nrun: NET exited with 0", log), "and it said so")
    m = re.search(r"sockets: (\d+) live, (\d+) made", log)
    result(m and m.group(1) == "0", f"none left at the end ({m.group(0) if m else '?'})")
    print(f"{'all passed' if not FAILS else f'{FAILS} FAILED'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
