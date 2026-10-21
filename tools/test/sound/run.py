#!/usr/bin/env python3
"""Axiom's sound in QEMU: an Intel HD Audio controller (ich9-intel-hda) and
its codec (hda-output), whose line out QEMU writes to a WAV file at 48 kHz,
judged here window by window, by Goertzel's filter at each tone's pitch.

    python tools/test/sound/run.py

  - hda: the controller and the codec found, a way from the line out to
    its converter; 'sound test' plays 9600 frames in 200 ms by the
    controller; the kernel's own tones at full volume and at half (a
    quarter of the amplitude); tone.asm's stream (SYS_SOUND_NEW, RO_WAIT),
    alone and then with a tone mixed over it; rtone's, from Rust (if there
    is a nightly toolchain). Each tone: its pitch, its length, its
    amplitude, no jumps in it (nothing dropped or repeated); the mixed
    part: both, summed, not clipped. No stream ran dry.
  - none: no controller: sound plays to nothing, at the same pace (by the
    clock); the programs play and finish as before; +sound gives a program
    the speakers.
Outputs go to build/test/sound/.
"""
import math
import pathlib
import re
import shutil
import struct
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "test"))
from qemu import boot_all  # noqa: E402

OUT = ROOT / "build" / "test" / "sound"
WAV = OUT / "line-out.wav"
RATE = 48000
WIN = 960                               # 20 ms a window
FAILS = 0


def result(ok, text):
    global FAILS
    FAILS += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + text)
    return ok


def script_hda(rust):
    s = ["until log: kept in", "wait 1",
         "type sound\\n", "wait 0.5",
         "type sound test\\n", "until sound test:",
         "type sound volume 100\\n", "wait 0.3",
         "type sound tone 440 300\\n", "wait 0.7",
         "type sound volume 50\\n", "wait 0.2",
         "type sound tone 440 200\\n", "wait 0.6",
         "type sound volume 100\\n", "wait 0.2",
         "type tone 1000 400\\n", "until tone: 1000 Hz for 400", "wait 0.4",
         "type tone 1000 1200 &\\n", "until frames, playing", "wait 0.3",
         "type sound tone 2000 300\\n", "until tone: 1000 Hz for 1200", "wait 0.4"]
    if rust:
        s += ["type rtone 660 300\\n", "until rtone:", "wait 0.4"]
    return s + ["type sound\\n", "wait 1.5"]


def script_none(rust):
    s = ["until log: kept in", "wait 1",
         "type sound\\n", "wait 0.5",
         "type sound test\\n", "until sound test:",
         "type tone 1000 300\\n", "until frames played"]
    if rust:
        s += ["type rtone 660 200\\n", "until rtone:"]
    return s + ["type hello\\n", "until hello: given", "wait 0.3",
                "type +sound hello\\n", "until hello: given", "wait 0.5"]


def samples():
    """The left and right channels, as QEMU wrote them (it was stopped, not
    quit, so the header's lengths are still 0: the data runs to the end)."""
    try:
        raw = WAV.read_bytes()
    except OSError:
        return None, None, 0
    rate = struct.unpack_from("<I", raw, 24)[0]
    data = raw[44:]
    n = len(data) // 4
    s = struct.unpack(f"<{n * 2}h", data[:n * 4])
    return s[0::2], s[1::2], rate


HANN = [0.5 - 0.5 * math.cos(2 * math.pi * i / (WIN - 1)) for i in range(WIN)]
HANN_SUM = sum(HANN)


def amplitude(x, start, hz):
    """A sine's amplitude at that pitch in the window from start (Goertzel,
    Hann-windowed)."""
    k = 2 * math.cos(2 * math.pi * hz / RATE)
    s1 = s2 = 0.0
    for i in range(WIN):
        s0 = x[start + i] * HANN[i] + k * s1 - s2
        s2, s1 = s1, s0
    power = s1 * s1 + s2 * s2 - k * s1 * s2
    return 2 * math.sqrt(max(power, 0)) / HANN_SUM


PITCHES = (440, 660, 1000, 2000)
PRESENT = 1000                          # an amplitude above this is there


def runs(x):
    """[(pitches, first window, windows, {pitch: median amplitude})]: the
    stretches where the same pitches sound, silence left out."""
    found = []
    cur = None
    for w in range(len(x) // WIN):
        amps = {hz: amplitude(x, w * WIN, hz) for hz in PITCHES}
        now = frozenset(hz for hz, a in amps.items() if a > PRESENT)
        if cur and now == cur[0]:
            cur[2] += 1
            cur[3].append(amps)
            continue
        if cur and cur[0]:
            found.append(cur)
        cur = [now, w, 1, [amps]]
    if cur and cur[0]:
        found.append(cur)
    out = []
    for pitches, first, count, amps in found:
        med = {}
        for hz in pitches:
            v = sorted(a[hz] for a in amps)
            med[hz] = v[len(v) // 2]
        out.append((pitches, first, count, med))
    return out


def near(a, b, tol):
    return abs(a - b) <= tol * b


def steps(x, first, count):
    """The largest jump from one sample to the next inside a run (its first
    and last windows, where it fades, left out)."""
    a, b = (first + 1) * WIN, (first + count - 1) * WIN
    return max((abs(x[i] - x[i - 1]) for i in range(a + 1, b)), default=0)


def check_wav(rust):
    left, right, rate = samples()
    if not result(left is not None and rate == RATE, f"QEMU wrote the line out, at 48 kHz ({rate})"):
        return
    result(left == right, "left and right the same (each tone is in both)")
    got = [r for r in runs(left) if r[2] >= 3]           # 60 ms or more
    print("      runs: " + ", ".join(
        f"{'+'.join(str(h) for h in sorted(p))} at {f * 20} ms for {c * 20} ms "
        f"({', '.join(f'{m[h]:.0f}' for h in sorted(p))})" for p, f, c, m in got))
    want = [({440}, 300, {440: 8192}), ({440}, 200, {440: 2048}), ({1000}, 400, {1000: 16384}),
            ({1000}, None, {1000: 16384}), ({1000, 2000}, 300, {1000: 16384, 2000: 8192}),
            ({1000}, None, {1000: 16384})]
    if rust:
        want.append(({660}, 300, {660: 12000}))
    names = ["the kernel's tone, 440 Hz, 300 ms", "at half the volume: a quarter of it",
             "tone.asm's stream, 1000 Hz, 400 ms", "tone.asm's again, 1200 ms",
             "with the kernel's 2000 Hz mixed over it", "and alone again after",
             "rtone's stream (Rust), 660 Hz, 300 ms"]
    if not result(len(got) == len(want), f"{len(want)} stretches of sound, in order (got {len(got)})"):
        return
    for (pitches, ms, amps), (p, first, count, med), name in zip(want, got, names):
        ok = set(p) == pitches
        ok = ok and (ms is None or abs(count * 20 - ms) <= 40)
        ok = ok and all(near(med[h], a, 0.1) for h, a in amps.items())
        step = steps(left, first, count)
        bound = sum(2 * math.pi * h * a / RATE for h, a in amps.items()) * 1.1 + 40
        ok = ok and step <= bound
        result(ok, f"{name}: {'+'.join(str(h) for h in sorted(p))} Hz, {count * 20} ms, amplitude "
                   f"{', '.join(f'{med[h]:.0f}' for h in sorted(p))}, largest step {step}")
    p, first, count, med = got[4]
    peak = max(abs(v) for v in left[first * WIN:(first + count) * WIN])
    result(8192 + 16384 - 600 <= peak < 32767, f"the mix summed, not clipped (peak {peak})")


def check_hda(log, err, rust):
    def has(text):
        return text in log

    result(has("sound: line out at node 3, through 2 nodes from converter 2"),
           "the codec walked: its line out, a way to its converter")
    result(bool(re.search(r"sound: HD Audio 8086:[0-9a-f]{4}, codec 0 \(1af4:00[0-9a-f]{2}\), "
                          r"1 outputs", log)),
           "the controller and the codec, by their IDs")
    result(bool(re.search(r"device\s+HD Audio 8086:[0-9a-f]{4}, codec 1af4:00[0-9a-f]{2}", log)),
           "'sound': the device")
    m = re.search(r"sound test: ok, (\d+) frames in 200 ms, by the controller", log)
    result(bool(m), f"'sound test': 48 kHz, by the controller ({m.group(1) if m else 'no line'})")
    result(has("sound: a tone, 440 Hz for 300 ms") and has("sound: a tone, 2000 Hz for 300 ms"),
           "'sound tone' said what it plays")
    result(has("tone: 1000 Hz for 400 ms, 19200 frames played, 0 short"),
           "tone.asm: all 19200 frames played, none short")
    result(has("tone: 1000 Hz for 1200 ms, 57600 frames played, 0 short"),
           "tone.asm, in the background: 57600 frames, none short")
    if rust:
        result(has("rtone: 660 Hz for 300 ms, 14400 frames played, 0 short"),
               "rtone: all 14400 frames played, none short")
    streams = re.findall(r"streams\s+(\d+)", log)
    result(streams[-1:] == ["0"], f"'sound' after: no stream left open ({streams})")
    caught = re.findall(r"caught up\s+(\d+)", log)     # (a host short of time can starve
    if caught[-1:] != ["0"]:                            # the guest: the WAV says if it mattered)
        print(f"      (the controller caught up with the mixer {caught[-1:]} times)")
    for line in log.splitlines():
        if "ended by a fault" in line or "PANIC" in line:
            result(False, f"no faults: {line}")


def check_none(log, err, rust):
    def has(text):
        return text in log

    result(has("sound: no HD Audio controller; sound plays to nothing"),
           "no controller: said so")
    result(bool(re.search(r"device\s+none: played to nothing", log)), "'sound': no device")
    m = re.search(r"sound test: ok, (\d+) frames in 200 ms, by the clock", log)
    result(bool(m), f"'sound test': 48 kHz, by the clock ({m.group(1) if m else 'no line'})")
    result(has("tone: 1000 Hz for 300 ms, 14400 frames played, 0 short"),
           "tone.asm plays to nothing, and finishes")
    if rust:
        result(has("rtone: 660 Hz for 200 ms, 9600 frames played, 0 short"),
               "rtone plays to nothing, and finishes")
    given = re.findall(r"hello: given:(.*)", log)
    result(len(given) >= 2 and "sound" not in given[0] and given[1].strip() == "sound",
           f"+sound gives a program the speakers ({given})")
    for line in log.splitlines():
        if "ended by a fault" in line or "PANIC" in line:
            result(False, f"no faults: {line}")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    built = subprocess.run([sys.executable, str(ROOT / "tools" / "rust.py"), "rtone"], cwd=ROOT,
                           capture_output=True, text=True)
    rust = built.returncode == 0
    if built.returncode == 3:
        print("      (no nightly toolchain: rtone left out)")
    elif not rust:
        print(built.stdout + built.stderr)
        result(False, "rtone built")
    stick = OUT / "stick.img"
    subprocess.run([sys.executable, str(ROOT / "tools" / "mkstick.py"), str(stick)], cwd=ROOT,
                   check=True, capture_output=True)
    stick_none = OUT / "stick-none.img"                # (a boot locks its image)
    shutil.copyfile(stick, stick_none)
    WAV.unlink(missing_ok=True)
    hda = ("-device ich9-intel-hda -device hda-output,audiodev=snd0 "
           f"-audiodev wav,id=snd0,out.frequency={RATE},path={WAV.relative_to(ROOT).as_posix()}")
    logs = boot_all(OUT, {
        "hda": (script_hda(rust), ["--smp", "2", "--extra", hda, "--stick",
                                   stick.relative_to(ROOT).as_posix()], 90, 1),
        "none": (script_none(rust), ["--smp", "2", "--stick",
                                     stick_none.relative_to(ROOT).as_posix()], 90, 1)})
    check_hda(*logs["hda"], rust)
    check_wav(rust)
    check_none(*logs["none"], rust)
    print(f"{'all passed' if not FAILS else f'{FAILS} FAILED'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
