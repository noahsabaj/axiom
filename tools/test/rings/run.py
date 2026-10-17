#!/usr/bin/env python3
"""Axiom's async rings in QEMU.

    python tools/test/rings/run.py [--quick]

Boots build/esp (build it first) and checks the serial log:
  - 8 CPUs: 'rings' (none yet; the thread async), 'rings test' (entries
    in one go, each completed with what it should; a wait completed from
    another thread with nobody blocked on it; timeouts in the order of
    their deadlines; linked entries, a chain canceled after a refusal;
    cancel; join; copies between blocks of memory; a full completion
    queue holding entries back; a corrupt ring; a ring closed with
    requests waiting, listed first; threads each with a ring; the cost of
    an entry; nothing left over), 'rings' after, a bad argument, and
    poweroff;
  - 'rings test' on one CPU, and (unless --quick) under TCG, QEMU's own
    CPU emulation, on four.
Outputs go to build/test/rings/.
"""
import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "test"))
from qemu import boot_all  # noqa: E402

OUT = ROOT / "build" / "test" / "rings"
FAILS = 0


def result(ok, text):
    global FAILS
    FAILS += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + text)
    return ok


TEST = ["type rings test\\n", "until rings test: p", "wait 0.5"]
LINES = ("7 entries", "a wait in the ring", "a 1 ms timeout", "a wait linked", "a wait never",
         "a join", "copies between", "with 16 completions", "a submission tail", "a ring closed",
         "a nop", "0 rings", "passed")


def check_test(log, label):
    """The lines 'rings test' prints, and what they must say."""
    lines = re.findall(r"^rings test: (.*)$", log, re.M)
    wrong = [l for l in lines if not l.startswith(LINES) and not re.match(r"\d+ threads, each", l)]
    result(lines and not wrong, f"{label}: every check as expected" +
           ("".join(f"\n      rings test: {w}" for w in wrong[:12])))
    for start, what in (("7 entries in one go", "entries in one go, each completed as it should"),
                        ("a wait in the ring, nobody blocked", "a wait completed from another "
                         "thread"),
                        ("a 1 ms timeout and a 2 ms wait completed in the order", "timeouts in "
                         "deadline order"),
                        ("a wait linked to a signal linked to a nop", "linked entries; a chain "
                         "canceled"),
                        ("a wait never satisfied, canceled", "cancel"),
                        ("a join completed", "join"),
                        ("copies between blocks of memory", "copies by handle"),
                        ("with 16 completions owed", "a full completion queue holds entries back"),
                        ("a submission tail too far ahead refused", "a corrupt ring")):
        result(f"rings test: {start}" in log, f"{label}: {what}")
    m = re.search(r"^\s+\d+\s+test\s+\d+\s+8\s+16\s+(\d+)\s+(\d+)\s+(\d+)\s+\d+\s+(\d+)\s+\d+$",
                  log, re.M)
    result(m and m.group(1) == "4" and m.group(2) == "3" and m.group(3) == "4"
           and m.group(4) == "3", f"{label}: 'rings' while requests wait: owed {m.group(1)}, "
           f"waiting {m.group(2)}, taken {m.group(3)}, waited {m.group(4)}" if m
           else f"{label}: 'rings' while requests wait")
    result("rings test: a ring closed with two waits, a 10 s timeout and a chain waiting: all "
           "canceled" in log, f"{label}: a ring closed with requests waiting")
    m = re.search(r"rings test: (\d+) threads, each with a ring, for 200 ms: (\d+) entries, (\d+) "
                  r"waits woken and (\d+) timed out .*, (\d+) unexpected results", log)
    result(m and int(m.group(2)) > 0 and int(m.group(3)) > 0 and m.group(5) == "0",
           f"{label}: {m.group(1)} threads with rings: {m.group(2)} entries, {m.group(3)} woken, "
           f"{m.group(4)} timed out, {m.group(5)} unexpected" if m
           else f"{label}: threads with rings")
    m = re.search(r"a nop (\d+) ns in batches of 32, (\d+) ns one at a time; a signal (\d+) ns in "
                  r"batches of 32; a wait taken, then signalled and its completion read, (\d+) ns",
                  log)
    result(m is not None, f"{label}: nop {m.group(1)} ns batched, {m.group(2)} ns alone; signal "
           f"{m.group(3)} ns; wait round trip {m.group(4)} ns" if m else f"{label}: timing")
    m = re.search(r"rings test: (\d+) rings \((\d+) before\), (\d+) requests \((\d+)\), (\d+) timers "
                  r"\((\d+)\), (\d+) events \((\d+)\), (\d+) blocks of memory \((\d+)\), (\d+) "
                  r"threads \((\d+)\), (\d+) handles held by the kernel \((\d+)\), (\d+) heap "
                  r"objects \((\d+)\), (\d+) vm mappings \((\d+)\)", log)
    result(m and all(m.group(i) == m.group(i + 1) for i in range(1, 19, 2))
           and "not all of it came back" not in log, f"{label}: everything given back")
    result("rings test: passed" in log, f"{label}: rings test passed")
    result("AXIOM PANIC" not in log, f"{label}: no panic")


def summary(text):
    m = re.search(r"^\s+(\d+) rings; requests: (\d+) in being, (\d+) finished; timers: (\d+) "
                  r"waiting, (\d+) fired", text, re.M)
    return m and tuple(int(g) for g in m.groups())


def jobs(opts):
    """Every boot, side by side."""
    jobs = {
        "eight": ([
            "type rings\\n", "until fired", "wait 0.5",
            *TEST,
            "type rings\\n", "wait 0.5",
            "type rings nonsense\\n", "wait 0.3",
            "type objects\\n", "until refused", "wait 0.5",
            "type poweroff\\n", "ended",
        ], ["--smp", "8"], 120),
        "one": ([*TEST, "type poweroff\\n", "ended"], ["--smp", "1"], 90),
    }
    if not opts.quick:
        jobs["tcg"] = ([*TEST, "type poweroff\\n", "ended"], ["--smp", "4", "--accel", "tcg"],
                       400)
    return jobs


def eight(logs):
    print("-- 8 CPUs")
    log, err = logs["eight"]
    first = summary(log[:log.find("rings test")])
    result(first and first[0] == 0 and first[1] == 0 and first[3] == 0,
           f"'rings' before: {first}")
    check_test(log, "8 CPUs")
    after = log[log.find("rings test: passed"):]
    last = summary(after)
    result(last and last[0] == 0 and last[1] == 0 and last[2] > 1000 and last[3] == 0
           and last[4] > 0, f"'rings' after: {last}")
    result("usage: rings [test]" in log, "'rings nonsense': the usage")
    m = re.search(r"^\s+ring\s+0\s+(\d+)$", after, re.M)
    result(m and int(m.group(1)) >= 10, f"'objects' lists rings: 0 live, {m.group(1) if m else '?'}"
           f" made")
    result("QEMU ended by itself" in err, "8 CPUs: powered off")


def small(opts, logs):
    print("-- one CPU")
    log, err = logs["one"]
    check_test(log, "1 CPU")
    result("QEMU ended by itself" in err, "1 CPU: powered off")
    if opts.quick:
        return
    print("-- TCG, 4 CPUs")
    log, err = logs["tcg"]
    result("smp: 4 of 4 threads online" in log, "TCG: 4 CPUs came up")
    check_test(log, "TCG")
    result("QEMU ended by itself" in err, "TCG: powered off")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true", help="skip the TCG boot")
    opts = ap.parse_args()
    logs = boot_all(OUT, jobs(opts))
    eight(logs)
    small(opts, logs)
    print(f"{'all passed' if not FAILS else f'{FAILS} FAILED'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
