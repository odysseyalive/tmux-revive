//! The primitives a frame is built from: scripts/panel.sh "drawing" (rep .. sect2), and
//! trim_colored, kc, kcs, meter and human from further down. Same names, same order.

use super::*;
use crate::compat::{blen, chars, pad, substr, Bytes};

/// The match of `$e\[[0-9;]*m` that starts at `s[i]`, if one does: its length.
fn sgr_at(s: &[u8], i: usize) -> Option<usize> {
    if s.get(i) != Some(&0x1b) || s.get(i + 1) != Some(&b'[') {
        return None;
    }
    let mut j = i + 2;
    while j < s.len() && (s[j].is_ascii_digit() || s[j] == b';') {
        j += 1;
    }
    (s.get(j) == Some(&b'm')).then_some(j + 1 - i)
}

/// `${s//"LIT"/}`: every LIT taken out, left to right.
fn remove_lit(s: &[u8], lit: &[u8]) -> Bytes {
    let mut out = Vec::with_capacity(s.len());
    let mut i = 0;
    while i < s.len() {
        if s[i..].starts_with(lit) {
            i += lit.len();
        } else {
            out.push(s[i]);
            i += 1;
        }
    }
    out
}

impl Ctx {
    /// rep CHAR N -> REP: `printf -v REP '%*s' N ''; REP=${REP// /CHAR}` (|N| of them)
    pub fn rep(&self, ch: &[u8], n: i64) -> Bytes {
        ch.repeat(n.unsigned_abs() as usize)
    }

    /// fld TEXT WIDTH -> FLD: plain text cut or padded to exactly WIDTH characters
    pub fn fld(&self, text: &[u8], width: i64) -> Bytes {
        // local s=${1:0:$2} (a width that ends before the start stops bash there)
        let s = substr(text, 0, Some(width)).expect("fld: substring expression < 0");
        let n = width - blen(&s);
        cat(&[&s, &pad(n)])
    }

    /// vlen TEXT -> VLEN: its length with the colour codes taken out. Bash takes the first
    /// `$e\[[0-9;]*m` it finds and removes every copy of it, then looks again.
    pub fn vlen(&self, text: &[u8]) -> i64 {
        let mut s = text.to_vec();
        loop {
            let Some((i, n)) = (0..s.len()).find_map(|i| sgr_at(&s, i).map(|n| (i, n))) else { break };
            let lit = s[i..i + n].to_vec();
            s = remove_lit(&s, &lit);
        }
        blen(&s)
    }

    /// padv TEXT WIDTH -> PADV: a coloured string padded (or cut) to WIDTH visible characters
    pub fn padv(&self, text: &[u8], width: i64) -> Bytes {
        let v = self.vlen(text);
        if v > width {
            self.trim_colored(text, width)
        } else {
            cat(&[text, &pad(width - v)])
        }
    }

    /// line TEXT: one line of the frame (OUT+=)
    pub fn line(&mut self, text: Bytes) {
        self.out.push(text);
    }

    /// row CONTENT [WIDTH]: one line inside the frame, cut or padded to the inner width. WIDTH
    /// given: its visible width, not measured again. RBAR set: one narrower, the bar's cell
    /// against the right edge. ROWL, ROWR: the edges' colours.
    pub fn row(&mut self, content: &[u8], width: Option<i64>) {
        let mut c = content.to_vec();
        let mut w = self.iw;
        if !self.rbar.is_empty() {
            w = self.iw - 1;
        }
        let mut vl = match width {
            Some(n) => n,
            None => self.vlen(&c),
        };
        if vl > w {
            c = self.trim_colored(&c, w);
            vl = w;
        }
        let p = pad(w - vl);
        let bar = if self.rbar.is_empty() { Vec::new() } else { cat(&[&self.rbar, R]) };
        let l = cat(&[&self.rowl, "║".as_bytes(), R, b" ", &c, &p, b" ", &bar, &self.rowr, "║".as_bytes(), R]);
        self.line(l);
    }

    /// sbar HEIGHT TOTAL OFFSET UP DOWN [COLOUR] -> SB: a scroll bar, index -> cell (empty when
    /// it all fits). UP/DOWN set: that arrow blinks bold yellow, lit one tick and dark the next.
    pub fn sbar(&self, h: i64, n: i64, o: i64, up_hot: i64, dn_hot: i64, colour: Option<&[u8]>) -> Vec<(i64, Bytes)> {
        let c: &[u8] = match colour {
            Some(c) if !c.is_empty() => c,
            _ => FRAME,
        };
        let mut sb = Vec::new();
        if !(n > h && h > 0) {
            return sb;
        }
        let hot: Bytes = if self.tick % 2 != 0 { c.to_vec() } else { cat(&[B, BYEL, BLINK]) };
        let mut up = cat(&[c, "▲".as_bytes()]);
        let mut dn = cat(&[c, "▼".as_bytes()]);
        if up_hot != 0 {
            up = cat(&[&hot, "▲".as_bytes()]);
        }
        if dn_hot != 0 {
            dn = cat(&[&hot, "▼".as_bytes()]);
        }
        if h == 1 {
            if (up_hot != 0 && dn_hot == 0) || o >= n - h {
                sb.push((0, cat(&[&up, R])));
            } else {
                sb.push((0, cat(&[&dn, R])));
            }
            return sb;
        }
        let mut cells: BTreeMap<i64, Bytes> = BTreeMap::new();
        cells.insert(0, cat(&[&up, R]));
        cells.insert(h - 1, cat(&[&dn, R]));
        let t = h - 2;
        let mut s = t.wrapping_mul(h) / n;
        if s < 1 {
            s = 1;
        }
        let p = ((t - s).wrapping_mul(o).wrapping_mul(2) / (n - h) + 1) / 2;
        for i in 0..t {
            let cell = if i >= p && i < p + s { cat(&[c, "▓".as_bytes(), R]) } else { cat(&[c, "░".as_bytes(), R]) };
            cells.insert(i + 1, cell);
        }
        sb.extend(cells);
        sb
    }

    /// tab TITLE [COLOUR 0-7] -> TAB: a title on a solid band fading into the black both sides
    pub fn tab(&self, title: &[u8], colour: Option<&[u8]>) -> Bytes {
        let c: &[u8] = match colour {
            Some(c) if !c.is_empty() => c,
            _ => b"4",
        };
        cat(&[b"\x1b[3", c, b"m", "░▒▓".as_bytes(), b"\x1b[4", c, b"m", B, BWHT, b" ", title, b" ", R, b"\x1b[3", c, b"m", "▓▒░".as_bytes(), R])
    }

    /// seg TAB HINT KEYS WIDTH BORDER -> SEG: a divider's run, WIDTH wide: ═, the title band, ═ up
    /// to the keys at its right end, ══. HINT goes before the keys; short of room only it's kept,
    /// and shorter still it's cut.
    pub fn seg(&self, tab: &[u8], hint: &[u8], keys: &[u8], width: i64, border: &[u8]) -> Bytes {
        let mut k = keys.to_vec();
        if !hint.is_empty() {
            k = if k.is_empty() { hint.to_vec() } else { cat(&[hint, b"  ", &k]) };
        }
        let a = self.vlen(tab);
        let r = width - a - 6;
        let mut vl = self.vlen(&k);
        if vl > r && !hint.is_empty() {
            k = hint.to_vec();
            vl = self.vlen(&k);
        }
        if vl > r {
            if r > 1 {
                k = self.trim_colored(&k, r);
                vl = r;
            } else {
                k = Vec::new();
                vl = 0;
            }
        }
        if !k.is_empty() {
            let rep = self.rep("═".as_bytes(), width - a - vl - 5);
            cat(&[border, "═".as_bytes(), tab, border, &rep, R, b" ", &k, b" ", border, "══".as_bytes()])
        } else {
            let rep = self.rep("═".as_bytes(), width - a - 1);
            cat(&[border, "═".as_bytes(), tab, border, &rep])
        }
    }

    /// sectk TITLE KEYS [COLOUR [BORDER [HINT]]]: a divider with a title and the section's keys
    pub fn sectk(&mut self, title: &[u8], keys: &[u8], colour: Option<&[u8]>, border: Option<&[u8]>, hint: Option<&[u8]>) {
        let b: Bytes = match border {
            Some(b) if !b.is_empty() => b.to_vec(),
            _ => FRAME.to_vec(),
        };
        let c: &[u8] = match colour {
            Some(c) if !c.is_empty() => c,
            _ => b"4",
        };
        let tab = self.tab(title, Some(c));
        let seg = self.seg(&tab, hint.unwrap_or(b""), keys, self.w - 2, &b);
        self.line(cat(&[&b, "╠".as_bytes(), &seg, &b, "╣".as_bytes(), R]));
    }

    /// sect TITLE [COLOUR [BORDER [HINT]]]
    pub fn sect(&mut self, title: &[u8], colour: Option<&[u8]>, border: Option<&[u8]>, hint: Option<&[u8]>) {
        let c: &[u8] = match colour {
            Some(c) if !c.is_empty() => c,
            _ => b"4",
        };
        self.sectk(title, b"", Some(c), Some(border.unwrap_or(b"")), Some(hint.unwrap_or(b"")));
    }

    /// sect2 SPLIT-AT JOIN TITLE COLOUR BORDER HINT TITLE COLOUR BORDER HINT: a divider over two
    /// windows side by side, joined at SPLIT-AT by a ╤ in JOIN's colour.
    #[allow(clippy::too_many_arguments)]
    pub fn sect2(&mut self, split: i64, join: &[u8], t1: &[u8], c1: &[u8], b1: &[u8], h1: &[u8], t2: &[u8], c2: &[u8], b2: &[u8], h2: &[u8]) {
        let tab = self.tab(t1, Some(c1));
        let seg = self.seg(&tab, h1, b"", split + 1, b1);
        let l = cat(&[b1, "╠".as_bytes(), &seg, join, "╤".as_bytes()]);
        let tab = self.tab(t2, Some(c2));
        let seg = self.seg(&tab, h2, b"", self.w - split - 4, b2);
        self.line(cat(&[&l, &seg, b2, "╣".as_bytes(), R]));
    }

    /// kc KEY LABEL -> KC: a key as the command bar shows it
    pub fn kc(&self, key: &[u8], label: &[u8]) -> Bytes {
        cat(&[BBLU, b"[", B, BYEL, key, R, BBLU, b"]", R, BWHT, label, R])
    }

    /// kcs KEY LABEL...: several, two spaces apart (an odd one out at the end is left out)
    pub fn kcs(&self, args: &[&[u8]]) -> Bytes {
        let mut k: Bytes = Vec::new();
        for p in args.chunks_exact(2) {
            let kc = self.kc(p[0], p[1]);
            if !k.is_empty() {
                k.extend_from_slice(b"  ");
            }
            k.extend(kc);
        }
        k
    }

    /// trim_colored TEXT WIDTH -> TRIM: cut to WIDTH visible characters, keeping the colours
    pub fn trim_colored(&self, text: &[u8], width: i64) -> Bytes {
        let mut s: &[u8] = text;
        let mut out: Bytes = Vec::new();
        let mut n: i64 = 0;
        while !s.is_empty() && n < width - 1 {
            if let Some(l) = sgr_at(s, 0) {
                out.extend_from_slice(&s[..l]);
                s = &s[l..];
            } else {
                let c = chars(s).next().unwrap();
                out.extend_from_slice(c);
                s = &s[c.len()..];
                n += 1;
            }
        }
        cat(&[&out, "…".as_bytes(), R])
    }

    /// meter PERCENT -> METER: five shaded cells, retro style
    pub fn meter(&self, percent: &[u8]) -> Bytes {
        // p=${1%.*}: up to its last dot; p=${p:-0}
        let p = match percent.iter().rposition(|&c| c == b'.') {
            Some(i) => &percent[..i],
            None => percent,
        };
        let p = crate::compat::arith_int(p).unwrap_or(0);
        let mut out = Vec::new();
        for i in 0..5 {
            let lvl = p - i * 20;
            out.extend_from_slice(
                if lvl >= 20 {
                    "█"
                } else if lvl >= 13 {
                    "▓"
                } else if lvl >= 7 {
                    "▒"
                } else if lvl > 0 {
                    "░"
                } else {
                    "·"
                }
                .as_bytes(),
            );
        }
        out
    }

    /// human KB -> HUMAN: 412M / 1.2G
    pub fn human(&self, k: i64) -> Bytes {
        if k >= 1048576 {
            format!("{}.{}G", k / 1048576, k % 1048576 * 10 / 1048576).into_bytes()
        } else if k >= 1024 {
            format!("{}M", k / 1024).into_bytes()
        } else {
            format!("{}K", k).into_bytes()
        }
    }
}
