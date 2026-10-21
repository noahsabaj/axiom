#!/usr/bin/env python3
"""Test runs (harness.asm), as hp-1 has them, in QEMU.

    python tools/test/harness/run.py

Boots build/esp (build it first) eight times, one after another, on one
file of firmware variables, as a machine keeps them across restarts:
  - 'harness queue' writes a script into AxiomRun, and 'reboot';
  - the next boot runs it by itself: shell lines, 'until', 'sleep', 'end'
    (nothing after it runs); its log goes into AxiomLog, and it restarts
    (QEMU ends: -no-reboot);
  - 'harness log' shows that log on the next, which queues the next run:
    a panic (saved, and a restart), then a time limit, then a hang with
    interrupts off, which only QEMU's TCO watchdog ends.
Outputs go to build/test/harness/.
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "test"))
from qemu import boot  # noqa: E402

OUT = ROOT / "build" / "test" / "harness"
VARS = OUT / "vars.fd"
FAILS = 0


def result(ok, text):
    global FAILS
    FAILS += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + text)
    return ok


def queue(lines):
    """The script lines for the next boot's run, then a reboot."""
    script = ["type harness clear\\n", "until are gone"]
    for line in lines:
        script += [f"type harness queue {line}\\n", "until of script"]
    return script + ["type harness\\n", "until the next boot runs", "type reboot\\n", "ended"]


def run(name, script, timeout=60):
    log, err, took = boot(OUT, name, script, "--smp", "2", "--vars", str(VARS),
                          timeout=timeout, again=False)
    ended = "ended by itself" in err
    print(f"      ({name}: {took:.0f} s{', QEMU ended by itself' if ended else ''})", flush=True)
    return log, ended


def shown(log):
    """What 'harness log' showed of the last run's log."""
    start = log.find("harness: the last run's log")
    end = log.find("harness: (the end of the last run's log)")
    return log[start:end] if start >= 0 and end > start else ""


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    VARS.unlink(missing_ok=True)
    read = ["type harness log\\n", "until the end of the last run"]

    log, ended = run("queue", queue(["echo harness says hi", "until says hi", "sleep 1",
                                     "echo after the sleep", "harness", "end",
                                     "echo never"]))
    result("the next boot runs 87 B of script" in log,
           "queued: 'the next boot runs 87 B of script'")
    result(ended, "queued, then 'reboot' ends QEMU")

    log, ended = run("run", ["ended"])
    result("harness: a test run, 87 bytes of script from the UEFI variable AxiomRun" in log,
           "the loader found AxiomRun, and the kernel its 87 bytes")
    result("harness: the TCO watchdog (I/O 660) resets the machine" in log,
           "the loader started QEMU's TCO watchdog at 0x660")
    result("harness says hi" in log and "after the sleep" in log,
           "its shell lines ran, after 'until' and 'sleep'")
    result("harness: sleep 1 s" in log, "'sleep 1' was logged")
    result("harness: a test run, " in log and " of its 87 bytes of script done" in log,
           "'harness' in the run says how far it is")
    result("harness: end" in log and "never" not in log, "'end' ended it: nothing after ran")
    result("harness: the run is over" in log and "goes into AxiomLog (the variable store has" in log,
           "the run is over, and its log goes into AxiomLog")
    result(ended, "and the machine restarts (QEMU ends)")

    log, ended = run("read", read + queue(["echo before the panic", "panic null"]))
    old = shown(log)
    result("axiom> echo harness says hi" in old and "harness says hi" in old,
           "'harness log' shows the run's lines as typed, and what they said")
    result("after the sleep" in old and "harness: the run is over" in old,
           "and the run's end")
    result(ended, "queued a panic, then rebooted")

    log, ended = run("panic", ["ended"])
    result("AXIOM PANIC" in log and "goes into AxiomLog" in log,
           "the panic's report goes into AxiomLog")
    result(ended, "and the machine restarts after it")

    log, ended = run("read-panic", read + queue(["limit 4", "sleep 30", "echo too late"]))
    old = shown(log)
    result("before the panic" in old and "AXIOM PANIC" in old,
           "'harness log' shows the panic report")
    result(ended, "queued a time limit, then rebooted")

    log, ended = run("limit", ["ended"])
    result("harness: limit 4 s" in log and "harness: the run's time is up" in log,
           "'limit 4' ends the run during its 'sleep 30'")
    result("too late" not in log and ended, "nothing after it ran, and the machine restarts")

    log, ended = run("read-limit", read + queue(["watchdog 5", "harness hang"]))
    result("harness: the run's time is up" in shown(log), "'harness log' shows that it ran out")
    result(ended, "queued a hang, then rebooted")

    log, ended = run("hang", ["ended"], timeout=40)
    result("harness: watchdog 5 s" in log and "stopping here, interrupts off" in log,
           "'watchdog 5', then 'harness hang' stops, interrupts off")
    result(ended, "QEMU's TCO watchdog resets the machine (QEMU ends)")

    print(f"{'all passed' if not FAILS else f'{FAILS} FAILED'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
