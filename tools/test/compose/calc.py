#!/usr/bin/env python3
"""compose's numbers and formulas (compose/calc.inc), on the host.

    python tools/test/compose/calc.py

Numbers read and written again; formulas of every kind, with their errors;
recalculation by dependency (only what depends on a change is evaluated
again), a cycle, and a chain through 200 rows (the calculation stack).
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from host import Compose  # noqa: E402

FAILS = 0


def result(ok, text):
    global FAILS
    FAILS += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + text)
    return ok


def main():
    c = Compose()
    for text, want in (("42", "42"), ("-7", "-7"), ("3.5", "3.5"), (" 12 ", "12"),
                       ("0.1", "0.1"), ("1e3", "1000"), ("2.5e-3", "0.0025"), ("50%", "0.5"),
                       ("1234567.891", "1234567.891"), ("123456789012345678", "1.234568E+17"),
                       ("0.000001", "1E-6"), ("1/3", None), ("abc", None), ("", None),
                       ("-0", "0"), ("3.14159265358979", "3.141592654"), ("1e300", "1E+300"),
                       ("12345678901.5", "12345678902"), ("99.99999999999", "100")):
        got = c.num(text)
        result(got == want, f"number {text!r}: {got!r}")

    g = c.grid()
    cells = {(0, 0): "10", (1, 0): "20", (2, 0): "30", (3, 0): "=SUM(A1:A3)",
             (0, 1): "=A1*2", (1, 1): "=A4/A1", (2, 1): "=AVERAGE(A1:A3)", (3, 1): "=MIN(A1:A3)",
             (4, 1): "=MAX(A1:A3, 99)", (5, 1): "=COUNT(A1:A3, B1)", (6, 1): '=IF(A1>5, "big", "small")',
             (7, 1): "=IF(A1<5, 1/0, 7)", (8, 1): "=A1/0", (9, 1): "=1+", (10, 1): "=FOO(1)",
             (11, 1): '="a"+1', (12, 1): "=(1+2)*3-4/2", (13, 1): "=-A1+ -2", (14, 1): '="x"&A1&"y"',
             (15, 1): "=ROUND(2.345, 2)", (16, 1): "=ROUND(-2.5)", (17, 1): "=ABS(-3)",
             (18, 1): "=A1=10", (19, 1): "=A1<>10", (20, 1): '="abc"<"abd"', (21, 1): "=sum(a1:a3)",
             (22, 1): "=$A$1+A$2", (23, 1): "=Z999", (24, 1): "=IF(TRUE, A1)", (25, 1): "=IF(0, 1)",
             (26, 1): "=SUM(A1:A3)/COUNT(A1:A3)", (27, 1): "=A1 >= 10", (28, 1): "=C1",
             (29, 1): '=IF(A1="x", 1, 2)', (30, 1): "=AVERAGE(D1:D3)", (31, 1): "=2*(3"}
    for (r, col), text in cells.items():
        c.set(g, r, col, text)
    want = {(3, 0): "60", (0, 1): "20", (1, 1): "6", (2, 1): "20", (3, 1): "10", (4, 1): "99",
            (5, 1): "4", (6, 1): "big", (7, 1): "7", (8, 1): "#DIV/0!", (9, 1): "#ERROR!",
            (10, 1): "#NAME?", (11, 1): "#VALUE!", (12, 1): "7", (13, 1): "-12", (14, 1): "x10y",
            (15, 1): "2.35", (16, 1): "-3", (17, 1): "3", (18, 1): "1", (19, 1): "0", (20, 1): "1",
            (21, 1): "60", (22, 1): "30", (23, 1): "#REF!", (24, 1): "10", (25, 1): "0",
            (26, 1): "20", (27, 1): "1", (28, 1): "0", (29, 1): "2", (30, 1): "0", (31, 1): "#ERROR!",
            (0, 0): "10"}
    for (r, col), w in want.items():
        got = c.show(g, r, col)
        result(got == w, f"{'ABCD'[col]}{r + 1} {cells.get((r, col), '')!r} = {got!r}"
               + ("" if got == w else f", not {w!r}"))

    # by dependency: A2 changes; A4 (the sum), B2 (A4/A1), B3..B6, B23, B27 depend on it
    n = c.set(g, 1, 0, "25")
    result(c.show(g, 3, 0) == "65" and c.show(g, 1, 1) == "6.5",
           f"A2 = 25: A4 = {c.show(g, 3, 0)}, B2 = {c.show(g, 1, 1)}")
    result(n == 9, f"recalculated {n} formulas (A4, B2, B3, B4, B5, B6, B22, B23, B27: 9)")
    n = c.set(g, 0, 2, "5")                     # C1: only B29 refers to it
    result(n == 1 and c.show(g, 28, 1) == "5", f"C1 = 5: {n} recalculated, B29 = {c.show(g, 28, 1)}")

    h = c.grid()
    c.set(h, 0, 0, "=B1+1")
    c.set(h, 0, 1, "=A1+1")
    result(c.show(h, 0, 0) == "#CYCLE!" and c.show(h, 0, 1) == "#CYCLE!",
           f"a cycle: {c.show(h, 0, 0)}, {c.show(h, 0, 1)}")
    c.set(h, 0, 1, "4")
    result(c.show(h, 0, 0) == "5", f"broken: A1 = {c.show(h, 0, 0)}")

    k = c.grid()                                # bottom up: each row on the one below
    for r in range(198, -1, -1):
        c.set(k, r, 0, f"=A{r + 2}+1")
    n = c.set(k, 199, 0, "1")
    result(c.show(k, 0, 0) == "200" and n == 199, f"a chain through 200 rows: A1 = "
           f"{c.show(k, 0, 0)}, {n} recalculated")
    print(f"{'all passed' if not FAILS else f'{FAILS} FAILED'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
