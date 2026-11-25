//! PANES: scripts/panel.sh ver_lt, wait_colour, lim_when, tab_next, wstyle, panes_rows, nav_at,
//! state_cell, draw_panes and ctx_cell (plan Phase 1.3, step 4). Each says which bash function
//! it is; the order is the file's.

use super::*;
use crate::compat::{blen, case_map, itoa, pad, strftime, sub_prefix, substr, Bytes};
use std::collections::HashMap;

/// `${s%%:*}`: up to the first `:`
fn before_colon(s: &[u8]) -> &[u8] {
    match s.iter().position(|&c| c == b':') {
        Some(i) => &s[..i],
        None => s,
    }
}
/// `${s##*/}`: after the last `/`
pub fn base_name(s: &[u8]) -> &[u8] {
    match s.iter().rposition(|&c| c == b'/') {
        Some(i) => &s[i + 1..],
        None => s,
    }
}
/// `[[ $s =~ ^[0-9]+$ ]]`
pub fn all_digits(s: &[u8]) -> bool {
    !s.is_empty() && s.iter().all(u8::is_ascii_digit)
}
/// `${s/PAT/REP}`, PAT literal: the first PAT replaced
pub fn sub_first(s: &[u8], pat: &[u8], rep: &[u8]) -> Bytes {
    match s.windows(pat.len().max(1)).position(|w| w == pat) {
        Some(i) if !pat.is_empty() => [&s[..i], rep, &s[i + pat.len()..]].concat(),
        _ => s.to_vec(),
    }
}
/// `${s//PAT/REP}`, PAT literal: every PAT replaced, left to right
pub fn sub_all(s: &[u8], pat: &[u8], rep: &[u8]) -> Bytes {
    if pat.is_empty() {
        return s.to_vec();
    }
    let mut out = Vec::with_capacity(s.len());
    let mut i = 0;
    while i < s.len() {
        if s[i..].starts_with(pat) {
            out.extend_from_slice(rep);
            i += pat.len();
        } else {
            out.push(s[i]);
            i += 1;
        }
    }
    out
}
/// `[[ $hay == *"NEEDLE"* ]]`
pub fn contains(hay: &[u8], needle: &[u8]) -> bool {
    needle.is_empty() || hay.windows(needle.len()).any(|w| w == needle)
}

/// ver_lt A B: is version A older than B? (`IFS=. read -ra`, then `10#` each of three parts)
pub fn ver_lt(a: &[u8], b: &[u8]) -> bool {
    let pa = crate::compat::read_split(a, b'.');
    let pb = crate::compat::read_split(b, b'.');
    let part = |v: &Vec<Bytes>, i: usize| -> i64 {
        let s = v.get(i).cloned().unwrap_or_default();
        crate::compat::arith_int(&[b"10#".as_slice(), &s].concat()).unwrap_or(0)
    };
    for i in 0..3 {
        if part(&pa, i) < part(&pb, i) {
            return true;
        }
        if part(&pa, i) > part(&pb, i) {
            return false;
        }
    }
    false
}

/// What wait_colour leaves: WCOL, WIDLE, WAGENT, WUNK
pub struct Wait {
    pub col: Bytes,
    pub idle: bool,
    pub agent: bool,
    pub unk: bool,
}

impl Ctx {
    /// wait_colour ROW -> WCOL, WIDLE, WAGENT, WUNK: WAITING ON YOU's colour, by how long ago
    /// the turn began (W_SINCE) and who began it (W_FROM)
    pub fn wait_colour(&self, row: &[u8]) -> Wait {
        let mut w = Wait { col: BGRN.to_vec(), idle: false, agent: false, unk: false };
        let mut s: &[u8] = b"";
        if all_digits(row) {
            s = self.p.a("W_SINCE", num(row));
        }
        if s.is_empty() {
            w.unk = true;
            return w;
        }
        let a = self.p.now.wrapping_sub(num(s));
        if a >= 5400 {
            w.idle = true;
            return w;
        }
        let from = self.p.a("W_FROM", num(row));
        if from == b"a" {
            w.agent = true;
            return w;
        }
        if from != b"u" {
            return w;
        }
        w.col = if a < 600 {
            cat(&[B, b"\x1b[38;5;118m"])
        } else if a < 2700 {
            b"\x1b[38;5;118m".to_vec()
        } else {
            b"\x1b[38;5;156m".to_vec()
        };
        w
    }

    /// lim_when EPOCH -> LWHEN: when a limit lifts, as short as it goes: 10:10pm today, with its
    /// date another day (Nov 23 3pm)
    pub fn lim_when(&self, at: &[u8]) -> Bytes {
        if !all_digits(at) {
            return Vec::new();
        }
        let e = num(at);
        let d = strftime(b"%Y%m%d", e);
        let n = strftime(b"%Y%m%d", self.p.now);
        let mut t = strftime(b"%I:%M%p", e);
        // t=${t#0} t=${t,,} t=${t/:00/}
        if t.first() == Some(&b'0') {
            t.remove(0);
        }
        t = case_map(&t, false);
        t = sub_first(&t, b":00", b"");
        if d == n {
            t
        } else {
            let d = strftime(b"%b %d", e);
            cat(&[&sub_first(&d, b" 0", b" "), b" ", &t])
        }
    }

    /// lim_left EPOCH -> LLEFT: how long until a limit lifts, counting down: whole minutes,
    /// rounded up (so never 0m while it holds), as 12m, 3h 20m, and past a day 2d 4h
    pub fn lim_left(&self, at: &[u8]) -> Bytes {
        if !all_digits(at) {
            return Vec::new();
        }
        let s = (num(at) - self.p.now).max(0);
        let m = (s + 59) / 60;
        let (d, h, m) = (m / 1440, m % 1440 / 60, m % 60);
        let t = if d != 0 {
            if h != 0 { format!("{d}d {h}h") } else { format!("{d}d") }
        } else if h != 0 {
            if m != 0 { format!("{h}h {m}m") } else { format!("{h}h") }
        } else {
            format!("{m}m")
        };
        t.into_bytes()
    }

    /// tab_next [STEP] -> NEXTW: the window J (STEP 1) or K (3) moves the focus to
    pub fn tab_next(&self, step: i64) -> i64 {
        let mut f = self.p.focus;
        for _ in 0..4 {
            f = (f + step) % 4;
            let won = if (0..4).contains(&f) { self.p.won[f as usize] } else { 0 };
            if won != 0 {
                return f;
            }
        }
        self.p.focus
    }

    /// wstyle ASKING -> WF, WB, WK: the focused window, each window's border colour and the key
    /// hint on its title
    pub fn wstyle(&mut self, asking: bool) {
        self.p.wf = self.p.focus;
        self.p.wb = [FRAME.to_vec(), FRAME.to_vec(), FRAME.to_vec(), FRAME.to_vec()];
        self.p.wk = Default::default();
        if self.p.answering != 0 {
            self.p.wf = 1;
        }
        let wf = self.p.wf.rem_euclid(4) as usize; // WB[WF]: WF is 0-3 (a FOCUS the frame has)
        if self.p.wf == 1 && asking {
            self.p.wb[1] = BMAG.to_vec();
        } else {
            self.p.wb[wf] = BCYN.to_vec();
        }
        if self.p.answering != 0 {
            return;
        }
        let nj = self.tab_next(1);
        let nk = self.tab_next(3);
        if nj == self.p.focus {
            return;
        }
        if nk == nj {
            self.p.wk[nj as usize] = self.kc("⇧J/⇧K".as_bytes(), b" focus");
            return;
        }
        self.p.wk[nj as usize] = self.kc("⇧J".as_bytes(), b" focus");
        self.p.wk[nk as usize] = self.kc("⇧K".as_bytes(), b" focus");
    }

    /// `${FOLD[$h]:-}` is set
    pub fn folded(&self, h: &[u8]) -> bool {
        !self.p.assoc("FOLD", h).is_empty()
    }

    /// panes_rows -> NAV: the PANES list top down, a pane's index or a computer's heading (an
    /// empty HOST for this computer's); a folded computer's panes left out
    pub fn panes_rows(&mut self) {
        let mut nav = Vec::new();
        let mut g: Option<Bytes> = None; // "-": no heading yet
        let n = self.p.alen("P_ID");
        for i in 0..n {
            let h = self.p.a("P_HOST", i).to_vec();
            if self.p.p_groups != 0 && g.as_deref() != Some(&h[..]) {
                g = Some(h.clone());
                nav.push(Nav::Head(h.clone()));
            }
            if !h.is_empty() && self.folded(&h) {
                continue;
            }
            nav.push(Nav::Pane(i));
        }
        self.p.nav = nav;
    }

    /// nav_at -> NAT: where the selection is in NAV
    pub fn nav_at(&mut self) {
        self.p.nat = 0;
        for (i, e) in self.p.nav.iter().enumerate() {
            if !self.p.hsel.is_empty() {
                if *e == Nav::Head(self.p.hsel.clone()) {
                    self.p.nat = i as i64;
                    return;
                }
            } else if *e == Nav::Pane(self.p.sel) {
                self.p.nat = i as i64;
                return;
            }
        }
    }

    /// state_cell STATE [ROW] -> CELL, CPAD: coloured status, 18 characters wide (20 with CPAD
    /// where draw_panes's sw is set). ROW None: no row given.
    pub fn state_cell(&mut self, state: &[u8], row: Option<i64>, sw: i64) -> Bytes {
        self.p.cpad = b"  ".to_vec();
        let spin = |t: i64| -> &'static str {
            const SPIN: [&str; 4] = ["▖", "▘", "▝", "▗"];
            SPIN[(t % 4).rem_euclid(4) as usize]
        };
        let row_s: Bytes = row.map(itoa).unwrap_or_default();
        match state {
            b"asking" => cat(&[B, BMAG, BLINK, b"?", R, B, BMAG, b" NEEDS ANSWER    ", R]),
            b"grant" => cat(&[B, BMAG, BLINK, "⚑ [G]RANT ACCESS".as_bytes(), R, b"  "]),
            b"working" | b"agents" => cat(&[BYEL, spin(self.tick).as_bytes(), b" WORKING         ", R]),
            b"waiting" => {
                let w = self.wait_colour(&row_s);
                if w.unk {
                    cat(&[GRY, b"  ---             ", R])
                } else if row.is_some() && !self.p.a("P_SRV", row.unwrap()).is_empty() {
                    if w.idle {
                        cat(&[GRY, "◇ IDLE · server   ".as_bytes(), R])
                    } else {
                        cat(&[&w.col, "◆ WAITING · server".as_bytes(), R])
                    }
                } else if w.idle {
                    cat(&[GRY, "◇ IDLE            ".as_bytes(), R])
                } else if w.agent && sw != 0 {
                    self.p.cpad = b" ".to_vec();
                    cat(&[&w.col, "◆ AGENT'S TURN DONE".as_bytes(), R])
                } else if w.agent {
                    cat(&[&w.col, "◆ AGENT TURN DONE ".as_bytes(), R])
                } else {
                    cat(&[&w.col, "◆ WAITING ON YOU  ".as_bytes(), R])
                }
            }
            b"limit" => {
                // lim_left "${2:+${P_LIM[$2]:-}}"
                let at: Bytes = match row {
                    Some(r) => self.p.a("P_LIM", r).to_vec(),
                    None => Vec::new(),
                };
                let left = self.lim_left(&at);
                let cell: Bytes = if left.is_empty() {
                    "◷ USAGE LIMIT".as_bytes().to_vec()
                } else {
                    cat(&["◷ BACK IN ".as_bytes(), &left])
                };
                let mut f = self.fld(&cell, 18);
                if blen(&cell) > 18 {
                    f = self.fld(&cell, 19);
                    self.p.cpad = b" ".to_vec();
                }
                cat(&[b"\x1b[38;5;214m", &f, R])
            }
            b"ready" => {
                if row.is_some() && self.p.a("P_LWHY", row.unwrap()) == b"plan" {
                    cat(&[B, b"\x1b[38;5;118m", "◆ READY · NEW PLAN".as_bytes(), R])
                } else {
                    cat(&[B, b"\x1b[38;5;118m", "◆ READY TO RESUME ".as_bytes(), R])
                }
            }
            b"shell" => cat(&[GRY, "· shell           ".as_bytes(), R]),
            b"self" => cat(&[BBLU, "✦ this panel      ".as_bytes(), R]),
            b"linked" => cat(&[GRY, "◌ linked          ".as_bytes(), R]),
            b"unreachable" => cat(&[BRED, "◌ unreachable     ".as_bytes(), R]),
            b"login" => cat(&[BYEL, "◌ needs login · B ".as_bytes(), R]),
            _ => cat(&[CYN, "▸ running         ".as_bytes(), R]),
        }
    }

    /// The pane's folder as PANES shows it: `${P_DIR[i]/#$HOME/\~}`, then `${folder##*/}`
    fn folder_of(&self, i: i64) -> Bytes {
        let f = sub_prefix(self.p.a("P_DIR", i), &self.p.home, b"~");
        base_name(&f).to_vec()
    }

    /// draw_panes: PANES's column header and its rows, PH of them from PO, with a scroll bar
    pub fn draw_panes(&mut self) {
        let n = self.p.alen("P_ID");
        let (mut wide, mut nw, mut fw, mut kw, mut uw, mut vw, mut aw, mut us, mut as_) = (1i64, 10i64, 10i64, 3i64, 4i64, 3i64, 7i64, 1i64, 0i64);
        // Who waits for access (G): each introduction's sender, as NAME@HOST.
        let mut gw: Bytes = b" ".to_vec();
        // [[ -n $SNAP ]] || intros_look
        let intros = match self.live.as_mut() {
            Some(l) => l.intros(),
            None => self.p.list("INTROS"),
        };
        for f in intros {
            gw.extend_from_slice(&f);
            gw.push(b' ');
        }
        let mut lab: HashMap<i64, Bytes> = HashMap::new();
        let mut nm: HashMap<i64, Bytes> = HashMap::new();
        let mut ver: HashMap<i64, Bytes> = HashMap::new();
        let mut stc: HashMap<i64, Bytes> = HashMap::new();
        let mut need: HashMap<i64, i64> = HashMap::new();
        let mut ses: HashMap<Bytes, Bytes> = HashMap::new();
        let mut many: HashMap<Bytes, i64> = HashMap::new();
        let mut cnt: HashMap<Bytes, i64> = HashMap::new();
        let mut needc: HashMap<Bytes, i64> = HashMap::new();
        // Which computers (this one is @) have more than one tmux session.
        for i in 0..n {
            let loc = self.p.a("P_LOC", i);
            if loc.is_empty() {
                continue;
            }
            let v = before_colon(loc).to_vec();
            let key = cat(&[b"@", self.p.a("P_HOST", i)]);
            let e = ses.entry(key.clone()).or_insert_with(|| v.clone());
            if *e != v {
                many.insert(key, 1);
            }
        }
        for i in 0..n {
            let name: Bytes = if !self.p.a("P_NAME", i).is_empty() {
                self.p.a("P_NAME", i).to_vec()
            } else if !self.p.a("P_LOC", i).is_empty() && many.contains_key(&cat(&[b"@", self.p.a("P_HOST", i)])) {
                before_colon(self.p.a("P_LOC", i)).to_vec()
            } else {
                b"---".to_vec()
            };
            nm.insert(i, name.clone());
            let folder = self.folder_of(i);
            if blen(&name) > nw {
                nw = blen(&name);
            }
            if blen(&folder) > fw {
                fw = blen(&folder);
            }
            let l: Bytes = if !self.p.a("P_WP", i).is_empty() {
                self.p.a("P_WP", i).to_vec()
            } else if i < 9 {
                itoa(i + 1)
            } else {
                Vec::new()
            };
            if blen(&l) + 2 > kw {
                kw = blen(&l) + 2;
            }
            lab.insert(i, l);
            // VER: the row's user's tmux-revive, or [U]
            let mut v = self.p.a("P_INST", i).to_vec();
            let h = self.p.a("P_HOST", i).to_vec();
            if v == b"owner" {
                v = self.p.version.clone();
                if !h.is_empty() {
                    v = self.p.assoc("RVER", &h).to_vec();
                    if !crate::compat::re(r"^[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}$").is_match(&v) {
                        v = Vec::new();
                    }
                }
            } else if v.is_empty() && !self.p.a("P_USER", i).is_empty() {
                v = b"[U]".to_vec();
            } else if !h.is_empty() && !self.p.a("P_RID", i).is_empty() && self.p.assoc("ROWNER", &h).is_empty() {
                v = b"[U]".to_vec();
            }
            if blen(&v) > vw {
                vw = blen(&v);
            }
            ver.insert(i, v.clone());
            if blen(self.p.a("P_USER", i)) > uw {
                uw = blen(self.p.a("P_USER", i));
            }
            let acct = self.p.a("P_ACCT", i).to_vec();
            if !acct.is_empty() {
                as_ = 1;
            }
            if blen(&acct) > aw {
                aw = blen(&acct);
            }
            // Its agent waiting for access through here
            let mut st = self.p.a("P_STATE", i).to_vec();
            let pname = self.p.a("P_NAME", i);
            if st != b"asking" && !pname.is_empty() {
                let at: Bytes = if !h.is_empty() {
                    h.clone()
                } else {
                    match &self.p.agent_say_host {
                        Some(a) if !a.is_empty() => a.clone(),
                        _ => self.p.host.clone(),
                    }
                };
                if contains(&gw, &cat(&[b" ", pname, b"@", &at, b" "])) {
                    st = b"grant".to_vec();
                }
            }
            let key: Bytes = if h.is_empty() { b".".to_vec() } else { h.clone() };
            *cnt.entry(key.clone()).or_insert(0) += 1;
            need.insert(i, 0);
            // draw_panes: `${ver[i]} == "[U]"`, a row whose user has no tmux-revive needs you too
            if st == b"asking" || st == b"grant" || st == b"ready" || ver.get(&i).map_or(false, |x| x.as_slice() == b"[U]") {
                need.insert(i, 1);
                *needc.entry(key).or_insert(0) += 1;
            }
            stc.insert(i, st);
        }
        if nw > 29 {
            nw = 29;
        }
        if fw > 35 {
            fw = 35;
        }
        if uw > 10 {
            uw = 10;
        }
        if aw > 12 {
            aw = 12;
        }
        if vw > 11 {
            vw = 11;
        }
        let ph = self.p.ph;
        let tot = self.p.nav.len() as i64;
        let mut cw = self.iw;
        if tot > ph {
            cw = self.iw - 1;
        }
        let mut extra = uw + vw + 2 + if as_ != 0 { aw + 1 } else { 0 };
        let mut gwid = cw - 67 - kw - nw - fw - extra;
        // STATE is 20 wide, room for AGENT'S TURN DONE and a gap; 18 when the panel is narrow
        let mut sw = 2;
        let v = if 13 - gwid < fw - 10 { 13 - gwid } else { fw - 10 };
        if v > 0 {
            fw -= v;
            gwid += v;
        }
        let v = if 13 - gwid < nw - 10 { 13 - gwid } else { nw - 10 };
        if v > 0 {
            nw -= v;
            gwid += v;
        }
        if gwid < 13 {
            wide = 0;
            sw = 0;
            nw = cw - 63 - kw - extra;
        }
        if nw < 10 && as_ != 0 {
            as_ = 0;
            nw = nw + aw + 1;
            extra = extra - aw - 1;
        }
        if nw < 10 {
            us = 0;
            nw += extra;
        }
        // The header, from the same widths as the rows.
        let mut hdr = self.fld(b" #", kw + 3);
        hdr.extend(self.fld(b"NAME", nw + 1));
        if us != 0 {
            hdr.extend(self.fld(b"USER", uw + 1));
            if as_ != 0 {
                hdr.extend(self.fld(b"ACCOUNT", aw + 1));
            }
            hdr.extend(self.fld(b"VER", vw + 1));
        }
        hdr.extend(self.fld(b"APP", 10));
        hdr.extend(self.fld(b"STATE", 18 + sw));
        if wide != 0 {
            hdr.extend(self.fld(b"FOLDER", fw + 1));
            hdr.extend(self.fld(b"GIT", gwid + 1));
        }
        hdr.extend(self.fld(b"CPU", 13));
        hdr.extend_from_slice(b"   MEM  ");
        hdr.extend(self.fld(b"CTX LEFT", 10));
        if tot > ph {
            self.rbar = b" ".to_vec();
        }
        self.row(&cat(&[GRY, &hdr, R]), None);
        self.rbar = Vec::new();
        // The list's rows (NAV's order), and which need you.
        let mut lr: Vec<Bytes> = Vec::new();
        let mut ln: Vec<i64> = Vec::new();
        let nav = self.p.nav.clone();
        for en in &nav {
            let i = match en {
                Nav::Head(group) => {
                    if group.is_empty() {
                        lr.push(cat(&[BLU, "▓▒░".as_bytes(), R, b" ", B, BWHT, &case_map(&self.p.host, true), R, b" ", GRY, "· this computer".as_bytes(), R]));
                        ln.push(0);
                        continue;
                    }
                    let c = cnt.get(group).copied().unwrap_or(0);
                    let mut mark = if self.p.hsel == *group {
                        cat(&[BYEL, "▶".as_bytes(), R, BLU, "▒░".as_bytes(), R, b" ", REV, B, BCYN, &case_map(group, true), R])
                    } else {
                        cat(&[BLU, "▓▒░".as_bytes(), R, b" ", B, BWHT, &case_map(group, true), R])
                    };
                    // Its link working, or not: then the key that makes it again (B), whatever the reason.
                    if self.p.assoc("LUP", group) == b"1" {
                        mark.extend(cat(&[b" ", GRY, "· linked · ".as_bytes(), &itoa(c), b" pane"]));
                    } else {
                        mark.extend(cat(&[b" ", GRY, "· not connected ·".as_bytes(), R, b" ", BBLU, b"[", B, BYEL, b"B", R, BBLU, b"]", R, BWHT, b"ridge", R, b" ", GRY, "· ".as_bytes(), &itoa(c), b" pane"]));
                    }
                    if c != 1 {
                        mark.push(b's');
                    }
                    mark.extend_from_slice(R);
                    let nc = needc.get(group).copied().unwrap_or(0);
                    if nc != 0 {
                        mark.extend(cat(&[b" ", GRY, "·".as_bytes(), R, b" ", B, BMAG, &itoa(nc), b" needs you", R]));
                    }
                    lr.push(mark);
                    ln.push((nc > 0) as i64);
                    continue;
                }
                Nav::Pane(i) => *i,
            };
            let name = nm.get(&i).cloned().unwrap_or_default();
            let l = lab.get(&i).cloned().unwrap_or_default();
            let p = pad(kw - blen(&l) - 2);
            let key = if !l.is_empty() { cat(&[BBLU, b"[", BWHT, B, &l, R, BBLU, b"]", R, &p]) } else { cat(&[GRY, " ·".as_bytes(), R, &p]) };
            let folder = self.folder_of(i);
            let git = self.p.a("P_GIT", i).to_vec();
            let mut cells = cat(&[&key, b" "]);
            let sl = self.p.hsel.is_empty() && i == self.p.sel;
            cells.extend_from_slice(if sl { b"\x1b[93m\xe2\x96\xb6\x1b[0m" } else { b" " });
            cells.push(b' ');
            let f = self.fld(&name, nw);
            if sl {
                cells.extend(cat(&[REV, BCYN, &f, R, b" "]));
            } else if self.p.a("P_NAME", i).is_empty() {
                cells.extend(cat(&[GRY, &f, R, b" "]));
            } else {
                cells.extend(cat(&[BWHT, &f, R, b" "]));
            }
            if us != 0 {
                let f = self.fld(self.p.a("P_USER", i), uw);
                cells.extend(cat(&[CYN, &f, R, b" "]));
                if as_ != 0 {
                    let f = self.fld(self.p.a("P_ACCT", i), aw);
                    cells.extend(cat(&[CYN, &f, R, b" "]));
                }
                let v = ver.get(&i).cloned().unwrap_or_default();
                let f = self.fld(&v, vw);
                if v == b"[U]" || (!v.is_empty() && !self.p.version.is_empty() && ver_lt(&v, &self.p.version)) {
                    cells.extend(cat(&[BYEL, &f, R, b" "]));
                } else {
                    cells.extend(cat(&[GRY, &f, R, b" "]));
                }
            }
            let f = self.fld(self.p.a("P_APP", i), 9);
            if num(self.p.a("P_AGENT", i)) != 0 {
                cells.extend(cat(&[BCYN, &f, R, b" "]));
            } else {
                cells.extend(cat(&[CYN, &f, R, b" "]));
            }
            let st = stc.get(&i).cloned().unwrap_or_default();
            let cell = self.state_cell(&st, Some(i), sw);
            cells.extend(cell);
            if sw != 0 {
                cells.extend(self.p.cpad.clone());
            }
            if wide != 0 {
                let f = self.fld(&folder, fw);
                cells.extend(cat(&[BBLU, &f, R, b" "]));
                let f = self.fld(&git, gwid);
                if git.last() == Some(&b'*') {
                    cells.extend(cat(&[BYEL, &f, R, b" "]));
                } else {
                    cells.extend(cat(&[GRN, &f, R, b" "]));
                }
            }
            // Names-only rows from a link have nothing measured: CPU and memory blank.
            let pst = self.p.a("P_STATE", i);
            if pst != b"linked" && pst != b"unreachable" && pst != b"login" {
                let cpu = self.p.a("P_CPU", i).to_vec();
                let meter = self.meter(&cpu);
                let human = self.human(num(self.p.a("P_MEM", i)));
                // printf -v num '%4s%%  %6s'
                let numc = cat(&[&pad((4 - blen(&cpu)).max(0)), &cpu, b"%  ", &pad((6 - blen(&human)).max(0)), &human]);
                cells.extend(cat(&[BCYN, &meter, R, b" ", &numc]));
                let cc = self.ctx_cell(self.p.a("P_CTX", i), self.p.a("P_AGENT", i));
                cells.extend(cat(&[b"  ", &cc]));
            }
            lr.push(cells);
            ln.push(need.get(&i).copied().unwrap_or(0));
        }
        if n == 0 {
            self.row(&cat(&[GRY, b"  no tmux panes found", R]), None);
            return;
        }
        // The window: PH rows from PO, moved just enough to keep the selection in view.
        self.nav_at();
        let nat = self.p.nat;
        if nat < self.p.po {
            self.p.po = nat;
        }
        if nat >= self.p.po + ph {
            self.p.po = nat - ph + 1;
        }
        if self.p.po > tot - ph {
            self.p.po = tot - ph;
        }
        if self.p.po < 0 {
            self.p.po = 0;
        }
        let po = self.p.po;
        let (mut up, mut dn) = (0, 0);
        for i in 0..tot {
            if ln[i as usize] == 0 {
                continue;
            }
            if i < po {
                up = 1;
            }
            if i >= po + ph {
                dn = 1;
            }
        }
        let wb0 = self.p.wb[0].clone();
        let sb: BTreeMap<i64, Bytes> = self.sbar(ph, tot, po, up, dn, Some(&wb0)).into_iter().collect();
        let mut i = 0;
        while i < ph && po + i < tot {
            self.rbar = sb.get(&i).cloned().unwrap_or_default();
            let mut c = lr[(po + i) as usize].clone();
            if self.p.wf == 0 && po + i == nat {
                let mut w = self.iw;
                if !self.rbar.is_empty() {
                    w = self.iw - 1;
                }
                let mut vl = self.vlen(&c);
                if vl > w {
                    c = self.trim_colored(&c, w);
                    vl = w;
                }
                let p = pad(w - vl);
                c = cat(&[SELBG, &sub_all(&c, R, &cat(&[R, SELBG])), &p, R]);
                self.row(&c, Some(w));
            } else {
                self.row(&c, None);
            }
            i += 1;
        }
        self.rbar = Vec::new();
    }

    /// ctx_cell PERCENT AGENT -> CTX_CELL: context left as a meter, red as it runs out; a dash
    /// for an agent that keeps no count, nothing for anything else
    pub fn ctx_cell(&self, pct: &[u8], agent: &[u8]) -> Bytes {
        if pct.is_empty() {
            if num(agent) != 0 {
                return cat(&[GRY, "·····    –".as_bytes(), R]);
            }
            return Vec::new();
        }
        let p = num(pct);
        let c = if p <= 15 {
            BRED
        } else if p <= 40 {
            BYEL
        } else {
            BGRN
        };
        let m = self.meter(pct);
        // printf -v CTX_CELL '%s %3s%%'
        cat(&[c, &m, R, b" ", &pad((3 - blen(pct)).max(0)), pct, b"%"])
    }
}

/// `${s:a:b}` in characters (b None: to the end), never failing (the frame's offsets are in range)
pub fn sub(s: &[u8], a: i64, b: Option<i64>) -> Bytes {
    substr(s, a, b).unwrap_or_default()
}
