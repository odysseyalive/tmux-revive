# shellcheck shell=bash
# Shared helpers for tmux-revive. Sourced, never executed. Needs bash >= 4
# (revive.tmux and bin/tmux-revive find one; macOS ships 3.2).

REVIVE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Private tools the installer may drop here (a static jq, for instance).
[[ -d $REVIVE_ROOT/vendor/bin ]] && PATH="$REVIVE_ROOT/vendor/bin:$PATH"
OS=$(uname -s)

# Talk to the right tmux server. Tests point REVIVE_SOCKET at a private socket.
tm() {
	if [[ -n ${REVIVE_SOCKET:-} ]]; then
		tmux -S "$REVIVE_SOCKET" "$@"
	else
		tmux "$@"
	fi
}

# opt NAME DEFAULT: read a global tmux user option.
opt() {
	local v
	v=$(tm show-option -gqv "$1" 2>/dev/null)
	printf '%s' "${v:-$2}"
}

revive_dir() {
	local d=${REVIVE_DIR:-}
	[[ -z $d ]] && d=$(opt @revive-dir "${XDG_DATA_HOME:-$HOME/.local/share}/tmux-revive")
	d=${d/#\~/$HOME}
	mkdir -p "$d/snapshots" "$d/panes"
	printf '%s' "$d"
}

log() {
	printf '%s [%s] %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "${0##*/}" "$*" >>"$(revive_dir)/revive.log"
}

msg() {
	tm display-message "tmux-revive: $*" 2>/dev/null || true
	log "$*"
}

server_alive() { tm display-message -p '#{pid}' >/dev/null 2>&1; }

now_iso() { date +%Y-%m-%dT%H:%M:%S%z; }

# One EXIT trap for everything a script wants cleaned up.
CLEANUP=()
on_exit() { CLEANUP+=("$1"); }
_run_cleanup() {
	local c
	for c in "${CLEANUP[@]}"; do eval "$c"; done
}
trap _run_cleanup EXIT

# take_lock FILE [WAIT_SECONDS]: flock where it exists (Linux), shlock on
# macOS. Held until the script exits or drop_lock. Fails when someone else
# holds it.
declare -A LOCK_FDS=()
take_lock() {
	local f=$1 w=${2:-0} fd i
	if command -v flock >/dev/null; then
		exec {fd}>"$f"
		LOCK_FDS[$f]=$fd
		if ((w)); then flock -w "$w" "$fd"; else flock -n "$fd"; fi
		return
	fi
	for ((i = 0; i <= w * 10; i++)); do
		if shlock -f "$f" -p $$ 2>/dev/null; then
			on_exit "rm -f '$f'"
			return 0
		fi
		((w)) || return 1
		sleep 0.1
	done
	return 1
}

drop_lock() {
	local fd=${LOCK_FDS[$1]:-}
	if [[ -n $fd ]]; then
		exec {fd}>&-
		unset 'LOCK_FDS[$1]'
	else
		rm -f "$1"
	fi
}

# read_argv PID -> global ARGV array. Exact on Linux; on macOS argument
# boundaries come from `ps`, which is good enough for flag matching.
read_argv() {
	ARGV=()
	if [[ -r /proc/$1/cmdline ]]; then
		mapfile -d '' -t ARGV <"/proc/$1/cmdline"
	else
		# shellcheck disable=SC2207
		ARGV=($(ps -ww -o args= -p "$1" 2>/dev/null))
	fi
}

# open_files PID: paths the process holds open.
open_files() {
	local l
	if [[ -d /proc/$1/fd ]]; then
		for l in /proc/"$1"/fd/*; do readlink "$l" 2>/dev/null; done
	elif command -v lsof >/dev/null; then
		lsof -p "$1" -Fn 2>/dev/null | sed -n 's/^n//p'
	fi
}
