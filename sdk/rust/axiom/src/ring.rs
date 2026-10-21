//! A thread's ring: requests submitted at its tail, their completions
//! reaped at its head, one at a time (or a linked pair) under a lock. The
//! first thread has the task's (the start block's); each other thread makes
//! its own the first time it asks for something, so one thread waiting
//! keeps no other from asking. And a block of memory to hand the kernel
//! bytes in (paths, titles, text), since it reads them from memory by handle.

use core::ptr;
use core::sync::atomic::{AtomicU32, Ordering};

use crate::sync::{Guard, SpinLock};
use crate::sys::*;

/// A thread's ring, its own (made when first asked for).
const THREAD_RING: u64 = 16;
/// State::first's: each with its cancel fits in a thread's ring.
pub const FIRST_MAX: usize = 7;

pub struct State {
    ring: Handle,
    mem: Handle, // the ring's memory: 0 for the task's, which stays
    va: *mut u8,
    io: Handle,
    io_ptr: *mut u8,
    io_cap: usize,
}

unsafe impl Send for State {}

#[thread_local]
static RING: SpinLock<State> = SpinLock::new(State {
    ring: 0,
    mem: 0,
    va: ptr::null_mut(),
    io: 0,
    io_ptr: ptr::null_mut(),
    io_cap: 0,
});

fn mine() -> &'static SpinLock<State> {
    unsafe { &*ptr::addr_of!(RING) } // (only this thread holds it)
}

/// The first thread's: the task's ring, from the start block.
pub(crate) fn init(ring: Handle, va: *mut u8) {
    let mut s = mine().lock();
    s.ring = ring;
    s.va = va;
}

/// This thread's ring, for a request or two. Nothing that allocates may
/// run while it is held (the heap takes it, to give memory back).
pub fn lock() -> Guard<'static, State> {
    let mut s = mine().lock();
    if s.ring == 0 {
        s.open();
    }
    s
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

/// What a thread that is ending made (its ring, its io block), for another
/// to give back (`release`): it asks nothing more after.
pub(crate) fn take() -> [Handle; 3] {
    let mut s = mine().lock();
    let made = [s.ring, s.mem, s.io];
    if s.mem == 0 {
        return [0; 3]; // the task's: never given back
    }
    s.ring = 0;
    s.mem = 0;
    s.va = ptr::null_mut();
    s.io = 0;
    s.io_ptr = ptr::null_mut();
    s.io_cap = 0;
    made
}

/// An ended thread's ring and io block given back.
pub(crate) fn release(made: [Handle; 3]) {
    let [ring, mem, io] = made;
    for m in [mem, io] {
        if m != 0 {
            unsafe { syscall(SYS_UNMAP, m as u64, 0, 0, 0, 0) };
            close(m);
        }
    }
    close(ring);
}

unsafe fn u32_at(va: *mut u8, off: usize) -> &'static AtomicU32 {
    unsafe { &*(va.add(off) as *const AtomicU32) }
}

impl State {
    fn open(&mut self) {
        let (ring, mem) = unsafe { syscall(SYS_RING_NEW, THREAD_RING, 0, 0, 0, 0) };
        if ring < 0 {
            exit(ring); // (no ring to say it with)
        }
        let (va, _) = unsafe { syscall(SYS_MAP, mem, 0, 0, 0, 0) };
        if va < 0 {
            exit(va);
        }
        self.ring = ring as Handle;
        self.mem = mem as Handle;
        self.va = va as *mut u8;
    }

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

    /// Requests that wait (RO_WAIT...), FIRST_MAX at most, submitted
    /// together; once one completes the others are canceled -> which
    /// completed first, and its result.
    pub fn first(&mut self, es: &[Entry]) -> (usize, i64) {
        const MARK: u64 = 0xF125_7000;
        let n = es.len().min(FIRST_MAX) as u32;
        if n == 0 {
            return (0, Error::ARG.0 as i64);
        }
        for (i, e) in es[..n as usize].iter().enumerate() {
            let mut e = *e;
            e.flags &= !SQF_LINK;
            e.data = MARK + i as u64;
            self.submit(&e);
        }
        self.enter(n, 1);
        let won = loop {
            let c = self.reap_wait();
            if c.data >= MARK && c.data < MARK + n as u64 {
                break c;
            }
        };
        for i in 0..n as u64 {
            if MARK + i != won.data {
                let mut c = Entry::new(RO_CANCEL, 0);
                c.a0 = MARK + i;
                self.submit(&c);
            }
        }
        self.enter(n - 1, 0);
        for _ in 0..2 * (n - 1) {
            self.reap_wait(); // each other one's end (canceled, or done), and each cancel's
        }
        ((won.data - MARK) as usize, won.result)
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
