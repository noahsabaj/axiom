"""A hand-made TLS 1.3 server for the client's tests: just enough of RFC 8446
to do what OpenSSL will not on request (a wrong Finished, KeyUpdate, padded
and empty records, handshake messages cut across records, tickets), on the
pure-Python references in tools/test/tls/run.py. Its certificate and
signature are random bytes (the client is told not to check them, as by
http -k) unless it is given a certificate chain and a signer, which gets
what CertificateVerify signs and returns the scheme and the signature.

    s = MiniServer(rng, **knobs)
    s.receive(bytes from the client) -> bytes for the client
    s.send_app(data), s.key_update(request), s.ticket(), s.close()
        -> bytes for the client; s.app holds what the client sent
"""
import hashlib
import hmac
import importlib.util
import pathlib

_here = pathlib.Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("tls_ref", _here.parent / "tls" / "run.py")
ref = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ref)

H = lambda b: hashlib.sha256(b).digest()


def u16(n):
    return n.to_bytes(2, "big")


def u24(n):
    return n.to_bytes(3, "big")


def msg(kind, body):
    return bytes([kind]) + u24(len(body)) + body


class Keys:
    def __init__(self, secret):
        self.secret = secret
        self.key = ref.expand_label(secret, b"key", b"", 16)
        self.iv = ref.expand_label(secret, b"iv", b"", 12)
        self.seq = 0

    def nonce(self):
        n = bytes(a ^ b for a, b in zip(self.iv, self.seq.to_bytes(12, "big")))
        self.seq += 1
        return n

    def seal(self, kind, content, pad=0):
        inner = content + bytes([kind]) + bytes(pad)
        hdr = bytes([23, 3, 3]) + u16(len(inner) + 16)
        ct, tag = ref.gcm_seal(self.key, self.nonce(), hdr, inner)
        return hdr + ct + tag

    def open(self, hdr, body):
        ct, tag = body[:-16], body[-16:]
        nonce = self.nonce()
        pt, _ = ref.gcm_seal(self.key, nonce, hdr, ct)        # CTR both ways
        if ref.gcm_seal(self.key, nonce, hdr, pt)[1] != tag:
            raise ValueError("a record from the client fails its tag")
        pt = pt.rstrip(b"\0")
        return pt[-1], pt[:-1]

    def update(self):
        return Keys(ref.expand_label(self.secret, b"traffic upd", b"", 32))


class MiniServer:
    def __init__(self, rng, bad_finished=False, split=None, pad=0, ccs=True,
                 cert_size=600, chain=None, signer=None):
        self.rng = rng
        self.bad_finished = bad_finished
        self.split = split            # None, "each" (a record per message) or a size
        self.pad = pad
        self.ccs = ccs
        self.cert_size = cert_size
        self.chain = chain            # DER certificates, the server's first
        self.signer = signer
        self.inbuf = b""
        self.state = "hello"
        self.app = b""
        self.events = []              # what the client's records were
        self.c = self.s = None

    # -- records in --
    def receive(self, data):
        self.inbuf += data
        out = b""
        while len(self.inbuf) >= 5:
            n = int.from_bytes(self.inbuf[3:5], "big")
            if len(self.inbuf) < 5 + n:
                break
            hdr, body = self.inbuf[:5], self.inbuf[5:5 + n]
            self.inbuf = self.inbuf[5 + n:]
            out += self.record(hdr, body)
        return out

    def record(self, hdr, body):
        if hdr[0] == 20:
            self.events.append("ccs")
            return b""
        if self.state == "hello":
            assert hdr[0] == 22 and body[0] == 1, "expected a ClientHello"
            return self.hello(body)
        assert hdr[0] == 23, f"record type {hdr[0]} after the handshake began"
        kind, content = self.c.open(hdr, body)
        if kind == 21:
            self.events.append(f"alert {content[1]}")
        elif kind == 22 and content[0] == 20:
            want = hmac.new(ref.expand_label(self.c.secret, b"finished", b"", 32),
                            H(self.th_sf), hashlib.sha256).digest()
            assert content[4:] == want, "the client's Finished is wrong"
            self.events.append("finished")
            self.c = Keys(self.c_ap)
        elif kind == 22 and content[0] == 24:
            self.events.append(f"keyupdate {content[4]}")
            self.c = self.c.update()
        elif kind == 23:
            self.app += content
            self.events.append(f"data {len(content)}")
        else:
            self.events.append(f"type {kind}")
        return b""

    # -- the handshake --
    def hello(self, ch):
        self.events.append("clienthello")
        b = ch[4:]
        sid = b[35:35 + b[34]]
        p = 35 + b[34]
        p += 2 + int.from_bytes(b[p:p + 2], "big")
        p += 1 + b[p]
        end = p + 2 + int.from_bytes(b[p:p + 2], "big")
        p += 2
        share = None
        while p < end:
            t, n = int.from_bytes(b[p:p + 2], "big"), int.from_bytes(b[p + 2:p + 4], "big")
            if t == 0x33:
                assert b[p + 6:p + 10] == bytes([0, 0x1d, 0, 32])
                share = b[p + 10:p + 42]
            p += 4 + n
        priv = self.rng.randbytes(32)
        pub = ref.x25519(priv, (9).to_bytes(32, "little"))
        shared = ref.x25519(priv, share)
        exts = (u16(0x2b) + u16(2) + bytes([3, 4]) +
                u16(0x33) + u16(36) + u16(0x1d) + u16(32) + pub)
        sh = msg(2, bytes([3, 3]) + self.rng.randbytes(32) + bytes([len(sid)]) + sid +
                 bytes([0x13, 1, 0]) + u16(len(exts)) + exts)
        tr = ch + sh
        early = ref.hkdf_extract(b"", bytes(32))
        hs = ref.hkdf_extract(ref.expand_label(early, b"derived", H(b""), 32), shared)
        self.c = Keys(ref.expand_label(hs, b"c hs traffic", H(tr), 32))
        self.s = Keys(ref.expand_label(hs, b"s hs traffic", H(tr), 32))
        ee = msg(8, u16(0))
        chain = self.chain or [self.rng.randbytes(self.cert_size)]
        entries = b"".join(u24(len(c)) + c + u16(0) for c in chain)
        cm = msg(11, b"\0" + u24(len(entries)) + entries)
        if self.signer:
            scheme, sig = self.signer(b" " * 64 + b"TLS 1.3, server CertificateVerify\0" +
                                      H(tr + ee + cm))
        else:
            scheme, sig = 0x0804, self.rng.randbytes(256)
        cv = msg(15, u16(scheme) + u16(len(sig)) + sig)
        tr += ee + cm + cv
        fin = hmac.new(ref.expand_label(self.s.secret, b"finished", b"", 32), H(tr),
                       hashlib.sha256).digest()
        if self.bad_finished:
            fin = bytes([fin[0] ^ 1]) + fin[1:]
        sf = msg(20, fin)
        tr += sf
        self.th_sf = tr
        master = ref.hkdf_extract(ref.expand_label(hs, b"derived", H(b""), 32), bytes(32))
        self.c_ap = ref.expand_label(master, b"c ap traffic", H(tr), 32)
        s_ap = ref.expand_label(master, b"s ap traffic", H(tr), 32)
        out = bytes([22, 3, 3]) + u16(len(sh)) + sh
        if self.ccs:
            out += bytes([20, 3, 3, 0, 1, 1])
        flight = ee + cm + cv + sf
        if self.split == "each":
            pieces = [ee, cm, cv, sf]
        elif self.split:
            pieces = [flight[i:i + self.split] for i in range(0, len(flight), self.split)]
        else:
            pieces = [flight[i:i + 16384] for i in range(0, len(flight), 16384)]
        for piece in pieces:
            out += self.s.seal(22, piece, self.pad)
        self.s = Keys(s_ap)
        self.state = "open"
        return out

    # -- after it --
    def send_app(self, data, pad=0):
        return b"".join(self.s.seal(23, data[i:i + 16384], pad)
                        for i in range(0, max(len(data), 1), 16384))

    def empty_record(self):
        return self.s.seal(23, b"", self.pad)

    def ticket(self):
        body = (u24(7200)[0:0] + (7200).to_bytes(4, "big") + self.rng.randbytes(4) +
                b"\x08" + self.rng.randbytes(8) + u16(32) + self.rng.randbytes(32) + u16(0))
        return self.s.seal(22, msg(4, body))

    def key_update(self, request):
        out = self.s.seal(22, msg(24, bytes([1 if request else 0])))
        self.s = self.s.update()
        return out

    def close(self):
        return self.s.seal(21, bytes([1, 0]))
