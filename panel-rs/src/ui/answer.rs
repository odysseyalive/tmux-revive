//! Answering a question (plan Phase 5): scripts/panel.sh's answer, free_answer, q_fresh,
//! question_look, question_free, send_answer, paste_answer, keys_send, paste_send, key_ok,
//! lit_tokens, paste_ok and paste_hex, ported line for line, without freezing the page.
//!
//! Enter on an asking pane freezes its target, (host, P_ID, P_RID) and its name, and starts one
//! send worker for it, a thread that owns the question's state (QFREE, QFREEN, QFTXT, QON, QEMPTY,
//! QHAS, QCUR, QASK, QLAST) and runs answer()'s whole loop: it reads the keys from the terminal
//! itself, in order and with answer()'s own timeouts (the UI thread reads none meanwhile), turns
//! them into tokens by answer()'s rules, sends them to the frozen pane, and looks at it every
//! 40 ms for 12 looks after a send, else every 0.3 s. Every decision that turns on the screen
//! after the keys just sent (the Enter guard, free_answer's steps) is made there, in order with
//! the sends. Each look is published for the UI to draw. The UI thread meanwhile goes on as it
//! does under any box (Ui::pump): PANES, the clock and the art keep moving, the plan's one
//! intended change from bash's frozen ATOP. free_answer's box is the UI's: the worker asks for
//! it and waits for its text (or none, closed), reading no keys while it is up.

use super::boxes::BoxHost;
use super::modal::{Rd, Woke};
use super::{term, Ui};
use crate::collect::links::{remote_run, LinkCfg};
use crate::collect::sh::{self, Bytes};
use crate::collect::{agents::lines_state, m, G, HOST_RE};
use crate::compat::{blen, chars, clean, is_cntrl, is_space, re, substr};
use crate::render::{cat, AnsPane};
use std::collections::VecDeque;
use std::os::fd::RawFd;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

// ------------------------------------------------------------------ the checks

/// KEY_RE: the tmux key names a question may be sent. No Escape: in Claude Code's question it
/// cancels, and the agent is told you declined.
pub const KEY_RE: &str = "^(Up|Down|Left|Right|Home|End|PPage|NPage|IC|DC|Enter|Tab|BTab|BSpace|Space|C-[a-z])$";

/// PASTE_MAX: a written answer's bytes at most
pub const PASTE_MAX: usize = 40000;

/// PASTE_SINCE: the first tmux-revive with --paste (an older one would start a panel instead)
pub const PASTE_SINCE: &[u8] = b"1.2.26";

/// Two hex digits each -> the bytes (the caller has checked they are hex)
fn unhex(h: &[u8]) -> Bytes {
    h.chunks(2).map(|p| u8::from_str_radix(std::str::from_utf8(p).unwrap_or("00"), 16).unwrap_or(0)).collect()
}

/// `od -An -v -tx1 | tr -d ' \n'`
pub fn hex(b: &[u8]) -> Bytes {
    b.iter().flat_map(|c| format!("{:02x}", c).into_bytes()).collect()
}

/// key_ok TOKEN: may it be sent? Some(LIT): a lit: token's text (64 characters at most), or ""
/// for a key name; None: no.
pub fn key_ok(t: &[u8]) -> Option<Bytes> {
    if re(KEY_RE).is_match(t) {
        return Some(Vec::new());
    }
    let h = t.strip_prefix(b"lit:")?;
    if !re("^([0-9a-f]{2}){1,192}$").is_match(h) {
        return None;
    }
    // no C0 controls (NUL least of all), no DEL
    if h.chunks(2).any(|p| p[0] == b'0' || p[0] == b'1' || p == b"7f") {
        return None;
    }
    let lit = unhex(h);
    // and no C1 controls, bidi overrides or zero-width characters
    (!lit.is_empty() && clean(&lit) == lit && blen(&lit) <= 64).then_some(lit)
}

/// lit_tokens TEXT -> TOKS: typed text as lit: tokens, 32 characters each
pub fn lit_tokens(t: &[u8]) -> Vec<Bytes> {
    let mut v = Vec::new();
    let mut t = t.to_vec();
    while !t.is_empty() {
        let x = substr(&t, 0, Some(32)).unwrap_or_default();
        v.push(cat(&[b"lit:", &hex(&x)]));
        t = substr(&t, 32, None).unwrap_or_default();
    }
    v
}

/// paste_hex HEX -> ESC's text: None on a control character but LF and tab, or DEL
pub fn paste_hex(h: &[u8]) -> Option<Bytes> {
    // [[ $1 =~ ^(..)*(0[0-8]|0[b-f]|1.|7f) ]]: a pair at an even place that is one
    if re("^(..)*(0[0-8]|0[b-f]|1.|7f)").is_match(h) {
        return None;
    }
    Some(unhex(h))
}

/// paste_ok HEX: may it be pasted? Its text (PASTE)
pub fn paste_ok(h: &[u8]) -> Option<Bytes> {
    if !(h.len() >= 2 && h.len() % 2 == 0 && h.len() <= 2 * PASTE_MAX && re("^[0-9a-f]+$").is_match(h)) {
        return None;
    }
    let paste = paste_hex(h)?;
    // No C1 controls, bidi overrides or zero-width characters (clean), and something to paste.
    let t: Bytes = paste.iter().copied().filter(|&c| c != b'\t' && c != b'\n').collect();
    (clean(&t) == t && chars(&paste).any(|c| !is_space(c))).then_some(paste)
}

// ------------------------------------------------------------------ the question's state

/// What answer() keeps of the question while it runs: the last look (QL, QRAW, QSHOT), what
/// question_free and q_fresh made of it, and what the panel last wrote in (QLAST)
#[derive(Default, Clone, Debug)]
pub struct Q {
    pub ql: Vec<Bytes>,
    pub qraw: Vec<Bytes>,
    pub qshot: Bytes,
    pub qfree: bool,
    pub qfreen: Bytes,
    pub qftxt: Bytes,
    pub qon: bool,
    pub qempty: bool,
    pub qhas: bool,
    pub qcur: Bytes,
    pub qask: bool,
    pub qlast: Bytes,
}

/// question_free -> QFREE, QFREEN, QON, QEMPTY, QHAS, QCUR, QFTXT: the question's free-text
/// choice ("5. Type something.", "3. [ ] Type something", or the one before "Chat about this"),
/// as this look sees it. QFREE, once set, stays.
pub fn question_free(q: &mut Q) {
    let ph_re = re(r"^[[:space:]│]*(❯[[:space:]]*)?([0-9]+)\.[[:space:]]*(\[.\][[:space:]]*)?Type something\.?[[:space:]]*$");
    let chat_re = re(r"^[[:space:]│]*(❯[[:space:]]*)?([0-9]+)\.[[:space:]]*Chat about this");
    let num_re = re(r"^[[:space:]│]*(❯[[:space:]]*)?([0-9]+)\.");
    let cur_re = re("^[[:space:]│]*❯");
    let curn_re = re(r"^[[:space:]│]*❯[[:space:]]*([0-9]+)\.");
    let one_re = re(r"^[[:space:]│]*(❯[[:space:]]*)?1\.[[:space:]]");
    let (mut cur, mut ph, mut chat): (Option<Bytes>, Bytes, Bytes) = (None, Vec::new(), Vec::new());
    let mut nums: Bytes = b" ".to_vec();
    for l in q.ql.iter().rev() {
        if let Some(g) = ph_re.matches(l) {
            ph = g[2].clone();
        } else if let Some(g) = chat_re.matches(l) {
            chat = g[2].clone();
        }
        if let Some(g) = num_re.matches(l) {
            nums.extend_from_slice(&g[2]);
            nums.push(b' ');
        }
        if cur.is_none() && cur_re.is_match(l) {
            cur = Some(curn_re.matches(l).map(|g| g[1].clone()).unwrap_or_else(|| b"x".to_vec()));
        }
        if one_re.is_match(l) {
            break;
        }
    }
    let chat_n = crate::render::num(&chat);
    if !ph.is_empty() {
        q.qfree = true;
        q.qfreen = ph.clone();
    } else if !chat.is_empty() && chat_n > 1 {
        q.qfree = true;
        q.qfreen = (chat_n - 1).to_string().into_bytes();
    } else {
        q.qfreen.clear();
    }
    let cur = cur.unwrap_or_default();
    q.qon = !q.qfreen.is_empty() && cur == q.qfreen;
    q.qempty = !ph.is_empty() && ph == q.qfreen;
    q.qhas = !q.qfreen.is_empty() && sh::contains(&nums, &cat(&[b" ", &q.qfreen, b" "]));
    q.qcur = cur;
    // QFTXT: what its row says (an answer in it, or the label).
    q.qftxt.clear();
    if !q.qhas {
        return;
    }
    let txt_re = re(r"^[[:space:]│]*(❯[[:space:]]*)?([0-9]+)\.[[:space:]]*(\[.\][[:space:]]*)?(.*[^[:space:]])[[:space:]]*$");
    for l in q.ql.iter().rev() {
        if let Some(g) = txt_re.matches(l) {
            if g[2] == q.qfreen {
                q.qftxt = g[4].clone();
                break;
            }
        }
    }
}

// ------------------------------------------------------------------ the keys, the pane

/// The terminal as answer() reads it: `IFS= read -rsn1 -t T` (a character, "" for a newline),
/// and `read -t 0`
pub trait Keys {
    fn ch(&mut self, t: Duration) -> Result<Bytes, Rd>;
    fn ready(&mut self) -> bool;
}

/// What answer() does to the pane and the panel, apart from reading keys
pub trait AnsIo {
    /// question_look -> QL, QRAW, QSHOT
    fn look(&mut self, q: &mut Q);
    /// question_free, on a look with something new
    fn question_free(&mut self, q: &mut Q) {
        question_free(q);
    }
    /// the answered test's look: is it still asking?
    fn asking(&mut self, q: &Q) -> bool;
    /// q_fresh -> the question as it is now, looked at until it holds still; QASK; question_free
    fn q_fresh(&mut self, q: &mut Q);
    /// send_answer TOKEN...: false when it didn't get through (and the flash says why)
    fn send(&mut self, toks: &[Bytes]) -> bool;
    /// paste_answer TEXT
    fn paste(&mut self, t: &[u8]) -> bool;
    /// peek_drop: a key was just sent, the screen being asked for over the link is out of date
    fn peek_drop(&mut self);
    /// flash TEXT (empty: FLASH="")
    fn flash(&mut self, t: &[u8]);
    /// draw
    fn draw(&mut self, q: &Q);
    /// EBC=m edit_box TITLE HINT TEXT -> REPLY, or None closed; PREV=() after it
    fn edit_box(&mut self, title: &[u8], hint: &[u8], text: &[u8]) -> Option<Bytes>;
    /// EPOCHREALTIME in µs
    fn now_us(&mut self) -> i64;
}

/// How answering ended: why=left (Esc, Ctrl-], Ctrl-C, the input closed), answered (twice not
/// asking, in a row), failed (a send didn't get through)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Why {
    Left,
    Answered,
    Failed,
}

/// `[[ $k == [0-9] ]]`
fn digit(k: &[u8]) -> bool {
    matches!(k, [c] if c.is_ascii_digit())
}

/// free_answer NAME: E on a dialog with a free-text choice, or Enter on its empty row. The answer
/// is written in a box over the panel (edit_box), then put in the choice's own box as a paste,
/// newlines and all, and not sent. What the panel put there before is in the box again to
/// change; anything else there is cleared first.
pub fn free_answer(io: &mut dyn AnsIo, q: &mut Q, name: &[u8]) {
    io.q_fresh(q);
    if !(q.qask && q.qhas) {
        io.flash(b"no Type something here");
        io.draw(q);
        return;
    }
    // Its row shows the answer's lines run together, or only the first of them.
    let f: Bytes = q.qlast.iter().copied().filter(|&c| c != b'\n' && c != b'\t').collect();
    let n = blen(&q.qftxt).min(20);
    let mut t: Bytes = Vec::new();
    if !q.qempty && n > 0 && !q.qlast.is_empty() && substr(&f, 0, Some(n)) == substr(&q.qftxt, 0, Some(n)) {
        t = q.qlast.clone();
    }
    let title = cat(&["ANSWER · ".as_bytes(), name]);
    match io.edit_box(&title, "Enter done · Alt-Enter new line · Esc closes".as_bytes(), &t) {
        None => {
            io.flash(b"closed; nothing was sent");
            io.draw(q);
            return;
        }
        Some(r) => t = r,
    }
    if chars(&t).all(is_space) {
        io.flash(b"nothing written; nothing was sent");
        io.draw(q);
        return;
    }
    io.draw(q);
    // Onto its row, a row at a time (its number would tick it in a multi-select), then empty
    // it: Ctrl-K and Ctrl-U take the line after and before the cursor, or the break they're at.
    io.q_fresh(q);
    if !(q.qask && q.qhas) {
        io.flash(b"the question has gone; nothing was sent");
        io.draw(q);
        return;
    }
    let mut n = 0;
    while n < 12 && q.qask && q.qhas && !q.qon {
        let down = re("^[0-9]+$").is_match(&q.qcur) && crate::render::num(&q.qcur) < crate::render::num(&q.qfreen);
        let tok: &[u8] = if down { b"Down" } else { b"Up" };
        if !io.send(&[tok.to_vec()]) {
            return;
        }
        io.q_fresh(q);
        n += 1;
    }
    let mut n = 0;
    while n < 10 && q.qon && !q.qempty {
        let toks: Vec<Bytes> = (0..8).flat_map(|_| [b"C-k".to_vec(), b"C-u".to_vec()]).collect();
        if !io.send(&toks) {
            return;
        }
        io.q_fresh(q);
        n += 1;
    }
    if !(q.qask && q.qon && q.qempty) {
        io.flash(b"couldn't get into Type something; nothing more was sent");
        io.draw(q);
        return;
    }
    if !io.paste(&t) {
        io.draw(q);
        return;
    }
    q.qlast = t;
    io.flash(b"written in; not sent yet");
    io.draw(q);
}

/// answer()'s loop, from its first look: keys go to the question as if typed in its own console
/// (but for a free-text choice's letters, which wait for E: free_answer). The question is drawn
/// again when the agent's screen changes: looked at every 40 ms for half a second after a key is
/// sent, to show it react, and every 0.3 s otherwise. Esc, Ctrl-] (or Ctrl-C) leave without
/// sending anything; it ends by itself once the pane stops asking.
pub fn answer_loop(k: &mut dyn Keys, io: &mut dyn AnsIo, q: &mut Q, name: &[u8]) -> Why {
    let mut pend: Option<Bytes> = None;
    let mut shot: Bytes = Vec::new();
    let (mut sent, mut skips, mut idle, mut poll, mut gone) = (false, 0, false, 0, 0);
    let mut tl = 0i64;
    loop {
        // Keys already waiting behind the ones just sent go first, so they reach the agent
        // together and are drawn once; but no more than three times running, so the view
        // can't freeze.
        if sent && skips < 3 && (pend.is_some() || k.ready()) {
            skips += 1;
        } else {
            skips = 0;
            tl = io.now_us(); // when this look began
            io.look(q);
            // Drawn only when there's something new to show.
            if q.qshot != shot {
                io.question_free(q);
                io.draw(q);
                shot = q.qshot.clone();
            }
            if idle {
                // Still asking? Twice not, in a row, means answered (one look can catch a redraw).
                if io.asking(q) {
                    gone = 0;
                } else {
                    gone += 1;
                    if gone >= 2 {
                        return Why::Answered;
                    }
                }
            }
        }
        sent = false;
        idle = false;
        let key = match pend.take() {
            Some(p) => p,
            None => {
                let r = if poll > 0 {
                    // 40 ms from the start of the last look, not from its end
                    let w = (40000 - (io.now_us() - tl)).max(1000);
                    k.ch(Duration::from_micros(w as u64))
                } else {
                    k.ch(Duration::from_millis(300))
                };
                match r {
                    Ok(c) => c,
                    Err(Rd::Time) => {
                        if poll > 0 {
                            poll -= 1;
                        } else {
                            idle = true;
                        }
                        continue;
                    }
                    Err(_) => return Why::Left, // Ctrl-C, or the input closed
                }
            }
        };
        let mut toks: Vec<Bytes> = Vec::new();
        // A dialog with a free-text choice: j and k move, E opens a box to write its answer in,
        // other letters and BSpace stay here. A digit picks a choice and Space may tick one, but
        // not on the box itself, where they would be typed.
        if q.qfree && !key.is_empty() && (!is_cntrl(&key) || key == b"\x7f" || key == b"\x08") {
            match key.as_slice() {
                b"j" => toks = vec![b"Down".to_vec()],
                b"k" => toks = vec![b"Up".to_vec()],
                b"e" | b"E" => {
                    io.flash(b"");
                    free_answer(io, q, name);
                    continue;
                }
                _ if digit(&key) => {
                    if !q.qon {
                        toks = lit_tokens(&key);
                    }
                }
                b" " => {
                    if !q.qon {
                        toks = vec![b"Space".to_vec()];
                    }
                }
                _ => {
                    io.flash(b"[E]nter to type");
                    io.draw(q);
                    continue;
                }
            }
        } else {
            match key.as_slice() {
                b"\x1d" => return Why::Left, // Ctrl-]
                b"" | b"\r" | b"\n" => {
                    // On the free-text choice with nothing in it, Claude Code takes Enter as
                    // declining the whole question: there it opens the box instead. Looked at
                    // afresh, as the keys just sent may have moved the cursor there.
                    if q.qfree {
                        io.q_fresh(q);
                        if !q.qask {
                            io.flash(b"can't see the question just now; Enter not sent");
                            io.draw(q);
                            continue;
                        }
                        if q.qon && q.qempty {
                            io.flash(b"");
                            free_answer(io, q, name);
                            continue;
                        }
                    }
                    toks = vec![b"Enter".to_vec()];
                }
                b"\t" => toks = vec![b"Tab".to_vec()],
                b"\x7f" | b"\x08" => toks = vec![b"BSpace".to_vec()],
                b"\x1b" => {
                    // A lone Esc is Escape; the arrows and the like arrive as sequences.
                    let rest = k.ch(Duration::from_millis(30)).unwrap_or_default();
                    let mut seq: Bytes = Vec::new();
                    match rest.as_slice() {
                        b"" => {
                            // Esc leaves, like Ctrl-]: sent on, it would cancel the question. A
                            // sequence that came in too slowly to tell from Esc is let go of.
                            while k.ch(Duration::from_millis(50)).is_ok() {}
                            return Why::Left;
                        }
                        b"[" => {
                            while let Ok(r) = k.ch(Duration::from_millis(30)) {
                                seq.extend_from_slice(&r);
                                if matches!(r.as_slice(), [c] if (b'@'..=b'~').contains(c)) || blen(&seq) > 8 {
                                    break;
                                }
                            }
                        }
                        b"O" => seq = k.ch(Duration::from_millis(30)).unwrap_or_default(),
                        _ => {}
                    }
                    let t: &[u8] = match seq.as_slice() {
                        b"A" => b"Up",
                        b"B" => b"Down",
                        b"C" => b"Right",
                        b"D" => b"Left",
                        b"H" | b"1~" | b"7~" => b"Home",
                        b"F" | b"4~" | b"8~" => b"End",
                        b"Z" => b"BTab",
                        b"2~" => b"IC",
                        b"3~" => b"DC",
                        b"5~" => b"PPage",
                        b"6~" => b"NPage",
                        _ => b"",
                    };
                    if !t.is_empty() {
                        toks = vec![t.to_vec()];
                    }
                }
                [c @ 0x01..=0x1a] => toks = vec![cat(&[b"C-", &[c + 96]])],
                _ if is_cntrl(&key) => {}
                _ => {
                    // Typed text goes as it is, with whatever else is already waiting. A digit
                    // that starts it goes alone: in a menu it picks a choice.
                    let mut txt = key.clone();
                    while !digit(&key) && blen(&txt) < 256 {
                        match k.ch(Duration::from_millis(5)) {
                            Ok(r) if r.is_empty() => {
                                pend = Some(b"\r".to_vec());
                                break;
                            }
                            Ok(r) if is_cntrl(&r) => {
                                pend = Some(r);
                                break;
                            }
                            Ok(r) => txt.extend_from_slice(&r),
                            Err(_) => break,
                        }
                    }
                    toks = lit_tokens(&clean(&txt));
                }
            }
        }
        if toks.is_empty() {
            continue;
        }
        if !io.send(&toks) {
            return Why::Failed;
        }
        io.peek_drop();
        sent = true;
        poll = 12;
    }
}

// ------------------------------------------------------------------ the worker

/// What the worker tells the UI, in order
pub enum Ev {
    /// draw: the look to draw the question from (QL; the pane's coloured capture for qhi when
    /// its screen has a tab bar), QON
    Look { ql: Vec<Bytes>, screen_e: Option<Vec<Bytes>>, qon: bool },
    /// flash TEXT ("" clears it)
    Flash(Bytes),
    /// free_answer's box: open it, and send its text back (None: closed)
    Box { title: Bytes, hint: Bytes, text: Bytes },
    /// answering is over
    Done(Why),
}

/// The worker's line to the UI: events in order, a byte on the pipe for each batch
#[derive(Clone)]
pub struct Line {
    q: Arc<Mutex<VecDeque<Ev>>>,
    w: RawFd,
}
impl Line {
    fn send(&self, e: Ev) {
        self.q.lock().unwrap().push_back(e);
        term::poke(self.w);
    }
}

/// The terminal's fd 0, read by the worker alone while it answers; Ctrl-C comes as INTR (the
/// UI's SIGINT, passed on through CTL)
pub struct Tty {
    intr: Arc<AtomicBool>,
    ctl: RawFd,
}

impl Tty {
    /// One byte within T: Ok, Err(Time), Err(Intr), Err(Gone)
    fn byte(&mut self, t: Duration) -> Result<u8, Rd> {
        let dl = Instant::now() + t;
        loop {
            // bash's read takes a key already there, INTR or not; it fails at once on Ctrl-C
            let mut b = 0u8;
            let mut fds = [libc::pollfd { fd: 0, events: libc::POLLIN, revents: 0 }, libc::pollfd { fd: self.ctl, events: libc::POLLIN, revents: 0 }];
            let now = Instant::now();
            let ms = if self.intr.load(Ordering::SeqCst) { 0 } else { dl.saturating_duration_since(now).as_millis().min(i32::MAX as u128) as libc::c_int };
            let r = unsafe { libc::poll(fds.as_mut_ptr(), 2, ms) };
            if r < 0 {
                if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(Rd::Gone);
            }
            if fds[1].revents != 0 {
                term::drain(self.ctl);
            }
            if fds[0].revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0 {
                let n = unsafe { libc::read(0, &mut b as *mut u8 as *mut libc::c_void, 1) };
                if n == 1 {
                    return Ok(b);
                }
                if n < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                term::GONE.store(true, Ordering::Relaxed);
                return Err(Rd::Gone);
            }
            if self.intr.load(Ordering::SeqCst) {
                return Err(Rd::Intr);
            }
            if Instant::now() >= dl {
                return Err(Rd::Time);
            }
        }
    }
}

impl Keys for Tty {
    fn ch(&mut self, t: Duration) -> Result<Bytes, Rd> {
        let first = self.byte(t)?;
        if first == b'\n' {
            return Ok(Vec::new());
        }
        let more = match first {
            0xc2..=0xdf => 1,
            0xe0..=0xef => 2,
            0xf0..=0xf4 => 3,
            _ => 0,
        };
        let mut c = vec![first];
        for _ in 0..more {
            match self.byte(super::keys::SEQ_WAIT) {
                Ok(b) => c.push(b),
                Err(_) => break,
            }
        }
        Ok(c)
    }
    fn ready(&mut self) -> bool {
        term::wait_readable(0, Some(Duration::ZERO))
    }
}

/// The frozen target, and all the worker asks with
pub struct Live {
    /// P_HOST: "" for a pane here
    h: Bytes,
    /// the id keys go to: P_ID here, P_RID on a linked computer
    id: Bytes,
    /// P_ID, for qhi's coloured capture (here)
    pid: Bytes,
    /// RVER[h] when answering began
    rver: Bytes,
    cfg: LinkCfg,
    /// for a linked computer's screen: its own peek_fetch, peek_look and gate (PEEK_EVERY=0)
    g: Option<G>,
    rdir: Bytes,
    line: Line,
    reply: mpsc::Receiver<Option<Bytes>>,
    peek_files: Arc<Mutex<Vec<Bytes>>>,
}

impl Live {
    /// The linked computer's peek file
    fn peek_file(&self) -> Bytes {
        sh::path(&[&self.rdir, b"/", &self.h, b".peek-", self.id.strip_prefix(b"%").unwrap_or(&self.id)])
    }
    /// tail -n 60 FILE, as mapfile reads it
    fn peek_tail(&self) -> Vec<Bytes> {
        let f = self.peek_file();
        if !sh::is_file(&f) {
            return Vec::new();
        }
        let d = std::fs::read(sh::os(&f)).unwrap_or_default();
        sh::mapfile(sh::tail_n(&d, 60))
    }
    /// The files it fetched, for the panel to remove when it closes
    fn note_files(&self) {
        if let Some(g) = &self.g {
            let mut pf = self.peek_files.lock().unwrap();
            for f in &g.peek_files {
                if !pf.contains(f) {
                    pf.push(f.clone());
                }
            }
        }
    }
    /// remote_peek 60 -> L, while it asks (P_STATE asking): its screen, or why it can't be shown
    fn remote_peek(&mut self) -> Vec<Bytes> {
        let h = self.h.clone();
        let mut l = vec![Vec::new(), cat(&[b"  on ", &h, b": no peek (update tmux-revive there)"])];
        if !(m(HOST_RE, &h) && m("^%[0-9]+$", &self.id)) {
            return l;
        }
        let id = self.id.clone();
        let Some(g) = self.g.as_mut() else { return l };
        let (at, rp) = g.peek_look(&h, &id, 60);
        self.note_files();
        if at == b"new" {
            l = rp.iter().map(|x| substr(&clean(x), 0, Some(500)).unwrap_or_default()).collect();
        } else if at != b"fail" {
            l = vec![Vec::new(), cat(&[b"  on ", &h, b": asking for its screen..."])];
        }
        l
    }
    /// keys_send %ID TOKEN...: to a pane on this computer, every token checked first
    fn keys_send(&self, toks: &[Bytes]) -> bool {
        let mut lits = Vec::new();
        for t in toks {
            match key_ok(t) {
                Some(l) => lits.push(l),
                None => return false,
            }
        }
        for (t, lit) in toks.iter().zip(lits) {
            let ok = if t.starts_with(b"lit:") {
                sh::tm(&[b"send-keys", b"-t", &self.id, b"-l", b"--", &lit]).ok
            } else {
                sh::tm(&[b"send-keys", b"-t", &self.id, t]).ok
            };
            if !ok {
                return false;
            }
        }
        true
    }
    /// paste_send %ID HEX: to a pane on this computer, as a bracketed paste, not submitted
    fn paste_send(&self, x: &[u8]) -> bool {
        let Some(paste) = paste_ok(x) else { return false };
        let b = format!("revive-answer-{}", std::process::id()).into_bytes();
        if !sh::tm_in(&[b"load-buffer", b"-b", &b, b"-"], &paste) {
            return false;
        }
        // -p: marked as a paste, so a line break isn't Enter; -r: as LF; -d: the buffer goes with it.
        sh::tm(&[b"paste-buffer", b"-p", b"-r", b"-d", b"-b", &b, b"-t", &self.id]).ok
    }
}

impl AnsIo for Live {
    fn look(&mut self, q: &mut Q) {
        if !self.h.is_empty() {
            // A linked computer's comes in its peek file, which changes only when a fetch comes
            // back, so while one is still out there's nothing new to read.
            let k = sh::path(&[&self.h, b" ", &self.id]);
            if !q.qshot.is_empty() && self.g.as_ref().is_some_and(|g| g.pgate.busy(&k)) {
                return;
            }
            q.ql = self.remote_peek();
        } else {
            q.qraw = sh::mapfile(&sh::tm(&[b"capture-pane", b"-p", b"-t", &self.id]).out);
            q.ql = q.qraw.iter().map(|l| clean(l)).collect(); // capture-pane passes C1 characters through
        }
        // printf -v QSHOT '%s\n' "${QL[@]}"
        q.qshot = if q.ql.is_empty() { b"\n".to_vec() } else { q.ql.iter().flat_map(|l| l.iter().copied().chain([b'\n'])).collect() };
    }
    fn asking(&mut self, q: &Q) -> bool {
        if !self.h.is_empty() {
            lines_state(&self.peek_tail()) == b"asking"
        } else {
            lines_state(&q.qraw) == b"asking"
        }
    }
    fn q_fresh(&mut self, q: &mut Q) {
        let st: &[u8] = if !self.h.is_empty() {
            let (h, id, f) = (self.h.clone(), self.id.clone(), self.peek_file());
            if let Some(g) = self.g.as_mut() {
                g.peek_drop(&h, &id);
                g.peek_fetch(&h, &id, 60, &f, true);
            }
            q.qshot.clear(); // the look reads what just came (and asks again, as answering does after a key)
            self.look(q);
            lines_state(&self.peek_tail())
        } else {
            let (mut n, mut last): (i32, Bytes) = (0, Vec::new());
            for _ in 0..25 {
                std::thread::sleep(Duration::from_millis(40));
                self.look(q);
                if q.qshot == last {
                    n += 1;
                    if n >= 2 {
                        break;
                    }
                } else {
                    n = 0;
                    last = q.qshot.clone();
                }
            }
            lines_state(&q.qraw)
        };
        q.qask = st == b"asking";
        question_free(q);
    }
    fn send(&mut self, toks: &[Bytes]) -> bool {
        let h = self.h.clone();
        if h.is_empty() {
            if self.keys_send(toks) {
                return true;
            }
            self.flash(b"the keys didn't reach that pane");
            return false;
        }
        if !(m(HOST_RE, &h) && m("^%[0-9]+$", &self.id)) {
            return false;
        }
        if toks.iter().any(|t| key_ok(t).is_none()) {
            return false;
        }
        let mut req: Vec<&[u8]> = vec![b"keys", &self.id];
        req.extend(toks.iter().map(|t| t.as_slice()));
        let (st, out) = remote_run(&self.cfg, &h, &req, usize::MAX);
        let out = sh::cmdsub(&out);
        if out == b"sent" {
            return true;
        }
        if st == 124 || st == 255 {
            self.flash(&cat(&[b"on ", &h, b": can't be reached to answer"]));
        } else if (st == 0 || st == 1) && out.is_empty() {
            self.flash(&cat(&[b"on ", &h, b": can't answer from here (update tmux-revive there)"]));
        } else {
            self.flash(&cat(&[b"on ", &h, b": the keys didn't get through"]));
        }
        false
    }
    fn paste(&mut self, t: &[u8]) -> bool {
        let h = self.h.clone();
        let x = hex(t);
        if h.is_empty() {
            if self.paste_send(&x) {
                return true;
            }
            self.flash(b"the answer didn't reach that pane");
            return false;
        }
        if !(m(HOST_RE, &h) && m("^%[0-9]+$", &self.id)) {
            return false;
        }
        if paste_ok(&x).is_none() {
            self.flash(b"that answer can't be sent");
            return false;
        }
        if self.rver.is_empty() || crate::render::panes::ver_lt(&self.rver, PASTE_SINCE) {
            self.flash(&cat(&[b"on ", &h, b": can't take a written answer (update tmux-revive there)"]));
            return false;
        }
        let (st, out) = remote_run(&self.cfg, &h, &[b"paste", &self.id, &x], usize::MAX);
        if sh::cmdsub(&out) == b"sent" {
            return true;
        }
        if st == 124 || st == 255 {
            self.flash(&cat(&[b"on ", &h, b": can't be reached to answer"]));
        } else {
            self.flash(&cat(&[b"on ", &h, b": the answer didn't get through"]));
        }
        false
    }
    fn peek_drop(&mut self) {
        let (h, id) = (self.h.clone(), self.id.clone());
        if let Some(g) = self.g.as_mut() {
            g.peek_drop(&h, &id);
        }
    }
    fn flash(&mut self, t: &[u8]) {
        self.line.send(Ev::Flash(t.to_vec()));
    }
    fn draw(&mut self, q: &Q) {
        // qhi's look: the pane's coloured capture, when its screen has a tab bar to light
        let tb = re("^[[:space:]]*←.*→[[:space:]]*$");
        let screen_e = (self.h.is_empty() && !self.pid.is_empty() && q.ql.iter().any(|l| tb.is_match(l)))
            .then(|| sh::mapfile(&sh::tm(&[b"capture-pane", b"-e", b"-p", b"-t", &self.pid]).out));
        self.line.send(Ev::Look { ql: q.ql.clone(), screen_e, qon: q.qon });
    }
    fn edit_box(&mut self, title: &[u8], hint: &[u8], text: &[u8]) -> Option<Bytes> {
        self.line.send(Ev::Box { title: title.to_vec(), hint: hint.to_vec(), text: text.to_vec() });
        self.reply.recv().ok().flatten()
    }
    fn now_us(&mut self) -> i64 {
        sh::now_us()
    }
}

// ------------------------------------------------------------------ the UI's side

impl Ui {
    /// act's Enter on a pane asking a question: answer it, the panel going on meanwhile
    pub(super) fn answer(&mut self) {
        let sel = self.c.p.sel;
        if self.c.p.a("P_STATE", sel) != b"asking" {
            return;
        }
        let h = self.pa("P_HOST", sel);
        let pid = self.pa("P_ID", sel);
        let id = if h.is_empty() { pid.clone() } else { self.pa("P_RID", sel) };
        if !m("^%[0-9]+$", &id) {
            return;
        }
        let name = self.c.p.sel_name();
        let rver = self.c.p.snap.assoc.get("RVER").and_then(|r| r.get(h.as_slice())).cloned().unwrap_or_default();
        // The dialog, at the bottom; the bar shows only this question's flash.
        self.prev.clear();
        self.c.p.atop.clear();
        self.c.p.snap.arrays.insert("QL", Default::default());
        self.c.p.pb = 0;
        self.c.p.qon = 0;
        self.c.p.flash.clear();
        self.c.p.ans = Some(AnsPane { id: pid.clone(), host: h.clone(), name: name.clone() });
        self.ans_on = true;
        self.want_peek(); // the peek looks at it no more: the worker's looks are drawn
        let (ev_r, ev_w) = term::pipe();
        let (ctl_r, ctl_w) = term::pipe();
        let (tx, rx) = mpsc::channel::<Option<Bytes>>();
        let events: Arc<Mutex<VecDeque<Ev>>> = Arc::default();
        let intr = Arc::new(AtomicBool::new(false));
        let line = Line { q: events.clone(), w: ev_w };
        let g = (!h.is_empty()).then(|| {
            let mut g = G::new(&self.root);
            g.once = false;
            g.peek_every = 0; // PEEK_EVERY=0: a linked pane's screen asked for as often as it can be
            g
        });
        let mut live = Live {
            h: h.clone(),
            id: id.clone(),
            pid,
            rver,
            cfg: LinkCfg::from_env(&self.astate, &sh::path(&[&self.root, b"/bin/agent-say"])),
            g,
            rdir: self.rdir.clone(),
            line: line.clone(),
            reply: rx,
            peek_files: Arc::new(Mutex::new(Vec::new())),
        };
        let files = live.peek_files.clone();
        let mut tty = Tty { intr: intr.clone(), ctl: ctl_r };
        let (wname, wline) = (name.clone(), line.clone());
        let worker = std::thread::Builder::new()
            .name("answer".into())
            .spawn(move || {
                let mut q = Q::default();
                let why = answer_loop(&mut tty, &mut live, &mut q, &wname);
                wline.send(Ev::Done(why));
            })
            .expect("the answer thread starts");
        // Ctrl-C while answering is the question's (trap 'INTR=1' INT)
        self.modal_on = true;
        let why = loop {
            let flash_on = !self.c.p.flash.is_empty() && self.secs() - self.c.p.flash_t < 5;
            let dl = flash_on.then(|| Instant::now() + Duration::from_millis(300));
            match self.pump(false, ev_r, dl) {
                Woke::Intr => {
                    intr.store(true, Ordering::SeqCst);
                    term::poke(ctl_w);
                }
                Woke::Time => {
                    // its time is up: the flash goes
                    if flash_on && self.secs() - self.c.p.flash_t >= 5 {
                        self.c.p.flash.clear();
                        self.paint_now();
                    }
                }
                Woke::Key | Woke::Job => {}
            }
            term::drain(ev_r);
            let mut done = None;
            loop {
                let e = events.lock().unwrap().pop_front();
                let Some(e) = e else { break };
                match e {
                    Ev::Look { ql, screen_e, qon } => {
                        let to_map = |v: Vec<Bytes>| v.into_iter().enumerate().map(|(i, x)| (i as i64, x)).collect();
                        self.c.p.snap.arrays.insert("QL", to_map(ql));
                        if let Some(e) = screen_e {
                            self.c.p.screen_id = self.c.p.ans.as_ref().map(|a| a.id.clone()).unwrap_or_default();
                            self.c.p.snap.arrays.insert("SCREEN_E", to_map(e));
                        }
                        self.c.p.qon = qon as i64;
                        self.c.p.answering = 1;
                        self.draw_box_lines();
                        self.paint_now();
                    }
                    Ev::Flash(t) => {
                        if t.is_empty() {
                            self.c.p.flash.clear();
                        } else {
                            self.notice(&t);
                        }
                    }
                    Ev::Box { title, hint, text } => {
                        let ok = self.edit_box(&title, &hint, &text, true);
                        self.modal_on = true; // edit_box let go of it
                        let r = ok.then(|| self.reply.clone());
                        // PREV=(): the panel under it drawn whole again
                        self.prev.clear();
                        let _ = tx.send(r);
                    }
                    Ev::Done(w) => done = Some(w),
                }
            }
            if let Some(w) = done {
                break w;
            }
        };
        let _ = worker.join();
        {
            let mut pf = self.hub.peek_files.lock().unwrap();
            for f in files.lock().unwrap().iter() {
                if !pf.contains(f) {
                    pf.push(f.clone());
                }
            }
        }
        unsafe {
            libc::close(ev_r);
            libc::close(ev_w);
            libc::close(ctl_r);
            libc::close(ctl_w);
        }
        // ANSWERING=0 PEEK_EVERY=$REFRESH PREV=() ATOP=() QFREE=0 QFREEN="" QON=0 ... QLAST=""
        self.modal_on = false;
        self.ans_on = false;
        self.c.p.answering = 0;
        self.c.p.ans = None;
        self.c.p.qon = 0;
        self.c.p.atop.clear();
        self.c.p.snap.arrays.insert("QL", Default::default());
        self.prev.clear();
        match why {
            Why::Left => self.notice(b"left the question; nothing more was sent"),
            Why::Answered => {
                let n = if name.is_empty() { b"the pane".to_vec() } else { name };
                self.notice(&cat(&[&n, b" has its answer"]));
                // Rows from over there asked for before this still say asking: they don't count now.
                if !h.is_empty() {
                    let f = sh::path(&[&self.rdir, b"/", &h, b".answered-", id.strip_prefix(b"%").unwrap_or(&id)]);
                    let _ = std::fs::write(sh::os(&f), b"");
                    self.hub.rows_again(Some(h));
                }
            }
            Why::Failed => {}
        }
    }

    /// A frame drawn at once, whatever the round is waiting for (a look while answering)
    fn paint_now(&mut self) {
        self.paint();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::collect::gather::tests::bash_fn;
    use crate::compat::tests::{bash, setup};

    /// clean, as panel.sh has it, for the bash side
    fn prims() -> String {
        crate::render::prim::tests::bash_prims()
    }

    #[test]
    fn key_ok_as_bash() {
        setup();
        let f = format!("{}\nKEY_RE='{}'\n{}", prims(), KEY_RE, bash_fn("key_ok"));
        let mut cases: Vec<Bytes> = ["Up", "Down", "Enter", "BSpace", "C-a", "C-z", "C-A", "Escape", "F1", "Enter;touch x", "send-keys", "$(touch x)", "Up ", "", "lit:", "lit:6", "lit:61", "lit:6162", "lit:00", "lit:0a", "lit:1b", "lit:7f", "lit:41FF", "lit:c3a9", "lit:c285", "lit:e280ae", "lit:e2808b", "lit:ff", "lit:6g"]
            .iter()
            .map(|s| s.as_bytes().to_vec())
            .collect();
        cases.push(cat(&[b"lit:", &hex(&[b'a'; 64])]));
        cases.push(cat(&[b"lit:", &hex(&[b'a'; 65])]));
        cases.push(cat(&[b"lit:", &hex("é".repeat(64).as_bytes())]));
        cases.push(cat(&[b"lit:", &hex("é".repeat(65).as_bytes())]));
        cases.push(cat(&[b"lit:", &hex(&[b'a'; 192])]));
        cases.push(cat(&[b"lit:", &hex(&[b'a'; 193])]));
        for c in cases {
            let theirs = bash(&format!("{}\nif key_ok \"$1\"; then printf 'ok:%s' \"$LIT\"; else printf no; fi", f), &[&c]);
            let ours = match key_ok(&c) {
                Some(l) => cat(&[b"ok:", &l]),
                None => b"no".to_vec(),
            };
            assert_eq!(ours, theirs, "{:?}", String::from_utf8_lossy(&c));
        }
    }

    #[test]
    fn lit_tokens_as_bash() {
        setup();
        let f = bash_fn("lit_tokens");
        let long = "x".repeat(70);
        for c in ["", "a", "2", "hello world", "é漢字", long.as_str(), &"é".repeat(40), "a\tb"] {
            let theirs = bash(&format!("{}\nTOKS=(); lit_tokens \"$1\"; printf '%s\\n' \"${{TOKS[@]}}\"", f), &[c.as_bytes()]);
            let ours: Bytes = lit_tokens(c.as_bytes()).iter().flat_map(|t| t.iter().copied().chain([b'\n'])).collect();
            let ours = if ours.is_empty() { b"\n".to_vec() } else { ours };
            assert_eq!(ours, theirs, "{:?}", c);
        }
        // bytes that aren't UTF-8 count one character each, as bash's ${t:0:32}
        let odd: Bytes = [b"\xff".repeat(33), b"ok".to_vec()].concat();
        let theirs = bash(&format!("{}\nTOKS=(); lit_tokens \"$1\"; printf '%s\\n' \"${{TOKS[@]}}\"", f), &[&odd]);
        let ours: Bytes = lit_tokens(&odd).iter().flat_map(|t| t.iter().copied().chain([b'\n'])).collect();
        assert_eq!(ours, theirs);
    }

    #[test]
    fn paste_ok_as_bash() {
        setup();
        let f = format!("{}\nPASTE_MAX={}\n{}\n{}", prims(), PASTE_MAX, bash_fn("paste_ok"), bash_fn("paste_hex"));
        let mut cases: Vec<Bytes> = ["", "6", "61", "6162", "0a", "20", "200a09", "610a62", "61096209", "6100", "6108", "610b", "611b", "617f", "61c285", "61e280ae", "41FF", "6g", "c3a9", "5c78", "2a"]
            .iter()
            .map(|s| s.as_bytes().to_vec())
            .collect();
        cases.push(hex(b"my custom answ\xc3\xa9r\nLine two\nthree"));
        cases.push(hex(&[b'a'; PASTE_MAX]));
        cases.push(hex(&[b'a'; PASTE_MAX + 1]));
        for c in cases {
            let theirs = bash(&format!("{}\nif paste_ok \"$1\"; then printf 'ok:%s' \"$PASTE\"; else printf no; fi", f), &[&c]);
            let ours = match paste_ok(&c) {
                Some(p) => cat(&[b"ok:", &p]),
                None => b"no".to_vec(),
            };
            assert_eq!(ours, theirs, "{:?}", String::from_utf8_lossy(&c[..c.len().min(40)]));
        }
    }

    /// test/panel.sh's qfree and qfrees fixtures (multi-selects, tabs, the review, a written-in
    /// answer), and more, against bash's own question_free run on each in turn
    #[test]
    fn question_free_as_bash() {
        setup();
        let rule50 = "─".repeat(50);
        let rule46 = "─".repeat(46);
        let msq = vec!["←  ☒ Fruit  ✔ Submit  →", "", "Which fruits?", "", "  1. [✔] Apple", "         A sweet fruit", "  2. [ ] Banana", "         A soft fruit", "  3. [ ] Type something", "❯    Submit", &rule50, "  4. Chat about this", "", "Enter to select · ↑/↓ to navigate · Esc to cancel"]
            .into_iter()
            .map(String::from)
            .collect::<Vec<_>>();
        let mut msq_on = msq.clone();
        msq_on[8] = "❯ 3. [ ] Type something".into();
        msq_on[9] = "     Submit".into();
        let tab1 = vec![
            "←  ☒ Scope  ☒ Cleanup   Submit  →", "", "Beyond the agent list, what should the README cleanup cover?", "", "  1. [ ] Agent list only", "     Just fix it.", "  2. [ ] Tighten the prose", "     Trim.", "  3. [ ] Fix stale steps", "     Check.", "  4. [ ] Drop the ad sections", "     Remove.",
            "❯ 5. [ ] But add codex-workforce install button to help menu under tame your AI", "     Submit", &rule46, "  6. Chat about this", "", "Enter to select · Tab/Arrow keys to navigate · ctrl+g to edit in Nvim · Esc to cancel",
        ]
        .into_iter()
        .map(String::from)
        .collect::<Vec<_>>();
        let mut tab1_off = tab1.clone();
        tab1_off[12] = tab1[12].replacen("❯ 5. ", "  5. ", 1);
        tab1_off[13] = "❯    Submit".into();
        let tab2 = vec!["←  ☒ Scope  ☒ Cleanup   Submit  →", "", "What scope?", "", "  1. README only", "❯ 2. the help menu too", &rule46, "  3. Chat about this", "", "Enter to select · Tab/Arrow keys to navigate · Esc to cancel"].into_iter().map(String::from).collect::<Vec<_>>();
        let tab3 = vec!["←  ☒ Scope  ☒ Cleanup  ✔ Submit  →", "", "Review your answers", "", " ● What scope?", "   → the help menu too", "", "  1. Submit answers", "❯ 2. Cancel", ""].into_iter().map(String::from).collect::<Vec<_>>();
        let ask = vec!["history", &rule50, " Do you want to proceed?", "", " ❯ 1. Yes", "      what choosing Yes does", "   2. No", "   3. Maybe", "   4. Later", "   5. Type something.", &rule50, "   6. Chat about this", "", " Enter to select"].into_iter().map(String::from).collect::<Vec<_>>();
        let mut ask5 = ask.clone();
        ask5[4] = "   1. Yes".into();
        ask5[9] = " ❯ 5. Type something.".into();
        let mut ask5w = ask5.clone();
        ask5w[9] = " ❯ 5. >my custom answér".into();
        let nofree = vec![" Do you want to proceed?", " ❯ 1. Yes", "   2. No", "   5. Not now", "   6. Never"].into_iter().map(String::from).collect::<Vec<_>>();
        let boxed = vec!["│ ❯ 1. Yes │", "│   2. Type something │"].into_iter().map(String::from).collect::<Vec<_>>();
        let empty: Vec<String> = Vec::new();
        let seqs: Vec<Vec<&Vec<String>>> = vec![
            vec![&msq],
            vec![&msq_on],
            vec![&tab1],
            vec![&tab1_off],
            vec![&tab1, &tab2, &tab3, &tab1],
            vec![&ask, &ask5, &ask5w, &nofree],
            vec![&nofree],
            vec![&boxed],
            vec![&empty],
        ];
        let f = bash_fn("question_free");
        for s in seqs {
            let mut args: Vec<Bytes> = Vec::new();
            for scr in &s {
                args.push(scr.join("\n").into_bytes());
            }
            let argv: Vec<&[u8]> = args.iter().map(|a| a.as_slice()).collect();
            let theirs = bash(
                &format!("{}\nQFREE=0 QFREEN=\"\"\nfor f; do QL=(); [[ -n $f ]] && mapfile -t QL <<<\"$f\"; question_free; printf '%s|%s|%s|%s|%s|%s|%s\\n' \"$QFREE\" \"$QFREEN\" \"$QON\" \"$QEMPTY\" \"$QHAS\" \"$QCUR\" \"$QFTXT\"; done", f),
                &argv,
            );
            let mut q = Q::default();
            let mut ours: Bytes = Vec::new();
            for a in &args {
                q.ql = if a.is_empty() { Vec::new() } else { sh::here(a) };
                question_free(&mut q);
                let b = |x: bool| if x { "1" } else { "0" };
                ours.extend_from_slice(format!("{}|{}|{}|{}|{}|", b(q.qfree), String::from_utf8_lossy(&q.qfreen), b(q.qon), b(q.qempty), b(q.qhas)).as_bytes());
                ours.extend_from_slice(&q.qcur);
                ours.push(b'|');
                ours.extend_from_slice(&q.qftxt);
                ours.push(b'\n');
            }
            assert_eq!(String::from_utf8_lossy(&ours), String::from_utf8_lossy(&theirs), "{:?}", s.iter().map(|x| x.join("/")).collect::<Vec<_>>());
        }
    }

    /// Keys as a pipe gives them to bash's read: all there at once, then the end of input
    struct Script(VecDeque<u8>);
    impl Keys for Script {
        fn ch(&mut self, _t: Duration) -> Result<Bytes, Rd> {
            let Some(first) = self.0.pop_front() else { return Err(Rd::Gone) };
            if first == b'\n' {
                return Ok(Vec::new());
            }
            let more = match first {
                0xc2..=0xdf => 1,
                0xe0..=0xef => 2,
                0xf0..=0xf4 => 3,
                _ => 0,
            };
            let mut c = vec![first];
            for _ in 0..more {
                match self.0.pop_front() {
                    Some(b) => c.push(b),
                    None => break,
                }
            }
            Ok(c)
        }
        fn ready(&mut self) -> bool {
            true // a pipe: something to read, or the end of it
        }
    }

    /// A question that doesn't move, as the stubs bash's answer() runs with below: its sends,
    /// looks afresh and flashes logged
    struct Fake {
        log: Vec<String>,
        qfree: bool,
        qon: bool,
        qempty: bool,
        qask: bool,
    }
    impl AnsIo for Fake {
        fn look(&mut self, q: &mut Q) {
            q.qshot = b"x".to_vec();
        }
        fn question_free(&mut self, q: &mut Q) {
            q.qfree = self.qfree;
            q.qon = self.qon;
            q.qempty = self.qempty;
        }
        fn asking(&mut self, _q: &Q) -> bool {
            true
        }
        fn q_fresh(&mut self, q: &mut Q) {
            q.qask = self.qask;
            q.qhas = self.qask;
            q.qon = self.qon;
            q.qempty = self.qempty;
            self.log.push("fresh".into());
        }
        fn send(&mut self, toks: &[Bytes]) -> bool {
            self.log.push(format!("send {}", toks.iter().map(|t| String::from_utf8_lossy(t).into_owned()).collect::<Vec<_>>().join(" ")));
            true
        }
        fn paste(&mut self, _t: &[u8]) -> bool {
            true
        }
        fn peek_drop(&mut self) {}
        fn flash(&mut self, t: &[u8]) {
            self.log.push(format!("flash {}", String::from_utf8_lossy(t)));
        }
        fn draw(&mut self, _q: &Q) {}
        fn edit_box(&mut self, _t: &[u8], _h: &[u8], _x: &[u8]) -> Option<Bytes> {
            None
        }
        fn now_us(&mut self) -> i64 {
            0
        }
    }

    /// answer()'s key -> token rules: bash's own answer() run with the keys on a pipe and its
    /// looks, sends and flashes stubbed, against answer_loop with the same. Esc against
    /// sequences, typed text batched and a digit sent alone, the free-text choice's j, k, E,
    /// digits and Space, the Enter guard, control keys.
    #[test]
    fn answer_keys_as_bash() {
        setup();
        let stubs = r#"
P_STATE=(asking) P_ID=(%1) P_HOST=() P_RID=() P_NAME=(asker) SEL=0 REFRESH=1 RDIR=/nonexistent
question_look() { QSHOT=x QRAW=() QL=(); }
question_free() { QFREE=$TQFREE QON=$TQON QEMPTY=$TQEMPTY; }
q_fresh() { QASK=$TQASK QHAS=$TQASK QON=$TQON QEMPTY=$TQEMPTY; echo fresh; }
lines_state() { LSTATE=asking; }
draw() { :; }
flash() { FLASH=$1; echo "flash $1"; }
send_answer() { echo "send $*"; }
peek_drop() { :; }
edit_box() { return 1; }
"#;
        // FLASH="" inside answer() is a flash of nothing, as Ev::Flash("") is
        let f = format!(
            "{}\n{}\n{}\n{}\n{}\n{}",
            prims(),
            bash_fn("lit_tokens"),
            bash_fn("free_answer").replace("FLASH=\"\"", "flash \"\""),
            bash_fn("answer").replace("FLASH=\"\"; free_answer", "flash \"\"; free_answer").replace("QLAST=\"\" FLASH=\"\"", "QLAST=\"\""),
            stubs,
            "printf '%b' \"$1\" | answer"
        );
        let cases: &[(&str, &str)] = &[
            ("", "0000"),
            ("\\e", "0000"),
            ("\\e[A\\e[B\\e[C\\e[D", "0000"),
            ("\\e[H\\e[F\\e[Z\\e[2~\\e[3~\\e[5~\\e[6~\\e[1~\\e[4~\\eOA\\eOH", "0000"),
            ("\\e[1;5A", "0000"),
            ("\\ex", "0000"),
            ("abc", "0000"),
            ("2xyz", "0000"),
            ("x2xyz", "0000"),
            ("hello world\\r", "0000"),
            ("ab\\ncd", "0000"),
            ("ab\\tc", "0000"),
            ("\\t\\x7f\\b\\x01\\x1a\\x15", "0000"),
            ("\\x1d", "0000"),
            ("a\\x1db", "0000"),
            ("\\x1c\\x1e\\x1f", "0000"),
            ("é漢\\xc2\\x85z", "0000"),
            ("\\xc2\\x85", "0000"),
            ("\\r\\n", "0000"),
            // a free-text choice: j k move, a digit and Space off it go, letters stay
            ("jjkk", "1000"),
            ("3 x", "1000"),
            ("3 x\\x7f", "1100"),
            ("\\e[B\\t", "1000"),
            // Enter on it: looked at afresh; empty and on it opens the box (closed: nothing sent)
            ("\\r", "1001"),
            ("\\r", "1111"),
            ("\\r", "1101"),
            ("\\rx", "1000"),
            ("E", "1111"),
            ("e", "1000"),
        ];
        for (keys, t) in cases {
            let tb = t.as_bytes();
            let on = |i: usize| tb[i] == b'1';
            let script = format!("TQFREE={} TQON={} TQEMPTY={} TQASK={}\n{}", on(0) as u8, on(1) as u8, on(2) as u8, on(3) as u8, f);
            let theirs = String::from_utf8_lossy(&bash(&script, &[keys.as_bytes()])).into_owned();
            assert!(theirs.ends_with("flash left the question; nothing more was sent\n"), "bash's answer() ran to its end: {:?}", theirs);
            if *keys == "2xyz" {
                assert_eq!(theirs.lines().filter(|l| l.starts_with("send ")).collect::<Vec<_>>(), ["send lit:32", "send lit:78797a"], "a digit alone, then the text");
            }
            let bytes = bash("printf '%b' \"$1\"", &[keys.as_bytes()]);
            let mut fk = Fake { log: Vec::new(), qfree: on(0), qon: on(1), qempty: on(2), qask: on(3) };
            let mut q = Q::default();
            let why = answer_loop(&mut Script(bytes.into_iter().collect()), &mut fk, &mut q, b"asker");
            assert_eq!(why, Why::Left, "the input closed: left");
            fk.log.push("flash left the question; nothing more was sent".into()); // the UI says it, as answer() does at its end
            let mut ours = fk.log.join("\n");
            if !ours.is_empty() {
                ours.push('\n');
            }
            assert_eq!(ours, theirs, "keys {:?} state {}", keys, t);
        }
    }
}
