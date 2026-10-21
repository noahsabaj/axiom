//! The console font's extra symbols (G_BLOCK, G_ARROW_R...), as the
//! assembly has them in src/kernel/gen/font.inc (tools/mkfont.py), for
//! text.rs: written to $OUT_DIR/font.rs as `pub const G_...: u8`.
use std::{env, fs, path::Path};

fn main() {
    let inc = Path::new(env!("CARGO_MANIFEST_DIR")).join("../kernel/gen/font.inc");
    println!("cargo:rerun-if-changed={}", inc.display());
    let text = fs::read_to_string(&inc).expect("src/kernel/gen/font.inc");
    let mut out = String::new();
    for line in text.lines() {
        let mut words = line.split_whitespace();
        if let (Some(name), Some("equ"), Some(value)) = (words.next(), words.next(), words.next())
            && name.starts_with("G_")
        {
            let value: u8 = value.parse().expect("a glyph's byte");
            out += &format!("pub const {name}: u8 = {value};\n");
        }
    }
    fs::write(Path::new(&env::var("OUT_DIR").unwrap()).join("font.rs"), out).unwrap();
}
