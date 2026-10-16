"""Reference model of the SBC encoder, written straight from A2DP spec 12.8 in
numpy, plus a frame parser: run.py compares src/kernel/sbc.asm against it
field by field (scale factors, join bits, quantised samples) and checks every
frame's header, length and CRC independently of ffmpeg.

The analysis here follows the spec's own formulation (shift register X with
the newest sample first, windowing by C[i], partial sums Y, matrixing with
M[k][i] = cos((k + 1/2)(i - M/2) pi / M)); the assembly reorders all of that,
so agreement says both are the spec.
"""
import math

import numpy as np

# Prototype windows, A2DP spec 12.8 Tables 12.23 (Proto_4_40) and 12.24
# (Proto_8_80); the lowpass with every other run of 2M taps negated
PROTO4 = [
    0.00000000E+00, 5.36548976E-04, 1.49188357E-03, 2.73370904E-03,
    3.83720193E-03, 3.89205149E-03, 1.86581691E-03, -3.06012286E-03,
    1.09137620E-02, 2.04385087E-02, 2.88757392E-02, 3.21939290E-02,
    2.58767811E-02, 6.13245186E-03, -2.88217274E-02, -7.76463494E-02,
    1.35593274E-01, 1.94987841E-01, 2.46636662E-01, 2.81828203E-01,
    2.94315332E-01, 2.81828203E-01, 2.46636662E-01, 1.94987841E-01,
    -1.35593274E-01, -7.76463494E-02, -2.88217274E-02, 6.13245186E-03,
    2.58767811E-02, 3.21939290E-02, 2.88757392E-02, 2.04385087E-02,
    -1.09137620E-02, -3.06012286E-03, 1.86581691E-03, 3.89205149E-03,
    3.83720193E-03, 2.73370904E-03, 1.49188357E-03, 5.36548976E-04,
]
PROTO8 = [
    0.00000000E+00, 1.56575398E-04, 3.43256425E-04, 5.54620202E-04,
    8.23919506E-04, 1.13992507E-03, 1.47640169E-03, 1.78371725E-03,
    2.01182542E-03, 2.10371989E-03, 1.99454554E-03, 1.61656283E-03,
    9.02154502E-04, -1.78805361E-04, -1.64973098E-03, -3.49717454E-03,
    5.65949473E-03, 8.02941163E-03, 1.04584443E-02, 1.27472335E-02,
    1.46525263E-02, 1.59045603E-02, 1.62208471E-02, 1.53184106E-02,
    1.29371806E-02, 8.85757540E-03, 2.92408442E-03, -4.91578024E-03,
    -1.46404076E-02, -2.61098752E-02, -3.90751381E-02, -5.31873032E-02,
    6.79989431E-02, 8.29847578E-02, 9.75753918E-02, 1.11196689E-01,
    1.23264548E-01, 1.33264415E-01, 1.40753505E-01, 1.45389847E-01,
    1.46955068E-01, 1.45389847E-01, 1.40753505E-01, 1.33264415E-01,
    1.23264548E-01, 1.11196689E-01, 9.75753918E-02, 8.29847578E-02,
    -6.79989431E-02, -5.31873032E-02, -3.90751381E-02, -2.61098752E-02,
    -1.46404076E-02, -4.91578024E-03, 2.92408442E-03, 8.85757540E-03,
    1.29371806E-02, 1.53184106E-02, 1.62208471E-02, 1.59045603E-02,
    1.46525263E-02, 1.27472335E-02, 1.04584443E-02, 8.02941163E-03,
    -5.65949473E-03, -3.49717454E-03, -1.64973098E-03, -1.78805361E-04,
    9.02154502E-04, 1.61656283E-03, 1.99454554E-03, 2.10371989E-03,
    2.01182542E-03, 1.78371725E-03, 1.47640169E-03, 1.13992507E-03,
    8.23919506E-04, 5.54620202E-04, 3.43256425E-04, 1.56575398E-04,
]

# A second, independent source for the same windows: the decoder's synthesis
# tables from FFmpeg libavcodec/sbcdec_data.c (ff_sbc_proto_*_m0/m1, from
# BlueZ), fixed point and in polyphase order, each entry -C[n] scaled by
# 2^29 (4 subbands) or 2^32 (8 subbands). check_tables() maps them back.
DEC4_M0 = [
    0x00000000, 0xffa6982f, 0xfba93848, 0x0456c7b8, 0x005967d1, 0xfffb9ac7, 0xff589157,
    0xf9c2a8d8, 0x027c1434, 0x0019118b, 0xfff3c74c, 0xff137330, 0xf81b8d70, 0x00ec1b8b,
    0xfff0b71a, 0xffe99b00, 0xfef84470, 0xf6fb4370, 0xffcdc351, 0xffe01dc7]
DEC4_M1 = [
    0xffe090ce, 0xff2c0475, 0xf694f800, 0xff2c0475, 0xffe090ce, 0xffe01dc7, 0xffcdc351,
    0xf6fb4370, 0xfef84470, 0xffe99b00, 0xfff0b71a, 0x00ec1b8b, 0xf81b8d70, 0xff137330,
    0xfff3c74c, 0x0019118b, 0x027c1434, 0xf9c2a8d8, 0xff589157, 0xfffb9ac7]
DEC8_M0 = [
    0x00000000, 0xfe8d1970, 0xee979f00, 0x11686100, 0x0172e690, 0xfff5bd1a, 0xfdf1c8d4,
    0xeac182c0, 0x0d9daee0, 0x00e530da, 0xffe9811d, 0xfd52986c, 0xe7054ca0, 0x0a00d410,
    0x006c1de4, 0xffdba705, 0xfcbc98e8, 0xe3889d20, 0x06af2308, 0x000bb7db, 0xffca00ed,
    0xfc3fbb68, 0xe071bc00, 0x03bf7948, 0xffc4e05c, 0xffb54b3b, 0xfbedadc0, 0xdde26200,
    0x0142291c, 0xff960e94, 0xff9f3e17, 0xfbd8f358, 0xdbf79400, 0xff405e01, 0xff7d4914,
    0xff8b1a31, 0xfc1417b8, 0xdac7bb40, 0xfdbb828c, 0xff762170]
DEC8_M1 = [
    0xff7c272c, 0xfcb02620, 0xda612700, 0xfcb02620, 0xff7c272c, 0xff762170, 0xfdbb828c,
    0xdac7bb40, 0xfc1417b8, 0xff8b1a31, 0xff7d4914, 0xff405e01, 0xdbf79400, 0xfbd8f358,
    0xff9f3e17, 0xff960e94, 0x0142291c, 0xdde26200, 0xfbedadc0, 0xffb54b3b, 0xffc4e05c,
    0x03bf7948, 0xe071bc00, 0xfc3fbb68, 0xffca00ed, 0x000bb7db, 0x06af2308, 0xe3889d20,
    0xfcbc98e8, 0xffdba705, 0x006c1de4, 0x0a00d410, 0xe7054ca0, 0xfd52986c, 0xffe9811d,
    0x00e530da, 0x0d9daee0, 0xeac182c0, 0xfdf1c8d4, 0xfff5bd1a]

# loudness offsets [frequency][subband]
OFFSET4 = [[-1, 0, 0, 0], [-2, 0, 0, 1], [-2, 0, 0, 1], [-2, 0, 0, 1]]
OFFSET8 = [[-2, 0, 0, 0, 0, 0, 0, 1], [-3, 0, 0, 0, 0, 0, 1, 2],
           [-4, 0, 0, 0, 0, 0, 1, 2], [-4, 0, 0, 0, 0, 0, 1, 2]]

RATES = [16000, 32000, 44100, 48000]
MONO, DUAL, STEREO, JOINT = range(4)


def check_tables():
    """Worst relative difference between PROTO4/8 and the decoder tables."""
    def s32(x):
        return x - (1 << 32) if x & 0x80000000 else x
    worst = 0.0
    for C, M, m0, m1, scale in ((PROTO4, 4, DEC4_M0, DEC4_M1, 2.0 ** 29),
                                (PROTO8, 8, DEC8_M0, DEC8_M1, 2.0 ** 32)):
        # m0: phases 0..M-1, five taps each; m1: phase M, then M+1..2M-1
        pairs = [(j + 2 * M * t, m0[5 * j + t]) for j in range(M) for t in range(5)]
        pairs += [(j + 2 * M * t, m1[5 * (j - M) + t]) for j in range(M, 2 * M) for t in range(5)]
        for n, v in pairs:
            ref = -s32(v) / scale
            worst = max(worst, abs(ref - C[n]) / abs(C[n]) if C[n] else abs(ref))
    return worst


def crc8(bits):
    """CRC-8, x^8 + x^4 + x^3 + x^2 + 1, initial 0x0F, over a list of bits."""
    crc = 0x0F
    for b in bits:
        top = (crc >> 7) ^ b
        crc = ((crc << 1) & 0xFF) ^ (0x1D if top else 0)
    return crc


def frame_length(mode, blocks, M, bitpool):
    nch = 1 if mode == MONO else 2
    if mode in (MONO, DUAL):
        return 4 + 4 * M * nch // 8 + (blocks * nch * bitpool + 7) // 8
    return 4 + 4 * M * 2 // 8 + ((M if mode == JOINT else 0) + blocks * bitpool + 7) // 8


def bitneed(sf, freq, M, method):
    if method == 1:
        return list(sf)
    off = (OFFSET4 if M == 4 else OFFSET8)[freq]
    need = []
    for sb, s in enumerate(sf):
        if s == 0:
            need.append(-5)
        else:
            loud = s - off[sb]
            need.append(loud // 2 if loud > 0 else loud)
    return need


def slices(need, bitpool):
    """The spec's bitslice allocation over one list, in hand-out order."""
    bitslice = max([0] + need) + 1
    bitcount = slicecount = 0
    while True:
        bitslice -= 1
        bitcount += slicecount
        slicecount = 0
        for v in need:
            if bitslice + 1 < v < bitslice + 16:
                slicecount += 1
            elif v == bitslice + 1:
                slicecount += 2
        if bitcount + slicecount >= bitpool:
            break
    if bitcount + slicecount == bitpool:
        bitcount += slicecount
        bitslice -= 1
    bits = [0 if v < bitslice + 2 else min(v - bitslice, 16) for v in need]
    for e in range(len(need)):
        if bitcount >= bitpool:
            break
        if 2 <= bits[e] < 16:
            bits[e] += 1
            bitcount += 1
        elif need[e] == bitslice + 1 and bitpool > bitcount + 1:
            bits[e] = 2
            bitcount += 2
    for e in range(len(need)):
        if bitcount >= bitpool:
            break
        if bits[e] < 16:
            bits[e] += 1
            bitcount += 1
    return bits


def allocate(sf, freq, mode, M, method, bitpool):
    """bits[ch][sb] from scale factors sf[ch][sb]."""
    need = [bitneed(s, freq, M, method) for s in sf]
    if mode in (MONO, DUAL):
        return [slices(n, bitpool) for n in need]
    flat = slices([need[ch][sb] for sb in range(M) for ch in range(2)], bitpool)
    return [[flat[2 * sb + ch] for sb in range(M)] for ch in range(2)]


def scale_factor(peak):
    """Smallest sf with every |sample| below 2^(sf + 1), within 0..15."""
    if peak < 1.0:
        return 0
    return min(15, math.frexp(peak)[1] - 1)


class Encoder:
    def __init__(self, freq, mode, blocks, M, method, bitpool):
        self.freq, self.mode, self.blocks, self.M = freq, mode, blocks, M
        self.method, self.bitpool = method, bitpool
        self.nch = 1 if mode == MONO else 2
        self.C = np.array(PROTO4 if M == 4 else PROTO8)
        k = np.arange(M)[:, None]
        i = np.arange(2 * M)[None, :]
        self.Mk = np.cos((k + 0.5) * (i - M / 2) * math.pi / M)
        self.X = np.zeros((self.nch, 10 * M))           # X[0] is the newest
        self.length = frame_length(mode, blocks, M, bitpool)

    def analyse(self, pcm):
        M = self.M
        S = np.zeros((self.blocks, self.nch, M))
        for ch in range(self.nch):
            X = self.X[ch]
            for b in range(self.blocks):
                X[M:] = X[:-M].copy()                    # shift in M samples
                X[:M] = pcm[b * M:(b + 1) * M, ch][::-1]
                Y = (self.C * X).reshape(5, 2 * M).sum(axis=0)
                S[b, ch] = self.Mk @ Y
        return S

    def encode(self, pcm):
        """pcm: (blocks * M, nch) array of samples -> one frame (bytes)."""
        M, B, nch = self.M, self.blocks, self.nch
        S = self.analyse(np.asarray(pcm, dtype=float))
        sf = [[scale_factor(np.max(np.abs(S[:, ch, sb]))) for sb in range(M)] for ch in range(nch)]
        join = [0] * M
        if self.mode == JOINT:
            for sb in range(M - 1):
                mid = (S[:, 0, sb] + S[:, 1, sb]) * 0.5
                side = (S[:, 0, sb] - S[:, 1, sb]) * 0.5
                a, b = scale_factor(np.max(np.abs(mid))), scale_factor(np.max(np.abs(side)))
                if a + b < sf[0][sb] + sf[1][sb]:
                    join[sb] = 1
                    S[:, 0, sb], S[:, 1, sb] = mid, side
                    sf[0][sb], sf[1][sb] = a, b
        bits = allocate(sf, self.freq, self.mode, M, self.method, self.bitpool)
        w = BitWriter()
        w.put(0x9C, 8)
        w.put((self.freq << 6) | ((B // 4 - 1) << 4) | (self.mode << 2) | (self.method << 1) | (M == 8), 8)
        w.put(self.bitpool, 8)
        w.put(0, 8)
        if self.mode == JOINT:
            for sb in range(M):
                w.put(join[sb], 1)
        for ch in range(nch):
            for sb in range(M):
                w.put(sf[ch][sb], 4)
        crc_end = w.count
        for blk in range(B):
            for ch in range(nch):
                for sb in range(M):
                    nb = bits[ch][sb]
                    if nb:
                        L = (1 << nb) - 1
                        x = S[blk, ch, sb] / 2.0 ** (sf[ch][sb] + 1)
                        q = math.floor((x + 1.0) * L / 2)
                        w.put(max(0, min(L - 1, q)), nb)
        data = bytearray(w.bytes(self.length))
        allbits = [(data[i // 8] >> (7 - i % 8)) & 1 for i in range(crc_end)]
        data[3] = crc8(allbits[8:24] + allbits[32:crc_end])
        return bytes(data)


class BitWriter:
    def __init__(self):
        self.value, self.count = 0, 0

    def put(self, v, n):
        self.value = (self.value << n) | v
        self.count += n

    def bytes(self, length):
        pad = length * 8 - self.count
        assert pad >= 0, "frame overflow"
        return (self.value << pad).to_bytes(length, "big")


def parse_frame(data):
    """Decode a frame's side information and quantised samples. Returns a dict,
    or raises ValueError naming what is wrong (sync, length, CRC)."""
    if len(data) < 4 or data[0] != 0x9C:
        raise ValueError("no syncword")
    h = data[1]
    freq, blocks, mode = h >> 6, ((h >> 4) & 3) * 4 + 4, (h >> 2) & 3
    method, M = (h >> 1) & 1, 8 if h & 1 else 4
    bitpool = data[2]
    nch = 1 if mode == MONO else 2
    length = frame_length(mode, blocks, M, bitpool)
    if len(data) < length:
        raise ValueError("short frame")
    bits_in = [(data[i // 8] >> (7 - i % 8)) & 1 for i in range(length * 8)]
    pos = 32

    def get(n):
        nonlocal pos
        v = 0
        for _ in range(n):
            v = (v << 1) | bits_in[pos]
            pos += 1
        return v
    join = [get(1) for _ in range(M)] if mode == JOINT else [0] * M
    sf = [[get(4) for _ in range(M)] for _ in range(nch)]
    crc = crc8(bits_in[8:24] + bits_in[32:pos])
    if crc != data[3]:
        raise ValueError(f"CRC {data[3]:02x}, computed {crc:02x}")
    bits = allocate(sf, freq, mode, M, method, bitpool)
    q = [[[get(bits[ch][sb]) if bits[ch][sb] else None for sb in range(M)]
          for ch in range(nch)] for _ in range(blocks)]
    used = pos
    return dict(freq=freq, blocks=blocks, mode=mode, method=method, M=M, bitpool=bitpool,
                length=length, join=join, sf=sf, bits=bits, q=q, used_bits=used,
                padding_zero=not any(bits_in[used:]))
