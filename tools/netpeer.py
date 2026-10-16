#!/usr/bin/env python3
"""A deliberately unreliable network peer for Axiom's TCP, on QEMU's socket
network backend: 10.1.0.1, answering ARP and ping, and an HTTP server whose
behaviour depends on the port:

    80  /big: 200000 bytes; drops the first SYN, the first copy of the
        request, and first copies of some data segments; reorders and
        duplicates others
    81  nothing listens: a reset (connection refused)
    82  accepts, reads the request, then resets the connection
    83  silent: drops everything (for ctrl+C)
    84  a zero window for 3 s after the handshake (Axiom must probe it)
    85  offers MSS 64, so the request comes in many segments; drops the
        second one once (Axiom's fast retransmit)

    python tools/netpeer.py [--port 5555] [--seconds 120]
    python tools/run.py --nic rtl8139 --netdev "socket,connect=127.0.0.1:5555"

then in Axiom: ip 10.1.0.2/24, and http 10.1.0.1/big and the others.
"""
import argparse
import random
import select
import socket
import struct
import time

PEER_MAC = bytes.fromhex("525400aabbcc")
PEER_IP = bytes([10, 1, 0, 1])
BIG = bytes((i * 31 + (i >> 7)) & 0xFF for i in range(200000))
FIN, SYN, RST, PSH, ACK = 1, 2, 4, 8, 16


def csum(data):
    if len(data) % 2:
        data += b"\0"
    s = sum(struct.unpack("!%dH" % (len(data) // 2), data))
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return s ^ 0xFFFF


def seq_lt(a, b):
    return ((a - b) & 0xFFFFFFFF) > 0x7FFFFFFF


class Peer:
    def __init__(self, sock):
        self.sock = sock
        self.buf = b""
        self.axiom_mac = None
        self.axiom_ip = None
        self.conns = {}
        self.ipid = 0
        self.log = []

    def say(self, text):
        line = "%7.3f %s" % (time.monotonic() - T0, text)
        print(line, flush=True)

    # -- frames --------------------------------------------------------------
    def send_frame(self, frame):
        self.sock.sendall(struct.pack(">I", len(frame)) + frame)

    def frames(self):
        while len(self.buf) >= 4:
            n, = struct.unpack(">I", self.buf[:4])
            if len(self.buf) < 4 + n:
                break
            f, self.buf = self.buf[4:4 + n], self.buf[4 + n:]
            yield f

    def ip_out(self, proto, payload):
        self.ipid += 1
        h = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(payload), self.ipid, 0, 64,
                        proto, 0, PEER_IP, self.axiom_ip)
        h = h[:10] + struct.pack("!H", csum(h)) + h[12:]
        self.send_frame(self.axiom_mac + PEER_MAC + b"\x08\x00" + h + payload)

    def handle(self, f):
        etype, = struct.unpack_from("!H", f, 12)
        if etype == 0x0806:
            op, = struct.unpack_from("!H", f, 20)
            if op == 1 and f[38:42] == PEER_IP:
                self.axiom_mac, self.axiom_ip = f[22:28], f[28:32]
                reply = (f[6:12] + PEER_MAC + b"\x08\x06" + f[14:20] + b"\x00\x02" +
                         PEER_MAC + PEER_IP + f[22:28] + f[28:32])
                self.send_frame(reply)
            return
        if etype != 0x0800:
            return
        h = f[14:]
        ihl = (h[0] & 15) * 4
        total, = struct.unpack_from("!H", h, 2)
        if h[16:20] != PEER_IP:
            return
        self.axiom_mac, self.axiom_ip = f[6:12], h[12:16]
        body = h[ihl:total]
        if h[9] == 1 and body[0] == 8:
            echo = b"\x00\x00\x00\x00" + body[4:]
            echo = echo[:2] + struct.pack("!H", csum(echo)) + echo[4:]
            self.ip_out(1, echo)
        elif h[9] == 6:
            pseudo = h[12:20] + struct.pack("!BBH", 0, 6, len(body))
            if csum(pseudo + body) != 0:
                self.say("BAD TCP checksum from Axiom")
                self.log.append("bad checksum")
                return
            self.tcp_in(body)

    # -- TCP -----------------------------------------------------------------
    def tcp_out(self, c, flags, seq, data=b"", window=None, mss=None):
        opts = struct.pack("!BBH", 2, 4, mss) if mss else b""
        hl = 20 + len(opts)
        w = c["wnd_offer"] if window is None else window
        seg = struct.pack("!HHIIBBHHH", c["lport"], c["rport"], seq & 0xFFFFFFFF,
                          c["rcv_nxt"] & 0xFFFFFFFF, hl << 2, flags, w, 0, 0) + opts + data
        pseudo = PEER_IP + self.axiom_ip + struct.pack("!BBH", 0, 6, len(seg))
        seg = seg[:16] + struct.pack("!H", csum(pseudo + seg)) + seg[18:]
        self.ip_out(6, seg)

    def tcp_in(self, seg):
        sport, dport, seq, ack, off, flags, wnd = struct.unpack_from("!HHIIBBH", seg)
        data = seg[(off >> 4) * 4:]
        key = (sport, dport)
        c = self.conns.get(key)
        if flags & SYN and c is None:
            self.syn(sport, dport, seq, seg)
            return
        if c is None:
            if not flags & RST:
                self.say(f"segment for no connection {sport}->{dport} flags {flags:#x}")
            return
        if c["port"] == 83:
            return
        if flags & RST:
            self.say(f"[{dport}] reset by Axiom")
            c["done"] = "reset by Axiom"
            del self.conns[key]
            return
        if flags & SYN:
            # our SYN-ACK was lost or slow: send it again
            self.tcp_out(c, SYN | ACK, c["iss"], mss=c["mss_offer"])
            return
        if flags & ACK:
            self.ack_in(c, ack, wnd, bool(data) or bool(flags & FIN))
        if data and seq_lt(seq, c["rcv_nxt"]) and seq_lt(c["rcv_nxt"], seq + len(data)):
            cut = (c["rcv_nxt"] - seq) & 0xFFFFFFFF  # partly new: keep the new part
            data, seq = data[cut:], c["rcv_nxt"]
        if data:
            if seq == c["rcv_nxt"]:
                c["rx_segs"] += 1
                if c["port"] == 80 and not c["dropped_req"]:
                    c["dropped_req"] = True
                    self.say(f"[{c['port']}] dropping the request's first copy")
                    return
                if c["port"] == 85 and c["rx_segs"] == 2:
                    self.say("[85] dropping the request's second segment")
                    c["rx_segs"] += 100
                    return
                if c["wnd_offer"] == 0:
                    self.say(f"[{c['port']}] zero window: {len(data)} byte(s) not taken (a probe)")
                    c["probes"] += 1
                    self.tcp_out(c, ACK, c["snd_nxt"])
                    return
                c["req"] += data
                c["rcv_nxt"] += len(data)
                self.tcp_out(c, ACK, c["snd_nxt"])
                if b"\r\n\r\n" in c["req"] and not c["answered"]:
                    self.request(c)
            else:
                if seq_lt(seq, c["rcv_nxt"]):
                    c["dup_rx"] += 1
                    self.tcp_out(c, ACK, c["snd_nxt"])
                else:
                    c["gap_rx"] += 1
                    # port 85: three duplicate ACKs at once, for a fast retransmit
                    for _ in range(3 if c["port"] == 85 else 1):
                        self.tcp_out(c, ACK, c["snd_nxt"])
        if flags & FIN and seq + len(data) == c["rcv_nxt"]:
            c["rcv_nxt"] += 1
            c["fin_rx"] = True
            self.tcp_out(c, ACK, c["snd_nxt"])
            if c["fin_sent"] and c["snd_una"] == c["snd_nxt"]:
                self.finish(c)

    def syn(self, sport, dport, seq, seg):
        if dport == 81:
            c = {"lport": dport, "rport": sport, "rcv_nxt": seq + 1, "wnd_offer": 0}
            self.tcp_out(c, RST | ACK, 0)
            self.say("[81] refused")
            return
        if dport == 83:
            return
        if dport == 80 and not self.__dict__.get("dropped_syn"):
            self.dropped_syn = True
            self.say("[80] dropping the first SYN")
            return
        mss = 1460
        opts = seg[20:(seg[12] >> 4) * 4]
        if len(opts) >= 4 and opts[0] == 2:
            mss = min(1460, struct.unpack_from("!H", opts, 2)[0])
        c = dict(port=dport, lport=dport, rport=sport, iss=random.getrandbits(32),
                 rcv_nxt=seq + 1, wnd_offer=0 if dport == 84 else 65535,
                 mss_offer=64 if dport == 85 else 1460, peer_mss=mss, req=b"",
                 answered=False, out=b"", snd_una=0, snd_nxt=0, wnd=0, dups=0,
                 last=time.monotonic(), fin_sent=False, fin_rx=False, rx_segs=0,
                 dropped_req=False, sent=set(), retrans=0, dup_rx=0, gap_rx=0,
                 probes=0, opened_at=time.monotonic() + 3, done=None, segs=0)
        c["snd_una"] = c["snd_nxt"] = c["iss"] + 1
        self.conns[(sport, dport)] = c
        self.tcp_out(c, SYN | ACK, c["iss"], mss=c["mss_offer"])
        self.say(f"[{dport}] SYN from port {sport}, its MSS {mss}")

    def request(self, c):
        c["answered"] = True
        line = c["req"].split(b"\r\n")[0].decode(errors="replace")
        self.say(f"[{c['port']}] request: {line!r} ({len(c['req'])} bytes)")
        if c["port"] == 82:
            self.tcp_out(c, RST | ACK, c["snd_nxt"])
            self.say("[82] reset sent")
            del self.conns[(c["rport"], c["lport"])]
            return
        if c["port"] == 80 and line.startswith("GET /big "):
            body = BIG
        else:
            body = ("port %d says hello; you asked for %s\n" % (c["port"], line)).encode()
        c["out"] = b"HTTP/1.0 200 OK\r\nContent-Type: application/octet-stream\r\n" + \
            b"Content-Length: %d\r\n\r\n" % len(body) + body
        c["base"] = c["snd_una"]
        self.pump(c)

    def ack_in(self, c, ack, wnd, carries):
        c["wnd"] = wnd
        if seq_lt(c["snd_una"], ack) and not seq_lt(c["snd_nxt"], ack):
            c["snd_una"] = ack
            c["dups"] = 0
            c["last"] = time.monotonic()
            if c["fin_sent"] and ack == c["snd_nxt"] and c["fin_rx"]:
                self.finish(c)
                return
            self.pump(c)
        elif ack == c["snd_una"] and not carries and c["snd_una"] != c["snd_nxt"]:
            c["dups"] += 1
            if c["dups"] == 3:
                self.say(f"[{c['port']}] three duplicate ACKs: resending from {ack - c['base']}")
                self.resend(c)

    def pump(self, c):
        if not c["answered"] or "base" not in c:
            return
        limit = min(c["wnd"], 16 * 1460)
        while True:
            off = c["snd_nxt"] - c["base"]
            flight = c["snd_nxt"] - c["snd_una"]
            if off >= len(c["out"]):
                break
            n = min(c["peer_mss"], len(c["out"]) - off, limit - flight)
            if n <= 0:
                break
            self.data_out(c, off, n)
            c["snd_nxt"] += n
        if c["snd_nxt"] - c["base"] >= len(c["out"]) and not c["fin_sent"]:
            c["fin_sent"] = True
            self.tcp_out(c, FIN | ACK, c["snd_nxt"])
            c["snd_nxt"] += 1

    def data_out(self, c, off, n, again=False):
        data = c["out"][off:off + n]
        seq = c["base"] + off
        c["segs"] += 1
        if c["port"] == 80 and not again and off not in c["sent"]:
            c["sent"].add(off)
            k = c["segs"]
            if k % 23 == 5:
                self.say(f"[80] dropping data at {off}")
                return
            if k % 31 == 7:
                c["held"] = (off, n)                # sent after the next one
                return
            if k % 17 == 3:
                self.tcp_out(c, ACK | PSH, seq, data)   # and a duplicate
        self.tcp_out(c, ACK | PSH, seq, data)
        if "held" in c and c["held"][0] != off:
            ho, hn = c.pop("held")
            self.tcp_out(c, ACK | PSH, c["base"] + ho, c["out"][ho:ho + hn])

    def resend(self, c):
        c["retrans"] += 1
        c["last"] = time.monotonic()
        off = c["snd_una"] - c["base"]
        if off < len(c["out"]):
            self.data_out(c, off, min(c["peer_mss"], len(c["out"]) - off), again=True)
        elif c["fin_sent"]:
            self.tcp_out(c, FIN | ACK, c["snd_una"])

    def tick(self):
        now = time.monotonic()
        for c in list(self.conns.values()):
            if c["port"] == 84 and c["wnd_offer"] == 0 and now >= c["opened_at"]:
                c["wnd_offer"] = 65535
                self.say("[84] window open")
                self.tcp_out(c, ACK, c["snd_nxt"])
            if c["snd_una"] != c["snd_nxt"] and now - c["last"] > 0.4:
                self.say(f"[{c['port']}] timeout: going back to {c['snd_una'] - c.get('base', c['snd_una'])}")
                c["retrans"] += 1
                c["last"] = now
                c["snd_nxt"] = c["snd_una"]
                c["fin_sent"] = False               # it goes again after the data
                self.pump(c)

    def finish(self, c):
        key = (c["rport"], c["lport"])
        if key not in self.conns:
            return
        del self.conns[key]
        ok = c["snd_una"] - c["base"] - 1 == len(c["out"]) if "base" in c else False
        self.say(f"[{c['port']}] closed: {'all data acknowledged' if ok else 'INCOMPLETE'}; "
                 f"{c['retrans']} resends by us, {c['dup_rx']} old and {c['gap_rx']} early "
                 f"segments from Axiom, {c['probes']} window probes")


def main():
    global T0
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=5555)
    ap.add_argument("--seconds", type=float, default=120)
    opts = ap.parse_args()
    random.seed(1)
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", opts.port))
    srv.listen(1)
    print(f"listening on 127.0.0.1:{opts.port}", flush=True)
    s, _ = srv.accept()
    T0 = time.monotonic()
    peer = Peer(s)
    end = T0 + opts.seconds
    while time.monotonic() < end:
        r, _, _ = select.select([s], [], [], 0.05)
        if r:
            try:
                chunk = s.recv(65536)
            except ConnectionError:
                break
            if not chunk:
                break
            peer.buf += chunk
            for f in peer.frames():
                peer.handle(f)
        peer.tick()
    print("done", flush=True)


if __name__ == "__main__":
    main()
