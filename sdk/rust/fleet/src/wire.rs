//! A connection as fleet's wire has it (its docs/protocol.md, section 1):
//! JSON lines, each perhaps followed by raw bytes, over the kernel's TLS.

use core::time::Duration;

use axiom::Error;
use axiom::net::Socket;
use axiom::time::Instant;

use crate::json::{self, Int, Object, Value};

/// A line's bytes at most (fleet's MAX_LINE).
pub const MAX_LINE: usize = 64 << 20;

/// Why a connection is done with.
#[derive(Debug)]
pub struct Closed(pub String);

/// A request failed: refused (answered with its error), or the
/// connection is done with.
#[derive(Debug)]
pub enum Fail {
    Refuse(String),
    Close(Closed),
}

impl From<Closed> for Fail {
    fn from(c: Closed) -> Fail {
        Fail::Close(c)
    }
}

impl From<String> for Fail {
    fn from(s: String) -> Fail {
        Fail::Refuse(s)
    }
}

impl From<&str> for Fail {
    fn from(s: &str) -> Fail {
        Fail::Refuse(s.to_string())
    }
}

pub struct Conn {
    s: Socket,
    buf: Vec<u8>,
    at: usize,
    /// How long one wait may be, once `deadline` is gone.
    pub idle: Duration,
    /// When everything must be done by (the hello's 20 s), if set.
    pub deadline: Option<Instant>,
}

impl Conn {
    pub fn new(s: Socket) -> Conn {
        Conn { s, buf: Vec::new(), at: 0, idle: Duration::from_secs(3600), deadline: None }
    }

    pub fn socket(&self) -> &Socket {
        &self.s
    }

    fn until(&self) -> Instant {
        self.deadline.unwrap_or_else(|| Instant::now() + self.idle)
    }

    /// More received, onto `buf`.
    fn fill(&mut self) -> Result<(), Closed> {
        if self.at > 0 && self.at * 2 >= self.buf.len() {
            self.buf.drain(..self.at);
            self.at = 0;
        }
        let mut b = [0u8; 16384];
        loop {
            match self.s.recv(&mut b) {
                Ok(n) => {
                    self.buf.extend_from_slice(&b[..n]);
                    return Ok(());
                }
                Err(Error::EMPTY) => match self.s.wait_recv(Some(self.until())) {
                    Ok(()) => {}
                    Err(Error::TIMEOUT) => return Err(Closed("quiet too long".into())),
                    Err(e) => return Err(Closed(format!("waiting: {:?}", e))),
                },
                Err(Error::PEER) => return Err(Closed("the connection closed".into())),
                Err(e) => return Err(Closed(format!("receiving: {:?}", e))),
            }
        }
    }

    /// The next line, without its newline; at most `max` bytes.
    pub fn line(&mut self, max: usize) -> Result<Vec<u8>, Closed> {
        let mut looked = self.at;
        loop {
            if let Some(i) = self.buf[looked..].iter().position(|&c| c == b'\n') {
                let end = looked + i;
                let line = self.buf[self.at..end].to_vec();
                self.at = end + 1;
                return Ok(line);
            }
            looked = self.buf.len();
            if looked - self.at > max {
                return Err(Closed("a line too long".into()));
            }
            let before = self.at;
            self.fill()?;
            looked -= before - self.at; // fill may have moved what was kept
        }
    }

    /// The next line, as a JSON object.
    pub fn message(&mut self, max: usize) -> Result<Value, Closed> {
        let line = self.line(max)?;
        match json::parse(&line) {
            Ok(v @ Object(_)) => Ok(v),
            Ok(_) => Err(Closed("a line that is not an object".into())),
            Err(e) => Err(Closed(format!("a line that is not JSON: {}", e))),
        }
    }

    /// `n` raw bytes, given to `each` as they come.
    pub fn take(&mut self, mut n: usize, mut each: impl FnMut(&[u8])) -> Result<(), Closed> {
        while n > 0 {
            if self.at == self.buf.len() {
                self.buf.clear();
                self.at = 0;
                self.fill()?;
            }
            let k = n.min(self.buf.len() - self.at);
            each(&self.buf[self.at..self.at + k]);
            self.at += k;
            n -= k;
        }
        Ok(())
    }

    pub fn write(&mut self, mut b: &[u8]) -> Result<(), Closed> {
        while !b.is_empty() {
            match self.s.send(b) {
                Ok(n) => b = &b[n..],
                Err(Error::FULL) => match self.s.wait_send(Some(self.until())) {
                    Ok(()) => {}
                    Err(Error::TIMEOUT) => return Err(Closed("not taking what is sent".into())),
                    Err(e) => return Err(Closed(format!("waiting to send: {:?}", e))),
                },
                Err(e) => return Err(Closed(format!("sending: {:?}", e))),
            }
        }
        Ok(())
    }

    /// One message, as one line.
    pub fn send(&mut self, msg: &Value) -> Result<(), Closed> {
        let mut line = msg.encode().into_bytes();
        line.push(b'\n');
        self.write(&line)
    }

    /// A message with `"bytes": n` added, then the n bytes (Channel.send's:
    /// no "bytes" when there are none).
    pub fn send_with(&mut self, msg: Value, payload: &[u8]) -> Result<(), Closed> {
        let msg = if payload.is_empty() { msg } else { with(msg, "bytes", Int(payload.len() as i128)) };
        self.send(&msg)?;
        self.write(payload)
    }
}

/// `msg` with `key` set (in its place if there, else at the end), as a
/// Python dict's update.
pub fn with(msg: Value, key: &str, v: Value) -> Value {
    match msg {
        Object(mut fields) => {
            match fields.iter_mut().find(|(k, _)| k == key) {
                Some(f) => f.1 = v,
                None => fields.push((key.to_string(), v)),
            }
            Object(fields)
        }
        other => other,
    }
}
