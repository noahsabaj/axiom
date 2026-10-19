//! rstd: Rust's std on Axiom, one piece at a time, each line "rstd: ..."
//! for the test to find: its arguments; threads (spawned and joined with
//! their results, scoped, many in turn, a name); locks (Mutex, Condvar and
//! its timeout, RwLock, Once and OnceLock, Barrier, mpsc, park); atomics
//! across threads; thread_local! (each thread its own, destructors run as
//! each ends); time (Instant, sleep, SystemTime); the CPUs; std::fs on a
//! volume (files made, written, appended to, read back, sought in, listed,
//! looked at, removed; a folder made and removed); std::net against the
//! test's servers on the host.
//!
//!   rstd [fs <folder> | ro <folder> | home | net <echo> <port> [dns] |
//!         panic | exit | code]
//!
//! fs needs a volume that can be written (vol <n> rw); ro checks that one
//! that can't says so; home: what is in the boot volume's /Home is written
//! without it, and nothing else is; panic: a thread panics, which ends the program;
//! exit: a thread ends it, 7, by std::process::exit; code: main returns
//! ExitCode 3. net: TCP to the echo server at 10.0.2.2:<echo> (written by
//! one thread, read back by another; peek, a read's timeout, nonblocking,
//! shutdown, its addresses), a connection nobody answers, what isn't here
//! (loopback, UDP), port 0, then <port> listened on for a client from the
//! host; then <port> + 1 as TLS's server (axiom::net::Identity, from the
//! stick's NODE.PEM and NODE.KEY), for a TLS client from the host, after
//! a key that is not the certificate's is refused; dns: axiom.test by name
//! too.

use std::cell::Cell;
use std::collections::BTreeSet;
use std::fs;
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::process::ExitCode;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Barrier, Condvar, Mutex, Once, OnceLock, RwLock, mpsc};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

axiom::entry!(wants = axiom::wants::FILES | axiom::wants::NET);

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
        Some("net") => network(&args[1..]),
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

/// std::net, against the test's servers on the host (10.0.2.2).
/// TLS's server side on `port`: the kernel's, through axiom::net.
fn tls_server(port: u16) {
    use axiom::Error;
    use axiom::net::{self, Identity, Net};
    let certs = fs::read_to_string("/NODE.PEM").expect("NODE.PEM");
    let key = fs::read_to_string("/NODE.KEY").expect("NODE.KEY");
    let id = Identity::from_pem(&certs, &key).expect("an identity");
    let junk = "-----BEGIN PRIVATE KEY-----\nnot base64!\n-----END PRIVATE KEY-----\n";
    let bad = [Identity::from_pem(&certs, junk).err(), Identity::from_pem("", &key).err()];
    let n = Net::get().expect("the network");

    let wrong = Identity::new([7; 32], id.certs().to_vec());
    let w = n.listen_tls(port, &wrong).expect("listen_tls");
    let _ = w.wait_send(None);
    let s = w.status().unwrap();
    println!("rstd: net tls, another key: failed {}, {:?}; bad PEM {:?}", s.failed(), net::why_text(s.why), bad);
    drop(w);

    let l = n.listen_tls(port, &id).expect("listen_tls");
    l.wait_send(None).unwrap();
    let s = l.status().unwrap();
    println!("rstd: net tls listening on port {}, failed {}, {} certificate", l.addrs().unwrap().port, s.failed(),
             id.certs().len());
    let c = loop {
        match l.accept() {
            Ok(c) => break c,
            Err(Error::EMPTY) => l.wait_recv(None).unwrap(),
            Err(e) => panic!("accept: {:?}", e),
        }
    };
    let _ = c.wait_send(None);                      // until its handshake is done
    let s = c.status().unwrap();
    let mut line = Vec::new();
    let mut b = [0u8; 256];
    while !line.contains(&b'\n') {
        match c.recv(&mut b) {
            Ok(got) => line.extend_from_slice(&b[..got]),
            Err(Error::EMPTY) => c.wait_recv(None).unwrap(),
            Err(e) => {
                println!("rstd: net tls recv {:?}", e);
                break;
            }
        }
    }
    let line = String::from_utf8_lossy(&line).into_owned();
    let answer = format!("you said, over TLS: {}", line);
    let mut sent = 0;
    while sent < answer.len() {
        match c.send(&answer.as_bytes()[sent..]) {
            Ok(k) => sent += k,
            Err(Error::FULL) => c.wait_send(None).unwrap(),
            Err(e) => panic!("send: {:?}", e),
        }
    }
    let from = net::ip(c.addrs().unwrap().peer);
    let said = line.trim_end();
    println!("rstd: net tls accepted from {}, open {}, said {:?}, {} bytes", from, s.state == axiom::sys::SKS_OPEN,
             &said[..said.len().min(14)], line.len());
    drop(c);
    drop(l);
}

fn network(args: &[String]) {
    use std::net::{Shutdown, SocketAddr, TcpListener, TcpStream, ToSocketAddrs, UdpSocket};
    let echo: u16 = args[0].parse().expect("the echo server's port");
    let serve: u16 = args[1].parse().expect("a port to listen on");
    let dns = args.get(2).is_some_and(|a| a == "dns");
    let host = SocketAddr::from(([10, 0, 2, 2], echo));

    let s = TcpStream::connect(host).expect("connect");
    let (peer, local) = (s.peer_addr().unwrap(), s.local_addr().unwrap());
    println!("rstd: net connected to {}, from {}, a port of ours {}", peer, local.ip(), local.port() >= 49152);
    let data: Vec<u8> = (0..200_000u32).map(|i| (i * 7 + i / 251) as u8).collect();
    let mut w = s.try_clone().expect("try_clone");
    let sent = data.clone();
    let writer = thread::spawn(move || w.write_all(&sent).map_err(|e| e.kind()));
    let mut back = vec![0u8; data.len()];
    let read = (&s).read_exact(&mut back).map_err(|e| e.kind());
    let wrote = writer.join().unwrap();
    println!("rstd: net echoed {} bytes {:?} {:?}, right {}", back.len(), wrote, read, back == data);

    (&s).write_all(b"peek").unwrap();
    let mut b = [0u8; 4];
    for _ in 0..200 {
        if s.peek(&mut b).unwrap() == 4 {
            break;
        }
        thread::sleep(Duration::from_millis(10));
    }
    let mut r = [0u8; 4];
    (&s).read_exact(&mut r).unwrap();
    println!("rstd: net peeked {:?}, then read {:?}", String::from_utf8_lossy(&b), String::from_utf8_lossy(&r));

    s.set_read_timeout(Some(Duration::from_millis(200))).unwrap();
    let t = Instant::now();
    let e = (&s).read(&mut b).map_err(|e| e.kind());
    let ms = t.elapsed().as_millis();
    println!("rstd: net read timed out {:?} {:?}, in time {}", e, s.read_timeout().unwrap(), (150..1000).contains(&ms));
    s.set_read_timeout(None).unwrap();
    s.set_nonblocking(true).unwrap();
    let e = (&s).read(&mut b).map_err(|e| e.kind());
    s.set_nonblocking(false).unwrap();
    s.set_nodelay(true).unwrap();
    println!("rstd: net nonblocking {:?}, nodelay {:?}", e, s.nodelay());

    s.shutdown(Shutdown::Write).unwrap();
    let mut rest = Vec::new();
    let n = (&s).read_to_end(&mut rest).map_err(|e| e.kind());
    println!("rstd: net shut, then the end {:?}", n);
    drop(s);

    let t = Instant::now();
    let nobody = SocketAddr::from(([10, 0, 2, 99], 9));
    let e = TcpStream::connect_timeout(&nobody, Duration::from_millis(300)).map(|_| ()).map_err(|e| e.kind());
    println!("rstd: net nobody at {}: {:?}, in time {}", nobody, e.is_err(), t.elapsed() < Duration::from_secs(4));

    let lo = TcpListener::bind("127.0.0.1:0").map(|_| ()).map_err(|e| e.kind());
    let lo_to = TcpStream::connect("127.0.0.1:80").map(|_| ()).map_err(|e| e.raw_os_error());
    let udp = UdpSocket::bind("0.0.0.0:0").map(|_| ()).map_err(|e| e.to_string());
    println!("rstd: net loopback {:?} {:?}, udp {:?}", lo, lo_to, udp);

    let any = TcpListener::bind("0.0.0.0:0").expect("port 0");
    let p = any.local_addr().unwrap().port();
    println!("rstd: net port 0 is one of ours {}", p >= 49152);
    drop(any);

    let l = TcpListener::bind(("0.0.0.0", serve)).expect("listen");
    println!("rstd: net listening on {}", l.local_addr().unwrap());
    let (mut c, from) = l.accept().expect("accept");
    let mut line = String::new();
    BufReader::new(&c).read_line(&mut line).unwrap();
    c.write_all(format!("you said: {}", line).as_bytes()).unwrap();
    println!("rstd: net accepted from {}, said {:?}", from.ip(), line.trim_end());
    drop(c);
    drop(l);
    tls_server(serve + 1);

    if dns {
        let found: Vec<SocketAddr> = ("axiom.test", echo).to_socket_addrs().expect("lookup").collect();
        println!("rstd: net axiom.test is {:?}", found);
        let mut s = TcpStream::connect(("axiom.test", echo)).expect("by name");
        s.write_all(b"by name").unwrap();
        s.shutdown(Shutdown::Write).unwrap();
        let mut back = String::new();
        s.read_to_string(&mut back).unwrap();
        println!("rstd: net by name, echoed {:?}", back);
        let none = ("nothing.here", 80).to_socket_addrs().map(|_| ()).map_err(|e| e.to_string());
        println!("rstd: net nothing.here {:?}", none);
    }
    println!("rstd: net done");
}
