#!/usr/bin/env python3
"""Axiom's NVMe driver in QEMU, on QEMU's own NVMe drive.

    python tools/test/nvme/run.py [--quick]

Each boot gets a 64 MiB drive of its own (serial AXIOMTEST, so Axiom may
write to it), every 512-byte block stamped with its number, and runs
'nvme', 'nvme test' and 'nvme' again. Checked from the serial log: as many
I/O queues as asked for, each interrupting its CPU; the first MiB read
back as stamped; a thread on every CPU reading at random, every read as
the first said, every queue used and interrupted; each thread's 128 KiB
written, read back and flushed; a read through the disk layer into a
buffer at an odd address; and afterwards, from the drive's file, that the
writes are there and nothing else changed. Boots:
  - 4 CPUs, a queue each;
  - 1 CPU;
  - 4 CPUs, the controller allowing 2 queues (max_ioqpairs): two CPUs'
    threads woken from another CPU's interrupt;
  - 4 CPUs, an MSI-X table of 2 entries (msix_qsize): 2 queues;
  - 8 CPUs;
  - (unless --quick) TCG, QEMU's own CPU emulation, on 4.
Outputs go to build/test/nvme/.
"""
import argparse
import pathlib
import re
import struct
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "test"))
from qemu import boot_all  # noqa: E402

OUT = ROOT / "build" / "test" / "nvme"
FAILS = 0
SIZE = 64 << 20
BLOCK = 512
MAGIC = 0x5354414D50000000          # block b starts with MAGIC | b (nvmetest.asm NT_MAGIC)
WMAGIC = 0x5752495445000000         # a written qword at byte P is WMAGIC ^ P (NT_WMAGIC)
REF = 1 << 20                       # the first MiB, read and never written
WBYTES = 128 << 10                  # written by each thread, after it


def result(ok, text):
    global FAILS
    FAILS += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + text)
    return ok


def stamped():
    data = bytearray(SIZE)
    for b in range(SIZE // BLOCK):
        struct.pack_into("<Q", data, b * BLOCK, MAGIC | b)
    return data


# name: (CPUs, what the drive is given, queues expected, the TCG?)
BOOTS = {
    "four": (4, "", 4, False),
    "one": (1, "", 1, False),
    "pairs": (4, ",max_ioqpairs=2", 2, False),
    "table": (4, ",msix_qsize=2", 2, False),
    "eight": (8, "", 8, False),
    "tcg": (4, "", 4, True),
}
TEST = ["type nvme\\n", "until interrupts", "wait 0.3",
        "type nvme test\\n", "until nvme test: p", "wait 0.3",
        "type nvme\\n", "until interrupts", "wait 0.3",
        "type nvme nonsense\\n", "until usage", "wait 0.2",
        "type poweroff\\n", "ended"]


def jobs(opts):
    data = stamped()
    out = {}
    OUT.mkdir(parents=True, exist_ok=True)
    for name, (cpus, more, _, tcg) in BOOTS.items():
        if tcg and opts.quick:
            continue
        img = OUT / f"{name}.img"
        img.write_bytes(data)
        drive = (f"-drive file={img.as_posix()},if=none,id=nvm,format=raw "
                 f"-device nvme,serial=AXIOMTEST,drive=nvm{more}")
        args = ["--smp", str(cpus), "--extra", drive] + (["--accel", "tcg"] if tcg else [])
        out[name] = (TEST, args, 400 if tcg else 90)
    return out


def check(name, log, err):
    cpus, _, queues, _ = BOOTS[name]
    label = f"{name} ({cpus} CPU{'s' if cpus > 1 else ''}, {queues} queue{'s' if queues > 1 else ''})"
    print(f"-- {label}")
    threads = min(cpus, 32)
    m = re.search(r"^nvme: QEMU NVMe Ctrl, (\d+) I/O queues, (.*)$", log, re.M)
    result(m and int(m.group(1)) == queues and m.group(2) == "each interrupting its own CPU",
           f"{name}: at boot, {m.group(1)} I/O queues, {m.group(2)}" if m else f"{name}: at boot")
    result(re.search(r"^disk\d: NVMe, 64\.0 MiB in 512-byte blocks", log, re.M),
           f"{name}: a disk of 64 MiB in 512-byte blocks")
    test = log[log.find("nvme test:"):]
    first = log[:log.find("nvme test:")]
    rows = re.findall(r"^\s+(\d+)\s+(-?\d+)\s+64\s+0\s+(\d+)\s+(\d+)\s+(\d+)\s+0$", first, re.M)
    result(len(rows) == queues and [int(r[1]) for r in rows] == list(range(queues)),
           f"{name}: 'nvme' lists {len(rows)} queues, each on its CPU")
    result("nvme test: 2048 blocks stamped, 0 of them wrongly" in test,
           f"{name}: the first MiB as stamped")
    m = re.search(r"nvme test: (\d+) reads of 1 to (\d+) blocks by (\d+) threads, one on each CPU: "
                  r"(.*) in (\d+) ms, (\d+) MiB/s; (\d+) wrong, (\d+) failed", test)
    result(m and int(m.group(1)) == 200 * threads and m.group(2) == "128"
           and int(m.group(3)) == threads and m.group(7) == "0" and m.group(8) == "0",
           f"{name}: {m.group(1)} reads by {m.group(3)} threads, {m.group(4)} in {m.group(5)} ms "
           f"({m.group(6)} MiB/s), {m.group(7)} wrong, {m.group(8)} failed" if m
           else f"{name}: reads from every CPU")
    qs = re.findall(r"nvme test: queue (\d+), interrupting CPU (-?\d+): (\d+) commands, (\d+) "
                    r"interrupts, (\d+) polls", test)
    result(len(qs) == queues and all(int(q[2]) > 0 and int(q[3]) > 0 for q in qs),
           f"{name}: every queue used and interrupted: " +
           ", ".join(f"{q[0]}: {q[2]} commands, {q[3]} interrupts, {q[4]} polls" for q in qs))
    result(f"nvme test: {threads} threads each wrote 128 KiB of its own, read it back and flushed"
           in test and "0 qwords wrong" in test, f"{name}: writes read back")
    result("nvme test: 300 blocks through the disk layer into a buffer at an odd address, as "
           "read before" in test, f"{name}: through the disk layer, at an odd address")
    result("nvme test: passed" in test, f"{name}: nvme test passed")
    after = test[test.find("nvme test: passed"):]
    rows = re.findall(r"^\s+(\d+)\s+(-?\d+)\s+64\s+0\s+(\d+)\s+(\d+)\s+(\d+)\s+0$", after, re.M)
    result(len(rows) == queues and all(int(r[3]) > 0 for r in rows),
           f"{name}: 'nvme' after: nothing out, every queue interrupted")
    result("usage: nvme [test]" in log, f"{name}: 'nvme nonsense': the usage")
    result("AXIOM PANIC" not in log, f"{name}: no panic")
    result("QEMU ended by itself" in err, f"{name}: powered off")
    data = (OUT / f"{name}.img").read_bytes()
    end = REF + threads * WBYTES
    bad = [p for p in range(REF, end, 8)
           if struct.unpack_from("<Q", data, p)[0] != WMAGIC ^ p]
    result(not bad, f"{name}: the drive's file holds the {threads * WBYTES >> 10} KiB written"
           + (f"; {len(bad)} qwords not, the first at {bad[0]:#x}" if bad else ""))
    want = stamped()
    same = data[:REF] == want[:REF] and data[end:] == want[end:]
    result(same, f"{name}: and nothing else on it changed")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true", help="skip the TCG boot")
    opts = ap.parse_args()
    logs = boot_all(OUT, jobs(opts))
    for name in logs:
        check(name, *logs[name])
    print(f"{'all passed' if not FAILS else f'{FAILS} FAILED'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
