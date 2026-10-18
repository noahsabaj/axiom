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
//! - std::net: Unsupported, for now
//!
//! Errors are Linux's numbers, as hermit-abi has them, negated.

use alloc::boxed::Box;
use alloc::string::String;
use alloc::vec::Vec;
use core::alloc::{GlobalAlloc, Layout};
use core::ffi::{CStr, c_char, c_void};
use core::sync::atomic::{AtomicU32, Ordering};
use core::time::Duration;

use crate::files::{self, Files};
use crate::heap::SYSTEM;
use crate::sync::SpinLock;
use crate::sys::{self, Error};
use crate::{console, thread, time};

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

fn volume_writable(files: Files, path: &str) -> bool {
    let n: Option<u32> = path.strip_prefix("vol").and_then(|r| r.split(':').next()).and_then(|n| n.parse().ok());
    match (n, files.volumes()) {
        (Some(n), Ok(vols)) => vols.iter().any(|v| v.index == n && v.flags & files::VOL_WRITABLE != 0),
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
    if let Open::File { files, path, data, dirty: true, .. } = &*o {
        if let Err(e) = files.write(path, data) {
            crate::println!("axiom: {} was not written: {}", path, e);
            return -errno(e);
        }
    }
    0 // (dropped here, out of the lock)
}

#[unsafe(no_mangle)]
extern "C" fn sys_dup(_fd: i32) -> i32 {
    -ENOSYS
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
        Open::Dir { .. } => -ESPIPE as isize,
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
        Open::File { .. } => -ENOTDIR as i64,
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

// ---- the network: not yet --------------------------------------------

macro_rules! no_net {
    ($($name:ident($($arg:ident: $ty:ty),*) -> $ret:ty;)*) => {$(
        #[unsafe(no_mangle)]
        extern "C" fn $name($($arg: $ty),*) -> $ret {
            $(let _ = $arg;)*
            -(ENOSYS as $ret)
        }
    )*};
}

no_net! {
    sys_socket(domain: i32, kind: i32, protocol: i32) -> i32;
    sys_bind(s: i32, name: *const c_void, len: u32) -> i32;
    sys_listen(s: i32, backlog: i32) -> i32;
    sys_accept(s: i32, addr: *mut c_void, len: *mut u32) -> i32;
    sys_connect(s: i32, name: *const c_void, len: u32) -> i32;
    sys_recv(s: i32, buf: *mut u8, len: usize, flags: i32) -> isize;
    sys_recvfrom(s: i32, buf: *mut u8, len: usize, flags: i32, addr: *mut c_void, alen: *mut u32) -> isize;
    sys_send(s: i32, buf: *const c_void, len: usize, flags: i32) -> isize;
    sys_sendto(s: i32, buf: *const c_void, len: usize, flags: i32, to: *const c_void, tolen: u32) -> isize;
    sys_shutdown(s: i32, how: i32) -> i32;
    sys_shutdown_socket(s: i32, how: i32) -> i32;
    sys_getpeername(s: i32, name: *mut c_void, len: *mut u32) -> i32;
    sys_getsockname(s: i32, name: *mut c_void, len: *mut u32) -> i32;
    sys_getsockopt(s: i32, level: i32, opt: i32, val: *mut c_void, len: *mut u32) -> i32;
    sys_setsockopt(s: i32, level: i32, opt: i32, val: *const c_void, len: u32) -> i32;
    sys_ioctl(s: i32, cmd: i32, argp: *mut c_void) -> i32;
    sys_poll(fds: *mut c_void, n: usize, timeout: i32) -> i32;
    sys_eventfd(init: u64, flags: i16) -> i32;
    sys_network_init() -> i32;
    sys_getaddrbyname(name: *const c_char, addr: *mut u8, len: usize) -> i32;
}

#[unsafe(no_mangle)]
extern "C" fn sys_getaddrinfo(_n: *const c_char, _s: *const c_char, _h: *const c_void, _r: *mut *mut c_void) -> i32 {
    EAI_FAIL
}

#[unsafe(no_mangle)]
extern "C" fn sys_freeaddrinfo(_ai: *mut c_void) {}

