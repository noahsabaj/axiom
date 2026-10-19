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
    python tools/hw/hp1.py try [--seconds S]   build/kernel.bin into the slot not kept
                                               on its EFI partition, named in
                                               AxiomTry: the next run tries it
                                               ('update keep' keeps it; S: 600)
    python tools/hw/hp1.py start [LINE...]     EFI/AXIOM/START.TXT: the lines Axiom
                                               types at every start; none: removed
    python tools/hw/hp1.py forget              AxiomTry and AxiomSlot deleted: the
                                               kernel built into the loader again
    python tools/hw/hp1.py fsck                its EFI partition checked, read only
    python tools/hw/hp1.py axiom1 [--update]   one run as axiom-1, fleet's node: see
                                               axiom1() below

axiom1 is the test before Ubuntu goes (Stage C): Axiom alone on hp-1,
fleet's node over Wi-Fi. It installs build/esp, makes START.TXT 'fleet &',
and starts tools/hw/axiom1.txt as a test run; from here, while hp-1 runs
Axiom, it reaches axiom-1 over fleet (a job, its info), and ends the run
with the job `hello axiom1-done`. With --update, the job `update
kernel.bin` instead: hp-1 restarts, and a second run is kernel A's trial,
which axiom-1's first job keeps. Afterwards the EFI partition is checked
(fsck.vfat -n), START.TXT removed and, with --update, AxiomSlot forgotten,
so later runs start what `install` puts there (--keep keeps both).

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
AXIOM1 = "axiom-1"
# what axiom1 pushes to it: a project of its own, kernel.bin for --update
PROJECT = ROOT / "build" / "hw" / "axiom1"
SCRIPT = ROOT / "tools" / "hw" / "axiom1.txt"


def fleet(*args, timeout=600, check=True):
    proc = subprocess.run(["fleet", *args], capture_output=True, text=True, encoding="utf-8",
                          errors="replace", timeout=timeout)
    if check and proc.returncode:
        sys.exit(f"hp1.py: fleet {' '.join(args)} failed ({proc.returncode}):\n"
                 f"{proc.stdout}{proc.stderr}")
    return proc


def stage(script=None, start=None):
    """What goes to hp-1: hp1_node.py, the loader and the programs (in
    EFI/AXIOM, where the loader is too), the run's script, and START.TXT's
    lines (for hp1_node.py start)."""
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
    (STAGE / "start.txt").write_text("".join(l + "\n" for l in start or []), encoding="utf-8",
                                     newline="\n")


def node(what, script=None, check=True, args=(), start=None):
    """hp1_node.py WHAT on hp-1, as root, in a folder with what stage() made."""
    stage(script, start)
    proc = fleet("run", "--on", NODE, "--dir", str(STAGE), "--name", "axiom-hp1", "--admin",
                 "--allow-battery", "--", "python3", "hp1_node.py", what, *args, check=check)
    return proc.stdout + proc.stderr


def try_kernel(seconds):
    """build/kernel.bin into the slot not kept on hp-1, for a trial at the
    next start of Axiom (hp1_node.py try)."""
    sent = STAGE / "kernel.bin"
    STAGE.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / "build" / "kernel.bin", sent)
    try:
        print(node("try", args=[str(seconds)]).strip())
    finally:
        sent.unlink(missing_ok=True)
    return 0


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


def run(script, wait, during=None):
    """One test run; during(deadline), if given, from here while hp-1 runs
    Axiom (axiom1's fleet jobs)."""
    busy = jobs_running()
    if busy:
        sys.exit("hp1.py: jobs run on hp-1; no restart now:\n" + "\n".join(busy))
    before = boot_id()
    if before is None:
        sys.exit("hp1.py: hp-1 does not answer")
    print(node("run", script).strip(), flush=True)
    start = time.monotonic()
    if during:
        during(start + wait)
    print("hp1.py: waiting for hp-1 to run Axiom and come back", flush=True)
    while time.monotonic() - start < wait:
        time.sleep(15)
        now = boot_id()
        if now and now != before:
            print(f"hp1.py: back after {time.monotonic() - start:.0f} s", flush=True)
            return log()
    sys.exit(f"hp1.py: hp-1 is not back after {wait} s")


def on_axiom1(*words, timeout=240):
    """A job on axiom-1, in its project (PROJECT, pushed) -> (ok, its output)."""
    proc = fleet("run", "--on", AXIOM1, "--dir", str(PROJECT), "--name", "axiom1",
                 "--timeout", "2m", "--", *words, timeout=timeout, check=False)
    return proc.returncode == 0, (proc.stdout + proc.stderr).strip()


def reach(deadline, word):
    """The job `hello WORD` on axiom-1, again and again until it answers ->
    its output, or None by the deadline."""
    print(f"hp1.py: waiting for {AXIOM1} to answer fleet", flush=True)
    tries, out = 0, ""
    while time.monotonic() < deadline - 60:
        tries += 1
        ok, out = on_axiom1("hello", word)
        if ok:
            print(f"hp1.py: {AXIOM1} answered (try {tries}):\n{out}", flush=True)
            return out
        time.sleep(20)
    print(f"hp1.py: {AXIOM1} never answered ({tries} tries); the last:\n{out}", flush=True)
    return None


def show_info():
    """What fleet's info says of axiom-1 (some of it)."""
    proc = fleet("nodes", "--json", timeout=300, check=False)
    try:
        nodes = json.loads(proc.stdout)
    except ValueError:
        print("hp1.py: fleet nodes --json: not JSON")
        return
    if isinstance(nodes, dict):
        nodes = nodes.get("nodes", [])
    entry = next((n for n in nodes if isinstance(n, dict) and n.get("name") == AXIOM1), {})
    info = entry.get("info") or {}
    keys = ("os_version", "cpu", "threads", "ram_gb", "disk_free_gb", "addresses", "uptime_s")
    print(f"hp1.py: {AXIOM1}: online {entry.get('online')}; " +
          ", ".join(f"{k} {info.get(k)}" for k in keys), flush=True)


def first_contact(deadline, update):
    """From here, while hp-1 runs Axiom: axiom-1 reached over fleet, then
    the run ended (`hello axiom1-done`), or, with update, a trial queued
    (`update kernel.bin`: hp-1 restarts into Ubuntu, AxiomTry pending)."""
    if reach(deadline, "axiom1-first") is None:
        return
    show_info()
    words = ("update", "kernel.bin", "600") if update else ("hello", "axiom1-done")
    ok, out = on_axiom1(*words)
    print(f"hp1.py: {' '.join(words)} on {AXIOM1}: {'ok' if ok else 'FAILED'}\n{out}", flush=True)


def trial(deadline):
    """The second run of axiom1 --update, kernel A on trial: the first job
    that reaches axiom-1 keeps it; then the run ended."""
    if reach(deadline, "axiom1-trial") is None:
        return
    show_info()
    ok, out = on_axiom1("hello", "axiom1-done")
    print(f"hp1.py: hello axiom1-done: {'ok' if ok else 'FAILED'}\n{out}", flush=True)


def axiom1(update, wait, keep):
    """hp-1 as axiom-1 for a run, or two with update (see the top)."""
    status = node("status")
    if "WIFI.KEY: not there" in status:
        sys.exit("hp1.py: no WIFI.KEY on hp-1: hp1.py wifi first")
    if "Home/fleet: node.json, cert.pem, key.pem" not in status:
        sys.exit("hp1.py: no /Home/fleet for axiom-1 on hp-1: hp1.py home first")
    print(node("install").strip(), flush=True)
    print(node("start", start=["fleet &"]).strip(), flush=True)
    PROJECT.mkdir(parents=True, exist_ok=True)
    (PROJECT / "README.txt").write_text("hp1.py axiom1's project on axiom-1\n", encoding="utf-8")
    kernel = PROJECT / "kernel.bin"
    if update:
        shutil.copyfile(ROOT / "build" / "kernel.bin", kernel)
    else:
        kernel.unlink(missing_ok=True)
    script = SCRIPT.read_text(encoding="utf-8")
    try:
        code = run(script, wait, during=lambda deadline: first_contact(deadline, update))
        print(node("fsck", check=False).strip(), flush=True)
        if update:
            if "AxiomTry: kernel " in node("status"):
                print("hp1.py: the second run: the trial", flush=True)
                code = run(script, wait, during=trial) or code
                print(node("fsck", check=False).strip(), flush=True)
            else:
                print("hp1.py: no trial pending after `update kernel.bin`: no second run")
                code = 1
    finally:
        if not keep:
            print(node("start", start=[]).strip())
            if update:
                print(node("forget").strip())
        print(node("status").strip())
    return code


def log():
    out = node("log", check=False)
    (ROOT / "build" / "hw").mkdir(parents=True, exist_ok=True)
    (ROOT / "build" / "hw" / "hp1-last.log").write_text(out, encoding="utf-8")
    print(out, end="")
    return 0 if "----- AxiomLog -----" in out else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("what", choices=("status", "install", "run", "log", "cancel", "wifi",
                                     "home", "try", "start", "forget", "fsck", "axiom1"))
    ap.add_argument("lines", nargs="*", help="run: the script's lines; start: START.TXT's")
    ap.add_argument("--update", action="store_true", help="axiom1: a new kernel over fleet, "
                    "and a second run, its trial")
    ap.add_argument("--keep", action="store_true", help="axiom1: START.TXT (and AxiomSlot) "
                    "left as the run left them")
    ap.add_argument("--file", help="run: the script, from this file")
    ap.add_argument("--seconds", type=int, default=600, help="try: how long the trial "
                    "has to be kept (600)")
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
    if opts.what == "try":
        return try_kernel(opts.seconds)
    if opts.what == "start":
        print(node("start", start=opts.lines).strip())
        return 0
    if opts.what == "axiom1":
        return axiom1(opts.update, max(opts.wait, 1200), opts.keep)
    print(node(opts.what, check=opts.what != "fsck").strip())
    return 0


if __name__ == "__main__":
    sys.exit(main())
