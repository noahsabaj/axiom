//! What std calls, built for this target: its zkvm layer (library/std's
//! sys/pal/zkvm) leaves these to the platform, as extern "C" functions. So
//! println! and eprintln! reach the console, std::env::args() has the
//! arguments, and the hash maps' seeds are random. std's own allocator
//! (System) is a heap here too, but a program says #[global_allocator] for
//! its own (axiom::Heap): System is then left for what asks for it by name.

use core::alloc::{GlobalAlloc, Layout};

use crate::{console, heap::Heap, rt, sys};

static SYSTEM: Heap = Heap::new();

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_alloc_aligned(bytes: usize, align: usize) -> *mut u8 {
    match Layout::from_size_align(bytes.max(1), align.max(1)) {
        Ok(l) => unsafe { SYSTEM.alloc(l) },
        Err(_) => core::ptr::null_mut(),
    }
}

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_alloc_words(words: usize) -> *mut u32 {
    unsafe { sys_alloc_aligned(words * 4, 4) as *mut u32 }
}

/// stdout, stderr (and risc0's journal): the console.
#[unsafe(no_mangle)]
unsafe extern "C" fn sys_write(_fd: u32, buf: *const u8, bytes: usize) {
    if bytes > 0 {
        console::write(unsafe { core::slice::from_raw_parts(buf, bytes) });
    }
}

/// A panic's message (panic_abort's, on the way out): said, and the
/// program ended.
#[unsafe(no_mangle)]
unsafe extern "C" fn sys_panic(msg: *const u8, bytes: usize) -> ! {
    console::write(unsafe { core::slice::from_raw_parts(msg, bytes) });
    console::write(b"\n");
    sys::exit(101)
}

/// stdin: nothing, yet.
#[unsafe(no_mangle)]
unsafe extern "C" fn sys_read(_fd: u32, _buf: *mut u8, _bytes: usize) -> usize {
    0
}

/// argv[0] is "axe" (the start block has what follows the program's name).
fn arg(i: usize) -> Option<&'static str> {
    if i == 0 { Some("axe") } else { rt::args().nth(i - 1) }
}

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_argc() -> usize {
    1 + rt::args().count()
}

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_argv(out: *mut u32, words: usize, i: usize) -> usize {
    let a = arg(i).unwrap_or("");
    let n = a.len().min(words * 4);
    if n > 0 {
        unsafe { core::ptr::copy_nonoverlapping(a.as_ptr(), out as *mut u8, n) };
    }
    a.len()
}

/// No environment: no variable is set.
#[unsafe(no_mangle)]
unsafe extern "C" fn sys_getenv(_out: *mut u32, _words: usize, _name: *const u8, _len: usize) -> usize {
    usize::MAX
}

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_rand(out: *mut u32, words: usize) {
    for i in 0..words {
        unsafe { out.add(i).write(random_u32()) };
    }
}

/// RDRAND where the CPU has it; else the TSC, stirred.
pub fn random_u32() -> u32 {
    use core::arch::x86_64::{__cpuid, _rdrand32_step};
    use core::sync::atomic::{AtomicU64, Ordering};
    static HAS: AtomicU64 = AtomicU64::new(2); // 2: not asked yet
    if HAS.load(Ordering::Relaxed) == 2 {
        let ecx = __cpuid(1).ecx;
        HAS.store((ecx >> 30) as u64 & 1, Ordering::Relaxed);
    }
    if HAS.load(Ordering::Relaxed) == 1 {
        #[target_feature(enable = "rdrand")]
        unsafe fn rd() -> Option<u32> {
            let mut v = 0;
            for _ in 0..10 {
                if _rdrand32_step(&mut v) == 1 {
                    return Some(v);
                }
            }
            None
        }
        if let Some(v) = unsafe { rd() } {
            return v;
        }
    }
    static STATE: AtomicU64 = AtomicU64::new(0x9E37_79B9_7F4A_7C15);
    let mut x = STATE.load(Ordering::Relaxed) ^ sys::rdtsc();
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    STATE.store(x, Ordering::Relaxed);
    (x >> 32) as u32
}
