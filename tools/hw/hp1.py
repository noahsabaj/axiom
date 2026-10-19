#!/usr/bin/env python3
"""Axiom on hp-1, a laptop of the fleet with no one at it, from here.

    python tools/hw/hp1.py status              what hp-1 has; changes nothing
    python tools/hw/hp1.py install             build/esp's loader and programs onto
                                               its EFI partition, and a boot entry
    python tools/hw/hp1.py run LINE...         one test run, its log printed
    python tools/hw/hp1.py run --file FILE     (the lines in a file)
    python tools/hw/hp1.py log                 AxiomLog, if a run left one
    python tools/hw/hp1.py cancel              the pending run undone

hp-1 still runs Ubuntu, and fleet reaches it there. A test run: the lines go
into the UEFI variable AxiomRun, BootNext is set to Axiom's boot entry and
hp-1 restarts. Axiom's loader finds the script and starts the TCO watchdog;
the kernel types the lines into its shell (harness.asm: also 'sleep', 'until',
'limit', 'watchdog', 'end'), puts the end of its log into the UEFI variable
AxiomLog, and restarts; BootNext is spent, so Ubuntu comes back, and the log
is read from there. A hang ends in the watchdog's reset, a panic in a restart.

Only BootNext is ever set, never BootOrder. A restart waits until no fleet
job runs on hp-1. The log is also saved to build/hw/hp1-last.log.
"""
import argparse
import pathlib
import shutil
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
STAGE = ROOT / "build" / "hw" / "hp1"
NODE = "hp-1"


def fleet(*args, timeout=600, check=True):
    proc = subprocess.run(["fleet", *args], capture_output=True, text=True, encoding="utf-8",
                          errors="replace", timeout=timeout)
    if check and proc.returncode:
        sys.exit(f"hp1.py: fleet {' '.join(args)} failed ({proc.returncode}):\n"
                 f"{proc.stdout}{proc.stderr}")
    return proc


def stage(script=None):
    """What goes to hp-1: hp1_node.py, the loader and the programs (in
    EFI/AXIOM, where the loader is too), and the run's script."""
    STAGE.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / "tools" / "hw" / "hp1_node.py", STAGE / "hp1_node.py")
    esp = ROOT / "build" / "esp" / "EFI"
    (STAGE / "EFI" / "AXIOM").mkdir(parents=True, exist_ok=True)
    for f in [esp / "BOOT" / "BOOTX64.EFI", *sorted((esp / "AXIOM").glob("*"))]:
        if f.is_file():
            to = STAGE / "EFI" / "AXIOM" / f.name
            if not to.exists() or to.read_bytes() != f.read_bytes():
                shutil.copyfile(f, to)
    (STAGE / "run.txt").write_text(script or "", encoding="utf-8", newline="\n")


def node(what, script=None, check=True):
    """hp1_node.py WHAT on hp-1, as root, in a folder with what stage() made."""
    stage(script)
    proc = fleet("run", "--on", NODE, "--dir", str(STAGE), "--name", "axiom-hp1", "--admin",
                 "--allow-battery", "--", "python3", "hp1_node.py", what, check=check)
    return proc.stdout + proc.stderr


def boot_id():
    proc = fleet("admin", NODE, "--", "cat", "/proc/sys/kernel/random/boot_id", timeout=60,
                 check=False)
    text = proc.stdout.strip().splitlines()
    return text[-1].strip() if proc.returncode == 0 and text else None


def jobs_running():
    out = fleet("jobs", "--on", NODE, timeout=120).stdout
    return [l for l in out.splitlines()[1:] if l.split()[3:4] == ["running"]]


def run(script, wait):
    busy = jobs_running()
    if busy:
        sys.exit("hp1.py: jobs run on hp-1; no restart now:\n" + "\n".join(busy))
    before = boot_id()
    if before is None:
        sys.exit("hp1.py: hp-1 does not answer")
    print(node("run", script).strip(), flush=True)
    start = time.monotonic()
    print("hp1.py: waiting for hp-1 to run Axiom and come back", flush=True)
    while time.monotonic() - start < wait:
        time.sleep(15)
        now = boot_id()
        if now and now != before:
            print(f"hp1.py: back after {time.monotonic() - start:.0f} s", flush=True)
            return log()
    sys.exit(f"hp1.py: hp-1 is not back after {wait} s")


def log():
    out = node("log", check=False)
    (ROOT / "build" / "hw").mkdir(parents=True, exist_ok=True)
    (ROOT / "build" / "hw" / "hp1-last.log").write_text(out, encoding="utf-8")
    print(out, end="")
    return 0 if "----- AxiomLog -----" in out else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("what", choices=("status", "install", "run", "log", "cancel"))
    ap.add_argument("lines", nargs="*", help="run: the script's lines")
    ap.add_argument("--file", help="run: the script, from this file")
    ap.add_argument("--wait", type=int, default=900, help="run: seconds to wait for hp-1 "
                    "to come back (900)")
    opts = ap.parse_args()
    if opts.what == "run":
        script = (pathlib.Path(opts.file).read_text(encoding="utf-8") if opts.file
                  else "".join(line + "\n" for line in opts.lines))
        if not script.strip():
            sys.exit("hp1.py: run what? Lines, or --file")
        return run(script, opts.wait)
    if opts.what == "log":
        return log()
    print(node(opts.what).strip())
    return 0


if __name__ == "__main__":
    sys.exit(main())
