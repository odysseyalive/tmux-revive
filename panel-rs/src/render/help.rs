//! The ? page: scripts/help.sh help_wrap, help_ink, hpush, hhang, hpara, hrule, hbutton,
//! hbtn_flush, hbox_close, hflush, the pictures (HART_*), hart, hart_close, help_build and
//! help_frame (plan Phase 1.3, step 9). The words are help.txt's, read at run time as bash
//! reads them: found next to the binary (see `help_file`).

use super::panes::sub;
use super::*;
use crate::compat::{blen, chars, clean, itoa, pad, Bytes};
use std::path::PathBuf;

/// The ? page's rows for one width (HROWS, HSPLIT), kept while the width is the same (HELP_W).
pub struct Page {
    pub help_w: i64,
    pub hrows: Vec<Bytes>,
    pub hsplit: i64,
}
impl Default for Page {
    fn default() -> Page {
        Page { help_w: -1, hrows: Vec::new(), hsplit: 0 }
    }
}

/// HELP_FILE: `$(dirname "${BASH_SOURCE[0]}")/help.txt`, panel.sh's scripts folder. The binary
/// finds it from where it is: the first folder above it holding scripts/help.txt, which is the
/// install's for vendor/bin/tmux-revive-panel and the checkout's for
/// panel-rs/target/release/tmux-revive-panel. None found: the install's place, two up.
pub fn help_file() -> PathBuf {
    let exe = std::env::current_exe().ok().and_then(|p| p.canonicalize().ok());
    if let Some(exe) = &exe {
        for d in exe.ancestors().skip(1) {
            let f = d.join("scripts").join("help.txt");
            if f.is_file() {
                return f;
            }
        }
        if let Some(d) = exe.parent().and_then(|p| p.parent()).and_then(|p| p.parent()) {
            return d.join("scripts").join("help.txt");
        }
    }
    PathBuf::from("scripts/help.txt")
}

/// help_wrap TEXT WIDTH -> WRAP: TEXT in lines of at most WIDTH, broken at spaces. Backticks
/// take no room; a word longer than a line is cut across lines.
pub fn help_wrap(text: &[u8], w: i64) -> Vec<Bytes> {
    let mut wrap = Vec::new();
    let mut cur: Bytes = Vec::new();
    let mut cl: i64 = 0;
    // read -ra words <<<"$1": its first line, split at blanks
    let first = text.split(|&c| c == b'\n').next().unwrap_or(b"");
    for word in first.split(|&c| c == b' ' || c == b'\t').filter(|w| !w.is_empty()) {
        let mut word = word.to_vec();
        let nobt = |w: &[u8]| -> i64 { blen(&w.iter().copied().filter(|&c| c != b'`').collect::<Vec<u8>>()) };
        let mut wl = nobt(&word);
        while wl > w {
            if cl != 0 {
                wrap.push(cur.clone());
            }
            wrap.push(sub(&word, 0, Some(w)));
            word = sub(&word, w, None);
            wl = nobt(&word);
            cur = Vec::new();
            cl = 0;
        }
        if wl == 0 {
            continue;
        }
        if cl == 0 {
            cur = word;
            cl = wl;
        } else if cl + 1 + wl <= w {
            cur.push(b' ');
            cur.extend(word);
            cl = cl + 1 + wl;
        } else {
            wrap.push(std::mem::replace(&mut cur, word));
            cl = wl;
        }
    }
    if cl != 0 {
        wrap.push(cur);
    }
    wrap
}

// The pictures: HART_NAME's rows and HART_NAME_ink's colour letters.
const HART_TALK: [&str; 5] = [
    "   ▄                         ▄   ",
    " ▄▄█▄▄                     ▄▄█▄▄ ",
    "██▄█▄██       ░░▒▒▓▓██►   ██▄█▄██",
    "██▀▀▀██   ◄██▓▓▒▒░░       ██▀▀▀██",
    " ▀▀▀▀▀                     ▀▀▀▀▀ ",
];
const HART_TALK_INK: [&str; 5] = [
    "   1                         2   ",
    " CCkCC                     MMkMM ",
    "CCCCCCC       CCCCCCCCC   MMMMMMM",
    "CCCCCCC   MMMMMMMMM       MMMMMMM",
    " ccccc                     mmmmm ",
];
const HART_SATELLITE: [&str; 4] = [
    "               ▪               ",
    " ▄▄▄▄▄▄▄▄▄  ▄▄▄▄▄▄▄  ▄▄▄▄▄▄▄▄▄ ",
    " █▒█▒█▒█▒█══███████══█▒█▒█▒█▒█ ",
    " ▀▀▀▀▀▀▀▀▀  ▀▀▀█▀▀▀  ▀▀▀▀▀▀▀▀▀ ",
];
const HART_SATELLITE_INK: [&str; 4] = [
    "               L               ",
    " BBBBBBBBB  YYYrYyy  BBBBBBBBB ",
    " BbBbBbBbBkkYYYYYyykkBbBbBbBbB ",
    " bbbbbbbbb  yyykyyy  bbbbbbbbb ",
];
/// HB1, HB2, HLIT: the beacons' colours, which help_frame lets go dark between blinks
pub const HB1: &[u8] = b"\x1b[38;5;226m";
pub const HB2: &[u8] = b"\x1b[38;5;227m";
pub const HLIT: &[u8] = b"\x1b[38;5;196m";

/// help_build's variables (HW, HROWS, HBOX, HBLANK, HPARA, HBC, HB, HPEND, HPEND_END, HBN, HBQ,
/// HBQW, HART, HARTW, HART_AT, HHEAD_AT, HSPLIT, HSIDE, HBW, HCW, HCODE)
struct Build {
    hw: i64,
    hrows: Vec<Bytes>,
    hbox: bool,
    hblank: bool,
    hpara: Bytes,
    hbc: Bytes,
    hb: Vec<Bytes>,
    hpend: Vec<Bytes>,
    hpend_end: Vec<Bytes>,
    hbn: i64,
    hbq: [Bytes; 3],
    hbq_n: bool,
    hbqw: i64,
    hart: Vec<Bytes>,
    hartw: i64,
    hart_at: i64,
    hhead_at: i64,
    hsplit: i64,
    hside: bool,
    hbw: i64,
    hcw: i64,
    hcode: bool,
}

impl Build {
    /// help_ink LINE -> INK: the line in colour, `commands` in cyan; HCODE carries over
    fn help_ink(&mut self, s: &[u8]) -> Bytes {
        let mut ink: Bytes = Vec::new();
        if self.hcode {
            ink.extend_from_slice(BCYN);
        }
        let mut s = s;
        while let Some(p) = s.iter().position(|&c| c == b'`') {
            ink.extend_from_slice(&s[..p]);
            s = &s[p + 1..];
            if self.hcode {
                self.hcode = false;
                ink.extend_from_slice(R);
            } else {
                self.hcode = true;
                ink.extend_from_slice(BCYN);
            }
        }
        ink.extend_from_slice(s);
        ink.extend_from_slice(R);
        ink
    }

    /// hpush CONTENT: one row of the page, inside the open box if there is one
    fn hpush(&mut self, cx: &Ctx, c: &[u8]) {
        self.hblank = c.is_empty();
        if self.hbox {
            let p = cx.padv(c, self.hbw - 5);
            self.hb.push(cat(&[&self.hbc, "║".as_bytes(), R, b" ", &p, b" ", &self.hbc, "║".as_bytes(), R, GRY, "░".as_bytes(), R]));
            return;
        }
        if !self.hpend.is_empty() {
            if c.is_empty() {
                return;
            }
            self.hflush();
        }
        self.hrows.push(c.to_vec());
    }

    /// hhang PREFIX PREFIX-WIDTH TEXT: TEXT wrapped beside PREFIX, its later lines under it
    fn hhang(&mut self, cx: &Ctx, prefix: &[u8], pw: i64, text: &[u8]) {
        let p = pad(pw);
        let wrap = help_wrap(text, self.hcw - pw);
        self.hcode = false;
        for (i, w) in wrap.iter().enumerate() {
            let ink = self.help_ink(w);
            if i == 0 {
                self.hpush(cx, &cat(&[prefix, &ink]));
            } else {
                self.hpush(cx, &cat(&[&p, &ink]));
            }
        }
        if wrap.is_empty() {
            self.hpush(cx, prefix);
        }
    }

    /// hpara: the paragraph gathered so far, wrapped
    fn hpara(&mut self, cx: &Ctx) {
        if self.hpara.is_empty() {
            return;
        }
        let t = std::mem::take(&mut self.hpara);
        self.hhang(cx, b" ", 1, &t);
    }

    /// hbutton KEY LABEL: a solid button, the key on a black cap at its left
    fn hbutton(&mut self, cx: &Ctx, key: &[u8], label: &[u8]) {
        let (fg, bg, cap): (&[u8], Bytes, Bytes) = if self.hbn % 2 != 0 {
            (BLU, cat(&[b"\x1b[44m", B, BWHT]), cat(&[b"\x1b[40m", B, BWHT]))
        } else {
            (BYEL, cat(&[b"\x1b[103m", B, b"\x1b[30m"]), cat(&[b"\x1b[40m", B, BYEL]))
        };
        self.hbn += 1;
        let blk = cat(&[&bg, b" ", &cap, b" ", key, b" ", R, &bg, b"  ", label, b"  ", R]);
        let n = blen(label) + 8;
        let w = blen(label) + 16;
        if self.hbq_n && self.hbqw + w > self.hcw {
            self.hbtn_flush(cx);
        }
        self.hbq_n = true;
        let rep = cx.rep("▄".as_bytes(), n);
        self.hbq[0].extend(cat(&[b"     ", fg, &rep, R, b"   "]));
        self.hbq[1].extend(cat(&[b"  ", fg, "░▒▓".as_bytes(), R, &blk, fg, "▓▒░".as_bytes(), R]));
        let rep = cx.rep("▀".as_bytes(), n);
        self.hbq[2].extend(cat(&[b"     ", fg, &rep, R, b"   "]));
        self.hbqw += w;
    }
    fn hbtn_flush(&mut self, cx: &Ctx) {
        if !self.hbq_n {
            return;
        }
        let q = std::mem::take(&mut self.hbq);
        for r in q.iter() {
            self.hpush(cx, r);
        }
        self.hbq_n = false;
        self.hbqw = 0;
    }

    /// hbox_close: the open box laid out, under the page or beside the box before it
    fn hbox_close(&mut self, cx: &Ctx) {
        let rep = cx.rep("═".as_bytes(), self.hbw - 3);
        let bot = cat(&[&self.hbc, "╚".as_bytes(), &rep, "╝".as_bytes(), R, GRY, "░".as_bytes(), R]);
        let rep = cx.rep("░".as_bytes(), self.hbw - 1);
        let sh = cat(&[b" ", GRY, &rep, R]);
        let blank = cat(&[&self.hbc, "║".as_bytes(), R, &pad(self.hbw - 3), &self.hbc, "║".as_bytes(), R, GRY, "░".as_bytes(), R]);
        self.hbox = false;
        self.hblank = false;
        if !self.hside {
            let hb = std::mem::take(&mut self.hb);
            self.hrows.extend(hb);
            self.hrows.push(bot);
            self.hrows.push(sh);
            return;
        }
        if self.hpend.is_empty() {
            self.hpend = self.hb.clone();
            self.hpend_end = vec![blank, bot, sh];
            return;
        }
        // Two boxes side by side end on the same row.
        while self.hpend.len() < self.hb.len() {
            let e = self.hpend_end[0].clone();
            self.hpend.push(e);
        }
        while self.hb.len() < self.hpend.len() {
            self.hb.push(blank.clone());
        }
        let rest: Vec<Bytes> = self.hpend_end[1..].to_vec();
        self.hpend.extend(rest);
        self.hb.push(bot);
        self.hb.push(sh);
        for i in 0..self.hb.len() {
            let r = cat(&[&self.hpend[i], b"  ", &self.hb[i]]);
            self.hrows.push(r);
        }
        self.hpend = Vec::new();
    }
    fn hflush(&mut self) {
        if self.hpend.is_empty() {
            return;
        }
        let p = std::mem::take(&mut self.hpend);
        self.hrows.extend(p);
        self.hrows.extend(self.hpend_end[1..].to_vec());
    }

    /// hart NAME: the picture for the section, beside it, above it, or left out
    fn hart(&mut self, cx: &Ctx, name: &[u8]) {
        let (g, p): (&[&str], &[&str]) = match name {
            b"talk" => (&HART_TALK, &HART_TALK_INK),
            b"satellite" => (&HART_SATELLITE, &HART_SATELLITE_INK),
            _ => return,
        };
        if self.hbox {
            return;
        }
        let pal = |c: &[u8]| -> &[u8] {
            match c {
                b"b" => BLU,
                b"B" => BBLU,
                b"c" => CYN,
                b"C" => BCYN,
                b"m" => MAG,
                b"M" => BMAG,
                b"y" => YEL,
                b"Y" => BYEL,
                b"g" => GRN,
                b"G" => BGRN,
                b"r" => BRED,
                b"k" => GRY,
                b"L" => HLIT,
                b"1" => HB1,
                b"2" => HB2,
                _ => b"",
            }
        };
        let w = blen(g[0].as_bytes());
        let mut rows = Vec::new();
        for (i, gr) in g.iter().enumerate() {
            let gc: Vec<&[u8]> = chars(gr.as_bytes()).collect();
            let pc: Vec<&[u8]> = chars(p[i].as_bytes()).collect();
            let mut s: Bytes = Vec::new();
            let mut last: &[u8] = b" ";
            for j in 0..w as usize {
                let c: &[u8] = pc.get(j).copied().unwrap_or(b"");
                if c != last {
                    s.extend_from_slice(R);
                    s.extend_from_slice(pal(c));
                    last = c;
                }
                s.extend_from_slice(gc.get(j).copied().unwrap_or(b""));
            }
            s.extend_from_slice(R);
            rows.push(s);
        }
        let _ = cx;
        if self.hw - w - 4 >= 44 {
            self.hart = rows;
            self.hartw = w;
            self.hart_at = self.hrows.len() as i64;
            // Under the title, past the blank row below it.
            if self.hhead_at == self.hart_at - 1 {
                self.hart_at += 1;
            }
        } else if w < self.hw {
            for s in rows {
                self.hrows.push(cat(&[b" ", &s]));
            }
            self.hrows.push(Vec::new());
            self.hblank = true;
        }
    }

    /// hart_close: the picture hart held back, set beside the rows of its section
    fn hart_close(&mut self, cx: &Ctx) {
        if self.hartw == 0 {
            return;
        }
        let n = self.hart.len() as i64;
        let tw = self.hw - self.hartw - 2;
        let blank = self.hblank;
        if blank {
            self.hrows.pop();
        }
        while (self.hrows.len() as i64) < self.hart_at + n {
            self.hrows.push(Vec::new());
        }
        for i in 0..n {
            let k = (self.hart_at + i) as usize;
            let p = cx.padv(&self.hrows[k], tw);
            self.hrows[k] = cat(&[&p, b"  ", &self.hart[i as usize]]);
        }
        if blank {
            self.hrows.push(Vec::new());
        }
        self.hart = Vec::new();
        self.hartw = 0;
    }
}

/// hrule WIDTH -> RULE: a line that fades out to the right
fn hrule(cx: &Ctx, w: i64) -> Bytes {
    let q = w / 4;
    cat(&[BCYN, &cx.rep("━".as_bytes(), q), BBLU, &cx.rep("━".as_bytes(), q), BLU, &cx.rep("─".as_bytes(), q), GRY, &cx.rep("┄".as_bytes(), w - 3 * q), R])
}

impl Ctx {
    /// help_build WIDTH -> HROWS, HSPLIT: help.txt drawn for a page WIDTH characters wide
    pub fn help_build(&mut self, hw: i64) {
        let file = help_file();
        let text = std::fs::read(&file).ok();
        let mut b = Build {
            hw,
            hrows: Vec::new(),
            hbox: false,
            hblank: true,
            hpara: Vec::new(),
            hbc: BMAG.to_vec(),
            hb: Vec::new(),
            hpend: Vec::new(),
            hpend_end: Vec::new(),
            hbn: 0,
            hbq: Default::default(),
            hbq_n: false,
            hbqw: 0,
            hart: Vec::new(),
            hartw: 0,
            hart_at: 0,
            hhead_at: -1,
            hsplit: -1,
            hside: hw >= 110,
            hbw: hw,
            hcw: 0,
            hcode: false,
        };
        if b.hside {
            b.hbw = (hw - 2) / 2;
        }
        let (mut boxes, mut heads) = (0i64, 0i64);
        let bcol: [&[u8]; 2] = [b"5", b"6"];
        // help.txt's lines, as `while IFS= read -r ln` gives them (the first pass leaves out a
        // last line with no newline after it; the second, `|| [[ -n $ln ]]`, keeps it)
        let (lines_all, lines_nl): (Vec<Bytes>, Vec<Bytes>) = match &text {
            Some(t) => {
                let mut v: Vec<Bytes> = t.split(|&c| c == b'\n').map(|l| l.to_vec()).collect();
                let last = v.pop().unwrap_or_default();
                let nl = v.clone();
                if !last.is_empty() {
                    v.push(last);
                }
                (v, nl)
            }
            None => (Vec::new(), Vec::new()),
        };
        let mut tags: Vec<Bytes> = Vec::new();
        for ln in &lines_nl {
            let ln = clean(ln);
            if ln.starts_with(b".tag ") {
                tags.push(ln[5..].to_vec());
            }
        }
        let big = self.big_banner(b"HELP", &[&cat(&[B, BWHT]), &cat(&[B, BYEL]), YEL, BRED, BMAG]);
        let sun: [Bytes; 6] = [
            cat(&[GRY, " ·    ".as_bytes(), BYEL, "▄▄▄▄▄▄▄".as_bytes(), GRY, "    + ".as_bytes(), R]),
            cat(&[BYEL, "   ▄███████████▄   ".as_bytes(), R]),
            cat(&[YEL, "  ███████████████  ".as_bytes(), R]),
            cat(&[BRED, "  ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀  ".as_bytes(), R]),
            cat(&[BMAG, "   ▀▀▀▀▀▀▀▀▀▀▀▀▀   ".as_bytes(), R]),
            cat(&[MAG, "━┿━━━┿━━━┿━━━┿━━━┿━".as_bytes(), R]),
        ];
        let tw = hw - self.vlen(&big[0]) - 5;
        let mut side: [Bytes; 6] = Default::default();
        if !tags.is_empty() {
            side[1] = self.tab(&tags[0], Some(b"4"));
        }
        if tags.len() > 1 {
            let wrap = help_wrap(&tags[1], tw);
            for i in 0..3 {
                if let Some(w) = wrap.get(i).filter(|w| !w.is_empty()) {
                    side[i + 3] = cat(&[B, BCYN, w, R]);
                }
            }
        }
        let mut sw = 0;
        for s in &side {
            let v = self.vlen(s);
            if v > sw {
                sw = v;
            }
        }
        b.hrows.push(Vec::new());
        for i in 0..6 {
            let p = self.padv(&side[i], sw);
            let mut t = cat(&[b"  ", big.get(i).map(|v| v.as_slice()).unwrap_or(b""), b"   ", &p]);
            if tw - sw >= 24 {
                t.extend(cat(&[b"    ", &sun[i]]));
            }
            b.hrows.push(t);
        }
        b.hblank = false;
        if text.is_none() {
            let dir = file.parent().map(|d| d.as_os_str().as_encoded_bytes().to_vec()).unwrap_or_else(|| b".".to_vec());
            b.hrows.push(Vec::new());
            b.hrows.push(cat(&[b"  ", BRED, b"help.txt is missing from ", &dir, R]));
            self.p.hp = Page { help_w: hw, hsplit: b.hrows.len() as i64, hrows: b.hrows };
            return;
        }
        let cx: &Ctx = self;
        for ln in &lines_all {
            let ln = clean(ln);
            if !ln.starts_with(b".button ") {
                b.hbtn_flush(cx);
            }
            b.hcw = if b.hbox { b.hbw - 5 } else { hw - 2 };
            // Text that starts beside a picture is wrapped to leave it room.
            if b.hartw != 0 && (b.hrows.len() as i64) < b.hart_at + b.hart.len() as i64 {
                b.hcw = b.hcw - b.hartw - 2;
            }
            let num_item = {
                let d = ln.iter().take_while(|c| c.is_ascii_digit()).count();
                (d == 1 || d == 2) && ln[d..].starts_with(b". ")
            };
            if ln.starts_with(b";") || ln.starts_with(b".tag ") {
                continue;
            } else if ln.is_empty() {
                b.hpara(cx);
                if !b.hblank {
                    b.hpush(cx, b"");
                }
            } else if ln.starts_with(b".art ") {
                b.hpara(cx);
                b.hart(cx, &ln[5..]);
            } else if ln.starts_with(b"= ") {
                b.hpara(cx);
                b.hart_close(cx);
                b.hflush();
                if !b.hblank {
                    b.hrows.push(Vec::new());
                }
                heads += 1;
                let tab = cx.tab(&cat(&[&itoa(heads), b" ", &ln[2..]]), Some(b"4"));
                let t = cat(&[b" ", &tab, b" "]);
                b.hhead_at = b.hrows.len() as i64;
                let rule = hrule(cx, hw - cx.vlen(&t));
                b.hrows.push(cat(&[&t, &rule]));
                b.hblank = false;
            } else if ln.starts_with(b".box ") {
                b.hpara(cx);
                b.hart_close(cx);
                if !(b.hblank || !b.hpend.is_empty()) {
                    b.hrows.push(Vec::new());
                }
                if b.hsplit < 0 {
                    b.hsplit = b.hrows.len() as i64;
                    if b.hrows.get((b.hsplit - 1) as usize).is_some_and(|r| r.is_empty()) {
                        b.hsplit -= 1;
                    }
                }
                let c = bcol[(boxes % 2) as usize];
                boxes += 1;
                b.hbc = cat(&[b"\x1b[9", c, b"m"]);
                let tab = cx.tab(&ln[5..], Some(b"4"));
                let t = cat(&[&b.hbc, "╔═".as_bytes(), &tab]);
                let rep = cx.rep("═".as_bytes(), b.hbw - cx.vlen(&t) - 2);
                b.hb = vec![cat(&[&t, &b.hbc, &rep, "╗".as_bytes(), R, b" "])];
                b.hbox = true;
                b.hpush(cx, b"");
            } else if ln == b".end" {
                b.hpara(cx);
                if !b.hblank {
                    b.hpush(cx, b"");
                }
                b.hbox_close(cx);
            } else if ln.starts_with(b".button ") {
                b.hpara(cx);
                let t = &ln[8..];
                // k=${t%% *} t=${t#* }
                let (k, t): (&[u8], &[u8]) = match t.iter().position(|&c| c == b' ') {
                    Some(p) => (&t[..p], &t[p + 1..]),
                    None => (t, t),
                };
                b.hbutton(cx, k, t);
            } else if ln.starts_with(b"$ ") {
                b.hpara(cx);
                // Too long for a line: broken after a / or a space where there's one late enough.
                let mut t = ln[2..].to_vec();
                let mut pd = cat(&[b"     ", GRY, b"$", R, b" "]);
                while !t.is_empty() {
                    let mut c = b.hcw - 8;
                    if blen(&t) > c {
                        let k = sub(&t, 0, Some(c));
                        // k=${k%[/ ]*}
                        let k = match k.iter().rposition(|&x| x == b'/' || x == b' ') {
                            Some(p) => k[..p].to_vec(),
                            None => k,
                        };
                        if blen(&k) >= c / 2 {
                            c = blen(&k) + 1;
                        }
                    }
                    b.hpush(cx, &cat(&[&pd, BCYN, &sub(&t, 0, Some(c)), R]));
                    t = sub(&t, c, None);
                    pd = b"       ".to_vec();
                }
            } else if ln.starts_with(b"- ") {
                b.hpara(cx);
                b.hhang(cx, &cat(&[b"  ", BYEL, "▪".as_bytes(), R, b" "]), 4, &ln[2..]);
            } else if num_item {
                b.hpara(cx);
                // printf -v k '%2s' "${ln%%.*}"; "${ln#*. }"
                let d = &ln[..ln.iter().position(|&c| c == b'.').unwrap()];
                let k = cat(&[&pad((2 - blen(d)).max(0)), d]);
                let p = ln.windows(2).position(|w| w == b". ").unwrap();
                b.hhang(cx, &cat(&[b" ", B, BYEL, &k, R, BBLU, "▸".as_bytes(), R, b" "]), 5, &ln[p + 2..]);
            } else {
                if !b.hpara.is_empty() {
                    b.hpara.push(b' ');
                }
                b.hpara.extend_from_slice(&ln);
            }
        }
        b.hpara(cx);
        b.hart_close(cx);
        if b.hbox {
            b.hbox_close(cx);
        }
        b.hflush();
        if b.hsplit < 0 {
            b.hsplit = b.hrows.len() as i64;
        }
        self.p.hp = Page { help_w: hw, hsplit: b.hsplit, hrows: b.hrows };
    }

    /// help_frame LINES BANNER-ROWS: the page in place of everything under the banner, its keys
    /// on the bar at the bottom; under --once the frame is printed here
    pub fn help_frame(&mut self, lines: i64, bh: i64) {
        let mut view = lines - bh - 5;
        if self.p.hp.help_w != self.iw - 2 {
            self.help_build(self.iw - 2);
        }
        let mut n = self.p.hp.hrows.len() as i64;
        let hsplit = self.p.hp.hsplit;
        let mut foot = 0;
        if view < 1 {
            view = 1;
        }
        if hsplit < n && view - (n - hsplit) >= 8 {
            foot = n - hsplit;
            n = hsplit;
        }
        view -= foot;
        if self.p.help_top > n - view {
            self.p.help_top = n - view;
        }
        if self.p.help_top < 0 {
            self.p.help_top = 0;
        }
        let top = self.p.help_top;
        self.sect("HELP · HOW TO USE REVIVE".as_bytes(), None, None, None);
        let sb: BTreeMap<i64, Bytes> = self.sbar(view, n, top, (top > 0) as i64, (top + view < n) as i64, Some(BCYN)).into_iter().collect();
        for i in 0..view + foot {
            let mut k: Bytes;
            if i < view {
                k = Vec::new();
                self.rbar = sb.get(&i).cloned().unwrap_or_default();
                if top + i < n {
                    k = self.p.hp.hrows.get((top + i) as usize).cloned().unwrap_or_default();
                }
            } else {
                k = self.p.hp.hrows.get((n + i - view) as usize).cloned().unwrap_or_default();
                self.rbar = Vec::new();
            }
            let t = self.tick;
            if t % 2 != 0 {
                k = super::panes::sub_all(&k, HB1, GRY);
            } else {
                k = super::panes::sub_all(&k, HB2, GRY);
            }
            if !(t % 7 == 0 || t % 7 == 3) {
                k = super::panes::sub_all(&k, HLIT, GRY);
            }
            self.row(&k, None);
        }
        self.rbar = Vec::new();
        let last = if top + view < n { top + view } else { n };
        let mut k = self.kcs(&["↑↓/j/k".as_bytes(), b" scroll", b"PgUp/PgDn", b" page", b"i/c/p", b" install", b"Esc", b" close"]);
        if !self.p.flash.is_empty() && self.p.secs - self.p.flash_t < 5 {
            k = cat(&[BGBLU, B, BWHT, b" ", &self.p.flash, b" ", R, b"  ", &k]);
        }
        let mut i = cat(&[GRY, &itoa(top + 1), b"-", &itoa(last), b" of ", &itoa(n), R]);
        if last < n {
            i.extend(cat(&[b" ", BYEL, "▼".as_bytes(), R]));
        }
        if top != 0 {
            i = cat(&[BYEL, "▲".as_bytes(), R, b" ", &i]);
        }
        k.extend_from_slice(b"  ");
        let kl = self.vlen(&k);
        let vl = self.vlen(&i);
        if kl + vl <= self.iw {
            let r = self.rep(b" ", self.iw - kl - vl);
            k.extend(r);
            k.extend(i);
        }
        let rep = self.rep("═".as_bytes(), self.w - 2);
        self.line(cat(&[FRAME, "╠".as_bytes(), &rep, "╣".as_bytes(), R]));
        self.row(&k, None);
        self.sig();
        self.print_frame();
    }
}
