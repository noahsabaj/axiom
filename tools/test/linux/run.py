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
  - /test/threads, ours in C through glibc and libpthread (threads.c):
    mutexes, TLS, condition variables, timed waits, many threads, signal
    handlers with their own SIMD state, sigaltstack, blocked and pending
    signals, kill, a SIGSEGV handler leaving by siglongjmp, a sleep cut
    short (EINTR), a join made again (SA_RESTART), sigsuspend; then abort
    (SIGABRT), a fault with no handler (SIGSEGV), the last thread's exit
    after main's pthread_exit, and exit from a thread while main joins;
  - sleep 60 ended by ctrl+C (SIGINT, the terminal's), a program ignoring
    SIGINT ended by ctrl+backslash (SIGQUIT), and another program after them;
  - /test/tty, ours in C (tty.c): the terminal as a program has it, a tty
    with termios, its size, a process group, xterm's answers to questions
    (the cursor, wide characters, DA, DECRQM, the size, OSC colors), the
    alternate screen, VMIN and VTIME, poll, select, O_NONBLOCK, SIGWINCH;
    then keys typed: a line edited (a backspace), an arrow plain and in
    DECCKM, ctrl+C raw and as SIGINT, ctrl+D;
  - /test/tty draw, the screen drawn on with escape sequences (places, SGR,
    DEC line drawing, deleted and inserted characters, an erased line end,
    the alternate screen left again, UTF-8, a line wrapped), then the
    shell's 'screen' saying what the window shows;
  - Ubuntu's terminal programs, through libtinfo and the root's terminfo:
    stty size, tput cols, stty -a, clear, and less on a file, left with q.
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
    return [f'type echo -- "{cmd}"\\n', "wait 0.2",     # quoted: the mark keeps its quotes
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
        *run("/test/threads", "threads", "threads exited"),
        *run("/test/threads abort", "threads", "threads ended"),
        *run("/test/threads segv", "threads", "threads ended"),
        *run("/test/threads lastexit", "threads", "threads exited"),
        *run("/test/threads exitgroup", "threads", "threads exited"),
        "type echo -- sleep 60\\n", "wait 0.2",
        "type linux sleep 60\\n", "wait 3", "sendkey ctrl-c", "until linux: sleep ended",
        "wait 0.3",
        "type echo -- /test/threads nointr\\n", "wait 0.2",
        "type linux /test/threads nointr\\n", "until ignoring SIGINT", "wait 0.5",
        "sendkey ctrl-c", "wait 1", "sendkey ctrl-backslash", "until linux: threads ended",
        "wait 0.3",
        *run("echo again", "echo", "echo exited"),
        "type echo -- /test/tty\\n", "wait 0.2",
        "type linux /test/tty\\n", "until tty: press a line", "wait 0.3",
        "type abx\\x7fc\\n", "until tty: press up", "wait 0.3",
        "sendkey up", "until tty: press up again", "wait 0.3",
        "sendkey up", "until tty: press ctrl+C as a byte", "wait 0.3",
        "sendkey ctrl-c", "until tty: press ctrl+C for SIGINT", "wait 0.3",
        "sendkey ctrl-c", "until tty: press ctrl+D", "wait 0.3",
        "sendkey ctrl-d", "until linux: tty exited", "wait 0.3",
        "type echo -- /test/tty draw\\n", "wait 0.2",
        "type linux /test/tty draw\\n", "until linux: tty exited", "wait 0.3",
        "type screen\\n", "until | cursor", "wait 0.3",
        *run("stty size", "stty", "stty exited"),
        *run("tput cols", "tput", "tput exited"),
        *run("stty -a", "stty", "stty exited"),
        *run("clear", "clear", "clear exited"),
        "type echo -- less /etc/passwd\\n", "wait 0.2",
        "type linux less /etc/passwd\\n", "wait 3", "type q", "until linux: less exited",
        "wait 0.3",
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
    for var in ("PATH=/usr/local/bin:/usr/bin:/bin", "HOME=/root", "TERM=xterm-256color",
                "COLORTERM=truecolor"):
        result(f"\n{var}" in env, f"env: {var}")
    size = (LINUX / "ROOT" / "usr" / "bin" / "ls").stat().st_size
    result(f"\n{size} /usr/bin/ls\n" in after(log, "wc -c /usr/bin/ls"),
           f"wc -c /usr/bin/ls: {size}")
    ended(log, "sleep 0.3", "sleep", 0)
    result("linux: nosuch: no such program in the Linux root" in log, "a name not there: said so")
    threads = after(log, "/test/threads")
    for name in ("mutex", "tls", "gettid", "cond", "timedwait", "many", "handler", "fpstate",
                 "sigaltstack", "blocked", "kill", "ignored", "sigsegv", "eintr", "restart",
                 "sigsuspend"):
        m = re.search(rf"^(ok|FAIL) {name}\b.*$", threads, re.M)
        result(m is not None and m.group(1) == "ok", f"threads: {m.group(0) if m else name + ' not said'}")
    result("\nthreads: all ok\n" in threads, "threads: all ok")
    ended(log, "/test/threads", "threads", 0)
    result("linux: threads ended by signal 6" in after(log, "/test/threads abort"),
           "threads abort: ended by SIGABRT")
    segv = after(log, "/test/threads segv")
    result("linux: threads ended by signal 11" in segv, "threads segv: ended by SIGSEGV")
    last = after(log, "/test/threads lastexit")
    result("\nlast thread\n" in last, "threads lastexit: the last thread ran on")
    ended(log, "/test/threads lastexit", "threads", 0)
    group = after(log, "/test/threads exitgroup")
    result("not expected" not in group, "threads exitgroup: the join never returned")
    ended(log, "/test/threads exitgroup", "threads", 3)
    result("linux: sleep ended by signal 2" in after(log, "sleep 60"), "sleep 60: ctrl+C, SIGINT")
    nointr = after(log, "/test/threads nointr")
    result("linux: threads ended by signal 3" in nointr and "not expected" not in nointr,
           "SIGINT ignored: ctrl+backslash ends it (SIGQUIT)")
    result("\nagain\n" in after(log, "echo again"), "a program after them runs")
    tty = after(log, "/test/tty")
    for name in ("isatty", "winsize", "termios", "pgrp", "dsr", "cursor", "wide", "da", "decrqm",
                 "size", "altscreen", "osc", "vmin0", "vtime", "poll", "pollout", "select",
                 "nonblock", "sigwinch", "line", "arrow", "decckm", "rawctrlc", "sigint", "eof"):
        m = re.search(rf"^(ok|FAIL) {name}\b.*$", tty, re.M)
        result(m is not None and m.group(1) == "ok", f"tty: {m.group(0) if m else name + ' not said'}")
    result("\ntty: all ok\n" in tty, "tty: all ok")
    ended(log, "/test/tty", "tty", 0)
    draw = after(log, "/test/tty draw")
    rows = re.findall(r"^\| ?(.*)$", draw, re.M)
    rows = [r for r in rows if not r.startswith("cursor ")]
    want = {3: "    placed at 3,5 red", 5: "┌──┐", 6: "│  │",
            7: "└──┘", 8: "abef", 9: "x yz", 10: "12",
            11: "utf8: é ❯ * ● └", 13: "next"}
    for row, text in ((1, ""), (2, ""), (4, ""), *want.items()):
        got = rows[row - 1] if len(rows) >= row else None
        result(got == text, f"tty draw: row {row} {text!r}" + ("" if got == text else f", not {got!r}"))
    wrap = rows[11] if len(rows) > 11 else ""
    result(re.fullmatch(r"wrap: \.{30,}", wrap) is not None,
           f"tty draw: row 12 dots to the edge ({len(wrap)} columns), then wrapped")
    m = re.search(r"^\| cursor (\d+),(\d+)$", draw, re.M)
    result(m is not None and int(m.group(1)) > 13, "tty draw: the cursor below what was drawn"
           + (f" ({m.group(1)},{m.group(2)})" if m else ""))
    m = re.search(r"^(\d+) (\d+)$", after(log, "stty size"), re.M)
    size = (int(m.group(1)), int(m.group(2))) if m else None
    result(size is not None and size[0] > 13 and size[1] > 40, f"stty size: {size}")
    m = re.search(r"^(\d+)$", after(log, "tput cols"), re.M)
    result(m is not None and size is not None and int(m.group(1)) == size[1],
           f"tput cols: {m.group(1) if m else 'nothing'}, as stty has it")
    sa = after(log, "stty -a")
    result(size is not None and f"rows {size[0]}; columns {size[1]};" in sa
           and re.search(r"\bisig icanon\b", sa) is not None and "intr = ^C;" in sa,
           "stty -a: the size, isig icanon, intr = ^C")
    ended(log, "clear", "clear", 0)
    less = after(log, "less /etc/passwd")
    result("root:x:0:0:root:/root:/bin/bash" in less, "less: the file shown")
    ended(log, "less /etc/passwd", "less", 0)
    calls = sorted(set(re.findall(r"system call (\d+) is not there yet", log)), key=int)
    print(f"      (calls not there yet: {', '.join(calls) or 'none'})")
    result("AXIOM PANIC" not in log, "no panic")
    rest = log.replace(segv, "")            # (the fault there is the point)
    result(not re.search(r"^\w+: (page fault|general protection)", rest, re.M | re.I), "no fault")
    result("QEMU ended by itself" in err, "powered off")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-root", action="store_true",
                    help="use build/linux as it is, without WSL")
    opts = ap.parse_args()
    sys.stdout.reconfigure(errors="backslashreplace")   # (the box drawing, on cp1252)
    OUT.mkdir(parents=True, exist_ok=True)
    if not (opts.no_root and (LINUX / "META").exists()):
        subprocess.run([sys.executable, str(ROOT / "tools" / "mkroot.py")], cwd=ROOT, check=True)
    stick = OUT / "stick.img"
    subprocess.run([sys.executable, str(ROOT / "tools" / "mkstick.py"), str(stick),
                    "--linux", str(LINUX)], cwd=ROOT, check=True, capture_output=True)
    logs = boot_all(OUT, {"linux": (script(), ["--smp", "4", "--stick",
                                                stick.relative_to(ROOT).as_posix()], 300, 1)})
    print("-- linux")
    check(*logs["linux"])
    print(f"{'all passed' if FAILS == 0 else f'{FAILS} failed'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
