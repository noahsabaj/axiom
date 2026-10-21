//! JSON as fleet's wire has it (its docs/protocol.md, section 1): any valid
//! JSON read; written as Python's json.dumps writes it, compact, keys in
//! the order given, non-ASCII escaped. Integers stay exact (a file's time
//! in nanoseconds does not fit a double).

use std::fmt::Write;

#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    Int(i128),
    Float(f64),
    Str(String),
    List(Vec<Value>),
    Object(Vec<(String, Value)>),
}

pub use Value::*;

impl Value {
    pub fn get(&self, key: &str) -> Option<&Value> {
        match self {
            Object(fields) => fields.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    /// A field, if it is there and not null.
    pub fn field(&self, key: &str) -> Option<&Value> {
        self.get(key).filter(|v| **v != Null)
    }

    pub fn str(&self) -> Option<&str> {
        match self {
            Str(s) => Some(s),
            _ => None,
        }
    }

    pub fn int(&self) -> Option<i128> {
        match self {
            Int(i) => Some(*i),
            Float(f) if f.fract() == 0.0 && f.abs() < 1e30 => Some(*f as i128),
            _ => None,
        }
    }

    pub fn num(&self) -> Option<f64> {
        match self {
            Int(i) => Some(*i as f64),
            Float(f) => Some(*f),
            _ => None,
        }
    }

    pub fn list(&self) -> Option<&[Value]> {
        match self {
            List(v) => Some(v),
            _ => None,
        }
    }

    /// Python's truth: false, 0, "", [], {} and null are false.
    pub fn truthy(&self) -> bool {
        match self {
            Null => false,
            Bool(b) => *b,
            Int(i) => *i != 0,
            Float(f) => *f != 0.0,
            Str(s) => !s.is_empty(),
            List(v) => !v.is_empty(),
            Object(f) => !f.is_empty(),
        }
    }

    /// One line, as fleet sends it (no newline).
    pub fn encode(&self) -> String {
        let mut out = String::new();
        self.write(&mut out);
        out
    }

    fn write(&self, out: &mut String) {
        match self {
            Null => out.push_str("null"),
            Bool(b) => out.push_str(if *b { "true" } else { "false" }),
            Int(i) => {
                let _ = write!(out, "{}", i);
            }
            Float(f) => {
                if f.is_finite() {
                    let _ = write!(out, "{:?}", f);
                } else {
                    out.push_str("null");
                }
            }
            Str(s) => quote(s, out),
            List(v) => {
                out.push('[');
                for (i, x) in v.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    x.write(out);
                }
                out.push(']');
            }
            Object(fields) => {
                out.push('{');
                for (i, (k, x)) in fields.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    quote(k, out);
                    out.push(':');
                    x.write(out);
                }
                out.push('}');
            }
        }
    }

    /// What Python's str() makes of it, for the hello's refusal.
    pub fn py_str(&self) -> String {
        match self {
            Str(s) => s.clone(),
            _ => self.py_repr(),
        }
    }

    /// And its repr(): 'text' quoted, None, True, lists and dicts with spaces.
    pub fn py_repr(&self) -> String {
        match self {
            Null => "None".into(),
            Bool(true) => "True".into(),
            Bool(false) => "False".into(),
            Int(i) => i.to_string(),
            Float(f) => {
                let s = format!("{:?}", f);
                if s.contains('e') || s.contains('.') || !f.is_finite() { s } else { s + ".0" }
            }
            Str(s) => {
                let q = if s.contains('\'') && !s.contains('"') { '"' } else { '\'' };
                let mut out = String::from(q);
                for c in s.chars() {
                    match c {
                        '\\' => out.push_str("\\\\"),
                        '\n' => out.push_str("\\n"),
                        '\r' => out.push_str("\\r"),
                        '\t' => out.push_str("\\t"),
                        c if c == q => {
                            out.push('\\');
                            out.push(c);
                        }
                        c if (c as u32) < 0x20 || c as u32 == 0x7F => {
                            let _ = write!(out, "\\x{:02x}", c as u32);
                        }
                        c => out.push(c),
                    }
                }
                out.push(q);
                out
            }
            List(v) => format!("[{}]", v.iter().map(Value::py_repr).collect::<Vec<_>>().join(", ")),
            Object(f) => format!(
                "{{{}}}",
                f.iter().map(|(k, v)| format!("{}: {}", Str(k.clone()).py_repr(), v.py_repr())).collect::<Vec<_>>().join(", ")
            ),
        }
    }
}

fn quote(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 || (c as u32) > 0x7E => {
                let mut units = [0u16; 2];
                for u in c.encode_utf16(&mut units) {
                    let _ = write!(out, "\\u{:04x}", u);
                }
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

/// An object, from (key, value) pairs.
pub fn obj<const N: usize>(fields: [(&str, Value); N]) -> Value {
    Object(fields.into_iter().map(|(k, v)| (k.to_string(), v)).collect())
}

impl From<&str> for Value {
    fn from(s: &str) -> Value {
        Str(s.to_string())
    }
}

impl From<String> for Value {
    fn from(s: String) -> Value {
        Str(s)
    }
}

impl From<bool> for Value {
    fn from(b: bool) -> Value {
        Bool(b)
    }
}

impl From<i64> for Value {
    fn from(i: i64) -> Value {
        Int(i as i128)
    }
}

impl From<u64> for Value {
    fn from(i: u64) -> Value {
        Int(i as i128)
    }
}

impl From<usize> for Value {
    fn from(i: usize) -> Value {
        Int(i as i128)
    }
}

impl From<f64> for Value {
    fn from(f: f64) -> Value {
        Float(f)
    }
}

impl<T: Into<Value>> From<Option<T>> for Value {
    fn from(v: Option<T>) -> Value {
        v.map_or(Null, Into::into)
    }
}

impl<T: Into<Value>> From<Vec<T>> for Value {
    fn from(v: Vec<T>) -> Value {
        List(v.into_iter().map(Into::into).collect())
    }
}

/// `text` as one JSON value -> it, or why not.
pub fn parse(text: &[u8]) -> Result<Value, String> {
    let mut p = Parser { b: text, i: 0, depth: 0 };
    p.ws();
    let v = p.value()?;
    p.ws();
    if p.i != p.b.len() {
        return Err(format!("extra data at {}", p.i));
    }
    Ok(v)
}

struct Parser<'a> {
    b: &'a [u8],
    i: usize,
    depth: u32,
}

impl Parser<'_> {
    fn ws(&mut self) {
        while self.i < self.b.len() && matches!(self.b[self.i], b' ' | b'\t' | b'\n' | b'\r') {
            self.i += 1;
        }
    }

    fn peek(&self) -> Option<u8> {
        self.b.get(self.i).copied()
    }

    fn lit(&mut self, word: &str, v: Value) -> Result<Value, String> {
        if self.b[self.i..].starts_with(word.as_bytes()) {
            self.i += word.len();
            Ok(v)
        } else {
            Err(format!("bad value at {}", self.i))
        }
    }

    fn value(&mut self) -> Result<Value, String> {
        self.depth += 1;
        if self.depth > 200 {
            return Err("nested too deep".into());
        }
        let v = match self.peek() {
            None => Err("the end, wanting a value".into()),
            Some(b'n') => self.lit("null", Null),
            Some(b't') => self.lit("true", Bool(true)),
            Some(b'f') => self.lit("false", Bool(false)),
            Some(b'"') => self.string().map(Str),
            Some(b'[') => {
                self.i += 1;
                let mut v = Vec::new();
                self.ws();
                if self.peek() == Some(b']') {
                    self.i += 1;
                } else {
                    loop {
                        self.ws();
                        v.push(self.value()?);
                        self.ws();
                        match self.peek() {
                            Some(b',') => self.i += 1,
                            Some(b']') => {
                                self.i += 1;
                                break;
                            }
                            _ => return Err(format!("wanted , or ] at {}", self.i)),
                        }
                    }
                }
                Ok(List(v))
            }
            Some(b'{') => {
                self.i += 1;
                let mut fields = Vec::new();
                self.ws();
                if self.peek() == Some(b'}') {
                    self.i += 1;
                } else {
                    loop {
                        self.ws();
                        if self.peek() != Some(b'"') {
                            return Err(format!("wanted a key at {}", self.i));
                        }
                        let k = self.string()?;
                        self.ws();
                        if self.peek() != Some(b':') {
                            return Err(format!("wanted : at {}", self.i));
                        }
                        self.i += 1;
                        self.ws();
                        let v = self.value()?;
                        match fields.iter_mut().find(|(key, _): &&mut (String, Value)| *key == k) {
                            Some(f) => f.1 = v, // the last one wins, as in Python
                            None => fields.push((k, v)),
                        }
                        self.ws();
                        match self.peek() {
                            Some(b',') => self.i += 1,
                            Some(b'}') => {
                                self.i += 1;
                                break;
                            }
                            _ => return Err(format!("wanted , or }} at {}", self.i)),
                        }
                    }
                }
                Ok(Object(fields))
            }
            Some(c) if c == b'-' || c.is_ascii_digit() => self.number(),
            Some(_) => Err(format!("bad value at {}", self.i)),
        };
        self.depth -= 1;
        v
    }

    fn number(&mut self) -> Result<Value, String> {
        let start = self.i;
        if self.peek() == Some(b'-') {
            self.i += 1;
        }
        let digits = self.i;
        while self.peek().is_some_and(|c| c.is_ascii_digit()) {
            self.i += 1;
        }
        if self.i == digits || (self.b[digits] == b'0' && self.i - digits > 1) {
            return Err(format!("bad number at {}", start));
        }
        let mut float = false;
        if self.peek() == Some(b'.') {
            float = true;
            self.i += 1;
            let f = self.i;
            while self.peek().is_some_and(|c| c.is_ascii_digit()) {
                self.i += 1;
            }
            if self.i == f {
                return Err(format!("bad number at {}", start));
            }
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            float = true;
            self.i += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.i += 1;
            }
            let e = self.i;
            while self.peek().is_some_and(|c| c.is_ascii_digit()) {
                self.i += 1;
            }
            if self.i == e {
                return Err(format!("bad number at {}", start));
            }
        }
        let text = std::str::from_utf8(&self.b[start..self.i]).unwrap();
        if !float {
            if let Ok(i) = text.parse::<i128>() {
                return Ok(Int(i));
            }
        }
        text.parse::<f64>().map(Float).map_err(|_| format!("bad number at {}", start))
    }

    fn hex4(&mut self) -> Result<u32, String> {
        let h = self.b.get(self.i..self.i + 4).ok_or("a cut-off \\u")?;
        let s = std::str::from_utf8(h).map_err(|_| "a bad \\u")?;
        let v = u32::from_str_radix(s, 16).map_err(|_| "a bad \\u")?;
        self.i += 4;
        Ok(v)
    }

    fn string(&mut self) -> Result<String, String> {
        self.i += 1; // the quote
        let mut out = String::new();
        loop {
            let start = self.i;
            while self.i < self.b.len() && self.b[self.i] != b'"' && self.b[self.i] != b'\\' && self.b[self.i] >= 0x20 {
                self.i += 1;
            }
            out.push_str(std::str::from_utf8(&self.b[start..self.i]).map_err(|_| "a string that is not UTF-8")?);
            match self.peek() {
                Some(b'"') => {
                    self.i += 1;
                    return Ok(out);
                }
                Some(b'\\') => {
                    self.i += 1;
                    let c = self.peek().ok_or("a cut-off escape")?;
                    self.i += 1;
                    match c {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'b' => out.push('\u{8}'),
                        b'f' => out.push('\u{c}'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'u' => {
                            let mut u = self.hex4()?;
                            if (0xD800..0xDC00).contains(&u) && self.b[self.i..].starts_with(b"\\u") {
                                let save = self.i;
                                self.i += 2;
                                let low = self.hex4()?;
                                if (0xDC00..0xE000).contains(&low) {
                                    u = 0x10000 + ((u - 0xD800) << 10) + (low - 0xDC00);
                                } else {
                                    self.i = save;
                                }
                            }
                            out.push(char::from_u32(u).unwrap_or('\u{FFFD}'));
                        }
                        _ => return Err(format!("a bad escape at {}", self.i)),
                    }
                }
                _ => return Err("a cut-off string".into()),
            }
        }
    }
}
