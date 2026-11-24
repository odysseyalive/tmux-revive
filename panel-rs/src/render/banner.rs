//! The banner: scripts/panel.sh banner_rows, big_banner, the CRT's prompt (OSP), monitor and
//! spark, in that order.

use super::*;
use crate::compat::{chars, Bytes};

/// GLYPH: block letters for the banner, three rows each.
fn glyph(c: &[u8]) -> &'static str {
    match c {
        b"R" => "█▀▄|█▀▄|▀ ▀",
        b"E" => "█▀▀|█▀▀|▀▀▀",
        b"V" => "█ █|▀▄▀| ▀ ",
        b"I" => "▀█▀| █ |▀▀▀",
        _ => "",
    }
}

/// BIG: the big banner's letters, five rows each.
fn big(c: &[u8]) -> &'static str {
    match c {
        b"R" => "█████▄|██   █|█████▀|██  ▀▄|██   █",
        b"E" => "██████|██    |█████ |██    |██████",
        b"V" => "██  ██|██  ██|▐█  █▌| ▀██▀ |  ▀▀  ",
        b"I" => "██|██|██|██|██",
        b"H" => "██  ██|██  ██|██████|██  ██|██  ██",
        b"L" => "██    |██    |██    |██    |██████",
        b"P" => "█████▄|██   █|█████▀|██    |██    ",
        _ => "",
    }
}

/// `IFS='|' read -ra parts <<<"$g"`, element R (a letter with no glyph has none: bash, under
/// set -u, would stop there; the panel only spells REVIVE and HELP).
fn part(g: &str, r: usize) -> &str {
    if g.is_empty() {
        return "";
    }
    g.split('|').nth(r).unwrap_or("")
}

/// The CRT's prompt shows the system it's running on (OSP, set once after big_banner).
pub fn osp() -> Bytes {
    let mut u: libc::utsname = unsafe { std::mem::zeroed() };
    let os = if unsafe { libc::uname(&mut u) } == 0 {
        unsafe { std::ffi::CStr::from_ptr(u.sysname.as_ptr()) }.to_bytes().to_vec()
    } else {
        Vec::new()
    };
    let p: &str = if os == b"Darwin" {
        "macos% "
    } else if os.ends_with(b"BSD") {
        "bsd$ "
    } else if os == b"Linux" {
        // grep -qi microsoft /proc/version
        let v = std::fs::read("/proc/version").unwrap_or_default();
        if v.to_ascii_lowercase().windows(9).any(|w| w == b"microsoft") {
            "wsl$ "
        } else {
            "linux$ "
        }
    } else {
        "$ "
    };
    p.as_bytes().to_vec()
}

impl Ctx {
    /// banner_rows WORD -> BANNER[0..2]
    pub fn banner_rows(&self, word: &[u8]) -> [Bytes; 3] {
        let mut b: [Bytes; 3] = Default::default();
        for ch in chars(word) {
            let g = glyph(ch);
            for (r, row) in b.iter_mut().enumerate() {
                row.extend_from_slice(part(g, r).as_bytes());
                row.push(b' ');
            }
        }
        b
    }

    /// big_banner WORD [COLOUR x5] -> BIG_ROWS[0..5]: five rows of block letters, a colour for
    /// each (white fading through cyan to blue unless given), with a blue ░ drop shadow one cell
    /// down and right.
    pub fn big_banner(&self, word: &[u8], shades: &[&[u8]]) -> Vec<Bytes> {
        let default: [Bytes; 5] = [cat(&[B, BWHT]), cat(&[B, BCYN]), cat(&[B, BCYN]), CYN.to_vec(), BBLU.to_vec()];
        let shade: Vec<Bytes> = if shades.is_empty() { default.to_vec() } else { shades.iter().map(|s| s.to_vec()).collect() };
        // G[0..4] as characters, G[5] empty
        let mut g: Vec<Vec<&[u8]>> = vec![Vec::new(); 6];
        for ch in chars(word) {
            let gl = big(ch);
            for (r, row) in g.iter_mut().take(5).enumerate() {
                row.extend(chars(part(gl, r).as_bytes()));
                row.push(b" ");
            }
        }
        let mut rows = Vec::new();
        for r in 0..6 {
            let mut out: Bytes = Vec::new();
            let mut cur: u8 = 0; // "" / L / S
            for c in 0..=g[0].len() {
                let ch: &[u8] = g[r].get(c).copied().unwrap_or(b"");
                let mut up: &[u8] = b" ";
                if r > 0 && c > 0 {
                    up = g[r - 1].get(c - 1).copied().unwrap_or(b"");
                }
                if !ch.is_empty() && ch != b" " {
                    if cur != b'L' {
                        out.extend_from_slice(R);
                        out.extend_from_slice(shade.get(r).map(|s| s.as_slice()).unwrap_or(b""));
                        cur = b'L';
                    }
                    out.extend_from_slice(ch);
                } else if !up.is_empty() && up != b" " {
                    if cur != b'S' {
                        out.extend_from_slice(R);
                        out.extend_from_slice(BLU);
                        cur = b'S';
                    }
                    out.extend_from_slice("░".as_bytes());
                } else {
                    out.push(b' ');
                }
            }
            out.extend_from_slice(R);
            rows.push(out);
        }
        rows
    }

    /// monitor WORKING ASKING AGENTS -> MON[0..5]: a little CRT, its screen live. The counts are
    /// shown as given, and tested as bash's arithmetic reads them.
    pub fn monitor(&self, working: &[u8], asking: &[u8], agents: &[u8]) -> Vec<Bytes> {
        let num = |s: &[u8]| crate::compat::arith_int(s).unwrap_or(0);
        let g = GRY;
        let mut cur: &[u8] = b" ";
        if self.tick % 2 == 0 {
            cur = "█".as_bytes();
        }
        let (msg, col) = if num(asking) != 0 {
            (cat(&[asking, b" NEED YOU"]), cat(&[B, BMAG, BLINK]))
        } else if num(working) != 0 {
            (cat(&[working, b" working"]), BYEL.to_vec())
        } else {
            (cat(&[agents, b" AI idle"]), BGRN.to_vec())
        };
        let cur = self.fld(&cat(&[b" ", &self.osp, cur]), 11);
        let fld = self.fld(&cat(&[b" ", &msg]), 11);
        vec![
            cat(&[g, "▄▄▄▄▄▄▄▄▄▄▄▄▄".as_bytes(), R]),
            cat(&[g, "█".as_bytes(), R, BGRN, &cur, R, g, "█".as_bytes(), R]),
            cat(&[g, "█".as_bytes(), R, &col, &fld, R, g, "█".as_bytes(), R]),
            cat(&[g, "▀▀▀▀▀▀▀▀▀▀▀▀▀".as_bytes(), R]),
            cat(&[g, "     ▄█▄     ".as_bytes(), R]),
            cat(&[g, "  ▀▀▀▀▀▀▀▀▀  ".as_bytes(), R]),
        ]
    }

    /// spark WIDTH -> SPARK: CPU history as a ▁▂▃▅▇ graph, newest on the right
    pub fn spark(&self, w: i64) -> Bytes {
        const BARS: [&str; 8] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"];
        let mut max: i64 = 10;
        // local -a h=("${CPU_HIST[@]}"), all of it while there are no more than w;
        // ((${#h[@]} > w)) && h=("${CPU_HIST[@]: -$w}"): "-$w" is arithmetic, so a negative
        // WIDTH counts from the start; a negative offset is from one past the highest index,
        // and one before the first index gives nothing at all.
        let off = w.wrapping_neg();
        let h: Vec<i64> = if (self.cpu_hist.len() as i64) <= w {
            self.cpu_hist.values().copied().collect()
        } else if off < 0 {
            let top = self.cpu_hist.keys().next_back().map(|k| k + 1).unwrap_or(0);
            let start = top + off;
            if start < 0 {
                Vec::new()
            } else {
                self.cpu_hist.range(start..).map(|(_, v)| *v).collect()
            }
        } else {
            self.cpu_hist.range(off..).map(|(_, v)| *v).collect()
        };
        for &v in &h {
            if v > max {
                max = v;
            }
        }
        let mut out: Bytes = Vec::new();
        let mut i = h.len() as i64;
        while i < w {
            out.extend_from_slice(GRY);
            out.extend_from_slice("▁".as_bytes());
            i += 1;
        }
        for &v in &h {
            let lvl = v.wrapping_mul(7) / max;
            if lvl <= 1 {
                out.extend_from_slice(BLU);
            } else if lvl <= 3 {
                out.extend_from_slice(BBLU);
            } else if lvl <= 5 {
                out.extend_from_slice(BCYN);
            } else {
                out.extend_from_slice(BYEL);
            }
            // ${bars[lvl]}: a negative index counts from the end
            let ix = if lvl < 0 { lvl + 8 } else { lvl };
            if (0..8).contains(&ix) {
                out.extend_from_slice(BARS[ix as usize].as_bytes());
            }
        }
        cat(&[&out, R])
    }
}
