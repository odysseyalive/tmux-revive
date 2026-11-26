//! What the live panel writes straight to the terminal, outside the frame: the splash and the
//! loading box (scripts/panel.sh `:4920-5065`).

use super::keys::Src;
use super::{term, Ui};
use crate::collect::sh::{self, Bytes};
use crate::compat::{chars, itoa};
use crate::render::{cat, num, Ctx, B, BCYN, BGBLU, BGRN, BLU, BWHT, CYN, GRY, R};
use std::time::Duration;

const SPIN: [&str; 4] = ["▖", "▘", "▝", "▗"];

fn at(r: i64, c: i64) -> Bytes {
    cat(&[b"\x1b[", &itoa(r), b";", &itoa(c), b"H"])
}

/// LBOX LBOX_ARMED LBOX_T0 LBOX_AT LBOX_SPIN LB_DONE LB_TOT
#[derive(Default)]
pub struct Lbox {
    pub on: bool,
    pub armed: bool,
    pub t0: i64,
    pub at: Option<(i64, i64)>,
    pub spin: i64,
    pub done: i64,
    pub tot: i64,
}

/// lbox_draw: the box, over what draw just put on the screen, framed as pick's
pub fn lbox_draw(lb: &mut Lbox, c: &Ctx) -> Bytes {
    let (rows, cols) = (c.p.tlines, c.p.tcols);
    let title: &[u8] = b"LOADING";
    let mut w: i64 = 40;
    if w > cols - 4 {
        w = cols - 4;
    }
    let top = ((rows - 6) / 2).max(1);
    let left = ((cols - w) / 2).max(1);
    let mut o: Bytes = Vec::new();
    let rep = c.rep("═".as_bytes(), w - title.len() as i64 - 11);
    o.extend(cat(&[&at(top, left), BGBLU, BWHT, "╔═".as_bytes(), R, BLU, "░▒▓".as_bytes(), BGBLU, B, BWHT, b" ", title, b" ", R, BLU, "▓▒░".as_bytes(), BGBLU, BWHT, &rep, "╗".as_bytes(), R]));
    let blank = c.rep(b" ", w - 2);
    o.extend(cat(&[&at(top + 1, left), BGBLU, BWHT, "║".as_bytes(), &blank, "║".as_bytes(), R, GRY, "░".as_bytes(), R]));
    let fld = c.fld("Loading…".as_bytes(), (w - 8).max(0));
    o.extend(cat(&[
        &at(top + 2, left),
        BGBLU,
        BWHT,
        "║  ".as_bytes(),
        BCYN,
        SPIN[lb.spin.rem_euclid(4) as usize].as_bytes(),
        BWHT,
        b" ",
        B,
        &fld,
        R,
        BGBLU,
        BWHT,
        "  ║".as_bytes(),
        R,
        GRY,
        "░".as_bytes(),
        R,
    ]));
    lb.at = Some((top + 2, left + 3));
    o.extend(cat(&[&at(top + 3, left), BGBLU, BWHT, "║".as_bytes(), &blank, "║".as_bytes(), R, GRY, "░".as_bytes(), R]));
    let d = lb.done.min(lb.tot);
    let pl = cat(&[b" ", &itoa(d), b"/", &itoa(lb.tot)]);
    let pw = w - 6 - pl.len() as i64;
    let pf = if lb.tot != 0 { pw * d / lb.tot } else { 0 };
    let on = c.rep("█".as_bytes(), pf);
    let off = c.rep("░".as_bytes(), pw - pf);
    o.extend(cat(&[&at(top + 4, left), BGBLU, BWHT, "║  ".as_bytes(), BCYN, &on, CYN, &off, BWHT, &pl, "  ║".as_bytes(), R, GRY, "░".as_bytes(), R]));
    o.extend(cat(&[&at(top + 5, left), BGBLU, BWHT, "║".as_bytes(), &blank, "║".as_bytes(), R, GRY, "░".as_bytes(), R]));
    let rep = c.rep("═".as_bytes(), w - 2);
    o.extend(cat(&[&at(top + 6, left), BGBLU, BWHT, "╚".as_bytes(), &rep, "╝".as_bytes(), R, GRY, "░".as_bytes(), R]));
    let rep = c.rep("░".as_bytes(), w);
    o.extend(cat(&[&at(top + 7, left + 1), GRY, &rep, R]));
    o
}

/// lbox_young PID: started under 2 minutes ago, and this user can look into it
fn lbox_young(pid: &[u8], clk: i64) -> bool {
    if pid.is_empty() || !pid.iter().all(|c| c.is_ascii_digit()) {
        return false;
    }
    let pe = sh::path(&[b"/proc/", pid, b"/environ"]);
    let ps = sh::path(&[b"/proc/", pid, b"/stat"]);
    if !sh::readable(&pe) || !sh::readable(&ps) {
        return false;
    }
    // read -r st </proc/PID/stat; st=${st##*) }; read -ra st <<<"$st"
    let Some(line) = sh::read_line(&ps) else { return false };
    let rest = match line.windows(2).rposition(|w| w == b") ") {
        Some(i) => &line[i + 2..],
        None => &line[..],
    };
    let f = sh::read_ws(rest, 64, b" \t\n");
    let Some(up) = sh::read_line(b"/proc/uptime") else { return false };
    let up = sh::read_ws(&up, 2, b" \t\n").into_iter().next().unwrap_or_default();
    // up=${up%.*}
    let up = match up.iter().rposition(|&c| c == b'.') {
        Some(i) => up[..i].to_vec(),
        None => up,
    };
    let st19 = f.get(19).map(|v| num(v)).unwrap_or(0);
    num(&up) - st19 / if clk != 0 { clk } else { 100 } < 120
}

impl Ui {
    /// lbox_count -> LB_TOT: agents here and linked computers, LB_DONE: those ready
    fn lbox_count(&mut self) {
        let mut hs: std::collections::HashMap<Bytes, i32> = Default::default();
        let (mut tot, mut done) = (0, 0);
        let secs = self.secs();
        for i in 0..self.p_len() {
            let h = self.pa("P_HOST", i);
            if !h.is_empty() {
                if !hs.contains_key(&h) {
                    hs.insert(h.clone(), 1);
                    tot += 1;
                    done += 1;
                }
                // Names only, its rows not in yet: still asking it, for a minute at most. Not while
                // its link isn't working (LUP): nothing is coming.
                if self.c.p.a("P_STATE", i) == b"linked" && self.c.p.assoc("LUP", &h) == b"1" && hs.get(&h) == Some(&1) && secs - self.lbox.t0 < 60 {
                    hs.insert(h, 2);
                    done -= 1;
                }
                continue;
            }
            if num(self.c.p.a("P_AGENT", i)) == 0 {
                continue;
            }
            tot += 1;
            let pid = self.a_load.get(&i).cloned().unwrap_or_default();
            if !(!pid.is_empty() && lbox_young(&pid, self.clk)) {
                done += 1;
            }
        }
        self.lbox.tot = tot;
        self.lbox.done = done;
    }

    fn lbox_off(&mut self) {
        if !self.lbox.on {
            return;
        }
        self.lbox.on = false;
        self.lbox.at = None;
        self.prev.clear();
    }

    /// lbox_check: after each look. Arms the box at the first, then closes it once all is ready.
    pub(super) fn lbox_check(&mut self) {
        if !self.lbox.armed {
            self.lbox.armed = true;
            self.lbox.t0 = self.secs();
            match sh::env("REVIVE_PANEL_LOADBOX").as_deref() {
                Some(b"0") => return,
                Some(b"1") => {}
                _ => {
                    let up = sh::cmdsub(&sh::tm(&[b"display-message", b"-p", b"#{start_time}"]).out);
                    let now = self.now();
                    if !(!up.is_empty() && up.iter().all(|c| c.is_ascii_digit()) && now - num(&up) <= 180) {
                        return;
                    }
                }
            }
            self.lbox_count();
            if self.lbox.done < self.lbox.tot {
                self.lbox.on = true;
            }
            return;
        }
        if !self.lbox.on {
            return;
        }
        self.lbox_count();
        if self.lbox.done >= self.lbox.tot {
            self.lbox_off();
        }
    }

    /// pause T: no key within T (a key skips the rest; it is read and dropped)
    fn pause(&mut self, t: f64) -> bool {
        match self.src.byte(Duration::from_secs_f64(t)) {
            Some(b) => {
                super::keys::read_char(&mut self.src, b);
                false
            }
            None => true,
        }
    }

    /// typed ROW COLOUR TEXT: one character at a time, like a slow modem
    fn typed(&mut self, row: i64, left: i64, colour: &[u8], text: &[u8]) -> bool {
        term::out(&cat(&[&at(row, left), colour]));
        for ch in chars(text) {
            term::out(ch);
            if !self.pause(0.02) {
                return false;
            }
        }
        term::out(R);
        true
    }

    /// splash: the dial-up welcome. Any key skips it.
    pub(super) fn splash(&mut self) {
        let (cols, rows) = term::size().unwrap_or((80, 30));
        let top = ((rows - 13) / 2).max(1);
        let left = ((cols - 44) / 2).max(1);
        term::out(b"\x1b[2J");
        for i in 0..6 {
            let r = self.c.p.big_rows.get(i).cloned().unwrap_or_default();
            term::out(&cat(&[&at(top + i as i64, left), &r]));
        }
        let t = top + 8;
        let user = sh::env("USER").filter(|u| !u.is_empty()).unwrap_or_else(|| b"friend".to_vec());
        let welcome = cat(&[b"Welcome to the tmux-revive BBS, ", &user, b"!"]);
        let _ = self.typed(t, left, GRY, b"ATDT 1-800-REVIVE")
            && self.pause(0.3)
            && self.typed(t + 1, left, GRY, b"RINGING...")
            && self.pause(0.4)
            && self.typed(t + 2, left, &cat(&[B, BGRN]), b"CONNECT 33600/ARQ/V.42bis")
            && self.pause(0.25)
            && self.typed(t + 4, left, &cat(&[B, BCYN]), &welcome)
            && self.pause(0.9);
        term::out(b"\x1b[2J");
    }
}
