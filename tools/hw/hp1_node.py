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
    python3 hp1_node.py wifi       the Wi-Fi network hp-1 is on, for Axiom:
                                   its SSID and WPA2 key (PMK), made from
                                   netplan's wpa_supplicant configuration,
                                   into EFI/AXIOM/WIFI.KEY

Only BootNext is ever set; BootOrder is never written. Nothing here reads
or prints anything but Axiom's own variables, the boot entries, and the
TCO watchdog's registers, but for `wifi`: it reads the network's saved
passphrase and writes only the key made from it, and prints neither, nor
the network's name.
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
WIFI_KEY = ESP / "EFI" / "AXIOM" / "WIFI.KEY"


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


def wpa_string(value):
    """A wpa_supplicant.conf string as bytes: "quoted", P"printf-escaped"
    or hex (None if none of them)."""
    if len(value) >= 3 and value.startswith('P"') and value.endswith('"'):
        text, out, i = value[2:-1], bytearray(), 0
        while i < len(text):
            if text[i] == "\\" and i + 1 < len(text):
                if text[i + 1] == "x" and i + 4 <= len(text):
                    out.append(int(text[i + 2:i + 4], 16))
                    i += 4
                    continue
                out.append({"n": 10, "r": 13, "t": 9, "e": 27}.get(text[i + 1], ord(text[i + 1])))
                i += 2
            else:
                out += text[i].encode("utf-8")
                i += 1
        return bytes(out)
    if len(value) >= 2 and value[0] == value[-1] == '"':
        return value[1:-1].encode("utf-8")
    try:
        return bytes.fromhex(value)
    except ValueError:
        return None


def wpa_form(value):
    """How a wpa_supplicant.conf string is written, not what it says."""
    return ("P-quoted" if value.startswith('P"') else "quoted" if value.startswith('"')
            else "hex" if value and wpa_string(value) is not None else "missing or unknown")


def ssid_txt(ssid):
    """An SSID as wpa_cli prints it (printf_encode)."""
    return "".join("\\" + chr(c) if c in (0x22, 0x5C) else chr(c) if 0x20 <= c < 0x7F
                   else f"\\x{c:02x}" for c in ssid)


def wifi():
    """WIFI.KEY, for src/kernel/rtwjoin.asm: "AXWIFI01", the SSID's length
    (1 byte), the SSID (32 bytes, zero-padded), and the PMK (32 bytes):
    PBKDF2-HMAC-SHA1 of the passphrase with the SSID, 4096 rounds, as every
    WPA2-Personal station makes it (IEEE 802.11-2020 J.4.1). The network
    is the one wpa_supplicant is on now, from the configuration netplan
    made for it."""
    ifaces = [p.parent.name for p in pathlib.Path("/sys/class/net").glob("*/wireless")]
    if len(ifaces) != 1:
        print(f"{len(ifaces)} Wi-Fi interfaces; 1 wanted")
        return 1
    status = dict(line.split("=", 1) for line in
                  sh("wpa_cli", "-i", ifaces[0], "status").splitlines() if "=" in line)
    print(f"{ifaces[0]}: {status.get('wpa_state')}, {status.get('freq')} MHz, key management "
          f"{status.get('key_mgmt')}, ciphers {status.get('pairwise_cipher')} (pairwise) and "
          f"{status.get('group_cipher')} (group)")
    if status.get("wpa_state") != "COMPLETED" or status.get("key_mgmt") != "WPA2-PSK":
        print("not on a WPA2-Personal network now")
        return 1
    conf = pathlib.Path(f"/run/netplan/wpa-{ifaces[0]}.conf").read_text(encoding="utf-8")
    networks = [dict(line.strip().split("=", 1) for line in block.splitlines()
                     if "=" in line)
                for block in re.findall(r"network=\{(.*?)\n\s*\}", conf, re.S)]
    mine = [n for n in networks if (s := wpa_string(n.get("ssid", ""))) is not None
            and ssid_txt(s) == status.get("ssid")]
    print(f"{len(networks)} networks configured, {len(mine)} of them this one by name; "
          f"SSIDs written {', '.join(wpa_form(n.get('ssid', '')) for n in networks)}")
    if not mine and len(networks) == 1:
        mine = networks                     # the only one wpa_supplicant could be on
        print("the only one configured, then")
    if len(mine) != 1 or "WPA-PSK" not in mine[0].get("key_mgmt", "WPA-PSK").split():
        return 1
    ssid = wpa_string(mine[0].get("ssid", "")) or b""
    psk = mine[0].get("psk", "")
    try:
        if len(psk) == 64 and all(c in "0123456789abcdefABCDEF" for c in psk):
            pmk = bytes.fromhex(psk)                    # saved as the key itself
        elif (phrase := wpa_string(psk)) is not None and psk[:1] in ('"', "P") \
                and 8 <= len(phrase) <= 63 and 1 <= len(ssid) <= 32:
            pmk = hashlib.pbkdf2_hmac("sha1", phrase, ssid, 4096, 32)
        else:
            print(f"no passphrase of 8-63 characters saved ({wpa_form(psk)}), or an SSID "
                  f"of {len(ssid)} bytes")
            return 1
    finally:
        psk = phrase = mine = networks = conf = None
    data = b"AXWIFI01" + bytes([len(ssid)]) + ssid.ljust(32, bytes(1)) + pmk
    tmp = WIFI_KEY.with_suffix(".NEW")
    tmp.write_bytes(data)
    os.sync()
    tmp.replace(WIFI_KEY)
    os.sync()
    ok = WIFI_KEY.read_bytes() == data
    print(f"{WIFI_KEY}: {len(data)} bytes, {'as written' if ok else 'NOT as written'}: "
          f"the active network's key (WPA2-Personal, an SSID of {len(ssid)} bytes)")
    return 0 if ok else 1


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
              "cancel": cancel, "wifi": wifi}[what]() or 0)
