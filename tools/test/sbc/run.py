#!/usr/bin/env python3
"""Host test of the SBC encoder in src/kernel/sbc.asm.

    python tools/test/sbc/run.py            every configuration and signal (minutes)
    python tools/test/sbc/run.py --quick    the A2DP default configuration only

Builds build/test/sbc/sbc_test.exe (tools/test/sbc/shim.asm, which includes
the encoder as the kernel does, plus sbc_test.c), runs its interface checks,
then for each configuration and test signal:
  - encodes with the assembly,
  - checks every frame independently of ffmpeg: syncword, header fields,
    length, CRC-8, zero padding (ref.parse_frame),
  - compares scale factors, join bits and quantised samples with the Python
    reference model ref.py, which follows the spec's own formulation,
  - decodes with ffmpeg, which must take every frame without a complaint and
    give back the right number of samples,
  - measures SNR per channel against the input, the codec delay found by
    cross-correlation on noise; for comparison, ffmpeg's own SBC encoder on the same
    input where it can produce the same configuration.
Tools: nasm on PATH; gcc and ffmpeg from $SBC_GCC / $SBC_FFMPEG, the WinGet
install paths, or PATH. Output in build/test/sbc/, summary in results.txt.
"""
import argparse
import math
import os
import pathlib
import shutil
import subprocess
import sys

import numpy as np

sys.dont_write_bytecode = True          # no __pycache__ in the source tree
import ref  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[3]
HERE = pathlib.Path(__file__).resolve().parent
OUT = ROOT / "build" / "test" / "sbc"
WINGET = pathlib.Path.home() / "AppData/Local/Microsoft/WinGet/Packages"
GCC_DEFAULT = WINGET / ("BrechtSanders.WinLibs.POSIX.UCRT_Microsoft.Winget.Source_8wekyb3d8bbwe"
                        "/mingw64/bin/gcc.exe")
FFMPEG_DEFAULT = WINGET / ("Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe"
                           "/ffmpeg-8.1.2-full_build/bin/ffmpeg.exe")

# label, frequency index, mode, blocks, subbands, allocation, bitpool
MAIN = ("44.1k joint 16/8 loud bp53", 2, 3, 16, 8, 0, 53)
CONFIGS = [
    MAIN,                                           # the A2DP high-quality default
    ("48k joint 16/8 loud bp51", 3, 3, 16, 8, 0, 51),
    ("44.1k stereo 16/8 loud bp53", 2, 2, 16, 8, 0, 53),
    ("44.1k joint 16/8 SNR bp53", 2, 3, 16, 8, 1, 53),
    ("44.1k joint 8/8 loud bp53", 2, 3, 8, 8, 0, 53),
    ("44.1k joint 16/4 loud bp53", 2, 3, 16, 4, 0, 53),
    ("44.1k dual 16/8 loud bp32", 2, 1, 16, 8, 0, 32),
    ("44.1k mono 16/8 loud bp31", 2, 0, 16, 8, 0, 31),
    ("32k stereo 12/4 loud bp40", 1, 2, 12, 4, 0, 40),
    ("16k mono 4/4 SNR bp20", 0, 0, 4, 4, 1, 20),
    ("48k stereo 16/8 loud bp250", 3, 2, 16, 8, 0, 250),
    ("44.1k joint 16/8 loud bp8", 2, 3, 16, 8, 0, 8),
    # the remaining rows of the loudness offset tables (a wrong offset would
    # make ffmpeg's allocation differ, and the frame decode to garbage)
    ("16k mono 16/8 loud bp32", 0, 0, 16, 8, 0, 32),
    ("16k joint 8/4 loud bp30", 0, 3, 8, 4, 0, 30),
    ("32k joint 16/8 loud bp45", 1, 3, 16, 8, 0, 45),
    ("48k dual 16/4 loud bp40", 3, 1, 16, 4, 0, 40),
]
# configurations ffmpeg's own encoder can produce too, for comparison
FFMPEG_TOO = [MAIN, CONFIGS[1], CONFIGS[2], CONFIGS[7]]
SIGNALS = ["sine:440", "sine:1000", "sine:5000", "sine:12000", "chord", "sweep",
           "noise", "silence", "square"]
SECONDS = 1.0
# tones, chords and sweeps must come back at least this clean (all but the
# deliberately starved bitpool 8); noise is reported, not judged
TONAL = ("sine", "chord", "sweep")
MIN_TONAL_SNR = 30.0
SKIP = 2048                     # samples left out at each end of the SNR window


def find(env, default, name):
    exe = os.environ.get(env)
    if exe:
        return exe
    if default.exists():
        return str(default)
    exe = shutil.which(name)
    if not exe:
        sys.exit(f"{name} not found (set {env})")
    return exe


def run(cmd, **kw):
    return subprocess.run([str(c) for c in cmd], capture_output=True, text=True, **kw)


def build(gcc):
    OUT.mkdir(parents=True, exist_ok=True)
    nasm = shutil.which("nasm") or sys.exit("nasm not found on PATH")
    r = run([nasm, "-f", "win64", "-I", str(ROOT / "src" / "kernel") + os.sep, "-o", OUT / "shim.obj",
             HERE / "shim.asm"])
    if r.returncode or r.stderr.strip():
        sys.exit("nasm: " + r.stdout + r.stderr)
    r = run([gcc, "-O2", "-Wall", "-Wextra", "-o", OUT / "sbc_test.exe", HERE / "sbc_test.c",
             OUT / "shim.obj", "-lm"])
    if r.returncode or r.stderr.strip():
        sys.exit("gcc: " + r.stdout + r.stderr)
    return OUT / "sbc_test.exe"


def decode(ffmpeg, sbc, raw, nch):
    """ffmpeg's SBC decoder -> (samples (n, nch), list of complaints)."""
    r = run([ffmpeg, "-hide_banner", "-nostdin", "-v", "warning", "-y", "-f", "sbc", "-i", sbc,
             "-f", "s16le", "-ac", nch, raw])
    # a raw .sbc stream carries no channel layout, so ffmpeg always notes
    # that it guessed one: not a decoding problem
    complaints = [l for l in r.stderr.splitlines()
                  if l.strip() and "Guessed Channel Layout" not in l]
    if r.returncode:
        complaints.append(f"exit {r.returncode}")
    y = np.fromfile(raw, dtype=np.int16) if raw.exists() else np.zeros(0, np.int16)
    return y.reshape(-1, nch).astype(float), complaints


def align(x, y, lags=1024):
    """Delay of y against x (0..lags), by cross-correlation."""
    n = min(len(x), len(y) - lags)
    a = x[:n]
    size = 1 << (n + lags).bit_length()
    corr = np.fft.irfft(np.conj(np.fft.rfft(a, size)) * np.fft.rfft(y[:n + lags], size), size)
    return int(np.argmax(corr[:lags + 1]))


def snr(x, y, d):
    n = len(x)
    a = x[SKIP:n - SKIP]
    b = y[SKIP + d:n - SKIP + d]
    m = min(len(a), len(b))
    a, b = a[:m], b[:m]
    err = np.sum((a - b) ** 2)
    sig = np.sum(a ** 2)
    gain = float(np.dot(a, b) / sig) if sig else 0.0
    return (10 * math.log10(sig / err) if err else float("inf")), gain


def delay_of(x, y):
    """Codec delay from the louder channel; use a broadband signal (a tone's
    correlation repeats every period)."""
    ch = int(np.argmax(np.sum(x ** 2, axis=0)))
    return align(x[:, ch], y[:, ch])


def measure(x, y, d):
    """(SNR in dB, gain) per channel, y delayed by d against x."""
    return [snr(x[:, c], y[:, c], d) for c in range(x.shape[1])]


def split(data, length):
    return [data[i:i + length] for i in range(0, len(data), length)]


def compare(frames, ref_frames):
    """Field-by-field agreement of two frame lists."""
    st = dict(frames=len(frames), identical=0, sf=0, join=0, q=0, qmax=0, values=0)
    for a, b in zip(frames, ref_frames):
        st["identical"] += a == b
        pa, pb = ref.parse_frame(a), ref.parse_frame(b)
        st["join"] += pa["join"] != pb["join"]
        st["sf"] += pa["sf"] != pb["sf"]
        if pa["bits"] != pb["bits"]:
            continue
        for ba, bb in zip(pa["q"], pb["q"]):
            for ca, cb in zip(ba, bb):
                for qa, qb in zip(ca, cb):
                    if qa is None:
                        continue
                    st["values"] += 1
                    if qa != qb:
                        st["q"] += 1
                        st["qmax"] = max(st["qmax"], abs(qa - qb))
    return st


def ffmpeg_encode(ffmpeg, cfg, raw, nch):
    """ffmpeg's encoder on the same input, forced to the same configuration
    where its options can express it -> its decoded output, or None."""
    label, freq, mode, blocks, m, method, bp = cfg
    if method != 0 or blocks != 16 or m != 8 or mode == ref.DUAL:
        return None
    rate = ref.RATES[freq]
    # ffmpeg picks joint stereo below 180 kb/s nominal, stereo between 180
    # and 420; -q:a sets the bitpool itself
    bitrate = {ref.MONO: "128k", ref.STEREO: "300k", ref.JOINT: "128k"}[mode]
    sbc = OUT / "ff.sbc"
    r = run([ffmpeg, "-hide_banner", "-nostdin", "-v", "error", "-y", "-f", "s16le", "-ar", rate,
             "-ac", nch, "-i", raw, "-c:a", "sbc", "-b:a", bitrate, "-q:a", bp, "-f", "sbc", sbc])
    if r.returncode:
        return None
    data = sbc.read_bytes()
    try:
        p = ref.parse_frame(data)
    except ValueError:
        return None
    if (p["freq"], p["mode"], p["blocks"], p["M"], p["method"], p["bitpool"]) != (freq, mode, 16, 8, 0, bp):
        return None
    return decode(ffmpeg, sbc, OUT / "ff.raw", nch)[0]


def fmt_snr(v):
    s, g = v
    return "  inf " if s == float("inf") else f"{s:6.1f}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true", help="the main configuration only")
    opts = ap.parse_args()

    gcc = find("SBC_GCC", GCC_DEFAULT, "gcc")
    ffmpeg = find("SBC_FFMPEG", FFMPEG_DEFAULT, "ffmpeg")
    exe = build(gcc)
    lines = []
    problems = []

    def out(s=""):
        print(s)
        lines.append(s)

    r = run([exe, "check"])
    out(r.stdout.rstrip())
    if r.returncode:
        problems.append("interface checks failed")

    # the assembled windows are the reference model's, and those agree with
    # the decoder tables (an independent copy of the spec's numbers)
    r = run([exe, "tables"])
    asm_tables = {l.split()[0]: [float(v) for v in l.split()[1:]] for l in r.stdout.splitlines()}
    same = asm_tables.get("proto4") == ref.PROTO4 and asm_tables.get("proto8") == ref.PROTO8
    worst = ref.check_tables()
    out(f"tables: assembled windows {'equal' if same else 'DIFFER FROM'} the reference model's; "
        f"those match the decoder's fixed-point tables to {worst:.1e} (relative)")
    if not same or worst > 1e-5:
        problems.append("prototype tables")

    configs = [MAIN] if opts.quick else CONFIGS
    out()
    out(f"{'configuration':28} {'signal':10} {'bytes':>5} {'SNR L':>6} {'SNR R':>6} {'gain':>5} "
        f"{'delay':>5}  {'vs ref model':24} {'ffmpeg enc L/R':>14}")
    for cfg in configs:
        label, freq, mode, blocks, m, method, bp = cfg
        rate, nch = ref.RATES[freq], 1 if mode == ref.MONO else 2
        # the codec delay of this configuration (and of ffmpeg's encoder), on noise
        sbc, raw = OUT / "x.sbc", OUT / "x.raw"
        run([exe, "enc", freq, mode, blocks, m, method, bp, "noise", SECONDS, sbc, raw])
        x = np.fromfile(raw, dtype=np.int16).astype(float).reshape(-1, nch)
        delay = delay_of(x, decode(ffmpeg, sbc, OUT / "x.dec.raw", nch)[0])
        ff_delay = None
        if cfg in FFMPEG_TOO:
            y = ffmpeg_encode(ffmpeg, cfg, raw, nch)
            ff_delay = None if y is None else delay_of(x, y)
        for sig in SIGNALS:
            if sig.startswith("sine:") and float(sig[5:]) >= 0.45 * rate:
                continue
            tag = f"{label} {sig}"
            sbc, raw, dec = OUT / "x.sbc", OUT / "x.raw", OUT / "x.dec.raw"
            r = run([exe, "enc", freq, mode, blocks, m, method, bp, sig, SECONDS, sbc, raw])
            if r.returncode:
                problems.append(f"{tag}: encoder failed: {r.stdout}{r.stderr}")
                continue
            info = dict(kv.split("=") for kv in r.stdout.split())
            length, nframes = int(info["len"]), int(info["frames"])
            data = sbc.read_bytes()
            frames = split(data, length)
            if len(data) != length * nframes or length != ref.frame_length(mode, blocks, m, bp):
                problems.append(f"{tag}: stream length")

            # every frame on its own: sync, header, length, CRC, padding
            for i, f in enumerate(frames):
                try:
                    p = ref.parse_frame(f)
                except ValueError as e:
                    problems.append(f"{tag}: frame {i}: {e}")
                    break
                if (p["freq"], p["mode"], p["blocks"], p["M"], p["method"], p["bitpool"]) != \
                        (freq, mode, blocks, m, method, bp) or p["length"] != length or not p["padding_zero"]:
                    problems.append(f"{tag}: frame {i}: header or padding")
                    break

            # the reference model on the same input
            x = np.fromfile(raw, dtype=np.int16).astype(float).reshape(-1, nch)
            enc = ref.Encoder(freq, mode, blocks, m, method, bp)
            spf = blocks * m
            ref_frames = [enc.encode(x[i * spf:(i + 1) * spf]) for i in range(nframes)]
            st = compare(frames, ref_frames)
            agree = f"{st['identical']}/{st['frames']} same"
            if st["q"] or st["sf"] or st["join"]:
                agree += f", {st['q']}q"
            if st["sf"] or st["join"] or st["qmax"] > 1 or st["q"] > max(2, st["values"] // 1000):
                problems.append(f"{tag}: disagrees with the reference model {st}")

            # ffmpeg decodes it all, cleanly
            y, complaints = decode(ffmpeg, sbc, dec, nch)
            if complaints:
                problems.append(f"{tag}: ffmpeg: {complaints[:3]}")
            if len(y) != nframes * spf:
                problems.append(f"{tag}: ffmpeg gave {len(y)} samples, expected {nframes * spf}")

            ffc = ""
            if sig == "silence":
                peak = int(np.max(np.abs(y))) if len(y) else -1
                res = f"{'peak ' + str(peak):>13}  {'':5} {'':>5}"
                if peak:
                    problems.append(f"{tag}: silence decodes to peak {peak}")
            else:
                per = measure(x, y, delay)
                res = " ".join(fmt_snr(v) for v in per)
                if nch == 1:
                    res += " " * 7
                res += f" {per[0][1]:5.3f} {delay:5}"
                if sig.startswith(TONAL) and bp >= 16 and min(v[0] for v in per) < MIN_TONAL_SNR:
                    problems.append(f"{tag}: SNR below {MIN_TONAL_SNR} dB")
                if ff_delay is not None:
                    yf = ffmpeg_encode(ffmpeg, cfg, raw, nch)
                    if yf is not None:
                        theirs = measure(x, yf, ff_delay)
                        ffc = "/".join(fmt_snr(v).strip() for v in theirs)
                        if any(a[0] < b[0] - 1.0 for a, b in zip(per, theirs)):
                            problems.append(f"{tag}: more than 1 dB below ffmpeg's encoder")
            out(f"{label:28} {sig:10} {length:5} {res}  {agree:24} {ffc:>14}")

    # a corrupted frame must be caught, or the clean decodes above prove little
    cfg = MAIN
    run([exe, "enc", *cfg[1:], "chord", SECONDS, OUT / "x.sbc", OUT / "x.raw"])
    data = bytearray((OUT / "x.sbc").read_bytes())
    length = ref.frame_length(cfg[2], cfg[3], cfg[4], cfg[6])
    data[5 * length + 3] ^= 0x01                    # frame 5: CRC byte
    data[9 * length + 6] ^= 0x10                    # frame 9: a scale factor
    bad = OUT / "bad.sbc"
    bad.write_bytes(bytes(data))
    y, complaints = decode(ffmpeg, bad, OUT / "bad.raw", 2)
    out()
    out(f"negative control (CRC byte and a scale factor flipped in two frames): ffmpeg reports "
        f"{len(complaints)} problem(s), {len(y)} of {len(data) // length * cfg[3] * cfg[4]} samples")
    for c in complaints[:2]:
        out("  ffmpeg: " + c.strip())
    if not complaints:
        problems.append("ffmpeg did not notice corrupted frames: the CRC check proves nothing")

    out()
    for cfg in configs:
        r = run([exe, "bench", *cfg[1:], 20000])
        out(f"{cfg[0]:28} {r.stdout.strip()}")

    out()
    if problems:
        out(f"FAILED ({len(problems)}):")
        for p in problems:
            out("  " + p)
    else:
        out("all checks passed")
    (OUT / "results.txt").write_text("\n".join(lines) + "\n")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
