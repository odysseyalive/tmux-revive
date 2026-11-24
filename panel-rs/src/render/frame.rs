//! The frame: scripts/panel.sh draw_top and draw (with the messages and links layout, the key
//! bar and the ANSWERING bar, plan Phase 1.3 steps 7 and 8), note_box, notice_up and
//! notice_box (1.2.55), and the --once load path: snap_apply's state for each size of
//! REVIVE_PANEL_SIZES, then draw.

use super::art::TITLES;
use super::help::help_wrap;
use super::panes::{contains, sub_all};
use super::*;
use crate::compat::{itoa, re, Bytes};
use crate::snapshot::Snapshot;

/// The environment a frame reads that the snapshot doesn't carry (the harness sets it the
/// same for both panels): HOME, USER, AGENT_SAY_HOST, REVIVE_PANEL_TIP_SECS, REVIVE_PANEL_NOW,
/// and the start-up defaults of what a snapshot may leave out.
pub struct Env {
    pub home: Bytes,
    pub user: Option<Bytes>,
    pub agent_say_host: Option<Bytes>,
    pub tip_secs: i64,
    pub now: i64,
    pub peek: Bytes,
    pub tick: Bytes,
    pub help: bool,
    pub scene: i64,
    pub host: Bytes,
}

fn env_bytes(k: &str) -> Option<Bytes> {
    std::env::var_os(k).map(|v| v.into_encoded_bytes())
}

impl Env {
    pub fn read() -> Env {
        // TIP_SECS=${REVIVE_PANEL_TIP_SECS:-30}, ^[1-9][0-9]{0,4}$ or 30
        let tip = env_bytes("REVIVE_PANEL_TIP_SECS").unwrap_or_else(|| b"30".to_vec());
        let tip_secs = if re("^[1-9][0-9]{0,4}$").is_match(&tip) { num(&tip) } else { 30 };
        // NOW_PIN: REVIVE_PANEL_NOW, ^[0-9]{1,12}$, else the clock (now_s)
        let pin = env_bytes("REVIVE_PANEL_NOW").unwrap_or_default();
        let now = if re("^[0-9]{1,12}$").is_match(&pin) {
            num(&pin)
        } else {
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
        };
        // SCENE: REVIVE_PANEL_ART by name, else $RANDOM's pick (a snapshot always carries it)
        let art = env_bytes("REVIVE_PANEL_ART").unwrap_or_default();
        let scene = art::SCENES.iter().position(|s| s.as_bytes() == art).map(|i| i as i64).unwrap_or_else(|| (std::process::id() % 5) as i64);
        // HOST=$(hostname -s 2>/dev/null || uname -n) (a snapshot always carries it)
        let mut u: libc::utsname = unsafe { std::mem::zeroed() };
        let mut host = Vec::new();
        if unsafe { libc::uname(&mut u) } == 0 {
            host = unsafe { std::ffi::CStr::from_ptr(u.nodename.as_ptr()) }.to_bytes().to_vec();
            if let Some(p) = host.iter().position(|&c| c == b'.') {
                host.truncate(p);
            }
        }
        Env {
            home: env_bytes("HOME").unwrap_or_default(),
            user: env_bytes("USER"),
            agent_say_host: env_bytes("AGENT_SAY_HOST"),
            tip_secs,
            now,
            peek: env_bytes("REVIVE_PANEL_PEEK").filter(|v| !v.is_empty()).unwrap_or_else(|| b"0".to_vec()),
            tick: env_bytes("REVIVE_PANEL_TICK").filter(|v| !v.is_empty()).unwrap_or_else(|| b"0".to_vec()),
            help: env_bytes("REVIVE_PANEL_HELP").as_deref() == Some(b"1"),
            scene,
            host,
        }
    }
}

impl Ctx {
    /// A fresh panel at its start (panel.sh's start-up values), then snap_apply: the snapshot's
    /// variables over them and its arrays in place of theirs. Called before each size, since
    /// draw changes what it reads (CPU_HIST, PO, PB_FOR, WON, ATOP...).
    pub fn load(snap: &Snapshot, env: &Env) -> Ctx {
        let mut c = Ctx::new();
        let v = |k: &str| -> Option<Bytes> { snap.var(k).map(|x| x.to_vec()) };
        let n = |k: &str, d: i64| -> i64 { snap.var(k).map(num).unwrap_or(d) };
        let p = &mut c.p;
        p.sel = n("SEL", 0);
        p.sel_id = v("SEL_ID").unwrap_or_default();
        p.hsel = v("HSEL").unwrap_or_default();
        p.focus = n("FOCUS", 0);
        let won = snap.arrays.get("WON").cloned().unwrap_or_default();
        for i in 0..4 {
            p.won[i] = won.get(&(i as i64)).map(|x| num(x)).unwrap_or(0);
        }
        p.po = n("PO", 0);
        p.pb = n("PB", 0);
        p.pb_for = v("PB_FOR").unwrap_or_default();
        p.mo = n("MO", 0);
        p.so = n("SO", 0);
        p.mman = n("MMAN", 0);
        p.peek = snap.var("PEEK").map(num).unwrap_or_else(|| num(&env.peek));
        p.peek_sel = v("PEEK_SEL").unwrap_or_default();
        p.peek_all = snap.var("PEEK_ALL").map(num).unwrap_or_else(|| num(&env.peek));
        p.help = n("HELP", env.help as i64);
        p.help_top = n("HELP_TOP", 0);
        p.flash = v("FLASH").unwrap_or_default();
        p.flash_t = n("FLASH_T", 0);
        p.lbox = n("LBOX", 0);
        p.answering = n("ANSWERING", 0);
        p.atop = snap.list("ATOP");
        p.atop_bh = n("ATOP_BH", 3);
        p.qon = n("QON", 0);
        p.mold = n("MOLD", 0);
        p.mwait = n("MWAIT", -1);
        p.msg_intro = v("MSG_INTRO").unwrap_or_else(|| b"0".to_vec());
        p.intro_on = v("INTRO_ON").unwrap_or_default();
        p.p_groups = n("P_GROUPS", 0);
        p.version = v("VERSION").unwrap_or_default();
        p.host = v("HOST").unwrap_or_else(|| env.host.clone());
        p.screen_id = v("SCREEN_ID").unwrap_or_default();
        p.rpeek_for = v("RPEEK_FOR").unwrap_or_default();
        p.rpeek_at = v("RPEEK_AT").unwrap_or_default();
        // ${SNAP_SECS:-$SECONDS}: a fresh shell's SECONDS where the snapshot has none
        p.secs = snap.snap_secs.as_deref().filter(|s| !s.is_empty()).map(num).unwrap_or(0);
        p.home = env.home.clone();
        p.user = env.user.clone();
        p.agent_say_host = env.agent_say_host.clone();
        p.tip_secs = env.tip_secs;
        p.now = env.now;
        p.snap = snap.clone();
        c.tick = snap.var("TICK").map(num).unwrap_or_else(|| num(&env.tick));
        c.scene = snap.var("SCENE").map(num).unwrap_or(env.scene);
        c.cpu_hist = snap.arrays.get("CPU_HIST").map(|m| m.iter().map(|(k, x)| (*k, num(x))).collect()).unwrap_or_default();
        c.p.banner = c.banner_rows(b"REVIVE");
        c.p.big_rows = c.big_banner(b"REVIVE", &[]);
        c
    }

    /// The frame's last line: the signature on the bottom edge
    pub fn sig(&mut self) {
        let sig = cat(&[BLU, "▓▒░".as_bytes(), R, GRY, " tmux-revive bbs · est. 2026 ".as_bytes(), R, BLU, "░▒▓".as_bytes(), R]);
        let rep = self.rep("═".as_bytes(), self.w - 4 - self.vlen(&sig));
        self.line(cat(&[FRAME, "╚".as_bytes(), &rep, R, &sig, FRAME, "══╝".as_bytes(), R]));
    }

    /// Under --once: `printf '%s\n' "${OUT[@]}"`, then a notice's box on a line of its own
    pub fn print_frame(&mut self) {
        for l in &self.out {
            self.p.print.extend_from_slice(l);
            self.p.print.push(b'\n');
        }
        if self.notice_up() {
            let nb = self.notice_box();
            self.p.print.extend(nb);
            self.p.print.push(b'\n');
        }
    }

    /// draw_top: the banner, and PANES with its cpu graph under it. false: the ? page took the
    /// rest of the frame (help_frame drew it).
    pub fn draw_top(&mut self) -> bool {
        let n = self.p.n;
        let (mut w, mut a, mut s) = (0i64, 0i64, 0i64);
        for i in 0..n {
            match self.p.a("P_STATE", i) {
                b"working" | b"agents" => w += 1,
                b"asking" => a += 1,
                _ => {}
            }
            if num(self.p.a("P_AGENT", i)) != 0 {
                s += 1;
            }
        }
        // Banner: block letters, a little CRT and the board's details.
        let rep = self.rep("═".as_bytes(), self.w - 2);
        self.line(cat(&[FRAME, "╔".as_bytes(), &rep, "╗".as_bytes(), R]));
        let mut ban: Vec<Bytes> = Vec::new();
        let user: Bytes = match &self.p.user {
            Some(u) if !u.is_empty() => u.clone(),
            _ => b"you".to_vec(),
        };
        let (ns, ss) = (itoa(n), itoa(s));
        if self.p.lines - self.p.ph >= 30 {
            self.p.bh = 6;
            let mon = self.monitor(&itoa(w), &itoa(a), &itoa(s));
            let rule = self.rep("─".as_bytes(), 25);
            let now = crate::compat::strftime(b"%a %H:%M:%S", self.p.now);
            let tag: [Bytes; 6] = [
                cat(&[BBLU, "░▒▓".as_bytes(), R, B, BWHT, b" T M U X ", R, BBLU, "▓▒░".as_bytes(), R]),
                cat(&[B, BCYN, b"C O N T R O L   P A N E L", R]),
                cat(&[GRY, &rule, R]),
                cat(&[GRY, b" node   ", BWHT, &self.p.host, R]),
                cat(&[GRY, b" time   ", BWHT, &now, R]),
                cat(&[GRY, b" sysop  ", BWHT, &user, GRY, " · ".as_bytes(), &ns, " panes · ".as_bytes(), &ss, b" agents", R]),
            ];
            for i in 0..6 {
                let p = self.padv(&tag[i], 36);
                let big = self.p.big_rows.get(i).cloned().unwrap_or_default();
                if self.iw >= 100 {
                    ban.push(cat(&[b" ", &big, b"  ", &mon[i], b"   ", &p]));
                } else {
                    ban.push(cat(&[b" ", &big, b"  ", &p]));
                }
            }
        } else {
            let now = crate::compat::strftime(b"%H:%M:%S", self.p.now);
            let tag: [Bytes; 3] = [
                cat(&[BBLU, "░▒▓".as_bytes(), R, B, BWHT, b" T M U X ", R, BBLU, "▓▒░".as_bytes(), R]),
                cat(&[B, BCYN, b"C O N T R O L   P A N E L", R]),
                cat(&[GRY, b" node ", BWHT, &self.p.host, GRY, " · ".as_bytes(), &now, " · ".as_bytes(), &ns, " panes · ".as_bytes(), &ss, b" agents", R]),
            ];
            let shade: [&[u8]; 3] = [BCYN, CYN, BBLU];
            for i in 0..3 {
                let p = self.padv(&tag[i], 60);
                ban.push(cat(&[b"  ", shade[i], B, &self.p.banner[i], R, b"   ", &p]));
            }
        }
        // Whatever width is left beside the banner shows the scene.
        let tw = self.iw - self.vlen(&ban[0]) - 1;
        let bh = self.p.bh;
        if tw >= 8 {
            let art = self.art(tw, bh, true); // beside the banner the scene holds still
            for i in 0..bh {
                let r = cat(&[&ban.get(i as usize).cloned().unwrap_or_default(), b" ", &art.get(i as usize).cloned().unwrap_or_default()]);
                self.row(&r, Some(self.iw));
            }
        } else {
            for i in 0..bh {
                let r = ban.get(i as usize).cloned().unwrap_or_default();
                self.row(&r, None);
            }
        }
        if self.p.help != 0 {
            self.help_frame(self.p.lines, bh); // the ? page takes everything below
            return false;
        }
        let mut counts = cat(&[BYEL, &itoa(w), b" working", R, GRY, " · ".as_bytes(), R, BMAG, &itoa(a), b" asking", R]);
        if a != 0 {
            counts = cat(&[BYEL, &itoa(w), b" working", R, GRY, " · ".as_bytes(), R, B, BMAG, BLINK, &itoa(a), b" asking", R]);
        }
        let (wb0, wk0) = (self.p.wb[0].clone(), self.p.wk[0].clone());
        if self.p.wf == 0 {
            self.sect("▸ PANES".as_bytes(), Some(b"6"), Some(&wb0), Some(&wk0));
        } else {
            self.sect(b"PANES", Some(b"4"), Some(&wb0), Some(&wk0));
        }
        self.rowl = wb0.clone();
        self.rowr = wb0;
        self.draw_panes();
        // CPU across every pane, as a running graph.
        let mut total: i64 = 0;
        let cpu = self.p.snap.arrays.get("P_CPU").cloned().unwrap_or_default();
        for (i, v) in cpu.iter() {
            if self.p.a("P_HOST", *i).is_empty() {
                total = total.wrapping_add(num(v));
            }
        }
        let k = self.cpu_hist.keys().next_back().map(|k| k + 1).unwrap_or(0);
        self.cpu_hist.insert(k, total);
        if self.cpu_hist.len() > 200 {
            // CPU_HIST=("${CPU_HIST[@]: -200}"): the last 200 by index, numbered again from 0
            let top = k + 1;
            let keep: Vec<i64> = self.cpu_hist.range(top - 200..).map(|(_, v)| *v).collect();
            self.cpu_hist = keep.into_iter().enumerate().map(|(i, v)| (i as i64, v)).collect();
        }
        let sp = self.spark(self.iw - 8 - self.vlen(&counts));
        self.row(&cat(&[GRY, b" cpu ", R, &sp, b"  ", &counts]), None);
        self.rowl = FRAME.to_vec();
        self.rowr = FRAME.to_vec();
        true
    }

    /// draw: the whole frame, OUT; under --once printed, with a notice's box after it
    pub fn draw(&mut self) {
        let cols = self.p.tcols;
        let lines = self.p.tlines;
        self.p.lines = lines;
        self.w = if cols < 80 { 80 } else { cols };
        self.iw = self.w - 4;
        self.out = Vec::new();
        self.p.bh = 3;
        let n = self.p.alen("P_ID");
        self.p.n = n;
        // PANES takes about half of what the banner, bars and messages leave.
        self.panes_rows();
        let mut ph = self.p.nav.len() as i64;
        let mut i = (lines - 16) / 2;
        if i < 3 {
            i = 3;
        }
        if ph > i {
            ph = i;
        }
        if ph == 0 {
            ph = 1;
        }
        self.p.ph = ph;
        let sel = self.p.sel;
        let sst: Bytes = if self.p.hsel.is_empty() { self.p.a("P_STATE", sel).to_vec() } else { Vec::new() };
        let pbf = cat(&[&self.p.sel_id, b"|", &self.p.hsel]);
        if pbf != self.p.pb_for {
            self.p.pb = 0;
            self.p.pb_for = pbf;
        }
        let (mut msgs, mut ask) = (1i64, false);
        if sst == b"asking" {
            msgs = 0;
            ask = true;
        }
        self.p.won[2] = msgs;
        self.p.won[3] = msgs;
        self.wstyle(ask);
        if self.p.answering != 0 && !self.p.atop.is_empty() {
            // Answering: the rows above the question kept from its first frame.
            self.out = self.p.atop.clone();
            self.p.bh = self.p.atop_bh;
        } else {
            if !self.draw_top() {
                return;
            }
            if self.p.answering != 0 {
                self.p.atop = self.out.clone();
                self.p.atop_bh = self.p.bh;
            }
        }
        let bh = self.p.bh;
        // The messages: with a snapshot, what they were when it was saved (MSG_INTRO).
        let mut bottom: i64 = -1;
        // With no snapshot, messages and links_saves look now (if ((!nav || MSG_OLD)): a
        // --once's one frame always does).
        if !ask {
            if let Some(l) = self.live.as_mut() {
                let (msg, mold, mwait, on, side) = l.messages();
                let to_map = |v: Vec<Bytes>| v.into_iter().enumerate().map(|(i, x)| (i as i64, x)).collect();
                self.p.snap.arrays.insert("MSG", to_map(msg));
                self.p.snap.arrays.insert("SIDE", to_map(side));
                self.p.mold = mold;
                self.p.mwait = mwait;
                self.p.msg_intro = on;
            }
        }
        let msg = self.p.list("MSG");
        let side = self.p.list("SIDE");
        if !ask {
            self.p.intro_on = self.p.msg_intro.clone();
            bottom = msg.len() as i64 - self.p.mold;
            if side.len() as i64 > bottom {
                bottom = side.len() as i64;
            }
            let mut bcap = lines / 4;
            if bcap < 4 {
                bcap = 4;
            }
            if bottom > bcap {
                bottom = bcap;
            }
        }
        let mut avail = lines - bh - 8 - ph - bottom;
        let pid = self.p.a("P_ID", sel).to_vec();
        if self.p.peek != 0 && self.p.peek_all == 0 {
            if self.p.peek_sel.is_empty() {
                self.p.peek_sel = pid.clone();
            }
            if !(self.p.hsel.is_empty() && pid == self.p.peek_sel) {
                self.p.peek = 0;
                self.p.peek_sel = Vec::new();
            }
        }
        let (mut show, mut bar, mut peek_h) = (0i64, false, 0i64);
        if n != 0 && avail >= 4 && !sst.is_empty() && sst != b"self" {
            if self.p.peek != 0 || sst == b"asking" {
                show = 1;
            } else {
                bar = true;
            }
        }
        // The windows drawn, for J and K; one that's gone hands the focus back to PANES.
        self.p.won = [1, show, msgs, msgs];
        let fw = if (0..4).contains(&self.p.focus) { self.p.won[self.p.focus as usize] } else { 0 };
        if !(self.p.answering != 0 || fw != 0) {
            self.p.focus = 0;
            self.draw();
            return;
        }
        self.wstyle(ask);
        if show != 0 {
            peek_h = avail;
            avail = 0;
            self.rowl = self.p.wb[1].clone();
            self.rowr = self.p.wb[1].clone();
            self.draw_peek(peek_h - 1);
            self.rowl = FRAME.to_vec();
            self.rowr = FRAME.to_vec();
        } else if bar {
            let kc = self.kc(b"P", b"eek");
            let name: Bytes = if !self.p.a("P_NAME", sel).is_empty() { self.p.a("P_NAME", sel).to_vec() } else { self.p.a("P_LOC", sel).to_vec() };
            self.sectk(&cat(&["PEEK · ".as_bytes(), &name]), &kc, Some(b"4"), None, None);
            avail -= 1;
            // Under its title, centered: a tip.
            if avail >= 1 {
                let t = self.tip_line();
                self.row(&t, None);
                avail -= 1;
            }
        }
        if avail >= 3 {
            let title = TITLES.get(self.scene as usize).copied().unwrap_or("");
            self.sect(&cat(&["ART · ".as_bytes(), title.as_bytes()]), None, None, None);
            let art = self.art(self.iw, avail - 1, false);
            for l in art {
                self.row(&l, Some(self.iw));
            }
            avail = 0;
        }
        while avail > 0 {
            self.row(b"", None);
            avail -= 1;
        }
        // WH: each window's height, the page PgUp and PgDn move by (scroll)
        self.p.wh = [ph, peek_h - 1, bottom, bottom];
        let lw = (self.iw - 3) * 3 / 5;
        let rw = self.iw - 3 - lw;
        if msgs != 0 {
            self.messages_layout(&msg, &side, bottom, lw, rw);
        }
        self.key_bar(&sst);
        self.print_frame();
    }

    /// draw's MESSAGES and LINKS · SAVES, side by side, BOTTOM rows high, from MSG and SIDE
    fn messages_layout(&mut self, msg: &[Bytes], side: &[Bytes], bottom: i64, lwid: i64, rwid: i64) {
        // The │ between them, and the ╤ over it, are the focused one's edge when either is.
        let (mut mt, mut st): (Bytes, Bytes) = (b"MESSAGES".to_vec(), "LINKS · SAVES".as_bytes().to_vec());
        let (mut mc, mut sc): (&[u8], &[u8]) = (b"4", b"4");
        let mut mid: Bytes = FRAME.to_vec();
        if self.p.wf == 2 {
            mt = cat(&["▸ ".as_bytes(), &mt]);
            mc = b"6";
            mid = self.p.wb[2].clone();
        }
        if self.p.wf == 3 {
            st = cat(&["▸ ".as_bytes(), &st]);
            sc = b"6";
            mid = self.p.wb[3].clone();
        }
        let (wb2, wk2, wb3, wk3) = (self.p.wb[2].clone(), self.p.wk[2].clone(), self.p.wb[3].clone(), self.p.wk[3].clone());
        self.sect2(lwid + 1, &mid, &mt, mc, &wb2, &wk2, &st, sc, &wb3, &wk3);
        // MESSAGES shows its newest unless scrolled by hand, never past the first access
        // waiting on you.
        let mn = msg.len() as i64;
        let (mut up, mut dn) = (0, 0);
        let (mut lw, mut rw) = (lwid, rwid);
        if self.p.mman == 0 {
            self.p.mo = mn - bottom;
            if self.p.mwait >= 0 && self.p.mwait < self.p.mo {
                self.p.mo = self.p.mwait;
            }
        }
        if self.p.mo > mn - bottom {
            self.p.mo = mn - bottom;
        }
        if self.p.mo < 0 {
            self.p.mo = 0;
        }
        let sn = side.len() as i64;
        if self.p.so > sn - bottom {
            self.p.so = sn - bottom;
        }
        if self.p.so < 0 {
            self.p.so = 0;
        }
        let (mo, so) = (self.p.mo, self.p.so);
        for (i, m) in msg.iter().enumerate() {
            let i = i as i64;
            if !(contains(m, b"waiting for [G]rant access") || contains(m, "✗".as_bytes())) {
                continue;
            }
            if i < mo {
                up = 1;
            }
            if i >= mo + bottom {
                dn = 1;
            }
        }
        let msb: Vec<Bytes> = self.sbar(bottom, mn, mo, up, dn, Some(&wb2)).into_iter().map(|(_, v)| v).collect();
        let ssb: Vec<Bytes> = self.sbar(bottom, sn, so, 0, 0, Some(&wb3)).into_iter().map(|(_, v)| v).collect();
        self.rowl = wb2;
        self.rowr = wb3;
        if !msb.is_empty() {
            lw = lwid - 1;
        }
        if !ssb.is_empty() {
            rw = rwid - 1;
        }
        for i in 0..bottom {
            let mut l = msg.get((mo + i) as usize).cloned().unwrap_or_default();
            let mut r = side.get((so + i) as usize).cloned().unwrap_or_default();
            if self.vlen(&l) > lw {
                l = self.trim_colored(&l, lw);
            }
            let v = self.vlen(&l);
            l.extend(self.rep(b" ", lw - v));
            if !msb.is_empty() {
                l.push(b' ');
                l.extend_from_slice(msb.get(i as usize).map(|v| v.as_slice()).unwrap_or(b""));
            }
            if self.vlen(&r) > rw {
                r = self.trim_colored(&r, rw);
            }
            self.rbar = ssb.get(i as usize).cloned().unwrap_or_default();
            if !msb.is_empty() {
                self.row(&cat(&[&l, &mid, "│".as_bytes(), R, b" ", &r]), None);
            } else {
                self.row(&cat(&[&l, b" ", &mid, "│".as_bytes(), R, b" ", &r]), None);
            }
        }
        self.rbar = Vec::new();
        self.rowl = FRAME.to_vec();
        self.rowr = FRAME.to_vec();
    }

    /// draw's command bar (or the ANSWERING bar), and the frame's bottom edge
    fn key_bar(&mut self, sst: &[u8]) {
        let sel = self.p.sel;
        let mut k: Bytes = Vec::new();
        if self.p.answering == 0 && sst == b"asking" {
            k = cat(&[B, BMAG, b"[Enter]", R, B, BWHT, b" answer", R, b"  "]);
        }
        // Keys that can't act on the selected pane are faded.
        let mut off: Bytes = b" ".to_vec();
        let rh = self.p.a("P_HOST", sel).to_vec();
        if !self.p.hsel.is_empty() {
            off.extend_from_slice(b"O M N ");
        } else if !rh.is_empty() {
            if self.p.a("P_RID", sel).is_empty() {
                off.extend_from_slice(b"N ");
            }
            if self.p.a("P_NAME", sel).is_empty() {
                off.extend_from_slice(b"M ");
            }
            off.extend_from_slice(b"O ");
        }
        let mut cs: Vec<&[u8]> = vec![b"O:pen", b"M:essage", b"N:ame", b"B:ridge", b"U:pdate"];
        let fh: Bytes = if !self.p.hsel.is_empty() { self.p.hsel.clone() } else { rh.clone() };
        if !fh.is_empty() {
            if self.folded(&fh) {
                cs.push(b"F: unfold");
            } else {
                cs.push(b"F:old");
            }
        }
        if num(&self.p.intro_on) != 0 {
            cs.push(b"G:rant access");
        }
        cs.extend_from_slice(&[b"A:rt", b"S:ave", b"D:etach", b"Q:uit", b"?: help"]);
        for c in cs {
            let p = c.iter().position(|&x| x == b':').unwrap();
            let (key, label) = (&c[..p], &c[p + 1..]);
            if contains(&off, &cat(&[b" ", key, b" "])) {
                k.extend(cat(&[GRY, b"[", key, b"]", label, R, b"  "]));
            } else {
                k.extend(cat(&[BBLU, b"[", B, BYEL, key, R, BBLU, b"]", R, BWHT, label, R, b"  "]));
            }
        }
        let vl = self.vlen(&k);
        // How to move: in PANES the arrows select, elsewhere they scroll.
        if self.p.focus != 0 {
            if vl + 19 <= self.iw {
                k.extend(cat(&[GRY, "↑↓ PgUp PgDn scroll".as_bytes(), R]));
            } else if vl + 9 <= self.iw {
                k.extend(cat(&[GRY, "↑↓ scroll".as_bytes(), R]));
            }
        } else if vl + 15 <= self.iw {
            k.extend(cat(&[GRY, "↑↓ 0-9 select".as_bytes(), R]));
        }
        let flash_on = !self.p.flash.is_empty() && self.p.secs - self.p.flash_t < 5;
        if flash_on {
            k = cat(&[BGBLU, B, BWHT, b" ", &self.p.flash, b" ", R, b"  ", &k]);
        }
        // While answering keys go to the agent, so the bar says that and how to stop.
        if self.p.answering != 0 {
            let name: Bytes = if !self.p.a("P_NAME", sel).is_empty() { self.p.a("P_NAME", sel).to_vec() } else { self.p.a("P_LOC", sel).to_vec() };
            k = cat(&[b"\x1b[45m", B, BWHT, b" ANSWERING ", &name, b" ", R, b"  ", BMAG, " keys go to its question ·".as_bytes(), R, b" "]);
            k.extend(cat(&[B, BYEL, b"Esc", R, BMAG, b" or ", B, BYEL, b"Ctrl-]", R, BMAG, b" leaves", R]));
            if flash_on {
                k = cat(&[BGBLU, B, BWHT, b" ", &self.p.flash, b" ", R, b"  ", &k]);
            }
        }
        let rep = self.rep("═".as_bytes(), self.w - 2);
        self.line(cat(&[FRAME, "╠".as_bytes(), &rep, "╣".as_bytes(), R]));
        self.row(&k, None);
        self.sig();
    }

    /// notice_up: a notice waits, and neither the loading box nor answering has the screen
    pub fn notice_up(&self) -> bool {
        self.p.alen("NOTICES") != 0 && self.p.lbox == 0 && self.p.answering == 0
    }

    /// notice_box -> NB: the first notice's box, wrapped to fit at 70 columns at most, as many
    /// lines as the terminal holds (bash's NB_KEY cache is not kept: it only saves the work)
    pub fn notice_box(&self) -> Bytes {
        let mut ww = self.p.tcols - 10;
        if ww > 70 {
            ww = 70;
        }
        if ww < 20 {
            ww = 20;
        }
        let first = self.p.list("NOTICES").into_iter().next().unwrap_or_default();
        let wrap = help_wrap(&sub_all(&first, b"`", b"'"), ww);
        // ${WRAP[@]:0:TLINES - 6}
        let k = (self.p.tlines - 6).max(0) as usize;
        let wrap: Vec<Bytes> = wrap.into_iter().take(k).collect();
        self.note_box(b"", b"Esc closes", &wrap)
    }

    /// note_box TITLE HINT LINE... with NB_ONLY=1 -> NB: note's box, made at the panel's size
    /// (TCOLS x TLINES) for draw to paint
    pub fn note_box(&self, title: &[u8], hint: &[u8], ls: &[Bytes]) -> Bytes {
        use crate::compat::blen;
        let rows = self.p.tlines;
        let cols = self.p.tcols;
        let mut nb: Bytes = Vec::new();
        let at = |r: i64, c: i64| -> Bytes { cat(&[b"\x1b[", &itoa(r), b";", &itoa(c), b"H"]) };
        let mut w = blen(hint) + 6;
        for l in ls {
            if blen(l) + 6 > w {
                w = blen(l) + 6;
            }
        }
        if blen(title) + 12 > w {
            w = blen(title) + 12;
        }
        if w > cols - 4 {
            w = cols - 4;
        }
        let mut top = (rows - ls.len() as i64 - 5) / 2;
        let mut left = (cols - w) / 2;
        if top < 1 {
            top = 1;
        }
        if left < 1 {
            left = 1;
        }
        if !title.is_empty() {
            let rep = self.rep("═".as_bytes(), w - blen(title) - 11);
            nb.extend(cat(&[&at(top, left), BGBLU, BWHT, "╔═".as_bytes(), R, BLU, "░▒▓".as_bytes(), BGBLU, B, BWHT, b" ", title, b" ", R, BLU, "▓▒░".as_bytes(), BGBLU, BWHT, &rep, "╗".as_bytes(), R]));
        } else {
            let rep = self.rep("═".as_bytes(), w - 2);
            nb.extend(cat(&[&at(top, left), BGBLU, BWHT, "╔".as_bytes(), &rep, "╗".as_bytes(), R]));
        }
        let rep = self.rep(b" ", w - 2);
        nb.extend(cat(&[&at(top + 1, left), BGBLU, BWHT, "║".as_bytes(), &rep, "║".as_bytes(), R, GRY, "░".as_bytes(), R]));
        for (i, l) in ls.iter().enumerate() {
            let f = self.fld(l, w - 4);
            nb.extend(cat(&[&at(top + 2 + i as i64, left), BGBLU, BWHT, "║ ".as_bytes(), B, &f, R, BGBLU, BWHT, " ║".as_bytes(), R, GRY, "░".as_bytes(), R]));
        }
        let n = ls.len() as i64;
        let f = self.fld(hint, w - 4);
        nb.extend(cat(&[&at(top + 2 + n, left), BGBLU, BWHT, "║ ".as_bytes(), BCYN, &f, BWHT, " ║".as_bytes(), R, GRY, "░".as_bytes(), R]));
        let rep = self.rep("═".as_bytes(), w - 2);
        nb.extend(cat(&[&at(top + 3 + n, left), BGBLU, BWHT, "╚".as_bytes(), &rep, "╝".as_bytes(), R, GRY, "░".as_bytes(), R]));
        let rep = self.rep("░".as_bytes(), w);
        nb.extend(cat(&[&at(top + 4 + n, left + 1), GRY, &rep, R]));
        nb
    }
}

/// `--once` from a snapshot: panel.sh's `if [[ $SNAP == load:* ]]` path. Each size of
/// REVIVE_PANEL_SIZES ("80x24 100x40") after a line "--- 80x24", else one frame at COLUMNS x
/// LINES (100x40 without them). Exit 2 for a size that isn't COLSxLINES, as bash.
pub fn once(snap: &Snapshot) -> Result<Bytes, String> {
    let env = Env::read();
    let sizes_s = env_bytes("REVIVE_PANEL_SIZES").unwrap_or_default();
    // read -ra sizes <<<"${REVIVE_PANEL_SIZES:-}"
    let first = sizes_s.split(|&c| c == b'\n').next().unwrap_or(b"");
    let sizes: Vec<Bytes> = first.split(|&c| c == b' ' || c == b'\t').filter(|s| !s.is_empty()).map(|s| s.to_vec()).collect();
    for s in &sizes {
        if !re("^[1-9][0-9]{0,3}x[1-9][0-9]{0,3}$").is_match(s) {
            return Err(format!("tmux-revive-panel: REVIVE_PANEL_SIZES: {} isn't COLSxLINES", String::from_utf8_lossy(s)));
        }
    }
    let mut out: Bytes = Vec::new();
    let draw_at = |cols: i64, lines: i64, out: &mut Bytes| {
        let mut c = Ctx::load(snap, &env);
        c.p.tcols = cols;
        c.p.tlines = lines;
        c.draw();
        out.extend(std::mem::take(&mut c.p.print));
    };
    if sizes.is_empty() {
        // TCOLS=${COLUMNS:-100} TLINES=${LINES:-40}
        let cols = env_bytes("COLUMNS").filter(|v| !v.is_empty()).map(|v| num(&v)).unwrap_or(100);
        let lines = env_bytes("LINES").filter(|v| !v.is_empty()).map(|v| num(&v)).unwrap_or(40);
        draw_at(cols, lines, &mut out);
    } else {
        for s in &sizes {
            out.extend(cat(&[b"--- ", s, b"\n"]));
            let x = s.iter().position(|&c| c == b'x').unwrap();
            draw_at(num(&s[..x]), num(&s[x + 1..]), &mut out);
        }
    }
    Ok(out)
}
