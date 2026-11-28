//! The agents' looks: scripts/panel.sh's agents_look and everything it calls, ported line for
//! line with the bash names in the comments. The screens (lines_state, one tmux for them all),
//! Claude Code's records (claude_record, claude_look, claude_turn_from), the accounts and plans
//! (acct_read, claude_acct, codex_acct), work in the background (snapshot_cmd, listen_load,
//! bg_serving), context left (ctx_left and common.sh's claude_ctx_file and ctx_pct, Codex's
//! rollout), usage limits (limit_look) and how long each pane has waited (wait_watch). jq's
//! programs are collect/jq.rs's; the caches keyed by SECONDS or by a file's stamp are G's.

use super::jq;
use super::sh::{self, Bytes};
use super::{m, n, procs, G};
use crate::compat::{re, Ere};

pub const Q_RE: &str = "do you want to|would you like to|allow (once|always)|\\(y/n\\)|\\[y/n\\]|enter to select|esc to cancel|trust (this|the) folder|yes, proceed|press enter to continue|ready to submit your answers|[0-9]\\. submit answers|enter (select|confirm|submit|choose)[^[:alnum:]]{1,8}esc (back|cancel|close)";
pub const W_RE: &str = "esc to interrupt|ctrl\\+c to interrupt";
pub const UUID_RE: &str = "/claude-[0-9]+/[^/]+/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(/|$)";
pub const LIM_MON: &[u8] = b" jan feb mar apr may jun jul aug sep oct nov dec";
pub const LIM_RE: &str = "(resets|try again at)( at)? ((jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]* ([0-9]{1,2})(st|nd|rd|th)?,( ([0-9]{4}),?)? )?([0-9]{1,2})(:([0-9]{2}))? ?([ap]m)?( \\(([A-Za-z][A-Za-z0-9_+/-]*)\\))?";

/// `shopt -s nocasematch; [[ S =~ RE ]]`: compiled once with REG_ICASE
pub fn re_i(pat: &str) -> &'static Ere {
    use std::collections::HashMap;
    use std::sync::{Mutex, OnceLock};
    static C: OnceLock<Mutex<HashMap<String, &'static Ere>>> = OnceLock::new();
    let mut g = C.get_or_init(|| Mutex::new(HashMap::new())).lock().unwrap();
    if let Some(e) = g.get(pat) {
        return e;
    }
    let e: &'static Ere = Box::leak(Box::new(Ere::new(pat.as_bytes(), true).expect("regcomp")));
    g.insert(pat.to_string(), e);
    e
}

/// lines_state ARRAY -> LSTATE: asking / working / waiting, read off the bottom of a screen
pub fn lines_state(l: &[Bytes]) -> &'static [u8] {
    let mut cnt = 0;
    let mut tail: Bytes = Vec::new();
    let mut prompt = false;
    let mut i = l.len() as i64 - 1;
    while i >= 0 && cnt < 12 {
        let s = &l[i as usize];
        i -= 1;
        if re("^[[:space:]]*$").is_match(s) {
            continue;
        }
        cnt += 1;
        tail.extend_from_slice(s);
        tail.push(b'\n');
        // ${L[i]//$'\xc2\xa0'/ }
        let nb = crate::render::panes::sub_all(s, b"\xc2\xa0", b" ");
        if cnt <= 6
            && re("^(❯|›|>) ?").is_match(&nb)
            && !(re("^(❯|›|>)[[:space:]]+[0-9]+\\.").is_match(s) || re("^(❯|›|>)[[:space:]]{2,}[^[:space:]]").is_match(s))
        {
            prompt = true;
        }
    }
    if !prompt && re_i(Q_RE).is_match(&tail) {
        b"asking"
    } else if re_i(W_RE).is_match(&tail) {
        b"working"
    } else {
        b"waiting"
    }
}

/// iso_epoch 2026-11-15T03:01:54Z -> ISO_S: seconds since 1970, or nothing
pub fn iso_epoch(s: &[u8]) -> Option<i64> {
    let mm = re("^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})Z$").matches(s)?;
    let d10 = |b: &[u8]| -> i64 { std::str::from_utf8(b).ok().and_then(|x| x.parse().ok()).unwrap_or(0) };
    let (mut y, mo, d) = (d10(&mm[1]), d10(&mm[2]), d10(&mm[3]));
    if mo <= 2 {
        y -= 1;
    }
    // bash's / truncates
    let era = y / 400;
    let yoe = y - era * 400;
    let doy = (153 * (if mo > 2 { mo - 3 } else { mo + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    Some((era * 146097 + doe - 719468) * 86400 + d10(&mm[4]) * 3600 + d10(&mm[5]) * 60 + d10(&mm[6]))
}

/// in_turn TIME W0 SINCE: TIME is in the pane's last working stretch: after it last began to
/// work (W0, a few seconds' grace: a message starts it), or, that not seen, in the ten minutes
/// before it began to wait (SINCE)
fn in_turn(t: i64, w0: &[u8], since: i64) -> bool {
    if w0.is_empty() {
        t > since - 600 && t <= since + 5
    } else {
        t >= n(w0) - 15
    }
}

/// lim_at ISO-TIME -> ISO_S, as iso_epoch, its fraction of a second dropped
pub fn lim_at(s: &[u8]) -> Option<i64> {
    let t = s.strip_suffix(b"Z").unwrap_or(s);
    // ${t%.*}
    let t = match t.iter().rposition(|&c| c == b'.') {
        Some(i) => &t[..i],
        None => t,
    };
    iso_epoch(&sh::path(&[t, b"Z"]))
}

/// common.sh's ctx_pct USED WINDOW -> percent left, or nothing
pub fn ctx_pct(u: &[u8], w: &[u8]) -> Bytes {
    if !(m("^[0-9]+$", u) && m("^[0-9]+$", w)) || n(w) <= 0 {
        return Vec::new();
    }
    let (u, w) = (n(u), n(w));
    let mut l = 100 - (u.wrapping_mul(100).wrapping_add(w / 2)) / w;
    if l < 0 {
        l = 0;
    }
    l.to_string().into_bytes()
}

/// `${s//[^SET]/_}` for a set of ASCII bytes: each character not in it (a byte that doesn't
/// decode is one) made `_`
fn only(s: &[u8], keep: &[u8], rep: &[u8]) -> Bytes {
    let mut o = Vec::new();
    for c in crate::compat::chars(s) {
        if c.len() == 1 && keep.contains(&c[0]) {
            o.push(c[0]);
        } else {
            o.extend_from_slice(rep);
        }
    }
    o
}
const ALNUM: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

/// The plan's characters kept: `${p//[^A-Za-z0-9._\/:+-]/_}`, then `${p:0:80}`
fn plan_clean(p: &[u8]) -> Bytes {
    let k = sh::path(&[ALNUM, b"._/:+-"]);
    crate::compat::substr(&only(p, &k, b"_"), 0, Some(80)).unwrap_or_default()
}

/// `${R%/sessions/*}`
fn before_sessions(r: &[u8]) -> Bytes {
    match r.windows(10).rposition(|w| w == b"/sessions/") {
        Some(i) => r[..i].to_vec(),
        None => r.to_vec(),
    }
}

/// own_plain FILE UID: FILE is UID's, reached by no symbolic link
pub fn own_plain(f: &[u8], uid: &[u8]) -> bool {
    sh::is_file(f)
        && m("^[0-9]+$", uid)
        && std::fs::canonicalize(sh::os(f)).map(|p| p.into_os_string().into_encoded_bytes()).ok().as_deref() == Some(f)
        && sh::owner(f).map(|o| o.to_string().into_bytes()).as_deref() == Some(uid)
}

/// `"DIR"/*/NAME` over DIR's folders, the glob in its order, those that are files
fn files_in_subdirs(dir: &[u8], name: &[u8]) -> Vec<Bytes> {
    sh::glob_sub(dir, name).into_iter().filter(|f| sh::is_file(f)).collect()
}

/// `${A[i]}` words of a stored list
fn word_of(pid: &[u8]) -> &[u8] {
    pid
}

/// open_files PID: paths the process holds open (readlink of each /proc/PID/fd/*, glob order)
pub fn open_files(pid: &[u8]) -> Vec<Bytes> {
    let fd = sh::path(&[b"/proc/", pid, b"/fd"]);
    if sh::is_dir(&fd) {
        let mut v = Vec::new();
        for l in sh::glob(&fd, b"", b"", false) {
            if let Some(t) = sh::readlink(&l) {
                // `while IFS= read -r f`: a target holding a newline reads as more lines
                for x in t.split(|&c| c == b'\n') {
                    v.push(x.to_vec());
                }
            }
        }
        v
    } else if sh::on_path("lsof") {
        let o = sh::run(&[b"lsof", b"-p", pid, b"-Fn"]);
        sh::lines(&o.out).into_iter().filter_map(|l| l.strip_prefix(b"n").map(|x| x.to_vec())).collect()
    } else {
        Vec::new()
    }
}

/// `[[ $f == */sessions/*/rollout-*.jsonl ]]`
fn rollout_path(f: &[u8]) -> bool {
    if !f.ends_with(b".jsonl") {
        return false;
    }
    let Some(i) = f.windows(10).position(|w| w == b"/sessions/") else { return false };
    let end = f.len() - 6;
    let mut j = i + 10;
    while j + 9 <= end {
        if &f[j..j + 9] == b"/rollout-" {
            return true;
        }
        j += 1;
    }
    false
}

/// `*" source "*/shell-snapshots/snapshot-*`
fn snapshot_args(a: &[u8]) -> bool {
    match a.windows(8).position(|w| w == b" source ") {
        Some(i) => sh::contains(&a[i + 8..], b"/shell-snapshots/snapshot-"),
        None => false,
    }
}

/// find DIR -type f -name 'PRE*SUF' [-mmin -N]: in find's own order (each folder as readdir
/// gives it, depth first), links not followed
fn find_files(dir: &[u8], pre: &[u8], suf: &[u8], mmin: Option<i64>, out: &mut Vec<Bytes>) {
    use std::os::unix::fs::MetadataExt;
    let Ok(rd) = std::fs::read_dir(sh::os(dir)) else { return };
    for e in rd.flatten() {
        let p = sh::path(&[dir, b"/", &e.file_name().into_encoded_bytes()]);
        let Ok(md) = std::fs::symlink_metadata(sh::os(&p)) else { continue };
        let name = sh::basename(&p).to_vec();
        if md.file_type().is_file() && name.starts_with(pre) && name.ends_with(suf) && name.len() >= pre.len() + suf.len() {
            let ok = match mmin {
                // -mmin -N: changed less than N minutes before find started
                Some(nm) => {
                    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos() as i128).unwrap_or(0);
                    let mt = md.mtime() as i128 * 1_000_000_000 + md.mtime_nsec() as i128;
                    mt > now - nm as i128 * 60_000_000_000
                }
                None => true,
            };
            if ok {
                out.push(p.clone());
            }
        }
        if md.file_type().is_dir() {
            find_files(&p, pre, suf, mmin, out);
        }
    }
}

/// The variables claude_look sets
#[derive(Default)]
pub struct Look {
    pub cst: Bytes,
    pub cbg: bool,
    pub csrv: bool,
    pub csu: Bytes,
    pub csa: Bytes,
}

/// Which account file's programs acct_read runs
#[derive(Clone, Copy)]
enum Acct {
    Claude,
    Codex,
}

/// tz_off EPOCH -> TZO: the offset from UTC then, in seconds, in the zone TZ names
pub fn tz_off(e: i64) -> i64 {
    let z = crate::compat::strftime(b"%z", e);
    if z.len() < 5 {
        return 0;
    }
    let d = |b: &[u8]| -> i64 { std::str::from_utf8(b).ok().and_then(|x| x.parse().ok()).unwrap_or(0) };
    let s = if z[0] == b'-' { -1 } else { 1 };
    (d(&z[1..3]) * 3600 + d(&z[3..5]) * 60) * s
}

/// local_epoch Y M D H MIN -> LEPOCH: that wall-clock time in the zone TZ names
pub fn local_epoch(y: i64, mo: i64, d: i64, h: i64, mi: i64) -> i64 {
    let o = format!("{:04}-{:02}-{:02}T{:02}:{:02}:00Z", y, mo, d, h, mi);
    let iso = iso_epoch(o.as_bytes()).unwrap_or(0);
    let t1 = tz_off(iso);
    let mut le = iso - t1;
    let t2 = tz_off(le);
    if t2 != t1 {
        le = iso - t2;
    }
    le
}

/// lim_reset AT TEXT -> LRESET: when the limit TEXT (written at AT) lifts, or nothing
pub fn lim_reset(at: i64, text: &[u8]) -> Option<i64> {
    if let Some(mm) = re("\\|([0-9]{10})([^0-9]|$)").matches(text) {
        return Some(n(&mm[1]));
    }
    let mm = re_i(LIM_RE).matches(text)?;
    let d10 = |b: &[u8]| -> i64 { std::str::from_utf8(b).ok().and_then(|x| x.parse().ok()).unwrap_or(0) };
    let mut h = d10(&mm[9]);
    let mi = d10(&mm[11]);
    match crate::compat::case_map(&mm[12], false).as_slice() {
        b"pm" if h < 12 => h += 12,
        b"am" if h == 12 => h = 0,
        _ => {}
    }
    if !(h < 24 && mi < 60) {
        return None;
    }
    // In the zone it names, if this computer knows it (else this computer's own).
    let z = &mm[14];
    let mut zone: Option<&[u8]> = None;
    if !z.is_empty() && !sh::contains(z, b"..") {
        for d in [&b"/usr/share/zoneinfo"[..], b"/var/db/timezone/zoneinfo", b"/usr/share/lib/zoneinfo"] {
            if sh::is_file(&sh::path(&[d, b"/", z])) {
                zone = Some(z);
                break;
            }
        }
    }
    let when = || if !mm[4].is_empty() {
        let mon = crate::compat::case_map(&mm[4], false);
        // mo=${LIM_MON%%" $mon"*}; mo=$((${#mo} / 4 + 1))
        let pre = LIM_MON.windows(mon.len() + 1).position(|w| w[0] == b' ' && &w[1..] == mon.as_slice()).unwrap_or(LIM_MON.len());
        let mo = pre as i64 / 4 + 1;
        let d = d10(&mm[5]);
        let y = if mm[8].is_empty() { d10(&crate::compat::strftime(b"%Y", at)) } else { d10(&mm[8]) };
        let mut le = local_epoch(y, mo, d, h, mi);
        if mm[8].is_empty() && le < at - 86400 {
            le = local_epoch(y + 1, mo, d, h, mi);
        }
        le
    } else {
        let w = crate::compat::strftime(b"%H %M %S", at);
        let f = sh::read_ws(&w, 3, b" \t\n");
        let mut w = h * 3600 + mi * 60 - (d10(&f[0]) * 3600 + d10(&f[1]) * 60 + d10(&f[2]));
        if w <= -60 {
            w += 86400;
        }
        // A change of the clocks in between moves it by as much.
        let o = tz_off(at);
        let t = tz_off(at + w);
        at + w - (t - o)
    };
    Some(match zone {
        Some(z) => crate::compat::in_zone(z, when),
        None => when(),
    })
}

/// claude_limit_file: a transcript -> "AT RESET -", or nothing
pub fn claude_limit_file(f: &[u8]) -> Bytes {
    let data = sh::tail_c(f, 2_000_000);
    let lines: Vec<&[u8]> = sh::split_lines(&data).into_iter().filter(|l| re("\"type\":\"(user|assistant)\"").is_match(l)).collect();
    let out = jq::claude_limit(&lines).unwrap_or_default();
    let first = out.split('\n').next().unwrap_or("").as_bytes().to_vec();
    let fl = sh::read_delim(&first, 2, 0x1f);
    let Some(iso) = lim_at(&fl[0]) else { return Vec::new() };
    let lr = lim_reset(iso, &fl[1]);
    format!("{} {} -", iso, lr.map(|x| x.to_string()).unwrap_or("-".into())).into_bytes()
}

/// codex_limit_file: a rollout -> "AT RESET PLAN", or nothing
pub fn codex_limit_file(f: &[u8]) -> Bytes {
    let data = sh::tail_c(f, 2_000_000);
    let lines: Vec<&[u8]> = sh::split_lines(&data).into_iter().filter(|l| re("\"(task_started|task_complete|turn_aborted|token_count|error)\"").is_match(l)).collect();
    let out = jq::codex_limit(&lines).unwrap_or_default();
    let first = out.split('\n').next().unwrap_or("").as_bytes().to_vec();
    let fl = sh::read_delim(&first, 4, 0x1f);
    let Some(iso) = lim_at(&fl[0]) else { return Vec::new() };
    let mut lr = lim_reset(iso, &fl[3]);
    // The time one of its limits resets, to the second, when it's in that minute.
    for r in fl[1].split(|c| c.is_ascii_whitespace()).filter(|w| !w.is_empty()) {
        if let Some(l) = lr {
            if m("^[0-9]{1,12}$", r) && n(r) >= l && n(r) < l + 60 {
                lr = Some(n(r));
            }
        }
    }
    let pl = plan_clean(&fl[2]);
    let pl = if pl.is_empty() { b"-".to_vec() } else { pl };
    sh::path(&[format!("{} {} ", iso, lr.map(|x| x.to_string()).unwrap_or("-".into())).as_bytes(), &pl])
}

/// codex_ctx_file: a rollout -> percent left
pub fn codex_ctx_file(f: &[u8]) -> Bytes {
    let data = sh::tail_c(f, 2_000_000);
    let mut last: Option<String> = None;
    for l in sh::split_lines(&data) {
        if sh::contains(l, b"\"token_count\"") {
            if let Some(o) = jq::codex_tokens(l) {
                for x in o.split('\n') {
                    last = Some(x.to_string());
                }
            }
        }
    }
    let l = last.unwrap_or_default();
    let f = sh::read_ws(l.as_bytes(), 2, b" \t\n");
    ctx_pct(&f[0], &f[1])
}

/// common.sh's claude_ctx_file: a transcript -> percent left
pub fn claude_ctx_file(f: &[u8]) -> Bytes {
    let w0 = sh::env("REVIVE_CLAUDE_WINDOW").unwrap_or_default();
    // dir=${1%/projects/*}
    let dir = match f.windows(10).rposition(|w| w == b"/projects/") {
        Some(i) => f[..i].to_vec(),
        None => f.to_vec(),
    };
    let data = sh::tail_c(f, 4_000_000);
    // jq's lines, then awk '$1 == "a" { u = $2; p = $2; m = $3 } $1 == "c" { u = $2 } END {...}'
    let (mut u, mut mo, mut p): (Bytes, Bytes, Bytes) = (Vec::new(), Vec::new(), Vec::new());
    for l in sh::split_lines(&data) {
        if !(sh::contains(l, b"\"usage\"") || sh::contains(l, b"\"compact_boundary\"")) {
            continue;
        }
        let Some(o) = jq::claude_usage(l) else { continue };
        for rec in o.split('\n') {
            let fs: Vec<&[u8]> = rec.as_bytes().split(|c| *c == b' ' || *c == b'\t').filter(|x| !x.is_empty()).collect();
            let g = |i: usize| fs.get(i).map(|x| x.to_vec()).unwrap_or_default();
            match fs.first().copied() {
                Some(b"a") => {
                    u = g(1);
                    p = g(1);
                    mo = g(2);
                }
                Some(b"c") => u = g(1),
                _ => {}
            }
        }
    }
    if u.is_empty() {
        return Vec::new();
    }
    // read -r u m p <<<"u m p"
    let line = sh::path(&[&u, b" ", &mo, b" ", &p]);
    let r = sh::read_ws(&line, 3, b" \t\n");
    let (u, mo, p) = (r[0].clone(), r[1].clone(), r[2].clone());
    let mut w = w0;
    if w.is_empty() {
        w = b"200000".to_vec();
        let gt = |x: &[u8]| crate::compat::arith_int(x).is_some_and(|v| v > 200000);
        let p0 = if p.is_empty() { b"0".to_vec() } else { p.clone() };
        let big = (crate::compat::arith_int(&u).is_some() && crate::compat::arith_int(&p0).is_some() && (gt(&u) || gt(&p0)))
            || m("^claude-[a-z]+-5", &mo)
            || m("^claude-(opus|sonnet)-4-[6-9]", &mo)
            || sh::contains(&mo, b"[1m]")
            || std::fs::read(sh::os(&sh::path(&[&dir, b"/settings.json"])))
                .map(|d| sh::split_lines(&d).iter().any(|l| re("\"model\": *\"[^\"]*\\[1m\\]").is_match(l)))
                .unwrap_or(false);
        if big {
            w = b"1000000".to_vec();
        }
    }
    ctx_pct(&u, &w)
}

/// codex_wait_at: a rollout file -> when its unanswered wait call was made (epoch), or nothing
pub fn codex_wait_at(f: &[u8]) -> Bytes {
    let data = sh::tail_c(f, 1_000_000);
    let lines: Vec<&[u8]> = sh::split_lines(&data).into_iter().filter(|l| re("\"(function_call|function_call_output|task_complete|turn_aborted)\"").is_match(l)).collect();
    sh::cmdsub(jq::codex_wait(&lines).unwrap_or_default().as_bytes())
}

impl G {
    fn secs_since(t: Option<&i64>) -> bool {
        // [[ -z ${T:-} ]] || ((SECONDS - T >= 30))
        match t {
            None => true,
            Some(t) => sh::seconds() - t >= 30,
        }
    }

    /// claude_record PID -> RECORD: Claude Code's session record for it, or nothing
    pub fn claude_record(&mut self, pid: &[u8]) -> Bytes {
        let name = sh::path(&[pid, b".json"]);
        for d in sh::glob(&self.home, b".claude", b"", true) {
            let f = sh::path(&[&d, b"/sessions/", &name]);
            if sh::is_file(&f) {
                return f;
            }
        }
        let ccd = sh::env("CLAUDE_CONFIG_DIR").unwrap_or_default();
        if !ccd.is_empty() {
            let f = sh::path(&[&ccd, b"/sessions/", &name]);
            if sh::is_file(&f) {
                return f;
            }
        }
        if !(m("^[0-9]+$", pid) && sh::readable(&sh::path(&[b"/proc/", pid, b"/environ"]))) {
            return Vec::new();
        }
        if self.cl_erec.get(pid).is_none_or(|v| v.is_empty()) && Self::secs_since(self.cl_erec_t.get(pid)) {
            self.cl_erec_t.insert(pid.to_vec(), sh::seconds());
            let mut d: Vec<Bytes> = Vec::new();
            for e in super::environ(pid).unwrap_or_default() {
                if let Some(v) = e.strip_prefix(b"CLAUDE_CONFIG_DIR=").filter(|v| v.starts_with(b"/")) {
                    d.insert(0, v.to_vec());
                } else if let Some(v) = e.strip_prefix(b"HOME=").filter(|v| v.starts_with(b"/")) {
                    d.push(sh::path(&[v, b"/.claude"]));
                }
            }
            let uid = sh::owner(&sh::path(&[b"/proc/", pid])).map(|o| o.to_string().into_bytes()).unwrap_or_default();
            for f in d {
                let r = sh::path(&[&f, b"/sessions/", &name]);
                if own_plain(&r, &uid) {
                    self.cl_erec.insert(pid.to_vec(), r);
                    break;
                }
            }
        }
        match self.cl_erec.get(pid) {
            Some(r) if !r.is_empty() && sh::is_file(r) => r.clone(),
            _ => Vec::new(),
        }
    }

    /// `${PUID[$1]:-$UID}`
    fn puid(&self, pid: &[u8]) -> Bytes {
        self.t.uid.get(pid).filter(|v| !v.is_empty()).cloned().unwrap_or_else(|| self.uid.clone())
    }

    /// acct_read PID FILE (its programs) -> ACCT, PLAN
    fn acct_read(&mut self, pid: &[u8], f: &[u8], k: Acct) -> (Bytes, Bytes) {
        if Self::secs_since(self.cl_at.get(f)) {
            self.cl_at.insert(f.to_vec(), sh::seconds());
            let st = sh::fstamp(f);
            if self.cl_astamp.get(f).map(|v| v.as_slice()).unwrap_or(b"") != st.as_slice() {
                self.cl_astamp.insert(f.to_vec(), st.clone());
                self.cl_acct.insert(f.to_vec(), Vec::new());
                self.cl_plan.insert(f.to_vec(), Vec::new());
                let pu = self.puid(pid);
                if !st.is_empty() && (pu == self.uid || own_plain(f, self.t.uid.get(pid).map(|v| v.as_slice()).unwrap_or(b""))) {
                    let data = std::fs::read(sh::os(f)).unwrap_or_default();
                    let out = match k {
                        Acct::Claude => jq::acct(&data, jq::cl_acct, jq::cl_plan),
                        Acct::Codex => jq::acct(&data, jq::cx_email, jq::cx_plan),
                    };
                    let first = out.first().cloned().unwrap_or_default().into_bytes();
                    let r = sh::read_delim(&first, 2, 0x1f);
                    let mut e = r[0].clone();
                    if let Some(i) = e.iter().position(|&c| c == b'@') {
                        e.truncate(i);
                    }
                    let e = crate::compat::substr(&e, 0, Some(12)).unwrap_or_default();
                    if m("^[A-Za-z0-9._+-]+$", &e) {
                        self.cl_acct.insert(f.to_vec(), e);
                    }
                    self.cl_plan.insert(f.to_vec(), plan_clean(&r[1]));
                }
            }
        }
        (self.cl_acct.get(f).cloned().unwrap_or_default(), self.cl_plan.get(f).cloned().unwrap_or_default())
    }

    /// claude_acct PID -> ACCT, PLAN
    pub fn claude_acct(&mut self, pid: &[u8]) -> (Bytes, Bytes) {
        if self.cl_cdir.get(pid).is_none_or(|v| v.is_empty()) {
            let (mut d, mut h): (Bytes, Bytes) = (Vec::new(), Vec::new());
            if m("^[0-9]+$", pid) && sh::readable(&sh::path(&[b"/proc/", pid, b"/environ"])) {
                for e in super::environ(pid).unwrap_or_default() {
                    if let Some(v) = e.strip_prefix(b"CLAUDE_CONFIG_DIR=").filter(|v| v.starts_with(b"/")) {
                        d = v.to_vec();
                    } else if let Some(v) = e.strip_prefix(b"HOME=").filter(|v| v.starts_with(b"/")) {
                        h = v.to_vec();
                    }
                }
                if d.is_empty() && !h.is_empty() {
                    self.cl_pfile.insert(pid.to_vec(), sh::path(&[&h, b"/.claude.json"]));
                }
                if d.is_empty() && !h.is_empty() {
                    d = sh::path(&[&h, b"/.claude"]);
                }
            } else {
                let r = self.claude_record(pid);
                if !r.is_empty() {
                    d = before_sessions(&r);
                }
            }
            if d.ends_with(b"/") {
                d.pop();
            }
            if d.is_empty() {
                return (Vec::new(), Vec::new());
            }
            self.cl_cdir.insert(pid.to_vec(), d);
        }
        let d = self.cl_cdir[pid].clone();
        let mut f = sh::path(&[&d, b"/.claude.json"]);
        if !sh::is_file(&f) && d.ends_with(b"/.claude") {
            f = sh::path(&[&d[..d.len() - 8], b"/.claude.json"]);
        }
        let pf = self.cl_pfile.get(pid).cloned().unwrap_or_default();
        if !pf.is_empty() && pf != f && sh::is_file(&pf) {
            let (_, e) = self.acct_read(pid, &pf, Acct::Claude);
            let (a, _) = self.acct_read(pid, &f, Acct::Claude);
            (a, e)
        } else {
            self.acct_read(pid, &f, Acct::Claude)
        }
    }

    /// codex_acct PID -> ACCT, PLAN
    pub fn codex_acct(&mut self, pid: &[u8]) -> (Bytes, Bytes) {
        if self.cx_cdir.get(pid).is_none_or(|v| v.is_empty()) {
            let (mut d, mut h): (Bytes, Bytes) = (Vec::new(), Vec::new());
            if m("^[0-9]+$", pid) && sh::readable(&sh::path(&[b"/proc/", pid, b"/environ"])) {
                for e in super::environ(pid).unwrap_or_default() {
                    if let Some(v) = e.strip_prefix(b"CODEX_HOME=").filter(|v| v.starts_with(b"/")) {
                        d = v.to_vec();
                    } else if let Some(v) = e.strip_prefix(b"HOME=").filter(|v| v.starts_with(b"/")) {
                        h = v.to_vec();
                    }
                }
                if d.is_empty() && !h.is_empty() {
                    d = sh::path(&[&h, b"/.codex"]);
                }
            } else if self.puid(pid) == self.uid {
                d = sh::env("CODEX_HOME").filter(|v| !v.is_empty()).unwrap_or_else(|| sh::path(&[&self.home, b"/.codex"]));
            }
            if d.ends_with(b"/") {
                d.pop();
            }
            if d.is_empty() {
                return (Vec::new(), Vec::new());
            }
            self.cx_cdir.insert(pid.to_vec(), d);
        }
        let f = sh::path(&[&self.cx_cdir[pid], b"/auth.json"]);
        self.acct_read(pid, &f, Acct::Codex)
    }

    /// snapshot_cmd PID: a command Claude Code started still runs under PID
    fn snapshot_cmd(&self, pid: &[u8]) -> bool {
        let mut q: std::collections::VecDeque<Bytes> = self.t.children(pid).iter().cloned().collect();
        while let Some(p) = q.pop_front() {
            if snapshot_args(self.t.args_of(&p)) {
                return true;
            }
            q.extend(self.t.children(&p).iter().cloned());
        }
        false
    }

    /// listen_load: which processes listen on a TCP port, once a look (ss, else lsof)
    fn listen_load(&mut self) {
        if self.listen_at == Some(self.gather_n) {
            return;
        }
        self.listen_at = Some(self.gather_n);
        self.listens.clear();
        if sh::on_path("ss") {
            let o = sh::run(&[b"ss", b"-Hltnp"]);
            for l in sh::lines(&o.out) {
                let mut l = l;
                while let Some(mm) = re("pid=([0-9]+)(.*)$").matches(&l) {
                    self.listens.insert(mm[1].clone());
                    l = mm[2].clone();
                }
            }
        } else if sh::on_path("lsof") {
            let o = sh::run(&[b"lsof", b"-nP", b"-iTCP", b"-sTCP:LISTEN", b"-Fp"]);
            for l in sh::lines(&o.out) {
                let l = sh::read_ws(&l, 1, b" \t\n").remove(0);
                if let Some(mm) = re("^p([0-9]+)$").matches(&l) {
                    self.listens.insert(mm[1].clone());
                }
            }
        }
    }

    /// bg_serving PID: the commands Claude Code started that still run under PID are all servers
    fn bg_serving(&mut self, pid: &[u8]) -> bool {
        let mut roots = Vec::new();
        let mut q: std::collections::VecDeque<Bytes> = self.t.children(pid).iter().cloned().collect();
        while let Some(p) = q.pop_front() {
            if snapshot_args(self.t.args_of(&p)) {
                roots.push(p);
                continue;
            }
            q.extend(self.t.children(&p).iter().cloned());
        }
        if roots.is_empty() {
            return false;
        }
        self.listen_load();
        for r in roots {
            let mut t: std::collections::VecDeque<Bytes> = std::collections::VecDeque::from([r]);
            let mut found = false;
            while let Some(p) = t.pop_front() {
                if self.listens.contains(&p) {
                    found = true;
                    break;
                }
                t.extend(self.t.children(&p).iter().cloned());
            }
            if !found {
                return false;
            }
        }
        true
    }

    /// claude_look PID -> CST (busy/idle/waiting or nothing), CBG, CSRV, CSU, CSA
    pub fn claude_look(&mut self, pid: &[u8]) -> Look {
        let mut l = Look::default();
        let rec = self.claude_record(pid);
        if rec.is_empty() {
            return l;
        }
        let (cst, sid, csu, csa) = if let Some(v) = self.jq_st.get(&rec) {
            v.clone()
        } else {
            let out = jq::records_tsv(&[rec.clone()], false);
            let first = out.first().cloned().unwrap_or_default();
            let f = sh::read_ws(&first, 4, b"\t");
            (f[0].clone(), f[1].clone(), f[2].clone(), f[3].clone())
        };
        l.cst = cst;
        l.csu = if m("^[0-9]{10,13}$", &csu) { csu[..10].to_vec() } else { Vec::new() };
        l.csa = if m("^[0-9]{10,13}$", &csa) { csa[..10].to_vec() } else { Vec::new() };
        self.cl_rec = rec;
        self.cl_sid = sid.clone();
        if l.cst == b"shell" {
            l.cst = b"idle".to_vec();
        }
        if l.cst != b"idle" {
            return l;
        }
        if self.bg_serving(pid) {
            l.csrv = true;
        } else if self.snapshot_cmd(pid) {
            l.cbg = true;
            return l;
        }
        if !m("^[A-Za-z0-9-]+$", &sid) {
            return l;
        }
        let mut roots: Vec<Bytes> = Vec::new();
        let mut cand: Vec<Bytes> = Vec::new();
        for k in ["CLAUDE_CODE_TMPDIR", "TMPDIR"] {
            let v = sh::env(k).unwrap_or_default();
            if !v.is_empty() {
                let mut v = v;
                if v.ends_with(b"/") {
                    v.pop();
                }
                cand.push(v);
            }
        }
        cand.push(b"/tmp".to_vec());
        for d in cand {
            let joined = sh::path(&[b" ", &roots.join(&b' '), b" "]);
            if !sh::contains(&joined, &sh::path(&[b" ", &d, b" "])) {
                roots.push(d);
            }
        }
        let mut f: Vec<Bytes> = Vec::new();
        for d in &roots {
            // "$d"/claude-"$UID"/*/"$sid"/tasks/*.output, the glob's order
            let mut hits = Vec::new();
            for sub in sh::glob(&sh::path(&[d, b"/claude-", &self.uid]), b"", b"", false) {
                for t in sh::glob(&sh::path(&[&sub, b"/", &sid, b"/tasks"]), b"", b".output", false) {
                    hits.push(t);
                }
            }
            hits.sort_by(|a, b| crate::compat::strcoll(a, b));
            for t in hits {
                if sh::exists(&t) && (!l.csrv || sh::is_link(&t)) {
                    f.push(t);
                }
            }
        }
        if f.is_empty() {
            return l;
        }
        let mut mx: i64 = 0;
        for t in &f {
            if let Some(x) = sh::mtime(t) {
                if x > mx {
                    mx = x;
                }
            }
        }
        if mx != 0 && self.now() - mx <= self.bg_secs {
            l.cbg = true;
            l.csrv = false;
        }
        l
    }

    /// claude_turn_from PID SINCE -> TFROM (a, u or nothing), TAT
    pub fn claude_turn_from(&mut self, pid: &[u8], since: &[u8]) -> (Bytes, Bytes) {
        let sid = self.cl_sid.clone();
        if self.tf_k.get(pid).map(|v| v.as_slice()) == Some(since) {
            return (self.tf_v.get(pid).cloned().unwrap_or_default(), self.tf_a.get(pid).cloned().unwrap_or_default());
        }
        self.tf_k.insert(pid.to_vec(), since.to_vec());
        self.tf_v.insert(pid.to_vec(), Vec::new());
        self.tf_a.insert(pid.to_vec(), Vec::new());
        let rec = self.claude_record(pid);
        if rec.is_empty() || !m("^[A-Za-z0-9-]+$", &sid) {
            return (Vec::new(), Vec::new());
        }
        let (mut tfrom, mut tat) = (Vec::new(), Vec::new());
        for f in sh::glob_sub(&sh::path(&[&before_sessions(&rec), b"/projects"]), &sh::path(&[&sid, b".jsonl"])) {
            if !sh::is_file(&f) {
                continue;
            }
            // tail -c 1000000 | grep -o '"timestamp":"[0-9T:-]*' | tail -n 1
            let d = sh::tail_c(&f, 1_000_000);
            let mut t: Bytes = Vec::new();
            for line in sh::split_lines(&d) {
                let mut s = line;
                while let Some(i) = s.windows(13).position(|w| w == b"\"timestamp\":\"") {
                    let rest = &s[i + 13..];
                    let k = rest.iter().position(|c| !(c.is_ascii_digit() || *c == b'T' || *c == b':' || *c == b'-')).unwrap_or(rest.len());
                    t = sh::path(&[b"\"timestamp\":\"", &rest[..k]]);
                    s = &rest[k..];
                }
            }
            // ${t#*:\"}Z
            let t2 = match t.windows(2).position(|w| w == b":\"") {
                Some(i) => t[i + 2..].to_vec(),
                None => t.clone(),
            };
            tat = iso_epoch(&sh::path(&[&t2, b"Z"])).map(|x| x.to_string().into_bytes()).unwrap_or_default();
            self.tf_a.insert(pid.to_vec(), tat.clone());
            // The last prompt: a user line that isn't a tool's result or one Claude Code added.
            let d = sh::tail_c(&f, 4_000_000);
            let last = sh::split_lines(&d)
                .into_iter()
                .filter(|l| sh::contains(l, b"\"type\":\"user\"") && !sh::contains(l, b"\"tool_result\"") && !sh::contains(l, b"\"isMeta\":true"))
                .last();
            let t = match last.and_then(jq::turn_text) {
                Some(s) => sh::cmdsub(s.as_bytes()),
                None => Vec::new(),
            };
            if t.is_empty() {
                return (tfrom, tat);
            }
            tfrom = if t == b"[agent-msg from=" { b"a".to_vec() } else { b"u".to_vec() };
            self.tf_v.insert(pid.to_vec(), tfrom.clone());
            return (tfrom, tat);
        }
        (tfrom, tat)
    }

    /// mail_times -> MAIL_T[NAME]: when a message was last delivered to each name, and
    /// MAIL_A["FROM TO"]: when one from FROM to TO last was; MAIL_S: the same less (no reply) notices
    fn mail_times(&mut self) {
        let me = sh::env("AGENT_SAY_HOST").filter(|v| !v.is_empty()).unwrap_or_else(|| self.host.clone());
        let st = match std::fs::metadata(sh::os(&self.amail)) {
            Ok(md) => {
                use std::os::unix::fs::MetadataExt;
                format!("{} {}", md.mtime(), md.len()).into_bytes()
            }
            Err(_) => Vec::new(),
        };
        if st == self.mail_stamp {
            return;
        }
        self.mail_stamp = st.clone();
        self.mail_t.clear();
        self.mail_s.clear();
        self.mail_a.clear();
        if st.is_empty() {
            return;
        }
        let data = std::fs::read(sh::os(&self.amail)).unwrap_or_default();
        let at_me = sh::path(&[b"@", &me]);
        for l in sh::split_lines(sh::tail_n(&data, 600)) {
            if !l.starts_with(b"## [") {
                continue;
            }
            // read -r _ from _ to when rest
            let f = sh::read_ws(l, 6, b" \t\n");
            let (mut from, mut to, when, rest) = (f[1].clone(), f[3].clone(), f[4].clone(), f[5].clone());
            if sh::contains(&rest, b"(held") || sh::contains(&rest, b"NOT DELIVERED") {
                continue;
            }
            if to.ends_with(&at_me) {
                to.truncate(to.len() - at_me.len());
            }
            if !m("^[A-Za-z0-9][A-Za-z0-9_.:+=@-]*$", &to) {
                continue;
            }
            let w = when.strip_suffix(b"]").unwrap_or(&when);
            let Some(t) = iso_epoch(w) else { continue };
            if t > *self.mail_t.get(&to).unwrap_or(&0) {
                self.mail_t.insert(to.clone(), t);
            }
            if from.first() == Some(&b'[') {
                from.remove(0);
            }
            if from.ends_with(&at_me) {
                from.truncate(from.len() - at_me.len());
            }
            if !m("^[A-Za-z0-9][A-Za-z0-9_.:+=@-]*$", &from) {
                continue;
            }
            let k = sh::path(&[&from, b" ", &to]);
            if t > *self.mail_a.get(&k).unwrap_or(&0) {
                self.mail_a.insert(k.clone(), t);
            }
            if sh::contains(&rest, b"(no reply)") {
                continue;
            }
            if t > *self.mail_s.get(&k).unwrap_or(&0) {
                self.mail_s.insert(k, t);
            }
        }
    }

    /// wait_watch: for the panes nothing above said it of, when they began to wait as the panel
    /// saw it, and from the mailbox whether a message reached it since it last began to work.
    /// WW_W0: when it last began to work, as the panel saw it (when it first looked, for one
    /// already working then); WW_B0: when the panel saw it leave its prompt for work. And then,
    /// every pane's state known, for this computer's waiting at their prompt, whether one waits
    /// on another session's answer to a message it sent (W_REPLY): see reply_open.
    pub fn wait_watch(&mut self) {
        let now = self.now();
        let ost = std::mem::take(&mut self.ww_st);
        let ot0 = std::mem::take(&mut self.ww_t0);
        let ow0 = std::mem::take(&mut self.ww_w0);
        let ob0 = std::mem::take(&mut self.ww_b0);
        let mut at: std::collections::HashMap<Bytes, usize> = Default::default();
        self.mail_times();
        let nb = |s: i64| s.to_string().into_bytes();
        for i in 0..self.p.id.len() {
            let ii = i as i64;
            let k = if self.p.id[i].is_empty() { sh::path(&[&self.p.host[i], b":", &self.p.rid[i]]) } else { self.p.id[i].clone() };
            if k == b":" {
                continue;
            }
            let st = self.p.state[i].clone();
            self.ww_st.insert(k.clone(), st.clone());
            self.ww_w0.insert(k.clone(), ow0.get(&k).cloned().unwrap_or_default());
            self.ww_b0.insert(k.clone(), ob0.get(&k).cloned().unwrap_or_default());
            let os = ost.get(&k).map(|v| v.as_slice());
            if st == b"working" || st == b"agents" {
                if !(os == Some(b"working") || os == Some(b"agents")) {
                    self.ww_w0.insert(k.clone(), nb(now));
                }
                if os == Some(b"waiting") {
                    self.ww_b0.insert(k.clone(), nb(now));
                }
            } else if st == b"waiting" {
                let ws = self.p.w_since.get(&ii).cloned().unwrap_or_default();
                if !ws.is_empty() {
                    self.ww_t0.insert(k.clone(), ws);
                } else if let Some(o) = os {
                    let t0 = if o == b"waiting" { ot0.get(&k).cloned().unwrap_or_default() } else { nb(now) };
                    self.ww_t0.insert(k.clone(), t0.clone());
                    if !t0.is_empty() {
                        self.p.w_since.insert(ii, t0);
                    }
                }
                let ws = self.p.w_since.get(&ii).cloned().unwrap_or_default();
                if !ws.is_empty() && self.p.w_from.get(&ii).is_none_or(|v| v.is_empty()) {
                    let mut t = if self.p.name[i].is_empty() { b".".to_vec() } else { self.p.name[i].clone() };
                    if !self.p.host[i].is_empty() {
                        t = sh::path(&[&t, b"@", &self.p.host[i]]);
                    }
                    let t = self.mail_t.get(&t).copied();
                    let w = self.ww_w0.get(&k).cloned().unwrap_or_default();
                    let a = t.is_some_and(|t| in_turn(t, &w, n(&ws)));
                    self.p.w_from.insert(ii, if a { b"a".to_vec() } else { b"u".to_vec() });
                }
            }
            // Its name as the mailbox says it (name@host for a linked computer's), the first
            // pane with that name.
            if !self.p.name[i].is_empty() {
                let mut t = self.p.name[i].clone();
                if !self.p.host[i].is_empty() {
                    t = sh::path(&[&t, b"@", &self.p.host[i]]);
                }
                at.entry(t).or_insert(i);
            }
        }
        // This computer's, at their prompt: whether one waits on an answer to a message sent in
        // the last 90 minutes or in its last turn (one older, from a turn before, waits no
        // more). A linked computer's panes bring their own (#reply), from the mailbox there.
        for i in 0..self.p.id.len() {
            let ii = i as i64;
            let name = &self.p.name[i];
            if self.p.state[i] != b"waiting" || self.p.w_since.get(&ii).is_none_or(|v| v.is_empty()) || !self.p.host[i].is_empty() || name.is_empty() {
                continue;
            }
            let pre = sh::path(&[name, b" "]);
            let w0 = self.ww_w0.get(&self.p.id[i]).cloned().unwrap_or_default();
            let ws = n(&self.p.w_since.get(&ii).cloned().unwrap_or_default());
            if self.mail_s.iter().any(|(m, &t)| m.starts_with(&pre) && (t > now - 5400 || in_turn(t, &w0, ws)) && self.reply_open(i, &m[pre.len()..], t, &at)) {
                self.p.w_reply.insert(ii, b"1".to_vec());
            }
        }
    }

    /// reply_open ROW NAME TIME: the message ROW's pane sent NAME at TIME waits on an answer
    /// yet: NAME's pane hasn't been at its prompt since, however many turns ROW's has had
    /// since. Waiting there now, since before the message reached it (five seconds' grace): not
    /// yet. Working, or idle while its agents work: not yet, unless the panel saw it leave its
    /// prompt for work since (fifteen seconds' grace: the message starts it); that not seen (the
    /// panel started since), it may be on the message yet. Asking, or stopped at its usage
    /// limit, the same as working. An answer from it while it works doesn't close the wait; its prompt
    /// closes it, answered or not. A name with no agent in a pane the panel sees (gone, or not
    /// known here), as before: sent in ROW's last turn, and no message back from NAME since.
    /// at: wait_watch's, the row of each name.
    fn reply_open(&self, i: usize, x: &[u8], t: i64, at: &std::collections::HashMap<Bytes, usize>) -> bool {
        let j = at.get(x).copied();
        let st: &[u8] = j.map(|j| self.p.state[j].as_slice()).unwrap_or(b"");
        match st {
            b"waiting" => {
                let ws = self.p.w_since.get(&(j.unwrap() as i64)).cloned().unwrap_or_default();
                !ws.is_empty() && n(&ws) <= t + 5
            }
            b"" | b"shell" | b"program" | b"self" => {
                let w = self.ww_w0.get(&self.p.id[i]).cloned().unwrap_or_default();
                let ws = self.p.w_since.get(&(i as i64)).cloned().unwrap_or_default();
                let name = &self.p.name[i];
                in_turn(t, &w, n(&ws)) && *self.mail_a.get(&sh::path(&[x, b" ", name])).unwrap_or(&0) < t
            }
            _ => {
                let j = j.unwrap();
                let k = if self.p.id[j].is_empty() { sh::path(&[&self.p.host[j], b":", &self.p.rid[j]]) } else { self.p.id[j].clone() };
                let w = self.ww_b0.get(&k).cloned().unwrap_or_default();
                w.is_empty() || n(&w) <= t + 15
            }
        }
    }

    /// ctx_cached FILE FUNC -> Some(CTX), FUNC FILE's answer, worked out again only when FILE
    /// changes; None: FILE has no stamp (CTX left as it was)
    fn ctx_cached(&mut self, f: &[u8], func: fn(&[u8]) -> Bytes) -> Option<Bytes> {
        let st = sh::fstamp(f);
        if st.is_empty() {
            return None;
        }
        if self.ctx_stamp.get(f) != Some(&st) {
            self.ctx_val.insert(f.to_vec(), sh::cmdsub(&func(f)));
            self.ctx_stamp.insert(f.to_vec(), st);
        }
        Some(self.ctx_val[f].clone())
    }

    /// codex_waits FILE PID: whether the codex PID is waiting on its agents
    fn codex_waits(&mut self, f: &[u8], pid: &[u8]) -> bool {
        let st = sh::fstamp(f);
        if st.is_empty() {
            return false;
        }
        if self.cxw_stamp.get(f) != Some(&st) {
            self.cxw_val.insert(f.to_vec(), codex_wait_at(f));
            self.cxw_stamp.insert(f.to_vec(), st);
        }
        let t = self.cxw_val[f].clone();
        if !m("^[0-9]+$", &t) {
            return false;
        }
        match self.proc_start(pid) {
            None => true,
            Some(ps) => n(&t) >= ps - 2,
        }
    }

    /// proc_start PID -> PSTART: when it started, in seconds since the epoch (worked out once)
    pub fn proc_start(&mut self, pid: &[u8]) -> Option<i64> {
        if let Some(s) = self.cx_start.get(pid) {
            return Some(*s);
        }
        let e = procs::etime(pid)?;
        let s = self.now() - e;
        self.cx_start.insert(pid.to_vec(), s);
        Some(s)
    }

    /// claude_transcript PID -> TRANSCRIPT, or nothing
    fn claude_transcript(&mut self, pid: &[u8]) -> Bytes {
        if let Some(t) = self.cl_tr_t.get(pid) {
            if sh::seconds() - t < 30 {
                let f = self.cl_tr.get(pid).cloned().unwrap_or_default();
                return if sh::is_file(&f) { f } else { Vec::new() };
            }
        }
        self.cl_tr.insert(pid.to_vec(), Vec::new());
        self.cl_tr_t.insert(pid.to_vec(), sh::seconds());
        let pp = sh::path(&[b"/proc/", pid]);
        if !sh::is_dir(&pp) {
            return Vec::new();
        }
        let mut dirs: Vec<Bytes> = Vec::new();
        for e in super::environ(pid).unwrap_or_default() {
            if let Some(v) = e.strip_prefix(b"CLAUDE_CONFIG_DIR=").filter(|v| v.starts_with(b"/")) {
                dirs.insert(0, v.to_vec());
            } else if let Some(v) = e.strip_prefix(b"HOME=").filter(|v| v.starts_with(b"/")) {
                dirs.push(sh::path(&[v, b"/.claude"]));
            }
        }
        dirs.push(sh::path(&[&self.home, b"/.claude"]));
        let ccd = sh::env("CLAUDE_CONFIG_DIR").unwrap_or_default();
        if !ccd.is_empty() {
            dirs.push(ccd);
        }
        // find /proc/PID/fd -maxdepth 1 -lname '*/claude-*' -printf '%l\n', in readdir's order
        let mut sid: Bytes = Vec::new();
        if let Ok(rd) = std::fs::read_dir(sh::os(&sh::path(&[&pp, b"/fd"]))) {
            'fds: for e in rd.flatten() {
                let Some(l) = sh::readlink(&e.path().into_os_string().into_encoded_bytes()) else { continue };
                let Some(i) = l.windows(8).position(|w| w == b"/claude-") else { continue };
                let _ = i;
                for line in l.split(|&c| c == b'\n') {
                    if let Some(mm) = re(UUID_RE).matches(line) {
                        sid = mm[1].clone();
                        break 'fds;
                    }
                }
            }
        }
        if !sid.is_empty() {
            for d in &dirs {
                for f in sh::glob_sub(&sh::path(&[d, b"/projects"]), &sh::path(&[&sid, b".jsonl"])) {
                    if sh::is_file(&f) {
                        self.cl_tr.insert(pid.to_vec(), f.clone());
                        return f;
                    }
                }
            }
            return Vec::new();
        }
        let cwd = sh::readlink(&sh::path(&[&pp, b"/cwd"])).unwrap_or_default();
        if cwd.is_empty() {
            return Vec::new();
        }
        // Another Claude Code in the same folder could own the newest transcript there.
        let others: Vec<Bytes> = self.t.args.keys().cloned().collect();
        for p in others {
            if p == pid {
                continue;
            }
            if super::gather::agent_kind(self.t.args_of(&p)) != b"claude" {
                continue;
            }
            let c = sh::readlink(&sh::path(&[b"/proc/", &p, b"/cwd"])).unwrap_or_default();
            if c == cwd {
                return Vec::new();
            }
        }
        let slug = only(&cwd, ALNUM, b"-");
        let mut f: Bytes = Vec::new();
        let mut cnt = 0;
        for d in &dirs {
            for p in sh::glob(&sh::path(&[d, b"/projects/", &slug]), b"", b".jsonl", false) {
                if !(sh::is_file(&p) && sh::newer(&p, &pp)) {
                    continue;
                }
                if f.is_empty() || sh::newer(&p, &f) {
                    f = p.clone();
                }
                cnt += 1;
            }
            if !f.is_empty() {
                break;
            }
        }
        if cnt == 1 {
            self.cl_tr.insert(pid.to_vec(), f.clone());
            return f;
        }
        Vec::new()
    }

    /// codex_meta FILE...: CX_META[FILE]=its session's folder TAB its start, from line 1
    fn codex_meta(&mut self, files: &[Bytes]) {
        let l: Vec<Bytes> = files.iter().filter(|f| !self.cx_meta.contains_key(*f)).cloned().collect();
        if l.is_empty() {
            return;
        }
        let mut mo: Vec<Bytes> = Vec::new();
        for f in &l {
            let first = sh::cmdsub(sh::head_n(&sh::head_c(f, 1 << 20), 1));
            // $(...) then printf '%s\n': one line in, unless it holds newlines of its own
            for line in first.split(|&c| c == b'\n') {
                if let Some(o) = jq::codex_meta(line) {
                    mo.extend(sh::mapfile(o.as_bytes()));
                }
            }
        }
        for (i, f) in l.iter().enumerate() {
            let v = mo.get(i).cloned().unwrap_or_default();
            if m("^(/.*|-)\t[0-9]+$", &v) {
                self.cx_meta.insert(f.clone(), v);
            }
        }
    }

    /// codex_rollout PID -> ROLLOUT, or nothing
    fn codex_rollout(&mut self, pid: &[u8]) -> Bytes {
        if let Some(t) = self.cx_ro_t.get(pid) {
            if sh::seconds() - t < 30 {
                let f = self.cx_ro.get(pid).cloned().unwrap_or_default();
                return if sh::is_file(&f) { f } else { Vec::new() };
            }
        }
        self.cx_ro.insert(pid.to_vec(), Vec::new());
        self.cx_ro_t.insert(pid.to_vec(), sh::seconds());
        let st = self.proc_start(pid);
        let cwd = procs::proc_cwd(pid);
        let Some(st) = st else { return Vec::new() };
        if cwd.is_empty() {
            return Vec::new();
        }
        let mut d: Bytes = Vec::new();
        if sh::readable(&sh::path(&[b"/proc/", pid, b"/environ"])) {
            for e in super::environ(pid).unwrap_or_default() {
                if let Some(v) = e.strip_prefix(b"CODEX_HOME=").filter(|v| v.starts_with(b"/")) {
                    d = v.to_vec();
                } else if let Some(v) = e.strip_prefix(b"HOME=").filter(|v| v.starts_with(b"/")) {
                    if d.is_empty() {
                        d = sh::path(&[v, b"/.codex"]);
                    }
                }
            }
        }
        if d.is_empty() {
            d = sh::env("CODEX_HOME").filter(|v| !v.is_empty()).unwrap_or_else(|| sh::path(&[&self.home, b"/.codex"]));
        }
        let sess = sh::path(&[&d, b"/sessions"]);
        if !sh::is_dir(&sess) {
            return Vec::new();
        }
        let a = sh::path(&[b" ", self.t.args_of(pid), b" "]);
        let resume = sh::contains(&a, b" resume ");
        let rid = re(" resume ([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}) ").matches(&a).map(|mm| mm[1].clone()).unwrap_or_default();
        // The other codex processes in the same folder (a wrapper's codex under it is the same one).
        let mut peers: Vec<(Bytes, i64)> = Vec::new();
        let all: Vec<Bytes> = self.t.args.keys().cloned().collect();
        for p in all {
            if p == pid || super::gather::agent_kind(self.t.args_of(&p)) != b"codex" {
                continue;
            }
            let par = self.t.par.get(&p).filter(|v| !v.is_empty()).cloned().unwrap_or_else(|| b"0".to_vec());
            if super::gather::agent_kind(self.t.args_of(&par)) == b"codex" {
                continue;
            }
            if procs::proc_cwd(&p) != cwd {
                continue;
            }
            if let Some(s) = self.proc_start(&p) {
                peers.push((p, s));
            }
        }
        let now = self.now();
        let mut files = Vec::new();
        find_files(&sess, b"rollout-", b".jsonl", Some((now - st) / 60 + 2), &mut files);
        if !files.is_empty() {
            self.codex_meta(&files);
        }
        let (mut best, mut bt): (Bytes, i64) = (Vec::new(), 0);
        let me = self.puid(pid);
        for f in &files {
            let meta = self.cx_meta.get(f).cloned().unwrap_or_default();
            let r = sh::read_ws(&meta, 2, b"\t");
            let (c, t) = (&r[0], &r[1]);
            if !(*c == cwd && m("^[0-9]+$", t)) {
                continue;
            }
            let t = n(t);
            let Some(mt) = sh::mtime(f) else { continue };
            if mt < st {
                continue;
            }
            if me != self.uid && !own_plain(f, &me) {
                continue;
            }
            let owner = self.cx_claim.get(f).cloned().unwrap_or_default();
            if !owner.is_empty() && owner != pid && !self.t.args_of(&owner).is_empty() {
                continue;
            }
            if t >= st - 2 {
                let mut os = st;
                for (_, ps) in &peers {
                    if *ps > os && *ps <= t + 2 {
                        os = *ps;
                    }
                }
                if os != st {
                    continue;
                }
                if !(peers.is_empty() || t - st <= 120) {
                    continue;
                }
            } else if !(resume && peers.is_empty()) {
                continue;
            }
            if mt > bt {
                best = f.clone();
                bt = mt;
            }
        }
        if best.is_empty() && !rid.is_empty() {
            let mut v = Vec::new();
            find_files(&sess, b"rollout-", &sh::path(&[b"-", &rid, b".jsonl"]), None, &mut v);
            best = v.into_iter().next().unwrap_or_default();
            if !best.is_empty() && me != self.uid && !own_plain(&best, &me) {
                best = Vec::new();
            }
        }
        if best.is_empty() {
            return Vec::new();
        }
        self.cx_claim.insert(best.clone(), pid.to_vec());
        self.cx_ro.insert(pid.to_vec(), best.clone());
        best
    }

    /// ctx_reported PANE AGENT_PID [SESSION] -> CTX, what that Claude Code last reported
    fn ctx_reported(&self, pane: &[u8], apid: &[u8], sid: &[u8]) -> Option<Bytes> {
        let f = sh::path(&[&self.astate, b"/ctx/", pane.strip_prefix(b"%").unwrap_or(pane)]);
        if !sh::is_file(&f) {
            return None;
        }
        let data = std::fs::read(sh::os(&f)).ok()?;
        // read -r ... <FILE: fails (|| return 0) on a first line with no newline
        let nl = data.iter().position(|&c| c == b'\n')?;
        let r = sh::read_ws(&data[..nl], 6, b" \t\n");
        let (id, s, pct, at, pid) = (&r[0], &r[1], &r[2], &r[3], &r[4]);
        if !(id == pane && pid == apid && m("^[0-9]{1,3}$", pct) && m("^[0-9]+$", at) && n(pct) <= 100) {
            return None;
        }
        if !(sid.is_empty() || s == sid) {
            return None;
        }
        let ttl = sh::env("REVIVE_CTX_TTL").filter(|v| !v.is_empty()).unwrap_or_else(|| b"600".to_vec());
        if self.now() - n(at) <= n(&ttl) {
            Some(pct.clone())
        } else {
            None
        }
    }

    /// claude_tfile PID SID -> TFILE: its session's transcript, or nothing
    fn claude_tfile(&mut self, pid: &[u8], sid: &[u8]) -> Bytes {
        let rec = self.claude_record(pid);
        if rec.is_empty() {
            return self.claude_transcript(pid);
        }
        if !m("^[A-Za-z0-9-]+$", sid) {
            return Vec::new();
        }
        for f in sh::glob_sub(&sh::path(&[&before_sessions(&rec), b"/projects"]), &sh::path(&[sid, b".jsonl"])) {
            if !sh::is_file(&f) {
                continue;
            }
            if self.cl_erec.get(pid) == Some(&rec) && !self.cl_trok.contains(&f) {
                let u = sh::owner(&rec).map(|o| o.to_string().into_bytes()).unwrap_or_default();
                if own_plain(&f, &u) {
                    self.cl_trok.insert(f.clone());
                } else {
                    continue;
                }
            }
            return f;
        }
        Vec::new()
    }

    /// ctx_left KIND AGENT_PID PANE PID... -> CTX; CX_FILE: a Codex's rollout
    fn ctx_left(&mut self, kind: &[u8], apid: &[u8], pane: &[u8], pids: &[Bytes]) -> Bytes {
        self.cx_file = Vec::new();
        if kind == b"claude" {
            let rec = self.claude_record(apid);
            let mut sid = Vec::new();
            if !rec.is_empty() && rec == self.cl_rec {
                sid = self.cl_sid.clone();
            } else if !rec.is_empty() {
                let d = std::fs::read(sh::os(&rec)).unwrap_or_default();
                sid = sh::cmdsub(jq::session_id(&d).join("\n").as_bytes());
            }
            if let Some(c) = self.ctx_reported(pane, apid, &sid) {
                return c;
            }
            let tf = self.claude_tfile(apid, &sid);
            if !tf.is_empty() {
                return self.ctx_cached(&tf, claude_ctx_file).unwrap_or_default();
            }
        } else if kind == b"codex" {
            for p in pids {
                for f in open_files(word_of(p)) {
                    if !(rollout_path(&f) && sh::is_file(&f)) {
                        continue;
                    }
                    self.codex_meta(std::slice::from_ref(&f));
                    if self.cx_meta.get(&f).is_some_and(|v| v.starts_with(b"-\t")) {
                        continue;
                    }
                    self.cx_file = f.clone();
                    return self.ctx_cached(&f, codex_ctx_file).unwrap_or_default();
                }
            }
            let ro = self.codex_rollout(apid);
            self.cx_file = ro.clone();
            if !ro.is_empty() {
                return self.ctx_cached(&ro, codex_ctx_file).unwrap_or_default();
            }
        }
        Vec::new()
    }

    /// lim_cached FILE FUNC -> LIMV
    fn lim_cached(&mut self, f: &[u8], func: fn(&[u8]) -> Bytes) -> Bytes {
        let st = sh::fstamp(f);
        if st.is_empty() {
            return Vec::new();
        }
        if self.lim_stamp.get(f) != Some(&st) {
            self.lim_val.insert(f.to_vec(), sh::cmdsub(&func(f)));
            self.lim_stamp.insert(f.to_vec(), st);
        }
        self.lim_val[f].clone()
    }

    /// lim_base FILE AT PLAN-NOW -> LBASE: its plan when the limit at AT was hit, as first seen
    fn lim_base(&mut self, f: &[u8], at: &[u8], plan: &[u8]) -> Bytes {
        let k = sh::basename(f);
        let k = k.strip_suffix(b".jsonl").unwrap_or(k).to_vec();
        if !m("^[A-Za-z0-9_.-]{1,120}$", &k) {
            return Vec::new();
        }
        let lf = sh::path(&[&self.rdir, b"/limit-", &k]);
        let pre = sh::path(&[at, b" "]);
        if let Some(v) = self.lim_base.get(&lf) {
            if v.starts_with(&pre) {
                let i = v.iter().position(|&c| c == b' ').unwrap();
                return v[i + 1..].to_vec();
            }
        }
        let (mut a, mut p) = (Vec::new(), Vec::new());
        if sh::is_file(&lf) {
            if let Some(l) = sh::read_line(&lf) {
                let r = sh::read_ws(&l, 3, b" \t\n");
                a = r[0].clone();
                p = r[1].clone();
            }
        }
        if a != at || p.is_empty() {
            if plan.is_empty() {
                return Vec::new();
            }
            p = plan.to_vec();
            self.cache_dir();
            let _ = std::fs::write(sh::os(&lf), sh::path(&[at, b" ", &p, b"\n"]));
            // find "$RDIR" -maxdepth 1 -name 'limit-*' -mtime +8 -delete
            let now = sh::time_s();
            for x in sh::glob(&self.rdir, b"limit-", b"", true) {
                if let Ok(md) = std::fs::symlink_metadata(sh::os(&x)) {
                    use std::os::unix::fs::MetadataExt;
                    if (now - md.mtime()) / 86400 > 8 {
                        let _ = std::fs::remove_file(sh::os(&x));
                    }
                }
            }
        }
        self.lim_base.insert(lf, sh::path(&[at, b" ", &p]));
        p
    }

    /// limit_look KIND AGENT_PID ROW -> LST: limit or ready (P_LIM, P_LWHY for ROW), or nothing
    fn limit_look(&mut self, kind: &[u8], apid: &[u8], i: i64) -> Bytes {
        let f;
        let limv;
        if kind == b"claude" {
            let rec = self.claude_record(apid);
            let sid = if !rec.is_empty() && rec == self.cl_rec { self.cl_sid.clone() } else { Vec::new() };
            f = self.claude_tfile(apid, &sid);
            limv = if f.is_empty() { Vec::new() } else { self.lim_cached(&f, claude_limit_file) };
        } else if kind == b"codex" {
            f = self.cx_file.clone();
            limv = if f.is_empty() { Vec::new() } else { self.lim_cached(&f, codex_limit_file) };
        } else {
            return Vec::new();
        }
        if f.is_empty() || limv.is_empty() {
            return Vec::new();
        }
        let r = sh::read_ws(&limv, 3, b" \t\n");
        let (at, rr, pl) = (r[0].clone(), r[1].clone(), r[2].clone());
        let (_, plan) = if kind == b"claude" { self.claude_acct(apid) } else { self.codex_acct(apid) };
        let mut base = pl.strip_prefix(b"-").unwrap_or(&pl).to_vec();
        if base.is_empty() {
            base = self.lim_base(&f, &at, &plan);
        }
        if rr != b"-" {
            self.p.lim.insert(i, rr.clone());
        }
        let now = self.now();
        let auth_ok = kind != b"codex" || {
            let a = sh::path(&[self.cx_cdir.get(apid).map(|v| v.as_slice()).unwrap_or(b""), b"/auth.json"]);
            sh::mtime(&a).unwrap_or(0) >= n(&at)
        };
        if !base.is_empty() && !plan.is_empty() && base != plan && auth_ok {
            self.p.lwhy.insert(i, b"plan".to_vec());
            b"ready".to_vec()
        } else if rr != b"-" && now >= n(&rr) {
            b"ready".to_vec()
        } else {
            b"limit".to_vec()
        }
    }

    /// screen_state PANE -> LSTATE
    fn screen_state(&self, id: &[u8]) -> &'static [u8] {
        lines_state(&sh::mapfile(&sh::tm(&[b"capture-pane", b"-p", b"-t", id]).out))
    }

    /// agents_look: P_STATE and P_CTX for the agent panes gather listed (A_AT), one tmux for
    /// all their screens and one jq for Claude Code's records
    pub fn agents_look(&mut self) {
        self.jq_st.clear();
        if self.a_at.is_empty() {
            return;
        }
        let r = || unsafe { libc::rand() } % 32768;
        let mark = format!("@@revive-{}{}{}@@", r(), r(), r()).into_bytes();
        let mut cmd: Vec<Bytes> = Vec::new();
        for &i in &self.a_at {
            for x in [&b"capture-pane"[..], b"-p", b"-t", super::at(&self.p.id, i), b";", b"display-message", b"-p", &mark, b";"] {
                cmd.push(x.to_vec());
            }
        }
        cmd.pop();
        let argv: Vec<&[u8]> = cmd.iter().map(|x| x.as_slice()).collect();
        let out = sh::mapfile(&sh::tm(&argv).out);
        let mut ast: Vec<&'static [u8]> = Vec::new();
        let (mut j, mut nn) = (0usize, 0usize);
        for (i, l) in out.iter().enumerate() {
            if j >= self.a_at.len() {
                break;
            }
            if *l != mark {
                continue;
            }
            ast.push(lines_state(&out[nn..i]));
            nn = i + 1;
            j += 1;
        }
        while j < self.a_at.len() {
            let id = super::at(&self.p.id, self.a_at[j]).to_vec();
            ast.push(self.screen_state(&id));
            j += 1;
        }
        // Claude Code's records, for the agents whose screen isn't asking.
        let mut recs = Vec::new();
        for j in 0..self.a_at.len() {
            if self.a_kind[j] == b"claude" && ast[j] != b"asking" {
                let pid = self.a_pid[j].clone();
                let r = self.claude_record(&pid);
                if !r.is_empty() {
                    recs.push(r);
                }
            }
        }
        if !recs.is_empty() {
            for l in jq::records_tsv(&recs, true) {
                let f = sh::read_ws(&l, 5, b"\t");
                if !f[0].is_empty() && !self.jq_st.contains_key(&f[0]) {
                    self.jq_st.insert(f[0].clone(), (f[1].clone(), f[2].clone(), f[3].clone(), f[4].clone()));
                }
            }
        }
        for j in 0..self.a_at.len() {
            let i = self.a_at[j];
            let iu = i as usize;
            let kind = self.a_kind[j].clone();
            let apid = self.a_pid[j].clone();
            let mut st: Bytes = ast[j].to_vec();
            self.cl_rec = Vec::new();
            let mut lk = Look::default();
            if kind == b"claude" && st != b"asking" {
                lk = self.claude_look(&apid);
                match lk.cst.as_slice() {
                    b"busy" => st = b"working".to_vec(),
                    b"" => {
                        self.a_load.insert(i, apid.clone());
                    }
                    _ => {
                        st = b"waiting".to_vec();
                        if lk.cbg {
                            st = b"agents".to_vec();
                        }
                    }
                }
                if st == b"waiting" && lk.csrv {
                    self.p.srv.insert(i, b"1".to_vec());
                }
            }
            let tree = self.a_tree[j].clone();
            let pane = super::at(&self.p.id, i).to_vec();
            let ctx = self.ctx_left(&kind, &apid, &pane, &tree);
            let mut lst: Bytes = Vec::new();
            if st == b"waiting" {
                lst = self.limit_look(&kind, &apid, i);
            }
            if lst.is_empty() && kind == b"codex" && st == b"waiting" && !self.cx_file.is_empty() {
                let cf = self.cx_file.clone();
                if self.codex_waits(&cf, &apid) {
                    st = b"working".to_vec();
                }
            }
            self.p.state[iu] = st.clone();
            self.p.ctx[iu] = ctx;
            if kind == b"claude" {
                self.p.acct[iu] = self.claude_acct(&apid).0;
            } else if kind == b"codex" {
                self.p.acct[iu] = self.codex_acct(&apid).0;
            }
            if st == b"waiting" && !lk.csu.is_empty() {
                self.p.w_since.insert(i, lk.csu.clone());
                let (tfrom, tat) = self.claude_turn_from(&apid, &lk.csu);
                self.p.w_from.insert(i, tfrom);
                if !lk.csa.is_empty() && !tat.is_empty() && n(&lk.csu) - n(&lk.csa) <= 60 && n(&tat) < n(&lk.csu) {
                    self.p.w_since.insert(i, tat);
                }
            } else if kind == b"codex" && st == b"waiting" && !self.cx_file.is_empty() {
                let w = sh::mtime(&self.cx_file).map(|x| x.to_string().into_bytes()).unwrap_or_default();
                self.p.w_since.insert(i, w);
            }
            if !lst.is_empty() {
                self.p.state[iu] = lst;
            }
        }
        self.jq_st.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::collect::gather::tests::bash_fn;
    use crate::compat::tests::bash;

    fn q_w() -> String {
        let src = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../scripts/panel.sh")).unwrap();
        src.lines().filter(|l| l.starts_with("Q_RE=") || l.starts_with("W_RE=") || l.starts_with("LIM_RE=") || l.starts_with("LIM_MON=")).collect::<Vec<_>>().join("\n")
    }

    #[test]
    fn constants_are_panel_sh_s() {
        let s = q_w();
        assert!(s.contains(&format!("Q_RE='{}'", Q_RE)));
        assert!(s.contains(&format!("W_RE='{}'", W_RE)));
        assert!(s.contains(&format!("LIM_RE='{}'", LIM_RE)));
    }

    #[test]
    fn lines_state_as_bash() {
        crate::compat::tests::setup();
        let f = format!("{}\n{}", q_w(), bash_fn("lines_state"));
        let cases: &[&str] = &[
            "history\n\n Do you want to proceed?\n ❯ 1. Yes\n   2. No\n\n Enter to select · Esc to cancel",
            "working...\n esc to interrupt",
            "❯ \n? for shortcuts",
            "> hello\nDo you want to",
            "❯    Submit\nDo you want to",
            "›\u{a0}type\nallow once",
            "plain shell $",
            "",
            "  \n\t\n",
            "Ready to submit your answers?\n1. Submit answers",
            "Enter select · Esc back",
            "Ctrl+C to interrupt",
        ];
        for c in cases {
            let theirs = bash(&format!("{}\nmapfile -t L <<<\"$1\"; lines_state L; printf %s \"$LSTATE\"", f), &[c.as_bytes()]);
            let ours = lines_state(&sh::here(c.as_bytes()));
            assert_eq!(ours, theirs.as_slice(), "{:?}", c);
        }
    }

    #[test]
    fn iso_epoch_as_bash() {
        let f = bash_fn("iso_epoch");
        for c in ["2026-11-15T03:01:54Z", "1970-01-01T00:00:00Z", "2000-02-29T23:59:59Z", "1999-12-31T12:00:00Z", "2026-11-15T03:01:54", "x", "0001-01-01T00:00:00Z"] {
            let theirs = bash(&format!("{}\niso_epoch \"$1\"; printf %s \"$ISO_S\"", f), &[c.as_bytes()]);
            assert_eq!(iso_epoch(c.as_bytes()).map(|x| x.to_string().into_bytes()).unwrap_or_default(), theirs, "{}", c);
        }
    }

    #[test]
    fn in_turn_as_bash() {
        let f = bash_fn("in_turn");
        for (t, w, s) in [(100, "", 100), (105, "", 100), (106, "", 100), (-500, "", 100), (-499, "", 100), (85, "100", 0), (84, "100", 0), (900, "100", 0)] {
            let theirs = bash(&format!("{}\nin_turn \"$1\" \"$2\" \"$3\" && printf 1; :", f), &[t.to_string().as_bytes(), w.as_bytes(), s.to_string().as_bytes()]);
            assert_eq!(in_turn(t, w.as_bytes(), s), theirs == b"1", "{} {} {}", t, w, s);
        }
    }

    /// wait_watch's W_REPLY over three looks, as bash's: an answer while it works keeps the wait
    /// open, its prompt closes it (answered or not), a later turn of the sender's doesn't, and
    /// a name with no pane here is as before
    #[test]
    fn wait_reply_as_bash() {
        let t0: i64 = 1_800_000_000;
        let iso = |t: i64| {
            let o = bash("date -u -d \"@$1\" +%Y-%m-%dT%H:%M:%SZ", &[t.to_string().as_bytes()]);
            String::from_utf8(o).unwrap().trim().to_string()
        };
        let d = std::env::temp_dir().join(format!("trp-reply-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        let mb = d.join("mailbox.md");
        let mut box_ = String::new();
        for (f, to, t) in [
            ("pa", "xa", t0), ("xa", "pa", t0 + 60), ("pb", "xb", t0), ("xb", "pb", t0 + 60), ("pc", "xc", t0),
            ("pd", "xd", t0), ("pe", "gone", t0), ("pf", "xf", t0), ("pg", "rb@far", t0), ("ph", "gone2", t0),
            ("gone2", "ph", t0 + 30),
        ] {
            box_.push_str(&format!("## [{} -> {} {}] #m\nx\n\n", f, to, iso(t)));
        }
        std::fs::write(&mb, box_).unwrap();
        let mbb = mb.as_os_str().as_encoded_bytes().to_vec();
        // Rows: name, host, rid, state and W_SINCE (-1 none) at each look: just after the
        // messages, a few seconds on, and ten minutes on. pa and pb took the answers they had in
        // turns of their own; pc had a later turn that sent nothing.
        let rows: [(&str, &str, &str, [&str; 3], [i64; 3]); 15] = [
            ("pa", "", "", ["waiting"; 3], [t0 + 1, t0 + 1, t0 + 70]),
            ("xa", "", "", ["waiting", "working", "working"], [t0 - 100, -1, -1]),
            ("pb", "", "", ["waiting"; 3], [t0 + 1, t0 + 1, t0 + 80]),
            ("xb", "", "", ["working", "working", "waiting"], [-1, -1, t0 + 70]),
            ("pc", "", "", ["waiting"; 3], [t0 + 1, t0 + 1, t0 + 600]),
            ("xc", "", "", ["working"; 3], [-1; 3]),
            ("pd", "", "", ["waiting"; 3], [t0 + 1; 3]),
            ("xd", "", "", ["working", "working", "waiting"], [-1, -1, t0 + 100]),
            ("pe", "", "", ["waiting"; 3], [t0 + 1; 3]),
            ("pf", "", "", ["waiting"; 3], [t0 + 1; 3]),
            ("xf", "", "", ["working", "waiting", "working"], [-1, t0 + 7, -1]),
            ("pg", "", "", ["waiting"; 3], [t0 + 1; 3]),
            ("rb", "far", "%9", ["working"; 3], [-1; 3]),
            ("ph", "", "", ["waiting"; 3], [t0 + 1, t0 + 1, t0 + 31]),
            ("xx", "", "", ["shell"; 3], [-1; 3]),
        ];
        let looks = [t0 + 3, t0 + 8, t0 + 700];
        // bash: both looks, W_REPLY's rows after each
        let mut sc = format!(
            "{}\n{}\n{}\n{}\n{}\n{}\nAMAIL=$1 HOST=here MAIL_STAMP=\ndeclare -A WW_ST=() WW_T0=() WW_W0=() WW_B0=() MAIL_T=() MAIL_S=() MAIL_A=()\n",
            "now_s() { NOW=$NOW_PIN; }",
            bash_fn("iso_epoch"),
            bash_fn("mail_times"),
            bash_fn("in_turn"),
            bash_fn("wait_watch"),
            bash_fn("reply_open")
        );
        for (l, at) in looks.iter().enumerate() {
            sc.push_str(&format!("NOW_PIN={} P_ID=() P_HOST=() P_RID=() P_NAME=() P_STATE=() W_SINCE=() W_FROM=() W_REPLY=()\n", at));
            for (i, r) in rows.iter().enumerate() {
                let id = if r.1.is_empty() { format!("%{}", i + 1) } else { String::new() };
                sc.push_str(&format!("P_ID+=('{}') P_HOST+=('{}') P_RID+=('{}') P_NAME+=('{}') P_STATE+=('{}')\n", id, r.1, r.2, r.0, r.3[l]));
                if r.4[l] >= 0 {
                    sc.push_str(&format!("W_SINCE[{}]={}\n", i, r.4[l]));
                }
            }
            sc.push_str("wait_watch; printf '%s ' \"${!W_REPLY[@]}\"; echo\n");
        }
        let theirs = String::from_utf8(bash(&sc, &[&mbb])).unwrap();
        let mut g = G { amail: mbb, host: b"here".to_vec(), ..Default::default() };
        let mut ours = String::new();
        for (l, at) in looks.iter().enumerate() {
            g.now_pin = Some(*at);
            g.p = Default::default();
            for (i, r) in rows.iter().enumerate() {
                let id = if r.1.is_empty() { format!("%{}", i + 1) } else { String::new() };
                g.p.id.push(id.into_bytes());
                g.p.host.push(r.1.as_bytes().to_vec());
                g.p.rid.push(r.2.as_bytes().to_vec());
                g.p.name.push(r.0.as_bytes().to_vec());
                g.p.state.push(r.3[l].as_bytes().to_vec());
                if r.4[l] >= 0 {
                    g.p.w_since.insert(i as i64, r.4[l].to_string().into_bytes());
                }
            }
            g.wait_watch();
            for k in g.p.w_reply.keys() {
                ours.push_str(&format!("{} ", k));
            }
            ours.push('\n');
        }
        std::fs::remove_dir_all(&d).ok();
        assert_eq!(ours, theirs);
        // The last look: pa (an answer, still working), pc (a later turn, it still works), pe
        // (no pane by that name, in its turn) and pg (a linked computer's, busy since the panel
        // first looked) wait; pb (answered, then its prompt), pd (its prompt, no answer), pf (it
        // left its prompt for work since), ph (no pane, answered) don't.
        assert_eq!(ours.lines().nth(2).unwrap(), "0 4 8 11 ");
    }

    #[test]
    fn mail_times_as_bash() {
        let d = std::env::temp_dir().join(format!("trp-mail-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        let mb = d.join("mailbox.md");
        std::fs::write(
            &mb,
            "## [amish-dev@here -> oa-work@here 2026-11-27T21:21:56Z] #h1.0001 (held: waiting for access)\nhi\n\n\
             ## [amish-dev -> oa-work 2026-11-27T21:22:04Z] #20261127212204-1\nhi\n\n\
             ## [amish-dev@here -> oa-work@here 2026-11-27T21:22:05Z] #h1.0001 (delivered)\nhi\n\n\
             ## [oa-work -> amish-dev 2026-11-27T21:20:00Z] #2\nold\n\n\
             ## [cx@far -> dr 2026-11-27T21:23:00Z] #h2.0001 (NOT DELIVERED: no)\nx\n\n\
             ## [tr@far -> pw 2026-11-27T21:24:00Z] #3\nx\n\n\
             ## [tmux-revive -> %10 2026-11-27T21:25:00Z] #4\nx\n\n\
             ## [%5 -> pw 2026-11-27T21:26:00Z] #5\nx\n\n\
             ## [pw -> tr@far 2026-11-27T21:27:00Z] #6\nx\n\n\
             ## [pw -> tr@far bad-time] #7\nx\n\n\
             ## [oa-work -> pw 2026-11-27T21:28:00Z] #8 (no reply)\n(no reply) oa-work finished\n",
        )
        .unwrap();
        let mbb = mb.as_os_str().as_encoded_bytes().to_vec();
        let f = format!("{}\n{}", bash_fn("iso_epoch"), bash_fn("mail_times"));
        let theirs = bash(
            &format!("{}\ndeclare -A MAIL_T MAIL_S MAIL_A; MAIL_STAMP=; AMAIL=$1 HOST=here; mail_times\nfor k in \"${{!MAIL_T[@]}}\"; do printf 't %s=%s\\n' \"$k\" \"${{MAIL_T[$k]}}\"; done\nfor k in \"${{!MAIL_S[@]}}\"; do printf 's %s=%s\\n' \"$k\" \"${{MAIL_S[$k]}}\"; done\nfor k in \"${{!MAIL_A[@]}}\"; do printf 'a %s=%s\\n' \"$k\" \"${{MAIL_A[$k]}}\"; done | sort", f),
            &[&mbb],
        );
        let mut theirs: Vec<String> = String::from_utf8(theirs).unwrap().lines().map(String::from).collect();
        theirs.sort();
        let mut g = G { amail: mbb, host: b"here".to_vec(), ..Default::default() };
        g.mail_times();
        let mut ours: Vec<String> = g.mail_t.iter().map(|(k, v)| format!("t {}={}", String::from_utf8_lossy(k), v)).collect();
        ours.extend(g.mail_s.iter().map(|(k, v)| format!("s {}={}", String::from_utf8_lossy(k), v)));
        ours.extend(g.mail_a.iter().map(|(k, v)| format!("a {}={}", String::from_utf8_lossy(k), v)));
        assert!(ours.iter().any(|l| l.starts_with("a oa-work pw=")) && !ours.iter().any(|l| l.starts_with("s oa-work pw=")), "{:?}", ours);
        ours.sort();
        std::fs::remove_dir_all(&d).ok();
        assert!(ours.iter().any(|l| l.starts_with("s amish-dev oa-work=")), "{:?}", ours);
        assert_eq!(ours, theirs);
    }

    #[test]
    fn lim_reset_as_bash() {
        crate::compat::tests::setup();
        let f = format!("{}\n{}\n{}\n{}\n{}\n{}", q_w(), bash_fn("iso_epoch"), bash_fn("tz_off"), bash_fn("local_epoch"), bash_fn("lim_reset"), "");
        let at = 1795000000i64; // 2026-11-18T08:26:40Z
        let cases: &[&str] = &[
            "You've hit your session limit · resets 10pm (Europe/Paris)",
            "resets Nov 25, 3pm",
            "resets Nov 25th, 2027 3:04pm (America/New_York)",
            "Claude AI usage limit reached|1795003600",
            "try again at 10:10 PM.",
            "try again at Nov 25th, 2026 3:04 PM",
            "resets 12am",
            "resets 12pm (Nowhere/Zone)",
            "resets 25:00",
            "nothing here",
            "RESETS JAN 2, 1AM",
            "resets 8:20am",
            "resets 8:27am",
        ];
        for c in cases {
            let theirs = bash(&format!("{}\nlim_reset {} \"$1\"; printf %s \"$LRESET\"", f, at), &[c.as_bytes()]);
            assert_eq!(lim_reset(at, c.as_bytes()).map(|x| x.to_string().into_bytes()).unwrap_or_default(), theirs, "{}", c);
        }
    }

    #[test]
    fn ctx_pct_as_bash() {
        let src = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../scripts/common.sh")).unwrap();
        let start = src.find("ctx_pct() {").unwrap();
        let body = &src[start..start + src[start..].find("\n}\n").unwrap() + 3];
        for (u, w) in [("50000", "200000"), ("250000", "200000"), ("0", "1"), ("1", "0"), ("x", "5"), ("123456", "1000000"), ("100", "")] {
            let theirs = bash(&format!("{}\nctx_pct \"$1\" \"$2\"", body), &[u.as_bytes(), w.as_bytes()]);
            assert_eq!(ctx_pct(u.as_bytes(), w.as_bytes()), theirs, "{} {}", u, w);
        }
    }

    #[test]
    fn rollout_and_snapshot_globs() {
        assert!(rollout_path(b"/h/.codex/sessions/2026/11/rollout-x.jsonl"));
        assert!(rollout_path(b"/sessions//rollout-.jsonl"));
        assert!(!rollout_path(b"/sessions/rollout-x.jsonl"));
        assert!(!rollout_path(b"/h/sessions/a/rollout-x.json"));
        assert!(snapshot_args(b"zsh -c source /h/.claude/shell-snapshots/snapshot-zsh-1.sh && x"));
        assert!(!snapshot_args(b"zsh -c /h/.claude/shell-snapshots/snapshot-zsh-1.sh source "));
    }
}
