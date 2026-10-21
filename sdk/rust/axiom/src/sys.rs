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
pub const SYS_TLS: u64 = 13;
pub const SYS_FUTEX_WAIT: u64 = 14;
pub const SYS_FUTEX_WAKE: u64 = 15;
pub const SYS_INFO: u64 = 16;

/// SYS_EXIT's second: the whole task ends, from any thread.
pub const EXIT_TASK: u64 = 1;
/// SYS_INFO's: microseconds since 1970 (the RTC's, as UTC); CPUs running;
/// bytes of memory, and of it free; milliseconds since power-on.
pub const SI_CLOCK: u64 = 0;
pub const SI_CPUS: u64 = 1;
pub const SI_RAM: u64 = 2;
pub const SI_RAM_FREE: u64 = 3;
pub const SI_UPTIME: u64 = 4;
/// SYS_INFO's: the battery as last read (each minute): its percent, with
/// the flags below and its charge mode at bits 19:16; negative with none.
pub const SI_BATTERY: u64 = 5;
pub const SI_BAT_PERCENT: u64 = 0xFF;
pub const SI_BAT_PLUGGED: u64 = 1 << 8;
pub const SI_BAT_HELD: u64 = 1 << 9;
pub const SI_BAT_MODE_SHIFT: u32 = 16;
/// SYS_INFO's: the CPU's temperature now, in degrees C; negative with none.
pub const SI_TEMP: u64 = 6;
/// SYS_INFO's: the load average over the last minute, in hundredths.
pub const SI_LOAD: u64 = 7;

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
pub const RO_NET_CONNECT: u8 = 24;
pub const RO_NET_LISTEN: u8 = 25;
pub const RO_NET_ACCEPT: u8 = 26;
pub const RO_NET_STATUS: u8 = 27;
pub const RO_NET_SHUT: u8 = 28;
pub const RO_NET_SUB: u8 = 29;
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
pub const RO_NET_ADDR: u8 = 44;
pub const RO_FS_UPDATE: u8 = 45;
pub const RO_WIN_ZOOM: u8 = 46;

pub const SQF_LINK: u8 = 1; // the next entry starts once this one succeeds

// a new kernel (RO_FS_UPDATE's a1, UPD_*; UPD_STATE's result, UPS_*)
pub const UPD_STATE: u64 = 0;
pub const UPD_TRY: u64 = 1;
pub const UPD_KEEP: u64 = 2;
pub const UPD_RESTART: u64 = 3;
pub const UPS_SLOT: u64 = 0xFF;
pub const UPS_TRIAL: u64 = 1 << 8;
pub const UPS_KEPT_SHIFT: u32 = 16;
pub const UPS_NEXT_SHIFT: u32 = 24;

// rights (RT_*)
pub const RT_DUP: u32 = 1 << 0;
pub const RT_GIVE: u32 = 1 << 1;
pub const RT_INFO: u32 = 1 << 2;
pub const RT_DESK_WINDOW: u32 = 1 << 8;
pub const RT_FS_READ: u32 = 1 << 8;
pub const RT_FS_WRITE: u32 = 1 << 9;
pub const RT_FS_KERNEL: u32 = 1 << 10;
pub const RT_NET_CONNECT: u32 = 1 << 8;
pub const RT_NET_TLS: u32 = 1 << 9;
pub const RT_NET_INSECURE: u32 = 1 << 10;
pub const RT_NET_LISTEN: u32 = 1 << 11;
pub const RT_SK_SEND: u32 = 1 << 8;
pub const RT_SK_RECV: u32 = 1 << 9;

// the network (socket.asm): RO_NET_CONNECT's a2 (NETF_*); a socket's state,
// why it failed, and what RO_WAIT would find there now (RO_NET_STATUS:
// SKS_* | NETW_* << 8 | TLS's error << 16 | NS_*); its addresses (RO_NET_ADDR,
// NA_*: 16 bytes each, IPv4 as ::ffff:a.b.c.d); what a TLS listener proves
// it is (RO_NET_LISTEN with NETF_TLS, NI_*: a P-256 key, 32 bytes, then
// the certificates' bytes, a dword, then each a 24-bit big-endian length,
// its DER and two zero bytes, the leaf first)
pub const NETF_TLS: u64 = 1;
pub const NETF_INSECURE: u64 = 2;
pub const NETF_LOOKUP: u64 = 4;
pub const SKS_LOOKUP: u32 = 1;
pub const SKS_CONNECT: u32 = 2;
pub const SKS_HANDSHAKE: u32 = 3;
pub const SKS_OPEN: u32 = 4;
pub const SKS_ENDED: u32 = 5;
pub const SKS_FAILED: u32 = 6;
pub const SKS_LISTEN: u32 = 7;
pub const NETW_NOSERVER: u32 = 1;
pub const NETW_BADNAME: u32 = 2;
pub const NETW_BUSY: u32 = 3;
pub const NETW_NOHOST: u32 = 4;
pub const NETW_NOADDR: u32 = 5;
pub const NETW_DNS: u32 = 6;
pub const NETW_NOANSWER: u32 = 7;
pub const NETW_DOWN: u32 = 8;
pub const NETW_NOROUTE: u32 = 9;
pub const NETW_REFUSED: u32 = 10;
pub const NETW_RESET: u32 = 11;
pub const NETW_TIMEOUT: u32 = 12;
pub const NETW_TLS: u32 = 13;
pub const NETW_INUSE: u32 = 14;
pub const NETW_IDENTITY: u32 = 15;
pub const NS_RECV: u64 = 1 << 24;
pub const NS_SEND: u64 = 1 << 25;
pub const NA_PEER: usize = 0;
pub const NA_LOCAL: usize = 16;
pub const NA_PEER_PORT: usize = 32;
pub const NA_PORT: usize = 36;
pub const NA_SIZE: usize = 40;
pub const NI_KEY: usize = 0;
pub const NI_LEN: usize = 32;
pub const NI_CERTS: usize = 40;
pub const NI_MAX: usize = 16000;
pub const SK_HOST_MAX: usize = 256;
pub const SK_BUF: usize = 65536;

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
    pub const CONFLICT: Error = Error(-16);
    pub const IO: Error = Error(-18);
    pub const NET: Error = Error(-20);
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

/// The program ends, with every thread, from whichever thread says so.
pub fn exit(code: i64) -> ! {
    unsafe {
        syscall(SYS_EXIT, code as u64, EXIT_TASK, 0, 0, 0);
        asm!("ud2", options(noreturn));
    }
}

/// This thread alone ends (the program, if it is the first).
pub fn exit_thread(code: i64) -> ! {
    unsafe {
        syscall(SYS_EXIT, code as u64, 0, 0, 0, 0);
        asm!("ud2", options(noreturn));
    }
}

/// While the dword at `word` holds `value`, this thread waits, until a
/// futex_wake there or the deadline (TSC, 0 for none) -> Ok once woken;
/// CONFLICT if it held another value, TIMEOUT.
pub fn futex_wait(word: &core::sync::atomic::AtomicU32, value: u32, deadline: u64) -> Result<()> {
    let (r, _) = unsafe {
        syscall(SYS_FUTEX_WAIT, word.as_ptr() as u64, value as u64, deadline, 0, 0)
    };
    check(r).map(|_| ())
}

/// Up to `count` of the threads waiting at `word` woken -> how many were.
pub fn futex_wake(word: &core::sync::atomic::AtomicU32, count: u32) -> u32 {
    let (r, _) = unsafe { syscall(SYS_FUTEX_WAKE, word.as_ptr() as u64, count as u64, 0, 0, 0) };
    r.max(0) as u32
}

/// Microseconds since 1970, by the machine's clock (taken as UTC).
pub fn clock_us() -> u64 {
    unsafe { syscall(SYS_INFO, SI_CLOCK, 0, 0, 0, 0) }.0.max(0) as u64
}

/// CPUs running.
pub fn cpus() -> usize {
    (unsafe { syscall(SYS_INFO, SI_CPUS, 0, 0, 0, 0) }.0).max(1) as usize
}

/// Bytes of memory Axiom has, and of those, free.
pub fn ram() -> (u64, u64) {
    let all = unsafe { syscall(SYS_INFO, SI_RAM, 0, 0, 0, 0) }.0.max(0) as u64;
    let free = unsafe { syscall(SYS_INFO, SI_RAM_FREE, 0, 0, 0, 0) }.0.max(0) as u64;
    (all, free)
}

/// Milliseconds since the machine was switched on.
pub fn uptime_ms() -> u64 {
    unsafe { syscall(SYS_INFO, SI_UPTIME, 0, 0, 0, 0) }.0.max(0) as u64
}

/// A laptop's battery, as Axiom last read it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Battery {
    /// 0 to 100.
    pub percent: u8,
    /// On its charger (also while Axiom runs it from the battery on purpose).
    pub plugged: bool,
    /// Kept between 75% and 80% ('battery hold').
    pub held: bool,
    /// HP's charge mode: 0 charging as the firmware likes, 2 running from
    /// the battery, 5 not charging.
    pub mode: u8,
}

/// The battery, where Axiom reads one; None on a machine without one, or
/// whose charge Axiom cannot read.
pub fn battery() -> Option<Battery> {
    let r = unsafe { syscall(SYS_INFO, SI_BATTERY, 0, 0, 0, 0) }.0;
    if r < 0 {
        return None;
    }
    let r = r as u64;
    Some(Battery {
        percent: (r & SI_BAT_PERCENT) as u8,
        plugged: r & SI_BAT_PLUGGED != 0,
        held: r & SI_BAT_HELD != 0,
        mode: ((r >> SI_BAT_MODE_SHIFT) & 0x0F) as u8,
    })
}

/// The CPU's temperature now, in degrees C, from its package's sensor (else
/// the calling CPU's core's); None where Axiom reads none (QEMU, AMD).
pub fn cpu_temp() -> Option<u32> {
    let r = unsafe { syscall(SYS_INFO, SI_TEMP, 0, 0, 0, 0) }.0;
    if r < 0 { None } else { Some(r as u32) }
}

/// The load average over the last minute, as Unix's: the threads running
/// or waiting for a CPU, averaged every 5 s (1.0: one CPU's worth).
pub fn load() -> f64 {
    unsafe { syscall(SYS_INFO, SI_LOAD, 0, 0, 0, 0) }.0.max(0) as f64 / 100.0
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
    let mut x = STATE.load(Ordering::Relaxed) ^ rdtsc();
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    STATE.store(x, Ordering::Relaxed);
    (x >> 32) as u32
}
