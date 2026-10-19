#!/usr/bin/env python3
"""The part of tools/hw/hp1.py that runs on hp-1 itself, as root, under its
other system (Ubuntu), through `fleet run --admin`. Its folder holds what
hp1.py sent: EFI/AXIOM/BOOTX64.EFI and run.txt.

    python3 hp1_node.py status     what is there; changes nothing
    python3 hp1_node.py install    the loader and the programs onto the EFI
                                   system partition (EFI/AXIOM), and a boot
                                   entry for the loader (BootOrder as it was)
    python3 hp1_node.py run        run.txt into AxiomRun, BootNext = Axiom,
                                   and a restart in 5 seconds
    python3 hp1_node.py log        AxiomLog printed, then deleted
    python3 hp1_node.py cancel     AxiomRun and BootNext gone: no test run

Only BootNext is ever set; BootOrder is never written. Nothing here reads
or prints anything but Axiom's own variables, the boot entries, and the
TCO watchdog's registers.
"""
import hashlib
import os
import pathlib
import re
import subprocess
import sys

GUID = "8b367f3b-9403-4cf2-81cd-bda84a771936"         # bootinfo.inc's AXIOM_VENDOR_GUID
EFIVARS = pathlib.Path("/sys/firmware/efi/efivars")
RUN = EFIVARS / f"AxiomRun-{GUID}"
LOG = EFIVARS / f"AxiomLog-{GUID}"
ESP = pathlib.Path("/boot/efi")
LOADER = pathlib.Path("EFI/AXIOM/BOOTX64.EFI")
LABEL = "Axiom"
SMBUS = pathlib.Path("/sys/bus/pci/devices/0000:00:1f.4")
NV_BS_RT = (7).to_bytes(4, "little")


def sh(*args, check=True):
    return subprocess.run(args, capture_output=True, text=True, check=check).stdout


def boot_entries():
    """efibootmgr's view: (BootCurrent, BootNext, BootOrder, Axiom's entry or None)."""
    out = sh("efibootmgr")
    get = lambda key: (re.search(rf"^{key}: (\S+)", out, re.M) or [None, None])[1]
    axiom = re.search(rf"^Boot([0-9A-Fa-f]{{4}})\*? {LABEL}\b", out, re.M)
    return get("BootCurrent"), get("BootNext"), get("BootOrder"), axiom and axiom[1]


def esp_disk():
    """The EFI system partition's disk and partition number, for efibootmgr."""
    dev = sh("findmnt", "-no", "SOURCE", str(ESP)).strip()
    name = pathlib.Path(dev).name
    part = (pathlib.Path("/sys/class/block") / name / "partition").read_text().strip()
    disk = sh("lsblk", "-no", "PKNAME", dev).strip()
    return f"/dev/{disk}", part


def efivar_delete(path):
    if path.exists():
        subprocess.run(["chattr", "-i", str(path)], check=False)
        path.unlink()


def tco():
    """The TCO watchdog's registers (read only): its base from the SMBus
    controller's configuration space, then TCO1_STS, TCO2_STS, TCO1_CNT,
    TCO_TMR from the I/O ports."""
    try:
        ident = (SMBUS / "vendor").read_text().strip() + ":" + (SMBUS / "device").read_text().strip()
        config = (SMBUS / "config").read_bytes()
        base_reg = int.from_bytes(config[0x50:0x54], "little")
        ctl = int.from_bytes(config[0x54:0x58], "little")
        base = base_reg & 0xFFE0
        regs = {}
        with open("/dev/port", "rb", buffering=0) as port:
            for name, off in (("TCO1_STS", 4), ("TCO2_STS", 6), ("TCO1_CNT", 8), ("TCO_TMR", 0x12)):
                port.seek(base + off)
                regs[name] = int.from_bytes(port.read(2), "little")
        return (f"SMBus {ident}, TCOBASE {base_reg:#010x}, TCOCTL {ctl:#010x}; " +
                ", ".join(f"{k} {v:#06x}" for k, v in regs.items()) +
                ("; the watchdog reset the machine (SECOND_TO_STS)" if regs["TCO2_STS"] & 2 else ""))
    except OSError as e:
        return f"unreadable: {e}"


def status():
    print("boot_id", pathlib.Path("/proc/sys/kernel/random/boot_id").read_text().strip())
    cur, nxt, order, axiom = boot_entries()
    print(f"BootCurrent {cur}, BootNext {nxt}, BootOrder {order}, Axiom's entry {axiom}")
    there = ESP / LOADER
    if there.exists():
        print(f"{there}: {there.stat().st_size} bytes, sha256 "
              f"{hashlib.sha256(there.read_bytes()).hexdigest()[:16]}")
    else:
        print(f"{there}: not there")
    print("AxiomRun:", f"{RUN.stat().st_size - 4} bytes" if RUN.exists() else "none")
    print("AxiomLog:", f"{LOG.stat().st_size - 4} bytes" if LOG.exists() else "none")
    print("TCO:", tco())


def install():
    same = True
    for src in sorted(LOADER.parent.iterdir()):
        dst = ESP / LOADER.parent / src.name
        dst.parent.mkdir(parents=True, exist_ok=True)
        data = src.read_bytes()
        if dst.exists() and dst.read_bytes() == data:
            continue
        tmp = dst.with_suffix(".NEW")
        tmp.write_bytes(data)
        os.sync()
        tmp.replace(dst)
        os.sync()
        ok = hashlib.sha256(dst.read_bytes()).digest() == hashlib.sha256(data).digest()
        same = same and ok
        print(f"{dst}: {len(data)} bytes, {'as sent' if ok else 'NOT as sent'}")
    _, _, order, axiom = boot_entries()
    if axiom is None:
        disk, part = esp_disk()
        sh("efibootmgr", "-C", "-d", disk, "-p", part, "-L", LABEL,
           "-l", "\\" + str(LOADER).replace("/", "\\"))
        _, _, after, axiom = boot_entries()
        print(f"made boot entry {axiom} ({disk} partition {part})")
        if after != order:
            print(f"BootOrder changed from {order} to {after}!")
            return 1
    print(f"Axiom's entry {axiom}; BootOrder {order}, as it was")
    return 0 if same else 1


def run():
    script = pathlib.Path("run.txt").read_bytes()
    if len(script) >= 8192:
        print(f"run.txt is {len(script)} bytes; 8191 at most")
        return 1
    _, _, order, axiom = boot_entries()
    if axiom is None:
        print("no boot entry for Axiom: install first")
        return 1
    efivar_delete(RUN)
    efivar_delete(LOG)
    with open(RUN, "wb", buffering=0) as f:          # one write: attributes, then the data
        f.write(NV_BS_RT + script)
    sh("efibootmgr", "-n", axiom)
    _, nxt, after, _ = boot_entries()
    if nxt != axiom or after != order:
        print(f"BootNext {nxt}, BootOrder {after}: not as meant; cancelled")
        cancel()
        return 1
    print("boot_id", pathlib.Path("/proc/sys/kernel/random/boot_id").read_text().strip())
    print(f"AxiomRun: {len(script)} bytes; BootNext {nxt} (Axiom), BootOrder {after}")
    sh("systemd-run", "--on-active=5", "--unit=axiom-test-run", "systemctl", "reboot")
    print("restarting in 5 s")
    return 0


def log():
    print("TCO:", tco())
    if not LOG.exists():
        print("AxiomLog: none")
        return 1
    data = LOG.read_bytes()[4:]
    print(f"AxiomLog: {len(data)} bytes")
    print("----- AxiomLog -----")
    sys.stdout.write(data.decode("utf-8", errors="replace"))
    print("\n----- end -----")
    efivar_delete(LOG)
    return 0


def cancel():
    efivar_delete(RUN)
    _, nxt, _, axiom = boot_entries()
    if nxt is not None and nxt == axiom:
        sh("efibootmgr", "-N")
    print("no test run pending; BootNext", boot_entries()[1])
    return 0


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "status"
    sys.exit({"status": status, "install": install, "run": run, "log": log,
              "cancel": cancel}[what]() or 0)
