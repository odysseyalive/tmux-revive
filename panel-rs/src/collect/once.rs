//! A `--once` that gathers for itself: scripts/panel.sh's `if ((ONCE))` path after its
//! snapshot load. Two gathers half a second apart (CPU is measured between them), the selection
//! from REVIVE_PANEL_SEL, fold_load, sel_fix, then one frame.
//!
//! - With REVIVE_PANEL_SNAP=save:FILE, snap_look reads what draw would read from outside, FILE
//!   gets SNAP_VARS as snap_save writes them, and the frame is drawn from those (bash draws
//!   from them too: its SNAP isn't empty).
//! - Without it, draw makes its own looks as it goes, in bash's order (render::Live), so the
//!   programs run are bash's, with the same arguments.

use super::sh::{self, Bytes};
use super::{m, G};
use crate::snapshot::{Kind, Snapshot, SNAP_VARS};
use std::collections::BTreeMap;

/// The selection and what fold_load and sel_fix leave
#[derive(Default)]
pub struct Sel {
    pub sel: i64,
    pub sel_id: Bytes,
    pub hsel: Bytes,
    pub fold: BTreeMap<Bytes, Bytes>,
}

/// What snap_look reads
#[derive(Default)]
pub struct Look {
    pub screen_id: Bytes,
    pub screen: Vec<Bytes>,
    pub screen_e: Vec<Bytes>,
    pub rpeek_for: Bytes,
    pub rpeek_at: Bytes,
    pub rpeek: Vec<Bytes>,
    pub intros: Vec<Bytes>,
    pub msg: Vec<Bytes>,
    pub mold: i64,
    pub mwait: i64,
    pub msg_intro: Bytes,
    pub side: Vec<Bytes>,
}

fn arr(v: &[Bytes]) -> BTreeMap<i64, Bytes> {
    v.iter().enumerate().map(|(i, x)| (i as i64, x.clone())).collect()
}

impl G {
    /// fold_load: FOLD[HOST]=1 for each file in $DIR/panel/fold
    pub fn fold_load(&self) -> BTreeMap<Bytes, Bytes> {
        let mut f = BTreeMap::new();
        for p in sh::glob(&sh::path(&[&self.dir, b"/panel/fold"]), b"", b"", false) {
            if sh::is_file(&p) {
                f.insert(sh::basename(&p).to_vec(), b"1".to_vec());
            }
        }
        f
    }

    /// The selection a --once draws with: REVIVE_PANEL_SEL's pane (the last row with that id),
    /// else the first; then sel_fix
    pub fn pick(&self) -> Sel {
        let mut s = Sel::default();
        let want = sh::env("REVIVE_PANEL_SEL").unwrap_or_default();
        for (i, id) in self.p.id.iter().enumerate() {
            if !want.is_empty() && *id == want {
                s.sel = i as i64;
            }
        }
        s.fold = self.fold_load();
        // sel_fix (HSEL is "" here: nothing has selected a heading)
        let h = super::at(&self.p.host, s.sel).to_vec();
        if self.p_groups != 0 && !h.is_empty() && s.fold.get(&h).is_some_and(|v| !v.is_empty()) {
            s.hsel = h;
        }
        s.sel_id = super::at(&self.p.id, s.sel).to_vec();
        s
    }

    /// snap_look: what draw would read from outside, read now
    pub fn snap_look(&mut self, s: &Sel) -> Look {
        let mut l = Look::default();
        let id = super::at(&self.p.id, s.sel).to_vec();
        let h = super::at(&self.p.host, s.sel).to_vec();
        let rid = super::at(&self.p.rid, s.sel).to_vec();
        if !s.hsel.is_empty() {
            // a heading: no peek
        } else if !h.is_empty() {
            if m(super::HOST_RE, &h) && m("^%[0-9]+$", &rid) {
                l.rpeek_for = sh::path(&[&h, b" ", &rid]);
                let (at, rp) = self.peek_look(&h, &rid, 60);
                l.rpeek_at = at;
                l.rpeek = rp;
            }
        } else if !id.is_empty() {
            l.screen_id = id.clone();
            l.screen = sh::mapfile(&sh::tm(&[b"capture-pane", b"-p", b"-t", &id]).out);
            l.screen_e = sh::mapfile(&sh::tm(&[b"capture-pane", b"-e", b"-p", b"-t", &id]).out);
        }
        l.intros = self.intros_look();
        let (msg, mold, mwait, on) = self.messages();
        l.msg = msg;
        l.mold = mold;
        l.mwait = mwait;
        l.msg_intro = on;
        l.side = self.links_saves();
        l
    }

    /// SNAP_VARS as snap_save writes them: NAME, INDEX, VALUE (INDEX "" for a variable). With
    /// no LOOK (a --once with no snapshot), only what the looks gathered: draw looks for the rest.
    pub fn records(&self, s: &Sel, look: Option<&Look>) -> Vec<(Bytes, Bytes, Bytes)> {
        let p = &self.p;
        let env0 = |k: &str| sh::env(k).filter(|v| !v.is_empty()).unwrap_or_else(|| b"0".to_vec());
        let scene = {
            let art = sh::env("REVIVE_PANEL_ART").unwrap_or_default();
            crate::render::art::SCENES.iter().position(|x| x.as_bytes() == art).unwrap_or((std::process::id() % 5) as usize)
        };
        let help: &[u8] = if sh::env("REVIVE_PANEL_HELP").as_deref() == Some(b"1") { b"1" } else { b"0" };
        let mut out = Vec::new();
        for &(k, nm) in SNAP_VARS {
            let a: Option<BTreeMap<i64, Bytes>> = match nm {
                "P_ID" => Some(arr(&p.id)),
                "P_LOC" => Some(arr(&p.loc)),
                "P_NAME" => Some(arr(&p.name)),
                "P_APP" => Some(arr(&p.app)),
                "P_STATE" => Some(arr(&p.state)),
                "P_DIR" => Some(arr(&p.dir)),
                "P_GIT" => Some(arr(&p.git)),
                "P_CPU" => Some(arr(&p.cpu)),
                "P_MEM" => Some(arr(&p.mem)),
                "P_CTX" => Some(arr(&p.ctx)),
                "P_AGENT" => Some(arr(&p.agent)),
                "P_SSH" => Some(arr(&p.ssh)),
                "P_HOST" => Some(arr(&p.host)),
                "P_RID" => Some(arr(&p.rid)),
                "P_WP" => Some(arr(&p.wp)),
                "P_USER" => Some(arr(&p.user)),
                "P_INST" => Some(arr(&p.inst)),
                "P_ACCT" => Some(arr(&p.acct)),
                "P_SRV" => Some(p.srv.clone()),
                "P_LIM" => Some(p.lim.clone()),
                "P_LWHY" => Some(p.lwhy.clone()),
                "W_SINCE" => Some(p.w_since.clone()),
                "W_FROM" => Some(p.w_from.clone()),
                "X_SSH" => Some(arr(&self.x_ssh)),
                "X_WHERE" => Some(arr(&self.x_where)),
                "WON" => Some(arr(&[b"1".to_vec(), b"0".to_vec(), b"0".to_vec(), b"0".to_vec()])),
                "MSG" => look.map(|l| arr(&l.msg)),
                "SIDE" => look.map(|l| arr(&l.side)),
                "INTROS" => look.map(|l| arr(&l.intros)),
                "SCREEN" => look.map(|l| arr(&l.screen)),
                "SCREEN_E" => look.map(|l| arr(&l.screen_e)),
                "RPEEK" => look.map(|l| arr(&l.rpeek)),
                _ => None,
            };
            let h: Option<BTreeMap<Bytes, Bytes>> = match nm {
                "RVER" => Some(self.rver.clone()),
                "ROWNER" => Some(self.rowner.clone()),
                "LUP" => Some(self.lup.clone()),
                "FOLD" => Some(s.fold.clone()),
                _ => None,
            };
            let v: Option<Bytes> = match nm {
                "P_GROUPS" => Some(self.p_groups.to_string().into_bytes()),
                "VERSION" => Some(self.version.clone()),
                "HOST" => Some(self.host.clone()),
                "SCENE" => Some(scene.to_string().into_bytes()),
                "TICK" => Some(env0("REVIVE_PANEL_TICK")),
                "SECONDS" => Some(sh::seconds().to_string().into_bytes()),
                "SEL" => Some(s.sel.to_string().into_bytes()),
                "SEL_ID" => Some(s.sel_id.clone()),
                "HSEL" => Some(s.hsel.clone()),
                "PEEK" | "PEEK_ALL" => Some(env0("REVIVE_PANEL_PEEK")),
                "HELP" => Some(help.to_vec()),
                "FOCUS" | "PO" | "PB" | "MO" | "SO" | "MMAN" | "HELP_TOP" | "FLASH_T" | "LBOX" | "ANSWERING" | "QFREE" | "QON" | "QEMPTY"
                | "QHAS" => Some(b"0".to_vec()),
                "ATOP_BH" => Some(b"3".to_vec()),
                "PB_FOR" | "PEEK_SEL" | "FLASH" | "QFREEN" | "INTRO_ON" => Some(Vec::new()),
                "MOLD" => look.map(|l| l.mold.to_string().into_bytes()),
                "MWAIT" => look.map(|l| l.mwait.to_string().into_bytes()),
                "MSG_INTRO" => look.map(|l| l.msg_intro.clone()),
                "SCREEN_ID" => look.map(|l| l.screen_id.clone()),
                "RPEEK_FOR" => look.map(|l| l.rpeek_for.clone()),
                "RPEEK_AT" => look.map(|l| l.rpeek_at.clone()),
                _ => None,
            };
            match k {
                Kind::Scalar => {
                    if let Some(v) = v {
                        out.push((nm.as_bytes().to_vec(), Vec::new(), v));
                    }
                }
                Kind::Indexed => {
                    for (i, x) in a.unwrap_or_default() {
                        out.push((nm.as_bytes().to_vec(), i.to_string().into_bytes(), x));
                    }
                }
                Kind::Assoc => {
                    for (i, x) in h.unwrap_or_default() {
                        out.push((nm.as_bytes().to_vec(), i, x));
                    }
                }
            }
        }
        out
    }
}

/// The looks draw makes for itself in a --once with no snapshot
struct Looks {
    g: G,
}

impl crate::render::Live for Looks {
    fn pane_screen(&mut self, id: &[u8], coloured: bool) -> Vec<Bytes> {
        // mapfile -t L < <(tm capture-pane ${3:+"$3"} -p -t "$2")
        let o = if coloured { sh::tm(&[b"capture-pane", b"-e", b"-p", b"-t", id]) } else { sh::tm(&[b"capture-pane", b"-p", b"-t", id]) };
        sh::mapfile(&o.out)
    }
    fn peek_look(&mut self, h: &[u8], id: &[u8], n: i64) -> (Bytes, Vec<Bytes>) {
        self.g.peek_look(h, id, n)
    }
    fn intros(&mut self) -> Vec<Bytes> {
        self.g.intros_look()
    }
    fn messages(&mut self) -> (Vec<Bytes>, i64, i64, Bytes, Vec<Bytes>) {
        let (msg, mold, mwait, on) = self.g.messages();
        let side = self.g.links_saves();
        (msg, mold, mwait, on, side)
    }
}

/// --once with no snapshot to load. -> what to print, or an exit status and a message.
pub fn run(root: &[u8]) -> Result<Bytes, (i32, String)> {
    sh::init(root);
    let mut g = G::new(root);
    g.gather();
    std::thread::sleep(std::time::Duration::from_millis(500)); // CPU is measured between two looks
    g.gather();
    let s = g.pick();
    let snapv = sh::env("REVIVE_PANEL_SNAP").unwrap_or_default();
    let save = if m("^(save|load):.", &snapv) { snapv.strip_prefix(b"save:").map(|f| f.to_vec()) } else { None };
    let env = crate::render::frame::Env::read();
    let cols = sh::env("COLUMNS").filter(|v| !v.is_empty()).map(|v| super::n(&v)).unwrap_or(100);
    let lines = sh::env("LINES").filter(|v| !v.is_empty()).map(|v| super::n(&v)).unwrap_or(40);
    let mut c;
    if let Some(f) = save {
        let look = g.snap_look(&s);
        let recs = g.records(&s, Some(&look));
        let mut buf = Vec::new();
        for (a, b, v) in &recs {
            for x in [a, b, v] {
                buf.extend_from_slice(x);
                buf.push(0);
            }
        }
        if std::fs::write(sh::os(&f), &buf).is_err() {
            return Err((1, String::new()));
        }
        let snap = Snapshot::apply(&recs).map_err(|_| (1, String::new()))?;
        c = crate::render::Ctx::load(&snap, &env);
    } else {
        let snap = Snapshot::apply(&g.records(&s, None)).map_err(|_| (1, String::new()))?;
        c = crate::render::Ctx::load(&snap, &env);
        c.live = Some(Box::new(Looks { g }));
    }
    c.p.tcols = cols;
    c.p.tlines = lines;
    c.draw();
    Ok(std::mem::take(&mut c.p.print))
}
