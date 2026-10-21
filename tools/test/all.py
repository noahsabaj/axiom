#!/usr/bin/env python3
"""Every suite in tools/test, at once.

    python tools/test/all.py [--quick] [suite ...]

Builds first, then runs each suite (or those named) side by side, each in a
process of its own; QEMU boots share the host's threads through
tools/test/qemu.py, as many vCPUs at once as the host has idle threads to
spare, so the timings inside the guests stay honest. Each
suite's output goes to build/test/<suite>.txt; the failures are printed,
and a line per suite with how long it took. A suite that passes has its disk
images deleted (tools/space.py); one that fails keeps them. --quick skips
the TCG boots.
The sbc suite is left out: Bluetooth is parked.
"""
import argparse
import concurrent.futures
import os
import pathlib
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "build" / "test"
# the slowest first, so they start first
SUITES = ["claude", "user", "desk", "settings", "browse", "rust", "masm", "sound", "linux", "store", "tcp", "net", "http", "ip6", "shell", "memory", "threads", "objects", "harness", "watchdog", "update", "fleet", "update-fleet", "battery", "nvme", "iommu", "rings", "pki",
          "tls", "tlsclient", "crypto", "wpa", "heap"]
QUICK = {"memory", "threads", "objects", "rings", "user", "nvme", "iommu", "store"}      # those that take --quick


def run(name, quick):
    start = time.monotonic()
    args = [sys.executable, str(ROOT / "tools" / "test" / name / "run.py")]
    if quick and name in QUICK:
        args.append("--quick")
    proc = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, encoding="utf-8",
                          errors="replace")
    text = proc.stdout + proc.stderr
    (OUT / f"{name}.txt").write_text(text, encoding="utf-8")
    return proc.returncode, text, time.monotonic() - start


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true", help="skip the TCG boots")
    ap.add_argument("suites", nargs="*", help=f"some of: {' '.join(SUITES)}")
    opts = ap.parse_args()
    names = opts.suites or SUITES
    unknown = [n for n in names if n not in SUITES]
    if unknown:
        sys.exit(f"no suite {' '.join(unknown)}; there are: {' '.join(SUITES)}")
    OUT.mkdir(parents=True, exist_ok=True)
    start = time.monotonic()
    build = subprocess.run([sys.executable, str(ROOT / "tools" / "build.py")], cwd=ROOT,
                           capture_output=True, text=True)
    if build.returncode:
        print(build.stdout + build.stderr)
        sys.exit("the build failed")
    sys.path.insert(0, str(ROOT / "tools" / "test"))
    import qemu                                         # measures the host once
    os.environ["AXIOM_VCPUS"] = str(qemu.VCPUS)
    print(f"QEMU boots: {qemu.VCPUS} vCPUs at once, at most", flush=True)
    failed = []
    with concurrent.futures.ThreadPoolExecutor(len(names)) as pool:
        jobs = {pool.submit(run, n, opts.quick): n for n in names}
        for job in concurrent.futures.as_completed(jobs):
            name = jobs[job]
            code, text, took = job.result()
            fails = [l for l in text.splitlines() if l.startswith("FAIL")]
            last = text.strip().splitlines()[-1] if text.strip() else "no output"
            print(f"{'ok  ' if code == 0 else 'FAIL'} {name:10} {took:5.0f} s  {last}",
                  flush=True)
            for line in fails[:20]:
                print(f"       {line}")
            if code:
                failed.append(name)
            else:
                # it passed: its disk images are made again on the next run
                for img in (OUT / name).rglob("*.img"):
                    img.unlink(missing_ok=True)
    print(f"{len(names) - len(failed)} of {len(names)} suites passed in "
          f"{time.monotonic() - start:.0f} s" +
          (f"; failed: {' '.join(failed)} (build/test/<suite>.txt)" if failed else ""))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
