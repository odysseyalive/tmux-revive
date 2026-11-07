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
padv() { # padv TEXT WIDTH: a coloured string padded (or cut) to WIDTH visible characters
	vlen "$1"
	if ((VLEN > $2)); then trim_colored "$1" "$2"; else printf '%s%*s' "$1" $(($2 - VLEN)) ''; fi
}
OUT=()
line() { OUT+=("$1"); }
row() { # row CONTENT: one line inside the frame, cut or padded to the inner width
	local c=$1
	vlen "$c"
	((VLEN > IW)) && { c=$(trim_colored "$c" "$IW"); VLEN=$IW; }
	line "$FRAME║$R $c$(rep ' ' $((IW - VLEN))) $FRAME║$R"
}
# A section title on a solid blue band that fades into the black on both sides: shading as
# a short transition between two colours, the way the artpack groups used it.
tab() { printf '%s' "$BLU░▒▓$BGBLU$B$BWHT $1 $R$BLU▓▒░$R"; }
sect() { # sect TITLE [RIGHT-TITLE SPLIT-AT]: a divider carrying section titles
	local t="$FRAME╠═$(tab "$1")"
	if [[ -n ${2:-} ]]; then
		vlen "$t"
		t+="$FRAME$(rep ═ $(($3 + 2 - VLEN)))╤═$(tab "$2")"
	fi
	vlen "$t"
	line "$t$FRAME$(rep ═ $((W - 1 - VLEN)))╣$R"
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

# The big banner: five rows of block letters, white fading through cyan to blue, with a
# blue ░ drop shadow one cell down and right, the way the old ANSI groups drew them.
declare -A BIG=(
	[R]="█████▄|██   █|█████▀|██  ▀▄|██   █" [E]="██████|██    |█████ |██    |██████"
	[V]="██  ██|██  ██|▐█  █▌| ▀██▀ |  ▀▀  " [I]="██|██|██|██|██"
)
big_banner() { # big_banner WORD -> BIG_ROWS[0..5]
	local w=$1 i r c ch up cur out parts
	local -a G=("" "" "" "" "") shade=("$B$BWHT" "$B$BCYN" "$B$BCYN" "$CYN" "$BBLU")
	for ((i = 0; i < ${#w}; i++)); do
		IFS='|' read -ra parts <<<"${BIG[${w:i:1}]}"
		for r in 0 1 2 3 4; do G[r]+="${parts[r]} "; done
	done
	G[5]=""
	BIG_ROWS=()
	for r in 0 1 2 3 4 5; do
		out="" cur=""
		for ((c = 0; c <= ${#G[0]}; c++)); do
			ch=${G[r]:c:1} up=" "
			((r > 0 && c > 0)) && up=${G[r - 1]:c-1:1}
			if [[ -n $ch && $ch != " " ]]; then
				[[ $cur == L ]] || { out+="$R${shade[r]}"; cur=L; }
				out+=$ch
			elif [[ -n $up && $up != " " ]]; then
				[[ $cur == S ]] || { out+="$R$BLU"; cur=S; }
				out+="░"
			else
				out+=" "
			fi
		done
		BIG_ROWS+=("$out$R")
	done
}
big_banner REVIVE

# The CRT's prompt shows the system it's running on.
case $OS in
Darwin) OSP="macos% " ;;
*BSD) OSP="bsd$ " ;;
Linux) if grep -qi microsoft /proc/version 2>/dev/null; then OSP="wsl$ "; else OSP="linux$ "; fi ;;
*) OSP="$ " ;;
esac

monitor() { # monitor WORKING ASKING AGENTS -> MON[0..5]: a little CRT, its screen live
	local cur=" " msg col g=$GRY
	((TICK % 2)) || cur="█"
	if (($2)); then msg="$2 NEED YOU" col="$B$BMAG$BLINK"
	elif (($1)); then msg="$1 working" col=$BYEL
	else msg="$3 AI idle" col=$BGRN; fi
	MON=(
		"$g▄▄▄▄▄▄▄▄▄▄▄▄▄$R"
		"$g█$R$BGRN$(fld " $OSP$cur" 11)$R$g█$R"
		"$g█$R$col$(fld " $msg" 11)$R$g█$R"
		"$g▀▀▀▀▀▀▀▀▀▀▀▀▀$R"
		"$g     ▄█▄     $R"
		"$g  ▀▀▀▀▀▀▀▀▀  $R"
	)
}

spark() { # spark WIDTH: CPU history as a ▁▂▃▅▇ graph, newest on the right
	local w=$1 i v max=10 lvl out="" bars=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
	local -a h=("${CPU_HIST[@]: -$w}")
	for v in "${h[@]}"; do ((v > max)) && max=$v; done
	for ((i = ${#h[@]}; i < w; i++)); do out+="$GRY▁"; done
	for v in "${h[@]}"; do
		lvl=$((v * 7 / max))
		if ((lvl <= 1)); then out+="$BLU"; elif ((lvl <= 3)); then out+="$BBLU"; elif ((lvl <= 5)); then out+="$BCYN"; else out+="$BYEL"; fi
		out+=${bars[lvl]}
	done
	printf '%s' "$out$R"
}
CPU_HIST=()

# ------------------------------------------------------------------ artwork
# Scenes drawn to whatever space is free, so the panel fills its pane at any size. One is
# picked at random when the panel opens (REVIVE_PANEL_ART=<name> picks one), A cycles them.
SCENES=(city mountains ocean space circuit rain grid)
TITLES=("night city" "mountains" "moonlit sea" "deep space" "circuit board" "digital rain" "neon grid")
SCENE=$((RANDOM % ${#SCENES[@]}))
for i in "${!SCENES[@]}"; do [[ ${SCENES[i]} == "${REVIVE_PANEL_ART:-}" ]] && SCENE=$i; done
BGBLK="$e[40m" BGGRY="$e[100m"

# A canvas of characters and colours, filled by a scene and turned into rows by emit.
canvas() { ART_W=$1 ART_H=$2 CH=() CO=(); }
put() { # put ROW COL CHAR COLOUR (off the canvas: ignored)
	(($1 >= 0 && $1 < ART_H && $2 >= 0 && $2 < ART_W)) || return 0
	CH[$1 * ART_W + $2]=$3 CO[$1 * ART_W + $2]=$4
}
rnd() { SEED=$(((SEED * 1103515245 + 12345) & 2147483647)) RV=$((SEED >> 8)); } # same seed, same picture
emit() { # -> ART rows, switching colour only where it changes
	local r c i out cur col
	ART=()
	for ((r = 0; r < ART_H; r++)); do
		out="" cur=""
		for ((c = 0; c < ART_W; c++)); do
			i=$((r * ART_W + c)) col=${CO[i]-}
			[[ $col == "$cur" ]] || { out+="$R$col"; cur=$col; }
			out+=${CH[i]:- }
		done
		ART+=("$out$R")
	done
}
stars() { # stars ROWS ONE-IN-N: sky dust in the top ROWS rows; a few twinkle
	local r c
	for ((r = 0; r < $1; r++)); do
		for ((c = 0; c < ART_W; c++)); do
			rnd
			((RV % $2)) && continue
			if (((RV / 7 + TICK) % 9 == 0)); then put $r $c "*" "$BWHT"
			elif ((RV % 3 == 0)); then put $r $c "·" "$GRY"
			else put $r $c "." "$BLU"; fi
		done
	done
}
art() { # art WIDTH HEIGHT -> ART rows of the current scene
	canvas "$1" "$2"
	SEED=$((7919 * (SCENE + 1)))
	((ART_W > 0 && ART_H > 0)) && "scene_${SCENES[SCENE]}"
	emit
}

scene_city() { # towers with lit windows under the stars, a few lights going on and off
	local W=$ART_W H=$ART_H
	local x=0 bw bh top body r c lit
	stars "$H" 23
	put $((H > 4)) $((W * 4 / 5)) "●" "$BYEL"
	while ((x < W)); do
		rnd; bw=$((3 + RV % 6))
		rnd; bh=$((H / 3 + RV % (H - H / 3 + 1)))
		((bh < 1)) && bh=1
		rnd; if ((RV % 2)); then top=$BLU body="$e[44m"; else top=$GRY body=$BGGRY; fi
		for ((c = x; c < x + bw && c < W; c++)); do
			put $((H - bh)) $c "▄" "$top"
			for ((r = H - bh + 1; r < H; r++)); do
				rnd; lit=0
				if (((c - x) % 2)); then
					((RV % 3 == 0)) && lit=1
					(((c * 31 + r * 17 + TICK) % 23 == 0)) && lit=$((!lit))
				fi
				if ((lit)); then put $r $c "▪" "$body$BYEL"; else put $r $c " " "$body"; fi
			done
		done
		rnd; x=$((x + bw + RV % 2))
	done
}

tri() { # tri X PERIOD AMPLITUDE -> TRI: a triangle wave from 0 up to AMPLITUDE and back
	local per=$2 x h
	((per < 2)) && per=2
	x=$((($1 % per + per) % per)) h=$((per / 2))
	TRI=$(((x < h ? x : per - x) * $3 / h))
}

ridge() { # ridge C -> HB HF: the far and near ridge heights at column C
	tri $(($1 + P1)) $((ART_W / 4 + 8)) $((ART_H * 3 / 5)); HB=$((ART_H / 4 + TRI))
	tri $(($1 + P2)) 9 1; HB=$((HB + TRI))
	((HB > ART_H - 1)) && HB=$((ART_H - 1))
	tri $(($1 + P3)) $((ART_W / 7 + 6)) $((ART_H / 4)); HF=$((1 + TRI))
}

scene_mountains() { # two ridges of peaks, snow on the high ones, a moon over them
	local W=$ART_W H=$ART_H
	local c r hb hf lb rb lf rf top
	rnd; P1=$((RV % 97)); rnd; P2=$((RV % 13)); rnd; P3=$((RV % 61))
	stars "$H" 19
	put 0 $((W / 6)) "●" "$BWHT"
	for ((c = 0; c < W; c++)); do
		ridge $((c - 1)); lb=$HB lf=$HF
		ridge $((c + 1)); rb=$HB rf=$HF
		ridge $c; hb=$HB hf=$HF
		# The top cell follows the slope: ▟ climbing, ▙ falling, ▲ a summit.
		if ((rb > hb && lb <= hb)); then top="▟"; elif ((lb > hb && rb <= hb)); then top="▙"
		elif ((lb < hb && rb < hb)); then top="▲"; else top="▄"; fi
		for ((r = H - hb; r < H; r++)); do
			if ((r == H - hb)); then
				if ((hb >= H * 2 / 3)); then put $r $c "$top" "$BWHT"; else put $r $c "$top" "$BBLU"; fi
			else
				put $r $c "▒" "$BBLU"
			fi
		done
		if ((rf > hf && lf <= hf)); then top="▟"; elif ((lf > hf && rf <= hf)); then top="▙"
		elif ((lf < hf && rf < hf)); then top="▲"; else top="▄"; fi
		for ((r = H - hf; r < H; r++)); do
			if ((r == H - hf)); then put $r $c "$top" "$BLU"; else put $r $c "█" "$BLU"; fi
		done
	done
}

scene_ocean() { # a moon on the horizon, its light trailing across moving water
	local W=$ART_W H=$ART_H
	local hz=$((H * 2 / 5)) mc=$((W * 7 / 10)) r c d waves=("~" "∼" "-" "≈" "~")
	((hz < 1)) && hz=1
	stars "$hz" 15
	put $((hz > 1 ? hz - 2 : 0)) $mc "●" "$BWHT"
	for ((c = 0; c < W; c++)); do put $hz $c "▁" "$BLU"; done
	for ((r = hz + 1; r < H; r++)); do
		for ((c = 0; c < W; c++)); do
			d=$((c > mc ? c - mc : mc - c))
			if ((d <= (r - hz) + 1 && (c + r + TICK) % 3)); then
				put $r $c "═" "$BYEL"
			else
				rnd
				((RV % 3)) && continue
				if (((r - hz) % 2)); then put $r $c "${waves[(c + r * 3 + TICK) % 5]}" "$BBLU"
				else put $r $c "${waves[(c + r * 3 + TICK) % 5]}" "$CYN"; fi
			fi
		done
	done
}

scene_space() { # a ringed planet, starfields and a comet crossing over time
	local W=$ART_W H=$ART_H
	local pr=$((H / 2)) pc=$((W / 4)) rad r c dx dy cx cr k tail=("=" "-" "-" "·" "·")
	rad=$((H * 2 / 5)); ((rad < 1)) && rad=1
	stars "$H" 11
	for ((r = pr - rad; r <= pr + rad; r++)); do
		for ((c = pc - 2 * rad; c <= pc + 2 * rad; c++)); do
			dx=$((c - pc)) dy=$(((r - pr) * 2))
			((dx * dx + dy * dy <= 4 * rad * rad)) || continue
			if ((dx < -rad / 2)); then put $r $c "█" "$BCYN"; elif ((dx < rad / 2)); then put $r $c "▓" "$CYN"; else put $r $c "▒" "$BLU"; fi
		done
	done
	for ((c = pc - 4 * rad; c <= pc + 4 * rad; c++)); do
		dx=$((c - pc)); ((dx < 0)) && dx=$((-dx))
		((dx > 2 * rad - 1)) && put $pr $c "─" "$BYEL"
	done
	cr=$((H / 4)) cx=$((TICK * 3 % (W + 12) - 6))
	put $cr $cx "*" "$BWHT"
	for ((k = 1; k <= 5; k++)); do
		if ((k <= 2)); then put $cr $((cx - k)) "${tail[k - 1]}" "$BCYN"; else put $cr $((cx - k)) "${tail[k - 1]}" "$BLU"; fi
	done
}

scene_circuit() { # traces turning corners, chips and blinking LEDs
	local W=$ART_W H=$ART_H
	local n k r c len vl i led
	n=$((W * H / 28 + 1))
	for ((k = 0; k < n; k++)); do
		rnd; r=$((RV % H)); rnd; c=$((RV % W)); rnd; len=$((3 + RV % 12)); rnd; vl=$((RV % (H / 2 + 1)))
		put $r $c "●" "$GRN"
		for ((i = 1; i < len; i++)); do put $r $((c + i)) "─" "$GRN"; done
		if ((vl)); then
			put $r $((c + len)) "┐" "$GRN"
			for ((i = 1; i < vl; i++)); do put $((r + i)) $((c + len)) "│" "$GRN"; done
		fi
		if (((k + TICK) % 4 == 0)); then led="$BRED"; else led="$BGRN"; fi
		put $((r + (vl ? vl : 0))) $((c + len)) "◆" "$led"
	done
	for ((k = 0; k < 2 && H >= 3; k++)); do
		rnd; r=$((1 + RV % (H - 2))); rnd; c=$((RV % W))
		for ((i = 0; i < 8; i++)); do
			put $((r - 1)) $((c + i)) "┬" "$GRY"
			put $r $((c + i)) "▓" "$GRY"
			put $((r + 1)) $((c + i)) "┴" "$GRY"
		done
	done
}

scene_rain() { # columns of falling code, bright at the head and fading behind
	local W=$ART_W H=$ART_H
	local g="01001101#%&*+=<>" c k r off len head
	for ((c = 0; c < W; c += 2)); do
		rnd; off=$((RV % (H * 2 + 1))); rnd; len=$((3 + RV % 7))
		head=$(((TICK * 2 + off) % (H + len)))
		for ((k = 0; k < len; k++)); do
			r=$((head - k))
			((r < 0 || r >= H)) && continue
			rnd
			if ((k == 0)); then put $r $c "${g:RV % ${#g}:1}" "$BWHT"
			elif ((k < 3)); then put $r $c "${g:RV % ${#g}:1}" "$BGRN"
			elif ((k < 5)); then put $r $c "${g:RV % ${#g}:1}" "$GRN"
			else put $r $c "${g:RV % ${#g}:1}" "$GRY"; fi
		done
	done
}

scene_grid() { # a striped sun setting behind a neon floor that runs to the horizon
	local W=$ART_W H=$ART_H
	local hz=$((H / 2)) cx=$((W / 2)) sr r c d dx dy k x col
	((hz < 1)) && hz=1
	sr=$hz; ((sr > W / 5)) && sr=$((W / 5)); ((sr < 1)) && sr=1
	stars "$hz" 21
	for ((r = hz - sr; r < hz; r++)); do
		dy=$(((hz - r) * 2))
		(((hz - r) <= sr / 2 && (hz - r) % 2 == 1)) && continue # the stripes
		if ((r < hz - sr * 2 / 3)); then col=$BYEL; elif ((r < hz - sr / 3)); then col=$BRED; else col=$BMAG; fi
		for ((c = cx - 2 * sr; c <= cx + 2 * sr; c++)); do
			dx=$((c - cx))
			((dx * dx + dy * dy <= 4 * sr * sr)) && put $r $c "█" "$col"
		done
	done
	for ((c = 0; c < W; c++)); do put $hz $c "─" "$BMAG"; done
	for ((r = hz + 1; r < H; r++)); do
		d=$((r - hz))
		if ((d == 1 || d == 3 || d == 6 || d == 10 || d == 15 || d == 21)); then
			for ((c = 0; c < W; c++)); do put $r $c "─" "$MAG"; done
		fi
		for ((k = -20; k <= 20; k++)); do
			x=$((cx + k * (d * 3 + 2)))
			if ((k < 0)); then put $r $x "/" "$BMAG"; elif ((k > 0)); then put $r $x "\\" "$BMAG"; else put $r $x "│" "$BMAG"; fi
		done
	done
}

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
	local i n=${#P_ID[@]} name key folder git cells mark wide=$((IW >= 100)) extra NW=15 FW=15
	# Spare width goes to the name and folder columns.
	if ((wide)); then
		extra=$((IW - 99))
		NW=$((15 + (extra / 2 > 14 ? 14 : extra / 2)))
		FW=$((15 + (extra - NW + 15 > 20 ? 20 : extra - NW + 15)))
	else
		extra=$((IW - 69))
		NW=$((15 + (extra > 14 ? 14 : extra)))
	fi
	# Built from the same widths as the rows below, so the columns line up.
	local hdr="$(fld ' #' 6)$(fld NAME $((NW + 1)))$(fld APP 10)$(fld STATE 18)"
	((wide)) && hdr+="$(fld FOLDER $((FW + 1)))$(fld GIT 14)"
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
		if ((i == SEL)); then cells+="$REV$BCYN$(fld "$name" "$NW")$R "; else cells+="$BWHT$(fld "$name" "$NW")$R "; fi
		if ((P_AGENT[i])); then cells+="$BCYN$(fld "${P_APP[i]}" 9)$R "; else cells+="$CYN$(fld "${P_APP[i]}" 9)$R "; fi
		cells+="$(state_cell "${P_STATE[i]}")"
		if ((wide)); then
			cells+="$BBLU$(fld "$folder" "$FW")$R "
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

	# Banner: block letters, a little CRT and the board's details. The big one when there's room.
	line "$FRAME╔$(rep ═ $((W - 2)))╗$R"
	local BH=3 total=0 BAN=()
	if ((lines - n >= 30)); then
		BH=6
		monitor "$w" "$a" "$s"
		local tag=("$BBLU░▒▓$R$B$BWHT T M U X $R$BBLU▓▒░$R" "$B${BCYN}C O N T R O L   P A N E L$R"
			"$GRY$(rep ─ 25)$R" "$GRY node   $BWHT$HOST$R" "$GRY time   $BWHT$(date '+%a %H:%M:%S')$R"
			"$GRY sysop  $BWHT${USER:-you}$GRY · $n panes · $s agents$R")
		for i in 0 1 2 3 4 5; do
			if ((IW >= 100)); then BAN[i]=" ${BIG_ROWS[i]}  ${MON[i]}   $(padv "${tag[i]}" 36)"; else BAN[i]=" ${BIG_ROWS[i]}  $(padv "${tag[i]}" 36)"; fi
		done
	else
		local tag=("$BBLU░▒▓$R$B$BWHT T M U X $R$BBLU▓▒░$R" "$B${BCYN}C O N T R O L   P A N E L$R" "$GRY node $BWHT$HOST$GRY · $(date +%H:%M:%S) · $n panes · $s agents$R")
		local shade=("$BCYN" "$CYN" "$BBLU")
		for i in 0 1 2; do BAN[i]="  ${shade[i]}$B${BANNER[i]}$R   $(padv "${tag[i]}" 60)"; done
	fi
	# Whatever width is left beside the banner shows the scene.
	vlen "${BAN[0]}"
	local tw=$((IW - VLEN - 1))
	if ((tw >= 8)); then
		art "$tw" "$BH"
		for ((i = 0; i < BH; i++)); do row "${BAN[i]} ${ART[i]}"; done
	else
		for ((i = 0; i < BH; i++)); do row "${BAN[i]}"; done
	fi
	counts="$BYEL$w working$R$GRY · $R$BMAG$a asking$R"
	((a)) && counts="$BYEL$w working$R$GRY · $R$B$BMAG$BLINK$a asking$R"
	sect "PANES"
	draw_panes
	# CPU across every pane, as a running graph.
	for i in "${P_CPU[@]}"; do total=$((total + i)); done
	CPU_HIST+=("$total")
	((${#CPU_HIST[@]} > 200)) && CPU_HIST=("${CPU_HIST[@]: -200}")
	vlen "$counts"
	row "$GRY cpu $R$(spark $((IW - 8 - VLEN)))  $counts"

	messages
	links_saves
	local bottom=$(( ${#MSG[@]} > ${#SIDE[@]} ? ${#MSG[@]} : ${#SIDE[@]} ))
	# Fixed rows: frame 2, banner, section bars 3, column header 1, totals 1, keys 1. The peek
	# takes up to 14 of the rest and the scene the remainder, so the panel fills its pane.
	avail=$((lines - BH - 8 - n - bottom))
	if ((PEEK && n && avail >= 4)); then
		peek_h=$((avail - 1 > 14 ? 14 : avail - 1))
		avail=$((avail - peek_h - 1))
		draw_peek "$peek_h"
	fi
	if ((avail >= 3)); then
		sect "ART · ${TITLES[SCENE]}"
		art "$IW" $((avail - 1))
		for l in "${ART[@]}"; do row "$l"; done
		avail=0
	fi
	for ((; avail > 0; avail--)); do row ""; done

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
	for c in "J:ump" "M:essage" "N:ame" "P:eek" "A:rt" "S:ave" "Q:uit"; do
		k+="$BBLU[$B$BYEL${c%%:*}$R$BBLU]$R$BWHT${c#*:}$R  "
	done
	k+="$GRY↑↓ or 1-9 select$R"
	if [[ -n $FLASH ]] && ((SECONDS - FLASH_T < 5)); then k="$BGBLU$B$BWHT $FLASH $R  $k"; fi
	line "$FRAME╠$(rep ═ $((W - 2)))╣$R"
	row "$k"
	local sig="$BLU▓▒░$R$GRY tmux-revive bbs · est. 2026 $R$BLU░▒▓$R"
	vlen "$sig"
	line "$FRAME╚$(rep ═ $((W - 4 - VLEN)))$R$sig$FRAME══╝$R"

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

ask() { # ask PROMPT -> REPLY on the bottom line. Enter accepts; Esc, Ctrl-C or an empty line backs out (returns 1)
	local rows cols k rest show room ok=1
	rows=$(tput lines 2>/dev/null || echo 40) cols=$(tput cols 2>/dev/null || echo 80)
	REPLY=""
	# Ctrl-C backs out of the prompt rather than closing the panel. Bash runs a trap but then
	# goes back to waiting in read, so read in short slices and check the flag between them.
	local INTR=0
	trap 'INTR=1' INT
	while :; do
		# Show the end of what's typed if it's longer than the line.
		room=$((cols - ${#1} - 26))
		((room < 10)) && room=10
		show=$REPLY
		((${#show} > room)) && show="…${show: -$((room - 1))}"
		printf '%s' "$e[${rows};1H$e[2K  $B$BYEL$1$R $show$GRY▏ Enter sends · Esc cancels$R$e[${rows};$((4 + ${#1} + ${#show}))H$e[?25h"
		k=""
		until IFS= read -rsn1 -t 0.2 k; do
			# Over 128 is the timeout slice; anything else means the input closed.
			(($? <= 128 || INTR)) && { k=CANCEL; break; }
			k=""
		done
		case $k in
		CANCEL) ok=0; break ;;                       # Ctrl-C
		$'\e')
			# A lone Esc backs out; an arrow or other key sequence is just ignored.
			rest=""
			IFS= read -rsn1 -t 0.05 rest || true
			[[ -z $rest ]] && { ok=0; break; }
			IFS= read -rsn4 -t 0.02 _ || true ;;
		"") break ;;                                # Enter
		$'\x7f' | $'\b') REPLY=${REPLY%?} ;;          # Backspace
		$'\x15') REPLY="" ;;                         # Ctrl-U clears the line
		[[:cntrl:]]) ;;
		*) REPLY+=$k ;;
		esac
	done
	trap 'exit 0' INT
	printf '%s' "$e[?25l$e[${rows};1H$e[2K"
	((ok)) && [[ -n $REPLY ]] && return 0
	REPLY=""
	return 1
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
		ask "Message to $name:" || { flash "message cancelled"; return; }
		out=$("$ASAY" --from panel "$id" "$REPLY" 2>&1 | tail -n 1)
		flash "${out#agent-say: }" ;;
	n | N)
		[[ -n $id ]] || return
		ask "New name for $name:" || { flash "rename cancelled"; return; }
		out=$(AGENT_SAY_PANE=$id "$ASAY" name "$REPLY" 2>&1 | head -n 1)
		flash "${out#agent-say: }" ;;
	p | P) PEEK=$((!PEEK)) ;;
	a | A)
		SCENE=$(((SCENE + 1) % ${#SCENES[@]}))
		flash "art: ${TITLES[SCENE]}" ;;
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

# Dial-up welcome, the first time the panel opens on a tmux server (REVIVE_PANEL_SPLASH=1
# always shows it, 0 never). Any key skips it. Returns 1 once skipped.
splash() {
	local rows cols top left i c t
	rows=$(tput lines 2>/dev/null || echo 30) cols=$(tput cols 2>/dev/null || echo 80)
	top=$(((rows - 13) / 2)) left=$(((cols - 44) / 2))
	((top < 1)) && top=1
	((left < 1)) && left=1
	printf '%s' "$e[2J"
	for i in 0 1 2 3 4 5; do printf '%s' "$e[$((top + i));${left}H${BIG_ROWS[i]}"; done
	pause() { ! IFS= read -rsn1 -t "$1" _; }
	typed() { # typed ROW COLOUR TEXT: one character at a time, like a slow modem
		printf '%s' "$e[$1;${left}H$2"
		for ((c = 0; c < ${#3}; c++)); do printf '%s' "${3:c:1}"; pause 0.02 || return 1; done
		printf '%s' "$R"
	}
	t=$((top + 8))
	typed $t "$GRY" "ATDT 1-800-REVIVE" && pause 0.3 &&
		typed $((t + 1)) "$GRY" "RINGING..." && pause 0.4 &&
		typed $((t + 2)) "$B$BGRN" "CONNECT 33600/ARQ/V.42bis" && pause 0.25 &&
		typed $((t + 4)) "$B$BCYN" "Welcome to the tmux-revive BBS, ${USER:-friend}!" && pause 0.9
	printf '%s' "$e[2J"
}

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
case ${REVIVE_PANEL_SPLASH:-} in
1) splash ;;
0) ;;
*) [[ $(opt @revive-panel-splashed '') == 1 ]] || { splash; tm set-option -g @revive-panel-splashed 1 2>/dev/null; } ;;
esac

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
