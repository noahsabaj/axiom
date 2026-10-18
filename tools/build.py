#!/usr/bin/env python3
"""Build Axiom: kernel.bin, then BOOTX64.EFI with the kernel embedded, and
the programs in src/user, each to EFI/AXIOM/<NAME>.AXE beside it.

    python tools/build.py              build into build/esp/EFI/BOOT/BOOTX64.EFI
    python tools/build.py --max 1920x1080   cap the display mode the loader picks
"""
import argparse
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"


def nasm(args):
    exe = shutil.which("nasm")
    if not exe:
        sys.exit("nasm not found on PATH")
    cmd = [exe, *args]
    result = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    out = (result.stdout + result.stderr).strip()
    if out:
        print(out)
    if result.returncode:
        sys.exit(f"nasm failed: {' '.join(args)}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--max", help="largest display mode, WxH")
    opts = ap.parse_args()

    BUILD.mkdir(exist_ok=True)
    boot = BUILD / "esp" / "EFI" / "BOOT"
    boot.mkdir(parents=True, exist_ok=True)

    nasm(["-f", "bin", "-w-reloc-abs-qword", "-w-reloc-abs-dword", "-w-reloc-rel-dword",
          "-I", "src/kernel/", "-I", "src/include/",
          "-o", "build/kernel.bin", "src/kernel/kernel.asm"])

    defines = []
    if opts.max:
        w, h = opts.max.lower().split("x")
        defines = [f"-DGOP_MAX_W={int(w)}", f"-DGOP_MAX_H={int(h)}"]
    nasm(["-f", "bin", *defines,
          "-I", "src/boot/", "-I", "src/include/", "-I", "build/",
          "-o", str((boot / "BOOTX64.EFI").relative_to(ROOT)), "src/boot/uefi.asm"])

    # browse's fonts (src/user/gen/webfont.*), made by tools/mkwebfont.py
    # from DejaVu if they are not there, are assembled into BROWSE.AXE
    font = ROOT / "src" / "user" / "gen" / "webfont.bin"
    if not font.exists() or not font.with_suffix(".inc").exists():
        result = subprocess.run([sys.executable, str(ROOT / "tools" / "mkwebfont.py")], cwd=ROOT)
        if result.returncode:
            sys.exit("mkwebfont.py failed: browse needs the DejaVu fonts")

    programs = BUILD / "esp" / "EFI" / "AXIOM"
    programs.mkdir(parents=True, exist_ok=True)
    made = []
    for src in sorted((ROOT / "src" / "user").glob("*.asm")):
        out = programs / f"{src.stem.upper()}.AXE"
        nasm(["-f", "bin", "-I", "src/kernel/", "-I", "src/user/",
              "-o", str(out.relative_to(ROOT)), str(src.relative_to(ROOT))])
        made.append(f"{out.name} {out.stat().st_size:,}")

    kernel = (BUILD / "kernel.bin").stat().st_size
    efi = (boot / "BOOTX64.EFI").stat().st_size
    print(f"kernel.bin   {kernel:>9,} bytes")
    print(f"BOOTX64.EFI  {efi:>9,} bytes  -> {boot / 'BOOTX64.EFI'}")
    print(f"programs     {', '.join(made)} -> {programs}")


if __name__ == "__main__":
    main()
