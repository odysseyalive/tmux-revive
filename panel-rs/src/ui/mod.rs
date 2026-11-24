//! The live panel (plan Phase 3): scripts/panel.sh's main loop, keys() and the act() keys that
//! move, scroll, fold, peek and change the art, on a UI thread that never waits on a collector.
//! Every frame is render::Ctx::draw's, the same builders --once draws with; the writer sends the
//! lines that changed inside ?2026. Keys whose act() branch isn't ported yet (O M N B U G I S D
//! ?, Enter on a question) are handed over to the bash panel for that one action (handoff.rs).
//!
//! What runs where:
//! - UI thread (here): input, the act() keys above, the flash, the loading screen,
//!   the loading box and the splash, the frame and its writer.
//! - collectors.rs: panes (gather), mail (messages, links_saves, intros) and peek, a thread
//!   each, kicked as bash looks again: every REVIVE_PANEL_REFRESH seconds without a key, and
//!   after any key but a move.

pub mod collectors;
pub mod handoff;
pub mod keys;
pub mod screens;
pub mod term;
pub mod writer;

use crate::collect::sh::{self, Bytes};
use crate::collect::{m, HOST_RE};
use crate::compat::clean;
use crate::render::frame::Env;
use crate::render::{num, Ctx, Nav};
use crate::snapshot::Snapshot;
use collectors::{Hub, Want};
use keys::{Class, Src};
use std::collections::BTreeMap;
use std::os::fd::RawFd;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// How long a frame waits for the peek or the mail of its round before it is drawn without
const ROUND_WAIT: Duration = Duration::from_millis(300);

/// The names a generation brings (what the looks gathered): the rest of the snapshot is the
/// panel's own (selection, folds, screens, messages)
fn gathered(name: &str) -> bool {
    name.starts_with("P_") || matches!(name, "W_SINCE" | "W_FROM" | "X_SSH" | "X_WHERE")
}

/// A generation's rows into the panel's snapshot, all of them at once: every gathered array
/// the old one had goes (a sparse P_LIM or P_SRV too), so no row ever mixes two gathers
fn swap_gen(s: &mut Snapshot, g: &Snapshot) {
    s.arrays.retain(|k, _| !gathered(k));
    for (k, v) in &g.arrays {
        if gathered(k) {
            s.arrays.insert(k, v.clone());
        }
    }
    for k in ["RVER", "ROWNER"] {
        s.assoc.insert(k, g.assoc.get(k).cloned().unwrap_or_default());
    }
}

pub struct Ui {
    pub c: Ctx,
    root: Bytes,
    hub: Arc<Hub>,
    src: term::Stdin,
    saved: term::Saved,
    sig_r: RawFd,
    wake_r: RawFd,
    /// PREV: the lines last sent
    prev: Vec<Bytes>,
    refresh: Duration,
    astate: Bytes,
    rdir: Bytes,
    folddir: Bytes,
    clk: i64,
    /// LOAD_AT: where the loading screen's bar is, until the first look is in
    load_at: Option<(i64, i64)>,
    lbox: screens::Lbox,
    a_load: BTreeMap<i64, Bytes>,
    full_t: i64,
    /// the first look is in: keys are read, frames drawn
    started: bool,
    // The round: a gather kicked and not yet in, and the mail and peek after it.
    wait_gen: bool,
    wait_mail: bool,
    wait_peek: bool,
    want_draw: bool,
    draw_at: Instant,
    /// When TICK moves on: REFRESH after the last frame with no key (bash's read -t)
    tick_at: Option<Instant>,
}

impl Ui {
    fn secs(&self) -> i64 {
        sh::seconds()
    }

    // ------------------------------------------------------------------ the flash

    /// notice TEXT, which since 1.2.57 is flash TEXT: on the key bar for 5 seconds, cleaned
    /// (agent-say's reply can quote anything). No box, no queue: NOTICES stays empty.
    pub fn notice(&mut self, t: &[u8]) {
        self.c.p.flash = clean(t);
        self.c.p.flash_t = self.secs();
    }

    // ------------------------------------------------------------------ the selection

    fn p_len(&self) -> i64 {
        self.c.p.alen("P_ID")
    }
    fn pa(&self, name: &str, i: i64) -> Bytes {
        self.c.p.a(name, i).to_vec()
    }
    fn folded(&self, h: &[u8]) -> bool {
        self.c.folded(h)
    }

    /// The main loop's before every draw: the same pane kept selected when panes come and go,
    /// then sel_fix
    fn sel_keep(&mut self) {
        let n = self.p_len();
        if !self.c.p.sel_id.is_empty() {
            for i in 0..n {
                if self.c.p.a("P_ID", i) == self.c.p.sel_id.as_slice() {
                    self.c.p.sel = i;
                }
            }
        }
        if self.c.p.sel >= n {
            self.c.p.sel = if n > 0 { n - 1 } else { 0 };
        }
        self.sel_fix();
    }

    /// sel_fix: a heading selected stays on its computer's first row (or goes with it); a row
    /// of a folded computer is its heading
    fn sel_fix(&mut self) {
        if !self.c.p.hsel.is_empty() {
            let mut h = Vec::new();
            for j in 0..self.p_len() {
                if self.c.p.a("P_HOST", j) == self.c.p.hsel.as_slice() {
                    h = self.c.p.hsel.clone();
                    self.c.p.sel = j;
                    break;
                }
            }
            self.c.p.hsel = h;
        }
        let h = self.pa("P_HOST", self.c.p.sel);
        if self.c.p.p_groups != 0 && self.c.p.hsel.is_empty() && !h.is_empty() && self.folded(&h) {
            self.c.p.hsel = h;
        }
        self.c.p.sel_id = self.pa("P_ID", self.c.p.sel);
    }

    /// fold_load: FOLD from $DIR/panel/fold
    fn fold_load(&mut self) {
        let mut f = BTreeMap::new();
        for p in sh::glob(&self.folddir, b"", b"", false) {
            if sh::is_file(&p) {
                f.insert(sh::basename(&p).to_vec(), b"1".to_vec());
            }
        }
        self.c.p.snap.assoc.insert("FOLD", f);
    }

    /// fold_toggle HOST: folded or opened, and the file that keeps it. false: not a host name,
    /// or the file couldn't be made
    fn fold_toggle(&mut self, h: &[u8]) -> bool {
        if !m(HOST_RE, h) {
            return false;
        }
        let f = sh::path(&[&self.folddir, b"/", h]);
        let fold = self.c.p.snap.assoc.entry("FOLD").or_default();
        if fold.get(h).is_some_and(|v| !v.is_empty()) {
            fold.remove(h);
            let _ = std::fs::remove_file(sh::os(&f));
            true
        } else {
            fold.insert(h.to_vec(), b"1".to_vec());
            std::fs::create_dir_all(sh::os(&self.folddir)).is_ok() && std::fs::write(sh::os(&f), b"").is_ok()
        }
    }

    /// nav_stop I: a pane's row, or a folded computer's heading (an open one is passed over)
    fn nav_stop(&self, i: i64) -> bool {
        match self.c.p.nav.get(i as usize) {
            Some(Nav::Head(h)) => !h.is_empty() && self.folded(h),
            _ => true,
        }
    }

    /// nav_go I [D]: select NAV's entry I, or the nearest stop from it going D (else back)
    fn nav_go(&mut self, i: i64, d: i64) {
        let k = self.c.p.nav.len() as i64;
        if k == 0 {
            return;
        }
        let mut i = i.clamp(0, k - 1);
        let mut j = i;
        while j >= 0 && j < k && !self.nav_stop(j) {
            j += d;
        }
        if j < 0 || j >= k {
            j = i;
            while j >= 0 && j < k && !self.nav_stop(j) {
                j -= d;
            }
        }
        if j < 0 || j >= k {
            return;
        }
        i = j;
        match self.c.p.nav[i as usize].clone() {
            Nav::Head(h) => {
                self.c.p.hsel = h;
                for j in 0..self.p_len() {
                    if self.c.p.a("P_HOST", j) == self.c.p.hsel.as_slice() {
                        self.c.p.sel = j;
                        break;
                    }
                }
            }
            Nav::Pane(p) => {
                self.c.p.hsel.clear();
                self.c.p.sel = p;
            }
        }
    }

    /// scroll KEY: in PANES the selection moves (round at the ends for the arrows); elsewhere
    /// the focused window scrolls, draw keeping it in range
    fn scroll(&mut self, key: &[u8]) {
        let f = self.c.p.focus.clamp(0, 3) as usize;
        let wh = self.c.p.wh[f];
        let pg = if wh > 1 { wh - 1 } else { 1 };
        let d = match key {
            b"up" => -1,
            b"down" => 1,
            b"pgup" => -pg,
            b"pgdn" => pg,
            b"home" => -100000,
            _ => 100000,
        };
        match self.c.p.focus {
            0 => {
                self.c.panes_rows();
                self.c.nav_at();
                let k = self.c.p.nav.len() as i64;
                if k == 0 {
                    return;
                }
                if key == b"up" || key == b"down" {
                    let mut i = self.c.p.nat;
                    for _ in 0..k {
                        i = (i + d + k) % k;
                        if self.nav_stop(i) {
                            break;
                        }
                    }
                    self.nav_go(i, d);
                } else {
                    let nat = self.c.p.nat;
                    self.nav_go(nat + d, if d > 0 { 1 } else { -1 });
                }
            }
            1 => self.c.p.pb -= d,
            2 => {
                self.c.p.mo += d;
                self.c.p.mman = if key == b"end" { 0 } else { 1 };
            }
            3 => self.c.p.so += d,
            _ => {}
        }
    }

    // ------------------------------------------------------------------ act

    /// act KEY: what a key does. Those not ported yet go to the bash panel for the one action.
    fn act(&mut self, key: &[u8]) {
        // A key may draw over the panel: repaint it whole. Moves keep the line-by-line redraw.
        if keys::class(key) != Class::Nav {
            self.prev.clear();
        }
        let sel = self.c.p.sel;
        // A heading selected: the keys for a pane wait for one.
        if !self.c.p.hsel.is_empty() && matches!(key, b"o" | b"O" | b"m" | b"M" | b"n" | b"N") {
            let t = crate::render::cat(&[b"select one of ", &self.c.p.hsel, b"'s panes for that"]);
            self.notice(&t);
            return;
        }
        match key {
            b"o" | b"O" | b"m" | b"M" | b"n" | b"N" | b"b" | b"B" | b"u" | b"U" | b"g" | b"G" | b"i" | b"I" | b"s" | b"S" | b"d" | b"D"
            | b"?" => self.handoff(key),
            b"p" | b"P" => {
                self.c.p.peek = (self.c.p.peek == 0) as i64;
                self.c.p.peek_sel = self.pa("P_ID", sel);
                self.c.p.peek_all = 0;
            }
            b"enter" => {
                if !self.c.p.hsel.is_empty() {
                    let h = self.c.p.hsel.clone();
                    self.fold_toggle(&h);
                    if !self.folded(&h) {
                        self.c.p.po = 1 << 30; // opened: its panes into view, under its heading
                    }
                } else if self.c.p.a("P_STATE", sel) == b"asking" {
                    self.handoff(b"enter"); // answering: Phase 5
                }
            }
            b"f" => {
                if !self.c.p.hsel.is_empty() {
                    self.act(b"enter");
                    return;
                }
                let h = self.pa("P_HOST", sel);
                if h.is_empty() {
                    return; // this computer: nothing to fold (1.2.57 says nothing)
                }
                if self.fold_toggle(&h) {
                    self.c.p.hsel = h;
                }
            }
            b"F" => {
                let mut seen: Vec<Bytes> = Vec::new();
                for i in 0..self.p_len() {
                    let h = self.pa("P_HOST", i);
                    if !h.is_empty() && !seen.contains(&h) {
                        seen.push(h);
                    }
                }
                if seen.is_empty() {
                    return; // nothing bridged
                }
                let all = seen.iter().all(|h| self.folded(h));
                for h in &seen {
                    if all || !self.folded(h) {
                        self.fold_toggle(h);
                    }
                }
                if all {
                    self.c.p.hsel.clear();
                } else if !self.c.p.a("P_HOST", sel).is_empty() {
                    self.c.p.hsel = self.pa("P_HOST", sel);
                }
            }
            b"a" | b"A" => self.c.scene = (self.c.scene + 1) % crate::render::art::SCENES.len() as i64,
            b"q" | b"Q" => self.quit(0),
            [d] if d.is_ascii_digit() => {
                let mut n: Bytes = vec![*d];
                let wp0 = |s: &Self, w: i64| -> Bytes {
                    let wp = s.c.p.a("P_WP", w);
                    wp.split(|&c| c == b'.').next().unwrap_or(b"").to_vec()
                };
                if n == b"0" {
                    n = b"10".to_vec();
                    for w in 0..self.p_len() {
                        if self.c.p.a("P_HOST", w).is_empty() && wp0(self, w) == b"0" {
                            n = b"0".to_vec();
                            break;
                        }
                    }
                }
                for w in 0..self.p_len() {
                    if self.c.p.a("P_HOST", w).is_empty() && wp0(self, w) == n {
                        self.c.p.sel = w;
                        self.c.p.hsel.clear();
                        break;
                    }
                }
            }
            b"up" | b"down" | b"pgup" | b"pgdn" | b"home" | b"end" => self.scroll(key),
            b"J" => self.c.p.focus = self.c.tab_next(1),
            b"K" => self.c.p.focus = self.c.tab_next(3),
            _ => {}
        }
        self.c.p.sel_id = self.pa("P_ID", self.c.p.sel);
    }

    // ------------------------------------------------------------------ keys

    /// keys KEY...: the key waiting, and any behind it already (a held arrow), drawn once.
    fn input(&mut self) {
        let Some(first) = self.src.byte(Duration::ZERO) else { return };
        // While the loading box is up keys wait for nothing: they go, all but q (quit).
        if self.lbox.on {
            if keys::lbox_key(&mut self.src, first) {
                self.quit(0);
            }
            self.look_again();
            self.request_draw();
            return;
        }
        let mut nav = false;
        let mut drawn = false;
        let mut key = keys::decode(&mut self.src, first);
        loop {
            match keys::class(&key) {
                Class::Nav => {
                    self.act(&key);
                    nav = true;
                }
                Class::View => {
                    // drawn at once from what was gathered, then looked at again
                    self.act(&key);
                    self.draw();
                    drawn = true;
                    nav = false;
                    break;
                }
                Class::Nothing => {}
                Class::Act => {
                    self.act(&key);
                    nav = false;
                    break;
                }
            }
            // read -t 0 && IFS= read -rsn1 key || break
            match self.src.byte(Duration::ZERO) {
                Some(b) => key = keys::decode(&mut self.src, b),
                None => break,
            }
        }
        if !nav {
            self.look_again();
        }
        if !drawn {
            self.request_draw();
        }
    }

    // ------------------------------------------------------------------ the round

    /// Look again: the panes, and after them the mail and the peek
    fn look_again(&mut self) {
        self.wait_gen = true;
        self.tick_at = None;
        self.hub.panes_k.kick();
    }

    /// The peek the frame about to be drawn shows (draw's show: a pane, not the panel's own,
    /// with the peek on for it or asking), told to the peek thread when it changed
    fn want_peek(&mut self) -> bool {
        let p = &self.c.p;
        let sel = p.sel;
        let id = p.a("P_ID", sel).to_vec();
        let st = p.a("P_STATE", sel);
        let h = p.a("P_HOST", sel).to_vec();
        let rid = p.a("P_RID", sel).to_vec();
        let on = p.peek != 0 && (p.peek_all != 0 || p.peek_sel.is_empty() || p.peek_sel == id);
        let w = if !p.hsel.is_empty() || st.is_empty() || st == b"self" || !(on || st == b"asking") {
            Want::None
        } else if !h.is_empty() {
            if m(HOST_RE, &h) && m("^%[0-9]+$", &rid) {
                Want::Remote { h, rid }
            } else {
                Want::None
            }
        } else {
            Want::Local { id, coloured: st == b"asking" }
        };
        let mut cur = self.hub.want.lock().unwrap();
        if *cur != w {
            *cur = w;
            drop(cur);
            self.hub.peek_k.kick();
            return true;
        }
        false
    }

    /// A frame wanted now; one whose peek moved to another pane waits a moment for its screen
    fn request_draw(&mut self) {
        self.want_draw = true;
        self.draw_at = Instant::now();
        if self.want_peek() {
            self.wait_peek = true;
            self.draw_at = Instant::now() + ROUND_WAIT;
        }
    }

    /// What the collectors left since: a generation, the mail, a peek
    fn take(&mut self) {
        let gen = self.hub.gen.lock().unwrap().take();
        if let Some(g) = gen {
            self.apply_gen(&g);
        }
        let mail = self.hub.mail.lock().unwrap().take();
        if let Some(mm) = mail {
            let to_map = |v: Vec<Bytes>| -> BTreeMap<i64, Bytes> { v.into_iter().enumerate().map(|(i, x)| (i as i64, x)).collect() };
            let s = &mut self.c.p.snap;
            s.arrays.insert("MSG", to_map(mm.msg));
            s.arrays.insert("SIDE", to_map(mm.side));
            s.arrays.insert("INTROS", to_map(mm.intros));
            self.c.p.mold = mm.mold;
            self.c.p.mwait = mm.mwait;
            self.c.p.msg_intro = mm.intro_on;
            self.wait_mail = false;
            if !self.want_draw {
                self.want_draw = true;
                self.draw_at = Instant::now();
            }
        }
        let peek = self.hub.peek.lock().unwrap().take();
        if let Some(pk) = peek {
            if pk.want == *self.hub.want.lock().unwrap() {
                let to_map = |v: Vec<Bytes>| -> BTreeMap<i64, Bytes> { v.into_iter().enumerate().map(|(i, x)| (i as i64, x)).collect() };
                match &pk.want {
                    Want::Local { id, .. } => {
                        self.c.p.screen_id = id.clone();
                        self.c.p.snap.arrays.insert("SCREEN", to_map(pk.screen));
                        self.c.p.snap.arrays.insert("SCREEN_E", to_map(pk.screen_e));
                    }
                    Want::Remote { h, rid } => {
                        self.c.p.rpeek_for = crate::render::cat(&[h, b" ", rid]);
                        self.c.p.rpeek_at = pk.rpeek_at;
                        self.c.p.snap.arrays.insert("RPEEK", to_map(pk.rpeek));
                    }
                    Want::None => {}
                }
                self.wait_peek = false;
                if !self.want_draw {
                    self.want_draw = true;
                    self.draw_at = Instant::now();
                }
            }
        }
    }

    /// A gather is in: its rows, then what the main loop does after each (1.2.57): the loading
    /// bar gone, the loading box checked
    fn apply_gen(&mut self, g: &collectors::Gen) {
        swap_gen(&mut self.c.p.snap, &g.snap);
        self.c.p.p_groups = g.snap.var("P_GROUPS").map(num).unwrap_or(0);
        if let Some(v) = g.snap.var("VERSION") {
            self.c.p.version = v.to_vec();
        }
        if let Some(v) = g.snap.var("HOST") {
            self.c.p.host = v.to_vec();
        }
        self.a_load = g.a_load.clone();
        self.load_at = None; // the first look is in: no more loading bar
        self.lbox_check();
        self.started = true;
        self.wait_gen = false;
        // The round: the mail after the panes (bash's draw runs messages after the gather), and
        // the peek, looked at again.
        self.wait_mail = true;
        self.hub.mail_k.kick();
        self.sel_keep();
        self.want_peek();
        self.hub.peek_k.kick();
        self.wait_peek = true;
        self.want_draw = true;
        self.draw_at = Instant::now() + ROUND_WAIT;
    }

    // ------------------------------------------------------------------ draw

    /// The main loop's draw: the selection kept, all of it sent again every 15 s, the frame
    /// (render's draw) through the writer, the loading box over it
    pub fn draw(&mut self) {
        self.sel_keep();
        let secs = self.secs();
        // All of it drawn again every 15 s, not only what changed.
        if secs - self.full_t >= 15 {
            self.prev.clear();
            self.full_t = secs;
        }
        let (cols, lines) = term::size().unwrap_or((100, 40));
        let now = self.now();
        let p = &mut self.c.p;
        p.tcols = cols;
        p.tlines = lines;
        p.secs = secs;
        p.now = now;
        p.lbox = self.lbox.on as i64;
        self.c.draw();
        self.c.p.print.clear();
        let out = std::mem::take(&mut self.c.out);
        let buf = writer::frame(&out, &mut self.prev, None);
        term::out(&buf);
        if self.lbox.on {
            let b = screens::lbox_draw(&mut self.lbox, &self.c);
            term::out(&b);
        }
        self.want_draw = false;
        if !self.wait_gen {
            self.tick_at = Some(Instant::now() + self.refresh);
        }
    }

    fn now(&self) -> i64 {
        let pin = sh::env("REVIVE_PANEL_NOW").unwrap_or_default();
        if m("^[0-9]{1,12}$", &pin) {
            num(&pin)
        } else {
            sh::time_s()
        }
    }

    /// The panel closes: the fetched screens removed, the terminal put back
    pub fn quit(&self, st: i32) -> ! {
        self.cleanup();
        term::restore(&self.saved);
        std::process::exit(st);
    }

    /// Other computers' screens it fetched go when it closes.
    fn cleanup(&self) {
        let files = self.hub.peek_files.lock().map(|f| f.clone()).unwrap_or_default();
        for f in files {
            let _ = std::fs::remove_file(sh::os(&f));
            // FILE.fail, and a screen still being asked for (FILE.XXXXXX): bash's fetch, hung up
            // on, throws it away; here the fetch's thread ends with the panel, so it goes now
            let dir = crate::collect::dirname(&f);
            let pre = sh::path(&[sh::basename(&f), b"."]);
            for t in sh::glob(&dir, &pre, b"", false) {
                let _ = std::fs::remove_file(sh::os(&t));
            }
        }
    }

    // ------------------------------------------------------------------ the loop

    fn run(&mut self) -> ! {
        loop {
            let now = Instant::now();
            // How long to wait: for a frame due, for the clock's tick.
            let mut until: Option<Instant> = None;
            if self.want_draw {
                until = Some(self.draw_at);
            }
            if let Some(t) = self.tick_at {
                until = Some(until.map_or(t, |u| u.min(t)));
            }
            let ms: libc::c_int = match until {
                None => -1,
                Some(t) => t.saturating_duration_since(now).as_millis().min(i32::MAX as u128) as libc::c_int,
            };
            // Keys are read once the first look is in (bash reads none while it gathers).
            let mut fds = [
                libc::pollfd { fd: self.sig_r, events: libc::POLLIN, revents: 0 },
                libc::pollfd { fd: self.wake_r, events: libc::POLLIN, revents: 0 },
                libc::pollfd { fd: if self.started { 0 } else { -1 }, events: libc::POLLIN, revents: 0 },
            ];
            let r = unsafe { libc::poll(fds.as_mut_ptr(), 3, ms) };
            if r < 0 && std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted {
                self.quit(1);
            }
            if fds[0].revents != 0 {
                for b in term::drain(self.sig_r) {
                    if b == b'X' || b == b'I' {
                        self.quit(0);
                    }
                    // WINCH: all of it drawn again, at the new size
                    term::out(b"\x1b[2J");
                    self.prev.clear();
                    self.c.p.atop.clear();
                    self.want_draw = true;
                    self.draw_at = Instant::now();
                }
            }
            if fds[1].revents != 0 {
                term::drain(self.wake_r);
                self.take();
            }
            if fds[2].revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0 {
                self.quit(0); // the terminal is gone
            }
            if fds[2].revents & libc::POLLIN != 0 {
                self.input();
            }
            if term::GONE.load(std::sync::atomic::Ordering::Relaxed) {
                self.quit(0);
            }
            let now = Instant::now();
            if self.tick_at.is_some_and(|t| now >= t) && !self.want_draw {
                // read -t timed out: the animation moves on with the clock, and all is looked at
                self.c.tick += 1;
                self.look_again();
            }
            if self.want_draw && (now >= self.draw_at || (!self.wait_mail && !self.wait_peek && !self.wait_gen)) {
                self.draw();
            }
        }
    }
}

/// The live panel: `tmux-revive-panel` with no arguments (bash: panel.sh with none)
pub fn run(root: &[u8]) -> ! {
    if !term::is_tty() {
        eprintln!("tmux-revive panel needs a terminal");
        std::process::exit(1);
    }
    sh::init(root);
    let g0 = crate::collect::G::new(root);
    g0.cache_dir();
    term::stderr_to(&sh::path(&[&g0.rdir, b"/panel.err"]));
    term::enter();
    let saved = term::Saved::take();
    saved.raw_ish();
    term::on_panic(&saved);
    let sig_r = term::signals();
    let (wake_r, wake_w) = term::pipe();
    let hub = Arc::new(Hub::default());
    collectors::start(root, &hub, wake_w);
    // The first look starts now, under the splash and the loading screen.
    hub.panes_k.kick();
    let env = Env::read();
    let mut c = Ctx::load(&Snapshot::apply(&[]).unwrap_or_default(), &env);
    c.tick = 0;
    c.p.help = 0; // the ? page is the bash panel's for now (a hand-over)
    c.p.version = g0.version.clone();
    c.p.host = g0.host.clone();
    let refresh = sh::env("REVIVE_PANEL_REFRESH").filter(|v| !v.is_empty()).unwrap_or_else(|| b"2".to_vec());
    let refresh = std::str::from_utf8(&refresh).ok().and_then(|s| s.parse::<f64>().ok()).filter(|f| f.is_finite() && *f > 0.0).unwrap_or(2.0);
    let dir = g0.dir.clone();
    let mut ui = Ui {
        c,
        root: root.to_vec(),
        hub,
        src: term::Stdin,
        saved,
        sig_r,
        wake_r,
        prev: Vec::new(),
        refresh: Duration::from_secs_f64(refresh),
        astate: g0.astate.clone(),
        rdir: g0.rdir.clone(),
        folddir: sh::path(&[&dir, b"/panel/fold"]),
        clk: g0.clk,
        load_at: None,
        lbox: screens::Lbox::default(),
        a_load: BTreeMap::new(),
        full_t: 0,
        started: false,
        wait_gen: true,
        wait_mail: false,
        wait_peek: false,
        want_draw: false,
        draw_at: Instant::now(),
        tick_at: None,
    };
    drop(g0);
    match sh::env("REVIVE_PANEL_SPLASH").as_deref() {
        Some(b"1") => ui.splash(),
        Some(b"0") => {}
        _ => {
            if sh::opt(b"@revive-panel-splashed", b"") != b"1" {
                ui.splash();
                sh::tm(&[b"set-option", b"-g", b"@revive-panel-splashed", b"1"]);
            }
        }
    }
    ui.loading();
    ui.prev.clear(); // after the splash: paint the whole panel
    let _ = std::fs::remove_dir_all(sh::os(&sh::path(&[&dir, b"/panel/login-said"]))); // (what an older panel kept here)
    ui.fold_load();
    ui.full_t = ui.secs();
    ui.run()
}

#[cfg(test)]
mod tests {
    use crate::snapshot::Snapshot;

    fn snap(recs: &[(&str, &str, &str)]) -> Snapshot {
        Snapshot::apply(&recs.iter().map(|(a, b, c)| (a.as_bytes().to_vec(), b.as_bytes().to_vec(), c.as_bytes().to_vec())).collect::<Vec<_>>()).unwrap()
    }

    /// A pane appearing above an asking one between two gathers: the second generation's rows
    /// replace the first's whole, so its state stays on its own row, and nothing of the old
    /// generation (a sparse P_LIM) is left on the row that is now another pane's.
    #[test]
    fn a_generation_replaces_the_rows_whole() {
        let mut s = snap(&[("P_ID", "0", "%1"), ("P_STATE", "0", "asking"), ("P_LIM", "0", "1795000000"), ("MSG", "0", "kept"), ("FOLD", "far", "1")]);
        let g = snap(&[("P_ID", "0", "%9"), ("P_ID", "1", "%1"), ("P_STATE", "0", "shell"), ("P_STATE", "1", "asking"), ("RVER", "h", "1.0.0")]);
        super::swap_gen(&mut s, &g);
        assert_eq!(s.list("P_ID"), vec![b"%9".to_vec(), b"%1".to_vec()]);
        assert_eq!(s.list("P_STATE"), vec![b"shell".to_vec(), b"asking".to_vec()]);
        assert!(s.list("P_LIM").is_empty(), "the old generation's limit isn't left on row 0");
        assert_eq!(s.list("MSG"), vec![b"kept".to_vec()], "the panel's own arrays stay");
        assert_eq!(s.assoc["FOLD"].get(&b"far"[..]).map(|v| v.as_slice()), Some(&b"1"[..]));
        assert_eq!(s.assoc["RVER"].get(&b"h"[..]).map(|v| v.as_slice()), Some(&b"1.0.0"[..]));
    }

    #[test]
    fn gathered_names_are_the_looks_only() {
        use super::gathered;
        for n in ["P_ID", "P_STATE", "P_LIM", "W_SINCE", "W_FROM", "X_SSH", "X_WHERE"] {
            assert!(gathered(n), "{}", n);
        }
        for n in ["MSG", "SIDE", "INTROS", "SCREEN", "SCREEN_E", "RPEEK", "NOTICES", "CPU_HIST", "ATOP", "QL", "WON"] {
            assert!(!gathered(n), "{}", n);
        }
    }
}
