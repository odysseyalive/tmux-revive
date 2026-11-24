//! tmux-revive-panel: the control panel of scripts/panel.sh, ported to Rust with its screen kept
//! byte for byte (plan/rust-panel-2026-11-23.md).
//!
//!   tmux-revive-panel --once --snapshot FILE   one frame from a bash --once's REVIVE_PANEL_SNAP
//!                                              (Phase 1: not drawn yet, see below)
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
    eprintln!("usage: tmux-revive-panel --once --snapshot FILE | --probe");
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
        ["--once", "--snapshot", _] | ["--snapshot", _, "--once"] => {
            let f = if a[0] == "--once" { &args[2] } else { &args[1] };
            if let Err(e) = snapshot::Snapshot::read(std::path::Path::new(f)) {
                match e {
                    snapshot::Error::NoFile => eprintln!("tmux-revive-panel: no snapshot to read at {}", f.to_string_lossy()),
                    snapshot::Error::BadIndex(m) => eprintln!("tmux-revive-panel: {}", m),
                }
                exit(1);
            }
            // Phase 1.3 has ported the primitives, the banner and the art so far; the frame
            // (draw_top, draw_panes, ...) comes with steps 4 to 9.
            eprintln!("tmux-revive-panel: the frame isn't ported yet");
            exit(3);
        }
        _ => usage(),
    }
}
