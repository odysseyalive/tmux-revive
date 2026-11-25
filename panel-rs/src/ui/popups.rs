//! What B and G open besides pick and ask: scripts/panel.sh's code_popup, login_window,
//! read_host_keys and unlink_host, ported literally. The popups are tmux's own (display-popup,
//! or a window of its own for a login when no client can show one), running bash and agent-say
//! as bash's do; the panel keeps drawing under them (each waits in wait_job).

use super::boxes::BoxHost;
use super::modal::NOTE;
use super::Ui;
use crate::collect::sh::{self, Bytes};
use crate::collect::{m, HOST_RE};
use crate::compat::{blen, clean, itoa};
use crate::render::cat;

/// code_popup's own shell, as bash's `bash -c '…'` has it (word for word: a cargo test reads
/// it from panel.sh). agent-say is read in first for its input box; the code is made after, in
/// the popup only. The popup stays open until FUNCTION is done (delivering what waited can take
/// a while): it says so, rather than sitting there an empty box once the input box has gone.
pub const POPUP_SH: &str = r#"export AGENT_SAY_MAILBOX="$3"; o=$4 s=$5; source "$s" || exit 1; c=$(( $(od -An -N4 -tu4 /dev/urandom) % 9000 + 1000 )); input_box ACCESS "Type $c and press Enter to $2" plain "Anything else counts as no · Esc cancels" "$1" || { printf "\\37" >"$o"; exit 1; }; [[ $BOX_REPLY == "$c" ]] || exit 1; read -r h _ < <(stty size 2>/dev/null) || h=10; printf "\e[?25l\e[%s;5H\e[1m%sing…\e[0m" $(( (h + 1) / 2 )) "${2^}"; export AGENT_SAY_APPROVE_CODE="$c"; shift 5; "$@" "$c" >"$o" 2>&1"#;

/// A word as a shell reads it back: in single quotes (printf %q's job, for tmux's sh -c)
pub fn q(s: &[u8]) -> Bytes {
    let mut o = b"'".to_vec();
    for &c in s {
        if c == b'\'' {
            o.extend_from_slice(b"'\\''");
        } else {
            o.push(c);
        }
    }
    o.push(b'\'');
    o
}

/// `printf '%q ' WORD...`: the words as one command line
pub fn cmdline(words: &[&[u8]]) -> Bytes {
    let mut o = Vec::new();
    for w in words {
        o.extend(q(w));
        o.push(b' ');
    }
    o
}

/// `ARGV </dev/null 2>&1` in a command substitution: its status, and its output and errors as
/// they came, in one pipe (close-on-exec: no other command started meanwhile holds it open)
pub fn run_all(argv: &[Bytes], envs: &[(&str, Bytes)]) -> (i32, Bytes) {
    use std::io::Read;
    use std::os::fd::FromRawFd;
    let mut p = [0 as libc::c_int; 2];
    if unsafe { libc::pipe(p.as_mut_ptr()) } != 0 {
        return (126, Vec::new());
    }
    for fd in p {
        unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) };
    }
    let (mut r, w) = unsafe { (std::fs::File::from_raw_fd(p[0]), std::os::fd::OwnedFd::from_raw_fd(p[1])) };
    let mut c = std::process::Command::new(sh::os(&argv[0]));
    for a in &argv[1..] {
        c.arg(sh::os(a));
    }
    for (k, v) in envs {
        c.env(k, sh::os(v));
    }
    let w2 = w.try_clone();
    c.stdin(std::process::Stdio::null()).stdout(std::process::Stdio::from(w));
    if let Ok(w2) = w2 {
        c.stderr(std::process::Stdio::from(w2));
    }
    let ch = c.spawn();
    drop(c); // the write ends close here, so the read ends with the command
    let mut out = Vec::new();
    match ch {
        Ok(mut ch) => {
            let _ = r.read_to_end(&mut out);
            use std::os::unix::process::ExitStatusExt;
            let st = ch.wait().map(|s| s.code().unwrap_or_else(|| 128 + s.signal().unwrap_or(0))).unwrap_or(1);
            (st, out)
        }
        Err(e) => (if e.kind() == std::io::ErrorKind::NotFound { 127 } else { 126 }, out),
    }
}

/// `$(… | tail -n 1)`
pub fn last_line(out: &[u8]) -> Bytes {
    sh::cmdsub(sh::tail_n(out, 1))
}

/// `${s#agent-say: }`
pub fn unsay(s: &[u8]) -> Bytes {
    s.strip_prefix(b"agent-say: ".as_slice()).unwrap_or(s).to_vec()
}

/// AGENT_SAY_SCAN_ID for the commands of one B (bash exports it for the rest of the panel)
pub fn scan_env(scan: &[u8]) -> Vec<(&'static str, Bytes)> {
    if scan.is_empty() {
        Vec::new()
    } else {
        vec![("AGENT_SAY_SCAN_ID", scan.to_vec())]
    }
}

impl Ui {
    /// $ASAY
    pub(super) fn asay(&self) -> Bytes {
        sh::path(&[&self.root, b"/bin/agent-say"])
    }

    /// flash TEXT
    pub(super) fn flash(&mut self, t: &[u8]) {
        self.notice(t);
    }

    /// code_popup QUESTION VERB FUNCTION ARGS... -> (true, CP_OUT: the last line it said, or
    /// nothing (no match)); (false, "") when the popup was closed with no code typed (Esc). A
    /// code shown only in a popup, typed back there: a popup isn't a pane, so no agent can read
    /// it or type into it with send-keys. The popup's own shell then runs agent-say's FUNCTION
    /// ARGS... CODE (approve, grant_refresh), which refuses without that code; no command does it.
    pub(super) fn code_popup(&mut self, qn: &[u8], verb: &[u8], args: &[&[u8]]) -> (bool, Bytes) {
        if self.box_answered(&[b"code", qn]) {
            return (self.bx.rc == 0, self.bx.ans.clone());
        }
        let dir = sh::path(&[&self.astate, b"/intros"]);
        let out = sh::path(&[&dir, b"/.allow.out"]);
        let _ = std::fs::create_dir_all(sh::os(&dir));
        let asay = self.asay();
        let mut w: Vec<&[u8]> = vec![b"bash", b"-c", POPUP_SH.as_bytes(), b"_", qn, verb, &self.amail, &out, &asay];
        w.extend_from_slice(args);
        let pc = cmdline(&w);
        let _ = std::fs::remove_file(sh::os(&out));
        // Tall enough for the question whole, however long the names in it are (it wraps, never cut).
        let h = itoa(12 + blen(qn) / 60);
        self.wait_job(move || sh::tm(&[b"display-popup", b"-E", b"-w", b"76", b"-h", &h, &pc]));
        let cp = sh::cmdsub(sh::tail_n(&std::fs::read(sh::os(&out)).unwrap_or_default(), 1));
        let _ = std::fs::remove_file(sh::os(&out));
        if cp == [NOTE] {
            self.box_out(1, b"", false);
            return (false, Vec::new());
        }
        self.box_out(0, &cp, true);
        (true, cp)
    }

    /// read_host_keys HOST [--new | --fresh] -> (KEYS: its key fingerprints, the one ssh would
    /// use first, KEY_STATE: where they came from: recorded, trusted (your known_hosts), live
    /// (read through your open ssh connection), changed, unknown (first seen by ssh-keyscan);
    /// anything else is taken as unknown)
    pub(super) fn read_host_keys(&mut self, h: &[u8], flag: &[u8], scan: &[u8]) -> (Vec<Bytes>, Bytes) {
        let mut argv: Vec<Bytes> = vec![b"timeout".to_vec(), b"20".to_vec(), self.asay(), b"_host-keys".to_vec(), h.to_vec()];
        if !flag.is_empty() {
            argv.push(flag.to_vec());
        }
        let env = scan_env(scan);
        let out = self.wait_job(move || {
            let e: Vec<(&str, &[u8])> = env.iter().map(|(k, v)| (*k, v.as_slice())).collect();
            let argv: Vec<&[u8]> = argv.iter().map(|a| a.as_slice()).collect();
            sh::run_env(&argv, &e, None).out
        });
        let (mut keys, mut st) = (Vec::new(), b"unknown".to_vec());
        // `| head -n 9`, each line as `while IFS= read -r k` reads it
        for k in sh::lines(&out).into_iter().take(9) {
            if let Some(mm) = crate::compat::re("^state: (recorded|trusted|live|changed|unknown)$").matches(&k) {
                st = mm[1].clone();
            } else if m(r"^SHA256:[A-Za-z0-9+/=]{1,64} \([A-Z0-9-]{1,16}\)$", &k) {
                keys.push(k);
            }
        }
        (keys, st)
    }

    /// login_window HOST [FINGERPRINT...]: log in to a host that wants a password, once, for its
    /// link. ssh runs in a popup over the panel (in a window of its own when no client can show a
    /// popup) and asks you itself; the panel and agent-say never see what you type. Only a key
    /// you press opens it. FINGERPRINTs: the keys you just confirmed; none, the link's own.
    /// Returns whether a login is open now.
    pub(super) fn login_window(&mut self, h: &[u8], keys: &[Bytes], scan: &[u8]) -> bool {
        if !m(HOST_RE, h) {
            return false;
        }
        // Over the panel drawn clean. Esc in it can't be told from a login that failed: either
        // way it's done, and the box before doesn't come back.
        let mut args: Vec<&[u8]> = vec![b"login", h];
        args.extend(keys.iter().map(|k| k.as_slice()));
        if self.box_answered(&args) {
            return self.bx.rc == 0;
        }
        // tmux runs it with the server's environment, not this panel's: say where agent-say
        // keeps its state, which ssh it uses, and where it reads host keys (as for the keys you
        // confirmed).
        let mut env: Vec<Bytes> = vec![cat(&[b"AGENT_SAY_MAILBOX=", &self.amail])];
        if !scan.is_empty() {
            env.push(cat(&[b"AGENT_SAY_SCAN_ID=", scan]));
        }
        for k in ["AGENT_SAY_SSH", "AGENT_SAY_KNOWN_HOSTS", "AGENT_SAY_KEYSCAN"] {
            if let Some(v) = sh::env(k).filter(|v| !v.is_empty()) {
                env.push(cat(&[k.as_bytes(), b"=", &v]));
            }
        }
        let asay = self.asay();
        let mut w: Vec<&[u8]> = vec![b"env"];
        w.extend(env.iter().map(|e| e.as_slice()));
        w.extend_from_slice(&[&asay, b"_login", h]);
        w.extend(keys.iter().map(|k| k.as_slice()));
        let cmd = cmdline(&w);
        if !sh::cmdsub(&sh::tm(&[b"list-clients", b"-F", b"x"]).out).is_empty() {
            self.wait_job(move || sh::tm(&[b"display-popup", b"-E", b"-w", b"84", b"-h", b"14", &cmd])); // returns when it closes
        } else {
            // Until that window closes (ten minutes at most; sshd gives up on a login sooner).
            let o = sh::tm(&[b"new-window", b"-P", b"-F", b"#{window_id}", b"-n", &cat(&[b"login ", h]), &cmd]);
            if !o.ok {
                return false;
            }
            let win = sh::cmdsub(&o.out);
            self.wait_job(move || {
                for _ in 0..2000 {
                    let l = sh::tm(&[b"list-windows", b"-a", b"-F", b"#{window_id}"]).out;
                    if !sh::lines(&l).iter().any(|x| *x == win) {
                        break;
                    }
                    std::thread::sleep(std::time::Duration::from_millis(300));
                }
            });
        }
        self.prev.clear();
        let argv = vec![self.asay(), b"_login".to_vec(), h.to_vec(), b"--check".to_vec()];
        let env = scan_env(scan);
        let st = self.wait_job(move || run_all(&argv, &env).0);
        self.box_out(st, b"", true) == 0
    }

    /// unlink_host HOST: agent-say unlink. Gone from LINKS, it says nothing more; still there,
    /// what agent-say said, on the bar.
    pub(super) fn unlink_host(&mut self, h: &[u8], scan: &[u8]) {
        self.flash(&cat(&[b"unlinking ", h, "…".as_bytes()]));
        BoxHost::draw(self);
        let argv = vec![b"timeout".to_vec(), b"30".to_vec(), self.asay(), b"unlink".to_vec(), h.to_vec()];
        let env = scan_env(scan);
        let out = self.wait_job(move || run_all(&argv, &env).1);
        let out = clean(&last_line(&out));
        if sh::is_dir(&sh::path(&[&self.astate, b"/links/", h])) {
            self.flash(&unsay(&out));
        } else {
            self.c.p.flash.clear();
            let _ = std::fs::remove_file(sh::os(&sh::path(&[&self.rdir, b"/", h, b".rows"]))); // what it kept of that computer
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The popup's shell is the one in panel.sh's code_popup, byte for byte
    #[test]
    fn the_popup_runs_bashs_shell() {
        let src = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../scripts/panel.sh")).unwrap();
        let l = src.lines().find(|l| l.contains("pc=$(printf '%q ' bash -c '")).expect("code_popup's pc= in panel.sh");
        let a = l.find("bash -c '").unwrap() + "bash -c '".len();
        let b = l.rfind("' _ \"$q\"").unwrap();
        assert_eq!(&l[a..b], POPUP_SH);
    }

    /// A command line put together here is read back as the same words by a shell
    #[test]
    fn quoted_words_come_back_whole() {
        let words: Vec<&[u8]> = vec![b"bash", b"-c", POPUP_SH.as_bytes(), b"_", b"Allow it's \"x\" $HOME `y` \\z?", b"", "±é \x1f".as_bytes()];
        let line = cmdline(&words);
        let mut s = b"for w in ".to_vec();
        s.extend(&line);
        s.extend(b"; do printf '%s\\0' \"$w\"; done");
        let out = std::process::Command::new("sh").arg("-c").arg(sh::os(&s)).output().unwrap().stdout;
        let back: Vec<&[u8]> = out.split(|&c| c == 0).collect();
        assert_eq!(&back[..words.len()], &words[..]);
    }
}
