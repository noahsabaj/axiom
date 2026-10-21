#!/usr/bin/env python3
"""A new kernel over fleet (FLEET.AXE's update job; update.asm; start.asm)
in QEMU: what lets hp-1, as axiom-1, take a new Axiom with no one at it.

    python tools/test/update-fleet/run.py

A stick holds /Home/fleet (as the fleet test's) and /EFI/AXIOM/START.TXT,
'fleet &': each start runs the node with no one typing. Four boots, one
after another, on that stick and one file of firmware variables:
  - push: a client (the fleet test's, speaking fleet's wire over TLS)
    pushes build/kernel.bin into a project, and the job `update kernel.bin
    60` there puts it in slot A and restarts the machine (wrong ones
    refused first: no such file, not a kernel, a trial of 5 s);
  - trial: kernel A on trial; the client's hello keeps it; info says so;
    then `update kernel.bin 30` again, into slot B;
  - lapse: kernel B on trial, and no client: 30 s on, a restart;
  - back: kernel A again, B given up; the client's info says kernel A.
    Then hp-1's way, tools/hw/axiom1.txt as hp1.py axiom1 --update runs
    it, as test runs (harness.asm), queued for the next start:
  - run1: the run waits for fleet; the client reaches it, and `update
    kernel.bin 60` restarts it, the run's log kept (AxiomLog). (On hp-1
    Ubuntu starts next, and queues the trial's run; here run1 queues it.)
  - run2: kernel B's trial, in a run: the client's first job keeps it, and
    `hello axiom1-done` ends the run;
  - after: 'harness log' says so, and 'update' that kernel B is kept.
Skipped (passing) if there is no nightly toolchain. Outputs go to
build/test/update-fleet/.
"""
import hashlib
import importlib.util
import json
import pathlib
import subprocess
import sys
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "test"))
sys.path.insert(0, str(ROOT / "tools"))
from qemu import boot  # noqa: E402
import mkstick  # noqa: E402

spec = importlib.util.spec_from_file_location("fleet_test", ROOT / "tools" / "test" / "fleet" / "run.py")
ft = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ft)

OUT = ROOT / "build" / "test" / "update-fleet"
VARS = OUT / "vars.fd"
STICK = OUT / "stick.img"
FAILS = 0
NAME = "axiom-update"
T0 = 1_790_000_000_000_000_000
found = {}                              # what each boot's client found


def result(ok, text):
    global FAILS
    FAILS += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + text)
    return ok


def axiom1_lines():
    """tools/hw/axiom1.txt's lines, comments out."""
    text = (ROOT / "tools" / "hw" / "axiom1.txt").read_text(encoding="utf-8")
    return [l.strip() for l in text.splitlines() if l.strip() and not l.strip().startswith("#")]


def queue(lines):
    """What the boot's script types to queue a test run of these lines."""
    script = ["type harness clear\\n", "until are gone"]
    for line in lines:
        script += [f"type harness queue {line}\\n", "until of script"]
    return script


def listening(log_path, started):
    return ft.wait_for(log_path, started, f"fleet: node {NAME} listening", 120)


def update(c, job, *argv):
    """The job `update ARGV` in the project -> (its start's answer, its log, its end)."""
    start = c.ask("start", job=job, project="os", argv=["update", *argv], env={})[0]
    text, end = c.log(job)
    return start, text.decode(errors="replace"), end.get("job", {})


def client_push(log_path, started, pin):
    r = found["push"] = {}
    if not listening(log_path, started):
        r["error"] = "the node never listened"
        return
    try:
        c = ft.Conn(pin)
        r["info"] = c.ask("info")[0]
        kernel = (ROOT / "build" / "kernel.bin").read_bytes()
        r["put"] = c.put("os", {"kernel.bin": (kernel, T0), "a.txt": (b"not a kernel", T0)})
        r["missing"] = update(c, "u-missing", "nothing.bin")
        r["not kernel"] = update(c, "u-text", "a.txt")
        r["short"] = update(c, "u-short", "kernel.bin", "5")
        r["update"] = update(c, "u1", "kernel.bin", "60")
        c.close()
    except Exception as e:  # noqa: BLE001
        r["error"] = f"{type(e).__name__}: {e}"


def client_trial(log_path, started, pin):
    r = found["trial"] = {}
    if not ft.wait_for(log_path, started, "is on trial: the first client to reach this node keeps it", 120):
        r["error"] = "the node never said it was on trial"
        return
    try:
        c = ft.Conn(pin)
        r["kept"] = ft.wait_for(log_path, started, "fleet: the kernel on trial is kept", 30)
        r["info"] = c.ask("info")[0]
        r["update"] = update(c, "u2", "kernel.bin", "30")
        c.close()
    except Exception as e:  # noqa: BLE001
        r["error"] = f"{type(e).__name__}: {e}"


def client_back(log_path, started, pin):
    r = found["back"] = {}
    if not listening(log_path, started):
        r["error"] = "the node never listened"
        return
    try:
        c = ft.Conn(pin)
        r["info"] = c.ask("info")[0]
        r["jobs"] = c.ask("jobs", ids=["u1", "u2"])[0]
        c.ask("start", job="bye", project="os", argv=["hello"], env={})     # (the boot's script waits for it)
        c.close()
    except Exception as e:  # noqa: BLE001
        r["error"] = f"{type(e).__name__}: {e}"


def job(c, name, *argv, project="axiom1"):
    """A job in hp1.py axiom1's project -> (its log, its end)."""
    c.ask("start", job=name, project=project, argv=list(argv), env={})
    text, end = c.log(name)
    return text.decode(errors="replace"), end.get("job", {})


def client_run1(log_path, started, pin):
    """As hp1.py axiom1 --update's first_contact: a job, info, the update."""
    r = found["run1"] = {}
    if not listening(log_path, started):
        r["error"] = "the node never listened"
        return
    try:
        c = ft.Conn(pin)
        kernel = (ROOT / "build" / "kernel.bin").read_bytes()      # (fleet run --dir pushes first)
        r["put"] = c.put("axiom1", {"README.txt": (b"axiom1\n", T0), "kernel.bin": (kernel, T0)})
        r["first"] = job(c, "a1", "hello", "axiom1-first")
        r["info"] = c.ask("info")[0]
        r["update"] = job(c, "a2", "update", "kernel.bin", "60")
        c.close()
    except Exception as e:  # noqa: BLE001
        r["error"] = f"{type(e).__name__}: {e}"


def client_run2(log_path, started, pin):
    """As hp1.py axiom1 --update's trial: the first job keeps it; the run ended."""
    r = found["run2"] = {}
    if not listening(log_path, started):
        r["error"] = "the node never listened"
        return
    try:
        c = ft.Conn(pin)
        r["trial"] = job(c, "a3", "hello", "axiom1-trial")
        r["info"] = c.ask("info")[0]
        r["done"] = job(c, "a4", "hello", "axiom1-done")
        c.close()
    except Exception as e:  # noqa: BLE001
        r["error"] = f"{type(e).__name__}: {e}"


def run(name, script, client, pin, args, timeout):
    log_path = OUT / f"{name}.log"
    log_path.unlink(missing_ok=True)
    started = time.time()
    t = None
    if client:
        t = threading.Thread(target=client, args=(log_path, started, pin), daemon=True)
        t.start()
    log, err, took = boot(OUT, name, script, *args, timeout=timeout, again=False, slots=1)
    ended = "ended by itself" in err
    print(f"      ({name}: {took:.0f} s{', QEMU ended by itself' if ended else ''})", flush=True)
    if t:
        t.join(5)
    return log, ended


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    built = subprocess.run([sys.executable, str(ROOT / "tools" / "rust.py")], cwd=ROOT,
                           capture_output=True, text=True)
    if built.returncode == 3:
        print("SKIP " + built.stdout.strip())
        print("all passed (skipped)")
        return 0
    if built.returncode:
        print(built.stdout + built.stderr)
        print("FAIL the Rust programs did not build")
        return 1
    ft.OUT, ft.NAME = OUT, NAME
    key, cert, pin = ft.identity()
    config = {"name": NAME, "port": ft.PORT, "self_managed": True,
              "clients": [{"name": "test-host", "token_sha256": hashlib.sha256(ft.TOKEN.encode()).hexdigest()}],
              "allow": ["10.0.2.0/24"]}
    VARS.unlink(missing_ok=True)
    mkstick.build(STICK, 0x55504454, extra={
        "Home": {"fleet": {"node.json": json.dumps(config).encode(), "cert.pem": cert, "key.pem": key}},
        "EFI": {"AXIOM": {"START.TXT": b"# axiom-1: fleet's node, at each start\r\nfleet &\r\n"}}})
    (OUT / "key.pem").unlink()
    fwd = f"user,hostfwd=tcp:127.0.0.1:{ft.FORWARD}-:{ft.PORT}"
    args = ["--smp", "2", "--nic", "rtl8139", "--netdev", fwd, "--vars", str(VARS),
            "--stick", STICK.relative_to(ROOT).as_posix()]

    log, ended = run("push", ["until update: the machine restarts in", "ended"], client_push, pin, args, 150)
    r = found.get("push", {})
    result("error" not in r, f"push: the client: {r.get('error', 'no exceptions')}")
    at = log.find("start: vol0:/EFI/AXIOM/START.TXT")
    result(0 <= at < log.find(f"fleet: node {NAME} listening"),
           "START.TXT read at the start, and its 'fleet &' run")
    result(r.get("info", {}).get("os_version") == "Axiom",
           f"info: the kernel built into the loader ({r.get('info', {}).get('os_version')!r})")
    for key, why in (("missing", "no such file"), ("not kernel", "a file that is not a kernel"),
                     ("short", "a trial of 5 s")):
        _, text, job = r.get(key, ({}, "", {}))
        result(job.get("state") == "failed" and job.get("exit") == 1 and "fleet: " in text,
               f"update refused: {why} ({text.strip()[:90]!r})")
    start, text, job = r.get("update", ({}, "", {}))
    result(start.get("job") == "u1" and job.get("state") == "done" and job.get("exit") == 0
           and "kernel.bin is kernel A, tried at the next start" in text,
           f"`update kernel.bin 60`: done ({text.strip()[:100]!r})")
    result("update: the machine restarts in 10 s, for the trial" in log and ended,
           "then the machine restarts, by itself")

    log, ended = run("trial", ["until fleet: the kernel on trial is kept", "until update: the machine restarts in",
                               "ended"], client_trial, pin, args, 150)
    r = found.get("trial", {})
    result("error" not in r, f"trial: the client: {r.get('error', 'no exceptions')}")
    result("update: this is kernel A, on trial" in log and "otherwise in 60 s" in log,
           "kernel A starts on trial, for 60 s")
    result(r.get("kept") and "update: kernel A is kept" in log,
           "the client's hello keeps it (AxiomSlot)")
    result(r.get("info", {}).get("os_version") == "Axiom (kernel A)",
           f"info: kernel A, kept ({r.get('info', {}).get('os_version')!r})")
    _, text, job = r.get("update", ({}, "", {}))
    result(job.get("state") == "done" and "is kernel B, tried at the next start" in text,
           f"`update kernel.bin 30` there: slot B ({text.strip()[:80]!r})")
    result(ended, "and the machine restarts")

    log, ended = run("lapse", ["until update: this is kernel B, on trial", "ended"], None, pin, args, 150)
    result("update: this is kernel B, on trial" in log, "kernel B starts on trial")
    result("fleet: kernel B is on trial" in log and "is kept" not in log,
           "fleet runs, and no client reaches it")
    result("update: kernel B was not kept within 30 s; the machine restarts, into kernel A" in log and ended,
           "30 s on, the machine restarts into kernel A")

    lines = axiom1_lines()
    run1 = [f"harness queue {l}" for l in lines] + lines     # (run2's queued by run1, as hp-1's Ubuntu would)
    log, ended = run("back", ["until fleet: job bye ended", *queue(run1), "type reboot\\n", "ended"],
                     client_back, pin, args, 150)
    r = found.get("back", {})
    result("error" not in r, f"back: the client: {r.get('error', 'no exceptions')}")
    result("update: this is kernel A\n" in log and "update: kernel B was tried and not kept" in log,
           "kernel A again; B was given up")
    result(r.get("info", {}).get("os_version") == "Axiom (kernel A)",
           f"info: kernel A ({r.get('info', {}).get('os_version')!r})")
    jobs = {j["id"]: j["state"] for j in r.get("jobs", {}).get("jobs", [])}
    result(jobs == {"u1": "done", "u2": "done"}, f"the update jobs' records kept: {jobs}")
    result(ended, "tools/hw/axiom1.txt queued as a test run; 'reboot' ends QEMU")

    log, ended = run("run1", ["until update: restarting, for the trial", "ended"], client_run1, pin, args, 200)
    r = found.get("run1", {})
    result("error" not in r, f"run1: the client: {r.get('error', 'no exceptions')}")
    at = log.find("harness: a test run")
    result(0 <= at < log.find(f"fleet: node {NAME} listening"), "a test run, and START.TXT's fleet in it")
    text, end = r.get("first", ("", {}))
    result(end.get("state") == "done" and "axiom1-first" in text, f"hello axiom1-first: done ({text.strip()[:60]!r})")
    result(r.get("info", {}).get("os_version") == "Axiom (kernel A)",
           f"info: kernel A ({r.get('info', {}).get('os_version')!r})")
    text, end = r.get("update", ("", {}))
    result(end.get("state") == "done" and "is kernel B, tried at the next start" in text,
           f"`update kernel.bin 60`: slot B ({text.strip()[:70]!r})")
    result("update: restarting, for the trial" in log and "AxiomLog" in log.split("restarting, for the trial")[-1]
           and ended, "the restart keeps the run's log (AxiomLog), as the run's end would")

    log, ended = run("run2", ["until harness: the run is over", "ended"], client_run2, pin, args, 300)
    r = found.get("run2", {})
    result("error" not in r, f"run2: the client: {r.get('error', 'no exceptions')}")
    result("harness: a test run" in log and "update: this is kernel B, on trial" in log,
           "the trial's start is a test run too")
    result("fleet: the kernel on trial is kept" in log and "update: kernel B is kept" in log,
           "the client's first job keeps kernel B")
    result(r.get("info", {}).get("os_version") == "Axiom (kernel B)",
           f"info: kernel B ({r.get('info', {}).get('os_version')!r})")
    text, end = r.get("done", ("", {}))
    result(end.get("state") == "done" and "harness: the run is over" in log and ended,
           "`hello axiom1-done` ends the run, and the machine restarts")

    log, ended = run("after", ["until update: this is", "type harness log\\n", "until the end of the last run",
                               "type update\\n", "until (AxiomSlot)", "type poweroff\\n", "ended"],
                     None, pin, args, 150)
    result("update: this is kernel B\n" in log and "update: kept: kernel B" in log,
           "the start after: kernel B, kept")
    old = log[log.find("harness: the last run's log"):]
    result("update: kernel B is kept" in old and "hello axiom1-done" in old,
           "'harness log' shows the trial's run")
    result(ended, "'poweroff' ends QEMU")

    print(f"{'all passed' if not FAILS else f'{FAILS} FAILED'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
