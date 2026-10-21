//! What std calls, built for this target: its hermit layer (library/std's
//! sys/*/hermit.rs, through the hermit-abi crate) leaves the system to
//! extern "C" functions named sys_*, which a Hermit kernel would link in.
//! Here they are Axiom's, so std's own pieces work as they are:
//!
//! - memory (System): the heap (axiom::Heap)
//! - std::time: Instant by the TSC, SystemTime by the machine's clock
//!   (SYS_INFO)
//! - std::thread: spawn and join (axiom::thread), sleep, yield,
//!   available_parallelism; Mutex, Condvar, RwLock, Once, park, mpsc by
//!   futexes (SYS_FUTEX_WAIT, SYS_FUTEX_WAKE); thread_local! (axiom::tls)
//! - stdin (nothing), stdout and stderr: the console
//! - std::fs, with wants::FILES: "vol<n>:/a/b" on any volume; a path with
//!   no volume is on the boot volume, from its root. A file is read whole
//!   when it is opened and written whole when it is closed (and made, or
//!   emptied, as it is opened: so a volume that can't be written says so
//!   then). read_dir of an empty folder is an error (std's hermit layer
//!   takes no entries for one); rename, set_len and sync_all are
//!   Unsupported, as std's hermit layer has them.
//! - env::args (argv[0] is "axe"), no environment, random bytes (RDRAND)
//! - std::net, with wants::NET: TCP, over the kernel's sockets (axiom::net):
//!   TcpStream (connect, its timeout, read and write timeouts, peek,
//!   nonblocking, shutdown, try_clone, its addresses), TcpListener (a
//!   port, or 0 for one of ours), lookups by the kernel's DNS (one
//!   address a name). A name looked up is remembered: connecting to its
//!   address gives the kernel the name, which a capability to that host
//!   reaches. There is no loopback: binding 127.0.0.1 is refused
//!   (EADDRNOTAVAIL: a port is listened on at every address), and so is
//!   connecting to it; and no UDP (EPROTONOSUPPORT). The socket options
//!   are kept and said back, but change nothing (TCP_NODELAY: each send
//!   goes at once).
//!
//! Errors are Linux's numbers, as hermit-abi has them, negated.

use alloc::boxed::Box;
use alloc::string::String;
use alloc::vec::Vec;
use core::alloc::{GlobalAlloc, Layout};
use core::ffi::{CStr, c_char, c_void};
use core::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use core::sync::atomic::{AtomicU32, Ordering};
use core::time::Duration;

use crate::files::{self, Files};
use crate::net::{self, Net};
use crate::heap::SYSTEM;
use crate::sync::SpinLock;
use crate::sys::{
    self, Entry, Error, Handle, NETW_BADNAME, NETW_BUSY, NETW_DNS, NETW_DOWN, NETW_IDENTITY, NETW_INUSE,
    NETW_NOADDR, NETW_NOANSWER, NETW_NOHOST, NETW_NOROUTE, NETW_NOSERVER, NETW_REFUSED, NETW_RESET,
    NETW_TIMEOUT, RO_WAIT, SK_BUF, SKS_LISTEN,
};
use crate::{console, ring, thread, time};

const ENOENT: i32 = 2;
const EINTR: i32 = 4;
const EIO: i32 = 5;
const EBADF: i32 = 9;
const EAGAIN: i32 = 11;
const ENOMEM: i32 = 12;
const EACCES: i32 = 13;
const EEXIST: i32 = 17;
const ENOTDIR: i32 = 20;
const EISDIR: i32 = 21;
const EINVAL: i32 = 22;
const EMFILE: i32 = 24;
const EFBIG: i32 = 27;
const ENOSPC: i32 = 28;
const ESPIPE: i32 = 29;
const EROFS: i32 = 30;
const ENAMETOOLONG: i32 = 36;
const ENOSYS: i32 = 38;
const ETIMEDOUT: i32 = 110;

const CLOCK_REALTIME: i32 = 1;
const CLOCK_MONOTONIC: i32 = 4;
const FUTEX_RELATIVE_TIMEOUT: u32 = 1;
const O_ACCMODE: i32 = 3;
const O_CREAT: i32 = 0o100;
const O_EXCL: i32 = 0o200;
const O_TRUNC: i32 = 0o1000;
const O_APPEND: i32 = 0o2000;
const O_DIRECTORY: i32 = 0o200000;
const SEEK_SET: i32 = 0;
const SEEK_CUR: i32 = 1;
const SEEK_END: i32 = 2;
const S_IFCHR: u32 = 0o2_0000;
const S_IFDIR: u32 = 0o4_0000;
const S_IFREG: u32 = 0o10_0000;
const DT_DIR: u8 = 4;
const DT_REG: u8 = 8;
const EAI_FAIL: i32 = 4;

/// As hermit-abi has them.
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Timespec {
    tv_sec: i64,
    tv_nsec: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Stat {
    st_dev: u64,
    st_ino: u64,
    st_nlink: u64,
    st_mode: u32,
    st_uid: u32,
    st_gid: u32,
    st_rdev: u64,
    st_size: i64,
    st_blksize: i64,
    st_blocks: i64,
    st_atim: Timespec,
    st_mtim: Timespec,
    st_ctim: Timespec,
}

#[repr(C)]
pub struct Dirent64 {
    d_ino: u64,
    d_off: i64,
    d_reclen: u16,
    d_type: u8,
    d_name: [u8; 256],
}

#[repr(C)]
pub struct Iovec {
    base: *mut u8,
    len: usize,
}

fn errno(e: Error) -> i32 {
    match e {
        Error::NOFILE => ENOENT,
        Error::READONLY => EROFS,
        Error::EXISTS => EEXIST,
        Error::RIGHTS | Error::ABSENT => EACCES,
        Error::ARG => EINVAL,
        Error::NOMEM => ENOMEM,
        Error::FULL => ENOSPC,
        Error::RANGE => EFBIG,
        Error::TIMEOUT => ETIMEDOUT,
        Error::TYPE => ENOTDIR,
        _ => EIO,
    }
}

// ---- memory -----------------------------------------------------------

fn layout(size: usize, align: usize) -> Option<Layout> {
    Layout::from_size_align(size.max(1), align.max(1)).ok()
}

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_malloc(size: usize, align: usize) -> *mut u8 {
    layout(size, align).map_or(core::ptr::null_mut(), |l| unsafe { SYSTEM.alloc(l) })
}

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_alloc(size: usize, align: usize) -> *mut u8 {
    unsafe { sys_malloc(size, align) }
}

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_alloc_zeroed(size: usize, align: usize) -> *mut u8 {
    layout(size, align).map_or(core::ptr::null_mut(), |l| unsafe { SYSTEM.alloc_zeroed(l) })
}

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_realloc(ptr: *mut u8, size: usize, align: usize, new: usize) -> *mut u8 {
    layout(size, align).map_or(core::ptr::null_mut(), |l| unsafe { SYSTEM.realloc(ptr, l, new.max(1)) })
}

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_free(ptr: *mut u8, size: usize, align: usize) {
    if let Some(l) = layout(size, align) {
        unsafe { SYSTEM.dealloc(ptr, l) }
    }
}

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_dealloc(ptr: *mut u8, size: usize, align: usize) {
    unsafe { sys_free(ptr, size, align) }
}

#[unsafe(no_mangle)]
extern "C" fn sys_getpagesize() -> i32 {
    4096
}

#[unsafe(no_mangle)]
extern "C" fn sys_mmap(_size: usize, _prot: u32, _ret: *mut *mut u8) -> i32 {
    -ENOSYS
}

#[unsafe(no_mangle)]
extern "C" fn sys_munmap(_ptr: *mut u8, _size: usize) -> i32 {
    -ENOSYS
}

#[unsafe(no_mangle)]
extern "C" fn sys_mprotect(_ptr: *mut u8, _size: usize, _prot: u32) -> i32 {
    -ENOSYS
}

// ---- time -------------------------------------------------------------

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_clock_gettime(clock: i32, tp: *mut Timespec) -> i32 {
    let ns = match clock {
        CLOCK_REALTIME => sys::clock_us() as u128 * 1000,
        CLOCK_MONOTONIC => time::nanos() as u128,
        _ => return -EINVAL,
    };
    if tp.is_null() {
        return -EINVAL;
    }
    let t = Timespec { tv_sec: (ns / 1_000_000_000) as i64, tv_nsec: (ns % 1_000_000_000) as i32 };
    unsafe { tp.write(t) };
    0
}

fn duration(t: &Timespec) -> Duration {
    Duration::new(t.tv_sec.max(0) as u64, t.tv_nsec.clamp(0, 999_999_999) as u32)
}

#[unsafe(no_mangle)]
extern "C" fn sys_usleep(us: u64) {
    time::sleep(Duration::from_micros(us));
}

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_nanosleep(req: *const Timespec) -> i32 {
    if req.is_null() {
        return -EINVAL;
    }
    time::sleep(duration(unsafe { &*req }));
    0
}

// ---- futexes ----------------------------------------------------------

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_futex_wait(addr: *mut u32, expected: u32, timeout: *const Timespec, flags: u32) -> i32 {
    if addr.is_null() {
        return -EINVAL;
    }
    let deadline = if timeout.is_null() {
        0
    } else {
        let d = duration(unsafe { &*timeout });
        let at = if flags & FUTEX_RELATIVE_TIMEOUT != 0 {
            time::Instant::now() + d
        } else {
            time::Instant::from_nanos(d.as_nanos() as u64) // (CLOCK_MONOTONIC's)
        };
        at.tsc().max(1)
    };
    let word = unsafe { AtomicU32::from_ptr(addr) };
    match sys::futex_wait(word, expected, deadline) {
        Ok(()) => 0,
        Err(Error::CONFLICT) => -EAGAIN,
        Err(Error::TIMEOUT) => -ETIMEDOUT,
        Err(Error::KILLED) => -EINTR,
        Err(_) => -EINVAL,
    }
}

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_futex_wake(addr: *mut u32, count: i32) -> i32 {
    if addr.is_null() {
        return -EINVAL;
    }
    let word = unsafe { AtomicU32::from_ptr(addr) };
    sys::futex_wake(word, count.max(0) as u32) as i32
}

// ---- threads ----------------------------------------------------------

#[unsafe(no_mangle)]
extern "C" fn sys_spawn2(func: extern "C" fn(usize), arg: usize, _prio: u8, stack: usize, _core: isize) -> u32 {
    thread::spawn(func, arg, if stack == 0 { 2 << 20 } else { stack }).map_or(0, |t| t.0)
}

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_spawn(id: *mut u32, func: extern "C" fn(usize), arg: usize, prio: u8, core: isize) -> i32 {
    let t = sys_spawn2(func, arg, prio, 0, core);
    if !id.is_null() {
        unsafe { id.write(t) };
    }
    if t == 0 { -ENOMEM } else { 0 }
}

#[unsafe(no_mangle)]
extern "C" fn sys_join(id: u32) -> i32 {
    thread::Thread(id).join();
    0
}

#[unsafe(no_mangle)]
extern "C" fn sys_yield() {
    sys::yield_now();
}

#[unsafe(no_mangle)]
extern "C" fn sys_available_parallelism() -> usize {
    sys::cpus()
}

#[unsafe(no_mangle)]
extern "C" fn sys_get_processor_count() -> usize {
    sys::cpus()
}

#[unsafe(no_mangle)]
extern "C" fn sys_getpid() -> i32 {
    1
}

#[unsafe(no_mangle)]
extern "C" fn sys_get_priority() -> u8 {
    2 // NORMAL_PRIO
}

#[unsafe(no_mangle)]
extern "C" fn sys_set_priority(_tid: u32, _prio: u8) {}

#[unsafe(no_mangle)]
extern "C" fn sys_exit(status: i32) -> ! {
    sys::exit(status as i64)
}

/// A panic (with panic = "abort", after std said it on stderr), or
/// process::abort: the program ends.
#[unsafe(no_mangle)]
extern "C" fn sys_abort() -> ! {
    sys::exit(134)
}

#[unsafe(no_mangle)]
extern "C" fn sys_get_errno() -> i32 {
    0 // (every call here returns its error)
}

#[unsafe(no_mangle)]
extern "C" fn sys_errno() -> i32 {
    0
}

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_read_entropy(buf: *mut u8, len: usize, _flags: u32) -> isize {
    let mut i = 0;
    while i < len {
        let r = sys::random_u32().to_le_bytes();
        let n = (len - i).min(4);
        unsafe { core::ptr::copy_nonoverlapping(r.as_ptr(), buf.add(i), n) };
        i += n;
    }
    len as isize
}

// Hermit's older calls, and its semaphores: nothing in std uses them.
#[unsafe(no_mangle)]
extern "C" fn sys_sem_init(_s: *mut c_void, _p: i32, _v: u32) -> i32 {
    -ENOSYS
}
#[unsafe(no_mangle)]
extern "C" fn sys_sem_destroy(_s: *mut c_void) -> i32 {
    -ENOSYS
}
#[unsafe(no_mangle)]
extern "C" fn sys_sem_post(_s: *mut c_void) -> i32 {
    -ENOSYS
}
#[unsafe(no_mangle)]
extern "C" fn sys_sem_trywait(_s: *mut c_void) -> i32 {
    -ENOSYS
}
#[unsafe(no_mangle)]
extern "C" fn sys_sem_timedwait(_s: *mut c_void, _t: *const Timespec) -> i32 {
    -ENOSYS
}
#[unsafe(no_mangle)]
extern "C" fn sys_notify(_id: usize, _count: i32) -> i32 {
    -ENOSYS
}
#[unsafe(no_mangle)]
extern "C" fn sys_add_queue(_id: usize, _t: i64) -> i32 {
    -ENOSYS
}
#[unsafe(no_mangle)]
extern "C" fn sys_wait(_id: usize) -> i32 {
    -ENOSYS
}
#[unsafe(no_mangle)]
extern "C" fn sys_init_queue(_id: usize) -> i32 {
    -ENOSYS
}
#[unsafe(no_mangle)]
extern "C" fn sys_destroy_queue(_id: usize) -> i32 {
    -ENOSYS
}
#[unsafe(no_mangle)]
extern "C" fn sys_block_current_task() {}
#[unsafe(no_mangle)]
extern "C" fn sys_block_current_task_with_timeout(_t: u64) {}
#[unsafe(no_mangle)]
extern "C" fn sys_wakeup_taskt(_tid: u32) {}

// ---- files ------------------------------------------------------------

enum Open {
    File { files: Files, path: String, data: Vec<u8>, pos: usize, write: bool, append: bool, dirty: bool },
    Dir { recs: Vec<u8>, read: bool },
    Socket(Sock),
}

struct Fds {
    open: Vec<Option<Box<Open>>>, // fd 3 is open[0]
}

static FDS: SpinLock<Fds> = SpinLock::new(Fds { open: Vec::new() });
static BOOT_VOL: AtomicU32 = AtomicU32::new(u32::MAX);

const FD_FIRST: i32 = 3;
const FDS_MAX: usize = 1024;

fn insert(o: Open) -> i32 {
    let mut fds = FDS.lock(); // (the heap never takes it: allocating under it is safe)
    if let Some(i) = fds.open.iter().position(|s| s.is_none()) {
        fds.open[i] = Some(Box::new(o));
        return FD_FIRST + i as i32;
    }
    if fds.open.len() >= FDS_MAX {
        return -EMFILE;
    }
    fds.open.push(Some(Box::new(o)));
    FD_FIRST + fds.open.len() as i32 - 1
}

/// `f` on what fd is open as -> its result, or -EBADF.
fn with_fd<R>(fd: i32, bad: R, f: impl FnOnce(&mut Open) -> R) -> R {
    let mut fds = FDS.lock();
    match fd.checked_sub(FD_FIRST).and_then(|i| fds.open.get_mut(i as usize)) {
        Some(Some(o)) => f(o),
        _ => bad,
    }
}

fn boot_volume(files: Files) -> u32 {
    let v = BOOT_VOL.load(Ordering::Relaxed);
    if v != u32::MAX {
        return v;
    }
    let v = files
        .volumes()
        .ok()
        .and_then(|vols| vols.iter().find(|v| v.flags & files::VOL_BOOT != 0).map(|v| v.index))
        .unwrap_or(0);
    BOOT_VOL.store(v, Ordering::Relaxed);
    v
}

/// A path as std gave it -> the files, and the path as they take it:
/// "vol<n>:/a/b", its "." and ".." worked out.
fn resolve(name: *const c_char) -> Result<(Files, String), i32> {
    if name.is_null() {
        return Err(EINVAL);
    }
    let s = unsafe { CStr::from_ptr(name) }.to_str().map_err(|_| EINVAL)?;
    let files = Files::get().map_err(errno)?;
    let (vol, rest) = match s.split_once(':') {
        Some((v, rest)) if v.len() > 3 && v.starts_with("vol") && v[3..].bytes().all(|b| b.is_ascii_digit()) => {
            (v[3..].parse::<u32>().map_err(|_| ENOENT)?, rest)
        }
        _ => (boot_volume(files), s),
    };
    let mut parts: Vec<&str> = Vec::new();
    for p in rest.split('/') {
        match p {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            p => parts.push(p),
        }
    }
    let mut out = alloc::format!("vol{}:", vol);
    if parts.is_empty() {
        out.push('/');
    }
    for p in parts {
        out.push('/');
        out.push_str(p);
    }
    if out.len() >= 256 {
        return Err(ENAMETOOLONG);
    }
    Ok((files, out))
}

fn is_root(path: &str) -> bool {
    path.ends_with(":/")
}

/// Whether a write there would be taken: the volume made writable, or
/// something in the boot volume's /Home (as the kernel judges it).
fn volume_writable(files: Files, path: &str) -> bool {
    let Some((vol, rest)) = path.split_once(':') else { return true };
    let n: Option<u32> = vol.strip_prefix("vol").and_then(|n| n.parse().ok());
    let in_home = rest.len() > 6 && rest[..6].eq_ignore_ascii_case("/home/");
    match (n, files.volumes()) {
        (Some(n), Ok(vols)) => vols.iter().any(|v| {
            v.index == n && (v.flags & files::VOL_WRITABLE != 0 || (in_home && v.flags & files::VOL_BOOT != 0))
        }),
        _ => true, // (the write says, then)
    }
}

/// What a folder's listing says of one thing in it.
fn lookup(files: Files, path: &str) -> Result<files::DirEntry, i32> {
    let (parent, name) = path.rsplit_once('/').ok_or(ENOENT)?;
    let parent = if parent.ends_with(':') { alloc::format!("{}/", parent) } else { String::from(parent) };
    let list = files.list(&parent).map_err(errno)?;
    list.into_iter().find(|e| e.name.eq_ignore_ascii_case(name)).ok_or(ENOENT)
}

fn dir_records(list: &[files::DirEntry]) -> Vec<u8> {
    let rec = core::mem::size_of::<Dirent64>();
    let mut out = alloc::vec![0u8; rec * list.len()];
    for (i, e) in list.iter().enumerate() {
        let mut d = Dirent64 {
            d_ino: i as u64 + 1,
            d_off: ((i + 1) * rec) as i64,
            d_reclen: rec as u16,
            d_type: if e.is_dir() { DT_DIR } else { DT_REG },
            d_name: [0; 256],
        };
        let n = e.name.len().min(255);
        d.d_name[..n].copy_from_slice(&e.name.as_bytes()[..n]);
        unsafe {
            core::ptr::copy_nonoverlapping(&d as *const Dirent64 as *const u8, out.as_mut_ptr().add(i * rec), rec)
        };
    }
    out
}

fn opendir(files: Files, path: &str) -> i32 {
    match files.list(path) {
        Ok(list) => insert(Open::Dir { recs: dir_records(&list), read: false }),
        Err(Error::NOFILE) => match lookup(files, path) {
            Ok(_) => -ENOTDIR, // a file
            Err(e) => -e,
        },
        Err(e) => -errno(e),
    }
}

#[unsafe(no_mangle)]
extern "C" fn sys_open(name: *const c_char, flags: i32, _mode: i32) -> i32 {
    let (files, path) = match resolve(name) {
        Ok(r) => r,
        Err(e) => return -e,
    };
    if flags & O_DIRECTORY != 0 || is_root(&path) {
        return opendir(files, &path);
    }
    let write = flags & O_ACCMODE != 0;
    if write && !volume_writable(files, &path) {
        return -EROFS;
    }
    let (mut data, mut made) = match files.read(&path) {
        Ok(d) if flags & O_CREAT != 0 && flags & O_EXCL != 0 => {
            drop(d);
            return -EEXIST;
        }
        Ok(d) => (d, false),
        Err(Error::NOFILE) if flags & O_CREAT != 0 => {
            if lookup(files, &path).is_ok_and(|e| e.is_dir()) {
                return -EISDIR;
            }
            (Vec::new(), true)
        }
        Err(Error::NOFILE) => {
            return match lookup(files, &path) {
                Ok(e) if e.is_dir() => opendir(files, &path), // (std opens folders to stat them)
                _ => -ENOENT,
            };
        }
        Err(e) => return -errno(e),
    };
    if write && flags & O_TRUNC != 0 && !data.is_empty() {
        data.clear();
        made = true;
    }
    if made {
        if let Err(e) = files.write(&path, &data) {
            return -errno(e);
        }
    }
    insert(Open::File { files, path, data, pos: 0, write, append: flags & O_APPEND != 0, dirty: false })
}

#[unsafe(no_mangle)]
extern "C" fn sys_opendir(name: *const c_char) -> i32 {
    match resolve(name) {
        Ok((files, path)) => opendir(files, &path),
        Err(e) => -e,
    }
}

#[unsafe(no_mangle)]
extern "C" fn sys_close(fd: i32) -> i32 {
    if (0..FD_FIRST).contains(&fd) {
        return 0;
    }
    let o = {
        let mut fds = FDS.lock();
        match fd.checked_sub(FD_FIRST).and_then(|i| fds.open.get_mut(i as usize)) {
            Some(slot) => slot.take(),
            None => None,
        }
    };
    let Some(o) = o else { return -EBADF };
    if let Open::Socket(s) = &*o {
        ring::close(s.h);
        return 0;
    }
    if let Open::File { files, path, data, dirty: true, .. } = &*o {
        if let Err(e) = files.write(path, data) {
            crate::println!("axiom: {} was not written: {}", path, e);
            return -errno(e);
        }
    }
    0 // (dropped here, out of the lock)
}

/// A socket's alone: another handle to the kernel's socket.
#[unsafe(no_mangle)]
extern "C" fn sys_dup(fd: i32) -> i32 {
    let made = match with_sock(fd, |s| {
        let mut d = Sock::new(s.v6);
        d.bound = s.bound;
        d.listening = s.listening;
        d.nonblocking = s.nonblocking;
        d.recv_timeout = s.recv_timeout;
        d.send_timeout = s.send_timeout;
        d.nodelay = s.nodelay;
        (s.h, d)
    }) {
        Ok(m) => m,
        Err(ENOTSOCK) => return -ENOSYS,
        Err(e) => return -e,
    };
    let (h, mut d) = made;
    if h != 0 {
        match ksock(h).try_clone() {
            Ok(c) => d.h = c.into_handle(),
            Err(e) => return -sock_errno(h, e),
        }
    }
    let h = d.h;
    let fd = insert(Open::Socket(d));
    if fd < 0 {
        ring::close(h);
    }
    fd
}

#[unsafe(no_mangle)]
extern "C" fn sys_fcntl(_fd: i32, _cmd: i32, _arg: i32) -> i32 {
    0
}

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_read(fd: i32, buf: *mut u8, len: usize) -> isize {
    match fd {
        0 => return 0, // stdin: nothing
        1 | 2 => return -EBADF as isize,
        _ if is_socket(fd) => return unsafe { sock_recv(fd, buf, len, 0) },
        _ => {}
    }
    with_fd(fd, -EBADF as isize, |o| match o {
        Open::File { data, pos, .. } => {
            let n = data.len().saturating_sub(*pos).min(len);
            unsafe { core::ptr::copy_nonoverlapping(data.as_ptr().add(*pos), buf, n) };
            *pos += n;
            n as isize
        }
        Open::Dir { .. } => -EISDIR as isize,
        Open::Socket(_) => -EBADF as isize,
    })
}

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_write(fd: i32, buf: *const u8, len: usize) -> isize {
    match fd {
        1 | 2 => {
            if len > 0 {
                console::write(unsafe { core::slice::from_raw_parts(buf, len) });
            }
            return len as isize;
        }
        0 => return -EBADF as isize,
        _ if is_socket(fd) => return unsafe { sock_send(fd, buf, len) },
        _ => {}
    }
    with_fd(fd, -EBADF as isize, |o| match o {
        Open::File { data, pos, write: true, append, dirty, .. } => {
            if *append {
                *pos = data.len();
            }
            if data.len() < *pos {
                data.resize(*pos, 0);
            }
            let src = unsafe { core::slice::from_raw_parts(buf, len) };
            let over = (data.len() - *pos).min(len);
            data[*pos..*pos + over].copy_from_slice(&src[..over]);
            data.extend_from_slice(&src[over..]);
            *pos += len;
            *dirty = true;
            len as isize
        }
        _ => -EBADF as isize,
    })
}

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_readv(fd: i32, iov: *const Iovec, n: usize) -> isize {
    let mut total = 0isize;
    for i in 0..n {
        let v = unsafe { &*iov.add(i) };
        let r = unsafe { sys_read(fd, v.base, v.len) };
        if r < 0 {
            return if total > 0 { total } else { r };
        }
        total += r;
        if (r as usize) < v.len {
            break;
        }
    }
    total
}

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_writev(fd: i32, iov: *const Iovec, n: usize) -> isize {
    let mut total = 0isize;
    for i in 0..n {
        let v = unsafe { &*iov.add(i) };
        let r = unsafe { sys_write(fd, v.base, v.len) };
        if r < 0 {
            return if total > 0 { total } else { r };
        }
        total += r;
    }
    total
}

#[unsafe(no_mangle)]
extern "C" fn sys_lseek(fd: i32, offset: isize, whence: i32) -> isize {
    if (0..FD_FIRST).contains(&fd) {
        return -ESPIPE as isize;
    }
    with_fd(fd, -EBADF as isize, |o| match o {
        Open::File { data, pos, .. } => {
            let base = match whence {
                SEEK_SET => 0,
                SEEK_CUR => *pos as isize,
                SEEK_END => data.len() as isize,
                _ => return -EINVAL as isize,
            };
            match base.checked_add(offset) {
                Some(p) if p >= 0 => {
                    *pos = p as usize;
                    p
                }
                _ => -EINVAL as isize,
            }
        }
        Open::Dir { .. } | Open::Socket(_) => -ESPIPE as isize,
    })
}

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_getdents64(fd: i32, dirp: *mut Dirent64, count: usize) -> i64 {
    with_fd(fd, -EBADF as i64, |o| match o {
        Open::Dir { recs, read } => {
            if *read {
                return 0;
            }
            if recs.len() > count {
                return -EINVAL as i64; // (std makes room, and asks again)
            }
            unsafe { core::ptr::copy_nonoverlapping(recs.as_ptr(), dirp as *mut u8, recs.len()) };
            *read = true;
            recs.len() as i64
        }
        Open::File { .. } | Open::Socket(_) => -ENOTDIR as i64,
    })
}

/// FAT's time (as the machine's clock keeps it, taken as UTC) -> seconds
/// since 1970.
fn unix_time(w: &files::Written) -> i64 {
    if w.year == 0 {
        return 0;
    }
    let (y, m, d) = (w.year as i64, w.month.clamp(1, 12) as i64, w.day.clamp(1, 31) as i64);
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = if m > 2 { m - 3 } else { m + 9 };
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    days * 86400 + w.hour as i64 * 3600 + w.min as i64 * 60 + w.sec as i64
}

fn stat_of(st: *mut Stat, mode: u32, size: u64, written: Option<&files::Written>) -> i32 {
    if st.is_null() {
        return -EINVAL;
    }
    let t = Timespec { tv_sec: written.map_or(0, unix_time), tv_nsec: 0 };
    let s = Stat {
        st_nlink: 1,
        st_mode: mode,
        st_size: size as i64,
        st_blksize: 4096,
        st_blocks: size.div_ceil(512) as i64,
        st_atim: t,
        st_mtim: t,
        st_ctim: t,
        ..Stat::default()
    };
    unsafe { st.write(s) };
    0
}

#[unsafe(no_mangle)]
extern "C" fn sys_stat(name: *const c_char, st: *mut Stat) -> i32 {
    let (files, path) = match resolve(name) {
        Ok(r) => r,
        Err(e) => return -e,
    };
    if is_root(&path) {
        return match files.list(&path) {
            Ok(_) => stat_of(st, S_IFDIR | 0o755, 0, None),
            Err(e) => -errno(e),
        };
    }
    match lookup(files, &path) {
        Ok(e) => {
            let ro = e.attr & files::ATTR_READONLY != 0;
            let mode = if e.is_dir() { S_IFDIR | 0o755 } else { S_IFREG | if ro { 0o444 } else { 0o644 } };
            stat_of(st, mode, e.size, Some(&e.written))
        }
        Err(e) => -e,
    }
}

#[unsafe(no_mangle)]
extern "C" fn sys_lstat(name: *const c_char, st: *mut Stat) -> i32 {
    sys_stat(name, st)
}

#[unsafe(no_mangle)]
extern "C" fn sys_fstat(fd: i32, st: *mut Stat) -> i32 {
    if (0..FD_FIRST).contains(&fd) {
        return stat_of(st, S_IFCHR | 0o620, 0, None);
    }
    with_fd(fd, -EBADF, |o| match o {
        Open::File { data, write, .. } => {
            stat_of(st, S_IFREG | if *write { 0o644 } else { 0o444 }, data.len() as u64, None)
        }
        Open::Dir { .. } => stat_of(st, S_IFDIR | 0o755, 0, None),
        Open::Socket(_) => stat_of(st, S_IFSOCK | 0o777, 0, None),
    })
}

#[unsafe(no_mangle)]
extern "C" fn sys_mkdir(name: *const c_char, _mode: u32) -> i32 {
    match resolve(name) {
        Ok((files, path)) => files.mkdir(&path).map_or_else(|e| -errno(e), |_| 0),
        Err(e) => -e,
    }
}

#[unsafe(no_mangle)]
extern "C" fn sys_unlink(name: *const c_char) -> i32 {
    match resolve(name) {
        Ok((files, path)) => {
            if lookup(files, &path).is_ok_and(|e| e.is_dir()) {
                return -EISDIR;
            }
            files.remove(&path).map_or_else(|e| -errno(e), |_| 0)
        }
        Err(e) => -e,
    }
}

#[unsafe(no_mangle)]
extern "C" fn sys_rmdir(name: *const c_char) -> i32 {
    match resolve(name) {
        Ok((files, path)) => match lookup(files, &path) {
            Ok(e) if !e.is_dir() => -ENOTDIR,
            Ok(_) => files.remove(&path).map_or_else(|e| -errno(e), |_| 0),
            Err(e) => -e,
        },
        Err(e) => -e,
    }
}

// ---- the network ------------------------------------------------------

const EPIPE: i32 = 32;
const ENOTSOCK: i32 = 88;
const ENOPROTOOPT: i32 = 92;
const EPROTONOSUPPORT: i32 = 93;
const EOPNOTSUPP: i32 = 95;
const EAFNOSUPPORT: i32 = 97;
const EADDRINUSE: i32 = 98;
const EADDRNOTAVAIL: i32 = 99;
const ENETDOWN: i32 = 100;
const ENETUNREACH: i32 = 101;
const ECONNRESET: i32 = 104;
const ENOBUFS: i32 = 105;
const EISCONN: i32 = 106;
const ENOTCONN: i32 = 107;
const ECONNREFUSED: i32 = 111;
const EHOSTUNREACH: i32 = 113;
const EALREADY: i32 = 114;
const EINPROGRESS: i32 = 115;

const AF_INET: i32 = 3;
const AF_INET6: i32 = 1;
const SOCK_STREAM: i32 = 1;
const SOCK_NONBLOCK: i32 = 0o4000;
const SOCK_CLOEXEC: i32 = 0o40000;
const IPPROTO_IP: i32 = 0;
const IPPROTO_TCP: i32 = 6;
const IPPROTO_IPV6: i32 = 41;
const SOL_SOCKET: i32 = 4095;
const SO_REUSEADDR: i32 = 0x0004;
const SO_KEEPALIVE: i32 = 0x0008;
const SO_BROADCAST: i32 = 0x0020;
const SO_LINGER: i32 = 0x0080;
const SO_SNDBUF: i32 = 0x1001;
const SO_RCVBUF: i32 = 0x1002;
const SO_SNDTIMEO: i32 = 0x1005;
const SO_RCVTIMEO: i32 = 0x1006;
const SO_ERROR: i32 = 0x1007;
const TCP_NODELAY: i32 = 1;
const IP_TTL: i32 = 2;
const IPV6_V6ONLY: i32 = 27;
const MSG_PEEK: i32 = 1;
const SHUT_RD: i32 = 0;
const SHUT_WR: i32 = 1;
const SHUT_RDWR: i32 = 2;
const FIONBIO: i32 = 0x8008667eu32 as i32;
const POLLIN: i16 = 0x1;
const POLLOUT: i16 = 0x4;
const POLLERR: i16 = 0x8;
const POLLHUP: i16 = 0x10;
const POLLNVAL: i16 = 0x20;
const POLLRDNORM: i16 = 0x40;
const POLLWRNORM: i16 = 0x100;
const EAI_AGAIN: i32 = 2;
const EAI_FAMILY: i32 = 5;
const EAI_NONAME: i32 = 8;
const EAI_SERVICE: i32 = 9;
const S_IFSOCK: u32 = 0o14_0000;

const SOCKADDR_IN: u32 = 16;
const SOCKADDR_IN6: u32 = 28;
/// Names looked up, kept for what is connected to by address.
const NAMES_MAX: usize = 16;

/// A TCP socket as std has it: made, bound, then connected (or
/// connecting), or listening; or taken from a listener.
struct Sock {
    v6: bool,
    /// The kernel's socket, once it connects or listens.
    h: Handle,
    bound: Option<(IpAddr, u16)>,
    listening: bool,
    /// Connecting: until it is seen open (or failed).
    connecting: bool,
    nonblocking: bool,
    rd_shut: bool,
    recv_timeout: Option<Duration>,
    send_timeout: Option<Duration>,
    /// SO_ERROR's: what a connection that failed said, not yet asked for.
    error: i32,
    /// What MSG_PEEK read, for the next recv.
    peeked: Vec<u8>,
    /// Options kept, and said back: they change nothing here.
    keepalive: bool,
    nodelay: bool,
    reuseaddr: bool,
    linger: Option<i32>,
    ttl: i32,
    v6only: bool,
}

impl Sock {
    fn new(v6: bool) -> Sock {
        Sock {
            v6,
            h: 0,
            bound: None,
            listening: false,
            connecting: false,
            nonblocking: false,
            rd_shut: false,
            recv_timeout: None,
            send_timeout: None,
            error: 0,
            peeked: Vec::new(),
            keepalive: false,
            nodelay: false,
            reuseaddr: false,
            linger: None,
            ttl: 64,
            v6only: false,
        }
    }
}

#[repr(C)]
struct Addrinfo {
    ai_flags: i32,
    ai_family: i32,
    ai_socktype: i32,
    ai_protocol: i32,
    ai_addrlen: u32,
    ai_canonname: *mut c_char,
    ai_addr: *mut c_void,
    ai_next: *mut Addrinfo,
}

/// One answer: its addrinfo, and the address it points at.
#[repr(C)]
struct Answer {
    ai: Addrinfo,
    sa: [u8; SOCKADDR_IN6 as usize],
}

#[repr(C)]
struct Pollfd {
    fd: i32,
    events: i16,
    revents: i16,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct Timeval {
    tv_sec: i64,
    tv_usec: i32,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct Linger {
    l_onoff: i32,
    l_linger: i32,
}

static NAMES: SpinLock<Vec<([u8; 16], String)>> = SpinLock::new(Vec::new());

/// A name looked up, and the address it had.
fn remember(addr: [u8; 16], name: &str) {
    let mut names = NAMES.lock();
    names.retain(|(a, _)| *a != addr);
    if names.len() >= NAMES_MAX {
        names.remove(0);
    }
    names.push((addr, String::from(name)));
}

/// The host to give the kernel for an address: the name it was looked up
/// by (which a capability to that name reaches), or the address as text.
fn host_for(ip: IpAddr, text: &mut [u8; 64]) -> String {
    let addr = net::kernel_addr(ip);
    if let Some((_, n)) = NAMES.lock().iter().rev().find(|(a, _)| *a == addr) {
        return n.clone();
    }
    String::from(net::host_text(ip, text))
}

/// A handle to the kernel's socket, not closed when this goes.
fn ksock(h: Handle) -> core::mem::ManuallyDrop<net::Socket> {
    core::mem::ManuallyDrop::new(net::Socket::from_handle(h))
}

fn why_errno(why: u32) -> i32 {
    match why {
        NETW_REFUSED => ECONNREFUSED,
        NETW_RESET => ECONNRESET,
        NETW_TIMEOUT => ETIMEDOUT,
        NETW_DOWN => ENETDOWN,
        NETW_NOROUTE => ENETUNREACH,
        NETW_INUSE => EADDRINUSE,
        NETW_IDENTITY => EINVAL,
        NETW_NOSERVER..=NETW_NOANSWER => EHOSTUNREACH,
        _ => EIO,
    }
}

/// What the kernel refused a socket's request with -> the errno: E_NET by
/// what its status says.
fn sock_errno(h: Handle, e: Error) -> i32 {
    match e {
        Error::NET => ksock(h).status().map_or(EIO, |s| why_errno(s.why)),
        Error::PEER => EPIPE,
        Error::ARG => EINVAL,
        Error::RIGHTS | Error::ABSENT => EACCES,
        Error::FULL => ENOBUFS,
        Error::NOMEM => ENOMEM,
        Error::BADH | Error::TYPE => EBADF,
        Error::TIMEOUT => EAGAIN,
        _ => EIO,
    }
}

/// `f` on the socket fd is -> its result; EBADF, or ENOTSOCK for a file.
fn with_sock<R>(fd: i32, f: impl FnOnce(&mut Sock) -> R) -> Result<R, i32> {
    with_fd(fd, Err(EBADF), |o| match o {
        Open::Socket(s) => Ok(f(s)),
        _ => Err(ENOTSOCK),
    })
}

fn is_socket(fd: i32) -> bool {
    with_sock(fd, |_| ()).is_ok()
}

fn deadline(t: Option<Duration>) -> Option<time::Instant> {
    t.map(|d| time::Instant::now() + d)
}

/// A sockaddr_in or sockaddr_in6 -> the address and port.
unsafe fn sockaddr_from(name: *const c_void, len: u32) -> Result<(IpAddr, u16), i32> {
    if name.is_null() || len < 2 {
        return Err(EINVAL);
    }
    let p = name as *const u8;
    let b = |i: usize| unsafe { p.add(i).read() };
    let port = u16::from_be_bytes([b(2), b(3)]);
    match b(1) as i32 {
        AF_INET if len >= SOCKADDR_IN => Ok((IpAddr::V4(Ipv4Addr::new(b(4), b(5), b(6), b(7))), port)),
        AF_INET6 if len >= SOCKADDR_IN6 => {
            let mut a = [0u8; 16];
            for (i, x) in a.iter_mut().enumerate() {
                *x = b(8 + i);
            }
            Ok((IpAddr::V6(Ipv6Addr::from(a)), port))
        }
        AF_INET | AF_INET6 => Err(EINVAL),
        _ => Err(EAFNOSUPPORT),
    }
}

/// An address as a sockaddr: sockaddr_in for IPv4 on an IPv4 socket, else
/// sockaddr_in6 (IPv4 there as ::ffff:a.b.c.d) -> its bytes.
fn sockaddr_of(ip: IpAddr, port: u16, v6: bool) -> ([u8; SOCKADDR_IN6 as usize], u32) {
    let mut sa = [0u8; SOCKADDR_IN6 as usize];
    sa[2..4].copy_from_slice(&port.to_be_bytes());
    match ip {
        IpAddr::V4(v4) if !v6 => {
            sa[0] = SOCKADDR_IN as u8;
            sa[1] = AF_INET as u8;
            sa[4..8].copy_from_slice(&v4.octets());
            (sa, SOCKADDR_IN)
        }
        _ => {
            sa[0] = SOCKADDR_IN6 as u8;
            sa[1] = AF_INET6 as u8;
            sa[8..24].copy_from_slice(&net::kernel_addr(ip));
            (sa, SOCKADDR_IN6)
        }
    }
}

/// It into `out`, `*len` bytes of room; `*len` then its size.
unsafe fn sockaddr_out(ip: IpAddr, port: u16, v6: bool, out: *mut c_void, len: *mut u32) -> i32 {
    if out.is_null() || len.is_null() {
        return if out.is_null() && len.is_null() { 0 } else { -EINVAL };
    }
    let (sa, n) = sockaddr_of(ip, port, v6);
    let room = unsafe { len.read() }.min(n) as usize;
    unsafe {
        core::ptr::copy_nonoverlapping(sa.as_ptr(), out as *mut u8, room);
        len.write(n);
    }
    0
}

fn unspecified(v6: bool) -> IpAddr {
    if v6 { IpAddr::V6(Ipv6Addr::UNSPECIFIED) } else { IpAddr::V4(Ipv4Addr::UNSPECIFIED) }
}

#[unsafe(no_mangle)]
extern "C" fn sys_socket(domain: i32, kind: i32, protocol: i32) -> i32 {
    let v6 = match domain {
        AF_INET => false,
        AF_INET6 => true,
        _ => return -EAFNOSUPPORT,
    };
    // TCP alone: the kernel has no datagrams for programs
    if kind & !(SOCK_NONBLOCK | SOCK_CLOEXEC) != SOCK_STREAM || !matches!(protocol, 0 | IPPROTO_TCP) {
        return -EPROTONOSUPPORT;
    }
    let mut s = Sock::new(v6);
    s.nonblocking = kind & SOCK_NONBLOCK != 0;
    insert(Open::Socket(s))
}

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_bind(fd: i32, name: *const c_void, len: u32) -> i32 {
    let at = match unsafe { sockaddr_from(name, len) } {
        Ok(a) => a,
        Err(e) => return -e,
    };
    if at.0.is_loopback() {
        return -EADDRNOTAVAIL; // (no loopback here: a port is listened on everywhere)
    }
    match with_sock(fd, |s| {
        if s.h != 0 || s.bound.is_some() {
            return -EINVAL;
        }
        s.bound = Some(at);
        0
    }) {
        Ok(r) => r,
        Err(e) => -e,
    }
}

#[unsafe(no_mangle)]
extern "C" fn sys_listen(fd: i32, _backlog: i32) -> i32 {
    let port = match with_sock(fd, |s| {
        if s.listening {
            Err(0)
        } else if s.h != 0 {
            Err(EINVAL)
        } else {
            Ok(s.bound.map_or(0, |b| b.1))
        }
    }) {
        Ok(Ok(p)) => p,
        Ok(Err(0)) => return 0,
        Ok(Err(e)) | Err(e) => return -e,
    };
    let Ok(n) = Net::get() else { return -EACCES };
    let l = match n.listen(port) {
        Ok(l) => l,
        Err(e) => return -sock_errno(0, e),
    };
    if let Err(e) = l.wait_send(None) {
        return -sock_errno(l.handle(), e);
    }
    match l.status() {
        Ok(st) if st.state == SKS_LISTEN => {}
        Ok(st) => return -why_errno(st.why),
        Err(e) => return -sock_errno(l.handle(), e),
    }
    let port = l.addrs().map_or(port, |a| a.port);
    let h = l.into_handle();
    match with_sock(fd, |s| {
        s.h = h;
        s.listening = true;
        let ip = s.bound.map_or(unspecified(s.v6), |b| b.0);
        s.bound = Some((ip, port));
    }) {
        Ok(()) => 0,
        Err(e) => {
            ring::close(h);
            -e
        }
    }
}

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_connect(fd: i32, name: *const c_void, len: u32) -> i32 {
    let (ip, port) = match unsafe { sockaddr_from(name, len) } {
        Ok(a) => a,
        Err(e) => return -e,
    };
    if ip.is_loopback() {
        return -ENETUNREACH; // (no loopback here)
    }
    let (nonblocking, timeout) = match with_sock(fd, |s| {
        if s.listening {
            Err(EINVAL)
        } else if s.connecting {
            Err(EALREADY)
        } else if s.h != 0 {
            Err(EISCONN)
        } else {
            Ok((s.nonblocking, s.send_timeout))
        }
    }) {
        Ok(Ok(r)) => r,
        Ok(Err(e)) | Err(e) => return -e,
    };
    let Ok(n) = Net::get() else { return -EACCES };
    let mut text = [0u8; 64];
    let host = host_for(ip, &mut text);
    let c = match n.connect(&host, port, net::Tls::No) {
        Ok(c) => c,
        Err(e) => return -sock_errno(0, e),
    };
    let h = c.into_handle();
    if let Err(e) = with_sock(fd, |s| {
        s.h = h;
        s.connecting = true;
    }) {
        ring::close(h);
        return -e;
    }
    if nonblocking {
        return -EINPROGRESS;
    }
    let k = ksock(h);
    if let Err(e) = k.wait_send(deadline(timeout)) {
        return -if e == Error::TIMEOUT { ETIMEDOUT } else { sock_errno(h, e) };
    }
    let r = match k.status() {
        Ok(st) if st.failed() => -why_errno(st.why),
        Ok(_) => 0,
        Err(e) => -sock_errno(h, e),
    };
    let _ = with_sock(fd, |s| s.connecting = false);
    r
}

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_accept(fd: i32, addr: *mut c_void, alen: *mut u32) -> i32 {
    let (h, v6, nonblocking, timeout) = match with_sock(fd, |s| (s.h, s.v6, s.nonblocking, s.recv_timeout)) {
        Ok(r) => r,
        Err(e) => return -e,
    };
    if h == 0 || !matches!(with_sock(fd, |s| s.listening), Ok(true)) {
        return -EINVAL;
    }
    let k = ksock(h);
    let until = deadline(timeout);
    let c = loop {
        match k.accept() {
            Ok(c) => break c,
            Err(Error::EMPTY) if nonblocking => return -EAGAIN,
            Err(Error::EMPTY) => {
                if let Err(e) = k.wait_recv(until) {
                    return -sock_errno(h, e);
                }
            }
            Err(e) => return -sock_errno(h, e),
        }
    };
    let peer = c.addrs().unwrap_or_default();
    let r = unsafe { sockaddr_out(net::ip(peer.peer), peer.peer_port, v6, addr, alen) };
    if r < 0 {
        return r;
    }
    let mut s = Sock::new(v6);
    s.h = c.into_handle();
    let h = s.h;
    let fd = insert(Open::Socket(s));
    if fd < 0 {
        ring::close(h);
    }
    fd
}

/// Into `buf`: what was peeked first, then what came (waiting for it,
/// unless it does not block); 0 at the end. A peek keeps what it read for
/// the next recv, and past what was kept takes what has come since.
unsafe fn sock_recv(fd: i32, buf: *mut u8, len: usize, flags: i32) -> isize {
    if len == 0 {
        return 0;
    }
    let peek = flags & MSG_PEEK != 0;
    let snap = with_sock(fd, |s| {
        let kept = s.peeked.len().min(len);
        unsafe { core::ptr::copy_nonoverlapping(s.peeked.as_ptr(), buf, kept) };
        if !peek {
            s.peeked.drain(..kept);
        }
        if (kept > 0 && !peek) || kept == len || s.rd_shut {
            return Err(kept as isize);
        }
        if s.h == 0 || s.listening {
            return Err(if kept > 0 { kept as isize } else { -ENOTCONN as isize });
        }
        Ok((kept, s.h, s.nonblocking || kept > 0, s.recv_timeout))
    });
    let (kept, h, nonblocking, timeout) = match snap {
        Ok(Ok(r)) => r,
        Ok(Err(n)) => return n,
        Err(e) => return -e as isize,
    };
    let k = ksock(h);
    let out = unsafe { core::slice::from_raw_parts_mut(buf.add(kept), len - kept) };
    let until = deadline(timeout);
    let or_kept = |e: i32| if kept > 0 { kept as isize } else { -e as isize };
    loop {
        match k.recv(out) {
            Ok(n) => {
                if peek {
                    let _ = with_sock(fd, |s| s.peeked.extend_from_slice(&out[..n]));
                }
                return (kept + n) as isize;
            }
            Err(Error::PEER) => return kept as isize,
            Err(Error::EMPTY) if nonblocking => return or_kept(EAGAIN),
            Err(Error::EMPTY) => {
                if let Err(e) = k.wait_recv(until) {
                    return -sock_errno(h, e) as isize;
                }
            }
            Err(e) => return or_kept(sock_errno(h, e)),
        }
    }
}

/// From `buf`, as much as the kernel takes (waiting for room, unless it
/// does not block).
unsafe fn sock_send(fd: i32, buf: *const u8, len: usize) -> isize {
    let snap = with_sock(fd, |s| {
        if s.h == 0 || s.listening { Err(ENOTCONN) } else { Ok((s.h, s.nonblocking, s.send_timeout)) }
    });
    let (h, nonblocking, timeout) = match snap {
        Ok(Ok(r)) => r,
        Ok(Err(e)) | Err(e) => return -e as isize,
    };
    if len == 0 {
        return 0;
    }
    let k = ksock(h);
    let src = unsafe { core::slice::from_raw_parts(buf, len) };
    let until = deadline(timeout);
    loop {
        match k.send(src) {
            Ok(n) => return n as isize,
            Err(Error::FULL) if nonblocking => return -EAGAIN as isize,
            Err(Error::FULL) => {
                if let Err(e) = k.wait_send(until) {
                    return -sock_errno(h, e) as isize;
                }
            }
            Err(e) => return -sock_errno(h, e) as isize,
        }
    }
}

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_recv(fd: i32, buf: *mut u8, len: usize, flags: i32) -> isize {
    unsafe { sock_recv(fd, buf, len, flags) }
}

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_recvfrom(
    fd: i32,
    buf: *mut u8,
    len: usize,
    flags: i32,
    addr: *mut c_void,
    alen: *mut u32,
) -> isize {
    let n = unsafe { sock_recv(fd, buf, len, flags) };
    if n >= 0 && !addr.is_null() {
        let r = unsafe { sys_getpeername(fd, addr, alen) };
        if r < 0 {
            return r as isize;
        }
    }
    n
}

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_send(fd: i32, buf: *const c_void, len: usize, _flags: i32) -> isize {
    unsafe { sock_send(fd, buf as *const u8, len) }
}

/// TCP's: where to was said when it connected.
#[unsafe(no_mangle)]
unsafe extern "C" fn sys_sendto(
    fd: i32,
    buf: *const c_void,
    len: usize,
    _flags: i32,
    _to: *const c_void,
    _tolen: u32,
) -> isize {
    unsafe { sock_send(fd, buf as *const u8, len) }
}

#[unsafe(no_mangle)]
extern "C" fn sys_shutdown(fd: i32, how: i32) -> i32 {
    if !matches!(how, SHUT_RD | SHUT_WR | SHUT_RDWR) {
        return -EINVAL;
    }
    let h = match with_sock(fd, |s| {
        if how != SHUT_WR {
            s.rd_shut = true;
        }
        s.h
    }) {
        Ok(h) => h,
        Err(e) => return -e,
    };
    if h == 0 {
        return -ENOTCONN;
    }
    if how == SHUT_RD {
        return 0;
    }
    ksock(h).shut().map_or_else(|e| -sock_errno(h, e), |_| 0)
}

#[unsafe(no_mangle)]
extern "C" fn sys_shutdown_socket(fd: i32, how: i32) -> i32 {
    sys_shutdown(fd, how)
}

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_getpeername(fd: i32, addr: *mut c_void, alen: *mut u32) -> i32 {
    let (h, v6, listening) = match with_sock(fd, |s| (s.h, s.v6, s.listening)) {
        Ok(r) => r,
        Err(e) => return -e,
    };
    if h == 0 || listening {
        return -ENOTCONN;
    }
    match ksock(h).addrs() {
        Ok(a) => unsafe { sockaddr_out(net::ip(a.peer), a.peer_port, v6, addr, alen) },
        Err(e) => -sock_errno(h, e),
    }
}

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_getsockname(fd: i32, addr: *mut c_void, alen: *mut u32) -> i32 {
    let (h, v6, listening, bound) = match with_sock(fd, |s| (s.h, s.v6, s.listening, s.bound)) {
        Ok(r) => r,
        Err(e) => return -e,
    };
    // a listener: the address it was bound to, and its port
    let (ip, port) = if h == 0 || listening {
        bound.unwrap_or((unspecified(v6), 0))
    } else {
        match ksock(h).addrs() {
            Ok(a) => (net::ip(a.local), a.port),
            Err(e) => return -sock_errno(h, e),
        }
    };
    unsafe { sockaddr_out(ip, port, v6, addr, alen) }
}

/// A value of an option, as std reads them: an int, a timeval, a linger.
unsafe fn opt_out<T>(v: T, val: *mut c_void, len: *mut u32) -> i32 {
    let n = core::mem::size_of::<T>();
    if val.is_null() || len.is_null() || (unsafe { len.read() } as usize) < n {
        return -EINVAL;
    }
    unsafe {
        (val as *mut T).write_unaligned(v);
        len.write(n as u32);
    }
    0
}

unsafe fn opt_in<T: Copy>(val: *const c_void, len: u32) -> Result<T, i32> {
    if val.is_null() || (len as usize) < core::mem::size_of::<T>() {
        return Err(EINVAL);
    }
    Ok(unsafe { (val as *const T).read_unaligned() })
}

fn timeval_of(d: Option<Duration>) -> Timeval {
    d.map_or(Timeval { tv_sec: 0, tv_usec: 0 }, |d| Timeval {
        tv_sec: d.as_secs() as i64,
        tv_usec: d.subsec_micros() as i32,
    })
}

fn duration_of(t: Timeval) -> Option<Duration> {
    if t.tv_sec <= 0 && t.tv_usec <= 0 {
        return None;
    }
    Some(Duration::new(t.tv_sec.max(0) as u64, (t.tv_usec.clamp(0, 999_999) as u32) * 1000))
}

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_getsockopt(fd: i32, level: i32, opt: i32, val: *mut c_void, len: *mut u32) -> i32 {
    // a connection that failed while nobody waited: SO_ERROR says so
    if (level, opt) == (SOL_SOCKET, SO_ERROR) {
        if let Ok((h, true)) = with_sock(fd, |s| (s.h, s.connecting && s.error == 0)) {
            if let Ok(st) = ksock(h).status() {
                if st.failed() {
                    let _ = with_sock(fd, |s| s.error = why_errno(st.why));
                }
            }
        }
    }
    let r = with_sock(fd, |s| unsafe {
        match (level, opt) {
            (SOL_SOCKET, SO_ERROR) => opt_out(core::mem::take(&mut s.error), val, len),
            (SOL_SOCKET, SO_RCVTIMEO) => opt_out(timeval_of(s.recv_timeout), val, len),
            (SOL_SOCKET, SO_SNDTIMEO) => opt_out(timeval_of(s.send_timeout), val, len),
            (SOL_SOCKET, SO_KEEPALIVE) => opt_out(s.keepalive as i32, val, len),
            (SOL_SOCKET, SO_REUSEADDR) => opt_out(s.reuseaddr as i32, val, len),
            (SOL_SOCKET, SO_BROADCAST) => opt_out(0i32, val, len),
            (SOL_SOCKET, SO_SNDBUF | SO_RCVBUF) => opt_out(SK_BUF as i32, val, len),
            (SOL_SOCKET, SO_LINGER) => opt_out(
                Linger { l_onoff: s.linger.is_some() as i32, l_linger: s.linger.unwrap_or(0) },
                val,
                len,
            ),
            (IPPROTO_TCP, TCP_NODELAY) => opt_out(s.nodelay as i32, val, len),
            (IPPROTO_IP, IP_TTL) => opt_out(s.ttl, val, len),
            (IPPROTO_IPV6, IPV6_V6ONLY) => opt_out(s.v6only as i32, val, len),
            _ => -ENOPROTOOPT,
        }
    });
    r.unwrap_or_else(|e| -e)
}

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_setsockopt(fd: i32, level: i32, opt: i32, val: *const c_void, len: u32) -> i32 {
    let r = with_sock(fd, |s| unsafe {
        let int = || opt_in::<i32>(val, len);
        let set = match (level, opt) {
            (SOL_SOCKET, SO_RCVTIMEO) => opt_in::<Timeval>(val, len).map(|t| s.recv_timeout = duration_of(t)),
            (SOL_SOCKET, SO_SNDTIMEO) => opt_in::<Timeval>(val, len).map(|t| s.send_timeout = duration_of(t)),
            (SOL_SOCKET, SO_KEEPALIVE) => int().map(|v| s.keepalive = v != 0),
            (SOL_SOCKET, SO_REUSEADDR) => int().map(|v| s.reuseaddr = v != 0),
            (SOL_SOCKET, SO_SNDBUF | SO_RCVBUF) => int().map(|_| ()), // (64 KiB, the kernel's)
            (SOL_SOCKET, SO_BROADCAST) => int().and_then(|v| if v == 0 { Ok(()) } else { Err(EOPNOTSUPP) }),
            (SOL_SOCKET, SO_LINGER) => opt_in::<Linger>(val, len)
                .map(|l| s.linger = if l.l_onoff != 0 { Some(l.l_linger.max(0)) } else { None }),
            (IPPROTO_TCP, TCP_NODELAY) => int().map(|v| s.nodelay = v != 0), // (each send goes at once)
            (IPPROTO_IP, IP_TTL) => int().and_then(|v| if (1..=255).contains(&v) { s.ttl = v; Ok(()) } else { Err(EINVAL) }),
            (IPPROTO_IPV6, IPV6_V6ONLY) => int().map(|v| s.v6only = v != 0),
            _ => Err(ENOPROTOOPT),
        };
        set.map_or_else(|e| -e, |_| 0)
    });
    r.unwrap_or_else(|e| -e)
}

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_ioctl(fd: i32, cmd: i32, argp: *mut c_void) -> i32 {
    if cmd != FIONBIO {
        return -EINVAL;
    }
    let Ok(on) = (unsafe { opt_in::<i32>(argp, 4) }) else { return -EINVAL };
    with_sock(fd, |s| s.nonblocking = on != 0).map_or_else(|e| -e, |_| 0)
}

/// What a socket fd has for `events` now -> revents (0: wait), and what to
/// wait for if nothing: the kernel's socket, RO_WAIT's a0s.
fn poll_one(fd: i32, events: i16) -> (i16, Handle, [bool; 2]) {
    if (0..FD_FIRST).contains(&fd) {
        return (events & (POLLIN | POLLOUT | POLLRDNORM | POLLWRNORM), 0, [false; 2]);
    }
    let snap = with_fd(fd, None, |o| match o {
        Open::Socket(s) => Some(Ok((s.h, s.listening, s.connecting, !s.peeked.is_empty() || s.rd_shut))),
        _ => Some(Err(())),
    });
    let (h, listening, connecting, held) = match snap {
        None => return (POLLNVAL, 0, [false; 2]),
        Some(Err(())) => return (events & (POLLIN | POLLOUT | POLLRDNORM | POLLWRNORM), 0, [false; 2]),
        Some(Ok(s)) => s,
    };
    let want_in = events & (POLLIN | POLLRDNORM) != 0;
    let want_out = events & (POLLOUT | POLLWRNORM) != 0;
    if h == 0 {
        return (POLLHUP | (events & (POLLOUT | POLLWRNORM)), 0, [false; 2]); // (not connected)
    }
    let st = match ksock(h).status() {
        Ok(st) => st,
        Err(_) => return (POLLNVAL, 0, [false; 2]),
    };
    let mut r = 0;
    if st.failed() {
        r |= POLLERR | POLLHUP;
        if connecting {
            let _ = with_sock(fd, |s| {
                if s.error == 0 {
                    s.error = why_errno(st.why);
                }
                s.connecting = false;
            });
        }
    }
    if want_in && (st.can_recv || held) {
        r |= events & (POLLIN | POLLRDNORM);
    }
    if want_out && st.can_send && !listening {
        r |= events & (POLLOUT | POLLWRNORM);
        if connecting && !st.failed() {
            let _ = with_sock(fd, |s| s.connecting = false);
        }
    }
    (r, h, [want_in && !st.can_recv, want_out && !st.can_send])
}

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_poll(fds: *mut c_void, n: usize, timeout: i32) -> i32 {
    let fds = if n == 0 { &mut [][..] } else { unsafe { core::slice::from_raw_parts_mut(fds as *mut Pollfd, n) } };
    let until = (timeout >= 0).then(|| time::Instant::now() + Duration::from_millis(timeout as u64));
    loop {
        let mut ready = 0;
        let mut waits: Vec<Entry> = Vec::new();
        for p in fds.iter_mut() {
            p.revents = 0;
            if p.fd < 0 {
                continue;
            }
            let (r, h, wait) = poll_one(p.fd, p.events);
            p.revents = r;
            if r != 0 {
                ready += 1;
            } else {
                for (a0, w) in wait.iter().enumerate() {
                    if *w {
                        let mut e = Entry::new(RO_WAIT, h);
                        e.a0 = a0 as u64;
                        waits.push(e);
                    }
                }
            }
        }
        if ready > 0 || timeout == 0 {
            return ready;
        }
        if until.is_some_and(|t| time::Instant::now() >= t) {
            return 0;
        }
        let at = until.map_or(0, |t| t.tsc().max(1));
        if waits.is_empty() || waits.len() > ring::FIRST_MAX {
            // nothing it could wait on, or more than a ring holds: a while
            let step = time::Instant::now() + Duration::from_millis(10);
            time::sleep_until(until.map_or(step, |t| if t.tsc() < step.tsc() { t } else { step }));
            continue;
        }
        for e in waits.iter_mut() {
            e.deadline = at;
        }
        let (_, r) = ring::lock().first(&waits);
        if r == Error::TIMEOUT.0 as i64 {
            return 0;
        }
    }
}

#[unsafe(no_mangle)]
extern "C" fn sys_eventfd(_init: u64, _flags: i16) -> i32 {
    -ENOSYS
}

#[unsafe(no_mangle)]
extern "C" fn sys_network_init() -> i32 {
    0
}

#[unsafe(no_mangle)]
extern "C" fn sys_getaddrbyname(_name: *const c_char, _addr: *mut u8, _len: usize) -> i32 {
    -ENOSYS
}

/// A host's address: an address as it is, a name by the kernel's DNS
/// (remembered, for connect to give the name back). One answer.
#[unsafe(no_mangle)]
unsafe extern "C" fn sys_getaddrinfo(
    node: *const c_char,
    service: *const c_char,
    hints: *const Addrinfo,
    res: *mut *mut Addrinfo,
) -> i32 {
    if node.is_null() || res.is_null() {
        return EAI_NONAME;
    }
    let Ok(name) = unsafe { CStr::from_ptr(node) }.to_str() else { return EAI_NONAME };
    let port = if service.is_null() {
        0
    } else {
        match unsafe { CStr::from_ptr(service) }.to_str().ok().and_then(|s| s.parse::<u16>().ok()) {
            Some(p) => p,
            None => return EAI_SERVICE,
        }
    };
    let (family, socktype) = if hints.is_null() {
        (0, SOCK_STREAM)
    } else {
        let h = unsafe { &*hints };
        (h.ai_family, if h.ai_socktype == 0 { SOCK_STREAM } else { h.ai_socktype })
    };
    let ip = match name.parse::<IpAddr>() {
        Ok(ip) => ip,
        Err(_) => match lookup_host(name) {
            Ok(ip) => ip,
            Err(e) => return e,
        },
    };
    let v6 = match (family, ip) {
        (AF_INET, IpAddr::V6(_)) | (AF_INET6, IpAddr::V4(_)) => return EAI_FAMILY,
        (AF_INET6, _) => true,
        (_, IpAddr::V6(_)) => true,
        _ => false,
    };
    let (sa, len) = sockaddr_of(ip, port, v6);
    let a = Box::into_raw(Box::new(Answer {
        ai: Addrinfo {
            ai_flags: 0,
            ai_family: if v6 { AF_INET6 } else { AF_INET },
            ai_socktype: socktype,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: len,
            ai_canonname: core::ptr::null_mut(),
            ai_addr: core::ptr::null_mut(),
            ai_next: core::ptr::null_mut(),
        },
        sa,
    }));
    unsafe {
        (*a).ai.ai_addr = core::ptr::addr_of_mut!((*a).sa) as *mut c_void;
        res.write(a as *mut Addrinfo);
    }
    0
}

/// A name, by the kernel's DNS -> its address; EAI_* if not.
fn lookup_host(name: &str) -> Result<IpAddr, i32> {
    let n = Net::get().map_err(|_| EAI_FAIL)?;
    let s = n.lookup(name).map_err(|e| if e == Error::ARG { EAI_NONAME } else { EAI_FAIL })?;
    s.wait_recv(None).map_err(|_| EAI_FAIL)?;
    let st = s.status().map_err(|_| EAI_FAIL)?;
    if st.failed() {
        return Err(match st.why {
            NETW_NOHOST | NETW_NOADDR | NETW_BADNAME => EAI_NONAME,
            NETW_NOSERVER | NETW_BUSY | NETW_DNS | NETW_NOANSWER | NETW_DOWN => EAI_AGAIN,
            _ => EAI_FAIL,
        });
    }
    let a = s.addrs().map_err(|_| EAI_FAIL)?;
    remember(a.peer, name);
    Ok(net::ip(a.peer))
}

#[unsafe(no_mangle)]
unsafe extern "C" fn sys_freeaddrinfo(ai: *mut Addrinfo) {
    let mut p = ai;
    while !p.is_null() {
        let a = unsafe { Box::from_raw(p as *mut Answer) };
        p = a.ai.ai_next;
    }
}
