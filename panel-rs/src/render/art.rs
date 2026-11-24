//! The artwork: scripts/panel.sh "artwork", in its order. canvas, put, rnd, emit, stars,
//! twinkle, art, then the scenes and their helpers. Shell arithmetic throughout: 64-bit signed,
//! wrapping, truncating division.
//!
//! bash keeps the last frames drawn in ART_MEMO; it is an optimisation with no visible effect
//! (a scene's frame is the same at TICK and TICK % ART_LOOP), and is not ported.

use super::*;
use crate::compat::{pad, Bytes};

/// SCENES and TITLES
pub const SCENES: [&str; 5] = ["city", "mountains", "space", "circuit", "grid"];
pub const TITLES: [&str; 5] = ["night city", "mountains", "deep space", "circuit board", "neon grid"];

/// The canvas (ART_W, ART_H; CH and CO, set together by put: an element set to an empty colour
/// is still set), the random numbers (SEED, RV) and the frame of the animation (AT).
#[derive(Default)]
pub struct Canvas {
    pub w: i64,
    pub h: i64,
    cells: Vec<Option<(&'static [u8], Bytes)>>,
    seed: i64,
    rv: i64,
    at: i64,
    tri: i64,
}

fn esc(n: &str) -> Bytes {
    format!("\x1b[{}m", n).into_bytes()
}

impl Ctx {
    /// canvas WIDTH HEIGHT
    fn canvas(&mut self, w: i64, h: i64) {
        let a = &mut self.art;
        a.w = w;
        a.h = h;
        a.cells = if w > 0 && h > 0 { vec![None; (w * h) as usize] } else { Vec::new() };
    }

    /// put ROW COL CHAR COLOUR (off the canvas: ignored)
    fn put(&mut self, r: i64, c: i64, ch: &'static str, co: &[u8]) {
        let a = &mut self.art;
        if !(r >= 0 && r < a.h && c >= 0 && c < a.w) {
            return;
        }
        a.cells[(r * a.w + c) as usize] = Some((ch.as_bytes(), co.to_vec()));
    }

    /// rnd: same seed, same picture
    fn rnd(&mut self) {
        let a = &mut self.art;
        a.seed = (a.seed.wrapping_mul(1103515245).wrapping_add(12345)) & 2147483647;
        a.rv = a.seed >> 8;
    }
    fn rv(&self) -> i64 {
        self.art.rv
    }

    /// emit -> ART rows, switching colour only where it changes; the empty cells between the
    /// ones drawn on go in as runs of spaces.
    fn emit(&mut self) -> Vec<Bytes> {
        let (aw, ah) = (self.art.w, self.art.h);
        let mut art = Vec::new();
        let (mut r, mut c) = (0i64, 0i64);
        let mut out: Bytes = Vec::new();
        let mut cur: Bytes = Vec::new();
        for (i, cell) in self.art.cells.iter().enumerate() {
            let Some((ch, co)) = cell else { continue };
            let i = i as i64;
            while i / aw > r {
                if c < aw {
                    if !cur.is_empty() {
                        out.extend_from_slice(R);
                    }
                    out.extend(pad(aw - c));
                }
                out.extend_from_slice(R);
                art.push(std::mem::take(&mut out));
                cur.clear();
                c = 0;
                r += 1;
            }
            let x = i % aw;
            if x > c {
                if !cur.is_empty() {
                    out.extend_from_slice(R);
                    cur.clear();
                }
                out.extend(pad(x - c));
            }
            if *co != cur {
                cur = co.clone();
                out.extend_from_slice(R);
                out.extend_from_slice(&cur);
            }
            // ${CH[i]:- }
            out.extend_from_slice(if ch.is_empty() { b" " } else { ch });
            c = x + 1;
        }
        while r < ah {
            if c < aw {
                if !cur.is_empty() {
                    out.extend_from_slice(R);
                }
                out.extend(pad(aw - c));
            }
            out.extend_from_slice(R);
            art.push(std::mem::take(&mut out));
            cur.clear();
            c = 0;
            r += 1;
        }
        art
    }

    /// stars ROWS ONE-IN-N: sky dust in the top ROWS rows, holding still
    fn stars(&mut self, rows: i64, n: i64) {
        for r in 0..rows {
            let mut c = 0;
            while c < self.art.w {
                self.rnd();
                let rv = self.rv();
                if rv % n != 0 {
                    c += 1;
                    continue;
                }
                if rv / 7 % 9 == 0 {
                    self.put(r, c, "*", BWHT);
                } else if rv % 3 == 0 {
                    self.put(r, c, "·", GRY);
                } else {
                    self.put(r, c, ".", BLU);
                }
                c += 1;
            }
        }
    }

    /// twinkle N ROWS: N stars in the top ROWS rows that take turns shining
    fn twinkle(&mut self, n: i64, rows: i64) {
        for k in 0..n {
            self.rnd();
            let r = self.rv() % (if rows > 0 { rows } else { 1 });
            self.rnd();
            let c = self.rv() % self.art.w;
            if (self.art.at + k) % 2 != 0 {
                self.put(r, c, "*", BWHT);
            } else {
                self.put(r, c, "·", GRY);
            }
        }
    }

    /// art WIDTH HEIGHT [still] -> ART rows of the current scene; "still" stops its animation
    pub fn art(&mut self, w: i64, h: i64, still: bool) -> Vec<Bytes> {
        self.art.at = if still { 0 } else { self.tick };
        self.canvas(w, h);
        self.art.seed = 7919i64.wrapping_mul(self.scene.wrapping_add(1));
        if self.art.w > 0 && self.art.h > 0 {
            // "scene_${SCENES[SCENE]}" (a SCENE out of range: bash, under set -u, stops there)
            match self.scene {
                0 => self.scene_city(),
                1 => self.scene_mountains(),
                2 => self.scene_space(),
                3 => self.scene_circuit(),
                4 => self.scene_grid(),
                _ => {}
            }
        }
        self.emit()
    }

    /// scene_city: towers with lit windows under the stars; one star and two windows change
    fn scene_city(&mut self) {
        let (w, h) = (self.art.w, self.art.h);
        let mut x = 0;
        let (mut wr, mut wc, mut wb): (Vec<i64>, Vec<i64>, Vec<&'static [u8]>) = (Vec::new(), Vec::new(), Vec::new());
        self.stars(h, 23);
        self.twinkle(1, h / 2);
        self.put((h > 4) as i64, w * 4 / 5, "●", BYEL);
        while x < w {
            self.rnd();
            let bw = 3 + self.rv() % 6;
            self.rnd();
            let mut bh = h / 3 + self.rv() % (h - h / 3 + 1);
            if bh < 1 {
                bh = 1;
            }
            self.rnd();
            let (top, body): (&[u8], &'static [u8]) = if self.rv() % 2 != 0 { (BLU, b"\x1b[44m") } else { (GRY, BGGRY) };
            let mut c = x;
            while c < x + bw && c < w {
                self.put(h - bh, c, "▄", top);
                for r in (h - bh + 1)..h {
                    self.rnd();
                    let mut lit = false;
                    if (c - x) % 2 != 0 {
                        if self.rv() % 3 == 0 {
                            lit = true;
                        }
                        wr.push(r);
                        wc.push(c);
                        wb.push(body);
                    }
                    if lit {
                        self.put(r, c, "▪", &cat(&[body, BYEL]));
                    } else {
                        self.put(r, c, " ", body);
                    }
                }
                c += 1;
            }
            self.rnd();
            x = x + bw + self.rv() % 2;
        }
        // Two windows somewhere in town, one light on while the other is off.
        let mut k = 0;
        while k < 2 && !wr.is_empty() {
            self.rnd();
            let i = (self.rv() % wr.len() as i64) as usize;
            if (self.art.at + k) % 2 != 0 {
                self.put(wr[i], wc[i], "▪", &cat(&[wb[i], BYEL]));
            } else {
                self.put(wr[i], wc[i], " ", wb[i]);
            }
            k += 1;
        }
    }

    /// tri X PERIOD AMPLITUDE -> TRI: a triangle wave from 0 up to AMPLITUDE and back
    pub fn tri(&mut self, x: i64, per: i64, amp: i64) -> i64 {
        let per = if per < 2 { 2 } else { per };
        let xx = (x % per + per) % per;
        let h = per / 2;
        self.art.tri = (if xx < h { xx } else { per - xx }).wrapping_mul(amp) / h;
        self.art.tri
    }

    /// pixel_cell ROW COL TOP BOTTOM: two pixels in one cell, a ▀ in the top one's colour over the
    /// bottom one's. Colours 0-15; -1 is empty sky, left for the stars.
    fn pixel_cell(&mut self, r: i64, c: i64, t: i64, b: i64) {
        if t < 0 && b < 0 {
            return;
        }
        let tf = if t < 8 { 30 + t } else { 82 + t };
        let bb = if b < 8 { 40 + b } else { 92 + b };
        if t == b {
            self.put(r, c, " ", &esc(&bb.to_string()));
        } else if t < 0 {
            self.put(r, c, "▄", &esc(&(if b < 8 { 30 + b } else { 82 + b }).to_string()));
        } else if b < 0 {
            self.put(r, c, "▀", &esc(&tf.to_string()));
        } else {
            self.put(r, c, "▀", &esc(&format!("{};{}", tf, bb)));
        }
    }

    /// scene_mountains: a snow-capped range under the moon, dark wooded hills in front
    fn scene_mountains(&mut self) {
        let (w, h) = (self.art.w, self.art.h);
        let ph = h * 2;
        let mut jag: i64 = 0;
        let mut win: i64 = -1;
        let (mut pk, mut phs, mut ps) = (Vec::new(), Vec::new(), Vec::new());
        let mut m = Mountains::default();
        self.stars(h, 19);
        self.twinkle(2, h / 3);
        self.rnd();
        self.put(0, w / 8 + self.rv() % (w * 3 / 4 + 1), "●", BWHT);
        // The range: two to four big peaks, each a rough cone, roughened a little column by column.
        self.rnd();
        let n = 2 + self.rv() % 3;
        for k in 0..n {
            self.rnd();
            pk.push(k * w / n + self.rv() % (w / n + 1));
            self.rnd();
            phs.push(ph * 55 / 100 + self.rv() % (ph * 35 / 100 + 1));
            self.rnd();
            ps.push(6 + self.rv() % 6);
        }
        self.rnd();
        let p = self.rv() % 97;
        for c in 0..w {
            // The peak standing tallest here decides the light.
            let mut v: i64 = 0;
            let mut k: usize = 0;
            for k2 in 0..n as usize {
                let d = if c > pk[k2] { c - pk[k2] } else { pk[k2] - c };
                let r = phs[k2] - d * ps[k2] / 10;
                if r > v {
                    v = r;
                    k = k2;
                }
            }
            m.lit.push((c <= pk[k]) as i64);
            // A dim range further back, for distance.
            let t = self.tri(c + p * 3, w / 4 + 9, ph / 7);
            m.back.push(ph * 3 / 10 + t);
            self.rnd();
            jag = jag + self.rv() % 3 - 1;
            if jag > 2 {
                jag = 2;
            }
            if jag < -2 {
                jag = -2;
            }
            v += jag;
            if v > ph - 1 {
                v = ph - 1;
            }
            if v < 2 {
                v = 2;
            }
            m.far.push(v);
            self.rnd();
            m.snow.push(2 + self.rv() % 3);
            // Wooded hills in front, and the ragged tops of their trees.
            let t = self.tri(c + p, w / 3 + 5, ph / 8);
            let v = ph / 7 + t;
            m.near.push(v);
            self.rnd();
            m.tree.push(v + self.rv() % 3);
        }
        self.rnd();
        if w > 20 {
            win = w / 5 + self.rv() % (w * 3 / 5);
        }
        m.win = win;
        m.ph = ph;
        for r in 0..h {
            for c in 0..w {
                let top = m.mpix(ph - 1 - 2 * r, c);
                let bot = m.mpix(ph - 2 - 2 * r, c);
                self.pixel_cell(r, c, top, bot);
            }
        }
    }

    /// scene_space: a ringed planet, starfields and a comet crossing over time
    fn scene_space(&mut self) {
        let (w, h) = (self.art.w, self.art.h);
        let (pr, pc) = (h / 2, w / 4);
        let tail = ["=", "-", "-", "·", "·"];
        let mut rad = h * 2 / 5;
        if rad < 1 {
            rad = 1;
        }
        self.stars(h, 11);
        self.twinkle(2, h);
        for r in (pr - rad)..=(pr + rad) {
            for c in (pc - 2 * rad)..=(pc + 2 * rad) {
                let dx = c - pc;
                let dy = (r - pr) * 2;
                if dx * dx + dy * dy > 4 * rad * rad {
                    continue;
                }
                if dx < -rad / 2 {
                    self.put(r, c, "█", BCYN);
                } else if dx < rad / 2 {
                    self.put(r, c, "▓", CYN);
                } else {
                    self.put(r, c, "▒", BLU);
                }
            }
        }
        for c in (pc - 4 * rad)..=(pc + 4 * rad) {
            let mut dx = c - pc;
            if dx < 0 {
                dx = -dx;
            }
            if dx > 2 * rad - 1 {
                self.put(pr, c, "─", BYEL);
            }
        }
        let cr = h / 4;
        let cx = self.art.at.wrapping_mul(3) % (w + 12) - 6;
        self.put(cr, cx, "*", BWHT);
        for k in 1..=5 {
            if k <= 2 {
                self.put(cr, cx - k, tail[(k - 1) as usize], BCYN);
            } else {
                self.put(cr, cx - k, tail[(k - 1) as usize], BLU);
            }
        }
    }

    /// scene_circuit: traces turning corners, chips and three blinking LEDs
    fn scene_circuit(&mut self) {
        let (w, h) = (self.art.w, self.art.h);
        let mut blink = 0;
        let (mut lr, mut lc) = (Vec::new(), Vec::new());
        let n = w * h / 28 + 1;
        for _ in 0..n {
            self.rnd();
            let r = self.rv() % h;
            self.rnd();
            let c = self.rv() % w;
            self.rnd();
            let len = 3 + self.rv() % 12;
            self.rnd();
            let vl = self.rv() % (h / 2 + 1);
            self.put(r, c, "●", GRN);
            for i in 1..len {
                self.put(r, c + i, "─", GRN);
            }
            if vl != 0 {
                self.put(r, c + len, "┐", GRN);
                for i in 1..vl {
                    self.put(r + i, c + len, "│", GRN);
                }
            }
            self.put(r + vl, c + len, "●", BGRN);
            lr.push(r + vl);
            lc.push(c + len);
        }
        let mut k = 0;
        while k < 2 && h >= 3 {
            self.rnd();
            let r = 1 + self.rv() % (h - 2);
            self.rnd();
            let c = self.rv() % w;
            for i in 0..8 {
                self.put(r - 1, c + i, "┬", GRY);
                self.put(r, c + i, "▓", GRY);
                self.put(r + 1, c + i, "┴", GRY);
            }
            k += 1;
        }
        // Three LEDs that ended up on the board blink; the rest stay lit.
        let mut k = 0;
        while k < lr.len() && blink < 3 {
            let (r, c) = (lr[k], lc[k]);
            k += 1;
            if !(r >= 0 && r < h && c >= 0 && c < w) {
                continue;
            }
            if (blink + self.art.at) % 2 != 0 {
                self.put(r, c, "●", BGRN);
            } else {
                self.put(r, c, "●", BRED);
            }
            blink += 1;
        }
    }

    /// cloud ROW COL WIDTH COLOUR: a thin streak, puffs along its top, flat underneath
    fn cloud(&mut self, row: i64, col: i64, width: i64, colour: &[u8]) {
        for i in 0..width {
            self.rnd();
            if i > 1 && i < width - 2 && self.rv() % 3 != 0 {
                self.put(row, col + i, "▄", colour);
            }
            self.put(row + 1, col + i, "▀", colour);
        }
    }

    /// scene_grid: a striped sun setting behind a neon floor, streaks of cloud in a dusk sky
    fn scene_grid(&mut self) {
        let (w, h) = (self.art.w, self.art.h);
        let mut hz = h / 2;
        let cx = w / 2;
        if hz < 1 {
            hz = 1;
        }
        let mut sr = hz;
        if sr > w / 5 {
            sr = w / 5;
        }
        if sr < 1 {
            sr = 1;
        }
        // Clouds first, so the sun sits in front of them. The first two drift slowly.
        let n = w / 25 + 2;
        let mut k = 0;
        while k < n && hz >= 3 {
            self.rnd();
            let cr = self.rv() % (hz - 2);
            self.rnd();
            let cw = 8 + self.rv() % 14;
            self.rnd();
            let mut cc = self.rv() % (w + cw) - cw;
            if k < 2 {
                cc = (cc + self.art.at / 2 + cw) % (w + cw) - cw; // a column every other frame
            }
            let mut dx = cc + cw / 2 - cx;
            if dx < 0 {
                dx = -dx;
            }
            let ccol: &[u8] = if dx < 3 * sr {
                BMAG
            } else if dx < 6 * sr {
                MAG
            } else {
                GRY
            };
            self.cloud(cr, cc, cw, ccol);
            k += 1;
        }
        for r in (hz - sr)..hz {
            let dy = (hz - r) * 2;
            let mut col: &[u8] = if r < hz - sr * 2 / 3 {
                BYEL
            } else if r < hz - sr / 3 {
                BRED
            } else {
                BMAG
            };
            // The stripes are gaps in the sun, cleared so nothing behind shows through them.
            if sr >= 4 && hz - r >= 2 && (hz - r) <= sr / 2 + 1 && (hz - r) % 2 == 0 {
                col = b"";
            }
            for c in (cx - 2 * sr)..=(cx + 2 * sr) {
                let dx = c - cx;
                if dx * dx + dy * dy > 4 * sr * sr {
                    continue;
                }
                if !col.is_empty() {
                    self.put(r, c, "█", col);
                } else {
                    self.put(r, c, " ", b"");
                }
            }
        }
        for c in 0..w {
            self.put(hz, c, "─", BMAG);
        }
        for r in (hz + 1)..h {
            let d = r - hz;
            if d == 1 || d == 3 || d == 6 || d == 10 || d == 15 || d == 21 {
                for c in 0..w {
                    self.put(r, c, "─", MAG);
                }
            }
            for k in -20..=20i64 {
                let x = cx + k * (d * 3 + 2);
                if k < 0 {
                    self.put(r, x, "/", BMAG);
                } else if k > 0 {
                    self.put(r, x, "\\", BMAG);
                } else {
                    self.put(r, x, "│", BMAG);
                }
            }
        }
    }
}

/// scene_mountains's columns, which mpix reads (bash's locals, seen through dynamic scope).
#[derive(Default)]
struct Mountains {
    far: Vec<i64>,
    near: Vec<i64>,
    tree: Vec<i64>,
    snow: Vec<i64>,
    back: Vec<i64>,
    lit: Vec<i64>,
    win: i64,
    ph: i64,
}

impl Mountains {
    /// mpix HEIGHT COL -> MP: the colour of that pixel of the mountain scene
    fn mpix(&self, y: i64, c: i64) -> i64 {
        let c = c as usize;
        if y < self.near[c] {
            if c as i64 == self.win && y == self.near[c] - 3 {
                11 // one lit window
            } else {
                2
            }
        } else if y < self.tree[c] {
            2
        } else if y < self.far[c] {
            // Snow on the high peaks; moonlit side bright, shadow side dim.
            if self.far[c] - y <= self.snow[c] && self.far[c] > self.ph * 6 / 10 {
                if self.lit[c] != 0 {
                    15
                } else {
                    7
                }
            } else if self.lit[c] != 0 {
                12
            } else {
                4
            }
        } else if y < self.back[c] {
            8
        } else {
            -1
        }
    }
}
