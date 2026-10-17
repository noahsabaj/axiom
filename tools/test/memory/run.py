#!/usr/bin/env python3
"""Axiom's memory in QEMU: its own page tables, W^X, guard pages, the vm
region, TLB shootdowns, the heap, and the firmware tables.

    python tools/test/memory/run.py [--quick]

Boots build/esp (build it first) and checks the serial log:
  - a full machine (8 CPUs, a USB stick to boot from and log to, an NVMe
    disk, a network card): the boot's page-table line, 'mem', 'mem' on
    addresses of each kind (code, constants, data, the direct map, nothing),
    'mem test' (the heap and the vm region on one CPU, then on all eight at
    once, with TLB shootdowns from each; a W^X audit of every page table
    entry; nothing left over), the drivers' work (disks, DHCP, saving the
    log), and poweroff through the firmware tables: QEMU must end by itself;
  - 'mem test' on one CPU, and (unless --quick) under TCG, QEMU's own CPU
    emulation, on four;
  - each 'panic <fault>' in a boot of its own: the report must name what
    the fault ran into.
Outputs go to build/test/memory/.
"""
import argparse
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "test"))
from qemu import boot_all  # noqa: E402

OUT = ROOT / "build" / "test" / "memory"
FAILS = 0

FAULTS = {
    "null": ["Page fault",
             "cause: a read from 0x0000000000000008, where nothing is mapped: a null pointer"],
    "code": ["Page fault", ", which is read-only: kernel code"],
    "const": ["Page fault", ", which is read-only: kernel constants"],
    "nx": ["Page fault", "cause: running code at ", ", which is not code: kernel data"],
    "stack": ["Double fault", "cause: a fault the CPU could not deliver",
              "the guard page below CPU 0's kernel stack (a stack overflow)"],
    "guard": ["Page fault", "where nothing is mapped: just past the end of a vm mapping"],
    "twice": ["kfree: freed twice: 0x"],
    "after": ["kmalloc: written to after it was freed: 0x"],
    "page": ["pmm_free: a page that was not in use: 0x"],
    "vm": ["vm_free: not the start of a vm mapping: 0x"],
}


def result(ok, text):
    global FAILS
    FAILS += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + text)
    return ok


def symbol(name):
    for line in (ROOT / "build" / "kernel.map").read_text().splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[2] == name:
            return int(parts[0], 16)
    sys.exit(f"{name} is not in build/kernel.map")


def check_mem_test(log, cpus, label):
    m = re.search(r"mem test: 40000 operations on one CPU, (\d+) failed", log)
    result(m and m.group(1) == "0", f"{label}: one CPU, no failures")
    m = re.search(r"mem test: 4000 operations on each of (\d+) CPUs, (\d+) failed; "
                  r"(\d+) TLB shootdowns", log)
    result(m and m.group(1) == str(cpus) and m.group(2) == "0",
           f"{label}: {cpus} CPU(s) at once, no failures" +
           (f", {m.group(3)} shootdowns" if m else ""))
    if m and cpus > 1:
        result(int(m.group(3)) > 0, f"{label}: shootdowns were sent")
    m = re.search(r"mem test: (\d+) page table entries, (\d+) both writable and executable; "
                  r"the direct map's view of kernel code is (\S+)", log)
    result(m and int(m.group(1)) > 1000 and m.group(2) == "0" and m.group(3) == "read-only",
           f"{label}: W^X audit: " + (f"{m.group(1)} entries, {m.group(2)} writable and "
                                      f"executable, kernel code {m.group(3)} in the direct map"
                                      if m else "missing"))
    result("not all of it came back" not in log, f"{label}: everything given back")
    result("mem test: passed" in log, f"{label}: mem test passed")
    m = re.search(r"mem test: kmalloc\(64\) \+ kfree (\S+) ns; vm_alloc\(16 KiB\) \+ vm_free "
                  r"(\S+) us", log)
    if m:
        print(f"      kmalloc + kfree {m.group(1)} ns, vm_alloc + vm_free {m.group(2)} us")


def jobs(opts):
    """Every boot, side by side."""
    OUT.mkdir(parents=True, exist_ok=True)
    subprocess.run([sys.executable, str(ROOT / "tools" / "mkstick.py"), str(OUT / "stick.img")],
                   cwd=ROOT, check=True, capture_output=True)
    subprocess.run([sys.executable, str(ROOT / "tools" / "mkdisk.py"), str(OUT / "disk.img")],
                   cwd=ROOT, check=True, capture_output=True)
    rodata, data = symbol("kernel_rodata"), symbol("kernel_data")
    script = [
        "press mem\\n", "until heap:",                 # on the keyboard, the rest serial
        "type mem ffffffff80000000\\n", "until physical",
        f"type mem {rodata + 64:x}\\n", "until physical",
        f"type mem {data + 64:x}\\n", "until physical",
        "type mem ffff800000100000\\n", "until physical",
        "type mem 10\\n", "until nothing",
        "type mem test\\n", "until mem test: kmalloc", "wait 0.5",
        "type disks\\n", "until vol2",
        "type dhcp\\n", "until lease", "wait 1",
        "type log save\\n", "until saved to",
        "type poweroff\\n", "ended",
    ]
    mem_test = ["type mem test\\n", "until mem test: kmalloc", "wait 0.5",
                "type poweroff\\n", "ended"]
    jobs = {
        "full": (script, ["--smp", "8", "--nic", "rtl8139",
                          "--stick", (OUT / "stick.img").relative_to(ROOT).as_posix(), "--extra",
                          f"-drive file={(OUT / 'disk.img').relative_to(ROOT).as_posix()},"
                          "if=none,id=nvm,format=raw "
                          "-device nvme,serial=axiom0,drive=nvm"], 90),
        "one": (mem_test, ["--smp", "1"], 60),
    }
    if not opts.quick:
        jobs["tcg"] = (mem_test, ["--smp", "4", "--accel", "tcg"], 300)
    for name in FAULTS:
        jobs[f"panic_{name}"] = ([f"type panic {name}\\n", "until AXIOM PANIC", "wait 0.5"],
                                 ["--smp", "1"], 30)
    return jobs


def full(logs):
    rodata, data = symbol("kernel_rodata"), symbol("kernel_data")
    log, err = logs["full"]
    print("-- a full machine, 8 CPUs")
    result("memory: our own page tables; code" in log and "no identity map" in log,
           "booted on its own page tables")
    result("smp: 8 of 8 threads online" in log, "8 CPUs came up through the firmware tables")
    result("the only ones with an identity map" in log, "'mem' names both sets of tables")
    for addr, what, how in [
            ("0xffffffff80000000", "kernel code", "read-only, executable"),
            (f"0x{rodata + 64:016x}", "kernel constants", "read-only, not executable"),
            (f"0x{data + 64:016x}", "kernel data", "writable, not executable"),
            ("0xffff800000100000", "the direct map of physical memory",
             "writable, not executable, write-back, in a 2.0 MiB page")]:
        m = re.search(re.escape(addr) + r": (.*)\n    physical \S+, (.*)", log)
        result(m and m.group(1) == what and m.group(2).startswith(how),
               f"mem {addr}: {m.group(1) + '; ' + m.group(2) if m else 'no answer'}")
    result("0x0000000000000010: a null pointer; nothing is mapped there" in log,
           "mem 10: a null pointer, nothing mapped")
    check_mem_test(log, 8, "8 CPUs")
    result("disk1: NVMe" in log and "vol2" in log, "the NVMe disk and its volumes")
    result("usb: QEMU USB HARDDRIVE" in log, "the USB stick")
    result("dhcp: address 10.0.2.15" in log, "DHCP over the network card")
    result(re.search(r"log: .* saved to vol0:/AXIOM.LOG", log) is not None,
           "the log saved to the stick")
    result("powering off" in log and "QEMU ended by itself" in err,
           "poweroff through UEFI on the firmware tables: QEMU ended by itself")
    result("AXIOM PANIC" not in log, "no panic")


def small(opts, logs):
    print("-- one CPU")
    log, err = logs["one"]
    check_mem_test(log, 1, "1 CPU")
    result("QEMU ended by itself" in err, "1 CPU: powered off")
    if opts.quick:
        return
    print("-- TCG, 4 CPUs")
    log, err = logs["tcg"]
    result("smp: 4 of 4 threads online" in log, "TCG: 4 CPUs came up")
    check_mem_test(log, 4, "TCG")
    result("QEMU ended by itself" in err, "TCG: powered off")


def faults(logs):
    print("-- faults, one boot each")
    for name, wants in FAULTS.items():
        log, _ = logs[f"panic_{name}"]
        report = log[log.find("*** AXIOM PANIC ***"):] if "AXIOM PANIC" in log else ""
        cause = next((l for l in report.splitlines()
                      if l.startswith("cause:") or ": 0x" in l), "no report")
        result(report and all(w in report for w in wants), f"panic {name}: {cause}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true", help="skip the TCG boot")
    opts = ap.parse_args()
    logs = boot_all(OUT, jobs(opts))
    full(logs)
    small(opts, logs)
    faults(logs)
    print(f"{'all passed' if not FAILS else f'{FAILS} FAILED'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
