#!/usr/bin/env python3
"""Axiom programs in MASM (sdk/masm/*.asm), as .AXEs: assembled by ml64,
linked by link.exe to run at 0x400000 as they are, made .AXEs by
tools/mkaxe.py, beside the others in build/esp/EFI/AXIOM.

    python tools/masm.py [names]        # mhello ...; all of them by default

sdk/masm/axiom.inc, the kernel's constants as MASM has them, is made first
from src/kernel/defs.inc (and the key codes in kbd.asm), so it says what
this kernel does. A program says what it wants (AW_*) in a line of its
own: "; wants: AW_DESK OR AW_FILES". MSVC is found by vswhere; with none,
this says so and exits 3 (the tests skip). See docs/ABI.md.
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SDK = ROOT / "sdk" / "masm"
OUT = ROOT / "build" / "masm"
AXE = ROOT / "build" / "esp" / "EFI" / "AXIOM"
VSWHERE = pathlib.Path(r"C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe")
K = ROOT / "src" / "kernel"
SOURCES = [K / "defs.inc", K / "kbd.asm", K / "kobj.asm", K / "user.asm", K / "fscap.asm"]
# what a program sees of them: the rest is the kernel's own
PUBLIC = ("OT_", "RT_", "E_", "RA_", "SQ_", "SQF_", "CQ_", "RO_", "FS_PATH", "FV_", "FVF_",
          "FE_", "FEA_", "USER_", "AXE_", "AW_", "SB_", "SYS_", "WE_", "WM_", "WNF_", "PTRM_",
          "WIN_MAX", "TC_", "LK_", "SKS_", "NETW_", "KEY_", "MEM_MAX", "AS_MAX",
          "CON_WRITE_MAX", "FS_ROOM_MAX")


def tools():
    """ml64.exe and link.exe, from the newest Visual Studio with the C++ tools."""
    if not VSWHERE.exists():
        return None
    found = subprocess.run([str(VSWHERE), "-latest", "-products", "*", "-find",
                            r"VC\Tools\MSVC\**\bin\Hostx64\x64\ml64.exe"],
                           capture_output=True, text=True).stdout.splitlines()
    if not found:
        return None
    ml64 = pathlib.Path(found[-1])
    return ml64, ml64.with_name("link.exe")


def masm_expr(expr, known):
    """A NASM constant expression as MASM has it, or None if it is not one
    (a string, a label, something only NASM can say)."""
    expr = expr.strip()
    if not expr or "'" in expr or '"' in expr or "$" in expr:
        return None
    toks = re.findall(r"0x[0-9A-Fa-f]+|\d+|[A-Za-z_]\w*|<<|>>|[-+*/|&~()]|\S", expr)
    out = []
    for t in toks:
        if t.startswith(("0x", "0X")):
            out.append("0" + t[2:].upper() + "h")
        elif t.isdigit():
            out.append(t)
        elif re.fullmatch(r"[A-Za-z_]\w*", t):
            if t not in known:
                return None
            out.append(t)
        else:
            op = {"<<": "SHL", ">>": "SHR", "|": "OR", "&": "AND", "~": "NOT"}.get(t, t)
            if op not in ("SHL", "SHR", "OR", "AND", "NOT", "+", "-", "*", "/", "(", ")"):
                return None
            out.append(op)
    return " ".join(out)


def make_inc():
    """sdk/masm/axiom.inc from the kernel's own constants -> the names in it."""
    known, lines = set(), []
    for src in SOURCES:
        lines.append(f"\n; from {src.relative_to(ROOT).as_posix()}")
        for raw in src.read_text(encoding="latin-1").splitlines():
            m = re.match(r"^([A-Z][A-Z0-9_]*)\s+equ\s+([^;]*?)\s*(;.*)?$", raw)
            if not m:
                continue
            name, expr, note = m.groups()
            if not name.startswith(PUBLIC) or name in known:
                continue
            value = masm_expr(expr, known)
            if value is None:
                continue
            known.add(name)
            lines.append(f"{name:<15} EQU {value}" + (f"  {note}" if note else ""))
    text = ("; axiom.inc: Axiom's constants for MASM programs, made by tools/masm.py from\n"
            "; the kernel's own (do not edit; see docs/ABI.md)\n" + "\n".join(lines) + "\n")
    inc = SDK / "axiom.inc"
    if not inc.exists() or inc.read_text(encoding="latin-1") != text:
        inc.write_text(text, encoding="latin-1", newline="\n")
    return known


def wants_of(src, known):
    m = re.search(r"^;\s*wants:\s*(.+)$", src.read_text(encoding="latin-1"), re.M)
    if not m:
        return 0
    names = {n: v for n, v in (("AW_NET", 1), ("AW_STORE", 2), ("AW_DESK", 4), ("AW_FILES", 16))}
    value = 0
    for word in m.group(1).replace("|", " OR ").split():
        if word.upper() == "OR":
            continue
        if word not in names:
            sys.exit(f"masm: {src.name}: wants {word}?")
        value |= names[word]
    return value


def main():
    found = tools()
    if not found:
        print("no MSVC with ml64 (Visual Studio's C++ tools): the MASM programs are not built")
        return 3
    ml64, link = found
    known = make_inc()
    names = sys.argv[1:] or sorted(p.stem for p in SDK.glob("*.asm"))
    OUT.mkdir(parents=True, exist_ok=True)
    for name in names:
        src = SDK / f"{name}.asm"
        obj, exe = OUT / f"{name}.obj", OUT / f"{name}.exe"
        axe = AXE / f"{name.upper()}.AXE"
        if len(name) > 8:
            sys.exit(f"masm: {name}: a program's name is 8 letters at most")
        steps = [
            [str(ml64), "/nologo", "/c", "/Cp", f"/Fo{obj}", f"/I{SDK}", str(src)],
            [str(link), "/nologo", "/NODEFAULTLIB", "/ENTRY:start", "/SUBSYSTEM:NATIVE",
             "/BASE:0x400000", "/FIXED", "/INCREMENTAL:NO", "/DEBUG:NONE", "/MANIFEST:NO",
             f"/OUT:{exe}", str(obj)],
            [sys.executable, str(ROOT / "tools" / "mkaxe.py"), str(exe), str(axe),
             "--wants", str(wants_of(src, known))],
        ]
        for step in steps:
            r = subprocess.run(step, capture_output=True, text=True)
            if r.returncode:
                print(r.stdout + r.stderr)
                sys.exit(f"masm: {name} did not build")
        print(r.stdout.strip())
    return 0


if __name__ == "__main__":
    sys.exit(main())
