# shellcheck shell=bash
# Shared helpers for tmux-revive. Sourced, never executed. Needs bash >= 4
# (revive.tmux and bin/tmux-revive find one; macOS ships 3.2).

REVIVE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Private tools the installer may drop here (a static jq, for instance).
[[ -d $REVIVE_ROOT/vendor/bin ]] && PATH="$REVIVE_ROOT/vendor/bin:$PATH"
OS=$(uname -s)

# Snapshots hold scrollback (pasted secrets, tokens) and agent session ids:
# everything we write is for this user only. tmux gets the user's own umask
# back, since a server it starts hands its umask to every shell it runs.
REVIVE_UMASK=$(umask)
umask 077

# Talk to the right tmux server. Tests point REVIVE_SOCKET at a private socket.
tm() {
	if [[ -n ${REVIVE_SOCKET:-} ]]; then
		(umask "$REVIVE_UMASK" && exec tmux -S "$REVIVE_SOCKET" "$@")
	else
		(umask "$REVIVE_UMASK" && exec tmux "$@")
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
	# Older versions left it world-readable: close it up, once.
	if [[ -n $(find "$d" -maxdepth 0 ! -perm 700 2>/dev/null) ]]; then
		chmod 700 "$d" && chmod -R go-rwx "$d" 2>/dev/null
	fi
	printf '%s' "$d"
}

log() {
	printf '%s [%s] %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "${0##*/}" "$*" >>"$(revive_dir)/revive.log"
}

msg() {
	tm display-message "tmux-revive: ${*//\#/##}" 2>/dev/null || true # no formats
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
			on_exit "rm -f $(printf '%q' "$f")"
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

# Context left in a Claude Code transcript, for the panel and for the hook that reports it
# (scripts/claude-hook.sh ctx). Claude Code doesn't write its window down: REVIVE_CLAUDE_WINDOW
# when set, else a million for a model or setting that has one (the Claude 5 family, Opus and
# Sonnet 4.6 on, an [1m] model, or a session already past 200k), else 200k.
ctx_pct() { # ctx_pct USED WINDOW -> percent left, or nothing
	[[ $1 =~ ^[0-9]+$ && $2 =~ ^[0-9]+$ ]] && (($2 > 0)) || return 0
	local l=$((100 - ($1 * 100 + $2 / 2) / $2))
	((l < 0)) && l=0
	printf '%s' "$l"
}
claude_ctx_file() { # a transcript -> percent left
	local u m w=${REVIVE_CLAUDE_WINDOW:-} dir=${1%/projects/*}
	# The last turn of the main conversation (not a subagent's, not a placeholder): the end of
	# the file is enough, and a line cut in half there is skipped.
	read -r u m < <(tail -c 4000000 "$1" 2>/dev/null | grep '"usage"' |
		jq -Rr 'fromjson? | select(.type == "assistant" and (.isSidechain | not) and .message.usage
			and .message.model != "<synthetic>") | .message
			| "\((.usage.input_tokens // 0) + (.usage.cache_read_input_tokens // 0)
				+ (.usage.cache_creation_input_tokens // 0)) \(.model)"' 2>/dev/null | tail -n 1)
	[[ -n ${u:-} ]] || return 0
	if [[ -z $w ]]; then
		w=200000
		if ((u > 200000)) || [[ $m =~ ^claude-[a-z]+-5 || $m =~ ^claude-(opus|sonnet)-4-[6-9] || $m == *'[1m]'* ]] ||
			grep -qs '"model": *"[^"]*\[1m\]' "$dir/settings.json"; then w=1000000; fi
	fi
	ctx_pct "$u" "$w"
}
