#!/usr/bin/env python3
"""Rasterize the desktop's proportional font: Noto Sans in two weights
(regular, semibold) at the sizes the desktop draws its words in,
into src/kernel/gen/uifont.bin (8-bit coverage) and src/kernel/gen/uifont.inc
(the tables that find a glyph). What Noto Sans lacks (arrows, a check, the
keys' symbols) comes from DejaVu Sans of the same weight. And the clock's
figures alone (digits, a colon, a point, % and a degree), large (UF_BIG).

    python tools/mkuifont.py [fonts directory]

Each glyph is drawn at four times its size and averaged down, unhinted, so
its shapes stay as the designer drew them. Semibold is regular drawn with a
thin outline at that size: half a pixel wider strokes.

Noto Sans: SIL Open Font License 1.1. DejaVu fonts: Bitstream Vera license
and public domain changes. Both free to embed and redistribute.

uifont.inc:
  UF_WEIGHTS, UF_SIZES, UF_GLYPHS; uf_size_px (UF_SIZES bytes)
  UF_BIG, UF_BIG_SIZES; uf_big_px: the figures' fonts, after the others
  uf_fonts: UF_WEIGHTS * UF_SIZES entries of UFT_SIZE bytes (weight-major),
  then UF_BIG_SIZES more:
    UFT_GLYPHS dq  offset of its glyph table in uifont.bin
    UFT_ASCENT dd  pixels above the baseline
    UFT_DESCENT dd pixels below it
    UFT_LINE   dd  line height, pixels
    UFT_CAP    dd  a capital's height, pixels (for centring a line)
  a glyph table: UF_GLYPHS entries of UG_SIZE bytes:
    UG_DATA dd   offset of its coverage in uifont.bin (w * h bytes)
    UG_ADV  dw   advance, 1/64 pixels
    UG_W    db, UG_H db   bitmap size
    UG_LEFT db (signed)   from the pen to the bitmap's left
    UG_TOP  db (signed)   from the baseline up to the bitmap's top
  uf_byte: 256 words, the glyph of each byte of the kernel's text: ASCII,
    and from 128 the console font's extra symbols (tools/mkfont.py), 0 none;
    from 248 the keys' symbols (UG_CTRL ...), the desktop's alone
  uf_uni: UF_UNI entries of (dd code point, dd glyph), sorted, for UTF-8
Glyph 0 is the replacement, drawn for anything missing.
"""
import pathlib
import struct
import sys

from fontTools.ttLib import TTFont
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from mkfont import EXTRAS, EXTRA_BASE  # noqa: E402  the console's symbols

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "src" / "kernel" / "gen"
FONTS = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(r"C:\Windows\Fonts")

# (name, Noto Sans file, DejaVu Sans file, outline at 4x)
WEIGHTS = [("REGULAR", "NotoSans-Regular.ttf", "DejaVuSans.ttf", 0),
           ("SEMIBOLD", "NotoSans-Regular.ttf", "DejaVuSans.ttf", 2)]
SIZES = [11, 13, 14, 16, 20, 22, 26]           # 11 and 13 points at 1, 1.25, 1.5, 2x
BIG_CHARS = "0123456789:.%-\u00b0"               # figures, for the clock and the widgets
BIG_SIZES = [22, 28, 33, 39, 44, 55, 66, 77, 88]  # 22 and 44 points at 1 .. 2x
SS = 4                                          # drawn at 4x, averaged down
# bytes past the console's symbols that only the desktop's text has: the
# keys' symbols, for the menus' shortcuts (UG_<name>)
UI_BASE = 248
UI_BYTES = [("CTRL", 0x2303), ("CMD", 0x2318), ("SHIFT", 0x21E7), ("ALT", 0x2325)]

SYMBOLS = [0x2318, 0x2325, 0x21E7, 0x2303, 0x23CE, 0x232B, 0x2713, 0x2715, 0x2192, 0x2190,
           0x2191, 0x2193, 0x25CF, 0x25B8, 0x25BE, 0x2039, 0x203A, 0x2022, 0x2026, 0x2014,
           0x2013, 0x2018, 0x2019, 0x201C, 0x201D, 0x20AC, 0x2122, 0x2212, 0x00B7, 0x2248,
           0x2260, 0x2264, 0x2265, 0x221E, 0x03C0, 0x03BB, 0x03A3, 0x0394, 0x221A, 0x2044]


def main():
    # the console's symbols that are words' (not its box drawing, blocks and shapes)
    extra = [ord(ch) for _, ch in EXTRAS if not 0x2500 <= ord(ch) < 0x2600]
    codes = sorted(set(list(range(0x20, 0x7F)) + SYMBOLS + extra))
    blob = bytearray()
    tables = []
    for name, noto, dejavu, outline in WEIGHTS:
        noto_cmap = TTFont(str(FONTS / noto)).getBestCmap()
        dv_cmap = TTFont(str(FONTS / dejavu)).getBestCmap()
        usable = [c for c in codes if c in noto_cmap or c in dv_cmap]
        if name == "REGULAR":
            glyph_codes = usable
        for px in SIZES:
            nf = ImageFont.truetype(str(FONTS / noto), px * SS)
            df = ImageFont.truetype(str(FONTS / dejavu), px * SS)
            plain = ImageFont.truetype(str(FONTS / noto), px)
            ascent, descent = plain.getmetrics()
            cap = round(-nf.getbbox("H", anchor="ls")[1] / SS)
            table = bytearray()
            for c in [None] + glyph_codes:
                ch = chr(0xFFFD if c is None else c)
                font = nf if c is not None and c in noto_cmap else df
                if c is None:
                    ch, font = "?", nf
                table += glyph(font, ch, outline, blob)
            blob += bytes(-len(blob) % 4)
            tables.append((len(blob), ascent, descent, ascent + descent, cap, table))
            blob += table
    for px in BIG_SIZES:                        # the figures, a little heavier
        nf = ImageFont.truetype(str(FONTS / WEIGHTS[0][1]), px * SS)
        ascent, descent = ImageFont.truetype(str(FONTS / WEIGHTS[0][1]), px).getmetrics()
        cap = round(-nf.getbbox("0", anchor="ls")[1] / SS)
        table = bytearray()
        for c in [None] + glyph_codes:
            if c is not None and chr(c) in BIG_CHARS + " ":
                table += glyph(nf, chr(c), px // 22, blob)
            else:
                table += struct.pack("<IHBBbbH", 0, 0, 0, 0, 0, 0, 0)
        blob += bytes(-len(blob) % 4)
        tables.append((len(blob), ascent, descent, ascent + descent, cap, table))
        blob += table
    index = {c: i + 1 for i, c in enumerate(glyph_codes)}
    _INDEX.update(index)

    (OUT / "uifont.bin").write_bytes(bytes(blob))
    lines = ["; generated by tools/mkuifont.py - do not edit",
             "; Noto Sans (SIL Open Font License 1.1), DejaVu Sans for the symbols",
             f"UF_WEIGHTS      equ {len(WEIGHTS)}",
             f"UF_SIZES        equ {len(SIZES)}",
             f"UF_GLYPHS       equ {len(glyph_codes) + 1}",
             "UFT_GLYPHS      equ 0", "UFT_ASCENT      equ 8", "UFT_DESCENT     equ 12",
             "UFT_LINE        equ 16", "UFT_CAP         equ 20", "UFT_SIZE        equ 24",
             "UG_DATA         equ 0", "UG_ADV          equ 4", "UG_W            equ 6",
             "UG_H            equ 7", "UG_LEFT         equ 8", "UG_TOP          equ 9",
             "UG_SIZE         equ 12"]
    for i, (name, *_rest) in enumerate(WEIGHTS):
        lines.append(f"UF_{name:<12} equ {i}")
    lines.append("uf_size_px:     db " + ", ".join(str(s) for s in SIZES))
    lines.append(f"UF_BIG          equ {len(WEIGHTS) * len(SIZES)}")
    lines.append(f"UF_BIG_SIZES    equ {len(BIG_SIZES)}")
    lines.append("uf_big_px:      db " + ", ".join(str(s) for s in BIG_SIZES))
    lines.append("align 8")
    lines.append("uf_fonts:")
    for off, asc, desc, line, cap, _ in tables:
        lines.append(f"    dq {off}")
        lines.append(f"    dd {asc}, {desc}, {line}, {cap}")
    byte_map = [0] * 256
    for b in range(0x20, 0x7F):
        byte_map[b] = index.get(b, 0)
    for i, (_, ch) in enumerate(EXTRAS):
        if EXTRA_BASE + i < 256:
            byte_map[EXTRA_BASE + i] = index.get(ord(ch), 0)
    assert UI_BASE >= EXTRA_BASE + len(EXTRAS)
    for i, (name, code) in enumerate(UI_BYTES):
        byte_map[UI_BASE + i] = index.get(code, 0)
        lines.append(f"UG_{name:<12} equ {UI_BASE + i}")
    lines.append("uf_byte:")
    for i in range(0, 256, 16):
        lines.append("    dw " + ", ".join(str(g) for g in byte_map[i:i + 16]))
    lines.append(f"UF_UNI          equ {len(glyph_codes)}")
    lines.append("align 4")
    lines.append("uf_uni:")
    for c in glyph_codes:
        lines.append(f"    dd 0x{c:04X}, {index[c]}")
    (OUT / "uifont.inc").write_text("\n".join(lines) + "\n", newline="\n")
    print(f"uifont: {len(glyph_codes) + 1} glyphs, {len(WEIGHTS)} weights x {len(SIZES)} sizes, "
          f"the figures at {len(BIG_SIZES)}, {len(blob):,} bytes")
    preview(blob, tables)


def glyph(font, ch, outline, blob):
    """CH drawn at SS times, averaged down; its coverage onto BLOB -> its entry."""
    adv = round(font.getlength(ch) * 64 / SS)
    x0, y0, x1, y1 = font.getbbox(ch, anchor="ls", stroke_width=outline)
    if x1 <= x0 or y1 <= y0 or ch == " ":
        return struct.pack("<IHBBbbH", len(blob), adv, 0, 0, 0, 0, 0)
    # the box in whole pixels of the result, the pen at a pixel's corner
    gx0, gy0 = x0 // SS, y0 // SS
    gx1, gy1 = -(-x1 // SS), -(-y1 // SS)
    w, h = gx1 - gx0, gy1 - gy0
    big = Image.new("L", (w * SS, h * SS), 0)
    ImageDraw.Draw(big).text((-gx0 * SS, -gy0 * SS), ch, font=font, fill=255, anchor="ls",
                             stroke_width=outline, stroke_fill=255)
    small = big.resize((w, h), Image.BOX)
    off = len(blob)
    blob += small.tobytes()
    return struct.pack("<IHBBbbH", off, adv, w, h, gx0, -gy0, 0)


def preview(blob, tables):
    """uifont_preview.png: each weight at each size, as the kernel lays it out."""
    text = "Axiom \u2014 Files, Notes & Settings \u2022 13:42 \u2318\u21e7 \u2713"
    img = Image.new("L", (1100, sum(t[3] + 6 for t in tables) + 10), 24)
    y = 8
    for off, asc, desc, line, cap, table in tables:
        pen = 8 * 64
        for ch in text:
            g = _INDEX.get(ord(ch), 0)
            data, adv, w, h, left, top, _ = struct.unpack_from("<IHBBbbH", table, g * 12)
            if w and h:
                cov = Image.frombytes("L", (w, h), bytes(blob[data:data + w * h]))
                img.paste(255, (pen // 64 + left, y + asc - top), cov)
            pen += adv
        y += line + 6
    img.save(OUT / "uifont_preview.png")


_INDEX = {}                                     # code point -> glyph, for the preview


if __name__ == "__main__":
    main()
