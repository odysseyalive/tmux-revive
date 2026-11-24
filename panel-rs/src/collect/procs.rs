//! The process table gather reads (scripts/panel.sh gather: `ps -ww -eo
//! pid=,ppid=,uid=,rss=,pcpu=,args=`), and what it reads of each process from /proc
//! (tree_ticks, shell_job's tpgid, proc_cwd, proc_start).
//!
//! On Linux it comes from /proc directly, each row as ps would print it (args from cmdline,
//! escaped as procps escapes it; [comm] for a process with none, and " <defunct>" for a zombie),
//! so the table is the same with no ps run. REVIVE_PANEL_PROCS=ps, or no /proc (macOS), runs ps
//! as bash does: the tests' ps stand-ins (test/panel.sh fakeps, uidps) need it.

use super::sh::{self, Bytes};
use std::collections::HashMap;

/// One row as `read -r pid ppid uid rss pcpu args` takes it from ps's line: each a string.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Row {
    pub pid: Bytes,
    pub ppid: Bytes,
    pub uid: Bytes,
    pub rss: Bytes,
    pub pcpu: Bytes,
    pub args: Bytes,
}

/// gather's PCHILD PARGS PRSS PCPU PPAR PUID, keyed as bash keys them (the strings ps gave)
#[derive(Default, Clone)]
pub struct Table {
    /// PCHILD[ppid]: its children's pids, in the order ps listed them
    pub child: HashMap<Bytes, Vec<Bytes>>,
    pub args: HashMap<Bytes, Bytes>,
    pub rss: HashMap<Bytes, Bytes>,
    pub pcpu: HashMap<Bytes, Bytes>,
    pub par: HashMap<Bytes, Bytes>,
    pub uid: HashMap<Bytes, Bytes>,
}

impl Table {
    /// gather's loop over ps's lines
    pub fn from_rows(rows: &[Row]) -> Table {
        let mut t = Table::default();
        for r in rows {
            if r.pid.is_empty() {
                continue;
            }
            t.child.entry(r.ppid.clone()).or_default().push(r.pid.clone());
            t.args.insert(r.pid.clone(), r.args.clone());
            t.rss.insert(r.pid.clone(), r.rss.clone());
            t.pcpu.insert(r.pid.clone(), r.pcpu.clone());
            t.par.insert(r.pid.clone(), r.ppid.clone());
            t.uid.insert(r.pid.clone(), r.uid.clone());
        }
        t
    }
    /// `${PARGS[$p]:-}`
    pub fn args_of(&self, p: &[u8]) -> &[u8] {
        self.args.get(p).map(|v| v.as_slice()).unwrap_or(b"")
    }
    /// `${PCHILD[$p]:-}` word-split
    pub fn children(&self, p: &[u8]) -> &[Bytes] {
        self.child.get(p).map(|v| v.as_slice()).unwrap_or(&[])
    }
}

/// ps's line read as bash reads it: `read -r pid ppid uid rss pcpu args` (default IFS)
pub fn read_row(line: &[u8]) -> Row {
    let f = sh::read_ws(line, 6, b" \t\n");
    Row { pid: f[0].clone(), ppid: f[1].clone(), uid: f[2].clone(), rss: f[3].clone(), pcpu: f[4].clone(), args: f[5].clone() }
}

/// Which backend: ps when REVIVE_PANEL_PROCS=ps or there is no /proc
pub fn use_ps() -> bool {
    sh::env("REVIVE_PANEL_PROCS").as_deref() == Some(b"ps") || !sh::is_dir(b"/proc/self")
}

/// The table's rows, from the backend in use
pub fn rows() -> Vec<Row> {
    if use_ps() {
        ps_rows()
    } else {
        proc_rows()
    }
}

/// `all=$(ps -ww -eo pid=,ppid=,uid=,rss=,pcpu=,args= 2>/dev/null)`, then `<<<"$all"`
pub fn ps_rows() -> Vec<Row> {
    let o = sh::run(&[b"ps", b"-ww", b"-eo", b"pid=,ppid=,uid=,rss=,pcpu=,args="]);
    let all = sh::cmdsub(&o.out);
    sh::here(&all).iter().map(|l| read_row(l)).collect()
}

pub fn clk() -> i64 {
    let c = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
    if c > 0 {
        c as i64
    } else {
        100
    }
}

/// /proc/uptime's first figure, seconds
fn uptime() -> Option<f64> {
    let u = std::fs::read("/proc/uptime").ok()?;
    let f = u.split(|&c| c == b' ').next()?;
    std::str::from_utf8(f).ok()?.parse().ok()
}

/// The fields of /proc/PID/stat after its name: `${l##*) }` split at spaces (state is [0])
pub fn stat_fields(pid: &[u8]) -> Option<Vec<Bytes>> {
    let l = std::fs::read(sh::os(&sh::path(&[b"/proc/", pid, b"/stat"]))).ok()?;
    let l = sh::lines(&l).into_iter().next().or_else(|| if l.is_empty() { None } else { Some(l.clone()) })?;
    let p = l.windows(2).rposition(|w| w == b") ")?;
    Some(l[p + 2..].split(|&c| c == b' ').map(|f| f.to_vec()).collect())
}

/// procps's escape of a command line: what decodes and prints stays, a newline is a space, and
/// every other byte (a control character, one that doesn't decode, each byte of a character
/// that doesn't print) is a '?'. Under the panel's UTF-8 locale.
pub fn ps_escape(s: &[u8]) -> Bytes {
    let mut out = Vec::with_capacity(s.len());
    let mut i = 0;
    while i < s.len() {
        let c = s[i];
        if c < 0x80 {
            out.push(if c == b'\n' {
                b' '
            } else if (0x20..0x7f).contains(&c) {
                c
            } else {
                b'?'
            });
            i += 1;
            continue;
        }
        let Some((wc, n)) = crate::compat::mb_decode(&s[i..]) else {
            out.push(b'?');
            i += 1;
            continue;
        };
        if crate::compat::wprint(wc) {
            out.extend_from_slice(&s[i..i + n]);
        } else {
            out.extend(std::iter::repeat(b'?').take(n));
        }
        i += n;
    }
    out
}

/// One process's row from /proc, as ps prints it; None if it went meanwhile
pub fn proc_row(pid: &[u8], up: f64, hz: i64) -> Option<Row> {
    let base = sh::path(&[b"/proc/", pid]);
    let raw = std::fs::read(sh::os(&sh::path(&[&base, b"/stat"]))).ok()?;
    let lp = raw.iter().position(|&c| c == b'(')?;
    let rp = raw.iter().rposition(|&c| c == b')')?;
    let comm = raw[lp + 1..rp].to_vec();
    let f: Vec<&[u8]> = raw[rp + 2..].split(|&c| c == b' ' || c == b'\n').collect();
    let state = *f.first()?;
    let ppid = f.get(1)?.to_vec();
    let num = |i: usize| -> u64 { f.get(i).and_then(|x| std::str::from_utf8(x).ok()).and_then(|x| x.parse().ok()).unwrap_or(0) };
    // utime stime are fields 14 and 15: [11] and [12] after the name; starttime 22: [19]
    let ticks = num(11) + num(12);
    let start = num(19);
    let status = std::fs::read(sh::os(&sh::path(&[&base, b"/status"]))).ok()?;
    let mut uid = Vec::new();
    let mut rss: Bytes = b"0".to_vec();
    for l in status.split(|&c| c == b'\n') {
        if let Some(r) = l.strip_prefix(b"Uid:") {
            // real, effective, saved, fs: ps's uid is the effective one
            if let Some(e) = r.split(|&c| c == b'\t' || c == b' ').filter(|x| !x.is_empty()).nth(1) {
                uid = e.to_vec();
            }
        } else if let Some(r) = l.strip_prefix(b"VmRSS:") {
            if let Some(k) = r.split(|&c| c == b'\t' || c == b' ').find(|x| !x.is_empty()) {
                rss = k.to_vec();
            }
        }
    }
    let cmd = std::fs::read(sh::os(&sh::path(&[&base, b"/cmdline"]))).ok()?;
    let mut args: Bytes;
    if cmd.is_empty() {
        args = sh::path(&[b"[", &ps_escape(&comm), b"]"]);
        if state == b"Z" {
            args.extend_from_slice(b" <defunct>");
        }
    } else {
        let mut c = cmd;
        while c.last() == Some(&0) {
            c.pop();
        }
        let c: Bytes = c.iter().map(|&b| if b == 0 { b' ' } else { b }).collect();
        args = ps_escape(&c);
    }
    // pcpu: procps's, the whole life's ticks over its seconds, tenths kept
    let secs = (up - start as f64 / hz as f64).max(0.0) as u64;
    let pc = if secs > 0 { ticks * 1000 / hz as u64 / secs } else { 0 };
    let pcpu = if pc > 999 { format!("{}", pc / 10) } else { format!("{}.{}", pc / 10, pc % 10) };
    // As read takes ps's line: args with the blanks at its ends gone
    let line = sh::path(&[b"0 0 0 0 0 ", &args]);
    let args = read_row(&line).args;
    Some(Row { pid: pid.to_vec(), ppid, uid, rss, pcpu: pcpu.into_bytes(), args })
}

/// Every process in /proc, in pid order as ps lists them
pub fn proc_rows() -> Vec<Row> {
    let up = uptime().unwrap_or(0.0);
    let hz = clk();
    let mut pids: Vec<u64> = Vec::new();
    if let Ok(rd) = std::fs::read_dir("/proc") {
        for e in rd.flatten() {
            if let Some(n) = e.file_name().to_str().and_then(|s| s.parse::<u64>().ok()) {
                pids.push(n);
            }
        }
    }
    pids.sort_unstable();
    pids.iter().filter_map(|p| proc_row(p.to_string().as_bytes(), up, hz)).collect()
}

/// tree_ticks PID... -> TICKS: utime stime cutime cstime of each, summed (Linux)
pub fn tree_ticks(pids: &[Bytes]) -> i64 {
    let mut t: i64 = 0;
    for p in pids {
        let Ok(l) = std::fs::read(sh::os(&sh::path(&[b"/proc/", p, b"/stat"]))) else { continue };
        // read -r l: the first line
        let l = l.split(|&c| c == b'\n').next().unwrap_or(b"");
        // ${l##*) }
        let rest = match l.windows(2).rposition(|w| w == b") ") {
            Some(i) => &l[i + 2..],
            None => l,
        };
        // STAT_RE='^([^ ]+ +){11}([0-9-]+) +([0-9-]+) +([0-9-]+) +([0-9-]+)'
        let Some(m) = crate::compat::re("^([^ ]+ +){11}([0-9-]+) +([0-9-]+) +([0-9-]+) +([0-9-]+)").matches(rest) else { continue };
        for k in 2..6 {
            t = t.wrapping_add(crate::render::num(&m[k]));
        }
    }
    t
}

/// shell_job's tpgid: `/proc/PID/stat`'s, else `ps -o tpgid= -p PID` with its spaces taken out
pub fn tpgid(pid: &[u8]) -> Bytes {
    let st = sh::path(&[b"/proc/", pid, b"/stat"]);
    if sh::readable(&st) {
        let Ok(raw) = std::fs::read(sh::os(&st)) else { return Vec::new() };
        // read -r a: its first line; nothing read, nothing
        let Some(a) = sh::lines(&raw).into_iter().next().or_else(|| if raw.is_empty() { None } else { Some(raw.clone()) }) else { return Vec::new() };
        let a = match a.windows(2).rposition(|w| w == b") ") {
            Some(i) => a[i + 2..].to_vec(),
            None => a,
        };
        // read -r _ _ _ _ _ fg _ <<<"$a"
        let f = sh::read_ws(&a, 7, b" \t\n");
        f[5].clone()
    } else {
        let o = sh::run(&[b"ps", b"-o", b"tpgid=", b"-p", pid]);
        sh::cmdsub(&o.out).into_iter().filter(|&c| c != b' ').collect()
    }
}

/// proc_cwd PID: its working folder (`$( )` of readlink, else lsof's)
pub fn proc_cwd(pid: &[u8]) -> Bytes {
    let c = sh::path(&[b"/proc/", pid, b"/cwd"]);
    if sh::exists(&c) {
        sh::readlink(&c).unwrap_or_default()
    } else {
        let o = sh::run(&[b"lsof", b"-a", b"-d", b"cwd", b"-p", pid, b"-Fn"]);
        let mut v = Vec::new();
        for l in sh::split_lines(&o.out) {
            if let Some(r) = l.strip_prefix(b"n") {
                v.extend_from_slice(r);
                v.push(b'\n');
            }
        }
        sh::cmdsub(&v)
    }
}

/// `ps -o etime= -p PID` in seconds: from /proc (procps's own sum), else ps itself. None:
/// none given (gone, or not a form proc_start reads).
pub fn etime(pid: &[u8]) -> Option<i64> {
    if sh::readable(&sh::path(&[b"/proc/", pid, b"/stat"])) && !use_ps() {
        let f = stat_fields(pid)?;
        let start: f64 = std::str::from_utf8(f.get(19)?).ok()?.parse().ok()?;
        let up = uptime()?;
        let e = up - start / clk() as f64;
        return Some(if e < 0.0 { 0 } else { e as i64 });
    }
    let o = sh::run(&[b"ps", b"-o", b"etime=", b"-p", pid]);
    let e: Bytes = sh::cmdsub(&o.out).into_iter().filter(|c| !c.is_ascii_whitespace()).collect();
    let m = crate::compat::re("^(([0-9]+)-)?(([0-9]+):)?([0-9]+):([0-9]+)$").matches(&e)?;
    let n = |b: &[u8]| -> i64 { crate::render::num(&crate::render::cat(&[b"10#0", b])) };
    Some(n(&m[2]) * 86400 + n(&m[4]) * 3600 + n(&m[5]) * 60 + n(&m[6]))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The /proc table is ps's: every process both saw (the machine runs on meanwhile) has the
    /// same parent, user, memory and command line as `ps -eo` gives them, read the same way.
    #[test]
    fn proc_table_is_ps_table() {
        crate::compat::tests::setup();
        if !sh::is_dir(b"/proc/self") {
            return;
        }
        let a = proc_rows();
        let b = ps_rows();
        let am: HashMap<Bytes, Row> = a.iter().map(|r| (r.pid.clone(), r.clone())).collect();
        let c = proc_rows();
        let cm: HashMap<Bytes, Row> = c.iter().map(|r| (r.pid.clone(), r.clone())).collect();
        let mut both = 0;
        let mut bad = Vec::new();
        for r in &b {
            let (Some(x), Some(y)) = (am.get(&r.pid), cm.get(&r.pid)) else { continue };
            // the same before and after ps looked: a process that changed meanwhile isn't a test
            if x != y {
                continue;
            }
            both += 1;
            // memory moves: proc_rss_is_ps_rss
            if !(x.ppid == r.ppid && x.uid == r.uid && x.args == r.args) {
                bad.push(format!("{:?}\n  proc {:?}\n  ps   {:?}", String::from_utf8_lossy(&r.pid), x, r));
            }
        }
        assert!(both > 10, "too few processes in both listings ({})", both);
        assert!(bad.is_empty(), "{} of {} differ:\n{}", bad.len(), both, bad.join("\n"));
        // their order: ps lists by pid, as /proc does
        let order: Vec<&Bytes> = b.iter().map(|r| &r.pid).filter(|p| am.contains_key(*p)).collect();
        let ours: Vec<&Bytes> = a.iter().map(|r| &r.pid).filter(|p| b.iter().any(|r| &r.pid == *p)).collect();
        assert_eq!(order, ours);
    }

    /// Memory, which moves: most processes hold still between two looks
    #[test]
    fn proc_rss_is_ps_rss() {
        crate::compat::tests::setup();
        if !sh::is_dir(b"/proc/self") {
            return;
        }
        let a = proc_rows();
        let b = ps_rows();
        let am: HashMap<Bytes, Row> = a.iter().map(|r| (r.pid.clone(), r.clone())).collect();
        let (mut n, mut same) = (0, 0);
        for r in &b {
            if let Some(x) = am.get(&r.pid) {
                n += 1;
                if x.rss == r.rss {
                    same += 1;
                }
            }
        }
        assert!(same * 10 >= n * 8, "rss agrees for only {} of {}", same, n);
    }

    #[test]
    fn escape_as_procps() {
        crate::compat::tests::setup();
        assert_eq!(ps_escape(b"tab\there nl\nthere \xc3\xa9 \x7f \xff \xc2\x85 \xe2\x80\x8b end"), b"tab?here nl there \xc3\xa9 ? ? ?? \xe2\x80\x8b end".to_vec());
    }
}
