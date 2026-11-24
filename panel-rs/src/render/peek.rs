//! The peek: scripts/panel.sh tip_line and TIPS, pane_screen, remote_peek, draw_peek, blank_tail,
//! peek_wrap (PW_STUB) and peek_rows (plan Phase 1.3, step 5). The screens come from the
//! snapshot (SCREEN, SCREEN_E, RPEEK), as bash's pane_screen and remote_peek take them under
//! REVIVE_PANEL_SNAP.

use super::panes::sub;
use super::*;
use crate::compat::{blen, clean, pad, re, remove_all, Bytes, Set};

/// TIPS: one at a time under the hidden peek's title
pub const TIPS: [&str; 14] = [
    "Turn [P]eek on to preview a selected session.",
    "[U]pdate Revive on all open sessions. Some user sessions require a manual update.",
    "[B]ridge a server so that its code sessions are discoverable.",
    "[N]ame a Tmux pane so other code sessions can reference it.",
    "Send a [M]essage to any connected code session.",
    "[O]pen the selected Tmux pane on this computer and work in it.",
    "When a code session asks a question, press [Enter] and answer from the peek window.",
    "[G]rant access when one code session requests to talk to another.",
    "[⇧J] and [⇧K] move between windows. [j] and [k] move inside one.",
    "[0]-[9] jump to a tmux window. [0] is window 10.",
    "[D]etach and come back anytime. Every session, Claude too, picks up where it left off.",
    "[S]ave a snapshot now. It also saves on its own when you [D]etach.",
    "[A]rt changes the artwork. [?] opens help.",
    "Computer shut down mid-task? After the restart, Revive asks each session to pick up where it left off.",
];

/// PW_STUB: overflow that's only blanks or box drawing
pub const PW_STUB: &str = "^[[:space:]─━═╌│┃╭╮╯╰┌┐└┘├┤┬┴┼]*$";

/// `[[ -z ${s//[[:space:]CHARS]/} ]]`
pub fn blank(s: &[u8], chars: &[u8]) -> bool {
    remove_all(s, Set::SpaceOr(chars)).is_empty()
}

impl Ctx {
    /// tip_line -> TIPL: this moment's tip, centered in the panel's width and coloured
    pub fn tip_line(&self) -> Bytes {
        let n = TIPS.len() as i64;
        let i = (self.p.secs / self.p.tip_secs) % n;
        let mut t: &[u8] = b"";
        for j in 0..n {
            t = TIPS[(i + j).rem_euclid(n) as usize].as_bytes();
            if blen(t) <= self.iw - 2 {
                break;
            }
        }
        if blen(t) > self.iw - 2 {
            t = b"[P]eek";
        }
        let lead = self.rep(b" ", (self.iw - blen(t)) / 2);
        let mut c: Bytes = Vec::new();
        let mut t = t.to_vec();
        // while [[ $t =~ ^([^[]*)\[([^]]+)\](.*)$ ]]
        while let Some(m) = re(r"^([^[]*)\[([^]]+)\](.*)$").matches(&t) {
            c.extend(cat(&[CYN, &m[1], BBLU, b"[", B, BYEL, &m[2], R, BBLU, b"]", R]));
            t = m[3].clone();
        }
        cat(&[&lead, &c, CYN, &t, R])
    }

    /// pane_screen %ID [-e]: the screen the snapshot holds (SCREEN, or SCREEN_E coloured) if
    /// it's of that pane (SCREEN_ID), else none
    pub fn pane_screen(&self, id: &[u8], coloured: bool) -> Vec<Bytes> {
        if self.p.screen_id == id {
            self.p.list(if coloured { "SCREEN_E" } else { "SCREEN" })
        } else {
            Vec::new()
        }
    }

    /// remote_peek LINES -> L: the selected linked pane's screen, or why it can't be shown
    pub fn remote_peek(&mut self, _n: i64) {
        let sel = self.p.sel;
        let h = self.p.a("P_HOST", sel).to_vec();
        let id = self.p.a("P_RID", sel).to_vec();
        self.p.l = vec![Vec::new(), cat(&[b"  on ", &h, b": no peek (update tmux-revive there)"])];
        let st = self.p.a("P_STATE", sel).to_vec();
        if st == b"unreachable" {
            self.p.l = vec![Vec::new(), cat(&[b"  on ", &h, b": can't be reached to peek"])];
        }
        if st == b"login" {
            self.p.l = vec![Vec::new(), cat(&[b"  on ", &h, b": needs login \xc2\xb7 press B to type its password"])];
        }
        if !(re("^[A-Za-z0-9][A-Za-z0-9._-]*$").is_match(&h) && re("^%[0-9]+$").is_match(&id)) {
            return;
        }
        // With a snapshot, what it holds for this pane, if anything.
        let (at, rp) = if self.p.rpeek_for != cat(&[&h, b" ", &id]) { (Vec::new(), Vec::new()) } else { (self.p.rpeek_at.clone(), self.p.list("RPEEK")) };
        if at == b"new" {
            self.p.l = rp.iter().map(|l| sub(&clean(l), 0, Some(500))).collect();
        } else if at != b"fail" {
            self.p.l = vec![Vec::new(), cat(&[b"  on ", &h, b": asking for its screen..."])];
        }
    }

    /// draw_peek LINES: the bottom of the selected pane's screen, or the question it's asking
    pub fn draw_peek(&mut self, lines: i64) {
        let sel = self.p.sel;
        let id = self.p.a("P_ID", sel).to_vec();
        let name: Bytes = if !self.p.a("P_NAME", sel).is_empty() { self.p.a("P_NAME", sel).to_vec() } else { self.p.a("P_LOC", sel).to_vec() };
        let st = self.p.a("P_STATE", sel).to_vec();
        if st == b"asking" {
            self.draw_question(lines);
            return;
        }
        let (mut fc, mut ft): (&[u8], &[u8]) = (b"4", b"");
        if self.p.wf == 1 {
            fc = b"6";
            ft = "▸ ".as_bytes();
        }
        let kc = self.kc(b"p", b" hide");
        let title = if st == b"agents" {
            cat(&[ft, "PEEK · ".as_bytes(), &name, " · agents busy, takes input".as_bytes()])
        } else if st == b"limit" {
            let lw = self.lim_when(&self.p.a("P_LIM", sel).to_vec());
            let back = if lw.is_empty() { Vec::new() } else { cat(&[b", back ", &lw]) };
            cat(&[ft, "PEEK · ".as_bytes(), &name, " · usage limit".as_bytes(), &back])
        } else if st == b"ready" && self.p.a("P_LWHY", sel) == b"plan" {
            cat(&[ft, "PEEK · ".as_bytes(), &name, " · new plan, ready to resume".as_bytes()])
        } else if st == b"ready" {
            cat(&[ft, "PEEK · ".as_bytes(), &name, " · limit lifted, ready to resume".as_bytes()])
        } else if !self.p.a("P_SRV", sel).is_empty() {
            cat(&[ft, "PEEK · ".as_bytes(), &name, " · a server it started runs".as_bytes()])
        } else {
            cat(&[ft, "PEEK · ".as_bytes(), &name])
        };
        let (wb, wk) = (self.p.wb[1].clone(), self.p.wk[1].clone());
        self.sectk(&title, &kc, Some(fc), Some(&wb), Some(&wk));
        self.p.l = Vec::new();
        if !self.p.a("P_HOST", sel).is_empty() {
            self.remote_peek(60); // all it may ask for, to scroll back through
        } else if !id.is_empty() {
            self.p.l = self.pane_screen(&id, false).iter().map(|l| clean(l)).collect();
        }
        self.p.qstyle.clear();
        self.p.qhi.clear();
        self.peek_rows(lines, GRY, false, &wb);
    }

    /// blank_tail ARRAY: more than 3 blank rows at its end cut to 1
    pub fn blank_tail(v: &mut Vec<Bytes>) {
        let mut k = v.len();
        while k > 0 && blank(&v[k - 1], b"") {
            k -= 1;
        }
        if v.len() - k > 3 {
            v.truncate(k + 1);
        }
    }

    /// peek_wrap WIDTH -> PWL, PWS, PWH: L as the box's rows, a line too long for WIDTH carried
    /// on in the rows under it, broken at a space in its second half when there's one
    pub fn peek_wrap(&self, w: i64) -> (Vec<Bytes>, BTreeMap<i64, Bytes>, BTreeMap<i64, Bytes>) {
        let mut pwl: Vec<Bytes> = Vec::new();
        let mut pws: BTreeMap<i64, Bytes> = BTreeMap::new();
        let mut pwh: BTreeMap<i64, Bytes> = BTreeMap::new();
        let stub = re(PW_STUB);
        for (i, line) in self.p.l.iter().enumerate() {
            let i = i as i64;
            let mut s = line.clone();
            let mut o: i64 = 0;
            let mut padv: Bytes = Vec::new();
            loop {
                let k = pwl.len() as i64;
                let r = w - blen(&padv);
                pws.insert(k, self.p.qstyle.get(&i).cloned().unwrap_or_default());
                let sl = blen(&s);
                let (cut, next);
                if sl <= r || stub.is_match(&sub(&s, r, None)) {
                    cut = sl;
                    next = sl;
                } else {
                    let t0 = sub(&s, 0, Some(r + 1));
                    // t=${t% *}: up to the last space that fits
                    let t = match t0.iter().rposition(|&c| c == b' ') {
                        Some(p) => t0[..p].to_vec(),
                        None => t0.clone(),
                    };
                    if t != t0 && !blank(&t, "│".as_bytes()) && blen(&t) > r / 2 {
                        cut = blen(&t);
                        next = cut + 1;
                    } else {
                        cut = r;
                        next = r;
                    }
                }
                pwl.push(cat(&[&padv, &sub(&s, 0, Some(cut))]));
                if let Some(q) = self.p.qhi.get(&i) {
                    let f = crate::compat::read_split(q, b' ');
                    let a = num(f.first().map(|v| v.as_slice()).unwrap_or(b""));
                    let b = num(f.get(1).map(|v| v.as_slice()).unwrap_or(b""));
                    let x = if a > o { a } else { o };
                    let mut y = a + b;
                    if y > o + cut {
                        y = o + cut;
                    }
                    if y > o + r {
                        y = o + r;
                    }
                    if y > x {
                        pwh.insert(k, cat(&[&crate::compat::itoa(x - o + blen(&padv)), b" ", &crate::compat::itoa(y - x)]));
                    }
                }
                if next >= sl {
                    break;
                }
                if o == 0 {
                    // a choice's: under its text
                    let ind = re(r"^[[:space:]│]*(❯[[:space:]]*)?([0-9]+\.[[:space:]]+)?").matches(&s).map(|m| blen(&m[0])).unwrap_or(0);
                    let ind = if ind > w / 2 { 0 } else { ind };
                    padv = pad(ind);
                }
                s = sub(&s, next, None);
                o += next;
            }
        }
        (pwl, pws, pwh)
    }

    /// peek_rows LINES COLOUR STYLED BAR-COLOUR: the bottom of its screen (L), row for row
    pub fn peek_rows(&mut self, h: i64, c: &[u8], styled: bool, barc: &[u8]) {
        let mut w = self.iw - 2;
        let mut vw = self.iw;
        let mut l = std::mem::take(&mut self.p.l);
        Self::blank_tail(&mut l);
        self.p.l = l;
        let (mut pwl, mut pws, mut pwh) = self.peek_wrap(w);
        if pwl.len() as i64 > h && h > 0 {
            (pwl, pws, pwh) = self.peek_wrap(self.iw - 3);
        }
        let n = pwl.len() as i64;
        if self.p.pb > n - h {
            self.p.pb = n - h;
        }
        if self.p.pb < 0 {
            self.p.pb = 0;
        }
        let mut start = n - h - self.p.pb;
        if start < 0 {
            start = 0;
        }
        let sb: BTreeMap<i64, Bytes> = self.sbar(h, n, start, 0, 0, Some(barc)).into_iter().collect();
        if !sb.is_empty() {
            w = self.iw - 3;
            vw = self.iw - 1;
        }
        let mut i = n;
        while i < h {
            self.row(&cat(&[c, "│".as_bytes(), R]), None);
            i += 1;
        }
        let mut i = 0;
        while i < h && start + i < n {
            self.rbar = sb.get(&i).cloned().unwrap_or_default();
            let f = self.fld(&pwl[(start + i) as usize], w);
            let st: Bytes = if styled {
                match pws.get(&(start + i)) {
                    Some(s) if !s.is_empty() => s.clone(),
                    _ => BWHT.to_vec(),
                }
            } else {
                DIM.to_vec()
            };
            match pwh.get(&(start + i)).filter(|_| styled) {
                Some(hb) => {
                    let fl = crate::compat::read_split(hb, b' ');
                    let a = num(fl.first().map(|v| v.as_slice()).unwrap_or(b""));
                    let b = num(fl.get(1).map(|v| v.as_slice()).unwrap_or(b""));
                    let line = cat(&[c, "│".as_bytes(), R, b" ", &st, &sub(&f, 0, Some(a)), QBAND, B, BWHT, &sub(&f, a, Some(b)), R, &st, &sub(&f, a + b, None), R]);
                    self.row(&line, Some(vw));
                }
                None => {
                    let line = cat(&[c, "│".as_bytes(), R, b" ", &st, &f, R]);
                    self.row(&line, Some(vw));
                }
            }
            i += 1;
        }
        self.rbar = Vec::new();
    }
}
