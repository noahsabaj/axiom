#!/usr/bin/env python3
"""An ELF program, linked by sdk/rust/axiom/axiom.ld, as an .AXE: the file
the kernel loads, flat at USER_IMAGE (0x400000) from its first byte.

    python tools/mkaxe.py program.elf PROGRAM.AXE

The linker script made the AXE header (AXE_*, src/kernel/defs.inc) at
0x400000: the code from there to AXE_TEXT_END, the constants to
AXE_RODATA_END, the data to AXE_DATA_END (the end of the file), and zeroes
to AXE_BSS_END. Here every section the program loads is put where it runs,
the header checked as the kernel will check it, and the image written.
"""
import pathlib
import struct
import sys

USER_IMAGE = 0x400000
USER_IMAGE_MAX = 16 << 20
AXE_HDR = 56
AW_ALL = 7 | 16
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


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    elf = src.read_bytes()
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
