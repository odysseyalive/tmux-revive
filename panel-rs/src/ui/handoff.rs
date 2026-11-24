//! The interim hand-over (until Phases 4 and 5): a key whose act() branch isn't ported yet goes
//! to the bash panel for that one action. The terminal is put back as it was found, and
//! `bash scripts/panel.sh` runs with REVIVE_PANEL_HANDOFF=KEY and REVIVE_PANEL_SEL=the selected
//! pane's id (REVIVE_PANEL_HSEL its heading): it gathers for itself, selects that pane, draws,
//! acts on the key with every pick, ask, note, edit_box and answer() loop it opens, and exits
//! 100 when done, leaving its flash (since 1.2.57, what a key did) in REVIVE_PANEL_HANDBACK.
//! 100: this panel takes the terminal back, the same pane selected, and paints all of it. Any other end (Q, O's
//! `exec tmux attach` or a popup's exit, Ctrl-C) ends this panel too, as it would have bash's.

use super::{term, Ui};
use crate::collect::sh;
use crate::render::{art::SCENES, num};

/// The bash panel's status for "done: carry on"
pub const BACK: i32 = 100;

impl Ui {
    pub(super) fn handoff(&mut self, key: &[u8]) {
        let back = sh::path(&[&self.rdir, b"/handback.", std::process::id().to_string().as_bytes()]);
        let _ = std::fs::remove_file(sh::os(&back));
        term::restore(&self.saved);
        let scene = SCENES.get(self.c.scene as usize).copied().unwrap_or("city");
        let script = sh::path(&[&self.root, b"/scripts/panel.sh"]);
        let st = std::process::Command::new("bash")
            .arg(sh::os(&script))
            .env("REVIVE_PANEL_HANDOFF", sh::os(key))
            .env("REVIVE_PANEL_SEL", sh::os(&self.c.p.sel_id))
            .env("REVIVE_PANEL_HSEL", sh::os(&self.c.p.hsel))
            .env("REVIVE_PANEL_HANDBACK", sh::os(&back))
            // the same view: no splash, no loading box, the same scene, the peek as it is
            .env("REVIVE_PANEL_SPLASH", "0")
            .env("REVIVE_PANEL_LOADBOX", "0")
            .env("REVIVE_PANEL_ART", scene)
            .env("REVIVE_PANEL_PEEK", if self.c.p.peek != 0 { "1" } else { "0" })
            // the flash on the key bar, for what is left of its 5 seconds
            .env("REVIVE_PANEL_FLASH", sh::os(&self.c.p.flash))
            .env("REVIVE_PANEL_FLASH_AGE", (self.secs() - self.c.p.flash_t).to_string())
            .status();
        let st = match st {
            Ok(s) => {
                use std::os::unix::process::ExitStatusExt;
                s.code().unwrap_or_else(|| 128 + s.signal().unwrap_or(0))
            }
            Err(_) => -1, // no bash to run: carry on as before
        };
        // Ctrl-C reached both: bash's own trap decided; this one's is dropped. A WINCH is
        // covered by painting it all again. TERM or HUP (the terminal closed) end this panel.
        let sigs = term::drain(self.sig_r);
        if st != BACK && st != -1 || sigs.contains(&b'X') {
            self.cleanup();
            std::process::exit(if st == BACK || st == -1 { 0 } else { st });
        }
        // What it said: a flash still showing, for what is left of its 5 seconds.
        if let Ok(d) = std::fs::read(sh::os(&back)) {
            let mut age: Option<i64> = None;
            let mut flash: Option<Vec<u8>> = None;
            for (n, _k, v) in crate::snapshot::records(&d) {
                match n.as_slice() {
                    b"FLASH" => flash = Some(v),
                    b"FLASH_AGE" => age = Some(num(&v)),
                    _ => {}
                }
            }
            if let (Some(f), Some(a)) = (flash, age) {
                self.c.p.flash = crate::compat::clean(&f);
                self.c.p.flash_t = self.secs() - a;
            }
        }
        let _ = std::fs::remove_file(sh::os(&back));
        term::enter();
        self.saved.raw_ish();
        self.prev.clear();
        self.c.p.atop.clear();
        self.fold_load();
        self.request_draw();
    }
}
