//! Jobs: programs started for fleet, each a child task of this one, its
//! console to a channel of ours (axiom::task, axiom::chan). Each has
//! HOME/jobs/ID/job.json (what fleet's node keeps, in its order) and
//! /log, kept in memory as it grows and written there every few seconds
//! and at its end. A job found unfinished at the start was lost.

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};

use core::time::Duration;

use axiom::time::Instant;
use axiom::{Error, Files, chan, task};

use crate::json::{self, Bool, Int, List, Null, Object, Str, Value};
use crate::store::{FILE_MAX, civil_from_days};
use crate::wire::with;

pub const FINAL: [&str; 4] = ["done", "failed", "stopped", "lost"];
const SUMMARY: [&str; 16] = [
    "id", "project", "argv", "state", "exit", "started", "ended", "client", "log_bytes", "user", "admin", "limits",
    "reason", "yields", "service", "timeouts",
];
/// How often a running job's log is written down.
const SAVE_EVERY: Duration = Duration::from_secs(5);

/// The time as fleet writes it: ISO, to the second, with the zone (UTC:
/// Axiom keeps the clock so).
pub fn now_iso() -> String {
    let s = (axiom::sys::clock_us() / 1_000_000) as i64;
    let (y, m, d) = civil_from_days(s.div_euclid(86400));
    let r = s.rem_euclid(86400);
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}+00:00", y, m, d, r / 3600, r / 60 % 60, r % 60)
}

/// Python's f"{x:g}".
pub fn g(x: f64) -> String {
    if x == 0.0 {
        return "0".into();
    }
    let exp = x.abs().log10().floor() as i32;
    let trim = |s: String| {
        if s.contains('.') { s.trim_end_matches('0').trim_end_matches('.').to_string() } else { s }
    };
    if !(-4..6).contains(&exp) {
        let s = format!("{:.5e}", x); // 1.50000e7
        let (m, e) = s.split_once('e').unwrap_or((&s, "0"));
        let e: i32 = e.parse().unwrap_or(0);
        return format!("{}e{}{:02}", trim(m.to_string()), if e < 0 { '-' } else { '+' }, e.abs());
    }
    trim(format!("{:.*}", (5 - exp).max(0) as usize, x))
}

/// jobrun's minutes().
pub fn minutes(s: f64) -> String {
    if s >= 60.0 { format!("{} min", g(s / 60.0)) } else { format!("{} s", g(s)) }
}

struct Log {
    bytes: Vec<u8>,
    /// in memory (this run's); else read from its file
    live: bool,
}

pub struct Job {
    pub id: String,
    /// in the order started (or found), for jobs started in the same second
    seq: u64,
    rec: Mutex<Value>,
    log: Mutex<Log>,
    changed: Condvar,
    stop: AtomicBool,
    child: Mutex<Option<Arc<task::Child>>>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl Job {
    fn new(id: &str, seq: u64, rec: Value, live: bool) -> Job {
        Job {
            id: id.to_string(),
            seq,
            rec: Mutex::new(rec),
            log: Mutex::new(Log { bytes: Vec::new(), live }),
            changed: Condvar::new(),
            stop: AtomicBool::new(false),
            child: Mutex::new(None),
        }
    }

    pub fn get(&self, key: &str) -> Value {
        lock(&self.rec).get(key).cloned().unwrap_or(Null)
    }

    pub fn state(&self) -> String {
        self.get("state").str().unwrap_or("").to_string()
    }

    pub fn is_final(&self) -> bool {
        FINAL.contains(&self.state().as_str())
    }

    fn update(&self, fields: Vec<(&str, Value)>) {
        let mut r = lock(&self.rec);
        let mut v = core::mem::replace(&mut *r, Null);
        for (k, x) in fields {
            v = with(v, k, x);
        }
        *r = v;
    }

    pub fn summary(&self) -> Value {
        let r = lock(&self.rec);
        Object(SUMMARY.iter().filter_map(|&k| r.get(k).map(|v| (k.to_string(), v.clone()))).collect())
    }

    fn append(&self, b: &[u8]) {
        lock(&self.log).bytes.extend_from_slice(b);
        self.changed.notify_all();
    }

    fn poke(&self) {
        let _l = lock(&self.log);
        self.changed.notify_all();
    }

    /// Until the log is past `offset` or the job changes, or `wait` passes.
    pub fn wait(&self, offset: usize, wait: Duration) {
        let l = lock(&self.log);
        if !l.live || l.bytes.len() > offset {
            return;
        }
        let _ = self.changed.wait_timeout(l, wait);
    }
}

pub struct Jobs {
    files: Files,
    /// "vol<n>:/Home/fleet/jobs"
    dir: String,
    node: String,
    all: Mutex<BTreeMap<String, Arc<Job>>>,
    seq: AtomicU64,
}

pub fn job_ok(id: &Value) -> Option<&str> {
    let s = id.str()?;
    (1..=64).contains(&s.len()).then_some(())?;
    s.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'-').then_some(s)
}

/// How a job is started (op_start's, checked).
pub struct Start {
    pub id: String,
    pub project: String,
    /// its folder, as the kernel takes it
    pub dir: String,
    /// the same, as a program's text has it ("/Home/...")
    pub dir_text: String,
    pub argv: Vec<String>,
    pub env: Value,
    pub limits: Value,
    pub timeouts: Value,
    pub total_s: Option<f64>,
    pub idle_s: Option<f64>,
    pub client: String,
}

impl Jobs {
    /// The jobs kept in `dir`: those that were running when this program
    /// last ended are lost.
    pub fn load(files: Files, dir: String, node: String) -> Arc<Jobs> {
        let _ = files.mkdir(&dir);
        let mut all = BTreeMap::new();
        for e in files.list(&dir).unwrap_or_default() {
            if !e.is_dir() || job_ok(&Str(e.name.clone())).is_none() {
                continue;
            }
            let Ok(b) = files.read(&format!("{}/{}/job.json", dir, e.name)) else { continue };
            let Ok(rec @ Object(_)) = json::parse(&b) else { continue };
            let job = Job::new(&e.name, all.len() as u64, rec, false);
            if !job.is_final() {
                job.update(vec![("state", "lost".into()), ("ended", now_iso().into())]);
                let _ = files.write(&format!("{}/{}/job.json", dir, e.name), lock(&job.rec).encode().as_bytes());
                println!("fleet: job {} was running when the node last ended: lost", e.name);
            }
            all.insert(e.name.clone(), Arc::new(job));
        }
        let seq = AtomicU64::new(all.len() as u64);
        Arc::new(Jobs { files, dir, node, all: Mutex::new(all), seq })
    }

    /// job_folder's: a job here, by id.
    pub fn get(&self, id: &Value) -> Result<Arc<Job>, String> {
        let s = job_ok(id).ok_or_else(|| format!("job id not allowed: {}", id.py_repr()))?;
        lock(&self.all).get(s).cloned().ok_or_else(|| format!("no job {} on {}", s, self.node))
    }

    /// Every job, the oldest first.
    pub fn list(&self) -> Vec<Arc<Job>> {
        let mut v: Vec<((String, u64), Arc<Job>)> = lock(&self.all)
            .values()
            .map(|j| ((j.get("started").str().unwrap_or("").to_string(), j.seq), j.clone()))
            .collect();
        v.sort_by(|a, b| a.0.cmp(&b.0));
        v.into_iter().map(|(_, j)| j).collect()
    }

    fn save(&self, job: &Job) {
        let text = lock(&job.rec).encode();
        if let Err(e) = self.files.write(&format!("{}/{}/job.json", self.dir, job.id), text.as_bytes()) {
            println!("fleet: could not write job {}'s record: {:?}", job.id, e);
        }
    }

    fn save_log(&self, job: &Job) -> usize {
        let l = lock(&job.log);
        let n = l.bytes.len();
        let from = n.saturating_sub(FILE_MAX); // the last 16 MiB, if more
        let _ = self.files.write(&format!("{}/{}/log", self.dir, job.id), &l.bytes[from..]);
        n
    }

    pub fn log_len(&self, job: &Job) -> usize {
        let l = lock(&job.log);
        if l.live {
            return l.bytes.len();
        }
        drop(l);
        self.files.size(&format!("{}/{}/log", self.dir, job.id)).unwrap_or(0)
    }

    /// The log from `offset`.
    pub fn log_from(&self, job: &Job, offset: usize) -> Vec<u8> {
        let l = lock(&job.log);
        if l.live {
            return l.bytes.get(offset..).map(<[u8]>::to_vec).unwrap_or_default();
        }
        drop(l);
        let all = self.files.read(&format!("{}/{}/log", self.dir, job.id)).unwrap_or_default();
        all.get(offset..).map(<[u8]>::to_vec).unwrap_or_default()
    }

    /// A job started -> its "pid" (its task's handle here; 0 if it never
    /// started, when it has failed already, saying why).
    pub fn start(self: &Arc<Self>, s: Start, files: Files, net: axiom::Net) -> Result<u64, String> {
        let mut all = lock(&self.all);
        let folder = format!("{}/{}", self.dir, s.id);
        if all.contains_key(&s.id) || self.files.list(&folder).is_ok() {
            return Err(format!("job {} already exists on {}", s.id, self.node));
        }
        let _ = self.files.mkdir(&self.dir);
        self.files.mkdir(&folder).map_err(|e| format!("OSError('making job {}: {:?}')", s.id, e))?;
        let rec = Object(vec![
            ("id".into(), s.id.clone().into()),
            ("project".into(), s.project.clone().into()),
            ("argv".into(), List(s.argv.iter().map(|a| Str(a.clone())).collect())),
            ("cwd".into(), s.dir_text.clone().into()),
            ("env".into(), s.env.clone()),
            ("state".into(), "starting".into()),
            ("started".into(), now_iso().into()),
            ("client".into(), s.client.clone().into()),
            ("admin".into(), Bool(false)),
            ("user".into(), Null),
            ("limits".into(), if s.limits.truthy() { s.limits.clone() } else { Null }),
            ("service".into(), Null),
            ("timeouts".into(), if s.timeouts.truthy() { s.timeouts.clone() } else { Null }),
        ]);
        let job = Arc::new(Job::new(&s.id, self.seq.fetch_add(1, Ordering::SeqCst), rec, true));
        all.insert(s.id.clone(), job.clone());
        drop(all);

        // The program: a name (as the shell's run takes it), or a path in
        // the project; then its words, as SYS_SPAWN splits them.
        let program = if s.argv[0].contains('/') && !s.argv[0].starts_with('/') {
            format!("{}/{}", s.dir_text, s.argv[0])
        } else {
            s.argv[0].clone()
        };
        let text = std::iter::once(program).chain(s.argv[1..].iter().cloned()).collect::<Vec<_>>().join(" ");
        let started = match self.spawn(&text, &s.dir, files, net) {
            Ok(pair) => Ok(pair),
            Err(why) => Err(why),
        };
        match started {
            Err(why) => {
                job.append(format!("fleet: {}\n", why).as_bytes());
                job.update(vec![
                    ("state", "failed".into()),
                    ("exit", Null),
                    ("ended", now_iso().into()),
                    ("log_bytes", Int(lock(&job.log).bytes.len() as i128)),
                    ("reason", why.clone().into()),
                ]);
                self.save_log(&job);
                self.save(&job);
                println!("fleet: job {} failed to start: {}", s.id, why);
                Ok(0)
            }
            Ok((child, ours)) => {
                let pid = child.task() as u64;
                job.update(vec![("state", "running".into()), ("pid", Int(pid as i128)), ("running", now_iso().into())]);
                *lock(&job.child) = Some(child.clone());
                self.save(&job);
                self.save_log(&job);
                println!("fleet: started job {} in {}: {}", s.id, s.project, text);
                let jobs = self.clone();
                let (total, idle) = (s.total_s, s.idle_s);
                let j = job.clone();
                let watcher = std::thread::Builder::new()
                    .name(format!("job {}", s.id))
                    .stack_size(256 << 10)
                    .spawn(move || jobs.watch(j, ours, child, total, idle));
                if let Err(e) = watcher {
                    println!("fleet: job {}: no thread to watch it: {}", s.id, e);
                }
                Ok(pid)
            }
        }
    }

    fn spawn(&self, text: &str, dir: &str, files: Files, net: axiom::Net) -> Result<(Arc<task::Child>, chan::End), String> {
        use axiom::sys::*;
        if text.len() > task::TEXT_MAX {
            return Err(format!("its command is {} bytes: Axiom takes {} at most", text.len(), task::TEXT_MAX));
        }
        let fs = files
            .sub(dir, RT_FS_READ | RT_FS_WRITE)
            .map_err(|e| format!("no handle to its project's folder: {:?}", e))?;
        let all = RT_NET_CONNECT | RT_NET_TLS | RT_NET_INSECURE | RT_NET_LISTEN | RT_DUP | RT_GIVE | RT_INFO;
        let n = match net.sub("", 0, all) {
            Ok(n) => n,
            Err(e) => {
                fs.close();
                return Err(format!("no handle to the network for it: {:?}", e));
            }
        };
        let (ours, theirs) = chan::pair().map_err(|e| format!("no channel for its output: {:?}", e))?;
        match task::spawn(text, [fs.handle(), n.handle()], Some(&theirs)) {
            Ok(c) => Ok((Arc::new(c), ours)),
            Err(e) => {
                fs.close();
                axiom::ring::close(n.handle());
                Err(format!("could not start {}: {}", text.split(' ').next().unwrap_or(""), e))
            }
        }
    }

    /// A job's output read into its log until it and all it started have
    /// ended; its timeouts kept; then its end written.
    fn watch(&self, job: Arc<Job>, ours: chan::End, child: Arc<task::Child>, total: Option<f64>, idle: Option<f64>) {
        let began = Instant::now();
        let secs = |s: f64| Duration::from_secs_f64(s.clamp(0.0, 1e8));
        let mut last_out = began;
        let mut last_save = began;
        let mut saved = 0;
        let mut why: Option<String> = None;
        let mut b = vec![0u8; chan::MSG_MAX];
        loop {
            match ours.recv(&mut b) {
                Ok(n) => {
                    job.append(&b[..n]);
                    last_out = Instant::now();
                }
                Err(Error::EMPTY) => {
                    let mut until = Instant::now() + SAVE_EVERY;
                    if why.is_none() {
                        if let Some(t) = total {
                            until = until.min(began + secs(t));
                        }
                        if let Some(t) = idle {
                            until = until.min(last_out + secs(t));
                        }
                    }
                    match ours.wait(Some(until)) {
                        Ok(()) | Err(Error::TIMEOUT) => {}
                        Err(e) => {
                            job.append(format!("fleet: waiting for its output: {}\n", e).as_bytes());
                            break;
                        }
                    }
                }
                Err(Error::PEER) => break,
                Err(e) => {
                    job.append(format!("fleet: reading its output: {}\n", e).as_bytes());
                    break;
                }
            }
            let now = Instant::now();
            if why.is_none() {
                if let Some(t) = total.filter(|&t| now >= began + secs(t)) {
                    why = Some(format!("timed out: still running after {} (--timeout)", minutes(t)));
                } else if let Some(t) = idle.filter(|&t| now >= last_out + secs(t)) {
                    why = Some(format!("timed out: no output for {} (--idle-timeout)", minutes(t)));
                }
                if let Some(w) = &why {
                    job.append(format!("fleet: {}; it is ended\n", w).as_bytes());
                    let _ = child.kill();
                }
            }
            if now - last_save >= SAVE_EVERY {
                let len = lock(&job.log).bytes.len();
                if len != saved {
                    saved = self.save_log(&job);
                }
                last_save = now;
            }
        }
        let code = match child.join(None) {
            Ok(c) => c,
            Err(e) => e.0 as i64,
        };
        drop(ours);
        *lock(&job.child) = None;
        let len = self.save_log(&job);
        if !job.is_final() {
            let state = if job.stop.load(Ordering::SeqCst) {
                "stopped"
            } else if code == 0 {
                "done"
            } else {
                "failed"
            };
            let mut fields = vec![
                ("state", Value::from(state)),
                ("exit", Int(code as i128)),
                ("ended", now_iso().into()),
                ("log_bytes", Int(len as i128)),
            ];
            if let Some(w) = why {
                fields.push(("reason", w.into()));
            }
            job.update(fields);
            self.save(&job);
        }
        println!("fleet: job {} ended: {}, {}", job.id, job.state(), code);
        job.poke();
    }

    /// stop_job's: ended, if it has not.
    pub fn stop(&self, job: &Arc<Job>) -> Value {
        if !job.is_final() {
            job.stop.store(true, Ordering::SeqCst);
            let child = lock(&job.child).clone();
            if let Some(c) = child {
                let _ = c.kill();
            }
            let until = Instant::now() + Duration::from_secs(5);
            while !job.is_final() && Instant::now() < until {
                let len = lock(&job.log).bytes.len();
                job.wait(len, Duration::from_millis(100));
            }
            if !job.is_final() {
                let len = self.save_log(job);
                job.update(vec![("state", "stopped".into()), ("ended", now_iso().into()), ("log_bytes", Int(len as i128))]);
                self.save(job);
            }
            println!("fleet: stopped job {}", job.id);
        }
        job.summary()
    }
}
