//! A program's start: the kernel starts its first thread at _start with RDI
//! = the start block (USER_START) and a 64 KiB stack. `axiom::entry!` makes
//! _start; it takes in the start block, gives the thread its thread-local
//! block, moves to a stack of its own (8 MiB, or what entry! says), and
//! runs main: std's runtime first, for a program with std.

use core::sync::atomic::{AtomicPtr, Ordering};

use crate::sys::*;
use crate::{console, mem, ring, time, tls};

static START: AtomicPtr<u8> = AtomicPtr::new(core::ptr::null_mut());

/// What a program is given and wants (AXE_WANTS, the shell's +net +store
/// +desk +files +sound).
pub mod wants {
    pub const NET: u64 = 1;
    pub const STORE: u64 = 2;
    pub const DESK: u64 = 4;
    pub const FILES: u64 = 16;
    pub const SOUND: u64 = 32;
}

fn sb_u32(off: usize) -> u32 {
    let sb = START.load(Ordering::Relaxed);
    if sb.is_null() { 0 } else { unsafe { (sb.add(off) as *const u32).read() } }
}

fn sb_u64(off: usize) -> u64 {
    let sb = START.load(Ordering::Relaxed);
    if sb.is_null() { 0 } else { unsafe { (sb.add(off) as *const u64).read() } }
}

/// The arguments it was run with, after its name, as typed.
pub fn args_line() -> &'static str {
    let sb = START.load(Ordering::Relaxed);
    if sb.is_null() {
        return "";
    }
    let len = (sb_u32(SB_ARGS_LEN) as usize).min(4096 - SB_ARGS - 1);
    let bytes = unsafe { core::slice::from_raw_parts(sb.add(SB_ARGS), len) };
    let end = bytes.iter().position(|&b| b == 0).unwrap_or(len);
    core::str::from_utf8(&bytes[..end]).unwrap_or("")
}

/// Them, split at blanks; a word in double quotes may hold blanks.
pub fn args() -> Args {
    Args { rest: args_line() }
}

pub struct Args {
    rest: &'static str,
}

impl Iterator for Args {
    type Item = &'static str;

    fn next(&mut self) -> Option<&'static str> {
        let s = self.rest.trim_start_matches(' ');
        if s.is_empty() {
            self.rest = s;
            return None;
        }
        if let Some(q) = s.strip_prefix('"') {
            let end = q.find('"').unwrap_or(q.len());
            self.rest = q.get(end + 1..).unwrap_or("");
            return Some(&q[..end]);
        }
        let end = s.find(' ').unwrap_or(s.len());
        self.rest = &s[end..];
        Some(&s[..end])
    }
}

/// The handles in the start block: 0 for what it was not given.
pub fn desk_handle() -> Handle {
    sb_u32(SB_DESK)
}
pub fn files_handle() -> Handle {
    sb_u32(SB_FILES)
}
pub fn net_handle() -> Handle {
    sb_u32(SB_NET)
}
pub fn store_handle() -> Handle {
    sb_u32(SB_STORE)
}
pub fn sound_handle() -> Handle {
    sb_u32(SB_SOUND)
}
pub fn gift() -> Handle {
    sb_u32(SB_GIFT)
}
pub fn gift2() -> Handle {
    sb_u32(SB_GIFT2)
}
pub fn console_handle() -> Handle {
    sb_u32(SB_CONSOLE)
}

fn init(sb: *mut u8) {
    START.store(sb, Ordering::Relaxed);
    tls::init_first(); // before anything that has thread-local storage
    ring::init(sb_u32(SB_RING), sb_u64(SB_RING_VA) as *mut u8);
    time::init(sb_u64(SB_TSC_PER_US));
    console::init(sb_u32(SB_CONSOLE));
}

/// A stack of its own -> its top (the 64 KiB it has, if none is made).
fn stack_top(stack: usize) -> Option<*mut u8> {
    let (_, base) = mem::block_new(stack).ok()?;
    Some(unsafe { base.add(stack.next_multiple_of(4096)) })
}

/// _start's: RDI = the start block, RSI = the stack's size, RDX = main.
#[doc(hidden)]
pub unsafe extern "C" fn start(sb: *mut u8, stack: usize, main: extern "C" fn() -> i64) -> ! {
    init(sb);
    let Some(top) = stack_top(stack) else {
        exit(main()); // on the 64 KiB it has
    };
    unsafe {
        core::arch::asm!(
            "mov rsp, {top}",
            "call {main}",
            "mov rdi, rax",
            "mov esi, 1",              // EXIT_TASK
            "xor eax, eax",            // SYS_EXIT
            "syscall",
            "ud2",
            top = in(reg) top,
            main = in(reg) main,
            options(noreturn));
    }
}

/// std's entry (its hermit layer's runtime_entry): (argc, argv, envp).
#[doc(hidden)]
pub type StdEntry = unsafe extern "C" fn(i32, *const *const u8, *const *const u8) -> !;

/// _start's, with std: std's runtime given the arguments as C strings
/// (argv[0] "axe"), and no environment; it runs main, and ends the program
/// with what main returned.
#[doc(hidden)]
#[cfg(feature = "alloc")]
pub unsafe extern "C" fn start_std(sb: *mut u8, stack: usize, entry: StdEntry) -> ! {
    use alloc::vec::Vec;
    init(sb);
    let mut argv: Vec<*const u8> = Vec::new();
    for a in core::iter::once("axe").chain(args()) {
        let mut s = Vec::with_capacity(a.len() + 1);
        s.extend_from_slice(a.as_bytes());
        s.push(0);
        argv.push(s.leak().as_ptr());
    }
    let argc = argv.len() as i32;
    argv.push(core::ptr::null());
    let argv = argv.leak().as_ptr();
    // HOME: the boot volume's /Home (std's paths without a volume are on it)
    let envp = alloc::vec![b"HOME=/Home\0".as_ptr(), core::ptr::null()].leak().as_ptr();
    let Some(top) = stack_top(stack) else {
        unsafe { entry(argc, argv, envp) }
    };
    unsafe {
        core::arch::asm!(
            "mov rsp, {top}",
            "call {entry}",
            "ud2",
            top = in(reg) top,
            entry = in(reg) entry,
            in("rdi") argc,
            in("rsi") argv,
            in("rdx") envp,
            options(noreturn));
    }
}

/// What main may return: an exit code, () for 0, a Result (an error said on
/// the console, and 1).
pub trait Termination {
    fn report(self) -> i64;
}

impl Termination for () {
    fn report(self) -> i64 {
        0
    }
}

impl Termination for i64 {
    fn report(self) -> i64 {
        self
    }
}

impl Termination for i32 {
    fn report(self) -> i64 {
        self as i64
    }
}

impl<T: Termination, E: core::fmt::Debug> Termination for core::result::Result<T, E> {
    fn report(self) -> i64 {
        match self {
            Ok(t) => t.report(),
            Err(e) => {
                crate::println!("Error: {:?}", e);
                1
            }
        }
    }
}

/// The program's entry, and what it wants given (the shell gives no more).
/// With std, main is a plain `fn main`, std's to run:
///
///   axiom::entry!(wants = axiom::wants::DESK);
///   axiom::entry!(wants = axiom::wants::DESK, stack = 16 << 20);
///
/// Without std (#![no_std], #![no_main]), it names main:
///
///   axiom::entry!(main);
///   axiom::entry!(main, wants = axiom::wants::DESK | axiom::wants::FILES);
///   axiom::entry!(main, wants = axiom::wants::DESK, stack = 16 << 20);
#[macro_export]
macro_rules! entry {
    (wants = $wants:expr) => { $crate::entry!(wants = $wants, stack = 8 << 20); };
    (wants = $wants:expr, stack = $stack:expr) => {
        #[unsafe(link_section = ".axe.wants")]
        #[used]
        static __AXE_WANTS: u64 = $wants;

        unsafe extern "C" {
            fn runtime_entry(argc: i32, argv: *const *const u8, envp: *const *const u8) -> !;
        }

        extern "C" fn __axiom_start(sb: *mut u8) -> ! {
            unsafe { $crate::rt::start_std(sb, $stack, runtime_entry) }
        }

        $crate::__start!(__axiom_start);
    };
    ($main:path) => { $crate::entry!($main, wants = 0, stack = 8 << 20); };
    ($main:path, wants = $wants:expr) => { $crate::entry!($main, wants = $wants, stack = 8 << 20); };
    ($main:path, wants = $wants:expr, stack = $stack:expr) => {
        #[unsafe(link_section = ".axe.wants")]
        #[used]
        static __AXE_WANTS: u64 = $wants;

        extern "C" fn __axiom_main() -> i64 {
            $crate::rt::Termination::report($main())
        }

        extern "C" fn __axiom_start(sb: *mut u8) -> ! {
            unsafe { $crate::rt::start(sb, $stack, __axiom_main) }
        }

        $crate::__start!(__axiom_start);
    };
}

/// _start itself: RSP comes 16-aligned, and a call expects it 8 past.
#[doc(hidden)]
#[macro_export]
macro_rules! __start {
    ($start:ident) => {
        #[unsafe(no_mangle)]
        #[unsafe(naked)]
        #[unsafe(link_section = ".text._start")]
        unsafe extern "C" fn _start() -> ! {
            core::arch::naked_asm!("and rsp, -16", "call {}", "ud2", sym $start)
        }
    };
}
