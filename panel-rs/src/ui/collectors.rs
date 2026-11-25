//! The live panel's collectors, each on a thread of its own (plan "Concurrency design"), each
//! with its own `G` (bash's globals for the gather path): the UI thread never takes a lock a
//! collector holds while it works, and never runs one itself.
//!
//! - panes: `G::gather` (the process table, the pane list, the agents' looks, git, the ssh
//!   sessions and linked computers' rows, as collect/ has them), published as one generation;
//! - mail: `intros_look`, `messages` and `links_saves`, after each generation (bash runs them
//!   in the draw after each gather), with that generation's panes (links_saves reads P_SSH);
//! - peek: the selected pane's screen, `tm capture-pane` here (bash's pane_screen) or
//!   `peek_look` for a linked computer's, for whatever the UI last asked for.
//!
//! A collector runs when the UI kicks it, as bash looks again: on its refresh, after a key that
//! isn't a move, and (peek) when the selection moves. A result goes into the hub and a byte on
//! the wake pipe tells the UI.

use super::term::poke;
use crate::collect::once::Sel;
use crate::collect::sh::{self, Bytes};
use crate::collect::{Panes, G};
use crate::snapshot::Snapshot;
use std::collections::BTreeMap;
use std::os::fd::RawFd;
use std::sync::{Arc, Condvar, Mutex};

/// A collector's doorbell: kicks while it works are kept as one
#[derive(Default)]
pub struct Kick {
    m: Mutex<bool>,
    c: Condvar,
}
impl Kick {
    pub fn kick(&self) {
        *self.m.lock().unwrap() = true;
        self.c.notify_one();
    }
    fn wait(&self) {
        let mut k = self.m.lock().unwrap();
        while !*k {
            k = self.c.wait(k).unwrap();
        }
        *k = false;
    }
}

/// One gather: the snapshot of what it found (P_*, W_*, X_*, RVER, ROWNER, P_GROUPS, VERSION,
/// HOST as snap_save names them), and what the UI needs of it besides
pub struct Gen {
    pub snap: Snapshot,
    pub panes: Panes,
    pub x_ssh: Vec<Bytes>,
    pub x_where: Vec<Bytes>,
    /// A_LOAD: a starting agent's pid by row, for the loading box
    pub a_load: BTreeMap<i64, Bytes>,
}

/// What draw reads from messages, links_saves and intros_look
#[derive(Default, Clone)]
pub struct Mail {
    pub msg: Vec<Bytes>,
    pub mold: i64,
    pub mwait: i64,
    pub intro_on: Bytes,
    pub side: Vec<Bytes>,
    pub intros: Vec<Bytes>,
}

/// Which screen the peek shows: a pane here (with its colours too when it asks: qhi's look),
/// or a linked computer's pane
#[derive(Default, Clone, PartialEq, Eq, Debug)]
pub enum Want {
    #[default]
    None,
    Local { id: Bytes, coloured: bool },
    Remote { h: Bytes, rid: Bytes },
}

#[derive(Default, Clone)]
pub struct Peek {
    pub want: Want,
    pub screen: Vec<Bytes>,
    pub screen_e: Vec<Bytes>,
    pub rpeek_at: Bytes,
    pub rpeek: Vec<Bytes>,
}

#[derive(Default)]
pub struct Hub {
    pub gen: Mutex<Option<Arc<Gen>>>,
    /// the newest generation, for the mail thread (links_saves reads its panes)
    pub last_gen: Mutex<Option<Arc<Gen>>>,
    pub mail: Mutex<Option<Mail>>,
    pub peek: Mutex<Option<Peek>>,
    pub want: Mutex<Want>,
    /// the files peek_look fetched, removed when the panel closes
    pub peek_files: Mutex<Vec<Bytes>>,
    /// Rows to ask a linked computer for at the next gather, as bash's RFETCH_T[$h]=0 after
    /// N, U or an answer there (handed over): Some(None) every computer's, Some(Some(h)) one's
    pub rows_again: Mutex<Option<Option<Bytes>>>,
    pub panes_k: Kick,
    pub mail_k: Kick,
    pub peek_k: Kick,
}

/// G for the live panel: as panel.sh starts, not a --once (links wait their turn, never "now")
fn live_g(root: &[u8]) -> G {
    let mut g = G::new(root);
    g.once = false;
    g
}

fn snap_of(g: &G) -> Snapshot {
    // snap_save's records of what the looks gathered (the UI's own variables it keeps itself)
    Snapshot::apply(&g.records(&Sel::default(), None)).unwrap_or_default()
}

/// The three collector threads, started; each waits for its first kick
pub fn start(root: &[u8], hub: &Arc<Hub>, wake: RawFd) {
    let (r, h) = (root.to_vec(), hub.clone());
    std::thread::Builder::new()
        .name("panes".into())
        .spawn(move || {
            let mut g = live_g(&r);
            loop {
                h.panes_k.wait();
                if let Some(k) = h.rows_again.lock().unwrap().take() {
                    g.rgate.again(k.as_deref());
                }
                g.gather();
                let gen = Arc::new(Gen {
                    snap: snap_of(&g),
                    panes: g.p.clone(),
                    x_ssh: g.x_ssh.clone(),
                    x_where: g.x_where.clone(),
                    a_load: g.a_load.clone(),
                });
                *h.last_gen.lock().unwrap() = Some(gen.clone());
                *h.gen.lock().unwrap() = Some(gen);
                poke(wake);
            }
        })
        .expect("the panes thread starts");
    let (r, h) = (root.to_vec(), hub.clone());
    std::thread::Builder::new()
        .name("mail".into())
        .spawn(move || {
            let mut g = live_g(&r);
            loop {
                h.mail_k.wait();
                if let Some(gen) = h.last_gen.lock().unwrap().clone() {
                    g.p = gen.panes.clone();
                    g.x_ssh = gen.x_ssh.clone();
                    g.x_where = gen.x_where.clone();
                }
                let intros = g.intros_look();
                let (msg, mold, mwait, intro_on) = g.messages();
                let side = g.links_saves();
                *h.mail.lock().unwrap() = Some(Mail { msg, mold, mwait, intro_on, side, intros });
                poke(wake);
            }
        })
        .expect("the mail thread starts");
    let (r, h) = (root.to_vec(), hub.clone());
    std::thread::Builder::new()
        .name("peek".into())
        .spawn(move || {
            let mut g = live_g(&r);
            loop {
                h.peek_k.wait();
                let want = h.want.lock().unwrap().clone();
                let mut p = Peek { want: want.clone(), ..Default::default() };
                match &want {
                    Want::None => {}
                    Want::Local { id, coloured } => {
                        // pane_screen: mapfile -t L < <(tm capture-pane ${3:+"$3"} -p -t "$2")
                        p.screen = sh::mapfile(&sh::tm(&[b"capture-pane", b"-p", b"-t", id]).out);
                        if *coloured {
                            p.screen_e = sh::mapfile(&sh::tm(&[b"capture-pane", b"-e", b"-p", b"-t", id]).out);
                        }
                    }
                    Want::Remote { h: host, rid } => {
                        // remote_peek's look, at most 60 lines (as snap_look asks for)
                        let (at, rp) = g.peek_look(host, rid, 60);
                        p.rpeek_at = at;
                        p.rpeek = rp;
                        *h.peek_files.lock().unwrap() = g.peek_files.iter().cloned().collect();
                    }
                }
                *h.peek.lock().unwrap() = Some(p);
                poke(wake);
            }
        })
        .expect("the peek thread starts");
}
