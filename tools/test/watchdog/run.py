#!/usr/bin/env python3
"""The watchdog kept (watch.asm), as axiom-1 has it, in QEMU.

    python tools/test/watchdog/run.py

One boot (build/esp, built first): 'watchdog' is off; 'watchdog on 5' is
too short and 'watchdog test' needs it on; 'watchdog on 12' starts QEMU's
TCO watchdog (ICH9's, at 0x660), whose count is seen moving; for 40 s,
over three times its 12 s, the main loop reloads it and nothing resets;
then 'watchdog test' stops the main loop, interrupts on, and the TCO
resets the machine (QEMU ends: -no-reboot) within its two counts.
Outputs go to build/test/watchdog/.
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "test"))
from qemu import boot  # noqa: E402

OUT = ROOT / "build" / "test" / "watchdog"
FAILS = 0


def result(ok, text):
    global FAILS
    FAILS += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + text)
    return ok


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    script = ["type watchdog\\n", "until ('watchdog on' starts it)",
              "type watchdog on 5\\n", "until usage: watchdog on",
              "type watchdog test\\n", "until only while the watchdog is on",
              "type watchdog on 12\\n", "until watchdog: on:",
              "until watchdog: counting",
              "wait 40",
              "type watchdog\\n", "until watchdog: on:",
              "type watchdog test\\n", "until the main loop stops here",
              "ended"]
    log, err, took = boot(OUT, "watch", script, "--smp", "2", timeout=90, again=False)
    ended = "ended by itself" in err
    print(f"      (watch: {took:.0f} s{', QEMU ended by itself' if ended else ''})", flush=True)
    result("watchdog: off ('watchdog on' starts it)" in log, "'watchdog' says it is off")
    result("usage: watchdog on [<seconds>]: 10 to 600, 120 unless said" in log,
           "'watchdog on 5' is too short: its usage")
    result("watchdog test: only while the watchdog is on" in log, "'watchdog test' needs it on")
    result("watchdog: on: the machine resets at most 12 s after Axiom's main loop stops "
           "(TCO at I/O 660)" in log, "'watchdog on 12' starts QEMU's TCO watchdog at 0x660")
    result("watchdog: counting (" in log and "of 10 ticks left a second on)" in log,
           "its count is seen moving (10 ticks of 0.6 s from the top, counted twice)")
    after = log[log.find("watchdog: counting"):]
    result(after.count("watchdog: on: the machine resets at most 12 s") == 1 and
           "watchdog test: the main loop stops here" in after,
           "40 s on, with the main loop reloading it, the machine still runs")
    result(ended, "'watchdog test' stops the main loop; the TCO resets the machine (QEMU ends)")
    stop = log.rfind("watchdog test: the main loop stops here")
    result(stop >= 0 and "AXIOM PANIC" not in log[stop:],
           "no panic: the reset is the chipset's")
    print(f"{'all passed' if not FAILS else f'{FAILS} FAILED'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
