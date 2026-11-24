//! tmux-revive-panel: the control panel of scripts/panel.sh, ported to Rust with its screen kept
//! byte for byte (plan/rust-panel-2026-11-23.md).
//!
//!   tmux-revive-panel --once --snapshot FILE   the frame a bash --once draws from that snapshot
//!   tmux-revive-panel --once                   the same, from REVIVE_PANEL_SNAP=load:FILE as bash
//!                                              takes it; REVIVE_PANEL_SIZES as bash's
//!   tmux-revive-panel --probe                  "ok VERSION": the install-time check (Phase 6.2)
//!   tmux-revive-panel --component              test-only: builders one call at a time (component.rs)

// The port is under way: colours, helpers and snapshot fields the later steps use are here already.
#![allow(dead_code)]

mod compat;
mod component;
mod render;
mod snapshot;

use std::process::exit;

/// The release this binary was built with: VERSION next to panel-rs.
const VERSION: &str = include_str!("../../VERSION");

fn usage() -> ! {
    eprintln!("usage: tmux-revive-panel --once [--snapshot FILE] | --probe");
    exit(2);
}

fn main() {
    compat::init_locale();
    let args: Vec<std::ffi::OsString> = std::env::args_os().skip(1).collect();
    let a: Vec<&str> = args.iter().map(|s| s.to_str().unwrap_or("")).collect();
    match a.as_slice() {
        ["--probe"] => println!("ok {}", VERSION.trim()),
        ["--component"] => {
            let stdout = std::io::stdout();
            if component::run(&mut std::io::stdin().lock(), &mut stdout.lock()).is_err() {
                exit(1);
            }
        }
        ["--once", "--snapshot", _] | ["--snapshot", _, "--once"] | ["--once"] => {
            // --snapshot F, or as bash takes it: REVIVE_PANEL_SNAP=load:F (save: needs the looks,
            // which come with Phase 2)
            let f: std::ffi::OsString = if a.len() == 3 {
                if a[0] == "--once" { args[2].clone() } else { args[1].clone() }
            } else {
                let s = std::env::var_os("REVIVE_PANEL_SNAP").map(|v| v.into_encoded_bytes()).unwrap_or_default();
                match s.strip_prefix(b"load:").filter(|f| !f.is_empty()) {
                    Some(f) => unsafe { std::ffi::OsString::from_encoded_bytes_unchecked(f.to_vec()) },
                    None => {
                        eprintln!("tmux-revive-panel: --once draws from a snapshot only (REVIVE_PANEL_SNAP=load:FILE or --snapshot FILE) until it gathers (Phase 2)");
                        exit(3);
                    }
                }
            };
            let snap = match snapshot::Snapshot::read(std::path::Path::new(&f)) {
                Ok(s) => s,
                Err(e) => {
                    match e {
                        snapshot::Error::NoFile => eprintln!("tmux-revive-panel: no snapshot to read at {}", f.to_string_lossy()),
                        snapshot::Error::BadIndex(m) => eprintln!("tmux-revive-panel: {}", m),
                    }
                    exit(1);
                }
            };
            match render::frame::once(&snap) {
                Ok(out) => {
                    use std::io::Write;
                    let o = std::io::stdout();
                    let mut o = o.lock();
                    if o.write_all(&out).and_then(|_| o.flush()).is_err() {
                        exit(1);
                    }
                }
                Err(m) => {
                    eprintln!("{}", m);
                    exit(2);
                }
            }
        }
        _ => usage(),
    }
}
