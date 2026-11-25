//! The ? page live: scripts/help.sh's help_view (its keys, the redraw every second, TICK moving
//! every other one), help_confirm, help_install, help_open and what. The page itself is
//! render::help's help_frame, the one --once draws, drawn by the panel's own draw while HELP is on.

use super::boxes::BoxHost;
use super::modal::Rd;
use super::Ui;
use crate::collect::sh::{self, Bytes};
use crate::compat::{blen, case_map, itoa};
use crate::render::help::help_wrap;
use crate::render::{cat, Ctx, B, BGBLU, BLU, BWHT, BYEL, GRY, R};
use std::time::Duration;

pub const WF_URL: &str = "https://raw.githubusercontent.com/odysseyalive/claude-workforce/main/install";
pub const PW_URL: &str = "https://github.com/odysseyalive/playwright-mcp";
pub const PWI_URL: &str = "https://raw.githubusercontent.com/odysseyalive/playwright-mcp/main/install";
pub const CWF_URL: &str = "https://raw.githubusercontent.com/odysseyalive/codex-workforce/main/install";

/// What an install button installs (what WHAT): WNAME, the name shown; WWIN, the window it runs
/// in; WENV, the stand-in tests set; and the URL its one-line installer comes from
pub struct What {
    pub name: &'static str,
    pub win: &'static str,
    pub env: &'static str,
    url: &'static str,
    ext: &'static str,
}

/// what WHAT
pub fn what(w: &[u8]) -> Option<What> {
    match w {
        b"workforce" => Some(What { name: "Claude Workforce", win: "workforce", env: "REVIVE_WORKFORCE_INSTALL_CMD", url: WF_URL, ext: "" }),
        b"codex" => Some(What { name: "Codex Workforce", win: "codex-workforce", env: "REVIVE_CODEX_INSTALL_CMD", url: CWF_URL, ext: "" }),
        b"playwright" => Some(What { name: "playwright-mcp", win: "playwright-mcp", env: "REVIVE_PLAYWRIGHT_INSTALL_CMD", url: PWI_URL, ext: ".sh" }),
        _ => None,
    }
}

/// `uname -s`
pub fn os() -> Bytes {
    let mut u: libc::utsname = unsafe { std::mem::zeroed() };
    if unsafe { libc::uname(&mut u) } != 0 {
        return Vec::new();
    }
    let s = unsafe { std::ffi::CStr::from_ptr(u.sysname.as_ptr()) };
    s.to_bytes().to_vec()
}

impl What {
    /// workforce_cmd, codex_cmd, playwright_cmd: the stand-in when set, else the installer's own
    /// one line for this system (None: there's none)
    pub fn cmd(&self) -> Option<Bytes> {
        let v = sh::env(self.env).unwrap_or_default();
        if !v.is_empty() {
            return Some(v);
        }
        let os = os();
        let unixy = matches!(os.as_slice(), b"Linux" | b"Darwin") || os.ends_with(b"BSD");
        let win = os.starts_with(b"MINGW") || os.starts_with(b"MSYS") || os.starts_with(b"CYGWIN");
        if unixy {
            Some(format!("bash -c \"$(curl -fsSL {}{})\"", self.url, self.ext).into_bytes())
        } else if win {
            Some(format!("powershell.exe -NoProfile -Command \"irm {}.ps1 | iex\"", self.url).into_bytes())
        } else {
            None
        }
    }
}

/// `printf %q`, for what tmux's shell reads back as the same word: backslashes before the
/// characters bash's %q quotes, '' for nothing
pub fn shq(s: &[u8]) -> Bytes {
    if s.is_empty() {
        return b"''".to_vec();
    }
    let mut o = Vec::with_capacity(s.len() + 8);
    for (i, &c) in s.iter().enumerate() {
        let q = matches!(c, b' ' | b'\t' | b'\'' | b'"' | b'\\' | b'|' | b'&' | b';' | b'(' | b')' | b'<' | b'>' | b'!' | b'{' | b'}' | b'*' | b'[' | b'?' | b']' | b'^' | b'$' | b'`' | b',')
            || (i == 0 && matches!(c, b'~' | b'#'));
        if q {
            o.push(b'\\');
        }
        o.push(c);
    }
    o
}

/// `command -v NAME`, its path: the first on PATH that can run
fn which(name: &str) -> Option<Bytes> {
    let p = sh::env("PATH").unwrap_or_default();
    for d in p.split(|&c| c == b':') {
        let d: &[u8] = if d.is_empty() { b"." } else { d };
        let f = sh::path(&[d, b"/", name.as_bytes()]);
        let Ok(c) = std::ffi::CString::new(f.clone()) else { continue };
        if unsafe { libc::access(c.as_ptr(), libc::X_OK) } == 0 && sh::is_file(&f) {
            return Some(f);
        }
    }
    None
}

/// help_confirm's box, as its printfs draw it at ROWS x COLS
pub fn confirm_box(c: &Ctx, title: &[u8], wname: &[u8], cmd: &[u8], rows: i64, cols: i64) -> Bytes {
    let bg: &[u8] = b"\x1b[44m";
    let at = |r: i64, col: i64| cat(&[b"\x1b[", &itoa(r), b";", &itoa(col), b"H"]);
    let w = if cols - 8 < 76 { cols - 8 } else { 76 };
    let mut l: Vec<Bytes> = vec![Vec::new(), cat(&[b"This runs ", wname, b"'s installer:"]), Vec::new()];
    for i in help_wrap(cmd, w - 8) {
        l.push(cat(&[b"  ", BYEL, &i]));
    }
    l.extend([Vec::new(), b"in a new tmux window, so you can watch it there.".to_vec(), Vec::new()]);
    let n = l.len() as i64;
    let top = ((rows - n - 4) / 2).max(1);
    let left = ((cols - w) / 2).max(1);
    let rep = c.rep("═".as_bytes(), w - blen(title) - 11);
    let mut o = cat(&[&at(top, left), BGBLU, BWHT, "╔═".as_bytes(), R, BLU, "░▒▓".as_bytes(), BGBLU, B, BWHT, b" ", title, b" ", R, BLU, "▓▒░".as_bytes(), BGBLU, BWHT, &rep, "╗".as_bytes(), R]);
    for (i, li) in l.iter().enumerate() {
        let pv = c.padv(&cat(&[bg, BWHT, li]), w - 4);
        o.extend(cat(&[&at(top + 1 + i as i64, left), bg, BWHT, "║ ".as_bytes(), &pv, bg, BWHT, " ║".as_bytes(), R, GRY, "░".as_bytes(), R]));
    }
    let pv = c.padv(&cat(&[B, BYEL, b"[y]", BWHT, b" yes, run it     ", B, BYEL, b"[n]", BWHT, b" no, cancel"]), w - 4);
    o.extend(cat(&[&at(top + 1 + n, left), bg, BWHT, "║ ".as_bytes(), &pv, bg, BWHT, " ║".as_bytes(), R, GRY, "░".as_bytes(), R]));
    let rep = c.rep("═".as_bytes(), w - 2);
    o.extend(cat(&[&at(top + 2 + n, left), bg, BWHT, "╚".as_bytes(), &rep, "╝".as_bytes(), R, GRY, "░".as_bytes(), R]));
    let rep = c.rep("░".as_bytes(), w);
    o.extend(cat(&[&at(top + 3 + n, left + 1), GRY, &rep, R]));
    o
}

impl Ui {
    /// help_view: the page stays up, redrawn every second (the clock, a resize), until Esc, x,
    /// q or ? again. ↑↓ (or k and j) scroll a line, PgUp/PgDn and Space a page, Home and End go
    /// to either end. Ctrl-C closes it too. The panel's own looks go on under it; only this
    /// moves TICK while it's up.
    pub(super) fn help_view(&mut self) {
        self.c.p.help = 1;
        self.c.p.help_top = 0;
        self.prev.clear();
        self.modal_on = true;
        self.help_on = true;
        let mut hsec = 0i64;
        loop {
            BoxHost::draw(self);
            let (k, st) = self.mread(1, Duration::from_secs(1));
            match st {
                Rd::Intr | Rd::Gone => break,
                // The second is up. The panel's clock moves on every other one (its REFRESH,
                // 2s), so the page's beacons blink as they would on the panel.
                Rd::Time => {
                    hsec += 1;
                    if hsec % 2 == 0 {
                        self.c.tick += 1;
                    }
                    continue;
                }
                Rd::Ch(_) => {}
            }
            let view = self.c.p.help_view;
            match k.as_slice() {
                b"x" | b"X" | b"q" | b"Q" | b"?" => break,
                b" " => self.c.p.help_top += view - 1,
                b"k" => self.c.p.help_top -= 1,
                b"j" => self.c.p.help_top += 1,
                b"i" | b"I" => self.help_install(b"workforce"),
                b"c" | b"C" => self.help_install(b"codex"),
                b"p" | b"P" => self.help_install(b"playwright"),
                b"o" | b"O" => self.help_open(PW_URL.as_bytes()),
                b"\x1b" => {
                    let (rest, _) = self.mread(1, Duration::from_millis(50));
                    if rest.is_empty() {
                        break; // a lone Esc closes it
                    }
                    let mut seq: Bytes = Vec::new();
                    loop {
                        let (r, st) = self.mread(1, Duration::from_millis(30));
                        if !matches!(st, Rd::Ch(_)) {
                            break;
                        }
                        seq.extend_from_slice(&r);
                        if (r.len() == 1 && (b'@'..=b'~').contains(&r[0])) || blen(&seq) > 8 {
                            break;
                        }
                    }
                    match seq.as_slice() {
                        b"A" => self.c.p.help_top -= 1,
                        b"B" => self.c.p.help_top += 1,
                        b"5~" => self.c.p.help_top -= view - 1,
                        b"6~" => self.c.p.help_top += view - 1,
                        b"H" | b"1~" | b"7~" => self.c.p.help_top = 0,
                        b"F" | b"4~" | b"8~" => self.c.p.help_top = self.c.p.hp.hrows.len() as i64,
                        _ => {}
                    }
                }
                _ => {}
            }
            // help_frame keeps HELP_TOP within the page.
        }
        self.c.p.help = 0;
        self.prev.clear();
        self.modal_on = false;
        self.help_on = false;
    }

    /// help_confirm TITLE WNAME COMMAND: a popup like pick's showing the command that would run.
    /// Only y says yes; n, Esc or any other key says no (false).
    fn help_confirm(&mut self, title: &[u8], wname: &[u8], cmd: &[u8]) -> bool {
        let (rows, cols) = super::modal::tsize();
        let b = confirm_box(&self.c, title, wname, cmd, rows, cols);
        self.over(b);
        let k = self.mkey(None).unwrap_or_else(|_| b"n".to_vec());
        self.over = None;
        self.prev.clear();
        k == b"y" || k == b"Y"
    }

    /// help_install workforce|codex|playwright: the install button. Ask, then run the
    /// installer in a new tmux window of its own, where its output and its question can be
    /// seen. Nothing runs without a y.
    fn help_install(&mut self, w: &[u8]) {
        let Some(wh) = what(w) else { return };
        let Some(cmd) = wh.cmd() else {
            self.notice(&cat(&[b"no ", wh.name.as_bytes(), b" installer for ", &os()]));
            return;
        };
        let stand_in = sh::env(wh.env).unwrap_or_default();
        if stand_in.is_empty() && !cmd.starts_with(b"powershell") && !sh::on_path("curl") {
            self.notice(&cat(&[b"installing ", wh.name.as_bytes(), b" needs curl"]));
            return;
        }
        let title = cat(&[b"INSTALL ", &case_map(wh.name.as_bytes(), true), b"?"]);
        if !self.help_confirm(&title, wh.name.as_bytes(), &cmd) {
            self.notice("install cancelled · nothing was run".as_bytes());
            return;
        }
        // A new window gets tmux's environment, not the panel's: a stand-in goes along by hand.
        let bash = which("bash").unwrap_or_else(|| b"bash".to_vec());
        let script = sh::path(&[&self.root, b"/scripts/help.sh"]);
        let mut run = cat(&[&shq(&bash), b" ", &shq(&script), b" --install ", &shq(w)]);
        if !stand_in.is_empty() {
            run = cat(&[b"env ", wh.env.as_bytes(), b"=", &shq(&stand_in), b" ", &run]);
        }
        if !sh::tm(&[b"new-window", b"-n", wh.win.as_bytes(), &run]).ok {
            self.notice(b"couldn't open a tmux window for the installer");
            return;
        }
        if !sh::env("REVIVE_PANEL_POPUP").unwrap_or_default().is_empty() {
            self.quit(0); // out of the way of the window it opened
        }
        self.notice(&cat(&[b"installing in the new tmux window: ", wh.win.as_bytes()]));
    }

    /// help_open URL: the link button. The page in a browser, or the address to open by hand.
    fn help_open(&mut self, url: &[u8]) {
        let op = if os() == b"Darwin" && sh::on_path("open") {
            "open"
        } else if sh::on_path("xdg-open") {
            "xdg-open"
        } else {
            self.notice(&cat(&[b"open this in your browser: ", url]));
            return;
        };
        use std::process::Stdio;
        let ch = std::process::Command::new(op).arg(sh::os(url)).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn();
        if let Ok(mut ch) = ch {
            std::thread::spawn(move || {
                let _ = ch.wait(); // (disown: never waited on here, never left a zombie)
            });
        }
        self.notice(&cat(&[b"opening ", url]));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::compat::tests::{bash, setup};
    use crate::render::prim::tests::bash_prims;

    fn help_fn(name: &str) -> String {
        let src = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../scripts/help.sh")).unwrap();
        let start = format!("{}() {{", name);
        let mut out = String::new();
        let mut on = false;
        for l in src.lines() {
            if l.starts_with(&start) {
                on = true;
            }
            if on {
                out.push_str(l);
                out.push('\n');
                if l == "}" {
                    break;
                }
            }
        }
        assert!(!out.is_empty(), "no {} in help.sh", name);
        out
    }

    /// help_confirm's box against bash's, at a few sizes, with a command that wraps
    #[test]
    fn confirm_box_as_bash() {
        setup();
        let c = Ctx::new();
        let long = "bash -c \"$(curl -fsSL https://raw.githubusercontent.com/odysseyalive/claude-workforce/main/install)\" and then some more words to wrap";
        for (rows, cols, title, wname, cmd) in [
            (40, 130, "INSTALL CLAUDE WORKFORCE?", "Claude Workforce", "touch /tmp/x/installed"),
            (24, 80, "INSTALL PLAYWRIGHT-MCP?", "playwright-mcp", long),
            (30, 60, "INSTALL CODEX WORKFORCE?", "Codex Workforce", long),
        ] {
            let body = format!(
                "{}\n{}\n{}\ntput() {{ case $1 in lines) echo {} ;; cols) echo {} ;; esac; }}\nWNAME=$2\nhelp_confirm \"$1\" \"$3\" </dev/null; :",
                bash_prims(),
                help_fn("help_wrap"),
                help_fn("help_confirm"),
                rows,
                cols
            );
            let theirs = bash(&body, &[title.as_bytes(), wname.as_bytes(), cmd.as_bytes()]);
            let ours = confirm_box(&c, title.as_bytes(), wname.as_bytes(), cmd.as_bytes(), rows, cols);
            assert_eq!(String::from_utf8_lossy(&ours), String::from_utf8_lossy(&theirs), "{}x{} {}", cols, rows, title);
        }
    }

    /// shq reads back as the same word, as bash's %q does, for what an install's command holds
    #[test]
    fn shq_as_printf_q() {
        for s in ["/usr/bin/bash", "touch /tmp/a b/installed", "a'b\"c$d`e", "~x#y", "x~#", "a=b,c", "é ü", "(x);y&z|w<v>u!t{s}r*q[p]o?n^"] {
            let theirs = bash("printf %q \"$1\"", &[s.as_bytes()]);
            assert_eq!(String::from_utf8_lossy(&shq(s.as_bytes())), String::from_utf8_lossy(&theirs), "{}", s);
            // and the shell reads it back as it was
            let back = bash(&format!("eval \"printf %s {}\"", String::from_utf8_lossy(&shq(s.as_bytes())).replace('\\', "\\\\").replace('"', "\\\"").replace('$', "\\$").replace('`', "\\`")), &[]);
            assert_eq!(String::from_utf8_lossy(&back), s, "{} read back", s);
        }
    }
}
