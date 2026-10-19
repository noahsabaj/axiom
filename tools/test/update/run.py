#!/usr/bin/env python3
"""A/B updates (update.asm, the loader's find_slot) in QEMU.

    python tools/test/update/run.py

Boots a stick image of build/esp (build it first) nine times, one after
another, on one file of firmware variables, as a machine keeps them across
restarts. The stick holds NEW.BIN, a copy of build/kernel.bin:
  - 'update try NEW.BIN 30' puts it in slot A; the next start is its trial,
    and 'update keep' there keeps it (AxiomSlot): the start after uses it;
  - tried in slot B and not kept, the trial ends in a restart after 30 s,
    and the start after is kernel A again; so after a panic on trial;
  - B's file damaged: its trial passed over, for A; A's damaged too: the
    kernel built into the loader.
Outputs go to build/test/update/.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "test"))
sys.path.insert(0, str(ROOT / "tools"))
import fat32  # noqa: E402
from qemu import boot  # noqa: E402

OUT = ROOT / "build" / "test" / "update"
VARS = OUT / "vars.fd"
STICK = OUT / "stick.img"
FAILS = 0
UP = "until is the current volume"


def result(ok, text):
    global FAILS
    FAILS += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + text)
    return ok


def run(name, script, timeout=60):
    log, err, took = boot(OUT, name, script, "--smp", "2", "--vars", str(VARS),
                          "--stick", STICK.relative_to(ROOT).as_posix(),
                          timeout=timeout, again=False)
    ended = "ended by itself" in err
    print(f"      ({name}: {took:.0f} s{', QEMU ended by itself' if ended else ''})", flush=True)
    return log, ended


def damage(name):
    """A byte of /EFI/AXIOM/<name> on the stick flipped, past its header."""
    img = bytearray(STICK.read_bytes())
    _, first, last, _ = fat32.read_gpt(img)[0]
    fs = fat32.Fat32(img, first, last - first + 1).mount()
    c = fs.root
    for part in ("EFI", "AXIOM", name):
        c = next(e for e in fs.listdir(c)[0] if e["name"].upper() == part)["cluster"]
    chain = fs.chain(c)
    at = fs.coff(chain[len(chain) // 2])
    img[at] ^= 0xFF
    STICK.write_bytes(img)


def try_next(slot, seconds=30):
    return [f"type update try NEW.BIN {seconds}\\n", "until the next start tries it",
            "type update\\n", "until (AxiomTry)", "type reboot\\n", "ended"]


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    VARS.unlink(missing_ok=True)
    subprocess.run([sys.executable, str(ROOT / "tools" / "mkstick.py"), str(STICK),
                    "--file", f"NEW.BIN={ROOT / 'build' / 'kernel.bin'}"],
                   cwd=ROOT, check=True, capture_output=True)

    log, ended = run("first", [UP, "type update\\n", "until (AxiomSlot)",
                               "type update keep\\n", "until update keep:",
                               "type update try NEW.BIN 5\\n", "until usage: update try",
                               "type update try EFI/BOOT/BOOTX64.EFI\\n", "until not a kernel.bin",
                               *try_next("A")])
    result("update: this is the kernel built into the loader" in log and
           "update: none kept (AxiomSlot)" in log, "first start: the built-in kernel, none kept")
    result("update keep: only on trial" in log, "'update keep' off trial is refused")
    result("usage: update try" in log, "a trial of 5 s is refused")
    result("update: that is not a kernel.bin" in log, "a file that is not a kernel is refused")
    result("into kernel A (vol" in log and "the next start tries kernel A" in log,
           "'update try NEW.BIN 30' writes slot A and names it in AxiomTry")
    result(ended, "then 'reboot' ends QEMU")

    log, ended = run("trial", ["until update: this is kernel A, on trial", "type update\\n",
                               "until (AxiomSlot)", "type update keep\\n", "until is kept",
                               "type update\\n", "until (AxiomSlot)", "type reboot\\n", "ended"])
    result("update: this is kernel A, on trial: 'update keep' keeps it; otherwise in 30 s" in log,
           "the loader started kernel A from its slot, on trial for 30 s")
    result("the TCO watchdog (I/O 660) restarts the machine" in log,
           "and started QEMU's TCO watchdog for it")
    result("update: kernel A is kept" in log and "the watchdog is stopped" in log,
           "'update keep' keeps it, and stops the watchdog")
    result("update: kept: kernel A" in log, "'update' says kernel A is kept")
    result(ended, "then 'reboot' ends QEMU")

    log, ended = run("kept", ["until update: this is", *try_next("B")])
    result("update: this is kernel A\n" in log and "on trial" not in log.split("update try")[0],
           "the next start is kernel A, kept, not on trial")
    result("into kernel B (vol" in log, "the next trial goes into slot B")
    result(ended, "then 'reboot' ends QEMU")

    log, ended = run("expire", ["until update: this is kernel B, on trial", "ended"], timeout=120)
    result("update: this is kernel B, on trial" in log, "kernel B starts on trial")
    result("update: kernel B was not kept within 30 s; the machine restarts, into kernel A" in log,
           "not kept within 30 s, it says so")
    result("goes into AxiomLog" in log, "the end of its log goes into AxiomLog")
    result(ended, "and the machine restarts (QEMU ends)")

    log, ended = run("back", ["until update: this is", "type harness log\\n",
                              "until the end of the last run", *try_next("B", 600)])
    result("update: kernel B was tried and not kept" in log and "update: this is kernel A\n" in log,
           "the start after is kernel A, and says B was not kept")
    old = log[log.find("harness: the last run's log"):]
    result("update: kernel B was not kept within 30 s" in old,
           "'harness log' there shows how the trial ended")
    result(ended, "kernel B queued again; 'reboot' ends QEMU")

    log, ended = run("crash", ["until update: this is kernel B, on trial", "type panic null\\n",
                               "ended"])
    result("otherwise in 600 s" in log, "kernel B on trial, for 600 s")
    result("AXIOM PANIC" in log and "goes into AxiomLog" in log,
           "a panic on trial: its report goes into AxiomLog")
    result(ended, "and the machine restarts")

    log, ended = run("after", ["until update: this is", *try_next("B")])
    result("update: kernel B was tried and not kept" in log and "update: this is kernel A\n" in log,
           "the start after the panic is kernel A again")
    result(ended, "kernel B queued again; 'reboot' ends QEMU")

    damage("KERNEL.B")
    log, ended = run("damaged", ["until update: this is", "type poweroff\\n", "ended"])
    result("update: kernel B, to be tried, was not started: its file is damaged" in log,
           "B's file damaged: its trial is passed over")
    result("update: this is kernel A\n" in log, "for kernel A, kept")
    result(ended, "'poweroff' ends QEMU")

    damage("KERNEL.A")
    log, ended = run("factory", ["until update: this is", "type poweroff\\n", "ended"])
    result("update: kernel A, the one kept, was not started: its file is damaged" in log,
           "A's file damaged too: passed over")
    result("update: this is the kernel built into the loader" in log,
           "for the kernel built into the loader")
    result(ended, "'poweroff' ends QEMU")

    print(f"{'all passed' if not FAILS else f'{FAILS} FAILED'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
