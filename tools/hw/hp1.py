#!/usr/bin/env python3
"""Axiom on hp-1, a laptop of the fleet with no one at it, from here.

    python tools/hw/hp1.py status              what hp-1 has; changes nothing
    python tools/hw/hp1.py install             build/esp's loader and programs onto
                                               its EFI partition, and a boot entry
    python tools/hw/hp1.py run LINE...         one test run, its log printed
    python tools/hw/hp1.py run --file FILE     (the lines in a file)
    python tools/hw/hp1.py log                 AxiomLog, if a run left one
    python tools/hw/hp1.py cancel              the pending run undone
    python tools/hw/hp1.py wifi                the Wi-Fi network hp-1 is on, for
                                               Axiom: its key (PMK) made on hp-1
                                               from Ubuntu's saved passphrase, into
                                               EFI/AXIOM/WIFI.KEY; neither printed
    python tools/hw/hp1.py home [--file DIR]   what `fleet add axiom-1 --self-managed`
                                               made (build/hw/axiom-1) onto its EFI
                                               partition as /Home/fleet, for
                                               FLEET.AXE; not printed

hp-1 still runs Ubuntu, and fleet reaches it there. A test run: the lines go
into the UEFI variable AxiomRun, BootNext is set to Axiom's boot entry and
hp-1 restarts. Axiom's loader finds the script and starts the TCO watchdog;
the kernel types the lines into its shell (harness.asm: also 'sleep', 'until',
'limit', 'watchdog', 'end'), puts the end of its log into the UEFI variable
AxiomLog, and restarts; BootNext is spent, so Ubuntu comes back, and the log
is read from there. A hang ends in the watchdog's reset, a panic in a restart.

Only BootNext is ever set, never BootOrder. A restart waits until no fleet
job starts or runs on hp-1, and none waiting in fleet's queue may go there.
The log is also saved to build/hw/hp1-last.log.
"""
import argparse
import json
import pathlib
import shutil
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
STAGE = ROOT / "build" / "hw" / "hp1"
# the Wi-Fi card's firmware, if it is here: Realtek's rtw88/rtw8821c_fw.bin
# from linux-firmware (not in this tree); src/kernel/rtwfw.asm reads it
FIRMWARE = ROOT / "build" / "hw" / "RTW8821C.BIN"
NODE = "hp-1"
# axiom-1, fleet's node that hp-1 becomes: `fleet add axiom-1 --self-managed
# --out build/hw/axiom-1` makes these, for sdk/rust/fleet's /Home/fleet
AXIOM_1 = ROOT / "build" / "hw" / "axiom-1"
HOME_FILES = ("node.json", "cert.pem", "key.pem")


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
    for f in [esp / "BOOT" / "BOOTX64.EFI", *sorted((esp / "AXIOM").glob("*")), FIRMWARE]:
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


def home(src):
    """What `fleet add axiom-1 --self-managed --out SRC` made, onto hp-1's EFI
    system partition as /Home/fleet (hp1_node.py home); the staged copy
    deleted here and there. Nothing of it is printed."""
    src = pathlib.Path(src)
    missing = [n for n in HOME_FILES if not (src / n).is_file()]
    if missing:
        sys.exit(f"hp1.py: {src} has no {', '.join(missing)}")
    to = STAGE / "Home" / "fleet"
    to.mkdir(parents=True, exist_ok=True)
    try:
        for n in HOME_FILES:
            shutil.copyfile(src / n, to / n)
        print(node("home").strip())
    finally:
        shutil.rmtree(STAGE / "Home", ignore_errors=True)
    return 0


def boot_id():
    proc = fleet("admin", NODE, "--", "cat", "/proc/sys/kernel/random/boot_id", timeout=60,
                 check=False)
    text = proc.stdout.strip().splitlines()
    return text[-1].strip() if proc.returncode == 0 and text else None


def jobs_running():
    """What a restart would lose: jobs starting or running on hp-1, and jobs
    waiting in fleet's queue that may go there (the hive would start them)."""
    out = fleet("jobs", "--on", NODE, timeout=120).stdout
    busy = [l for l in out.splitlines()[1:] if l.split()[3:4] in (["running"], ["starting"])]
    queue = json.loads(fleet("queue", "--json", timeout=120).stdout or "{}")
    for job in queue.get("jobs", []):
        if job.get("state") in ("done", "failed", "stopped", "lost", "cancelled"):
            continue
        if job.get("node") == NODE or NODE in (job.get("nodes") or []):
            busy.append(f"queued for {NODE}: {job.get('id')} ({job.get('state')})")
    return busy


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
    ap.add_argument("what", choices=("status", "install", "run", "log", "cancel", "wifi",
                                     "home"))
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
    if opts.what == "home":
        return home(opts.file or AXIOM_1)
    print(node(opts.what).strip())
    return 0


if __name__ == "__main__":
    sys.exit(main())
