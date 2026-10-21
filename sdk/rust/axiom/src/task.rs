//! Programs started by this one (SYS_SPAWN). Each is a task of its own and
//! a child of this one: it ends when this one does, and Child::kill ends
//! it and what it started. It is given up to two of our handles (they move
//! to it), and nothing else: not the files, the network or the desktop
//! unless given. What it writes to its console goes where ours does, or,
//! with `out`, to a channel of ours: a message each write, from it and from
//! what it starts, waiting while QUEUE_MAX are unread; our end hears PEER
//! once they have all ended.

use crate::chan::End;
use crate::ring;
use crate::sys::*;
use crate::time::Instant;

/// "program arguments" at most, bytes.
pub const TEXT_MAX: usize = 255;

/// A program started: its task and its first thread.
#[derive(Debug)]
pub struct Child {
    task: Handle,
    thread: Handle,
}

/// `text`, "program arguments" (a program's name, as the shell's `run`
/// takes it, or a path to its .AXE on the volume Axiom started from), run,
/// given `gifts` (0 for none), its console to `out` (the end the program
/// writes to; ours is the other) if given.
pub fn spawn(text: &str, gifts: [Handle; 2], out: Option<&End>) -> Result<Child> {
    if text.is_empty() || text.len() > TEXT_MAX || text.as_bytes().contains(&0) {
        return Err(Error::ARG);
    }
    let out = out.map_or(0, |e| e.handle() as u64);
    let mut r = ring::lock();
    let io = r.io_with(text.as_bytes())?;
    let (task, thread) = unsafe {
        syscall(SYS_SPAWN, io as u64, 0, text.len() as u64 | out << 32, gifts[0] as u64, gifts[1] as u64)
    };
    let task = check(task)? as Handle;
    Ok(Child { task, thread: thread as Handle })
}

impl Child {
    /// Until its first thread ends -> what it returned (the program's exit
    /// code); TIMEOUT at `until`.
    pub fn join(&self, until: Option<Instant>) -> Result<i64> {
        let mut e = Entry::new(RO_JOIN, self.thread);
        e.deadline = until.map_or(0, |t| t.tsc().max(1));
        ring::call(&e).map(|v| v.1 as i64)
    }

    /// It ends now, and so does whatever it started.
    pub fn kill(&self) -> Result<()> {
        ring::call(&Entry::new(RO_KILL, self.task)).map(|_| ())
    }

    pub fn task(&self) -> Handle {
        self.task
    }

    pub fn thread(&self) -> Handle {
        self.thread
    }
}

impl Drop for Child {
    /// Our handles go; it runs on.
    fn drop(&mut self) {
        ring::close(self.thread);
        ring::close(self.task);
    }
}
