#!/usr/bin/env bash
# One per tmux server. Saves every @revive-interval seconds, and holds a
# systemd-logind *delay* inhibitor so that when the machine is about to shut
# down or sleep, logind waits (up to InhibitDelayMaxSec, default 5 s) while we
# take a final snapshot with every process still alive. Exits with the server.
set -uo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

DIR=$(revive_dir)
spid=$(tm display-message -p '#{pid}' 2>/dev/null) || exit 0
take_lock "$DIR/.daemon.$spid.lock" || exit 0 # one per server (config reloads)

SAVE=("$BASH" "$REVIVE_ROOT/scripts/save.sh")
same_server() { [[ $(tm display-message -p '#{pid}' 2>/dev/null) == "$spid" ]]; }

logind_watch() {
	command -v systemd-inhibit >/dev/null && command -v gdbus >/dev/null || return 0
	trap 'pkill -P "${wpid:-0}" 2>/dev/null; kill "${wpid:-0}" 2>/dev/null; exit 0' TERM INT
	while same_server; do
		# The inhibitor lives exactly as long as this pipeline. Ending it
		# after the save releases logind to carry on.
		coproc WATCH {
			exec systemd-inhibit --what=shutdown:sleep --mode=delay \
				--who=tmux-revive --why="Saving tmux sessions" \
				gdbus monitor --system --dest org.freedesktop.login1 \
				--object-path /org/freedesktop/login1 2>/dev/null
		}
		wpid=$WATCH_PID
		event=""
		while read -r line <&"${WATCH[0]}"; do
			case $line in
			*PrepareForShutdown*true*) event=shutdown ;;
			*PrepareForSleep*true*) event=sleep ;;
			*) continue ;;
			esac
			"${SAVE[@]}" "$event" --quiet
			break
		done
		pkill -P "$wpid" 2>/dev/null
		kill "$wpid" 2>/dev/null
		wait "$wpid" 2>/dev/null
		[[ $event == shutdown ]] && return 0
		# After sleep: wait for resume before re-arming. Inhibitor setup
		# failing (no polkit rights) also lands here; back off.
		sleep 5
	done
}

if [[ $(opt @revive-shutdown-hook on) == on ]]; then
	logind_watch &
	watcher=$!
	on_exit "kill $watcher 2>/dev/null"
fi

log "daemon up for server $spid"
elapsed=0
while same_server; do
	sleep 5 # short ticks so the daemon dies within seconds of its server
	((elapsed += 5))
	# Backstop for the close hooks: a server left with no sessions is one
	# you closed down; record that and let it exit (see revive.tmux).
	if [[ $(opt @revive-exit-empty on) == on && -z $(tm list-sessions -F x 2>/dev/null) ]] && same_server; then
		"${SAVE[@]}" close --quiet
		continue
	fi
	interval=$(opt @revive-interval 60)
	if ((interval > 0 && elapsed >= interval)); then
		elapsed=0
		same_server && "${SAVE[@]}" auto --quiet
	fi
done
log "daemon down for server $spid"
