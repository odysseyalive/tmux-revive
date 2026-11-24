//! What the gathering half of scripts/panel.sh leans on from bash and the programs it runs,
//! made explicit: `read`'s field splitting, the programs it still starts (tmux, git, ssh...),
//! with the umask and PATH bash gives them, and the small file reads it does through `head`,
//! `tail`, `stat` and `find`.

pub use crate::compat::Bytes;
use std::ffi::{OsStr, OsString};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::MetadataExt;
use std::process::{Command, Stdio};
use std::sync::OnceLock;

pub fn os(b: &[u8]) -> &OsStr {
    OsStr::from_bytes(b)
}

pub fn env(k: &str) -> Option<Bytes> {
    std::env::var_os(k).map(|v| v.into_vec())
}
/// `${K:-}`
pub fn env_or(k: &str, d: &[u8]) -> Bytes {
    env(k).filter(|v| !v.is_empty()).unwrap_or_else(|| d.to_vec())
}

// ------------------------------------------------------------------ read

/// `IFS=<whitespace> read -r A B ...` of one line into N names: runs of the IFS characters
/// split it, none at either end, and the last name takes the rest (its inner runs kept). So an
/// empty field between two tabs vanishes and the ones after it move left, as in bash: with
/// IFS=$'\t' tab is IFS whitespace.
pub fn read_ws(line: &[u8], n: usize, ifs: &[u8]) -> Vec<Bytes> {
    let is = |c: &u8| ifs.contains(c);
    let mut out = Vec::with_capacity(n);
    let mut i = 0;
    while i < line.len() && is(&line[i]) {
        i += 1;
    }
    for k in 0..n {
        if k + 1 == n {
            let mut e = line.len();
            while e > i && is(&line[e - 1]) {
                e -= 1;
            }
            out.push(line[i.min(e)..e].to_vec());
            break;
        }
        let s = i;
        while i < line.len() && !is(&line[i]) {
            i += 1;
        }
        out.push(line[s..i].to_vec());
        while i < line.len() && is(&line[i]) {
            i += 1;
        }
    }
    out
}

/// `IFS=<one character that isn't whitespace> read -r A B ...`: each one a field, empty ones
/// too; the last name takes the rest of the line as it is, delimiters and all.
pub fn read_delim(line: &[u8], n: usize, d: u8) -> Vec<Bytes> {
    let mut out = Vec::with_capacity(n);
    let mut rest = line;
    for k in 0..n {
        if k + 1 == n {
            out.push(rest.to_vec());
            break;
        }
        match rest.iter().position(|&c| c == d) {
            Some(p) => {
                out.push(rest[..p].to_vec());
                rest = &rest[p + 1..];
            }
            None => {
                out.push(rest.to_vec());
                rest = b"";
            }
        }
    }
    out
}

/// The lines `while read -r l; do ... done < <(...)` runs its body for: each one a newline ends
/// (a last one with none fails the read, and the loop ends without it). `read` drops NUL bytes.
/// A here-string (`<<<"$v"`) adds a newline, so there it is every line: `lines(&join(v, "\n"))`.
pub fn lines(text: &[u8]) -> Vec<Bytes> {
    let mut v: Vec<Bytes> = text.split(|&c| c == b'\n').map(|l| l.iter().copied().filter(|&c| c != 0).collect()).collect();
    v.pop();
    v
}

/// `mapfile -t A < <(...)`: every line, a last one with no newline too.
pub fn mapfile(text: &[u8]) -> Vec<Bytes> {
    let mut v: Vec<Bytes> = text.split(|&c| c == b'\n').map(|l| l.to_vec()).collect();
    if text.ends_with(b"\n") || text.is_empty() {
        v.pop();
    }
    v
}

/// `<<<"$v"`'s lines: every line of V (the here-string ends it with a newline)
pub fn here(v: &[u8]) -> Vec<Bytes> {
    let mut t = v.to_vec();
    t.push(b'\n');
    lines(&t)
}

/// `$(...)`: the output with its trailing newlines taken off (and NULs dropped).
pub fn cmdsub(out: &[u8]) -> Bytes {
    let mut v: Bytes = out.iter().copied().filter(|&c| c != 0).collect();
    while v.last() == Some(&b'\n') {
        v.pop();
    }
    v
}

/// `read -r v < FILE`: its first line (none: a file that's empty or can't be read).
pub fn read_line(path: &[u8]) -> Option<Bytes> {
    let d = std::fs::read(os(path)).ok()?;
    if d.is_empty() {
        return None;
    }
    let l = d.split(|&c| c == b'\n').next().unwrap_or(b"");
    // read fails at end of file with no newline, but the variable still gets what it read
    Some(l.iter().copied().filter(|&c| c != 0).collect())
}

// ------------------------------------------------------------------ files

pub fn is_file(p: &[u8]) -> bool {
    std::fs::metadata(os(p)).map(|m| m.is_file()).unwrap_or(false)
}
pub fn is_dir(p: &[u8]) -> bool {
    std::fs::metadata(os(p)).map(|m| m.is_dir()).unwrap_or(false)
}
pub fn exists(p: &[u8]) -> bool {
    std::fs::metadata(os(p)).is_ok()
}
pub fn is_link(p: &[u8]) -> bool {
    std::fs::symlink_metadata(os(p)).map(|m| m.file_type().is_symlink()).unwrap_or(false)
}
/// `[[ -s F ]]`
pub fn nonempty(p: &[u8]) -> bool {
    std::fs::metadata(os(p)).map(|m| m.len() > 0).unwrap_or(false)
}
/// `[[ -r F ]]`
pub fn readable(p: &[u8]) -> bool {
    let c = match std::ffi::CString::new(p) {
        Ok(c) => c,
        Err(_) => return false,
    };
    unsafe { libc::access(c.as_ptr(), libc::R_OK) == 0 }
}
/// stat's mtime, seconds (`stat -c %Y`, links followed)
pub fn mtime(p: &[u8]) -> Option<i64> {
    std::fs::metadata(os(p)).ok().map(|m| m.mtime())
}
/// `stat -c %u`
pub fn owner(p: &[u8]) -> Option<u32> {
    std::fs::metadata(os(p)).ok().map(|m| m.uid())
}
/// fstamp FILE: `stat -c '%s.%Y'`, or nothing
pub fn fstamp(p: &[u8]) -> Bytes {
    match std::fs::metadata(os(p)) {
        Ok(m) => format!("{}.{}", m.len(), m.mtime()).into_bytes(),
        Err(_) => Vec::new(),
    }
}
/// `[[ A -nt B ]]`: A is newer (or B doesn't exist and A does)
pub fn newer(a: &[u8], b: &[u8]) -> bool {
    let ma = std::fs::metadata(os(a)).ok();
    let mb = std::fs::metadata(os(b)).ok();
    match (ma, mb) {
        (Some(a), Some(b)) => (a.mtime(), a.mtime_nsec()) > (b.mtime(), b.mtime_nsec()),
        (Some(_), None) => true,
        _ => false,
    }
}
/// `[[ A -ot B ]]`
pub fn older(a: &[u8], b: &[u8]) -> bool {
    let ma = std::fs::metadata(os(a)).ok();
    let mb = std::fs::metadata(os(b)).ok();
    match (ma, mb) {
        (Some(a), Some(b)) => (a.mtime(), a.mtime_nsec()) < (b.mtime(), b.mtime_nsec()),
        (None, Some(_)) => true,
        _ => false,
    }
}
/// `head -c N FILE` (nothing when it can't be read)
pub fn head_c(p: &[u8], n: usize) -> Bytes {
    use std::io::Read;
    let mut v = Vec::new();
    if let Ok(f) = std::fs::File::open(os(p)) {
        let _ = f.take(n as u64).read_to_end(&mut v);
    }
    v
}
/// `head -n N` of TEXT
pub fn head_n(t: &[u8], n: usize) -> &[u8] {
    let mut k = 0;
    for (i, &c) in t.iter().enumerate() {
        if c == b'\n' {
            k += 1;
            if k == n {
                return &t[..=i];
            }
        }
    }
    t
}
/// `head -n 1 FILE` as `$( )` gives it
pub fn head1(p: &[u8]) -> Bytes {
    let d = head_c(p, 1 << 20);
    cmdsub(head_n(&d, 1))
}
/// `tail -c N FILE`
pub fn tail_c(p: &[u8], n: u64) -> Bytes {
    use std::io::{Read, Seek, SeekFrom};
    let mut v = Vec::new();
    if let Ok(mut f) = std::fs::File::open(os(p)) {
        if let Ok(m) = f.metadata() {
            if m.is_file() && m.len() > n {
                let _ = f.seek(SeekFrom::Start(m.len() - n));
            }
        }
        let _ = f.take(n).read_to_end(&mut v);
        if v.len() as u64 > n {
            let cut = v.len() - n as usize;
            v.drain(..cut);
        }
    }
    v
}
/// `tail -n N` of TEXT
pub fn tail_n(t: &[u8], n: usize) -> &[u8] {
    if n == 0 {
        return b"";
    }
    let body = if t.ends_with(b"\n") { &t[..t.len() - 1] } else { t };
    let mut k = 0;
    for i in (0..body.len()).rev() {
        if body[i] == b'\n' {
            k += 1;
            if k == n {
                return &t[i + 1..];
            }
        }
    }
    t
}
/// The lines of TEXT that hold PAT (grep -F PAT), each with its newline
pub fn grep_f<'a>(t: &'a [u8], pat: &[u8]) -> Vec<&'a [u8]> {
    split_lines(t).into_iter().filter(|l| contains(l, pat)).collect()
}
/// TEXT's lines, without their newlines (a last one with none too, as grep reads them)
pub fn split_lines(t: &[u8]) -> Vec<&[u8]> {
    let mut v: Vec<&[u8]> = t.split(|&c| c == b'\n').collect();
    if t.ends_with(b"\n") || t.is_empty() {
        v.pop();
    }
    v
}
pub fn contains(h: &[u8], n: &[u8]) -> bool {
    n.is_empty() || h.windows(n.len()).any(|w| w == n)
}
pub fn starts(h: &[u8], n: &[u8]) -> bool {
    h.starts_with(n)
}
/// `[[ $s == *N* ]]` for a fixed N
pub fn has(h: &[u8], n: &str) -> bool {
    contains(h, n.as_bytes())
}

/// The names in DIR in bash's glob order (`DIR/*`: no dot names, by strcoll), whole paths;
/// none: nothing (the caller tests each with -f/-d, as bash's loops do on the pattern itself).
pub fn glob(dir: &[u8], pre: &[u8], suf: &[u8], dots: bool) -> Vec<Bytes> {
    let mut v: Vec<Bytes> = Vec::new();
    if let Ok(rd) = std::fs::read_dir(os(dir)) {
        for e in rd.flatten() {
            let name = e.file_name().into_vec();
            if !dots && name.first() == Some(&b'.') {
                continue;
            }
            if !name.starts_with(pre) || !name.ends_with(suf) || name.len() < pre.len() + suf.len() {
                continue;
            }
            let mut p = dir.to_vec();
            if !p.ends_with(b"/") {
                p.push(b'/');
            }
            p.extend_from_slice(&name);
            v.push(p);
        }
    }
    v.sort_by(|a, b| crate::compat::strcoll(a, b));
    v
}

/// `"$D"/*/X` over every D in DIR's folders (the glob `DIR/*/X`, in its order): each existing path
pub fn glob_sub(dir: &[u8], x: &[u8]) -> Vec<Bytes> {
    let mut v = Vec::new();
    for d in glob(dir, b"", b"", false) {
        let mut p = d.clone();
        p.push(b'/');
        p.extend_from_slice(x);
        if exists(&p) || is_link(&p) {
            v.push(p);
        }
    }
    // the glob sorts the whole paths
    v.sort_by(|a, b| crate::compat::strcoll(a, b));
    v
}

/// `${p##*/}`
pub fn basename(p: &[u8]) -> &[u8] {
    match p.iter().rposition(|&c| c == b'/') {
        Some(i) => &p[i + 1..],
        None => p,
    }
}
/// `$(basename "$d")` of a `DIR/NAME/`
pub fn basename_dir(p: &[u8]) -> Bytes {
    let mut q = p;
    while q.len() > 1 && q.ends_with(b"/") {
        q = &q[..q.len() - 1];
    }
    basename(q).to_vec()
}
pub fn join(a: &[u8], b: &[u8]) -> Bytes {
    let mut v = a.to_vec();
    v.extend_from_slice(b);
    v
}
pub fn path(parts: &[&[u8]]) -> Bytes {
    crate::render::cat(parts)
}

pub fn readlink(p: &[u8]) -> Option<Bytes> {
    std::fs::read_link(os(p)).ok().map(|x| x.into_os_string().into_vec())
}

// ------------------------------------------------------------------ the clock

static T0: OnceLock<i64> = OnceLock::new();
pub fn time_s() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}
/// The process's start, for SECONDS
pub fn start() {
    T0.get_or_init(time_s);
}
/// bash's SECONDS: whole seconds of the clock since the shell started
pub fn seconds() -> i64 {
    time_s() - *T0.get_or_init(time_s)
}
/// EPOCHREALTIME as microseconds
pub fn now_us() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_micros() as i64).unwrap_or(0)
}

// ------------------------------------------------------------------ programs

/// The umask the panel was started with (common.sh's REVIVE_UMASK), before it set 077.
static UMASK: OnceLock<libc::mode_t> = OnceLock::new();
/// common.sh's start: REVIVE_UMASK kept, then `umask 077`; PATH with the install's vendor/bin
/// first when there is one (a private jq, and so on).
pub fn init(root: &[u8]) {
    start();
    UMASK.get_or_init(|| unsafe {
        let u = libc::umask(0o077);
        libc::umask(0o077);
        u
    });
    let vb = path(&[root, b"/vendor/bin"]);
    if is_dir(&vb) {
        let mut p = vb;
        p.push(b':');
        p.extend(env("PATH").unwrap_or_default());
        std::env::set_var("PATH", os(&p));
    }
}

pub struct Out {
    pub ok: bool,
    /// the exit status, 128+N for a signal (as bash's $? and PIPESTATUS)
    pub st: i32,
    pub out: Bytes,
}

fn status_code(s: std::process::ExitStatus) -> i32 {
    use std::os::unix::process::ExitStatusExt;
    match s.code() {
        Some(c) => c,
        None => 128 + s.signal().unwrap_or(0),
    }
}

/// ARGV run as bash runs a command: from PATH, stdin /dev/null, stderr thrown away, its output
/// read whole. Not found: 127.
pub fn run(argv: &[&[u8]]) -> Out {
    run_env(argv, &[], None)
}
pub fn run_env(argv: &[&[u8]], envs: &[(&str, &[u8])], umask: Option<libc::mode_t>) -> Out {
    let mut c = Command::new(os(argv[0]));
    for a in &argv[1..] {
        c.arg(os(a));
    }
    for (k, v) in envs {
        c.env(k, os(v));
    }
    c.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
    if let Some(m) = umask {
        use std::os::unix::process::CommandExt;
        unsafe {
            c.pre_exec(move || {
                libc::umask(m);
                Ok(())
            });
        }
    }
    match c.output() {
        Ok(o) => Out { ok: o.status.success(), st: status_code(o.status), out: o.stdout },
        Err(e) => Out { ok: false, st: if e.kind() == std::io::ErrorKind::NotFound { 127 } else { 126 }, out: Vec::new() },
    }
}

/// ARGV with its output cut at CAP bytes, as `cmd | head -c CAP` does: the reader closes the
/// pipe once it has CAP, so a writer still going gets SIGPIPE (141). -> (status, bytes)
pub fn run_capped(argv: &[&[u8]], cap: usize) -> (i32, Bytes) {
    run_capped_env(argv, cap, &[])
}
pub fn run_capped_env(argv: &[&[u8]], cap: usize, envs: &[(&str, &[u8])]) -> (i32, Bytes) {
    use std::io::Read;
    let mut c = Command::new(os(argv[0]));
    for a in &argv[1..] {
        c.arg(os(a));
    }
    for (k, v) in envs {
        c.env(k, os(v));
    }
    c.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
    let mut ch = match c.spawn() {
        Ok(ch) => ch,
        Err(e) => return (if e.kind() == std::io::ErrorKind::NotFound { 127 } else { 126 }, Vec::new()),
    };
    let mut buf = Vec::new();
    if let Some(o) = ch.stdout.take() {
        let _ = o.take(cap as u64).read_to_end(&mut buf);
        // dropped here: the pipe closes, as head's exit closes it
    }
    let st = ch.wait().map(status_code).unwrap_or(1);
    (st, buf)
}

/// tm ARGS: tmux, at REVIVE_SOCKET when set, with the umask the panel started with (common.sh's tm)
pub fn tm(args: &[&[u8]]) -> Out {
    let sock = env("REVIVE_SOCKET").unwrap_or_default();
    let mut argv: Vec<&[u8]> = vec![b"tmux"];
    if !sock.is_empty() {
        argv.push(b"-S");
        argv.push(&sock);
    }
    argv.extend_from_slice(args);
    run_env(&argv, &[], Some(*UMASK.get().unwrap_or(&0o022)))
}

/// opt NAME DEFAULT: a global tmux user option, else DEFAULT
pub fn opt(name: &[u8], d: &[u8]) -> Bytes {
    let v = cmdsub(&tm(&[b"show-option", b"-gqv", name]).out);
    if v.is_empty() {
        d.to_vec()
    } else {
        v
    }
}

/// `command -v NAME` finds it on PATH
pub fn on_path(name: &str) -> bool {
    let p = env("PATH").unwrap_or_default();
    for d in p.split(|&c| c == b':') {
        let d: &[u8] = if d.is_empty() { b"." } else { d };
        let f = path(&[d, b"/", name.as_bytes()]);
        let c = match std::ffi::CString::new(f) {
            Ok(c) => c,
            Err(_) => continue,
        };
        if unsafe { libc::access(c.as_ptr(), libc::X_OK) } == 0 && is_file(c.as_bytes()) {
            return true;
        }
    }
    false
}

pub fn osstr(b: Bytes) -> OsString {
    OsString::from_vec(b)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::compat::tests::bash;

    #[test]
    fn read_splits_as_bash() {
        let cases: &[&[u8]] = &[b"\tx\t\ty\t", b"a\tb\t\tc\t", b"", b"\t\t", b"one", b"a\t\t\tb", b" sp ace\tb  \t c "];
        for c in cases {
            for n in 1..4 {
                let names: Vec<String> = (0..n).map(|i| format!("v{}", i)).collect();
                let pr: Vec<String> = names.iter().map(|v| format!("\"[${}]\"", v)).collect();
                let s = format!("IFS=$'\\t' read -r {} <<<\"$1\"; printf '%s\\n' {}", names.join(" "), pr.join(" "));
                let theirs = bash(&s, &[c]);
                let ours: Bytes = read_ws(c, n, b"\t").iter().flat_map(|f| crate::render::cat(&[b"[", f, b"]\n"])).collect();
                assert_eq!(String::from_utf8_lossy(&ours), String::from_utf8_lossy(&theirs), "{:?} into {}", String::from_utf8_lossy(c), n);
                let s = format!("IFS=: read -r {} <<<\"$1\"; printf '%s\\n' {}", names.join(" "), pr.join(" "));
                let c2: Bytes = c.iter().map(|&b| if b == b'\t' { b':' } else { b }).collect();
                let theirs = bash(&s, &[&c2]);
                let ours: Bytes = read_delim(&c2, n, b':').iter().flat_map(|f| crate::render::cat(&[b"[", f, b"]\n"])).collect();
                assert_eq!(String::from_utf8_lossy(&ours), String::from_utf8_lossy(&theirs), "{:?} into {} (:)", String::from_utf8_lossy(&c2), n);
                let s = format!("read -r {} <<<\"$1\"; printf '%s\\n' {}", names.join(" "), pr.join(" "));
                let theirs = bash(&s, &[c]);
                let ours: Bytes = read_ws(c, n, b" \t\n").iter().flat_map(|f| crate::render::cat(&[b"[", f, b"]\n"])).collect();
                assert_eq!(String::from_utf8_lossy(&ours), String::from_utf8_lossy(&theirs), "{:?} into {} (default IFS)", String::from_utf8_lossy(c), n);
            }
        }
    }

    #[test]
    fn tails_and_heads() {
        assert_eq!(tail_n(b"a\nb\nc\n", 2), b"b\nc\n");
        assert_eq!(tail_n(b"a\nb\nc", 2), b"b\nc");
        assert_eq!(tail_n(b"a\n", 5), b"a\n");
        assert_eq!(head_n(b"a\nb\nc\n", 2), b"a\nb\n");
        assert_eq!(lines(b"a\n\nb"), vec![b"a".to_vec(), b"".to_vec()]);
        assert_eq!(mapfile(b"a\n\nb"), vec![b"a".to_vec(), b"".to_vec(), b"b".to_vec()]);
    }
}
