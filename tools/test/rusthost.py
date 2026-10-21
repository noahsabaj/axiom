"""The kernel's Rust (src/rust) for the host tests whose shims assemble
kernel files that call it (rusthost.inc): built for the host as a DLL, its
rs_* entry points handed to a shim's forwarders.

    rust = rusthost.build(out)          # cargo, into out/rust-host
    rusthost.forward(rust, shim, ["rs_x509_parse", ...])
"""
import ctypes
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
RUST = ROOT / "src" / "rust"


def build(out):
    """-> the Rust, built for the host (release), loaded"""
    target = pathlib.Path(out) / "rust-host"
    r = subprocess.run(["cargo", "+nightly", "rustc", "--release", "--lib", "--crate-type", "cdylib",
                        "--target-dir", str(target)], cwd=RUST, capture_output=True, text=True)
    if r.returncode:
        print((r.stdout + r.stderr).strip())
        sys.exit(f"cargo rustc (the kernel's Rust, for the host) failed ({r.returncode})")
    return ctypes.CDLL(str(target / "release" / "axiom_kernel.dll"))


def forward(rust, shim, names):
    """Each name's forwarder in the shim (name_at, from rusthost.inc's
    FORWARD) pointed at the Rust's name."""
    for name in names:
        entry = ctypes.cast(getattr(rust, name), ctypes.c_void_p).value
        ctypes.c_uint64.in_dll(shim, name + "_at").value = entry
