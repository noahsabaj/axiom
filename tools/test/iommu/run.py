#!/usr/bin/env python3
"""Axiom's VT-d DMA remapping in QEMU (intel-iommu).

    python tools/test/iommu/run.py [--quick]

Boots:
  - nvme: 4 CPUs and QEMU's NVMe drive: 'iommu' (one unit translating, the
    NVMe domain holding the controller), 'nvme test' with every buffer
    mapped for its command and unmapped after, 'iommu test' (a read into a
    page outside the domain stopped with a fault naming the controller and
    that page, the page untouched; mapped, read into; unmapped, stopped
    again), and 'iommu' after: the domain holds as many pages as before,
    and no fault but the test's own;
  - stick: booted from a USB stick, its log written there and a program
    loaded from it, all through the USB domain, with no fault;
  - net: an RTL8139C+ on QEMU's user network, an address from DHCP through
    the network's domain, with no fault;
  - off: no VT-d unit (--no-iommu): said so, and 'nvme test' passes the same;
  - (unless --quick) nvme under TCG, QEMU's own CPU emulation.
Outputs go to build/test/iommu/.
"""
import argparse
import pathlib
import re
import struct
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "test"))
from qemu import boot_all  # noqa: E402

OUT = ROOT / "build" / "test" / "iommu"
FAILS = 0
SIZE = 64 << 20
MAGIC = 0x5354414D50000000          # nvmetest.asm NT_MAGIC: block b starts with MAGIC | b
ON = r"iommu: 1 VT-d unit\(s\), (\d)-level tables, 0 reserved region\(s\); a device reaches only"


def result(ok, text):
    global FAILS
    FAILS += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + text)
    return ok


def drive(name):
    data = bytearray(SIZE)
    for b in range(SIZE // 512):
        struct.pack_into("<Q", data, b * 512, MAGIC | b)
    img = OUT / f"{name}.img"
    img.write_bytes(data)
    return (f"-drive file={img.as_posix()},if=none,id=nvm,format=raw "
            f"-device nvme,serial=AXIOMTEST,drive=nvm")


NVME = ["type iommu\\n", "until unmaps", "wait 0.3",
        "type nvme test\\n", "until nvme test: p", "wait 0.3",
        "type iommu test\\n", "until iommu test: p", "wait 0.3",
        "type iommu\\n", "until unmaps", "wait 0.5",
        "type iommu nonsense\\n", "until usage", "wait 0.2",
        "type poweroff\\n", "ended"]


def jobs(opts):
    OUT.mkdir(parents=True, exist_ok=True)
    stick = OUT / "stick.img"
    subprocess.run([sys.executable, str(ROOT / "tools" / "mkstick.py"), str(stick)], cwd=ROOT,
                   check=True, capture_output=True)
    out = {
        "nvme": (NVME, ["--smp", "4", "--extra", drive("nvme")], 90),
        "stick": (["until log: kept in", "type run hello one two\\n", "until run: HELLO exited",
                   "type ls /EFI/AXIOM\\n", "wait 0.5",
                   "type iommu\\n", "until unmaps", "wait 0.5",
                   "type poweroff\\n", "ended"],
                  ["--smp", "2", "--stick", stick.relative_to(ROOT).as_posix()], 90),
        "net": (["until dhcp: address", "wait 0.5",
                 "type iommu\\n", "until unmaps", "wait 0.5",
                 "type poweroff\\n", "ended"], ["--smp", "2", "--nic", "rtl8139"], 90),
        "off": (["type iommu\\n", "wait 0.3",
                 "type nvme test\\n", "until nvme test: p", "wait 0.3",
                 "type iommu test\\n", "until iommu test: ", "wait 0.3",
                 "type poweroff\\n", "ended"],
                ["--smp", "4", "--no-iommu", "--extra", drive("off")], 90),
    }
    if not opts.quick:
        out["tcg"] = (NVME, ["--smp", "4", "--accel", "tcg", "--extra", drive("tcg")], 400)
    return out


def domains(text):
    """{name: (devices, pages, tables, maps, unmaps)} from one 'iommu'."""
    return {m.group(1): tuple(int(g) for g in m.groups()[1:])
            for m in re.finditer(r"^  (\w+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)$", text, re.M)}


def common(name, log, err):
    m = re.search(ON, log)
    result(m is not None, f"{name}: at boot, one VT-d unit translating, {m.group(1)}-level tables"
           if m else f"{name}: at boot, one VT-d unit translating")
    result(re.search(r"^  unit 0 at 0x0*fed90000: VT-d \d\.\d, translating", log, re.M),
           f"{name}: 'iommu' lists the unit, translating")
    result("AXIOM PANIC" not in log, f"{name}: no panic")
    result("QEMU ended by itself" in err, f"{name}: powered off")


def nvme(name, log, err):
    print(f"-- {name}: NVMe")
    common(name, log, err)
    lists = [log[m.start():] for m in re.finditer(r"^iommu: 1 unit\(s\)", log, re.M)]
    before = domains(lists[0][:lists[0].find("nvme test:")]) if lists else {}
    after = domains(lists[-1]) if len(lists) > 1 else {}
    result(before.get("nvme", (0,))[0] == 1, f"{name}: the NVMe domain holds the controller")
    result("nvme test: passed" in log, f"{name}: nvme test passed, its buffers in the domain")
    for step in ("a read into a page outside the NVMe domain", "the page unmapped again"):
        result(re.search(rf"iommu test: {step}: stopped, a fault from the controller writing "
                         r"0x[0-9a-f]+, the page untouched", log),
               f"{name}: {step}: stopped, the page untouched")
    result("iommu test: the page mapped into the NVMe domain: read into, as the drive says" in log,
           f"{name}: the page mapped: read into")
    result("iommu test: passed" in log, f"{name}: iommu test passed")
    b, a = before.get("nvme"), after.get("nvme")
    result(b and a and a[1] == b[1] and a[3] > b[3] + 800 and a[4] > b[4] + 800,
           f"{name}: after, {a[1]} pages in the NVMe domain as before ({b[1]}); {a[3] - b[3]} "
           f"maps and {a[4] - b[4]} unmaps meanwhile" if a and b else f"{name}: pages after")
    result(not re.search(r"^iommu: fault:", log, re.M), f"{name}: no fault but the test's own")
    result("usage: iommu [test]" in log, f"{name}: 'iommu nonsense': the usage")


def stick(log, err):
    print("-- stick: booted from USB")
    common("stick", log, err)
    result("Hello from ring 3!" in log, "stick: a program loaded from the stick ran")
    d = domains(log[log.rfind("iommu: 1 unit(s)"):])
    u = d.get("usb")
    result(u and u[0] == 1 and u[1] > 0, f"stick: the USB domain holds the controller and {u[1]} "
           f"pages" if u else "stick: the USB domain")
    result(not re.search(r"^iommu: fault:", log, re.M), "stick: no fault")


def net(log, err):
    print("-- net: RTL8139C+")
    common("net", log, err)
    result(re.search(r"^dhcp: address 10\.0\.2\.15/24", log, re.M), "net: an address from DHCP")
    d = domains(log[log.rfind("iommu: 1 unit(s)"):])
    n = d.get("network")
    result(n and n[0] == 1 and n[1] > 0, f"net: the network's domain holds the card and {n[1]} "
           f"pages" if n else "net: the network's domain")
    result(not re.search(r"^iommu: fault:", log, re.M), "net: no fault")


def off(log, err):
    print("-- off: no VT-d")
    result("iommu: no VT-d (no DMAR table): DMA is not confined" in log, "off: said so at boot")
    result("iommu: off: no VT-d unit found" in log, "off: 'iommu' says so")
    result("nvme test: passed" in log, "off: nvme test passed")
    result("iommu test: no VT-d unit is translating" in log, "off: 'iommu test' says why not")
    result("AXIOM PANIC" not in log, "off: no panic")
    result("QEMU ended by itself" in err, "off: powered off")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true", help="skip the TCG boot")
    opts = ap.parse_args()
    logs = boot_all(OUT, jobs(opts))
    nvme("nvme", *logs["nvme"])
    stick(*logs["stick"])
    net(*logs["net"])
    off(*logs["off"])
    if "tcg" in logs:
        nvme("tcg", *logs["tcg"])
    print(f"{'all passed' if not FAILS else f'{FAILS} FAILED'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
