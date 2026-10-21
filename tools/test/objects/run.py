#!/usr/bin/env python3
"""Axiom's kernel objects and capabilities in QEMU.

    python tools/test/objects/run.py [--quick]

Boots build/esp (build it first) and checks the serial log:
  - 8 CPUs: 'objects' (each type, live and made; the task 'kernel'),
    'objects test' (an event's handles: fewer rights, closed, reused,
    forged and mistyped handles; a task of its own given narrowed handles,
    then a revoke, its refusals counted and in the audit ring, its handles
    listed, one revoked and one derived from the kernel's; a handle
    that expires; windows on a block of memory; threads deriving and
    closing handles while what they derive from is revoked; the cost of
    the common operations; nothing left over), 'objects 1', 'objects
    audit', a task that is not there, a bad argument, and poweroff;
  - 'objects test' on one CPU, and (unless --quick) under TCG, QEMU's own
    CPU emulation, on four.
Outputs go to build/test/objects/.
"""
import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "test"))
from qemu import boot_all  # noqa: E402

OUT = ROOT / "build" / "test" / "objects"
FAILS = 0


def result(ok, text):
    global FAILS
    FAILS += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + text)
    return ok


TEST = ["type objects test\\n", "until objects test: p", "wait 0.5"]


def check_test(log, label):
    """The lines 'objects test' prints, and what they must say."""
    wrong = re.findall(r"^objects test: (?!an event|a task|a handle|a read-only|\d+ threads|"
                       r"signalling|\d+ tasks|passed).*$", log, re.M)
    result(not wrong, f"{label}: every check as expected" +
           ("".join(f"\n      {w}" for w in wrong[:12])))
    result("objects test: an event's handles:" in log,
           f"{label}: an event's handles: fewer rights; closed, reused, forged and mistyped "
           f"handles refused")
    m = re.search(r"objects test: a task given .*; (\d+) refusals in the audit ring", log)
    result(m and m.group(1) == "5", f"{label}: a task given narrowed handles, then a revoke; "
           f"{m.group(1) if m else '?'} refusals audited")
    rows = re.search(r"task \d+, agent: 2 handles, in a table of \d+\n.*\n"
                     r"\s+0x\w+\s+revoked: refused until closed\n"
                     r"\s+0x\w+\s+event\s+\d+ go\s+give wait\s+-\s+0x\w+ of task 1\n", log)
    result(rows is not None, f"{label}: 'objects <task>' shows the agent's handles: the revoked "
           f"one, and one derived from the kernel's")
    result("objects test: a handle expiring in 2 ms" in log, f"{label}: a handle that expires")
    result("objects test: a read-only window of 100 bytes" in log,
           f"{label}: windows on a block of memory")
    m = re.search(r"objects test: (\d+) threads deriving, using and closing handles to one event "
                  r"while what was derived from it was revoked (\d+) times \((\d+) handles in "
                  r"all\): (\d+) operations, (\d+) unexpected results; then (\d+) capability and "
                  r"(\d+) references to it", log)
    result(m and int(m.group(2)) > 0 and int(m.group(3)) > 0 and m.group(5) == "0"
           and m.group(6) == "1" and m.group(7) == "2",
           f"{label}: {m.group(1)} threads against {m.group(2)} revokes ({m.group(3)} handles "
           f"revoked), {m.group(4)} operations, {m.group(5)} unexpected" if m
           else f"{label}: revoking while threads derive")
    m = re.search(r"by handle \(finding it, checking it, signalling\) (\d+) ns; deriving a handle "
                  r"and closing it (\d+) ns", log)
    result(m is not None, f"{label}: signal by handle {m.group(1)} ns, dup and close "
           f"{m.group(2)} ns" if m else f"{label}: timing")
    m = re.search(r"objects test: (\d+) tasks \((\d+) before\), (\d+) threads \((\d+)\), (\d+) "
                  r"events \((\d+)\), (\d+) blocks of memory \((\d+)\), (\d+) handles held by the "
                  r"kernel \((\d+)\), (\d+) heap objects \((\d+)\), (\d+) vm mappings \((\d+)\)",
                  log)
    result(m and all(m.group(i) == m.group(i + 1) for i in range(1, 15, 2))
           and "not all of it came back" not in log, f"{label}: everything given back")
    result("objects test: passed" in log, f"{label}: objects test passed")
    result("AXIOM PANIC" not in log, f"{label}: no panic")


def jobs(opts):
    """Every boot, side by side."""
    jobs = {
        "eight": ([
            "type objects\\n", "until refused", "wait 0.5",
            *TEST,
            "type objects\\n", "wait 0.5",
            "type objects 1\\n", "until derived from", "wait 0.5",
            "type objects audit\\n", "until since boot", "wait 1",
            "type objects 99\\n", "wait 0.3",
            "type objects nonsense\\n", "wait 0.3",
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
    first = log[log.find("  type       live"):log.find("objects test")]
    types = dict(re.findall(r"^\s+(task|thread|event|memory)\s+(\d+)\s+\d+$", first, re.M))
    result(set(types) == {"task", "thread", "event", "memory"} and types["task"] == "1"
           and types["event"] == "0" and types["memory"] == "1",   # the desktop's look
           f"'objects' lists each type: {types}")
    m = re.search(r"^\s+1\s+kernel\s+0\s+(\d+)\s+0\s+\d+\s+\d+$", first, re.M)
    result(m and m.group(1) == types.get("thread"),
           f"'objects' lists the task 'kernel', acting for all {m.group(1) if m else '?'} threads")
    check_test(log, "8 CPUs")
    after = log[log.find("objects test: passed"):]
    made = dict(re.findall(r"^\s+(task|thread|event|memory)\s+\d+\s+(\d+)$", after, re.M))
    result(made and int(made.get("task", 0)) >= 2 and int(made.get("event", 0)) >= 6
           and int(made.get("memory", 0)) >= 1, f"'objects' after: made {made}")
    result(re.search(r"task 1, kernel: 0 handles, in a table of \d+", log) is not None,
           "'objects 1': the kernel holds no handles after the test")
    m = re.search(r"(\d+) changes and refusals since boot; the last (\d+):", log)
    records = re.findall(r"^\s+\d+\.\d\d s\s+\d+\s+(make|dup|window|give|close|revoke|use|end)\s",
                         log, re.M)
    result(m and int(m.group(1)) > 1000 and m.group(2) == "32" and len(records) == 32,
           f"'objects audit': {m.group(1) if m else '?'} records, the last {len(records)} shown")
    result("objects: no task 99" in log, "'objects 99': no such task")
    result("usage: objects [test | audit | <task id>]" in log, "'objects nonsense': the usage")
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
