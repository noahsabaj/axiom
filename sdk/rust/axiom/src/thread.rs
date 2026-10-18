//! Threads: each a stack and a thread-local block of its own, in one piece
//! of the heap, started by SYS_THREAD_NEW. Each has a slot here; its word
//! says which thread had the slot (a generation) and whether it has ended,
//! so a join waits on that word (a futex) and nothing else. A thread that
//! ends says so last, touching no memory after: whoever comes next (a join,
//! or the next spawn, for those no one joins) gives back its stack, its
//! ring and its handle.
//!
//!   let t = axiom::thread::spawn(work, arg, 1 << 20)?;  // extern "C" fn(usize)
//!   t.join();

use core::alloc::{GlobalAlloc, Layout};
use core::cell::UnsafeCell;
use core::sync::atomic::{AtomicU32, Ordering};

use crate::heap::SYSTEM;
use crate::sync::SpinLock;
use crate::sys::*;
use crate::{ring, tls};

const SLOTS: usize = 512;
const SLOT_BITS: u32 = 9;
const GEN_MASK: u32 = (1 << (32 - SLOT_BITS)) - 1;
const FREE: u32 = 0;
const RUNNING: u32 = 1;
const ENDED: u32 = 2;
const MIN_STACK: usize = 64 << 10;

#[repr(C)]
struct Slot {
    word: AtomicU32, // generation << 2 | FREE, RUNNING or ENDED (first: thread_entry's)
    inner: UnsafeCell<Inner>,
}

struct Inner {
    era: u32,
    func: Option<extern "C" fn(usize)>,
    arg: usize,
    block: *mut u8,
    size: usize, // its stack and its thread-local block (aligned to pages)
    tp: usize,
    handle: Handle,
    made: [Handle; 3], // its ring, handed over as it ended
}

unsafe impl Sync for Slot {}

#[allow(clippy::declare_interior_mutable_const)]
const EMPTY: Slot = Slot {
    word: AtomicU32::new(FREE),
    inner: UnsafeCell::new(Inner {
        era: 0,
        func: None,
        arg: 0,
        block: core::ptr::null_mut(),
        size: 0,
        tp: 0,
        handle: 0,
        made: [0; 3],
    }),
};

static TABLE: [Slot; SLOTS] = [EMPTY; SLOTS];
static LOCK: SpinLock<()> = SpinLock::new(()); // slots taken and given back

/// A thread started by spawn: its id (never 0).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Thread(pub u32);

/// `func(arg)` on a thread of its own, with a stack of `stack` bytes (64
/// KiB at least).
pub fn spawn(func: extern "C" fn(usize), arg: usize, stack: usize) -> Result<Thread> {
    let stack = stack.max(MIN_STACK).next_multiple_of(4096);
    let layout = Layout::from_size_align(stack + tls::size(), 4096).map_err(|_| Error::ARG)?;
    let _held = LOCK.lock();
    reap_ended();
    let Some(i) = TABLE.iter().position(|s| s.word.load(Ordering::Acquire) & 3 == FREE) else {
        return Err(Error::FULL);
    };
    let slot = &TABLE[i];
    let block = unsafe { SYSTEM.alloc(layout) };
    if block.is_null() {
        return Err(Error::NOMEM);
    }
    let inner = unsafe { &mut *slot.inner.get() };
    inner.era = (inner.era % GEN_MASK) + 1; // 1 ..= GEN_MASK: never a 0 id
    inner.func = Some(func);
    inner.arg = arg;
    inner.block = block;
    inner.size = layout.size();
    inner.tp = unsafe { tls::make(block.add(stack)) }; // above its stack
    inner.made = [0; 3];
    slot.word.store(inner.era << 2 | RUNNING, Ordering::Release);
    let top = block as u64 + stack as u64; // (16-aligned)
    let (h, _) = unsafe {
        syscall(SYS_THREAD_NEW, thread_entry as *const () as u64, top, slot as *const Slot as u64, 0, 0)
    };
    if h < 0 {
        unsafe { SYSTEM.dealloc(block, layout) };
        slot.word.store(inner.era << 2 | FREE, Ordering::Release);
        return Err(Error(h as i32));
    }
    inner.handle = h as Handle; // (before any reap: they wait for LOCK)
    Ok(Thread(inner.era << SLOT_BITS | i as u32))
}

impl Thread {
    /// Waits for it to end, and gives back what it had. Ok at once if it
    /// ended and was given back already.
    pub fn join(self) {
        let i = (self.0 & ((1 << SLOT_BITS) - 1)) as usize;
        let era = self.0 >> SLOT_BITS;
        let Some(slot) = TABLE.get(i) else { return };
        loop {
            let w = slot.word.load(Ordering::Acquire);
            if w >> 2 != era || w & 3 == FREE {
                return; // given back already
            }
            if w & 3 == ENDED {
                break;
            }
            let _ = futex_wait(&slot.word, w, 0);
        }
        let _held = LOCK.lock();
        if slot.word.load(Ordering::Acquire) == era << 2 | ENDED {
            give_back(slot);
        }
    }
}

/// Every slot whose thread ended (and no one joined yet) given back.
fn reap_ended() {
    for slot in TABLE.iter() {
        if slot.word.load(Ordering::Acquire) & 3 == ENDED {
            give_back(slot);
        }
    }
}

/// A slot whose thread ended, given back (LOCK held).
fn give_back(slot: &Slot) {
    let inner = unsafe { &mut *slot.inner.get() };
    let layout = unsafe { Layout::from_size_align_unchecked(inner.size, 4096) };
    unsafe { SYSTEM.dealloc(inner.block, layout) }; // (it touches it no more)
    ring::release(inner.made);
    ring::close(inner.handle);
    inner.block = core::ptr::null_mut();
    inner.handle = 0;
    inner.func = None;
    slot.word.store(inner.era << 2 | FREE, Ordering::Release);
    futex_wake(&slot.word, u32::MAX);
}

/// A new thread's first instructions, RDI = its slot: its thread-local
/// block set, its function run; then its word says it ended, those waiting
/// for that are woken, and it ends, all without its stack.
#[unsafe(naked)]
unsafe extern "C" fn thread_entry() -> ! {
    core::arch::naked_asm!(
        "mov rbx, rdi",
        "call {main}",
        "mov dword ptr [rbx], eax",     // the slot's word: ended
        "mov rdi, rbx",
        "mov esi, 0x7fffffff",
        "mov eax, {wake}",
        "syscall",
        "xor edi, edi",
        "xor esi, esi",
        "xor eax, eax",                 // SYS_EXIT: this thread
        "syscall",
        "ud2",
        main = sym thread_main,
        wake = const SYS_FUTEX_WAKE,
    )
}

/// -> the word it ends with.
extern "C" fn thread_main(slot: &Slot) -> u32 {
    let inner = unsafe { &mut *slot.inner.get() };
    tls::set(inner.tp);
    if let Some(f) = inner.func {
        f(inner.arg);
    }
    inner.made = ring::take();
    inner.era << 2 | ENDED
}
