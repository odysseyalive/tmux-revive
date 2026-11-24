//! The frame's line builders, ported line for line from scripts/panel.sh (plan Phase 1.3). Bash
//! keeps their results in globals (REP, FLD, PADV, ART...); here they are return values, and the
//! globals a builder reads (TICK, W, IW, RBAR, ROWL, ROWR, OUT, CPU_HIST, SCENE) live in `Ctx`.
//! Each function names the bash one it is, in the same order as the file.

pub mod art;
pub mod banner;
pub mod prim;

use crate::compat::Bytes;
use std::collections::BTreeMap;

/// `cat(&[a, b, ...])`: the parts one after another, as bash writes "$a$b...".
pub fn cat(parts: &[&[u8]]) -> Bytes {
    let mut v = Vec::with_capacity(parts.iter().map(|p| p.len()).sum());
    for p in parts {
        v.extend_from_slice(p);
    }
    v
}

// ------------------------------------------------------------------ colours (panel.sh "colours")
pub const R: &[u8] = b"\x1b[0m";
pub const B: &[u8] = b"\x1b[1m";
pub const DIM: &[u8] = b"\x1b[2m";
pub const BLINK: &[u8] = b"\x1b[5m";
pub const REV: &[u8] = b"\x1b[7m";
pub const SELBG: &[u8] = b"\x1b[48;5;236m";
pub const QBAND: &[u8] = b"\x1b[48;5;31m";
pub const BLU: &[u8] = b"\x1b[34m";
pub const BBLU: &[u8] = b"\x1b[94m";
pub const CYN: &[u8] = b"\x1b[36m";
pub const BCYN: &[u8] = b"\x1b[96m";
pub const MAG: &[u8] = b"\x1b[35m";
pub const BMAG: &[u8] = b"\x1b[95m";
pub const YEL: &[u8] = b"\x1b[33m";
pub const BYEL: &[u8] = b"\x1b[93m";
pub const GRN: &[u8] = b"\x1b[32m";
pub const BGRN: &[u8] = b"\x1b[92m";
pub const BRED: &[u8] = b"\x1b[91m";
pub const BWHT: &[u8] = b"\x1b[97m";
pub const GRY: &[u8] = b"\x1b[90m";
pub const BGBLU: &[u8] = b"\x1b[44m";
pub const FRAME: &[u8] = BLU;
// The artwork's (panel.sh "artwork")
pub const BGBLK: &[u8] = b"\x1b[40m";
pub const BGGRY: &[u8] = b"\x1b[100m";

/// The globals the line builders read and write, as bash has them.
pub struct Ctx {
    /// TICK: the animation frame
    pub tick: i64,
    /// W, IW: the frame's width and the width inside its edges
    pub w: i64,
    pub iw: i64,
    /// RBAR, ROWL, ROWR: row's scroll bar cell and its edges' colours
    pub rbar: Bytes,
    pub rowl: Bytes,
    pub rowr: Bytes,
    /// OUT: the frame's lines so far
    pub out: Vec<Bytes>,
    /// CPU_HIST: index -> value, sparse as a bash array may be
    pub cpu_hist: BTreeMap<i64, i64>,
    /// SCENE: an index into SCENES
    pub scene: i64,
    /// OSP: the CRT's prompt, from the system (panel.sh after big_banner)
    pub osp: Bytes,
    /// The art's canvas and its random numbers (canvas, put, rnd)
    pub art: art::Canvas,
}

impl Ctx {
    pub fn new() -> Ctx {
        Ctx {
            tick: 0,
            w: 80,
            iw: 76,
            rbar: Vec::new(),
            rowl: FRAME.to_vec(),
            rowr: FRAME.to_vec(),
            out: Vec::new(),
            cpu_hist: BTreeMap::new(),
            scene: 0,
            osp: banner::osp(),
            art: art::Canvas::default(),
        }
    }
}

impl Default for Ctx {
    fn default() -> Self {
        Ctx::new()
    }
}
