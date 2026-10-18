//! Thread-local storage: each thread a block of its own, made from the
//! program's template (.tdata, then .tbss's zeroes: axiom.ld), and its FS
//! base (SYS_TLS) the end of it. That is x86-64's layout for an executable
//! (variant II, the local-exec model the target asks for): the variables
//! below the thread pointer, at offsets the linker worked out, and at the
//! pointer a word holding itself.

use core::ptr;

use crate::sys::*;

unsafe extern "C" {
    static __axe_tls_start: u8;
    static __axe_tls_data_end: u8;
    static __axe_tls_end: u8;
    static __axe_tls_align: u8; // its address is the alignment
}

/// What follows the thread pointer: the pointer itself, and room.
const TCB: usize = 64;

struct Image {
    start: usize,
    data: usize, // bytes copied
    mem: usize,  // bytes in all, the zeroes after
    align: usize,
}

fn image() -> Image {
    let start = ptr::addr_of!(__axe_tls_start) as usize;
    let data = ptr::addr_of!(__axe_tls_data_end) as usize;
    let end = ptr::addr_of!(__axe_tls_end) as usize;
    let align = (ptr::addr_of!(__axe_tls_align) as usize).max(1);
    Image { start, data: data - start, mem: end.max(data) - start, align }
}

/// Bytes a thread's block takes, from wherever it starts.
pub fn size() -> usize {
    let i = image();
    i.mem.next_multiple_of(i.align) + i.align.max(16) + TCB
}

/// The block at `at` (size() bytes, any alignment) made a thread's: the
/// template copied in -> its thread pointer, for SYS_TLS.
///
/// # Safety
/// `at` must be size() bytes this thread may write, and stay while the
/// thread runs.
pub unsafe fn make(at: *mut u8) -> usize {
    let i = image();
    let below = i.mem.next_multiple_of(i.align); // as the linker has it
    let tp = (at as usize + below).next_multiple_of(i.align.max(16));
    let block = (tp - below) as *mut u8;
    unsafe {
        ptr::copy_nonoverlapping(i.start as *const u8, block, i.data);
        ptr::write_bytes(block.add(i.data), 0, below - i.data);
        ptr::write_bytes(tp as *mut u8, 0, TCB);
        (tp as *mut usize).write(tp);
    }
    tp
}

/// This thread's from now on.
pub fn set(tp: usize) {
    unsafe { syscall(SYS_TLS, tp as u64, 0, 0, 0, 0) };
}

/// The first thread's: a block from the kernel (nothing else is ready yet).
pub(crate) fn init_first() {
    let bytes = size().next_multiple_of(4096);
    let (h, _) = unsafe { syscall(SYS_MEM_NEW, bytes as u64, 0, 0, 0, 0) };
    if h < 0 {
        exit_thread(h);
    }
    let (va, _) = unsafe { syscall(SYS_MAP, h as u64, 0, 0, 0, 0) };
    if va < 0 {
        exit_thread(va);
    }
    set(unsafe { make(va as *mut u8) });
}
