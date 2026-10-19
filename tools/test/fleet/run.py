#!/usr/bin/env python3
"""The fleet node program (sdk/rust/fleet) in QEMU: Axiom as one of fleet's
self-managed nodes, a client here speaking fleet's wire to it (fleet's
docs/protocol.md, sections 1 to 4 and 7) over TLS, through a forwarded port.

    python tools/test/fleet/run.py

A stick holds /Home/fleet as `fleet add NAME --self-managed` makes it: its
node.json (a client's token's SHA-256, the network it comes from), a P-256
cert.pem and key.pem. Two boots, one after the other, on that stick:

  - the first: `fleet`; the hello (a wrong token refused, a protocol not
    spoken refused, then the reply: its node, version, code, protocol,
    since); ping; info; an operation it does not know (and the connection
    goes on); a push (manifest: all needed; put; manifest again: nothing
    needed, the pushed times kept though the FAT keeps only seconds); list,
    get; a put whose sizes do not add up (refused, then the connection
    closed); --mirror (what the client lacks deleted, its folders too);
    paths, project names, a project not pushed; jobs: hello run, its log
    followed to its end, done; `jobs` with ids; one again by the same id;
    admin, --cwd and a word with a space refused; spin past its
    --timeout (failed, why); spin stopped; a program pushed into the project
    and run from there; one left running;
  - the second: `fleet` again: a new `since`; the job left running is lost,
    the others as they ended, their logs still there; the push's files
    still need nothing.
Skipped (passing) if there is no nightly toolchain. Outputs go to
build/test/fleet/.
"""
import hashlib
import json
import pathlib
import secrets
import socket
import ssl
import subprocess
import sys
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "test"))
sys.path.insert(0, str(ROOT / "tools"))
from qemu import boot  # noqa: E402
import mkstick  # noqa: E402

OUT = ROOT / "build" / "test" / "fleet"
FAILS = 0
NAME = "axiom-test"
PORT = 47950                            # the guest's, FORWARD forwarded to it
TOKEN = secrets.token_hex(32)


def result(ok, text):
    global FAILS
    FAILS += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + text)
    return ok


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


FORWARD = free_port()


def identity():
    """A P-256 key (PKCS #8) and a self-signed certificate, CN "fleet node
    NAME", as fleet makes a node's -> (key.pem, cert.pem, the pin)."""
    key, cert = OUT / "key.pem", OUT / "cert.pem"
    subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256",
                    "-out", str(key)], check=True, capture_output=True)
    subprocess.run(["openssl", "req", "-new", "-x509", "-key", str(key), "-out", str(cert), "-days", "30",
                    "-subj", f"/CN=fleet node {NAME}", "-sha256"], check=True, capture_output=True)
    der = ssl.PEM_cert_to_DER_cert(cert.read_text())
    return key.read_bytes(), cert.read_bytes(), hashlib.sha256(der).hexdigest()


class Refused(Exception):
    pass


class Conn:
    """fleet's Channel, as its client has it: JSON lines, raw bytes after."""

    def __init__(self, pin, token=TOKEN, protocol=1):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        self.s = ctx.wrap_socket(socket.create_connection(("127.0.0.1", FORWARD), timeout=60))
        der = self.s.getpeercert(binary_form=True)
        if hashlib.sha256(der).hexdigest() != pin:
            raise Refused("not the pinned certificate")
        self.f = self.s.makefile("rwb")
        self.n = 0
        self.send({"fleet": protocol, "token": token, "client": "test-host"})
        self.hello = self.recv()[0]
        if "error" in self.hello:
            raise Refused(self.hello["error"])

    def send(self, msg, data=b""):
        if data:
            msg = {**msg, "bytes": len(data)}
        self.f.write(json.dumps(msg, separators=(",", ":")).encode() + b"\n" + data)
        self.f.flush()

    def recv(self):
        line = self.f.readline(64 << 20)
        if not line:
            raise ConnectionError("the connection closed")
        msg = json.loads(line)
        return msg, self.f.read(int(msg.get("bytes") or 0))

    def ask(self, op, data=b"", **fields):
        self.n += 1
        self.send({"op": op, "id": self.n, **fields}, data)
        msg, got = self.recv()
        if msg.get("id") != self.n:
            raise ConnectionError(f"answered out of turn: {msg}")
        return msg, got

    def put(self, project, files):
        """files: {path: (bytes, mtime_ns)}"""
        entries = [[p, len(d), t] for p, (d, t) in files.items()]
        self.n += 1
        self.send({"op": "put", "id": self.n, "project": project, "files": entries,
                   "bytes": sum(e[1] for e in entries)})
        for d, _ in files.values():
            self.f.write(d)
        self.f.flush()
        return self.recv()[0]

    def log(self, job, follow=True, offset=0, tail=0):
        """A job's log -> (its text, the final message)."""
        self.n += 1
        self.send({"op": "log", "id": self.n, "job": job, "offset": offset, "follow": follow, "tail": tail})
        text = b""
        while True:
            msg, got = self.recv()
            if "error" in msg:
                return text, msg
            text += got
            if not msg.get("more"):
                return text, msg

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass


def wait_for(log_path, started, text, seconds=240):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            if log_path.stat().st_mtime >= started and text in log_path.read_text(errors="replace"):
                return True
        except OSError:
            pass
        time.sleep(0.3)
    return False


T0 = 1_790_000_000_123_456_789          # times as a Linux client's, to the nanosecond
FILES = {
    "a.txt": (b"hello", T0),
    "sub/b.bin": (bytes(range(256)) * 800, T0 + 1_000_000_001),
    "deep/x/y/z.txt": (b"zed", T0 + 7),
}
first = {}                              # what the first boot's client found
second = {}


def entries(files):
    return [[p, len(d), t] for p, (d, t) in files.items()]


def client_one(log_path, started, pin):
    r = first
    if not wait_for(log_path, started, f"fleet: node {NAME} listening"):
        r["error"] = "the node never listened"
        return
    try:
        try:
            Conn(pin, token="0" * 64)
        except Refused as e:
            r["wrong token"] = str(e)
        try:
            Conn(pin, protocol=2)
        except Refused as e:
            r["protocol 2"] = str(e)
        c = Conn(pin)
        r["hello"] = c.hello
        r["ping"] = c.ask("ping")[0]
        r["info"] = c.ask("info")[0]
        r["unknown"] = c.ask("frobnicate")[0]
        r["ping after"] = c.ask("ping")[0]

        r["manifest"] = c.ask("manifest", project="demo", files=entries(FILES))[0]
        r["put"] = c.put("demo", FILES)
        r["manifest again"] = c.ask("manifest", project="demo", files=entries(FILES))[0]
        r["list"] = c.ask("list", project="demo")[0]
        r["list sub"] = c.ask("list", project="demo", path="sub")[0]
        msg, got = c.ask("get", project="demo", files=["sub/b.bin", "a.txt"])
        r["get"] = (msg, got)
        r["bad path"] = c.ask("manifest", project="demo", files=[["../x", 1, 0]])[0]
        r["bad project"] = c.ask("list", project="bad name")[0]
        r["no project"] = c.ask("list", project="nope")[0]
        r["no file"] = c.ask("list", project="demo", path="nothing/here")[0]
        c.n += 1                        # sizes that do not add up, and no bytes sent
        c.send({"op": "put", "id": c.n, "project": "demo", "files": [["q.txt", 5, T0]], "bytes": 9})
        r["bad put"] = c.recv()[0]
        try:
            r["after bad put"] = c.recv()[0]
        except (ConnectionError, OSError) as e:
            r["after bad put"] = type(e).__name__
        c.close()

        c = Conn(pin)
        extra = {"gone/one.txt": (b"1", T0), "gone/deeper/two.txt": (b"2", T0)}
        c.put("demo", extra)
        r["mirror"] = c.ask("manifest", project="demo", files=entries(FILES), mirror=True)[0]
        r["after mirror"] = c.ask("list", project="demo")[0]
        r["mirror folders"] = c.ask("list", project="demo", path="gone")[0]

        r["start"] = c.ask("start", job="j1", project="demo", argv=["hello", "one", "two"], env={"A": "b"})[0]
        r["j1 log"] = c.log("j1")
        r["jobs ids"] = c.ask("jobs", ids=["j1", "zzz"])[0]
        r["again"] = c.ask("start", job="j1", project="demo", argv=["hello"], env={})[0]
        r["admin"] = c.ask("start", job="j2", project="demo", argv=["hello"], env={}, admin=True)[0]
        r["cwd"] = c.ask("start", job="j3", project="demo", argv=["hello"], env={}, cwd="sub")[0]
        r["space"] = c.ask("start", job="j4", project="demo", argv=["hello", "two words"], env={})[0]
        r["bad id"] = c.ask("start", job="no/slash", project="demo", argv=["hello"], env={})[0]
        r["not pushed"] = c.ask("start", job="j5", project="nope", argv=["hello"], env={})[0]
        r["missing"] = c.ask("start", job="j6", project="demo", argv=["nothing-here"], env={})[0]
        r["missing log"] = c.log("j6")

        c.ask("start", job="slow", project="demo", argv=["spin"], env={}, timeouts={"total_s": 2})
        t = time.time()
        r["slow log"] = c.log("slow")
        r["slow took"] = time.time() - t
        c.ask("start", job="stopme", project="demo", argv=["spin"], env={})
        time.sleep(0.5)
        r["running"] = c.ask("jobs", ids=["stopme"])[0]
        r["stop"] = c.ask("stop", job="stopme")[0]

        hello = (ROOT / "build" / "esp" / "EFI" / "AXIOM" / "HELLO.AXE").read_bytes()
        r["put program"] = c.put("demo", {"bin/hi.axe": (hello, T0)})
        c.ask("start", job="pushed", project="demo", argv=["bin/hi.axe", "from", "a", "push"], env={})
        r["pushed log"] = c.log("pushed")

        c.ask("start", job="forever", project="demo", argv=["spin"], env={})
        time.sleep(0.5)
        r["info busy"] = c.ask("info")[0]
        r["jobs"] = c.ask("jobs")[0]
        r["recent"] = c.ask("jobs", recent=1)[0]
        r["tail"] = c.log("j1", follow=False, tail=6)
        c.ask("start", job="last", project="demo", argv=["hello", "the-end"], env={})
        c.close()
    except Exception as e:  # noqa: BLE001 (said, and the checks fail)
        r["error"] = repr(e)


def client_two(log_path, started, pin):
    r = second
    if not wait_for(log_path, started, f"fleet: node {NAME} listening"):
        r["error"] = "the node never listened"
        return
    try:
        c = Conn(pin)
        r["hello"] = c.hello
        r["jobs"] = c.ask("jobs", ids=["forever", "j1", "slow"])[0]
        r["j1 log"] = c.log("j1")
        r["manifest"] = c.ask("manifest", project="demo", files=entries(FILES))[0]
        c.ask("start", job="last2", project="demo", argv=["hello", "the-end"], env={})
        c.close()
    except Exception as e:  # noqa: BLE001
        r["error"] = repr(e)


def script(last):
    return ["until log: kept in", "until dhcp: address", "wait 0.5",
            "type fleet\\n", f"until fleet: node {NAME} listening", f"until fleet: job {last} ended", "wait 1"]


def by_id(jobs):
    return {j["id"]: j for j in jobs}


def check(log1, log2):
    def has(log, text):
        return text in log

    r = first
    result("error" not in r, f"the first boot's client: {r.get('error', 'no exceptions')}")
    result(r.get("wrong token") == "not_authorized", f"a wrong token: {r.get('wrong token')!r}")
    result(r.get("protocol 2") == "protocol 2 not spoken here", f"another protocol: {r.get('protocol 2')!r}")
    h = r.get("hello", {})
    result(h.get("ok") is True and h.get("node") == NAME and h.get("protocol") == 1
           and isinstance(h.get("since"), float) and len(h.get("code", "")) == 12
           and all(ch in "0123456789abcdef" for ch in h.get("code", "x")), f"the hello's reply: {h}")
    result(r.get("ping") == {"id": 1, "ok": True}, f"ping: {r.get('ping')}")
    i = r.get("info", {})
    result(i.get("os") == "axiom" and i.get("threads") == 2 and i.get("ram_gb", 0) > 0.5
           and 0 < i.get("disk_free_gb", 0) <= i.get("disk_total_gb", 0) and i.get("gpus") == []
           and i.get("admin") is False and i.get("battery") is None and i.get("jobs_running") == 0
           and i.get("projects_running") == [] and i.get("uptime_s", 0) > 0,
           f"info: {json.dumps(i)[:400]}")
    result(r.get("unknown") == {"id": 3, "error": "unknown operation 'frobnicate'"} and
           r.get("ping after", {}).get("ok") is True, f"an unknown operation, then on: {r.get('unknown')}")

    m = r.get("manifest", {})
    result(m == {"id": 5, "need": list(FILES), "deleted": 0, "kept": [], "kept_count": 0, "partial": {}},
           f"manifest: all needed: {m}")
    result(r.get("put") == {"id": 6, "ok": True, "count": 3}, f"put: {r.get('put')}")
    result(r.get("manifest again", {}).get("need") == [], f"manifest again: nothing needed, the times kept: "
           f"{r.get('manifest again')}")
    want = sorted([p, len(d), t] for p, (d, t) in FILES.items())
    result(r.get("list", {}).get("files") == want, f"list: {r.get('list')}")
    result(r.get("list sub", {}).get("files") == [["sub/b.bin", 204800, T0 + 1_000_000_001]],
           f"list below a folder: {r.get('list sub')}")
    msg, got = r.get("get", ({}, b""))
    result(msg.get("files") == [["sub/b.bin", 204800, T0 + 1_000_000_001], ["a.txt", 5, T0]]
           and msg.get("bytes") == 204805 and got == FILES["sub/b.bin"][0] + b"hello",
           f"get: {msg}, {len(got)} bytes back")
    result(r.get("bad path", {}).get("error") == "path not allowed: '../x'", f"a path out: {r.get('bad path')}")
    result(r.get("bad project", {}).get("error") == "project name not allowed: 'bad name'",
           f"a project's name: {r.get('bad project')}")
    result(r.get("no project", {}).get("error") == f"no project nope on {NAME}: push it first",
           f"a project not pushed: {r.get('no project')}")
    result(r.get("no file", {}).get("error") == f"no nothing/here in project demo on {NAME}",
           f"list of nothing: {r.get('no file')}")
    result(r.get("bad put", {}).get("error") == "the files' sizes do not add up to the bytes sent"
           and r.get("after bad put") in ("ConnectionError", "ConnectionResetError", "SSLEOFError", "OSError"),
           f"a put that does not add up: {r.get('bad put')}, then {r.get('after bad put')}")

    result(r.get("mirror", {}).get("deleted") == 2 and r.get("mirror", {}).get("need") == [],
           f"--mirror: {r.get('mirror')}")
    result(r.get("after mirror", {}).get("files") == want, f"after it: {r.get('after mirror')}")
    result(r.get("mirror folders", {}).get("error") == f"no gone in project demo on {NAME}",
           f"its folders gone too: {r.get('mirror folders')}")

    s = r.get("start", {})
    result(s.get("job") == "j1" and s.get("node") == NAME and isinstance(s.get("pid"), int) and s["pid"] > 0,
           f"start: {s}")
    text, end = r.get("j1 log", (b"", {}))
    j = end.get("job", {})
    result(b"hello: arguments: one two" in text and end.get("more") is False and end.get("offset") == len(text)
           and j.get("state") == "done" and j.get("exit") == 0 and j.get("log_bytes") == len(text)
           and j.get("argv") == ["hello", "one", "two"] and j.get("client") == "test-host"
           and j.get("admin") is False and j.get("started", "").endswith("+00:00"),
           f"its log, followed to its end: {text[-80:]!r}, {end}")
    ji = r.get("jobs ids", {})
    result(ji.get("only") is True and [x["id"] for x in ji.get("jobs", [])] == ["j1"]
           and list(ji["jobs"][0]) == [k for k in ("id", "project", "argv", "state", "exit", "started", "ended",
                                                   "client", "log_bytes", "user", "admin", "limits", "reason",
                                                   "yields", "service", "timeouts") if k in ji["jobs"][0]],
           f"jobs with ids: {ji}")
    result(r.get("again", {}).get("error") == f"job j1 already exists on {NAME}", f"the same id: {r.get('again')}")
    result("takes no admin jobs" in r.get("admin", {}).get("error", ""), f"admin: {r.get('admin')}")
    result("--cwd" in r.get("cwd", {}).get("error", ""), f"--cwd: {r.get('cwd')}")
    result("'two words'" in r.get("space", {}).get("error", ""), f"a word with a space: {r.get('space')}")
    result(r.get("bad id", {}).get("error") == "job id not allowed: 'no/slash'", f"a job's id: {r.get('bad id')}")
    result(r.get("not pushed", {}).get("error") == f"no project nope on {NAME}: push it first",
           f"a job in a project not pushed: {r.get('not pushed')}")
    text, end = r.get("missing log", (b"", {}))
    result(r.get("missing", {}).get("job") == "j6" and end.get("job", {}).get("state") == "failed"
           and b"could not start nothing-here" in text, f"a program that is not there: {text!r}, {end}")

    text, end = r.get("slow log", (b"", {}))
    j = end.get("job", {})
    result(j.get("state") == "failed" and j.get("reason") == "timed out: still running after 2 s (--timeout)"
           and j.get("exit") == -12 and j.get("timeouts") == {"total_s": 2} and 1.5 < r.get("slow took", 0) < 8,
           f"--timeout: {end}, {r.get('slow took', 0):.1f} s")
    run = r.get("running", {}).get("jobs", [{}])[0]
    st = r.get("stop", {}).get("job", {})
    result(run.get("state") == "running" and st.get("state") == "stopped" and st.get("id") == "stopme",
           f"stop: {run.get('state')}, then {st}")
    text, end = r.get("pushed log", (b"", {}))
    result(r.get("put program", {}).get("ok") is True and b"hello: arguments: from a push" in text
           and end.get("job", {}).get("state") == "done", f"a program pushed and run: {text[-60:]!r}")
    ib = r.get("info busy", {})
    result(ib.get("jobs_running") == 1 and ib.get("projects_running") == ["demo"] and ib.get("projects") == ["demo"],
           f"info with a job running: {ib.get('jobs_running')}, {ib.get('projects_running')}")
    every = by_id(r.get("jobs", {}).get("jobs", []))
    result(set(every) == {"j1", "j6", "slow", "stopme", "pushed", "forever"} and "only" not in r.get("jobs", {})
           and every["forever"]["state"] == "running", f"jobs: {sorted(every)}")
    recent = [x["id"] for x in r.get("recent", {}).get("jobs", [])]
    result(recent == ["pushed", "forever"], f"jobs, recent 1: {recent}")
    text, end = r.get("tail", (b"", {}))
    result(text == b"o two\n" or len(text) == 6, f"log's tail: {text!r}")
    result(has(log1, "fleet: started job j1 in demo: hello one two") and has(log1, "fleet: stopped job stopme"),
           "the node says what it starts and stops")
    for secret in (TOKEN, hashlib.sha256(TOKEN.encode()).hexdigest()):
        result(secret not in log1 and secret not in log2, "the token is in neither log, nor its hash")

    r = second
    result("error" not in r, f"the second boot's client: {r.get('error', 'no exceptions')}")
    result(r.get("hello", {}).get("since", 0) > first.get("hello", {}).get("since", 0),
           f"since: a new start ({r.get('hello', {}).get('since')})")
    j = by_id(r.get("jobs", {}).get("jobs", []))
    result(j.get("forever", {}).get("state") == "lost" and j.get("j1", {}).get("state") == "done"
           and j.get("slow", {}).get("state") == "failed", f"after a restart: {j}")
    text, end = r.get("j1 log", (b"", {}))
    result(b"hello: arguments: one two" in text and end.get("job", {}).get("state") == "done",
           f"a log from before: {text[-40:]!r}")
    result(r.get("manifest", {}).get("need") == [], f"the push still needs nothing: {r.get('manifest')}")
    result(has(log2, "fleet: job forever was running when the node last ended: lost"), "the node says so")


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
    key, cert, pin = identity()
    config = {"name": NAME, "port": PORT, "self_managed": True,
              "clients": [{"name": "test-host", "token_sha256": hashlib.sha256(TOKEN.encode()).hexdigest()}],
              "allow": ["10.0.2.0/24"]}
    stick = OUT / "stick.img"
    mkstick.build(stick, 0x464C4554, extra={"Home": {"fleet": {
        "node.json": json.dumps(config).encode(), "cert.pem": cert, "key.pem": key}}})
    (OUT / "key.pem").unlink()           # a key, if only a test's: not left about
    fwd = f"user,hostfwd=tcp:127.0.0.1:{FORWARD}-:{PORT}"
    args = ["--smp", "2", "--nic", "rtl8139", "--netdev", fwd, "--stick", stick.relative_to(ROOT).as_posix()]
    logs = []
    for client, last in ((client_one, "last"), (client_two, "last2")):
        name = f"fleet-{len(logs) + 1}"
        (OUT / f"{name}.log").unlink(missing_ok=True)    # (the last run's would do for this one's)
        started = time.time()
        t = threading.Thread(target=client, args=(OUT / f"{name}.log", started, pin), daemon=True)
        t.start()
        log, _, took = boot(OUT, name, script(last), *args, timeout=150, slots=1)
        print(f"      ({name} {took:.0f} s)")
        t.join(5)
        logs.append(log)
    check(*logs)
    print(f"{'all passed' if not FAILS else f'{FAILS} FAILED'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
