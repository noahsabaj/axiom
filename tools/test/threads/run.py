#!/usr/bin/env python3
"""Axiom's threads and scheduler in QEMU.

    python tools/test/threads/run.py [--quick]

Boots build/esp (build it first) and checks the serial log:
  - 8 CPUs: 'threads cpus' (each CPU), 'threads' (the threads every boot
    has: main, an idle thread and a job worker on each CPU), 'threads |
    count' (as many after the tests as before), 'threads test' (2000
    threads started and joined; switches on one CPU and wake-ups across
    two; 1 ms sleeps; fairness between spinning threads, with the main
    thread answering on time and SIMD registers kept across switches;
    threads started on one CPU spreading out; perf and eff threads on P-
    and E-cores, pretended where QEMU has one kind; a perf thread moving
    off an E-core; nothing left over), 'threads spin' while 'threads'
    looks on, and poweroff;
  - 'threads test' on one CPU, and (unless --quick) under TCG, QEMU's own
    CPU emulation, on four;
  - the load average ('uptime'), on two CPUs: idle, after 2 threads spin
    for 30 s (Unix's would be 0.79), and after 30 s idle again;
  - 'panic thread': a thread's stack overflow, named in the report.
Outputs go to build/test/threads/.
"""
import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "test"))
from qemu import boot_all  # noqa: E402

OUT = ROOT / "build" / "test" / "threads"
FAILS = 0


def result(ok, text):
    global FAILS
    FAILS += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + text)
    return ok


TEST = ["type threads test\\n", "until threads test: p", "wait 0.5"]
COUNT = ["type threads | count | to json\\n", 'until "count"', "wait 0.3"]


def check_test(log, cpus, label):
    """The lines 'threads test' prints, and what they must say."""
    m = re.search(r"threads test: (\d+) threads started and joined, \d+ at a time: (\d+) ns "
                  r"each, (\d+) wrong answers", log)
    result(m and m.group(3) == "0",
           f"{label}: {m.group(1)} threads started and joined, {m.group(2)} ns each"
           if m else f"{label}: threads started and joined")
    m = re.search(r"on one CPU, taking turns \d+ times: (\d+) ns a switch", log)
    result(m is not None, f"{label}: a switch on one CPU" + (f", {m.group(1)} ns" if m else ""))
    m = re.search(r"on two CPUs, taking turns \d+ times: (\d+) ns a wake-up", log)
    if cpus > 1:
        result(m is not None, f"{label}: a wake-up across two CPUs" +
               (f", {m.group(1)} ns" if m else ""))
    m = re.search(r"sleeps of 1 ms: (\d+) us late on average, (\d+) us at most", log)
    result(m and int(m.group(1)) < 5000,
           f"{label}: 1 ms sleeps, {m.group(1)} us late on average" if m
           else f"{label}: 1 ms sleeps")
    m = re.search(r"(\d+) spinning threads on (\d+) CPUs for \d+ ms: (\d+) to (\d+) ms of CPU "
                  r"each \((\d+) on average\); the main thread woke (\d+) us late", log)
    result(m and m.group(2) == str(cpus) and int(m.group(3)) * 2 >= int(m.group(5))
           and int(m.group(6)) < 20000,
           f"{label}: fair: {m.group(1)} threads, {m.group(3)} to {m.group(4)} ms each; "
           f"main {m.group(6)} us late" if m else f"{label}: fairness")
    m = re.search(r"SIMD registers checked across (\d+) switches: (\d+) found changed", log)
    result(m and m.group(2) == "0" and int(m.group(1)) > 0,
           f"{label}: SIMD registers kept across {m.group(1)} switches" if m
           else f"{label}: SIMD registers")
    if cpus > 1:
        m = re.search(r"threads started on CPU 1 spread out: (\d+) stolen or handed over; "
                      r"(\d+) ms of CPU at least, (\d+) on average", log)
        result(m and "they did not spread" not in log,
               f"{label}: spread out, {m.group(1)} moved, {m.group(2)} ms at least "
               f"({m.group(3)} on average)" if m else f"{label}: spreading out")
    if cpus >= 4:
        m = re.search(r"perf threads ran (\d+)% of their time on P-cores, \d+ eff threads "
                      r"(\d+)% on E-cores", log)
        result(m and int(m.group(1)) >= 90 and int(m.group(2)) >= 90,
               f"{label}: perf on P-cores {m.group(1)}%, eff on E-cores {m.group(2)}%" if m
               else f"{label}: P- and E-cores")
        m = re.search(r"moved to a P-core (\d+) ms after they went idle", log)
        result(m is not None, f"{label}: a perf thread moved off an E-core" +
               (f" {m.group(1)} ms after a P-core idled" if m else ""))
    m = re.search(r"threads test: (\d+) threads \((\d+) before\), (\d+) heap objects \((\d+)\), "
                  r"(\d+) vm mappings \((\d+)\)", log)
    result(m and m.group(1) == m.group(2) and m.group(3) == m.group(4)
           and m.group(5) == m.group(6) and "not all of it came back" not in log,
           f"{label}: everything given back")
    result("threads test: passed" in log, f"{label}: threads test passed")
    result("AXIOM PANIC" not in log, f"{label}: no panic")


def jobs(opts):
    """Every boot, side by side."""
    jobs = {
        "eight": ([
            "type threads cpus\\n", "until handed", "wait 0.5",
            "type threads\\n", "until moves", "wait 0.5",
            *COUNT,
            *TEST,
            "type threads spin 16 any 2\\n", "until spin: 16", "wait 1",
            "type threads\\n", "until moves", "wait 0.5",
            *COUNT, "wait 2",
            "type threads\\n", "wait 0.5",
            *COUNT,
            "type poweroff\\n", "ended",
        ], ["--smp", "8"], 120),
        "one": ([*TEST, "type poweroff\\n", "ended"], ["--smp", "1"], 90),
        "load": (["wait 12", "type uptime\\n", "until load", "wait 0.5",
                  "type threads spin 2 any 30\\n", "wait 31", "type uptime\\n", "until load", "wait 30",
                  "type uptime\\n", "until load", "wait 0.5", "type poweroff\\n", "ended"],
                 ["--smp", "2"], 120),
        "panic_thread": (["type panic thread\\n", "until AXIOM PANIC", "wait 0.5"],
                         ["--smp", "1"], 30),
    }
    if not opts.quick:
        jobs["tcg"] = ([*TEST, "type poweroff\\n", "ended"], ["--smp", "4", "--accel", "tcg"],
                       400)
    return jobs


def eight(logs):
    print("-- 8 CPUs")
    log, err = logs["eight"]
    first = log[log.find("  cpu  kind"):]
    rows = re.findall(r"^\s+(\d+)\s+\S+\s+\d+\s+\d+%", first.split("name")[0], re.M)
    result(rows == [str(i) for i in range(8)], "'threads cpus' lists 8 CPUs")
    names = re.findall(r"^\s+\d+\s+(\S+)\s+(?:running|parked|ready)", first.split("threads test")[0],
                       re.M)
    want = {"main", "idle/0"} | {f"idle/{i}" for i in range(1, 8)} | \
        {f"jobs/{i}" for i in range(1, 8)}
    result(want <= set(names), "'threads' lists main, an idle thread on each CPU and "
           "a job worker on each AP")
    check_test(log, 8, "8 CPUs")
    spins = re.findall(r"spin: thread \d+ ran (\d+) ms", log)
    result(len(spins) == 16 and all(int(s) > 400 for s in spins),
           f"threads spin: 16 threads ran {min(map(int, spins)) if spins else 0} to "
           f"{max(map(int, spins)) if spins else 0} ms each in 2 s on 8 CPUs")
    during = log[log.find("spin: 16 threads"):]
    result(re.search(r"^\s+\d+\s+spin\s+(?:running|ready)", during, re.M) is not None,
           "'threads' shows the spinners while they run")
    counts = re.findall(r'"count": (\d+)', log)
    result(len(counts) >= 3 and counts[0] == counts[-1],
           f"after them, {counts[-1] if counts else '?'} threads, as at boot")
    result("QEMU ended by itself" in err, "8 CPUs: powered off")


def small(opts, logs):
    print("-- one CPU")
    log, err = logs["one"]
    check_test(log, 1, "1 CPU")
    result("QEMU ended by itself" in err, "1 CPU: powered off")
    if opts.quick:
        return
    print("-- TCG, 4 CPUs")
    log, err = logs["tcg"]
    result("smp: 4 of 4 threads online" in log, "TCG: 4 CPUs came up")
    check_test(log, 4, "TCG")
    result("QEMU ended by itself" in err, "TCG: powered off")


def load(logs):
    print("-- the load average")
    log, err = logs["load"]
    loads = [float(x) for x in re.findall(r"since power-on; load (\d+\.\d\d)", log)]
    result(len(loads) == 3, f"'uptime' says the load, three times: {loads}")
    if len(loads) != 3:
        return
    idle, busy, after = loads
    result(idle < 0.15, f"idle: {idle}")
    # 2 threads wanting a CPU for 30 s, on 2: 2 (1 - e^(-30/60)) = 0.79, less a
    # sample's phase (5 s), more with the host's own interruptions
    result(0.55 <= busy <= 1.0, f"2 spinning threads for 30 s: {busy} (Unix's would be 0.79)")
    result(abs(after - busy * 0.61) <= 0.12, f"then 30 s idle: {after} (e^(-1/2) of it: "
           f"{busy * 0.61:.2f})")


def overflow(logs):
    print("-- a thread's stack overflow")
    log, _ = logs["panic_thread"]
    report = log[log.find("*** AXIOM PANIC ***"):] if "AXIOM PANIC" in log else ""
    cause = next((l for l in report.splitlines() if l.startswith("cause:")), "no report")
    result(re.search(r"^thread \d+, deep$", report, re.M) is not None,
           "panic thread: the report names the thread")
    result(re.search(r"the guard page below the stack of thread \d+, deep \(a stack overflow\)",
                     report) is not None, f"panic thread: {cause}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true", help="skip the TCG boot")
    opts = ap.parse_args()
    logs = boot_all(OUT, jobs(opts))
    eight(logs)
    small(opts, logs)
    load(logs)
    overflow(logs)
    print(f"{'all passed' if not FAILS else f'{FAILS} FAILED'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
