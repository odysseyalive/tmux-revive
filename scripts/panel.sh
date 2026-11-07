#!/usr/bin/env bash
# tmux-revive panel: a live, BBS-style control panel for every pane. It shows what each pane
# runs, whether an agent is working, waiting on you or asking a question, its CPU, memory and
# git state, with agent-say messages, links and saves underneath. Keys act on the selected pane.
#
#   panel.sh            run it (redraws every couple of seconds)
#   panel.sh --once     draw one frame to stdout and exit (tests, a quick look)
#
# REVIVE_PANEL_POPUP=1 (set by @revive-panel-key) closes the panel after a jump, since a popup
# would otherwise sit on top of the pane you jumped to.
set -uo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ONCE=0
[[ ${1:-} == --once ]] && ONCE=1

# Widths below are counted in characters, which needs a UTF-8 locale.
if [[ $(locale charmap 2>/dev/null) != UTF-8 ]]; then
	for l in C.UTF-8 en_US.UTF-8; do
		[[ $(LC_ALL=$l locale charmap 2>/dev/null) == UTF-8 ]] && { export LC_ALL=$l; break; }
	done
fi

ASAY="$REVIVE_ROOT/bin/agent-say"
AMAIL="${AGENT_SAY_MAILBOX:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-say/mailbox.md}"
ASTATE=$(dirname "$AMAIL")
DIR=$(revive_dir)
REFRESH=${REVIVE_PANEL_REFRESH:-2}
CLK=$(getconf CLK_TCK 2>/dev/null || echo 100)
HOST=$(hostname -s 2>/dev/null || uname -n)

# ------------------------------------------------------------------ colours
e=$'\e'
R="$e[0m" B="$e[1m" DIM="$e[2m" BLINK="$e[5m" REV="$e[7m"
BLU="$e[34m" BBLU="$e[94m" CYN="$e[36m" BCYN="$e[96m" MAG="$e[35m" BMAG="$e[95m"
YEL="$e[33m" BYEL="$e[93m" GRN="$e[32m" BGRN="$e[92m" BRED="$e[91m" BWHT="$e[97m" GRY="$e[90m"
BGBLU="$e[44m"
FRAME="$BLU"

# ------------------------------------------------------------------ drawing
rep() { local s; printf -v s '%*s' "$2" ''; printf '%s' "${s// /$1}"; } # rep CHAR N
fld() { # fld TEXT WIDTH: plain text cut or padded to exactly WIDTH characters
	local s=${1:0:$2}
	printf '%s%*s' "$s" $(($2 - ${#s})) ''
}
vlen() { # visible length of a string holding colour codes -> VLEN
	local s=$1
	while [[ $s =~ $e\[[0-9\;]*m ]]; do s=${s//"${BASH_REMATCH[0]}"/}; done
	VLEN=${#s}
}
OUT=()
line() { OUT+=("$1"); }
row() { # row CONTENT: one line inside the frame, cut or padded to the inner width
	local c=$1
	vlen "$c"
	((VLEN > IW)) && { c=$(trim_colored "$c" "$IW"); VLEN=$IW; }
	line "$FRAME║$R $c$(rep ' ' $((IW - VLEN))) $FRAME║$R"
}
sect() { # sect TITLE [RIGHT-TITLE SPLIT-AT]: a divider carrying section titles
	local t="$FRAME╠═$BBLU[ $B$BCYN$1$R$BBLU ]$FRAME" used=$((${#1} + 5))
	if [[ -n ${2:-} ]]; then
		t+="$(rep ═ $(($3 - used + 1)))╤═$BBLU[ $B$BCYN$2$R$BBLU ]$FRAME"
		used=$(($3 + 2 + ${#2} + 5))
	fi
	line "$t$(rep ═ $((W - 2 - used)))╣$R"
}

# Block letters for the banner, three rows each.
declare -A GLYPH=(
	[R]="█▀▄|█▀▄|▀ ▀" [E]="█▀▀|█▀▀|▀▀▀" [V]="█ █|▀▄▀| ▀ " [I]="▀█▀| █ |▀▀▀"
)
banner_rows() { # banner_rows WORD -> BANNER[0..2]
	local w=$1 i r g parts
	BANNER=("" "" "")
	for ((i = 0; i < ${#w}; i++)); do
		g=${GLYPH[${w:i:1}]}
		IFS='|' read -ra parts <<<"$g"
		for r in 0 1 2; do BANNER[r]+="${parts[r]} "; done
	done
}
banner_rows REVIVE

meter() { # meter PERCENT -> five shaded cells, retro style
	local p=${1%.*} out="" i lvl
	p=${p:-0}
	for ((i = 0; i < 5; i++)); do
		lvl=$((p - i * 20))
		if ((lvl >= 20)); then out+="█"; elif ((lvl >= 13)); then out+="▓"; elif ((lvl >= 7)); then out+="▒"; elif ((lvl > 0)); then out+="░"; else out+="·"; fi
	done
	printf '%s' "$out"
}
human() { # KB -> 412M / 1.2G
	local k=$1
	if ((k >= 1048576)); then printf '%d.%dG' $((k / 1048576)) $((k % 1048576 * 10 / 1048576))
	elif ((k >= 1024)); then printf '%dM' $((k / 1024))
	else printf '%dK' "$k"; fi
}

# ------------------------------------------------------------------ gathering
declare -A PCHILD PARGS PRSS PCPU TICKS_PREV GIT GIT_T
T_PREV=""
SHELLS=" sh bash zsh fish dash ksh tcsh csh nu "
# An agent asking you something: a permission prompt or a multiple-choice question.
Q_RE='do you want to|would you like to|allow (once|always)|\(y/n\)|\[y/n\]|enter to select|esc to cancel|trust (this|the) folder|yes, proceed|press enter to continue'
W_RE='esc to interrupt|ctrl\+c to interrupt'

agent_kind() { # agent_kind ARGS -> claude/codex/cursor/crush/gemini or nothing (as agent-say does)
	case " $1 " in
	*app-server*) ;;
	*/claude\ * | " claude "* | *" claude --"*) echo claude ;;
	*/codex\ * | " codex "*) echo codex ;;
	*cursor-agent*) echo cursor ;;
	*/crush\ * | " crush "*) echo crush ;;
	*/gemini\ * | *" gemini "*) echo gemini ;;
	esac
}

claude_status() { # Claude Code's own idle/busy, from its session record
	local f
	for f in "$HOME"/.claude*/sessions/"$1".json; do
		[[ -f $f ]] && { jq -r '.status // empty' "$f" 2>/dev/null; return; }
	done
}

screen_state() { # screen_state PANE -> asking / working / waiting, read off the bottom of the screen
	local -a L
	local n=0 i tail="" prompt=0
	mapfile -t L < <(tm capture-pane -p -t "$1" 2>/dev/null)
	for ((i = ${#L[@]} - 1; i >= 0 && n < 12; i--)); do
		[[ ${L[i]} =~ ^[[:space:]]*$ ]] && continue
		((n++))
		tail+="${L[i]}"$'\n'
		# The agent's own input prompt near the bottom: it is waiting for you, not asking.
		if ((n <= 6)) && [[ ${L[i]//$'\xc2\xa0'/ } =~ ^(❯|›|\>)\ ? ]] && ! [[ ${L[i]} =~ ^(❯|›|\>)[[:space:]]+[0-9]+\. ]]; then prompt=1; fi
	done
	shopt -s nocasematch
	if ((!prompt)) && [[ $tail =~ $Q_RE ]]; then echo asking
	elif [[ $tail =~ $W_RE ]]; then echo working
	else echo waiting; fi
	shopt -u nocasematch
}

git_info() { # git_info DIR -> "branch" or "branch*" (uncommitted changes), cached 15 s
	local d=$1 b dirty
	if [[ -n ${GIT_T[$d]:-} ]] && ((SECONDS - GIT_T[$d] < 15)); then printf '%s' "${GIT[$d]}"; return; fi
	b=$(git -C "$d" symbolic-ref --short -q HEAD 2>/dev/null || git -C "$d" rev-parse --short HEAD 2>/dev/null)
	if [[ -n $b ]]; then
		dirty=$(git -C "$d" status --porcelain -uno 2>/dev/null | head -c1)
		[[ -n $dirty ]] && b+="*"
	fi
	GIT[$d]=$b GIT_T[$d]=$SECONDS
	printf '%s' "$b"
}

tree_ticks() { # tree_ticks PID...: CPU ticks used so far by these processes (Linux)
	local p l f t=0
	for p in "$@"; do
		read -r l 2>/dev/null <"/proc/$p/stat" || continue # gone since ps ran
		read -ra f <<<"${l##*) }"
		t=$((t + f[11] + f[12]))
	done
	echo "$t"
}

# One record per pane, in these parallel arrays.
P_ID=() P_LOC=() P_NAME=() P_APP=() P_STATE=() P_DIR=() P_GIT=() P_CPU=() P_MEM=() P_AGENT=()
gather() {
	local pid ppid rss pcpu args id loc ppid0 cmd path name kind apid st q p tree cpu mem now dt t
	PCHILD=() PARGS=() PRSS=() PCPU=()
	while read -r pid ppid rss pcpu args; do
		PCHILD[$ppid]+="$pid " PARGS[$pid]=$args PRSS[$pid]=$rss PCPU[$pid]=$pcpu
	done < <(ps -ww -eo pid=,ppid=,rss=,pcpu=,args= 2>/dev/null) # -ww: never cut to $COLUMNS
	now=${EPOCHREALTIME:-$SECONDS}
	P_ID=() P_LOC=() P_NAME=() P_APP=() P_STATE=() P_DIR=() P_GIT=() P_CPU=() P_MEM=() P_AGENT=()
	while IFS=$'\t' read -r id loc ppid0 cmd path name; do
		# The pane's process tree, breadth-first, and the first agent in it.
		tree=() q=("$ppid0") kind="" apid=""
		while ((${#q[@]})); do
			p=${q[0]} q=("${q[@]:1}")
			tree+=("$p")
			if [[ -z $kind ]]; then kind=$(agent_kind "${PARGS[$p]:-}"); [[ -n $kind ]] && apid=$p; fi
			# shellcheck disable=SC2206
			[[ -n ${PCHILD[$p]:-} ]] && q+=(${PCHILD[$p]})
		done
		mem=0
		for p in "${tree[@]}"; do mem=$((mem + ${PRSS[$p]:-0})); done
		# CPU now, not the lifetime average ps reports: ticks used since the last frame.
		if [[ -r /proc/$ppid0/stat ]]; then
			t=$(tree_ticks "${tree[@]}")
			cpu=0
			if [[ -n $T_PREV && -n ${TICKS_PREV[$id]:-} ]]; then
				dt=$(awk -v a="$now" -v b="$T_PREV" 'BEGIN{printf "%.3f", a-b}')
				cpu=$(awk -v d=$((t - TICKS_PREV[$id])) -v c="$CLK" -v s="$dt" 'BEGIN{v = s > 0 ? d / c / s * 100 : 0; if (v < 0) v = 0; printf "%d", v + 0.5}')
			fi
			TICKS_PREV[$id]=$t
		else
			cpu=0
			for p in "${tree[@]}"; do cpu=$(awk -v a="$cpu" -v b="${PCPU[$p]:-0}" 'BEGIN{printf "%d", a + b + 0.5}'); done
		fi
		if [[ $id == "${TMUX_PANE:-}" ]]; then
			st=self P_APP+=("panel") P_AGENT+=(0)
		elif [[ -n $kind ]]; then
			st=$(screen_state "$id")
			if [[ $kind == claude && $st != asking ]]; then
				[[ $(claude_status "$apid") == busy ]] && st=working || st=waiting
			fi
			P_APP+=("$kind") P_AGENT+=(1)
		elif [[ $SHELLS == *" ${cmd#-} "* ]]; then
			st=shell P_APP+=("${cmd#-}") P_AGENT+=(0)
		else
			st=program P_APP+=("$cmd") P_AGENT+=(0)
		fi
		P_ID+=("$id") P_LOC+=("$loc") P_NAME+=("$name") P_STATE+=("$st")
		P_DIR+=("$path") P_GIT+=("$(git_info "$path")") P_CPU+=("$cpu") P_MEM+=("$mem")
	done < <(tm list-panes -a -F $'#{pane_id}\t#{session_name}:#{window_index}.#{pane_index}\t#{pane_pid}\t#{pane_current_command}\t#{pane_current_path}\t#{@agent}' 2>/dev/null)
	T_PREV=$now
}

# ------------------------------------------------------------------ sections
SEL=0 SEL_ID="" PEEK=1 FLASH="" FLASH_T=0 TICK=0
SPIN=(▖ ▘ ▝ ▗)

state_cell() { # coloured status, 18 characters wide
	case $1 in
	asking) printf '%s' "$B$BMAG$BLINK?$R$B$BMAG NEEDS ANSWER    $R" ;;
	working) printf '%s' "$BYEL${SPIN[TICK % 4]} WORKING         $R" ;;
	waiting) printf '%s' "$BGRN◆ WAITING ON YOU  $R" ;;
	shell) printf '%s' "$GRY· shell           $R" ;;
	self) printf '%s' "$BBLU✦ this panel      $R" ;;
	*) printf '%s' "$CYN▸ running         $R" ;;
	esac
}

draw_panes() {
	local i n=${#P_ID[@]} name key folder git cells mark wide=$((IW >= 100))
	# Built from the same widths as the rows below, so the columns line up.
	local hdr="$(fld ' #' 6)$(fld NAME 16)$(fld APP 10)$(fld STATE 18)"
	((wide)) && hdr+="$(fld FOLDER 16)$(fld GIT 14)"
	hdr+="$(fld CPU 13)   MEM"
	row "$GRY$hdr$R"
	for ((i = 0; i < n; i++)); do
		name=${P_NAME[i]:-${P_LOC[i]}}
		if ((i < 9)); then key="$BBLU[$BWHT$B$((i + 1))$R$BBLU]$R"; else key="$GRY · $R"; fi
		folder=${P_DIR[i]/#$HOME/\~}
		folder=${folder##*/}
		git=${P_GIT[i]}
		cells="$key "
		if ((i == SEL)); then mark="$BYEL▶$R"; else mark=" "; fi
		cells+="$mark "
		if ((i == SEL)); then cells+="$REV$BCYN$(fld "$name" 15)$R "; else cells+="$BWHT$(fld "$name" 15)$R "; fi
		if ((P_AGENT[i])); then cells+="$BCYN$(fld "${P_APP[i]}" 9)$R "; else cells+="$CYN$(fld "${P_APP[i]}" 9)$R "; fi
		cells+="$(state_cell "${P_STATE[i]}")"
		if ((wide)); then
			cells+="$BBLU$(fld "$folder" 15)$R "
			if [[ $git == *\* ]]; then cells+="$BYEL$(fld "$git" 13)$R "; else cells+="$GRN$(fld "$git" 13)$R "; fi
		fi
		cells+="$BCYN$(meter "${P_CPU[i]}")$R $(printf '%4s%%' "${P_CPU[i]}")  $(printf '%6s' "$(human "${P_MEM[i]}")")"
		row "$cells"
	done
	((n)) || row "$GRY  no tmux panes found$R"
}

draw_peek() { # draw_peek LINES: the bottom of the selected pane's screen
	local -a L=()
	local id=${P_ID[SEL]:-} i end start shown=0
	sect "PEEK · ${P_NAME[SEL]:-${P_LOC[SEL]:-}}"
	[[ -n $id ]] && mapfile -t L < <(tm capture-pane -p -t "$id" 2>/dev/null)
	# The last lines on its screen, trailing blank rows aside.
	for ((end = ${#L[@]} - 1; end >= 0; end--)); do [[ ${L[end]} =~ ^[[:space:]]*$ ]] || break; done
	start=$((end - $1 + 1))
	((start < 0)) && start=0
	for ((i = start; i <= end; i++, shown++)); do row "$GRY│$R $DIM$(fld "${L[i]}" $((IW - 2)))$R"; done
	for ((; shown < $1; shown++)); do row "$GRY│$R"; done
}

messages() { # -> MSG lines for the message center
	MSG=()
	local h b from to when id rest qn
	if [[ -f $AMAIL ]]; then
		while IFS=$'\t' read -r h b; do
			[[ $h =~ ^\#\#\ \[([^ ]+)\ -\>\ ([^ ]+)\ ([^]]+)\]\ \#([^ ]+)(.*)$ ]] || continue
			from=${BASH_REMATCH[1]} to=${BASH_REMATCH[2]} when=${BASH_REMATCH[3]} rest=${BASH_REMATCH[5]}
			when=${when:11:5}
			if [[ $rest == *"NOT DELIVERED"* ]]; then
				MSG+=("$GRY$when$R $BRED✗$R $BWHT$from$R$GRY→$R$BWHT$to$R $BRED${b}$R")
			else
				MSG+=("$GRY$when$R $BGRN✉$R $BWHT$from$R$GRY→$R$BWHT$to$R $GRY$b$R")
			fi
		done < <(tail -n 600 "$AMAIL" 2>/dev/null | awk '/^## \[/{h=$0; getline b; print h "\t" b}' | tail -n 4)
	fi
	((${#MSG[@]})) || MSG+=("$GRY no messages yet · ask an agent to use agent-say$R")
	qn=$(find "$ASTATE/queue" -maxdepth 1 -name 'msg.*' ! -name '*.err' 2>/dev/null | wc -l)
	((qn)) && MSG+=("$BYEL⧗ $qn queued, waiting for a busy pane$R")
}

links_saves() { # -> SIDE lines: saves, then links
	SIDE=()
	local last at reason n iv d h pid names
	last=$(cd -P "$DIR/last" 2>/dev/null && pwd)
	n=$(find "$DIR/snapshots" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
	iv=$(opt @revive-interval 60)
	if [[ -n $last && -f $last/state.json ]]; then
		IFS=$'\t' read -r at reason < <(jq -r '[.saved_at, .reason] | @tsv' "$last/state.json" 2>/dev/null)
		SIDE+=("$BCYN▓ SAVED$R $BWHT${at:11:8}$R $GRY($reason)$R")
	else
		SIDE+=("$BCYN▓ SAVED$R $GRY never$R")
	fi
	SIDE+=("$GRY  $n kept · every ${iv}s · on detach$R")
	for d in "$ASTATE"/links/*/; do
		[[ -f $d/on ]] || continue
		h=$(basename "$d")
		pid=$(cat "$d/pid" 2>/dev/null)
		names=$(grep -c . "$d/names" 2>/dev/null)
		if [[ -n $pid ]] && [[ $(ps -ww -o args= -p "$pid" 2>/dev/null) == *"_poll $h"* ]] && [[ ! -s $d/error ]]; then
			SIDE+=("$BGRN●$R $BWHT$h$R $GRY· linked · ${names:-0} names$R")
		elif [[ -s $d/error ]]; then
			SIDE+=("$BRED●$R $BWHT$h$R $BRED$(head -c 60 "$d/error")$R")
		else
			SIDE+=("$BRED●$R $BWHT$h$R $GRY· not running$R")
		fi
	done
	for d in "$ASTATE"/peers/*/; do
		[[ -d $d ]] || continue
		h=$(basename "$d")
		if [[ -n $(find "$d/alive" -mmin -1 2>/dev/null) ]]; then SIDE+=("$BGRN◌$R $BWHT$h$R $GRY· checks in here$R"); fi
	done
	((${#SIDE[@]} > 2)) || SIDE+=("$GRY  no links · agent-say link <host>$R")
}

draw() {
	local cols lines n i LW RW avail peek_h=0 counts w=0 a=0 s=0 l r
	cols=$(tput cols 2>/dev/null || echo 100) lines=$(tput lines 2>/dev/null || echo 40)
	((ONCE)) && cols=${COLUMNS:-$cols} lines=${LINES:-$lines}
	W=$((cols < 80 ? 80 : cols)) IW=$((W - 4))
	OUT=()
	n=${#P_ID[@]}
	for ((i = 0; i < n; i++)); do
		case ${P_STATE[i]} in working) ((w++)) ;; asking) ((a++)) ;; esac
		((P_AGENT[i])) && ((s++))
	done

	# Banner: block letters in a cyan-to-blue fade, the board's details beside them.
	line "$FRAME╔$(rep ═ $((W - 2)))╗$R"
	local tag=("$BBLU░▒▓$R$B$BWHT T M U X $R$BBLU▓▒░$R" "$B${BCYN}C O N T R O L   P A N E L$R" "$GRY node $BWHT$HOST$GRY · $(date +%H:%M:%S) · $n panes · $s agents$R")
	local shade=("$BCYN" "$CYN" "$BBLU")
	for i in 0 1 2; do row "  ${shade[i]}$B${BANNER[i]}$R   ${tag[i]}"; done
	counts="$BYEL$w working$R$GRY · $R$BMAG$a asking$R"
	((a)) && counts="$BYEL$w working$R$GRY · $R$B$BMAG$BLINK$a asking$R"
	sect "PANES"
	draw_panes
	row "$GRY$(rep ─ $((IW - 22)))$R  $counts"

	messages
	links_saves
	local bottom=$(( ${#MSG[@]} > ${#SIDE[@]} ? ${#MSG[@]} : ${#SIDE[@]} ))
	# Fixed rows: frame 2, banner 3, section bars 3, column header 1, totals 1, keys 1.
	avail=$((lines - 11 - n - bottom - 1))
	if ((PEEK && n && avail >= 4)); then
		peek_h=$((avail - 1 > 14 ? 14 : avail - 1))
		draw_peek "$peek_h"
	fi

	LW=$(((IW - 3) * 3 / 5)) RW=$((IW - 3 - LW))
	sect "MESSAGES" "LINKS · SAVES" "$((LW + 1))"
	for ((i = 0; i < bottom; i++)); do
		l=${MSG[i]:-} r=${SIDE[i]:-}
		vlen "$l"
		((VLEN > LW)) && l=$(trim_colored "$l" "$LW")
		vlen "$l"
		l+="$(rep ' ' $((LW - VLEN)))"
		vlen "$r"
		((VLEN > RW)) && r=$(trim_colored "$r" "$RW")
		row "$l $FRAME│$R $r"
	done

	# Command bar.
	local k=""
	for c in "J:ump" "M:essage" "N:ame" "P:eek" "S:ave" "Q:uit"; do
		k+="$BBLU[$B$BYEL${c%%:*}$R$BBLU]$R$BWHT${c#*:}$R  "
	done
	k+="$GRY↑↓ or 1-9 select$R"
	if [[ -n $FLASH ]] && ((SECONDS - FLASH_T < 5)); then k="$BGBLU$B$BWHT $FLASH $R  $k"; fi
	line "$FRAME╠$(rep ═ $((W - 2)))╣$R"
	row "$k"
	line "$FRAME╚$(rep ═ $((W - 2)))╝$R"

	if ((ONCE)); then
		printf '%s\n' "${OUT[@]}"
	else
		local buf=""
		for l in "${OUT[@]}"; do buf+="$l$e[K"$'\n'; done
		printf '%s' "$e[H${buf%$'\n'}$e[J"
	fi
}

trim_colored() { # trim_colored TEXT WIDTH: cut to WIDTH visible characters, keeping the colours
	local s=$1 w=$2 out="" n=0
	while [[ -n $s ]] && ((n < w - 1)); do
		if [[ $s =~ ^($e\[[0-9\;]*m) ]]; then
			out+=${BASH_REMATCH[1]} s=${s:${#BASH_REMATCH[1]}}
		else
			out+=${s:0:1} s=${s:1}
			((n++))
		fi
	done
	printf '%s' "$out…$R"
}

# ------------------------------------------------------------------ actions
flash() { FLASH=$1 FLASH_T=$SECONDS; }

ask() { # ask PROMPT -> REPLY, on the bottom line with the cursor showing
	local rows
	rows=$(tput lines 2>/dev/null || echo 40)
	printf '%s' "$e[${rows};1H$e[2K$e[?25h"
	REPLY=""
	read -e -r -p "  ${1} " REPLY
	printf '%s' "$e[?25l"
}

act() {
	local id=${P_ID[SEL]:-} name=${P_NAME[SEL]:-${P_LOC[SEL]:-}} out
	case $1 in
	j | J)
		[[ -n $id ]] || return
		if [[ -n ${TMUX:-} ]]; then
			tm switch-client -t "$id" 2>/dev/null
			tm select-window -t "$id" 2>/dev/null
			tm select-pane -t "$id" 2>/dev/null
			[[ -n ${REVIVE_PANEL_POPUP:-} ]] && exit 0
			flash "jumped to $name"
		else
			tm select-window -t "$id" 2>/dev/null
			tm select-pane -t "$id" 2>/dev/null
			restore_term
			exec tmux attach -t "${P_LOC[SEL]%%:*}"
		fi ;;
	m | M)
		[[ -n $id ]] || return
		ask "Message to $name:"
		[[ -n $REPLY ]] || return
		out=$("$ASAY" --from panel "$id" "$REPLY" 2>&1 | tail -n 1)
		flash "${out#agent-say: }" ;;
	n | N)
		[[ -n $id ]] || return
		ask "New name for $name:"
		[[ -n $REPLY ]] || return
		out=$(AGENT_SAY_PANE=$id "$ASAY" name "$REPLY" 2>&1 | head -n 1)
		flash "${out#agent-say: }" ;;
	p | P) PEEK=$((!PEEK)) ;;
	s | S)
		if "$BASH" "$REVIVE_ROOT/scripts/save.sh" manual >/dev/null 2>&1; then flash "saved"; else flash "save failed (see: tmux-revive log)"; fi ;;
	q | Q) exit 0 ;;
	[1-9]) (($1 - 1 < ${#P_ID[@]})) && SEL=$(($1 - 1)) ;;
	up) ((SEL > 0)) && ((SEL--)) ;;
	down) ((SEL < ${#P_ID[@]} - 1)) && ((SEL++)) ;;
	esac
	SEL_ID=${P_ID[SEL]:-}
}

restore_term() { printf '%s' "$e[?25h$e[?1049l"; }

# ------------------------------------------------------------------ main
if ((ONCE)); then
	gather
	sleep 0.5 # CPU is measured between two looks
	gather
	draw
	exit 0
fi
[[ -t 0 && -t 1 ]] || { echo "tmux-revive panel needs a terminal" >&2; exit 1; }
printf '%s' "$e[?1049h$e[?25l$e[2J"
on_exit restore_term
trap 'exit 0' INT TERM
trap 'printf "%s" "$e[2J"' WINCH

while :; do
	gather
	# Keep the same pane selected when panes come and go.
	if [[ -n $SEL_ID ]]; then
		for i in "${!P_ID[@]}"; do [[ ${P_ID[i]} == "$SEL_ID" ]] && SEL=$i; done
	fi
	((SEL >= ${#P_ID[@]})) && SEL=$((${#P_ID[@]} ? ${#P_ID[@]} - 1 : 0))
	SEL_ID=${P_ID[SEL]:-}
	draw
	((TICK++))
	key=""
	IFS= read -rsn1 -t "$REFRESH" key || true
	if [[ $key == "$e" ]]; then
		IFS= read -rsn2 -t 0.05 rest || true
		case $rest in '[A') key=up ;; '[B') key=down ;; *) key="" ;; esac
	fi
	[[ -n $key ]] && act "$key"
done
