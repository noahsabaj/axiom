//! Windows on the desktop, for a program given it (wants::DESK, or +desk).
//!
//!   let mut w = Window::open(800, 600, Window::RESIZE)?;
//!   w.set_title("Hello");
//!   loop {
//!       while let Some(e) = w.poll() { ... }       // or w.wait(deadline)
//!       let f = w.frame();                          // draw: f.row(y)[x] = 0xRRGGBB
//!       w.show();
//!   }
//!
//! The pixels are memory the program and the desktop share: 0x00RRGGBB in
//! each u32 (bytes B, G, R, x), `stride` u32s a row. A window that can be
//! resized (or is the whole screen) has room for the whole screen from the
//! start: its stride is the screen's width, and stays; a resize hands it no
//! new memory, only a new size (Event::Resized), to draw all of again and
//! show. One that cannot has a stride of its width. What was drawn reaches
//! the screen once shown (RO_WIN_SHOW).
//!
//! What happens to it comes over a channel, a message each (WE_*): keys
//! while it has them (no key-up: a key's press, its repeats), presses and
//! releases, the pointer while a button is held, the wheel, its close button
//! (it only asks: the window goes when the program drops it, or ends), a
//! new size, a new look, the keys gained or lost.

use core::sync::atomic::{AtomicPtr, Ordering};

use crate::ring;
use crate::rt;
use crate::sys::*;
use crate::time::Instant;

// the look (LK_*)
const LK_SERIAL: usize = 0;
const LK_S4: usize = 4;
const LK_MODE: usize = 8;
const LK_ACCENT: usize = 12;
const LK_SCR_W: usize = 16;
const LK_SCR_H: usize = 20;
const LK_C: usize = 64;

// what a window says (WE_*)
const WE_SIZE: usize = 16;
const WE_KEY: u32 = 1;
const WE_PRESS: u32 = 2;
const WE_RELEASE: u32 = 3;
const WE_MOVE: u32 = 4;
const WE_WHEEL: u32 = 5;
const WE_CLOSE: u32 = 6;
const WE_RESIZED: u32 = 7;
const WE_LOOK: u32 = 8;
const WE_FOCUS: u32 = 9;

static LOOK: AtomicPtr<u8> = AtomicPtr::new(core::ptr::null_mut());

/// The desktop's look: its scale, its theme, the screen. The kernel keeps it
/// up to date in memory it shares; Event::Look says it changed.
#[derive(Clone, Copy)]
pub struct Look {
    p: *const u8,
}

unsafe impl Send for Look {}
unsafe impl Sync for Look {}

/// The theme's colours, by what they are for (TC_*): Look::color.
pub mod colors {
    pub const WINDOW: usize = 0;
    pub const TITLE: usize = 4;
    pub const SEP: usize = 12;
    pub const EDGE: usize = 16;
    pub const TEXT: usize = 24;
    pub const TEXT2: usize = 28;
    pub const TEXT3: usize = 32;
    pub const PANEL: usize = 84;
    pub const LINE: usize = 88;
}

impl Look {
    /// It, mapped the first time (RO_DESK_LOOK).
    pub fn get() -> Result<Look> {
        let p = LOOK.load(Ordering::Acquire);
        if !p.is_null() {
            return Ok(Look { p });
        }
        let desk = rt::desk_handle();
        if desk == 0 {
            return Err(Error::ABSENT);
        }
        let (h, _) = ring::call(&Entry::new(RO_DESK_LOOK, desk))?;
        let (va, _) = unsafe { syscall(SYS_MAP, h, 0, 0, 0, 0) };
        let p = check(va)? as *mut u8;
        LOOK.store(p, Ordering::Release);
        Ok(Look { p })
    }

    fn u32_at(self, off: usize) -> u32 {
        unsafe { core::ptr::read_volatile(self.p.add(off) as *const u32) }
    }

    /// One more each time it changes.
    pub fn serial(self) -> u32 {
        self.u32_at(LK_SERIAL)
    }

    /// The scale the user chose: quarters of a pixel a point (4 = 1x).
    pub fn scale4(self) -> u32 {
        self.u32_at(LK_S4)
    }

    /// Points in pixels, at that scale.
    pub fn px(self, points: i32) -> i32 {
        (points * self.scale4() as i32 + 2) >> 2
    }

    pub fn dark(self) -> bool {
        self.u32_at(LK_MODE) == 0
    }

    /// The accent, 0xRRGGBB.
    pub fn accent(self) -> u32 {
        self.u32_at(LK_ACCENT)
    }

    /// The screen, in pixels.
    pub fn screen(self) -> (u32, u32) {
        (self.u32_at(LK_SCR_W), self.u32_at(LK_SCR_H))
    }

    /// A theme colour, 0xRRGGBB (colors::*).
    pub fn color(self, which: usize) -> u32 {
        self.u32_at(LK_C + which) & 0xFF_FFFF
    }
}

/// The modifiers held with a key (WM_*).
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct Mods(pub u32);

impl Mods {
    pub fn shift(self) -> bool {
        self.0 & 1 != 0
    }
    pub fn ctrl(self) -> bool {
        self.0 & 2 != 0
    }
    pub fn alt(self) -> bool {
        self.0 & 4 != 0
    }
    pub fn meta(self) -> bool {
        self.0 & 8 != 0
    }
}

/// A key, as the kernel codes them: text, and the keys past it.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Key {
    /// What it types; with ctrl, the letter (ctrl+A is Char('a')).
    Char(char),
    Enter,
    Tab,
    Backspace,
    Escape,
    Up,
    Down,
    Left,
    Right,
    Home,
    End,
    PageUp,
    PageDown,
    Insert,
    Delete,
    /// shift+tab
    BackTab,
    /// F1 to F12
    F(u8),
    Other(u32),
}

impl Key {
    pub fn from_code(code: u32, mods: Mods) -> Key {
        match code {
            1..=26 if mods.ctrl() => Key::Char((b'a' + code as u8 - 1) as char),
            27..=31 if mods.ctrl() => Key::Char(b"[\\]^_"[code as usize - 27] as char),
            8 | 127 => Key::Backspace,
            9 => Key::Tab,
            10 | 13 => Key::Enter,
            27 => Key::Escape,
            32..=126 => Key::Char(code as u8 as char),
            0x80 => Key::Up,
            0x81 => Key::Down,
            0x82 => Key::Left,
            0x83 => Key::Right,
            0x84 => Key::Home,
            0x85 => Key::End,
            0x86 => Key::PageUp,
            0x87 => Key::PageDown,
            0x88 => Key::Insert,
            0x89 => Key::Delete,
            0x8A => Key::BackTab,
            0x90..=0x9B => Key::F((code - 0x90 + 1) as u8),
            0xA0.. => char::from_u32(code).map_or(Key::Other(code), Key::Char),
            _ => Key::Other(code),
        }
    }
}

/// A mouse button.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Button {
    Left,
    Right,
    Middle,
    Other(u32),
}

impl Button {
    fn from_code(code: u32) -> Button {
        match code {
            1 => Button::Left,
            2 => Button::Right,
            3 => Button::Middle,
            n => Button::Other(n),
        }
    }
}

/// What happened to a window. Positions are pixels from its top left.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Event {
    Key { key: Key, mods: Mods, code: u32 },
    Press { button: Button, x: i32, y: i32 },
    /// let go, anywhere
    Release { button: Button, x: i32, y: i32 },
    /// the pointer moved, a button held
    Move { x: i32, y: i32 },
    /// notches, up positive
    Wheel { notches: i32, x: i32, y: i32 },
    /// its close button: it is asked to go
    Close,
    /// its size now: draw all of it again, then show it
    Resized { width: u32, height: u32 },
    /// the look changed (Look::get): draw again
    Look,
    /// it has the keys now, or not
    Focus(bool),
    /// the window is gone (the desktop let it go)
    Gone,
}

/// A window's pixels, to draw in.
pub struct Frame<'a> {
    pub pixels: &'a mut [u32],
    pub width: u32,
    pub height: u32,
    /// u32s a row
    pub stride: usize,
}

impl Frame<'_> {
    /// Row y's pixels, `width` of them.
    pub fn row(&mut self, y: u32) -> &mut [u32] {
        let s = y as usize * self.stride;
        &mut self.pixels[s..s + self.width as usize]
    }

    pub fn fill(&mut self, color: u32) {
        for y in 0..self.height {
            self.row(y).fill(color);
        }
    }

    /// A rectangle, clipped to the frame.
    pub fn fill_rect(&mut self, x: i32, y: i32, w: i32, h: i32, color: u32) {
        let x0 = x.max(0) as u32;
        let y0 = y.max(0) as u32;
        let x1 = ((x + w).max(0) as u32).min(self.width);
        let y1 = ((y + h).max(0) as u32).min(self.height);
        for yy in y0..y1 {
            if x0 < x1 {
                self.row(yy)[x0 as usize..x1 as usize].fill(color);
            }
        }
    }
}

pub struct Window {
    win: Handle,
    end: Handle,
    mem: Handle,
    px: *mut u32,
    stride: usize,
    rows: usize,
    width: u32,
    height: u32,
    gone: bool,
}

unsafe impl Send for Window {}

impl Window {
    /// SYS_WINDOW_NEW's flags (WNF_*).
    pub const RESIZE: u32 = 1;
    pub const FULL: u32 = 2;

    /// A window `width` by `height` pixels (no larger than the screen), with
    /// Window::RESIZE (the user may resize it) or Window::FULL (no frame,
    /// the whole screen), or 0. Shown once drawn and shown.
    pub fn open(width: u32, height: u32, flags: u32) -> Result<Window> {
        let desk = rt::desk_handle();
        if desk == 0 {
            return Err(Error::ABSENT);
        }
        let look = Look::get()?;
        let (sw, sh) = look.screen();
        let (w, h) = if flags & Window::FULL != 0 {
            (sw, sh)
        } else {
            (width.clamp(1, sw.max(1)), height.clamp(1, sh.max(1)))
        };
        let (theirs, ours) = unsafe { syscall(SYS_CHANNEL_NEW, 0, 0, 0, 0, 0) };
        let theirs = check(theirs)? as Handle;
        let ours = ours as Handle;
        let (win, mem) = unsafe {
            syscall(SYS_WINDOW_NEW, desk as u64, w as u64, h as u64, theirs as u64, flags as u64)
        };
        let win = match check(win) {
            Ok(win) => win as Handle,
            Err(e) => {
                ring::close(ours);
                return Err(e);
            }
        };
        let mem = mem as Handle;
        let (va, _) = unsafe { syscall(SYS_MAP, mem as u64, 0, 0, 0, 0) };
        let px = match check(va) {
            Ok(va) => va as *mut u32,
            Err(e) => {
                ring::close(win);
                ring::close(ours);
                ring::close(mem);
                return Err(e);
            }
        };
        let any = flags & (Window::RESIZE | Window::FULL) != 0;
        Ok(Window {
            win,
            end: ours,
            mem,
            px,
            stride: if any { sw as usize } else { w as usize },
            rows: if any { sh as usize } else { h as usize },
            width: w,
            height: h,
            gone: false,
        })
    }

    /// Its size now, pixels.
    pub fn size(&self) -> (u32, u32) {
        (self.width, self.height)
    }

    /// u32s a row of its pixels.
    pub fn stride(&self) -> usize {
        self.stride
    }

    /// All its pixels: `stride` a row, room for as many rows as it can have.
    pub fn pixels(&mut self) -> &mut [u32] {
        unsafe { core::slice::from_raw_parts_mut(self.px, self.stride * self.rows) }
    }

    /// Its pixels, at its size now.
    pub fn frame(&mut self) -> Frame<'_> {
        let (width, height, stride) = (self.width, self.height, self.stride);
        Frame { pixels: self.pixels(), width, height, stride }
    }

    /// What was drawn, all of it, onto the screen.
    pub fn show(&self) {
        self.show_rect(0, 0, 0, 0);
    }

    /// What was drawn in a part of it (w or h 0: all of it).
    pub fn show_rect(&self, x: u32, y: u32, w: u32, h: u32) {
        let mut e = Entry::new(RO_WIN_SHOW, self.win);
        e.a0 = x as u64;
        e.a1 = y as u64;
        e.a2 = w as u64 | (h as u64) << 32;
        let _ = ring::call(&e);
    }

    /// Its title, UTF-8 (255 bytes at most).
    pub fn set_title(&self, title: &str) {
        let mut n = title.len().min(255);
        while !title.is_char_boundary(n) {
            n -= 1;
        }
        let mut r = ring::lock();
        let Ok(io) = r.io_with(&title.as_bytes()[..n]) else { return };
        let mut e = Entry::new(RO_WIN_TITLE, self.win);
        e.handle2 = io;
        e.a1 = n as u64;
        let _ = r.call(&e);
    }

    /// The next thing that happened, if one did (it does not wait).
    pub fn poll(&mut self) -> Option<Event> {
        loop {
            if self.gone {
                return Some(Event::Gone);
            }
            let mut msg = [0u8; WE_SIZE];
            let got = {
                let mut r = ring::lock();
                let (p, io) = r.io(WE_SIZE).ok()?;
                let mut e = Entry::new(RO_RECV, self.end);
                e.handle2 = io;
                e.a1 = WE_SIZE as u64;
                let got = r.call(&e);
                if got.is_ok() {
                    unsafe { core::ptr::copy_nonoverlapping(p, msg.as_mut_ptr(), WE_SIZE) };
                }
                got
            };
            match got {
                Ok(_) => match self.take(&msg) {
                    Some(ev) => return Some(ev),
                    None => continue,
                },
                Err(Error::EMPTY) => return None,
                Err(_) => {
                    self.gone = true;
                }
            }
        }
    }

    /// The next thing that happens, waited for until `deadline` (None:
    /// for as long as it takes) -> None at the deadline.
    ///
    /// The program's ring is held while it waits: v1 programs are single
    /// threaded.
    pub fn wait(&mut self, deadline: Option<Instant>) -> Option<Event> {
        loop {
            if let Some(ev) = self.poll() {
                return Some(ev);
            }
            if let Some(t) = deadline {
                if Instant::now() >= t {
                    return None;
                }
            }
            let mut msg = [0u8; WE_SIZE];
            let (rw, rr) = {
                let mut r = ring::lock();
                let (p, io) = r.io(WE_SIZE).ok()?;
                let mut w = Entry::new(RO_WAIT, self.end);
                w.deadline = deadline.map_or(0, |t| t.tsc().max(1));
                let mut e = Entry::new(RO_RECV, self.end);
                e.handle2 = io;
                e.a1 = WE_SIZE as u64;
                let got = r.call_linked(&w, &e);
                if got.1 >= 0 {
                    unsafe { core::ptr::copy_nonoverlapping(p, msg.as_mut_ptr(), WE_SIZE) };
                }
                got
            };
            if rr >= 0 {
                if let Some(ev) = self.take(&msg) {
                    return Some(ev);
                }
                continue;
            }
            let (rw, rr) = (Error(rw as i32), Error(rr as i32));
            if rw == Error::TIMEOUT || rr == Error::TIMEOUT {
                return None;
            }
            if rr == Error::EMPTY || (rr == Error::CANCELED && rw == Error::CANCELED) {
                continue;
            }
            self.gone = true;
        }
    }

    /// A message, as an event; None for one to skip.
    fn take(&mut self, m: &[u8; WE_SIZE]) -> Option<Event> {
        let at = |o: usize| u32::from_le_bytes([m[o], m[o + 1], m[o + 2], m[o + 3]]);
        let (kind, code, x, y) = (at(0), at(4), at(8) as i32, at(12) as i32);
        Some(match kind {
            WE_KEY => {
                let mods = Mods(x as u32);
                if code == 27 && mods.alt() {
                    return None; // alt's escape, before its key
                }
                Event::Key { key: Key::from_code(code, mods), mods, code }
            }
            WE_PRESS => Event::Press { button: Button::from_code(code), x, y },
            WE_RELEASE => Event::Release { button: Button::from_code(code), x, y },
            WE_MOVE => Event::Move { x, y },
            WE_WHEEL => Event::Wheel { notches: code as i32, x, y },
            WE_CLOSE => Event::Close,
            WE_RESIZED => {
                self.width = (x.max(1) as u32).min(self.stride as u32);
                self.height = (y.max(1) as u32).min(self.rows as u32);
                Event::Resized { width: self.width, height: self.height }
            }
            WE_LOOK => Event::Look,
            WE_FOCUS => Event::Focus(code != 0),
            _ => return None,
        })
    }
}

impl Drop for Window {
    fn drop(&mut self) {
        ring::close(self.win);
        ring::close(self.end);
        unsafe { crate::mem::block_free(self.mem) };
    }
}
