#!/usr/bin/env python3
"""Axiom's Rust programs in QEMU: sdk/rust built (tools/rust.py) onto a
stick, then run from the shell and checked from the serial log and the
screen.

    python tools/test/rust/run.py

  - rhello (no std): its arguments; the heap (3000 allocations of every
    size, a third kept and checked, 12 MiB at once, a vector grown to 16 MiB,
    a page-aligned one); the volumes; its own .AXE read back whole and found
    in its folder's listing at that size; 50 ms slept by the clock; exit 0;
  - rdemo (std): println, std::env::args, a window that can be resized
    (640x400, its stride the screen's width), drawn each frame: its ground
    and its square on the screen; keys (a letter, ctrl+A, F5, up), a drag
    (the press where it began, the square where it ended), the wheel, then
    its close button: it ends, 0, having counted what happened. Games' input
    on the way: each key down and up as its HID usage (ctrl+A, F5 and up
    from the keyboard, each down, then what it typed, then up; w held
    while it repeats: one down, one up, three keys), the pointer over it with no button held (where, and how far it
    went) and leaving it; the pointer held (g: Pointer::Grab): hidden, in
    the window's middle, only how far it moved changing; ctrl+alt lets it
    go, a click holds it again;
  - rdemo --full: filling the screen between the bar and the dock, drawn
    there; q ends it;
  - the keys down and up again from a USB keyboard (hid.asm, where the first
    boot's are the PS/2 one's, kbd.asm): w held is one key there, since a
    USB keyboard says a key is down, not that it repeats;
  - rstd (std, on its hermit layer): threads (spawned, joined, scoped, 300
    in turn, 50 never joined and given back, named), Mutex, atomics,
    Condvar (and its timeout), RwLock, Once, OnceLock, Barrier, mpsc and a
    rendezvous, park; thread_local! (each thread's own, their destructors);
    sleep, Instant, SystemTime's year; files on the read-only stick (mkdir
    and write: "Read-only file system", read works), then after `vol 0 rw`
    a folder made, written, appended to, 256 KiB sought in, its metadata,
    listed, NotFound, removed; a thread's panic ends it, 134; a thread's
    std::process::exit ends it with that code; main's ExitCode is its own;
  - rstd spawn (axiom::task, axiom::chan): hello started, its console to a
    channel here, what it printed read until the channel's end, its exit
    code; a child printing 3000 lines faster than they are read (it
    waits), all of them in order; a grandchild's text there too; spin
    killed (E_KILLED); a program that is not there; the memory, the
    uptime, the boot volume's free space;
  - rstd net (std::net, on an RTL8139 on QEMU's user network, the host
    10.0.2.2): to an echo server here, 200 KB written by one thread and read
    back whole by another (try_clone), its addresses, peek, a read's
    timeout, nonblocking, shutdown and the end; connect_timeout to nobody;
    loopback and UDP refused; port 0 one of ours; a port listened on, a
    client from here (forwarded to it) answered; TLS's server side
    (axiom::net::Identity from a PKCS #8 key and a certificate made here,
    put on the stick): a key not the certificate's refused (NETW_IDENTITY),
    bad PEM refused, then a TLS 1.3 client from here, its certificate
    pinned as fleet pins a node's, answered; by name (axiom.test, a DNS
    server here on 127.0.0.1:53, if it can be had), and a name that isn't;
    no sockets left.
Skipped (passing) if there is no nightly toolchain. Outputs go to
build/test/rust/.
"""
import hashlib
import pathlib
import re
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "test"))
from qemu import boot_all  # noqa: E402

OUT = ROOT / "build" / "test" / "rust"
FAILS = 0
SCR_W, SCR_H = 2560, 1600
PT = 2
TITLE = 28 * PT
TABLET = "-device qemu-xhci,id=ux -device usb-tablet,bus=ux.0"
USB_KBD = " -device usb-kbd,bus=ux.0"    # the keys go to it, not to PS/2
CX, CY = 472, 448                       # rdemo's window, where the desktop puts it
GROUND, MARK = (0x20, 0x30, 0x40), (0xE0, 0xA0, 0x30)
FROM, TO = (300, 200), (420, 260)       # the drag, in the window
H1, H2 = (200, 150), (260, 190)         # the pointer over it, no button held


def at(x, y):
    """A point on the screen, as the tablet's 0..32767."""
    return f"{(x * 32768 + SCR_W // 2) // SCR_W} {(y * 32768 + SCR_H // 2) // SCR_H}"


def win(x, y):
    return at(CX + x, CY + y)


def result(ok, text):
    global FAILS
    FAILS += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + text)
    return ok


def script(tag):
    """The same for each keyboard; screenshots named for it (tag)."""
    return [
        "until log: kept in", "wait 1.5",
        'type rhello one "two words"\\n', "until run: RHELLO exited", "wait 0.3",
        "type rdemo\\n", "until rdemo: first frame", "wait 0.5",
        f"shot build/test/rust/{tag}open.png",
        "type x", "wait 0.2", "sendkey ctrl-a", "wait 0.2", "sendkey f5", "wait 0.5",
        f"drag {win(*FROM)} {win(*TO)}", "wait 0.8",
        f"wheel {win(*TO)} 2", "wait 0.3",
        f"shot build/test/rust/{tag}dragged.png",
        "sendkey up", "wait 0.3",
        "key w down", "wait 0.1", "key w down", "wait 0.1", "key w down", "wait 0.1",
        "key w up", "wait 0.4",
        f"abs {win(*H1)}", "wait 0.3", f"abs {win(*H2)}", "wait 0.3",
        f"abs {at(CX + 300, CY - TITLE // 2)}", "wait 0.4",  # its title bar: out of it
        "type g", "until rdemo: pointer Grab", "wait 0.3",   # held, in its middle
        f"abs {win(*H1)}", "wait 0.3", f"abs {win(*H2)}", "wait 0.3",
        f"shot build/test/rust/{tag}grabbed.png",
        "key ctrl down", "key alt down", "wait 0.1", "key alt up", "key ctrl up", "wait 0.3",
        f"abs {win(*H1)}", "wait 0.4",                       # let go: it moves
        f"shot build/test/rust/{tag}released.png",
        f"abs {win(*H2)} left", "wait 0.5",                  # a click: held again
        f"abs {win(*H1)}", "wait 0.3",
        "type g", "until rdemo: pointer Arrow", "wait 0.3",
        f"abs {at(CX + 14 * PT, CY - TITLE // 2)} left",   # its close button
        "until run: RDEMO exited", "wait 0.3",
        "type rdemo --full\\n", "until rdemo: first frame", "wait 0.5",
        f"shot build/test/rust/{tag}full.png",
        "type q", "until run: RDEMO exited", "wait 0.3",
    ]


def script_usb():
    return [
        "until log: kept in", "wait 1.5",
        "type rdemo\\n", "until rdemo: first frame", "wait 0.5",
        "sendkey ctrl-a", "wait 0.3", "sendkey f5", "wait 0.3", "sendkey up", "wait 0.3",
        "key w down", "wait 0.1", "key w down", "wait 0.1", "key w down", "wait 0.1",
        "key w up", "wait 0.4",
        "type q", "until run: RDEMO exited", "wait 0.3",
    ]


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


ECHO, SERVE, TLS_SERVE = free_port(), free_port(), free_port()
LISTEN = 7777                           # the guest's, SERVE forwarded to it
TLS_LISTEN = LISTEN + 1                 # its TLS listener's, TLS_SERVE to it
heard = []                              # what the guest told the client here
heard_tls = []                          # and the TLS client
TLS_LINE = b"hello over TLS" + b"." * 200_000 + b"\n"


def node_identity():
    """A P-256 key (PKCS #8, as fleet's install.py writes key.pem) and a
    self-signed certificate for it, as fleet makes a node's -> their paths."""
    key, cert = OUT / "node.key", OUT / "node.pem"
    subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256",
                    "-out", str(key)], check=True, capture_output=True)
    subprocess.run(["openssl", "req", "-new", "-x509", "-key", str(key), "-out", str(cert), "-days", "30",
                    "-subj", "/CN=fleet node test", "-sha256"], check=True, capture_output=True)
    return key, cert


def tls_client(log_path, started, cert):
    """Once the guest's TLS listener listens: TLS 1.3 to it, its certificate
    pinned by its SHA-256 (fleet's protocol, section 7), a line of 200 KB
    (more than the kernel holds for it at once), the answer."""
    want = hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert.read_text())).hexdigest()
    deadline = time.time() + 300
    while time.time() < deadline:
        try:
            if log_path.stat().st_mtime >= started and \
                    "rstd: net tls listening on" in log_path.read_text(errors="replace"):
                break
        except OSError:
            pass
        time.sleep(0.3)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        raw = socket.create_connection(("127.0.0.1", TLS_SERVE), timeout=30)
        with ctx.wrap_socket(raw) as c:
            got = hashlib.sha256(c.getpeercert(binary_form=True)).hexdigest()
            info = (c.version(), c.cipher()[0], got == want)
            c.sendall(TLS_LINE)
            back = b""
            while True:
                try:
                    b = c.recv(4096)
                except ssl.SSLError as e:
                    back += f" [{e.reason}]".encode()
                    break
                if not b:
                    break
                back += b
        heard_tls.append((info, back))
    except OSError as e:
        heard_tls.append(repr(e))


def echo_server():
    """Back whatever comes, until the other side finishes."""
    l = socket.socket()
    l.bind(("127.0.0.1", ECHO))
    l.listen(8)

    def one(c):
        with c:
            while True:
                try:
                    b = c.recv(65536)
                except OSError:
                    return
                if not b:
                    return
                c.sendall(b)

    def loop():
        while True:
            c, _ = l.accept()
            threading.Thread(target=one, args=(c,), daemon=True).start()
    threading.Thread(target=loop, daemon=True).start()


def dns_server():
    """axiom.test is 10.0.2.2; anything else does not exist. -> the names
    asked for, or None if port 53 cannot be had (by name is not tried)."""
    try:
        u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        u.bind(("127.0.0.1", 53))
    except OSError:
        return None
    asked = []

    def loop():
        while True:
            try:
                q, peer = u.recvfrom(512)
            except OSError:
                return
            qid = struct.unpack(">H", q[:2])[0]
            i, labels = 12, []
            while q[i]:
                labels.append(q[i + 1:i + 1 + q[i]].decode())
                i += 1 + q[i]
            name = ".".join(labels).lower()
            asked.append(name)
            question = q[12:i + 5]
            qtype = struct.unpack(">H", q[i + 1:i + 3])[0]
            if name == "axiom.test" and qtype == 1:
                ans = b"\xc0\x0c" + struct.pack(">HHIH", 1, 1, 60, 4) + socket.inet_aton("10.0.2.2")
                r = struct.pack(">HHHHHH", qid, 0x8180, 1, 1, 0, 0) + question + ans
            elif name == "axiom.test":
                r = struct.pack(">HHHHHH", qid, 0x8180, 1, 0, 0, 0) + question  # no AAAA
            else:
                r = struct.pack(">HHHHHH", qid, 0x8183, 1, 0, 0, 0) + question
            u.sendto(r, peer)
    threading.Thread(target=loop, daemon=True).start()
    return asked


def client(log_path, started):
    """Once the guest listens: a line to it, and what it says back."""
    deadline = time.time() + 240
    while time.time() < deadline:
        try:
            if log_path.stat().st_mtime >= started and \
                    "rstd: net listening on" in log_path.read_text(errors="replace"):
                break
        except OSError:
            pass
        time.sleep(0.3)
    try:
        c = socket.create_connection(("127.0.0.1", SERVE), timeout=20)
        c.sendall(b"hello from the host\n")
        back = b""
        while True:
            b = c.recv(4096)
            if not b:
                break
            back += b
        c.close()
        heard.append(back)
    except OSError as e:
        heard.append(repr(e))


def script_net(dns):
    s = ["until log: kept in", "until dhcp: address", "wait 0.5"]
    if dns:
        s += ["type ip 10.0.2.15/24 10.0.2.2 10.0.2.2\\n", "wait 0.5"]
    s += [f"type rstd net {ECHO} {LISTEN}{' dns' if dns else ''}\\n", "until run: RSTD exited",
          "wait 12", "type sockets\\n", "wait 0.5", "type poweroff\\n", "ended"]
    return s


def check_net(log, dns):
    """rstd net: std::net on axiom::hermit's sockets."""
    def has(text):
        return text in log

    for line, what in [
        (f"rstd: net connected to 10.0.2.2:{ECHO}, from 10.0.2.15, a port of ours true",
         "connected, peer_addr, local_addr"),
        ("rstd: net echoed 200000 bytes Ok(()) Ok(()), right true",
         "200 KB echoed, written by one thread, read by another (try_clone)"),
        ('rstd: net peeked "peek", then read "peek"', "peek, then read"),
        ("rstd: net read timed out Err(WouldBlock) Some(200ms), in time true", "set_read_timeout"),
        ("rstd: net nonblocking Err(WouldBlock), nodelay Ok(true)", "set_nonblocking, set_nodelay"),
        ("rstd: net shut, then the end Ok(0)", "shutdown(Write), then the server's end"),
        ("rstd: net nobody at 10.0.2.99:9: true, in time true", "connect_timeout to nobody"),
        ('rstd: net loopback Err(AddrNotAvailable) Err(Some(101)), udp Err("Protocol not supported (os error 93)")',
         "no loopback (bind, connect), no UDP"),
        ("rstd: net port 0 is one of ours true", "bind port 0"),
        (f"rstd: net listening on 0.0.0.0:{LISTEN}", "TcpListener::bind, local_addr"),
        ('rstd: net accepted from 10.0.2.2, said "hello from the host"', "accept, a line read"),
        (f"net: a program listens on port {LISTEN}", "the kernel said so"),
        ('rstd: net tls, another key: failed true, "the certificates will not do, or the key is not theirs"; '
         'bad PEM [Some(Error(-10: ', "TLS listener: a key not the certificate's refused; bad PEM refused"),
        (f"rstd: net tls listening on port {TLS_LISTEN}, failed false, 1 certificate",
         "TLS listener: Identity::from_pem (PKCS #8), listen_tls"),
        (f'rstd: net tls accepted from 10.0.2.2, open true, said "hello over TLS", {len(TLS_LINE)} bytes',
         "TLS listener: accepted, the handshake done, a line of 200 KB read"),
        ("rstd: net done", "done"),
    ]:
        result(has(line), f"rstd net: {what}")
    result(heard == [b"you said: hello from the host\n"], f"rstd net: the client here was answered ({heard})")
    result(heard_tls == [(("TLSv1.3", "TLS_AES_128_GCM_SHA256", True), b"you said, over TLS: " + TLS_LINE)],
           "rstd net: the TLS client here: TLS 1.3, the certificate pinned, answered "
           f"({str(heard_tls)[:300]})")
    if dns:
        result(has(f"rstd: net axiom.test is [10.0.2.2:{ECHO}]"), "rstd net: to_socket_addrs by the kernel's DNS")
        result(has('rstd: net by name, echoed "by name"'), "rstd net: connected by name")
        result(has('rstd: net nothing.here Err("failed to lookup address information: ")'),
               "rstd net: a name that does not exist")
    else:
        print("SKIP rstd net by name: port 53 here could not be had")
    result(has("run: RSTD exited with 0"), "rstd net: exit 0")
    m = re.search(r"sockets: (\d+) live, (\d+) made", log)
    result(bool(m) and m.group(1) == "0", f"rstd net: no sockets left ({m.group(0) if m else 'no line'})")
    for line in log.splitlines():
        if "panicked" in line or "PANIC" in line or "ended by a fault" in line:
            result(False, f"rstd net: no panics, no faults: {line}")


def script_std():
    return [
        "until log: kept in", "wait 1",
        "type rstd one two\\n", "until run: RSTD exited", "wait 0.3",
        "type rstd ro rstdro\\n", "until run: RSTD exited", "wait 0.3",
        "type rstd home\\n", "until run: RSTD exited", "wait 0.3",  # (before vol 0 rw)
        "type vol 0 rw\\n", "wait 0.5",                     # (a test copy of the stick)
        "type rstd fs rstdtest\\n", "until run: RSTD exited", "wait 0.3",
        "type rstd panic\\n", "until run: RSTD exited", "wait 0.3",
        "type rstd exit\\n", "until run: RSTD exited", "wait 0.3",
        "type rstd code\\n", "until run: RSTD exited", "wait 0.5",
        "type rstd spawn\\n", "until rstd: spawn the boot volume", "wait 0.5",
    ]


def pixel(name, x, y):
    from PIL import Image
    try:
        return Image.open(OUT / name).convert("RGB").getpixel((x, y))
    except OSError:
        return None


def check_keys(log, who, repeats):
    """Keys down and up (Window::KEYS), as the keyboard said them; a held
    key `repeats` times as text."""
    def has(text):
        return text in log

    result(has("rdemo: key Up"), f"{who}: up")
    result(has("rdemo: down 0xe0 ctrl") and has("rdemo: down 0x04 ctrl") and has("rdemo: up 0x04")
           and has("rdemo: up 0xe0"), f"{who}: ctrl+A down and up, as HID usages")
    result(has("rdemo: down 0x3e") and has("rdemo: up 0x3e"), f"{who}: F5 down and up")
    result(has("rdemo: down 0x52") and has("rdemo: up 0x52"), f"{who}: up down and up")
    def order(*lines):
        at = [log.find(t) for t in lines]
        return -1 not in at and at == sorted(at)

    result(order("rdemo: down 0x04 ctrl", "rdemo: key Char('a') ctrl", "rdemo: up 0x04") and
           order("rdemo: down 0x3e", "rdemo: key F(5)", "rdemo: up 0x3e") and
           order("rdemo: down 0x52", "rdemo: key Up", "rdemo: up 0x52"),
           f"{who}: each key down, then what it typed, then up, in that order")
    downs, ups, keys = (log.count(t) for t in ("rdemo: down 0x1a", "rdemo: up 0x1a", "rdemo: key Char('w')"))
    result((downs, ups, keys) == (1, 1, repeats),
           f"{who}: w held: down once, up once, {repeats} as text ({downs}, {ups}, {keys})")


def check_std(log):
    """rstd: std's threads, locks, thread_local!, time and files, on
    hermit's layer (axiom::hermit)."""
    def has(text):
        return text in log

    first = log.split("run: RSTD exited", 1)[0]
    result(has('rstd: args ["one", "two"]'), "rstd: std::env::args")
    m = re.search(r"rstd: cpus (\d+)", log)
    result(bool(m) and m.group(1) == "4", f"rstd: available_parallelism ({m.group(0) if m else 'no line'})")
    for line, what in [
        ("rstd: 8 threads, their sums right", "threads spawned and joined"),
        ("rstd: scoped, sum 3000", "thread::scope"),
        ("rstd: 300 in turn 300, 50 unjoined, then 1", "300 in turn, 50 never joined, given back"),
        ('rstd: named Some("worker"), main is Some("main")', "names"),
        ("rstd: mutex 80000", "Mutex"),
        ("rstd: atomic 200000", "atomics"),
        ("rstd: condvar, turns 400", "Condvar"),
        ("rstd: condvar timed out true", "Condvar's timeout"),
        ("rstd: rwlock, written 200, read 28800", "RwLock"),
        ("rstd: once ran 1, oncelock agreed true", "Once, OnceLock"),
        ("rstd: barrier held true", "Barrier"),
        ("rstd: mpsc 1000 messages", "mpsc"),
        ("rstd: rendezvous 4950", "sync_channel(0)"),
        ("rstd: parked and unparked 1", "park, unpark"),
        ("rstd: thread_local each its own true, the first's 100, destructors 6",
         "thread_local!, each its own, destructors run"),
    ]:
        result(line in first, f"rstd: {what}")
    m = re.search(r"rstd: slept (\d+) ms, spun (\d+) ms \((\w+) looks\)", log)
    result(bool(m) and 50 <= int(m.group(1)) < 500 and m.group(3) == "true",
           f"rstd: sleep and Instant ({m.group(0) if m else 'no line'})")
    m = re.search(r"rstd: the year (\d+)", log)
    result(bool(m) and 2024 <= int(m.group(1)) < 2100, f"rstd: SystemTime ({m.group(0) if m else 'no line'})")
    result(has("rstd: done") and "run: RSTD exited with 0" in log.split('"ro"', 1)[0], "rstd: exit 0")
    ro = 'rstd: ro mkdir Err("Read-only file system (os error 30)"), ' \
         'write Err("Read-only file system (os error 30)"), read Ok(true)'
    result(has(ro), "rstd ro: a read-only volume says so; reading works")
    result(has('rstd: home Ok("vol0:/Home"), HOME Ok("/Home")'), "rstd home: Files::home, and HOME")
    result(has("rstd: home made true, wrote true, read back true, appended true, renamed true"),
           "rstd home: in /Home, written without vol 0 rw: made, written, appended to, renamed")
    result(has('rstd: home outside Err("Read-only file system (os error 30)"), moved out '
               'Err("Error(-22: read-only (vol <n> rw in the shell allows writing))"), removed Err("Read-only file system (os error 30)")'),
           "rstd home: nothing outside it, nor moved out of it, nor the folder itself")
    result(has("rstd: home cleaned true, there true"), "rstd home: removed again, /Home still there")
    result(has("files: made vol0:/Home, where programs may write"), "rstd home: the kernel made /Home on the stick")
    for line, what in [
        ("rstd: fs made rstdtest", "create_dir"),
        ("rstd: fs wrote and read back true", "write, read_to_string"),
        ("rstd: fs appended, 3 lines", "OpenOptions::append"),
        ("rstd: fs big 262144 bytes, at 1000 [232, 233, 234, 235]", "256 KiB, seek and read"),
        ("rstd: fs metadata: file true 262144 bytes, folder true, written within a day true", "metadata"),
        ('rstd: fs listed ["a.txt", "big.bin", "sub"]', "read_dir"),
        ("rstd: fs missing Err(NotFound)", "NotFound"),
        ("rstd: fs removed, gone true", "remove_file, remove_dir"),
    ]:
        result(has(line), f"rstd fs: {what}")
    result(has("rstd: a thread panics") and has("run: RSTD exited with 134"),
           "rstd panic: a thread's panic ends the program, 134")
    result(has("rstd: a thread exits") and has("run: RSTD exited with 7") and not has("rstd: still here"),
           "rstd exit: std::process::exit from a thread ends the program, 7")
    result(has("run: RSTD exited with 3"), "rstd code: main's ExitCode, 3")
    for line, what in [
        ("rstd: spawn hello Ok(0), said hello true, its arguments true",
         "hello started, its console to a channel of ours, its exit code"),
        ("rstd: spawn chatter Ok(5), 3000 lines in order true",
         "3000 lines faster than they are read: the child waits, nothing lost"),
        ("rstd: spawn nest Ok(0), the grandchild's text too true, then its own true",
         "a grandchild writes to the same channel; its end comes after both"),
        ("rstd: spawn spin Err(Error(-9: timed out)), killed Ok(()), then Ok(-12) in time true",
         "join's deadline; kill; then join says E_KILLED"),
        ("rstd: spawn a name that is not there Err(", "a program that is not there"),
        ("rstd: spawn info ram ", "SYS_INFO's memory"),
        ("free some true, uptime some true", "SYS_INFO's free memory and uptime"),
        ("rstd: spawn the boot volume 62 MiB, free some true", "a volume's free space (FV_FREE)"),
    ]:
        result(has(line), f"rstd spawn: {what}")
    panics = log.count("panicked")
    result(panics == 1, f"rstd: no panic but the one asked for ({panics})")
    for line in log.splitlines():
        if "PANIC" in line or "ended by a fault" in line:
            result(False, f"rstd: no faults: {line}")


def check(log, err):
    def has(text):
        return text in log

    # rhello
    result(has('rhello: 2 args ["one", "two words"]') or has('rhello: 3 args ["one", "two", "words"]'),
           "rhello: its arguments")
    m = re.search(r"rhello: heap (\d+) bytes, (\d+) kept, (\w+), big (\d+), grown (\w+), aligned (\w+)", log)
    result(bool(m) and m.group(2) == "1000" and m.group(3) == "intact" and
           m.group(4) == str(7 * (3 << 20)) and m.group(5) == "true" and m.group(6) == "true",
           f"rhello: the heap ({m.group(0) if m else 'no line'})")
    m = re.search(r"rhello: read (\d+) bytes of vol\d+:/EFI/AXIOM/RHELLO.AXE, magic AXIOMEX2", log)
    size = (ROOT / "build" / "esp" / "EFI" / "AXIOM" / "RHELLO.AXE").stat().st_size
    result(bool(m) and int(m.group(1)) == size, f"rhello: its own file read back ({size} bytes)")
    result(has(f"RHELLO.AXE {size}"), "rhello: and found in its folder at that size")
    result(bool(re.search(r"rhello: vol\d+ 'AXIOM BOOT' \d+ MiB flags \d+", log)), "rhello: the volumes")
    m = re.search(r"rhello: slept (\d+) ms", log)
    result(bool(m) and 50 <= int(m.group(1)) < 500, f"rhello: the clock ({m.group(0) if m else 'no line'})")
    result(has("run: RHELLO exited with 0"), "rhello: exit 0")

    # rdemo
    result(has("rdemo: std says hello, 1 args"), "rdemo: std's println and args")
    result(has("rdemo: first frame 640x400, stride 2560"), "rdemo: its window, and its stride")
    result(has("rdemo: key Char('x')"), "rdemo: a letter")
    result(has("rdemo: key Char('a') ctrl"), "rdemo: ctrl+A")
    result(has("rdemo: key F(5)"), "rdemo: F5")
    check_keys(log, "rdemo", 3)
    hovers = [tuple(int(v) for v in h) for h in re.findall(r"rdemo: hover at (\d+),(\d+) by (-?\d+),(-?\d+)", log)]
    near = lambda a, b, d: abs(a - b) <= d
    m = [h for h in hovers if near(h[0], H2[0], 1) and near(h[1], H2[1], 1)]
    result(bool(m) and near(m[0][2], H2[0] - H1[0], 2) and near(m[0][3], H2[1] - H1[1], 2),
           f"rdemo: the pointer over it, no button, and how far it went ({m[0] if m else hovers})")
    result(has("rdemo: left"), "rdemo: and leaving it")
    after = log.split("rdemo: pointer Grab", 1)[1].split("rdemo: pointer Arrow", 1)[0]         if "rdemo: pointer Grab" in log else ""
    held = [tuple(int(v) for v in h) for h in re.findall(r"rdemo: hover at (\d+),(\d+) by (-?\d+),(-?\d+)", after)]
    mid = (320, 200)                                    # the middle of 640x400
    def find(start, x, y, dx=None, dy=None):
        for i in range(start, len(held)):
            h = held[i]
            if near(h[0], x, 1) and near(h[1], y, 1) and (dx is None or (near(h[2], dx, 2) and near(h[3], dy, 2))):
                return i
        return None
    i = find(0, *mid, H2[0] - H1[0], H2[1] - H1[1])
    result(i is not None, f"rdemo: held in its middle, only how far it moved changing ({held})")
    j = find(i + 1, *H1) if i is not None else None
    result(j is not None, "rdemo: ctrl+alt let it go")
    k = find(j + 1, *mid, H1[0] - H2[0], H1[1] - H2[1]) if j is not None else None
    result(k is not None, "rdemo: and a click held it again")
    p = pixel("grabbed.png", CX + mid[0] + 4, CY + mid[1] + 12)
    result(p == GROUND, f"rdemo: no pointer drawn while held ({p})")
    p = pixel("released.png", CX + H1[0] + 4, CY + H1[1] + 12)
    result(p is not None and p != GROUND, f"rdemo: and drawn once let go ({p})")
    m = re.search(r"rdemo: press Left at (\d+),(\d+)", log)        # (the tablet's rounding: a pixel)
    result(bool(m) and abs(int(m.group(1)) - FROM[0]) <= 1 and abs(int(m.group(2)) - FROM[1]) <= 1,
           f"rdemo: the press, where the drag began ({m.group(0) if m else 'no line'})")
    m = re.search(r"rdemo: (\d+) frames in [\d.]+ s; \[(.*)\]", log)
    kinds = dict(re.findall(r'\("(\w+)", (\d+)\)', m.group(2))) if m else {}
    result(bool(m) and int(m.group(1)) >= 10 and "move" in kinds and "wheel" in kinds and
           "release" in kinds, f"rdemo: its count ({m.group(0) if m else 'no line'})")
    result(has("run: RDEMO exited with 0"), "rdemo: its close button ends it, 0")
    sizes = re.findall(r"rdemo: resized (\d+)x(\d+)", log)
    w, h = (int(v) for v in sizes[-1]) if sizes else (0, 0)
    result(w == SCR_W and SCR_H // 2 < h < SCR_H, f"rdemo --full: zoomed, the screen's width ({w}x{h})")
    p = pixel("full.png", SCR_W // 2, SCR_H // 2)
    result(p == GROUND, f"rdemo --full: drawn there ({p})")
    result(log.count("run: RDEMO exited with 0") == 2, "rdemo --full: q ends it, 0")
    p = pixel("open.png", CX + 10, CY + 200)
    result(p == GROUND, f"rdemo: its ground on the screen ({p})")
    p = pixel("open.png", CX + 100, CY + 100)
    result(p == MARK, f"rdemo: its square ({p})")
    p = pixel("dragged.png", CX + TO[0] - 12, CY + TO[1] - 12)      # up and left of the pointer
    result(p == MARK, f"rdemo: the square where the drag ended ({p})")
    p = pixel("dragged.png", CX + 100, CY + 100)
    result(p == GROUND, f"rdemo: and gone from where it was ({p})")
    for line in log.splitlines():
        if "panicked" in line or "ended by a fault" in line or "PANIC" in line:
            result(False, f"no panics, no faults: {line}")


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
    stick = OUT / "stick.img"
    subprocess.run([sys.executable, str(ROOT / "tools" / "mkstick.py"), str(stick)], cwd=ROOT,
                   check=True, capture_output=True)
    stick_usb = OUT / "stick-usb.img"                  # (a boot locks its image)
    shutil.copyfile(stick, stick_usb)
    stick_std = OUT / "stick-std.img"
    shutil.copyfile(stick, stick_std)
    stick_net = OUT / "stick-net.img"
    key, cert = node_identity()
    subprocess.run([sys.executable, str(ROOT / "tools" / "mkstick.py"), str(stick_net), "--file",
                    f"NODE.PEM={cert}", "--file", f"NODE.KEY={key}"], cwd=ROOT, check=True, capture_output=True)
    echo_server()
    dns = dns_server()
    started = time.time()
    threading.Thread(target=client, args=(OUT / "rust-net.log", started), daemon=True).start()
    threading.Thread(target=tls_client, args=(OUT / "rust-net.log", started, cert), daemon=True).start()
    fwd = f"user,hostfwd=tcp:127.0.0.1:{SERVE}-:{LISTEN},hostfwd=tcp:127.0.0.1:{TLS_SERVE}-:{TLS_LISTEN}"
    logs = boot_all(OUT, {
        "rust": (script(""), ["--smp", "4", "--demo", "--extra", TABLET, "--stick",
                              stick.relative_to(ROOT).as_posix()], 120, 2),
        "rust-usb": (script_usb(), ["--smp", "2", "--extra", TABLET + USB_KBD, "--stick",
                                    stick_usb.relative_to(ROOT).as_posix()], 120, 1),
        "rust-std": (script_std(), ["--smp", "4", "--stick",
                                    stick_std.relative_to(ROOT).as_posix()], 120, 2),
        "rust-net": (script_net(dns is not None), ["--smp", "2", "--nic", "rtl8139", "--netdev", fwd,
                                                   "--stick", stick_net.relative_to(ROOT).as_posix()],
                     150, 1)})
    check(*logs["rust"])
    check_keys(logs["rust-usb"][0], "usb", 1)
    check_std(logs["rust-std"][0])
    check_net(logs["rust-net"][0], dns is not None)
    print(f"{'all passed' if not FAILS else f'{FAILS} FAILED'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
