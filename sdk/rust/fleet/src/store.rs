//! Projects: the folders pushes write, in HOME/projects, walked and
//! written as fleet's node does (its protocol.py's walk, clean_path,
//! differing; node.py's manifest, put, list, get).
//!
//! A FAT keeps a file's time to the second, and Axiom sets it as it
//! writes. So each project keeps, in .fleet/files.json (never walked or
//! copied), each pushed file's size and pushed time with the time the
//! FAT gave it: a file still that size and time is the pushed one, and
//! listed with the pushed time; one written since (by a job) is listed
//! with its own.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::sync::{Arc, Mutex};

use axiom::Files;
use axiom::files::{DirEntry, Written};

use crate::json::{self, Int, List, Object, Str, Value};

/// fleet's SKIP_DIRS and SKIP_SUFFIXES: never copied either way.
const SKIP_DIRS: [&str; 15] = [
    ".git", ".hg", ".svn", ".venv", "venv", "__pycache__", "node_modules", ".mypy_cache", ".pytest_cache",
    ".ruff_cache", ".idea", ".vscode", ".tox", "target", ".fleet",
];
const SKIP_SUFFIXES: [&str; 2] = [".pyc", ".fleet-part"];
/// fleet's SAME_TIME_NS.
pub const SAME_TIME_NS: i128 = 2_000_000;
/// A path as the kernel takes it, at most (FS_PATH less its NUL).
const PATH_MAX: usize = 255;
/// A file Axiom reads or writes, at most.
pub const FILE_MAX: usize = 16 << 20;

/// [path, size, mtime_ns]
pub type Entry = (String, u64, i128);

pub struct Store {
    pub files: Files,
    /// "vol<n>:/Home/fleet/projects"
    pub root: String,
    node: String,
    /// Each project's .fleet/files.json, once read: by lowercased path.
    index: Mutex<HashMap<String, Arc<Mutex<Index>>>>,
}

#[derive(Default)]
pub struct Index {
    /// path (lowercased) -> (size, pushed time, the FAT's stamp)
    pub kept: BTreeMap<String, (u64, i128, i64)>,
}

pub fn project_ok(name: &Value) -> Option<&str> {
    let s = name.str()?;
    (1..=40).contains(&s.len()).then_some(())?;
    s.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'-').then_some(s)
}

/// clean_path's: a relative POSIX path, nothing outside, nothing odd.
pub fn clean_path(v: &Value) -> Result<String, String> {
    let bad = || format!("path not allowed: {}", v.py_repr());
    let s = v.str().ok_or_else(bad)?;
    if s.is_empty() || s.chars().count() > 1000 || s.contains(['\\', ':', '\0']) || s.starts_with('/') {
        return Err(bad());
    }
    if s.split('/').any(|p| p.is_empty() || p == "." || p == "..") {
        return Err(bad());
    }
    Ok(s.to_string())
}

/// A stamp's seconds since 1970 (Axiom's FAT times are UTC).
pub fn unix_secs(w: &Written) -> i64 {
    if w.year == 0 {
        return 0;
    }
    days_from_civil(w.year as i64, w.month as i64, w.day as i64) * 86400
        + w.hour as i64 * 3600
        + w.min as i64 * 60
        + w.sec as i64
}

fn stamp(w: &Written) -> i64 {
    ((((w.year as i64 * 100 + w.month as i64) * 100 + w.day as i64) * 100 + w.hour as i64) * 100 + w.min as i64) * 100
        + w.sec as i64
}

/// Days since 1970-01-01 (Howard Hinnant's).
pub fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

/// (year, month, day) of days since 1970.
pub fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (yoe + era * 400 + (m <= 2) as i64, m, d)
}

/// .fleetignore's rules: (negated, folders only, anchored, pattern).
type Rules = Vec<(bool, bool, Vec<Tok>)>;

#[derive(Clone, Debug, PartialEq)]
enum Tok {
    /// (?:.*/)?
    AnyDirs,
    /// .*
    Any,
    /// [^/]*
    Star,
    /// [^/]
    One,
    Ch(char),
}

fn glob(pattern: &str, anchored: bool) -> Vec<Tok> {
    let mut out = Vec::new();
    if !anchored {
        out.push(Tok::AnyDirs);
    }
    let c: Vec<char> = pattern.chars().collect();
    let mut i = 0;
    while i < c.len() {
        if c[i] == '*' && c.get(i + 1) == Some(&'*') {
            if c.get(i + 2) == Some(&'/') {
                out.push(Tok::AnyDirs);
                i += 3;
            } else {
                out.push(Tok::Any);
                i += 2;
            }
        } else if c[i] == '*' {
            out.push(Tok::Star);
            i += 1;
        } else if c[i] == '?' {
            out.push(Tok::One);
            i += 1;
        } else {
            out.push(Tok::Ch(c[i]));
            i += 1;
        }
    }
    out
}

fn matches(p: &[Tok], s: &[char]) -> bool {
    match p.first() {
        None => s.is_empty(),
        Some(Tok::Ch(c)) => s.first() == Some(c) && matches(&p[1..], &s[1..]),
        Some(Tok::One) => s.first().is_some_and(|&c| c != '/') && matches(&p[1..], &s[1..]),
        Some(Tok::Star) => {
            let mut i = 0;
            loop {
                if matches(&p[1..], &s[i..]) {
                    return true;
                }
                if i == s.len() || s[i] == '/' {
                    return false;
                }
                i += 1;
            }
        }
        Some(Tok::Any) => (0..=s.len()).any(|i| matches(&p[1..], &s[i..])),
        Some(Tok::AnyDirs) => {
            if matches(&p[1..], s) {
                return true;
            }
            (0..s.len()).any(|i| s[i] == '/' && matches(&p[1..], &s[i + 1..]))
        }
    }
}

fn ignore_rules(text: &str) -> Rules {
    let mut rules = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let negated = line.starts_with('!');
        let line = if negated { &line[1..] } else { line };
        let folders = line.ends_with('/');
        let line = if folders { line.trim_matches('/') } else { line };
        let anchored = line.contains('/');
        rules.push((negated, folders, glob(line.trim_start_matches('/'), anchored)));
    }
    rules
}

fn ignored(rules: &Rules, relative: &str, folder: bool) -> bool {
    let s: Vec<char> = relative.chars().collect();
    let mut verdict = false;
    for (negated, folders_only, p) in rules {
        if *folders_only && !folder {
            continue;
        }
        if matches(p, &s) {
            verdict = !negated;
        }
    }
    verdict
}

impl Store {
    pub fn new(files: Files, root: String, node: String) -> Store {
        Store { files, root, node, index: Mutex::new(HashMap::new()) }
    }

    /// A project's folder; made with `create`, else it must be there.
    pub fn project(&self, name: &Value, create: bool) -> Result<String, String> {
        let p = project_ok(name).ok_or_else(|| format!("project name not allowed: {}", name.py_repr()))?;
        let dir = format!("{}/{}", self.root, p);
        if self.files.list(&dir).is_ok() {
            return Ok(dir);
        }
        if !create {
            return Err(format!("no project {} on {}: push it first", p, self.node));
        }
        let _ = self.files.mkdir(&self.root);
        self.files.mkdir(&dir).map_err(|e| format!("OSError('making {}: {:?}')", p, e))?;
        Ok(dir)
    }

    pub fn projects(&self) -> Vec<String> {
        let mut v: Vec<String> = match self.files.list(&self.root) {
            Ok(l) => l.into_iter().filter(|e| e.is_dir() && !e.name.starts_with('.')).map(|e| e.name).collect(),
            Err(_) => Vec::new(),
        };
        v.sort();
        v
    }

    /// `rel` under `dir`, as the kernel takes it.
    pub fn full(&self, dir: &str, rel: &str) -> Result<String, String> {
        let p = format!("{}/{}", dir, rel);
        if p.len() > PATH_MAX {
            return Err(format!("path too long for Axiom ({} bytes in all, at most {}): {}", p.len(), PATH_MAX,
                               Str(rel.to_string()).py_repr()));
        }
        Ok(p)
    }

    pub fn index(&self, dir: &str) -> Arc<Mutex<Index>> {
        let mut all = self.index.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(i) = all.get(dir) {
            return i.clone();
        }
        let mut index = Index::default();
        if let Ok(b) = self.files.read(&format!("{}/.fleet/files.json", dir)) {
            if let Ok(Object(fields)) = json::parse(&b) {
                for (k, v) in fields {
                    if let Some([s, m, t]) = v.list() {
                        if let (Some(s), Some(m), Some(t)) = (s.int(), m.int(), t.int()) {
                            index.kept.insert(k, (s as u64, m, t as i64));
                        }
                    }
                }
            }
        }
        let i = Arc::new(Mutex::new(index));
        all.insert(dir.to_string(), i.clone());
        i
    }

    pub fn save_index(&self, dir: &str, index: &Index) {
        let v = Object(
            index
                .kept
                .iter()
                .map(|(k, (s, m, t))| (k.clone(), List(vec![Int(*s as i128), Int(*m), Int(*t as i128)])))
                .collect(),
        );
        let _ = self.files.mkdir(&format!("{}/.fleet", dir));
        if let Err(e) = self.files.write(&format!("{}/.fleet/files.json", dir), v.encode().as_bytes()) {
            println!("fleet: could not keep {}'s file times: {:?}", dir, e);
        }
    }

    /// What a listing says of `rel` under `dir`, if it is there.
    pub fn lookup(&self, dir: &str, rel: &str) -> Option<DirEntry> {
        let (parent, name) = match rel.rsplit_once('/') {
            Some((p, n)) => (format!("{}/{}", dir, p), n),
            None => (dir.to_string(), rel),
        };
        self.files.list(&parent).ok()?.into_iter().find(|e| e.name.eq_ignore_ascii_case(name))
    }

    fn time_of(&self, index: &Index, rel: &str, e: &DirEntry) -> i128 {
        match index.kept.get(&rel.to_lowercase()) {
            Some(&(size, pushed, st)) if size == e.size && st == stamp(&e.written) => pushed,
            _ => unix_secs(&e.written) as i128 * 1_000_000_000,
        }
    }

    /// walk's: every file fleet copies under `dir` (or its `below`, which
    /// may name one file), sorted.
    pub fn walk(&self, dir: &str, below: &str) -> Result<Vec<Entry>, String> {
        let index = self.index(dir);
        let index = index.lock().unwrap_or_else(|e| e.into_inner());
        let rules = match self.files.read(&format!("{}/.fleetignore", dir)) {
            Ok(b) => ignore_rules(&String::from_utf8_lossy(&b)),
            Err(_) => Vec::new(),
        };
        let mut found = Vec::new();
        if !below.is_empty() {
            match self.lookup(dir, below) {
                Some(e) if !e.is_dir() => {
                    return Ok(vec![(below.to_string(), e.size, self.time_of(&index, below, &e))]);
                }
                Some(_) => {}
                None => return Err(format!("FileNotFoundError(2, 'No such file or directory')")),
            }
        }
        let mut todo = vec![below.to_string()];
        while let Some(rel_dir) = todo.pop() {
            let at = if rel_dir.is_empty() { dir.to_string() } else { format!("{}/{}", dir, rel_dir) };
            let Ok(list) = self.files.list(&at) else { continue };
            for e in list {
                if e.name == "." || e.name == ".." {
                    continue;
                }
                let rel = if rel_dir.is_empty() { e.name.clone() } else { format!("{}/{}", rel_dir, e.name) };
                if e.is_dir() {
                    if SKIP_DIRS.contains(&e.name.as_str()) || (!rules.is_empty() && ignored(&rules, &rel, true)) {
                        continue;
                    }
                    todo.push(rel);
                    continue;
                }
                if SKIP_SUFFIXES.iter().any(|s| e.name.ends_with(s)) {
                    continue;
                }
                if !rules.is_empty() && ignored(&rules, &rel, false) {
                    continue;
                }
                if clean_path(&Str(rel.clone())).is_err() {
                    continue;
                }
                let t = self.time_of(&index, &rel, &e);
                found.push((rel, e.size, t));
            }
        }
        found.sort();
        Ok(found)
    }

    /// The folders `rel`'s place needs, made (those made already in `made`).
    pub fn make_parents(&self, dir: &str, rel: &str, made: &mut BTreeSet<String>) {
        let mut at = 0;
        while let Some(i) = rel[at..].find('/') {
            let parent = &rel[..at + i];
            if made.insert(parent.to_string()) {
                let _ = self.files.mkdir(&format!("{}/{}", dir, parent));
            }
            at += i + 1;
        }
    }

    /// The pushed times of files just written (each folder listed once).
    pub fn note_written(&self, dir: &str, written: &[(String, u64, i128)]) {
        let index = self.index(dir);
        let mut index = index.lock().unwrap_or_else(|e| e.into_inner());
        let mut by_folder: BTreeMap<&str, Vec<&(String, u64, i128)>> = BTreeMap::new();
        for w in written {
            by_folder.entry(w.0.rsplit_once('/').map_or("", |(p, _)| p)).or_default().push(w);
        }
        for (folder, ws) in by_folder {
            let at = if folder.is_empty() { dir.to_string() } else { format!("{}/{}", dir, folder) };
            let list = self.files.list(&at).unwrap_or_default();
            for (rel, size, mtime) in ws {
                let name = rel.rsplit_once('/').map_or(rel.as_str(), |(_, n)| n);
                if let Some(e) = list.iter().find(|e| e.name.eq_ignore_ascii_case(name)) {
                    index.kept.insert(rel.to_lowercase(), (*size, *mtime, stamp(&e.written)));
                }
            }
        }
        self.save_index(dir, &index);
    }

    /// remove_files': these files, then the folders their going left
    /// empty (with `below`, only folders there) -> how many.
    pub fn remove_files(&self, dir: &str, paths: &[String], below: Option<&[String]>) -> usize {
        let index = self.index(dir);
        let mut index = index.lock().unwrap_or_else(|e| e.into_inner());
        let mut emptied = BTreeSet::new();
        for p in paths {
            let _ = self.files.remove(&format!("{}/{}", dir, p));
            index.kept.remove(&p.to_lowercase());
            let mut parent = p.as_str();
            while let Some((up, _)) = parent.rsplit_once('/') {
                emptied.insert(up.to_string());
                parent = up;
            }
        }
        let mut emptied: Vec<String> = emptied
            .into_iter()
            .filter(|p| below.is_none_or(|b| b.iter().any(|d| p == d || p.starts_with(&format!("{}/", d)))))
            .collect();
        emptied.sort_by_key(|p| std::cmp::Reverse(p.matches('/').count()));
        for p in emptied {
            let _ = self.files.remove(&format!("{}/{}", dir, p)); // only an empty one goes
        }
        self.save_index(dir, &index);
        paths.len()
    }
}

/// entries': [path, size, mtime] each, checked; an offset refused (no
/// partial copies are kept here).
pub fn entries(raw: &Value) -> Result<Vec<Entry>, String> {
    let list = raw.list().ok_or_else(|| format!("TypeError('files is a list of entries')"))?;
    let mut out = Vec::with_capacity(list.len());
    for e in list {
        let parts = e.list().filter(|p| p.len() >= 3).ok_or_else(|| "TypeError('an entry is [path, size, mtime]')".to_string())?;
        let path = clean_path(&parts[0])?;
        let size = parts[1].int().ok_or_else(|| format!("ValueError('a size: {}')", parts[1].py_repr()))?;
        let mtime = parts[2].int().ok_or_else(|| format!("ValueError('a time: {}')", parts[2].py_repr()))?;
        let offset = parts.get(3).and_then(Value::int).unwrap_or(0);
        if size < 0 {
            return Err(format!("size {} of {} is negative", size, path));
        }
        if !(0..size.max(1)).contains(&offset) {
            return Err(format!("offset {} is not inside {} ({} bytes)", offset, path, size));
        }
        if offset != 0 {
            return Err(format!("the partial copy of {} is gone: send it whole", path));
        }
        out.push((path, size as u64, mtime));
    }
    Ok(out)
}

pub fn entry_value(e: &Entry) -> Value {
    List(vec![Str(e.0.clone()), Int(e.1 as i128), Int(e.2)])
}

pub fn same(a: (u64, i128), b: (u64, i128)) -> bool {
    a.0 == b.0 && (a.1 - b.1).abs() < SAME_TIME_NS
}

/// differing's: what of `wanted` `have` lacks or holds otherwise.
pub fn differing(wanted: &[Entry], have: &[Entry]) -> Vec<String> {
    let held: HashMap<&str, (u64, i128)> = have.iter().map(|(p, s, m)| (p.as_str(), (*s, *m))).collect();
    wanted
        .iter()
        .filter(|(p, s, m)| !held.get(p.as_str()).is_some_and(|&h| same((*s, *m), h)))
        .map(|(p, _, _)| p.clone())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn globs() {
        let r = ignore_rules("*.log\n/build/\n!keep.log\ndocs/**/x\n/top.txt\n");
        assert!(ignored(&r, "a/b.log", false));
        assert!(!ignored(&r, "a/keep.log", false));
        assert!(ignored(&r, "build", true));
        assert!(ignored(&r, "a/build", true)); // fleet strips both of "/build/"'s slashes
        assert!(ignored(&r, "top.txt", false));
        assert!(!ignored(&r, "a/top.txt", false));
        assert!(ignored(&r, "docs/x", false));
        assert!(ignored(&r, "docs/a/b/x", false));
    }

    #[test]
    fn days() {
        assert_eq!(days_from_civil(1970, 1, 1), 0);
        assert_eq!(civil_from_days(days_from_civil(2026, 10, 18)), (2026, 10, 18));
    }
}
