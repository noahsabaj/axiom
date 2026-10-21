//! Unicode text for a console with one byte per character (was text.asm):
//! UTF-8 decoded a byte at a time, and each code point drawn as the console
//! font has it (ASCII, or one of its extra symbols), as a look-alike ('é'
//! as e, '—' as -), or as '?'.

use crate::json::Answer;

#[allow(dead_code)]
mod font {
    include!(concat!(env!("OUT_DIR"), "/font.rs"));
}
use font::*;

/// UTF-8 decoded a byte at a time, as the assembly kept it in 8 bytes: the
/// bits so far, and how many bytes are still to come. Zero to begin.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Utf8 {
    pub value: u32,
    pub left: u32,
}

impl Utf8 {
    /// The next byte -> None while a character is unfinished; else its
    /// code point, U+FFFD for a malformed sequence. A byte that cuts a
    /// sequence short is lost with it.
    pub fn step(&mut self, byte: u8) -> Option<u32> {
        let b = u32::from(byte);
        if self.left != 0 {
            if b & 0xC0 != 0x80 {
                self.left = 0;
                return Some(0xFFFD);
            }
            self.value = self.value << 6 | b & 0x3F;
            self.left -= 1;
            return (self.left == 0).then_some(self.value);
        }
        let (value, left) = match b {
            0..0x80 => return Some(b),
            0xC2..0xE0 => (b & 0x1F, 1),
            0xE0..0xF0 => (b & 0x0F, 2),
            0xF0..0xF5 => (b & 0x07, 3),
            _ => return Some(0xFFFD), // a stray continuation, overlong, or past U+10FFFF
        };
        self.value = value;
        self.left = left;
        None
    }
}

/// The byte to draw for a code point, or 0 for nothing (joiners, variation
/// selectors, other control characters); 10 stays 10, a tab is a space.
pub fn glyph_of(c: u32) -> u8 {
    match c {
        10 => 10,
        9 => b' ',
        0..0x20 | 0x7F => 0,
        0x20..0x80 => c as u8,
        0xC0..=0xFF => LATIN1[(c - 0xC0) as usize], // Latin-1 letters: without accents
        0x2000..=0x200A => b' ',                     // the many spaces
        _ => MAP.iter().find(|&&(cp, _)| cp == c).map_or(b'?', |&(_, g)| g),
    }
}

/// U+00C0 to U+00FF.
const LATIN1: [u8; 64] = {
    let mut t = *b"AAAAAAACEEEEIIIIDNOOOOOxOUUUUYTsaaaaaaaceeeeiiiidnooooo/ouuuuyty";
    t[0xD7 - 0xC0] = G_TIMES;
    t
};

/// The rest: a code point, and the byte drawn for it (0: nothing).
const MAP: &[(u32, u8)] = &[
    (0x00A0, b' '),
    (0x00A1, b'!'),
    (0x00A2, b'c'),
    (0x00A3, b'L'),
    (0x00A5, b'Y'),
    (0x00A7, b'S'),
    (0x00A9, b'C'),
    (0x00AB, b'"'),
    (0x00AD, 0),
    (0x00AE, b'R'),
    (0x00B0, G_DEGREE),
    (0x00B1, b'+'),
    (0x00B2, b'2'),
    (0x00B3, b'3'),
    (0x00B4, b'\''),
    (0x00B5, G_MICRO),
    (0x00B7, G_MIDDOT),
    (0x00B9, b'1'),
    (0x00BB, b'"'),
    (0x00BF, b'?'),
    (0x03BC, G_MICRO),
    (0x200B, 0), // zero-width space, joiners, marks
    (0x200C, 0),
    (0x200D, 0),
    (0x200E, 0),
    (0x200F, 0),
    (0x2060, 0),
    (0xFEFF, 0),
    (0xFE0E, 0), // variation selectors
    (0xFE0F, 0),
    (0x2010, b'-'), // hyphens and dashes
    (0x2011, b'-'),
    (0x2012, b'-'),
    (0x2013, b'-'),
    (0x2014, b'-'),
    (0x2015, b'-'),
    (0x2212, b'-'),
    (0x2043, b'-'),
    (0x2018, b'\''), // quotes
    (0x2019, b'\''),
    (0x201A, b','),
    (0x201B, b'\''),
    (0x2032, b'\''),
    (0x201C, b'"'),
    (0x201D, b'"'),
    (0x201E, b'"'),
    (0x2033, b'"'),
    (0x2039, b'<'),
    (0x203A, b'>'),
    (0x2044, b'/'),
    (0x2215, b'/'),
    (0x202F, b' '),
    (0x205F, b' '),
    (0x3000, b' '),
    (0x2022, G_BULLET),
    (0x2023, G_TRI_R),
    (0x25AA, G_BULLET),
    (0x25E6, G_CIRCLE),
    (0x2219, G_MIDDOT),
    (0x22C5, G_MIDDOT),
    (0x2026, G_ELLIPSIS),
    (0x2192, G_ARROW_R),
    (0x21D2, G_ARROW_R),
    (0x27F6, G_ARROW_R),
    (0x2794, G_ARROW_R),
    (0x2190, G_ARROW_L),
    (0x21D0, G_ARROW_L),
    (0x2191, G_ARROW_U),
    (0x2193, G_ARROW_D),
    (0x2713, G_CHECK),
    (0x2714, G_CHECK),
    (0x2705, G_CHECK),
    (0x2717, G_CROSSMARK),
    (0x2718, G_CROSSMARK),
    (0x274C, G_CROSSMARK),
    (0x25CF, G_DOT),
    (0x25CB, G_CIRCLE),
    (0x25C6, G_DIAMOND),
    (0x25B6, G_TRI_R),
    (0x25BA, G_TRI_R),
    (0x2248, G_APPROX),
    (0x2264, G_LE),
    (0x2265, G_GE),
    (0x2588, G_BLOCK), // blocks and shades
    (0x2593, G_SHADE3),
    (0x2592, G_SHADE2),
    (0x2591, G_SHADE1),
    (0x258C, G_HALF_L),
    (0x2590, G_HALF_R),
    (0x2580, G_HALF_T),
    (0x2584, G_HALF_B),
    (0x2587, G_BAR8),
    (0x2500, G_HLINE), // box drawing, light, heavy, double, rounded
    (0x2501, G_HLINE),
    (0x2550, G_HLINE),
    (0x2502, G_VLINE),
    (0x2503, G_VLINE),
    (0x2551, G_VLINE),
    (0x250C, G_TL),
    (0x250F, G_TL),
    (0x2554, G_TL),
    (0x256D, G_TL),
    (0x2510, G_TR),
    (0x2513, G_TR),
    (0x2557, G_TR),
    (0x256E, G_TR),
    (0x2514, G_BL),
    (0x2517, G_BL),
    (0x255A, G_BL),
    (0x2570, G_BL),
    (0x2518, G_BR),
    (0x251B, G_BR),
    (0x255D, G_BR),
    (0x256F, G_BR),
    (0x251C, G_TEE_L),
    (0x2523, G_TEE_L),
    (0x2560, G_TEE_L),
    (0x2524, G_TEE_R),
    (0x252B, G_TEE_R),
    (0x2563, G_TEE_R),
    (0x252C, G_TEE_T),
    (0x2533, G_TEE_T),
    (0x2566, G_TEE_T),
    (0x2534, G_TEE_B),
    (0x253B, G_TEE_B),
    (0x2569, G_TEE_B),
    (0x253C, G_CROSS),
    (0x254B, G_CROSS),
    (0x256C, G_CROSS),
    (0xFFFD, b'?'),
];

/// utf8_step(AL, RDI = the state): text.asm. Answer: the code point, and
/// ok 0 while the character is unfinished.
///
/// # Safety
/// `state` points at the caller's 8 bytes of state.
#[unsafe(no_mangle)]
pub unsafe extern "sysv64" fn rs_utf8_step(state: &mut Utf8, byte: u64) -> Answer {
    match state.step(byte as u8) {
        Some(c) => Answer { value: u64::from(c), ok: 1 },
        None => Answer { value: 0, ok: 0 },
    }
}

/// glyph_of(EAX): text.asm.
#[unsafe(no_mangle)]
pub extern "sysv64" fn rs_glyph_of(c: u64) -> u64 {
    u64::from(glyph_of(c as u32))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn decode(bytes: &[u8]) -> Vec<u32> {
        let mut s = Utf8::default();
        bytes.iter().filter_map(|&b| s.step(b)).collect()
    }

    #[test]
    fn utf8() {
        assert_eq!(decode("aé€😀".as_bytes()), [0x61, 0xE9, 0x20AC, 0x1F600]);
        assert_eq!(decode(b"\x80\xC0\xC1\xF5\xFF"), [0xFFFD; 5]);
        assert_eq!(decode(b"\xE2\x82x"), [0xFFFD]); // the x is lost with it
        assert_eq!(decode(b"\xF0\x9F\x98"), []);
    }

    #[test]
    fn glyphs() {
        assert_eq!(glyph_of(u32::from(b'A')), b'A');
        assert_eq!(glyph_of(9), b' ');
        assert_eq!(glyph_of(10), 10);
        assert_eq!(glyph_of(13), 0);
        assert_eq!(glyph_of(0xE9), b'e');
        assert_eq!(glyph_of(0xD7), G_TIMES);
        assert_eq!(glyph_of(0x2014), b'-');
        assert_eq!(glyph_of(0x2005), b' ');
        assert_eq!(glyph_of(0x200D), 0);
        assert_eq!(glyph_of(0x2500), G_HLINE);
        assert_eq!(glyph_of(0x1F600), b'?');
        assert_eq!(glyph_of(0x10000A0), b'?');
    }
}
