#!/usr/bin/env bash
# tmux-revive: survive detach + reboot, and wake every pane's program back up,
# Claude Code sessions included, in the exact session each one was running.
#
# Load from tmux.conf:   run-shell ~/.local/share/tmux-revive/revive.tmux
# or with TPM:           set -g @plugin 'odysseyalive/tmux-revive'
#
# This file must stay bash-3.2 safe (stock macOS); the scripts it launches
# run under the newest bash it can find.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$ROOT/scripts"

get() {
	local v
	v=$(tmux show-option -gqv "$1")
	printf '%s' "${v:-$2}"
}

BASH4=""
for b in "$(get @revive-bash '')" "$BASH" /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash)"; do
	[ -n "$b" ] && [ -x "$b" ] || continue
	if [ "$("$b" -c 'echo ${BASH_VERSINFO[0]}')" -ge 4 ] 2>/dev/null; then BASH4=$b; break; fi
done
if [ -z "$BASH4" ]; then
	tmux display-message "tmux-revive: needs bash 4 or newer (macOS: brew install bash)"
	exit 0
fi
tmux set-option -g @revive-bash "$BASH4"
run() { printf '%q %q' "$BASH4" "$S/$1"; }
# run-shell expands formats in its command, so a '#' in the install path
# must reach it as '##'.
rs() { local c="$(run "$1")"; shift; c="$c${*:+ $*}"; printf '%s' "${c//\#/##}"; }
# A command string tmux parses again (hooks): single-quote it for tmux,
# splicing any ' as '\'' (the %q output inside may itself hold one).
tq() { local c=$1 q="'" r="'\\''"; printf "'%s'" "${c//$q/$r}"; }

# Saving and restoring are automatic, so no keys are bound unless you ask
# for them. Drop the bindings older versions made by default.
for k in C-s C-r M-r; do
	tmux list-keys -T prefix "$k" 2>/dev/null | grep -q tmux-revive && tmux unbind-key -T prefix "$k"
done
save_key=$(get @revive-save-key none)
restore_key=$(get @revive-restore-key none)
status_key=$(get @revive-status-key none)
panel_key=$(get @revive-panel-key none)

[ "$save_key" != none ] && tmux bind-key "$save_key" run-shell -b "$(rs save.sh manual)"
[ "$restore_key" != none ] && tmux bind-key "$restore_key" run-shell -b "$(rs restore.sh)"
[ "$status_key" != none ] &&
	tmux bind-key "$status_key" display-popup -E -w 90% -h 80% \
		"$(printf %q "$ROOT/bin/tmux-revive") status; printf '\\npress a key'; read -rsn1"
[ "$panel_key" != none ] &&
	tmux bind-key "$panel_key" display-popup -E -w 95% -h 95% \
		"REVIVE_PANEL_POPUP=1 $(printf %q "$ROOT/bin/tmux-revive") panel"

# Save the moment you detach: the usual last thing before a shutdown.
# An indexed hook slot keeps any client-detached hooks of your own intact.
tmux set-hook -g 'client-detached[77]' "run-shell -b $(tq "$(rs save.sh detach)")"

# Save when you close a pane, window or session, so what you closed stays
# closed. tmux exits the moment its last session goes, before any hook runs,
# so keep the server up (exit-empty off) long enough to record that you
# closed everything; save.sh then shuts it down as tmux would have, unless
# you had exit-empty off yourself. kill-server and a shutdown signal fire no
# hooks, so they keep the last snapshot for the next start.
[ -z "$(tmux show-option -gqv @revive-exit-empty)" ] &&
	tmux set-option -g @revive-exit-empty "$(tmux show-option -gv exit-empty)"
tmux set-option -g exit-empty off
for h in pane-exited after-kill-pane window-unlinked session-closed; do
	tmux set-hook -g "$h[77]" "run-shell -b $(tq "$(rs save.sh close --quiet)")"
done

# Interval saves + a final save on shutdown/suspend (one daemon per server).
tmux run-shell -b "$(rs daemon.sh)"

# agent-say links to machines you ssh into come back with tmux.
as=$(printf %q "$ROOT/bin/agent-say")
tmux run-shell -b "${as//\#/##} _resume-links"

# First start after a reboot: bring everything back.
tmux run-shell -b "$(rs restore.sh --auto)"
