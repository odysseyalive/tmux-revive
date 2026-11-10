#!/usr/bin/env bash
# One per tmux server. Saves every @revive-interval seconds, and holds a
# systemd-logind *delay* inhibitor so that when the machine is about to shut
# down or sleep, logind waits (up to InhibitDelayMaxSec, default 5 s) while we
# take a final snapshot with every process still alive. Exits with the server.
# It also says when an agent asks a question (@revive-question-alert), panel or not.
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
	# Only ever signal our own watcher: an empty pid would mean process
	# group 0, everything we share a group with.
	wpid=""
	trap '[[ -n $wpid ]] && { pkill -P "$wpid"; kill "$wpid"; } 2>/dev/null; exit 0' TERM INT
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
		wpid=""
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

# An agent asking you something (a permission prompt, a choice) waits until you answer, so
# say so on every client, with a bell in the clients showing that pane's session
# (@revive-question-bell off: no bell). Once per question: a pane is told about again only
# after it stopped asking. Which panes are asking is the panel's own look (panel.sh --asking).
declare -A ASKED=()
question_alerts() {
	local id name loc now=" " text c tty sess
	if [[ $(opt @revive-question-alert on) == off ]]; then ASKED=(); return 0; fi
	while IFS=$'\t' read -r id loc name; do
		[[ $id =~ ^%[0-9]+$ ]] || continue
		now+="$id "
		[[ -n ${ASKED[$id]:-} ]] && continue
		ASKED[$id]=1
		text="${name:-$loc} ($loc) is asking a question"
		log "question: $text"
		text="tmux-revive: ${text//\#/##}" # no formats
		while IFS=$'\t' read -r c tty sess; do
			tm display-message -c "$c" "$text" 2>/dev/null
			# A bell in the clients showing that pane's session.
			[[ $sess == "${loc%%:*}" && $(opt @revive-question-bell on) != off && -w $tty ]] && printf '\a' 2>/dev/null >"$tty"
		done < <(tm list-clients -F $'#{client_name}\t#{client_tty}\t#{session_name}' 2>/dev/null)
	done < <("$BASH" "$REVIVE_ROOT/scripts/panel.sh" --asking 2>/dev/null)
	for id in "${!ASKED[@]}"; do [[ $now == *" $id "* ]] || unset 'ASKED[$id]'; done
}

# Root's tmux, with a pane where root ran su - USER: USER's agent-say can't reach this tmux,
# and asks root's for it instead (bin/agent-say, ask_owner). agent-say _serve answers, one for
# each such user, started here when a pane of theirs shows up, and leaving once none is left.
# Only in root's tmux: nothing runs for anyone else's.
declare -A SERVING=()
serve_users() {
	local u sock
	((EUID == 0)) || return 0
	for u in $({ tm list-panes -a -F 'P #{pane_pid}' 2>/dev/null; ps -eo pid=,ppid=,uid= 2>/dev/null; } |
		awk '$1 == "P" {top[$2] = 1; next} {up[$1] = $2; id[$1] = $3}
			END {for (p in id) if (id[p] != 0) {q = p; for (i = 0; i < 64 && q > 1; i++) {if (q in top) {print id[p]; break} q = up[q]}}}' | sort -u); do
		[[ $u =~ ^[0-9]+$ ]] || continue
		[[ -n ${SERVING[$u]:-} ]] && kill -0 "${SERVING[$u]}" 2>/dev/null && continue
		sock=$(tm display-message -p '#{socket_path}' 2>/dev/null) || return 0
		TMUX="$sock,$spid,0" "$REVIVE_ROOT/bin/agent-say" _serve "$u" </dev/null >/dev/null 2>&1 &
		SERVING[$u]=$!
	done
}

log "daemon up for server $spid"
elapsed=0
tick=${REVIVE_DAEMON_TICK:-5} # tests shorten it
while same_server; do
	sleep "$tick" # short ticks so the daemon dies within seconds of its server
	((elapsed += tick))
	question_alerts
	serve_users
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
