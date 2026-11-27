//! The collectors: scripts/panel.sh's gather and everything it calls, ported (plan Phase 2), and
//! the --once that gathers for itself (`once`). Bash keeps its state in globals that live from
//! one gather to the next (the CPU ticks, the caches keyed by SECONDS or by a file's stamp, what
//! wait_watch saw); here they are the fields of `G`, one per bash name, so the second gather of
//! a --once finds what the first left, as bash's does.

pub mod agents;
pub mod gather;
pub mod git;
pub mod jq;
pub mod links;
pub mod mail;
pub mod once;
pub mod procs;
pub mod sh;

use sh::Bytes;
use std::collections::{BTreeMap, HashMap, HashSet};

/// The P_* arrays: one record per pane, by row. The dense ones grow together; P_SRV, P_LIM,
/// P_LWHY, W_SINCE, W_FROM and W_REPLY are sparse (set by row). P_LWHY: "plan" when its plan
/// changed since its limit, "login" on a names-only row whose link waits for its login.
/// W_REPLY: "1" when it waits on another session's answer to a message it sent.
#[derive(Default, Clone, Debug)]
pub struct Panes {
    pub id: Vec<Bytes>,
    pub loc: Vec<Bytes>,
    pub name: Vec<Bytes>,
    pub app: Vec<Bytes>,
    pub state: Vec<Bytes>,
    pub dir: Vec<Bytes>,
    pub git: Vec<Bytes>,
    pub cpu: Vec<Bytes>,
    pub mem: Vec<Bytes>,
    pub ctx: Vec<Bytes>,
    pub agent: Vec<Bytes>,
    pub ssh: Vec<Bytes>,
    pub host: Vec<Bytes>,
    pub rid: Vec<Bytes>,
    pub wp: Vec<Bytes>,
    pub user: Vec<Bytes>,
    pub inst: Vec<Bytes>,
    pub acct: Vec<Bytes>,
    pub srv: BTreeMap<i64, Bytes>,
    pub lim: BTreeMap<i64, Bytes>,
    pub lwhy: BTreeMap<i64, Bytes>,
    pub w_since: BTreeMap<i64, Bytes>,
    pub w_from: BTreeMap<i64, Bytes>,
    pub w_reply: BTreeMap<i64, Bytes>,
}

/// `${A[i]:-}` of a dense array
pub fn at(v: &[Bytes], i: i64) -> &[u8] {
    if i < 0 {
        return b"";
    }
    v.get(i as usize).map(|x| x.as_slice()).unwrap_or(b"")
}
/// `${A[i]:-}` of a sparse one
pub fn sat(m: &BTreeMap<i64, Bytes>, i: i64) -> &[u8] {
    m.get(&i).map(|x| x.as_slice()).unwrap_or(b"")
}

/// Every global the gather path keeps, by its bash name.
#[derive(Default)]
pub struct G {
    // The environment panel.sh starts with.
    pub once: bool,
    pub uid: Bytes,
    pub me: Bytes,
    pub home: Bytes,
    pub host: Bytes,
    pub clk: i64,
    pub version: Bytes,
    pub amail: Bytes,
    pub astate: Bytes,
    pub dir: Bytes,
    pub rdir: Bytes,
    pub asay: Bytes,
    pub now_pin: Option<i64>,
    pub bg_secs: i64,
    // gather's
    pub t: procs::Table,
    pub inpane: HashSet<Bytes>,
    pub ticks_prev: HashMap<Bytes, i64>,
    /// T_PREV, EPOCHREALTIME as microseconds
    pub t_prev: Option<i64>,
    pub gather_n: i64,
    pub p: Panes,
    pub p_groups: i64,
    pub a_at: Vec<i64>,
    pub a_kind: Vec<Bytes>,
    pub a_pid: Vec<Bytes>,
    pub a_tree: Vec<Vec<Bytes>>,
    pub a_load: BTreeMap<i64, Bytes>,
    pub x_ssh: Vec<Bytes>,
    pub x_where: Vec<Bytes>,
    pub git: HashMap<Bytes, Bytes>,
    pub git_t: HashMap<Bytes, i64>,
    pub unames: HashMap<Bytes, Bytes>,
    pub uhomes: HashMap<Bytes, Bytes>,
    pub uapps: HashMap<Bytes, Bytes>,
    // agents'
    pub cl_erec: HashMap<Bytes, Bytes>,
    pub cl_erec_t: HashMap<Bytes, i64>,
    pub cl_trok: HashSet<Bytes>,
    pub cl_cdir: HashMap<Bytes, Bytes>,
    pub cx_cdir: HashMap<Bytes, Bytes>,
    pub cl_acct: HashMap<Bytes, Bytes>,
    pub cl_astamp: HashMap<Bytes, Bytes>,
    pub cl_at: HashMap<Bytes, i64>,
    pub cl_plan: HashMap<Bytes, Bytes>,
    pub cl_pfile: HashMap<Bytes, Bytes>,
    pub listens: HashSet<Bytes>,
    pub listen_at: Option<i64>,
    pub jq_st: HashMap<Bytes, (Bytes, Bytes, Bytes, Bytes)>,
    pub cl_rec: Bytes,
    pub cl_sid: Bytes,
    pub tf_k: HashMap<Bytes, Bytes>,
    pub tf_v: HashMap<Bytes, Bytes>,
    pub tf_a: HashMap<Bytes, Bytes>,
    pub ww_st: HashMap<Bytes, Bytes>,
    pub ww_t0: HashMap<Bytes, Bytes>,
    pub ww_w0: HashMap<Bytes, Bytes>,
    pub mail_t: HashMap<Bytes, i64>,
    pub mail_s: HashMap<Bytes, i64>,
    pub mail_stamp: Bytes,
    pub ctx_stamp: HashMap<Bytes, Bytes>,
    pub ctx_val: HashMap<Bytes, Bytes>,
    pub cxw_stamp: HashMap<Bytes, Bytes>,
    pub cxw_val: HashMap<Bytes, Bytes>,
    pub cl_tr: HashMap<Bytes, Bytes>,
    pub cl_tr_t: HashMap<Bytes, i64>,
    pub cx_ro: HashMap<Bytes, Bytes>,
    pub cx_ro_t: HashMap<Bytes, i64>,
    pub cx_start: HashMap<Bytes, i64>,
    pub cx_meta: HashMap<Bytes, Bytes>,
    pub cx_claim: HashMap<Bytes, Bytes>,
    pub cx_file: Bytes,
    pub lim_stamp: HashMap<Bytes, Bytes>,
    pub lim_val: HashMap<Bytes, Bytes>,
    pub lim_base: HashMap<Bytes, Bytes>,
    // links'
    pub rver: BTreeMap<Bytes, Bytes>,
    pub rowner: BTreeMap<Bytes, Bytes>,
    /// LUP: each link's 1 (working) or 0, as remote_panes found it; links_saves reads it
    pub lup: BTreeMap<Bytes, Bytes>,
    pub peek_files: HashSet<Bytes>,
    /// RFETCH_T/RFETCH_PID and PFETCH_T/PFETCH_PID: when each host's rows (each pane's peek)
    /// were last asked for, and whether that ask is still going
    pub rgate: links::Gate,
    pub pgate: links::Gate,
    /// PEEK_EVERY: REFRESH, seconds between asks for a linked pane's screen
    pub peek_every: i64,
}

pub const SHELLS: &[u8] = b" sh bash zsh fish dash ksh tcsh csh nu ";
pub const VER_RE: &str = r"^[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}$";
pub const USER_RE: &str = r"^[A-Za-z_][A-Za-z0-9_.-]{0,31}$";
pub const HOST_RE: &str = r"^[A-Za-z0-9][A-Za-z0-9._-]*$";

/// `[[ $S == *" W "* ]]` for SHELLS
pub fn in_shells(w: &[u8]) -> bool {
    sh::contains(SHELLS, &sh::path(&[b" ", w, b" "]))
}

/// `${s#-}`
pub fn strip_dash(s: &[u8]) -> &[u8] {
    s.strip_prefix(b"-").unwrap_or(s)
}

/// `[[ $s =~ RE ]]`
pub fn m(re: &str, s: &[u8]) -> bool {
    crate::compat::re(re).is_match(s)
}

/// `$((S))`
pub fn n(s: &[u8]) -> i64 {
    crate::render::num(s)
}

/// /proc/PID/environ's entries, as `while IFS= read -r -d '' e` takes them (one with no NUL
/// after it is left out); None when it can't be read
pub fn environ(pid: &[u8]) -> Option<Vec<Bytes>> {
    let d = std::fs::read(sh::os(&sh::path(&[b"/proc/", pid, b"/environ"]))).ok()?;
    let mut v: Vec<Bytes> = d.split(|&c| c == 0).map(|x| x.to_vec()).collect();
    v.pop();
    Some(v)
}

impl G {
    /// panel.sh's start: what it works out before anything is gathered
    pub fn new(root: &[u8]) -> G {
        let mut g = G { once: true, ..Default::default() };
        g.uid = unsafe { libc::getuid() }.to_string().into_bytes();
        g.me = user_name(unsafe { libc::geteuid() }).unwrap_or_default();
        g.home = sh::env("HOME").unwrap_or_default();
        // AMAIL, ASTATE, DIR, RDIR
        let st = match sh::env("XDG_STATE_HOME").filter(|v| !v.is_empty()) {
            Some(x) => x,
            None => sh::path(&[&g.home, b"/.local/state"]),
        };
        g.amail = sh::env("AGENT_SAY_MAILBOX").filter(|v| !v.is_empty()).unwrap_or_else(|| sh::path(&[&st, b"/agent-say/mailbox.md"]));
        g.astate = dirname(&g.amail);
        g.dir = revive_dir(&g.home);
        g.rdir = sh::path(&[&g.astate, b"/panel"]);
        g.asay = sh::path(&[root, b"/bin/agent-say"]);
        // NOW_PIN
        let pin = sh::env("REVIVE_PANEL_NOW").unwrap_or_default();
        g.now_pin = if m("^[0-9]{1,12}$", &pin) { Some(n(&pin)) } else { None };
        g.clk = procs::clk();
        g.host = hostname();
        // VERSION=$(head -n 1 FILE | head -c 32), checked
        let vf = sh::env("REVIVE_VERSION_FILE").filter(|v| !v.is_empty()).unwrap_or_else(|| sh::path(&[root, b"/VERSION"]));
        let first = sh::head_n(&sh::head_c(&vf, 1 << 16), 1).to_vec();
        let v = sh::cmdsub(&first.into_iter().take(32).collect::<Vec<u8>>());
        g.version = if m(VER_RE, &v) { v } else { Vec::new() };
        let bg = sh::env("REVIVE_BG_SECS").filter(|v| !v.is_empty()).unwrap_or_else(|| b"20".to_vec());
        g.bg_secs = n(&bg);
        let rf = sh::env("REVIVE_PANEL_REFRESH").filter(|v| !v.is_empty()).unwrap_or_else(|| b"2".to_vec());
        g.peek_every = n(&rf);
        g
    }

    /// now_s -> NOW
    pub fn now(&self) -> i64 {
        self.now_pin.unwrap_or_else(sh::time_s)
    }

    /// young FILE: changed under a minute ago, as find -mmin -1 says (by NOW_PIN's clock when set)
    pub fn young(&self, f: &[u8]) -> bool {
        if self.now_pin.is_none() {
            // find FILE -mmin -1: changed under 60 s before find started (or since)
            let Some(md) = std::fs::metadata(sh::os(f)).ok() else { return false };
            use std::os::unix::fs::MetadataExt;
            let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos() as i128).unwrap_or(0);
            let mt = md.mtime() as i128 * 1_000_000_000 + md.mtime_nsec() as i128;
            return now - mt < 60_000_000_000;
        }
        match sh::mtime(f) {
            Some(mt) => self.now() - mt < 60,
            None => false,
        }
    }

    /// cache_dir: $RDIR, for this user only
    pub fn cache_dir(&self) {
        use std::os::unix::fs::PermissionsExt;
        if !sh::is_dir(&self.rdir) {
            let _ = std::fs::create_dir_all(sh::os(&self.rdir));
        }
        if let Ok(md) = std::fs::metadata(sh::os(&self.rdir)) {
            if md.permissions().mode() & 0o7777 != 0o700 {
                let _ = std::fs::set_permissions(sh::os(&self.rdir), std::fs::Permissions::from_mode(0o700));
            }
        }
    }
}

/// `$(dirname "$p")`
pub fn dirname(p: &[u8]) -> Bytes {
    let mut q = p.to_vec();
    while q.len() > 1 && q.ends_with(b"/") {
        q.pop();
    }
    match q.iter().rposition(|&c| c == b'/') {
        Some(0) => b"/".to_vec(),
        Some(i) => {
            let mut d = q[..i].to_vec();
            while d.len() > 1 && d.ends_with(b"/") {
                d.pop();
            }
            d
        }
        None => b".".to_vec(),
    }
}

/// HOST=$(hostname -s 2>/dev/null || uname -n)
pub fn hostname() -> Bytes {
    let mut u: libc::utsname = unsafe { std::mem::zeroed() };
    if unsafe { libc::uname(&mut u) } != 0 {
        return Vec::new();
    }
    let mut h = unsafe { std::ffi::CStr::from_ptr(u.nodename.as_ptr()) }.to_bytes().to_vec();
    if let Some(p) = h.iter().position(|&c| c == b'.') {
        h.truncate(p);
    }
    h
}

/// A uid's user name, as `id -un` gives it
pub fn user_name(uid: libc::uid_t) -> Option<Bytes> {
    let mut pw: libc::passwd = unsafe { std::mem::zeroed() };
    let mut buf = vec![0 as libc::c_char; 16384];
    let mut res: *mut libc::passwd = std::ptr::null_mut();
    let r = unsafe { libc::getpwuid_r(uid, &mut pw, buf.as_mut_ptr(), buf.len(), &mut res) };
    if r != 0 || res.is_null() {
        return None;
    }
    Some(unsafe { std::ffi::CStr::from_ptr(pw.pw_name) }.to_bytes().to_vec())
}

/// common.sh's revive_dir: REVIVE_DIR, else the tmux option @revive-dir, else the XDG data
/// folder's tmux-revive; ~ for HOME; made (snapshots, panes), and closed up as it does
pub fn revive_dir(home: &[u8]) -> Bytes {
    let mut d = sh::env("REVIVE_DIR").unwrap_or_default();
    if d.is_empty() {
        let xdg = sh::env("XDG_DATA_HOME").filter(|v| !v.is_empty()).unwrap_or_else(|| sh::path(&[home, b"/.local/share"]));
        d = sh::opt(b"@revive-dir", &sh::path(&[&xdg, b"/tmux-revive"]));
    }
    // ${d/#\~/$HOME}
    if d.first() == Some(&b'~') {
        d = sh::path(&[home, &d[1..]]);
    }
    let _ = std::fs::create_dir_all(sh::os(&sh::path(&[&d, b"/snapshots"])));
    let _ = std::fs::create_dir_all(sh::os(&sh::path(&[&d, b"/panes"])));
    {
        use std::os::unix::fs::PermissionsExt;
        if let Ok(md) = std::fs::metadata(sh::os(&d)) {
            if md.permissions().mode() & 0o7777 != 0o700 {
                // chmod 700 "$d" && chmod -R go-rwx "$d"
                if std::fs::set_permissions(sh::os(&d), std::fs::Permissions::from_mode(0o700)).is_ok() {
                    let _ = sh::run(&[b"chmod", b"-R", b"go-rwx", &d]);
                }
            }
        }
    }
    d
}
