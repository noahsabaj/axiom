//! rstd: Rust's std on Axiom, one piece at a time, each line "rstd: ..."
//! for the test to find: its arguments; threads (spawned and joined with
//! their results, scoped, many in turn, a name); locks (Mutex, Condvar and
//! its timeout, RwLock, Once and OnceLock, Barrier, mpsc, park); atomics
//! across threads; thread_local! (each thread its own, destructors run as
//! each ends); time (Instant, sleep, SystemTime); the CPUs; std::fs on a
//! volume (files made, written, appended to, read back, sought in, listed,
//! looked at, removed; a folder made and removed).
//!
//!   rstd [fs <folder> | ro <folder> | home | panic | exit | code]
//!
//! fs needs a volume that can be written (vol <n> rw); ro checks that one
//! that can't says so; home: what is in the boot volume's /Home is written
//! without it, and nothing else is; panic: a thread panics, which ends the program;
//! exit: a thread ends it, 7, by std::process::exit; code: main returns
//! ExitCode 3.

use std::cell::Cell;
use std::collections::BTreeSet;
use std::fs;
use std::io::{Read, Seek, SeekFrom, Write};
use std::process::ExitCode;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Barrier, Condvar, Mutex, Once, OnceLock, RwLock, mpsc};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

axiom::entry!(wants = axiom::wants::FILES);

static DROPPED: AtomicU32 = AtomicU32::new(0);

struct Counted(u32);

impl Drop for Counted {
    fn drop(&mut self) {
        DROPPED.fetch_add(self.0, Ordering::SeqCst);
    }
}

thread_local! {
    static MINE: Cell<u64> = const { Cell::new(7) };
    static COUNTED: Counted = const { Counted(1) };
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    println!("rstd: args {:?}", args);
    match args.first().map(String::as_str) {
        Some("panic") => {
            let t = thread::spawn(|| panic!("rstd: a thread panics"));
            let _ = t.join();
            println!("rstd: still here");
            return ExitCode::SUCCESS;
        }
        Some("exit") => {
            let t = thread::spawn(|| {
                println!("rstd: a thread exits");
                std::process::exit(7)
            });
            let _ = t.join();
            println!("rstd: still here");
        }
        Some("code") => return ExitCode::from(3),
        Some("fs") => files(&args[1]),
        Some("ro") => read_only(&args[1]),
        Some("home") => home(),
        _ => {
            threads();
            locks();
            locals();
            time();
            println!("rstd: done");
        }
    }
    ExitCode::SUCCESS
}

fn threads() {
    let cpus = thread::available_parallelism().map(|n| n.get()).unwrap_or(0);
    println!("rstd: cpus {}", cpus);

    let hs: Vec<_> = (0..8u64)
        .map(|i| thread::spawn(move || (0..1_000_000u64).map(|x| x * i).sum::<u64>()))
        .collect();
    let sums: Vec<u64> = hs.into_iter().map(|h| h.join().unwrap()).collect();
    let right = sums.iter().enumerate().all(|(i, &s)| s == i as u64 * 499_999_500_000);
    println!("rstd: 8 threads, their sums {}", if right { "right" } else { "wrong" });

    let mut v = vec![1u32; 1000];
    thread::scope(|s| {
        for chunk in v.chunks_mut(100) {
            s.spawn(move || chunk.iter_mut().for_each(|x| *x *= 3));
        }
    });
    println!("rstd: scoped, sum {}", v.iter().sum::<u32>());

    let mut done = 0;
    for i in 0..300 {
        let t = thread::Builder::new().stack_size(64 << 10).spawn(move || i * 2).unwrap();
        done += (t.join().unwrap() == i * 2) as u32;
    }
    for _ in 0..50 {
        drop(thread::spawn(|| ())); // never joined: given back by the next spawns
    }
    thread::sleep(Duration::from_millis(20));
    let t = thread::spawn(|| 1);
    println!("rstd: 300 in turn {}, 50 unjoined, then {}", done, t.join().unwrap());

    let named = thread::Builder::new()
        .name("worker".into())
        .spawn(|| thread::current().name().map(String::from))
        .unwrap();
    println!("rstd: named {:?}, main is {:?}", named.join().unwrap(), thread::current().name());
}

fn locks() {
    let n = Arc::new(Mutex::new(0u64));
    let hs: Vec<_> = (0..4)
        .map(|_| {
            let n = n.clone();
            thread::spawn(move || {
                for _ in 0..20_000 {
                    *n.lock().unwrap() += 1;
                }
            })
        })
        .collect();
    hs.into_iter().for_each(|h| h.join().unwrap());
    println!("rstd: mutex {}", *n.lock().unwrap());

    let a = Arc::new(AtomicU64::new(0));
    let hs: Vec<_> = (0..4)
        .map(|_| {
            let a = a.clone();
            thread::spawn(move || (0..50_000).for_each(|_| { a.fetch_add(1, Ordering::Relaxed); }))
        })
        .collect();
    hs.into_iter().for_each(|h| h.join().unwrap());
    println!("rstd: atomic {}", a.load(Ordering::SeqCst));

    let pair = Arc::new((Mutex::new(0u32), Condvar::new()));
    let p = pair.clone();
    let t = thread::spawn(move || {
        let (m, c) = &*p;
        for _ in 0..200 {
            let mut g = c.wait_while(m.lock().unwrap(), |n| *n % 2 == 0).unwrap();
            *g += 1;
            c.notify_one();
        }
    });
    {
        let (m, c) = &*pair;
        for _ in 0..200 {
            let mut g = c.wait_while(m.lock().unwrap(), |n| *n % 2 == 1).unwrap();
            *g += 1;
            c.notify_one();
        }
    }
    t.join().unwrap();
    println!("rstd: condvar, turns {}", *pair.0.lock().unwrap());

    let (m, c) = (Mutex::new(()), Condvar::new());
    let t0 = Instant::now();
    let (_g, r) = c.wait_timeout(m.lock().unwrap(), Duration::from_millis(30)).unwrap();
    let ms = t0.elapsed().as_millis();
    println!("rstd: condvar timed out {} after {} ms", r.timed_out(), ms);

    let rw = Arc::new(RwLock::new(vec![0u32; 16]));
    let hs: Vec<_> = (0..4)
        .map(|i| {
            let rw = rw.clone();
            thread::spawn(move || {
                let mut seen = 0;
                for j in 0..500 {
                    if j % 10 == 0 {
                        rw.write().unwrap()[i] += 1;
                    } else {
                        seen += rw.read().unwrap().len();
                    }
                }
                seen
            })
        })
        .collect();
    let seen: usize = hs.into_iter().map(|h| h.join().unwrap()).sum();
    println!("rstd: rwlock, written {}, read {}", rw.read().unwrap().iter().sum::<u32>(), seen);

    static ONCE: Once = Once::new();
    static RAN: AtomicU32 = AtomicU32::new(0);
    static LOCK: OnceLock<u32> = OnceLock::new();
    let hs: Vec<_> = (0..4)
        .map(|i| {
            thread::spawn(move || {
                ONCE.call_once(|| { RAN.fetch_add(1, Ordering::SeqCst); });
                *LOCK.get_or_init(|| 40 + i)
            })
        })
        .collect();
    let got: BTreeSet<u32> = hs.into_iter().map(|h| h.join().unwrap()).collect();
    println!("rstd: once ran {}, oncelock agreed {}", RAN.load(Ordering::SeqCst), got.len() == 1);

    let b = Arc::new(Barrier::new(5));
    let order = Arc::new(Mutex::new(Vec::new()));
    let hs: Vec<_> = (0..5)
        .map(|i| {
            let (b, order) = (b.clone(), order.clone());
            thread::spawn(move || {
                order.lock().unwrap().push(i);
                b.wait();
                order.lock().unwrap().push(10 + i);
            })
        })
        .collect();
    hs.into_iter().for_each(|h| h.join().unwrap());
    let o = order.lock().unwrap();
    println!("rstd: barrier held {}", o[..5].iter().all(|&x| x < 10) && o[5..].iter().all(|&x| x >= 10));

    let (tx, rx) = mpsc::channel();
    for i in 0..4u32 {
        let tx = tx.clone();
        thread::spawn(move || (0..250).for_each(|j| tx.send(i * 1000 + j).unwrap()));
    }
    drop(tx);
    let got: BTreeSet<u32> = rx.iter().collect();
    println!("rstd: mpsc {} messages", got.len());

    let (tx, rx) = mpsc::sync_channel(0);
    let t = thread::spawn(move || (0..100u32).map(|_| rx.recv().unwrap()).sum::<u32>());
    (0..100u32).for_each(|i| tx.send(i).unwrap());
    println!("rstd: rendezvous {}", t.join().unwrap());

    let flag = Arc::new(AtomicU32::new(0));
    let f = flag.clone();
    let t = thread::spawn(move || {
        while f.load(Ordering::Acquire) == 0 {
            thread::park();
        }
        1
    });
    thread::sleep(Duration::from_millis(10));
    flag.store(1, Ordering::Release);
    t.thread().unpark();
    println!("rstd: parked and unparked {}", t.join().unwrap());
}

fn locals() {
    MINE.with(|m| m.set(100));
    let hs: Vec<_> = (0..6u64)
        .map(|i| {
            thread::spawn(move || {
                let first = MINE.with(|m| m.get());
                MINE.with(|m| m.set(i));
                COUNTED.with(|c| c.0); // made in this thread, dropped as it ends
                thread::sleep(Duration::from_millis(5));
                (first, MINE.with(|m| m.get()))
            })
        })
        .collect();
    let got: Vec<(u64, u64)> = hs.into_iter().map(|h| h.join().unwrap()).collect();
    let own = got.iter().enumerate().all(|(i, &(first, now))| first == 7 && now == i as u64);
    println!(
        "rstd: thread_local each its own {}, the first's {}, destructors {}",
        own,
        MINE.with(|m| m.get()),
        DROPPED.load(Ordering::SeqCst)
    );
}

fn time() {
    let t0 = Instant::now();
    thread::sleep(Duration::from_millis(50));
    let slept = t0.elapsed();
    let t1 = Instant::now();
    let mut spins = 0u64;
    while t1.elapsed() < Duration::from_millis(20) {
        spins += 1;
    }
    println!("rstd: slept {} ms, spun {} ms ({} looks)", slept.as_millis(), t1.elapsed().as_millis(), spins > 0);
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
    let days = now / 86400;
    println!("rstd: the year {}", 1970 + days * 400 / 146097);
}

fn files(dir: &str) {
    let path = |name: &str| format!("{}/{}", dir, name);
    match fs::create_dir(dir) {
        Ok(()) => println!("rstd: fs made {}", dir),
        Err(e) => return println!("rstd: fs mkdir failed: {} ({:?})", e, e.kind()),
    }
    let text = "the first line\nthe second\n";
    fs::write(path("a.txt"), text).unwrap();
    let back = fs::read_to_string(path("a.txt")).unwrap();
    println!("rstd: fs wrote and read back {}", back == text);

    let mut f = fs::OpenOptions::new().append(true).open(path("a.txt")).unwrap();
    f.write_all(b"the third\n").unwrap();
    drop(f);
    let lines = fs::read_to_string(path("a.txt")).unwrap().lines().count();
    println!("rstd: fs appended, {} lines", lines);

    let mut f = fs::File::create(path("big.bin")).unwrap();
    let block: Vec<u8> = (0..=255u8).collect();
    for _ in 0..1024 {
        f.write_all(&block).unwrap(); // 256 KiB, in pieces
    }
    drop(f);
    let mut f = fs::File::open(path("big.bin")).unwrap();
    f.seek(SeekFrom::Start(1000)).unwrap();
    let mut b = [0u8; 4];
    f.read_exact(&mut b).unwrap();
    let end = f.seek(SeekFrom::End(0)).unwrap();
    println!("rstd: fs big {} bytes, at 1000 {:?}", end, b);

    let md = fs::metadata(path("big.bin")).unwrap();
    let dm = fs::metadata(dir).unwrap();
    let age = SystemTime::now().duration_since(md.modified().unwrap()).map(|d| d.as_secs()).unwrap_or(0);
    println!(
        "rstd: fs metadata: file {} {} bytes, folder {}, written within a day {}",
        md.is_file(),
        md.len(),
        dm.is_dir(),
        age < 86400
    );

    fs::create_dir(path("sub")).unwrap();
    fs::write(path("sub/c.txt"), "c").unwrap();
    let mut names: Vec<String> =
        fs::read_dir(dir).unwrap().map(|e| e.unwrap().file_name().into_string().unwrap()).collect();
    names.sort();
    println!("rstd: fs listed {:?}", names);

    let missing = fs::read("rstd-none/x.txt").map_err(|e| e.kind());
    println!("rstd: fs missing {:?}", missing);

    fs::remove_file(path("sub/c.txt")).unwrap();
    fs::remove_dir(path("sub")).unwrap();
    fs::remove_file(path("a.txt")).unwrap();
    fs::remove_file(path("big.bin")).unwrap();
    fs::remove_dir(dir).unwrap();
    println!("rstd: fs removed, gone {}", fs::metadata(dir).is_err());
}

fn read_only(dir: &str) {
    let made = fs::create_dir(dir).map_err(|e| e.to_string());
    let written = fs::write(format!("{}.txt", dir), "x").map_err(|e| e.to_string());
    let read = fs::read("EFI/AXIOM/RSTD.AXE").map(|v| v.len() > 0);
    println!("rstd: ro mkdir {:?}, write {:?}, read {:?}", made, written, read);
}

/// The boot volume's /Home: written without "vol <n> rw", and nothing
/// outside it (nor the folder itself) is.
fn home() {
    let env = std::env::var("HOME");
    let files = axiom::Files::get().expect("files");
    let at = files.home().map_err(|e| format!("{:?}", e));
    println!("rstd: home {:?}, HOME {:?}", at, env);
    let made = fs::create_dir("/Home/rstd").is_ok();
    let wrote = fs::write("/Home/rstd/a.txt", "kept").is_ok();
    let back = fs::read_to_string("/Home/rstd/a.txt").map(|s| s == "kept").unwrap_or(false);
    let mut f = fs::OpenOptions::new().append(true).open("/Home/rstd/a.txt").expect("append");
    let _ = f.write_all(b", twice");
    drop(f);
    let appended = fs::read_to_string("/Home/rstd/a.txt").map(|s| s == "kept, twice").unwrap_or(false);
    let home = at.unwrap_or_default();
    let renamed = files.rename(&format!("{}/rstd/a.txt", home), &format!("{}/rstd/b.txt", home)).is_ok();
    println!("rstd: home made {}, wrote {}, read back {}, appended {}, renamed {}", made, wrote, back, appended, renamed);
    let outside = fs::write("/rstdhome.txt", "x").map_err(|e| e.to_string());
    let out = files.rename(&format!("{}/rstd/b.txt", home), "vol0:/b.txt").map_err(|e| format!("{:?}", e));
    let itself = fs::remove_dir("/Home").map_err(|e| e.to_string());
    println!("rstd: home outside {:?}, moved out {:?}, removed {:?}", outside, out, itself);
    let gone = fs::remove_file("/Home/rstd/b.txt").is_ok() && fs::remove_dir("/Home/rstd").is_ok();
    println!("rstd: home cleaned {}, there {}", gone, fs::metadata("/Home").map(|m| m.is_dir()).unwrap_or(false));
}
