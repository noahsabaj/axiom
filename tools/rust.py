#!/usr/bin/env python3
"""Build Axiom's Rust programs (sdk/rust) into build/esp/EFI/AXIOM/<NAME>.AXE.

    python tools/rust.py                 every program in sdk/rust's workspace
    python tools/rust.py rhello rdemo    those
    python tools/rust.py --debug         without optimising

Needs the nightly toolchain with its rust-src component (rustup's), and
nothing more: the target is sdk/rust/x86_64-axiom.json, core, alloc and std
are built from rust-src for it (-Zbuild-std), and the crates std uses come
from rust-src's own vendored copies, offline. Cargo builds into build/rust;
tools/mkaxe.py makes each program's .AXE. Exits 3 if there is no nightly
toolchain (the tests skip, then).
"""
import argparse
import pathlib
import subprocess
import sys
import tomllib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SDK = ROOT / "sdk" / "rust"
OUT = ROOT / "build" / "esp" / "EFI" / "AXIOM"
TARGET = SDK / "x86_64-axiom.json"


def nightly():
    """The nightly toolchain's sysroot, if it is there with its rust-src;
    None, having said what is missing, if not."""
    try:
        sysroot = subprocess.run(["rustc", "+nightly", "--print", "sysroot"], check=True,
                                 capture_output=True, text=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        print("rust: no nightly toolchain (rustup toolchain install nightly, with rust-src)")
        return None
    if not (vendor(sysroot)).is_dir():
        print("rust: nightly has no rust-src (rustup component add rust-src --toolchain nightly)")
        return None
    return pathlib.Path(sysroot)


def vendor(sysroot):
    return pathlib.Path(sysroot) / "lib" / "rustlib" / "src" / "rust" / "library" / "vendor"


def cargo_build(sysroot, target, target_dir, std):
    """cargo build for a JSON target, the crates in STD built from rust-src
    and those they use from its vendored copies, offline."""
    return ["cargo", "+nightly", "build", "--offline",
            f"-Zbuild-std={std}", "-Zbuild-std-features=compiler-builtins-mem",
            "-Zjson-target-spec",
            "--target", str(target), "--target-dir", str(target_dir),
            "--config", 'source.crates-io.replace-with="rust-src"',
            "--config", f'source.rust-src.directory="{vendor(sysroot).as_posix()}"']


def programs():
    """{bin name: its package} for the workspace's programs."""
    ws = tomllib.loads((SDK / "Cargo.toml").read_text(encoding="utf-8"))
    found = {}
    for member in ws["workspace"]["members"]:
        pkg = tomllib.loads((SDK / member / "Cargo.toml").read_text(encoding="utf-8"))
        for b in pkg.get("bin", []):
            found[b["name"]] = pkg["package"]["name"]
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("names", nargs="*", help="programs to build (all, if none)")
    ap.add_argument("--debug", action="store_true", help="the dev profile, unoptimised")
    opts = ap.parse_args()
    known = programs()
    names = opts.names or sorted(known)
    unknown = [n for n in names if n not in known]
    if unknown:
        sys.exit(f"rust: no program {' '.join(unknown)}; there are: {' '.join(sorted(known))}")
    for n in names:
        if len(n) > 8:
            sys.exit(f"rust: {n}: a program's name is 8 letters at most (NAME.AXE)")
    sysroot = nightly()
    if not sysroot:
        sys.exit(3)
    profile = "debug" if opts.debug else "release"
    cmd = cargo_build(sysroot, TARGET, ROOT / "build" / "rust", "std,panic_abort")
    if not opts.debug:
        cmd.append("--release")
    for n in names:                     # one at a time: each its own features
        if subprocess.run(cmd + ["-p", known[n], "--bin", n], cwd=SDK).returncode:
            sys.exit(f"rust: {n} did not build")
        elf = ROOT / "build" / "rust" / "x86_64-axiom" / profile / n
        r = subprocess.run([sys.executable, str(ROOT / "tools" / "mkaxe.py"), str(elf),
                            str(OUT / f"{n.upper()}.AXE")])
        if r.returncode:
            sys.exit(r.returncode)


if __name__ == "__main__":
    main()
