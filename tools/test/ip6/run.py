#!/usr/bin/env python3
"""IPv6 (ip6.asm) in QEMU, two ways at once.

    python tools/test/ip6/run.py

'user': one guest on QEMU's user network, whose router advertises
fec0::/64 and stands for the host as fec0::2, which reaches the host's
[::1]. The guest takes its address from the advertisement (SLAAC), pings
fec0::2, fetches with 'http' from a server here on [::1] (a body by
length, one in chunks on the same connection, two over TLS), and runs
'net echo' through sockets with four connections at once.

'hub': two guests on QEMU's socket network, joined by a hub here that is
also their router: fe80::1, prefix 2001:db8:6::/64, DNS on 2001:db8:6::1
for server.six.test. No IPv4. The server guest runs httpd; the hub
advertises the prefix to the client only once the server has its address.
The client pings the server by name and the router by both its
addresses, looks names up, and fetches from the server's httpd by its
global address, by name and by its link-local one; the files it saves are
compared with build/esp. The hub checks what NDP and MLD sent on the way.
Outputs go to build/test/ip6/.
"""
import hashlib
import ipaddress
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
import fat32  # noqa: E402
import mkstick  # noqa: E402

OUT = ROOT / "build" / "test" / "ip6"
ESP = ROOT / "build" / "esp"
FAILS = 0
NL = "\\n"


def result(ok, text):
    global FAILS
    FAILS += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + text)
    return ok


def text(n):
    out = bytearray()
    i = 0
    while len(out) < n:
        out += b"%07d the quick brown fox jumps over the lazy dog\n" % i
        i += 1
    return bytes(out[:n])


def a6(s):
    return ipaddress.IPv6Address(s).packed


def mac_iid(mac):
    m = bytes.fromhex(mac.replace(":", ""))
    return bytes([m[0] ^ 2]) + m[1:3] + b"\xff\xfe" + m[3:]


# --------------------------------------------------------------------------
#  Servers on [::1], for the guest on QEMU's network
# --------------------------------------------------------------------------

def listener6():
    s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("::1", 0))
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


conns = {"plain": [], "tls": []}


def web(kind):
    """HTTP/1.1, kept alive: /len/N by length, /chunked/N in chunks."""
    def handle(c):
        mine = []
        conns[kind].append(mine)
        buf = b""
        rng = random.Random(len(conns[kind]))
        while True:
            while b"\r\n\r\n" not in buf:
                b = c.recv(65536)
                if not b:
                    return
                buf += b
            head, buf = buf.split(b"\r\n\r\n", 1)
            path = head.split(b"\r\n")[0].split(b" ")[1].decode()
            mine.append(path)
            m = re.match(r"/(len|chunked)/(\d+)$", path)
            if not m:
                c.sendall(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
                continue
            body = text(int(m.group(2)))
            if m.group(1) == "len":
                c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
            else:
                out = [b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"]
                i = 0
                while i < len(body):
                    n = rng.randint(1, 20000)
                    piece = body[i:i + n]
                    out.append(b"%x\r\n" % len(piece) + piece + b"\r\n")
                    i += n
                out.append(b"0\r\n\r\n")
                c.sendall(b"".join(out))
    return handle


def echo(c):
    while True:
        b = c.recv(65536)
        if not b:
            return
        c.sendall(b)


# --------------------------------------------------------------------------
#  The hub: a wire between two guests, and their router
# --------------------------------------------------------------------------

ROUTER_MAC = bytes.fromhex("525400aabb01")
ROUTER_LL = a6("fe80::1")
ROUTER_GUA = a6("2001:db8:6::1")
PREFIX = a6("2001:db8:6::")
SERVER_MAC, CLIENT_MAC = "52:54:00:12:34:01", "52:54:00:12:34:02"
SERVER_GUA = PREFIX[:8] + mac_iid(SERVER_MAC)
SERVER_LL = a6("fe80::")[:8] + mac_iid(SERVER_MAC)
CLIENT_GUA = PREFIX[:8] + mac_iid(CLIENT_MAC)
ALL_NODES = a6("ff02::1")


def csum(data):
    if len(data) % 2:
        data += b"\0"
    s = sum(struct.unpack("!%dH" % (len(data) // 2), data))
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return s ^ 0xFFFF


def ip6(src, dst, nh, payload, hops=64, sum_at=None):
    if sum_at is not None:
        pseudo = src + dst + struct.pack("!I3xB", len(payload), nh)
        payload = payload[:sum_at] + b"\0\0" + payload[sum_at + 2:]
        s = csum(pseudo + payload) or 0xFFFF
        payload = payload[:sum_at] + struct.pack("!H", s) + payload[sum_at + 2:]
    return struct.pack("!IHBB", 0x60000000, len(payload), nh, hops) + src + dst + payload


class Hub:
    def __init__(self):
        self.srv = socket.socket()
        self.srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.srv.bind(("127.0.0.1", 0))
        self.srv.listen(4)
        self.port = self.srv.getsockname()[1]
        self.links = []                     # [socket, lock, its MAC or None]
        self.lock = threading.Lock()
        self.seen = {"rs": set(), "dad": set(), "mld": set(), "ns_router": 0, "echo": 0,
                     "dns": [], "ra_to_client": None, "frames": 0}
        self.server_ready_at = None
        self.told_all = False
        threading.Thread(target=self.accept, daemon=True).start()
        threading.Thread(target=self.tick, daemon=True).start()

    def accept(self):
        while True:
            try:
                s, _ = self.srv.accept()
            except OSError:
                return
            link = [s, threading.Lock(), None]
            with self.lock:
                self.links.append(link)
            threading.Thread(target=self.read, args=(link,), daemon=True).start()

    def read(self, link):
        buf = b""
        while True:
            try:
                b = link[0].recv(65536)
            except OSError:
                return
            if not b:
                return
            buf += b
            while len(buf) >= 4:
                n, = struct.unpack(">I", buf[:4])
                if len(buf) < 4 + n:
                    break
                f, buf = buf[4:4 + n], buf[4 + n:]
                self.frame(link, f)

    def out(self, link, f):
        with link[1]:
            try:
                link[0].sendall(struct.pack(">I", len(f)) + f)
            except OSError:
                pass

    def to_mac(self, mac, f):
        for link in list(self.links):
            if mac[0] & 1 or link[2] == mac:
                self.out(link, f)

    def frame(self, src, f):
        self.seen["frames"] += 1
        if len(f) < 14:
            return
        dst, smac, etype = f[:6], f[6:12], f[12:14]
        src[2] = smac
        for link in list(self.links):       # the wire
            if link is not src and (dst[0] & 1 or link[2] == dst or link[2] is None):
                self.out(link, f)
        if etype == b"\x86\xdd" and (dst[0] & 1 or dst == ROUTER_MAC):
            try:
                self.ipv6(smac, f[14:])
            except (struct.error, IndexError):
                pass

    def send6(self, mac, src, dst, nh, payload, hops=64, sum_at=2):
        self.to_mac(mac, mac + ROUTER_MAC + b"\x86\xdd" + ip6(src, dst, nh, payload, hops, sum_at))

    def ra(self, mac, dst):
        icmp = struct.pack("!BBHBBHII", 134, 0, 0, 64, 0, 1800, 0, 0)
        icmp += struct.pack("!BB", 1, 1) + ROUTER_MAC
        icmp += struct.pack("!BBBBIII", 3, 4, 64, 0xC0, 3600, 1800, 0) + PREFIX
        icmp += struct.pack("!BBHI", 5, 1, 0, 1500)
        icmp += struct.pack("!BBHI", 25, 3, 0, 600) + ROUTER_GUA
        self.send6(mac, ROUTER_LL, dst, 58, icmp, hops=255)

    def server_ready(self):
        return self.server_ready_at is not None and time.time() >= self.server_ready_at

    def tick(self):
        while True:
            time.sleep(0.2)
            if self.server_ready() and not self.told_all:
                self.told_all = True
                self.seen["ra_to_client"] = "unsolicited"
                self.ra(b"\x33\x33\x00\x00\x00\x01", ALL_NODES)

    def ipv6(self, smac, p):
        nh, src, dst = p[6], p[8:24], p[24:40]
        body = p[40:40 + struct.unpack("!H", p[4:6])[0]]
        if nh == 0 and body[0] == 58:       # hop-by-hop, then ICMPv6: MLD
            n = (body[1] + 1) * 8
            m = body[n:]
            if m[0] == 143:
                for i in range(struct.unpack("!H", m[6:8])[0]):
                    self.seen["mld"].add((smac, m[8 + 4 + i * 20:8 + 20 + i * 20]))
            return
        if nh == 58:
            t = body[0]
            if t == 133:
                self.seen["rs"].add(smac)
                if smac == bytes.fromhex(SERVER_MAC.replace(":", "")) or self.server_ready():
                    if smac != bytes.fromhex(SERVER_MAC.replace(":", "")) and not self.seen["ra_to_client"]:
                        self.seen["ra_to_client"] = "solicited"
                    self.ra(smac, src)
            elif t == 135:
                target = body[8:24]
                if src == bytes(16):
                    self.seen["dad"].add(target)
                    if target == SERVER_GUA and self.server_ready_at is None:
                        self.server_ready_at = time.time() + 4
                    return
                if target in (ROUTER_LL, ROUTER_GUA):
                    self.seen["ns_router"] += 1
                    na = struct.pack("!BBHI", 136, 0, 0, 0xE0000000) + target
                    na += struct.pack("!BB", 2, 1) + ROUTER_MAC
                    self.send6(smac, target, src, 58, na, hops=255)
            elif t == 128 and dst in (ROUTER_LL, ROUTER_GUA):
                self.seen["echo"] += 1
                self.send6(smac, dst, src, 58, b"\x81" + body[1:])
        elif nh == 17 and dst == ROUTER_GUA:
            sport, dport = struct.unpack("!HH", body[:4])
            if dport == 53:
                self.dns(smac, src, sport, body[8:])

    def dns(self, smac, src, sport, q):
        qid, = struct.unpack("!H", q[:2])
        i, labels = 12, []
        while q[i]:
            labels.append(q[i + 1:i + 1 + q[i]].decode())
            i += 1 + q[i]
        qtype, = struct.unpack("!H", q[i + 1:i + 3])
        name = ".".join(labels).lower()
        self.seen["dns"].append((name, qtype))
        question = q[12:i + 5]
        if name == "server.six.test":
            if qtype == 28:
                ans = b"\xc0\x0c" + struct.pack("!HHIH", 28, 1, 60, 16) + SERVER_GUA
                r = struct.pack("!HHHHHH", qid, 0x8180, 1, 1, 0, 0) + question + ans
            else:
                r = struct.pack("!HHHHHH", qid, 0x8180, 1, 0, 0, 0) + question
        else:
            r = struct.pack("!HHHHHH", qid, 0x8183, 1, 0, 0, 0) + question
        udp = struct.pack("!HHHH", 53, sport, 8 + len(r), 0) + r
        self.send6(smac, ROUTER_GUA, src, 17, udp, sum_at=6)


# --------------------------------------------------------------------------

def stick_files(stick):
    img = bytearray(stick.read_bytes())
    _, first, last, _ = fat32.read_gpt(img)[0]
    return fat32.check(fat32.Fat32(img, first, last - first + 1).mount(), verbose=False)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    import httpsd
    cert, key = httpsd.certs()
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    ctx.load_cert_chain(cert, key)
    try:
        plain, tls, ech = listener6(), listener6(), listener6()
    except OSError as e:
        print(f"FAIL no IPv6 on this host's loopback ({e})")
        return 1
    serve(plain, web("plain"))
    serve(tls, web("tls"), ctx)
    serve(ech, echo)
    P, T, E = (s.getsockname()[1] for s in (plain, tls, ech))
    hub = Hub()

    sticks = {}
    for name, serial in (("user", 0x49503601), ("server", 0x49503602), ("client", 0x49503603)):
        sticks[name] = OUT / f"{name}.img"
        mkstick.build(sticks[name], serial)

    def get(url, file, until=None):
        return [f"type http {url} {file}" + NL, "until " + (until or f"saved to {file}"), "wait 0.3"]

    user = ["until log: kept in", "until ip6: address", "type vol 0 rw" + NL, "wait 0.3",
            "type ping fec0::2 2" + NL, "until 2 sent", "wait 0.3"]
    user += get(f"http://[fec0::2]:{P}/len/200000", "LEN6.TXT")
    user += get(f"http://[fec0::2]:{P}/chunked/300000", "CHUNK6.TXT")
    user += get(f"-k https://[fec0::2]:{T}/len/50000", "TLS6.TXT")
    user += get(f"-k https://[fec0::2]:{T}/len/1000", "TLS6B.TXT")
    user += [f"type run net echo fec0::2 {E} 4 50000" + NL, "until exited with", "wait 0.3",
             "type tcp" + NL, "wait 0.5", "type ip6" + NL, "wait 0.5", "type poweroff" + NL, "ended"]

    sgua = str(ipaddress.IPv6Address(SERVER_GUA))
    sll = str(ipaddress.IPv6Address(SERVER_LL))
    server = ["until log: kept in", "until ip6: address", "type httpd 8080" + NL, "until httpd: serving",
              "until /__done__", "wait 0.5", "type httpd" + NL, "wait 0.5",
              "type ip6" + NL, "wait 0.5", "type poweroff" + NL, "ended"]
    client = ["until log: kept in", "type vol 0 rw" + NL, "wait 0.3", "until ip6: address", "wait 0.3",
              "type ping server.six.test 3" + NL, "until 3 sent", "wait 0.3",
              "type host server.six.test" + NL, "until server.six.test is", "wait 1",
              "type host nothing.six.test" + NL, "until does not exist", "wait 0.3",
              "type ping fe80::1 1" + NL, "until 1 sent", "wait 0.3",
              "type ping 2001:db8:6::1 1" + NL, "until 1 sent", "wait 0.3"]
    client += get(f"http://[{sgua}]:8080/EFI/AXIOM/TEST.AXE", "TEST.AXE")
    client += get("server.six.test:8080/EFI/BOOT/BOOTX64.EFI", "BOOT.EFI")
    client += [f"type http http://[{sll}]:8080/EFI/" + NL, "until <h1>/EFI/</h1>", "wait 0.5",
               "type ip6" + NL, "wait 0.5",
               f"type http http://[{sgua}]:8080/__done__" + NL, "until 404", "wait 0.3",
               "type poweroff" + NL, "ended"]

    stick = lambda n: ["--stick", sticks[n].relative_to(ROOT).as_posix()]
    wire = ["--nic", "rtl8139", "--netdev", f"socket,connect=127.0.0.1:{hub.port}"]
    logs = boot_all(OUT, {
        "user": (user, ["--smp", "2", "--nic", "rtl8139"] + stick("user"), 240),
        "server": (server, ["--smp", "1", "--mac", SERVER_MAC] + wire + stick("server"), 240),
        "client": (client, ["--smp", "1", "--mac", CLIENT_MAC] + wire + stick("client"), 240),
    })

    for name in ("user", "server", "client"):
        log, err = logs[name]
        result("AXIOM PANIC" not in log, f"{name}: no panic")
        result("QEMU ended by itself" in err, f"{name}: powered off")

    print("on QEMU's network:")
    log = logs["user"][0]
    result("ip6: address fec0::5054:ff:fe12:3456/64, router fe80::2, DNS fec0::3" in log,
           "SLAAC from QEMU's router: address, router, DNS")
    result("ip6: link-local address fe80::5054:ff:fe12:3456" in log, "the link-local address, checked first")
    result("2 sent, 2 answered" in log, "ping fec0::2 over ICMPv6")
    files, problems = stick_files(sticks["user"])
    result(not problems, f"the stick's FAT: {len(problems)} problems")
    for name, n in (("LEN6", 200000), ("CHUNK6", 300000), ("TLS6", 50000), ("TLS6B", 1000)):
        got = files.get(f"/{name}.TXT")
        result(got == text(n), f"{name}.TXT: {len(got) if got is not None else 'missing'} of {n} bytes, right")
    result(conns["plain"] == [["/len/200000", "/chunked/300000"]], f"by length then in chunks, on one connection: {conns['plain']}")
    result(conns["tls"] == [["/len/50000", "/len/1000"]], f"over TLS, both on one: {conns['tls']}")
    result(re.search(r"net: echo: 4 of 4 right, 50000 bytes each\nrun: NET exited with 0", log),
           "sockets: 'net echo' with four connections at once over IPv6")
    result("http: GET /len/200000 from [fec0::2] (fec0::2)" in log, "http names the address")

    print("on the hub:")
    slog, clog = logs["server"][0], logs["client"][0]
    result(f"ip6: address {sgua}/64, router fe80::1, DNS 2001:db8:6::1" in slog, f"the server's address: {sgua}")
    cgua = str(ipaddress.IPv6Address(CLIENT_GUA))
    result(f"ip6: address {cgua}/64, router fe80::1, DNS 2001:db8:6::1" in clog, f"the client's: {cgua}")
    result(hub.seen["ra_to_client"] is not None, f"the client heard of the prefix ({hub.seen['ra_to_client']})")
    result(SERVER_GUA in hub.seen["dad"] and SERVER_LL in hub.seen["dad"] and CLIENT_GUA in hub.seen["dad"],
           f"DAD for each address ({len(hub.seen['dad'])} checked)")
    groups = {g for _, g in hub.seen["mld"]}
    want = {a6("ff02::1:ff12:3401"), a6("ff02::1:ff12:3402")}
    result(want <= groups, f"MLD: each joined its solicited-node group ({len(hub.seen['mld'])} reports)")
    result(hub.seen["ns_router"] >= 1, f"the router found by NDP ({hub.seen['ns_router']} solicitations)")
    result("3 sent, 3 answered" in clog, "ping server.six.test: by name, AAAA over DNS on IPv6")
    result(hub.seen["echo"] == 2 and clog.count("1 sent, 1 answered") == 2, "ping the router: link-local and global")
    result(f"server.six.test is {sgua}" in clog, "host: its AAAA")
    result(("server.six.test", 28) in hub.seen["dns"] and ("server.six.test", 1) in hub.seen["dns"],
           "host asked for both kinds")
    result("host: nothing.six.test does not exist" in clog, "host: a name that does not exist")
    files, problems = stick_files(sticks["client"])
    result(not problems, f"the client's stick: {len(problems)} problems")
    for name, path in (("TEST.AXE", "EFI/AXIOM/TEST.AXE"), ("BOOT.EFI", "EFI/BOOT/BOOTX64.EFI")):
        got, want = files.get("/" + name), (ESP / path).read_bytes()
        result(got == want, f"{name}: {len(got) if got is not None else 'missing'} of {len(want)} bytes, the same as build/esp")
    result('<li><a href="AXIOM/">AXIOM/</a>' in clog, "a listing, over the link-local address")
    served = re.findall(r"httpd: (\S+) GET (\S+): (\d+)", slog)
    result(len(served) == 4 and all(a in (cgua, "fe80::5054:ff:fe12:3402") for a, _, _ in served),
           f"httpd logged {len(served)} requests, from the client's addresses")
    print(f"{'all passed' if not FAILS else f'{FAILS} FAILED'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
