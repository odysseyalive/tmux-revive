//! Linked computers: scripts/panel.sh's remote_run, rows_get, remote_fetch, peek_get,
//! peek_fetch, peek_drop, peek_look and remote_panes, ported line for line.
//!
//! The rules here are hard constraints (plan, "Rules carried over"), each with a test below:
//! - no ssh attempt while a link has `login` or `paused`: the first thing remote_run does,
//!   and every ask goes through remote_run;
//! - no retries anywhere: a failed ask leaves the stale rows (or HOST.peek-ID.fail) as bash
//!   does, and nothing asks again until the next look;
//! - one ask in flight per host, at most one every 10 s (rows), one every PEEK_EVERY (peeks):
//!   `Gate`. A --once asks "now" (once per gather, as bash's does), past the gates.
//!
//! The programs are bash's, with the same arguments: `timeout`, AGENT_SAY_SSH (else ssh) and
//! agent-say's _key-opts, _ride and _pin. Nothing here connects by itself.

use super::sh::{self, Bytes};
use super::{m, G, HOST_RE, VER_RE};
use crate::compat::{clean, re, substr};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

pub const REMOTE_ROWS_CMD: &[u8] = b"PATH=\"$HOME/.local/bin:$PATH\" tmux-revive panel --rows";
pub const REMOTE_PEEK_CMD: &[u8] = b"PATH=\"$HOME/.local/bin:$PATH\" tmux-revive panel --peek";
pub const REMOTE_KEYS_CMD: &[u8] = b"PATH=\"$HOME/.local/bin:$PATH\" tmux-revive panel --keys";
pub const REMOTE_PASTE_CMD: &[u8] = b"PATH=\"$HOME/.local/bin:$PATH\" tmux-revive panel --paste";
pub const REMOTE_UPDATE_CMD: &[u8] = b"PATH=\"$HOME/.local/bin:$PATH\" tmux-revive update </dev/null 2>&1";
pub const REMOTE_NAME_CMD: &[u8] = b"PATH=\"$HOME/.local/bin:$PATH\" agent-say name";

/// What remote_run needs, apart from the panel (a worker thread takes a copy)
#[derive(Clone, Default)]
pub struct LinkCfg {
    /// $ASTATE: the links' folders are $ASTATE/links/HOST
    pub astate: Bytes,
    /// $ASAY: agent-say
    pub asay: Bytes,
    /// ${AGENT_SAY_SSH:-ssh}, as words
    pub ssh: Vec<Bytes>,
    /// ${RTIMEOUT:-8}
    pub rtimeout: Bytes,
}

impl LinkCfg {
    pub fn from_env(astate: &[u8], asay: &[u8]) -> LinkCfg {
        let s = sh::env("AGENT_SAY_SSH").filter(|v| !v.is_empty()).unwrap_or_else(|| b"ssh".to_vec());
        LinkCfg {
            astate: astate.to_vec(),
            asay: asay.to_vec(),
            ssh: s.split(|c| *c == b' ' || *c == b'\t' || *c == b'\n').filter(|w| !w.is_empty()).map(|w| w.to_vec()).collect(),
            rtimeout: sh::env("RTIMEOUT").filter(|v| !v.is_empty()).unwrap_or_else(|| b"8".to_vec()),
        }
    }
}

/// remote_run HOST REQUEST...: ask that computer over the link's own connection; its output,
/// cut at CAP bytes as `| head -c CAP` cuts it. -> (status, output); 255 nothing tried.
pub fn remote_run(c: &LinkCfg, h: &[u8], req: &[&[u8]], cap: usize) -> (i32, Bytes) {
    let l = sh::path(&[&c.astate, b"/links/", h]);
    // While the link waits for its login, or is stopped on a failure: nothing is tried.
    if sh::is_file(&sh::path(&[&l, b"/login"])) || sh::is_file(&sh::path(&[&l, b"/paused"])) {
        return (255, Vec::new());
    }
    let asay = |what: &[u8]| -> Vec<Bytes> { sh::mapfile(&sh::run(&[b"timeout", b"20", &c.asay, what, h]).out) };
    let ssh_run = |mid: &[&[u8]], c2: &[u8]| -> (i32, Bytes) {
        let mut argv: Vec<&[u8]> = vec![b"timeout", &c.rtimeout];
        argv.extend(c.ssh.iter().map(|x| x.as_slice()));
        argv.extend_from_slice(mid);
        argv.push(h);
        argv.push(c2);
        sh::run_capped(&argv, cap)
    };
    if sh::is_file(&sh::path(&[&l, b"/linkkey"])) {
        let pin = asay(b"_key-opts");
        if pin.is_empty() {
            return (255, Vec::new());
        }
        let mut mid: Vec<&[u8]> = vec![b"-o", b"ConnectTimeout=5"];
        mid.extend(pin.iter().map(|x| x.as_slice()));
        return ssh_run(&mid, &sh::path(&[b"_link ", &req.join(&b' ')]));
    }
    let q = |s: &[u8]| sh::path(&[b"'", s, b"'"]);
    let arg = |i: usize| req.get(i).copied().unwrap_or(b"");
    let cmd: Bytes = match arg(0) {
        b"rows" => REMOTE_ROWS_CMD.to_vec(),
        b"peek" => sh::path(&[REMOTE_PEEK_CMD, b" ", &q(arg(1)), b" ", arg(2)]),
        b"keys" => sh::path(&[REMOTE_KEYS_CMD, b" ", &q(arg(1)), b" ", &req.get(2..).unwrap_or(&[]).join(&b' ')]),
        b"paste" => sh::path(&[REMOTE_PASTE_CMD, b" ", &q(arg(1)), b" ", arg(2)]),
        b"update" => REMOTE_UPDATE_CMD.to_vec(),
        b"name" => sh::path(&[b"AGENT_SAY_PANE=", &q(arg(1)), b" ", REMOTE_NAME_CMD, b" ", &q(arg(2)), b" </dev/null 2>&1"]),
        _ => return (2, Vec::new()),
    };
    let fp = sh::path(&[&l, b"/fingerprint"]);
    if sh::nonempty(&fp) {
        let pin = asay(b"_ride");
        if !pin.is_empty() {
            let mid: Vec<&[u8]> = pin.iter().map(|x| x.as_slice()).collect();
            return ssh_run(&mid, &cmd);
        }
    }
    let mut pin: Vec<Bytes> = Vec::new();
    if sh::nonempty(&fp) {
        let o = sh::run(&[b"timeout", b"20", &c.asay, b"_pin", h]);
        let p = sh::cmdsub(&o.out);
        if !(o.ok && sh::nonempty(&p)) {
            return (255, Vec::new());
        }
        for x in [&b"-o"[..], b"StrictHostKeyChecking=yes", b"-o"] {
            pin.push(x.to_vec());
        }
        pin.push(sh::path(&[b"UserKnownHostsFile=", &p]));
        for x in [&b"-o"[..], b"GlobalKnownHostsFile=/dev/null", b"-o", b"HostKeyAlias=agent-say-confirmed", b"-o", b"CheckHostIP=no", b"-o", b"UpdateHostKeys=no"] {
            pin.push(x.to_vec());
        }
    }
    let cp = sh::path(&[b"ControlPath=", &c.astate, b"/ssh-%C"]);
    let mut mid: Vec<&[u8]> = vec![b"-o", b"BatchMode=yes", b"-o", b"ConnectTimeout=5", b"-o", b"ControlMaster=auto", b"-o", &cp, b"-o", b"ControlPersist=120"];
    mid.extend(pin.iter().map(|x| x.as_slice()));
    ssh_run(&mid, &cmd)
}

/// `mktemp "$F.XXXXXX"`: a new file of this user's alone next to F
fn mktemp(f: &[u8]) -> Option<Bytes> {
    use std::os::unix::fs::OpenOptionsExt;
    const AL: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    for _ in 0..100 {
        let mut s = sh::path(&[f, b"."]);
        for _ in 0..6 {
            s.push(AL[(unsafe { libc::rand() } as usize) % AL.len()]);
        }
        match std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(sh::os(&s)) {
            Ok(_) => return Some(s),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(_) => return None,
        }
    }
    None
}

/// rows_get HOST FILE: the rows into FILE, through a temporary file of its own, capped. A failed
/// ask leaves FILE as it was (stale rows), and isn't tried again here.
pub fn rows_get(c: &LinkCfg, h: &[u8], f: &[u8]) {
    let Some(t) = mktemp(f) else { return };
    let (st, out) = remote_run(c, h, &[b"rows"], 262144);
    let _ = std::fs::write(sh::os(&t), &out);
    if st == 0 || st == 141 {
        let _ = std::fs::rename(sh::os(&t), sh::os(f));
    } else {
        let _ = std::fs::remove_file(sh::os(&t));
    }
}

/// peek_get HOST %ID LINES FILE: that pane's screen into FILE, or FILE.fail when the ask failed
pub fn peek_get(c: &LinkCfg, h: &[u8], id: &[u8], n: &[u8], f: &[u8]) -> bool {
    peek_get_or_drop(c, h, id, n, f, None)
}

/// peek_get, told to stop (DROPPED set by peek_drop) while it asks: bash's fetch, killed, still
/// finishes asking (its TERM trap waits for that), then throws the screen away (`rm -f
/// "$PEEK_TMP"`) instead of putting it in place
fn peek_get_or_drop(c: &LinkCfg, h: &[u8], id: &[u8], n: &[u8], f: &[u8], dropped: Option<&AtomicBool>) -> bool {
    if !(m("^%[0-9]+$", id) && m("^[0-9]{1,2}$", n)) {
        return false;
    }
    let Some(t) = mktemp(f) else { return false };
    let (st, out) = remote_run(c, h, &[b"peek", id, n], 65536);
    if dropped.is_some_and(|d| d.load(Ordering::SeqCst)) {
        let _ = std::fs::remove_file(sh::os(&t));
        return true;
    }
    let _ = std::fs::write(sh::os(&t), &out);
    let fail = sh::path(&[f, b".fail"]);
    if st == 0 || st == 141 {
        let _ = std::fs::rename(sh::os(&t), sh::os(f));
        let _ = std::fs::remove_file(sh::os(&fail));
    } else {
        let _ = std::fs::remove_file(sh::os(&t));
        let _ = std::fs::remove_file(sh::os(f));
        let _ = std::fs::write(sh::os(&fail), b"");
    }
    true
}

/// When an ask may start, per key (a host, or "HOST %ID" for a peek): none while one is in
/// flight (bash's `kill -0 $PID`), and none within EVERY seconds of the last (FETCH_T)
#[derive(Default)]
pub struct Gate {
    t: HashMap<Bytes, i64>,
    busy: HashMap<Bytes, Arc<AtomicBool>>,
    /// each ask's "let go" flag (peek_drop), for it to throw its answer away
    dropped: HashMap<Bytes, Arc<AtomicBool>>,
}

impl Gate {
    /// -> the flag to hold while the ask runs, when one may start at SECS
    pub fn start(&mut self, k: &[u8], secs: i64, every: i64) -> Option<Arc<AtomicBool>> {
        if self.busy.get(k).is_some_and(|b| b.load(Ordering::SeqCst)) {
            return None;
        }
        if self.t.get(k).is_some_and(|t| secs - t < every) {
            return None;
        }
        self.t.insert(k.to_vec(), secs);
        let b = Arc::new(AtomicBool::new(true));
        self.busy.insert(k.to_vec(), b.clone());
        self.dropped.insert(k.to_vec(), Arc::new(AtomicBool::new(false)));
        Some(b)
    }
    /// `[[ -n ${PFETCH_PID[$k]:-} ]] && kill -0 "${PFETCH_PID[$k]}"`: an ask for K in flight
    pub fn busy(&self, k: &[u8]) -> bool {
        self.busy.get(k).is_some_and(|b| b.load(Ordering::SeqCst))
    }
    /// The flag the ask for K last started watches: set, it throws its answer away
    fn dropped(&self, k: &[u8]) -> Arc<AtomicBool> {
        self.dropped.get(k).cloned().unwrap_or_default()
    }
    /// RFETCH_T[$h]=0 (every key with None): the next ask may start at once, though not
    /// while one is still running
    pub fn again(&mut self, k: Option<&[u8]>) {
        match k {
            Some(k) => {
                self.t.remove(k);
            }
            None => self.t.clear(),
        }
    }
    /// peek_drop: the ask in flight is let go (its answer thrown away), the next may start at once
    pub fn drop_key(&mut self, k: &[u8]) {
        if let Some(d) = self.dropped.remove(k) {
            d.store(true, Ordering::SeqCst);
        }
        self.busy.remove(k);
        self.t.remove(k);
    }
}

/// A worker for one ask; its flag goes down when it's done
fn spawn(flag: Arc<AtomicBool>, f: impl FnOnce() + Send + 'static) {
    std::thread::spawn(move || {
        f();
        flag.store(false, Ordering::SeqCst);
    });
}

impl G {
    pub fn link_cfg(&self) -> LinkCfg {
        LinkCfg::from_env(&self.astate, &self.asay)
    }

    /// remote_fetch HOST [now]
    pub fn remote_fetch(&mut self, h: &[u8], now: bool) {
        let f = sh::path(&[&self.rdir, b"/", h, b".rows"]);
        self.cache_dir();
        let c = self.link_cfg();
        if now {
            rows_get(&c, h, &f);
            return;
        }
        let Some(flag) = self.rgate.start(h, sh::seconds(), 10) else { return };
        let h = h.to_vec();
        spawn(flag, move || rows_get(&c, &h, &f));
    }

    /// peek_fetch HOST %ID LINES FILE [now]
    pub fn peek_fetch(&mut self, h: &[u8], id: &[u8], n: i64, f: &[u8], now: bool) {
        self.cache_dir();
        self.peek_files.insert(f.to_vec());
        let c = self.link_cfg();
        let ns = n.to_string().into_bytes();
        if now {
            peek_get(&c, h, id, &ns, f);
            return;
        }
        let k = sh::path(&[h, b" ", id]);
        let Some(flag) = self.pgate.start(&k, sh::seconds(), self.peek_every) else { return };
        let dropped = self.pgate.dropped(&k);
        let (h, id, f) = (h.to_vec(), id.to_vec(), f.to_vec());
        spawn(flag, move || {
            peek_get_or_drop(&c, &h, &id, &ns, &f, Some(&dropped));
        });
    }

    /// peek_drop HOST %ID: a key was just sent there, so the screen being asked for now (asked
    /// before the key landed) is out of date. It's let go of (its answer thrown away) and the
    /// next look asks again at once.
    pub fn peek_drop(&mut self, h: &[u8], id: &[u8]) {
        self.pgate.drop_key(&sh::path(&[h, b" ", id]));
    }

    /// peek_look HOST %ID LINES -> RPEEK_AT (new, fail or nothing), RPEEK
    pub fn peek_look(&mut self, h: &[u8], id: &[u8], n: i64) -> (Bytes, Vec<Bytes>) {
        let f = sh::path(&[&self.rdir, b"/", h, b".peek-", id.strip_prefix(b"%").unwrap_or(id)]);
        let once = self.once;
        self.peek_fetch(h, id, n, &f, once);
        if sh::is_file(&f) && self.young(&f) {
            // tail -n N FILE, `IFS= read -r l || [[ -n $l ]]`: a last line with no newline too
            let d = std::fs::read(sh::os(&f)).unwrap_or_default();
            let t = sh::tail_n(&d, n.max(0) as usize);
            let v = sh::mapfile(t).into_iter().map(|l| l.into_iter().filter(|&c| c != 0).collect()).collect();
            (b"new".to_vec(), v)
        } else if sh::exists(&sh::path(&[&f, b".fail"])) {
            (b"fail".to_vec(), Vec::new())
        } else {
            (Vec::new(), Vec::new())
        }
    }

    /// remote_panes: each linked computer's rows (or its names alone), after this computer's
    pub fn remote_panes(&mut self) {
        self.p_groups = 0;
        // Other computers' screens are kept no longer than they're shown: a minute at most.
        if sh::is_dir(&self.rdir) {
            let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos() as i128).unwrap_or(0);
            if let Ok(rd) = std::fs::read_dir(sh::os(&self.rdir)) {
                for e in rd.flatten() {
                    let nm = e.file_name().into_encoded_bytes();
                    let rows_tmp = nm.len() >= 12 && sh::contains(&nm[..nm.len() - 6], b".rows.") && nm[..nm.len() - 6].ends_with(b".rows.");
                    if !(sh::contains(&nm, b".peek-") || sh::contains(&nm, b".answered-") || rows_tmp) {
                        continue;
                    }
                    use std::os::unix::fs::MetadataExt;
                    let Ok(md) = e.metadata() else { continue };
                    if md.is_dir() {
                        continue;
                    }
                    let mt = md.mtime() as i128 * 1_000_000_000 + md.mtime_nsec() as i128;
                    if now - mt > 60_000_000_000 {
                        let _ = std::fs::remove_file(e.path());
                    }
                }
            }
        }
        for d in crate::compat::glob_dirs(&sh::path(&[&self.astate, b"/links"])) {
            if !sh::is_file(&sh::path(&[&d, b"on"])) {
                continue;
            }
            let h = sh::basename_dir(&d);
            if !m(HOST_RE, &h) {
                continue;
            }
            // A link waiting for its login shows its names, marked so, and isn't asked.
            let lg = sh::is_file(&sh::path(&[&d, b"login"]));
            if !lg {
                let once = self.once;
                self.remote_fetch(&h, once);
            }
            let f = sh::path(&[&self.rdir, b"/", &h, b".rows"]);
            let mut got = false;
            self.rver.insert(h.clone(), Vec::new());
            self.rowner.insert(h.clone(), Vec::new());
            if !lg && sh::nonempty(&f) && self.young(&f) {
                got = self.read_rows(&h, &f);
            }
            if !got {
                // Names only, from the link.
                let mut st: &[u8] = b"linked";
                if !(sh::nonempty(&f) || !sh::nonempty(&sh::path(&[&d, b"error"]))) {
                    st = b"unreachable";
                }
                if lg {
                    st = b"login";
                }
                let raw = sh::head_c(&sh::path(&[&d, b"names"]), 65536);
                let lines = sh::lines(sh::head_n(&raw, 200));
                for name in lines {
                    if !m("^[A-Za-z0-9][A-Za-z0-9_.:+=-]*$", &name) {
                        continue;
                    }
                    let p = &mut self.p;
                    p.id.push(sh::path(&[&name, b"@", &h]));
                    p.loc.push(Vec::new());
                    p.name.push(name);
                    p.app.push(Vec::new());
                    p.state.push(st.to_vec());
                    p.dir.push(Vec::new());
                    p.git.push(Vec::new());
                    p.cpu.push(b"0".to_vec());
                    p.mem.push(b"0".to_vec());
                    p.ctx.push(Vec::new());
                    p.agent.push(b"0".to_vec());
                    p.ssh.push(Vec::new());
                    p.host.push(h.clone());
                    p.rid.push(Vec::new());
                    p.wp.push(Vec::new());
                    p.user.push(Vec::new());
                    p.inst.push(Vec::new());
                    p.acct.push(Vec::new());
                    got = true;
                }
            }
            if got {
                self.p_groups += 1;
            }
        }
        // A heading for this computer too, once there's more than one.
        if self.p_groups != 0 {
            self.p_groups += 1;
        }
    }

    /// remote_panes's loop over one computer's rows (HOST.rows, a minute old or newer). -> got
    fn read_rows(&mut self, h: &[u8], f: &[u8]) -> bool {
        let mut got = false;
        let (mut rctx, mut rbg, mut rsrv, mut ruser, mut rinst, mut rwait, mut racct, mut rlim): (
            HashMap<Bytes, Bytes>,
            HashMap<Bytes, Bytes>,
            HashMap<Bytes, Bytes>,
            HashMap<Bytes, Bytes>,
            HashMap<Bytes, Bytes>,
            HashMap<Bytes, Bytes>,
            HashMap<Bytes, Bytes>,
            HashMap<Bytes, Bytes>,
        ) = Default::default();
        let mut ft: Bytes = Vec::new();
        let raw = std::fs::read(sh::os(f)).unwrap_or_default();
        let sub = |s: &[u8], k: i64| substr(s, 0, Some(k)).unwrap_or_default();
        for line in sh::lines(sh::head_n(&raw, 200)) {
            // IFS=$'\x1f' read -r id loc name app st folder git cpu mem agent
            let x = sh::read_delim(&line, 10, 0x1f);
            let (id, loc, name, app, st, folder, git, cpu, mem, agent) =
                (x[0].clone(), x[1].clone(), x[2].clone(), x[3].clone(), x[4].clone(), x[5].clone(), x[6].clone(), x[7].clone(), x[8].clone(), x[9].clone());
            let id40 = sub(&id, 40);
            if loc.is_empty() {
                if let Some(mm) = re("^#version (.*)$").matches(&id40) {
                    if m(VER_RE, &mm[1]) {
                        self.rver.insert(h.to_vec(), mm[1].clone());
                    }
                    continue;
                }
                if let Some(mm) = re("^#ctx (%[0-9]{1,9}) ([0-9]{1,3})$").matches(&id40) {
                    if super::n(&mm[2]) <= 100 {
                        rctx.insert(mm[1].clone(), mm[2].clone());
                    }
                    continue;
                }
                if let Some(mm) = re("^#agents (%[0-9]{1,9})$").matches(&id40) {
                    rbg.insert(mm[1].clone(), b"1".to_vec());
                    continue;
                }
                if let Some(mm) = re("^#serving (%[0-9]{1,9})$").matches(&id40) {
                    rsrv.insert(mm[1].clone(), b"1".to_vec());
                    continue;
                }
                if let Some(mm) = re("^#wait (%[0-9]{1,9}) ([0-9]{1,9}) ([au])$").matches(&id40) {
                    rwait.insert(mm[1].clone(), sh::path(&[&mm[2], b" ", &mm[3]]));
                    continue;
                }
                if let Some(mm) = re("^#limit (%[0-9]{1,9}) (-|[0-9]{1,9}) ([01])$").matches(&id40) {
                    rlim.insert(mm[1].clone(), sh::path(&[&mm[2], b" ", &mm[3]]));
                    continue;
                }
                if let Some(mm) = re("^#acct (%[0-9]{1,9}) ([A-Za-z0-9._+-]{1,12})$").matches(&id40) {
                    racct.insert(mm[1].clone(), clean(&mm[2]));
                    continue;
                }
                if let Some(mm) = re("^#owner ([A-Za-z_][A-Za-z0-9_.-]{0,31})$").matches(&id40) {
                    self.rowner.insert(h.to_vec(), mm[1].clone());
                    continue;
                }
                if let Some(mm) = re("^#user (%[0-9]{1,9}) ([A-Za-z_][A-Za-z0-9_.-]{0,31}) (owner|-|[0-9]{1,9}\\.[0-9]{1,9}\\.[0-9]{1,9})$").matches(&sub(&id, 80)) {
                    ruser.insert(mm[1].clone(), mm[2].clone());
                    rinst.insert(mm[1].clone(), mm[3].strip_prefix(b"-").unwrap_or(&mm[3]).to_vec());
                    continue;
                }
            }
            // Only a complete row from a pane: a %id first and the agent flag last.
            if !(m("^%[0-9]+$", &id) && m("^[01]$", &agent)) {
                continue;
            }
            let loc = clean(&sub(&loc, 64));
            let mut name = clean(&sub(&name, 64));
            let app = clean(&sub(&app, 64));
            let mut st = clean(&sub(&st, 16));
            let folder = clean(&sub(&folder, 256));
            let git = clean(&sub(&git, 128));
            if !m("^[A-Za-z0-9][A-Za-z0-9_.:+=-]*$", &name) {
                name = Vec::new();
            }
            if ![&b"asking"[..], b"working", b"waiting", b"agents", b"shell", b"program"].contains(&st.as_slice()) {
                st = b"program".to_vec();
            }
            if (st == b"waiting" || st == b"working") && rbg.get(&id).is_some_and(|v| !v.is_empty()) {
                st = b"agents".to_vec();
            }
            if st == b"asking" && sh::older(f, &sh::path(&[&self.rdir, b"/", h, b".answered-", id.strip_prefix(b"%").unwrap_or(&id)])) {
                st = b"waiting".to_vec(); // answered from here since
            }
            // Its seconds count from when the rows came (the file's time), not from now.
            let mut v: Bytes = Vec::new();
            if st == b"waiting" {
                if let Some(rl) = rlim.get(&id).filter(|x| !x.is_empty()) {
                    let sp = rl.iter().position(|&c| c == b' ').unwrap_or(rl.len());
                    let first = &rl[..sp];
                    let second = if sp < rl.len() { &rl[sp + 1..] } else { &rl[..] };
                    if ft.is_empty() {
                        ft = sh::mtime(f).map(|x| x.to_string().into_bytes()).unwrap_or_default();
                    }
                    let now = self.now();
                    v = if first == b"-" { Vec::new() } else { ((if ft.is_empty() { now } else { super::n(&ft) }) + super::n(first)).to_string().into_bytes() };
                    st = b"limit".to_vec();
                    if second == b"1" {
                        st = b"ready".to_vec();
                    }
                    if !v.is_empty() && now >= super::n(&v) {
                        st = b"ready".to_vec();
                    }
                }
            }
            let cpu = if m("^[0-9]{1,4}$", &cpu) { cpu } else { b"0".to_vec() };
            let mem = if m("^[0-9]{1,10}$", &mem) { mem } else { b"0".to_vec() };
            let agent = if agent == b"1" { agent } else { b"0".to_vec() };
            // Its window.pane there, from its whole place.
            let wp = match loc.iter().rposition(|&c| c == b':') {
                Some(i) => loc[i + 1..].to_vec(),
                None => loc.clone(),
            };
            let wp = if m("^[0-9]{1,4}\\.[0-9]{1,4}$", &wp) { wp } else { Vec::new() };
            let row = self.p.id.len() as i64;
            let p = &mut self.p;
            p.id.push(if name.is_empty() { Vec::new() } else { sh::path(&[&name, b"@", h]) });
            p.loc.push(sub(&loc, 20));
            p.name.push(name);
            p.app.push(sub(&app, 12));
            p.state.push(st.clone());
            p.dir.push(sub(&folder, 40));
            p.git.push(sub(&git, 30));
            p.cpu.push(cpu);
            p.mem.push(mem);
            p.ctx.push(rctx.get(&id).cloned().unwrap_or_default());
            p.agent.push(agent);
            p.ssh.push(Vec::new());
            p.host.push(h.to_vec());
            p.rid.push(id.clone());
            p.wp.push(wp);
            p.user.push(ruser.get(&id).cloned().unwrap_or_default());
            p.inst.push(rinst.get(&id).cloned().unwrap_or_default());
            p.acct.push(racct.get(&id).cloned().unwrap_or_default());
            if st == b"waiting" && rsrv.get(&id).is_some_and(|v| !v.is_empty()) {
                p.srv.insert(row, b"1".to_vec());
            }
            if st == b"limit" || st == b"ready" {
                p.lim.insert(row, v.clone());
            }
            // [[ $st == ready && ${rlim[$id]#* } == 1 ]]
            let second = |r: &[u8]| -> Bytes { match r.iter().position(|&c| c == b' ') { Some(i) => r[i + 1..].to_vec(), None => r.to_vec() } };
            if st == b"ready" && second(rlim.get(&id).map(|v| v.as_slice()).unwrap_or(b"")) == b"1" {
                p.lwhy.insert(row, b"plan".to_vec());
            }
            if st == b"waiting" {
                if let Some(w) = rwait.get(&id).filter(|x| !x.is_empty()) {
                    let sp = w.iter().position(|&c| c == b' ').unwrap_or(w.len());
                    let secs = super::n(&w[..sp]);
                    let who = if sp < w.len() { w[sp + 1..].to_vec() } else { w.clone() };
                    let now = self.now();
                    self.p.w_since.insert(row, (now - secs).to_string().into_bytes());
                    self.p.w_from.insert(row, who);
                }
            }
            got = true;
        }
        got
    }
}

#[cfg(test)]
mod tests {
    //! The hard constraints, each tried against a stand-in ssh that counts its runs (no real
    //! connection is ever made: AGENT_SAY_SSH is the stand-in, agent-say is `false`).
    use super::*;

    /// RFETCH_T[$h]=0: that host's rows may be asked for again at once (every host's with
    /// None), never while an ask for them still runs
    #[test]
    fn again_lets_the_next_ask_through_at_once() {
        let mut g = Gate::default();
        let a = g.start(b"a", 100, 10).unwrap();
        let _b = g.start(b"b", 100, 10).unwrap();
        a.store(false, Ordering::SeqCst);
        assert!(g.start(b"a", 101, 10).is_none(), "the gate holds for 10 s");
        g.again(Some(b"a"));
        assert!(g.start(b"a", 101, 10).is_some(), "again: at once");
        assert!(g.start(b"b", 101, 10).is_none(), "b's still running");
        g.again(None);
        assert!(g.start(b"b", 101, 10).is_none(), "not while it runs");
    }

    struct Tmp(std::path::PathBuf);
    impl Drop for Tmp {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    /// A link folder, a counting ssh stand-in (exit ST, after SLEEP seconds), and its config
    fn setup(name: &str, st: i32, sleep: &str) -> (Tmp, LinkCfg, Bytes) {
        use std::os::unix::fs::PermissionsExt;
        let d = std::env::temp_dir().join(format!("trp-links-{}-{}", name, std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(d.join("links/h.example")).unwrap();
        std::fs::write(d.join("links/h.example/on"), b"").unwrap();
        let count = d.join("count");
        let ssh = d.join("ssh");
        std::fs::write(&ssh, format!("#!/bin/sh\necho x >>'{}'\nsleep {}\necho '#version 1.2.0'\nexit {}\n", count.display(), sleep, st)).unwrap();
        std::fs::set_permissions(&ssh, std::fs::Permissions::from_mode(0o700)).unwrap();
        let c = LinkCfg {
            astate: d.as_os_str().as_encoded_bytes().to_vec(),
            asay: b"false".to_vec(),
            ssh: vec![ssh.as_os_str().as_encoded_bytes().to_vec()],
            rtimeout: b"8".to_vec(),
        };
        let cnt = count.as_os_str().as_encoded_bytes().to_vec();
        (Tmp(d), c, cnt)
    }
    fn runs(count: &[u8]) -> usize {
        std::fs::read(sh::os(count)).map(|d| d.iter().filter(|&&c| c == b'\n').count()).unwrap_or(0)
    }

    #[test]
    fn no_ssh_while_a_link_waits_for_its_login_or_is_paused() {
        for flag in ["login", "paused"] {
            let (t, c, count) = setup(flag, 0, "0");
            std::fs::write(t.0.join("links/h.example").join(flag), b"").unwrap();
            let rows = sh::path(&[&c.astate, b"/h.example.rows"]);
            assert_eq!(remote_run(&c, b"h.example", &[b"rows"], 100).0, 255);
            rows_get(&c, b"h.example", &rows);
            let pk = sh::path(&[&c.astate, b"/h.example.peek-1"]);
            peek_get(&c, b"h.example", b"%1", b"10", &pk);
            for req in [&[&b"keys"[..], b"%1", b"Enter"][..], &[b"paste", b"%1", b"6869"], &[b"update"], &[b"name", b"%1", b"x"]] {
                assert_eq!(remote_run(&c, b"h.example", req, 100).0, 255);
            }
            // With a link key, too
            std::fs::write(t.0.join("links/h.example/linkkey"), b"k").unwrap();
            assert_eq!(remote_run(&c, b"h.example", &[b"rows"], 100).0, 255);
            assert_eq!(runs(&count), 0, "{}: ssh ran", flag);
            assert!(!sh::exists(&rows), "{}: rows written", flag);
        }
    }

    #[test]
    fn no_retries_a_failed_ask_leaves_stale_rows_or_fail() {
        let (_t, c, count) = setup("fail", 255, "0");
        let rows = sh::path(&[&c.astate, b"/h.example.rows"]);
        std::fs::write(sh::os(&rows), b"stale\n").unwrap();
        rows_get(&c, b"h.example", &rows);
        assert_eq!(runs(&count), 1, "one ask, no retry");
        assert_eq!(std::fs::read(sh::os(&rows)).unwrap(), b"stale\n", "stale rows kept");
        let pk = sh::path(&[&c.astate, b"/h.example.peek-1"]);
        std::fs::write(sh::os(&pk), b"old screen").unwrap();
        peek_get(&c, b"h.example", b"%1", b"10", &pk);
        assert_eq!(runs(&count), 2, "one ask for the peek, no retry");
        assert!(!sh::exists(&pk) && sh::exists(&sh::path(&[&pk, b".fail"])), "peek: screen gone, .fail left");
        // No temporary files left behind either
        let left: Vec<_> = std::fs::read_dir(sh::os(&c.astate)).unwrap().flatten().map(|e| e.file_name()).collect();
        assert_eq!(left.iter().filter(|n| n.to_string_lossy().contains(".rows.") || (n.to_string_lossy().contains(".peek-1.") && !n.to_string_lossy().ends_with(".fail"))).count(), 0);
        // And a good answer replaces them
        let (_t2, c2, _) = setup("ok", 0, "0");
        let rows2 = sh::path(&[&c2.astate, b"/h.example.rows"]);
        rows_get(&c2, b"h.example", &rows2);
        assert_eq!(std::fs::read(sh::os(&rows2)).unwrap(), b"#version 1.2.0\n");
    }

    #[test]
    fn one_rows_ask_in_flight_per_host_at_most_one_every_10_s() {
        let mut g = Gate::default();
        let a = g.start(b"h", 100, 10).expect("the first starts");
        assert!(g.start(b"h", 100, 10).is_none(), "in flight");
        a.store(false, Ordering::SeqCst);
        assert!(g.start(b"h", 109, 10).is_none(), "9 s after");
        assert!(g.start(b"other", 109, 10).is_some(), "another host has its own");
        assert!(g.start(b"h", 110, 10).is_some(), "10 s after, the last done");
        // A slow one still in flight after 10 s: none starts beside it.
        let mut g = Gate::default();
        let _b = g.start(b"h", 0, 10).unwrap();
        assert!(g.start(b"h", 60, 10).is_none());
        // Through the panel: two looks a moment apart, one slow ask between them.
        let (t, c, count) = setup("gate", 0, "1");
        let mut gg = G { rdir: t.0.join("panel").as_os_str().as_encoded_bytes().to_vec(), astate: c.astate.clone(), asay: c.asay.clone(), ..Default::default() };
        std::env::set_var("AGENT_SAY_SSH", sh::os(&c.ssh[0]));
        gg.remote_fetch(b"h.example", false);
        gg.remote_fetch(b"h.example", false);
        std::thread::sleep(std::time::Duration::from_millis(1600));
        gg.remote_fetch(b"h.example", false);
        std::thread::sleep(std::time::Duration::from_millis(300));
        std::env::remove_var("AGENT_SAY_SSH");
        assert_eq!(runs(&count), 1);
    }

    #[test]
    fn peeks_at_most_one_per_peek_every() {
        let mut g = Gate::default();
        let every = 2;
        let a = g.start(b"h %1", 50, every).unwrap();
        a.store(false, Ordering::SeqCst);
        assert!(g.start(b"h %1", 51, every).is_none());
        assert!(g.start(b"h %2", 51, every).is_some(), "each pane its own");
        assert!(g.start(b"h %1", 52, every).is_some());
        // peek_drop lets the next go at once (a key was just sent)
        let d = g.dropped(b"h %1");
        assert!(g.busy(b"h %1"));
        g.drop_key(b"h %1");
        assert!(d.load(Ordering::SeqCst) && !g.busy(b"h %1"), "the ask let go of is told, and isn't in flight");
        assert!(g.start(b"h %1", 52, every).is_some());
        assert!(!g.dropped(b"h %1").load(Ordering::SeqCst), "the new ask has a flag of its own");
    }
}
