#!/usr/bin/env python3
"""Axiom's TCP server side (tcp.asm: tcp_listen, the half-open handshake,
tcp_flow's window) in QEMU, through 'tcp echo', from clients on the host.

    python tools/test/tcp/run.py

One boot, an RTL8139 on QEMU's user network, ports forwarded from the host
to the guest's 7 and 9. Clients here: a short echo; 1 MiB echoed while
being read; 3 MB sent while nothing is read back, with a 4 KiB receive
buffer, so that QEMU stops taking the guest's answers, the guest's send
buffer fills, and its window (16 KiB) closes and stays closed with all of
it held; then read, all of it, in order; both FINs. Twelve clients at
once, 200 KB each. A port nobody listens on: reset. 'tcp stop 7': no more.
Outputs go to build/test/tcp/.
"""
import pathlib
import random
import re
import socket
import sys
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "test"))
from qemu import boot_all  # noqa: E402

OUT = ROOT / "build" / "test" / "tcp"
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


ECHO, DEAD = free_port(), free_port()
said = []                                   # what the clients found
phase = {"stall": False, "many": False, "stopped": False}


def connect(port, rcvbuf=None, timeout=10):
    c = socket.socket()
    if rcvbuf:
        c.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf)
    c.settimeout(timeout)
    c.connect(("127.0.0.1", port))
    return c


def exchange(c, data, chunk=65536):
    """Send DATA while reading; -> what came back."""
    back = bytearray()

    def reader():
        while len(back) < len(data):
            b = c.recv(65536)
            if not b:
                break
            back.extend(b)
    t = threading.Thread(target=reader)
    t.start()
    for i in range(0, len(data), chunk):
        c.sendall(data[i:i + chunk])
    t.join()
    return bytes(back)


def clients():
    deadline = time.time() + 90             # until the guest echoes
    while True:
        try:
            c = connect(ECHO, rcvbuf=4096, timeout=3)
            c.sendall(b"hello")
            if c.recv(100) == b"hello":
                break
            c.close()
        except OSError:
            pass
        if time.time() > deadline:
            said.append(("connect", False, "never echoed"))
            return
        time.sleep(1)
    said.append(("hello", True, ""))
    rng = random.Random(7)
    data = rng.randbytes(1 << 20)
    c.settimeout(20)
    t0 = time.time()
    back = exchange(c, data)
    said.append(("1mib", back == data, f"{len(back)} bytes back in {time.time() - t0:.1f} s"))

    data = rng.randbytes(3_000_000)         # nothing read back for a while
    c.setblocking(False)
    sent, t0 = 0, time.time()
    phase["stall"] = True
    while time.time() - t0 < 8 and sent < len(data):
        try:
            sent += c.send(data[sent:sent + 65536])
        except BlockingIOError:
            time.sleep(0.05)
    phase["stall"] = False
    said.append(("stalled", sent < len(data), f"{sent} of {len(data)} bytes taken while nothing was read"))
    c.setblocking(True)
    c.settimeout(20)
    back = bytearray()

    def reader():
        while len(back) < len(data):
            b = c.recv(65536)
            if not b:
                break
            back.extend(b)
    t = threading.Thread(target=reader)
    t.start()
    c.sendall(data[sent:])
    t.join()
    said.append(("drained", bytes(back) == data, f"{len(back)} of {len(data)} bytes back"))
    time.sleep(3)                           # open a while, for a 'tcp' to see the window again
    c.shutdown(socket.SHUT_WR)
    said.append(("fin", c.recv(10) == b"", "their FIN after ours"))
    c.close()

    phase["many"] = True                    # twelve at once
    oks = [None] * 12

    def one(i):
        try:
            d = random.Random(i).randbytes(200_000)
            k = connect(ECHO, timeout=30)
            oks[i] = exchange(k, d, 7000) == d
            k.shutdown(socket.SHUT_WR)
            oks[i] = oks[i] and k.recv(10) == b""
            k.close()
        except OSError as e:
            oks[i] = repr(e)
    ts = [threading.Thread(target=one, args=(i,)) for i in range(12)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    phase["many"] = False
    said.append(("many", all(x is True for x in oks), f"{sum(x is True for x in oks)} of 12 whole"))

    try:                                    # nobody listens on 9
        k = connect(DEAD, timeout=5)
        k.sendall(b"anyone?")
        got = k.recv(10)
        said.append(("dead", got == b"", f"got {got!r}"))
    except OSError as e:
        said.append(("dead", True, type(e).__name__))
    phase["stopped"] = True


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    threading.Thread(target=clients, daemon=True).start()
    script = ["until dhcp: address", "wait 0.5",
              "type tcp echo 7" + NL, "until echoing"]
    script += ["wait 1.5", "type tcp" + NL] * 14     # the stall shows in some of these
    script += ["wait 25", "type tcp stop 7" + NL, "until no longer listening", "wait 0.5",
               "type tcp echo 0" + NL, "wait 0.3",
               "type tcp" + NL, "wait 0.5",
               "type poweroff" + NL, "ended"]
    fwd = f"user,hostfwd=tcp:127.0.0.1:{ECHO}-:7,hostfwd=tcp:127.0.0.1:{DEAD}-:9"
    logs = boot_all(OUT, {"tcp": (script, ["--smp", "2", "--nic", "rtl8139", "--netdev", fwd], 180, 1)})
    log, err = logs["tcp"]
    result("AXIOM PANIC" not in log, "no panic")
    result("QEMU ended by itself" in err, "powered off")
    for name, ok, why in said:
        result(ok, f"{name}: {why}")
    result(len(said) == 7, f"every client case ran ({len(said)} of 7)")
    result(re.search(r"window offered 0 of 16384, 16384 held", log),
           "while nothing was read: the guest's window closed, all 16 KiB held")
    result(re.search(r"window offered 1\d{4} of 16384, 0 held", log), "and it opened again")
    m = re.search(r"tcp: port 7: no longer listening \((\d+) accepted\)", log)
    result(m and int(m.group(1)) >= 14, f"'tcp stop 7': {m.group(1) if m else '?'} accepted")
    result("cannot listen on port 0" in log or "usage: tcp" in log, "port 0 refused")
    tail = log[log.find("no longer listening"):]
    result("listening on port" not in tail, "nothing listens after it")
    print(f"{'all passed' if not FAILS else f'{FAILS} FAILED'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
