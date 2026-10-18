"""What the QEMU suites share: booting Axiom headless, several boots at once.

    from qemu import boot_all
    logs = boot_all(OUT, {"eight": (script, ["--smp", "8"], 120), ...})
    log, err = logs["eight"]

Each boot gets ports of its own (tools/run.py --port 0), so boots run side by
side: as many at once as there are host threads to spare for their CPUs
(--smp, 8 when not given), counting only threads that are idle when the
suite starts (AXIOM_VCPUS=N says otherwise). That limit holds across processes, so suites can
run at the same time too: each vCPU is a lock on a file in build/test/slots,
let go when the boot ends or its process dies. A boot that mostly waits (for
what is typed, for the network) can take fewer slots than it has vCPUs, since
an idle guest's CPUs sleep: a fourth element in boot_all's tuple, or slots=N. Each boot has 1 GiB unless
it asks for more (--mem). A boot whose firmware never
got as far as Axiom is booted again. AXIOM_TRACE=1 times each step of each
boot's script (tools/run.py --trace).
"""
import concurrent.futures
import ctypes
import os
import pathlib
import subprocess
import sys
import time

if os.name == "nt":
    import msvcrt
else:
    import fcntl

ROOT = pathlib.Path(__file__).resolve().parents[2]
SLOTS = ROOT / "build" / "test" / "slots"


def idle_threads():
    """How many of the host's threads are idle now (whatever else is
    running), from two samples of the system's times a second apart."""
    n = os.cpu_count() or 8
    if os.name != "nt":
        return max(0.0, n - os.getloadavg()[0])
    k32 = ctypes.windll.kernel32

    def sample():
        t = [ctypes.c_ulonglong() for _ in range(3)]      # idle, kernel (with idle), user
        k32.GetSystemTimes(*(ctypes.byref(x) for x in t))
        return [x.value for x in t]
    a = sample()
    time.sleep(1)
    b = sample()
    idle, total = b[0] - a[0], (b[1] - a[1]) + (b[2] - a[2])
    return n * idle / total if total else n


# vCPUs booted at once, at most: the host's idle threads, less a few for
# QEMU's own and for the suites, so timings inside the guests stay honest
# (tools/test/all.py measures once for all the suites it runs)
VCPUS = int(os.environ.get("AXIOM_VCPUS") or max(4, int(idle_threads()) - 6))
BOOTED = "memory: our own page tables"
# guest memory for a boot that does not say: a dozen boots of tools/run.py's
# 6 GiB each would ask the host for more than it has
MEM = "1G"


def _lock(fd):
    try:
        if os.name == "nt":
            os.lseek(fd, 0, os.SEEK_SET)
            msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
        else:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except OSError:
        return False


def _unlock(fd):
    try:
        if os.name == "nt":
            os.lseek(fd, 0, os.SEEK_SET)
            msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
        else:
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


def take(n):
    """n vCPU slots (all of them, if n is more): their locked files."""
    n = min(n, VCPUS)
    SLOTS.mkdir(parents=True, exist_ok=True)
    while True:
        got = []
        for i in range(VCPUS):
            fd = os.open(SLOTS / str(i), os.O_RDWR | os.O_CREAT)
            if _lock(fd):
                got.append(fd)
                if len(got) == n:
                    return got
            else:
                os.close(fd)
        for fd in got:
            _unlock(fd)
        time.sleep(0.1)


def give(fds):
    for fd in fds:
        _unlock(fd)


def cpus(extra):
    extra = list(extra)
    return int(extra[extra.index("--smp") + 1]) if "--smp" in extra else 8


def boot(out, name, script, *extra, timeout=60, again=True, slots=None):
    """One boot, once it has its slots (its vCPUs, or slots): (the serial
    log, run.py's stderr, seconds). Booted again if the firmware never got
    as far as Axiom, unless again is False."""
    serial = out / f"{name}.log"
    out.mkdir(parents=True, exist_ok=True)
    slots = take(slots or cpus(extra))
    start = time.monotonic()
    try:
        for attempt in range(2 if again else 1):
            proc = subprocess.run([sys.executable, str(ROOT / "tools" / "run.py"), "--headless",
                                   "--port", "0", "--timeout", str(timeout),
                                   "--serial", str(serial.relative_to(ROOT / "build")),
                                   "--script", "; ".join(script),
                                   *([] if "--mem" in extra else ["--mem", MEM]), *extra,
                                   *(["--trace"] if os.environ.get("AXIOM_TRACE") else [])],
                                  cwd=ROOT, capture_output=True, text=True, encoding="utf-8",
                                  errors="replace")
            serial.with_suffix(".err").write_text(proc.stderr, encoding="utf-8")
            try:
                log = serial.read_bytes().decode("utf-8", errors="replace").replace("\r", "")
            except OSError:
                log = ""
            if BOOTED in log:
                break
            print(f"      ({name}: the firmware never reached Axiom" +
                  ("; booting again)" if again and attempt == 0 else ")"), flush=True)
    finally:
        give(slots)
    return log, proc.stderr, time.monotonic() - start


def boot_all(out, jobs):
    """jobs: {name: (script, [run.py arguments], timeout[, slots])}, booted
    side by side -> {name: (log, stderr)}; how long each took is printed."""
    start = time.monotonic()
    with concurrent.futures.ThreadPoolExecutor(len(jobs)) as pool:
        done = dict(zip(jobs, pool.map(
            lambda name: boot(out, name, jobs[name][0], *jobs[name][1], timeout=jobs[name][2],
                              slots=(jobs[name][3:] or [None])[0]),
            jobs)))
    print("      (" + ", ".join(f"{name} {done[name][2]:.0f} s" for name in jobs) +
          f"; {time.monotonic() - start:.0f} s in all)", flush=True)
    return {name: (log, err) for name, (log, err, _) in done.items()}
