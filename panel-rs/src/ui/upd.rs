//! U: scripts/panel.sh's update jobs, ported literally (upd_add, upd_job, upd_running, upd_last,
//! upd_users, upd_start, upd_poll, upd_lines, upd_tick, upd_show) and user_note.
//!
//! tmux-revive updated everywhere it can be, all at once, in a box that shows each line as it
//! goes: this computer's (yours), and each linked computer's over its link. Each is tried once;
//! one that fails says so and is never tried again until you press U again (a server's fail2ban
//! counts every try). Another user's install, here or there, is theirs to update: nothing runs as
//! them. Its line has [I], and I shows the command to run in their pane.
//!
//! Each job is a child of its own, as bash's `( … ) &`: HUP ignored (a popup panel closed
//! mid-install mustn't cut the installer short), and INT and QUIT, as bash's background jobs
//! have them; its output to UPD_DIR/N.out, how it ended to N.st (through N.tmp and mv). A linked
//! computer's runs this binary again as `--remote-run HOST update` (links::remote_run, RTIMEOUT
//! 300), the same request bash's remote_run makes.

use super::{modal, Ui};
use crate::collect::sh::{self, Bytes};
use crate::collect::{m, HOST_RE, USER_RE, VER_RE};
use crate::compat::clean;
use crate::render::{cat, num, Ctx};
use std::process::{Child, Command, Stdio};

/// The job's own shell: bash's upd_job subshell, with its file names from $0
const JOB_SH: &str = r#"trap '' HUP; "$@" </dev/null >"$0.out" 2>&1; echo $? >"$0.tmp" && mv -f "$0.tmp" "$0.st""#;

/// UPD_N and its arrays; PITEMS, PKROWS and UPD_BAR as upd_lines leaves them
#[derive(Default)]
pub struct Upd {
    /// UPD_KIND: job (here, or HOST over ssh), skip (a link waiting for you: not tried), or note
    /// (an [I] line)
    pub kind: Vec<Bytes>,
    pub name: Vec<Bytes>,
    /// UPD_ARG: the host, or for a note "install|update USER [HOST]"
    pub arg: Vec<Bytes>,
    pub text: Vec<Bytes>,
    pub seen: Vec<bool>,
    /// UPD_PID: each job's child, reaped as upd_running looks (kill -0 would see a zombie)
    pid: Vec<Option<Child>>,
    pub pitems: Vec<Bytes>,
    pub pkrows: Bytes,
    pub bar: Bytes,
}

impl Upd {
    pub fn n(&self) -> usize {
        self.kind.len()
    }

    /// upd_add KIND NAME ARG [TEXT]
    pub fn add(&mut self, kind: &[u8], name: &[u8], arg: &[u8], text: &[u8]) {
        self.kind.push(kind.to_vec());
        self.name.push(name.to_vec());
        self.arg.push(arg.to_vec());
        self.text.push(text.to_vec());
        self.seen.push(false);
        self.pid.push(None);
    }

    /// upd_running: a job still going
    pub fn running(&mut self) -> bool {
        self.pid.iter_mut().flatten().any(|c| matches!(c.try_wait(), Ok(None)))
    }

    /// upd_lines -> PITEMS: the box's lines, each as wide as the others; PKROWS: those with [I];
    /// UPD_BAR: "FINISHED TOTAL" of the updates run, for the progress bar. false when none
    /// changed. ROWNER: a linked computer's owner, as its rows say.
    pub fn lines(&mut self, c: &Ctx, dir: &[u8], me: &[u8], rowner: &dyn Fn(&[u8]) -> Bytes) -> bool {
        let was = self.pitems.join(&b' ');
        let (mut fin, mut tot) = (0, 0);
        self.pitems.clear();
        self.pkrows = b" ".to_vec();
        for i in 0..self.n() {
            let mut s = self.text[i].clone();
            let mut mark = false;
            let h = self.arg[i].clone();
            match self.kind[i].as_slice() {
                b"note" => mark = true,
                b"job" => {
                    tot += 1;
                    let base = sh::path(&[dir, b"/", &crate::compat::itoa(i as i64)]);
                    let stf = sh::path(&[&base, b".st"]);
                    let outf = sh::path(&[&base, b".out"]);
                    if !sh::nonempty(&stf) {
                        s = "updating…".as_bytes().to_vec();
                    } else {
                        fin += 1;
                        let st = num(&read_r(&stf).1);
                        let last = upd_last(&outf);
                        let out = std::fs::read(sh::os(&outf)).unwrap_or_default();
                        // Its result, from the installer's "tmux-revive 1.2.19 -> 1.2.20" line (its
                        // last line is only the end of its help, cut to a stray letter here).
                        if st == 0 {
                            s = b"updated".to_vec();
                            if let Some((a, b)) = ver_arrow(&out) {
                                s = if a == b { cat(&[b"already ", &b]) } else { cat(&[&a, " → ".as_bytes(), &b]) };
                            }
                        } else if !h.is_empty() && (st == 124 || st == 255) {
                            s = b"unreachable".to_vec();
                        } else if denied(&out) {
                            // Not the link's user's to update: [I], with tmux-revive update for its
                            // owner's pane (UPD_TEXT holds what user_note is given, as UPD_ARG does
                            // for a note).
                            s = b"no permission".to_vec();
                            if h.is_empty() {
                                self.text[i] = cat(&[b"update ", me]);
                                mark = true;
                            } else {
                                let o = rowner(&h);
                                if !o.is_empty() {
                                    self.text[i] = cat(&[b"update ", &o, b" ", &h]);
                                    mark = true;
                                }
                            }
                        } else {
                            s = if last.is_empty() { b"failed".to_vec() } else { cat(&[b"failed: ", &last]) };
                        }
                    }
                }
                _ => {}
            }
            let mut l = cat(&[&c.fld(&self.name[i], 22), b"  ", &c.fld(&s, 36)]);
            if mark {
                l.extend_from_slice(b"  [I]");
                self.pkrows.extend(cat(&[&crate::compat::itoa(i as i64), b" "]));
            } else {
                l.extend_from_slice(b"     ");
            }
            self.pitems.push(l);
        }
        self.bar = cat(&[&crate::compat::itoa(fin), b" ", &crate::compat::itoa(tot)]);
        self.pitems.join(&b' ') != was
    }
}

/// `read -r v <FILE`: its first line, IFS whitespace trimmed; false when there is none whole
/// (no file, or no newline at its end), v still what it read
pub fn read_r(f: &[u8]) -> (bool, Bytes) {
    let Ok(d) = std::fs::read(sh::os(f)) else { return (false, Vec::new()) };
    let (l, ok) = match d.iter().position(|&c| c == b'\n') {
        Some(i) => (&d[..i], true),
        None => (&d[..], false),
    };
    let l: Bytes = l.iter().copied().filter(|&c| c != 0).collect();
    (ok, trim_ifs(&l))
}

/// `grep -qiE 'permission denied|operation not permitted'`
fn denied(t: &[u8]) -> bool {
    let l = t.to_ascii_lowercase();
    sh::contains(&l, b"permission denied") || sh::contains(&l, b"operation not permitted")
}

/// `grep -oE 'tmux-revive D.D.D -> D.D.D' FILE | tail -n 1`, then its two versions
fn ver_arrow(t: &[u8]) -> Option<(Bytes, Bytes)> {
    // [0-9]+\.[0-9]+\.[0-9]+ at I: its end
    fn ver(t: &[u8], mut i: usize) -> Option<usize> {
        for k in 0..3 {
            let s = i;
            while i < t.len() && t[i].is_ascii_digit() {
                i += 1;
            }
            if i == s {
                return None;
            }
            if k < 2 {
                if t.get(i) != Some(&b'.') {
                    return None;
                }
                i += 1;
            }
        }
        Some(i)
    }
    let mut last = None;
    for line in t.split(|&c| c == b'\n') {
        let mut i = 0;
        while i < line.len() {
            let found = (|| {
                let p = line[i..].strip_prefix(b"tmux-revive ".as_slice())?;
                let a0 = line.len() - p.len();
                let a1 = ver(line, a0)?;
                let b0 = a1 + line[a1..].strip_prefix(b" -> ".as_slice()).map(|_| 4)?;
                let b1 = ver(line, b0)?;
                Some((a0, a1, b0, b1))
            })();
            match found {
                Some((a0, a1, b0, b1)) => {
                    last = Some((line[a0..a1].to_vec(), line[b0..b1].to_vec()));
                    i = b1;
                }
                None => i += 1,
            }
        }
    }
    last
}

/// The sed of upd_last, on one line (LC_ALL=C: bytes): CSI sequences, OSC ones, then any other
/// ESC and the byte after it, each taken out everywhere
pub fn strip_esc(l: &[u8]) -> Bytes {
    // s#\e\[[0-9:;<=>?]*[ -/]*[@-~]##g
    let mut a = Vec::new();
    let mut i = 0;
    while i < l.len() {
        if l[i] == 0x1b && l.get(i + 1) == Some(&b'[') {
            let mut j = i + 2;
            while j < l.len() && (0x30..=0x3f).contains(&l[j]) {
                j += 1;
            }
            while j < l.len() && (0x20..=0x2f).contains(&l[j]) {
                j += 1;
            }
            if j < l.len() && (0x40..=0x7e).contains(&l[j]) {
                i = j + 1;
                continue;
            }
        }
        a.push(l[i]);
        i += 1;
    }
    // s#\e\][^\a\e]*(\a|\e\\)?##g
    let mut b = Vec::new();
    let mut i = 0;
    while i < a.len() {
        if a[i] == 0x1b && a.get(i + 1) == Some(&b']') {
            let mut j = i + 2;
            while j < a.len() && a[j] != 0x07 && a[j] != 0x1b {
                j += 1;
            }
            if j < a.len() && a[j] == 0x07 {
                j += 1;
            } else if j + 1 < a.len() && a[j] == 0x1b && a[j + 1] == b'\\' {
                j += 2;
            }
            i = j;
            continue;
        }
        b.push(a[i]);
        i += 1;
    }
    // s#\e.##g
    let mut c = Vec::new();
    let mut i = 0;
    while i < b.len() {
        if b[i] == 0x1b && i + 1 < b.len() {
            i += 2;
            continue;
        }
        c.push(b[i]);
        i += 1;
    }
    c
}

/// upd_last FILE -> LAST: its last line, as text: the installer's colour codes (and any other
/// escape sequence) go whole, not just their ESC, and so does its "xx" or "!!" in front.
pub fn upd_last(f: &[u8]) -> Bytes {
    let t = sh::tail_c(f, 4096);
    let mut last: Bytes = Vec::new();
    let body = t.strip_suffix(b"\n").unwrap_or(&t);
    if !t.is_empty() {
        for l in body.split(|&c| c == b'\n') {
            let s = strip_esc(l);
            // grep -v '^[[:space:]]*$'
            if !s.iter().all(|c| matches!(c, b' ' | b'\t' | b'\n' | 0x0b | 0x0c | b'\r')) {
                last = s;
            }
        }
    }
    let last = clean(&last);
    match crate::compat::re("^[[:space:]]*(xx|!!|==>)[[:space:]]+(.*)$").matches(&last) {
        Some(mm) => mm[2].clone(),
        None => last,
    }
}

impl Ui {
    /// UPD_DIR
    fn upd_dir(&self) -> Bytes {
        sh::path(&[&self.rdir, b"/update"])
    }

    /// upd_job N COMMAND...: in the background, its output to UPD_DIR/N.out, how it ended to N.st
    fn upd_job(&mut self, n: usize, argv: &[Bytes], envs: &[(&str, &[u8])]) {
        use std::os::unix::process::CommandExt;
        let f = sh::path(&[&self.upd_dir(), b"/", &crate::compat::itoa(n as i64)]);
        let mut c = Command::new("bash");
        c.arg("-c").arg(JOB_SH).arg(sh::os(&f));
        for a in argv {
            c.arg(sh::os(a));
        }
        for (k, v) in envs {
            c.env(k, sh::os(v));
        }
        c.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
        // HUP ignored, and INT and QUIT as bash's background jobs have them (no job control)
        unsafe {
            c.pre_exec(|| {
                for s in [libc::SIGHUP, libc::SIGINT, libc::SIGQUIT] {
                    libc::signal(s, libc::SIG_IGN);
                }
                Ok(())
            });
        }
        self.upd.pid[n] = c.spawn().ok();
    }

    /// upd_users HOST (this computer: ""): an [I] line for each other user there whose
    /// tmux-revive isn't current (none, or older than the owner's). A computer whose rows don't
    /// say whose its tmux is (from before users) has none. SEEN: upd_start's.
    fn upd_users(&mut self, h: &[u8], seen: &mut Bytes) {
        let (own, rf) = if h.is_empty() {
            (self.me.clone(), self.c.p.version.clone())
        } else {
            (self.c.p.assoc("ROWNER", h).to_vec(), self.c.p.assoc("RVER", h).to_vec())
        };
        if own.is_empty() {
            return;
        }
        let ids: Vec<i64> = self.c.p.snap.arrays.get("P_ID").map(|m| m.keys().copied().collect()).unwrap_or_default();
        for i in ids {
            if self.c.p.a("P_HOST", i) != h {
                continue;
            }
            let u = self.pa("P_USER", i);
            let v = self.pa("P_INST", i);
            let key = cat(&[b" ", &u, b"@", h, b" "]);
            if !(m(USER_RE, &u) && u != own && v != b"owner" && !sh::contains(seen, &key)) {
                continue;
            }
            seen.extend(cat(&[&u, b"@", h, b" "]));
            let who = if h.is_empty() { u.clone() } else { cat(&[&u, b"@", h]) };
            if v.is_empty() {
                self.upd.add(b"note", &who, &cat(&[b"install ", &u, b" ", h]), b"not installed");
            } else if m(VER_RE, &v) && m(VER_RE, &rf) && crate::render::panes::ver_lt(&v, &rf) {
                self.upd.add(b"note", &who, &cat(&[b"update ", &u, b" ", h]), &cat(&[b"has ", &v]));
            }
        }
    }

    /// upd_start: a new round, every job started at once
    fn upd_start(&mut self) {
        let mut seen: Bytes = b" ".to_vec();
        crate::collect::G { rdir: self.rdir.clone(), ..Default::default() }.cache_dir();
        let dir = self.upd_dir();
        let _ = std::fs::remove_dir_all(sh::os(&dir));
        let _ = std::fs::create_dir_all(sh::os(&dir));
        self.upd = Upd::default();
        self.upd.add(b"job", b"this computer", b"", b"");
        let tr = sh::path(&[&self.root, b"/bin/tmux-revive"]);
        self.upd_job(0, &[b"timeout".to_vec(), b"600".to_vec(), tr, b"update".to_vec()], &[]);
        self.upd_users(b"", &mut seen);
        // Each linked computer, once; one waiting for a login or stopped on a failure isn't tried
        // (remote_run wouldn't either): B is where you try it again.
        let me = std::env::current_exe().map(|p| p.into_os_string().into_encoded_bytes()).unwrap_or_default();
        for d in crate::compat::glob_dirs(&sh::path(&[&self.astate, b"/links"])) {
            let h = sh::basename_dir(&d);
            if !(sh::is_file(&sh::path(&[&d, b"/on"])) && m(HOST_RE, &h)) {
                continue;
            }
            if sh::is_file(&sh::path(&[&d, b"/login"])) {
                self.upd.add(b"skip", &h, b"", "skipped: needs login · B".as_bytes());
            } else if sh::is_file(&sh::path(&[&d, b"/paused"])) {
                self.upd.add(b"skip", &h, b"", "skipped: link stopped · B".as_bytes());
            } else {
                self.upd.add(b"job", &h, &h, b"");
                let n = self.upd.n() - 1;
                self.upd_job(n, &[me.clone(), b"--remote-run".to_vec(), h.clone(), b"update".to_vec()], &[("RTIMEOUT", b"300")]);
            }
            self.upd_users(&h, &mut seen);
        }
    }

    /// upd_poll: what finished since last looked at: this computer's tmux-revive read again, a
    /// linked computer asked for its rows (and so its version) again.
    pub(super) fn upd_poll(&mut self) {
        let dir = self.upd_dir();
        for i in 0..self.upd.n() {
            let stf = sh::path(&[&dir, b"/", &crate::compat::itoa(i as i64), b".st"]);
            if !(self.upd.kind[i] == b"job" && !self.upd.seen[i] && sh::nonempty(&stf)) {
                continue;
            }
            self.upd.seen[i] = true;
            if read_r(&stf).1 != b"0" {
                continue;
            }
            if self.upd.arg[i].is_empty() {
                let vf = sh::env("REVIVE_VERSION_FILE").filter(|v| !v.is_empty()).unwrap_or_else(|| sh::path(&[&self.root, b"/VERSION"]));
                let first = sh::head_n(&sh::head_c(&vf, 1 << 16), 1).to_vec();
                let v = sh::cmdsub(&first.into_iter().take(32).collect::<Vec<u8>>());
                let v = if m(VER_RE, &v) { v } else { Vec::new() };
                self.c.p.version = v.clone();
                *self.hub.version.lock().unwrap() = Some(v);
            } else {
                self.hub.rows_again(Some(self.upd.arg[i].clone()));
            }
        }
    }

    /// upd_lines, with this panel's UPD_DIR, ME and ROWNER
    fn upd_lines(&mut self) -> bool {
        let dir = self.upd_dir();
        let p = &self.c.p;
        let rowner = |h: &[u8]| p.assoc("ROWNER", h).to_vec();
        let mut u = std::mem::take(&mut self.upd);
        let ch = u.lines(&self.c, &dir, &self.me, &rowner);
        self.upd = u;
        ch
    }

    /// U: a new round, or, while the last one still runs, that one shown again (never a second
    /// try at any of it). Enter or I on an [I] line: its command, copied; Enter elsewhere, or
    /// Esc, closes.
    pub(super) fn upd_show(&mut self) {
        let mut sel: Bytes = b"0".to_vec();
        if !(self.upd.n() > 0 && self.upd.running()) {
            self.upd_start();
        }
        loop {
            self.upd_poll();
            self.upd_lines();
            // upd_tick: upd_poll; upd_lines
            let mut tick = |s: &mut Ui| -> Option<Vec<Bytes>> {
                s.upd_poll();
                s.upd_lines().then(|| s.upd.pitems.clone())
            };
            let bar = |s: &Ui| s.upd.bar.clone();
            let krows = |s: &Ui| s.upd.pkrows.clone();
            let mut o = modal::PickOpts {
                keys: b"i".to_vec(),
                krows: self.upd.pkrows.clone(),
                hint: Some("↑↓ choose · I: command · Esc closes".as_bytes().to_vec()),
                sel: sel.clone(),
                tick: Some(&mut tick),
                bar: Some(&bar),
                krows_at: Some(&krows),
            };
            let items = self.upd.pitems.clone();
            if !self.pick(&mut o, b"UPDATE", &items) {
                break;
            }
            sel = self.picked.clone();
            let k = num(&sel);
            if !sh::contains(&self.upd.pkrows, &cat(&[b" ", &sel, b" "])) {
                break;
            }
            let k = k as usize;
            let a = if self.upd.kind[k] == b"note" { self.upd.arg[k].clone() } else { self.upd.text[k].clone() };
            // user_note $a: mode, user and host, checked words
            let w: Vec<Bytes> = a.split(|c| matches!(c, b' ' | b'\t' | b'\n')).filter(|x| !x.is_empty()).map(|x| x.to_vec()).collect();
            self.user_note(&w);
            self.prev.clear();
            super::boxes::BoxHost::draw(self);
        }
        if self.upd.running() {
            self.notice("still updating · U shows it".as_bytes());
        }
    }

    /// user_note install|update USER [HOST]: the command that installs or updates tmux-revive
    /// for USER, to run in their own pane (on HOST, a linked computer): shown in a box over the
    /// panel, and put in tmux's paste buffer. Nothing is run for them from here. The install
    /// command is README.md's.
    fn user_note(&mut self, a: &[Bytes]) {
        let arg = |i: usize| a.get(i).cloned().unwrap_or_default();
        let (mode, u, h) = (arg(0), arg(1), arg(2));
        let mut cmd: Bytes = b"tmux-revive update".to_vec();
        let mut who = cat(&[&u, b"'s pane"]);
        if !m(USER_RE, &u) {
            return;
        }
        if !h.is_empty() {
            who.extend(cat(&[b" on ", &h]));
        }
        if mode == b"install" {
            cmd.clear();
            'f: for f in [&b"/README.md"[..], b"/install.sh"] {
                let t = std::fs::read(sh::os(&sh::path(&[&self.root, f]))).unwrap_or_default();
                // while IFS= read -r l: each whole line (one with no newline at its end isn't read)
                for l in sh::lines(&t) {
                    let l = l.strip_prefix(b"#   ".as_slice()).unwrap_or(&l).to_vec();
                    if m(r"^curl -fsSL https://[A-Za-z0-9./_-]+/install\.sh \| sh$", &l) {
                        cmd = l;
                        break 'f;
                    }
                }
            }
            if cmd.is_empty() {
                return;
            }
        }
        // Into tmux's paste buffer, and the system clipboard too where the terminal allows (-w).
        if !sh::tm(&[b"set-buffer", b"-w", b"--", &cmd]).ok {
            sh::tm(&[b"set-buffer", b"--", &cmd]);
        }
        let lines = vec![
            cat(&[b"Run this in ", &who, b":"]),
            Vec::new(),
            cmd,
            Vec::new(),
            b"Copied. Paste it there, or press prefix ].".to_vec(),
        ];
        self.note(&cat(&[&mode, b" for ", &u]), &lines);
    }
}

/// IFS whitespace off both ends (read with the default IFS)
pub fn trim_ifs(l: &[u8]) -> Bytes {
    let ws = |c: &u8| *c == b' ' || *c == b'\t' || *c == b'\n';
    let a = l.iter().position(|c| !ws(c)).unwrap_or(l.len());
    let b = l.iter().rposition(|c| !ws(c)).map(|i| i + 1).unwrap_or(a);
    l[a..b.max(a)].to_vec()
}

/// `tmux-revive-panel --remote-run HOST REQUEST...`: links::remote_run of this tree's links, its
/// output on stdout and its status as this one's (a U job for a linked computer)
pub fn remote_run_main(root: &[u8], args: &[Bytes]) -> ! {
    use std::io::Write;
    sh::init(root);
    let g = crate::collect::G::new(root);
    let cfg = crate::collect::links::LinkCfg::from_env(&g.astate, &g.asay);
    let req: Vec<&[u8]> = args[1..].iter().map(|a| a.as_slice()).collect();
    let (st, out) = crate::collect::links::remote_run(&cfg, &args[0], &req, usize::MAX);
    let _ = std::io::stdout().write_all(&out);
    let _ = std::io::stdout().flush();
    std::process::exit(st);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::collect::gather::tests::bash_fn;
    use crate::compat::tests::{bash, setup};
    use crate::render::prim::tests::bash_prims;

    fn tmp(name: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("upd-test-{}-{}", name, std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    /// upd_last against bash's, on installer output with colours, OSC titles, stray escapes,
    /// blank lines, "xx"/"!!"/"==>" in front, and a last line with no newline
    #[test]
    fn upd_last_as_bash() {
        setup();
        let d = tmp("last");
        let long = "y".repeat(5000);
        let cases: Vec<String> = vec![
            "".into(),
            "\n\n  \n".into(),
            "\x1b[1;34m==>\x1b[0m downloading\n\x1b[1;31mxx\x1b[0m  download failed: https://x/y.tar.gz\n".into(),
            "ok\n!! careful now\n\n".into(),
            "a\n  ==>   done it\n".into(),
            "==>done\n".into(),
            "title \x1b]0;pwned\x07 here\nand \x1b]2;t\x1b\\ there".into(),
            "open \x1b]0;never ends\n".into(),
            "csi \x1b[?25l\x1b[2K\x1b[38;5;196mred\x1b[0m \x1b[ 1q end\n".into(),
            "stray \x1bX and \x1b(B and a last \x1b".into(),
            "not csi \x1b[12\x01 x\n".into(),
            format!("{}\nlast line ±é\n", long),
            format!("start\n{}", long),
            "tab\there\x01\x7f ctl\n\t \n".into(),
        ];
        for (i, c) in cases.iter().enumerate() {
            let f = d.join(format!("{}.out", i));
            std::fs::write(&f, c).unwrap();
            let fb = f.as_os_str().as_encoded_bytes();
            let theirs = bash(&format!("{}\n{}\nupd_last \"$1\"; printf '%s' \"$LAST\"", bash_prims(), bash_fn("upd_last")), &[fb]);
            assert_eq!(String::from_utf8_lossy(&upd_last(fb)), String::from_utf8_lossy(&theirs), "case {} {:?}", i, c);
        }
        let _ = std::fs::remove_dir_all(&d);
    }

    /// upd_lines against bash's: jobs updating, updated (a version arrow, already current, no
    /// arrow), unreachable, failed with its last line, no permission here and there (with and
    /// without an owner), skips and notes; PITEMS, PKROWS, UPD_BAR and UPD_TEXT after, and
    /// whether a second look changed anything
    #[test]
    fn upd_lines_as_bash() {
        setup();
        let d = tmp("lines");
        let db = d.as_os_str().as_encoded_bytes().to_vec();
        // (kind, name, arg, text, st, out)
        let rows: Vec<(&str, &str, &str, &str, Option<&str>, &str)> = vec![
            ("job", "this computer", "", "", Some("0"), "==> tmux-revive 1.0.0 -> 9.9.9, release v9.9.9\n  agent-say name x\n"),
            ("note", "root", "install root ", "not installed", None, ""),
            ("note", "deploy", "update deploy ", "has 1.0.0", None, ""),
            ("job", "far.example", "far.example", "", Some("0"), "x tmux-revive 1.2.0 -> 1.2.0 y tmux-revive 1.2.3 -> 1.2.3\n"),
            ("job", "near.example", "near.example", "", Some("0"), "done\n"),
            ("job", "dead.example", "dead.example", "", Some("255"), "anything\n"),
            ("job", "slow.example", "slow.example", "", Some("124"), ""),
            ("job", "slow2.example", "slow2.example", "", None, ""),
            ("job", "perm.example", "perm.example", "", Some("1"), "mv: cannot move '/opt/tmux-revive': Permission denied\n"),
            ("job", "perm2.example", "perm2.example", "", Some("1"), "Operation NOT permitted\n"),
            ("skip", "login.example", "", "skipped: needs login · B", None, ""),
            ("job", "fail.example", "fail.example", "", Some("1"), "\x1b[1;31mxx\x1b[0m  download failed: a very long reason that goes well past the thirty-six columns\n"),
            ("job", "bare.example", "bare.example", "", Some("2"), ""),
            ("job", "a-name-much-longer-than-twenty-two.example", "x.example", "", Some("124"), ""),
            ("job", "", "", "", Some("1"), "Permission denied\n"),
        ];
        let mut u = Upd::default();
        let mut sh_rows = String::new();
        for (i, (k, n, a, t, st, out)) in rows.iter().enumerate() {
            u.add(k.as_bytes(), n.as_bytes(), a.as_bytes(), t.as_bytes());
            if let Some(st) = st {
                std::fs::write(d.join(format!("{}.st", i)), format!("{}\n", st)).unwrap();
            }
            if !out.is_empty() {
                std::fs::write(d.join(format!("{}.out", i)), out).unwrap();
            }
            sh_rows += &format!("upd_add '{}' '{}' '{}' '{}'\n", k, n, a, t);
        }
        let c = Ctx::new();
        let rowner = |h: &[u8]| if h == b"perm.example" { b"deploy".to_vec() } else { Vec::new() };
        let ch = u.lines(&c, &db, b"me", &rowner);
        let mut ours = format!("{}\n", ch as i32);
        for l in &u.pitems {
            ours += &format!("{}\n", String::from_utf8_lossy(l));
        }
        ours += &format!("[{}] [{}]\n", String::from_utf8_lossy(&u.pkrows), String::from_utf8_lossy(&u.bar));
        for t in &u.text {
            ours += &format!("{}|", String::from_utf8_lossy(t));
        }
        let again = u.lines(&c, &db, b"me", &rowner);
        ours += &format!("\n{}\n", again as i32);
        let body = format!(
            "{}\n{}\n{}\n{}\nUPD_DIR=$1 ME=me PITEMS=() PKROWS=' ' UPD_BAR=''\ndeclare -A ROWNER=([perm.example]=deploy)\nUPD_N=0 UPD_NAME=() UPD_KIND=() UPD_ARG=() UPD_TEXT=() UPD_PID=() UPD_SEEN=()\n{}\
             upd_lines; echo $((!$?)); printf '%s\\n' \"${{PITEMS[@]}}\"; echo \"[$PKROWS] [$UPD_BAR]\"; printf '%s|' \"${{UPD_TEXT[@]}}\"; upd_lines; r=$?; echo; echo $((!r))",
            bash_prims(),
            bash_fn("upd_add"),
            bash_fn("upd_last"),
            bash_fn("upd_lines"),
            sh_rows
        );
        let theirs = bash(&body, &[&db]);
        assert_eq!(ours, String::from_utf8_lossy(&theirs));
        let _ = std::fs::remove_dir_all(&d);
    }

    /// The job's shell is bash's upd_job subshell, word for word
    #[test]
    fn the_job_is_bashs() {
        let f = bash_fn("upd_job");
        assert!(f.contains("trap '' HUP"));
        assert!(f.contains(r#""$@" </dev/null >"$f.out" 2>&1"#));
        assert!(f.contains(r#"echo $? >"$f.tmp" && mv -f "$f.tmp" "$f.st""#));
        assert_eq!(JOB_SH.replace("$0", "$f"), r#"trap '' HUP; "$@" </dev/null >"$f.out" 2>&1; echo $? >"$f.tmp" && mv -f "$f.tmp" "$f.st""#);
    }
}
