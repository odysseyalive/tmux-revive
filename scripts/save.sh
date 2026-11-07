#!/usr/bin/env bash
# Snapshot every tmux session, window, pane, and the exact AI-agent session
# running in each pane, so restore.sh can bring it all back after a reboot.
#
# usage: save.sh [manual|auto|detach|shutdown|sleep] [--quiet]
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
if [[ $reason == auto || $reason == detach ]] && command -v systemctl >/dev/null; then
	case $(systemctl is-system-running 2>/dev/null) in
	stopping) exit 0 ;;
	esac
fi

take_lock "$DIR/.save.lock" 10 || exit 0

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

detect_codex() {
	local pid=$1 link id=""
	[[ ${COMM[$pid]:-} == codex* ]] || return 1
	while read -r link; do
		if [[ $link =~ /rollout-.*([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$ ]]; then
			id=${BASH_REMATCH[1]}
			break
		fi
	done < <(open_files "$pid")
	read_argv "$pid"
	# Keep only the binary; drop `resume`, prompts, and the rest.
	local bin=${ARGV[0]:-codex}
	[[ ${bin##*/} == codex* ]] || bin=codex
	[[ $bin == */installs/codex/[0-9]*/* ]] && bin=codex
	if [[ -n $id ]]; then
		CMD="$(printf '%q' "$bin") resume $id"
	else
		CMD="$(printf '%q' "$bin") resume" # picker: never guess a session
	fi
	DETAIL=$(jq -cn --arg id "$id" '{sessionId: (if $id == "" then null else $id end)}')
}

detect_gemini() {
	local pid=$1
	read_argv "$pid"
	[[ ${ARGV[*]:-} =~ (^|/|[[:space:]])gemini([[:space:]]|$) ]] || return 1
	CMD="gemini --resume latest"
	DETAIL='{}'
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
lines=$(opt @revive-scrollback 2000)
S=$'\x1f'
fmt="#{session_name}${S}#{session_attached}${S}#{window_index}${S}#{window_name}${S}#{window_layout}${S}#{window_active}${S}#{automatic-rename}${S}#{window_zoomed_flag}${S}#{pane_index}${S}#{pane_id}${S}#{pane_pid}${S}#{pane_current_path}${S}#{pane_active}${S}#{pane_title}${S}#{session_last_attached}"

count=0 agents=0
while IFS=$S read -r sess attached widx wname layout wactive autoren zoomed pidx pid ppid cwd pactive title lastatt; do
	kind=shell CMD="" DETAIL='{}' CWD_OVERRIDE=""
	for p in $(descendants "$ppid"); do
		if detect_claude "$p"; then kind=claude; break; fi
		if detect_codex "$p"; then kind=codex; break; fi
		if detect_gemini "$p"; then kind=gemini; break; fi
	done
	if [[ $kind == shell ]] && detect_program "$ppid" "$cwd"; then kind=program; fi
	[[ $kind == claude || $kind == codex || $kind == gemini ]] && ((agents++))
	# Claude resumes by project directory: start it where the session lives.
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

if ((count == 0)); then
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
if [[ $reason == manual && $quiet == 0 ]]; then
	tm display-message "tmux-revive: saved $count panes, $agents agent sessions" 2>/dev/null
fi
exit 0
