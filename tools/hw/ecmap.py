#!/usr/bin/env python3
"""What a laptop's ACPI tables say about its embedded controller and its
battery, for the board table in src/kernel/battery.asm: Axiom runs no AML,
so it reads the EC registers the firmware's _BST and _PSR read, at the
offsets found here.

    python tools/hw/ecmap.py DSDT.aml [SSDT.aml...] [--live FILE] [--show NAME...]

Prints the EC's device (its ports from _CRS, whether it asks for the global
lock), every field of its EmbeddedControl regions, and the code of the
battery's _BST, _BIF, _BIX and _STA and the charger's _PSR, with the methods
they call, and the EC fields they reach. --live: what tools/hw/hp1.py
battery saved (the EC's 256 registers read under Linux, and what Linux says
of the battery and the charger): which registers hold Linux's numbers now.
--show: more methods' code, by name (EC0._Q12, SBCO...).

Standard library only. Not a whole AML disassembler: what it does not know
in a scope it passes over, and says so. Names are found as ACPI finds
them: a single name in the scope it is used in, then each scope above.
"""
import argparse
import json
import pathlib
import sys

EC_SPACE = 3                            # OperationRegion space: EmbeddedControl
LEAD = set(b"ABCDEFGHIJKLMNOPQRSTUVWXYZ_")
CHARS = LEAD | set(b"0123456789")
ONES = 0xFFFFFFFFFFFFFFFF


def eisa(text):
    """EisaId("PNP0C09") as AML stores it: 0x090CD041."""
    v = ((ord(text[0]) - 0x40) << 26) | ((ord(text[1]) - 0x40) << 21) | \
        ((ord(text[2]) - 0x40) << 16) | int(text[3:], 16)
    return int.from_bytes(v.to_bytes(4, "big"), "little")


EC_HID = {eisa("PNP0C09"), "PNP0C09"}
BATTERY_HID = {eisa("PNP0C0A"), "PNP0C0A"}
AC_HID = {"ACPI0003"}
SMBUS_HID = {"ACPI0001", "ACPI0005"}

# opcode: (name, arguments: e an operand, t a target (0x00: none), n a name,
# b a byte, w a word, d a dword)
OPS = {
    0x70: ("Store", "et"), 0x71: ("RefOf", "e"), 0x72: ("Add", "eet"),
    0x73: ("Concatenate", "eet"), 0x74: ("Subtract", "eet"), 0x75: ("Increment", "e"),
    0x76: ("Decrement", "e"), 0x77: ("Multiply", "eet"), 0x78: ("Divide", "eett"),
    0x79: ("ShiftLeft", "eet"), 0x7A: ("ShiftRight", "eet"), 0x7B: ("And", "eet"),
    0x7C: ("NAnd", "eet"), 0x7D: ("Or", "eet"), 0x7E: ("NOr", "eet"), 0x7F: ("XOr", "eet"),
    0x80: ("Not", "et"), 0x81: ("FindSetLeftBit", "et"), 0x82: ("FindSetRightBit", "et"),
    0x83: ("DerefOf", "e"), 0x84: ("ConcatenateResTemplate", "eet"), 0x85: ("Mod", "eet"),
    0x86: ("Notify", "ee"), 0x87: ("SizeOf", "e"), 0x88: ("Index", "eet"),
    0x89: ("Match", "ebebee"), 0x8A: ("CreateDWordField", "een"),
    0x8B: ("CreateWordField", "een"), 0x8C: ("CreateByteField", "een"),
    0x8D: ("CreateBitField", "een"), 0x8E: ("ObjectType", "e"),
    0x8F: ("CreateQWordField", "een"), 0x90: ("LAnd", "ee"), 0x91: ("LOr", "ee"),
    0x92: ("LNot", "e"), 0x93: ("LEqual", "ee"), 0x94: ("LGreater", "ee"),
    0x95: ("LLess", "ee"), 0x96: ("ToBuffer", "et"), 0x97: ("ToDecimalString", "et"),
    0x98: ("ToHexString", "et"), 0x99: ("ToInteger", "et"), 0x9C: ("ToString", "eet"),
    0x9D: ("CopyObject", "et"), 0x9E: ("Mid", "eeet"), 0x9F: ("Continue", ""),
    0xA3: ("Noop", ""), 0xA4: ("Return", "e"), 0xA5: ("Break", ""), 0xCC: ("BreakPoint", ""),
}
EXT = {
    0x12: ("CondRefOf", "et"), 0x13: ("CreateField", "eeen"), 0x21: ("Stall", "e"),
    0x22: ("Sleep", "e"), 0x23: ("Acquire", "nw"), 0x24: ("Signal", "n"), 0x25: ("Wait", "ne"),
    0x26: ("Reset", "n"), 0x27: ("Release", "n"), 0x28: ("FromBCD", "et"),
    0x29: ("ToBCD", "et"), 0x30: ("Revision", ""), 0x31: ("Debug", ""), 0x32: ("Fatal", "bde"),
    0x33: ("Timer", ""),
}
DECLARE = {0x10: "Scope", 0x14: "Method", 0x06: "Alias", 0x15: "External"}
DECLARE_EXT = {0x80: "OperationRegion", 0x81: "Field", 0x82: "Device", 0x83: "Processor",
               0x84: "PowerResource", 0x85: "ThermalZone", 0x86: "IndexField",
               0x87: "BankField", 0x01: "Mutex", 0x02: "Event"}


class Unknown(Exception):
    """AML this does not read: the rest of the scope is passed over."""


def pkglen(d, i):
    """-> (the length, how many bytes it took)."""
    n = d[i] >> 6
    if n == 0:
        return d[i] & 0x3F, 1
    v = d[i] & 0x0F
    for k in range(n):
        v |= d[i + 1 + k] << (4 + 8 * k)
    return v, n + 1


def seg_ok(s):
    return len(s) == 4 and s[0] in LEAD and all(c in CHARS for c in s)


def namestring(d, i):
    """-> ((root, parents up, (segments)), the next offset)."""
    root, up = False, 0
    if d[i] == 0x5C:
        root, i = True, i + 1
    else:
        while d[i] == 0x5E:
            up, i = up + 1, i + 1
    if d[i] == 0x00:
        return (root, up, ()), i + 1
    if d[i] == 0x2E:
        count, i = 2, i + 1
    elif d[i] == 0x2F:
        count, i = d[i + 1], i + 2
    else:
        count = 1
    segs = []
    for _ in range(count):
        s = d[i:i + 4]
        if not seg_ok(s):
            raise Unknown(f"a name at {i:#x}")
        segs.append(s.decode())
        i += 4
    return (root, up, tuple(segs)), i


def resolve(scope, name):
    root, up, segs = name
    return tuple(segs) if root else tuple(scope[:len(scope) - up]) + tuple(segs)


def show(path):
    return "\\" + ".".join(short(s) for s in path)


def short(seg):
    return seg.rstrip("_") or seg


def text_of(name):
    root, up, segs = name
    return ("\\" if root else "^" * up) + ".".join(short(s) for s in segs)


class Tables:
    def __init__(self, blobs):
        self.devices = {}               # path -> {"hid": .., "crs": bytes, "glk": ..}
        self.methods = {}               # path -> (data, start, end, argc)
        self.regions = {}               # path -> (space, offset, length)
        self.declared = []              # (scope, region name, field name, bit, bits)
        self.skipped = []               # where a scope was passed over
        for _, d in blobs:
            self.walk(d, 36, len(d), ())        # past the table's header
        self.fields = {}                # path -> (bit, bits, region path)
        for scope, region, seg, bit, bits in self.declared:
            where = self.lookup(scope, region, self.regions)
            self.fields.setdefault(tuple(scope) + (seg,), (bit, bits, where))
        self.ec_fields = {p: f for p, f in self.fields.items()
                          if f[2] is not None and self.regions[f[2]][0] == EC_SPACE}

    def lookup(self, scope, name, table):
        """Where a name used in scope is, among table's paths: a single name
        in scope, then each scope above it; any other as it says."""
        root, up, segs = name
        if not segs:
            return None
        if root or up or len(segs) > 1:
            p = resolve(scope, name)
            return p if p in table else None
        s = tuple(scope)
        while True:
            if s + segs in table:
                return s + segs
            if not s:
                return None
            s = s[:-1]

    # the namespace: scopes, devices, methods, names, regions, fields

    def walk(self, d, i, end, scope):
        while i < end:
            try:
                i = self.term(d, i, end, scope)
            except (Unknown, IndexError) as e:
                self.skipped.append(f"{show(scope)} from {i:#x}: {e}")
                return

    def body(self, d, i):
        """-> (where a PkgLength's object ends, where its contents start)."""
        n, k = pkglen(d, i)
        return i + n, i + k

    def term(self, d, i, end, scope):
        op = d[i]
        if op == 0x10:                                  # Scope
            stop, j = self.body(d, i + 1)
            name, j = namestring(d, j)
            self.walk(d, j, stop, resolve(scope, name))
            return stop
        if op == 0x14:                                  # Method
            stop, j = self.body(d, i + 1)
            name, j = namestring(d, j)
            self.methods[resolve(scope, name)] = (d, j + 1, stop, d[j] & 7)
            return stop
        if op == 0x08:                                  # Name
            name, j = namestring(d, i + 1)
            path = resolve(scope, name)
            value, j = self.data(d, j)
            dev = self.devices.get(path[:-1])
            if dev is not None and path[-1] in ("_HID", "_CRS", "_GLK", "_UID"):
                dev[path[-1].lower().strip("_")] = value
            return j
        if op == 0x06:                                  # Alias
            _, j = namestring(d, i + 1)
            return namestring(d, j)[1]
        if op == 0x15:                                  # External
            return namestring(d, i + 1)[1] + 2
        if op in (0xA0, 0xA2):                          # If, While: their bodies walked
            stop, j = self.body(d, i + 1)
            _, j = self.expr(d, j)
            self.walk(d, j, stop, scope)
            return stop
        if op == 0xA1:                                  # Else
            stop, j = self.body(d, i + 1)
            self.walk(d, j, stop, scope)
            return stop
        if op == 0x5B:
            ext = d[i + 1]
            if ext in (0x82, 0x85):                     # Device, ThermalZone
                stop, j = self.body(d, i + 2)
                name, j = namestring(d, j)
                path = resolve(scope, name)
                if ext == 0x82:
                    self.devices.setdefault(path, {})
                self.walk(d, j, stop, path)
                return stop
            if ext in (0x83, 0x84):                     # Processor, PowerResource
                stop, j = self.body(d, i + 2)
                name, j = namestring(d, j)
                self.walk(d, j + (6 if ext == 0x83 else 3), stop, resolve(scope, name))
                return stop
            if ext == 0x80:                             # OperationRegion
                name, j = namestring(d, i + 2)
                space = d[j]
                offset, j = self.integer(d, j + 1)
                length, j = self.integer(d, j)
                self.regions[resolve(scope, name)] = (space, offset, length)
                return j
            if ext == 0x81:                             # Field
                stop, j = self.body(d, i + 2)
                name, j = namestring(d, j)
                self.field_list(d, j + 1, stop, name, scope)
                return stop
            if ext in (0x86, 0x87):                     # IndexField, BankField
                return self.body(d, i + 2)[0]
            if ext == 0x01:                             # Mutex
                return namestring(d, i + 2)[1] + 1
            if ext == 0x02:                             # Event
                return namestring(d, i + 2)[1]
        _, j = self.expr(d, i)                          # anything else: a statement
        return j

    def integer(self, d, i):
        """A number, or None for an expression (a name, Add(...))."""
        value, j = self.expr(d, i, want_value=True)
        return (value if isinstance(value, int) else None), j

    def data(self, d, i):
        """A Name's value: a number, a string, a buffer's bytes, or a
        package's text."""
        op = d[i]
        if op == 0x11:                                  # Buffer
            stop, j = self.body(d, i + 1)
            _, j = self.expr(d, j)
            return bytes(d[j:stop]), stop
        if op in (0x12, 0x13):                          # Package, VarPackage
            stop, _ = self.body(d, i + 1)
            return "Package", stop
        if op == 0x0D:
            stop = d.index(0, i + 1)
            return d[i + 1:stop].decode("latin-1"), stop + 1
        return self.expr(d, i, want_value=True)

    def field_list(self, d, i, end, region, scope):
        bit = 0
        while i < end:
            b = d[i]
            if b == 0x00:                               # Offset(), or unnamed bits
                n, k = pkglen(d, i + 1)
                bit, i = bit + n, i + 1 + k
            elif b == 0x01:                             # AccessAs
                i += 3
            elif b == 0x03:                             # AccessAs, extended
                i += 4
            elif b == 0x02:                             # Connection
                if d[i + 1] == 0x11:
                    i = self.body(d, i + 2)[0]
                else:
                    i = namestring(d, i + 1)[1]
            else:
                s = d[i:i + 4]
                if not seg_ok(s):
                    raise Unknown(f"a field at {i:#x}")
                n, k = pkglen(d, i + 4)
                self.declared.append((tuple(scope), region, s.decode(), bit, n))
                bit, i = bit + n, i + 4 + k

    # code

    def expr(self, d, i, want_value=False, names=None):
        """-> (its text, or its value if want_value and it is a number; the
        next offset). names: a set the names it uses are added to."""
        op = d[i]
        if 0x60 <= op <= 0x67:
            return f"Local{op - 0x60}", i + 1
        if 0x68 <= op <= 0x6E:
            return f"Arg{op - 0x68}", i + 1
        consts = {0x00: 0, 0x01: 1, 0xFF: ONES}
        if op in consts:
            v = consts[op]
            return (v if want_value else {0: "Zero", 1: "One", ONES: "Ones"}[v]), i + 1
        sizes = {0x0A: 1, 0x0B: 2, 0x0C: 4, 0x0E: 8}
        if op in sizes:
            v = int.from_bytes(d[i + 1:i + 1 + sizes[op]], "little")
            return (v if want_value else hex(v)), i + 1 + sizes[op]
        if op == 0x0D:
            stop = d.index(0, i + 1)
            return '"' + d[i + 1:stop].decode("latin-1") + '"', stop + 1
        if op == 0x11:
            stop, _ = self.body(d, i + 1)
            return "Buffer(...)", stop
        if op in (0x12, 0x13):
            stop, _ = self.body(d, i + 1)
            return "Package(...)", stop
        if op == 0x92 and d[i + 1] in (0x93, 0x94, 0x95):
            a, j = self.expr(d, i + 2, names=names)
            b, j = self.expr(d, j, names=names)
            what = {0x93: "LNotEqual", 0x94: "LLessEqual", 0x95: "LGreaterEqual"}[d[i + 1]]
            return f"{what}({a}, {b})", j
        if op == 0x5B:
            if d[i + 1] not in EXT:
                raise Unknown(f"opcode 5B {d[i + 1]:02X} at {i:#x}")
            name, spec = EXT[d[i + 1]]
            return self.call(d, i + 2, name, spec, names)
        if op in OPS:
            name, spec = OPS[op]
            return self.call(d, i + 1, name, spec, names)
        if op in LEAD or op in (0x5C, 0x5E, 0x2E, 0x2F):
            name, j = namestring(d, i)
            if names is not None:
                names.add(name)
            n = self.arguments(name)
            if n:
                args = []
                for _ in range(n):
                    a, j = self.expr(d, j, names=names)
                    args.append(a)
                return f"{text_of(name)}({', '.join(args)})", j
            return text_of(name), j
        raise Unknown(f"opcode {op:02X} at {i:#x}")

    def arguments(self, name):
        """How many arguments a name used as a method call takes: the method
        it finds from the code's scope; none for a name the method declared
        itself, or one not (yet) known."""
        if not name[2] or not hasattr(self, "fields"):
            return 0
        if len(name[2]) == 1 and not name[0] and not name[1] and name[2][0] in self.local:
            return 0
        m = self.lookup(self.scope, name, self.methods)
        return self.methods[m][3] if m else 0

    def call(self, d, j, name, spec, names):
        args = []
        for kind in spec:
            if kind == "e":
                a, j = self.expr(d, j, names=names)
            elif kind == "t":
                if d[j] == 0x00:
                    a, j = None, j + 1
                else:
                    a, j = self.expr(d, j, names=names)
            elif kind == "n":
                n, j = namestring(d, j)
                if names is not None:
                    names.add(n)
                a = text_of(n)
            elif kind == "b":
                a, j = hex(d[j]), j + 1
            elif kind == "w":
                a, j = hex(int.from_bytes(d[j:j + 2], "little")), j + 2
            else:                                       # d: a dword
                a, j = hex(int.from_bytes(d[j:j + 4], "little")), j + 4
            if a is not None:
                args.append(a)
        return f"{name}({', '.join(args)})" if spec else name, j

    def code(self, d, i, end, depth, names, out):
        """A method's statements, as lines, into out."""
        pad = "    " * depth
        while i < end:
            op = d[i]
            if op in (0xA0, 0xA2):
                stop, j = self.body(d, i + 1)
                pred, j = self.expr(d, j, names=names)
                out.append(f"{pad}{'If' if op == 0xA0 else 'While'} ({pred})")
                self.code(d, j, stop, depth + 1, names, out)
                i = stop
            elif op == 0xA1:
                stop, j = self.body(d, i + 1)
                out.append(f"{pad}Else")
                self.code(d, j, stop, depth + 1, names, out)
                i = stop
            elif op == 0x08:
                name, j = namestring(d, i + 1)
                if name[2]:
                    self.local.add(name[2][-1])
                value, i = self.data(d, j)
                if isinstance(value, int):
                    value = hex(value)
                elif isinstance(value, bytes):
                    value = "Buffer(" + value.hex() + ")"
                out.append(f"{pad}Name({text_of(name)}, {value})")
            elif op in DECLARE or (op == 0x5B and d[i + 1] in DECLARE_EXT):
                what = DECLARE.get(op) if op != 0x5B else DECLARE_EXT[d[i + 1]]
                at = i + (1 if op != 0x5B else 2)
                if what in ("Scope", "Method", "Field", "Device", "Processor",
                            "PowerResource", "ThermalZone", "IndexField", "BankField"):
                    stop, j = self.body(d, at)
                    name = namestring(d, j)[0]
                    i = stop
                else:
                    name = namestring(d, at)[0]
                    i = self.term(d, i, end, self.scope)
                if name[2]:
                    self.local.add(name[2][-1])
                label = text_of(name)
                out.append(f"{pad}{what}({label}, ...)")
            else:
                text, i = self.expr(d, i, names=names)
                out.append(pad + text)

    def method_code(self, path):
        d, start, end, argc = self.methods[path]
        names, out = set(), []
        self.scope, self.local = path, set()
        try:
            self.code(d, start, end, 1, names, out)
        except (Unknown, IndexError) as e:
            out.append(f"    ... ({e}: not read further)")
        return out, names

    def find(self, text):
        """Methods named so: a name, or a dotted path's end."""
        parts = tuple(s.ljust(4, "_") for s in text.strip("\\").split("."))
        return [p for p in self.methods if p[-len(parts):] == parts]

    def device_with(self, hids):
        return [p for p, dev in self.devices.items() if dev.get("hid") in hids]


def io_ports(crs):
    """A _CRS buffer's I/O ranges, in order: [(base, length)]."""
    out, i = [], 0
    while isinstance(crs, bytes) and i < len(crs):
        tag = crs[i]
        if tag & 0x80:                                  # a large item
            i += 3 + int.from_bytes(crs[i + 1:i + 3], "little")
            continue
        n = tag & 7
        if tag >> 3 == 0x08:                            # I/O port
            out.append((int.from_bytes(crs[i + 2:i + 4], "little"), crs[i + 7]))
        elif tag >> 3 == 0x09:                          # fixed I/O port
            out.append((int.from_bytes(crs[i + 1:i + 3], "little"), crs[i + 3]))
        elif tag >> 3 == 0x0F:                          # the end
            break
        i += 1 + n
    return out


def field_text(t, path):
    bit, bits, _ = t.ec_fields[path]
    return f"{short(path[-1])} {bit // 8:#04x}.{bit % 8}/{bits}"


def report(blobs, live=None, more=()):
    t = Tables(blobs)
    lines = []
    say = lines.append
    for p in t.device_with(EC_HID):
        dev = t.devices[p]
        ports = io_ports(dev.get("crs"))
        where = (f"data {ports[0][0]:#x}, command {ports[1][0]:#x}" if len(ports) >= 2
                 else "_CRS not a plain buffer here")
        glk = dev.get("glk")
        if glk is None:
            glk = "a method" if p + ("_GLK",) in t.methods else "none"
        say(f"EC: {show(p)}: {where}; _GLK: {glk}")
    if not t.device_with(EC_HID):
        say("EC: no device with _HID PNP0C09")
    for p in t.device_with(SMBUS_HID):
        say(f"SMBus host: {show(p)} ({t.devices[p].get('hid')})")
    for p, (space, off, ln) in t.regions.items():
        if space == EC_SPACE:
            say(f"EmbeddedControl region {show(p)}: "
                + (f"{off:#x}, {ln:#x} bytes" if off is not None and ln is not None
                   else "(not constants)"))
    say("fields (offset.bit, bits, name):")
    for path, (bit, bits, region) in sorted(t.ec_fields.items(), key=lambda f: (f[1][2], f[1][0])):
        say(f"  {bit // 8:#04x}.{bit % 8}  {bits:3}  {short(path[-1]):4}  ({show(region)})")
    roots = []
    for hids, methods in ((BATTERY_HID, ("_BST", "_BIF", "_BIX", "_STA")), (AC_HID, ("_PSR",))):
        for p in t.device_with(hids):
            roots += [p + (m,) for m in methods if p + (m,) in t.methods]
    for m in more:
        roots += t.find(m)
    seen, reached = set(), {}
    todo = [(r, r) for r in roots]
    while todo:
        path, root = todo.pop(0)
        if path in seen:
            continue
        seen.add(path)
        out, names = t.method_code(path)
        say("")
        say(f"{show(path)}:")
        lines.extend(out)
        ec, calls = set(), set()
        for n in names:
            f = t.lookup(path, n, t.ec_fields)
            if f:
                ec.add(f)
            m = t.lookup(path, n, t.methods)
            if m:
                calls.add(m)
        ec = sorted(ec, key=lambda f: t.ec_fields[f][0])
        if ec:
            say("    EC fields: " + ", ".join(field_text(t, f) for f in ec))
        reached.setdefault(root, set()).update(ec)
        for q in sorted(calls):
            if q not in seen and len(seen) < 80:
                todo.append((q, root))
    say("")
    for root, ec in reached.items():
        say(f"{show(root)} reaches: " + (", ".join(field_text(t, f) for f in
                                                   sorted(ec, key=lambda f: t.ec_fields[f][0]))
                                          or "no EC field"))
    if live:
        say("")
        lines.extend(match(t, live, reached))
    if t.skipped:
        say("")
        say(f"passed over ({len(t.skipped)}): " + "; ".join(t.skipped[:8]))
    return lines


def match(t, live, reached):
    """Which EC registers hold, now, the numbers Linux says."""
    out = []
    ec = bytes.fromhex(live.get("ec") or "")
    if len(ec) != 256:
        return ["live: no EC registers (ec_sys not loaded): nothing to match"]
    by_offset = {}
    for path, (bit, bits, _) in t.ec_fields.items():
        by_offset.setdefault(bit // 8, []).append(f"{short(path[-1])}/{bits}")
    for supply, values in live.get("supplies", {}).items():
        for key, value in sorted(values.items()):
            if not key.startswith(("CHARGE_", "ENERGY_", "VOLTAGE_NOW", "CURRENT_NOW",
                                   "POWER_NOW")):
                continue
            try:
                want = int(value) // 1000
            except ValueError:
                continue
            if want <= 0:
                continue
            hits = [o for o in range(255)
                    if abs(int.from_bytes(ec[o:o + 2], "little") - want) <= max(1, want // 100)]
            out.append(f"live: {supply} {key} {value} ({want}): word at " +
                       (", ".join(f"{o:#04x} [{' '.join(by_offset.get(o, ['-']))}]" for o in hits)
                        or "nowhere"))
        if "ONLINE" in values:
            want = values["ONLINE"] == "1"
            ones = sorted({f for fs in reached.values() for f in fs if t.ec_fields[f][1] == 1})
            agree = [f for f in ones
                     if bool(ec[t.ec_fields[f][0] // 8] >> (t.ec_fields[f][0] % 8) & 1) == want]
            out.append(f"live: {supply} ONLINE {values['ONLINE']}: one-bit fields reached that "
                       "agree: " + (", ".join(field_text(t, f) for f in agree) or "none"))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("tables", nargs="+")
    ap.add_argument("--live", help="hp1.py battery's JSON")
    ap.add_argument("--show", nargs="*", default=[])
    opts = ap.parse_args()
    blobs = [(f, pathlib.Path(f).read_bytes()) for f in opts.tables]
    live = json.loads(pathlib.Path(opts.live).read_text(encoding="utf-8")) if opts.live else None
    print("\n".join(report(blobs, live, opts.show)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
