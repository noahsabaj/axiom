#!/usr/bin/env python3
"""Linux programs on Axiom, in QEMU: 'linux <program> [arguments]'.

    python tools/test/linux/run.py

Builds the Linux root (tools/mkroot.py, from WSL, unless --no-root and
build/linux is there) and a stick with it (mkstick.py --linux), boots it,
and runs in the shell:
  - /test/hello, our own static program: write, brk, an anonymous mmap,
    open and read; it exits with 7;
  - Ubuntu's own, through ld.so and glibc: true and false (0 and 1), echo,
    cat /etc/hostname, ls -la / (the links, the directories), uname -a, id,
    date (the clock, near the host's, in UTC), sha256sum (the digest as
    Python makes it), env (the environment programs start with), wc -c on a
    file of 140 KB (the bytes all there), sleep 0.3;
  - a name not in the root, said so;
  - sleep 60 stopped by ctrl+C in the shell, and another program after it.
Outputs go to build/test/linux/.
"""
import argparse
import datetime
import hashlib
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "test"))
from qemu import boot_all  # noqa: E402

OUT = ROOT / "build" / "test" / "linux"
LINUX = ROOT / "build" / "linux"
FAILS = 0


def result(ok, text):
    global FAILS
    FAILS += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + text)
    return ok


def run(cmd, name, until=None):
    """'linux cmd', marked in the log first (the shell does not echo what
    is typed), then its end said."""
    return [f"type echo -- {cmd}\\n", "wait 0.2",
            f"type linux {cmd}\\n", f"until linux: {until or name}", "wait 0.3"]


def script():
    return [
        "until log: kept in", "wait 0.5",
        *run("/test/hello", "hello", "hello exited"),
        *run("true", "true", "true exited"),
        *run("false", "false", "false exited"),
        *run("echo Hello from 'Ubuntu, unchanged'", "echo", "echo exited"),
        *run("cat /etc/hostname", "cat", "cat exited"),
        *run("ls -la /", "ls", "ls exited"),
        *run("uname -a", "uname", "uname exited"),
        *run("id", "id", "id exited"),
        *run("date -u '+date: %Y-%m-%d %H:%M:%S'", "date", "date exited"),
        *run("sha256sum /etc/hostname /etc/passwd", "sha256sum", "sha256sum exited"),
        *run("env", "env", "env exited"),
        *run("wc -c /usr/bin/ls", "wc", "wc exited"),
        *run("sleep 0.3", "sleep", "sleep exited"),
        *run("nosuch", "", "nosuch: no such program"),
        "type echo -- sleep 60\\n", "wait 0.2",
        "type linux sleep 60\\n", "wait 3", "sendkey ctrl-c", "until linux: sleep stopped",
        "wait 0.3",
        *run("echo again", "echo", "echo exited"),
        "type poweroff\\n", "ended",
    ]


def after(log, cmd):
    """What the log says after 'linux cmd', up to the next one's mark."""
    i = log.find(f"\n-- {cmd}\n")
    if i < 0:
        return ""
    j = log.find("\n-- ", i + 1)
    return log[i:j if j >= 0 else len(log)]


def ended(log, cmd, name, code):
    text = after(log, cmd)
    return result(f"linux: {name} exited with {code}" in text,
                  f"'linux {cmd}' exited with {code}")


def check(log, err):
    hello = after(log, "/test/hello")
    result("hello: a Linux program on Axiom" in hello, "hello: its first line")
    result("hello: brk and mmap work" in hello, "hello: brk and mmap")
    result("hello: /etc/hostname says axiom" in hello, "hello: open and read")
    result("FAILED" not in hello, "hello: nothing failed")
    ended(log, "/test/hello", "hello", 7)
    ended(log, "true", "true", 0)
    ended(log, "false", "false", 1)
    echo = after(log, "echo Hello from 'Ubuntu, unchanged'")
    result("\nHello from Ubuntu, unchanged\n" in echo, "echo: its arguments, quotes kept")
    ended(log, "echo Hello from 'Ubuntu, unchanged'", "echo", 0)
    result(re.search(r"^axiom$", after(log, "cat /etc/hostname"), re.M) is not None,
           "cat /etc/hostname: axiom")
    ended(log, "cat /etc/hostname", "cat", 0)
    ls = after(log, "ls -la /")
    for line in (r"^l\S+ +1 root root +7 .* bin -> usr/bin$", r"^d\S+ +\d+ root root .* etc$",
                 r"^d\S+ +\d+ root root .* usr$", r"^drwxrwxrwt .* tmp$", r"^total \d+$"):
        result(re.search(line, ls, re.M) is not None, f"ls -la /: {line}")
    ended(log, "ls -la /", "ls", 0)
    uname = after(log, "uname -a")
    result(re.search(r"^Linux axiom 6\.8\.0-axiom #1 SMP PREEMPT_DYNAMIC Axiom x86_64 .*$",
                     uname, re.M) is not None, "uname -a: Linux axiom 6.8.0-axiom ... x86_64")
    ended(log, "uname -a", "uname", 0)
    result(re.search(r"^uid=0\(root\) gid=0\(root\) groups=0\(root\)$", after(log, "id"), re.M)
           is not None, "id: uid=0(root) gid=0(root) groups=0(root)")
    ended(log, "id", "id", 0)
    m = re.search(r"^date: (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)$",
                  after(log, "date -u '+date: %Y-%m-%d %H:%M:%S'"), re.M)
    now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    off = abs((datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S") - now)
              .total_seconds()) if m else None
    result(off is not None and off < 600,
           f"date: {m.group(1) if m else 'nothing'}, the host's within 10 minutes")
    sums = after(log, "sha256sum /etc/hostname /etc/passwd")
    etc = (LINUX / "ROOT" / "etc" / "passwd").read_bytes()
    for name, data in (("/etc/hostname", b"axiom\n"), ("/etc/passwd", etc)):
        result(f"{hashlib.sha256(data).hexdigest()}  {name}" in sums,
               f"sha256sum {name}: as Python has it")
    env = after(log, "env")
    for var in ("PATH=/usr/local/bin:/usr/bin:/bin", "HOME=/root", "TERM=dumb"):
        result(f"\n{var}" in env, f"env: {var}")
    size = (LINUX / "ROOT" / "usr" / "bin" / "ls").stat().st_size
    result(f"\n{size} /usr/bin/ls\n" in after(log, "wc -c /usr/bin/ls"),
           f"wc -c /usr/bin/ls: {size}")
    ended(log, "sleep 0.3", "sleep", 0)
    result("linux: nosuch: no such program in the Linux root" in log, "a name not there: said so")
    stopped = after(log, "sleep 60")
    result("linux: sleep stopped" in stopped, "sleep 60: stopped by ctrl+C")
    result("\nagain\n" in after(log, "echo again"), "a program after it runs")
    calls = sorted(set(re.findall(r"system call (\d+) is not there yet", log)), key=int)
    print(f"      (calls not there yet: {', '.join(calls) or 'none'})")
    result("AXIOM PANIC" not in log, "no panic")
    result(not re.search(r"^\w+: (page fault|general protection)", log, re.M), "no fault")
    result("QEMU ended by itself" in err, "powered off")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-root", action="store_true",
                    help="use build/linux as it is, without WSL")
    opts = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    if not (opts.no_root and (LINUX / "META").exists()):
        subprocess.run([sys.executable, str(ROOT / "tools" / "mkroot.py")], cwd=ROOT, check=True)
    stick = OUT / "stick.img"
    subprocess.run([sys.executable, str(ROOT / "tools" / "mkstick.py"), str(stick),
                    "--linux", str(LINUX)], cwd=ROOT, check=True, capture_output=True)
    logs = boot_all(OUT, {"linux": (script(), ["--smp", "4", "--stick",
                                                stick.relative_to(ROOT).as_posix()], 300)})
    print("-- linux")
    check(*logs["linux"])
    print(f"{'all passed' if FAILS == 0 else f'{FAILS} failed'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
