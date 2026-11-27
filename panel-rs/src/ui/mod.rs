//! The live panel (plan Phase 3): scripts/panel.sh's main loop, keys() and the act() keys that
//! move, scroll, fold, peek and change the art, on a UI thread that never waits on a collector.
//! Every frame is render::Ctx::draw's, the same builders --once draws with; the writer sends the
//! lines that changed inside ?2026. O, N, S, D, U (upd.rs), B and G (flows.rs, popups.rs), M
//! (edit_box, editbox.rs), the ? page (help.rs), and O M N where the key bar fades them, are here
//! too; every key act() runs goes through box_flow (boxes.rs), and the boxes it opens (pick, ask,
//! note, edit_box, tmux's popups) wait in modal.rs with the panel going on under them. Enter on
//! a question answers it (answer.rs), the panel going on meanwhile. No key goes to the bash panel.
//!
//! What runs where:
//! - UI thread (here): input, the act() keys above and their boxes, the flash, the loading
//!   box and the splash, the frame and its writer.
//! - a thread per command that can take a while (agent-say, remote_run, tmux's popups), the
//!   panel drawing while it waits (modal.rs wait_job);
//! - while answering, the send worker (answer.rs): the keys, the sends, the looks at the pane;
//! - U's jobs, each a child of its own that outlives the panel (upd.rs).
//! - collectors.rs: panes (gather), mail (messages, links_saves, intros) and peek, a thread
//!   each, kicked as bash looks again: every REVIVE_PANEL_REFRESH seconds without a key, and
//!   after any key but a move.

pub mod answer;
pub mod boxes;
pub mod collectors;
pub mod editbox;
pub mod flows;
pub mod help;
pub mod keys;
pub mod modal;
pub mod popups;
pub mod screens;
pub mod term;
pub mod upd;
pub mod writer;

use crate::collect::sh::{self, Bytes};
use crate::collect::{m, HOST_RE};
use crate::compat::clean;
use crate::render::frame::Env;
use crate::render::{num, Ctx, Nav};
use crate::snapshot::Snapshot;
use boxes::{BoxHost, Boxes};
use collectors::{Hub, Want};
use keys::{Class, Src};
use std::collections::BTreeMap;
use std::os::fd::RawFd;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// How long a frame waits for the peek or the mail of its round before it is drawn without
const ROUND_WAIT: Duration = Duration::from_millis(300);

/// The names a generation brings (what the looks gathered): the rest of the snapshot is the
/// panel's own (selection, folds, screens, messages)
fn gathered(name: &str) -> bool {
    name.starts_with("P_") || matches!(name, "W_SINCE" | "W_FROM" | "W_REPLY" | "X_SSH" | "X_WHERE")
}

/// A generation's rows into the panel's snapshot, all of them at once: every gathered array
/// the old one had goes (a sparse P_LIM or P_SRV too), so no row ever mixes two gathers
fn swap_gen(s: &mut Snapshot, g: &Snapshot) {
    s.arrays.retain(|k, _| !gathered(k));
    for (k, v) in &g.arrays {
        if gathered(k) {
            s.arrays.insert(k, v.clone());
        }
    }
    for k in ["RVER", "ROWNER", "LUP"] {
        s.assoc.insert(k, g.assoc.get(k).cloned().unwrap_or_default());
    }
}

/// LUP for the headings: the generation's, each host LINKS has a row for as the mail had it. A
/// generation in before its mail would otherwise put a heading and its LINKS row a gather apart;
/// a host the mail hasn't seen yet has no LINKS row to disagree with.
fn lup_over(s: &mut Snapshot, mail: &BTreeMap<Bytes, Bytes>) {
    let l = s.assoc.entry("LUP").or_default();
    for (h, v) in mail {
        l.insert(h.clone(), v.clone());
    }
}

/// act()'s early returns for O, M and N, the ones that need nothing but the selection: every
/// key the key bar fades (State::keys_off) is one of them. Some(Some(TEXT)): notice TEXT and
/// return; Some(None): return, saying nothing; None: the key acts (O opens, M and N go on to
/// their box).
fn pane_key_early(p: &crate::render::State, key: &[u8]) -> Option<Option<Bytes>> {
    use crate::render::cat;
    if !matches!(key, b"o" | b"O" | b"m" | b"M" | b"n" | b"N") {
        return None;
    }
    // A heading selected: the keys for a pane wait for one.
    if !p.hsel.is_empty() {
        return Some(Some(cat(&[b"select one of ", &p.hsel, b"'s panes for that"])));
    }
    let id = p.a("P_ID", p.sel);
    let h = p.a("P_HOST", p.sel);
    match key {
        // Panes on this computer only: focus moves only where you press O.
        b"o" | b"O" if !h.is_empty() => Some(Some(b"O opens panes on this computer only".to_vec())),
        b"o" | b"O" if id.is_empty() => Some(None),
        b"m" | b"M" if id.is_empty() => {
            Some(if h.is_empty() { None } else { Some(cat(&[b"that pane has no name; name it on ", h, b" to message it"])) })
        }
        b"n" | b"N" if !h.is_empty() => {
            if !m(HOST_RE, h) {
                Some(None)
            } else if !m("^%[0-9]+$", p.a("P_RID", p.sel)) {
                Some(Some(cat(&[b"on ", h, b": can't tell which pane that is (update tmux-revive there)"])))
            } else {
                None
            }
        }
        b"n" | b"N" if id.is_empty() => Some(None),
        _ => None,
    }
}

pub struct Ui {
    pub c: Ctx,
    root: Bytes,
    hub: Arc<Hub>,
    src: term::Stdin,
    saved: term::Saved,
    sig_r: RawFd,
    wake_r: RawFd,
    /// PREV: the lines last sent
    prev: Vec<Bytes>,
    refresh: Duration,
    astate: Bytes,
    rdir: Bytes,
    folddir: Bytes,
    clk: i64,
    lbox: screens::Lbox,
    a_load: BTreeMap<i64, Bytes>,
    full_t: i64,
    /// the first look is in: keys are read, frames drawn
    started: bool,
    // The round: a gather kicked and not yet in, and the mail and peek after it.
    wait_gen: bool,
    wait_mail: bool,
    /// The LUP of the mail drawn (the one its LINKS rows went by), over each generation's
    mail_lup: BTreeMap<Bytes, Bytes>,
    wait_peek: bool,
    want_draw: bool,
    draw_at: Instant,
    /// When TICK moves on: REFRESH after the last frame with no key (bash's read -t)
    tick_at: Option<Instant>,
    /// BOX_*: one box at a time (boxes.rs)
    bx: Boxes,
    /// The box up now (pick, ask, note), painted over every frame drawn under it
    over: Option<Bytes>,
    /// A box is up: Ctrl-C closes it, not the panel
    modal_on: bool,
    /// edit_box is up: a resize takes its box off until it's drawn again at the new size
    eb_on: bool,
    /// WINCH came while edit_box was up (bash's TCOLS=""): its box is drawn again
    eb_winch: bool,
    /// The ? page is up: it moves TICK itself (every other second), the panel's clock doesn't
    help_on: bool,
    /// Answering a question (answer.rs): the keys are the send worker's, the peek looks at
    /// nothing (the worker's looks are drawn), and the clock's tick isn't put off by its frames
    ans_on: bool,
    /// pick's PICKED and PKEY, ask's REPLY
    picked: Bytes,
    pkey: Bytes,
    reply: Bytes,
    /// SEL_ID set by a key for the next gather to find (N on a linked computer: its new name)
    pending_sel: Option<Bytes>,
    /// U's jobs and box (upd.rs)
    upd: upd::Upd,
    /// AMAIL and ME, for B's and G's popups (agent-say's mailbox, this user)
    amail: Bytes,
    me: Bytes,
}

impl BoxHost for Ui {
    fn bx(&mut self) -> &mut Boxes {
        &mut self.bx
    }
    fn flash_get(&self) -> (Bytes, i64) {
        (self.c.p.flash.clone(), self.c.p.flash_t)
    }
    fn flash_put(&mut self, f: (Bytes, i64)) {
        self.c.p.flash = f.0;
        self.c.p.flash_t = f.1;
    }
    fn prev_clear(&mut self) {
        self.prev.clear();
    }
    /// draw, as a key's own steps call it: its BOX_ lines, then the frame. Bash's draw looks at
    /// the messages, LINKS · SAVES and the intros again each time a key draws (G's _cull, B's
    /// link, a deny: what they changed shows under the next box): the mail thread is kicked,
    /// and what it finds is painted when it comes.
    fn draw(&mut self) {
        self.draw_box_lines();
        self.hub.mail_k.kick();
        self.paint();
    }
}

impl Ui {
    fn secs(&self) -> i64 {
        sh::seconds()
    }

    // ------------------------------------------------------------------ the flash

    /// notice TEXT, which since 1.2.57 is flash TEXT: on the key bar for 5 seconds, cleaned
    /// (agent-say's reply can quote anything). No box, no queue: NOTICES stays empty.
    pub fn notice(&mut self, t: &[u8]) {
        self.c.p.flash = clean(t);
        self.c.p.flash_t = self.secs();
    }

    // ------------------------------------------------------------------ the selection

    fn p_len(&self) -> i64 {
        self.c.p.alen("P_ID")
    }
    fn pa(&self, name: &str, i: i64) -> Bytes {
        self.c.p.a(name, i).to_vec()
    }
    fn folded(&self, h: &[u8]) -> bool {
        self.c.folded(h)
    }

    /// The main loop's before every draw: the same pane kept selected when panes come and go,
    /// then sel_fix
    fn sel_keep(&mut self) {
        let n = self.p_len();
        if !self.c.p.sel_id.is_empty() {
            for i in 0..n {
                if self.c.p.a("P_ID", i) == self.c.p.sel_id.as_slice() {
                    self.c.p.sel = i;
                }
            }
        }
        if self.c.p.sel >= n {
            self.c.p.sel = if n > 0 { n - 1 } else { 0 };
        }
        self.sel_fix();
    }

    /// sel_fix: a heading selected stays on its computer's first row (or goes with it); a row
    /// of a folded computer is its heading
    fn sel_fix(&mut self) {
        if !self.c.p.hsel.is_empty() {
            let mut h = Vec::new();
            for j in 0..self.p_len() {
                if self.c.p.a("P_HOST", j) == self.c.p.hsel.as_slice() {
                    h = self.c.p.hsel.clone();
                    self.c.p.sel = j;
                    break;
                }
            }
            self.c.p.hsel = h;
        }
        let h = self.pa("P_HOST", self.c.p.sel);
        if self.c.p.p_groups != 0 && self.c.p.hsel.is_empty() && !h.is_empty() && self.folded(&h) {
            self.c.p.hsel = h;
        }
        self.c.p.sel_id = self.pa("P_ID", self.c.p.sel);
    }

    /// fold_load: FOLD from $DIR/panel/fold
    fn fold_load(&mut self) {
        let mut f = BTreeMap::new();
        for p in sh::glob(&self.folddir, b"", b"", false) {
            if sh::is_file(&p) {
                f.insert(sh::basename(&p).to_vec(), b"1".to_vec());
            }
        }
        self.c.p.snap.assoc.insert("FOLD", f);
    }

    /// fold_toggle HOST: folded or opened, and the file that keeps it. false: not a host name,
    /// or the file couldn't be made
    fn fold_toggle(&mut self, h: &[u8]) -> bool {
        if !m(HOST_RE, h) {
            return false;
        }
        let f = sh::path(&[&self.folddir, b"/", h]);
        let fold = self.c.p.snap.assoc.entry("FOLD").or_default();
        if fold.get(h).is_some_and(|v| !v.is_empty()) {
            fold.remove(h);
            let _ = std::fs::remove_file(sh::os(&f));
            true
        } else {
            fold.insert(h.to_vec(), b"1".to_vec());
            std::fs::create_dir_all(sh::os(&self.folddir)).is_ok() && std::fs::write(sh::os(&f), b"").is_ok()
        }
    }

    /// nav_stop I: a pane's row, or a folded computer's heading (an open one is passed over)
    fn nav_stop(&self, i: i64) -> bool {
        match self.c.p.nav.get(i as usize) {
            Some(Nav::Head(h)) => !h.is_empty() && self.folded(h),
            _ => true,
        }
    }

    /// nav_go I [D]: select NAV's entry I, or the nearest stop from it going D (else back)
    fn nav_go(&mut self, i: i64, d: i64) {
        let k = self.c.p.nav.len() as i64;
        if k == 0 {
            return;
        }
        let mut i = i.clamp(0, k - 1);
        let mut j = i;
        while j >= 0 && j < k && !self.nav_stop(j) {
            j += d;
        }
        if j < 0 || j >= k {
            j = i;
            while j >= 0 && j < k && !self.nav_stop(j) {
                j -= d;
            }
        }
        if j < 0 || j >= k {
            return;
        }
        i = j;
        match self.c.p.nav[i as usize].clone() {
            Nav::Head(h) => {
                self.c.p.hsel = h;
                for j in 0..self.p_len() {
                    if self.c.p.a("P_HOST", j) == self.c.p.hsel.as_slice() {
                        self.c.p.sel = j;
                        break;
                    }
                }
            }
            Nav::Pane(p) => {
                self.c.p.hsel.clear();
                self.c.p.sel = p;
            }
        }
    }

    /// scroll KEY: in PANES the selection moves (round at the ends for the arrows); elsewhere
    /// the focused window scrolls, draw keeping it in range
    fn scroll(&mut self, key: &[u8]) {
        let f = self.c.p.focus.clamp(0, 3) as usize;
        let wh = self.c.p.wh[f];
        let pg = if wh > 1 { wh - 1 } else { 1 };
        let d = match key {
            b"up" => -1,
            b"down" => 1,
            b"pgup" => -pg,
            b"pgdn" => pg,
            b"home" => -100000,
            _ => 100000,
        };
        match self.c.p.focus {
            0 => {
                self.c.panes_rows();
                self.c.nav_at();
                let k = self.c.p.nav.len() as i64;
                if k == 0 {
                    return;
                }
                if key == b"up" || key == b"down" {
                    let mut i = self.c.p.nat;
                    for _ in 0..k {
                        i = (i + d + k) % k;
                        if self.nav_stop(i) {
                            break;
                        }
                    }
                    self.nav_go(i, d);
                } else {
                    let nat = self.c.p.nat;
                    self.nav_go(nat + d, if d > 0 { 1 } else { -1 });
                }
            }
            1 => self.c.p.pb -= d,
            2 => {
                self.c.p.mo += d;
                self.c.p.mman = if key == b"end" { 0 } else { 1 };
            }
            3 => self.c.p.so += d,
            _ => {}
        }
    }

    // ------------------------------------------------------------------ act

    /// act KEY: what a key does. Those not ported yet go to the bash panel for the one action.
    fn act(&mut self, key: &[u8]) {
        // A key may draw over the panel: repaint it whole. Moves keep the line-by-line redraw.
        if keys::class(key) != Class::Nav {
            self.prev.clear();
        }
        let sel = self.c.p.sel;
        // O M N where they can't act (a heading, a linked computer's pane: faded on the key bar)
        // say why here, as act()'s early returns do.
        if let Some(said) = pane_key_early(&self.c.p, key) {
            if let Some(t) = said {
                self.notice(&t);
            }
            return;
        }
        match key {
            b"o" | b"O" => self.open(),
            b"s" | b"S" => self.save(),
            b"b" | b"B" => self.link(),
            b"u" | b"U" => self.upd_show(),
            b"g" | b"G" | b"i" | b"I" => self.access(),
            b"m" | b"M" => self.message(),
            b"?" => self.help_view(),
            b"n" | b"N" => {
                if self.rename() {
                    return; // on a linked computer: SEL_ID is its new name, for the next gather
                }
            }
            b"d" | b"D" => self.detach(),
            b"p" | b"P" => {
                self.c.p.peek = (self.c.p.peek == 0) as i64;
                self.c.p.peek_sel = self.pa("P_ID", sel);
                self.c.p.peek_all = 0;
            }
            b"enter" => {
                if !self.c.p.hsel.is_empty() {
                    let h = self.c.p.hsel.clone();
                    self.fold_toggle(&h);
                    if !self.folded(&h) {
                        self.c.p.po = 1 << 30; // opened: its panes into view, under its heading
                    }
                } else if self.c.p.a("P_STATE", sel) == b"asking" {
                    self.answer(); // answering (answer.rs), the panel going on
                }
            }
            b"f" => {
                if !self.c.p.hsel.is_empty() {
                    self.act(b"enter");
                    return;
                }
                let h = self.pa("P_HOST", sel);
                if h.is_empty() {
                    return; // this computer: nothing to fold (1.2.57 says nothing)
                }
                if self.fold_toggle(&h) {
                    self.c.p.hsel = h;
                }
            }
            b"F" => {
                let mut seen: Vec<Bytes> = Vec::new();
                for i in 0..self.p_len() {
                    let h = self.pa("P_HOST", i);
                    if !h.is_empty() && !seen.contains(&h) {
                        seen.push(h);
                    }
                }
                if seen.is_empty() {
                    return; // nothing bridged
                }
                let all = seen.iter().all(|h| self.folded(h));
                for h in &seen {
                    if all || !self.folded(h) {
                        self.fold_toggle(h);
                    }
                }
                if all {
                    self.c.p.hsel.clear();
                } else if !self.c.p.a("P_HOST", sel).is_empty() {
                    self.c.p.hsel = self.pa("P_HOST", sel);
                }
            }
            b"a" | b"A" => self.c.scene = (self.c.scene + 1) % crate::render::art::SCENES.len() as i64,
            b"q" | b"Q" => self.quit(0),
            [d] if d.is_ascii_digit() => {
                let mut n: Bytes = vec![*d];
                let wp0 = |s: &Self, w: i64| -> Bytes {
                    let wp = s.c.p.a("P_WP", w);
                    wp.split(|&c| c == b'.').next().unwrap_or(b"").to_vec()
                };
                if n == b"0" {
                    n = b"10".to_vec();
                    for w in 0..self.p_len() {
                        if self.c.p.a("P_HOST", w).is_empty() && wp0(self, w) == b"0" {
                            n = b"0".to_vec();
                            break;
                        }
                    }
                }
                for w in 0..self.p_len() {
                    if self.c.p.a("P_HOST", w).is_empty() && wp0(self, w) == n {
                        self.c.p.sel = w;
                        self.c.p.hsel.clear();
                        break;
                    }
                }
            }
            b"up" | b"down" | b"pgup" | b"pgdn" | b"home" | b"end" => self.scroll(key),
            b"J" => self.c.p.focus = self.c.tab_next(1),
            b"K" => self.c.p.focus = self.c.tab_next(3),
            _ => {}
        }
        self.c.p.sel_id = self.pa("P_ID", self.c.p.sel);
    }

    /// act's N (pane_key_early has said no to what can't be renamed): a new name asked for on
    /// the bottom line, then agent-say name for a pane here, or, on a linked computer, agent-say
    /// name there over the link (remote_run), its rows asked for again at once. true: act
    /// returns there (bash's `return` in that branch), SEL_ID left for the next gather.
    fn rename(&mut self) -> bool {
        use crate::render::cat;
        let sel = self.c.p.sel;
        let id = self.pa("P_ID", sel);
        let name = if !self.c.p.a("P_NAME", sel).is_empty() { self.pa("P_NAME", sel) } else { self.pa("P_LOC", sel) };
        let h = self.pa("P_HOST", sel);
        let asay = sh::path(&[&self.root, b"/bin/agent-say"]);
        if !h.is_empty() {
            // A pane on a linked computer: agent-say name runs there, over the link's ssh.
            let rid = self.pa("P_RID", sel);
            if !self.ask(&cat(&[b"New name for ", &name, b" on ", &h, b":"])) {
                self.notice(b"rename cancelled");
                return true;
            }
            let reply = self.reply.clone();
            // The same letters a name may have there, so no quote or shell character gets through.
            if !m("^[A-Za-z0-9][A-Za-z0-9_.:+=-]*$", &reply) {
                self.notice(b"that can't be a name: use letters, digits and . _ - : + =");
                return true;
            }
            self.notice(&cat(&[b"naming it on ", &h, "…".as_bytes()]));
            BoxHost::draw(self);
            let cfg = crate::collect::links::LinkCfg::from_env(&self.astate, &asay);
            let (h2, r2) = (h.clone(), reply.clone());
            // out=$(remote_run "$h" name "$rid" "$REPLY" | tail -c 4096); st=$? (pipefail: remote_run's)
            let (st, out) = self.wait_job(move || crate::collect::links::remote_run(&cfg, &h2, &[b"name", &rid, &r2], usize::MAX));
            let out = sh::cmdsub(&out[out.len().saturating_sub(4096)..]);
            // out=$(grep -v '^[[:space:]]*$' <<<"$out" | head -n 1); clean out
            let first = sh::here(&out).into_iter().find(|l| !l.iter().all(|c| c.is_ascii_whitespace())).unwrap_or_default();
            let out = clean(&first);
            let out = out.strip_prefix(b"agent-say: ".as_slice()).unwrap_or(&out).to_vec();
            let out = crate::compat::substr(&out, 0, Some(120)).unwrap_or_default();
            if st == 124 || st == 255 {
                self.notice(&cat(&[b"on ", &h, b": couldn't be reached to rename"]));
            } else {
                let what: &[u8] = if out.is_empty() { b"rename failed" } else { &out };
                self.notice(&cat(&[b"on ", &h, b": ", what]));
            }
            if st == 0 {
                self.pending_sel = Some(cat(&[&reply, b"@", &h])); // the row goes by its new name
            }
            self.hub.rows_again(Some(h)); // RFETCH_T[$h]=0: its rows asked for again, to show it
            return true;
        }
        if !self.ask(&cat(&[b"New name for ", &name, b":"])) {
            self.notice(b"rename cancelled");
            return false;
        }
        let reply = self.reply.clone();
        // out=$(AGENT_SAY_PANE=$id "$ASAY" name "$REPLY" 2>&1 | head -n 1)
        let out = self.wait_job(move || modal::run_first_line(&[asay, b"name".to_vec(), reply], &[("AGENT_SAY_PANE", id)]));
        let out = sh::cmdsub(&out);
        let out = out.strip_prefix(b"agent-say: ".as_slice()).unwrap_or(&out).to_vec();
        self.notice(&out);
        false
    }

    /// act's M (pane_key_early has said no to what can't be messaged): written in a box, as
    /// long as it needs to be: several lines go as one message, through agent-say --from panel.
    fn message(&mut self) {
        use crate::render::cat;
        let sel = self.c.p.sel;
        let id = self.pa("P_ID", sel);
        let name = if !self.c.p.a("P_NAME", sel).is_empty() { self.pa("P_NAME", sel) } else { self.pa("P_LOC", sel) };
        let ok = self.edit_box(&cat(&[b"MESSAGE TO ", &name]), "Enter sends · Alt-Enter new line · Esc closes".as_bytes(), b"", false);
        // [[ -n ${REPLY//[[:space:]]/} ]]
        if !ok || crate::compat::chars(&self.reply).all(crate::compat::is_space) {
            self.notice(b"message cancelled");
            BoxHost::draw(self);
            return;
        }
        BoxHost::draw(self); // the box goes at once: sending can take a while
        let asay = sh::path(&[&self.root, b"/bin/agent-say"]);
        let reply = self.reply.clone();
        // out=$("$ASAY" --from panel "$id" "$REPLY" 2>&1 | tail -n 1)
        let out = self.wait_job(move || modal::run_last_line(&[asay, b"--from".to_vec(), b"panel".to_vec(), id, reply]));
        let out = out.strip_prefix(b"agent-say: ".as_slice()).unwrap_or(&out).to_vec();
        self.notice(&out);
    }

    /// act's D: detach this tmux (the client looking at the panel), once you've said yes.
    /// Everything keeps running, and a snapshot is taken on detach, so it comes back after a
    /// reboot too.
    fn detach(&mut self) {
        self.prev.clear();
        BoxHost::draw(self);
        let items = vec![
            crate::render::cat(&[&[modal::NOTE], b"This session will restore even after reboot."]),
            b"No, stay".to_vec(),
            b"Yes, detach".to_vec(),
        ];
        if !(self.pick(&mut modal::PickOpts::default(), b"DETACH TMUX?", &items) && num(&self.picked) == 2) {
            self.prev.clear();
            self.notice(b"detach cancelled");
            return;
        }
        self.prev.clear();
        if !sh::tm(&[b"detach-client"]).ok {
            self.notice(b"couldn't detach");
        }
    }

    /// act's S: a snapshot taken now, said on the key bar
    fn save(&mut self) {
        let save = sh::path(&[&self.root, b"/scripts/save.sh"]);
        let ok = sh::run(&[b"bash", &save, b"manual"]).ok;
        self.notice(if ok { b"saved" } else { b"save failed (see: tmux-revive log)" });
    }

    /// act's O on a pane here (pane_key_early has said no to the rest): inside tmux the client
    /// goes to it (and a popup panel closes); outside, tmux is attached there in its place.
    fn open(&mut self) {
        let sel = self.c.p.sel;
        let id = self.pa("P_ID", sel);
        if !sh::env("TMUX").unwrap_or_default().is_empty() {
            sh::tm(&[b"switch-client", b"-t", &id]);
            sh::tm(&[b"select-window", b"-t", &id]);
            sh::tm(&[b"select-pane", b"-t", &id]);
            if !sh::env("REVIVE_PANEL_POPUP").unwrap_or_default().is_empty() {
                self.quit(0);
            }
        } else {
            sh::tm(&[b"select-window", b"-t", &id]);
            sh::tm(&[b"select-pane", b"-t", &id]);
            let loc = self.pa("P_LOC", sel);
            let session = loc.split(|&c| c == b':').next().unwrap_or(b"").to_vec();
            self.cleanup();
            term::restore(&self.saved);
            // exec tmux attach -t SESSION 2>&1: its messages on the screen again
            use std::os::fd::AsFd;
            use std::os::unix::process::CommandExt;
            let mut c = std::process::Command::new("tmux");
            c.arg("attach").arg("-t").arg(sh::os(&session));
            if let Ok(fd) = std::io::stdout().as_fd().try_clone_to_owned() {
                c.stderr(fd);
            }
            let e = c.exec();
            std::process::exit(if e.kind() == std::io::ErrorKind::NotFound { 127 } else { 126 });
        }
    }

    // ------------------------------------------------------------------ keys

    /// keys KEY...: the key waiting, and any behind it already (a held arrow), drawn once.
    fn input(&mut self) {
        let Some(first) = self.src.byte(Duration::ZERO) else { return };
        // While the loading box is up keys wait for nothing: they go, all but q (quit).
        if self.lbox.on {
            if keys::lbox_key(&mut self.src, first) {
                self.quit(0);
            }
            self.look_again();
            self.request_draw();
            return;
        }
        let mut nav = false;
        let mut drawn = false;
        let mut key = keys::decode(&mut self.src, first);
        loop {
            match keys::class(&key) {
                Class::Nav => {
                    self.act(&key);
                    nav = true;
                }
                Class::View => {
                    // drawn at once from what was gathered, then looked at again
                    self.act(&key);
                    BoxHost::draw(self);
                    drawn = true;
                    nav = false;
                    break;
                }
                Class::Nothing => {}
                Class::Act => {
                    // box_flow act KEY: Esc on a box brings the one before back
                    self.box_flow(&mut |s: &mut Ui| s.act(&key));
                    nav = false;
                    break;
                }
            }
            // read -t 0 && IFS= read -rsn1 key || break
            match self.src.byte(Duration::ZERO) {
                Some(b) => key = keys::decode(&mut self.src, b),
                None => break,
            }
        }
        if !nav {
            self.look_again();
        }
        if !drawn {
            self.request_draw();
        }
    }

    // ------------------------------------------------------------------ the round

    /// Look again: the panes, and after them the mail and the peek
    fn look_again(&mut self) {
        self.wait_gen = true;
        self.tick_at = None;
        self.hub.panes_k.kick();
    }

    /// The peek the frame about to be drawn shows (draw's show: a pane, not the panel's own,
    /// with the peek on for it or asking), told to the peek thread when it changed
    fn want_peek(&mut self) -> bool {
        let p = &self.c.p;
        let sel = p.sel;
        let id = p.a("P_ID", sel).to_vec();
        let st = p.a("P_STATE", sel);
        let h = p.a("P_HOST", sel).to_vec();
        let rid = p.a("P_RID", sel).to_vec();
        let on = p.peek != 0 && (p.peek_all != 0 || p.peek_sel.is_empty() || p.peek_sel == id);
        let w = if self.ans_on || !p.hsel.is_empty() || st.is_empty() || st == b"self" || !(on || st == b"asking") {
            Want::None
        } else if !h.is_empty() {
            if m(HOST_RE, &h) && m("^%[0-9]+$", &rid) {
                Want::Remote { h, rid }
            } else {
                Want::None
            }
        } else {
            Want::Local { id, coloured: st == b"asking" }
        };
        let mut cur = self.hub.want.lock().unwrap();
        if *cur != w {
            *cur = w;
            drop(cur);
            self.hub.peek_k.kick();
            return true;
        }
        false
    }

    /// A frame wanted now; one whose peek moved to another pane waits a moment for its screen
    /// (a peek gone, Want::None, has no screen to wait for: drawn at once)
    fn request_draw(&mut self) {
        self.want_draw = true;
        self.draw_at = Instant::now();
        if self.want_peek() && *self.hub.want.lock().unwrap() != Want::None {
            self.wait_peek = true;
            self.draw_at = Instant::now() + ROUND_WAIT;
        }
    }

    /// What the collectors left since: a generation, the mail, a peek
    fn take(&mut self) {
        let gen = self.hub.gen.lock().unwrap().take();
        if let Some(g) = gen {
            self.apply_gen(&g);
        }
        let mail = self.hub.mail.lock().unwrap().take();
        if let Some(mm) = mail {
            let to_map = |v: Vec<Bytes>| -> BTreeMap<i64, Bytes> { v.into_iter().enumerate().map(|(i, x)| (i as i64, x)).collect() };
            let s = &mut self.c.p.snap;
            s.arrays.insert("MSG", to_map(mm.msg));
            s.arrays.insert("SIDE", to_map(mm.side));
            self.mail_lup = mm.lup;
            lup_over(s, &self.mail_lup);
            s.arrays.insert("INTROS", to_map(mm.intros));
            self.c.p.mold = mm.mold;
            self.c.p.mwait = mm.mwait;
            self.c.p.msg_intro = mm.intro_on;
            self.wait_mail = false;
            if !self.want_draw {
                self.want_draw = true;
                self.draw_at = Instant::now();
            }
        }
        let peek = self.hub.peek.lock().unwrap().take();
        if let Some(pk) = peek {
            if pk.want == *self.hub.want.lock().unwrap() {
                let to_map = |v: Vec<Bytes>| -> BTreeMap<i64, Bytes> { v.into_iter().enumerate().map(|(i, x)| (i as i64, x)).collect() };
                match &pk.want {
                    Want::Local { id, .. } => {
                        self.c.p.screen_id = id.clone();
                        self.c.p.snap.arrays.insert("SCREEN", to_map(pk.screen));
                        self.c.p.snap.arrays.insert("SCREEN_E", to_map(pk.screen_e));
                    }
                    Want::Remote { h, rid } => {
                        self.c.p.rpeek_for = crate::render::cat(&[h, b" ", rid]);
                        self.c.p.rpeek_at = pk.rpeek_at;
                        self.c.p.snap.arrays.insert("RPEEK", to_map(pk.rpeek));
                    }
                    Want::None => {}
                }
                self.wait_peek = false;
                if !self.want_draw {
                    self.want_draw = true;
                    self.draw_at = Instant::now();
                }
            }
        }
    }

    /// A gather is in: its rows, then what the main loop does after each (1.2.57): the loading
    /// box checked
    fn apply_gen(&mut self, g: &collectors::Gen) {
        swap_gen(&mut self.c.p.snap, &g.snap);
        lup_over(&mut self.c.p.snap, &self.mail_lup);
        self.c.p.p_groups = g.snap.var("P_GROUPS").map(num).unwrap_or(0);
        if let Some(v) = g.snap.var("VERSION") {
            self.c.p.version = v.to_vec();
        }
        if let Some(v) = g.snap.var("HOST") {
            self.c.p.host = v.to_vec();
        }
        self.a_load = g.a_load.clone();
        self.lbox_check();
        self.started = true;
        self.wait_gen = false;
        // SEL_ID a key left for this gather (bash's main loop looks for it after gather)
        if let Some(id) = self.pending_sel.take() {
            self.c.p.sel_id = id;
        }
        if self.upd.n() > 0 {
            self.upd_poll(); // what U started, finished since
        }
        // The round: the mail after the panes (bash's draw runs messages after the gather), and
        // the peek, looked at again.
        self.wait_mail = true;
        self.hub.mail_k.kick();
        self.sel_keep();
        self.want_peek();
        // While answering the question's looks are the send worker's: no peek to wait for.
        if !self.ans_on {
            self.hub.peek_k.kick();
            self.wait_peek = true;
        }
        self.want_draw = true;
        self.draw_at = Instant::now() + ROUND_WAIT;
    }

    // ------------------------------------------------------------------ draw

    /// The main loop's draw: the selection kept, all of it sent again every 15 s, the frame
    /// (render's draw) through the writer, the box up (if one is) painted over it again in the
    /// same update when anything under it was, the loading box over it
    pub fn paint(&mut self) {
        self.sel_keep();
        let secs = self.secs();
        // All of it drawn again every 15 s, not only what changed.
        if secs - self.full_t >= 15 {
            self.prev.clear();
            self.full_t = secs;
        }
        let (cols, lines) = term::size().unwrap_or((100, 40));
        let now = self.now();
        let p = &mut self.c.p;
        p.tcols = cols;
        p.tlines = lines;
        p.secs = secs;
        p.now = now;
        p.lbox = self.lbox.on as i64;
        // Answering, bash keeps the rows above the question from its first frame (ATOP): nothing
        // there could change, as nothing was gathered. Here PANES, the banner and the spark go on
        // (the plan's one intended change), so they are drawn afresh each frame.
        if self.ans_on {
            p.atop.clear();
        }
        self.c.draw();
        self.c.p.print.clear();
        let out = std::mem::take(&mut self.c.out);
        // The ? page's own writer (help_frame's) leaves the cursor where it was: no ESC[H.
        let mut buf = writer::frame_at(&out, &mut self.prev, None, self.c.p.help == 0);
        if let Some(o) = &self.over {
            // after the frame's ESC[H, so the cursor ends where the box leaves it
            if let Some(n) = buf.len().checked_sub(b"\x1b[?2026l".len()) {
                buf.splice(n..n, o.iter().copied());
            }
        }
        term::out(&buf);
        if self.lbox.on {
            let b = screens::lbox_draw(&mut self.lbox, &self.c);
            term::out(&b);
        }
        self.want_draw = false;
        // REFRESH after the last frame (bash's read -t); while answering, after the last look
        // round, not put off by the question's own frames (every 40 ms after a key)
        if !self.wait_gen && !(self.ans_on && self.tick_at.is_some()) {
            self.tick_at = Some(Instant::now() + self.refresh);
        }
    }

    fn now(&self) -> i64 {
        let pin = sh::env("REVIVE_PANEL_NOW").unwrap_or_default();
        if m("^[0-9]{1,12}$", &pin) {
            num(&pin)
        } else {
            sh::time_s()
        }
    }

    /// The panel closes: the fetched screens removed, the terminal put back
    pub fn quit(&self, st: i32) -> ! {
        self.cleanup();
        term::restore(&self.saved);
        std::process::exit(st);
    }

    /// Other computers' screens it fetched go when it closes.
    fn cleanup(&self) {
        let files = self.hub.peek_files.lock().map(|f| f.clone()).unwrap_or_default();
        for f in files {
            let _ = std::fs::remove_file(sh::os(&f));
            // FILE.fail, and a screen still being asked for (FILE.XXXXXX): bash's fetch, hung up
            // on, throws it away; here the fetch's thread ends with the panel, so it goes now
            let dir = crate::collect::dirname(&f);
            let pre = sh::path(&[sh::basename(&f), b"."]);
            for t in sh::glob(&dir, &pre, b"", false) {
                let _ = std::fs::remove_file(sh::os(&t));
            }
        }
    }

    // ------------------------------------------------------------------ the loop

    fn run(&mut self) -> ! {
        loop {
            if self.pump(true, -1, None) == modal::Woke::Key {
                self.input();
            }
        }
    }
}

/// The live panel: `tmux-revive-panel` with no arguments (bash: panel.sh with none)
pub fn run(root: &[u8]) -> ! {
    if !term::is_tty() {
        eprintln!("tmux-revive panel needs a terminal");
        std::process::exit(1);
    }
    sh::init(root);
    let g0 = crate::collect::G::new(root);
    g0.cache_dir();
    term::stderr_to(&sh::path(&[&g0.rdir, b"/panel.err"]));
    term::enter();
    let saved = term::Saved::take();
    saved.raw_ish();
    term::on_panic(&saved);
    let sig_r = term::signals();
    let (wake_r, wake_w) = term::pipe();
    let hub = Arc::new(Hub::default());
    collectors::start(root, &hub, wake_w);
    // The first look starts now, under the splash.
    hub.panes_k.kick();
    let env = Env::read();
    let mut c = Ctx::load(&Snapshot::apply(&[]).unwrap_or_default(), &env);
    c.tick = 0;
    c.p.help = 0; // (REVIVE_PANEL_HELP opens the page for a --once only, as help.sh's)
    c.p.version = g0.version.clone();
    c.p.host = g0.host.clone();
    let refresh = sh::env("REVIVE_PANEL_REFRESH").filter(|v| !v.is_empty()).unwrap_or_else(|| b"2".to_vec());
    let refresh = std::str::from_utf8(&refresh).ok().and_then(|s| s.parse::<f64>().ok()).filter(|f| f.is_finite() && *f > 0.0).unwrap_or(2.0);
    let dir = g0.dir.clone();
    let mut ui = Ui {
        c,
        root: root.to_vec(),
        hub,
        src: term::Stdin,
        saved,
        sig_r,
        wake_r,
        prev: Vec::new(),
        refresh: Duration::from_secs_f64(refresh),
        astate: g0.astate.clone(),
        rdir: g0.rdir.clone(),
        folddir: sh::path(&[&dir, b"/panel/fold"]),
        clk: g0.clk,
        lbox: screens::Lbox::default(),
        a_load: BTreeMap::new(),
        full_t: 0,
        started: false,
        wait_gen: true,
        wait_mail: false,
        mail_lup: BTreeMap::new(),
        wait_peek: false,
        want_draw: false,
        draw_at: Instant::now(),
        tick_at: None,
        bx: Boxes::default(),
        over: None,
        modal_on: false,
        eb_on: false,
        eb_winch: false,
        help_on: false,
        ans_on: false,
        picked: Vec::new(),
        pkey: Vec::new(),
        reply: Vec::new(),
        pending_sel: None,
        upd: upd::Upd::default(),
        amail: g0.amail.clone(),
        me: g0.me.clone(),
    };
    drop(g0);
    match sh::env("REVIVE_PANEL_SPLASH").as_deref() {
        Some(b"1") => ui.splash(),
        Some(b"0") => {}
        _ => {
            if sh::opt(b"@revive-panel-splashed", b"") != b"1" {
                ui.splash();
                sh::tm(&[b"set-option", b"-g", b"@revive-panel-splashed", b"1"]);
            }
        }
    }
    ui.prev.clear(); // after the splash: paint the whole panel
    let _ = std::fs::remove_dir_all(sh::os(&sh::path(&[&dir, b"/panel/login-said"]))); // (what an older panel kept here)
    ui.fold_load();
    ui.full_t = ui.secs();
    ui.run()
}

#[cfg(test)]
mod tests {
    use crate::snapshot::Snapshot;
    use crate::compat::Bytes;
    use std::collections::BTreeMap;

    fn snap(recs: &[(&str, &str, &str)]) -> Snapshot {
        Snapshot::apply(&recs.iter().map(|(a, b, c)| (a.as_bytes().to_vec(), b.as_bytes().to_vec(), c.as_bytes().to_vec())).collect::<Vec<_>>()).unwrap()
    }

    /// A pane appearing above an asking one between two gathers: the second generation's rows
    /// replace the first's whole, so its state stays on its own row, and nothing of the old
    /// generation (a sparse P_LIM) is left on the row that is now another pane's.
    #[test]
    fn a_generation_replaces_the_rows_whole() {
        let mut s = snap(&[("P_ID", "0", "%1"), ("P_STATE", "0", "asking"), ("P_LIM", "0", "1795000000"), ("MSG", "0", "kept"), ("FOLD", "far", "1")]);
        let g = snap(&[("P_ID", "0", "%9"), ("P_ID", "1", "%1"), ("P_STATE", "0", "shell"), ("P_STATE", "1", "asking"), ("RVER", "h", "1.0.0")]);
        super::swap_gen(&mut s, &g);
        assert_eq!(s.list("P_ID"), vec![b"%9".to_vec(), b"%1".to_vec()]);
        assert_eq!(s.list("P_STATE"), vec![b"shell".to_vec(), b"asking".to_vec()]);
        assert!(s.list("P_LIM").is_empty(), "the old generation's limit isn't left on row 0");
        assert_eq!(s.list("MSG"), vec![b"kept".to_vec()], "the panel's own arrays stay");
        assert_eq!(s.assoc["FOLD"].get(&b"far"[..]).map(|v| v.as_slice()), Some(&b"1"[..]));
        assert_eq!(s.assoc["RVER"].get(&b"h"[..]).map(|v| v.as_slice()), Some(&b"1.0.0"[..]));
    }

    /// A generation in before its mail: each heading LINKS has a row for says what that row says
    /// (the mail's LUP), a host new in the generation what the generation found.
    #[test]
    fn headings_go_by_the_lup_links_went_by() {
        let mut s = snap(&[("LUP", "far", "0")]);
        let g = snap(&[("LUP", "far", "1"), ("LUP", "new", "1")]);
        let mail: BTreeMap<Bytes, Bytes> = [(b"far".to_vec(), b"0".to_vec())].into_iter().collect();
        super::swap_gen(&mut s, &g);
        super::lup_over(&mut s, &mail);
        assert_eq!(s.assoc["LUP"].get(&b"far"[..]).map(|v| v.as_slice()), Some(&b"0"[..]), "LINKS's row still says not connected");
        assert_eq!(s.assoc["LUP"].get(&b"new"[..]).map(|v| v.as_slice()), Some(&b"1"[..]));
        let mail: BTreeMap<Bytes, Bytes> = [(b"far".to_vec(), b"1".to_vec()), (b"new".to_vec(), b"1".to_vec())].into_iter().collect();
        super::lup_over(&mut s, &mail);
        assert_eq!(s.assoc["LUP"].get(&b"far"[..]).map(|v| v.as_slice()), Some(&b"1"[..]), "its mail in: linked, in both");
    }

    /// State with these panes' rows, pane SEL selected, heading HSEL
    fn state(recs: &[(&str, &str, &str)], sel: i64, hsel: &str) -> crate::render::State {
        let mut p = crate::render::State::default();
        p.snap = snap(recs);
        p.sel = sel;
        p.hsel = hsel.as_bytes().to_vec();
        p
    }
    // Row 0 a pane here; 1 on far.example with its rows (P_RID) and a name; 2 there with rows
    // but no name (no P_ID either: the gather's ${name:+$name@$h}); 3 a name only (a link
    // whose rows haven't come: no P_RID).
    const ROWS: &[(&str, &str, &str)] = &[
        ("P_ID", "0", "%1"),
        ("P_NAME", "0", "shop"),
        ("P_LOC", "0", "work:0.0"),
        ("P_HOST", "0", ""),
        ("P_RID", "0", ""),
        ("P_ID", "1", "far-top@far.example"),
        ("P_NAME", "1", "far-top"),
        ("P_HOST", "1", "far.example"),
        ("P_RID", "1", "%1"),
        ("P_ID", "2", ""),
        ("P_NAME", "2", ""),
        ("P_HOST", "2", "far.example"),
        ("P_RID", "2", "%7"),
        ("P_ID", "3", "zed-a@Zed.example"),
        ("P_NAME", "3", "zed-a"),
        ("P_HOST", "3", "Zed.example"),
        ("P_RID", "3", ""),
    ];

    #[test]
    fn the_key_bar_fades_what_cant_act() {
        assert_eq!(state(ROWS, 0, "far.example").keys_off(), b" O M N ", "a heading: none of a pane's keys");
        assert_eq!(state(ROWS, 0, "").keys_off(), b" ", "a pane here: all of them");
        assert_eq!(state(ROWS, 1, "").keys_off(), b" O ", "linked, rows and a name: never O");
        assert_eq!(state(ROWS, 2, "").keys_off(), b" M O ", "linked, no name: no M");
        assert_eq!(state(ROWS, 3, "").keys_off(), b" N O ", "linked, no P_RID: no N");
        let none = [("P_ID", "0", ""), ("P_HOST", "0", "h"), ("P_RID", "0", ""), ("P_NAME", "0", "")];
        assert_eq!(state(&none, 0, "").keys_off(), b" N M O ");
    }

    /// Every key the bar fades is said here, with bash act()'s words, from the Rust panel itself
    #[test]
    fn a_faded_key_says_why_and_goes_nowhere() {
        use super::pane_key_early as early;
        let said = |t: &str| Some(Some(t.as_bytes().to_vec()));
        for k in ["o", "O", "m", "M", "n", "N"] {
            assert_eq!(early(&state(ROWS, 0, "far.example"), k.as_bytes()), said("select one of far.example's panes for that"), "{}", k);
        }
        for (row, k, want) in [
            (1, "O", said("O opens panes on this computer only")),
            (1, "o", said("O opens panes on this computer only")),
            (2, "O", said("O opens panes on this computer only")),
            (3, "O", said("O opens panes on this computer only")),
            (2, "M", said("that pane has no name; name it on far.example to message it")),
            (2, "m", said("that pane has no name; name it on far.example to message it")),
            (3, "N", said("on Zed.example: can't tell which pane that is (update tmux-revive there)")),
            (3, "n", said("on Zed.example: can't tell which pane that is (update tmux-revive there)")),
            // what can act, acts: O here opens, M and N go on to their box
            (0, "O", None),
            (0, "M", None),
            (0, "N", None),
            (1, "M", None),
            (1, "N", None),
            (2, "N", None),
            (3, "M", None),
        ] {
            assert_eq!(early(&state(ROWS, row, ""), k.as_bytes()), want, "row {} {}", row, k);
        }
        // the key bar's off and these agree: a faded key never acts
        for row in 0..4 {
            let p = state(ROWS, row, "");
            for k in ["O", "M", "N"] {
                let faded = p.keys_off().windows(3).any(|w| w == format!(" {} ", k).as_bytes());
                assert_eq!(faded, early(&p, k.as_bytes()).is_some(), "row {} {}", row, k);
            }
        }
        // act()'s other early returns: a pane with no id here, a host that can't be one
        let bare = [("P_ID", "0", ""), ("P_HOST", "0", "")];
        for k in ["O", "M", "N"] {
            assert_eq!(early(&state(&bare, 0, ""), k.as_bytes()), Some(None), "{}", k);
        }
        let odd = [("P_ID", "0", "x@-bad"), ("P_NAME", "0", "x"), ("P_HOST", "0", "-bad"), ("P_RID", "0", "%1")];
        assert_eq!(early(&state(&odd, 0, ""), b"N"), Some(None));
        assert_eq!(early(&state(ROWS, 0, ""), b"x"), None);
    }

    #[test]
    fn gathered_names_are_the_looks_only() {
        use super::gathered;
        for n in ["P_ID", "P_STATE", "P_LIM", "W_SINCE", "W_FROM", "W_REPLY", "X_SSH", "X_WHERE"] {
            assert!(gathered(n), "{}", n);
        }
        for n in ["MSG", "SIDE", "INTROS", "SCREEN", "SCREEN_E", "RPEEK", "NOTICES", "CPU_HIST", "ATOP", "QL", "WON"] {
            assert!(!gathered(n), "{}", n);
        }
    }
}
