//! The boxes a key opens over the panel: scripts/panel.sh's pick (and pick_box), ask and note,
//! byte for byte as bash writes them straight to the terminal, and the nested wait they run in.
//!
//! Each box is a wait loop on the UI thread, as bash's is: its own reads (`read -rsn1 -t 0.2`
//! slices, its own escape parsing and timeouts; keys::decode is not used), so a key's flow in
//! act() stays straight-line code. While it waits, the panel goes on as the main loop does
//! (pump): generations, mail and peeks are taken, the clock ticks and looks again, and the base
//! frame is drawn through the writer; whenever that wrote anything, the box is painted over it
//! inside the same ?2026 update, after its ESC[H, so the cursor ends where the box leaves it (ask
//! shows it at the end of what's typed). Bash freezes the panel under a box; here PANES goes on
//! (the plan's composites). Ctrl-C while a box is up closes the box (bash's `trap 'INTR=1' INT`)
//! and doesn't end the panel.
//!
//! A command that can take a while (agent-say, remote_run) runs on a thread of its own while the
//! panel keeps drawing (wait_job); bash draws and then blocks. Keys typed meanwhile wait, as in
//! bash, for the loop after.

use super::boxes::BoxHost;
use super::{term, Ui};
use crate::collect::sh::{self, Bytes};
use crate::compat::{blen, itoa, substr};
use crate::render::{cat, num, Ctx, B, BCYN, BGBLU, BLU, BWHT, BYEL, CYN, GRY, R};
use std::os::fd::RawFd;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// NOTE: an item starting with it is a line to read, not a choice
pub const NOTE: u8 = 0x1f;

/// What woke the panel's wait
#[derive(Debug, PartialEq, Eq)]
pub enum Woke {
    /// a key is waiting on the terminal
    Key,
    /// the job's pipe was poked
    Job,
    /// the deadline passed
    Time,
    /// Ctrl-C, while a box is up
    Intr,
}

/// One `read -rsn1` as a box reads it
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Rd {
    /// a character; "" is Enter (the newline read stops at)
    Ch(Bytes),
    /// read -t ran out
    Time,
    /// Ctrl-C (bash's INTR=1)
    Intr,
    /// the input closed
    Gone,
}

fn at(r: i64, c: i64) -> Bytes {
    cat(&[b"\x1b[", &itoa(r), b";", &itoa(c), b"H"])
}

/// `tput lines`, `tput cols` as the boxes read them (40 and 80 when there's no terminal)
pub fn tsize() -> (i64, i64) {
    match term::size() {
        Some((c, l)) => (l, c),
        None => (40, 80),
    }
}

// ------------------------------------------------------------------ pick

/// What pick takes for one call (bash sets these as PKEYS=… pick …): letters that also pick
/// the highlighted item on the rows PKROWS lists (" 0 3 "); PHINT, the hint line; PSEL, the
/// item highlighted first; PTICK, run every 0.2 s, Some(items) when they are new (as many, and
/// no wider); PBAR, "DONE TOTAL" drawn as a bar in the blank row.
#[derive(Default)]
pub struct PickOpts<'a> {
    pub keys: Bytes,
    pub krows: Bytes,
    pub hint: Option<Bytes>,
    pub sel: Bytes,
    pub tick: Option<&'a mut dyn FnMut(&mut Ui) -> Option<Vec<Bytes>>>,
    pub bar: Option<&'a dyn Fn(&Ui) -> Bytes>,
}

/// pick_box's state: its items, which are choices (num, ch), the one highlighted, its place
#[derive(Debug, Clone)]
pub struct PickBox {
    pub title: Bytes,
    pub items: Vec<Bytes>,
    pub num: Vec<Option<usize>>,
    pub ch: Vec<usize>,
    pub sel: usize,
    pub hint: Bytes,
    pub w: i64,
    pub top: i64,
    pub left: i64,
}

/// A key as pick_box's loop has it
#[derive(Debug, Clone)]
pub enum PKey {
    /// a character read ("" Enter)
    Ch(Bytes),
    /// Esc, and the 2 characters read after it within 0.05 s
    Esc(Bytes),
    /// Ctrl-C, or the input closed
    Close,
    /// PTICK said the items are new
    Tick(Vec<Bytes>),
}

impl PickBox {
    /// pick_box up to its loop: None when there's nothing to choose (it returns 1, unseen)
    pub fn new(title: &[u8], items: &[Bytes], hint: Option<&[u8]>, psel: &[u8], rows: i64, cols: i64) -> Option<PickBox> {
        let hint = hint.filter(|h| !h.is_empty()).unwrap_or("↑↓ choose · Enter picks · Esc closes".as_bytes()).to_vec();
        let mut num = vec![None; items.len()];
        let mut ch = Vec::new();
        let mut sel: Option<usize> = None;
        for (i, it) in items.iter().enumerate() {
            if it.first() == Some(&NOTE) {
                continue;
            }
            num[i] = Some(ch.len());
            ch.push(i);
            if sel.is_none() {
                sel = Some(i);
            }
        }
        let mut sel = sel?;
        if !psel.is_empty() {
            let p = num_of(psel);
            if p >= 0 && (p as usize) < num.len() && num[p as usize].is_some() {
                sel = p as usize;
            }
        }
        let mut w = blen(&hint) + 6;
        for i in items {
            if blen(i) + 10 > w {
                w = blen(i) + 10;
            }
        }
        if blen(title) + 12 > w {
            w = blen(title) + 12;
        }
        if w > cols - 4 {
            w = cols - 4;
        }
        let h = items.len() as i64 + 5;
        let top = ((rows - h) / 2).max(1);
        let left = ((cols - w) / 2).max(1);
        Some(PickBox { title: title.to_vec(), items: items.to_vec(), num, ch, sel, hint, w, top, left })
    }

    /// One pass of pick_box's loop, its printfs: the frame, title tab and shadow, the items,
    /// the blank row (or PBAR's bar), the hint
    pub fn paint(&self, c: &Ctx, bar: &[u8]) -> Bytes {
        let (w, top, left) = (self.w, self.top, self.left);
        let bg: &[u8] = b"\x1b[44m";
        let hi: &[u8] = b"\x1b[46m\x1b[30m";
        let mut o: Bytes = Vec::new();
        let rep = c.rep("═".as_bytes(), w - blen(&self.title) - 11);
        let line = cat(&[BGBLU, BWHT, "╔═".as_bytes(), R, BLU, "░▒▓".as_bytes(), BGBLU, B, BWHT, b" ", &self.title, b" ", R, BLU, "▓▒░".as_bytes(), BGBLU, BWHT, &rep, "╗".as_bytes(), R]);
        o.extend(cat(&[&at(top, left), &line]));
        let blank = c.rep(b" ", w - 2);
        o.extend(cat(&[&at(top + 1, left), bg, BWHT, "║".as_bytes(), &blank, "║".as_bytes(), R, GRY, "░".as_bytes(), R]));
        let n = self.items.len() as i64;
        for (i, it) in self.items.iter().enumerate() {
            let row = at(top + 2 + i as i64, left);
            if it.first() == Some(&NOTE) {
                let f = c.fld(&it[1..], w - 6);
                o.extend(cat(&[&row, bg, BWHT, "║  ".as_bytes(), BCYN, &f, BWHT, "  ║".as_bytes(), R, GRY, "░".as_bytes(), R]));
                continue;
            }
            let k = self.num[i].unwrap_or(usize::MAX);
            let key: Bytes = if k < 9 { cat(&[&itoa(k as i64 + 1), b" "]) } else { b"  ".to_vec() };
            if i == self.sel {
                let f = c.fld(&cat(&[b" ", &key, b" ", it]), w - 5);
                o.extend(cat(&[&row, bg, BWHT, "║ ".as_bytes(), hi, B, "▶".as_bytes(), &f, R, bg, BWHT, " ║".as_bytes(), R, GRY, "░".as_bytes(), R]));
            } else {
                let kf = c.fld(&key, 3);
                let f = c.fld(it, w - 9);
                o.extend(cat(&[&row, bg, BWHT, "║  ".as_bytes(), BYEL, &kf, BWHT, &f, "  ║".as_bytes(), R, GRY, "░".as_bytes(), R]));
            }
        }
        // PBAR: "DONE TOTAL", drawn as a bar in the blank row
        let bar_m = crate::collect::m("^([0-9]+) ([1-9][0-9]*)$", bar);
        if bar_m {
            let sp = bar.iter().position(|&x| x == b' ').unwrap();
            let (pd, pt) = (num(&bar[..sp]), num(&bar[sp + 1..]));
            let pl = cat(&[b" ", &bar[..sp], b"/", &bar[sp + 1..]]);
            let pw = w - 6 - blen(&pl);
            let pf = pw.wrapping_mul(pd) / pt;
            let pon = c.rep("█".as_bytes(), pf);
            let poff = c.rep("░".as_bytes(), pw - pf);
            o.extend(cat(&[&at(top + 2 + n, left), bg, BWHT, "║  ".as_bytes(), BCYN, &pon, CYN, &poff, BWHT, &pl, "  ║".as_bytes(), R, GRY, "░".as_bytes(), R]));
        } else {
            o.extend(cat(&[&at(top + 2 + n, left), bg, BWHT, "║".as_bytes(), &blank, "║".as_bytes(), R, GRY, "░".as_bytes(), R]));
        }
        let f = c.fld(&self.hint, w - 4);
        o.extend(cat(&[&at(top + 3 + n, left), bg, BWHT, "║ ".as_bytes(), BCYN, &f, BWHT, " ║".as_bytes(), R, GRY, "░".as_bytes(), R]));
        let rep = c.rep("═".as_bytes(), w - 2);
        o.extend(cat(&[&at(top + 4 + n, left), bg, BWHT, "╚".as_bytes(), &rep, "╝".as_bytes(), R, GRY, "░".as_bytes(), R]));
        let rep = c.rep("░".as_bytes(), w);
        o.extend(cat(&[&at(top + 5 + n, left + 1), GRY, &rep, R]));
        o
    }

    /// pick_box's case on a key: None, go on (drawn again); Some((status, PICKED, PKEY))
    pub fn key(&mut self, k: PKey, pkeys: &[u8], pkrows: &[u8]) -> Option<(i32, Option<usize>, Bytes)> {
        let up = |s: &mut PickBox| {
            let n = s.num[s.sel].unwrap_or(0);
            if n > 0 {
                s.sel = s.ch[n - 1];
            }
        };
        let down = |s: &mut PickBox| {
            let n = s.num[s.sel].unwrap_or(0);
            if n + 1 < s.ch.len() {
                s.sel = s.ch[n + 1];
            }
        };
        match k {
            PKey::Tick(items) => self.items = items,
            PKey::Close => return Some((1, None, vec![])),
            PKey::Esc(rest) => match rest.as_slice() {
                b"" => return Some((1, None, vec![])), // a lone Esc closes the window
                b"[A" => up(self),
                b"[B" => down(self),
                _ => {}
            },
            PKey::Ch(k) => match k.as_slice() {
                b"q" | b"Q" => return Some((1, None, vec![])),
                b"k" => up(self),
                b"j" => down(self),
                [d @ b'1'..=b'9'] => {
                    let i = (d - b'1') as usize;
                    if i < self.ch.len() {
                        self.sel = self.ch[i];
                        return Some((0, Some(self.sel), vec![]));
                    }
                }
                b"" => return Some((0, Some(self.sel), vec![])), // Enter
                _ => {
                    // [[ ${#k} == 1 && -n $PKEYS && $PKEYS == *"${k,,}"* ]], on a row PKROWS lists
                    let lk = k.to_ascii_lowercase();
                    if blen(&k) != 1 || pkeys.is_empty() || !sh::contains(pkeys, &lk) {
                        return None;
                    }
                    if !sh::contains(pkrows, &cat(&[b" ", &itoa(self.sel as i64), b" "])) {
                        return None;
                    }
                    return Some((0, Some(self.sel), lk));
                }
            },
        }
        None
    }
}

/// $((PSEL)) as an index: digits only, else none
fn num_of(s: &[u8]) -> i64 {
    if crate::collect::m("^[0-9]{1,9}$", s) {
        num(s)
    } else {
        -1
    }
}

// ------------------------------------------------------------------ ask

/// ask's line, as each pass of its loop prints it: the prompt and the end of what's typed on
/// the bottom row, the cursor shown after it
pub fn ask_line(prompt: &[u8], reply: &[u8], rows: i64, cols: i64) -> Bytes {
    // Show the end of what's typed if it's longer than the line.
    let room = (cols - blen(prompt) - 26).max(10);
    let mut show = reply.to_vec();
    if blen(&show) > room {
        show = cat(&["…".as_bytes(), &substr(&show, -(room - 1), None).unwrap_or_default()]);
    }
    cat(&[
        &at(rows, 1),
        b"\x1b[2K  ",
        B,
        BYEL,
        prompt,
        R,
        b" ",
        &show,
        GRY,
        "▏ Enter sends · Esc cancels".as_bytes(),
        R,
        &at(rows, 4 + blen(prompt) + blen(&show)),
        b"\x1b[?25h",
    ])
}

/// [[:cntrl:]] for one character read: C0, DEL, and the C1 controls
fn cntrl(k: &[u8]) -> bool {
    match k {
        [c] => *c < 0x20 || *c == 0x7f,
        [0xc2, c] => (0x80..=0x9f).contains(c),
        _ => false,
    }
}

/// A key as ask's loop has it
#[derive(Debug, Clone)]
pub enum AKey {
    Ch(Bytes),
    /// Esc, and whether a character followed within 0.05 s
    Esc(bool),
    /// Ctrl-C, or the input closed
    Cancel,
}

/// ask's case on a key: None, go on; Some(ok)
pub fn ask_key(reply: &mut Bytes, k: AKey) -> Option<bool> {
    match k {
        AKey::Cancel => Some(false),
        AKey::Esc(more) => (!more).then_some(false), // a lone Esc backs out; a sequence is ignored
        AKey::Ch(k) => {
            match k.as_slice() {
                b"" => return Some(true), // Enter
                b"\x7f" | b"\x08" => {
                    // REPLY=${REPLY%?}
                    let n = blen(reply);
                    if n > 0 {
                        *reply = substr(reply, 0, Some(n - 1)).unwrap_or_default();
                    }
                }
                b"\x15" => reply.clear(), // Ctrl-U clears the line
                _ if cntrl(&k) => {}
                _ => reply.extend_from_slice(&k),
            }
            None
        }
    }
}

// ------------------------------------------------------------------ the wait

impl Ui {
    /// The panel's wait: what the main loop does between keys (signals, what the collectors
    /// left, the tick, a frame due), until a key waits (KEYS), JOB is poked, DL passes, or Ctrl-C
    /// comes while a box is up.
    pub(super) fn pump(&mut self, keys: bool, job: RawFd, dl: Option<Instant>) -> Woke {
        loop {
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
                self.paint();
            }
            // How long to wait: for the deadline, for a frame due, for the clock's tick.
            let mut until: Option<Instant> = dl;
            if self.want_draw {
                until = Some(until.map_or(self.draw_at, |u| u.min(self.draw_at)));
            }
            if let Some(t) = self.tick_at {
                until = Some(until.map_or(t, |u| u.min(t)));
            }
            let now = Instant::now();
            let ms: libc::c_int = match until {
                None => -1,
                Some(t) => t.saturating_duration_since(now).as_millis().min(i32::MAX as u128) as libc::c_int,
            };
            // Keys are read once the first look is in (bash reads none while it gathers).
            let mut fds = [
                libc::pollfd { fd: self.sig_r, events: libc::POLLIN, revents: 0 },
                libc::pollfd { fd: self.wake_r, events: libc::POLLIN, revents: 0 },
                libc::pollfd { fd: if keys && self.started { 0 } else { -1 }, events: libc::POLLIN, revents: 0 },
                libc::pollfd { fd: job, events: libc::POLLIN, revents: 0 },
            ];
            let r = unsafe { libc::poll(fds.as_mut_ptr(), 4, ms) };
            if r < 0 && std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted {
                self.quit(1);
            }
            let mut intr = false;
            if r > 0 && fds[0].revents != 0 {
                for b in term::drain(self.sig_r) {
                    match b {
                        b'X' => self.quit(0),
                        // Ctrl-C: a box up closes (trap 'INTR=1' INT); otherwise the panel ends
                        b'I' if self.modal_on => intr = true,
                        b'I' => self.quit(0),
                        _ => {
                            // WINCH: all of it drawn again, at the new size
                            term::out(b"\x1b[2J");
                            self.prev.clear();
                            self.c.p.atop.clear();
                            self.want_draw = true;
                            self.draw_at = Instant::now();
                        }
                    }
                }
            }
            if r > 0 && fds[1].revents != 0 {
                term::drain(self.wake_r);
                self.take();
            }
            if r > 0 && fds[2].revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0 {
                self.quit(0); // the terminal is gone
            }
            if intr {
                return Woke::Intr;
            }
            if r > 0 && fds[3].revents != 0 {
                return Woke::Job;
            }
            if r > 0 && fds[2].revents & libc::POLLIN != 0 {
                return Woke::Key;
            }
            if dl.is_some_and(|d| Instant::now() >= d) {
                return Woke::Time;
            }
        }
    }

    /// One byte from the terminal by DL, the panel going on meanwhile
    fn mbyte(&mut self, dl: Instant) -> Result<u8, Rd> {
        use super::keys::Src;
        loop {
            match self.pump(true, -1, Some(dl)) {
                Woke::Key => {
                    if let Some(b) = term::Stdin.byte(Duration::ZERO) {
                        return Ok(b);
                    }
                    if term::GONE.load(std::sync::atomic::Ordering::Relaxed) {
                        return Err(Rd::Gone);
                    }
                }
                Woke::Time => return Err(Rd::Time),
                Woke::Intr => return Err(Rd::Intr),
                Woke::Job => {}
            }
        }
    }

    /// `IFS= read -rsn N -t T`: up to N characters within T in all, stopping at a newline.
    /// -> (what was read, Ok or why it stopped short); a newline read is Ok with what came before
    pub(super) fn mread(&mut self, n: usize, t: Duration) -> (Bytes, Rd) {
        let dl = Instant::now() + t;
        let mut got: Bytes = Vec::new();
        for _ in 0..n {
            let first = match self.mbyte(dl) {
                Ok(b) => b,
                Err(e) => return (got, e),
            };
            if first == b'\n' {
                return (got, Rd::Ch(vec![]));
            }
            got.push(first);
            let more = match first {
                0xc2..=0xdf => 1,
                0xe0..=0xef => 2,
                0xf0..=0xf4 => 3,
                _ => 0,
            };
            for _ in 0..more {
                match self.mbyte(dl.max(Instant::now() + super::keys::SEQ_WAIT)) {
                    Ok(b) => got.push(b),
                    Err(_) => break,
                }
            }
        }
        (got, Rd::Ch(vec![]))
    }

    /// `until IFS= read -rsn1 -t 0.2 k; do …; done`: one character (Rd::Ch, "" for Enter), or
    /// why there is none. TICK, when given, runs after each 0.2 s that passes with no key.
    fn mkey<'t>(&mut self, mut tick: Option<&mut (dyn FnMut(&mut Ui) -> Option<Vec<Bytes>> + 't)>) -> Result<Bytes, Result<Vec<Bytes>, Rd>> {
        loop {
            match self.mread(1, Duration::from_millis(200)) {
                (k, Rd::Ch(_)) => return Ok(k),
                (_, Rd::Time) => {
                    if let Some(t) = tick.as_deref_mut() {
                        if let Some(items) = t(self) {
                            return Err(Ok(items));
                        }
                    }
                }
                (_, e) => return Err(Err(e)),
            }
        }
    }

    /// The box over the panel now, painted at once (inside ?2026) when it changed; draw paints
    /// it again over every frame while it's up
    pub(super) fn over(&mut self, b: Bytes) {
        if self.over.as_ref() == Some(&b) {
            return;
        }
        term::out(&cat(&[b"\x1b[?2026h", &b, b"\x1b[?2026l"]));
        self.over = Some(b);
    }

    /// A command that can take a while, on a thread of its own while the panel keeps drawing;
    /// keys wait for after it, as in bash. Ctrl-C meanwhile ends the panel, as bash's does.
    pub(super) fn wait_job<T: Send + 'static>(&mut self, f: impl FnOnce() -> T + Send + 'static) -> T {
        let (r, w) = term::pipe();
        let slot: Arc<Mutex<Option<T>>> = Arc::new(Mutex::new(None));
        let s2 = slot.clone();
        std::thread::spawn(move || {
            let v = f();
            *s2.lock().unwrap() = Some(v);
            term::poke(w);
            unsafe { libc::close(w) };
        });
        loop {
            if let Some(v) = slot.lock().unwrap().take() {
                unsafe { libc::close(r) };
                return v;
            }
            if self.pump(false, r, None) == Woke::Job {
                term::drain(r);
            }
        }
    }

    // ------------------------------------------------------------------ the boxes

    /// pick TITLE ITEM...: a BBS-style popup over the panel, a blue double-line box with a
    /// shaded shadow, listing ITEMs. ↑↓ (j k) or 1-9 choose, Enter picks (-> PICKED, the index),
    /// Esc or q closes it (false). Ctrl-C closes it too. An ITEM starting with NOTE is a line to
    /// read (a heading, some words), not a choice: unnumbered, and never picked.
    pub fn pick(&mut self, o: &mut PickOpts, title: &[u8], items: &[Bytes]) -> bool {
        let mut args: Vec<&[u8]> = vec![b"pick", title];
        args.extend(items.iter().map(|i| i.as_slice()));
        if self.box_answered(&args) {
            // read -r PICKED PKEY <<<"$BOX_ANS"
            let f = sh::read_ws(&self.bx.ans, 2, b" \t\n");
            self.picked = f[0].clone();
            self.pkey = f[1].clone();
            return self.bx.rc == 0;
        }
        // local re=${BOX_RE%% *}: the item picked, gone back to
        let re: Bytes = self.bx.re.split(|&c| c == b' ').next().unwrap_or(b"").to_vec();
        let psel = if re.is_empty() { o.sel.clone() } else { re };
        let st = self.pick_box(o, &psel, title, items);
        let ans = cat(&[&self.picked, b" ", &self.pkey]);
        self.box_out(st, &ans, false) == 0
    }

    /// pick_box TITLE ITEM...: the box and its loop -> 0 picked, 1 closed
    fn pick_box(&mut self, o: &mut PickOpts, psel: &[u8], title: &[u8], items: &[Bytes]) -> i32 {
        self.pkey.clear();
        let (rows, cols) = tsize();
        let Some(mut pb) = PickBox::new(title, items, o.hint.as_deref(), psel, rows, cols) else { return 1 };
        self.modal_on = true;
        let st = loop {
            let bar = o.bar.map(|f| f(self)).unwrap_or_default();
            let b = pb.paint(&self.c, &bar);
            self.over(b);
            let k = match self.mkey(o.tick.as_deref_mut()) {
                Ok(k) => PKey::Ch(k),
                Err(Ok(items)) => PKey::Tick(items),
                Err(Err(_)) => PKey::Close,
            };
            let k = match k {
                PKey::Ch(k) if k == b"\x1b" => {
                    let (rest, _) = self.mread(2, Duration::from_millis(50));
                    PKey::Esc(rest)
                }
                k => k,
            };
            if let Some((st, picked, pkey)) = pb.key(k, &o.keys, &o.krows) {
                if let Some(p) = picked {
                    self.picked = itoa(p as i64);
                    self.pkey = pkey;
                }
                break st;
            }
        };
        self.modal_on = false;
        self.over = None;
        st
    }

    /// ask PROMPT -> REPLY on the bottom line. Enter accepts; Esc, Ctrl-C or an empty line backs
    /// out (false)
    pub fn ask(&mut self, prompt: &[u8]) -> bool {
        if self.box_answered(&[b"ask", prompt]) {
            self.reply = self.bx.ans.clone();
            return self.bx.rc == 0;
        }
        let (rows, cols) = tsize();
        let mut reply = self.bx.re.clone();
        self.modal_on = true;
        let ok = loop {
            self.over(ask_line(prompt, &reply, rows, cols));
            let k = match self.mkey(None) {
                Ok(k) if k == b"\x1b" => {
                    // A lone Esc backs out; an arrow or other key sequence is just ignored.
                    let (rest, _) = self.mread(1, Duration::from_millis(50));
                    if !rest.is_empty() {
                        self.mread(4, Duration::from_millis(20));
                    }
                    AKey::Esc(!rest.is_empty())
                }
                Ok(k) => AKey::Ch(k),
                Err(_) => AKey::Cancel,
            };
            if let Some(ok) = ask_key(&mut reply, k) {
                break ok;
            }
        };
        self.modal_on = false;
        self.over = None;
        term::out(&cat(&[b"\x1b[?25l", &at(rows, 1), b"\x1b[2K"]));
        if ok && !reply.is_empty() {
            self.reply = reply.clone();
            return self.box_out(0, &reply, false) == 0;
        }
        self.reply.clear();
        self.box_out(1, b"", false);
        false
    }

    /// note TITLE LINE...: a box over the panel, drawn as pick's, until a key is pressed
    pub fn note(&mut self, title: &[u8], lines: &[Bytes]) -> bool {
        let mut args: Vec<&[u8]> = vec![b"note", title];
        args.extend(lines.iter().map(|l| l.as_slice()));
        if self.box_answered(&args) {
            return self.bx.rc == 0;
        }
        let b = self.note_box(title, b"press any key to close", lines);
        self.modal_on = true;
        self.over(b);
        let _ = self.mkey(None);
        // The rest of a key sequence (an arrow) goes too.
        self.mread(4, Duration::from_millis(20));
        self.modal_on = false;
        self.over = None;
        self.box_out(0, b"", false) == 0
    }

    /// note_box TITLE HINT LINE...: note's box at the terminal's size (tput), as bash's live one
    pub fn note_box(&mut self, title: &[u8], hint: &[u8], lines: &[Bytes]) -> Bytes {
        let (rows, cols) = tsize();
        let (tc, tl) = (self.c.p.tcols, self.c.p.tlines);
        self.c.p.tcols = cols;
        self.c.p.tlines = rows;
        let b = self.c.note_box(title, hint, lines);
        self.c.p.tcols = tc;
        self.c.p.tlines = tl;
        b
    }
}

/// `ARGV 2>&1 | head -n 1`, with ENVS, stdin /dev/null: its stdout and stderr in one pipe, read
/// up to the end of its first line, and the pipe closed then as head's exit closes it (what it
/// writes after gets SIGPIPE). A child it leaves running with the pipe open doesn't hold this up.
pub fn run_first_line(argv: &[Bytes], envs: &[(&str, Bytes)]) -> Bytes {
    use std::io::Read;
    use std::os::fd::FromRawFd;
    let mut p = [0 as libc::c_int; 2];
    // close-on-exec: no other command started meanwhile (a collector's) keeps the pipe open
    if unsafe { libc::pipe2(p.as_mut_ptr(), libc::O_CLOEXEC) } != 0 {
        return Vec::new();
    }
    let (r, w) = unsafe { (std::fs::File::from_raw_fd(p[0]), std::os::fd::OwnedFd::from_raw_fd(p[1])) };
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
    if let Ok(mut ch) = ch {
        let mut r = r;
        let mut b = [0u8; 1];
        while let Ok(1) = r.read(&mut b) {
            out.push(b[0]);
            if b[0] == b'\n' {
                break;
            }
        }
        drop(r);
        let _ = ch.wait();
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::collect::gather::tests::bash_fn;
    use crate::compat::tests::{bash, setup};
    use crate::render::prim::tests::bash_prims;

    fn bash_with(body: &str, args: &[&[u8]]) -> Bytes {
        let s = format!("{}\nNOTE=$'\\x1f'\ntput() {{ case $1 in lines) echo 30 ;; cols) echo 100 ;; esac; }}\n{}", bash_prims(), body);
        bash(&s, args)
    }

    fn b(v: &[&str]) -> Vec<Bytes> {
        v.iter().map(|s| s.as_bytes().to_vec()).collect()
    }

    /// pick_box against bash's, painted as each key comes and the box closes: the same bytes,
    /// and the same PICKED and PKEY
    #[test]
    fn pick_box_as_bash() {
        setup();
        let c = Ctx::new();
        let items = b(&["\x1fThis session will restore even after reboot.", "No, stay", "Yes, detach"]);
        let many: Vec<Bytes> = (0..12).map(|i| format!("item {} ±é", i).into_bytes()).collect();
        let cases: Vec<(&str, Vec<Bytes>, &str, &str, &str, &str, &str, Vec<PKey>)> = vec![
            ("DETACH TMUX?", items.clone(), "", "", "", "", "", vec![PKey::Close]),
            ("DETACH TMUX?", items.clone(), "\x1b", "", "", "", "", vec![PKey::Esc(vec![])]),
            ("DETACH TMUX?", items.clone(), "j\n", "", "", "", "", vec![PKey::Ch(b"j".to_vec()), PKey::Ch(vec![])]),
            ("DETACH TMUX?", items.clone(), "2", "", "", "", "", vec![PKey::Ch(b"2".to_vec())]),
            ("DETACH TMUX?", items.clone(), "\x1b[B\x1b[Bk\x1b[A9q", "", "", "", "", vec![
                PKey::Esc(b"[B".to_vec()), PKey::Esc(b"[B".to_vec()), PKey::Ch(b"k".to_vec()), PKey::Esc(b"[A".to_vec()), PKey::Ch(b"9".to_vec()), PKey::Ch(b"q".to_vec()),
            ]),
            ("UPDATE", many.clone(), "jjjjjjjjjjJu", "u", " 0 3 11 ", "↑↓ choose · I: command · Esc closes", "11", vec![
                PKey::Ch(b"j".to_vec()); 10
            ].into_iter().chain([PKey::Ch(b"J".to_vec()), PKey::Ch(b"u".to_vec())]).collect()),
            ("UPDATE", many.clone(), "x", "x", " 0 ", "", "3", vec![PKey::Ch(b"x".to_vec()), PKey::Close]),
            ("A TITLE MUCH LONGER THAN ANY OF THE ITEMS IN IT, ±", b(&["a", "\x1fnote", "b"]), "j\n", "", "", "", "1", vec![PKey::Ch(b"j".to_vec()), PKey::Ch(vec![])]),
        ];
        for (title, items, keys, pkeys, pkrows, hint, psel, ks) in cases {
            let mut args: Vec<&[u8]> = vec![keys.as_bytes(), pkeys.as_bytes(), pkrows.as_bytes(), hint.as_bytes(), psel.as_bytes(), title.as_bytes()];
            args.extend(items.iter().map(|i| i.as_slice()));
            let body = format!(
                "{}\nk=$1 PKEYS=$2 PKROWS=$3 PHINT=$4 PSEL=$5; shift 5\nPICKED=- PKEY=-\npick_box \"$@\" < <(printf %s \"$k\"); st=$?\nprintf '\\n--%s %s %s\\n' \"$st\" \"$PICKED\" \"$PKEY\"",
                bash_fn("pick_box")
            );
            let theirs = bash_with(&body, &args);
            let mut pb = PickBox::new(title.as_bytes(), &items, Some(hint.as_bytes()), psel.as_bytes(), 30, 100).unwrap();
            let mut ours: Bytes = Vec::new();
            let mut end = None;
            for k in ks {
                ours.extend(pb.paint(&c, b""));
                if let Some(e) = pb.key(k, pkeys.as_bytes(), pkrows.as_bytes()) {
                    end = Some(e);
                    break;
                }
            }
            let (st, p, k) = end.expect("the box closed");
            let p = p.map(|p| p.to_string()).unwrap_or("-".into());
            let k = String::from_utf8_lossy(&k).into_owned();
            ours.extend(format!("\n--{} {} {}\n", st, p, k).into_bytes());
            assert_eq!(String::from_utf8_lossy(&ours), String::from_utf8_lossy(&theirs), "{} keys {:?}", title, keys);
        }
    }

    /// PBAR's bar in the blank row, and a PTICK's new items, as bash's
    #[test]
    fn pick_bar_and_tick_as_bash() {
        setup();
        let c = Ctx::new();
        let items = b(&["one", "two"]);
        for bar in ["3 7", "0 5", "9 9", "x", "4 0"] {
            let body = format!(
                "{}\nBAR=$1; shift; PBAR=BAR pick_box T \"$@\" </dev/null",
                bash_fn("pick_box")
            );
            let theirs = bash_with(&format!("{}; :", body), &[bar.as_bytes(), b"one", b"two"]);
            let pb = PickBox::new(b"T", &items, None, b"", 30, 100).unwrap();
            assert_eq!(String::from_utf8_lossy(&pb.paint(&c, bar.as_bytes())), String::from_utf8_lossy(&theirs), "bar {}", bar);
        }
        // PTICK: the items swapped for PITEMS, drawn again
        let body = format!(
            "{}\nn=0; tk() {{ ((n++ == 0)) && PITEMS=(uno dos) && return 0; return 1; }}\nPTICK=tk pick_box T one two < <(sleep 0.5); :",
            bash_fn("pick_box")
        );
        let theirs = bash_with(&body, &[]);
        let mut pb = PickBox::new(b"T", &items, None, b"", 30, 100).unwrap();
        let mut ours = pb.paint(&c, b"");
        pb.key(PKey::Tick(b(&["uno", "dos"])), b"", b"");
        ours.extend(pb.paint(&c, b""));
        assert_eq!(String::from_utf8_lossy(&ours), String::from_utf8_lossy(&theirs));
    }

    /// ask's line against bash's, as each key comes, and what it ends with
    #[test]
    fn ask_as_bash() {
        setup();
        let long = "a".repeat(120);
        let cases: Vec<(&str, String, Vec<AKey>)> = vec![
            ("New name for asker:", "top\n".into(), vec![AKey::Ch(b"t".to_vec()), AKey::Ch(b"o".to_vec()), AKey::Ch(b"p".to_vec()), AKey::Ch(vec![])]),
            ("New name for asker:", "\x1b".into(), vec![AKey::Esc(false)]),
            ("New name for asker:", "ab\x7fé\x15xy\x01z\x1b[A".into(), vec![
                AKey::Ch(b"a".to_vec()), AKey::Ch(b"b".to_vec()), AKey::Ch(b"\x7f".to_vec()), AKey::Ch("é".as_bytes().to_vec()), AKey::Ch(b"\x15".to_vec()),
                AKey::Ch(b"x".to_vec()), AKey::Ch(b"y".to_vec()), AKey::Ch(b"\x01".to_vec()), AKey::Ch(b"z".to_vec()), AKey::Esc(true), AKey::Cancel,
            ]),
            ("New name for far-top on far.example:", format!("{}\n", long), long.bytes().map(|c| AKey::Ch(vec![c])).chain([AKey::Ch(vec![])]).collect()),
            ("Q:", "\n".into(), vec![AKey::Ch(vec![])]),
            ("Q:", "ab".into(), vec![AKey::Ch(b"a".to_vec()), AKey::Ch(b"b".to_vec()), AKey::Cancel]),
        ];
        for (prompt, keys, ks) in cases {
            let body = format!(
                "{}\nbox_answered() {{ BOX_RE=''; return 1; }}\nbox_out() {{ return $1; }}\nask \"$1\" < <(printf %s \"$2\"); st=$?\nprintf '\\n--%s %s\\n' \"$st\" \"$REPLY\"",
                bash_fn("ask")
            );
            let theirs = bash_with(&body, &[prompt.as_bytes(), keys.as_bytes()]);
            let mut reply = Vec::new();
            let mut ours: Bytes = Vec::new();
            let mut ok = None;
            for k in ks {
                ours.extend(ask_line(prompt.as_bytes(), &reply, 30, 100));
                if let Some(o) = ask_key(&mut reply, k) {
                    ok = Some(o);
                    break;
                }
            }
            let ok = ok.expect("ask ended");
            ours.extend(cat(&[b"\x1b[?25l", &at(30, 1), b"\x1b[2K"]));
            let (st, r) = if ok && !reply.is_empty() { (0, reply) } else { (1, vec![]) };
            ours.extend(format!("\n--{} {}\n", st, String::from_utf8_lossy(&r)).into_bytes());
            assert_eq!(String::from_utf8_lossy(&ours), String::from_utf8_lossy(&theirs), "{} {:?}", prompt, keys);
        }
    }

    /// note's box (note_box, not NB_ONLY: at tput's size) as bash's
    #[test]
    fn note_box_as_bash() {
        setup();
        let mut c = Ctx::new();
        c.p.tcols = 100;
        c.p.tlines = 30;
        for (title, lines) in [("UPDATED", b(&["a line", "and another, ±é"])), ("", b(&["one"])), ("A TITLE", b(&[&"x".repeat(150)]))] {
            let mut args: Vec<&[u8]> = vec![title.as_bytes()];
            args.extend(lines.iter().map(|l| l.as_slice()));
            let theirs = bash_with(&format!("{}\nnote_box \"$1\" 'press any key to close' \"${{@:2}}\"", bash_fn("note_box")), &args);
            assert_eq!(String::from_utf8_lossy(&c.note_box(title.as_bytes(), b"press any key to close", &lines)), String::from_utf8_lossy(&theirs), "{}", title);
        }
    }

    #[test]
    fn a_command_and_its_errors_in_one_pipe() {
        let out = run_first_line(&[b"bash".to_vec(), b"-c".to_vec(), b"echo \"$X\" >&2; echo out".to_vec()], &[("X", b"x".to_vec())]);
        assert_eq!(out, b"x\n", "stderr in the same pipe");
        // a child left running with the pipe open doesn't hold it up
        let t = std::time::Instant::now();
        let out = run_first_line(&[b"bash".to_vec(), b"-c".to_vec(), b"sleep 5 & echo first; echo second".to_vec()], &[]);
        assert_eq!(out, b"first\n");
        assert!(t.elapsed() < std::time::Duration::from_secs(3));
    }
}
