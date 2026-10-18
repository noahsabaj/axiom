//! Sound, for a program given the speakers (wants::SOUND, or +sound).
//!
//!   let mut s = Stream::open(4096)?;           // a ring of 4096 frames
//!   loop {
//!       let n = s.room();                      // frames that fit now
//!       s.write(&frames[..n]);                 // [left, right] each
//!       s.wait(None)?;                         // until half the ring is free
//!   }
//!
//! A stream is 48 kHz, 16-bit signed, stereo: [`RATE`] frames a second, each
//! a [`Frame`]. Its ring is memory the program and the kernel share: the
//! program writes frames and says how many in all (SN_WRITE); the kernel's
//! mixer takes them as they play (SN_READ), sums every stream open, each by
//! its own gain, then all by the volume the user set. A stream that runs
//! dry plays silence until more come, and counts the frames it had none for
//! (`short`). The sound reaches the speakers about 40 ms after the mixer
//! takes it. Dropping the stream ends it, played or not.

use core::sync::atomic::{AtomicU32, Ordering};

use crate::mem::Block;
use crate::ring;
use crate::rt;
use crate::sys::*;
use crate::time::Instant;

/// Frames a second.
pub const RATE: u32 = 48000;

/// A left and a right sample.
pub type Frame = [i16; 2];

/// A stream's gain as written: `Stream::set_gain`.
pub const UNITY: u32 = 65536;

// a stream's memory (SN_*)
const SN_WRITE: usize = 0;
const SN_READ: usize = 4;
const SN_FRAMES: usize = 8;
const SN_LOW: usize = 20;
const SN_GAIN: usize = 24;
const SN_SHORT: usize = 28;
const SN_DATA: usize = 64;

/// A stream of sound, playing.
pub struct Stream {
    handle: Handle,
    mem: Block,
    frames: u32,
    low: u32,
}

unsafe impl Send for Stream {}

impl Stream {
    /// A stream with room for `frames` (a power of two from 1024 to 65536;
    /// others are rounded up to one, within those): what it plays, it plays
    /// from there.
    pub fn open(frames: u32) -> Result<Stream> {
        let speakers = rt::sound_handle();
        if speakers == 0 {
            return Err(Error::ABSENT);
        }
        let (h, m) = unsafe { syscall(SYS_SOUND_NEW, speakers as u64, frames as u64, 0, 0, 0) };
        let handle = check(h)? as Handle;
        let room = frames.clamp(1024, 65536).next_power_of_two() as usize; // as the kernel makes it
        let mem = match Block::map(m as Handle, SN_DATA + room * 4) {
            Ok(b) => b,
            Err(e) => {
                ring::close(m as Handle);
                ring::close(handle);
                return Err(e);
            }
        };
        let mut s = Stream { handle, mem, frames: 0, low: 0 };
        s.frames = s.at(SN_FRAMES).load(Ordering::Relaxed);
        s.low = s.at(SN_LOW).load(Ordering::Relaxed);
        Ok(s)
    }

    fn at(&self, off: usize) -> &AtomicU32 {
        unsafe { &*(self.mem.as_ptr().add(off) as *const AtomicU32) }
    }

    pub fn handle(&self) -> Handle {
        self.handle
    }

    /// Its ring's frames.
    pub fn frames(&self) -> u32 {
        self.frames
    }

    /// Frames written and not yet taken to play.
    pub fn queued(&self) -> u32 {
        let w = self.at(SN_WRITE).load(Ordering::Relaxed);
        let r = self.at(SN_READ).load(Ordering::Acquire);
        w.wrapping_sub(r).min(self.frames)
    }

    /// Frames that can be written now.
    pub fn room(&self) -> usize {
        (self.frames - self.queued()) as usize
    }

    /// Frames played (taken by the mixer), in all.
    pub fn played(&self) -> u32 {
        self.at(SN_READ).load(Ordering::Acquire)
    }

    /// Frames it had none for since it began: the program was late.
    pub fn short(&self) -> u32 {
        self.at(SN_SHORT).load(Ordering::Relaxed)
    }

    /// As many of `frames` as there is room for, queued -> how many.
    pub fn write(&mut self, frames: &[Frame]) -> usize {
        let n = frames.len().min(self.room());
        let w = self.at(SN_WRITE).load(Ordering::Relaxed);
        let mask = self.frames - 1;
        let data = unsafe { self.mem.as_ptr().add(SN_DATA) as *mut Frame };
        for (i, f) in frames[..n].iter().enumerate() {
            let at = (w.wrapping_add(i as u32) & mask) as usize;
            unsafe { data.add(at).write_volatile(*f) };
        }
        self.at(SN_WRITE).store(w.wrapping_add(n as u32), Ordering::Release);
        n
    }

    /// Room for up to `n` frames, filled by `f` (given each frame's index
    /// from 0) -> how many.
    pub fn write_with(&mut self, n: usize, mut f: impl FnMut(usize) -> Frame) -> usize {
        let n = n.min(self.room());
        let w = self.at(SN_WRITE).load(Ordering::Relaxed);
        let mask = self.frames - 1;
        let data = unsafe { self.mem.as_ptr().add(SN_DATA) as *mut Frame };
        for i in 0..n {
            let at = (w.wrapping_add(i as u32) & mask) as usize;
            unsafe { data.add(at).write_volatile(f(i)) };
        }
        self.at(SN_WRITE).store(w.wrapping_add(n as u32), Ordering::Release);
        n
    }

    /// Its own volume: UNITY as written (at most), 0 silent.
    pub fn set_gain(&mut self, gain: u32) {
        self.at(SN_GAIN).store(gain.min(UNITY), Ordering::Relaxed);
    }

    /// `wait` returns once no more than this many frames are queued (half
    /// the ring, to begin with).
    pub fn set_low(&mut self, frames: u32) {
        self.low = frames.min(self.frames);
        self.at(SN_LOW).store(self.low, Ordering::Relaxed);
    }

    /// Until no more than the low mark is queued (RO_WAIT), or the deadline
    /// (Error::TIMEOUT).
    pub fn wait(&mut self, deadline: Option<Instant>) -> Result<()> {
        let mut e = Entry::new(RO_WAIT, self.handle);
        e.deadline = deadline.map_or(0, |t| t.tsc().max(1));
        ring::call(&e).map(|_| ())
    }

    /// Until every frame written is taken to play, or the deadline.
    pub fn drain(&mut self, deadline: Option<Instant>) -> Result<()> {
        let low = self.low;
        self.at(SN_LOW).store(0, Ordering::Relaxed);
        let mut got = Ok(());
        while self.queued() > 0 {
            got = self.wait(deadline);
            if got.is_err() {
                break;
            }
        }
        self.at(SN_LOW).store(low, Ordering::Relaxed);
        got
    }
}

impl Drop for Stream {
    fn drop(&mut self) {
        ring::close(self.handle);
    }
}
