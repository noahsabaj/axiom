#!/usr/bin/env python3
"""Axiom's ring 3 in QEMU: programs from the boot stick.

    python tools/test/user/run.py [--quick]

Builds a USB stick image of build/esp (build it first: the programs are in
build/esp/EFI/AXIOM), boots it and checks the serial log:
  - 4 CPUs: 'run hello' (it says hello, its arguments, where it runs; it
    exits 0), a program that is not there, a file that is not a program,
    one too large, a path, 'run spin' stopped by ctrl+C (spinning, and
    parked), a fault, 'user', 'user test' (the program TEST checks itself; a fault of
    each kind ends its task and the kernel goes on; tasks that spin, park
    in their ring, call the kernel, or have another thread fault, killed in
    time; nothing left over), 'objects' (the console), and poweroff;
  - 'user test' on one CPU, and (unless --quick) under TCG, QEMU's own CPU
    emulation, on four;
  - files through a capability: FSTEST while vol0 is read-only (writes
    refused) and, after 'vol 0 rw', twice (what it leaves, it cleans up),
    then Notes writes a new file and saves it; the stick's FAT, and what
    Notes wrote, checked from here.
Outputs go to build/test/user/.
"""
import argparse
import pathlib
import re
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "test"))
from qemu import boot_all  # noqa: E402

OUT = ROOT / "build" / "test" / "user"
FAILS = 0
READY = ["until log: kept in"]                  # the boot stick is mounted
TEST = ["type user test\\n", "until user test: passed", "wait 0.3"]
FAULTS = ("null", "write", "exec", "kernel", "priv", "ud", "div", "stack", "gp", "int", "io",
          "unmap", "close", "revoke")
SPINS = ("4", "3 wait", "3 calls", "3 fault")


def result(ok, text):
    global FAILS
    FAILS += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + text)
    return ok


def check_test(log, label):
    """What 'user test' prints, and what it must say."""
    result("test: arguments 'one two  three'" in log, f"{label}: TEST got its arguments")
    result(log.count("test: all 21 checks passed") >= 2, f"{label}: TEST passed its 21 checks, "
                                                         "twice")
    for kind in FAULTS:
        result(f"user test: fault {kind}: the task ended, the kernel went on" in log,
               f"{label}: fault {kind}")
    for what, line in (("a page fault at 0", r"FAULT: Page fault at 0x[0-9a-f]+: a read from "
                                             r"0x0+, where nothing is mapped"),
                       ("writing code", r"a write to 0x0+4[0-9a-f]+, which is read-only"),
                       ("running data", r"running code at 0x0+4[0-9a-f]+, which is not code"),
                       ("the kernel's half", r"a read from 0xffffffff80000000, which the page "
                                             r"does not allow"),
                       ("the stack's guard", r"a write to 0x0+7feffffef[0-9a-f]{3}, where "
                                             r"nothing is mapped"),
                       ("ud2", r"FAULT: Invalid opcode at"),
                       ("dividing by 0", r"FAULT: Divide error at")):
        result(re.search(line, log) is not None, f"{label}: said: {what}")
    for spin in SPINS:
        m = re.search(rf"user test: spin {spin}: killed, gone in (\d+) us; it returned -12", log)
        result(m and int(m.group(1)) < (1000000 if label == "TCG" else 50000),
               f"{label}: spin {spin}: killed, gone in {m.group(1)} us" if m
               else f"{label}: spin {spin}: killed")
    m = re.search(r"user test: (\d+) tasks \((\d+) before\), (\d+) threads \((\d+)\), (\d+) blocks "
                  r"of memory \((\d+)\), (\d+) rings \((\d+)\), (\d+) heap objects \((\d+)\), (\d+) "
                  r"vm mappings \((\d+)\), (\d+) user pages \((\d+)\), (\d+) user page tables "
                  r"\((\d+)\), (\d+) channel ends \((\d+)\)", log)
    result(m and all(m.group(i) == m.group(i + 1) for i in range(1, 19, 2))
           and m.group(13) == "0" and m.group(15) == "0"
           and "not all of it came back" not in log, f"{label}: everything given back")
    result("user test: passed" in log and "FAILED" not in log, f"{label}: user test passed")
    result("AXIOM PANIC" not in log, f"{label}: no panic")


def jobs(opts):
    """Every boot, side by side, each on a stick of its own (they write
    their logs to it)."""
    OUT.mkdir(parents=True, exist_ok=True)
    stick = OUT / "stick.img"
    text = OUT / "notaprog.txt"                 # a file that is not a program
    text.write_text("Not a program, though long enough to have a header.\n" * 4)
    subprocess.run([sys.executable, str(ROOT / "tools" / "mkstick.py"), str(stick),
                    "--file", f"NOTAPROG.TXT={text}"], cwd=ROOT, check=True, capture_output=True)
    names = ["four", "one", "files"] + ([] if opts.quick else ["tcg"])
    for name in names:
        shutil.copyfile(stick, OUT / f"stick-{name}.img")

    def on(name):
        return ["--stick", (OUT / f"stick-{name}.img").relative_to(ROOT).as_posix()]
    four = [
        *READY,
        "type run hello one two\\n", "until run: HELLO exited",
        "type run nothing\\n", "until nothing called",
        "type run /NOTAPROG.TXT\\n", "until not an Axiom program",
        "type run /EFI/BOOT/BOOTX64.EFI\\n", "until BOOTX64.EFI is not",
        "type run /EFI/AXIOM/HELLO.AXE by path\\n", "until run: HELLO exited",
        "type run spin 2\\n", "until spin: 2 threads", "wait 0.3",
        "sendkey ctrl-c", "until run: SPIN stopped",
        "type run spin 3 wait\\n", "until spin: 3 threads", "wait 0.2",
        "sendkey ctrl-c", "until run: SPIN stopped",
        "type run fault write\\n", "until run: FAULT ended by a fault",
        "type run fault\\n", "until run: FAULT exited",
        "type user\\n", "until their pages",
        *TEST,
        "type run test\\n", "until run: TEST exited",
        "type user\\n", "wait 0.3",
        "type user nonsense\\n", "wait 0.3",
        "type objects\\n", "until refused", "wait 0.3",
        "type poweroff\\n", "ended",
    ]
    jobs = {
        "four": (four, ["--smp", "4", *on("four")], 120),
        "one": ([*READY, *TEST, "type poweroff\\n", "ended"], ["--smp", "1", *on("one")], 90),
        "files": ([*READY, "type run fstest ro\\n", "until run: FSTEST exited",
                   "type vol 0 rw\\n", "until vol0 is writable",
                   "type run fstest\\n", "until run: FSTEST exited",
                   "type run fstest\\n", "until run: FSTEST exited", "wait 0.3",
                   # Notes: a new file, written, saved, closed
                   "type run notes notes.txt\\n", "wait 3", "type Written by Notes.\\n",
                   "wait 0.5", "sendkey ctrl-s", "wait 1", "sendkey ctrl-w",
                   "until run: NOTES exited", "wait 0.3",
                   "type poweroff\\n", "ended"], ["--smp", "2", *on("files")], 90),
    }
    if not opts.quick:
        jobs["tcg"] = ([*READY, *TEST, "type poweroff\\n", "ended"],
                       ["--smp", "4", "--accel", "tcg", *on("tcg")], 400)
    return jobs


def four(logs):
    print("-- 4 CPUs")
    log, err = logs["four"]
    result("Hello from ring 3!" in log, "hello: said hello")
    result("hello: arguments: one two" in log, "hello: its arguments")
    m = re.search(r"hello: code at 0x(\w+), stack at 0x(\w+), ring at 0x(\w+)", log)
    result(m and 0x400000 < int(m.group(1), 16) < 0x500000
           and 0x7fefffff0000 < int(m.group(2), 16) < 0x7ff000000000
           and int(m.group(3), 16) == 0x100000000000,
           f"hello: code at {m.group(1)}, stack at {m.group(2)}, ring at {m.group(3)}" if m
           else "hello: where it runs")
    result(log.count("run: HELLO exited with 0") >= 2, "hello: exited with 0, by name and by path")
    result("hello: arguments: by path" in log, "a program by its path")
    result("nothing called 'NOTHING.AXE' there" in log, "a program that is not there")
    result("run: /NOTAPROG.TXT is not an Axiom program" in log, "a file that is not one")
    result("run: /EFI/BOOT/BOOTX64.EFI is not an Axiom program" in log,
           "a file over 64 KiB: read whole, and not one")
    result(log.count("run: SPIN stopped") == 2, "ctrl+C stopped 'run spin', twice")
    result(re.search(r"FAULT: Page fault at 0x\w+: a write to 0x\w+, which is read-only", log)
           is not None and "run: FAULT ended by a fault" in log, "run fault write: said, and ended")
    result("usage: run fault" in log and "run: FAULT exited with 1" in log,
           "run fault, no kind: its usage, and 1")
    m = re.findall(r"programs: (\d+) started, (\d+) ended by a fault, (\d+) stopped; running: "
                   r"(\w+)", log)
    result(len(m) >= 2 and m[0] == ("6", "1", "2", "none"),
           f"'user' before the test: {m[0] if m else '?'}")
    result(re.search(r"their pages: 0, and 0 page tables", log) is not None,
           "'user': no pages left once programs end")
    check_test(log, "4 CPUs")
    result("run: TEST exited with 0" in log and log.count("test: all 21 checks passed") >= 3,
           "'run test': its children started from the main loop")
    m = re.findall(r"programs: (\d+) started", log)
    result(len(m) >= 2 and int(m[-1]) - int(m[0]) >= 3 * 12,
           f"'user': programs started by programs counted ({m[0]} then {m[-1]})" if m
           else "'user': programs started by programs counted")
    result("usage: user [test]" in log, "'user nonsense': the usage")
    result(re.search(r"^\s+console\s+1\s+1$", log, re.M) is not None, "'objects': one console")
    result("QEMU ended by itself" in err, "4 CPUs: powered off")


def files(logs):
    print("-- files")
    log, err = logs["files"]
    result("fstest: all 6 checks passed" in log, "fstest ro: writes refused, reads allowed")
    result(log.count("fstest: all 24 checks passed") == 2, "fstest: all 24 checks, twice")
    result(log.count("run: FSTEST exited with 0") == 3, "fstest: exited with 0, each time")
    result("AXIOM PANIC" not in log, "files: no panic")
    result("QEMU ended by itself" in err, "files: powered off")
    result("run: NOTES exited with 0" in log, "notes: closed, exited with 0")
    r = subprocess.run([sys.executable, str(ROOT / "tools" / "fatcheck.py"),
                        str(OUT / "stick-files.img"), "--show", "/notes.txt"],
                       capture_output=True, text=True)
    result(r.returncode == 0, "files: the stick's FAT has no damage" +
           ("" if r.returncode == 0 else ": " + (r.stdout + r.stderr).strip()[-300:]))
    result("--- /notes.txt: 18 bytes\nWritten by Notes.\n" in r.stdout,
           "notes: the file it saved, as typed")


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
    four(logs)
    files(logs)
    small(opts, logs)
    print(f"{'all passed' if not FAILS else f'{FAILS} FAILED'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
