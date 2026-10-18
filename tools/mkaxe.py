#!/usr/bin/env python3
"""A program linked by another toolchain, as an .AXE: the file the kernel
loads, flat at USER_IMAGE (0x400000) from its first byte.

    python tools/mkaxe.py program.elf PROGRAM.AXE
    python tools/mkaxe.py program.exe PROGRAM.AXE [--wants N]

An ELF file is linked by sdk/rust/axiom/axiom.ld, which made the AXE header
(AXE_*, src/kernel/defs.inc) at 0x400000: the code from there to
AXE_TEXT_END, the constants to AXE_RODATA_END, the data to AXE_DATA_END
(the end of the file), and zeroes to AXE_BSS_END. Every section the program
loads is put where it runs, the header checked as the kernel will check it,
and the image written.

A PE file is from MSVC's link.exe (for MASM: docs/ABI.md), linked to run at
0x400000 as it is (/BASE:0x400000 /FIXED, /ENTRY, /NODEFAULTLIB, no imports).
Its headers' page becomes the AXE header, made here from its sections: code
(executable), then constants (read only), then data (written; what it has
past its bytes in the file is the zeroes). What it wants (AW_*) is --wants.
"""
import pathlib
import struct
import sys

USER_IMAGE = 0x400000
USER_IMAGE_MAX = 16 << 20
AXE_HDR = 56
AW_ALL = 7 | 16 | 32
SHF_ALLOC, SHF_TLS = 0x2, 0x400
SHT_NOBITS = 8


def fail(why):
    sys.exit(f"mkaxe: {why}")


def sections(elf):
    """(name, type, flags, addr, offset, size) of each section."""
    if elf[:4] != b"\x7fELF" or elf[4] != 2 or elf[5] != 1:
        fail("not a 64-bit little-endian ELF file")
    e_type, e_machine = struct.unpack_from("<HH", elf, 16)
    if e_type != 2 or e_machine != 62:
        fail("not an x86-64 executable (ET_EXEC)")
    entry, = struct.unpack_from("<Q", elf, 24)
    shoff, = struct.unpack_from("<Q", elf, 40)
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", elf, 58)
    raw = [struct.unpack_from("<IIQQQQIIQQ", elf, shoff + i * shentsize) for i in range(shnum)]
    names = raw[shstrndx]
    out = []
    for name, typ, flags, addr, offset, size, *_ in raw:
        end = elf.index(b"\0", names[4] + name)
        out.append((elf[names[4] + name:end].decode(), typ, flags, addr, offset, size))
    return entry, out


def page(n):
    return (n + 4095) & ~4095


def from_pe(pe, wants):
    """A PE image, linked for 0x400000 -> the AXE image, its header made."""
    if pe[:2] != b"MZ":
        fail("not an ELF or a PE file")
    at, = struct.unpack_from("<I", pe, 0x3C)
    if pe[at:at + 4] != b"PE\0\0":
        fail("not a PE file")
    machine, nsec, _, _, _, optsize, _ = struct.unpack_from("<HHIIIHH", pe, at + 4)
    opt = at + 24
    if machine != 0x8664 or struct.unpack_from("<H", pe, opt)[0] != 0x20B:
        fail("not an x86-64 (PE32+) image")
    entry_rva, = struct.unpack_from("<I", pe, opt + 16)
    base, = struct.unpack_from("<Q", pe, opt + 24)
    if base != USER_IMAGE:
        fail(f"linked for {base:#x}: link with /BASE:0x400000 /FIXED")
    ndirs, = struct.unpack_from("<I", pe, opt + 108)
    dirs = [struct.unpack_from("<II", pe, opt + 112 + i * 8) for i in range(min(ndirs, 16))]
    if len(dirs) > 1 and dirs[1][1]:
        fail("it imports from DLLs: an Axiom program calls only the kernel (/NODEFAULTLIB)")
    if len(dirs) > 9 and dirs[9][1]:
        fail("it has thread-local data: Axiom programs have none")
    code, consts, data = [], [], []
    for i in range(nsec):
        name, vsize, rva, rawsize, rawptr, _, _, _, _, chars = struct.unpack_from(
            "<8sIIIIIIHHI", pe, opt + optsize + i * 40)
        name = name.rstrip(b"\0").decode(errors="replace")
        if chars & 0x02000000 or name in (".reloc", ".pdata") or not vsize:
            continue                                # discardable, or unwinding
        if chars & 0x20000000:                      # IMAGE_SCN_MEM_EXECUTE
            kind = code
        elif chars & 0x80000000:                    # IMAGE_SCN_MEM_WRITE
            kind = data
        else:
            kind = consts
        kind.append((name, USER_IMAGE + rva, vsize, pe[rawptr:rawptr + min(rawsize, vsize)]))
    if not code:
        fail("no code")
    order = code + consts + data
    for a, b in zip(order, order[1:]):
        if b[1] < a[1] + a[2]:
            fail(f"{b[0]} before {a[0]} ends: code, then constants, then data "
                 "(/MERGE:.rdata=.text, say, for constants among the code)")
    text_end = page(code[-1][1] + code[-1][2])
    rodata_end = page(consts[-1][1] + consts[-1][2]) if consts else text_end
    data_end = data[-1][1] + len(data[-1][3]) if data else rodata_end
    bss_end = data[-1][1] + data[-1][2] if data else data_end
    entry = USER_IMAGE + entry_rva
    image = bytearray(data_end - USER_IMAGE)
    for name, addr, vsize, raw in order:
        if addr < USER_IMAGE + AXE_HDR:
            fail(f"{name} at {addr:#x}: where the header goes")
        image[addr - USER_IMAGE:addr - USER_IMAGE + len(raw)] = raw
    image[:AXE_HDR] = struct.pack("<8s6Q", b"AXIOMEX2", entry, text_end, rodata_end, data_end,
                                  bss_end, wants)
    return bytes(image)


def main():
    args = sys.argv[1:]
    wants = 0
    if "--wants" in args:
        i = args.index("--wants")
        wants = int(args[i + 1], 0)
        del args[i:i + 2]
    if len(args) != 2:
        sys.exit(__doc__)
    src, dst = pathlib.Path(args[0]), pathlib.Path(args[1])
    elf = src.read_bytes()
    if elf[:2] == b"MZ":
        elf = from_pe(elf, wants)
        entry, secs = struct.unpack_from("<Q", elf, 8)[0], [(".axe", 1, SHF_ALLOC, USER_IMAGE, 0, len(elf))]
        bss_at = struct.unpack_from("<Q", elf, 32)[0]
        bss_end = struct.unpack_from("<Q", elf, 40)[0]
        if bss_end > bss_at:
            secs.append((".bss", SHT_NOBITS, SHF_ALLOC, bss_at, 0, bss_end - bss_at))
    elif wants:
        fail("--wants is for a PE file: an ELF one says it in its header")
    else:
        entry, secs = sections(elf)
    loaded = [s for s in secs if s[2] & SHF_ALLOC and s[5]]
    if not loaded or loaded[0][3] != USER_IMAGE:
        fail("nothing at 0x400000: not linked by axiom.ld")
    tls = [s[0] for s in loaded if s[2] & SHF_TLS]
    if tls:
        fail(f"thread-local sections {tls}: Axiom programs have none")
    hdr = elf[loaded[0][4]:loaded[0][4] + AXE_HDR]
    magic, h_entry, text_end, rodata_end, data_end, bss_end, wants = struct.unpack("<8s6Q", hdr)
    if magic != b"AXIOMEX2":
        fail("no AXE header at 0x400000")
    if h_entry != entry or not USER_IMAGE + AXE_HDR <= entry < text_end:
        fail(f"the entry {entry:#x} is not in the code")
    if text_end % 4096 or rodata_end % 4096:
        fail("the code and the constants must end on pages")
    if not text_end <= rodata_end <= data_end <= bss_end <= USER_IMAGE + USER_IMAGE_MAX:
        fail(f"its parts are out of order, or past 16 MiB (to {bss_end - USER_IMAGE:#x})")
    if wants & ~AW_ALL:
        fail(f"it wants {wants:#x}: more than there is")
    image = bytearray(data_end - USER_IMAGE)
    for name, typ, flags, addr, offset, size in loaded:
        if typ == SHT_NOBITS:
            if not (data_end <= addr and addr + size <= bss_end):
                fail(f"{name}: zeroes outside the bss")
            continue
        if not (USER_IMAGE <= addr and addr + size <= data_end):
            fail(f"{name} at {addr:#x} is outside the file")
        image[addr - USER_IMAGE:addr - USER_IMAGE + size] = elf[offset:offset + size]
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(image)
    kib = lambda a, b: (b - a + 1023) // 1024  # noqa: E731
    print(f"{dst.name}: {kib(USER_IMAGE, text_end)} KiB code, "
          f"{kib(text_end, rodata_end)} KiB constants, {kib(rodata_end, data_end)} KiB data, "
          f"{kib(data_end, bss_end)} KiB zeroes; wants {wants:#x}")


if __name__ == "__main__":
    main()
