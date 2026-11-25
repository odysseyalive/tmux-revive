//! scripts/panel.sh's edit_box, ported literally: a box over the panel to write in, as much as
//! you like (eb_ins, eb_wrap, eb_line, eb_max, eb_move, eb_paint with EB_RE through libc's
//! regcomp as bash's `=~` is, eb_draw), and text_clean. Every place in the text (cur, VS, VN,
//! PS, PE) counts characters as bash does, so the text is kept as its characters.
//!
//! The box writes its own ?2026 update, which also places and shows the cursor (eb_draw's
//! printf); here those bytes go through Ui::over, which wraps them in the same ?2026h/l, and are
//! painted again over every frame the panel draws under it. While it's open the terminal is
//! `-icrnl -isig` on top of the panel's own `-echo -icanon` (Enter is CR, Ctrl-J is LF, Ctrl-C
//! the byte 0x03), with bracketed paste on (?2004h); both go back on close. Bash reads the keys
//! through a `cat` pipe because its read would put CR-to-LF back for a terminal; here they are
//! read from the terminal as they come, one character at a time, with bash's timeouts.

use super::modal::Rd;
use crate::compat::{blen, c1_set, chars, is_cntrl, is_space, itoa, pad, remove_all, zw_set, Bytes, Set};
use crate::render::{cat, Ctx, B, BCYN, BGRN, BMAG, BWHT, BYEL, GRY, R};
use std::time::Duration;

/// EB_MAX: the most characters the box holds, as text_clean leaves them
pub const EB_MAX: i64 = 10000;

/// EB_SLASH EB_AT EB_CODE EB_URL: the colours of the words eb_paint finds
const EB_SLASH: &[u8] = b"\x1b[1m\x1b[38;5;208m";
const EB_AT: &[u8] = BCYN;
const EB_CODE: &[u8] = BGRN;
const EB_URL: &[u8] = b"\x1b[4m\x1b[95m";
/// EB_RE: a /skill, an @name or @path, `code`, a URL
const EB_RE: &str = "[[:space:](](/[[:alnum:]_:-]+)|[[:space:](](@[^[:space:]`]+)|(`[^`\n]*`)|(https?://[^[:space:]`]+)";

/// text_clean: written text (typed or pasted) as the panel keeps it: line breaks as LF (CR LF
/// and CR become one), and no control characters but LF and tab; no C1 controls, bidi
/// overrides or zero-width characters either (as clean).
pub fn text_clean(t: &[u8]) -> Bytes {
    let t = replace(t, b"\r\n", b"\n");
    let t = replace(&t, b"\r", b"\n");
    let ctl: Vec<u8> = (0x01u8..=0x08).chain(0x0b..=0x1f).chain([0x7f]).collect();
    let t = remove_all(&t, Set::Of(&ctl));
    let t = remove_all(&t, Set::Of(&c1_set()));
    remove_all(&t, Set::Of(&zw_set()))
}

/// `${s//PAT/REP}` for a plain ASCII PAT
fn replace(s: &[u8], pat: &[u8], rep: &[u8]) -> Bytes {
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

/// The text's characters A..A+N (clamped to it), joined
fn sub(t: &[Bytes], a: i64, n: i64) -> Bytes {
    let len = t.len() as i64;
    let a = a.clamp(0, len);
    let e = (a + n.max(0)).min(len);
    t[a as usize..e as usize].concat()
}

/// A key as edit_box's loop has it
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EbKey {
    /// a character typed (Ctrl-J, Tab and the rest of the case's own)
    Ch(Bytes),
    /// Esc and what followed it: "" a lone Esc, CR or LF (Alt-Enter), or a sequence's SEQ
    Esc(Bytes, Bytes),
    /// a paste, its end mark taken off
    Paste(Bytes),
}

/// edit_box's state: the text, the cursor, the rows on show, and the box's place as eb_draw
/// last worked it out
#[derive(Debug, Clone, Default)]
pub struct EditBox {
    pub title: Bytes,
    pub hint: Bytes,
    /// txt, as its characters
    pub txt: Vec<Bytes>,
    pub cur: i64,
    pub vtop: i64,
    pub dirty: bool,
    pub vs: Vec<i64>,
    pub vn: Vec<i64>,
    pub w: i64,
    pub h: i64,
    pub th: i64,
    pub tw: i64,
    pub top: i64,
    pub left: i64,
    pub el: i64,
    pub em: i64,
    pub ps: Vec<i64>,
    pub pe: Vec<i64>,
    pub pc: Vec<&'static [u8]>,
    /// EBC=m: magenta, for answering a question
    pub ebc_m: bool,
    /// TCOLS, TLINES and PEEK_ROW eb_draw last drew it for
    pub drawn_for: (i64, i64, i64),
}

impl EditBox {
    /// edit_box TITLE HINT [TEXT] up to its loop: TEXT cleaned, cut to EB_MAX, the cursor at its end
    pub fn new(title: &[u8], hint: &[u8], text: &[u8], ebc_m: bool) -> EditBox {
        let t = text_clean(text);
        let mut txt: Vec<Bytes> = chars(&t).map(|c| c.to_vec()).collect();
        txt.truncate(EB_MAX as usize);
        let cur = txt.len() as i64;
        EditBox { title: title.to_vec(), hint: hint.to_vec(), txt, cur, dirty: true, ebc_m, ..Default::default() }
    }

    /// The text as typed (REPLY)
    pub fn text(&self) -> Bytes {
        self.txt.concat()
    }

    fn len(&self) -> i64 {
        self.txt.len() as i64
    }

    /// eb_ins TEXT: at the cursor, as much as EB_MAX leaves room for
    pub fn eb_ins(&mut self, s: &[u8]) {
        let room = EB_MAX - self.len();
        if room <= 0 {
            return;
        }
        let mut cs: Vec<Bytes> = chars(s).map(|c| c.to_vec()).collect();
        cs.truncate(room as usize);
        let n = cs.len() as i64;
        let at = self.cur.clamp(0, self.len()) as usize;
        self.txt.splice(at..at, cs);
        self.cur += n;
        self.dirty = true;
    }

    /// eb_wrap -> VS, VN: where each line on screen starts in txt, and its length, wrapped at tw
    pub fn eb_wrap(&mut self) {
        let tw = self.tw.max(1); // (bash loops for ever at a width under 1)
        let mut s = 0i64;
        self.vs.clear();
        self.vn.clear();
        // mapfile -t LN <<<"$txt": the lines between each LF, the last one too
        let mut lines: Vec<&[Bytes]> = Vec::new();
        let mut a = 0;
        for (i, c) in self.txt.iter().enumerate() {
            if c.as_slice() == b"\n" {
                lines.push(&self.txt[a..i]);
                a = i + 1;
            }
        }
        lines.push(&self.txt[a..]);
        for l in lines {
            let mut l: &[Bytes] = l;
            let mut len = l.len() as i64;
            // At the last space that fits (it stays at the line's end), or where it must.
            while len > tw {
                let q = &l[..tw as usize];
                // q=${q% *}
                let ql = q.iter().rposition(|c| c.as_slice() == b" ").map(|i| i as i64).unwrap_or(tw);
                let cut = if ql < tw && ql > 0 { ql + 1 } else { tw };
                self.vs.push(s);
                self.vn.push(cut);
                s += cut;
                l = &l[cut as usize..];
                len -= cut;
            }
            self.vs.push(s);
            self.vn.push(len);
            s += len + 1;
        }
        self.dirty = false;
    }

    /// eb_line -> EL: the line on screen the cursor is on; EM: the last column it may have there
    pub fn eb_line(&mut self) {
        if self.dirty {
            self.eb_wrap();
        }
        let mut j = self.vs.len() as i64 - 1;
        while j > 0 {
            if self.vs[j as usize] <= self.cur {
                break;
            }
            j -= 1;
        }
        self.el = j.max(0);
        self.eb_max(self.el);
    }

    /// eb_max LINE -> EM: a wrapped line's last column is its last character; a line's end, past it
    pub fn eb_max(&mut self, l: i64) {
        let l = l as usize;
        self.em = self.vn[l];
        if l + 1 < self.vs.len() && self.vs[l + 1] == self.vs[l] + self.vn[l] {
            self.em -= 1;
        }
    }

    /// eb_move KEY: Up, Down, PgUp, PgDn (as their sequences), Home, End
    pub fn eb_move(&mut self, k: &[u8]) {
        self.eb_line();
        let el = self.el;
        let mut col = self.cur - self.vs[el as usize];
        let t = match k {
            b"A" => el - 1,
            b"B" => el + 1,
            b"5~" => el - self.th,
            b"6~" => el + self.th,
            b"H" | b"1~" | b"7~" => {
                self.cur = self.vs[el as usize];
                return;
            }
            b"F" | b"4~" | b"8~" => {
                self.cur = self.vs[el as usize] + self.em;
                return;
            }
            _ => el,
        };
        if t < 0 {
            self.cur = 0;
            return;
        }
        if t >= self.vs.len() as i64 {
            self.cur = self.len();
            return;
        }
        self.eb_max(t);
        if col > self.em {
            col = self.em;
        }
        self.cur = self.vs[t as usize] + col;
    }

    /// edit_box's case on a key: Some(true) Enter, Some(false) closed, None go on
    pub fn key(&mut self, k: EbKey) -> Option<bool> {
        match k {
            EbKey::Ch(k) => match k.as_slice() {
                b"\x03" => return Some(false), // Ctrl-C
                b"\r" => return Some(true),    // Enter
                b"\n" => self.eb_ins(b"\n"),   // Ctrl-J
                b"\t" => self.eb_ins(b"\t"),
                b"\x7f" | b"\x08" => {
                    if self.cur > 0 {
                        let c = self.cur as usize;
                        self.txt.remove(c - 1);
                        self.cur -= 1;
                        self.dirty = true;
                    }
                }
                _ if is_cntrl(&k) => {}
                _ => self.eb_ins(&k),
            },
            EbKey::Esc(rest, seq) => {
                match rest.as_slice() {
                    b"" => return Some(false), // a lone Esc closes it
                    b"\r" | b"\n" => self.eb_ins(b"\n"), // Alt-Enter
                    _ => {}
                }
                match seq.as_slice() {
                    b"C" => {
                        if self.cur < self.len() {
                            self.cur += 1;
                        }
                    }
                    b"D" => {
                        if self.cur > 0 {
                            self.cur -= 1;
                        }
                    }
                    b"3~" => {
                        if self.cur < self.len() {
                            self.txt.remove(self.cur as usize);
                            self.dirty = true;
                        }
                    }
                    b"A" | b"B" | b"5~" | b"6~" | b"H" | b"1~" | b"7~" | b"F" | b"4~" | b"8~" => self.eb_move(&seq),
                    _ => {}
                }
            }
            EbKey::Paste(p) => {
                let p = text_clean(&p);
                self.eb_ins(&p);
            }
        }
        None
    }

    /// eb_paint -> PS, PE, PC: the words to colour on the rows on show, where each starts and
    /// ends in txt, and its colour
    pub fn eb_paint(&mut self) {
        self.ps.clear();
        self.pe.clear();
        self.pc.clear();
        let n = self.vs.len() as i64;
        if n == 0 {
            return;
        }
        let (vs, vn) = (&self.vs, &self.vn);
        let th = self.th;
        let vtop = self.vtop;
        let mut last = vtop + th - 1;
        if last >= n {
            last = n - 1;
        }
        let a = vs[vtop as usize];
        let b = vs[last as usize] + vn[last as usize];
        // Only the text near the rows on show is looked at: back to the start of the line the
        // first is part of, on to the end of the last's (a line wraps onto many rows).
        let mut j = vtop;
        while j > 0 && vs[j as usize] == vs[j as usize - 1] + vn[j as usize - 1] {
            j -= 1;
        }
        let ls = vs[j as usize];
        let mut j = last;
        while j + 1 < n && vs[j as usize + 1] == vs[j as usize] + vn[j as usize] {
            j += 1;
        }
        let le = vs[j as usize] + vn[j as usize];
        let txt = &self.txt;
        let mut p = a;
        let mut c0: Bytes = b" ".to_vec();
        if a > ls {
            // Inside `code` that started on a row above: an odd number of backticks before it.
            let t = &txt[ls as usize..a as usize];
            let ticks = t.iter().filter(|c| c.as_slice() == b"`").count();
            c0 = b"x".to_vec();
            if ticks % 2 == 1 {
                let t = &txt[a as usize..le as usize];
                // x=${t%%\`*}
                let x = t.iter().position(|c| c.as_slice() == b"`").unwrap_or(t.len()) as i64;
                if x < t.len() as i64 {
                    self.ps.push(a);
                    self.pe.push(a + x + 1);
                    self.pc.push(EB_CODE);
                    p = a + x + 1;
                }
            }
            if p == a {
                // Otherwise from the start of the word the first row starts in (a URL runs on).
                let mut j = a - ls;
                if j > 1000 {
                    j = 1000;
                }
                let t = &txt[(a - j) as usize..a as usize];
                // x=${t##*[[:space:]\`]}
                let x = match t.iter().rposition(|c| c.as_slice() == b"`" || is_space(c)) {
                    Some(i) => t.len() - i - 1,
                    None => t.len(),
                } as i64;
                p = a - x;
                if p == ls || {
                    let c = &txt[(p - 1) as usize];
                    is_space(c) || c.as_slice() == b"("
                } {
                    c0 = b" ".to_vec();
                }
            }
        }
        let mut end = b + 2000;
        if end > le {
            end = le;
        }
        let seg: &[Bytes] = &txt[p as usize..end.max(p) as usize];
        let ere = crate::compat::re(EB_RE);
        let mut q: i64 = 0;
        while p + q < b {
            // rest[0] stands for the character before seg[q]: a space if a word may start after
            // it. Looked for in the next 256 characters, as matching costs by the length; in all
            // the rest when that might cut a word, or `code`, short.
            let qq = (q.max(0) as usize).min(seg.len());
            let tail = &seg[qq..];
            let mut rest: Bytes = c0.clone();
            rest.extend(tail[..tail.len().min(256)].concat());
            let rest_len = 1 + tail.len().min(256) as i64;
            let mut m: Bytes = Vec::new();
            let mut x: Bytes = Vec::new();
            let mut bm = ere.matches(&rest);
            if let Some(g) = &bm {
                m = g[0].clone();
                x = before(&rest, &m);
            }
            if rest_len > 256 && (m.is_empty() || x.contains(&b'`') || blen(&x) + blen(&m) >= rest_len) {
                rest = c0.clone();
                rest.extend(tail.concat());
                bm = ere.matches(&rest);
                let Some(g) = &bm else { break };
                m = g[0].clone();
                x = before(&rest, &m);
            }
            if m.is_empty() {
                break;
            }
            let g = bm.unwrap();
            let xl = blen(&x);
            let ml = blen(&m);
            let mut st = p + q + xl - 1;
            q = q + xl - 1 + ml;
            c0 = b"x".to_vec();
            let tok: Bytes;
            let col: &'static [u8];
            if !g[1].is_empty() {
                // A /skill ends the word: not /usr/bin, nor /notes.txt.
                let mut tk = g[1].clone();
                st += 1;
                let t = sub(seg, q, 2);
                let tc: Vec<&[u8]> = chars(&t).collect();
                let ok = t.is_empty()
                    || is_space(tc[0])
                    || matches!(tc[0], b"," | b";" | b"!" | b"?" | b")" | b"\"" | b"'")
                    || t == b"."
                    || (tc.len() == 2 && tc[0] == b"." && is_space(tc[1]));
                if !ok {
                    continue;
                }
                while tk.last() == Some(&b':') {
                    tk.pop();
                }
                tok = tk;
                col = EB_SLASH;
            } else if !g[3].is_empty() {
                tok = m.clone();
                col = EB_CODE;
            } else {
                let mut tk;
                if !g[2].is_empty() {
                    tk = g[2].clone();
                    st += 1;
                    col = EB_AT;
                } else {
                    tk = m.clone();
                    col = EB_URL;
                }
                while matches!(tk.last(), Some(b'.' | b',' | b';' | b':' | b'!' | b'?' | b')' | b'"' | b'\'')) {
                    tk.pop();
                }
                tok = tk;
            }
            let tl = blen(&tok);
            if tl <= 1 {
                continue;
            }
            self.ps.push(st);
            self.pe.push(st + tl);
            self.pc.push(col);
        }
    }

    /// eb_draw: the box, centred over the panel, as pick draws its own; the cursor where it
    /// writes. -> what bash's printf sends inside its ?2026h/l: the box, the cursor placed and
    /// shown. TCOLS and TLINES are the panel's as it last drew; PEEK_ROW its peek's first row.
    pub fn eb_draw(&mut self, c: &Ctx, tcols: i64, tlines: i64, peek_row: i64) -> Bytes {
        let (fc, band): (&[u8], i64) = if self.ebc_m { (BMAG, 90) } else { (BCYN, 25) };
        let tb = cat(&[b"\x1b[48;5;", &itoa(band), b"m"]);
        let tf = cat(&[b"\x1b[38;5;", &itoa(band), b"m"]);
        let at = |r: i64, col: i64| cat(&[b"\x1b[", &itoa(r), b";", &itoa(col), b"H"]);
        let mut w = tcols - 8;
        let mut h = tlines - 6;
        if w > 100 {
            w = 100;
        }
        if w < 30 {
            w = tcols - 2;
        }
        if h > 24 {
            h = 24;
        }
        if h < 7 {
            h = tlines - 1;
        }
        let mut th = h - 4;
        let tw = w - 4;
        if th < 1 {
            th = 1;
        }
        let mut top = (tlines - h) / 2;
        let mut left = (tcols - w) / 2;
        // With the peek showing (a question, or the screen you're writing to), the box keeps
        // above it, over PANES, so all of the peek can still be read: 7 rows at least, its
        // shadow too.
        if peek_row > 1 {
            let room = peek_row - 2;
            if h > room {
                h = room;
            }
            if h < 7 {
                h = 7;
            }
            th = h - 4;
            top = (peek_row - 1 - h - 1) / 2 + 1;
        }
        if top < 1 {
            top = 1;
        }
        if left < 1 {
            left = 1;
        }
        if tw != self.tw {
            self.dirty = true; // (bash rewraps after a resize: dirty=1)
        }
        (self.w, self.h, self.th, self.tw, self.top, self.left) = (w, h, th, tw, top, left);
        self.drawn_for = (tcols, tlines, peek_row);
        self.eb_line();
        if self.el < self.vtop {
            self.vtop = self.el;
        }
        if self.el >= self.vtop + th {
            self.vtop = self.el - th + 1;
        }
        self.eb_paint();
        // The title on its band, faded in and out with shade blocks, as a section's is.
        let mut s = c.fld(&self.title, (w - 14).max(0));
        while s.last() == Some(&b' ') {
            s.pop();
        }
        let rep = c.rep("═".as_bytes(), w - blen(&s) - 11);
        let mut buf = cat(&[&at(top, left), fc, "╔═".as_bytes(), R, &tf, "░▒▓".as_bytes(), &tb, B, BWHT, b" ", &s, b" ", R, &tf, "▓▒░".as_bytes(), R, fc, &rep, "╗".as_bytes(), R]);
        let mut k = 0usize;
        let nvs = self.vs.len() as i64;
        for r in 0..th {
            let j = self.vtop + r;
            let mut s: Bytes = Vec::new();
            let mut len = 0i64;
            if j < nvs {
                let rs = self.vs[j as usize];
                len = self.vn[j as usize];
                let t: Vec<Bytes> = self.txt[rs as usize..(rs + len) as usize].iter().map(|c| if c.as_slice() == b"\t" { b" ".to_vec() } else { c.clone() }).collect();
                // The coloured words on this row, or the part of one that's on it.
                while k < self.ps.len() && self.pe[k] <= rs {
                    k += 1;
                }
                let mut pos = 0i64;
                let mut i = k;
                while i < self.ps.len() && self.ps[i] < rs + len {
                    let mut from = self.ps[i] - rs;
                    let mut to = self.pe[i] - rs;
                    if from < 0 {
                        from = 0;
                    }
                    if to > len {
                        to = len;
                    }
                    s.extend(sub(&t, pos, from - pos));
                    s.extend_from_slice(self.pc[i]);
                    s.extend(sub(&t, from, to - from));
                    s.extend_from_slice(R);
                    pos = to;
                    i += 1;
                }
                s.extend(sub(&t, pos, len));
            }
            let t = pad(tw - len);
            let mut edge = cat(&[fc, "║".as_bytes()]);
            if r == 0 && self.vtop > 0 {
                edge = cat(&[BYEL, "▲".as_bytes()]);
            }
            if r == th - 1 && self.vtop + th < nvs {
                edge = cat(&[BYEL, "▼".as_bytes()]);
            }
            buf.extend(cat(&[&at(top + 1 + r, left), fc, "║".as_bytes(), R, b" ", &s, &t, b" ", &edge, R, GRY, "▓".as_bytes(), R]));
        }
        let rep = c.rep("─".as_bytes(), w - 2);
        buf.extend(cat(&[&at(top + 1 + th, left), fc, "╟".as_bytes(), &tf, &rep, fc, "╢".as_bytes(), R, GRY, "▓".as_bytes(), R]));
        let f = c.fld(&self.hint, (w - 4).max(0));
        buf.extend(cat(&[&at(top + 2 + th, left), fc, "║".as_bytes(), R, b" ", BCYN, &f, R, b" ", fc, "║".as_bytes(), R, GRY, "▓".as_bytes(), R]));
        let rep = c.rep("═".as_bytes(), w - 2);
        buf.extend(cat(&[&at(top + 3 + th, left), fc, "╚".as_bytes(), &rep, "╝".as_bytes(), R, GRY, "▓".as_bytes(), R]));
        // A shadow that darkens from the left, under the box and down its right side.
        let rep = c.rep("▓".as_bytes(), w - 2);
        buf.extend(cat(&[&at(top + 4 + th, left + 1), GRY, "░▒".as_bytes(), &rep, R]));
        let row = top + 1 + self.el - self.vtop;
        let col = left + 2 + self.cur - self.vs[self.el as usize];
        buf.extend(cat(&[&at(row, col), b"\x1b[?25h"]));
        buf
    }
}

/// `${rest%%"$m"*}`: REST before the first M in it
fn before(rest: &[u8], m: &[u8]) -> Bytes {
    if m.is_empty() {
        return Vec::new();
    }
    match rest.windows(m.len()).position(|w| w == m) {
        Some(i) => rest[..i].to_vec(),
        None => rest.to_vec(),
    }
}

/// Where edit_box's keys come from and its frames go: the panel live (Ui), a list in tests
pub trait EbIo {
    /// `IFS= read -rn1 -d '' -t T`: one character (CR and LF as themselves), within T (None:
    /// no limit)
    fn ch(&mut self, t: Option<Duration>) -> Result<Bytes, Rd>;
    /// `read -t 0`: a key already waiting
    fn waiting(&mut self) -> bool;
    /// eb_draw, sent to the terminal
    fn draw(&mut self, eb: &mut EditBox);
    /// A 0.2 s with no key: eb_draw again if the terminal was resized (bash's `[[ -z $TCOLS ]]`)
    fn idle(&mut self, eb: &mut EditBox);
}

const ESC_WAIT: Duration = Duration::from_millis(50);

/// edit_box's loop, from its first eb_draw to a key that ends it: true Enter, false Esc or
/// Ctrl-C (or the input closed)
pub fn edit_loop(io: &mut dyn EbIo, eb: &mut EditBox) -> bool {
    loop {
        io.draw(eb);
        let mut more = false;
        loop {
            let k: Bytes = if more {
                match io.ch(None) {
                    Ok(k) => k,
                    Err(_) => break,
                }
            } else {
                loop {
                    match io.ch(Some(Duration::from_millis(200))) {
                        Ok(k) => break k,
                        Err(Rd::Time) => io.idle(eb), // the terminal may have been resized
                        Err(_) => break b"\x03".to_vec(), // the input closed (or a SIGINT)
                    }
                }
            };
            let key = if k == b"\x1b" {
                let rest = io.ch(Some(ESC_WAIT)).unwrap_or_default();
                let mut seq: Bytes = Vec::new();
                match rest.as_slice() {
                    b"[" => {
                        while let Ok(r) = io.ch(Some(ESC_WAIT)) {
                            seq.extend_from_slice(&r);
                            if (r.len() == 1 && (b'@'..=b'~').contains(&r[0])) || blen(&seq) > 8 {
                                break;
                            }
                        }
                    }
                    b"O" => seq = io.ch(Some(ESC_WAIT)).unwrap_or_default(),
                    _ => {}
                }
                if seq == b"200~" {
                    // A paste, to its end mark: text, whatever it holds.
                    let mut p: Bytes = Vec::new();
                    let mut n = 0i64;
                    while let Ok(c) = io.ch(Some(Duration::from_secs(1))) {
                        p.extend_from_slice(&c);
                        if c == b"~" && p.ends_with(b"\x1b[201~") {
                            break;
                        }
                        n += 1;
                        if n > 4 * EB_MAX {
                            p.clear(); // far too much: kept only from here on
                            n = 0;
                        }
                    }
                    if p.ends_with(b"\x1b[201~") {
                        p.truncate(p.len() - 6);
                    }
                    EbKey::Paste(p)
                } else {
                    EbKey::Esc(rest, seq)
                }
            } else {
                EbKey::Ch(k)
            };
            if let Some(ok) = eb.key(key) {
                return ok;
            }
            // Keys already waiting (typing fast, a paste the terminal didn't mark) before drawing.
            if !io.waiting() {
                break;
            }
            more = true;
        }
    }
}

// ------------------------------------------------------------------ the box over the panel

use super::boxes::BoxHost;
use super::{term, Ui};
use std::time::Instant;

impl EbIo for Ui {
    fn ch(&mut self, t: Option<Duration>) -> Result<Bytes, Rd> {
        let dl = Instant::now() + t.unwrap_or(Duration::from_secs(3600));
        let first = self.mbyte(dl)?;
        if first == 0 {
            return Ok(Vec::new()); // read -d '': a NUL ends the read, with nothing in it
        }
        let mut c = vec![first];
        let more = match first {
            0xc2..=0xdf => 1,
            0xe0..=0xef => 2,
            0xf0..=0xf4 => 3,
            _ => 0,
        };
        for _ in 0..more {
            match self.mbyte(dl.max(Instant::now() + super::keys::SEQ_WAIT)) {
                Ok(b) => c.push(b),
                Err(_) => break,
            }
        }
        Ok(c)
    }
    fn waiting(&mut self) -> bool {
        term::wait_readable(0, Some(Duration::ZERO))
    }
    fn draw(&mut self, eb: &mut EditBox) {
        let b = eb.eb_draw(&self.c, self.c.p.tcols, self.c.p.tlines, self.c.p.peek_row);
        self.over(b);
    }
    fn idle(&mut self, eb: &mut EditBox) {
        // Resized (bash's WINCH empties TCOLS, and eb_draw draws the panel clean at the new size
        // first, then itself), or the peek under it moved (the panel goes on under the box
        // here): the box drawn again where it now goes.
        if self.eb_winch || (self.c.p.tcols, self.c.p.tlines, self.c.p.peek_row) != eb.drawn_for {
            self.eb_winch = false;
            self.over = None;
            self.box_clean();
            eb.dirty = true;
            EbIo::draw(self, eb);
        }
    }
}

impl Ui {
    /// edit_box TITLE HINT [TEXT] -> REPLY: a box over the panel to write in, as much as you
    /// like: paragraphs, wrapped at its width, with a cursor that Left, Right, Up, Down, Home,
    /// End, PgUp and PgDn move. Backspace and Delete delete. Enter finishes (true); Alt-Enter or
    /// Ctrl-J starts a new line; Esc or Ctrl-C closes it (false, REPLY empty). The terminal marks
    /// pasted text while it's open (bracketed paste), so a paste comes in as text, line breaks
    /// and all, never as Enter. EB_MAX characters at most, as text_clean leaves them. The panel
    /// under it is drawn whole again after (PREV is emptied). EBC_M: magenta, for answering.
    pub fn edit_box(&mut self, title: &[u8], hint: &[u8], text: &[u8], ebc_m: bool) -> bool {
        if self.box_answered(&[b"edit", title, hint]) {
            self.reply = self.bx.ans.clone();
            return self.bx.rc == 0;
        }
        let txt = if self.bx.re.is_empty() { text.to_vec() } else { self.bx.re.clone() };
        let mut eb = EditBox::new(title, hint, &txt, ebc_m);
        // Enter (CR) told apart from Ctrl-J (LF), and Ctrl-C a key: the terminal turns neither
        // into anything else.
        let otty = term::eb_mode();
        term::out(b"\x1b[?2004h");
        self.modal_on = true;
        self.eb_on = true;
        self.eb_winch = false;
        let ok = edit_loop(self, &mut eb);
        term::out(b"\x1b[?2004l\x1b[?25l");
        if let Some(t) = otty {
            term::set_mode(&t);
        }
        self.modal_on = false;
        self.eb_on = false;
        self.over = None;
        self.prev.clear();
        self.reply.clear();
        if !ok {
            self.box_out(1, b"", false);
            return false;
        }
        self.reply = eb.text();
        let r = self.reply.clone();
        self.box_out(0, &r, false) == 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::collect::gather::tests::bash_fn;
    use crate::compat::tests::{bash, setup};
    use crate::render::prim::tests::bash_prims;
    use std::collections::VecDeque;

    /// panel.sh's edit_box and all it calls, with EB_MAX, EB_SLASH… and EB_RE as the file sets them
    fn eb_bash() -> String {
        let src = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../scripts/panel.sh")).unwrap();
        let mut s = bash_prims();
        s.push('\n');
        for l in src.lines() {
            if l.starts_with("EB_MAX=") || l.starts_with("EB_SLASH=") || l.starts_with("EB_RE=") {
                s.push_str(l);
                s.push('\n');
            }
        }
        for f in ["text_clean", "edit_box", "eb_ins", "eb_wrap", "eb_line", "eb_max", "eb_move", "eb_paint", "eb_draw"] {
            s.push_str(&bash_fn(f));
        }
        s.push_str("box_answered() { BOX_RE=''; return 1; }\nbox_out() { return \"$1\"; }\nbox_clean() { :; }\n");
        s
    }

    /// eb_draw in a state set by hand (TEXT, CUR, VTOP at TCOLS x TLINES, PEEK_ROW, EBC) against
    /// bash's: wrapping, the words coloured, the arrows, the cursor
    #[test]
    fn eb_draw_as_bash() {
        setup();
        let c = Ctx::new();
        let words = (1..=60).map(|i| format!("w{:03}", i)).collect::<Vec<_>>().join(" ");
        let code = format!("start `{}` end /skill. and @who: ok", words);
        let long_a = format!("{} https://example.com/a/b, then /x:", "a".repeat(600));
        let lines = (1..=40).map(|i| format!("line {:02}", i)).collect::<Vec<_>>().join("\n");
        let cases: Vec<(String, i64, i64, i64, i64, i64, &str)> = vec![
            ("".into(), 0, 0, 100, 30, 0, ""),
            ("hello /review on @src/a.md, then `make test` per https://example.com/docs. or /usr/bin".into(), 10, 0, 100, 30, 0, ""),
            ("tab\there é ü… and (/paren) (@x) /a /bb /cc: /dd/e /notes.txt /s, /q?".into(), 5, 0, 60, 20, 0, "m"),
            (code.clone(), code.chars().count() as i64, 0, 50, 12, 0, ""),
            (code.clone(), 3, 0, 50, 12, 0, ""),
            (code.clone(), code.chars().count() as i64, 0, 50, 40, 9, ""),
            (long_a.clone(), long_a.len() as i64, 0, 80, 24, 0, ""),
            (long_a.clone(), 0, 0, 80, 24, 0, "m"),
            (lines.clone(), 0, 0, 100, 30, 0, ""),
            (lines.clone(), lines.len() as i64, 0, 100, 30, 0, ""),
            (lines.clone(), 200, 0, 100, 30, 14, ""),
            (lines.clone(), 120, 5, 40, 12, 0, ""),
            (words.clone(), 50, 0, 24, 8, 0, ""),
            ("x".repeat(96) + "y", 96, 0, 100, 30, 0, ""),
            ("a\n\nb\n".into(), 4, 0, 200, 60, 30, ""),
        ];
        for (txt, cur, vtop, cols, lines_, pr, ebc) in cases {
            let body = format!(
                "{}\nt() {{ local title=$1 hint=$2 txt=$3 cur=$4 vtop=$5 dirty=1 w h th tw top left; local -a VS VN PS PE PC; TCOLS=$6 TLINES=$7 PEEK_ROW=$8 EBC=$9; eb_draw; printf '\\n--%s %s %s' \"$vtop\" \"$EL\" \"${{#VS[@]}}\"; }}\nt \"$@\"",
                eb_bash()
            );
            let args: Vec<Vec<u8>> = vec![
                b"MESSAGE TO asker".to_vec(),
                "Enter sends · Alt-Enter new line · Esc closes".as_bytes().to_vec(),
                txt.as_bytes().to_vec(),
                cur.to_string().into_bytes(),
                vtop.to_string().into_bytes(),
                cols.to_string().into_bytes(),
                lines_.to_string().into_bytes(),
                pr.to_string().into_bytes(),
                ebc.as_bytes().to_vec(),
            ];
            let a: Vec<&[u8]> = args.iter().map(|v| v.as_slice()).collect();
            let theirs = bash(&body, &a);
            let mut eb = EditBox::new(&args[0], &args[1], txt.as_bytes(), ebc == "m");
            eb.cur = cur;
            eb.vtop = vtop;
            let mut ours = b"\x1b[?2026h".to_vec();
            ours.extend(eb.eb_draw(&c, cols, lines_, pr));
            ours.extend_from_slice(b"\x1b[?2026l");
            ours.extend(format!("\n--{} {} {}", eb.vtop, eb.el, eb.vs.len()).into_bytes());
            assert_eq!(String::from_utf8_lossy(&ours), String::from_utf8_lossy(&theirs), "{:?} cur {} {}x{} peek {}", &txt[..txt.len().min(40)], cur, cols, lines_, pr);
        }
    }

    /// Keys from a list, in chunks (a moment apart, as bash's input gets them), and the frames drawn
    struct TIo {
        chunks: VecDeque<Vec<u8>>,
        cur: VecDeque<u8>,
        c: Ctx,
        size: (i64, i64, i64),
        frames: Vec<Bytes>,
    }
    impl EbIo for TIo {
        fn ch(&mut self, t: Option<Duration>) -> Result<Bytes, Rd> {
            if self.cur.is_empty() {
                if t.is_some_and(|d| d < Duration::from_millis(200)) {
                    return Err(Rd::Time);
                }
                match self.chunks.pop_front() {
                    Some(c) => self.cur = c.into(),
                    None => return Err(Rd::Gone),
                }
            }
            let first = self.cur.pop_front().unwrap();
            if first == 0 {
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
                if let Some(b) = self.cur.pop_front() {
                    c.push(b);
                }
            }
            Ok(c)
        }
        fn waiting(&mut self) -> bool {
            !self.cur.is_empty()
        }
        fn draw(&mut self, eb: &mut EditBox) {
            let (a, b, p) = self.size;
            let f = eb.eb_draw(&self.c, a, b, p);
            self.frames.push(f);
        }
        fn idle(&mut self, _: &mut EditBox) {}
    }

    /// The whole of edit_box, keys typed in chunks a moment apart: the last frame drawn, how it
    /// ended and REPLY, as bash's
    #[test]
    fn edit_box_keys_as_bash() {
        setup();
        let paste: String = (1..=40).map(|i| format!("line {:02}\r", i)).collect::<String>() + &(1..=30).map(|i| format!("w{:04} ", i)).collect::<String>();
        let cases: Vec<(i64, i64, i64, &str, Vec<String>)> = vec![
            (100, 30, 0, "", vec!["hello /review on @src/a.md, then `make test` per https://example.com/docs. or /usr/bin".into(), "\r".into()]),
            (100, 30, 0, "", vec!["line one".into(), "\x1b\r".into(), "line two\n".into(), "three".into(), "\x1b[A".into(), "\x1b[D\x1b[D".into(), "X".into(), "\r".into()]),
            (100, 30, 0, "", vec![format!("\x1b[200~{}\x1b[201~", paste), "\r".into()]),
            (100, 30, 0, "", vec![format!("\x1b[200~{}\x1b[201~", paste), "\x1b[5~\x1b[5~\x1b[5~".into(), "\r".into()]),
            (100, 30, 0, "m", vec![format!("\x1b[200~{}\x1b[201~", paste), "\x1b[5~".into(), "\x1b[H".into(), "\x1b[B\x1b[B\x1b[F".into(), "\x1b[3~\x7fZ".into(), "\x1b[6~".into(), "\r".into()]),
            (60, 16, 9, "", vec!["a\tb\x15c é…".into(), "\x7f".into(), "\x1bOH".into(), "\x1b[1~>".into(), "\x1b[C\x1b[4~<".into(), "\r".into()]),
            (100, 30, 0, "", vec!["abc".into(), "\x1b".into()]),
            (100, 30, 0, "", vec!["abc".into(), "\x03".into()]),
            (100, 30, 0, "", vec!["closed".into()]),
            (40, 12, 0, "", vec![(1..=50).map(|i| format!("word{} ", i)).collect::<String>(), "\x1b[A\x1b[A\x1b[A".into(), "\r".into()]),
            (100, 30, 0, "", vec!["  \n ".into(), "\r".into()]),
        ];
        for (cols, lines, pr, ebc, chunks) in cases {
            let body = format!(
                "{}\nTCOLS=$1 TLINES=$2 PEEK_ROW=$3 EBC=$4; shift 4\nedit_box 'MESSAGE TO asker' 'Enter sends · Alt-Enter new line · Esc closes' < <(for c; do printf %s \"$c\"; sleep 0.3; done); st=$?\nprintf '\\n--%s ' \"$st\"; printf %s \"$REPLY\"",
                eb_bash()
            );
            let mut args: Vec<Vec<u8>> = vec![cols.to_string().into_bytes(), lines.to_string().into_bytes(), pr.to_string().into_bytes(), ebc.as_bytes().to_vec()];
            args.extend(chunks.iter().map(|c| c.as_bytes().to_vec()));
            let a: Vec<&[u8]> = args.iter().map(|v| v.as_slice()).collect();
            let theirs = bash(&body, &a);
            // the last ?2026 frame, and the end
            let start = theirs.windows(8).rposition(|w| w == b"\x1b[?2026h").expect("a frame");
            let end = start + theirs[start..].windows(8).position(|w| w == b"\x1b[?2026l").unwrap() + 8;
            let tail = theirs.windows(3).rposition(|w| w == b"\n--").unwrap();
            let mut t = theirs[start..end].to_vec();
            t.extend_from_slice(&theirs[tail..]);
            assert!(theirs.starts_with(b"\x1b[?2004h"), "bracketed paste on first");
            assert!(theirs[..tail].ends_with(b"\x1b[?2004l\x1b[?25l"), "and off at the end");

            let mut io = TIo { chunks: chunks.iter().map(|c| c.as_bytes().to_vec()).collect(), cur: VecDeque::new(), c: Ctx::new(), size: (cols, lines, pr), frames: vec![] };
            let mut eb = EditBox::new(b"MESSAGE TO asker", "Enter sends · Alt-Enter new line · Esc closes".as_bytes(), b"", ebc == "m");
            let ok = edit_loop(&mut io, &mut eb);
            let mut o = b"\x1b[?2026h".to_vec();
            o.extend(io.frames.last().unwrap().clone());
            o.extend_from_slice(b"\x1b[?2026l");
            o.extend(format!("\n--{} ", if ok { 0 } else { 1 }).into_bytes());
            if ok {
                o.extend(eb.text());
            }
            assert_eq!(String::from_utf8_lossy(&o), String::from_utf8_lossy(&t), "{:?}", chunks.iter().map(|c| &c[..c.len().min(30)]).collect::<Vec<_>>());
        }
    }

    #[test]
    fn text_clean_as_bash() {
        setup();
        let mut ins: Vec<Bytes> = crate::compat::tests::inputs();
        ins.extend([b"a\r\nb\rc\nd\te\x01\x7f\x1b[1m".to_vec(), "x\u{0085}y\u{200b}z\u{202e}".as_bytes().to_vec(), b"\xff\xc3\xa9\r\r\n".to_vec()]);
        let body = format!("{}\n{}\nfor s; do text_clean s; printf '%s\\0' \"$s\"; done", bash_prims(), bash_fn("text_clean"));
        let a: Vec<&[u8]> = ins.iter().map(|v| v.as_slice()).collect();
        let theirs = bash(&body, &a);
        let ours: Bytes = ins
            .iter()
            .flat_map(|s| {
                let mut v = text_clean(s);
                v.push(0);
                v
            })
            .collect();
        assert_eq!(ours, theirs);
    }
}
