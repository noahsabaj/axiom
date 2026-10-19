#!/usr/bin/env python3
"""Make src/kernel/gen/rtw8821c.inc: the register tables of the Realtek
RTL8821C (the RTL8821CE Wi-Fi card), taken from Linux's rtw88 driver.

    python tools/mkrtw.py PATH/TO/rtw88/rtw8821c_table.c [commit]

rtw8821c_table.c is Realtek's, under GPL-2.0 OR BSD-3-Clause; the tables
are used here under the BSD-3-Clause license, whose notice the output
carries.

rtw8821c.inc (section .rodata, dword-aligned):
  rtwt_mac, rtwt_agc, rtwt_agc_btg2, rtwt_bb, rtwt_rf_a: pairs of dwords
    (address, value) with the condition words rtw88 puts between them
    (rtw_parse_tbl_phy_cond, in rtw.asm); each has its _end label
  rtwt_bb_pg: rows of six dwords: band, path, streams, address, mask, value
    (the power by rate), and rtwt_bb_pg_end
  rtwt_lmt: rows of six bytes: regulatory domain, band, bandwidth, rate
    section, channel, limit (signed, half dBm), and rtwt_lmt_end
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "src" / "kernel" / "gen" / "rtw8821c.inc"

PAIRS = [("rtw8821c_mac", "rtwt_mac"), ("rtw8821c_agc", "rtwt_agc"),
         ("rtw8821c_agc_btg_type2", "rtwt_agc_btg2"), ("rtw8821c_bb", "rtwt_bb"),
         ("rtw8821c_rf_a", "rtwt_rf_a")]

BSD = """\
; Copyright(c) 2018-2019  Realtek Corporation
;
; Redistribution and use in source and binary forms, with or without
; modification, are permitted provided that the following conditions are met:
; 1. Redistributions of source code must retain the above copyright notice,
;    this list of conditions and the following disclaimer.
; 2. Redistributions in binary form must reproduce the above copyright
;    notice, this list of conditions and the following disclaimer in the
;    documentation and/or other materials provided with the distribution.
; 3. Neither the name of the copyright holder nor the names of its
;    contributors may be used to endorse or promote products derived from
;    this software without specific prior written permission.
;
; THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
; AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
; IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
; ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
; LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
; CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
; SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
; INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
; CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
; ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
; POSSIBILITY OF SUCH DAMAGE.
"""


def body(text, name):
    m = re.search(r"static const [^\n]*\b%s\[\] = \{(.*?)\n\};" % re.escape(name), text, re.S)
    if not m:
        sys.exit(f"mkrtw: no table {name}")
    return re.sub(r"/\*.*?\*/", "", m.group(1), flags=re.S)


def numbers(s):
    return [int(x, 0) for x in re.findall(r"-?(?:0x[0-9A-Fa-f]+|\d+)", s)]


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    src = pathlib.Path(sys.argv[1])
    commit = sys.argv[2] if len(sys.argv) > 2 else "unknown"
    text = src.read_text(encoding="utf-8")
    out = [f"; src/kernel/gen/rtw8821c.inc - made by tools/mkrtw.py from Linux's",
           f"; drivers/net/wireless/realtek/rtw88/rtw8821c_table.c (commit {commit}),",
           "; under the BSD-3-Clause license (the file is GPL-2.0 OR BSD-3-Clause):",
           ";", BSD.rstrip("\n"), "", "section .rodata", "align 4"]
    sizes = []
    for cname, label in PAIRS:
        v = numbers(body(text, cname))
        if len(v) % 2:
            sys.exit(f"mkrtw: {cname} has an odd count")
        out.append(f"{label}:")
        for i in range(0, len(v), 8):
            out.append("    dd " + ", ".join(f"0x{x:08X}" for x in v[i:i + 8]))
        out.append(f"{label}_end:")
        sizes.append(f"{label} {len(v) // 2}")
    rows = re.findall(r"\{([^{}]*)\}", body(text, "rtw8821c_bb_pg_type0"))
    out.append("rtwt_bb_pg:")
    for r in rows:
        v = numbers(r)
        assert len(v) == 6, r
        out.append("    dd " + ", ".join(f"0x{x:08X}" for x in v))
    out.append("rtwt_bb_pg_end:")
    sizes.append(f"rtwt_bb_pg {len(rows)}")
    rows = re.findall(r"\{([^{}]*)\}", body(text, "rtw8821c_txpwr_lmt_type0"))
    out.append("rtwt_lmt:")
    for i in range(0, len(rows), 4):
        line = []
        for r in rows[i:i + 4]:
            v = numbers(r)
            assert len(v) == 6 and -128 <= v[5] < 128, r
            line.append(", ".join(str(x) for x in v))
        out.append("    db " + ",  ".join(line))
    out.append("rtwt_lmt_end:")
    sizes.append(f"rtwt_lmt {len(rows)}")
    OUT.write_text("\n".join(out) + "\n", encoding="utf-8", newline="\n")
    print(f"mkrtw: {OUT.relative_to(ROOT)}: " + ", ".join(sizes))


main()
