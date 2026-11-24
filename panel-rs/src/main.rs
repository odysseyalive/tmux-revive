//! tmux-revive-panel: the control panel of scripts/panel.sh, ported to Rust with its screen kept
//! byte for byte (plan/rust-panel-2026-11-23.md). Phase 1: the render core, from snapshots.

mod compat;
mod snapshot;

fn main() {
    compat::init_locale();
}
