//! The frame's line builders, ported line for line from scripts/panel.sh (plan Phase 1.3). Bash
//! keeps their results in globals (REP, FLD, PADV, ART...); here they are return values, and the
//! globals a builder reads (TICK, W, IW, RBAR, ROWL, ROWR, OUT, CPU_HIST, SCENE) live in `Ctx`.
//! Each function names the bash one it is, in the same order as the file.

pub mod art;
pub mod banner;
pub mod frame;
pub mod help;
pub mod panes;
pub mod peek;
pub mod prim;
pub mod question;

use crate::compat::{arith_int, Bytes};
use crate::snapshot::Snapshot;
use std::collections::BTreeMap;

/// `$((X))` of a variable's value: bash's arithmetic, 0 for what it can't read as a number.
pub fn num(b: &[u8]) -> i64 {
    arith_int(b).unwrap_or(0)
}

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
    /// What a frame is drawn from (frame.rs): the snapshot and the panel's own variables
    pub p: State,
    /// A --once with no snapshot (SNAP ""): the looks draw makes as it goes, in bash's order
    /// (pane_screen's capture-pane, remote_peek's peek_look, intros_look, messages and
    /// links_saves). None: everything from the snapshot, as under REVIVE_PANEL_SNAP.
    pub live: Option<Box<dyn Live>>,
}

/// What draw looks at for itself when there is no snapshot (bash's `[[ -z $SNAP ]]` paths).
pub trait Live {
    /// pane_screen %ID [-e]: `tm capture-pane [-e] -p -t ID`'s lines
    fn pane_screen(&mut self, id: &[u8], coloured: bool) -> Vec<Bytes>;
    /// peek_look HOST %ID LINES -> (RPEEK_AT, RPEEK)
    fn peek_look(&mut self, h: &[u8], id: &[u8], n: i64) -> (Bytes, Vec<Bytes>);
    /// intros_look -> INTROS
    fn intros(&mut self) -> Vec<Bytes>;
    /// messages; links_saves -> MSG, MOLD, MWAIT, INTRO_ON, SIDE
    fn messages(&mut self) -> (Vec<Bytes>, i64, i64, Bytes, Vec<Bytes>);
}

/// The variables draw reads and changes, as bash has them for one frame: loaded from a snapshot
/// (snap_apply), the environment's, and what draw sets on its way (WF, WB, WK, NAV, PH...).
#[derive(Default)]
pub struct State {
    /// The snapshot's arrays (P_*, W_*, X_*, MSG, SIDE, INTROS, SCREEN*, RPEEK, QL, NOTICES)
    /// and associative arrays (RVER, ROWNER, FOLD), read through `a`, `alen` and `assoc`.
    pub snap: Snapshot,
    // The snapshot's variables, as draw reads them.
    pub sel: i64,
    pub sel_id: Bytes,
    pub hsel: Bytes,
    pub focus: i64,
    pub won: [i64; 4],
    pub po: i64,
    pub pb: i64,
    pub pb_for: Bytes,
    pub mo: i64,
    pub so: i64,
    pub mman: i64,
    pub peek: i64,
    pub peek_sel: Bytes,
    pub peek_all: i64,
    pub help: i64,
    pub help_top: i64,
    pub flash: Bytes,
    pub flash_t: i64,
    pub lbox: i64,
    pub answering: i64,
    pub atop: Vec<Bytes>,
    pub atop_bh: i64,
    pub qon: i64,
    pub mold: i64,
    pub mwait: i64,
    pub msg_intro: Bytes,
    pub intro_on: Bytes,
    pub p_groups: i64,
    pub version: Bytes,
    pub host: Bytes,
    pub screen_id: Bytes,
    pub rpeek_for: Bytes,
    pub rpeek_at: Bytes,
    /// `${SNAP_SECS:-$SECONDS}`
    pub secs: i64,
    // The environment's (not in the snapshot: the harness sets them the same for both panels).
    pub home: Bytes,
    pub user: Option<Bytes>,
    pub agent_say_host: Option<Bytes>,
    pub tip_secs: i64,
    /// NOW, as now_s gives it (REVIVE_PANEL_NOW pinned, else the clock)
    pub now: i64,
    // What draw sets on its way.
    pub tcols: i64,
    pub tlines: i64,
    pub lines: i64,
    pub n: i64,
    pub ph: i64,
    pub bh: i64,
    pub wf: i64,
    pub wb: [Bytes; 4],
    /// WH: each window's height as draw last drew it (scroll's page)
    pub wh: [i64; 4],
    pub wk: [Bytes; 4],
    /// NAV: a pane's index, or h:HOST for a heading (Nav::Head)
    pub nav: Vec<Nav>,
    pub nat: i64,
    pub cpad: Bytes,
    /// L: the screen being drawn in the peek or question box
    pub l: Vec<Bytes>,
    pub qstyle: BTreeMap<i64, Bytes>,
    pub qhi: BTreeMap<i64, Bytes>,
    /// BANNER and BIG_ROWS, made once at the start (banner_rows REVIVE, big_banner REVIVE)
    pub banner: [Bytes; 3],
    pub big_rows: Vec<Bytes>,
    /// The ? page's (help.sh): its rows for a width, kept while the width is the same
    pub hp: help::Page,
    /// What a --once prints: the frame's rows, and a notice's box after them
    pub print: Bytes,
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Nav {
    Pane(i64),
    Head(Bytes),
}

impl State {
    /// `${A[i]}` of an indexed array in the snapshot ("" when unset)
    pub fn a(&self, name: &str, i: i64) -> &[u8] {
        self.snap.arrays.get(name).and_then(|m| m.get(&i)).map(|v| v.as_slice()).unwrap_or(b"")
    }
    /// `${A[i]+set}`
    pub fn aset(&self, name: &str, i: i64) -> bool {
        self.snap.arrays.get(name).is_some_and(|m| m.contains_key(&i))
    }
    /// `${#A[@]}`
    pub fn alen(&self, name: &str) -> i64 {
        self.snap.arrays.get(name).map(|m| m.len() as i64).unwrap_or(0)
    }
    /// `("${A[@]}")`
    pub fn list(&self, name: &str) -> Vec<Bytes> {
        self.snap.list(name)
    }
    /// `${A[KEY]:-}` of an associative array
    pub fn assoc(&self, name: &str, k: &[u8]) -> &[u8] {
        self.snap.assoc.get(name).and_then(|m| m.get(k)).map(|v| v.as_slice()).unwrap_or(b"")
    }
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
            p: State::default(),
            live: None,
        }
    }
}

impl Default for Ctx {
    fn default() -> Self {
        Ctx::new()
    }
}
