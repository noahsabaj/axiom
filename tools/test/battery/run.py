#!/usr/bin/env python3
"""The battery hold (battery.asm, ec.asm) in QEMU, which has no embedded
controller and no battery; and tools/hw/ecmap.py, which finds what the
board table needs in a DSDT.

    python tools/test/battery/run.py [--ecmap]

  - none: a board the table does not have: the battery left alone, no EC;
    'battery test' passes against the simulated EC (batterytest.asm): the
    EC protocol, HP's charge modes, both ways of reading the charge, and
    the hold over 40 simulated minutes; 'battery simulate': a battery read
    at 90% on its charger from then on, and 'battery test' refused.
  - hp1: QEMU's SMBIOS says HP 87FE (hp-1's board): the board found, its
    EC's ports from the table, its EC only read (never written); an EC
    that does not answer (QEMU has none) said so; the hold refused, its
    charge readings still unknown; 'battery mode inhibit' refused, the EC
    not written; 'battery test' passes there too (its simulated EC is
    written) and gives the board back; 'battery simulate' refused.
  - ecmap: on a DSDT made here (no QEMU; --ecmap: only this): the EC's
    ports and fields, what _BST, _BIF and _PSR reach through the methods
    they call, a scope it cannot read passed over and said so; and which
    registers hold Linux's numbers.
Outputs go to build/test/battery/.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "test"))
sys.path.insert(0, str(ROOT / "tools" / "hw"))
from qemu import boot_all  # noqa: E402
import ecmap  # noqa: E402

OUT = ROOT / "build" / "test" / "battery"
FAILS = 0
CHECKS = 14                             # batterytest.asm's


def result(ok, text):
    global FAILS
    FAILS += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + text)
    return ok


def script():
    return ["wait 1",
            "type battery\\n", "wait 0.5",
            "type battery hold\\n", "wait 0.5",
            "type battery mode inhibit\\n", "wait 1",
            "type battery ec\\n", "wait 0.5",
            "type battery test\\n", "until battery test: ",
            "until passed", "wait 0.5",
            "type battery\\n", "wait 1",
            "type battery simulate\\n", "wait 1",
            "type battery\\n", "wait 0.5",
            "type battery test\\n", "wait 1"]


def after(log, text):
    """The log from the line that says text on."""
    at = log.find(text)
    return log[at:] if at >= 0 else ""


# AML, made by hand: enough of it for a laptop's EC, battery and charger
def pkg(body):
    """A PkgLength (counting itself), then the body."""
    for k in range(4):
        total = len(body) + 1 + k
        if k == 0 and total < 0x40:
            return bytes([total]) + body
        if k and total < 1 << (4 + 8 * k):
            return bytes([(k << 6) | (total & 15)] +
                         [(total >> (4 + 8 * j)) & 0xFF for j in range(k)]) + body
    raise ValueError("too long")


def bits(n):
    """A field's width, as a field list says it."""
    return bytes([n]) if n < 0x40 else bytes([0x40 | (n & 15), n >> 4])


def ns(path):
    """A name: "EC0", or "\\_SB.PCI0.LPCB.EC0"."""
    root = path.startswith("\\")
    segs = [s.ljust(4, "_").encode() for s in path.strip("\\").split(".")]
    if len(segs) == 1:
        body = segs[0]
    elif len(segs) == 2:
        body = bytes([0x2E]) + b"".join(segs)
    else:
        body = bytes([0x2F, len(segs)]) + b"".join(segs)
    return (bytes([0x5C]) if root else b"") + body


def num(v):
    if v in (0, 1):
        return bytes([v])
    return bytes([0x0A, v]) if v < 256 else bytes([0x0C]) + v.to_bytes(4, "little")


def scope(path, *body):
    return bytes([0x10]) + pkg(ns(path) + b"".join(body))


def device(name, *body):
    return bytes([0x5B, 0x82]) + pkg(ns(name) + b"".join(body))


def method(name, *body):
    return bytes([0x14]) + pkg(ns(name) + bytes([0]) + b"".join(body))


def name(n, value):
    return bytes([0x08]) + ns(n) + value


def dsdt():
    STORE, INDEX, IF, RETURN, LEQUAL, LOCAL0 = 0x70, 0x88, 0xA0, 0xA4, 0x93, 0x60
    crs = bytes([0x47, 1, 0x62, 0, 0x62, 0, 0, 1, 0x47, 1, 0x66, 0, 0x66, 0, 0, 1, 0x79, 0])
    fields = (bytes([0]) + bits(0x76 * 8) + b"BDVO" + bits(8) +
              bytes([0]) + bits((0xA0 - 0x77) * 8) + b"B0RC" + bits(16) + b"B0FC" + bits(16) +
              b"ADPT" + bits(1) + bytes([0]) + bits(7))
    ec = device("EC0",
                name("_HID", num(ecmap.eisa("PNP0C09"))),
                name("_CRS", bytes([0x11]) + pkg(num(len(crs)) + crs)),
                name("_GLK", num(0)),
                bytes([0x5B, 0x01]) + ns("ECMX") + bytes([0]),
                bytes([0x5B, 0x80]) + ns("ERAM") + bytes([3]) + num(0) + num(0xFF),
                bytes([0x5B, 0x81]) + pkg(ns("ERAM") + bytes([1]) + fields),
                method("UPBS", bytes([STORE]) + ns("B0RC") +
                       bytes([INDEX]) + ns("\\_SB.BAT0.PBST") + num(2) + bytes([0])))
    body = scope("\\_SB",
                 device("PCI0", device("LPCB", ec)),
                 device("ODD", bytes([0x5B, 0x99]), name("XXXX", num(1))),
                 device("BAT0",
                        name("_HID", num(ecmap.eisa("PNP0C0A"))),
                        name("PBST", bytes([0x12]) + pkg(bytes([4]) + num(0) * 4)),
                        method("_BST",
                               bytes([IF]) + pkg(bytes([LEQUAL]) + num(1) + num(1) +
                                                 ns("\\_SB.PCI0.LPCB.EC0.UPBS")),
                               bytes([RETURN]) + ns("PBST")),
                        method("_BIF", bytes([STORE]) + ns("\\_SB.PCI0.LPCB.EC0.B0FC") +
                               bytes([LOCAL0, RETURN, LOCAL0]))),
                 device("ADP1",
                        name("_HID", bytes([0x0D]) + b"ACPI0003" + bytes([0])),
                        method("_PSR", bytes([RETURN]) + ns("\\_SB.PCI0.LPCB.EC0.ADPT"))))
    return b"DSDT" + (36 + len(body)).to_bytes(4, "little") + bytes(28) + body


def ecmap_checks():
    print("ecmap:")
    ec = bytearray(256)
    ec[0x76] = 0x80
    ec[0xA0:0xA2] = (3000).to_bytes(2, "little")
    ec[0xA2:0xA4] = (4000).to_bytes(2, "little")
    ec[0xA4] = 1
    live = {"ec": ec.hex(), "supplies": {
        "BAT0": {"CHARGE_NOW": "3000000", "CHARGE_FULL": "4000000", "CAPACITY": "75"},
        "ADP1": {"ONLINE": "1"}}}
    text = "\n".join(ecmap.report([("DSDT", dsdt())], live))
    (OUT / "ecmap.txt").write_text(text, encoding="utf-8")
    result("EC: \\_SB.PCI0.LPCB.EC0: data 0x62, command 0x66; _GLK: 0" in text,
           "the EC's device, its ports from _CRS, its _GLK")
    result(all(f in text for f in ("0x76.0    8  BDVO", "0xa0.0   16  B0RC",
                                   "0xa2.0   16  B0FC", "0xa4.0    1  ADPT")),
           "its fields, at their offsets")
    result("_BST reaches: B0RC" in text and "_BIF reaches: B0FC" in text
           and "_PSR reaches: ADPT" in text, "what _BST, _BIF and _PSR reach, through UPBS")
    result("Store(B0RC, Index(\\_SB.BAT0.PBST, 0x2))" in text, "UPBS's code read")
    result("\\_SB.ODD from" in text and "passed over (1)" in text,
           "a device it cannot read: passed over, said so, the rest read")
    result("CHARGE_NOW 3000000 (3000): word at 0xa0 [B0RC/16]" in text
           and "CHARGE_FULL 4000000 (4000): word at 0xa2 [B0FC/16]" in text,
           "Linux's charge, now and when full: in B0RC and B0FC")
    result("ADP1 ONLINE 1: one-bit fields reached that agree: ADPT" in text,
           "Linux's charger: ADPT")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    ecmap_checks()
    if "--ecmap" in sys.argv:
        print(f"{'ALL PASSED' if FAILS == 0 else f'{FAILS} FAILED'}")
        return 1 if FAILS else 0
    logs = boot_all(OUT, {
        "none": (script(), ["--smp", "2"], 90),
        "hp1": (script(), ["--smp", "2", "--extra",
                           "-smbios type=2,manufacturer=HP,product=87FE"], 90),
    })

    log = logs["none"][0]
    print("none:")
    result("battery: not a board Axiom holds the battery of (SMBIOS names none)" in log,
           "not a board in the table: left alone")
    result("battery: not held: not a board Axiom holds the battery of" in log,
           "'battery hold' refused")
    result("battery: not a board Axiom holds the battery of\n" in log,
           "'battery mode' refused")
    result("battery: no embedded controller known here" in log, "'battery ec': no EC")
    for f in re.findall(r"battery test: FAILED: (.*)", log):
        print(f"      failed: {f}")
    m = re.search(r"battery test: (\d+) of (\d+) passed", log)
    result(bool(m) and m.group(1) == m.group(2) == str(CHECKS),
           f"'battery test': {m.group(1) + ' of ' + m.group(2) if m else 'no result'} passed"
           f" (of {CHECKS})")
    result("battery: 90%: discharge" in log and "battery: 80%: inhibit" in log
           and "battery: 75%: normal" in log, "the hold's changes said, as they happen")
    result("no lower: held where it is instead" in log,
           "a run-down that lowers nothing: said so")
    tail = after(log, "battery: simulated from now on: a simulated EC (registers)")
    result("battery: 90% (3600 of 4000), on its charger; charging: normal" in tail,
           "'battery simulate': a battery at 90%, on its charger, read")
    result("battery test: not while simulated" in tail, "'battery test' refused while simulated")

    log = logs["hp1"][0]
    print("hp1:")
    result("battery: HP Laptop 15-dy2xxx (HP 87FE), its EC at 66/62 (the board table)" in log,
           "hp-1's board found at boot, its EC's ports from the table")
    result("battery: no reading: the EC does not answer" in log,
           "QEMU has no EC: said so")
    result("battery: not held: how to read this board's charge is not known yet" in log,
           "the hold refused: its charge readings not known yet")
    result("battery: this board's EC is only read, never written (no hold, no charging mode)"
           in log, "hp-1's EC: only read, never written")
    result("battery: inhibit asked for, but this board's EC is never written" in log,
           "'battery mode inhibit': refused, the EC not written")
    result("battery: the EC did not answer, at register 0" in log,
           "'battery ec': the EC does not answer")
    m = re.search(r"battery test: (\d+) of (\d+) passed", log)
    result(bool(m) and m.group(1) == m.group(2) == str(CHECKS), "'battery test' passes here too")
    tail = after(log, "battery test: " + (m.group(0)[14:] if m else "?"))
    result("battery: HP Laptop 15-dy2xxx (HP 87FE), its EC at 66/62" in tail,
           "after the test, the board and its EC given back")
    result("battery: not simulated: an embedded controller is known here" in log,
           "'battery simulate' refused where an EC is known")

    print(f"{'ALL PASSED' if FAILS == 0 else f'{FAILS} FAILED'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
