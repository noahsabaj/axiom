//! A heap for Rust's allocations, over the kernel's blocks.
//!
//!   #[global_allocator]
//!   static HEAP: axiom::Heap = axiom::Heap::new();
//!
//! A program maps few blocks at once (128, the kernel's AS_MAX), so the heap
//! takes few: arenas of 1 MiB, then each twice the last, to 64 MiB (a block's
//! most), and hands out their pages. Pages free are kept as runs, in order,
//! joined when they touch.
//!
//! Up to 32 KiB, an allocation is a slot of one of 40 sizes (16 to 128 by
//! 16, then four to each doubling), carved from a 64 KiB span of slots its
//! size alone; what is freed goes on its size's list, for the next. Spans
//! are pages from an arena, aligned to 64 KiB, and stay. A slot whose size
//! is a power of two is aligned to it, so alignment past 16 is met by
//! rounding the size up to one. Past 32 KiB, an allocation is pages of its
//! own, given back when freed, and grown in place when the pages after it
//! are free.

use core::alloc::{GlobalAlloc, Layout};
use core::ptr;

use crate::mem;
use crate::sync::SpinLock;

const NCLASS: usize = 40;
const SMALL_MAX: usize = 32 << 10;
const SPAN: usize = 64 << 10;
const PAGE: usize = 4096;
const ARENA_FIRST: usize = 1 << 20;
const ARENA_MAX: usize = 64 << 20;
const RUNS: usize = 512;

#[derive(Clone, Copy)]
struct Run {
    start: usize,
    end: usize,
}

struct Inner {
    free: [*mut u8; NCLASS],
    span: [*mut u8; NCLASS],
    span_end: [*mut u8; NCLASS],
    runs: [Run; RUNS], // pages free, by address
    nruns: usize,
    arenas: u32, // made so far: the next is twice the last
}

unsafe impl Send for Inner {}

/// The crate's own: std's System, and threads' stacks.
pub(crate) static SYSTEM: Heap = Heap::new();

pub struct Heap {
    inner: SpinLock<Inner>,
}

impl Heap {
    pub const fn new() -> Heap {
        Heap {
            inner: SpinLock::new(Inner {
                free: [ptr::null_mut(); NCLASS],
                span: [ptr::null_mut(); NCLASS],
                span_end: [ptr::null_mut(); NCLASS],
                runs: [Run { start: 0, end: 0 }; RUNS],
                nruns: 0,
                arenas: 0, // (all zeroes: the heap is in the bss)
            }),
        }
    }
}

impl Default for Heap {
    fn default() -> Heap {
        Heap::new()
    }
}

/// The class a layout's slot is of, or None past SMALL_MAX.
fn class_of(layout: Layout) -> Option<usize> {
    let mut size = layout.size().max(1);
    if layout.align() > 16 {
        size = size.max(layout.align()).next_power_of_two();
    }
    if size > SMALL_MAX {
        return None;
    }
    if size <= 128 {
        return Some(size.div_ceil(16) - 1);
    }
    let p = (usize::BITS - 1 - (size - 1).leading_zeros()) as usize; // 2^p < size <= 2^(p+1)
    let step = 1usize << (p - 2);
    let sub = (size - (1 << p)).div_ceil(step); // 1..=4
    Some(8 + (p - 7) * 4 + sub - 1)
}

fn class_size(c: usize) -> usize {
    if c < 8 {
        return (c + 1) * 16;
    }
    let p = 7 + (c - 8) / 4;
    let sub = (c - 8) % 4 + 1;
    (1 << p) + sub * (1 << (p - 2))
}

/// A large allocation's pages.
fn pages(size: usize) -> usize {
    size.max(1).next_multiple_of(PAGE)
}

impl Inner {
    unsafe fn small(&mut self, c: usize) -> *mut u8 {
        let p = self.free[c];
        if !p.is_null() {
            self.free[c] = unsafe { *(p as *mut *mut u8) };
            return p;
        }
        let size = class_size(c);
        if self.span[c].is_null() || unsafe { self.span[c].add(size) } > self.span_end[c] {
            let s = self.take(SPAN, SPAN);
            if s.is_null() {
                return s;
            }
            self.span[c] = s;
            self.span_end[c] = unsafe { s.add(SPAN) };
        }
        let p = self.span[c];
        self.span[c] = unsafe { p.add(size) };
        p
    }

    /// `bytes` (whole pages) aligned to `align`, from the runs free; an arena
    /// more if none has room.
    fn take(&mut self, bytes: usize, align: usize) -> *mut u8 {
        loop {
            for i in 0..self.nruns {
                let r = self.runs[i];
                let a = r.start.next_multiple_of(align);
                if a + bytes > r.end {
                    continue;
                }
                // the run left before it, and after it
                let after = Run { start: a + bytes, end: r.end };
                if a > r.start {
                    self.runs[i].end = a;
                    if after.start < after.end {
                        self.insert_at(i + 1, after);
                    }
                } else if after.start < after.end {
                    self.runs[i] = after;
                } else {
                    self.remove_at(i);
                }
                return a as *mut u8;
            }
            if !self.arena(bytes + if align > PAGE { align } else { 0 }) {
                return ptr::null_mut();
            }
        }
    }

    fn arena(&mut self, least: usize) -> bool {
        let next = (ARENA_FIRST << self.arenas.min(6)).min(ARENA_MAX);
        let size = next.max(least.next_multiple_of(PAGE));
        if size > ARENA_MAX {
            return false;
        }
        let Ok((_, base)) = mem::block_new(size) else {
            return false;
        };
        self.arenas += 1;
        self.give(base as usize, size);
        true
    }

    /// Pages back among the runs, joined to those they touch.
    fn give(&mut self, start: usize, bytes: usize) {
        let end = start + bytes;
        let i = self.runs[..self.nruns].partition_point(|r| r.start < start);
        let joins_before = i > 0 && self.runs[i - 1].end == start;
        let joins_after = i < self.nruns && self.runs[i].start == end;
        match (joins_before, joins_after) {
            (true, true) => {
                self.runs[i - 1].end = self.runs[i].end;
                self.remove_at(i);
            }
            (true, false) => self.runs[i - 1].end = end,
            (false, true) => self.runs[i].start = start,
            (false, false) => self.insert_at(i, Run { start, end }),
        }
    }

    fn insert_at(&mut self, i: usize, r: Run) {
        if self.nruns == RUNS {
            return; // too scattered to keep: those pages stay out
        }
        self.runs.copy_within(i..self.nruns, i + 1);
        self.runs[i] = r;
        self.nruns += 1;
    }

    fn remove_at(&mut self, i: usize) {
        self.runs.copy_within(i + 1..self.nruns, i);
        self.nruns -= 1;
    }

    /// A large allocation at `p` grown in place to `to` bytes (whole pages),
    /// if the pages after it are free.
    fn grow(&mut self, p: usize, from: usize, to: usize) -> bool {
        let end = p + from;
        let i = self.runs[..self.nruns].partition_point(|r| r.start < end);
        if i == self.nruns || self.runs[i].start != end || self.runs[i].end < p + to {
            return false;
        }
        if self.runs[i].end == p + to {
            self.remove_at(i);
        } else {
            self.runs[i].start = p + to;
        }
        true
    }
}

unsafe impl GlobalAlloc for Heap {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let mut h = self.inner.lock();
        match class_of(layout) {
            Some(c) => unsafe { h.small(c) },
            None => h.take(pages(layout.size()), layout.align().max(PAGE)),
        }
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        let p = unsafe { self.alloc(layout) };
        if !p.is_null() {
            unsafe { ptr::write_bytes(p, 0, layout.size()) };
        }
        p
    }

    unsafe fn dealloc(&self, p: *mut u8, layout: Layout) {
        let mut h = self.inner.lock();
        match class_of(layout) {
            Some(c) => {
                unsafe { *(p as *mut *mut u8) = h.free[c] };
                h.free[c] = p;
            }
            None => h.give(p as usize, pages(layout.size())),
        }
    }

    unsafe fn realloc(&self, p: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        let Ok(new) = Layout::from_size_align(new_size, layout.align()) else {
            return ptr::null_mut();
        };
        match (class_of(layout), class_of(new)) {
            (Some(a), Some(b)) if a == b => return p,
            (None, None) => {
                let (from, to) = (pages(layout.size()), pages(new_size));
                let mut h = self.inner.lock();
                if to <= from {
                    if to < from {
                        h.give(p as usize + to, from - to);
                    }
                    return p;
                }
                if h.grow(p as usize, from, to) {
                    return p;
                }
            }
            _ => {}
        }
        let q = unsafe { self.alloc(new) };
        if !q.is_null() {
            unsafe {
                ptr::copy_nonoverlapping(p, q, layout.size().min(new_size));
                self.dealloc(p, layout);
            }
        }
        q
    }
}
