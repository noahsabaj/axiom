//! The console the program was run from: its shell's window, and the log.
//!
//!   axiom::println!("{} frames", n);
//!
//! (With std, println! reaches it too, through the zkvm layer.)

use core::fmt::{self, Write};
use core::sync::atomic::{AtomicU32, Ordering};

use crate::ring;
use crate::sys::*;

static CONSOLE: AtomicU32 = AtomicU32::new(0);

pub(crate) fn init(h: Handle) {
    CONSOLE.store(h, Ordering::Relaxed);
}

/// Bytes onto the console (RO_WRITE), as they are.
pub fn write(bytes: &[u8]) {
    let con = CONSOLE.load(Ordering::Relaxed);
    if con == 0 {
        return;
    }
    let mut r = ring::lock();
    for part in bytes.chunks(4096) {
        let Ok(io) = r.io_with(part) else { return };
        let mut e = Entry::new(RO_WRITE, con);
        e.handle2 = io;
        e.a1 = part.len() as u64;
        let _ = r.call(&e);
    }
}

/// What print! writes through: a line's bytes gathered, then written.
pub struct Console {
    buf: [u8; 512],
    len: usize,
}

impl Console {
    pub const fn new() -> Console {
        Console { buf: [0; 512], len: 0 }
    }

    pub fn flush(&mut self) {
        write(&self.buf[..self.len]);
        self.len = 0;
    }
}

impl Default for Console {
    fn default() -> Console {
        Console::new()
    }
}

impl Write for Console {
    fn write_str(&mut self, s: &str) -> fmt::Result {
        let mut b = s.as_bytes();
        while !b.is_empty() {
            let n = b.len().min(self.buf.len() - self.len);
            self.buf[self.len..self.len + n].copy_from_slice(&b[..n]);
            self.len += n;
            b = &b[n..];
            if self.len == self.buf.len() {
                self.flush();
            }
        }
        Ok(())
    }
}

impl Drop for Console {
    fn drop(&mut self) {
        if self.len > 0 {
            self.flush();
        }
    }
}

#[doc(hidden)]
pub fn _print(args: fmt::Arguments) {
    let mut c = Console::new();
    let _ = c.write_fmt(args);
}

#[macro_export]
macro_rules! print {
    ($($arg:tt)*) => { $crate::console::_print(format_args!($($arg)*)) };
}

#[macro_export]
macro_rules! println {
    () => { $crate::console::write(b"\n") };
    ($($arg:tt)*) => { $crate::console::_print(format_args!("{}\n", format_args!($($arg)*))) };
}
