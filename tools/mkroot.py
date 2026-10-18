#!/usr/bin/env python3
"""A Linux root for Axiom's Linux programs: build/linux/ROOT, a tree of
files that mkstick.py --linux puts at /LINUX/ROOT on the boot stick, and
build/linux/META, what FAT cannot keep: each path's kind and mode, and
where each symbolic link points.

    python tools/mkroot.py [--distro Ubuntu] [--add /usr/bin/foo ...]

The programs (PROGRAMS, and any --add) and every library they need (their
DT_NEEDED, followed) are copied from a WSL distribution, with each
symbolic link on the way (/bin -> usr/bin, the loader's name, ...).
/etc is Axiom's own (passwd, group, hosts, nsswitch.conf), never the
distribution's, but for ld.so.cache. Test programs of our own, assembled
from tools/test/linux/*.asm, go in /test.

META, a line each, tab-separated:
    d <path> <mode>          a directory
    f <path> <mode> <size>   a file, at /LINUX/ROOT<path> on the stick
    l <path> <target>        a symbolic link
The run inside WSL (--inside) does the copying; it needs only python3.
"""
import argparse
import os
import pathlib
import shutil
import stat
import struct
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "build" / "linux"

PROGRAMS = [
    "/usr/bin/true", "/usr/bin/false", "/usr/bin/echo", "/usr/bin/cat",
    "/usr/bin/ls", "/usr/bin/uname", "/usr/bin/env", "/usr/bin/wc",
    "/usr/bin/head", "/usr/bin/sha256sum", "/usr/bin/date", "/usr/bin/id",
    "/usr/bin/sleep",
]
FILES = ["/etc/ld.so.cache", "/bin"]
LIBDIRS = ["/lib/x86_64-linux-gnu", "/usr/lib/x86_64-linux-gnu", "/lib64", "/usr/lib64"]

ETC = {
    "/etc/passwd": "root:x:0:0:root:/root:/bin/bash\nuser:x:1000:1000:user:/home/user:/bin/bash\n",
    "/etc/group": "root:x:0:\nuser:x:1000:\n",
    "/etc/hosts": "127.0.0.1\tlocalhost\n::1\tlocalhost\n",
    "/etc/nsswitch.conf": "passwd: files\ngroup: files\nshadow: files\nhosts: files dns\n",
    "/etc/hostname": "axiom\n",
    "/etc/os-release": 'NAME="Axiom"\nID=axiom\nPRETTY_NAME="Axiom (Linux programs from Ubuntu)"\n',
}
DIRS = ["/tmp", "/root", "/home/user", "/dev", "/proc", "/sys", "/etc", "/test"]


# ---------------------------------------------------------------- inside WSL

def needed(path):
    """DT_NEEDED of an ELF file (empty if it is not one)."""
    with open(path, "rb") as f:
        d = f.read()
    if d[:4] != b"\x7fELF" or d[4] != 2:
        return []
    phoff, = struct.unpack_from("<Q", d, 32)
    phentsize, phnum = struct.unpack_from("<HH", d, 54)
    loads, dyn = [], None
    for i in range(phnum):
        t, _, off, va, _, fs, _, _ = struct.unpack_from("<IIQQQQQQ", d, phoff + i * phentsize)
        if t == 1:
            loads.append((off, va, fs))
        elif t == 2:
            dyn = (off, fs)
    interp = []
    for i in range(phnum):
        t, _, off, _, _, fs, _, _ = struct.unpack_from("<IIQQQQQQ", d, phoff + i * phentsize)
        if t == 3:
            interp.append(d[off:off + fs].rstrip(bytes(1)).decode())
    if not dyn:
        return interp

    def v2o(v):
        for off, va, fs in loads:
            if va <= v < va + fs:
                return v - va + off
        raise ValueError(hex(v))
    names, strtab = [], 0
    for i in range(dyn[0], dyn[0] + dyn[1], 16):
        tag, val = struct.unpack_from("<qQ", d, i)
        if tag == 0:
            break
        if tag == 1:
            names.append(val)
        elif tag == 5:
            strtab = val
    out = interp
    for n in names:
        s = v2o(strtab) + n
        out.append(d[s:d.index(b"\0", s)].decode())
    return out


def inside(dest, programs, files):
    dest = pathlib.Path(dest)
    meta = {}                       # path -> line

    def canon(p):
        """p with its directories through their links (each link taken)."""
        parts = p.strip("/").split("/")
        cur = ""
        for part in parts[:-1]:
            take(cur + "/" + part)
            cur = os.path.realpath(cur + "/" + part)
        return cur + "/" + parts[-1]

    def take(p):
        """p and every link on the way to it, then what it is."""
        p = canon(p)
        if p in meta:
            return
        st = os.lstat(p)
        if stat.S_ISLNK(st.st_mode):
            target = os.readlink(p)
            meta[p] = f"l\t{p}\t{target}"
            nxt = target if target.startswith("/") else os.path.normpath(os.path.join(os.path.dirname(p), target))
            take(nxt)
        elif stat.S_ISDIR(st.st_mode):
            meta[p] = f"d\t{p}\t{stat.S_IMODE(st.st_mode):o}"
        else:
            meta[p] = f"f\t{p}\t{stat.S_IMODE(st.st_mode):o}\t{st.st_size}"
            out = dest / "ROOT" / p.lstrip("/")
            out.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(p, out)

    def real(p):
        """p through its links (but each link is taken on the way)."""
        take(p)
        return os.path.realpath(p)

    todo = list(programs)
    seen = set()
    while todo:
        p = todo.pop()
        if p in seen:
            continue
        seen.add(p)
        for lib in needed(real(p)):
            if lib.startswith("/"):
                todo.append(lib)
                continue
            for d in LIBDIRS:
                cand = d + "/" + lib
                if os.path.exists(cand):
                    todo.append(cand)
                    break
            else:
                sys.exit(f"mkroot: {p} needs {lib}, which is not in {LIBDIRS}")
    for p in files:
        real(p)
    (dest / "META.part").write_text("\n".join(meta[k] for k in sorted(meta)) + "\n")


# ---------------------------------------------------------------- on Windows

def wsl_path(p):
    p = str(p.resolve())
    return "/mnt/" + p[0].lower() + p[2:].replace("\\", "/")


def assemble_tests():
    """tools/test/linux/*.asm -> ROOT/test/<name>, ELF files of our own."""
    out = {}
    nasm = shutil.which("nasm") or "nasm"
    for src in sorted((ROOT / "tools" / "test" / "linux").glob("*.asm")):
        dst = OUT / "ROOT" / "test" / src.stem
        dst.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run([nasm, "-f", "bin", "-o", str(dst), str(src)], check=True)
        out["/test/" + src.stem] = dst.stat().st_size
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--distro", default="Ubuntu")
    ap.add_argument("--add", action="append", default=[], metavar="PATH",
                    help="one more program (or file) from the distribution")
    ap.add_argument("--inside", nargs="+", help=argparse.SUPPRESS)
    opts = ap.parse_args()
    if opts.inside:
        dest, rest = opts.inside[0], opts.inside[1:]
        progs = [p for p in rest if not p.startswith("=")]
        files = [p[1:] for p in rest if p.startswith("=")]
        inside(dest, progs, files)
        return
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)
    args = PROGRAMS + [a for a in opts.add if not a.startswith("=")] + ["=" + f for f in FILES]
    args += [a for a in opts.add if a.startswith("=")]
    r = subprocess.run(["wsl.exe", "-d", opts.distro, "--", "python3", wsl_path(pathlib.Path(__file__)),
                        "--inside", wsl_path(OUT)] + args)
    if r.returncode:
        sys.exit("mkroot: the copy inside WSL failed")
    meta = {}
    for line in (OUT / "META.part").read_text().splitlines():
        meta[line.split("\t")[1]] = line
    (OUT / "META.part").unlink()
    for d in DIRS:
        meta.setdefault(d, f"d\t{d}\t{'1777' if d == '/tmp' else '755'}")
    for d in ("/home",):
        meta.setdefault(d, f"d\t{d}\t755")
    for path, text in ETC.items():
        dst = OUT / "ROOT" / path.lstrip("/")
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(text.encode())
        meta[path] = f"f\t{path}\t644\t{len(text.encode())}"
    for path, size in assemble_tests().items():
        meta[path] = f"f\t{path}\t755\t{size}"
    names = {}
    for p in meta:                  # FAT keeps no case: two names one apart?
        key = p.lower()
        if key in names and names[key] != p:
            sys.exit(f"mkroot: {p} and {names[key]} differ only in case")
        names[key] = p
    (OUT / "META").write_text("".join(meta[k] + "\n" for k in sorted(meta)), newline="\n")
    total = sum(f.stat().st_size for f in (OUT / "ROOT").rglob("*") if f.is_file())
    print(f"mkroot: {len(meta)} paths, {total:,} bytes -> {OUT}")


if __name__ == "__main__":
    main()
