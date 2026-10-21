#!/usr/bin/env python3
"""TCP to Axiom in QEMU, timed from the host: 'tcp echo' over an RTL8139.

    python tools/test/bench/net.py [--esp DIR] [--label NAME]

One boot (build/esp, or --esp DIR), QEMU's user network, a port forwarded
from the host to the guest's echo port. From here: connections opened and
closed, one-byte round trips, and 8 MiB echoed while being read back
(throughput both ways at once). Prints each and writes them to
build/test/bench/<label>-net.json. The host is shared: compare builds run
close in time.
"""
import argparse
import json
import pathlib
import socket
import sys
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "test"))
from qemu import boot_all  # noqa: E402

OUT = ROOT / "build" / "test" / "bench"
NL = "\\n"
ROUND_TRIPS = 2000
CONNECTS = 50
BULK = 8 << 20
found = {}


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


PORT = free_port()


def connect(timeout=10):
    c = socket.socket()
    c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    c.settimeout(timeout)
    c.connect(("127.0.0.1", PORT))
    return c


def clients():
    deadline = time.time() + 120            # until the guest echoes
    while True:
        try:
            c = connect(3)
            c.sendall(b"hello")
            if c.recv(100) == b"hello":
                break
            c.close()
        except OSError:
            pass
        if time.time() > deadline:
            found["error"] = "never echoed"
            return
        time.sleep(1)
    c.settimeout(20)
    for _ in range(100):                    # warm
        c.sendall(b"x")
        c.recv(1)
    t0 = time.perf_counter()
    for _ in range(ROUND_TRIPS):
        c.sendall(b"x")
        if c.recv(1) != b"x":
            found["error"] = "round trip lost"
            return
    found["round trip (1 byte)"] = (time.perf_counter() - t0) / ROUND_TRIPS * 1e9

    data = bytes(range(256)) * (BULK // 256)
    back = bytearray()

    def reader():
        while len(back) < len(data):
            b = c.recv(65536)
            if not b:
                break
            back.extend(b)
    t0 = time.perf_counter()
    t = threading.Thread(target=reader)
    t.start()
    for i in range(0, len(data), 65536):
        c.sendall(data[i:i + 65536])
    t.join()
    took = time.perf_counter() - t0
    found["echo 8 MiB"] = took * 1e9
    found["echo MB/s"] = len(data) / took / 1e6
    found["echo whole"] = bytes(back) == data
    c.close()

    t0 = time.perf_counter()
    for _ in range(CONNECTS):
        k = connect()
        k.sendall(b"y")
        k.recv(1)
        k.close()
    found["connect, echo, close"] = (time.perf_counter() - t0) / CONNECTS * 1e9
    found["done"] = True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--esp", default="")
    ap.add_argument("--label", default="last")
    args = ap.parse_args()
    threading.Thread(target=clients, daemon=True).start()
    script = ["until dhcp: address", "wait 0.5", "type tcp echo 7" + NL, "until echoing",
              "wait 45", "type poweroff" + NL, "ended"]
    fwd = f"user,hostfwd=tcp:127.0.0.1:{PORT}-:7"
    extra = ["--smp", "4", "--nic", "rtl8139", "--netdev", fwd]
    if args.esp:
        extra += ["--esp", args.esp]
    # (the clients take a few seconds of the 45 the guest stays up)
    boot_all(OUT, {args.label + "-net": (script, extra, 200, 1)})
    if not found.get("done"):
        print("not finished:", found)
        return 1
    for k, v in found.items():
        if isinstance(v, float) and k != "echo MB/s":
            print(f"  {k:<24} {v / 1e3:10.1f} us")
    print(f"  {'echo MB/s':<24} {found['echo MB/s']:10.2f}   whole: {found['echo whole']}")
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / f"{args.label}-net.json").write_text(json.dumps(found, indent=1))
    return 0 if found["echo whole"] else 1


if __name__ == "__main__":
    sys.exit(main())
