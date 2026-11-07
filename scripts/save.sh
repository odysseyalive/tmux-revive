#!/usr/bin/env bash
# Snapshot every tmux session, window, pane, and the exact AI-agent session
# running in each pane, so restore.sh can bring it all back after a reboot.
#
# usage: save.sh [manual|auto|detach|close|shutdown|sleep] [--quiet]
#   close: a pane, window or session was closed on purpose. Closing the last
#   one records an empty snapshot, so the next start restores nothing, then
#   ends the server (revive.tmux keeps it alive for this).
set -uo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

reason=${1:-manual}
quiet=0
[[ ${2:-} == --quiet ]] && quiet=1

server_alive || exit 0
DIR=$(revive_dir)

# A periodic save while the machine is going down would capture panes whose
# programs have already been killed, and overwrite the good snapshot with a
# hollow one. The logind hook (reason=shutdown) saves before that point.
if [[ $reason == auto || $reason == detach || $reason == close ]] && command -v systemctl >/dev/null; then
	case $(systemctl is-system-running 2>/dev/null) in
	stopping) exit 0 ;;
	esac
fi
# Panes dying because the machine is going down are not closes either. The
# shutdown save leaves a marker; the next startup restore clears it.
if [[ $reason == close && -n $(find "$DIR/.shutdown" -mmin -10 2>/dev/null) ]]; then
	exit 0
fi
# A restore moves windows and drops its placeholder session: not closes.
[[ $reason == close && $(opt @revive-restoring '') == 1 ]] && exit 0
[[ $reason == shutdown ]] && touch "$DIR/.shutdown"

if [[ $reason == close ]]; then
	# Closing panes one after another fires a save for each. One save waiting
	# behind the running one covers them all, since it reads tmux only after
	# it stops waiting; the rest leave. Waiting longer than usual matters
	# here: the save after the last close is the one that counts.
	take_lock "$DIR/.close.lock" || exit 0
	take_lock "$DIR/.save.lock" 30 || exit 0
	drop_lock "$DIR/.close.lock"
else
	take_lock "$DIR/.save.lock" 10 || exit 0
fi

# ---------------------------------------------------------------- processes
declare -A CHILDREN COMM
while read -r pid ppid comm; do
	CHILDREN[$ppid]+="$pid "
	COMM[$pid]=${comm##*/}
done < <(ps -eo pid=,ppid=,comm=)

descendants() { # breadth-first, the pane's shell first
	local queue=("$1") p
	while ((${#queue[@]})); do
		p=${queue[0]}
		queue=("${queue[@]:1}")
		printf '%s\n' "$p"
		# shellcheck disable=SC2206
		[[ -n ${CHILDREN[$p]:-} ]] && queue+=(${CHILDREN[$p]})
	done
}

starttime() { # field 22 of /proc/PID/stat, robust to spaces in comm
	local s
	[[ -r /proc/$1/stat ]] || return 1
	s=$(<"/proc/$1/stat")
	s=${s##*) }
	# shellcheck disable=SC2086
	set -- $s
	printf '%s' "${20}"
}

quote_argv() { printf '%q ' "$@" | sed 's/ $//'; }

# ------------------------------------------------------------ claude code
# Every live Claude Code process writes <config>/sessions/<pid>.json holding
# its sessionId, cwd, name and Remote Control bridge. Map pid -> that record.
declare -A CLAUDE
shopt -s nullglob
claude_files=("$HOME"/.claude*/sessions/*.json)
[[ -n ${CLAUDE_CONFIG_DIR:-} ]] && claude_files+=("$CLAUDE_CONFIG_DIR"/sessions/*.json)
for extra in $(opt @revive-claude-dirs ""); do
	extra=${extra/#\~/$HOME}
	claude_files+=("$extra"/sessions/*.json)
done
shopt -u nullglob
if ((${#claude_files[@]})); then
	while IFS=$'\t' read -r pid rec; do
		CLAUDE[$pid]=$rec
	done < <(jq -r '. + {file: input_filename} | select(.pid and .sessionId) | "\(.pid)\t\(tojson)"' "${claude_files[@]}" 2>/dev/null)
fi

# Flags worth carrying over to the resumed process. Anything else (a prompt,
# -p, --continue, an old --resume) is dropped so nothing is re-sent or forked.
claude_keep_args() {
	local -a out=()
	local a i=1
	while ((i < ${#ARGV[@]})); do
		a=${ARGV[i]}
		case $a in
		--model | --permission-mode | --effort | --agent | --add-dir | --settings | --mcp-config | --plugin-dir | --fallback-model | --append-system-prompt)
			out+=("$a" "${ARGV[i + 1]:-}")
			((i += 2))
			continue
			;;
		--model=* | --permission-mode=* | --effort=* | --agent=* | --add-dir=* | --settings=* | --mcp-config=* | --plugin-dir=* | --fallback-model=*)
			out+=("$a")
			;;
		--dangerously-skip-permissions | --allow-dangerously-skip-permissions | --chrome | --no-chrome | --ide | --verbose | --strict-mcp-config)
			out+=("$a")
			;;
		esac
		((i++))
	done
	((${#out[@]})) && quote_argv "${out[@]}"
}

detect_claude() { # detect_claude PID -> prints JSON detail + sets CMD
	local pid=$1 rec start want cfg bin args name rc
	rec=${CLAUDE[$pid]:-}
	[[ -z $rec ]] && return 1
	# A stale file from before a crash can name a pid that was later reused.
	if start=$(starttime "$pid"); then
		want=$(jq -r '.procStart // empty' <<<"$rec")
		[[ -n $want && $want != "$start" ]] && return 1
	else # no /proc (macOS): at least require a claude process
		read_argv "$pid"
		[[ ${COMM[$pid]:-} == claude* || ${ARGV[*]:-} == *claude* ]] || return 1
	fi

	read_argv "$pid"
	# argv[0] is `claude` for the native build but `node` (npm install) or
	# an interpreter for wrappers; then the PATH name is the right thing.
	bin=${ARGV[0]:-claude}
	[[ ${bin##*/} == claude* ]] || bin=claude
	[[ $bin == */* && ! -x $bin ]] && bin=claude
	# A versioned install path (mise .../2.1.317/claude) would pin an old
	# release after an upgrade; prefer whatever `claude` resolves to then.
	[[ $bin == */installs/claude/[0-9]*/claude ]] && bin=claude

	cfg=$(jq -r '.file | sub("/sessions/[^/]+$"; "")' <<<"$rec")
	args=$(claude_keep_args)

	CMD=""
	[[ $cfg != "$HOME/.claude" ]] && CMD="CLAUDE_CONFIG_DIR=$(printf '%q' "$cfg") "
	CMD+="$(printf '%q' "$bin") --resume $(jq -r '.sessionId' <<<"$rec")"
	[[ -n $args ]] && CMD+=" $args"

	# Bring the Remote Control bridge back too, so the session is reachable
	# from claude.ai and the phone app again under the same name.
	if [[ $(opt @revive-claude-remote-control on) == on ]] && jq -e '.bridgeSessionId' <<<"$rec" >/dev/null; then
		name=$(jq -r '.name // empty' <<<"$rec")
		rc="--remote-control"
		[[ -n $name ]] && rc+=" $(printf '%q' "$name")"
		CMD+=" $rc"
	fi
	DETAIL=$(jq -c '{sessionId, name, cwd, configDir: (.file | sub("/sessions/[^/]+$"; "")), remoteControl: (.bridgeSessionId != null), status}' <<<"$rec")
	CWD_OVERRIDE=$(jq -r '.cwd // empty' <<<"$rec")
}

# ------------------------------------------------- other agents, shared
# Each agent below is resolved by the same ladder, most certain first:
#   1. a session id the process itself exposes (an open file, its own log)
#   2. the one session in its project touched since the process started,
#      used only when it is the sole process of that agent in the project
#   3. an id on its command line (it may have switched session since)
#   4. the agent's own picker, or its "most recent", marked exact:false
UUID='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

proc_start_epoch() { # seconds since the epoch; Linux only
	local st btime
	st=$(starttime "$1") || return 1
	btime=$(awk '/^btime/ { print $2 }' /proc/stat)
	printf '%s' $((btime + st / $(getconf CLK_TCK)))
}

proc_cwd() {
	if [[ -e /proc/$1/cwd ]]; then
		readlink "/proc/$1/cwd"
	else
		lsof -a -d cwd -p "$1" -Fn 2>/dev/null | sed -n 's/^n//p'
	fi
}

proc_env() { # proc_env PID NAME: the process's own environment variable
	[[ -r /proc/$1/environ ]] || return 1
	tr '\0' '\n' <"/proc/$1/environ" | sed -n "s/^$2=//p" | head -1
}

argv_value() { # argv_value FLAG...: what follows the flag in ARGV
	local i a f
	for ((i = 1; i < ${#ARGV[@]}; i++)); do
		a=${ARGV[i]}
		for f in "$@"; do
			[[ $a == "$f" ]] && { printf '%s' "${ARGV[i + 1]:-}"; return 0; }
			[[ $a == "$f="* ]] && { printf '%s' "${a#*=}"; return 0; }
		done
	done
	return 1
}

argv_has() {
	local a f
	for a in "${ARGV[@]:1}"; do for f in "$@"; do [[ $a == "$f" ]] && return 0; done; done
	return 1
}

# sq DB SQL: read-only query; fails quietly without sqlite3 or the file.
sq() {
	[[ -f $1 ]] && command -v sqlite3 >/dev/null || return 1
	timeout 3 sqlite3 -readonly "file:$1?mode=ro" "$2" 2>/dev/null
}
sql_str() { printf "'%s'" "${1//\'/\'\'}"; }

# newest FILE-GLOB: the highest-versioned match (state_5.sqlite over state_4)
newest() {
	local f
	f=$(ls -1 $1 2>/dev/null | sort -V | tail -1)
	[[ -n $f ]] && printf '%s' "$f"
}

# alone_in_cwd PID CWD MATCHER: no other top-level process of this agent
# runs in the same directory. MATCHER is a function taking a pid.
alone_in_cwd() {
	local me=$1 cwd=$2 match=$3 p pp
	for p in "${!COMM[@]}"; do
		[[ $p == "$me" ]] && continue
		"$match" "$p" || continue
		pp=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
		"$match" "$pp" && continue # a worker of another instance
		[[ $(proc_cwd "$p") == "$cwd" ]] && return 1
	done
	return 0
}

# A resolved session: set CMD and DETAIL.
agent_result() { # agent_result ID HOW RESUME_CMD FALLBACK_CMD [CWD]
	local id=$1 how=$2
	if [[ -n $id ]]; then
		CMD=$3
		DETAIL=$(jq -cn --arg id "$id" --arg how "$how" '{sessionId: $id, exact: true, how: $how}')
	else
		CMD=$4
		DETAIL='{"sessionId": null, "exact": false, "how": "fallback"}'
	fi
	[[ -n ${5:-} ]] && CWD_OVERRIDE=$5
	return 0
}

# ------------------------------------------------------------------ codex
codex_argv() { # ARGV for PID with any interpreter (a wrapper script's bash) dropped
	read_argv "$1"
	local a0=${ARGV[0]:-}
	[[ ${a0##*/} != codex && ${ARGV[1]:-} == */codex ]] && ARGV=("${ARGV[@]:1}")
	return 0
}

is_codex() {
	codex_argv "$1"
	local a0=${ARGV[0]:-}
	[[ ${COMM[$1]:-} == codex* || ${a0##*/} == codex ]] || return 1
	[[ ${ARGV[1]:-} != app-server ]] # the shared daemon is not a pane's agent
}

detect_codex() {
	local pid=$1 id="" how="" home start cwd f bin
	is_codex "$pid" || return 1
	home=$(proc_env "$pid" CODEX_HOME)
	home=${home:-$HOME/.codex}
	cwd=$(proc_cwd "$pid")
	start=$(proc_start_epoch "$pid")

	while read -r f; do # older Codex keeps its rollout file open
		[[ $f =~ /rollout-.*($UUID)\.jsonl$ ]] && { id=${BASH_REMATCH[1]}; how=open-file; break; }
	done < <(open_files "$pid")
	if [[ -z $id && -n $start ]]; then # its log tags rows pid:<pid>:<uuid>
		id=$(sq "$(newest "$home/logs_*.sqlite")" "select thread_id from logs where process_uuid like 'pid:$pid:%' and thread_id is not null and ts >= $start order by ts desc, ts_nanos desc limit 1") && how=process-log
	fi
	if [[ -z $id && -n $start && -n $cwd ]] && alone_in_cwd "$pid" "$cwd" is_codex; then
		id=$(sq "$(newest "$home/state_*.sqlite")" "select id from threads where cwd = $(sql_str "$cwd") and source = 'cli' and archived = 0 and updated_at >= $start order by updated_at desc limit 1") && how=recent-in-project
	fi
	codex_argv "$pid"
	if [[ -z $id && ${ARGV[1]:-} == resume && ${ARGV[2]:-} =~ ^$UUID$ ]]; then
		id=${ARGV[2]} how=argv
	fi
	[[ $id =~ ^$UUID$ ]] || id=""
	bin=${ARGV[0]:-codex}
	[[ ${bin##*/} == codex && $bin != */installs/codex/[0-9]*/* ]] || bin=codex
	bin=$(printf '%q' "$bin")
	[[ $home != "$HOME/.codex" ]] && bin="CODEX_HOME=$(printf '%q' "$home") $bin"
	agent_result "$id" "$how" "$bin resume $id" "$bin resume" "$cwd"
}

# ----------------------------------------------------------- cursor agent
is_cursor() {
	read_argv "$1"
	# Its node process is named MainThread; argv[0] is .../bin/cursor-agent
	# (argv[1] when it is launched through a wrapper script).
	[[ ${ARGV[0]:-} == *cursor-agent* || ${ARGV[1]:-} == */cursor-agent ]]
}

detect_cursor() {
	local pid=$1 id="" how="" cfg start cwd f hash d newest_t=0 t keep=()
	is_cursor "$pid" || return 1
	cfg=$(proc_env "$pid" CURSOR_CONFIG_DIR)
	cfg=${cfg:-$HOME/.cursor}
	cwd=$(proc_cwd "$pid")
	start=$(proc_start_epoch "$pid")

	while read -r f; do # <config>/chats/<md5 of project>/<chat id>/store.db
		[[ $f =~ /chats/[0-9a-f]{32}/([^/]+)/store\.db ]] && { id=${BASH_REMATCH[1]}; how=open-file; break; }
	done < <(open_files "$pid")
	if [[ -z $id && -n $start && -n $cwd ]] && alone_in_cwd "$pid" "$cwd" is_cursor; then
		if command -v md5sum >/dev/null; then hash=$(printf '%s' "$cwd" | md5sum | cut -c1-32); else hash=$(printf '%s' "$cwd" | md5 -q); fi
		for d in "$cfg/chats/$hash"/*/; do
			[[ -f $d/store.db ]] || continue
			t=$(stat -c %Y "$d/store.db" 2>/dev/null || stat -f %m "$d/store.db")
			((t >= start && t > newest_t)) && { newest_t=$t; id=$(basename "$d"); how=recent-in-project; }
		done
	fi
	read_argv "$pid"
	if [[ -z $id ]] && id=$(argv_value --resume) && [[ -n $id && $id != -* ]]; then how=argv; else [[ $how ]] || id=""; fi
	f=$(argv_value --model) && keep+=(--model "$f")
	argv_has --force -f && keep+=(--force)
	f=$( ((${#keep[@]})) && quote_argv "${keep[@]}")
	agent_result "$id" "$how" "cursor-agent --resume $(printf '%q' "$id")${f:+ $f}" "cursor-agent ls" "$cwd"
}

# ------------------------------------------------------------------ crush
is_crush() {
	read_argv "$1"
	local a0=${ARGV[0]:-}
	[[ ${a0##*/} == crush && ${ARGV[1]:-} != run ]] # `crush run` is one-shot
}

detect_crush() {
	local pid=$1 id="" how="" start cwd data db keep=() f
	is_crush "$pid" || return 1
	cwd=$(argv_value --cwd -c) || cwd=$(proc_cwd "$pid")
	data=$(argv_value --data-dir -D) || data=$cwd/.crush
	db=$data/crush.db
	start=$(proc_start_epoch "$pid")

	if [[ -n $start ]] && alone_in_cwd "$pid" "$cwd" is_crush; then
		id=$(sq "$db" "select id from sessions where parent_session_id is null and updated_at >= $start order by updated_at desc limit 1") && how=recent-in-project
	fi
	read_argv "$pid"
	if [[ -z $id ]] && id=$(argv_value --session -s) && [[ -n $id ]]; then how=argv; else [[ $how ]] || id=""; fi
	[[ $data != "$cwd/.crush" ]] && keep+=(--data-dir "$data")
	argv_has -yy && keep+=(-yy)
	argv_has -y --yolo && keep+=(-y)
	f=$( ((${#keep[@]})) && quote_argv "${keep[@]}")
	agent_result "$id" "$how" "crush --session $(printf '%q' "$id")${f:+ $f}" "crush --continue${f:+ $f}" "$cwd"
}

# ----------------------------------------------------------------- gemini
detect_gemini() {
	local pid=$1
	read_argv "$pid"
	[[ ${ARGV[*]:-} =~ (^|/|[[:space:]])gemini([[:space:]]|$) ]] || return 1
	# Gemini resumes by project and index, never by id: the newest is the
	# best available, so it is marked inexact.
	CMD="gemini --resume latest"
	DETAIL='{"sessionId": null, "exact": false, "how": "latest-in-project"}'
	CWD_OVERRIDE=$(proc_cwd "$pid")
}

# Ordinary programs worth relaunching. ":all:" relaunches anything.
PROGRAMS=" $(opt @revive-programs 'vim nvim vi man less more tail top htop btop watch ssh mosh journalctl lazygit lazydocker yazi ranger k9s') "

detect_program() { # foreground job of the pane's tty
	local shell_pid=$1 cwd=$2 fg name
	fg=$(ps -o tpgid= -p "$shell_pid" 2>/dev/null | tr -d ' ')
	[[ -z $fg || $fg -le 0 ]] && return 1
	# The pane's own process is the foreground job: idle if it is a shell,
	# the program itself if the pane was started as `tmux new-window less`.
	[[ $fg == "$shell_pid" && " sh bash zsh fish dash ksh tcsh nu " == *" ${COMM[$shell_pid]#-} "* ]] && return 1
	read_argv "$fg"
	((${#ARGV[@]})) || return 1
	name=${ARGV[0]##*/}
	[[ $PROGRAMS == *" :all: "* || $PROGRAMS == *" $name "* ]] || return 1
	if [[ $name == nvim || $name == vim ]] && [[ -f $cwd/Session.vim ]]; then
		CMD="$name -S Session.vim"
	else
		CMD=$(quote_argv "${ARGV[@]}")
	fi
	DETAIL=$(jq -cn --arg n "$name" '{program: $n}')
}

# ------------------------------------------------------------------- panes
stamp=$(date +%Y%m%dT%H%M%S)
work=$(mktemp -d "$DIR/.save.XXXXXX")
on_exit "rm -rf '$work'"
: >"$work/panes.jsonl"
lines=$(opt @revive-scrollback 2000)
S=$'\x1f'
fmt="#{session_name}${S}#{session_attached}${S}#{window_index}${S}#{window_name}${S}#{window_layout}${S}#{window_active}${S}#{automatic-rename}${S}#{window_zoomed_flag}${S}#{pane_index}${S}#{pane_id}${S}#{pane_pid}${S}#{pane_current_path}${S}#{pane_active}${S}#{pane_title}${S}#{session_last_attached}"

count=0 agents=0
while IFS=$S read -r sess attached widx wname layout wactive autoren zoomed pidx pid ppid cwd pactive title lastatt; do
	kind=shell CMD="" DETAIL='{}' CWD_OVERRIDE=""
	for p in $(descendants "$ppid"); do
		if detect_claude "$p"; then kind=claude; break; fi
		if detect_codex "$p"; then kind=codex; break; fi
		if detect_cursor "$p"; then kind=cursor; break; fi
		if detect_crush "$p"; then kind=crush; break; fi
		if detect_gemini "$p"; then kind=gemini; break; fi
	done
	if [[ $kind == shell ]] && detect_program "$ppid" "$cwd"; then kind=program; fi
	[[ $kind =~ ^(claude|codex|cursor|crush|gemini)$ ]] && ((agents++))
	# Agents resume by project directory: start each where its session lives.
	[[ -n $CWD_OVERRIDE ]] && cwd=$CWD_OVERRIDE

	scroll=""
	if [[ $kind == shell && $lines -gt 0 ]]; then
		scroll="scroll-${pid#%}.txt"
		tm capture-pane -t "$pid" -p -e -S "-$lines" 2>/dev/null |
			awk '{ l[NR] = $0 } NF { last = NR } END { for (i = 1; i <= last; i++) print l[i] }' >"$work/$scroll" # drop trailing blank lines
	fi

	jq -cn \
		--arg session "$sess" --arg attached "$attached" --arg lastatt "$lastatt" \
		--arg widx "$widx" --arg wname "$wname" --arg layout "$layout" \
		--arg wactive "$wactive" --arg autoren "$autoren" --arg zoomed "$zoomed" \
		--arg pidx "$pidx" --arg cwd "$cwd" --arg pactive "$pactive" --arg title "$title" \
		--arg kind "$kind" --arg cmd "$CMD" --argjson detail "$DETAIL" --arg scroll "$scroll" \
		'{session: $session, attached: ($attached | tonumber > 0), last_attached: ($lastatt | tonumber? // 0),
		  window: ($widx | tonumber), window_name: $wname, layout: $layout,
		  window_active: ($wactive == "1"), auto_rename: ($autoren == "on"), zoomed: ($zoomed == "1"),
		  pane: ($pidx | tonumber), cwd: $cwd, active: ($pactive == "1"), title: $title,
		  kind: $kind, cmd: (if $cmd == "" then null else $cmd end), detail: $detail,
		  scrollback: (if $scroll == "" then null else $scroll end)}' >>"$work/panes.jsonl"
	((count++))
done < <(tm list-panes -a -F "$fmt")

# No panes left after a close means you shut everything down yourself: keep
# that as an empty snapshot. Any other empty save is a server on its way out.
if ((count == 0)) && [[ $reason != close ]]; then
	log "nothing to save ($reason)"
	exit 0
fi

jq -s --arg at "$(now_iso)" --arg host "$(hostname 2>/dev/null || uname -n)" --arg reason "$reason" '
  {version: 1, saved_at: $at, host: $host, reason: $reason,
   sessions: (group_by(.session) | map({
     name: .[0].session, attached: .[0].attached, last_attached: .[0].last_attached,
     windows: (group_by(.window) | map({
       index: .[0].window, name: .[0].window_name, layout: .[0].layout,
       active: .[0].window_active, auto_rename: .[0].auto_rename, zoomed: .[0].zoomed,
       panes: (sort_by(.pane) | map({index: .pane, cwd, active, title, kind, cmd, detail, scrollback}))
     }))
   }))}' "$work/panes.jsonl" >"$work/state.json"

# Unchanged layout and processes: refresh the latest snapshot in place rather
# than piling up identical copies every interval.
last="$DIR/last"
same() { cmp -s <(jq -S 'del(.saved_at, .reason)' "$1") <(jq -S 'del(.saved_at, .reason)' "$2"); }
if [[ -f $last/state.json ]] && same "$last/state.json" "$work/state.json"; then
	target=$(cd -P "$last" && pwd)
	rm -f "$target"/scroll-*.txt
else
	target="$DIR/snapshots/$stamp"
	[[ -e $target ]] && target+="-$$"
	mkdir -p "$target"
fi
mv "$work"/scroll-*.txt "$target"/ 2>/dev/null
mv "$work/state.json" "$target/state.json"
ln -sfn "$target" "$last"

# Prune old snapshots.
keep=$(opt @revive-keep 30)
mapfile -t old < <(find "$DIR/snapshots" -mindepth 1 -maxdepth 1 -type d | sort -r | tail -n +"$((keep + 1))")
((${#old[@]})) && rm -rf "${old[@]}"

log "saved $count panes, $agents agent sessions ($reason) -> ${target##*/}"
# Everything is closed: end the server the way tmux would have.
if ((count == 0)) && [[ $(opt @revive-exit-empty on) == on && -z $(tm list-sessions -F x 2>/dev/null) ]]; then
	tm kill-server 2>/dev/null
fi
if [[ $reason == manual && $quiet == 0 ]]; then
	tm display-message "tmux-revive: saved $count panes, $agents agent sessions" 2>/dev/null
fi
exit 0
