"""The RTL8821CE station's handshakes (src/kernel/rtwwpa.asm, through
hs_shim.asm), against an access point played here from IEEE 802.11-2020
12.7.6-7: the 4-way handshake (message 2's and 4's fields and MICs, the PTK,
the GTK unwrapped from message 3, the keys put in use only after message 4
went out unprotected), messages it must ignore (a wrong MIC, a stale replay
counter, another handshake's ANonce, a repeat), the group key handshake
(answered protected), and data frames through rtw_rx_data (CCMP with the
pairwise and group keys, refused when tampered with, keyed wrong or sent
in the clear). Run by run.py."""
import ctypes
import hashlib
import hmac

RSN_IE = bytes([48, 20, 1, 0, 0, 0x0F, 0xAC, 4, 1, 0, 0, 0x0F, 0xAC, 4, 1, 0, 0, 0x0F, 0xAC, 2, 0, 0])
LLC_EAPOL = bytes([0xAA, 0xAA, 3, 0, 0, 0, 0x88, 0x8E])
LLC_IP = bytes([0xAA, 0xAA, 3, 0, 0, 0, 0x08, 0x00])


def eapol_key(ver, info, keylen, replay, nonce, rsc, data, kck=None):
    body = (bytes([2]) + info.to_bytes(2, "big") + keylen.to_bytes(2, "big") +
            replay.to_bytes(8, "big") + nonce + bytes(16) + rsc + bytes(8) + bytes(16) +
            len(data).to_bytes(2, "big") + data)
    frame = bytes([ver, 3]) + len(body).to_bytes(2, "big") + body
    if kck:
        frame = frame[:81] + mic(kck, frame) + frame[97:]
    return frame


def mic(kck, frame):
    return hmac.new(kck, frame[:81] + bytes(16) + frame[97:], hashlib.sha1).digest()[:16]


def gtk_kde(gtk, keyid, tx):
    return bytes([0xDD, 6 + len(gtk), 0, 0x0F, 0xAC, 1, keyid | (4 if tx else 0), 0]) + gtk


def padded(data):
    if len(data) % 8 or len(data) < 16:
        data += b"\xdd"
        data += bytes(-len(data) % 8)
        if len(data) < 16:
            data += bytes(16 - len(data))
    return data


def run(k, rng, result, prf, aes_wrap, ccmp_seal):
    def w(name, data, off=0):
        ctypes.memmove(k.addr(name) + off, data, len(data))

    def r(name, n, off=0):
        return k.read(k.addr(name) + off, n)

    def u(name, n=4):
        return int.from_bytes(r(name, n), "little")

    def sent():
        return r("sent_buf", u("sent_len"))

    def rx(frame):
        w("sent_n", bytes(4))
        k.fresh()
        k.call("rtw_eapol_rx", 0, k.buf(frame), 0, len(frame))
        return u("sent_n")

    def rx_data(frame, hlen=24):
        w("sent_n", bytes(4))
        w("eth_n", bytes(4))
        k.fresh()
        b = k.buf(frame)
        k.call("hs_rx_data", 0, b, hlen, len(frame))
        return b

    for case in range(24):
        pmk, aa, spa = rng.randbytes(32), rng.randbytes(6), rng.randbytes(6)
        aa, spa = bytes([aa[0] & 0xFC]) + aa[1:], bytes([spa[0] & 0xFC]) + spa[1:]
        anonce, snonce = rng.randbytes(32), rng.randbytes(32)
        w("rtw_wk", pmk, 41)
        w("rtw_bss", aa)
        w("rtw_mac", spa)
        w("rand_src", snonce)
        k.fresh()
        k.call("rtw_wpa_reset")
        result(r("rtw_snonce", 32) == snonce and u("rtw_keys", 1) == 0,
               f"case {case}: reset: the SNonce, no keys")
        ptk = prf(pmk, b"Pairwise key expansion",
                  min(aa, spa) + max(aa, spa) + min(anonce, snonce) + max(anonce, snonce), 48)
        kck, kek, tk = ptk[:16], ptk[16:32], ptk[32:]
        ver = rng.choice((1, 2))
        replay = rng.randrange(1, 1 << 40)

        # message 1 (with a PMKID element now and then): message 2 back
        kd1 = bytes([0xDD, 20, 0, 0x0F, 0xAC, 4]) + rng.randbytes(16) if case % 3 == 0 else b""
        m1 = eapol_key(ver, 0x008A, 16, replay, anonce, bytes(8), kd1)
        n = rx(m1)
        m2 = sent()
        result(n == 1 and u("sent_type", 2) == 0x8E88 and r("sent_da", 6) == aa
               and u("sent_keys", 1) == 0, f"case {case}: message 1 answered, unprotected, to the AP")
        result(len(m2) == 99 + 22 and m2[0] == ver and m2[1] == 3
               and int.from_bytes(m2[2:4], "big") == len(m2) - 4 and m2[4] == 2,
               f"case {case}: message 2's EAPOL header")
        result(int.from_bytes(m2[5:7], "big") == 0x010A and m2[7:9] == bytes(2)
               and int.from_bytes(m2[9:17], "big") == replay and m2[17:49] == snonce
               and m2[49:81] == bytes(32) and int.from_bytes(m2[97:99], "big") == 22
               and m2[99:] == RSN_IE, f"case {case}: message 2's fields")
        result(m2[81:97] == mic(kck, m2), f"case {case}: message 2's MIC (the PTK)")
        if case % 4 == 1:                               # message 1 again: the same answer
            n = rx(eapol_key(ver, 0x008A, 16, replay + 1, anonce, bytes(8), b""))
            again = sent()
            result(n == 1 and again[17:49] == snonce and again[81:97] == mic(kck, again)
                   and int.from_bytes(again[9:17], "big") == replay + 1,
                   f"case {case}: a repeated message 1 answered the same way")
            replay += 1

        # message 3, and the ones to ignore
        gtk, keyid, rsc = rng.randbytes(16), rng.randrange(1, 4), rng.randbytes(6) + bytes(2)
        ap_rsn = RSN_IE[:-2] + bytes([rng.choice((0, 0x80, 0x0C)), 0])
        kd3 = aes_wrap(kek, padded(ap_rsn + gtk_kde(gtk, keyid, case % 2)))
        m3 = eapol_key(ver, 0x13CA, 16, replay + 1, anonce, rsc, kd3, kck)
        bad = bytearray(m3)
        bad[81 + rng.randrange(16)] ^= 1 << rng.randrange(8)
        result(rx(bytes(bad)) == 0 and u("rtw_keys", 1) == 0, f"case {case}: a wrong MIC ignored")
        stale = eapol_key(ver, 0x13CA, 16, replay, anonce, rsc, kd3, kck)
        result(rx(stale) == 0 and u("rtw_keys", 1) == 0, f"case {case}: a stale replay counter ignored")
        other = eapol_key(ver, 0x13CA, 16, replay + 1, rng.randbytes(32), rsc, kd3, kck)
        result(rx(other) == 0 and u("rtw_keys", 1) == 0, f"case {case}: another ANonce ignored")
        n = rx(m3)
        m4 = sent()
        result(n == 1 and u("sent_keys", 1) == 0, f"case {case}: message 3 answered, unprotected")
        result(len(m4) == 99 and int.from_bytes(m4[5:7], "big") == 0x030A
               and int.from_bytes(m4[9:17], "big") == replay + 1 and m4[17:81] == bytes(64)
               and m4[97:99] == bytes(2) and m4[81:97] == mic(kck, m4),
               f"case {case}: message 4's fields and MIC")
        result(u("rtw_keys", 1) == 1 and r("rtw_tk", 16) == tk and r("rtw_gtk", 16) == gtk
               and u("rtw_gtk_id", 1) == keyid and u("rtw_tx_pn", 8) == 1
               and u("rtw_hs", 1) == 2 and u("rtw_js_got", 1) == 1,
               f"case {case}: the keys in use after message 4")
        result(rx(m3) == 0, f"case {case}: message 3 again ignored (its counter was taken)")

        # the group key handshake
        gtk2, keyid2 = rng.randbytes(16), 1 + keyid % 3
        g1 = eapol_key(ver, 0x1382, 16, replay + 2, bytes(32), rsc,
                       aes_wrap(kek, padded(gtk_kde(gtk2, keyid2, False))), kck)
        n = rx(g1)
        g2 = sent()
        result(n == 1 and u("sent_keys", 1) == 1 and len(g2) == 99
               and int.from_bytes(g2[5:7], "big") == 0x0302
               and int.from_bytes(g2[9:17], "big") == replay + 2 and g2[81:97] == mic(kck, g2),
               f"case {case}: the group key handshake answered, protected")
        result(r("rtw_gtk", 16) == gtk2 and u("rtw_gtk_id", 1) == keyid2,
               f"case {case}: the new group key in use")

        # data frames
        sa = rng.randbytes(6)
        payload = rng.randbytes(rng.randrange(0, 200))
        hdr = bytes([0x08, 0x42, 0, 0]) + spa + aa + sa + rng.randbytes(2)
        pn = rng.randrange(1, 1 << 48)
        frame = ccmp_seal(tk, hdr, pn, 0, LLC_IP + payload)
        b = rx_data(frame)
        result(u("eth_n") == 1 and u("eth_off") == 32 and u("eth_len") == 8 + len(payload)
               and k.read(b + 32, 8 + len(payload)) == LLC_IP + payload,
               f"case {case}: a unicast frame decrypted (pairwise key) and handed on")
        ghdr = bytes([0x08, 0x42, 0, 0]) + b"\xff" * 6 + aa + sa + rng.randbytes(2)
        b = rx_data(ccmp_seal(gtk2, ghdr, pn, keyid2, LLC_IP + payload))
        result(u("eth_n") == 1 and k.read(b + 32, 8 + len(payload)) == LLC_IP + payload,
               f"case {case}: a group frame decrypted (group key) and handed on")
        rx_data(ccmp_seal(gtk2, ghdr, pn, 1 + keyid2 % 3, LLC_IP + payload))
        result(u("eth_n") == 0, f"case {case}: a group frame under another key ID refused")
        bad = bytearray(frame)
        bad[24 + 8 + rng.randrange(8 + len(payload) + 8)] ^= 1
        rx_data(bytes(bad))
        result(u("eth_n") == 0, f"case {case}: a tampered frame refused")
        rx_data(bytes([0x08, 0x02]) + hdr[2:] + LLC_IP + payload)
        result(u("eth_n") == 0, f"case {case}: an unprotected data frame refused")
        g3 = eapol_key(ver, 0x1382, 16, replay + 3, bytes(32), rsc,
                       aes_wrap(kek, padded(gtk_kde(gtk, keyid, False))), kck)
        rx_data(ccmp_seal(tk, hdr, pn + 1, 0, LLC_EAPOL + g3))
        result(u("sent_n") == 1 and u("eth_n") == 0 and r("rtw_gtk", 16) == gtk
               and u("rtw_gtk_id", 1) == keyid,
               f"case {case}: a protected EAPOL frame to the handshake, not the network")
