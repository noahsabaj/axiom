#!/usr/bin/env python3
"""Rasterize a monospace TrueType font into Axiom's anti-aliased glyph atlas.

Writes src/kernel/gen/font.bin (8-bit coverage, glyph after glyph, size after
size) and src/kernel/gen/font.inc (metrics table and codes for the extra
symbols). Box-drawing and block characters are drawn procedurally so lines
join exactly across cells.

Default font: Cascadia Mono (SIL Open Font License 1.1).
Usage: python tools/mkfont.py [path/to/font.ttf]
"""
import pathlib
import sys

from fontTools.ttLib import TTFont
from PIL import Image, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "src" / "kernel" / "gen"
FONT = sys.argv[1] if len(sys.argv) > 1 else r"C:\Windows\Fonts\CascadiaMono.ttf"

CELL_HEIGHTS = [20, 30, 40]
EXTRA_BASE = 128

# Bytes 128+ in Axiom strings select these symbols, in this order.
EXTRAS = [
    ("BLOCK", "\u2588"), ("SHADE3", "\u2593"), ("SHADE2", "\u2592"), ("SHADE1", "\u2591"),
    ("HLINE", "\u2500"), ("VLINE", "\u2502"), ("TL", "\u250c"), ("TR", "\u2510"),
    ("BL", "\u2514"), ("BR", "\u2518"), ("TEE_L", "\u251c"), ("TEE_R", "\u2524"),
    ("TEE_T", "\u252c"), ("TEE_B", "\u2534"), ("CROSS", "\u253c"),
    ("HALF_L", "\u258c"), ("HALF_R", "\u2590"), ("HALF_T", "\u2580"), ("HALF_B", "\u2584"),
    ("BULLET", "\u2022"), ("MIDDOT", "\u00b7"), ("ARROW_R", "\u2192"), ("ARROW_L", "\u2190"),
    ("ARROW_U", "\u2191"), ("ARROW_D", "\u2193"), ("CHECK", "\u2713"), ("CROSSMARK", "\u2717"),
    ("DOT", "\u25cf"), ("CIRCLE", "\u25cb"), ("DIAMOND", "\u25c6"), ("ELLIPSIS", "\u2026"),
    ("DEGREE", "\u00b0"), ("MICRO", "\u00b5"), ("TIMES", "\u00d7"), ("TRI_R", "\u25b6"),
    ("APPROX", "\u2248"), ("LE", "\u2264"), ("GE", "\u2265"), ("BAR8", "\u2587"),
    # what terminal programs draw with (term.asm's xterm maps Unicode to these)
    ("CHEVRON", "\u276f"), ("RSAQUO", "\u203a"), ("LSAQUO", "\u2039"), ("CIRCLE_L", "\u25ef"),
    ("FISHEYE", "\u25c9"), ("TRI_R_S", "\u25b8"), ("TRI_R_O", "\u25b7"), ("TRI_L", "\u25c0"),
    ("TRI_U", "\u25b2"), ("TRI_D", "\u25bc"), ("TRI_U_O", "\u25b3"), ("TRI_D_O", "\u25bd"),
    ("RETURN", "\u23ce"), ("RSQUO", "\u2019"), ("LSQUO", "\u2018"), ("LDQUO", "\u201c"),
    ("RDQUO", "\u201d"), ("EMDASH", "\u2014"), ("ENDASH", "\u2013"), ("NE", "\u2260"),
    ("PLUSMINUS", "\u00b1"), ("DIVIDE", "\u00f7"), ("ARROW_LR", "\u2194"), ("DIAMOND_O", "\u25c7"),
    ("SQUARE", "\u25a0"), ("SQUARE_O", "\u25a1"), ("SQUARE_S", "\u25aa"), ("SQUARE_SO", "\u25ab"),
    ("ARC_TL", "\u256d"), ("ARC_TR", "\u256e"), ("ARC_BL", "\u2570"), ("ARC_BR", "\u256f"),
    ("QUAD_TL", "\u2598"), ("QUAD_TR", "\u259d"), ("QUAD_BL", "\u2596"), ("QUAD_BR", "\u2597"),
    ("QUAD_NBR", "\u259b"), ("QUAD_NBL", "\u259c"), ("QUAD_NTR", "\u2599"), ("QUAD_NTL", "\u259f"),
    ("QUAD_TLBR", "\u259a"), ("QUAD_TRBL", "\u259e"),
    ("LEFT1", "\u258f"), ("LEFT2", "\u258e"), ("LEFT3", "\u258d"), ("LEFT5", "\u258b"),
    ("LEFT6", "\u258a"), ("LEFT7", "\u2589"), ("LOW1", "\u2581"), ("LOW2", "\u2582"),
    ("LOW3", "\u2583"), ("LOW5", "\u2585"), ("LOW6", "\u2586"), ("TOP1", "\u2594"),
    ("RIGHT1", "\u2595"), ("EURO", "\u20ac"), ("POUND", "\u00a3"), ("SECTION", "\u00a7"),
    ("COPYRIGHT", "\u00a9"), ("REGISTERED", "\u00ae"), ("LAMBDA", "\u03bb"), ("PI", "\u03c0"),
    ("SIGMA", "\u03a3"), ("DELTA", "\u0394"), ("INFINITY", "\u221e"), ("SQRT", "\u221a"),
    ("NOT", "\u00ac"), ("IQUEST", "\u00bf"), ("IEXCL", "\u00a1"), ("E_ACUTE", "\u00e9"),
    ("E_GRAVE", "\u00e8"), ("U_UML", "\u00fc"), ("O_UML", "\u00f6"), ("A_UML", "\u00e4"),
    ("N_TILDE", "\u00f1"), ("C_CEDIL", "\u00e7"), ("A_GRAVE", "\u00e0"), ("SHARP_S", "\u00df"),
    ("O_SLASH", "\u00f8"), ("A_RING", "\u00e5"), ("DBL_BAR", "\u2016"),
]

# Unicode the font has no glyph of its own for, drawn as one it has
ALIASES = {
    "\u2501": "\u2500", "\u2503": "\u2502", "\u2550": "\u2500", "\u2551": "\u2502",
    "\u2554": "\u250c", "\u2557": "\u2510", "\u255a": "\u2514", "\u255d": "\u2518",
    "\u2560": "\u251c", "\u2563": "\u2524", "\u2566": "\u252c", "\u2569": "\u2534",
    "\u256c": "\u253c", "\u250f": "\u250c", "\u2513": "\u2510", "\u2517": "\u2514",
    "\u251b": "\u2518", "\u2523": "\u251c", "\u252b": "\u2524", "\u2533": "\u252c",
    "\u253b": "\u2534", "\u254b": "\u253c", "\u2504": "\u2500", "\u2505": "\u2500",
    "\u2508": "\u2500", "\u2509": "\u2500", "\u254c": "\u2500", "\u254d": "\u2500",
    "\u2574": "\u2500", "\u2576": "\u2500", "\u2578": "\u2500", "\u257a": "\u2500",
    "\u2506": "\u2502", "\u2507": "\u2502", "\u250a": "\u2502", "\u250b": "\u2502",
    "\u254e": "\u2502", "\u254f": "\u2502", "\u2575": "\u2502", "\u2577": "\u2502",
    "\u2579": "\u2502", "\u257b": "\u2502",
    "\u273b": "*", "\u2733": "*", "\u2736": "*", "\u2722": "*", "\u273d": "*",
    "\u2731": "*", "\u2605": "*", "\u2606": "*", "\u23fa": "\u25cf", "\u23bf": "\u2514",
    "\u23f5": "\u25b6", "\u23f8": "\u2016", "\u2714": "\u2713", "\u2718": "x",
    "\u2717": "x", "\u26a0": "!", "\u21d2": "\u2192", "\u22ef": "\u2026", "\u21b5": "\u23ce",
    "\u2610": "\u25a1", "\u2612": "\u25a0", "\u29c9": "\u25a1", "\u21af": "!",
    "\u2318": "#", "\u2325": "~", "\u21e7": "\u2191", "\u00a0": " ", "\u2027": "\u00b7",
    "\u2219": "\u00b7", "\u2043": "-", "\u2010": "-", "\u2011": "-", "\u2012": "-",
    "\u2015": "\u2014", "\u2032": "'", "\u2033": '"', "\u00ab": "<", "\u00bb": ">",
    "\u27e8": "<", "\u27e9": ">", "\u25e6": "\u25cb", "\u2023": "\u25b8", "\u25aa": "\u25aa",
    "\u2588": "\u2588",
}

# light box drawing: which of (up, down, left, right) arms a glyph has
BOX = {
    "\u2500": (0, 0, 1, 1), "\u2502": (1, 1, 0, 0), "\u250c": (0, 1, 0, 1),
    "\u2510": (0, 1, 1, 0), "\u2514": (1, 0, 0, 1), "\u2518": (1, 0, 1, 0),
    "\u251c": (1, 1, 0, 1), "\u2524": (1, 1, 1, 0), "\u252c": (0, 1, 1, 1),
    "\u2534": (1, 0, 1, 1), "\u253c": (1, 1, 1, 1),
}


def procedural(ch, w, h):
    """Return an 'L' image for box/block characters, or None."""
    img = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(img)
    if ch in BOX:
        up, down, left, right = BOX[ch]
        t = max(1, round(h / 18))
        cx0 = (w - t) // 2
        cy0 = (h - t) // 2
        if up:
            d.rectangle([cx0, 0, cx0 + t - 1, cy0 + t - 1], fill=255)
        if down:
            d.rectangle([cx0, cy0, cx0 + t - 1, h - 1], fill=255)
        if left:
            d.rectangle([0, cy0, cx0 + t - 1, cy0 + t - 1], fill=255)
        if right:
            d.rectangle([cx0, cy0, w - 1, cy0 + t - 1], fill=255)
        return img
    shades = {"\u2588": 255, "\u2593": 192, "\u2592": 128, "\u2591": 64}
    if ch in shades:
        d.rectangle([0, 0, w - 1, h - 1], fill=shades[ch])
        return img
    halves = {
        "\u258c": [0, 0, w // 2 - 1, h - 1], "\u2590": [w // 2, 0, w - 1, h - 1],
        "\u2580": [0, 0, w - 1, h // 2 - 1], "\u2584": [0, h // 2, w - 1, h - 1],
        "\u2587": [0, h // 8, w - 1, h - 1],
        "\u2594": [0, 0, w - 1, h // 8 - 1], "\u2595": [w - w // 8, 0, w - 1, h - 1],
    }
    for n, c in zip((1, 2, 3, 5, 6, 7), "\u258f\u258e\u258d\u258b\u258a\u2589"):
        halves[c] = [0, 0, max(1, round(w * n / 8)) - 1, h - 1]
    for n, c in zip((1, 2, 3, 5, 6), "\u2581\u2582\u2583\u2585\u2586"):
        halves[c] = [0, h - max(1, round(h * n / 8)), w - 1, h - 1]
    if ch in halves:
        d.rectangle(halves[ch], fill=255)
        return img
    # quadrants: which of top-left, top-right, bottom-left, bottom-right
    quads = {
        "\u2598": (1, 0, 0, 0), "\u259d": (0, 1, 0, 0), "\u2596": (0, 0, 1, 0),
        "\u2597": (0, 0, 0, 1), "\u259b": (1, 1, 1, 0), "\u259c": (1, 1, 0, 1),
        "\u2599": (1, 0, 1, 1), "\u259f": (0, 1, 1, 1), "\u259a": (1, 0, 0, 1),
        "\u259e": (0, 1, 1, 0),
    }
    if ch in quads:
        mx, my = w // 2, h // 2
        boxes = ([0, 0, mx - 1, my - 1], [mx, 0, w - 1, my - 1],
                 [0, my, mx - 1, h - 1], [mx, my, w - 1, h - 1])
        for on, box in zip(quads[ch], boxes):
            if on:
                d.rectangle(box, fill=255)
        return img
    if ch == "‖":                         # (not in Cascadia Mono)
        t = max(1, round(h / 14))
        for x in (w // 3, w - w // 3 - t):
            d.rectangle([x, h // 6, x + t - 1, h - h // 6], fill=255)
        return img
    if ch == "✗":
        t = max(1, round(h / 12))
        d.line([(w * 0.2, h * 0.3), (w * 0.8, h * 0.75)], fill=255, width=t)
        d.line([(w * 0.8, h * 0.3), (w * 0.2, h * 0.75)], fill=255, width=t)
        return img
    # rounded corners: the light lines' arms, joined by a quarter circle
    arcs = {"\u256d": (0, 1, 0, 1), "\u256e": (0, 1, 1, 0), "\u2570": (1, 0, 0, 1), "\u256f": (1, 0, 1, 0)}
    if ch in arcs:
        up, down, left, right = arcs[ch]
        t = max(1, round(h / 18))
        cx = (w - t) // 2 + t // 2
        cy = (h - t) // 2 + t // 2
        r = max(2, w // 2 - 1)
        ex = cx + r if right else cx - r          # the arc's centre
        ey = cy + r if down else cy - r
        start = {(0, 1, 0, 1): 180, (0, 1, 1, 0): 270, (1, 0, 0, 1): 90, (1, 0, 1, 0): 0}[arcs[ch]]
        d.arc([ex - r, ey - r, ex + r, ey + r], start, start + 90, fill=255, width=t)
        x0 = (w - t) // 2
        y0 = (h - t) // 2
        if right:
            d.rectangle([cx + r, y0, w - 1, y0 + t - 1], fill=255)
        if left:
            d.rectangle([0, y0, cx - r, y0 + t - 1], fill=255)
        if down:
            d.rectangle([x0, cy + r, x0 + t - 1, h - 1], fill=255)
        if up:
            d.rectangle([x0, 0, x0 + t - 1, cy - r], fill=255)
        return img
    return None


def pick_size(cell_h):
    """Largest em size whose line height fits the cell."""
    best = None
    for px in range(6, cell_h * 2):
        f = ImageFont.truetype(FONT, px)
        asc, desc = f.getmetrics()
        if asc + desc <= cell_h:
            best = (px, f, asc, desc)
    return best


def main():
    cmap = TTFont(FONT).getBestCmap()
    chars = [chr(c) for c in range(32, 127)] + [c for _, c in EXTRAS]
    OUT.mkdir(parents=True, exist_ok=True)

    blob = bytearray()
    table = []
    previews = []
    for cell_h in CELL_HEIGHTS:
        px, font, asc, desc = pick_size(cell_h)
        cell_w = round(font.getlength("M"))
        top = (cell_h - (asc + desc)) // 2
        baseline = top + asc
        table.append((len(blob), cell_w, cell_h))
        sheet = Image.new("L", (cell_w * 32, cell_h * ((len(chars) + 31) // 32)), 0)
        for i, ch in enumerate(chars):
            img = procedural(ch, cell_w, cell_h)
            if img is None:
                glyph = ch if ord(ch) in cmap else "?"
                img = Image.new("L", (cell_w, cell_h), 0)
                ImageDraw.Draw(img).text((0, baseline), glyph, font=font, fill=255, anchor="ls")
            blob += img.tobytes()
            sheet.paste(img, ((i % 32) * cell_w, (i // 32) * cell_h))
        previews.append(sheet)
        missing = [f"U+{ord(c):04X}" for c in chars if ord(c) not in cmap and procedural(c, 4, 4) is None]
        print(f"cell {cell_w}x{cell_h}: em {px}px, baseline {baseline}, missing {missing or 'none'}")

    (OUT / "font.bin").write_bytes(blob)

    lines = [
        "; generated by tools/mkfont.py - do not edit",
        f"; source: {pathlib.Path(FONT).name} (SIL Open Font License 1.1)",
        f"FONT_SIZES      equ {len(CELL_HEIGHTS)}",
        f"FONT_GLYPHS     equ {len(chars)}",
        f"FONT_EXTRA_BASE equ {EXTRA_BASE}",
        f"FONT_EXTRAS     equ {len(EXTRAS)}",
        "align 8",
        "font_sizes:                 ; qword offset into font_data, dword cell width, dword cell height",
    ]
    for off, w, h in table:
        lines.append(f"    dq {off}")
        lines.append(f"    dd {w}, {h}")
    for i, (name, _) in enumerate(EXTRAS):
        lines.append(f"G_{name:<14} equ {EXTRA_BASE + i}")
    # Unicode to glyph codes, sorted: the extras and the aliases (term.asm's xterm)
    code = {c: EXTRA_BASE + i for i, (_, c) in enumerate(EXTRAS)}
    code.update({chr(c): c for c in range(32, 127)})
    umap = {ord(c): g for c, g in code.items() if ord(c) >= 128}
    for c, to in ALIASES.items():
        if to not in code:
            sys.exit(f"mkfont: the alias of U+{ord(c):04X} is not a glyph")
        umap.setdefault(ord(c), code[to])
    lines.append(f"FONT_UNICODE    equ {len(umap)}")
    lines.append("font_unicode:               ; dword code point, dword glyph code, by code point")
    for cp in sorted(umap):
        lines.append(f"    dd 0x{cp:04X}, {umap[cp]}")
    lines.append("font_extra_cp:              ; dword: the code point of each extra glyph")
    for _, c in EXTRAS:
        lines.append(f"    dd 0x{ord(c):04X}")
    (OUT / "font.inc").write_text("\n".join(lines) + "\n")

    width = max(p.width for p in previews)
    height = sum(p.height for p in previews) + 8 * len(previews)
    preview = Image.new("L", (width, height), 40)
    y = 0
    for p in previews:
        preview.paste(p, (0, y))
        y += p.height + 8
    preview.save(OUT / "font_preview.png")
    print(f"wrote {len(blob)} bytes of glyphs")


if __name__ == "__main__":
    main()
