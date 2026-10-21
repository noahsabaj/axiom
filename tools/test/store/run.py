#!/usr/bin/env python3
"""Axiom's object store (store.asm) in QEMU, its drive read back here.

    python tools/test/store/run.py [--quick]

Boots:
  - first: a blank NVMe drive (serial AXIOMTEST) and the boot stick: no
    store; 'store format'; names put, diffed, committed, snapshotted,
    changed, removed, rolled back; 'store test'; STASH checking itself
    through its capability, then 'stash put'; 'store verify'; last a commit
    torn short of its superblock ('store tear'). Then the drive is read
    here, by a reader of its own: both superblocks, every journal record,
    every object's SHA-256, the chain of commits, who made each and why,
    the head's names and what they hold, the torn commit past the log's
    end and not in the head;
  - again: the same drive: the store as it was left, the torn commit
    nowhere, STASH's names still there, 'store verify', and the drive not
    written to by reading;
  - damaged: a copy, its newer superblock broken: the older one used, said
    so; a commit then mends the broken slot;
  - readonly: a store written here, on a drive with another serial:
    mounted, read-only; writes, 'store format' and 'store test' refused; the
    drive untouched;
  - (unless --quick) tcg: 'store format', 'store test' under QEMU's own CPU
    emulation.
Outputs go to build/test/store/.
"""
import argparse
import hashlib
import pathlib
import re
import shutil
import struct
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "test"))
from qemu import boot_all  # noqa: E402

OUT = ROOT / "build" / "test" / "store"
FAILS = 0
SIZE = 64 << 20
BLOCK = 4096
NL = "\\n"


def result(ok, text):
    global FAILS
    FAILS += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + text)
    return ok


def nvme(img, serial="AXIOMTEST"):
    return (f"-drive file={img.as_posix()},if=none,id=nvm,format=raw "
            f"-device nvme,serial={serial},drive=nvm")


def sha(b):
    return hashlib.sha256(b).digest()


# -----------------------------------------------------------------------------
#  The format, read and written here (store.asm's SU_*, JR_*, TR_*, CM_*)
# -----------------------------------------------------------------------------

def superblock(b):
    """None if no superblock, False if a damaged one, else its fields."""
    if b[:8] != b"AXSTORE1":
        return None
    if sha(b[:4064]) != b[4064:4096]:
        return False
    version, shift, gen, blocks, nxt, journal, seq, objects = struct.unpack_from("<IIQQQQQQ", b, 8)
    if version != 1 or shift != 12:
        return False
    snaps = {}
    for i in range(32):
        e = b[128 + i * 64:192 + i * 64]
        if e[0]:
            snaps[e[:24].rstrip(b"\0").decode()] = (struct.unpack_from("<Q", e, 24)[0], e[32:64])
    return dict(gen=gen, blocks=blocks, next=nxt, journal=journal, seq=seq, objects=objects,
                head=b[64:96], bytes=struct.unpack_from("<Q", b, 120)[0], snaps=snaps)


def journal_record(img, block):
    """(seq, prev, commit hash, [(hash, block, bytes, kind)], whole) of the record there."""
    b = img[block * BLOCK:(block + 1) * BLOCK]
    if b[:8] != b"AXJRNL01":
        return None
    seq, prev, count, blocks = struct.unpack_from("<QQII", b, 8)
    rec = bytearray(img[block * BLOCK:(block + blocks) * BLOCK])
    summed = bytes(rec[64:96])
    rec[64:96] = bytes(32)
    whole = sha(bytes(rec)) == summed
    entries = [(bytes(rec[128 + i * 48:160 + i * 48]),) + struct.unpack_from("<QII", rec, 160 + i * 48)
               for i in range(count)]
    return seq, prev, bytes(rec[32:64]), entries, whole


def commit(b):
    seq, time, task = struct.unpack_from("<QQQ", b, 8)
    cap, rights, kind, added, changed, removed, names, target = struct.unpack_from("<QIIIIIIQ", b, 120)
    text = lambda f: f.split(b"\0")[0].decode()
    return dict(seq=seq, time=time, task=task, parent=b[32:64], tree=b[64:96], who=text(b[96:120]),
                cap=cap, rights=rights, kind=kind, added=added, changed=changed, removed=removed,
                names=names, target=target, prefix=text(b[160:224]), reason=text(b[224:480]))


def tree(b):
    assert b[:8] == b"AXTREE01"
    count = struct.unpack_from("<I", b, 8)[0]
    out = {}
    for i in range(count):
        e = b[16 + i * 128:16 + (i + 1) * 128]
        out[e[:64].rstrip(b"\0").decode()] = (e[64:96], struct.unpack_from("<Q", e, 96)[0])
    return out


class Store:
    """A store read from an image, every object checked on the way."""

    def __init__(self, img):
        self.img = img
        self.slots = [superblock(img[0:BLOCK]), superblock(img[BLOCK:2 * BLOCK])]
        whole = [s for s in self.slots if s]
        self.sb = max(whole, key=lambda s: s["gen"]) if whole else None
        self.objects = {}                   # hash -> (block, bytes, kind)
        self.chain = {0: bytes(32)}
        self.bad = []
        if not self.sb:
            return
        block, seq = self.sb["journal"], self.sb["seq"]
        while block:
            r = journal_record(img, block)
            if not r or not r[4] or r[0] != seq:
                self.bad.append(f"journal record at block {block}")
                break
            for h, at, n, kind in r[3]:
                if sha(img[at * BLOCK:at * BLOCK + n]) != h:
                    self.bad.append(f"object at block {at}")
                self.objects[h] = (at, n, kind)
            self.chain[seq] = r[2]
            block, seq = r[1], seq - 1
        if seq != 0:
            self.bad.append(f"the journal ends at commit {seq}")

    def get(self, h):
        at, n, kind = self.objects[h]
        return self.img[at * BLOCK:at * BLOCK + n], kind

    def commit(self, seq):
        return commit(self.get(self.chain[seq])[0])

    def tree(self, seq):
        if seq == 0:
            return {}
        return tree(self.get(self.commit(seq)["tree"])[0])

    def names(self, seq=None):
        """{name: bytes held} at a commit (the head's by default)."""
        t = self.tree(self.sb["seq"] if seq is None else seq)
        return {n: self.get(h)[0] for n, (h, _) in t.items()}


def mkstore(path, blocks):
    """An empty store, as 'store format' makes one."""
    img = bytearray(blocks * BLOCK)
    for gen in (0, 1):
        sb = bytearray(BLOCK)
        sb[:8] = b"AXSTORE1"
        struct.pack_into("<IIQQQQQQ", sb, 8, 1, 12, gen, blocks, 2, 0, 0, 0)
        sb[96:112] = b"made by run.py!!"
        sb[4064:4096] = sha(bytes(sb[:4064]))
        img[gen * BLOCK:(gen + 1) * BLOCK] = sb
    path.write_bytes(img)


# -----------------------------------------------------------------------------
#  Boots
# -----------------------------------------------------------------------------

FIRST = ["until Type 'help'", "wait 1",
         "type store" + NL, "wait 0.3",
         "type store format" + NL, "until store: disk", "wait 0.5",
         "type store format" + NL, "wait 0.3",
         "type store put a.txt hello" + NL, "wait 0.2",
         "type store put b.txt world" + NL, "wait 0.2",
         "type store put c.txt hello" + NL, "wait 0.2",
         "type store diff" + NL, "until store diff:", "wait 0.2",
         "type store commit first three" + NL, "until store: commit #1", "wait 0.3",
         "type store snap one" + NL, "until store: snapshot", "wait 0.2",
         "type store put a.txt changed" + NL, "wait 0.2",
         "type store rm b.txt" + NL, "wait 0.2",
         "type store rm nothing.txt" + NL, "wait 0.2",
         "type store commit second" + NL, "until store: commit #2", "wait 0.3",
         "type store diff one" + NL, "until store diff #", "wait 0.2",
         "type store rollback one" + NL, "until store: commit #3", "wait 0.3",
         "type store undo" + NL, "until store: commit #4", "wait 0.3",
         "type store rollback 3 back again" + NL, "until store: commit #5", "wait 0.3",
         "type store get a.txt" + NL, "until store: a.txt,", "wait 0.3",
         "type store log 3" + NL, "until store log:", "wait 0.5",
         "type store test" + NL, "until store test: ", "until store test: ", "wait 1",
         "type run stash" + NL, "until run: STASH ", "wait 0.5",
         "type run stash put hi there you" + NL, "until run: STASH ", "wait 0.5",
         "type store verify" + NL, "until store verify: p", "wait 0.5",
         "type store put t.txt torn" + NL, "wait 0.2",
         "type store tear never happened" + NL, "until written up to", "wait 0.5",
         "type store" + NL, "until superblock generation", "wait 0.5",
         "type store nonsense" + NL, "until usage", "wait 0.2",
         "type poweroff" + NL, "ended"]

AGAIN = ["until log: kept in", "wait 1",
         "type store log 2" + NL, "until store log:", "wait 0.5",
         "type store get a.txt" + NL, "until store: a.txt,", "wait 0.3",
         "type store ls" + NL, "until names", "wait 0.3",
         "type store snap" + NL, "until snapshots listed", "wait 0.3",
         "type run stash ls" + NL, "until run: STASH ", "wait 0.5",
         "type run stash get hi" + NL, "until run: STASH ", "wait 0.5",
         "type store verify" + NL, "until store verify: p", "wait 0.5",
         "type poweroff" + NL, "ended"]

DAMAGED = ["until Type 'help'", "wait 1",
           "type store verify" + NL, "until store verify: F", "wait 0.3",
           "type store put z.txt after the damage" + NL, "wait 0.2",
           "type store commit after the damage" + NL, "until store: commit #", "wait 0.5",
           "type store verify" + NL, "until store verify: p", "wait 0.5",
           "type poweroff" + NL, "ended"]

READONLY = ["until Type 'help'", "wait 1",
            "type store" + NL, "until generation", "wait 0.3",
            "type store put x.txt nope" + NL, "until store put:", "wait 0.2",
            "type store commit nope" + NL, "until store commit", "wait 0.2",
            "type store format" + NL, "until store format:", "wait 0.2",
            "type store test" + NL, "until store test:", "wait 0.2",
            "type store verify" + NL, "until store verify: p", "wait 0.3",
            "type poweroff" + NL, "ended"]

TCG = ["until Type 'help'", "wait 1",
       "type store format" + NL, "until store: disk", "wait 0.5",
       "type store test" + NL, "until store test: ", "until store test: ", "wait 1",
       "type poweroff" + NL, "ended"]


def common(name, log, err):
    result("AXIOM PANIC" not in log, f"{name}: no panic")
    result("QEMU ended by itself" in err, f"{name}: powered off")


def first(log, err, img):
    print("-- first: a store made, used, checked, torn")
    common("first", log, err)
    result("store: none on any drive" in log, "first: no store at boot")
    result(re.search(r"store: disk\d formatted: 64\.0 MiB, 16384 blocks", log), "first: formatted")
    result("holds a store already ('store format again'" in log, "first: a second 'store format' refused")
    result(re.search(r"^  \+ a\.txt, 5 bytes$", log, re.M) and "store diff: 3 changes staged, 0 of them in conflict" in log,
           "first: 'store diff' shows what is staged")
    result(re.search(r"^  #1 [0-9a-f]{16}  \d{4}-\d\d-\d\d \d\d:\d\d:\d\d  console, task \d+, capability 0 \(all\) "
                     r"on everything: \+3 ~0 -0, 3 names$", log, re.M), "first: commit #1, by the console, +3")
    result("store rm: no such name" in log, "first: removing a name nobody has: refused")
    result(re.search(r"^  ~ a\.txt, 7 bytes \(was 5\)$", log, re.M) and re.search(r"^  - b\.txt$", log, re.M)
           and "store diff #1 #2: +0 ~1 -1" in log, "first: 'store diff one': a changed, b removed")
    result(re.search(r"^      back to #1$", log, re.M), "first: rolled back to 'one' (#3)")
    result(re.search(r"#4 .*\n      back to #2; why: undo", log), "first: 'store undo' (#4): back to #2")
    result(re.search(r"#5 .*\n      back to #3; why: back again", log), "first: and again (#5)")
    result(re.search(r"store: a\.txt, 5 bytes:\nhello\n", log), "first: a.txt holds hello")
    m = re.search(r"store test: (\d+) checks, (\d+) failed", log)
    result(m and m.group(2) == "0" and "store test: passed" in log,
           f"first: store test passed, {m.group(1)} checks" if m else "first: store test")
    result(re.search(r"stash: all \d+ checks passed\nrun: STASH exited with 0", log), "first: STASH checked itself")
    result(re.search(r"stash: committed, #\d+", log), "first: 'stash put' committed")
    result(re.search(r"store verify: \d+ objects \(.*\) read back whole, \d+ commits each on the one before, 0 things wrong", log)
           and "store verify: passed" in log, "first: store verify passed")
    m = re.search(r"store: commit #(\d+) written up to its superblock, which was not", log)
    result(m, "first: a commit torn short of its superblock")
    torn = int(m.group(1)) if m else 0
    m = re.search(r"store: disk\d: (\d+) commits, (\d+) names, (\d+) objects; .*; writable\n.*\n.*\nstore: (\d+) snapshots", log)
    said = int(m.group(1)) if m else -1
    result(said == torn - 1, f"first: after it, the store says {said} commits, one before the torn one")
    result("usage: store [put" in log, "first: 'store nonsense': the usage")

    print("-- first: the drive, read here")
    s = Store(img.read_bytes())
    result(all(s.slots), "both superblocks whole")
    result(s.sb and s.sb["seq"] == said, f"the newer says {s.sb['seq'] if s.sb else '-'} commits, as the kernel did")
    result(not s.bad, "every journal record whole, every object its SHA-256" + (f": {s.bad}" if s.bad else ""))
    if not s.sb or s.bad:
        return s, torn
    result(len(s.objects) == s.sb["objects"], f"{len(s.objects)} objects in the journal, as the superblock says")
    blobs = [h for h, (_, _, k) in s.objects.items() if k == 1]
    result(sha(b"hello") in blobs and len(blobs) == len(set(blobs)), "hello stored once, though three names held it")
    ok = True
    for n in range(1, s.sb["seq"] + 1):
        c = s.commit(n)
        ok &= c["seq"] == n and c["parent"] == s.chain[n - 1] and c["names"] == len(s.tree(n))
    result(ok, "each commit numbered, on the one before, its tree as many names as it says")
    names = s.names()
    want = {"a.txt": b"hello", "b.txt": b"world", "c.txt": b"hello", "stash/greeting": b"hello from ring 3",
            "stash/c/k": b"hello from ring 3", "stash/hi": b"there you"}
    result(names == want, f"the head holds {sorted(names)}, each as it should")
    result(s.tree(5) == s.tree(3) and s.commit(5)["tree"] == s.commit(3)["tree"],
           "#5 (back to #3) is #3's tree, the same object")
    c1 = s.commit(1)
    result(c1["who"] == "console" and c1["cap"] == 0 and c1["prefix"] == "" and c1["reason"] == "first three"
           and (c1["added"], c1["changed"], c1["removed"]) == (3, 0, 0), "#1: the console, all, 'first three', +3")
    c4 = s.commit(4)
    result(c4["kind"] == 1 and c4["target"] == 2 and c4["reason"] == "undo", "#4: a rollback to #2, 'undo'")
    st = [s.commit(n) for n in range(1, s.sb["seq"] + 1) if s.commit(n)["who"] == "STASH"]
    result(st and all(c["prefix"].startswith("stash/") and c["cap"] and c["task"] for c in st),
           f"{len(st)} commits by STASH, each through a capability under stash/, its task named")
    put = [c for c in st if c["reason"] == "stash put hi"]
    result(put and put[0]["rights"] & 0xF00 == 0xF00, "'stash put hi': why, and the rights it had")
    result("one" in s.sb["snaps"] and s.sb["snaps"]["one"][0] == 1 and s.sb["snaps"]["one"][1] == s.chain[1]
           and "test-1" not in s.sb["snaps"], "snapshot 'one' is #1; the test's own is gone")
    at = s.sb["next"]                       # its objects, then its record, past the log's end
    while at < s.sb["blocks"] and s.img[at * BLOCK:at * BLOCK + 8] != b"AXJRNL01":
        at += 1
    r = journal_record(s.img, at) if at < s.sb["blocks"] else None
    result(r and r[0] == torn and r[4] and r[1] == s.sb["journal"],
           f"the torn commit's record is whole (block {at}), past the log's end (block {s.sb['next']})")
    cm = [e for e in (r[3] if r else []) if e[3] == 3]
    tc = commit(s.img[cm[0][1] * BLOCK:][:512]) if cm else {}
    result(tc.get("reason") == "never happened" and "t.txt" not in names, "it is 'never happened', and t.txt is in no commit")
    return s, torn


def again(log, err, s, before, after):
    print("-- again: the same drive")
    common("again", log, err)
    seq = s.sb["seq"] if s and s.sb else -1
    result(re.search(rf"store: disk\d: {seq} commits, 6 names, \d+ objects", log), f"mounted: {seq} commits, 6 names")
    result(re.search(rf"^  #{seq} ", log, re.M) and f"#{seq + 1} " not in log, "the log ends before the torn commit")
    result(re.search(r"store: a\.txt, 5 bytes:\nhello\n", log), "a.txt holds hello")
    result(re.search(r"^  one\s+#1 ", log, re.M), "snapshot 'one' is #1")
    result(re.search(r"stash: names: 3\nc/k\ngreeting\nhi\n", log), "STASH's names, without its prefix")
    result("there you" in log, "'stash get hi'")
    result("store verify: passed" in log, "store verify passed")
    result(before == after, "the drive is as it was: reading wrote nothing")


def damaged(log, err, img, older):
    print("-- damaged: the newer superblock broken")
    common("damaged", log, err)
    result(re.search(r"store: disk\d: superblock \d is damaged; the other is used", log), "said at boot")
    result(re.search(rf"store: disk\d: {older['seq']} commits", log), f"the older one used: {older['seq']} commits")
    result("store verify: a superblock is damaged" in log and "store verify: FAILED" in log, "store verify says so")
    result(re.search(rf"store: commit #{older['seq'] + 1}\b", log), f"a commit after it: #{older['seq'] + 1}")
    result("store verify: passed" in log, "then store verify passes")
    s = Store(img.read_bytes())
    result(all(s.slots) and not s.bad and s.sb["seq"] == older["seq"] + 1
           and s.names().get("z.txt") == b"after the damage", "both superblocks whole again; z.txt in the head")


def readonly(log, err, before, after):
    print("-- readonly: another drive's store")
    common("readonly", log, err)
    result(re.search(r"store: disk\d: 0 commits, 0 names, 0 objects; 8\.0 KiB of 16\.0 MiB used; "
                     r"read-only \(not QEMU's test drive\)", log), "a store written here, mounted read-only")
    result("store put: no store to write to" in log, "a put refused")
    result("store commit: no store to write to" in log, "a commit refused")
    result("store format: refused" in log, "'store format' refused")
    result("store test: no store to write to" in log, "'store test' refused")
    result("store verify: passed" in log, "store verify passes")
    result(before == after, "the drive is untouched")


def tcg(log, err):
    print("-- tcg")
    common("tcg", log, err)
    result("store test: passed" in log, "tcg: store test passed")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true", help="skip the TCG boot")
    opts = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    stick = OUT / "stick.img"
    subprocess.run([sys.executable, str(ROOT / "tools" / "mkstick.py"), str(stick)], cwd=ROOT,
                   check=True, capture_output=True)
    st = ["--stick", stick.relative_to(ROOT).as_posix()]
    a = OUT / "first.img"
    a.write_bytes(bytes(SIZE))
    ro = OUT / "readonly.img"
    mkstore(ro, 4096)
    ro_before = ro.read_bytes()
    jobs = {"first": (FIRST, ["--smp", "4", "--extra", nvme(a)] + st, 240, 1),
            "readonly": (READONLY, ["--smp", "2", "--extra", nvme(ro, "OTHERDISK")], 90)}
    if not opts.quick:
        t = OUT / "tcg.img"
        t.write_bytes(bytes(SIZE))
        jobs["tcg"] = (TCG, ["--smp", "2", "--accel", "tcg", "--extra", nvme(t)], 500)
    logs = boot_all(OUT, jobs)
    s, torn = first(*logs["first"], a)
    readonly(*logs["readonly"], ro_before, ro.read_bytes())
    if "tcg" in logs:
        tcg(*logs["tcg"])

    d = OUT / "damaged.img"                 # the newer superblock broken
    shutil.copyfile(a, d)
    data = bytearray(d.read_bytes())
    newer = (s.sb["gen"] & 1) if s and s.sb else 1
    data[newer * BLOCK + 200] ^= 0xFF
    d.write_bytes(data)
    older = s.slots[newer ^ 1] if s and s.sb else {"seq": -1}
    before = a.read_bytes()
    logs = boot_all(OUT, {"again": (AGAIN, ["--smp", "4", "--extra", nvme(a)] + st, 180),
                          "damaged": (DAMAGED, ["--smp", "2", "--extra", nvme(d)], 90)})
    again(*logs["again"], s, before, a.read_bytes())
    damaged(*logs["damaged"], d, older or {"seq": -1})
    print(f"{'all passed' if not FAILS else f'{FAILS} FAILED'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
