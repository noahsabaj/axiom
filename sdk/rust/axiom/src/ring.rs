//! The task's ring: requests submitted at its tail, their completions reaped
//! at its head, one at a time (or a linked pair) under a lock. And a block
//! of memory to hand the kernel bytes in (paths, titles, text), since it
//! reads them from memory by handle.

use core::ptr;
use core::sync::atomic::{AtomicU32, Ordering};

use crate::sync::{Guard, SpinLock};
use crate::sys::*;

pub struct State {
    ring: Handle,
    va: *mut u8,
    io: Handle,
    io_ptr: *mut u8,
    io_cap: usize,
}

unsafe impl Send for State {}

static RING: SpinLock<State> = SpinLock::new(State {
    ring: 0,
    va: ptr::null_mut(),
    io: 0,
    io_ptr: ptr::null_mut(),
    io_cap: 0,
});

pub(crate) fn init(ring: Handle, va: *mut u8) {
    let mut s = RING.lock();
    s.ring = ring;
    s.va = va;
}

/// The ring, for a request or two. Nothing that allocates may run while it
/// is held (the heap takes it, to give memory back).
pub fn lock() -> Guard<'static, State> {
    RING.lock()
}

/// One request, waited for -> its result (and value).
pub fn call(e: &Entry) -> Result<(u64, u64)> {
    lock().call(e)
}

/// A handle closed.
pub fn close(h: Handle) {
    if h != 0 {
        let _ = call(&Entry::new(RO_CLOSE, h));
    }
}

unsafe fn u32_at(va: *mut u8, off: usize) -> &'static AtomicU32 {
    unsafe { &*(va.add(off) as *const AtomicU32) }
}

impl State {
    fn submit(&mut self, e: &Entry) {
        unsafe {
            let tail = u32_at(self.va, RA_SQ_TAIL).load(Ordering::Relaxed);
            let n = u32_at(self.va, RA_SQ_ENTRIES).load(Ordering::Relaxed);
            let off = u32_at(self.va, RA_SQ_OFF).load(Ordering::Relaxed) as usize;
            let slot = self.va.add(off + ((tail & (n - 1)) as usize) * 64) as *mut Entry;
            ptr::write_volatile(slot, *e);
            u32_at(self.va, RA_SQ_TAIL).store(tail.wrapping_add(1), Ordering::Release);
        }
    }

    fn reap(&mut self) -> Option<Completion> {
        unsafe {
            let head = u32_at(self.va, RA_CQ_HEAD).load(Ordering::Relaxed);
            if head == u32_at(self.va, RA_CQ_TAIL).load(Ordering::Acquire) {
                return None;
            }
            let n = u32_at(self.va, RA_CQ_ENTRIES).load(Ordering::Relaxed);
            let off = u32_at(self.va, RA_CQ_OFF).load(Ordering::Relaxed) as usize;
            let slot = self.va.add(off + ((head & (n - 1)) as usize) * 32) as *const Completion;
            let c = ptr::read_volatile(slot);
            u32_at(self.va, RA_CQ_HEAD).store(head.wrapping_add(1), Ordering::Release);
            Some(c)
        }
    }

    fn enter(&mut self, take: u32, wait: u32) {
        unsafe { syscall(SYS_RING_ENTER, self.ring as u64, take as u64, wait as u64, 0, 0) };
    }

    fn reap_wait(&mut self) -> Completion {
        loop {
            if let Some(c) = self.reap() {
                return c;
            }
            self.enter(0, 1);
        }
    }

    /// One request, waited for.
    pub fn call(&mut self, e: &Entry) -> Result<(u64, u64)> {
        self.submit(e);
        self.enter(1, 1);
        let c = self.reap_wait();
        check(c.result).map(|r| (r, c.value))
    }

    /// Two, the second linked to the first (SQF_LINK set here) -> their
    /// results, in order.
    pub fn call_linked(&mut self, a: &Entry, b: &Entry) -> (i64, i64) {
        let mut a = *a;
        a.flags |= SQF_LINK;
        a.data = 1;
        let mut b = *b;
        b.data = 2;
        self.submit(&a);
        self.submit(&b);
        self.enter(2, 2);
        let (mut ra, mut rb) = (0, 0);
        for _ in 0..2 {
            let c = self.reap_wait();
            if c.data == 1 { ra = c.result } else { rb = c.result }
        }
        (ra, rb)
    }

    /// The block bytes are handed over in, at least `len` long -> where it
    /// is mapped, and its handle.
    pub fn io(&mut self, len: usize) -> Result<(*mut u8, Handle)> {
        if len > self.io_cap || self.io == 0 {
            let cap = len.max(4096).next_multiple_of(4096);
            let (h, p) = crate::mem::block_new(cap)?;
            if self.io != 0 {
                let old = self.io;
                unsafe { syscall(SYS_UNMAP, old as u64, 0, 0, 0, 0) };
                let _ = self.call(&Entry::new(RO_CLOSE, old));
            }
            self.io = h;
            self.io_ptr = p;
            self.io_cap = cap;
        }
        Ok((self.io_ptr, self.io))
    }

    /// `bytes` copied into the io block -> its handle.
    pub fn io_with(&mut self, bytes: &[u8]) -> Result<Handle> {
        let (p, h) = self.io(bytes.len())?;
        unsafe { ptr::copy_nonoverlapping(bytes.as_ptr(), p, bytes.len()) };
        Ok(h)
    }
}
