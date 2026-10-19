//! fleet: this computer as one of fleet's nodes, a self-managed one (fleet's
//! docs/protocol.md, section 7): it answers fleet's coordinator over TLS,
//! takes pushes into projects, runs jobs (Axiom's programs, each a child
//! of this one) and says how they did.
//!
//!   fleet [home]
//!
//! home (by default /Home/fleet, on the volume Axiom started from) holds
//! what `fleet add NAME --self-managed` made for it: node.json (its name,
//! its port, the SHA-256 of each client's token, the networks they come
//! from), cert.pem and key.pem (its P-256 identity, which the kernel's TLS
//! proves). It keeps projects/ (what was pushed) and jobs/ there.
//!
//! It answers the hello, ping, info, manifest, put, list, get, start, jobs,
//! log and stop; anything else is an unknown operation, as fleet expects of
//! a self-managed node. Transfers are raw (no zlib, no partial copies). A
//! job's argv is a program's name and its words (no word with a space), or
//! a path in its project to an .AXE; it is given its project's folder and
//! the network, and what it prints is its log. Its env, limits and grace
//! are taken and not used.
//!
//! The job `update <file> [<seconds>]` is fleet's own: the project's file,
//! a kernel.bin, is tried at the next start, and the machine restarts into
//! it. On that trial the first client's hello keeps it; with none in time
//! (600 s unless said), the machine restarts into the kernel it ran before.
//! So a machine no one is at takes a new Axiom over fleet, and a kernel
//! that cannot reach fleet is given up on its own.

mod jobs;
mod json;
mod sha256;
mod store;
mod wire;

use std::collections::BTreeSet;
use std::net::IpAddr;
use std::process::ExitCode;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use core::time::Duration;

use axiom::net::{self, Identity, Socket};
use axiom::time::Instant;
use axiom::{Error, Files, Net};

use jobs::{Jobs, Start};
use json::{Bool, Float, Int, List, Null, Object, Str, Value, obj};
use store::{Store, clean_path, differing, entries, entry_value};
use wire::{Closed, Conn, Fail, MAX_LINE, with};

axiom::entry!(wants = axiom::wants::FILES | axiom::wants::NET | axiom::wants::UPDATE);

const VERSION: &str = "0.1.0";
const PROTOCOL: i128 = 1;
const PORT: u16 = 47950;
/// The hello's line, at most: it comes before the token is known.
const HELLO_MAX: usize = 64 << 10;
/// A `log` piece, at most.
const CHUNK: usize = 1 << 20;

struct Client {
    name: String,
    token_sha256: String,
}

struct Node {
    name: String,
    code: String,
    since: f64,
    clients: Vec<Client>,
    allow: Vec<(IpAddr, u32)>,
    files: Files,
    net: Net,
    store: Store,
    jobs: Arc<Jobs>,
    /// The kernel is on trial: the first client's hello keeps it.
    trial: AtomicBool,
}

/// Python's round(x, 1).
fn round1(x: f64) -> f64 {
    (x * 10.0).round() / 10.0
}

fn cpu_name() -> String {
    use core::arch::x86_64::__cpuid;
    #[allow(unused_unsafe)]
    let b = unsafe {
        if __cpuid(0x8000_0000).eax < 0x8000_0004 {
            return "x86_64".into();
        }
        let mut b = Vec::new();
        for leaf in 0x8000_0002..=0x8000_0004u32 {
            let r = __cpuid(leaf);
            for x in [r.eax, r.ebx, r.ecx, r.edx] {
                b.extend_from_slice(&x.to_le_bytes());
            }
        }
        b
    };
    String::from_utf8_lossy(&b).trim_matches(|c: char| c == '\0' || c.is_whitespace()).to_string()
}

/// "a.b.c.d/n", "x::/n" or an address alone.
fn network(text: &str) -> Option<(IpAddr, u32)> {
    let (a, bits) = match text.split_once('/') {
        Some((a, b)) => (a, Some(b.parse::<u32>().ok()?)),
        None => (text, None),
    };
    let ip: IpAddr = a.parse().ok()?;
    let max = if ip.is_ipv4() { 32 } else { 128 };
    let bits = bits.unwrap_or(max);
    (bits <= max).then_some((ip, bits))
}

fn inside(ip: IpAddr, net: IpAddr, bits: u32) -> bool {
    match (ip, net) {
        (IpAddr::V4(a), IpAddr::V4(n)) => {
            let m = if bits == 0 { 0 } else { u32::MAX << (32 - bits) };
            u32::from(a) & m == u32::from(n) & m
        }
        (IpAddr::V6(a), IpAddr::V6(n)) => {
            let m = if bits == 0 { 0 } else { u128::MAX << (128 - bits) };
            u128::from(a) & m == u128::from(n) & m
        }
        _ => false,
    }
}

/// A request's field, there or KeyError as Python says it.
fn need<'a>(req: &'a Value, key: &str) -> Result<&'a Value, String> {
    req.get(key).ok_or_else(|| format!("KeyError({})", Str(key.to_string()).py_repr()))
}

/// Python's int() of a field, 0 if it is not there or false.
fn int_of(v: Option<&Value>) -> Result<i128, String> {
    match v {
        None => Ok(0),
        Some(v) if !v.truthy() => Ok(0),
        Some(Str(s)) => s.trim().parse().map_err(|_| format!("invalid literal for int() with base 10: {}", Str(s.clone()).py_repr())),
        Some(Float(f)) => Ok(f.trunc() as i128),
        Some(Bool(b)) => Ok(*b as i128),
        Some(v) => v.int().ok_or_else(|| format!("TypeError(\"int() can't take {}\")", v.py_repr())),
    }
}

impl Node {
    fn allowed(&self, ip: IpAddr) -> bool {
        if self.allow.is_empty() {
            return true;
        }
        let ip = match ip {
            IpAddr::V6(v) => v.to_ipv4_mapped().map_or(IpAddr::V6(v), IpAddr::V4),
            v4 => v4,
        };
        ip.is_loopback() || self.allow.iter().any(|&(n, bits)| inside(ip, n, bits))
    }

    fn client_named(&self, token: Option<&Value>) -> Option<String> {
        let token = token?.str()?;
        let digest = sha256::hex(&sha256::sha256(token.as_bytes()));
        let mut found = None;
        for c in &self.clients {
            if sha256::same_secret(digest.as_bytes(), c.token_sha256.as_bytes()) && found.is_none() {
                found = Some(c.name.clone());
            }
        }
        found
    }

    /// One connection, from its accept to its end.
    fn serve(&self, sock: Socket, accepted: Instant) {
        let peer = match sock.addrs() {
            Ok(a) => net::ip(a.peer),
            Err(_) => return,
        };
        if !self.allowed(peer) {
            println!("fleet: refused {}: not an allowed address", peer);
            return;
        }
        let mut c = Conn::new(sock);
        c.deadline = Some(accepted + Duration::from_secs(20));
        if c.socket().wait_send(c.deadline).is_err() {
            return;
        }
        match c.socket().status() {
            Ok(s) if !s.failed() => {}
            Ok(s) => {
                println!("fleet: {}: no TLS ({}, {})", peer, net::why_text(s.why), s.tls_error);
                return;
            }
            Err(_) => return,
        }
        let Ok(hello) = c.message(HELLO_MAX) else { return };
        let Some(client) = self.client_named(hello.get("token")) else {
            println!("fleet: refused {}: wrong token", peer);
            let _ = c.send(&obj([("error", "not_authorized".into())]));
            return;
        };
        let spoken = matches!(hello.get("fleet"), Some(Int(PROTOCOL)) | Some(Bool(true)))
            || matches!(hello.get("fleet"), Some(Float(f)) if *f == PROTOCOL as f64);
        if !spoken {
            let said = hello.get("fleet").map_or("None".to_string(), Value::py_str);
            let _ = c.send(&obj([("error", format!("protocol {} not spoken here", said).into())]));
            return;
        }
        let reply = obj([
            ("ok", Bool(true)),
            ("node", self.name.clone().into()),
            ("version", VERSION.into()),
            ("code", self.code.clone().into()),
            ("protocol", Int(PROTOCOL)),
            ("since", Float(self.since)),
        ]);
        if c.send(&reply).is_err() {
            return;
        }
        if self.trial.swap(false, Ordering::SeqCst) {
            match self.files.keep_kernel() {
                Ok(()) => println!("fleet: the kernel on trial is kept: {} reached this node", client),
                Err(e) => println!("fleet: the kernel on trial could not be kept: {}", e),
            }
        }
        c.deadline = None;
        while self.request(&mut c, &client, peer) {}
    }

    /// One request answered -> whether to go on.
    fn request(&self, c: &mut Conn, client: &str, peer: IpAddr) -> bool {
        let Ok(req) = c.message(MAX_LINE) else { return false };
        let id = req.get("id").cloned().unwrap_or(Null);
        let op = req.get("op").cloned().unwrap_or(Null);
        let done = match op.str().unwrap_or("") {
            "ping" => c.send(&obj([("id", id.clone()), ("ok", Bool(true))])).map_err(Fail::from),
            "info" => self.info(c, &id),
            "manifest" => self.manifest(c, &id, &req),
            "put" => self.put(c, &id, &req),
            "list" => self.list(c, &id, &req),
            "get" => self.get(c, &id, &req),
            "start" => self.start(c, &id, &req, client),
            "jobs" => self.job_list(c, &id, &req),
            "log" => self.log(c, &id, &req),
            "stop" => self.stop(c, &id, &req),
            _ => Err(Fail::Refuse(format!("unknown operation {}", op.py_repr()))),
        };
        match done {
            Ok(()) => true,
            Err(Fail::Close(Closed(why))) => {
                if why != "the connection closed" {
                    println!("fleet: the connection from {} ended in {}: {}", peer, op.py_str(), why);
                }
                false
            }
            Err(Fail::Refuse(why)) => {
                if c.send(&obj([("id", id), ("error", why.into())])).is_err() {
                    return false;
                }
                // Its bytes may be left unread: the stream is out of step.
                let bytes = req.get("bytes").is_some_and(Value::truthy);
                !(bytes || req.get("zlib").is_some_and(Value::truthy) && op.str() == Some("put"))
            }
        }
    }

    fn info(&self, c: &mut Conn, id: &Value) -> Result<(), Fail> {
        let (ram, free) = axiom::sys::ram();
        let gb = |b: u64| Float(round1(b as f64 / (1u64 << 30) as f64));
        let vols = self.files.volumes().unwrap_or_default();
        let boot = vols.iter().find(|v| v.flags & axiom::files::VOL_BOOT != 0);
        let running: Vec<_> =
            self.jobs.list().into_iter().filter(|j| matches!(j.state().as_str(), "starting" | "running")).collect();
        let busy: BTreeSet<String> =
            running.iter().filter_map(|j| j.get("project").str().map(String::from)).collect();
        let here = c.socket().addrs().ok().map(|a| net::ip(a.local).to_string());
        let os_version = match self.files.kernel() {
            Ok(k) => match k.running {
                Some(s) => format!("Axiom (kernel {}{})", s, if k.trial { ", on trial" } else { "" }),
                None => "Axiom".to_string(),
            },
            Err(_) => "Axiom".to_string(),
        };
        let reply = obj([
            ("id", id.clone()),
            ("node", self.name.clone().into()),
            ("version", VERSION.into()),
            ("code", self.code.clone().into()),
            ("protocol", Int(PROTOCOL)),
            ("os", "axiom".into()),
            ("os_version", os_version.into()),
            ("arch", "x86_64".into()),
            ("hostname", self.name.clone().into()),
            ("cpu", cpu_name().into()),
            ("threads", Int(axiom::sys::cpus() as i128)),
            ("load", Null),
            ("ram_gb", gb(ram)),
            ("ram_free_gb", gb(free)),
            ("commit_gb", Null),
            ("commit_free_gb", Null),
            ("gpus", List(vec![])),
            (
                "battery",
                axiom::sys::battery().map_or(Null, |b| {
                    obj([("percent", Int(b.percent as i128)), ("plugged", Bool(b.plugged))])
                }),
            ),
            ("disk_free_gb", boot.map_or(Null, |v| gb(v.free))),
            ("disk_total_gb", boot.map_or(Null, |v| gb(v.bytes))),
            ("temp_c", axiom::sys::cpu_temp().map_or(Null, |t| Float(t as f64))),
            ("uptime_s", Int((axiom::sys::uptime_ms() / 1000) as i128)),
            ("addresses", here.into_iter().collect::<Vec<_>>().into()),
            ("desktop", Null),
            ("firewall_asks", Null),
            ("jobs_running", Int(running.len() as i128)),
            ("projects_running", busy.into_iter().collect::<Vec<_>>().into()),
            ("projects", self.store.projects().into()),
            ("admin", Bool(false)),
            ("thermal", Null),
        ]);
        Ok(c.send(&reply)?)
    }

    fn manifest(&self, c: &mut Conn, id: &Value, req: &Value) -> Result<(), Fail> {
        let project = need(req, "project")?;
        let dir = self.store.project(project, true)?;
        let wanted = entries(need(req, "files")?)?;
        let have = self.store.walk(&dir, "")?;
        let mut need_ = differing(&wanted, &have);
        // While a job of the project runs, a file here newer than the pushed
        // one is its output: kept.
        let mut kept = Vec::new();
        let busy = self.jobs.list().iter().any(|j| {
            j.get("project").str() == project.str() && !j.is_final()
        });
        if !need_.is_empty() && busy {
            let here: std::collections::HashMap<&str, i128> = have.iter().map(|(p, _, m)| (p.as_str(), *m)).collect();
            let theirs: std::collections::HashMap<&str, i128> =
                wanted.iter().map(|(p, _, m)| (p.as_str(), *m)).collect();
            kept = need_
                .iter()
                .filter(|p| here.get(p.as_str()).is_some_and(|&h| h > theirs[p.as_str()] + store::SAME_TIME_NS))
                .cloned()
                .collect();
            need_.retain(|p| !kept.contains(p));
        }
        let dirs = match req.get("mirror_dirs") {
            None => Vec::new(),
            Some(v) if !v.truthy() => Vec::new(),
            Some(List(ds)) if ds.iter().all(|d| d.str().is_some()) => ds
                .iter()
                .map(|d| clean_path(&Str(d.str().unwrap_or("").replace('\\', "/").trim_matches('/').to_string())))
                .collect::<Result<Vec<_>, _>>()?,
            Some(_) => return Err("mirror_dirs is a list of folders in the project".into()),
        };
        let mirror = req.get("mirror").is_some_and(Value::truthy);
        let mut deleted = 0;
        if mirror || !dirs.is_empty() {
            let keep: BTreeSet<&str> = wanted.iter().map(|(p, _, _)| p.as_str()).collect();
            let mut gone: Vec<String> =
                have.iter().filter(|(p, _, _)| !keep.contains(p.as_str())).map(|(p, _, _)| p.clone()).collect();
            if !mirror {
                gone.retain(|p| dirs.iter().any(|d| p.starts_with(&format!("{}/", d))));
            }
            deleted = self.store.remove_files(&dir, &gone, if mirror { None } else { Some(&dirs) });
        }
        let kept_count = kept.len();
        kept.truncate(50);
        Ok(c.send(&obj([
            ("id", id.clone()),
            ("need", need_.into()),
            ("deleted", deleted.into()),
            ("kept", kept.into()),
            ("kept_count", kept_count.into()),
            ("partial", Object(vec![])),
        ]))?)
    }

    fn put(&self, c: &mut Conn, id: &Value, req: &Value) -> Result<(), Fail> {
        let dir = self.store.project(need(req, "project")?, true)?;
        let files = entries(need(req, "files")?)?;
        if req.get("zlib").is_some_and(Value::truthy) {
            return Err(format!("{} takes no compressed streams: send them raw", self.name).into());
        }
        let total: i128 = files.iter().map(|e| e.1 as i128).sum();
        if total != req.get("bytes").and_then(Value::int).unwrap_or(0) {
            return Err("the files' sizes do not add up to the bytes sent".into());
        }
        let mut places = Vec::with_capacity(files.len());
        for (path, size, _) in &files {
            places.push(self.store.full(&dir, path)?);
            if *size as usize > store::FILE_MAX {
                return Err(format!("{} is {} bytes: a file on Axiom is 16 MiB at most", path, size).into());
            }
        }
        let mut made = BTreeSet::new();
        for ((path, size, _), place) in files.iter().zip(&places) {
            self.store.make_parents(&dir, path, &mut made);
            let mut data = Vec::with_capacity(*size as usize);
            c.take(*size as usize, |b| data.extend_from_slice(b))?;
            self.files
                .write(place, &data)
                .map_err(|e| format!("OSError('writing {}: {}')", path, e))?;
        }
        self.store.note_written(&dir, &files);
        Ok(c.send(&obj([("id", id.clone()), ("ok", Bool(true)), ("count", files.len().into())]))?)
    }

    fn list(&self, c: &mut Conn, id: &Value, req: &Value) -> Result<(), Fail> {
        let project = need(req, "project")?;
        let dir = self.store.project(project, false)?;
        let below = match req.get("path") {
            Some(v) if v.truthy() => clean_path(v)?,
            _ => String::new(),
        };
        if !below.is_empty() && self.store.lookup(&dir, &below).is_none() {
            return Err(format!("no {} in project {} on {}", below, project.py_str(), self.name).into());
        }
        let files = self.store.walk(&dir, &below)?;
        Ok(c.send(&obj([("id", id.clone()), ("files", List(files.iter().map(entry_value).collect()))]))?)
    }

    fn get(&self, c: &mut Conn, id: &Value, req: &Value) -> Result<(), Fail> {
        let dir = self.store.project(need(req, "project")?, false)?;
        let paths = need(req, "files")?.list().ok_or("TypeError('files is a list of paths')")?;
        let mut files = Vec::with_capacity(paths.len());
        for p in paths {
            let rel = clean_path(p)?;
            match self.store.walk(&dir, &rel) {
                Ok(mut v) if v.len() == 1 && v[0].0 == rel => files.push(v.remove(0)),
                Ok(_) => return Err(format!("IsADirectoryError(21, 'Is a directory')").into()),
                Err(e) => return Err(e.into()),
            }
        }
        let total: u64 = files.iter().map(|e| e.1).sum();
        c.send(&obj([
            ("id", id.clone()),
            ("files", List(files.iter().map(entry_value).collect())),
            ("bytes", Int(total as i128)),
        ]))?;
        let mut changed = 0;
        for (rel, size, _) in &files {
            let mut data = self.files.read(&format!("{}/{}", dir, rel)).unwrap_or_default();
            if data.len() as u64 != *size {
                changed += 1;
                data.resize(*size as usize, 0); // padded, or cut, to the size listed
            }
            c.write(&data)?;
        }
        if changed > 0 {
            println!("fleet: {} files changed while they were sent", changed);
        }
        Ok(())
    }

    fn start(&self, c: &mut Conn, id: &Value, req: &Value, client: &str) -> Result<(), Fail> {
        let job = need(req, "job")?;
        let job = jobs::job_ok(job).ok_or_else(|| format!("job id not allowed: {}", job.py_repr()))?.to_string();
        let refuse = |what: &str| -> Fail { format!("{} does not take {}", self.name, what).into() };
        if req.field("cwd").is_some() {
            return Err(refuse("--cwd: a job runs in its project"));
        }
        let project = need(req, "project")?;
        let dir = self.store.project(project, false)?;
        let argv: Vec<String> = match need(req, "argv")? {
            List(a) if !a.is_empty() && a.iter().all(|x| x.str().is_some_and(|s| s.len() < 32768)) => {
                a.iter().map(|x| x.str().unwrap_or("").to_string()).collect()
            }
            _ => return Err("a job needs a command: a list of strings".into()),
        };
        if argv[0].is_empty() {
            return Err("a job needs a command: a list of strings".into());
        }
        if let Some(w) = argv.iter().find(|w| w.is_empty() || w.contains([' ', '\t', '\n', '\r'])) {
            return Err(format!("{} takes words, not {}: an Axiom program's arguments have no spaces",
                               self.name, Str(w.clone()).py_repr()).into());
        }
        let env = match req.get("env") {
            None => Object(vec![]),
            Some(v) if !v.truthy() => Object(vec![]),
            Some(Object(f)) if f.iter().all(|(_, v)| v.str().is_some()) => Object(f.clone()),
            Some(_) => return Err("a job's environment maps names to strings".into()),
        };
        let numbers = |key: &str, allowed: &[&str], max: f64, why: &str| -> Result<Value, Fail> {
            match req.get(key) {
                None => Ok(Object(vec![])),
                Some(v) if !v.truthy() => Ok(Object(vec![])),
                Some(Object(f))
                    if f.iter().all(|(k, v)| {
                        allowed.contains(&k.as_str()) && v.num().is_some_and(|x| x > 0.0 && x < max)
                    }) =>
                {
                    Ok(Object(f.clone()))
                }
                Some(_) => Err(why.into()),
            }
        };
        let timeouts = numbers("timeouts", &["total_s", "idle_s"], 1e8, "timeouts are {total_s: S, idle_s: S}, both positive")?;
        let limits = numbers("limits", &["cpus", "ram_gb"], 1e6, "limits are {cpus: N, ram_gb: G}, both positive")?;
        if req.get("admin").is_some_and(Value::truthy) {
            return Err(format!("{} takes no admin jobs: it joined without administrator rights", self.name).into());
        }
        for (key, what) in [("fail_on", "--fail-on"), ("script", "--script")] {
            if req.field(key).is_some() {
                return Err(refuse(what));
            }
        }
        for (key, what) in [("xdg", "--xdg"), ("desktop", "--own-desktop")] {
            if req.get(key).is_some_and(Value::truthy) {
                return Err(refuse(what));
            }
        }
        let dir_text = match dir.split_once(':') {
            Some((_, rest)) => rest.to_string(),
            None => dir.clone(),
        };
        let s = Start {
            id: job.clone(),
            project: project.str().unwrap_or("").to_string(),
            dir,
            dir_text,
            argv,
            env,
            total_s: timeouts.get("total_s").and_then(Value::num),
            idle_s: timeouts.get("idle_s").and_then(Value::num),
            limits,
            timeouts,
            client: client.to_string(),
        };
        let pid = self.jobs.start(s, self.files, self.net)?;
        Ok(c.send(&obj([("id", id.clone()), ("job", job.into()), ("pid", Int(pid as i128)), ("node", self.name.clone().into())]))?)
    }

    fn job_list(&self, c: &mut Conn, id: &Value, req: &Value) -> Result<(), Fail> {
        let summary = |j: &jobs::Job| {
            let s = j.summary();
            if j.state() == "running" { with(s, "progress", Null) } else { s }
        };
        let all = self.jobs.list();
        match req.get("ids") {
            None | Some(Null) => {
                let project = req.field("project");
                if let Some(p) = project {
                    if store::project_ok(p).is_none() {
                        return Err(format!("project name not allowed: {}", p.py_repr()).into());
                    }
                }
                let recent = match req.field("recent") {
                    None => None,
                    Some(Int(n)) if (0..=100000).contains(n) => Some(*n as usize),
                    Some(_) => return Err("recent: a number of jobs, 0 to 100000".into()),
                };
                let mut v: Vec<_> =
                    all.iter().filter(|j| project.is_none_or(|p| j.get("project").str() == p.str())).collect();
                if let Some(n) = recent {
                    let ended: Vec<&String> = v.iter().filter(|j| !matches!(j.state().as_str(), "starting" | "running")).map(|j| &j.id).collect();
                    let kept: BTreeSet<&String> = ended[ended.len() - n.min(ended.len())..].iter().copied().collect();
                    v.retain(|j| matches!(j.state().as_str(), "starting" | "running") || kept.contains(&j.id));
                }
                let list = List(v.iter().map(|j| summary(j)).collect());
                Ok(c.send(&obj([("id", id.clone()), ("jobs", list)]))?)
            }
            Some(List(ids)) if ids.len() <= 10000 && ids.iter().all(|i| jobs::job_ok(i).is_some()) => {
                let wanted: BTreeSet<&str> = ids.iter().filter_map(Value::str).collect();
                let list = List(all.iter().filter(|j| wanted.contains(j.id.as_str())).map(|j| summary(j)).collect());
                Ok(c.send(&obj([("id", id.clone()), ("jobs", list), ("only", Bool(true))]))?)
            }
            Some(_) => Err("ids: a list of job ids".into()),
        }
    }

    fn log(&self, c: &mut Conn, id: &Value, req: &Value) -> Result<(), Fail> {
        let job = self.jobs.get(need(req, "job")?)?;
        let mut offset = int_of(req.get("offset"))?.max(0) as usize;
        let follow = req.get("follow").is_some_and(Value::truthy);
        let tail = int_of(req.get("tail"))?;
        if tail > 0 && offset == 0 {
            offset = self.jobs.log_len(&job).saturating_sub(tail as usize);
        }
        let mut quiet = Instant::now();
        loop {
            let done = job.is_final();
            let rest = self.jobs.log_from(&job, offset);
            for piece in rest.chunks(CHUNK) {
                c.send_with(obj([("id", id.clone()), ("more", Bool(true))]), piece)?;
                offset += piece.len();
                quiet = Instant::now();
            }
            if done || !follow {
                return Ok(c.send(&obj([
                    ("id", id.clone()),
                    ("more", Bool(false)),
                    ("offset", offset.into()),
                    ("job", job.summary()),
                ]))?);
            }
            if quiet.elapsed() > Duration::from_secs(20) {
                c.send(&obj([("id", id.clone()), ("more", Bool(true))]))?;
                quiet = Instant::now();
            }
            job.wait(offset, Duration::from_millis(500));
        }
    }

    fn stop(&self, c: &mut Conn, id: &Value, req: &Value) -> Result<(), Fail> {
        match req.get("grace") {
            None => {}
            Some(v) if !v.truthy() => {}
            Some(v) if matches!(v, Int(_) | Float(_)) && v.num().is_some_and(|g| (0.0..=3600.0).contains(&g)) => {}
            Some(_) => return Err("grace: seconds to wait after asking the job to end, 0 to 3600".into()),
        }
        let job = self.jobs.get(need(req, "job")?)?;
        let summary = self.jobs.stop(&job);
        Ok(c.send(&obj([("id", id.clone()), ("job", summary)]))?)
    }
}

/// Zeroes over what a key was in.
fn wipe(mut b: Vec<u8>) {
    for x in b.iter_mut() {
        unsafe { core::ptr::write_volatile(x, 0) };
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Ok(files) = Files::get() else {
        println!("fleet: no files given");
        return ExitCode::from(1);
    };
    let Ok(net) = Net::get() else {
        println!("fleet: no network given");
        return ExitCode::from(1);
    };
    let vol = match files.home() {
        Ok(h) => h.split_once(':').map(|(v, _)| v.to_string()).unwrap_or_default(),
        Err(e) => {
            println!("fleet: no boot volume: {:?}", e);
            return ExitCode::from(1);
        }
    };
    let home = match args.first() {
        Some(h) if h.contains(':') => h.clone(),
        Some(h) => format!("{}:{}", vol, if h.starts_with('/') { h.clone() } else { format!("/{}", h) }),
        None => format!("{}:/Home/fleet", vol),
    };
    let config = match files.read(&format!("{}/node.json", home)).map(|b| json::parse(&b)) {
        Ok(Ok(v @ Object(_))) => v,
        Ok(_) => {
            println!("fleet: {}/node.json is not a JSON object", home);
            return ExitCode::from(1);
        }
        Err(e) => {
            println!("fleet: no {}/node.json ({:?}): `fleet add NAME --self-managed` makes it", home, e);
            return ExitCode::from(1);
        }
    };
    let Some(name) = config.get("name").and_then(Value::str).map(String::from) else {
        println!("fleet: node.json has no name");
        return ExitCode::from(1);
    };
    let port = config.get("port").and_then(Value::int).map_or(PORT, |p| p as u16);
    let clients: Vec<Client> = config
        .get("clients")
        .and_then(Value::list)
        .unwrap_or(&[])
        .iter()
        .filter_map(|c| {
            Some(Client {
                name: c.get("name")?.str()?.to_string(),
                token_sha256: c.get("token_sha256")?.str()?.to_string(),
            })
        })
        .collect();
    let mut allow = Vec::new();
    for n in config.get("allow").and_then(Value::list).unwrap_or(&[]) {
        match n.str().and_then(network) {
            Some(x) => allow.push(x),
            None => println!("fleet: node.json's allow: {} is not a network; left out", n.encode()),
        }
    }

    let certs = files.read(&format!("{}/cert.pem", home));
    let key = files.read(&format!("{}/key.pem", home));
    let (Ok(certs), Ok(key)) = (certs, key) else {
        println!("fleet: {} needs cert.pem and key.pem", home);
        return ExitCode::from(1);
    };
    let id = Identity::from_pem(&String::from_utf8_lossy(&certs), core::str::from_utf8(&key).unwrap_or(""));
    wipe(key);
    let Ok(id) = id else {
        println!("fleet: cert.pem and key.pem are not a P-256 key and its certificate");
        return ExitCode::from(1);
    };
    let listener = match net.listen_tls(port, &id) {
        Ok(l) => l,
        Err(e) => {
            println!("fleet: could not listen on port {}: {:?}", port, e);
            return ExitCode::from(1);
        }
    };
    drop(id);
    let _ = listener.wait_send(None);
    match listener.status() {
        Ok(s) if !s.failed() => {}
        Ok(s) => {
            println!("fleet: could not listen on port {}: {}", port, net::why_text(s.why));
            return ExitCode::from(1);
        }
        Err(e) => {
            println!("fleet: could not listen on port {}: {:?}", port, e);
            return ExitCode::from(1);
        }
    }

    let code = match files.read(&format!("{}:/EFI/AXIOM/FLEET.AXE", vol)) {
        Ok(b) => sha256::hex(&sha256::sha256(&b))[..12].to_string(),
        Err(_) => sha256::hex(&sha256::sha256(VERSION.as_bytes()))[..12].to_string(),
    };
    let jobs = Jobs::load(files, format!("{}/jobs", home), name.clone());
    let node = Arc::new(Node {
        store: Store::new(files, format!("{}/projects", home), name.clone()),
        name,
        code,
        since: axiom::sys::clock_us() as f64 / 1e6,
        clients,
        allow,
        files,
        net,
        jobs,
        trial: AtomicBool::new(false),
    });
    println!("fleet: node {} listening on port {}, code {}, {} clients", node.name, port, node.code, node.clients.len());
    match files.kernel() {
        Ok(k) if k.trial => {
            node.trial.store(true, Ordering::SeqCst);
            println!("fleet: kernel {} is on trial: the first client to reach this node keeps it", k.running.unwrap_or('?'));
        }
        Ok(_) => {}
        Err(e) => println!("fleet: no new kernels here: {}", e),
    }

    loop {
        match listener.accept() {
            Ok(s) => {
                let at = Instant::now();
                let n = node.clone();
                let t = std::thread::Builder::new().stack_size(1 << 20).spawn(move || n.serve(s, at));
                if let Err(e) = t {
                    println!("fleet: no thread for a connection: {}", e);
                }
            }
            Err(Error::EMPTY) => {
                if let Err(e) = listener.wait_recv(None) {
                    println!("fleet: listening: {:?}", e);
                    std::thread::sleep(Duration::from_secs(1));
                }
            }
            Err(e) => {
                println!("fleet: accepting: {:?}", e);
                if listener.status().is_ok_and(|s| s.failed()) {
                    return ExitCode::from(1);
                }
                std::thread::sleep(Duration::from_secs(1));
            }
        }
    }
}

