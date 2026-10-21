//! Just enough JSON (RFC 8259) to talk to a web API: find a key in an
//! object, read a string (escapes and \u surrogate pairs to UTF-8) or a
//! number, skip any value; and write text as the inside of a string.
//!
//! This was src/kernel/json.asm, and does what it did, step for step: the
//! same answers, the same place left in the text, the same bytes out
//! (tools/test/json holds each against that assembly).
//!
//! The kernel calls it through json.asm, whose wrappers keep the old
//! registers: a reader's text is RSI, ending at R11 (a [`Cursor`]), and
//! what it found comes back as RAX and the carry flag (an [`Answer`]).

use core::ffi::CStr;

/// Where a reader is in the text (RSI), and where the text ends (R11).
#[repr(C)]
pub struct Cursor {
    pub at: *const u8,
    pub end: *const u8,
}

/// What a call found (RAX), and whether it worked: `ok` 0 is the carry
/// flag set. Returned in RAX and RDX.
#[repr(C)]
#[derive(Debug, PartialEq, Eq)]
pub struct Answer {
    pub value: u64,
    pub ok: u64,
}

impl Answer {
    fn of(found: Option<u64>) -> Answer {
        match found {
            Some(value) => Answer { value, ok: 1 },
            None => Answer { value: 0, ok: 0 },
        }
    }
}

/// A reader over the text: `at` may end one past the text's end (an
/// escape's backslash as its last byte skips the byte after it), as RSI
/// did; nothing is read there.
pub struct Reader<'a> {
    pub text: &'a [u8],
    pub at: usize,
}

impl<'a> Reader<'a> {
    pub fn new(text: &'a [u8]) -> Reader<'a> {
        Reader { text, at: 0 }
    }

    fn peek(&self) -> Option<u8> {
        self.text.get(self.at).copied()
    }

    /// Past white space.
    pub fn ws(&mut self) {
        while let Some(b' ' | b'\t' | b'\n' | b'\r') = self.peek() {
            self.at += 1;
        }
    }

    /// At a string: past its closing quote; None if there is none.
    fn skip_str(&mut self) -> Option<()> {
        if self.peek()? != b'"' {
            return None;
        }
        self.at += 1;
        loop {
            let c = self.peek()?;
            self.at += 1;
            match c {
                b'"' => return Some(()),
                b'\\' => self.at += 1, // whatever is escaped
                _ => {}
            }
        }
    }

    /// Past one value; None if there is none, or it runs off the end.
    pub fn skip(&mut self) -> Option<()> {
        self.ws();
        let mut depth = 0u32;
        loop {
            match self.peek()? {
                b'"' => {
                    self.skip_str()?;
                    if depth == 0 {
                        return Some(());
                    }
                }
                b'{' | b'[' => {
                    depth += 1;
                    self.at += 1;
                }
                b'}' | b']' => {
                    if depth == 0 {
                        return None; // a close with nothing open
                    }
                    self.at += 1;
                    depth -= 1;
                    if depth == 0 {
                        return Some(());
                    }
                }
                _ if depth > 0 => self.at += 1, // inside: commas, colons, atoms
                _ => return self.atom(),
            }
        }
    }

    /// A number, true, false or null: up to a comma, a close or a space.
    fn atom(&mut self) -> Option<()> {
        let first = self.at;
        while let Some(c) = self.peek() {
            if matches!(c, b',' | b'}' | b']') || c <= b' ' {
                break;
            }
            self.at += 1;
        }
        (self.at != first).then_some(())
    }

    /// At an object: at that key's value; None if it is not an object or
    /// has no such key. Keys are compared as they are written, escapes and
    /// all.
    pub fn get(&mut self, key: &[u8]) -> Option<()> {
        self.ws();
        if self.peek()? != b'{' {
            return None;
        }
        self.at += 1;
        loop {
            self.ws();
            if self.peek()? != b'"' {
                return None; // ('}': an empty object, so no key)
            }
            let first = self.at + 1;
            self.skip_str()?;
            let found = self.text[first..self.at - 1] == *key;
            self.ws();
            if self.peek()? != b':' {
                return None;
            }
            self.at += 1;
            self.ws();
            if found {
                return Some(());
            }
            self.skip()?;
            self.ws();
            if self.peek()? != b',' {
                return None; // '}': not there
            }
            self.at += 1;
        }
    }

    /// At a value: whether it is the string `text` (as it is written).
    /// The reader stays.
    pub fn is(&self, text: &[u8]) -> bool {
        let rest = self.text.get(self.at..).unwrap_or(&[]);
        let n = text.len();
        rest.len() >= n + 2 && rest[0] == b'"' && rest[1..=n] == *text && rest[n + 1] == b'"'
    }

    /// At a number: its unsigned integer part (wrapping, as RAX did);
    /// None if it is not one.
    pub fn num(&mut self) -> Option<u64> {
        let digit = |c: u8| Some(c.wrapping_sub(b'0')).filter(|&d| d <= 9);
        let mut n = digit(self.peek()?)? as u64;
        self.at += 1;
        while let Some(d) = self.peek().and_then(digit) {
            n = n.wrapping_mul(10).wrapping_add(d as u64);
            self.at += 1;
        }
        Some(n)
    }

    /// At a string: it, UTF-8, into `out` (cut short to its room, on a
    /// character boundary), the reader past it; None if it is not one.
    pub fn string(&mut self, out: &mut Out) -> Option<()> {
        if self.peek()? != b'"' {
            return None;
        }
        self.at += 1;
        loop {
            let c = self.peek()?;
            self.at += 1;
            match c {
                b'"' => return Some(()),
                b'\\' => {
                    let e = self.peek()?;
                    self.at += 1;
                    match e {
                        b'u' => self.unicode(out)?,
                        b'n' => out.put(b'\n'),
                        b't' => out.put(b'\t'),
                        b'r' => out.put(b'\r'),
                        b'b' => out.put(8),
                        b'f' => out.put(12),
                        _ => out.put(e), // and '"', '\' and '/' as they are
                    }
                }
                _ => out.put(c),
            }
        }
    }

    /// After \u: its code point out; a high surrogate takes the low one
    /// after it, and one alone, or not followed by a low one, is U+FFFD.
    fn unicode(&mut self, out: &mut Out) -> Option<()> {
        let high = self.hex4()?;
        if !(0xD800..=0xDBFF).contains(&high) {
            out.utf8(high); // a low surrogate alone: U+FFFD there
            return Some(());
        }
        if self.at + 6 > self.text.len() || self.text[self.at..self.at + 2] != *b"\\u" {
            out.utf8(0xFFFD);
            return Some(());
        }
        self.at += 2;
        let low = self.hex4()?;
        if !(0xDC00..=0xDFFF).contains(&low) {
            out.utf8(0xFFFD); // U+FFFD for the high one, then this
            out.utf8(low);
            return Some(());
        }
        out.utf8(0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00));
        Some(())
    }

    /// Four hex digits: their value, the reader past them; None if not.
    /// As the assembly did, a digit is its byte with 0x20 set (so A-F are
    /// a-f, and 0x10-0x19 are 0-9).
    fn hex4(&mut self) -> Option<u32> {
        if self.at + 4 > self.text.len() {
            return None;
        }
        let mut v = 0;
        for _ in 0..4 {
            let c = self.text[self.at] as u32 | 0x20;
            self.at += 1;
            let d = match c.wrapping_sub(b'0' as u32) {
                d @ 0..=9 => d,
                _ => match c.wrapping_sub(b'a' as u32) {
                    d @ 0..=5 => d + 10,
                    _ => return None,
                },
            };
            v = v << 4 | d;
        }
        Some(v)
    }
}

/// A string's bytes out: into `buf`, up to `room`, which shrinks to what
/// is there once something did not fit (nothing more goes out).
pub struct Out<'a> {
    pub buf: &'a mut [u8],
    pub len: usize,
    room: usize,
}

impl<'a> Out<'a> {
    pub fn new(buf: &'a mut [u8]) -> Out<'a> {
        let room = buf.len();
        Out { buf, len: 0, room }
    }

    /// A byte out, if there is room; if not, a raw multi-byte character
    /// the end of the room cut is taken back.
    fn put(&mut self, c: u8) {
        if self.len < self.room {
            self.buf[self.len] = c;
            self.len += 1;
            return;
        }
        let mut lead = self.len; // back over continuation bytes
        while lead > 0 && self.buf[lead - 1] & 0xC0 == 0x80 {
            lead -= 1;
        }
        if lead > 0 && self.buf[lead - 1] >= 0xC0 {
            let need = match self.buf[lead - 1] {
                0xC0..0xE0 => 2,
                0xE0..0xF0 => 3,
                _ => 4,
            };
            if self.len - lead + 1 < need {
                self.len = lead - 1;
            }
        }
        self.room = self.len;
    }

    /// A code point out, whole or not at all (a surrogate as U+FFFD).
    fn utf8(&mut self, cp: u32) {
        let cp = if (0xD800..=0xDFFF).contains(&cp) {
            0xFFFD
        } else {
            cp
        };
        if cp < 0x80 {
            return self.put(cp as u8);
        }
        let n = match cp {
            0..0x800 => 2,
            0x800..0x10000 => 3,
            _ => 4,
        };
        if self.len + n > self.room {
            self.room = self.len;
            return;
        }
        let lead = [0, 0, 0xC0, 0xE0, 0xF0][n];
        self.put(lead | (cp >> (6 * (n - 1))) as u8);
        for i in (0..n - 1).rev() {
            self.put(0x80 | (cp >> (6 * i)) as u8 & 0x3F);
        }
    }
}

/// Text as the inside of a JSON string, into `out`: '"' and '\' escaped,
/// \n \t \r as such, other control characters as \u00xx, the rest as it
/// is -> (bytes written, whether it all fit). What did not fit is left
/// out, from the first byte that did not.
pub fn escape(text: &[u8], out: &mut [u8]) -> (usize, bool) {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut at = 0;
    for &c in text {
        let pair = match c {
            b'"' | b'\\' => c,
            b'\n' => b'n',
            b'\t' => b't',
            b'\r' => b'r',
            0..0x20 => {
                if at + 6 > out.len() {
                    return (at, false);
                }
                out[at..at + 4].copy_from_slice(b"\\u00");
                out[at + 4] = HEX[(c >> 4) as usize];
                out[at + 5] = HEX[(c & 15) as usize];
                at += 6;
                continue;
            }
            _ => {
                if at >= out.len() {
                    return (at, false);
                }
                out[at] = c;
                at += 1;
                continue;
            }
        };
        if at + 2 > out.len() {
            return (at, false);
        }
        out[at] = b'\\';
        out[at + 1] = pair;
        at += 2;
    }
    (at, true)
}

// -- the kernel's entry points, through json.asm ----------------------------

/// The cursor's text, from where it is to its end.
///
/// # Safety
/// The cursor's bytes must be readable, and not change while it is read.
unsafe fn text_at<'a>(c: &Cursor) -> &'a [u8] {
    let len = (c.end as usize).saturating_sub(c.at as usize);
    if len == 0 {
        return &[];
    }
    // SAFETY: the caller's
    unsafe { core::slice::from_raw_parts(c.at, len) }
}

/// `len` bytes at `p` to write, or none if there are none.
///
/// # Safety
/// They must be writable, and nothing else may use them meanwhile.
unsafe fn bytes_out<'a>(p: *mut u8, len: usize) -> &'a mut [u8] {
    if len == 0 || p.is_null() {
        return &mut [];
    }
    // SAFETY: the caller's
    unsafe { core::slice::from_raw_parts_mut(p, len) }
}

/// A reader at the cursor, `f` on it, then the cursor where it was left.
///
/// # Safety
/// As [`text_at`].
unsafe fn read(c: &mut Cursor, f: impl FnOnce(&mut Reader) -> Option<u64>) -> Answer {
    // SAFETY: the caller's
    let mut r = Reader::new(unsafe { text_at(c) });
    let found = f(&mut r);
    c.at = c.at.wrapping_add(r.at);
    Answer::of(found)
}

/// json_ws: past white space.
///
/// # Safety
/// For each of these: the cursor's text must be readable, a key or text a
/// NUL-terminated string, and an output buffer writable for its room and
/// apart from the text.
#[unsafe(no_mangle)]
pub unsafe extern "sysv64" fn rs_json_ws(c: &mut Cursor, _: usize, _: usize) -> Answer {
    // SAFETY: the caller's
    unsafe {
        read(c, |r| {
            r.ws();
            Some(0)
        })
    }
}

/// json_skip: past one value.
///
/// # Safety
/// As [`rs_json_ws`].
#[unsafe(no_mangle)]
pub unsafe extern "sysv64" fn rs_json_skip(c: &mut Cursor, _: usize, _: usize) -> Answer {
    // SAFETY: the caller's
    unsafe { read(c, |r| r.skip().map(|_| 0)) }
}

/// json_get(key): at an object -> at that key's value.
///
/// # Safety
/// As [`rs_json_ws`].
#[unsafe(no_mangle)]
pub unsafe extern "sysv64" fn rs_json_get(c: &mut Cursor, key: *const u8, _: usize) -> Answer {
    // SAFETY: the caller's
    let key = unsafe { CStr::from_ptr(key.cast()) }.to_bytes();
    // SAFETY: the caller's
    unsafe { read(c, |r| r.get(key).map(|_| 0)) }
}

/// json_is(text): whether the value is that string (`ok`, which json.asm
/// makes ZF); the cursor stays.
///
/// # Safety
/// As [`rs_json_ws`].
#[unsafe(no_mangle)]
pub unsafe extern "sysv64" fn rs_json_is(c: &mut Cursor, text: *const u8, _: usize) -> Answer {
    // SAFETY: the caller's
    let text = unsafe { CStr::from_ptr(text.cast()) }.to_bytes();
    // SAFETY: the caller's
    unsafe { read(c, |r| r.is(text).then_some(0)) }
}

/// json_str(out, room): a string -> its bytes out.
///
/// # Safety
/// As [`rs_json_ws`].
#[unsafe(no_mangle)]
pub unsafe extern "sysv64" fn rs_json_str(c: &mut Cursor, out: *mut u8, room: usize) -> Answer {
    // SAFETY: the caller's
    let mut out = Out::new(unsafe { bytes_out(out, room) });
    // SAFETY: the caller's
    unsafe { read(c, |r| r.string(&mut out).map(|_| out.len as u64)) }
}

/// json_num: a number -> its unsigned integer part.
///
/// # Safety
/// As [`rs_json_ws`].
#[unsafe(no_mangle)]
pub unsafe extern "sysv64" fn rs_json_num(c: &mut Cursor, _: usize, _: usize) -> Answer {
    // SAFETY: the caller's
    unsafe { read(c, |r| r.num()) }
}

/// json_escape(text, bytes, out, room) -> bytes written; `ok` 0 if they
/// did not all fit.
///
/// # Safety
/// `text` must be readable for `bytes`, `out` writable for `room`, apart.
#[unsafe(no_mangle)]
pub unsafe extern "sysv64" fn rs_json_escape(
    text: *const u8,
    bytes: usize,
    out: *mut u8,
    room: usize,
) -> Answer {
    let text = if bytes == 0 || text.is_null() {
        &[]
    } else {
        // SAFETY: the caller's
        unsafe { core::slice::from_raw_parts(text, bytes) }
    };
    // SAFETY: the caller's
    let (n, all) = escape(text, unsafe { bytes_out(out, room) });
    Answer {
        value: n as u64,
        ok: all as u64,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn str_of(json: impl AsRef<[u8]>, room: usize) -> Option<(Vec<u8>, usize)> {
        let mut buf = vec![0; room];
        let mut r = Reader::new(json.as_ref());
        let mut out = Out::new(&mut buf);
        r.string(&mut out)?;
        let n = out.len;
        Some((buf[..n].to_vec(), r.at))
    }

    #[test]
    fn get_finds_a_key_past_others() {
        let text = br#" { "a" : [1, {"b": "}"}], "b":{"c" :  42 } } "#;
        let mut r = Reader::new(text);
        assert_eq!(r.get(b"b"), Some(()));
        assert_eq!(r.get(b"c"), Some(()));
        assert_eq!(r.num(), Some(42));
        assert_eq!(Reader::new(text).get(b"d"), None);
        assert_eq!(Reader::new(b"{}").get(b"a"), None);
        assert_eq!(Reader::new(b"[1]").get(b"a"), None);
    }

    #[test]
    fn is_compares_the_string_as_written() {
        let r = Reader::new(br#""text_delta","#);
        assert!(r.is(b"text_delta"));
        assert!(!r.is(b"text"));
        assert!(!r.is(b"text_delta_"));
        assert!(!Reader::new(br#""text_delta"#).is(b"text_delta"));
    }

    #[test]
    fn strings_unescape_to_utf8() {
        let (s, at) = str_of(r#""a\"b\\c\/\n\t\r\b\f\u00e9\ud83d\ude00" tail"#, 64).unwrap();
        assert_eq!(s, "a\"b\\c/\n\t\r\u{8}\u{c}\u{e9}\u{1f600}".as_bytes());
        assert_eq!(at, 39);
        assert_eq!(str_of(r#""\ud83d""#, 8).unwrap().0, "\u{FFFD}".as_bytes());
        assert_eq!(str_of(r#""\ude00x""#, 8).unwrap().0, "\u{FFFD}x".as_bytes());
        assert_eq!(str_of(r#""\ud83dA""#, 8).unwrap().0, "\u{FFFD}A".as_bytes());
        assert_eq!(str_of(r#""abc"#, 8), None);
        assert_eq!(str_of(r#""\u12"#, 8), None);
    }

    #[test]
    fn strings_cut_on_a_character_boundary() {
        assert_eq!(str_of(b"\"a\xc3\xa9b\"", 2).unwrap().0, b"a");
        assert_eq!(str_of("\"a\u{e9}\"", 3).unwrap().0, "a\u{e9}".as_bytes());
        assert_eq!(str_of(r#""a\u00e9b""#, 2).unwrap().0, b"a");
        assert_eq!(str_of(r#""a\ud83d\ude00""#, 4).unwrap().0, b"a");
        assert_eq!(str_of(r#""abc""#, 0).unwrap().0, b"");
    }

    #[test]
    fn numbers_and_skips() {
        assert_eq!(Reader::new(b"1234,").num(), Some(1234));
        assert_eq!(Reader::new(b"12.5").num(), Some(12));
        assert_eq!(Reader::new(b"-1").num(), None);
        let mut r = Reader::new(br#"  {"a":[1,"]",{"b":null}]} ,"#);
        assert_eq!(r.skip(), Some(()));
        assert_eq!(r.at, 26);
        let mut r = Reader::new(b"true]");
        assert_eq!(r.skip(), Some(()));
        assert_eq!(r.at, 4);
        assert_eq!(Reader::new(b"]").skip(), None);
        assert_eq!(Reader::new(b"[1, 2").skip(), None);
    }

    #[test]
    fn escape_writes_a_strings_inside() {
        let mut out = [0; 32];
        let (n, all) = escape(b"a\"b\\\n\t\r\x01\x1f\xc3\xa9", &mut out);
        assert!(all);
        assert_eq!(&out[..n], b"a\\\"b\\\\\\n\\t\\r\\u0001\\u001f\xc3\xa9");
        let mut out = [0; 7];
        assert_eq!(escape(b"ab\x01", &mut out), (2, false));
        assert_eq!(escape(b"abc\"", &mut out[..4]), (3, false));
    }
}
