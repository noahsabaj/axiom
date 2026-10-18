#!/usr/bin/env python3
"""Build Axiom: kernel.bin, then BOOTX64.EFI with the kernel embedded, and
the programs in src/user, each to EFI/AXIOM/<NAME>.AXE beside it.

    python tools/build.py              build into build/esp/EFI/BOOT/BOOTX64.EFI
    python tools/build.py --max 1920x1080   cap the display mode the loader picks
    python tools/build.py --all        assemble everything, changed or not
    python tools/build.py --small      the kernel with NASM's jump sizing (-Ox):
                                       4% smaller, a minute instead of 2 s

The kernel and the programs are assembled side by side, then the loader,
which embeds the kernel. Each is assembled only if it, a file it includes,
or the command that makes it changed since last time: NASM lists what each
includes (-MD, build/deps/<name>.d) as it assembles. The kernel is assembled
with -O1, every jump long: NASM's own sizing (-Ox) takes some 200 passes
over it, a minute, for 4% less.
"""
import argparse
import concurrent.futures
import os
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"
DEPS = BUILD / "deps"


def current(out, name, cmd):
    """Whether OUT is newer than everything it was made from, by CMD."""
    stamp, deps = DEPS / f"{name}.cmd", DEPS / f"{name}.d"
    try:
        if stamp.read_text() != cmd:
            return False
        made = out.stat().st_mtime
        text = deps.read_text().replace("\\\n", " ")
        files = text.split(":", 1)[1].split() if ":" in text else []
        return bool(files) and all((ROOT / f).stat().st_mtime <= made for f in files)
    except (OSError, IndexError):
        return False


def nasm(out, name, args, force):
    """Assemble OUT (unless it is current) -> (what NASM said, assembled?)."""
    exe = shutil.which("nasm")
    if not exe:
        sys.exit("nasm not found on PATH")
    rel = out.relative_to(ROOT).as_posix()
    cmd = " ".join(args + ["-o", rel])
    if not force and current(out, name, cmd):
        return "", False
    deps = (DEPS / f"{name}.d").relative_to(ROOT).as_posix()
    result = subprocess.run([exe, *args, "-MD", deps, "-MT", rel, "-o", rel], cwd=ROOT,
                            capture_output=True, text=True)
    said = (result.stdout + result.stderr).strip()
    if result.returncode:
        (DEPS / f"{name}.cmd").unlink(missing_ok=True)
        sys.exit((said + "\n" if said else "") + f"nasm failed: {cmd}")
    (DEPS / f"{name}.cmd").write_text(cmd)
    return said, True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--max", help="largest display mode, WxH")
    ap.add_argument("--all", action="store_true", help="assemble everything, changed or not")
    ap.add_argument("--small", action="store_true", help="the kernel with -Ox: NASM sizes "
                    "every jump, in some 200 passes (a minute), for a kernel 4%% smaller")
    opts = ap.parse_args()

    boot = BUILD / "esp" / "EFI" / "BOOT"
    boot.mkdir(parents=True, exist_ok=True)
    programs = BUILD / "esp" / "EFI" / "AXIOM"
    programs.mkdir(parents=True, exist_ok=True)
    DEPS.mkdir(parents=True, exist_ok=True)

    # browse's fonts (src/user/gen/webfont.*), made by tools/mkwebfont.py
    # from DejaVu if they are not there, are assembled into BROWSE.AXE
    font = ROOT / "src" / "user" / "gen" / "webfont.bin"
    if not font.exists() or not font.with_suffix(".inc").exists():
        result = subprocess.run([sys.executable, str(ROOT / "tools" / "mkwebfont.py")], cwd=ROOT)
        if result.returncode:
            sys.exit("mkwebfont.py failed: browse needs the DejaVu fonts")

    first = [(BUILD / "kernel.bin", "kernel",
              ["-f", "bin", "-Ox" if opts.small else "-O1", "-w-reloc-abs-qword", "-w-reloc-abs-dword", "-w-reloc-rel-dword",
               "-I", "src/kernel/", "-I", "src/include/", "src/kernel/kernel.asm"])]
    for src in sorted((ROOT / "src" / "user").glob("*.asm")):
        first.append((programs / f"{src.stem.upper()}.AXE", src.stem,
                      ["-f", "bin", "-I", "src/kernel/", "-I", "src/user/",
                       src.relative_to(ROOT).as_posix()]))
    defines = []
    if opts.max:
        w, h = opts.max.lower().split("x")
        defines = [f"-DGOP_MAX_W={int(w)}", f"-DGOP_MAX_H={int(h)}"]
    loader = (boot / "BOOTX64.EFI", "uefi",
              ["-f", "bin", *defines, "-I", "src/boot/", "-I", "src/include/", "-I", "build/",
               "src/boot/uefi.asm"])

    assembled = 0
    with concurrent.futures.ThreadPoolExecutor(min(len(first), os.cpu_count() or 4)) as pool:
        for said, did in pool.map(lambda t: nasm(*t, opts.all), first):
            if said:
                print(said)
            assembled += did
    said, did = nasm(*loader, opts.all)             # it embeds kernel.bin
    if said:
        print(said)
    assembled += did

    kernel = (BUILD / "kernel.bin").stat().st_size
    efi = (boot / "BOOTX64.EFI").stat().st_size
    made = [f"{out.name} {out.stat().st_size:,}" for out, _, _ in first[1:]]
    print(f"kernel.bin   {kernel:>9,} bytes")
    print(f"BOOTX64.EFI  {efi:>9,} bytes  -> {boot / 'BOOTX64.EFI'}")
    print(f"programs     {', '.join(made)} -> {programs}")
    print(f"assembled    {assembled} of {len(first) + 1}" +
          ("" if assembled == len(first) + 1 else ", the rest up to date"))


if __name__ == "__main__":
    main()
