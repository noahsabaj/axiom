#!/usr/bin/env python3
"""Host tests for src/kernel/heap.asm: kmalloc and kfree.

    python tools/test/heap/run.py [--seed N] [--cc PATH]

Assembles heap.asm inside shim.asm as a win64 object (with stand-ins for
pmm and the vm region that track every page), links it with host.c into a
DLL and drives it with ctypes: every size class and the large objects
(alignment, zeroing, where each lands, the slab layout, a freed object's
poison, empty slabs given back), each kind of misuse (freed twice, not the
start of an object, never handed out, written after it was freed), random
operations from one thread and then from four at once with every object's
contents checked, the counters, register preservation, and a speed. Outputs
go to build/test/heap/. Exit status 0 only if every test passed.
"""
import argparse
import ctypes
import os
import pathlib
import random
import shutil
import subprocess
import sys
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[3]
HERE = pathlib.Path(__file__).resolve().parent
OUT = ROOT / "build" / "test" / "heap"
GCC = (r"C:\Users\noahs\AppData\Local\Microsoft\WinGet\Packages"
       r"\BrechtSanders.WinLibs.POSIX.UCRT_Microsoft.Winget.Source_8wekyb3d8bbwe"
       r"\mingw64\bin\gcc.exe")

FN = {"kmalloc": 0, "kfree": 1, "heap_init": 2, "s_bench": 3}
CLASSES = [16, 32, 64, 128, 256, 512, 1024]
HDR = 128
POOL_BYTES = 8192 * 4096
VPOOL_BYTES = 32768 * 4096
STATS = ("objects bytes slabs big big_bytes bad_count bad_addr bad_why pages_out vm_out "
         "errors pool vpool").split()
passes = fails = 0


def check(ok, text):
    global passes, fails
    if ok:
        passes += 1
    else:
        fails += 1
        print("FAIL " + text)
    return ok


def run(cmd, what):
    r = subprocess.run([str(c) for c in cmd], capture_output=True, text=True)
    if r.returncode:
        print((r.stdout + r.stderr).strip())
        sys.exit(f"{what} failed")


class Heap:
    def __init__(self, path):
        d = self.d = ctypes.CDLL(str(path))
        d.h_k.argtypes = [ctypes.c_int] + [ctypes.c_uint64] * 6 + [ctypes.POINTER(ctypes.c_int)]
        d.h_k.restype = ctypes.c_uint64
        d.h_regs.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_uint64),
                             ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_uint64)]
        d.h_stats.argtypes = [ctypes.POINTER(ctypes.c_uint64)]
        d.h_classes.restype = ctypes.c_void_p
        d.h_stress.argtypes = [ctypes.c_uint64, ctypes.c_int, ctypes.c_int, ctypes.c_uint64]
        d.h_stress.restype = ctypes.c_uint64

    def call(self, fn, *args):
        a = [int(x) & (2 ** 64 - 1) for x in args] + [0] * (6 - len(args))
        cf = ctypes.c_int()
        return self.d.h_k(FN[fn], *a, ctypes.byref(cf))

    def malloc(self, n):
        return self.call("kmalloc", n)

    def free(self, p):
        self.call("kfree", p)

    def regs(self, fn, *args):
        a = (ctypes.c_uint64 * 6)(*([int(x) for x in args] + [0] * (6 - len(args))))
        cf = ctypes.c_int()
        r = (ctypes.c_uint64 * 32)()
        self.d.h_regs(FN[fn], a, ctypes.byref(cf), r)
        return list(r[:16]), list(r[16:])

    def stats(self):
        out = (ctypes.c_uint64 * len(STATS))()
        self.d.h_stats(out)
        return dict(zip(STATS, out))

    def class_slabs(self, c):
        return ctypes.c_uint64.from_address(self.d.h_classes() + c * 32 + 8).value

    @staticmethod
    def read(p, n):
        return ctypes.string_at(p, n)

    @staticmethod
    def write(p, data):
        ctypes.memmove(p, data, len(data))


def class_of(n):
    for c in CLASSES:
        if max(n, 1) <= c:
            return c
    return None


def misuse(h, before, why, addr):
    s = h.stats()
    ok = s["bad_count"] == before + 1 and s["bad_addr"] == addr
    said = ctypes.string_at(s["bad_why"]).decode() if s["bad_why"] else ""
    return ok and said == why, said


def test_shapes(h):
    st = h.stats()
    pool, vpool = st["pool"], st["vpool"]
    sizes = [0, 1, 8, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128, 129, 255, 256, 257, 511,
             512, 513, 1000, 1023, 1024, 1025, 2000, 4080, 4096, 4097, 8192, 100000, 1 << 20]
    good = 0
    for n in sizes:
        p = h.malloc(n)
        c = class_of(n)
        ok = p != 0 and p % 16 == 0 and h.read(p, max(n, 1)) == bytes(max(n, 1))
        if c:
            slab = p & ~0xFFF
            size = ctypes.c_uint32.from_address(slab + 28).value
            ok = ok and pool <= p < pool + POOL_BYTES and size == c and (p - slab - HDR) % c == 0
        else:
            ok = ok and vpool <= p < vpool + VPOOL_BYTES and (p + (n + 15) // 16 * 16) % 4096 == 0
        h.write(p, b"\xAA" * max(n, 1))
        h.free(p)
        good += check(ok, f"kmalloc({n}) = {p:#x}: aligned, zeroed, in the right place")
    s = h.stats()
    check(s["objects"] == 0 and s["big"] == 0 and s["bytes"] == 0 and s["big_bytes"] == 0
          and s["vm_out"] == 0, f"all given back: {s}")
    print(f"sizes: {good} of {len(sizes)} land where they should, zeroed and aligned; "
          f"large ones end where their mapping does")


def test_slabs(h):
    for ci, c in enumerate(CLASSES):
        count = (4096 - HDR) // c
        ps = [h.malloc(c) for _ in range(count + 1)]
        first = ps[0] & ~0xFFF
        ok = all(p == first + HDR + i * c for i, p in enumerate(ps[:count]))
        ok = ok and ps[count] & ~0xFFF != first
        check(ok, f"class {c}: {count} objects in a slab, in order, then a new slab")
        slabs = h.class_slabs(ci)
        pages = h.stats()["pages_out"]
        for p in ps:
            h.free(p)
        check(h.class_slabs(ci) == 1 and h.stats()["pages_out"] == pages - (slabs - 1),
              f"class {c}: empty slabs given back but one ({h.class_slabs(ci)} left)")
    p = h.malloc(100)
    h.free(p)
    check(h.read(p, 128) == b"\xDF" * 128, "a freed object is filled with 0xDF")
    s = h.stats()
    check(s["slabs"] == len(CLASSES) and s["pages_out"] == len(CLASSES),
          f"one slab kept per class: {s['slabs']} slabs, {s['pages_out']} pages")
    print(f"slabs: each class's layout, poison, and empty slabs given back")


def test_misuse(h):
    n = h.stats()["bad_count"]
    p = h.malloc(40)
    h.free(p)
    h.free(p)
    ok, said = misuse(h, n, "kfree: freed twice", p)
    check(ok, f"freed twice: {said}")
    n += 1
    p = h.malloc(64)
    h.free(p + 16)
    ok, said = misuse(h, n, "kfree: not the start of an object", p + 16)
    check(ok, f"inside an object: {said}")
    n += 1
    h.free(p + 8)
    ok, said = misuse(h, n, "kfree: not something kmalloc gave out", p + 8)
    check(ok, f"misaligned: {said}")
    n += 1
    h.free((p & ~0xFFF) + 64)
    ok, said = misuse(h, n, "kfree: not something kmalloc gave out", (p & ~0xFFF) + 64)
    check(ok, f"a slab's header: {said}")
    n += 1
    h.free(p)
    stray = h.stats()["pool"] + 8000 * 4096
    h.free(stray)
    ok, said = misuse(h, n, "kfree: not something kmalloc gave out", stray)
    check(ok, f"a page that is no slab: {said}")
    n += 1
    buf = ctypes.create_string_buffer(64)
    addr = (ctypes.addressof(buf) + 15) & ~15
    h.free(addr)
    ok, said = misuse(h, n, "kfree: not something kmalloc gave out", addr)
    check(ok, f"memory the heap never had: {said}")
    n += 1
    p = h.malloc(200)                   # the kept 256 slab's first object
    h.free(p)
    h.write(p + 5, b"\x01")
    q = h.malloc(200)
    ok, said = misuse(h, n, "kmalloc: written to after it was freed", p)
    check(ok and q == p and h.read(q, 256) == bytes(256),
          f"written after free, caught when handed out again: {said}")
    n += 1
    h.free(q)
    h.free(0)
    check(h.stats()["bad_count"] == n, "kfree(0) is nothing")
    e = h.stats()["errors"]
    b = h.malloc(5000)
    h.free(b + 8)
    ok, said = misuse(h, n, "kfree: not something kmalloc gave out", b + 8)
    check(ok, f"a large object, misaligned: {said}")
    n += 1
    h.free(b)
    h.free(b)
    check(h.stats()["errors"] == e + 1 and h.stats()["bad_count"] == n,
          "a large object freed twice reaches vm_free (which panics in the kernel)")
    s = h.stats()
    check(s["objects"] == 0 and s["big"] == 0, f"nothing left over: {s}")
    print(f"misuse: each kind caught and named")


def test_random(h, rng):
    t = time.perf_counter()
    bad = h.d.h_stress(rng.getrandbits(64), 200000, 1024, 1 << 20)
    t = time.perf_counter() - t
    s = h.stats()
    check(bad == 0 and s["objects"] == 0 and s["big"] == 0 and s["vm_out"] == 0
          and s["bytes"] == 0 and s["big_bytes"] == 0,
          f"one thread: {bad} problems; {s}")
    print(f"random: 200000 operations from one thread, every object checked ({t:.1f} s)")
    results = []

    def worker(seed):
        results.append(h.d.h_stress(seed, 60000, 512, 1 << 20))

    threads = [threading.Thread(target=worker, args=(rng.getrandbits(64),)) for _ in range(4)]
    t = time.perf_counter()
    for th in threads:
        th.start()
    for th in threads:
        th.join()
    t = time.perf_counter() - t
    s = h.stats()
    check(results == [0, 0, 0, 0] and s["objects"] == 0 and s["big"] == 0 and s["vm_out"] == 0,
          f"four threads: problems {results}; {s}")
    check(s["errors"] == 1 and s["pages_out"] == s["slabs"] <= len(CLASSES) * 2,
          f"the stand-ins saw no other misuse: {s['errors']} errors, "
          f"{s['pages_out']} pages for {s['slabs']} slabs")
    print(f"random: 4 threads x 60000 operations at once ({t:.1f} s)")


def test_regs(h):
    small = h.malloc(24)
    big = h.malloc(3000)
    cases = [("kmalloc", 24), ("kmalloc", 0), ("kmalloc", 3000), ("kfree", small),
             ("kfree", big), ("kfree", 0)]
    good = 0
    for fn, arg in cases:
        before, after = h.regs(fn, arg)
        same = [i for i in range(16) if i != 0 and before[i] != after[i]]
        if fn == "kmalloc":
            h.free(after[0])
        good += check(not same, f"{fn}({arg:#x}) changed registers {same}")
    print(f"registers: {good} of {len(cases)} calls keep all but RAX")


def test_speed(h):
    for size in (64, 1000):
        n = 1000000
        t = time.perf_counter()
        h.call("s_bench", n, size)
        t = time.perf_counter() - t
        print(f"speed: kmalloc({size}) + kfree {t / n * 1e9:.1f} ns")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--cc", default=os.environ.get("CC", GCC))
    opts = ap.parse_args()
    sys.stdout.reconfigure(line_buffering=True)
    nasm = shutil.which("nasm")
    if not nasm:
        sys.exit("nasm not found on PATH")
    cc = opts.cc if os.path.exists(opts.cc) else shutil.which(opts.cc)
    if not cc:
        sys.exit(f"compiler not found: {opts.cc}")
    OUT.mkdir(parents=True, exist_ok=True)
    obj = OUT / "shim.obj"
    dll = OUT / "heap.dll"
    run([nasm, "-f", "win64", "-I", str(ROOT / "src" / "kernel") + os.sep,
         "-I", str(ROOT / "src" / "include") + os.sep, "-o", obj, HERE / "shim.asm"],
        "nasm -f win64")
    run([cc, "-O2", "-Wall", "-Wextra", "-shared", "-static", "-o", dll, HERE / "host.c", obj],
        "gcc")
    h = Heap(dll)
    h.call("heap_init")
    rng = random.Random(opts.seed)
    test_shapes(h)
    test_slabs(h)
    test_misuse(h)
    test_random(h, rng)
    test_regs(h)
    test_speed(h)
    print(f"-- {passes} passed, {fails} failed")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
