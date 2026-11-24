//! tmux-revive-panel: the control panel of scripts/panel.sh, ported to Rust with its screen kept
//! byte for byte (plan/rust-panel-2026-11-23.md).
//!
//!   tmux-revive-panel --once --snapshot FILE   the frame a bash --once draws from that snapshot
//!   tmux-revive-panel --once                   the same, from REVIVE_PANEL_SNAP=load:FILE as bash
//!                                              takes it; REVIVE_PANEL_SIZES as bash's
//!   tmux-revive-panel --probe                  "ok VERSION": the install-time check (Phase 6.2)

// The port is under way: colours, helpers and snapshot fields the later steps use are here already.
#![allow(dead_code)]

mod collect;
mod compat;
mod render;
mod snapshot;

use std::process::exit;

/// The release this binary was built with: VERSION next to panel-rs.
const VERSION: &str = include_str!("../../VERSION");

fn usage() -> ! {
    eprintln!("usage: tmux-revive-panel --once [--snapshot FILE] | --probe");
    exit(2);
}

fn print_out(out: &[u8]) {
    use std::io::Write;
    let o = std::io::stdout();
    let mut o = o.lock();
    if o.write_all(out).and_then(|_| o.flush()).is_err() {
        exit(1);
    }
}

/// REVIVE_ROOT: the checkout or install this binary belongs to, found from the binary's own
/// path as bash finds its root from its own (common.sh), never from the working folder: the
/// first folder above the canonical executable that holds scripts/panel.sh. The binary sits in
/// panel-rs/target/*/ in a checkout (vendor/bin/ in an install, Phase 6). None: it isn't inside
/// a tmux-revive tree, and nothing is run (agent-say, vendor/bin and VERSION all come from here).
fn root_from(exe: &std::path::Path) -> Option<Vec<u8>> {
    let mut d = exe.parent().map(|p| p.to_path_buf());
    while let Some(p) = d {
        if p.join("scripts/panel.sh").is_file() {
            return Some(p.into_os_string().into_encoded_bytes());
        }
        d = p.parent().map(|x| x.to_path_buf());
    }
    None
}
fn root() -> Vec<u8> {
    let exe = std::env::current_exe().ok().and_then(|p| p.canonicalize().ok());
    match exe.as_deref().and_then(root_from) {
        Some(r) => r,
        None => {
            eprintln!("tmux-revive-panel: this binary must sit inside a tmux-revive tree (a folder above it holding scripts/panel.sh)");
            exit(1);
        }
    }
}

fn main() {
    compat::init_locale();
    let args: Vec<std::ffi::OsString> = std::env::args_os().skip(1).collect();
    let a: Vec<&str> = args.iter().map(|s| s.to_str().unwrap_or("")).collect();
    match a.as_slice() {
        ["--probe"] => println!("ok {}", VERSION.trim()),
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
                        // No snapshot to load: gather, as bash's --once does (save:FILE too)
                        match collect::once::run(&root()) {
                            Ok(out) => print_out(&out),
                            Err((st, m)) => {
                                if !m.is_empty() {
                                    eprintln!("{}", m);
                                }
                                exit(st);
                            }
                        }
                        return;
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
                Ok(out) => print_out(&out),
                Err(m) => {
                    eprintln!("{}", m);
                    exit(2);
                }
            }
        }
        _ => usage(),
    }
}

#[cfg(test)]
mod tests {
    /// Outside a tmux-revive tree there is no root: never the working folder.
    #[test]
    fn root_only_from_the_binarys_own_tree() {
        let here = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("target/release/tmux-revive-panel");
        assert!(super::root_from(&here).is_some());
        assert_eq!(super::root_from(std::path::Path::new("/usr/bin/tmux-revive-panel")), None);
        assert_eq!(super::root_from(std::path::Path::new("/tmp/x/tmux-revive-panel")), None);
    }
}
