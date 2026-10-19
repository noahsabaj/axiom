//! Channels (channel.asm): two ends, each a handle; what is sent from one
//! waits at the other, oldest first, a message of up to MSG_MAX bytes each,
//! QUEUE_MAX of them at most. When either end's last handle goes, the
//! other's sends say Error::PEER, and so do its receives once what was
//! sent before is read.

use crate::ring;
use crate::sys::*;
use crate::time::Instant;

/// Bytes in a message, at most.
pub const MSG_MAX: usize = 4096;
/// Messages waiting at an end, at most: then sends say FULL.
pub const QUEUE_MAX: usize = 64;

/// One end of a channel. Closed when dropped.
#[derive(Debug)]
pub struct End {
    h: Handle,
}

/// A new channel -> its two ends.
pub fn pair() -> Result<(End, End)> {
    let (a, b) = unsafe { syscall(SYS_CHANNEL_NEW, 0, 0, 0, 0, 0) };
    let a = check(a)? as Handle;
    Ok((End { h: a }, End { h: b as Handle }))
}

impl End {
    pub const fn from_handle(h: Handle) -> End {
        End { h }
    }

    pub fn handle(&self) -> Handle {
        self.h
    }

    /// Its handle, no longer closed when this goes (to give it away).
    pub fn into_handle(self) -> Handle {
        let h = self.h;
        core::mem::forget(self);
        h
    }

    /// `msg` as one message -> its bytes; FULL if QUEUE_MAX wait already,
    /// PEER once the other end is gone.
    pub fn send(&self, msg: &[u8]) -> Result<usize> {
        if msg.len() > MSG_MAX {
            return Err(Error::ARG);
        }
        let mut r = ring::lock();
        let io = r.io_with(msg)?;
        let mut e = Entry::new(RO_SEND, self.h);
        e.handle2 = io;
        e.a1 = msg.len() as u64;
        r.call(&e).map(|v| v.0 as usize)
    }

    /// The next message into `buf` -> its bytes; EMPTY if none waits,
    /// RANGE (and it stays) if it does not fit, PEER at the end.
    pub fn recv(&self, buf: &mut [u8]) -> Result<usize> {
        let n = buf.len().min(MSG_MAX);
        let mut r = ring::lock();
        let (p, io) = r.io(n.max(1))?;
        let mut e = Entry::new(RO_RECV, self.h);
        e.handle2 = io;
        e.a1 = n as u64;
        let got = (r.call(&e)?.0 as usize).min(n);
        unsafe { core::ptr::copy_nonoverlapping(p, buf.as_mut_ptr(), got) };
        Ok(got)
    }

    /// Until a message waits here or the other end has gone; or until
    /// `until`: TIMEOUT.
    pub fn wait(&self, until: Option<Instant>) -> Result<()> {
        let mut e = Entry::new(RO_WAIT, self.h);
        e.deadline = until.map_or(0, |t| t.tsc().max(1));
        ring::call(&e).map(|_| ())
    }
}

impl Drop for End {
    fn drop(&mut self) {
        ring::close(self.h);
    }
}
