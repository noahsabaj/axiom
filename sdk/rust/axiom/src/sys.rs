//! The kernel's interface, as src/kernel/defs.inc has it: system calls, the
//! ring's requests and completions, and what they answer.

use core::arch::asm;
use core::fmt;

// system calls: SYSCALL with RAX = the number, the arguments in RDI, RSI, RDX,
// R10 (and R8); RAX (and RDX) back, RCX and R11 lost
pub const SYS_EXIT: u64 = 0;
pub const SYS_RING_ENTER: u64 = 1;
pub const SYS_RING_NEW: u64 = 2;
pub const SYS_MEM_NEW: u64 = 3;
pub const SYS_MAP: u64 = 4;
pub const SYS_EVENT_NEW: u64 = 5;
pub const SYS_THREAD_NEW: u64 = 6;
pub const SYS_YIELD: u64 = 7;
pub const SYS_UNMAP: u64 = 8;
pub const SYS_SPAWN: u64 = 9;
pub const SYS_CHANNEL_NEW: u64 = 10;
pub const SYS_WINDOW_NEW: u64 = 11;
pub const SYS_SOUND_NEW: u64 = 12;

// what a ring entry asks for (RO_*)
pub const RO_NOP: u8 = 0;
pub const RO_SIGNAL: u8 = 1;
pub const RO_RESET: u8 = 2;
pub const RO_WAIT: u8 = 3;
pub const RO_JOIN: u8 = 4;
pub const RO_TIMEOUT: u8 = 5;
pub const RO_COPY: u8 = 6;
pub const RO_DUP: u8 = 7;
pub const RO_CLOSE: u8 = 8;
pub const RO_GIVE: u8 = 9;
pub const RO_REVOKE: u8 = 10;
pub const RO_CANCEL: u8 = 11;
pub const RO_WRITE: u8 = 12;
pub const RO_SEND: u8 = 13;
pub const RO_RECV: u8 = 14;
pub const RO_KILL: u8 = 15;
pub const RO_WIN_SHOW: u8 = 30;
pub const RO_WIN_TITLE: u8 = 31;
pub const RO_DESK_LOOK: u8 = 34;
pub const RO_FS_VOLUMES: u8 = 35;
pub const RO_FS_LIST: u8 = 36;
pub const RO_FS_READ: u8 = 37;
pub const RO_FS_WRITE: u8 = 38;
pub const RO_FS_MKDIR: u8 = 39;
pub const RO_FS_REMOVE: u8 = 40;
pub const RO_FS_RENAME: u8 = 41;
pub const RO_FS_SUB: u8 = 42;
pub const RO_WIN_POINTER: u8 = 43;

pub const SQF_LINK: u8 = 1; // the next entry starts once this one succeeds

// rights (RT_*)
pub const RT_DUP: u32 = 1 << 0;
pub const RT_GIVE: u32 = 1 << 1;
pub const RT_INFO: u32 = 1 << 2;
pub const RT_DESK_WINDOW: u32 = 1 << 8;
pub const RT_FS_READ: u32 = 1 << 8;
pub const RT_FS_WRITE: u32 = 1 << 9;

// the start block, at USER_START (SB_*)
pub const SB_RING: usize = 0;
pub const SB_CONSOLE: usize = 8;
pub const SB_GIFT: usize = 12;
pub const SB_RING_VA: usize = 16;
pub const SB_TSC_PER_US: usize = 24;
pub const SB_ARGS_LEN: usize = 32;
pub const SB_STORE: usize = 36;
pub const SB_NET: usize = 40;
pub const SB_DESK: usize = 44;
pub const SB_FILES: usize = 52;
pub const SB_GIFT2: usize = 56;
pub const SB_SOUND: usize = 60;
pub const SB_ARGS: usize = 64;

// the ring's memory (RA_*)
pub const RA_SQ_TAIL: usize = 0;
pub const RA_CQ_HEAD: usize = 4;
pub const RA_CQ_TAIL: usize = 68;
pub const RA_SQ_ENTRIES: usize = 128;
pub const RA_CQ_ENTRIES: usize = 132;
pub const RA_SQ_OFF: usize = 136;
pub const RA_CQ_OFF: usize = 140;

/// A request on the ring (SQ_*), 64 bytes.
#[repr(C, align(64))]
#[derive(Clone, Copy, Default)]
pub struct Entry {
    pub op: u8,
    pub flags: u8,
    pub _pad: u16,
    pub handle: u32,
    pub data: u64,
    pub a0: u64,
    pub a1: u64,
    pub a2: u64,
    pub handle2: u32,
    pub _pad2: u32,
    pub deadline: u64, // TSC, 0 for none
    pub _pad3: u64,
}

impl Entry {
    pub fn new(op: u8, handle: u32) -> Entry {
        Entry { op, handle, ..Entry::default() }
    }
}

/// What came of one (CQ_*), 32 bytes.
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Completion {
    pub data: u64,
    pub result: i64,
    pub value: u64,
    pub op: u32,
    _pad: u32,
}

/// A handle in this task's table: what it may reach, and how.
pub type Handle = u32;

/// What the kernel refused with (E_*).
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Error(pub i32);

pub type Result<T> = core::result::Result<T, Error>;

impl Error {
    pub const BADH: Error = Error(-1);
    pub const TYPE: Error = Error(-2);
    pub const RIGHTS: Error = Error(-3);
    pub const EXPIRED: Error = Error(-4);
    pub const REVOKED: Error = Error(-5);
    pub const RANGE: Error = Error(-6);
    pub const NOMEM: Error = Error(-7);
    pub const FULL: Error = Error(-8);
    pub const TIMEOUT: Error = Error(-9);
    pub const ARG: Error = Error(-10);
    pub const CANCELED: Error = Error(-11);
    pub const KILLED: Error = Error(-12);
    pub const FAULT: Error = Error(-13);
    pub const PEER: Error = Error(-14);
    pub const EMPTY: Error = Error(-15);
    pub const IO: Error = Error(-18);
    pub const NOFILE: Error = Error(-21);
    pub const READONLY: Error = Error(-22);
    pub const EXISTS: Error = Error(-23);
    /// Not given to the program: no desktop, no files.
    pub const ABSENT: Error = Error(-100);

    /// What it means, in a few words.
    pub fn text(self) -> &'static str {
        match self.0 {
            -1 => "no such handle",
            -2 => "the wrong kind of thing",
            -3 => "not allowed",
            -4 => "expired",
            -5 => "revoked",
            -6 => "out of range",
            -7 => "out of memory",
            -8 => "full",
            -9 => "timed out",
            -10 => "a bad argument",
            -11 => "canceled",
            -12 => "killed",
            -13 => "faulted",
            -14 => "the other end is closed",
            -15 => "nothing yet",
            -16 => "a conflict",
            -17 => "no such name",
            -18 => "the drive failed",
            -19 => "no store",
            -20 => "the network failed",
            -21 => "no such file or folder",
            -22 => "read-only (vol <n> rw in the shell allows writing)",
            -23 => "the name is taken",
            -100 => "not given to this program",
            _ => "refused",
        }
    }
}

impl fmt::Debug for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Error({}: {})", self.0, self.text())
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.text())
    }
}

/// RAX < 0 as an error, else RAX.
pub fn check(rax: i64) -> Result<u64> {
    if rax < 0 { Err(Error(rax as i32)) } else { Ok(rax as u64) }
}

/// A system call: RAX and RDX back.
///
/// # Safety
/// The kernel reads and writes memory the arguments point at.
#[inline]
pub unsafe fn syscall(n: u64, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64) -> (i64, u64) {
    let rax: i64;
    let rdx: u64;
    unsafe {
        asm!("syscall",
            inlateout("rax") n as i64 => rax,
            in("rdi") a0, in("rsi") a1,
            inlateout("rdx") a2 => rdx,
            in("r10") a3, in("r8") a4,
            lateout("rcx") _, lateout("r11") _,
            options(nostack));
    }
    (rax, rdx)
}

/// This thread ends (the program, if it is the first).
pub fn exit(code: i64) -> ! {
    unsafe {
        syscall(SYS_EXIT, code as u64, 0, 0, 0, 0);
        asm!("ud2", options(noreturn));
    }
}

/// Others run first.
pub fn yield_now() {
    unsafe { syscall(SYS_YIELD, 0, 0, 0, 0, 0) };
}

/// The time stamp counter.
#[inline]
pub fn rdtsc() -> u64 {
    unsafe { core::arch::x86_64::_rdtsc() }
}
