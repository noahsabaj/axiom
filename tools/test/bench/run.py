#!/usr/bin/env python3
"""Axiom's benchmarks in QEMU: 'bench' and its areas, as records.

    python tools/test/bench/run.py [--areas boot,sched,...] [--smp N]
                                   [--runs N] [--label NAME]

Boots build/esp headless and runs 'bench <area>' for each area asked for
(boot, sched, mem, caps, gfx; all of them by default), each --runs times
(3), in one boot; prints every bench's median and its spread, and writes
them to build/test/bench/<label>.json (label: 'last'), so two builds can be
compared with --compare a.json b.json. The host is shared: run the two
builds close in time, and read the spread.
Outputs go to build/test/bench/.
"""
import argparse
import json
import pathlib
import re
import statistics
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "test"))
from qemu import boot_all  # noqa: E402

OUT = ROOT / "build" / "test" / "bench"
AREAS = ["boot", "sched", "mem", "caps", "gfx"]
ROW = re.compile(r"^  (\w+)\s+(.+?)\s+(\d+)\s+(\d+\.\d)ns\s+(\d+)\s+(MB/s|op/s)\s*$")


def parse(log):
    """{(area, bench): [ns each, ...]} and {(area, bench): unit rates}"""
    each, rate = {}, {}
    for line in log.splitlines():
        m = ROW.match(line)
        if m:
            key = f"{m.group(1)}/{m.group(2).strip()}"
            each.setdefault(key, []).append(float(m.group(4)))
            rate.setdefault(key, []).append((int(m.group(5)), m.group(6)))
    return each, rate


def fmt_ns(ns):
    for unit, scale in (("s", 1e9), ("ms", 1e6), ("us", 1e3)):
        if ns >= scale:
            return f"{ns / scale:.2f} {unit}"
    return f"{ns:.1f} ns"


def summary(each, rate):
    out = {}
    for key, values in each.items():
        med = statistics.median(values)
        r = sorted(rate[key])[len(rate[key]) // 2]
        out[key] = {"ns": med, "min": min(values), "max": max(values), "runs": len(values),
                    "rate": r[0], "unit": r[1]}
    return out


def show(results):
    width = max(len(k) for k in results)
    for key, v in results.items():
        spread = f"{fmt_ns(v['min'])} .. {fmt_ns(v['max'])}" if v["runs"] > 1 else ""
        print(f"  {key:<{width}}  {fmt_ns(v['ns']):>11}  {v['rate']:>12} {v['unit']}  {spread}")


def compare(a_path, b_path):
    a = json.loads(pathlib.Path(a_path).read_text())
    b = json.loads(pathlib.Path(b_path).read_text())
    width = max(len(k) for k in a)
    print(f"  {'bench':<{width}}  {'before':>11}  {'after':>11}  speed-up")
    for key in a:
        if key in b:
            x, y = a[key]["ns"], b[key]["ns"]
            print(f"  {key:<{width}}  {fmt_ns(x):>11}  {fmt_ns(y):>11}  {x / y if y else 0:6.2f}x")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--areas", default=",".join(AREAS))
    ap.add_argument("--smp", default="4")
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--label", default="last")
    ap.add_argument("--extra", default="", help="more run.py arguments, one string")
    ap.add_argument("--compare", nargs=2, metavar=("BEFORE", "AFTER"))
    args = ap.parse_args()
    if args.compare:
        compare(*args.compare)
        return 0
    script = []
    for run in range(args.runs):
        for area in args.areas.split(","):
            if area == "boot" and run:
                continue                    # the same every time
            script += [f"type bench {area}\\n", "until unit", f"type echo mark''{run}{area}\\n",
                       f"until mark{run}{area}"]
    script += ["type poweroff\\n"]
    extra = ["--smp", args.smp, "--mem", "2G"] + (args.extra.split() if args.extra else [])
    logs = boot_all(OUT, {args.label: (script, extra, 600)})
    log, _ = logs[args.label]
    each, rate = parse(log)
    if not each:
        print("no bench rows in the log: build/test/bench/" + args.label + ".log")
        return 1
    results = summary(each, rate)
    show(results)
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / f"{args.label}.json").write_text(json.dumps(results, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
