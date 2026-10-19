#!/usr/bin/env python3
"""Boot Axiom in QEMU (q35 + OVMF), from the FAT image in build/esp.

    python tools/run.py                      a window, like a real screen
    python tools/run.py --headless --wait 20 --shot build/shot.png
    python tools/run.py --headless --keys "help\\n" --shot out.png
    python tools/run.py --nic rtl8139        a network card on QEMU's user network

    python tools/run.py --headless --keys "crypto\\n" --script "until X25519"

Headless runs log the serial port to build/serial.log and talk to the QEMU
monitor on 127.0.0.1:4444 for screenshots and keystrokes (QMP on 4445, the
serial port on 4446; --port 0 picks ports nobody uses and firmware variables
of its own, so boots can run side by side). They wait for the shell's first
prompt line, not a fixed time (--wait N for that instead). In --script,
'type TEXT' sends TEXT down the serial port, all at once, as a terminal
would; 'press TEXT' types it on the keyboard, key by key; 'until TEXT' waits
for TEXT in the log after the last text typed; 'ended' waits for the guest
to end QEMU itself (poweroff). When the firmware stalls before it loads
Axiom, as OVMF now and then does, QEMU is started again. Every boot has an
emulated VT-d unit (intel-iommu) all device DMA goes through, unless
--no-iommu.

QEMU runs on the Windows Hypervisor Platform (WHPX) when it can, many times
faster than its own CPU emulation (TCG); --accel picks one. The first run
tries WHPX and remembers the answer in build/accel.txt.
"""
import argparse
import json
import os
import pathlib
import random
import re
import shlex
import shutil
import socket
import subprocess
import sys
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"
MONITOR = ["127.0.0.1", 4444]

KEYNAMES = {" ": "spc", "\n": "ret", "-": "minus", ".": "dot", "/": "slash",
            ",": "comma", "=": "equal", "'": "apostrophe", ";": "semicolon",
            "\b": "backspace", ":": "shift-semicolon", "_": "shift-minus",
            "?": "shift-slash", "&": "shift-7", "~": "shift-grave_accent"}


BOOT_DONE = "Type 'help' for commands."
LOADER = "Axiom loader"
STALL = {"whpx": 30, "tcg": 120}    # seconds the firmware may take to load Axiom, busy


def free_ports(n=3):
    """n ports in a row nobody listens on: the monitor, QMP, the serial port.
    Picked at random, not by the system, which hands out ports in order, so
    that runs starting at the same moment pick apart."""
    while True:
        port = random.randrange(20000, 60000)
        socks = []
        try:
            for i in range(n):
                s = socket.socket()
                socks.append(s)
                s.bind(("127.0.0.1", port + i))
            return port
        except OSError:
            pass
        finally:
            for s in socks:
                s.close()


def pick_accel(qemu, want):
    """'whpx' or 'tcg': as asked, or for 'auto' whether WHPX works here
    (tried once, remembered in build/accel.txt)."""
    if want != "auto":
        return want
    memo = BUILD / "accel.txt"
    if memo.exists():
        return memo.read_text().strip()
    probe = subprocess.Popen([str(qemu), "-accel", "whpx", "-machine", "q35", "-nodefaults",
                              "-display", "none", "-S", "-monitor", "none"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        err = probe.communicate(timeout=3)[1].decode(errors="replace")
        accel = "tcg"                   # it gave up: no hypervisor platform
        print("run.py: WHPX is not available, so QEMU emulates the CPU (slow):",
              err.strip()[-200:], file=sys.stderr)
    except subprocess.TimeoutExpired:
        probe.kill()
        probe.communicate()
        accel = "whpx"
    memo.write_text(accel + "\n")
    return accel


class SerialLog:
    """The guest's serial log, for waiting on what it prints."""
    def __init__(self, path):
        self.path = path
        self.mark = 0

    def text(self):
        try:
            return self.path.read_bytes().decode(errors="replace")
        except OSError:
            return ""

    def set_mark(self):
        self.mark = len(self.text())

    def until(self, needle, timeout, proc):
        """Wait for needle after the mark; False on timeout or if QEMU ends."""
        end = time.time() + timeout
        while time.time() < end:
            if needle in self.text()[self.mark:]:
                return True
            if proc.poll() is not None:
                return False
            time.sleep(0.05)
        return False


class Serial:
    """The guest's serial port on a socket: what it prints goes into the
    log file as it comes; what is typed goes the other way."""
    def __init__(self, port, path, proc):
        self.path = path
        self.sock = None
        while self.sock is None and proc.poll() is None:
            try:
                self.sock = socket.create_connection(("127.0.0.1", port), timeout=2)
            except OSError:
                time.sleep(0.05)
        self.thread = threading.Thread(target=self.pump, daemon=True)
        self.thread.start()

    def pump(self):
        with open(self.path, "ab", buffering=0) as f:
            if self.sock is None:
                return
            self.sock.settimeout(None)
            while True:
                try:
                    data = self.sock.recv(65536)
                except OSError:
                    break
                if not data:
                    break
                f.write(data)

    def send(self, data):
        if self.sock is not None:
            try:
                self.sock.sendall(data)
            except OSError:
                pass

    def close(self):
        """Once QEMU has ended: the rest of the log, then the socket."""
        self.thread.join(timeout=5)
        if self.sock is not None:
            self.sock.close()


def find_qemu():
    exe = shutil.which("qemu-system-x86_64")
    if exe:
        return pathlib.Path(exe)
    scoop = pathlib.Path.home() / "scoop/apps/qemu/current/qemu-system-x86_64.exe"
    if scoop.exists():
        return scoop
    sys.exit("qemu-system-x86_64 not found")


def firmware(qemu, tag, fresh=False):
    """The firmware's code, and its variables: kept per tag, or (fresh) a
    copy of their first state for this run alone."""
    share = qemu.parent / "share"
    code = share / "edk2-x86_64-code.fd"
    vars_src = share / "edk2-i386-vars.fd"
    if fresh:
        (BUILD / "vars").mkdir(exist_ok=True)
        vars_dst = BUILD / "vars" / f"ovmf_vars_{os.getpid()}_{tag}.fd"
        shutil.copyfile(vars_src, vars_dst)
    else:
        vars_dst = BUILD / f"ovmf_vars_{tag}.fd"
        if not vars_dst.exists():
            shutil.copyfile(vars_src, vars_dst)
    return code, vars_dst


class Qmp:
    """QMP, for what the human monitor cannot do (absolute pointer events)."""
    def __init__(self, port):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=2)
        self.buf = b""
        self.reply()
        self.send({"execute": "qmp_capabilities"})

    def reply(self):
        while b"\n" not in self.buf:
            self.buf += self.sock.recv(65536)
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def send(self, msg):
        self.sock.sendall(json.dumps(msg).encode() + b"\n")
        while True:
            r = self.reply()
            if "return" in r or "error" in r:
                return r

    def abs(self, x, y, buttons=()):
        events = [{"type": "abs", "data": {"axis": "x", "value": x}},
                  {"type": "abs", "data": {"axis": "y", "value": y}}]
        events += [{"type": "btn", "data": {"button": b, "down": d}} for b, d in buttons]
        return self.send({"execute": "input-send-event", "arguments": {"events": events}})


class Monitor:
    def __init__(self):
        for _ in range(100):
            try:
                self.sock = socket.create_connection(tuple(MONITOR), timeout=2)
                break
            except OSError:
                time.sleep(0.1)
        else:
            sys.exit("cannot reach the QEMU monitor")
        self.read()

    def read(self):
        data = b""
        self.sock.settimeout(0.5)
        try:
            while True:
                chunk = self.sock.recv(65536)
                if not chunk:
                    break
                data += chunk
                if data.endswith(b"(qemu) "):
                    break
        except (socket.timeout, ConnectionError):
            pass
        return data.decode(errors="replace")

    def cmd(self, line):
        self.sock.sendall(line.encode() + b"\n")
        return self.read()

    def keys(self, text):
        for ch in text:
            if ch in KEYNAMES:
                name = KEYNAMES[ch]
            elif ch.isupper():
                name = "shift-" + ch.lower()
            else:
                name = ch
            self.cmd(f"sendkey {name} 20")     # held 20 ms, then the next
            time.sleep(0.03)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--headless", action="store_true")
    ap.add_argument("--smp", default="8")
    ap.add_argument("--mem", default="6G")
    ap.add_argument("--wait", type=float, help="seconds before keys/shot, instead of "
                    "waiting for the shell's first prompt line")
    ap.add_argument("--timeout", type=float, default=90, help="the most to wait for the "
                    "boot or an 'until' (seconds)")
    ap.add_argument("--accel", default="auto", choices=("auto", "whpx", "tcg"),
                    help="CPU virtualization: auto tries WHPX, else TCG emulation")
    ap.add_argument("--keys", help="text to type on the keyboard (\\n for enter)")
    ap.add_argument("--after-keys", type=float, default=3)
    ap.add_argument("--shot", help="screenshot path (PNG)")
    ap.add_argument("--extra", default="", help="more QEMU arguments, one string")
    ap.add_argument("--port", type=int, default=4444, help="monitor port (QMP and the "
                    "serial port on the next two); 0 for free ones and firmware "
                    "variables of its own")
    ap.add_argument("--serial", default="serial.log", help="log name in build/")
    ap.add_argument("--cpu", help="CPU model (default: max; max,-svm,-vmx on WHPX)")
    ap.add_argument("--no-iommu", action="store_true", help="leave out the emulated VT-d "
                    "unit (intel-iommu) every device's DMA otherwise goes through")
    ap.add_argument("--nic", help="a network card model (rtl8139, e1000...); its "
                    "frames are also written to build/net-PORT.pcap")
    ap.add_argument("--netdev", default="user", help="its backend, e.g. "
                    "'socket,listen=:5555' to join another QEMU")
    ap.add_argument("--mac", help="the card's MAC address")
    ap.add_argument("--stick", help="boot from this USB stick image (tools/mkstick.py) "
                    "instead of build/esp")
    ap.add_argument("--trace", action="store_true", help="say how long each step of "
                    "--script took")
    ap.add_argument("--script", help="monitor commands after the keys, separated "
                    "by ';' ('wait N' pauses N seconds, 'until TEXT' waits for TEXT in "
                    "the log after the last text typed, 'shot FILE' takes a screenshot, "
                    "'type TEXT' types down the serial port, 'press TEXT' on the "
                    "keyboard, 'abs X Y [button]' points (and clicks), 'drag X1 Y1 X2 Y2 "
                    "[button]' drags, 'wheel X Y N' turns the wheel N notches)")
    opts = ap.parse_args()
    fresh = opts.port == 0
    sys.path.insert(0, str(ROOT / "tools"))
    import space
    space.check()                       # stops before the disk fills

    if opts.stick:
        # the loader on a USB stick image, as on real hardware; writes stay
        boot = ["-device", "qemu-xhci,id=bootx",
                "-drive", f"file={opts.stick},if=none,id=bootstick,format=raw",
                "-device", "usb-storage,bus=bootx.0,drive=bootstick,bootindex=0"]
    else:
        boot = ["-drive", f"format=raw,file=fat:{BUILD / 'esp'},snapshot=on"]
    qemu = find_qemu()
    serial = BUILD / opts.serial
    accel = pick_accel(qemu, opts.accel)
    # under WHPX the firmware faults on the nested-virtualization bits of "max"
    cpu = opts.cpu or ("max,-svm,-vmx" if accel == "whpx" else "max")

    def qemu_args():
        MONITOR[1] = free_ports() if fresh else opts.port
        # a stick boot leaves its own boot entries in the firmware's variables:
        # keep them apart from the usual ones
        code, vars_fd = firmware(qemu, f"{MONITOR[1]}{'-stick' if opts.stick else ''}", fresh)
        args = [str(qemu), "-accel", accel, "-machine", "q35", "-cpu", cpu, "-smp", opts.smp,
                "-m", opts.mem,
                *([] if opts.no_iommu else ["-device", "intel-iommu,intremap=off"]),
                "-drive", f"if=pflash,format=raw,readonly=on,file={code}",
                "-drive", f"if=pflash,format=raw,file={vars_fd}",
                *boot,
                "-no-reboot",
                "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04",
                *shlex.split(opts.extra)]
        if opts.nic:
            mac = f",mac={opts.mac}" if opts.mac else ""
            pcap = BUILD / f"net-{MONITOR[1]}.pcap"
            args += ["-netdev", f"{opts.netdev},id=n0",
                     "-device", f"{opts.nic},netdev=n0{mac}",
                     "-object", f"filter-dump,id=f0,netdev=n0,file={pcap}"]
        else:
            args += ["-nic", "none"]
        return args, vars_fd

    if not opts.headless:
        args = qemu_args()[0] + ["-serial", "stdio"]
        sys.exit(subprocess.call(args, cwd=ROOT))

    t0 = time.time()
    log = SerialLog(serial)
    for attempt in range(3):
        args, vars_fd = qemu_args()
        # the serial port on a socket QEMU waits on before it starts the guest
        args += ["-display", "none",
                 "-chardev", f"socket,id=com1,host={MONITOR[0]},port={MONITOR[1] + 2},"
                             "server=on,wait=on",
                 "-serial", "chardev:com1",
                 "-monitor", f"tcp:{MONITOR[0]}:{MONITOR[1]},server,nowait",
                 "-qmp", f"tcp:{MONITOR[0]}:{MONITOR[1] + 1},server,nowait"]
        if serial.exists():
            serial.unlink()
        proc = subprocess.Popen(args, cwd=ROOT)
        com = Serial(MONITOR[1] + 2, serial, proc)
        if opts.wait is not None or attempt == 2 or log.until(LOADER, STALL[accel], proc):
            break
        print("run.py: QEMU ended before the firmware loaded Axiom" if proc.poll() is not None
              else f"run.py: the firmware did not load Axiom in {STALL[accel]} s",
              "- starting it again", file=sys.stderr)
        proc.kill()
        proc.wait()
        com.close()
        if fresh:
            vars_fd.unlink(missing_ok=True)
    try:
        mon = Monitor()
        if opts.wait is not None:
            time.sleep(opts.wait)
        elif log.until(BOOT_DONE, opts.timeout, proc):
            time.sleep(0.2)
            print(f"run.py: booted in {time.time() - t0:.1f} s ({accel})", file=sys.stderr)
        else:
            print(f"run.py: no shell prompt after {opts.timeout:.0f} s", file=sys.stderr)
        if opts.keys:
            log.set_mark()
            mon.keys(opts.keys.encode().decode("unicode_escape"))
            if not opts.script:
                time.sleep(opts.after_keys)
        qmp = None
        for line in (opts.script or "").split(";"):
            line = line.strip()
            if opts.trace:
                print(f"run.py: {time.time() - t0:6.2f} s  {line}", file=sys.stderr)
            if line.startswith("drag "):
                # drag X1 Y1 X2 Y2 [button]: absolute pointer (0..32767), the
                # button held from the first point to the second, in steps
                qmp = qmp or Qmp(MONITOR[1] + 1)
                parts = line.split()
                x1, y1, x2, y2 = (int(v) for v in parts[1:5])
                b = parts[5] if len(parts) > 5 else "left"
                qmp.abs(x1, y1)
                time.sleep(0.1)
                qmp.abs(x1, y1, [(b, True)])
                for i in range(1, 9):
                    time.sleep(0.05)
                    qmp.abs(x1 + (x2 - x1) * i // 8, y1 + (y2 - y1) * i // 8)
                time.sleep(0.1)
                qmp.abs(x2, y2, [(b, False)])
            elif line.startswith("wheel "):
                # wheel X Y N: the pointer there, the wheel turned N notches
                # (up positive)
                qmp = qmp or Qmp(MONITOR[1] + 1)
                parts = line.split()
                x, y, n = int(parts[1]), int(parts[2]), int(parts[3])
                qmp.abs(x, y)
                for _ in range(abs(n)):
                    time.sleep(0.05)
                    b = "wheel-up" if n > 0 else "wheel-down"
                    qmp.abs(x, y, [(b, True)])
                    qmp.abs(x, y, [(b, False)])
            elif line.startswith("abs "):
                # abs X Y [left|right|middle]: absolute pointer, 0..32767,
                # with an optional click there
                qmp = qmp or Qmp(MONITOR[1] + 1)
                parts = line.split()
                x, y = int(parts[1]), int(parts[2])
                qmp.abs(x, y)
                for b in parts[3:]:
                    time.sleep(0.1)
                    qmp.abs(x, y, [(b, True)])
                    time.sleep(0.1)
                    qmp.abs(x, y, [(b, False)])
            elif line.startswith("wait "):
                time.sleep(float(line[5:]))
            elif line == "ended":
                # ended: wait for the guest to end QEMU itself (poweroff)
                end = time.time() + opts.timeout
                while proc.poll() is None and time.time() < end:
                    time.sleep(0.05)
                print("run.py: QEMU " + ("ended by itself" if proc.poll() is not None
                                         else "is still running"), file=sys.stderr)
            elif line.startswith("until "):
                # until TEXT: in the log, after the last text typed
                if not log.until(line[6:], opts.timeout, proc):
                    print(f"run.py: no '{line[6:]}' after {opts.timeout:.0f} s",
                          file=sys.stderr)
            elif line.startswith("type "):
                # type TEXT: down the serial port, \n for enter
                log.set_mark()
                com.send(line[5:].encode().decode("unicode_escape").encode("latin-1"))
            elif line.startswith("press "):
                # press TEXT: on the keyboard, key by key
                log.set_mark()
                mon.keys(line[6:].encode().decode("unicode_escape"))
            elif line.startswith("shot "):
                mon.cmd(f"screendump {pathlib.Path(line[5:]).resolve()} -f png")
            elif line:
                out = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", mon.cmd(line))
                out = out.replace("(qemu) ", "")
                lines = [l.strip() for l in out.splitlines()
                         if l.strip() and line not in l]
                if lines:
                    print("monitor:", line, "->", " | ".join(lines))
        if opts.shot:
            shot = pathlib.Path(opts.shot).resolve()
            ppm = shot.with_suffix(".ppm")
            out = mon.cmd(f"screendump {shot} -f png")
            if not shot.exists():
                mon.cmd(f"screendump {ppm}")
                print(out.strip())
        if proc.poll() is None:
            try:
                mon.cmd("quit")
            except OSError:
                pass                        # the guest powered off just now
    finally:
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        com.close()
        if fresh:
            vars_fd.unlink(missing_ok=True)
    sys.stdout.flush()                      # (UTF-8 now: Claude's answers)
    sys.stdout.buffer.write(serial.read_bytes().replace(b"\r\n", b"\n") + b"\n")
    sys.stdout.flush()
    print(f"run.py: {time.time() - t0:.1f} s in all", file=sys.stderr)


if __name__ == "__main__":
    main()
