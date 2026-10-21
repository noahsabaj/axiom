"""Just enough ELF64 for the kernel's link (tools/build.py): the bytes it
loads as one flat image, and its sections and symbols, for build/kernel.map.

    image(data)     -> (address of its first byte, the bytes): every PT_LOAD
                       segment's file bytes at its address, gaps zeroed, up to
                       the last one's end (.bss, not in the file, is not)
    sections(data)  -> [(name, address, size, kind)], the allocated ones
    symbols(data)   -> [(address, size, name)], sorted, without the file and
                       section symbols
    map_text(data, source) -> build/kernel.map's text: the sections, then a
                       line per symbol, "ADDRESS SIZE NAME" in hex
"""
import struct

PT_LOAD = 1
SHT_SYMTAB, SHT_NOBITS = 2, 8
SHF_ALLOC = 2
STT_SECTION, STT_FILE = 3, 4


def _header(data):
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise ValueError("not a little-endian ELF64 file")
    phoff, shoff, _, _, phentsize, phnum, shentsize, shnum, shstrndx = struct.unpack_from(
        "<QQIHHHHHH", data, 32)
    return phoff, phentsize, phnum, shoff, shentsize, shnum, shstrndx


def _segments(data):
    phoff, phentsize, phnum = _header(data)[:3]
    for i in range(phnum):
        kind, _, offset, vaddr, _, filesz, memsz, _ = struct.unpack_from(
            "<IIQQQQQQ", data, phoff + i * phentsize)
        yield kind, offset, vaddr, filesz, memsz


def _sections(data):
    _, _, _, shoff, shentsize, shnum, shstrndx = _header(data)
    raw = [struct.unpack_from("<IIQQQQIIQQ", data, shoff + i * shentsize) for i in range(shnum)]
    names = raw[shstrndx][4]
    for name, kind, flags, addr, offset, size, link, _, _, entsize in raw:
        end = data.index(b"\0", names + name)
        yield (data[names + name:end].decode(), kind, flags, addr, offset, size, link, entsize)


def image(data):
    loads = [(o, v, f) for k, o, v, f, _ in _segments(data) if k == PT_LOAD and f]
    if not loads:
        raise ValueError("nothing loaded")
    base = min(v for _, v, _ in loads)
    out = bytearray(max(v + f for _, v, f in loads) - base)
    for offset, vaddr, filesz in loads:
        out[vaddr - base:vaddr - base + filesz] = data[offset:offset + filesz]
    return base, bytes(out)


def sections(data):
    return [(name, addr, size, "nobits" if kind == SHT_NOBITS else "progbits")
            for name, kind, flags, addr, _, size, _, _ in _sections(data) if flags & SHF_ALLOC]


def symbols(data):
    secs = list(_sections(data))
    found = []
    for _, kind, _, _, offset, size, link, entsize in secs:
        if kind != SHT_SYMTAB:
            continue
        strtab = secs[link][4]
        for at in range(offset + entsize, offset + size, entsize):   # (the first is null)
            name, info, _, _, value, length = struct.unpack_from("<IBBHQQ", data, at)
            if info & 15 in (STT_SECTION, STT_FILE) or not name:
                continue
            end = data.index(b"\0", strtab + name)
            found.append((value, length, data[strtab + name:end].decode(errors="replace")))
    return sorted(found)


def map_text(data, source):
    lines = [f"Axiom kernel map, from {source} (tools/build.py)", "",
             "-- Sections " + "-" * 66, "",
             "Start             Stop              Length    Class     Name"]
    for name, addr, size, kind in sections(data):
        lines.append(f"{addr:016X}  {addr + size:016X}  {size:08X}  {kind:<8}  {name}")
    lines += ["", "-- Symbols " + "-" * 67, "",
              "Address           Size      Name"]
    for value, size, name in symbols(data):
        lines.append(f"{value:016X}  {size:08X}  {name}")
    return "\n".join(lines) + "\n"
