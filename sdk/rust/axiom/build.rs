// Puts axiom.ld where the linker finds it (the target's -Taxiom.ld), for
// every program built with this crate.
use std::{env, fs, path::PathBuf};

fn main() {
    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    fs::copy("axiom.ld", out.join("axiom.ld")).unwrap();
    println!("cargo:rustc-link-search={}", out.display());
    println!("cargo:rerun-if-changed=axiom.ld");
}
