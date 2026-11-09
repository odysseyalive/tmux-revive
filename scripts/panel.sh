#!/usr/bin/env bash
# tmux-revive panel: a live, BBS-style control panel for every pane. It shows what each pane
# runs, whether an agent is working, waiting on you or asking a question, its CPU, memory and
# git state, with agent-say messages, links and saves underneath. Keys act on the selected pane.
#
#   panel.sh            run it (redraws every couple of seconds)
#   panel.sh --once     draw one frame to stdout and exit (tests, a quick look)
#   panel.sh --rows     this computer's panes as rows for another computer's panel (over a link)
#   panel.sh --peek %ID N   the last N lines of that pane's screen, for another computer's peek
#   panel.sh --keys %ID KEY...   keys for a question on that pane, sent from another computer's panel
#   panel.sh --show %ID  retired: changes nothing, and fails (an older computer's J asked for it)
#   panel.sh --asking   the panes whose agent is asking a question now: id, place, name (daemon.sh)
#
# REVIVE_PANEL_POPUP=1 (set by @revive-panel-key) closes the panel after a jump, since a popup
# would otherwise sit on top of the pane you jumped to.
set -uo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=help.sh
source "$(dirname "${BASH_SOURCE[0]}")/help.sh" # the ? page

# Everything it keeps (other computers' rows and screens) is for this user only. common.sh sets
# this too; it's said again here because the cache holds what's on other computers' screens.
umask 077

ONCE=0 ROWS=0 PEEKMODE=0 KEYSMODE=0 SHOWMODE=0 ASKMODE=0
[[ ${1:-} == --once ]] && ONCE=1
[[ ${1:-} == --rows ]] && ROWS=1
[[ ${1:-} == --asking ]] && ASKMODE=1
if [[ ${1:-} == --peek ]]; then
	# Asked for by another computer: nothing but a pane id and a line count gets through.
	[[ ${2:-} =~ ^%[0-9]+$ && ${3:-} =~ ^[1-9][0-9]?$ ]] && (($3 <= 60)) ||
		{ echo "usage: panel.sh --peek %PANE LINES (1-60)" >&2; exit 2; }
	PEEKMODE=1 PEEK_ID=$2 PEEK_N=$3
fi
# --keys is checked key by key once key_ok is defined, before anything is sent.
[[ ${1:-} == --keys ]] && KEYSMODE=1
[[ ${1:-} == --show ]] && SHOWMODE=1

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
# This tmux-revive's version (the installer puts VERSION next to it), or nothing if unknown.
# Linked computers report theirs in --rows, and one older than this is shown out of date.
VER_RE='^[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}$'
VERSION=$(head -n 1 "${REVIVE_VERSION_FILE:-$REVIVE_ROOT/VERSION}" 2>/dev/null | head -c 32)
[[ $VERSION =~ $VER_RE ]] || VERSION=""
ver_lt() { # ver_lt A B: is version A older than B?
	local -a a b
	local i
	IFS=. read -ra a <<<"$1"
	IFS=. read -ra b <<<"$2"
	for i in 0 1 2; do
		((10#${a[i]} < 10#${b[i]})) && return 0
		((10#${a[i]} > 10#${b[i]})) && return 1
	done
	return 1
}

# ------------------------------------------------------------------ colours
e=$'\e'
R="$e[0m" B="$e[1m" DIM="$e[2m" BLINK="$e[5m" REV="$e[7m"
BLU="$e[34m" BBLU="$e[94m" CYN="$e[36m" BCYN="$e[96m" MAG="$e[35m" BMAG="$e[95m"
YEL="$e[33m" BYEL="$e[93m" GRN="$e[32m" BGRN="$e[92m" BRED="$e[91m" BWHT="$e[97m" GRY="$e[90m"
BGBLU="$e[44m"
FRAME="$BLU"

# ------------------------------------------------------------------ drawing
# The helpers a frame is built from leave their result in a variable named after them (REP,
# FLD, PADV...) rather than printing it: a $( ) costs a fork, and a frame took hundreds.
rep() { printf -v REP '%*s' "$2" ''; REP=${REP// /$1}; } # rep CHAR N -> REP
fld() { # fld TEXT WIDTH -> FLD: plain text cut or padded to exactly WIDTH characters
	local s=${1:0:$2}
	printf -v FLD '%s%*s' "$s" $(($2 - ${#s})) ''
}
vlen() { # visible length of a string holding colour codes -> VLEN
	local s=$1
	while [[ $s =~ $e\[[0-9\;]*m ]]; do s=${s//"${BASH_REMATCH[0]}"/}; done
	VLEN=${#s}
}
padv() { # padv TEXT WIDTH -> PADV: a coloured string padded (or cut) to WIDTH visible characters
	vlen "$1"
	if ((VLEN > $2)); then trim_colored "$1" "$2"; PADV=$TRIM; else printf -v PADV '%s%*s' "$1" $(($2 - VLEN)) ''; fi
}
# Folder and pane names, process names, mail from linked machines and ssh errors can carry
# escape sequences (an OSC 52 clipboard write, a faked screen). clean drops C0, DEL and C1
# controls from the named variables, so only the panel's own colour codes reach the terminal.
# Bidi overrides and zero-width characters go too (U+200B-200F, U+202A-202E, U+2066-2069):
# they would make a name read differently from what it is, or hide text in plain sight.
C1="" ZW=""
for i in {128..159}; do printf -v c '\\xc2\\x%x' "$i"; printf -v c "$c"; C1+=$c; done # UTF-8 bytes
for c in 80{8b,8c,8d,8e,8f,aa,ab,ac,ad,ae} 81{a6,a7,a8,a9}; do printf -v c '\\xe2\\x%s\\x%s' "${c:0:2}" "${c:2}"; printf -v c "$c"; ZW+=$c; done
clean() { # clean VAR...
	local -n _v
	for _v; do _v=${_v//[[:cntrl:]]/} _v=${_v//[$C1]/} _v=${_v//[$ZW]/}; done
}
OUT=()
line() { OUT+=("$1"); }
row() { # row CONTENT [WIDTH]: one line inside the frame, cut or padded to the inner width.
	# A row whose visible width is known already (the artwork, a peek line) says so, and isn't
	# measured again: measuring a row of many colours is most of what drawing it costs.
	local c=$1 pad
	if [[ -n ${2:-} ]]; then VLEN=$2; else vlen "$c"; fi
	((VLEN > IW)) && { trim_colored "$c" "$IW"; c=$TRIM VLEN=$IW; }
	printf -v pad '%*s' $((IW - VLEN)) ''
	line "$FRAME║$R $c$pad $FRAME║$R"
}
# A section title on a solid blue band that fades into the black on both sides: shading as
# a short transition between two colours, the way the artpack groups used it.
# A question waiting on you gets the band in magenta, the colour of the asking state.
tab() { local c=${2:-4}; TAB="$e[3${c}m░▒▓$e[4${c}m$B$BWHT $1 $R$e[3${c}m▓▒░$R"; } # tab TITLE [COLOUR 0-7] -> TAB
sectk() { # sectk TITLE KEYS [COLOUR]: a divider with a title, and the keys for that section at its right end
	local t a
	tab "$1" "${3:-4}"
	t="$FRAME╠═$TAB"
	vlen "$t"; a=$VLEN
	vlen "$2"
	rep ═ $((W - 5 - a - VLEN))
	line "$t$FRAME$REP$R $2 $FRAME══╣$R"
}
sect() { # sect TITLE [RIGHT-TITLE SPLIT-AT]: a divider carrying section titles
	local t
	tab "$1"
	t="$FRAME╠═$TAB"
	if [[ -n ${2:-} ]]; then
		vlen "$t"
		rep ═ $(($3 + 2 - VLEN))
		tab "$2"
		t+="$FRAME$REP╤═$TAB"
	fi
	vlen "$t"
	rep ═ $((W - 1 - VLEN))
	line "$t$FRAME$REP╣$R"
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
	[H]="██  ██|██  ██|██████|██  ██|██  ██" [L]="██    |██    |██    |██    |██████"
	[P]="█████▄|██   █|█████▀|██    |██    "
)
big_banner() { # big_banner WORD [COLOUR x5] -> BIG_ROWS[0..5]: a colour for each row, top down
	local w=$1 i r c ch up cur out parts
	shift
	local -a G=("" "" "" "" "") shade=("$B$BWHT" "$B$BCYN" "$B$BCYN" "$CYN" "$BBLU")
	(($#)) && shade=("$@")
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
	fld " $OSP$cur" 11
	cur=$FLD
	fld " $msg" 11
	MON=(
		"$g▄▄▄▄▄▄▄▄▄▄▄▄▄$R"
		"$g█$R$BGRN$cur$R$g█$R"
		"$g█$R$col$FLD$R$g█$R"
		"$g▀▀▀▀▀▀▀▀▀▀▀▀▀$R"
		"$g     ▄█▄     $R"
		"$g  ▀▀▀▀▀▀▀▀▀  $R"
	)
}

spark() { # spark WIDTH -> SPARK: CPU history as a ▁▂▃▅▇ graph, newest on the right
	local w=$1 i v max=10 lvl out="" bars=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
	local -a h=("${CPU_HIST[@]: -$w}")
	for v in "${h[@]}"; do ((v > max)) && max=$v; done
	for ((i = ${#h[@]}; i < w; i++)); do out+="$GRY▁"; done
	for v in "${h[@]}"; do
		lvl=$((v * 7 / max))
		if ((lvl <= 1)); then out+="$BLU"; elif ((lvl <= 3)); then out+="$BBLU"; elif ((lvl <= 5)); then out+="$BCYN"; else out+="$BYEL"; fi
		out+=${bars[lvl]}
	done
	SPARK=$out$R
}
CPU_HIST=()

# ------------------------------------------------------------------ artwork
# Scenes drawn to whatever space is free, so the panel fills its pane at any size. One is
# picked at random when the panel opens (REVIVE_PANEL_ART=<name> picks one), A cycles them.
# Each scene moves in two or three places at most, so the panel stays calm to look at.
SCENES=(city mountains space circuit grid)
TITLES=("night city" "mountains" "deep space" "circuit board" "neon grid")
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
stars() { # stars ROWS ONE-IN-N: sky dust in the top ROWS rows, holding still
	local r c
	for ((r = 0; r < $1; r++)); do
		for ((c = 0; c < ART_W; c++)); do
			rnd
			((RV % $2)) && continue
			if ((RV / 7 % 9 == 0)); then put $r $c "*" "$BWHT"
			elif ((RV % 3 == 0)); then put $r $c "·" "$GRY"
			else put $r $c "." "$BLU"; fi
		done
	done
}
twinkle() { # twinkle N ROWS: N stars in the top ROWS rows that take turns shining
	local k r c
	for ((k = 0; k < $1; k++)); do
		rnd; r=$((RV % ($2 > 0 ? $2 : 1))); rnd; c=$((RV % ART_W))
		if (((AT + k) % 2)); then put $r $c "*" "$BWHT"; else put $r $c "·" "$GRY"; fi
	done
}
declare -A ART_MEMO=()
art() { # art WIDTH HEIGHT [still] -> ART rows of the current scene; "still" stops its animation
	local k rows
	if [[ ${3:-} == still ]]; then AT=0; else AT=$TICK; fi
	# The same frame again (a redraw that only moved the selection) is kept, not redrawn.
	k="$SCENE $1 $2 $AT"
	if [[ -n ${ART_MEMO[$k]+set} ]]; then mapfile -t ART <<<"${ART_MEMO[$k]}"; return; fi
	canvas "$1" "$2"
	SEED=$((7919 * (SCENE + 1)))
	((ART_W > 0 && ART_H > 0)) && "scene_${SCENES[SCENE]}"
	emit
	((${#ART_MEMO[@]} > 6)) && ART_MEMO=()
	printf -v rows '%s\n' "${ART[@]}"
	ART_MEMO[$k]=${rows%$'\n'}
}

scene_city() { # towers with lit windows under the stars; one star and two windows change
	local W=$ART_W H=$ART_H
	local x=0 bw bh top body r c lit k i
	local -a wr=() wc=() wb=()
	stars "$H" 23
	twinkle 1 $((H / 2))
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
					wr+=("$r") wc+=("$c") wb+=("$body")
				fi
				if ((lit)); then put $r $c "▪" "$body$BYEL"; else put $r $c " " "$body"; fi
			done
		done
		rnd; x=$((x + bw + RV % 2))
	done
	# Two windows somewhere in town, one light on while the other is off.
	for ((k = 0; k < 2 && ${#wr[@]}; k++)); do
		rnd; i=$((RV % ${#wr[@]}))
		if (((AT + k) % 2)); then put "${wr[i]}" "${wc[i]}" "▪" "${wb[i]}$BYEL"; else put "${wr[i]}" "${wc[i]}" " " "${wb[i]}"; fi
	done
}

tri() { # tri X PERIOD AMPLITUDE -> TRI: a triangle wave from 0 up to AMPLITUDE and back
	local per=$2 x h
	((per < 2)) && per=2
	x=$((($1 % per + per) % per)) h=$((per / 2))
	TRI=$(((x < h ? x : per - x) * $3 / h))
}

# Pixel art at twice the height: each cell is two pixels, a ▀ in the top one's colour over the
# bottom one's. Colours are the 16 ANSI ones (0-15); -1 is empty sky, left for the stars.
pixel_cell() { # pixel_cell ROW COL TOP BOTTOM
	local t=$3 b=$4 tf bb
	((t < 0 && b < 0)) && return
	tf=$((t < 8 ? 30 + t : 82 + t)) bb=$((b < 8 ? 40 + b : 92 + b))
	if ((t == b)); then put "$1" "$2" " " "$e[${bb}m"
	elif ((t < 0)); then put "$1" "$2" "▄" "$e[$((b < 8 ? 30 + b : 82 + b))m"
	elif ((b < 0)); then put "$1" "$2" "▀" "$e[${tf}m"
	else put "$1" "$2" "▀" "$e[${tf};${bb}m"; fi
}

scene_mountains() { # a snow-capped range under the moon, dark wooded hills in front
	local W=$ART_W H=$ART_H
	local PH=$((H * 2)) c r k k2 n v jag=0 win=-1 top bot P
	local -a pk=() ph=() ps=() far=() near=() tree=() snow=() back=() lit=()
	stars "$H" 19
	twinkle 2 $((H / 3))
	rnd; put 0 $((W / 8 + RV % (W * 3 / 4 + 1))) "●" "$BWHT"
	# The range: two to four big peaks, each a rough cone, roughened a little column by column.
	rnd; n=$((2 + RV % 3))
	for ((k = 0; k < n; k++)); do
		rnd; pk+=($((k * W / n + RV % (W / n + 1))))
		rnd; ph+=($((PH * 55 / 100 + RV % (PH * 35 / 100 + 1))))
		rnd; ps+=($((6 + RV % 6))) # tenths of a pixel down per column: steep, not cliffs
	done
	rnd; P=$((RV % 97))
	for ((c = 0; c < W; c++)); do
		# The peak standing tallest here decides the light: the side toward the moon (left of
		# its summit) is lit, the other side in shadow.
		v=0 k=0
		for ((k2 = 0; k2 < n; k2++)); do
			r=$((ph[k2] - (c > pk[k2] ? c - pk[k2] : pk[k2] - c) * ps[k2] / 10))
			((r > v)) && v=$r k=$k2
		done
		lit+=($((c <= pk[k])))
		# A dim range further back, for distance.
		tri $((c + P * 3)) $((W / 4 + 9)) $((PH / 7)); back+=($((PH * 3 / 10 + TRI)))
		rnd; jag=$((jag + RV % 3 - 1)); ((jag > 2)) && jag=2; ((jag < -2)) && jag=-2
		v=$((v + jag)); ((v > PH - 1)) && v=$((PH - 1)); ((v < 2)) && v=2
		far+=("$v")
		rnd; snow+=($((2 + RV % 3)))
		# Wooded hills in front, and the ragged tops of their trees.
		tri $((c + P)) $((W / 3 + 5)) $((PH / 8)); v=$((PH / 7 + TRI))
		near+=("$v")
		rnd; tree+=($((v + RV % 3)))
	done
	rnd; ((W > 20)) && win=$((W / 5 + RV % (W * 3 / 5)))
	for ((r = 0; r < H; r++)); do
		for ((c = 0; c < W; c++)); do
			mpix $((PH - 1 - 2 * r)) $c; top=$MP
			mpix $((PH - 2 - 2 * r)) $c; bot=$MP
			pixel_cell $r $c $top $bot
		done
	done
}
mpix() { # mpix HEIGHT COL -> MP: the colour of that pixel of the mountain scene
	local y=$1 c=$2
	if ((y < near[c])); then
		if ((c == win && y == near[c] - 3)); then MP=11; else MP=2; fi # one lit window
	elif ((y < tree[c])); then MP=2
	elif ((y < far[c])); then
		# Snow on the high peaks; moonlit side bright, shadow side dim.
		if ((far[c] - y <= snow[c] && far[c] > PH * 6 / 10)); then
			((lit[c])) && MP=15 || MP=7
		else
			((lit[c])) && MP=12 || MP=4
		fi
	elif ((y < back[c])); then MP=8
	else MP=-1; fi
}

scene_space() { # a ringed planet, starfields and a comet crossing over time
	local W=$ART_W H=$ART_H
	local pr=$((H / 2)) pc=$((W / 4)) rad r c dx dy cx cr k tail=("=" "-" "-" "·" "·")
	rad=$((H * 2 / 5)); ((rad < 1)) && rad=1
	stars "$H" 11
	twinkle 2 "$H"
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
	cr=$((H / 4)) cx=$((AT * 3 % (W + 12) - 6))
	put $cr $cx "*" "$BWHT"
	for ((k = 1; k <= 5; k++)); do
		if ((k <= 2)); then put $cr $((cx - k)) "${tail[k - 1]}" "$BCYN"; else put $cr $((cx - k)) "${tail[k - 1]}" "$BLU"; fi
	done
}

scene_circuit() { # traces turning corners, chips and three blinking LEDs
	local W=$ART_W H=$ART_H
	local n k r c len vl i blink=0
	local -a lr=() lc=()
	n=$((W * H / 28 + 1))
	for ((k = 0; k < n; k++)); do
		rnd; r=$((RV % H)); rnd; c=$((RV % W)); rnd; len=$((3 + RV % 12)); rnd; vl=$((RV % (H / 2 + 1)))
		put $r $c "●" "$GRN"
		for ((i = 1; i < len; i++)); do put $r $((c + i)) "─" "$GRN"; done
		if ((vl)); then
			put $r $((c + len)) "┐" "$GRN"
			for ((i = 1; i < vl; i++)); do put $((r + i)) $((c + len)) "│" "$GRN"; done
		fi
		put $((r + (vl ? vl : 0))) $((c + len)) "●" "$BGRN"
		lr+=($((r + (vl ? vl : 0)))) lc+=($((c + len)))
	done
	for ((k = 0; k < 2 && H >= 3; k++)); do
		rnd; r=$((1 + RV % (H - 2))); rnd; c=$((RV % W))
		for ((i = 0; i < 8; i++)); do
			put $((r - 1)) $((c + i)) "┬" "$GRY"
			put $r $((c + i)) "▓" "$GRY"
			put $((r + 1)) $((c + i)) "┴" "$GRY"
		done
	done
	# Three LEDs that ended up on the board blink; the rest stay lit.
	for ((k = 0; k < ${#lr[@]} && blink < 3; k++)); do
		r=${lr[k]} c=${lc[k]}
		((r >= 0 && r < H && c >= 0 && c < W)) || continue
		if (((blink + AT) % 2)); then put $r $c "●" "$BGRN"; else put $r $c "●" "$BRED"; fi
		((blink++))
	done
}


cloud() { # cloud ROW COL WIDTH COLOUR: a thin streak, puffs along its top, flat underneath
	local i
	for ((i = 0; i < $3; i++)); do
		rnd
		((i > 1 && i < $3 - 2 && RV % 3)) && put "$1" $(($2 + i)) "▄" "$4"
		put $(($1 + 1)) $(($2 + i)) "▀" "$4"
	done
}

scene_grid() { # a striped sun setting behind a neon floor, streaks of cloud in a dusk sky
	local W=$ART_W H=$ART_H
	local hz=$((H / 2)) cx=$((W / 2)) sr r c d dx dy k x col
	((hz < 1)) && hz=1
	sr=$hz; ((sr > W / 5)) && sr=$((W / 5)); ((sr < 1)) && sr=1
	# Clouds first, so the sun sits in front of them and its stripes stay whole. The first
	# two drift slowly, as a whole; the rest hold still. Near the sun they catch its light.
	local n k cr cc cw ccol
	n=$((W / 25 + 2))
	for ((k = 0; k < n && hz >= 3; k++)); do
		rnd; cr=$((RV % (hz - 2))); rnd; cw=$((8 + RV % 14)); rnd; cc=$((RV % (W + cw) - cw))
		((k < 2)) && cc=$(((cc + AT / 2 + cw) % (W + cw) - cw)) # a column every other frame
		dx=$((cc + cw / 2 - cx)); ((dx < 0)) && dx=$((-dx))
		if ((dx < 3 * sr)); then ccol=$BMAG; elif ((dx < 6 * sr)); then ccol=$MAG; else ccol=$GRY; fi
		cloud "$cr" "$cc" "$cw" "$ccol"
	done
	for ((r = hz - sr; r < hz; r++)); do
		dy=$(((hz - r) * 2))
		if ((r < hz - sr * 2 / 3)); then col=$BYEL; elif ((r < hz - sr / 3)); then col=$BRED; else col=$BMAG; fi
		# The stripes are gaps in the sun, cleared so nothing behind shows through them.
		# The row on the horizon is never a gap, so the sun sits on it; a sun too small for
		# stripes (the banner's) has none.
		((sr >= 4 && hz - r >= 2 && (hz - r) <= sr / 2 + 1 && (hz - r) % 2 == 0)) && col=""
		for ((c = cx - 2 * sr; c <= cx + 2 * sr; c++)); do
			dx=$((c - cx))
			((dx * dx + dy * dy <= 4 * sr * sr)) || continue
			if [[ -n $col ]]; then put $r $c "█" "$col"; else put $r $c " " ""; fi
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

meter() { # meter PERCENT -> METER: five shaded cells, retro style
	local p=${1%.*} out="" i lvl
	p=${p:-0}
	for ((i = 0; i < 5; i++)); do
		lvl=$((p - i * 20))
		if ((lvl >= 20)); then out+="█"; elif ((lvl >= 13)); then out+="▓"; elif ((lvl >= 7)); then out+="▒"; elif ((lvl > 0)); then out+="░"; else out+="·"; fi
	done
	METER=$out
}
human() { # KB -> HUMAN: 412M / 1.2G
	local k=$1
	if ((k >= 1048576)); then printf -v HUMAN '%d.%dG' $((k / 1048576)) $((k % 1048576 * 10 / 1048576))
	elif ((k >= 1024)); then printf -v HUMAN '%dM' $((k / 1024))
	else printf -v HUMAN '%dK' "$k"; fi
}

# ------------------------------------------------------------------ gathering
declare -A PCHILD PARGS PRSS PCPU PPAR PUID INPANE TICKS_PREV GIT GIT_T
X_SSH=() X_WHERE=()
T_PREV=""
SHELLS=" sh bash zsh fish dash ksh tcsh csh nu "
# An agent asking you something: a permission prompt or a multiple-choice question.
Q_RE='do you want to|would you like to|allow (once|always)|\(y/n\)|\[y/n\]|enter to select|esc to cancel|trust (this|the) folder|yes, proceed|press enter to continue'
W_RE='esc to interrupt|ctrl\+c to interrupt'
# The line a question's dialog starts under: a horizontal rule, or the top of a box.

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

claude_record() { # claude_record PID -> RECORD: Claude Code's session record for it, or nothing
	local f
	RECORD=""
	for f in "$HOME"/.claude*/sessions/"$1".json ${CLAUDE_CONFIG_DIR:+"$CLAUDE_CONFIG_DIR/sessions/$1.json"}; do
		[[ -f $f ]] && { RECORD=$f; return; }
	done
}
# Claude Code's record says idle between turns even while agents it started in the background
# (the Agent tool's run_in_background, background shells) go on working, and it has no field
# that says so. Their output files do: each is under its temp folder, as
# claude-UID/<its folder>/<sessionId>/tasks/*.output, and grows while it runs (an agent's is a
# link to its transcript). Written to within REVIVE_BG_SECS (20) means work in the background.
# An agent inside one long command writes nothing for as long as it runs, though. Every command
# Claude Code runs (its own, its agents', a background shell's) is started under it as
# `zsh -c source ~/.claude/shell-snapshots/snapshot-…` (or bash): one still running under it is
# work in the background too, however long it takes. Its other children (MCP servers, the
# status line, hooks) aren't started that way and don't count.
BG_SECS=${REVIVE_BG_SECS:-20}
snapshot_cmd() { # snapshot_cmd PID: a command Claude Code started still runs under PID (from gather's ps)
	local p
	local -a q=()
	# shellcheck disable=SC2206
	q=(${PCHILD[$1]:-})
	while ((${#q[@]})); do
		p=${q[0]} q=("${q[@]:1}")
		[[ ${PARGS[$p]:-} == *" source "*/shell-snapshots/snapshot-* ]] && return 0
		# shellcheck disable=SC2206
		[[ -n ${PCHILD[$p]:-} ]] && q+=(${PCHILD[$p]})
	done
	return 1
}
claude_look() { # claude_look PID -> CST: its record's status (busy/idle/waiting) or nothing; CBG=1: background work
	local sid t m=0 d
	local -a f=() roots=()
	CST="" CBG=0
	claude_record "$1"
	[[ -n $RECORD ]] || return 0
	IFS=$'\t' read -r CST sid < <(jq -r '[.status // "", .sessionId // ""] | @tsv' "$RECORD" 2>/dev/null)
	# "shell": its turn is over but a background shell it started still runs. That's work in
	# the background, the same as idle with a command still running under it.
	[[ $CST == shell ]] && { CST=idle CBG=1; return 0; }
	# Only idle: "waiting" is a dialog of its own open, which needs you whatever else runs.
	[[ $CST == idle ]] || return 0
	snapshot_cmd "$1" && { CBG=1; return 0; }
	[[ $sid =~ ^[A-Za-z0-9-]+$ ]] || return 0
	# Where its temp folder is: CLAUDE_CODE_TMPDIR, else the system's (TMPDIR, else /tmp).
	for d in ${CLAUDE_CODE_TMPDIR:+"${CLAUDE_CODE_TMPDIR%/}"} ${TMPDIR:+"${TMPDIR%/}"} /tmp; do
		[[ " ${roots[*]} " == *" $d "* ]] || roots+=("$d")
	done
	for d in "${roots[@]}"; do
		for t in "$d"/claude-"$UID"/*/"$sid"/tasks/*.output; do [[ -e $t ]] && f+=("$t"); done
	done
	((${#f[@]})) || return 0
	# One stat for them all, through the links.
	while read -r t; do
		[[ $t =~ ^[0-9]+$ ]] && ((t > m)) && m=$t
	done < <(stat -L -c %Y "${f[@]}" 2>/dev/null || stat -L -f %m "${f[@]}" 2>/dev/null)
	((m && ${EPOCHSECONDS:-$(date +%s)} - m <= BG_SECS)) && CBG=1
	return 0
}

# ------------------------------------------------------------------ context left
# How much of an agent's context window is still free, as a percentage, read from the
# record the agent itself keeps of its session: Claude Code's transcript (the session record
# under sessions/PID.json names it), Codex's rollout file (the file its process holds open).
# Each holds the tokens the last turn sent; Codex also says its window (Claude Code's is
# worked out in common.sh). A Claude Code session also reports its own, from a hook
# (scripts/claude-hook.sh ctx, through agent-say _ctx): that comes first, since the panel may
# be another user than the agent, as over a link to a server where agents run as root.
declare -A CTX_STAMP=() CTX_VAL=()
CTX=""
fstamp() { stat -c '%s.%Y' "$1" 2>/dev/null || stat -f '%z.%m' "$1" 2>/dev/null; }
ctx_cached() { # ctx_cached FILE FUNC: CTX=FUNC FILE's answer, worked out again only when FILE changes
	local st
	st=$(fstamp "$1")
	[[ -n $st ]] || return 0
	if [[ ${CTX_STAMP[$1]:-} != "$st" ]]; then CTX_VAL[$1]=$("$2" "$1") CTX_STAMP[$1]=$st; fi
	CTX=${CTX_VAL[$1]}
}
codex_ctx_file() { # a rollout file -> percent left
	local u w
	read -r u w < <(tail -c 2000000 "$1" 2>/dev/null | grep '"token_count"' |
		jq -Rr 'fromjson? | .payload | select(.type == "token_count" and .info)
			| "\(.info.last_token_usage.total_tokens) \(.info.model_context_window)"' 2>/dev/null | tail -n 1)
	ctx_pct "${u:-}" "${w:-}"
}
# Claude Code with no session record to be found (an older Claude Code, or one whose config
# is somewhere this panel's environment doesn't say, as over a link's ssh): its transcript is
# looked for from the process itself. Its config folder from its own environment; the session
# from the folder it keeps open under the temporary claude-UID/ (named for the session), or
# failing that, the newest transcript for its working folder written since it started, if no
# other Claude Code works there. Looked for again every 30 s (a /clear starts a new session).
declare -A CL_TR=() CL_TR_T=()
UUID_RE='/claude-[0-9]+/[^/]+/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(/|$)'
claude_transcript() { # claude_transcript PID -> TRANSCRIPT, or nothing
	local pid=$1 e d f sid="" cwd slug p c n=0
	local -a dirs=()
	TRANSCRIPT=""
	if [[ -n ${CL_TR_T[$pid]:-} ]] && ((SECONDS - CL_TR_T[$pid] < 30)); then
		[[ -f ${CL_TR[$pid]} ]] && TRANSCRIPT=${CL_TR[$pid]}
		return 0
	fi
	CL_TR[$pid]="" CL_TR_T[$pid]=$SECONDS
	[[ -d /proc/$pid ]] || return 0 # Linux: macOS keeps no such files to read
	while IFS= read -r -d '' e; do
		case $e in
		CLAUDE_CONFIG_DIR=/*) dirs=("${e#*=}" "${dirs[@]}") ;;
		HOME=/*) dirs+=("${e#*=}/.claude") ;;
		esac
	done <"/proc/$pid/environ" 2>/dev/null
	dirs+=("$HOME"/.claude ${CLAUDE_CONFIG_DIR:+"$CLAUDE_CONFIG_DIR"})
	while IFS= read -r f; do
		[[ $f =~ $UUID_RE ]] && { sid=${BASH_REMATCH[1]}; break; }
	done < <(find "/proc/$pid/fd" -maxdepth 1 -lname '*/claude-*' -printf '%l\n' 2>/dev/null)
	if [[ -n $sid ]]; then
		for d in "${dirs[@]}"; do
			for f in "$d"/projects/*/"$sid".jsonl; do
				[[ -f $f ]] && { CL_TR[$pid]=$f TRANSCRIPT=$f; return 0; }
			done
		done
		return 0
	fi
	cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null)
	[[ -n $cwd ]] || return 0
	# Another Claude Code in the same folder could own the newest transcript there.
	for p in "${!PARGS[@]}"; do
		[[ $p == "$pid" ]] && continue
		case " ${PARGS[$p]} " in *app-server*) continue ;; */claude\ * | " claude "* | *" claude --"*) ;; *) continue ;; esac
		c=$(readlink "/proc/$p/cwd" 2>/dev/null)
		[[ $c == "$cwd" ]] && return 0
	done
	slug=${cwd//[^A-Za-z0-9]/-}
	f=""
	for d in "${dirs[@]}"; do
		for p in "$d/projects/$slug"/*.jsonl; do
			[[ -f $p && $p -nt /proc/$pid ]] || continue
			[[ -z $f || $p -nt $f ]] && f=$p
			((n++))
		done
		[[ -n $f ]] && break
	done
	# Only one written since it started; with more, which is its own can't be told.
	((n == 1)) && CL_TR[$pid]=$f TRANSCRIPT=$f
	return 0
}
# ctx_reported PANE AGENT_PID [SESSION] -> CTX: what the Claude Code in PANE last reported,
# if it was that process (and that session, when known) and within REVIVE_CTX_TTL (600 s).
ctx_reported() {
	local f=$ASTATE/ctx/${1#%} id sid pct at pid
	[[ -f $f ]] || return 0
	read -r id sid pct at pid _ <"$f" 2>/dev/null || return 0
	[[ $id == "$1" && $pid == "$2" && $pct =~ ^[0-9]{1,3}$ && $at =~ ^[0-9]+$ ]] && ((pct <= 100)) || return 0
	[[ -z ${3:-} || $sid == "$3" ]] || return 0
	((${EPOCHSECONDS:-$(date +%s)} - at <= ${REVIVE_CTX_TTL:-600})) && CTX=$pct
	return 0
}
ctx_left() { # ctx_left KIND AGENT_PID PANE PID... -> CTX: percent of its context window left, or nothing
	local kind=$1 apid=$2 pane=$3 f sid p
	shift 3
	CTX="" # set here, not printed: the files' answers are kept between frames
	case $kind in
	claude)
		claude_record "$apid"
		sid=""
		[[ -n $RECORD ]] && sid=$(jq -r '.sessionId // empty' "$RECORD" 2>/dev/null)
		ctx_reported "$pane" "$apid" "$sid"
		[[ -n $CTX ]] && return 0
		if [[ -z $RECORD ]]; then
			claude_transcript "$apid"
			[[ -n $TRANSCRIPT ]] && ctx_cached "$TRANSCRIPT" claude_ctx_file
			return 0
		fi
		[[ $sid =~ ^[A-Za-z0-9-]+$ ]] || return 0
		for f in "${RECORD%/sessions/*}"/projects/*/"$sid".jsonl; do
			[[ -f $f ]] && { ctx_cached "$f" claude_ctx_file; return 0; }
		done ;;
	codex)
		for p in "$@"; do
			while IFS= read -r f; do
				[[ $f == */sessions/*/rollout-*.jsonl && -f $f ]] && { ctx_cached "$f" codex_ctx_file; return 0; }
			done < <(open_files "$p")
		done ;;
	esac
}

screen_state() { # screen_state PANE -> asking / working / waiting, read off the bottom of the screen
	local -a SL
	mapfile -t SL < <(tm capture-pane -p -t "$1" 2>/dev/null)
	lines_state SL
	echo "$LSTATE"
}
lines_state() { # lines_state ARRAY -> LSTATE: the same, for a screen already read (a linked computer's peek)
	local -n L=$1
	local n=0 i tail="" prompt=0
	for ((i = ${#L[@]} - 1; i >= 0 && n < 12; i--)); do
		[[ ${L[i]} =~ ^[[:space:]]*$ ]] && continue
		((n++))
		tail+="${L[i]}"$'\n'
		# The agent's own input prompt near the bottom: it is waiting for you, not asking.
		if ((n <= 6)) && [[ ${L[i]//$'\xc2\xa0'/ } =~ ^(❯|›|\>)\ ? ]] && ! [[ ${L[i]} =~ ^(❯|›|\>)[[:space:]]+[0-9]+\. ]]; then prompt=1; fi
	done
	shopt -s nocasematch
	if ((!prompt)) && [[ $tail =~ $Q_RE ]]; then LSTATE=asking
	elif [[ $tail =~ $W_RE ]]; then LSTATE=working
	else LSTATE=waiting; fi
	shopt -u nocasematch
}

# git in a pane's folder, which may be anyone's repo: its config must not get to run a
# command (core.fsmonitor, hooks), and the panel must not take the index lock from you.
pgit() { GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor= -c core.hooksPath=/dev/null --no-optional-locks -C "$@"; }
git_info() { # git_info DIR -> "branch" or "branch*" (uncommitted changes), cached 15 s
	local d=$1 b dirty filters
	if [[ -n ${GIT_T[$d]:-} ]] && ((SECONDS - GIT_T[$d] < 15)); then printf '%s' "${GIT[$d]}"; return; fi
	b=$(pgit "$d" symbolic-ref --short -q HEAD 2>/dev/null || pgit "$d" rev-parse --short HEAD 2>/dev/null)
	if [[ -n $b ]]; then
		# A clean/process filter would run while status rehashes files. Yours (global, system,
		# git-lfs) are trusted; one the repo sets itself means no dirty check there.
		filters=$(pgit "$d" config --show-scope --get-regexp '^filter\..*\.(clean|process)$' 2>/dev/null |
			grep -v $'^\\(global\\|system\\)\t')
		if [[ -z $filters ]]; then
			dirty=$(pgit "$d" status --porcelain -uno 2>/dev/null | head -c1)
			[[ -n $dirty ]] && b+="*"
		fi
	fi
	clean b
	GIT[$d]=$b GIT_T[$d]=$SECONDS
	printf '%s' "$b"
}

tree_ticks() { # tree_ticks PID...: CPU ticks used so far by these processes (Linux)
	# Their children's that have ended count too (cutime, cstime), so a command an agent ran
	# between two looks still shows, where it would drop out of the tree uncounted.
	local p l f t=0
	for p in "$@"; do
		read -r l 2>/dev/null <"/proc/$p/stat" || continue # gone since ps ran
		read -ra f <<<"${l##*) }"
		t=$((t + f[11] + f[12] + f[13] + f[14]))
	done
	echo "$t"
}

# One record per pane, in these parallel arrays. P_RID is a linked computer's own pane id,
# P_WP the pane's window.pane as tmux's status bar numbers it (empty when not known). P_USER is
# the user its agent (or the program it runs) runs as, empty when not known; P_INST whether that
# user has tmux-revive: "owner" (it's the tmux owner's own), a version, or empty (none known).
P_ID=() P_LOC=() P_NAME=() P_APP=() P_STATE=() P_DIR=() P_GIT=() P_CPU=() P_MEM=() P_CTX=() P_AGENT=() P_SSH=() P_HOST=() P_RID=() P_WP=() P_USER=() P_INST=()
ME=$(id -un 2>/dev/null)
USER_RE='^[A-Za-z_][A-Za-z0-9_.-]{0,31}$'
declare -A UNAMES=()
user_of() { # user_of UID -> UNAME: its user name (the number if it has none)
	local n
	if [[ -z ${UNAMES[$1]+x} ]]; then
		n=$(getent passwd "$1" 2>/dev/null | cut -d: -f1)
		[[ -n $n ]] || n=$(id -un "$1" 2>/dev/null)
		[[ $n =~ $USER_RE ]] || n=$1
		UNAMES[$1]=$n
	fi
	UNAME=${UNAMES[$1]}
}
# user_inst NAME -> INST: as P_INST. Another user's install inside this tmux leaves its version
# here (agent-say _user-installed), since their home can't be looked in.
user_inst() {
	local v=""
	INST=owner
	[[ $1 == "$ME" ]] && return 0
	INST=""
	[[ $1 =~ $USER_RE && -f $ASTATE/users/$1 ]] && read -r v <"$ASTATE/users/$1" 2>/dev/null
	[[ $v =~ $VER_RE ]] && INST=$v
	return 0
}
P_GROUPS=0
# ssh_dest ARGS -> the host an `ssh ...` command line connects to, as agent-say link takes it
# (no user@, no port), or nothing. Options that take a value are skipped with their value.
ssh_dest() {
	local -a a
	local i d
	read -ra a <<<"$1"
	[[ ${a[0]##*/} == ssh ]] || return 0
	for ((i = 1; i < ${#a[@]}; i++)); do
		case ${a[i]} in
		-[BbcDEeFIiJLlmOoPpQRSWw]) ((i++)) ;;
		-*) ;;
		*)
			d=${a[i]#ssh://} d=${d##*@} d=${d%%:*}
			[[ $d =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && printf '%s' "$d"
			return 0 ;;
		esac
	done
}
linked() { [[ -f $ASTATE/links/$1/on ]]; }
gather() {
	local pid ppid rss pcpu args id loc ppid0 cmd path name kind apid st q p tree cpu mem now dt t ssh ctx k
	local -A tnow=()
	PCHILD=() PARGS=() PRSS=() PCPU=() PPAR=() PUID=() INPANE=()
	while read -r pid ppid uid rss pcpu args; do
		PCHILD[$ppid]+="$pid " PARGS[$pid]=$args PRSS[$pid]=$rss PCPU[$pid]=$pcpu PPAR[$pid]=$ppid PUID[$pid]=$uid
	done < <(ps -ww -eo pid=,ppid=,uid=,rss=,pcpu=,args= 2>/dev/null) # -ww: never cut to $COLUMNS
	now=${EPOCHREALTIME:-$SECONDS}
	P_ID=() P_LOC=() P_NAME=() P_APP=() P_STATE=() P_DIR=() P_GIT=() P_CPU=() P_MEM=() P_CTX=() P_AGENT=() P_SSH=() P_HOST=() P_RID=() P_WP=() P_USER=() P_INST=()
	while IFS=$'\t' read -r id loc ppid0 cmd path name; do
		clean loc cmd path name
		# The pane's process tree, breadth-first, and the first agent in it.
		tree=() q=("$ppid0") kind="" apid=""
		while ((${#q[@]})); do
			p=${q[0]} q=("${q[@]:1}")
			tree+=("$p") INPANE[$p]=1
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
			# Kept by pane and its process: a pane id tmux gives out again is another pane.
			if [[ -n $T_PREV && -n ${TICKS_PREV[$id:$ppid0]:-} ]]; then
				dt=$(awk -v a="$now" -v b="$T_PREV" 'BEGIN{printf "%.3f", a-b}')
				cpu=$(awk -v d=$((t - TICKS_PREV[$id:$ppid0])) -v c="$CLK" -v s="$dt" 'BEGIN{v = s > 0 ? d / c / s * 100 : 0; if (v < 0) v = 0; printf "%d", v + 0.5}')
			fi
			tnow[$id:$ppid0]=$t
		else
			cpu=0
			for p in "${tree[@]}"; do cpu=$(awk -v a="$cpu" -v b="${PCPU[$p]:-0}" 'BEGIN{printf "%d", a + b + 0.5}'); done
		fi
		ctx=""
		if [[ $id == "${TMUX_PANE:-}" ]]; then
			st=self P_APP+=("panel") P_AGENT+=(0)
		elif [[ -n $kind ]]; then
			st=$(screen_state "$id")
			# Claude Code's record says for itself whether it is busy, and outranks the screen.
			# With nothing in it to go by (no record found for this process, or one with no
			# status), the screen decides, as it does for the other agents. Idle while work it
			# started goes on in the background is working, but takes input.
			if [[ $kind == claude && $st != asking ]]; then
				claude_look "$apid"
				case $CST in busy) st=working ;; "") ;; *) st=waiting; ((CBG)) && st=agents ;; esac
			fi
			ctx_left "$kind" "$apid" "$id" "${tree[@]}"
			ctx=$CTX
			P_APP+=("$kind") P_AGENT+=(1)
		elif [[ $SHELLS == *" ${cmd#-} "* ]]; then
			st=shell P_APP+=("${cmd#-}") P_AGENT+=(0)
		else
			st=program P_APP+=("$cmd") P_AGENT+=(0)
		fi
		# An ssh connection in a pane without an agent: a host its agents could be linked to.
		ssh=""
		if [[ $st == program ]]; then
			for p in "${tree[@]}"; do
				ssh=$(ssh_dest "${PARGS[$p]:-}")
				[[ -n $ssh ]] && break
			done
		fi
		# window.pane from the place: tmux allows no : or . in a session name.
		# Whose it is: its agent's user, else the deepest process in it (root's shell after sudo -i).
		p=${apid:-${tree[${#tree[@]} - 1]}}
		UNAME=""
		[[ -n ${PUID[$p]:-} ]] && user_of "${PUID[$p]}"
		user_inst "$UNAME"
		P_SSH+=("$ssh") P_HOST+=("") P_RID+=("") P_WP+=("${loc##*:}") P_USER+=("$UNAME") P_INST+=("$INST")
		P_ID+=("$id") P_LOC+=("$loc") P_NAME+=("$name") P_STATE+=("$st")
		P_DIR+=("$path") P_GIT+=("$(git_info "$path")") P_CPU+=("$cpu") P_MEM+=("$mem") P_CTX+=("$ctx")
	done < <(tm list-panes -a -F $'#{pane_id}\t#{session_name}:#{window_index}.#{pane_index}\t#{pane_pid}\t#{pane_current_command}\t#{pane_current_path}\t#{@agent}' 2>/dev/null)
	# Only the panes there now: a closed pane's count goes with it.
	TICKS_PREV=()
	for k in "${!tnow[@]}"; do TICKS_PREV[$k]=${tnow[$k]}; done
	T_PREV=$now
	outside_ssh
	((ROWS)) || remote_panes
}

# The CPU counts --rows keeps between asks: the time of its look, then a "%pane:pid ticks" line
# for each pane. Used only when that time is from 1 to 60 s ago by this computer's clock.
rows_ticks_load() { # rows_ticks_load FILE -> T_PREV, TICKS_PREV
	local now=${EPOCHREALTIME:-} t="" k v age
	T_PREV="" TICKS_PREV=()
	[[ -n $now && -f $1 ]] || return 0
	{
		read -r t
		while read -r k v; do
			[[ $k =~ ^%[0-9]{1,9}:[0-9]{1,10}$ && $v =~ ^[0-9]{1,15}$ ]] && TICKS_PREV[$k]=$v
		done
	} <"$1" 2>/dev/null
	[[ $t =~ ^[0-9]{1,12}[.,][0-9]+$ ]] || { TICKS_PREV=(); return 0; }
	age=$((${now%[.,]*} - ${t%[.,]*}))
	if ((age >= 1 && age <= 60)); then T_PREV=$t; else TICKS_PREV=(); fi
}
rows_ticks_save() { # rows_ticks_save FILE: through a temporary file, as two asks may overlap
	local t k
	[[ -n ${EPOCHREALTIME:-} ]] || return 0
	cache_dir
	t=$(mktemp "$1.XXXXXX" 2>/dev/null) || return 0
	{
		printf '%s\n' "$T_PREV"
		for k in "${!TICKS_PREV[@]}"; do printf '%s %s\n' "$k" "${TICKS_PREV[$k]}"; done
	} >"$t" && mv -f "$t" "$1"
}

# ------------------------------------------------------------------ other computers
# Panes on linked computers: each link's other end is asked for its panel rows over the
# link's own ssh connection, in the background every 10 s so the panel never waits on it.
# Rows from there are treated as untrusted: cleaned, and every field checked. If that
# computer's tmux-revive is too old to answer, or it can't be reached, its pane names (which
# the link already keeps) are shown instead.
RDIR="$ASTATE/panel"
REMOTE_ROWS_CMD='PATH="$HOME/.local/bin:$PATH" tmux-revive panel --rows'
REMOTE_PEEK_CMD='PATH="$HOME/.local/bin:$PATH" tmux-revive panel --peek'
REMOTE_KEYS_CMD='PATH="$HOME/.local/bin:$PATH" tmux-revive panel --keys'
# A fixed command line: nothing from this panel or that computer goes into it.
REMOTE_UPDATE_CMD='PATH="$HOME/.local/bin:$PATH" tmux-revive update </dev/null 2>&1'
# agent-say name there, for the pane AGENT_SAY_PANE gives. The pane id and the name are
# checked before they go into the command line, and agent-say checks the name again there.
REMOTE_NAME_CMD='PATH="$HOME/.local/bin:$PATH" agent-say name'
declare -A RFETCH_T=() RFETCH_PID=() PFETCH_T=() PFETCH_PID=() PEEK_FILES=() RVER=() ROWNER=()
PEEK_EVERY=$REFRESH # seconds between asks for a linked pane's screen; none while answering
cache_dir() { # $RDIR, for this user only (an older panel made it with the default umask)
	[[ -d $RDIR ]] || mkdir -p "$RDIR"
	[[ -n $(find "$RDIR" -maxdepth 0 -perm 700 2>/dev/null) ]] || chmod 700 "$RDIR" 2>/dev/null
}
remote_run() { # remote_run HOST COMMAND: run it on that computer over the link's ssh connection
	# The same socket as agent-say's link (its CONTROL), so a login opened for the link (a host
	# that wants a password) carries these too. While the link waits for one, nothing is tried:
	# each try would be a refused login in that host's log.
	[[ -f $ASTATE/links/$1/login ]] && return 255
	# Bound to the host key you confirmed for the link, as agent-say's own calls are: ssh checks
	# it against the link's pin, whatever the ssh config says. agent-say _pin checks it afresh
	# on every call (a key revoked since, the fingerprint changed) and rebuilds it as needed; a
	# link it refuses gets nothing sent.
	local l=$ASTATE/links/$1 pin=() p
	if [[ -s $l/fingerprint ]]; then
		p=$(timeout 20 "$ASAY" _pin "$1" </dev/null 2>/dev/null) && [[ -s $p ]] || return 255
		pin=(-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$p" -o GlobalKnownHostsFile=/dev/null
			-o HostKeyAlias=agent-say-confirmed -o CheckHostIP=no -o UpdateHostKeys=no)
	fi
	# shellcheck disable=SC2086 # AGENT_SAY_SSH may carry its own arguments, as in agent-say
	timeout "${RTIMEOUT:-8}" ${AGENT_SAY_SSH:-ssh} -o BatchMode=yes -o ConnectTimeout=5 -o ControlMaster=auto \
		-o "ControlPath=$ASTATE/ssh-%C" -o ControlPersist=120 "${pin[@]}" "$1" "$2" </dev/null 2>/dev/null
}
fetch_rows() { remote_run "$1" "$REMOTE_ROWS_CMD"; }
# rows_get HOST FILE: the rows into FILE, through a temporary file of its own (two panels may
# be asking at once). Capped in bytes: one endless line from over there must not freeze this.
rows_get() {
	local t st
	t=$(mktemp "$2.XXXXXX") || return
	fetch_rows "$1" | head -c 262144 >"$t"
	st=${PIPESTATUS[0]}
	if ((st == 0 || st == 141)); then mv -f "$t" "$2"; return; fi # 141: cut off by head
	rm -f "$t"
}
remote_fetch() { # remote_fetch HOST [now]
	local h=$1 f="$RDIR/$1.rows"
	cache_dir
	if [[ ${2:-} == now ]]; then rows_get "$h" "$f"; return; fi
	[[ -n ${RFETCH_PID[$h]:-} ]] && kill -0 "${RFETCH_PID[$h]}" 2>/dev/null && return
	[[ -n ${RFETCH_T[$h]:-} ]] && ((SECONDS - RFETCH_T[$h] < 10)) && return
	RFETCH_T[$h]=$SECONDS
	rows_get "$h" "$f" &
	RFETCH_PID[$h]=$!
}
# The peek at a pane on a linked computer: its screen, asked for like the rows (in the
# background, no more than once a refresh) and kept in $RDIR/HOST.peek-ID. A failed ask
# (unreachable, or a tmux-revive there too old to answer) leaves HOST.peek-ID.fail instead.
peek_get() { # peek_get HOST %ID LINES FILE
	local st t
	# The id and count are checked before they go into a command line run over there.
	[[ $2 =~ ^%[0-9]+$ && $3 =~ ^[0-9]{1,2}$ ]] || return 1
	t=$(mktemp "$4.XXXXXX") || return 1
	PEEK_TMP=$t # for peek_drop
	remote_run "$1" "$REMOTE_PEEK_CMD '$2' $3" | head -c 65536 >"$t"
	st=${PIPESTATUS[0]}
	if ((st == 0 || st == 141)); then # 141: more than head would take, cut off
		mv -f "$t" "$4"; rm -f "$4.fail"
	else
		rm -f "$t" "$4"; : >"$4.fail"
	fi
}
peek_fetch() { # peek_fetch HOST %ID LINES FILE [now]
	local k="$1 $2"
	cache_dir
	PEEK_FILES[$4]=1
	if [[ ${5:-} == now ]]; then peek_get "$1" "$2" "$3" "$4"; return; fi
	[[ -n ${PFETCH_PID[$k]:-} ]] && kill -0 "${PFETCH_PID[$k]}" 2>/dev/null && return
	[[ -n ${PFETCH_T[$k]:-} ]] && ((SECONDS - PFETCH_T[$k] < PEEK_EVERY)) && return
	PFETCH_T[$k]=$SECONDS
	# Told to stop (peek_drop), or hung up on (the panel quit), it still finishes asking (a trap
	# waits for that), then throws the screen away instead of putting it in place.
	(
		trap 'rm -f "${PEEK_TMP:-}"; exit 0' TERM HUP
		peek_get "$1" "$2" "$3" "$4"
	) &
	PFETCH_PID[$k]=$!
}
# peek_drop HOST %ID: a key was just sent there, so the screen being asked for now (asked
# before the key landed) is out of date. It's dropped and the next look asks again at once;
# waiting for it and only then asking left the choice a whole ask behind the keys.
peek_drop() {
	local k="$1 $2"
	[[ -n ${PFETCH_PID[$k]:-} ]] && kill "${PFETCH_PID[$k]}" 2>/dev/null
	PFETCH_PID[$k]="" PFETCH_T[$k]=""
}
remote_peek() { # remote_peek LINES -> L: the selected linked pane's screen, or why it can't be shown
	local h=${P_HOST[SEL]} id=${P_RID[SEL]:-} n=$1 f l
	L=("" "  on $h: no peek (update tmux-revive there)")
	[[ ${P_STATE[SEL]:-} == unreachable ]] && L=("" "  on $h: can't be reached to peek")
	[[ ${P_STATE[SEL]:-} == login ]] && L=("" "  on $h: needs login · press L to type its password")
	[[ $h =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $id =~ ^%[0-9]+$ ]] || return 0
	((n > 60)) && n=60
	f="$RDIR/$h.peek-${id#%}"
	if ((ONCE)); then peek_fetch "$h" "$id" "$n" "$f" now; else peek_fetch "$h" "$id" "$n" "$f"; fi
	if [[ -f $f && -n $(find "$f" -mmin -1 2>/dev/null) ]]; then
		# Untrusted like the rows: control characters out, and only so many lines, so wide.
		L=()
		while IFS= read -r l || [[ -n $l ]]; do
			clean l
			L+=("${l:0:500}")
		done < <(tail -n "$n" "$f")
	elif [[ ! -e $f.fail ]]; then
		L=("" "  on $h: asking for its screen...")
	fi
}
remote_panes() {
	local d h f id loc name app st folder git cpu mem agent got v wp lg S=$'\x1f'
	local -A rctx rbg ruser rinst
	P_GROUPS=0
	# Other computers' screens are kept no longer than they're shown: a minute at most. So are
	# the temporary files of an ask cut off by the panel closing.
	[[ -d $RDIR ]] && find "$RDIR" -maxdepth 1 \( -name '*.peek-*' -o -name '*.answered-*' -o -name '*.rows.??????' \) -mmin +1 -delete 2>/dev/null
	for d in "$ASTATE"/links/*/; do
		[[ -f $d/on ]] || continue
		h=$(basename "$d")
		[[ $h =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
		# A link waiting for its login (press L) shows its names, marked so, and isn't asked.
		lg=0
		[[ -f $d/login ]] && lg=1
		if ((lg)); then :; elif ((ONCE)); then remote_fetch "$h" now; else remote_fetch "$h"; fi
		f="$RDIR/$h.rows" got=0 RVER[$h]="" ROWNER[$h]="" rctx=() rbg=() ruser=() rinst=()
		# Rows a minute old or newer; older means that computer stopped answering.
		if ((!lg)) && [[ -s $f && -n $(find "$f" -mmin -1 2>/dev/null) ]]; then
			while IFS=$S read -r id loc name app st folder git cpu mem agent; do
				# Its version, on a line of its own (an older panel's check below skips it).
				if [[ ${id:0:40} =~ ^\#version\ (.*)$ && -z $loc ]]; then
					v=${BASH_REMATCH[1]}
					[[ $v =~ $VER_RE ]] && RVER[$h]=$v
					continue
				fi
				# A pane's context left, on a line of its own before its row (for the same reason).
				if [[ ${id:0:40} =~ ^\#ctx\ (%[0-9]{1,9})\ ([0-9]{1,3})$ && -z $loc ]]; then
					((BASH_REMATCH[2] <= 100)) && rctx[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
					continue
				fi
				# A pane at its prompt while its work goes on in the background, likewise: its row
				# says working (a panel from before this read waiting there), and this line that it
				# takes input.
				if [[ ${id:0:40} =~ ^\#agents\ (%[0-9]{1,9})$ && -z $loc ]]; then
					rbg[${BASH_REMATCH[1]}]=1
					continue
				fi
				# Whose tmux it is, and whose each pane is, with whether that user has tmux-revive
				# there (owner, a version, or -), likewise.
				if [[ ${id:0:40} =~ ^\#owner\ ([A-Za-z_][A-Za-z0-9_.-]{0,31})$ && -z $loc ]]; then
					ROWNER[$h]=${BASH_REMATCH[1]}
					continue
				fi
				if [[ ${id:0:80} =~ ^\#user\ (%[0-9]{1,9})\ ([A-Za-z_][A-Za-z0-9_.-]{0,31})\ (owner|-|[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9})$ && -z $loc ]]; then
					ruser[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]} rinst[${BASH_REMATCH[1]}]=${BASH_REMATCH[3]#-}
					continue
				fi
				# Only a complete row from a pane: a %id first and the agent flag last.
				[[ $id =~ ^%[0-9]+$ && $agent =~ ^[01]$ ]] || continue
				# Cut before cleaning, so a huge field costs nothing to look at.
				loc=${loc:0:64} name=${name:0:64} app=${app:0:64} st=${st:0:16} folder=${folder:0:256} git=${git:0:128}
				clean loc name app st folder git
				[[ $name =~ ^[A-Za-z0-9][A-Za-z0-9_.:+=-]*$ ]] || name=""
				case $st in asking | working | waiting | agents | shell | program) ;; *) st=program ;; esac
				[[ $st =~ ^(waiting|working)$ && -n ${rbg[$id]:-} ]] && st=agents
				[[ $st == asking && $f -ot $RDIR/$h.answered-${id#%} ]] && st=waiting # answered from here since
				[[ $cpu =~ ^[0-9]{1,4}$ ]] || cpu=0
				[[ $mem =~ ^[0-9]{1,10}$ ]] || mem=0
				[[ $agent == 1 ]] || agent=0
				# Its window.pane there, from its whole place (P_LOC keeps only 20 characters of it).
				wp=${loc##*:}
				[[ $wp =~ ^[0-9]{1,4}\.[0-9]{1,4}$ ]] || wp=""
				P_ID+=("${name:+$name@$h}") P_LOC+=("${loc:0:20}") P_NAME+=("$name") P_APP+=("${app:0:12}")
				P_STATE+=("$st") P_DIR+=("${folder:0:40}") P_GIT+=("${git:0:30}") P_CPU+=("$cpu") P_MEM+=("$mem")
				P_CTX+=("${rctx[$id]:-}") P_AGENT+=("$agent") P_SSH+=("") P_HOST+=("$h") P_RID+=("$id") P_WP+=("$wp")
				P_USER+=("${ruser[$id]:-}") P_INST+=("${rinst[$id]:-}")
				got=1
			done < <(head -n 200 "$f")
		fi
		if ((!got)); then
			# Names only, from the link.
			st=linked
			[[ -s $f || ! -s $d/error ]] || st=unreachable
			((lg)) && st=login
			while IFS= read -r name; do
				[[ $name =~ ^[A-Za-z0-9][A-Za-z0-9_.:+=-]*$ ]] || continue
				P_ID+=("$name@$h") P_LOC+=("") P_NAME+=("$name") P_APP+=("") P_STATE+=("$st") P_DIR+=("")
				P_GIT+=("") P_CPU+=(0) P_MEM+=(0) P_CTX+=("") P_AGENT+=(0) P_SSH+=("") P_HOST+=("$h") P_RID+=("") P_WP+=("")
				P_USER+=("") P_INST+=("")
				got=1
			done < <(head -c 65536 "$d/names" 2>/dev/null | head -n 200)
		fi
		((got)) && ((P_GROUPS++))
	done
	# A heading for this computer too, once there's more than one.
	((P_GROUPS)) && ((P_GROUPS++))
}

# ssh sessions in terminals outside tmux (a kitty tab, another window): their hosts can be
# linked too. Only someone's own interactive ssh counts: not the ones git, scp, sftp or
# rsync start for themselves, and not agent-say's own link connections. Only your own ssh:
# anyone on this computer can start a process whose command line says "ssh evil.example".
outside_ssh() {
	local pid a h up where c
	X_SSH=() X_WHERE=()
	for pid in "${!PARGS[@]}"; do
		[[ -n ${INPANE[$pid]:-} || ${PUID[$pid]:-} != "$UID" ]] && continue
		a=${PARGS[$pid]}
		h=$(ssh_dest "$a")
		[[ -n $h ]] || continue
		[[ $a == *BatchMode=yes* || $a == *agent-say* || $a == *git-upload-pack* || $a == *git-receive-pack* ||
			$a == *"rsync --server"* || $a == *" -s "* || $a == *sftp* ]] && continue
		c=${PARGS[${PPAR[$pid]:-0}]:-}
		c=${c%% *} c=${c##*/}
		[[ $c == git || $c == scp || $c == sftp || $c == rsync ]] && continue
		# Where it runs: the first ancestor that isn't a shell (kitty, alacritty, sshd...).
		up=${PPAR[$pid]:-0} where=""
		while ((up > 1)); do
			c=${PARGS[$up]:-}
			c=${c%% *} c=${c##*/} c=${c#-}
			[[ $SHELLS == *" $c "* ]] || { where=$c; break; }
			up=${PPAR[$up]:-0}
		done
		clean where
		X_SSH+=("$h") X_WHERE+=("${where:-a terminal}")
	done
}

# ------------------------------------------------------------------ sections
SEL=0 SEL_ID="" PEEK=${REVIVE_PANEL_PEEK:-1} FULL=0 ANSWERING=0 FLASH="" FLASH_T=0 TICK=0
# nav: this frame only moves the selection. Then the messages, links and saves (MSG, SIDE) are
# kept from the last frame, unless MSG_OLD says they're due a look (new panes were gathered,
# or they were hidden). TCOLS and TLINES: the terminal's size, asked again with the panes.
nav=0 MSG=() SIDE=() MSG_OLD=1 TCOLS="" TLINES=""
# While answering: the rows above the question kept from its first frame (ATOP, the banner's
# height ATOP_BH), and the pane's screen as answer() last read it (QL cleaned for drawing,
# QRAW as it came, QSHOT the same as one string).
ATOP=() ATOP_BH=3 QL=() QRAW=() QSHOT=""
SPIN=(▖ ▘ ▝ ▗)

state_cell() { # state_cell STATE -> CELL: coloured status, 18 characters wide
	case $1 in
	asking) CELL="$B$BMAG$BLINK?$R$B$BMAG NEEDS ANSWER    $R" ;;
	grant) CELL="$B$BMAG$BLINK⚑ [G]RANT ACCESS$R  " ;; # its agent waits for access (G)
	working) CELL="$BYEL${SPIN[TICK % 4]} WORKING         $R" ;;
	waiting) CELL="$BGRN◆ WAITING ON YOU  $R" ;;
	# Idle at its prompt while its work goes on in the background: working all the same (its
	# peek says it takes input).
	agents) CELL="$BYEL${SPIN[TICK % 4]} WORKING         $R" ;;
	shell) CELL="$GRY· shell           $R" ;;
	self) CELL="$BBLU✦ this panel      $R" ;;
	linked) CELL="$GRY◌ linked          $R" ;;
	unreachable) CELL="$BRED◌ unreachable     $R" ;;
	login) CELL="$BYEL◌ needs login · L $R" ;;
	*) CELL="$CYN▸ running         $R" ;;
	esac
}

draw_panes() {
	local i n=${#P_ID[@]} name key folder git cells mark wide=1 NW=10 FW=10 GW v KW=3 pad UW=4 VW=3 us=1 extra
	# Who waits for access (G): each introduction's sender, as NAME@HOST.
	local gw=" " st d f
	for d in "$ASTATE"/intros/*/; do [[ -f $d/from ]] && read -r f <"$d/from" && gw+="$f "; done
	local -a lab=() nm=() ver=()
	local -A ses=() many=()
	# An unnamed pane's NAME is a dim ---: the # column already says where it is. Unless its
	# computer has more than one tmux session, when [0.0] alone could be any of them: then its
	# session's name. So first, which computers (this one is @) have more than one.
	for ((i = 0; i < n; i++)); do
		[[ -n ${P_LOC[i]} ]] || continue
		v=${P_LOC[i]%%:*} key=@${P_HOST[i]}
		[[ -z ${ses[$key]+x} ]] && ses[$key]=$v
		[[ ${ses[$key]} == "$v" ]] || many[$key]=1
	done
	# Worked out again on every frame, so a resized terminal gets them too. The name and folder
	# are as wide as their longest (10 to 29 and 10 to 35), USER and VER too (4 to 10, 3 to 11)
	# with a space after each; GIT has the rest of the row, so
	# CTX LEFT ends at the panel's right edge. The rest of the row is fixed: the # cell (its
	# widest label, the mark and two spaces: 6 for [1]), APP 10, STATE 18, CPU and MEM 19,
	# CTX LEFT 12, and a space after the name, folder and GIT.
	# The # label: the pane's window.pane (3.1), or where that isn't known (a linked computer
	# that only gave its pane names) the row's count, 1 to 9.
	for ((i = 0; i < n; i++)); do
		if [[ -n ${P_NAME[i]} ]]; then nm[i]=${P_NAME[i]}
		elif [[ -n ${P_LOC[i]} && -n ${many[@${P_HOST[i]}]:-} ]]; then nm[i]=${P_LOC[i]%%:*}
		else nm[i]=---; fi
		name=${nm[i]} folder=${P_DIR[i]/#$HOME/\~} folder=${folder##*/}
		((${#name} > NW)) && NW=${#name}
		((${#folder} > FW)) && FW=${#folder}
		if [[ -n ${P_WP[i]:-} ]]; then lab[i]=${P_WP[i]}; elif ((i < 9)); then lab[i]=$((i + 1)); else lab[i]=""; fi
		((${#lab[i]} + 2 > KW)) && KW=$((${#lab[i]} + 2))
		# VER: the row's user's tmux-revive, or [V] when that user has none (V installs it). A
		# linked computer whose rows say nothing of whose tmux it is has a tmux-revive from before
		# users: [V] there too, as V updates it.
		v=${P_INST[i]:-}
		if [[ $v == owner ]]; then
			v=$VERSION
			[[ -n ${P_HOST[i]} ]] && { v=${RVER[${P_HOST[i]}]:-}; [[ $v =~ $VER_RE ]] || v=""; }
		elif [[ -z $v && -n ${P_USER[i]:-} ]]; then v="[V]"
		elif [[ -n ${P_HOST[i]} && -n ${P_RID[i]:-} && -z ${ROWNER[${P_HOST[i]}]:-} ]]; then v="[V]"; fi
		ver[i]=$v
		((${#v} > VW)) && VW=${#v}
		((${#P_USER[i]} > UW)) && UW=${#P_USER[i]}
	done
	((NW > 29)) && NW=29
	((FW > 35)) && FW=35
	((UW > 10)) && UW=10
	((VW > 11)) && VW=11
	# USER and VER, and a space after each.
	extra=$((UW + VW + 2))
	GW=$((IW - 65 - KW - NW - FW - extra))
	# A narrow panel cuts GIT first, down to 13, then the folder and the name, down to 10. Too
	# narrow for that, the folder and GIT go and the name has their room: the narrowest panel
	# takes the name down to 10 to keep CTX LEFT.
	v=$((13 - GW < FW - 10 ? 13 - GW : FW - 10)); ((v > 0)) && FW=$((FW - v)) GW=$((GW + v))
	v=$((13 - GW < NW - 10 ? 13 - GW : NW - 10)); ((v > 0)) && NW=$((NW - v)) GW=$((GW + v))
	((GW < 13)) && wide=0 NW=$((IW - 63 - KW - extra))
	# Narrower still, USER and VER go too, before the name gets under 10.
	((NW < 10)) && us=0 NW=$((NW + extra))
	# Built from the same widths as the rows below, so the columns line up.
	local hdr num
	fld ' #' $((KW + 3)); hdr=$FLD
	fld NAME $((NW + 1)); hdr+=$FLD
	if ((us)); then
		fld USER $((UW + 1)); hdr+=$FLD
		fld VER $((VW + 1)); hdr+=$FLD
	fi
	fld APP 10; hdr+=$FLD
	fld STATE 18; hdr+=$FLD
	if ((wide)); then
		fld FOLDER $((FW + 1)); hdr+=$FLD
		fld GIT $((GW + 1)); hdr+=$FLD
	fi
	fld CPU 13; hdr+="$FLD   MEM  "
	fld 'CTX LEFT' 10; hdr+=$FLD
	row "$GRY$hdr$R"
	local group="-"
	for ((i = 0; i < n; i++)); do
		# One heading per computer, once panes from a linked one are listed.
		if ((P_GROUPS)) && [[ ${P_HOST[i]} != "$group" ]]; then
			group=${P_HOST[i]}
			if [[ -z $group ]]; then
				row "$BLU▓▒░$R $B$BWHT${HOST^^}$R $GRY· this computer$R"
			else
				row "$BLU▓▒░$R $B$BWHT${group^^}$R $GRY· linked$R"
			fi
		fi
		name=${nm[i]}
		printf -v pad '%*s' $((KW - ${#lab[i]} - 2)) ''
		if [[ -n ${lab[i]} ]]; then key="$BBLU[$BWHT$B${lab[i]}$R$BBLU]$R$pad"; else key="$GRY ·$R$pad"; fi
		folder=${P_DIR[i]/#$HOME/\~}
		folder=${folder##*/}
		git=${P_GIT[i]}
		cells="$key "
		if ((i == SEL)); then mark="$BYEL▶$R"; else mark=" "; fi
		cells+="$mark "
		fld "$name" "$NW"
		if ((i == SEL)); then cells+="$REV$BCYN$FLD$R "
		elif [[ -z ${P_NAME[i]} ]]; then cells+="$GRY$FLD$R "
		else cells+="$BWHT$FLD$R "; fi
		if ((us)); then
			fld "${P_USER[i]:-}" "$UW"
			cells+="$CYN$FLD$R "
			fld "${ver[i]}" "$VW"
			if [[ ${ver[i]} == "[V]" ]]; then cells+="$BYEL$FLD$R "
			elif [[ -n ${ver[i]} && -n $VERSION ]] && ver_lt "${ver[i]}" "$VERSION"; then cells+="$BYEL$FLD$R "
			else cells+="$GRY$FLD$R "; fi
		fi
		fld "${P_APP[i]}" 9
		if ((P_AGENT[i])); then cells+="$BCYN$FLD$R "; else cells+="$CYN$FLD$R "; fi
		# Its agent waiting for access through here: said in its STATE, unless it asks a question.
		st=${P_STATE[i]}
		[[ $st != asking && -n ${P_NAME[i]} && $gw == *" ${P_NAME[i]}@${P_HOST[i]:-${AGENT_SAY_HOST:-$HOST}} "* ]] && st=grant
		state_cell "$st"
		cells+=$CELL
		if ((wide)); then
			fld "$folder" "$FW"
			cells+="$BBLU$FLD$R "
			fld "$git" "$GW"
			if [[ $git == *\* ]]; then cells+="$BYEL$FLD$R "; else cells+="$GRN$FLD$R "; fi
		fi
		# Names-only rows from a link have nothing measured: leave CPU and memory blank.
		if [[ ${P_STATE[i]} != linked && ${P_STATE[i]} != unreachable && ${P_STATE[i]} != login ]]; then
			meter "${P_CPU[i]}"
			human "${P_MEM[i]}"
			printf -v num '%4s%%  %6s' "${P_CPU[i]}" "$HUMAN"
			cells+="$BCYN$METER$R $num"
			ctx_cell "${P_CTX[i]}" "${P_AGENT[i]}"
			cells+="  $CTX_CELL"
		fi
		row "$cells"
	done
	((n)) || row "$GRY  no tmux panes found$R"
}

ctx_cell() { # ctx_cell PERCENT AGENT -> CTX_CELL: context left as a meter, red as it runs out; a
	# dash for an agent that keeps no count the panel can read, nothing for anything else
	local c
	CTX_CELL=""
	if [[ -z $1 ]]; then (($2)) && CTX_CELL="$GRY·····    –$R"; return 0; fi
	if (($1 <= 15)); then c=$BRED; elif (($1 <= 40)); then c=$BYEL; else c=$BGRN; fi
	meter "$1"
	printf -v CTX_CELL '%s %3s%%' "$c$METER$R" "$1"
}
# kc KEY LABEL -> KC: a key as the command bar shows it. kcs KEY LABEL...: several, two spaces apart
kc() { KC="$BBLU[$B$BYEL$1$R$BBLU]$R$BWHT$2$R"; }
kcs() {
	local k=""
	while (($# >= 2)); do kc "$1" "$2"; k+="${k:+  }$KC"; shift 2; done
	KC=$k
}
draw_peek() { # draw_peek LINES: the bottom of the selected pane's screen, or the question it's asking
	local -a L=()
	local id=${P_ID[SEL]:-} i end start shown=0 keys name=${P_NAME[SEL]:-${P_LOC[SEL]:-}}
	if [[ ${P_STATE[SEL]:-} == asking ]]; then
		draw_question "$1"
		return
	fi
	if ((FULL)); then kc c " collapse"; else kc x " full view"; fi
	# Its agents working in the background don't keep it from taking what you type.
	if [[ ${P_STATE[SEL]:-} == agents ]]; then sectk "PEEK · $name · agents busy, takes input" "$KC"; else sectk "PEEK · $name" "$KC"; fi
	if [[ -n ${P_HOST[SEL]:-} ]]; then
		remote_peek "$1"
	elif [[ -n $id ]]; then
		mapfile -t L < <(tm capture-pane -p -t "$id" 2>/dev/null)
		for i in "${!L[@]}"; do clean "L[$i]"; done # capture-pane passes C1 characters through
	fi
	# The bottom of its screen, row for row: the box's last line is the pane's last line,
	# blank or not, and it reads upward from there. A screen shorter than the box is padded
	# above, so the bottoms still line up.
	end=$((${#L[@]} - 1))
	start=$((end - $1 + 1))
	((start < 0)) && start=0
	for ((shown = end - start + 1; shown < $1; shown++)); do row "$GRY│$R"; done
	for ((i = start; i <= end; i++)); do fld "${L[i]}" $((IW - 2)); row "$GRY│$R $DIM$FLD$R" "$IW"; done
}

# The question the selected pane is asking, in place of its peek: only the dialog at the
# bottom of its screen, bright, from the top of the box down. Enter answers it from here (keys
# go to the pane until Ctrl-]); a chat with the agent is J, in the pane itself.
draw_question() { # draw_question LINES
	local id=${P_ID[SEL]:-} i start keys name=${P_NAME[SEL]:-${P_LOC[SEL]:-}}
	if ((ANSWERING)); then
		kcs Tab " back to panes" "Ctrl-]" " leaves"
		keys="$B${BMAG}keys go to $name$R  $KC"
	else
		if [[ -n ${P_HOST[SEL]:-} ]]; then kcs Tab " answer"; else kcs Tab " answer" J " open the chat"; fi
		keys="$KC  "
		if ((FULL)); then kc c " collapse"; else kc x " full view"; fi
		keys+=$KC
	fi
	sectk "QUESTION · $name" "$keys" 5
	if ((ANSWERING)); then
		L=("${QL[@]}") # answer() has just read it
	elif [[ -n ${P_HOST[SEL]:-} ]]; then
		remote_peek 60
	elif [[ -n $id ]]; then
		mapfile -t L < <(tm capture-pane -p -t "$id" 2>/dev/null)
		for i in "${!L[@]}"; do clean "L[$i]"; done
	fi
	# The dialog sits at the bottom of the agent's screen, so show that bottom row for row,
	# exactly like the peek: the question, every choice and the footer, nothing cut out.
	# (Cutting it at a rule lost the question: Claude Code draws one between its choices.)
	local end=$((${#L[@]} - 1)) shown
	start=$((end - $1 + 1))
	((start < 0)) && start=0
	question_parts
	for ((shown = end - start + 1; shown < $1; shown++)); do row "$BMAG│$R"; done
	for ((i = start; i <= end; i++)); do fld "${L[i]}" $((IW - 2)); row "$BMAG│$R ${QSTYLE[i]:-$BWHT}$FLD$R" "$IW"; done
}

# question_parts: a colour for each line of L by what it is, so the question stands out:
# the question itself bold yellow, the highlighted choice bold cyan on a band, the other
# choices white with their descriptions dim, the history above and the footer grey. Only
# colours are chosen here, nothing is cut, so a dialog shaped some other way just looks
# plainer. -> QSTYLE[i]
question_parts() {
	local i first=-1 top=-1 last=-1
	QSTYLE=()
	# The first choice: "1." (or "❯ 1.") nearest the bottom that starts a run of choices.
	for ((i = ${#L[@]} - 1; i >= 0; i--)); do
		[[ ${L[i]} =~ ^[[:space:]│]*(❯[[:space:]]*)?1\.[[:space:]] ]] && { first=$i; break; }
	done
	((first < 0)) && return 0
	# The dialog's top: the nearest rule above the first choice, else the blank-line gap.
	for ((i = first - 1; i >= 0 && i >= first - 20; i--)); do
		[[ ${L[i]} =~ ^[[:space:]]*[─━═╌]{8,} ]] && { top=$i; break; }
	done
	((top < 0)) && top=$((first > 6 ? first - 6 : 0))
	# The footer: "Enter to select", "Esc to cancel" and the like, after the choices.
	for ((i = ${#L[@]} - 1; i > first; i--)); do
		[[ ${L[i]} =~ (Esc to|Enter to|to navigate|to cancel) ]] && { last=$i; break; }
	done
	for ((i = 0; i < ${#L[@]}; i++)); do
		if ((i < top)); then QSTYLE[i]=$GRY$DIM                          # history above it
		elif [[ ${L[i]} =~ ^[[:space:]]*[─━═╌]{8,} ]]; then QSTYLE[i]=$MAG  # its rules
		elif ((i < first)); then QSTYLE[i]=$B$BYEL                         # the question
		elif ((last >= 0 && i >= last)); then QSTYLE[i]=$GRY                # the footer
		elif [[ ${L[i]} =~ ^[[:space:]│]*❯ ]]; then QSTYLE[i]=$e[44m$B$BCYN  # the highlighted choice
		elif [[ ${L[i]} =~ ^[[:space:]│]*(\[.\][[:space:]]*)?[0-9]+\. ]]; then QSTYLE[i]=$BWHT # a choice
		else QSTYLE[i]=$GRY; fi                                               # a choice's description
	done
}

messages() { # -> MSG lines for the message center; INTRO_ON
	MSG=()
	local h b from to when id rest qn why k i j d c f t gn now more
	local -a H=() BS=() WAIT=() ASKS=()
	local -A asks=() last=() shown=()
	# Access waiting on you, by its introduction's time: a held message's id starts with it.
	INTRO_ON=0 # anything for G: access waiting, or approved and not yet lapsed (the key bar offers G)
	for d in "$ASTATE"/intros/*/; do
		[[ -f $d/from ]] || continue
		INTRO_ON=1
		ASKS+=("$d")
		c=$(head -n 1 "$d/created" 2>/dev/null)
		[[ $c =~ ^[0-9]{1,12}$ ]] && asks[$c]=1
	done
	if [[ -f $AMAIL ]]; then
		# A held message gets a row when it's held and another when its fate is known, under
		# the same id: only the last one for each is shown, so its row says what became of it.
		while IFS=$'\t' read -r h b; do
			clean h b
			[[ $h =~ ^\#\#\ \[([^ ]+)\ -\>\ ([^ ]+)\ ([^]]+)\]\ \#([^ ]+)(.*)$ ]] || continue
			k="${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[4]}"
			j=${last[$k]:-}; [[ -n $j ]] && H[j]="" # superseded (j is a number set here, never text)
			last[$k]=${#H[@]}
			H+=("$h") BS+=("$b")
		done < <(tail -n 600 "$AMAIL" 2>/dev/null | awk '/^## \[/{h=$0; getline b; print h "\t" b}' | tail -n 40)
		for i in "${!H[@]}"; do
			[[ -n ${H[i]} ]] || continue
			[[ ${H[i]} =~ ^\#\#\ \[([^ ]+)\ -\>\ ([^ ]+)\ ([^]]+)\]\ \#([^ ]+)(.*)$ ]] || continue
			from=${BASH_REMATCH[1]} to=${BASH_REMATCH[2]} when=${BASH_REMATCH[3]} id=${BASH_REMATCH[4]} rest=${BASH_REMATCH[5]} b=${BS[i]}
			when=${when:11:5}
			c=${id#h} c=${c%%.*} c=${c:-x}
			if [[ $rest == " (held: waiting for access)" && -n ${asks[$c]:-} ]]; then
				# Not failed: waiting on you. "waiting" first, so a narrow panel cuts the pair, not it.
				shown[$c]=1
				WAIT+=("$GRY$when$R $BMAG⚑$R $B${BMAG}waiting for [G]rant access$R $BWHT$from$R$GRY→$R$BWHT$to$R $GRY· $b$R")
			elif [[ $rest == *"NOT DELIVERED"* ]]; then
				# Why, short: an agent whose session changed has restarted.
				why=${rest#*NOT DELIVERED: } why=${why%)}
				[[ $why == *"has changed since it was given permission"* ]] && why="${to%@*} restarted"
				MSG+=("$GRY$when$R $BRED✗$R $BWHT$from$R$GRY→$R$BWHT$to$R ${BRED}not delivered: ${why:0:60}$R $GRY· $b$R")
			elif [[ $rest == " (held"* ]]; then
				MSG+=("$GRY$when$R $BYEL⏸$R $BWHT$from$R$GRY→$R$BWHT$to$R ${BYEL}held ·$R $GRY$b$R")
			else
				MSG+=("$GRY$when$R $BGRN✉$R $BWHT$from$R$GRY→$R$BWHT$to$R $GRY$b$R")
			fi
		done
		((${#MSG[@]} > 4)) && MSG=("${MSG[@]: -4}") # the last four
	fi
	# One waiting whose held rows are older than the ones read: from its introduction instead.
	for d in "${ASKS[@]}"; do
		c=$(head -n 1 "$d/created" 2>/dev/null)
		[[ -n $c && -n ${shown[$c]:-} ]] && continue
		f=$(head -n 1 "$d/from") t=$(head -n 1 "$d/to") b=$(head -c 200 "$d/intro" 2>/dev/null)
		clean f t b
		[[ $c =~ ^[0-9]{1,12}$ ]] && TZ=UTC printf -v when '%(%H:%M)T' "$c" || when="--:--"
		WAIT+=("$GRY$when$R $BMAG⚑$R $B${BMAG}waiting for [G]rant access$R $BWHT$f$R$GRY→$R$BWHT$t$R${b:+ $GRY· $b$R}")
	done
	# Waiting ones first, so other messages never push them off: a few, then a count.
	if ((${#WAIT[@]} > 3)); then
		more=$((${#WAIT[@]} - 2))
		WAIT=("${WAIT[@]:0:2}" "$BMAG⚑$R $B$BMAG$more more waiting for [G]rant access$R")
	fi
	((${#WAIT[@]} + ${#MSG[@]})) || MSG+=("$GRY no messages yet · ask an agent to use agent-say$R")
	MSG=("${WAIT[@]}" "${MSG[@]}")
	# Approved: allow lines within their day (agent-say culls the rest when G is pressed).
	local ttl=${AGENT_SAY_SESSION_TTL:-86400}
	[[ $ttl =~ ^[1-9][0-9]{0,9}$ ]] || ttl=86400
	printf -v now '%(%s)T' -1
	gn=$(awk -v c="$((now - ttl))" '$1 == "allow" && $6 ~ /^[0-9]+$/ && $6 > c {n++} END {print n + 0}' "$ASTATE/grants" 2>/dev/null)
	((gn)) && INTRO_ON=1 && MSG+=("$BGRN✓$R $GRY$gn approved · $R$BBLU[$B${BYEL}G$R$BBLU]$R$GRY to see$R")
	qn=$(find "$ASTATE/queue" -maxdepth 1 -name 'msg.*' ! -name '*.err' 2>/dev/null | wc -l)
	((qn)) && MSG+=("$BYEL⧗ $qn queued, waiting for a busy pane$R")
}

links_saves() { # -> SIDE lines: saves, then links
	SIDE=()
	local last at reason n iv d h pid names err mode al
	last=$(cd -P "$DIR/last" 2>/dev/null && pwd)
	n=$(find "$DIR/snapshots" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
	iv=$(opt @revive-interval 60)
	if [[ -n $last && -f $last/state.json ]]; then
		IFS=$'\t' read -r at reason < <(jq -r '[.saved_at, .reason] | @tsv' "$last/state.json" 2>/dev/null)
		clean at reason
		SIDE+=("$BCYN▓ SAVED$R $BWHT${at:11:8}$R $GRY($reason)$R")
	else
		SIDE+=("$BCYN▓ SAVED$R $GRY never$R")
	fi
	SIDE+=("$GRY  $n kept · every ${iv}s · on detach$R")
	for d in "$ASTATE"/links/*/; do
		[[ -f $d/on ]] || continue
		h=$(basename "$d") err=$(head -c 60 "$d/error" 2>/dev/null)
		clean h err
		pid=$(cat "$d/pid" 2>/dev/null)
		names=$(grep -c . "$d/names" 2>/dev/null)
		# What the link lets that computer do here (agent-say link HOST --read-only / --allow).
		mode=""
		[[ -f $d/read-only ]] && mode+=" $BYEL· read-only$R"
		if [[ -f $d/allow ]]; then
			al=$(head -c 200 "$d/allow" | paste -sd, -)
			clean al
			mode+=" $BYEL· only ${al:0:40}$R"
		fi
		if [[ -n $pid ]] && [[ $(ps -ww -o args= -p "$pid" 2>/dev/null) == *"_poll $h"* ]] && [[ ! -s $d/error ]]; then
			SIDE+=("$BGRN●$R $BWHT$h$R$mode $GRY· linked · ${names:-0} names$R")
		elif [[ -f $d/login ]]; then
			SIDE+=("$BYEL●$R $BWHT$h$R$mode $BYEL· needs login ·$R $BBLU[$B${BYEL}L$R$BBLU]$R${BWHT}og in$R")
		elif [[ -s $d/error ]]; then
			SIDE+=("$BRED●$R $BWHT$h$R$mode $BRED$err$R")
		else
			SIDE+=("$BRED●$R $BWHT$h$R$mode $GRY· not running$R")
		fi
	done
	for d in "$ASTATE"/peers/*/; do
		[[ -d $d ]] || continue
		h=$(basename "$d")
		clean h
		if [[ -n $(find "$d/alive" -mmin -1 2>/dev/null) ]]; then SIDE+=("$BGRN◌$R $BWHT$h$R $GRY· checks in here$R"); fi
	done
	# Access waiting and approved shows in MESSAGES (messages()), not here.
	# ssh connections in panes that aren't linked yet: offered for linking with L.
	local i seen=" "
	for i in "${!P_SSH[@]}"; do
		h=${P_SSH[i]}
		[[ -z $h || $seen == *" $h "* ]] && continue
		seen+="$h "
		linked "$h" && continue
		SIDE+=("$BYEL◇$R $BWHT$h$R $GRY· ssh in ${P_NAME[i]:-${P_LOC[i]}} ·$R $BBLU[$B${BYEL}L$R$BBLU]$R${BWHT}ink?$R")
	done
	for i in "${!X_SSH[@]}"; do
		h=${X_SSH[i]}
		[[ $seen == *" $h "* ]] && continue
		seen+="$h "
		linked "$h" && continue
		SIDE+=("$BYEL◇$R $BWHT$h$R $GRY· ssh in ${X_WHERE[i]} ·$R $BBLU[$B${BYEL}L$R$BBLU]$R${BWHT}ink?$R")
	done
	((${#SIDE[@]} > 2)) || SIDE+=("$GRY  no links · ssh to a host and press L$R")
}

# draw_top: draw's rows from the top of the frame down to the CPU graph, and BH, the banner's
# height. Returns 1 when the ? page has drawn the rest instead.
draw_top() {
	local i counts w=0 a=0 s=0
	for ((i = 0; i < n; i++)); do
		case ${P_STATE[i]} in working | agents) ((w++)) ;; asking) ((a++)) ;; esac
		((P_AGENT[i])) && ((s++))
	done

	# Banner: block letters, a little CRT and the board's details. The big one when there's room.
	rep ═ $((W - 2))
	line "$FRAME╔$REP╗$R"
	local total=0 BAN=() now
	if ((lines - n >= 30)); then
		BH=6
		monitor "$w" "$a" "$s"
		rep ─ 25
		printf -v now '%(%a %H:%M:%S)T' -1
		local tag=("$BBLU░▒▓$R$B$BWHT T M U X $R$BBLU▓▒░$R" "$B${BCYN}C O N T R O L   P A N E L$R"
			"$GRY$REP$R" "$GRY node   $BWHT$HOST$R" "$GRY time   $BWHT$now$R"
			"$GRY sysop  $BWHT${USER:-you}$GRY · $n panes · $s agents$R")
		for i in 0 1 2 3 4 5; do
			padv "${tag[i]}" 36
			if ((IW >= 100)); then BAN[i]=" ${BIG_ROWS[i]}  ${MON[i]}   $PADV"; else BAN[i]=" ${BIG_ROWS[i]}  $PADV"; fi
		done
	else
		printf -v now '%(%H:%M:%S)T' -1
		local tag=("$BBLU░▒▓$R$B$BWHT T M U X $R$BBLU▓▒░$R" "$B${BCYN}C O N T R O L   P A N E L$R" "$GRY node $BWHT$HOST$GRY · $now · $n panes · $s agents$R")
		local shade=("$BCYN" "$CYN" "$BBLU")
		for i in 0 1 2; do padv "${tag[i]}" 60; BAN[i]="  ${shade[i]}$B${BANNER[i]}$R   $PADV"; done
	fi
	# Whatever width is left beside the banner shows the scene.
	vlen "${BAN[0]}"
	local tw=$((IW - VLEN - 1))
	if ((tw >= 8)); then
		art "$tw" "$BH" still # beside the banner the scene holds still
		# Every banner row is as wide as the first (the letters, the CRT and the padded details).
		for ((i = 0; i < BH; i++)); do row "${BAN[i]} ${ART[i]}" "$IW"; done
	else
		for ((i = 0; i < BH; i++)); do row "${BAN[i]}"; done
	fi
	((HELP)) && { help_frame "$lines" "$BH"; return 1; } # the ? page takes everything below
	counts="$BYEL$w working$R$GRY · $R$BMAG$a asking$R"
	((a)) && counts="$BYEL$w working$R$GRY · $R$B$BMAG$BLINK$a asking$R"
	sect "PANES"
	draw_panes
	# CPU across every pane, as a running graph.
	for i in "${!P_CPU[@]}"; do [[ -z ${P_HOST[i]} ]] && total=$((total + P_CPU[i])); done
	CPU_HIST+=("$total")
	((${#CPU_HIST[@]} > 200)) && CPU_HIST=("${CPU_HIST[@]: -200}")
	vlen "$counts"
	spark $((IW - 8 - VLEN))
	row "$GRY cpu $R$SPARK  $counts"
}

draw() {
	local cols lines n i LW RW avail peek_h=0 l r BH=3
	[[ -n $TCOLS ]] || TCOLS=$(tput cols 2>/dev/null || echo 100) TLINES=$(tput lines 2>/dev/null || echo 40)
	cols=$TCOLS lines=$TLINES
	((ONCE)) && cols=${COLUMNS:-$cols} lines=${LINES:-$lines}
	W=$((cols < 80 ? 80 : cols)) IW=$((W - 4))
	OUT=()
	n=${#P_ID[@]}
	if ((ANSWERING && ${#ATOP[@]})); then
		# Answering: nothing above the question can change (no panes are gathered meanwhile),
		# so those rows are kept from the first frame, and only the question and the bar drawn.
		OUT=("${ATOP[@]}") BH=$ATOP_BH
	else
		draw_top || return
		((ANSWERING)) && ATOP=("${OUT[@]}") ATOP_BH=$BH
	fi

	# A question needs every row it can get: the messages step aside until it's answered, and
	# aren't looked at meanwhile. Moving the selection can't change them, so they're kept.
	local bottom=-1 msgs=0
	if [[ ${P_STATE[SEL]:-} == asking ]]; then
		MSG_OLD=1
	else
		((nav && !MSG_OLD)) || { messages; links_saves; MSG_OLD=0; }
		msgs=1 bottom=$((${#MSG[@]} > ${#SIDE[@]} ? ${#MSG[@]} : ${#SIDE[@]}))
	fi
	# Fixed rows: frame 2, banner, section bars 3, column header 1, totals 1, keys 1. The peek
	# matters more than the artwork: it takes about two thirds of the rest (14 rows or more
	# when they're there) and the scene the others, unless that leaves the scene too little to
	# be worth drawing. X gives the peek all of it. With no peek (P hides it, or nothing to
	# peek at) the scene fills the space, so the panel fills its pane. A question shows even
	# with the peek hidden: it's waiting on you.
	avail=$((lines - BH - 8 - n - P_GROUPS - bottom))
	# No peek at the panel's own pane: it would only show itself.
	local show=0
	if ((n && avail >= 4)) && [[ ${P_STATE[SEL]:-} != self ]]; then
		((PEEK)) || [[ ${P_STATE[SEL]:-} == asking ]] && show=1
	fi
	if ((show)); then
		# Rows with its title: 15 is the 14 it always had.
		peek_h=$((avail * 2 / 3))
		((peek_h < 15)) && peek_h=15
		# A question takes all the room: its top (the question itself) must not be cut off.
		((peek_h > avail || avail - peek_h < 4 || FULL)) && peek_h=$avail
		[[ ${P_STATE[SEL]:-} == asking ]] && peek_h=$avail
		avail=$((avail - peek_h))
		draw_peek $((peek_h - 1))
	fi
	if ((avail >= 3)); then
		sect "ART · ${TITLES[SCENE]}"
		art "$IW" $((avail - 1))
		for l in "${ART[@]}"; do row "$l" "$IW"; done
		avail=0
	fi
	for ((; avail > 0; avail--)); do row ""; done

	LW=$(((IW - 3) * 3 / 5)) RW=$((IW - 3 - LW))
	((msgs)) && sect "MESSAGES" "LINKS · SAVES" "$((LW + 1))"
	for ((i = 0; i < bottom; i++)); do
		l=${MSG[i]:-} r=${SIDE[i]:-}
		vlen "$l"
		((VLEN > LW)) && { trim_colored "$l" "$LW"; l=$TRIM; }
		vlen "$l"
		rep ' ' $((LW - VLEN))
		l+=$REP
		vlen "$r"
		((VLEN > RW)) && { trim_colored "$r" "$RW"; r=$TRIM; }
		row "$l $FRAME│$R $r"
	done

	# Command bar.
	local k=""
	((!ANSWERING)) && [[ ${P_STATE[SEL]:-} == asking ]] && k="$B$BMAG[Tab]$R$B$BWHT answer$R  "
	# Keys that can't act on the selected pane are faded: on a linked computer's pane, nothing
	# to rename unless its rows say which pane it is, and never J: a jump there would move
	# focus somewhere you may be busy (another pane, or tmux over there).
	local off=" " rh=${P_HOST[SEL]:-}
	if [[ -n $rh ]]; then
		[[ -n ${P_RID[SEL]:-} ]] || off+="N "
		[[ -n ${P_NAME[SEL]:-} ]] || off+="M "
		off+="J "
	fi
	local cs=("J:ump" "M:essage" "N:ame" "L:ink" "U:nlink")
	v_mode # tmux-revive for that row's user, or on that computer
	case $VMODE in host | update) cs+=("V: update") ;; install) cs+=("V: install") ;; esac
	((${INTRO_ON:-0})) && cs+=("G:rant access")
	cs+=("P:eek" "A:rt" "S:ave" "Q:uit" "?: help")
	for c in "${cs[@]}"; do
		if [[ $off == *" ${c%%:*} "* ]]; then
			k+="$GRY[${c%%:*}]${c#*:}$R  "
		else
			k+="$BBLU[$B$BYEL${c%%:*}$R$BBLU]$R$BWHT${c#*:}$R  "
		fi
	done
	vlen "$k"
	((VLEN + 15 <= IW)) && k+="$GRY↑↓ 0-9 select$R"
	if [[ -n $FLASH ]] && ((SECONDS - FLASH_T < 5)); then k="$BGBLU$B$BWHT $FLASH $R  $k"; fi
	# While answering every key goes to the agent, so the bar says that and how to stop.
	((ANSWERING)) && k="$e[45m$B$BWHT ANSWERING ${P_NAME[SEL]:-${P_LOC[SEL]:-}} $R  $BMAG every key goes to its question ·$R $B${BYEL}Tab$R$BMAG back to the panes ·$R $B${BYEL}Ctrl-]$R$BMAG leaves$R"
	rep ═ $((W - 2))
	line "$FRAME╠$REP╣$R"
	row "$k"
	local sig="$BLU▓▒░$R$GRY tmux-revive bbs · est. 2026 $R$BLU░▒▓$R"
	vlen "$sig"
	rep ═ $((W - 4 - VLEN))
	line "$FRAME╚$REP$R$sig$FRAME══╝$R"

	if ((ONCE)); then
		printf '%s\n' "${OUT[@]}"
	else
		# Only the lines that changed since the last frame are sent, each placed by row, and the
		# whole update is wrapped in synchronized-output marks (?2026) so the terminal shows it at
		# once. A twinkling star then rewrites one line, not the whole screen.
		local buf="" i
		for i in "${!OUT[@]}"; do
			[[ ${OUT[i]} == "${PREV[i]-}" ]] && continue
			buf+="$e[$((i + 1));1H${OUT[i]}$e[K"
		done
		((${#OUT[@]} < ${#PREV[@]})) && buf+="$e[$((${#OUT[@]} + 1));1H$e[J"
		PREV=("${OUT[@]}")
		[[ -n $buf ]] && printf '%s' "$e[?2026h$buf$e[?2026l"
	fi
}

trim_colored() { # trim_colored TEXT WIDTH -> TRIM: cut to WIDTH visible characters, keeping the colours
	local s=$1 w=$2 out="" n=0
	while [[ -n $s ]] && ((n < w - 1)); do
		if [[ $s =~ ^($e\[[0-9\;]*m) ]]; then
			out+=${BASH_REMATCH[1]} s=${s:${#BASH_REMATCH[1]}}
		else
			out+=${s:0:1} s=${s:1}
			((n++))
		fi
	done
	TRIM=$out…$R
}

# ------------------------------------------------------------------ actions
flash() { FLASH=$1 FLASH_T=$SECONDS; clean FLASH; } # agent-say's reply can quote anything
# A code shown only in a popup, typed back there: a popup isn't a pane, so no agent can read
# it or type into it with send-keys. The popup's own shell then runs agent-say's FUNCTION
# ARGS... CODE (approve, grant_refresh), which refuses without that code; no command does it.
# code_popup QUESTION VERB FUNCTION ARGS... -> the last line it said, or nothing (no match)
code_popup() {
	local q=$1 verb=$2 out="$ASTATE/intros/.allow.out" pc
	shift 2
	mkdir -p "$ASTATE/intros"
	pc=$(printf '%q ' bash -c 'c=$(( $(od -An -N4 -tu4 /dev/urandom) % 9000 + 1000 )); printf "\n  %s\n\n  Type %s and Enter to %s (anything else: no): " "$1" "$c" "$2"; IFS= read -r r; [[ $r == "$c" ]] || exit 1; export AGENT_SAY_MAILBOX="$3" AGENT_SAY_APPROVE_CODE="$c"; o=$4 s=$5; shift 5; source "$s" && "$@" "$c" >"$o" 2>&1' _ "$q" "$verb" "$AMAIL" "$out" "$ASAY" "$@")
	rm -f "$out"
	tm display-popup -E -w 76 -h 9 "$pc" 2>/dev/null
	tail -n 1 "$out" 2>/dev/null || true
	rm -f "$out"
}

# read_host_keys HOST -> KEYS: its key fingerprints, as agent-say link would show them, and
# KEY_STATE: whether link would ask you to confirm them (agent-say's key_state: recorded,
# trusted, changed, unknown; anything else is taken as unknown, so it asks).
read_host_keys() {
	local k
	KEYS=() KEY_STATE=unknown
	while IFS= read -r k; do
		if [[ $k =~ ^state:\ (recorded|trusted|changed|unknown)$ ]]; then KEY_STATE=${BASH_REMATCH[1]}
		elif [[ $k =~ ^SHA256:[A-Za-z0-9+/=]{1,64}\ \([A-Z0-9-]{1,16}\)$ ]]; then KEYS+=("$k"); fi
	done < <(timeout 20 "$ASAY" _host-keys "$1" ${2:+"$2"} </dev/null 2>/dev/null | head -n 9)
}

# login_window HOST: log in to a host that wants a password, once, for its link. ssh runs in a
# popup over the panel (in a window of its own when no client can show a popup) and asks you
# itself; the panel and agent-say never see what you type. Only a key you press opens it.
# login_window HOST [FINGERPRINT...]: the keys you just confirmed; none, the link's own.
# Returns whether a login is open now.
login_window() {
	local h=$1 cmd w i
	[[ $h =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
	shift
	# tmux runs it with the server's environment, not this panel's: say where agent-say keeps
	# its state, which ssh it uses, and where it reads host keys (as for the keys you confirmed).
	cmd=$(printf '%q ' env AGENT_SAY_MAILBOX="$AMAIL" ${AGENT_SAY_SSH:+AGENT_SAY_SSH="$AGENT_SAY_SSH"} \
		${AGENT_SAY_KNOWN_HOSTS:+AGENT_SAY_KNOWN_HOSTS="$AGENT_SAY_KNOWN_HOSTS"} \
		${AGENT_SAY_KEYSCAN:+AGENT_SAY_KEYSCAN="$AGENT_SAY_KEYSCAN"} "$ASAY" _login "$h" "$@")
	if [[ -n $(tm list-clients -F x 2>/dev/null) ]]; then
		tm display-popup -E -w 84 -h 12 "$cmd" 2>/dev/null # returns when it closes
	else
		# Until that window closes (ten minutes at most; sshd gives up on a login sooner).
		w=$(tm new-window -P -F '#{window_id}' -n "login $h" "$cmd") || return 1
		for ((i = 0; i < 2000; i++)); do
			tm list-windows -a -F '#{window_id}' 2>/dev/null | grep -qxF -- "$w" || break
			sleep 0.3
		done
	fi
	PREV=()
	"$ASAY" _login "$h" --check
}

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

# pick TITLE ITEM...: a BBS-style popup over the panel, a blue double-line box with a shaded
# shadow, listing ITEMs. ↑↓ or 1-9 choose, Enter picks (-> PICKED, the index), Esc or q closes
# it (returns 1). Ctrl-C closes it too, read in slices as in ask. An ITEM starting with $NOTE
# is a line to read (a heading, some words), not a choice: unnumbered, and never picked.
NOTE=$'\x1f' # clean takes control characters out of anything shown, so none can start with it
pick() {
	local title=$1 rows cols w h top left i k rest sel=-1 line hint="↑↓ choose · Enter picks · Esc closes" INTR=0
	shift
	local -a items=("$@") ch=() num=()
	for i in "${!items[@]}"; do
		[[ ${items[i]} == "$NOTE"* ]] && continue
		num[i]=${#ch[@]} ch+=("$i")
		((sel < 0)) && sel=$i
	done
	((${#ch[@]})) || return 1
	rows=$(tput lines 2>/dev/null || echo 40) cols=$(tput cols 2>/dev/null || echo 80)
	w=$((${#hint} + 6))
	for i in "${items[@]}"; do ((${#i} + 10 > w)) && w=$((${#i} + 10)); done
	((${#title} + 12 > w)) && w=$((${#title} + 12))
	((w > cols - 4)) && w=$((cols - 4))
	h=$((${#items[@]} + 5))
	top=$(((rows - h) / 2)) left=$(((cols - w) / 2))
	((top < 1)) && top=1
	((left < 1)) && left=1
	local bg="$e[44m" hi="$e[46m$e[30m"
	trap 'INTR=1' INT
	while :; do
		# Frame, title tab and shadow.
		rep ═ $((w - ${#title} - 11))
		line="$BGBLU$BWHT╔═$R$BLU░▒▓$BGBLU$B$BWHT $title $R$BLU▓▒░$BGBLU$BWHT$REP╗$R"
		printf '%s' "$e[$top;${left}H$line"
		rep ' ' $((w - 2))
		local blank=$REP
		printf '%s' "$e[$((top + 1));${left}H$bg$BWHT║$blank║$R$GRY░$R"
		for ((i = 0; i < ${#items[@]}; i++)); do
			local key="  "
			if [[ ${items[i]} == "$NOTE"* ]]; then
				fld "${items[i]#"$NOTE"}" $((w - 6))
				printf '%s' "$e[$((top + 2 + i));${left}H$bg$BWHT║  $BCYN$FLD$BWHT  ║$R$GRY░$R"
				continue
			fi
			((num[i] < 9)) && key="$((num[i] + 1)) "
			if ((i == sel)); then
				fld " $key ${items[i]}" $((w - 5))
				printf '%s' "$e[$((top + 2 + i));${left}H$bg$BWHT║ $hi$B▶$FLD$R$bg$BWHT ║$R$GRY░$R"
			else
				fld "$key" 3
				local kf=$FLD
				fld "${items[i]}" $((w - 9))
				printf '%s' "$e[$((top + 2 + i));${left}H$bg$BWHT║  $BYEL$kf$BWHT$FLD  ║$R$GRY░$R"
			fi
		done
		printf '%s' "$e[$((top + 2 + ${#items[@]}));${left}H$bg$BWHT║$blank║$R$GRY░$R"
		fld "$hint" $((w - 4))
		printf '%s' "$e[$((top + 3 + ${#items[@]}));${left}H$bg$BWHT║ $BCYN$FLD$BWHT ║$R$GRY░$R"
		rep ═ $((w - 2))
		printf '%s' "$e[$((top + 4 + ${#items[@]}));${left}H$bg$BWHT╚$REP╝$R$GRY░$R"
		rep ░ "$w"
		printf '%s' "$e[$((top + 5 + ${#items[@]}));$((left + 1))H$GRY$REP$R"
		k=""
		until IFS= read -rsn1 -t 0.2 k; do
			(($? <= 128 || INTR)) && { k=CLOSE; break; }
			k=""
		done
		case $k in
		CLOSE | q | Q) trap 'exit 0' INT; return 1 ;;
		$'\e')
			rest=""
			IFS= read -rsn2 -t 0.05 rest || true
			case $rest in
			'') trap 'exit 0' INT; return 1 ;; # a lone Esc closes the window
			'[A') ((num[sel] > 0)) && sel=${ch[num[sel] - 1]} ;;
			'[B') ((num[sel] < ${#ch[@]} - 1)) && sel=${ch[num[sel] + 1]} ;;
			esac ;;
		[1-9]) ((k - 1 < ${#ch[@]})) && sel=${ch[k - 1]} && { PICKED=$sel; trap 'exit 0' INT; return 0; } ;;
		"") PICKED=$sel; trap 'exit 0' INT; return 0 ;; # Enter
		esac
	done
}

# ------------------------------------------------------------------ answering a question
# Keys for a question, as they travel: tmux key names from a short list, or literal text as
# lit:HEX. Hex, so no shell on the way, here or on a linked computer, can read anything into
# it. Checked before a command line is built from them, and again where they're sent.
KEY_RE='^(Up|Down|Left|Right|Home|End|PPage|NPage|IC|DC|Enter|Escape|Tab|BTab|BSpace|Space|C-[a-z])$'
key_ok() { # key_ok TOKEN: may it be sent? A lit: token's text -> LIT (64 characters at most)
	local h=${1#lit:} i esc="" t
	LIT=""
	[[ $1 =~ $KEY_RE ]] && return 0
	[[ $1 == lit:* && $h =~ ^([0-9a-f]{2}){1,192}$ ]] || return 1
	for ((i = 0; i < ${#h}; i += 2)); do
		[[ ${h:i:2} =~ ^([01].|7f)$ ]] && return 1 # no C0 controls (NUL least of all), no DEL
		esc+="\\x${h:i:2}"
	done
	printf -v LIT '%b' "$esc"
	t=$LIT
	clean t # and no C1 controls, bidi overrides or zero-width characters
	[[ -n $LIT && $t == "$LIT" && ${#LIT} -le 64 ]]
}
lit_tokens() { # lit_tokens TEXT -> TOKS+=: typed text as lit: tokens, 32 characters each
	local t=$1 x
	while [[ -n $t ]]; do
		x=$(printf '%s' "${t:0:32}" | od -An -v -tx1 | tr -d ' \n')
		TOKS+=("lit:$x") t=${t:32}
	done
}
keys_send() { # keys_send %ID TOKEN...: to a pane on this computer, every token checked first
	local id=$1 k
	shift
	for k; do key_ok "$k" || return 2; done
	for k; do
		key_ok "$k"
		if [[ $k == lit:* ]]; then tm send-keys -t "$id" -l -- "$LIT" || return 1
		else tm send-keys -t "$id" "$k" || return 1; fi
	done
}
pane_here() { grep -qxF -- "$1" <<<"$(tm list-panes -a -F '#{pane_id}' 2>/dev/null)"; }
send_answer() { # send_answer TOKEN...: to the selected pane, here or over the link
	local h=${P_HOST[SEL]:-} id=${P_RID[SEL]:-} out st k
	if [[ -z $h ]]; then keys_send "${P_ID[SEL]}" "$@" && return; flash "the keys didn't reach that pane"; return 1; fi
	[[ $h =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $id =~ ^%[0-9]+$ ]] || return 1
	for k; do key_ok "$k" || return 1; done
	out=$(remote_run "$h" "$REMOTE_KEYS_CMD '$id' $*")
	st=$?
	[[ $out == sent ]] && return 0
	if ((st == 124 || st == 255)); then flash "on $h: can't be reached to answer"
	elif ((st == 0 || st == 1)) && [[ -z $out ]]; then flash "on $h: can't answer from here (update tmux-revive there)"
	else flash "on $h: the keys didn't get through"; fi
	return 1
}
# question_look -> QL, QRAW, QSHOT: the selected pane's screen while answering. A pane here
# is one capture-pane. A linked computer's comes in its peek file, which changes only when a
# fetch comes back, so while one is still out there's nothing new to read.
question_look() {
	local i k="${P_HOST[SEL]:-} ${P_RID[SEL]:-}"
	local -a L
	if [[ -n ${P_HOST[SEL]:-} ]]; then
		[[ -n $QSHOT && -n ${PFETCH_PID[$k]:-} ]] && kill -0 "${PFETCH_PID[$k]}" 2>/dev/null && return
		remote_peek 60
		QL=("${L[@]}")
	else
		mapfile -t QRAW < <(tm capture-pane -p -t "${P_ID[SEL]}" 2>/dev/null)
		QL=("${QRAW[@]}")
		for i in "${!QL[@]}"; do clean "QL[$i]"; done # capture-pane passes C1 characters through
	fi
	printf -v QSHOT '%s\n' "${QL[@]}"
}

# answer: every key goes to the selected pane's question, as if typed in its own console.
# The question is drawn again when the agent's screen changes: looked at every 40 ms for half
# a second after a key is sent, to show it react, and every 0.3 s otherwise. Ctrl-] (or
# Ctrl-C) leaves without sending anything; it ends by itself once the pane stops asking.
# Questions only: a chat with the agent is J, in its own pane.
answer() {
	local h=${P_HOST[SEL]:-} id=${P_ID[SEL]:-} k rest seq txt st got gone=0 why=left pend="" INTR=0 f
	local shot="" sent=0 skips=0 idle=0 poll=0
	local -a TOKS AL
	[[ ${P_STATE[SEL]:-} == asking ]] || return 0
	[[ -n $h ]] && id=${P_RID[SEL]:-}
	[[ $id =~ ^%[0-9]+$ ]] || return 0
	ANSWERING=1 PEEK_EVERY=0 PREV=() ATOP=() QL=() QRAW=() QSHOT=""
	trap 'INTR=1' INT
	while :; do
		# Keys already waiting behind the ones just sent go first, so they reach the agent together
		# and are drawn once; but no more than three times running, so the view can't freeze.
		if ((sent && skips < 3)) && { [[ -n $pend ]] || read -t 0; }; then
			((skips++))
		else
			skips=0
			question_look
			# Drawn only when there's something new to show (a resize empties PREV).
			if [[ $QSHOT != "$shot" || ${#PREV[@]} == 0 ]]; then draw; shot=$QSHOT; fi
			if ((idle)); then
				# Still asking? Twice not, in a row, means answered (one look can catch a redraw).
				if [[ -n $h ]]; then
					f="$RDIR/$h.peek-${id#%}" AL=()
					[[ -f $f ]] && mapfile -t AL < <(tail -n 60 "$f")
					lines_state AL
				else
					lines_state QRAW
				fi
				if [[ $LSTATE == asking ]]; then gone=0; else ((++gone >= 2)) && { why=answered; break; }; fi
			fi
		fi
		sent=0 idle=0
		if [[ -n $pend ]]; then
			k=$pend pend=""
		else
			k="" got=1 st=0
			if ((poll)); then IFS= read -rsn1 -t 0.04 k || { st=$? got=0; }
			else IFS= read -rsn1 -t 0.3 k || { st=$? got=0; }; fi
			if ((!got)); then
				((st > 128 && !INTR)) || break # Ctrl-C, or the input closed
				if ((poll)); then ((poll--)); else idle=1; fi
				continue
			fi
		fi
		TOKS=()
		case $k in
		$'\x1d') break ;;                    # Ctrl-]
		"" | $'\r' | $'\n') TOKS=(Enter) ;;
		$'\t') why=tab; break ;;            # Tab: focus back to the panes
		$'\x7f' | $'\b') TOKS=(BSpace) ;;
		$'\e')
			# A lone Esc is Escape; the arrows and the like arrive as sequences.
			rest="" seq=""
			IFS= read -rsn1 -t 0.03 rest
			case $rest in
			"") TOKS=(Escape) ;;
			'[') while IFS= read -rsn1 -t 0.03 rest; do seq+=$rest; [[ $rest == [@-~] || ${#seq} -gt 8 ]] && break; done ;;
			O) IFS= read -rsn1 -t 0.03 seq ;;
			esac
			case $seq in
			A) TOKS=(Up) ;; B) TOKS=(Down) ;; C) TOKS=(Right) ;; D) TOKS=(Left) ;;
			H | 1~ | 7~) TOKS=(Home) ;; F | 4~ | 8~) TOKS=(End) ;; Z) TOKS=(BTab) ;;
			2~) TOKS=(IC) ;; 3~) TOKS=(DC) ;; 5~) TOKS=(PPage) ;; 6~) TOKS=(NPage) ;;
			esac ;;
		[$'\x01'-$'\x1a'])
			printf -v st '%d' "'$k"
			printf -v k "\\x$(printf %x $((st + 96)))"
			TOKS=("C-$k") ;;
		[[:cntrl:]]) ;;
		*)
			# Typed text (a custom answer) goes as it is, with whatever else is already waiting. A
			# digit that starts it goes alone: in a menu it picks a choice, and "2x" sent as one
			# could be read as something else.
			txt=$k
			while [[ $k != [0-9] ]] && ((${#txt} < 256)) && IFS= read -rsn1 -t 0.005 rest; do
				if [[ -z $rest ]]; then pend=$'\r'; break
				elif [[ $rest == [[:cntrl:]] ]]; then pend=$rest; break; fi
				txt+=$rest
			done
			clean txt
			lit_tokens "$txt" ;;
		esac
		((${#TOKS[@]})) || continue
		send_answer "${TOKS[@]}" || { why=failed; break; }
		[[ -n $h ]] && peek_drop "$h" "$id"
		sent=1 poll=12
	done
	ANSWERING=0 PEEK_EVERY=$REFRESH PREV=() ATOP=()
	trap 'exit 0' INT
	case $why in
	left) flash "left the question; nothing more was sent" ;;
	tab) flash "back to the panes · Tab returns to the question" ;;
	answered)
		flash "${P_NAME[SEL]:-${P_LOC[SEL]:-the pane}} has its answer"
		# Rows from over there asked for before this still say asking: they don't count now.
		[[ -n $h ]] && { : >"$RDIR/$h.answered-${id#%}"; RFETCH_T[$h]=0; } ;;
	esac
}

PREV=()
# v_mode -> VMODE: what V does for the selected row. Another user's pane (not the tmux owner's,
# here or on its linked computer): install when that user has no tmux-revive, update when theirs
# is older than the owner's, current otherwise. host: update tmux-revive on its linked computer,
# for the user the link logs in as. Nothing for this tmux's owner here.
v_mode() {
	local u=${P_USER[SEL]:-} h=${P_HOST[SEL]:-} own=$ME v=${P_INST[SEL]:-} ref=$VERSION
	VMODE=""
	[[ -n $h ]] && own=${ROWNER[$h]:-} ref=${RVER[$h]:-}
	if [[ -n $u && $u != "$own" ]]; then
		if [[ -z $v ]]; then VMODE=install
		elif [[ $v =~ $VER_RE && $ref =~ $VER_RE ]] && ver_lt "$v" "$ref"; then VMODE=update
		else VMODE=current; fi
	elif [[ -n $h ]]; then VMODE=host; fi
}
# user_note install|update: the command that installs or updates tmux-revive for the selected
# row's user, to run in that user's own pane: shown in a box over the panel, and put in tmux's
# paste buffer. Nothing is run for them from here. The install command is README.md's.
user_note() {
	local u=${P_USER[SEL]:-} cmd="tmux-revive update" f l
	[[ $u =~ $USER_RE ]] || return
	if [[ $1 == install ]]; then
		cmd=""
		for f in "$REVIVE_ROOT/README.md" "$REVIVE_ROOT/install.sh"; do
			while IFS= read -r l; do
				l=${l#\#   }
				[[ $l =~ ^curl\ -fsSL\ https://[A-Za-z0-9./_-]+/install\.sh\ \|\ sh$ ]] && { cmd=$l; break 2; }
			done <"$f" 2>/dev/null
		done
		[[ -n $cmd ]] || return
	fi
	# Into tmux's paste buffer, and the system clipboard too where the terminal allows (-w).
	tm set-buffer -w -- "$cmd" 2>/dev/null || tm set-buffer -- "$cmd" 2>/dev/null
	note "$1 for $u" "Run this in $u's pane:" "" "$cmd" "" "Copied. Paste it there, or press prefix ]."
}
# note TITLE LINE...: a box over the panel, drawn as pick's, until a key is pressed.
note() {
	local title=$1 rows cols w top left i k l hint="press any key to close" INTR=0
	shift
	local -a ls=("$@")
	rows=$(tput lines 2>/dev/null || echo 40) cols=$(tput cols 2>/dev/null || echo 80)
	w=$((${#hint} + 6))
	for l in "${ls[@]}"; do ((${#l} + 6 > w)) && w=$((${#l} + 6)); done
	((${#title} + 12 > w)) && w=$((${#title} + 12))
	((w > cols - 4)) && w=$((cols - 4))
	top=$(((rows - ${#ls[@]} - 5) / 2)) left=$(((cols - w) / 2))
	((top < 1)) && top=1
	((left < 1)) && left=1
	rep ═ $((w - ${#title} - 11))
	printf '%s' "$e[$top;${left}H$BGBLU$BWHT╔═$R$BLU░▒▓$BGBLU$B$BWHT $title $R$BLU▓▒░$BGBLU$BWHT$REP╗$R"
	rep ' ' $((w - 2))
	printf '%s' "$e[$((top + 1));${left}H$BGBLU$BWHT║$REP║$R$GRY░$R"
	for ((i = 0; i < ${#ls[@]}; i++)); do
		fld "${ls[i]}" $((w - 4))
		printf '%s' "$e[$((top + 2 + i));${left}H$BGBLU$BWHT║ $B$FLD$R$BGBLU$BWHT ║$R$GRY░$R"
	done
	fld "$hint" $((w - 4))
	printf '%s' "$e[$((top + 2 + ${#ls[@]}));${left}H$BGBLU$BWHT║ $BCYN$FLD$BWHT ║$R$GRY░$R"
	rep ═ $((w - 2))
	printf '%s' "$e[$((top + 3 + ${#ls[@]}));${left}H$BGBLU$BWHT╚$REP╝$R$GRY░$R"
	rep ░ "$w"
	printf '%s' "$e[$((top + 4 + ${#ls[@]}));$((left + 1))H$GRY$REP$R"
	trap 'INTR=1' INT
	until IFS= read -rsn1 -t 0.2 k; do (($? <= 128 || INTR)) && break; done
	# The rest of a key sequence (an arrow) goes too.
	read -rsn4 -t 0.02 _ || true
	trap 'exit 0' INT
}
act() {
	# A key may draw over the panel (popup, prompt) and return early: repaint it whole. Keys
	# that only move the selection don't, so they keep the line-by-line redraw.
	case $1 in up | down | [0-9]) ;; *) PREV=() ;; esac
	local id=${P_ID[SEL]:-} name=${P_NAME[SEL]:-${P_LOC[SEL]:-}} out
	case $1 in
	j | J)
		# Panes on this computer only. On a linked computer's row J does nothing but say so:
		# focus moves only where you press J, never in tmux over there.
		[[ -n ${P_HOST[SEL]:-} ]] && { flash "J jumps to panes on this computer only"; return; }
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
		[[ -n $id ]] || { [[ -n ${P_HOST[SEL]:-} ]] && flash "that pane has no name; name it on ${P_HOST[SEL]} to message it"; return; }
		ask "Message to $name:" || { flash "message cancelled"; return; }
		out=$("$ASAY" --from panel "$id" "$REPLY" 2>&1 | tail -n 1)
		flash "${out#agent-say: }" ;;
	n | N)
		if [[ -n ${P_HOST[SEL]:-} ]]; then
			# A pane on a linked computer: agent-say name runs there, over the link's ssh.
			local h=${P_HOST[SEL]} rid=${P_RID[SEL]:-} st
			[[ $h =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return
			[[ $rid =~ ^%[0-9]+$ ]] || { flash "on $h: can't tell which pane that is (update tmux-revive there)"; return; }
			ask "New name for $name on $h:" || { flash "rename cancelled"; return; }
			# The same letters a name may have there, so no quote or shell character gets through.
			[[ $REPLY =~ ^[A-Za-z0-9][A-Za-z0-9_.:+=-]*$ ]] || { flash "that can't be a name: use letters, digits and . _ - : + ="; return; }
			flash "naming it on $h…"; draw
			out=$(remote_run "$h" "AGENT_SAY_PANE='$rid' $REMOTE_NAME_CMD '$REPLY' </dev/null 2>&1" | tail -c 4096)
			st=$?
			out=$(grep -v '^[[:space:]]*$' <<<"$out" | head -n 1)
			clean out
			out=${out#agent-say: } out=${out:0:120}
			if ((st == 124 || st == 255)); then flash "on $h: couldn't be reached to rename"
			else flash "on $h: ${out:-rename failed}"; fi
			((st == 0)) && SEL_ID="$REPLY@$h" # the row goes by its new name
			RFETCH_T[$h]=0 # and ask it for its rows again, to show it
			return
		fi
		[[ -n $id ]] || return
		ask "New name for $name:" || { flash "rename cancelled"; return; }
		out=$(AGENT_SAY_PANE=$id "$ASAY" name "$REPLY" 2>&1 | head -n 1)
		flash "${out#agent-say: }" ;;
	l | L)
		# Links waiting for their login first, then every ssh host not linked yet (the selected
		# pane's first), then "other host...".
		local hosts=() labels=() seen=" " h i j d
		for d in "$ASTATE"/links/*/; do
			[[ -f $d/on && -f $d/login ]] || continue
			h=$(basename "$d")
			[[ $h =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
			seen+="$h " hosts+=("$h") labels+=("$h  · needs login: type its password")
		done
		for j in -1 "${!P_SSH[@]}"; do
			((j < 0)) && i=$SEL || i=$j
			h=${P_SSH[i]:-}
			[[ -n $h && $seen != *" $h "* ]] && ! linked "$h" || continue
			seen+="$h " hosts+=("$h") labels+=("$h  · ssh in ${P_NAME[i]:-${P_LOC[i]}}")
		done
		for i in "${!X_SSH[@]}"; do
			h=${X_SSH[i]}
			[[ $seen != *" $h "* ]] && ! linked "$h" || continue
			seen+="$h " hosts+=("$h") labels+=("$h  · ssh in ${X_WHERE[i]}")
		done
		hosts+=("") labels+=("other host… (type its name)")
		pick "LINK AGENTS ON" "${labels[@]}" || { flash "link cancelled"; return; }
		h=${hosts[PICKED]}
		if [[ -z $h ]]; then
			ask "Host to link (as you'd type after ssh):" || { flash "link cancelled"; return; }
			h=$REPLY
			[[ $h =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { flash "not a host name: $h"; return; }
		fi
		# A link whose login dropped: its key was confirmed when it was linked (and the link
		# checks it still), so only the login is asked for.
		if linked "$h" && [[ -f $ASTATE/links/$h/login ]]; then
			flash "logging in to $h…"; draw
			if login_window "$h"; then flash "logged in to $h; its link picks up again"; else flash "not logged in to $h"; fi
			return
		fi
		# Its host key first, as ssh itself (and agent-say link on a terminal) would have it: a host
		# linked before that still has the key you confirmed then, or one ssh already trusts (its
		# key in a known_hosts file ssh reads for it), links as it is. Only where ssh would ask (a
		# key it doesn't know), or the key changed, are you asked: say no, and nothing is linked.
		# No is first, so Enter alone doesn't trust a key.
		flash "reading $h's host key…"; draw
		# What link is told: the keys shown and confirmed here (--fingerprint), so it is bound to
		# exactly those, never to what it might scan a moment later; or, linking with no key found,
		# that none is to be taken (--no-key). A relink gives none: it keeps the one recorded, and
		# refuses another.
		local -a keys largs=()
		local k linked_msg=""
		read_host_keys "$h"
		keys=("${KEYS[@]}")
		PREV=()
		case $KEY_STATE in
			recorded)
				linked_msg="relinked $h with the key you confirmed" ;;
			trusted)
				for k in "${keys[@]}"; do largs+=(--fingerprint "$k"); done
				linked_msg="linked to $h with the key ssh already trusts for it: ${keys[*]}" ;;
			*)
				if ((${#keys[@]})); then
					labels=("No, don't link $h")
					for k in "${keys[@]}"; do labels+=("Yes, link: its key is $k"); done
				else
					labels=("No, don't link $h" "Yes, link (no key found in known_hosts or by ssh-keyscan)")
				fi
				if [[ $KEY_STATE == changed ]]; then
					pick "WARNING: $h's HOST KEY CHANGED since you linked it" "${labels[@]}" && ((PICKED > 0)) || { flash "link cancelled"; return; }
				else
					pick "HOST KEY OF $h" "${labels[@]}" && ((PICKED > 0)) || { flash "link cancelled"; return; }
				fi
				if ((${#keys[@]})); then
					keys=("${keys[PICKED - 1]}")
					largs=(--yes --fingerprint "${keys[0]}")
				else
					largs=(--yes --no-key)
				fi ;;
		esac
		flash "linking $h…"; draw
		link_out() { # what link said: all of it (LOUT), and the line to show (out)
			LOUT=$(timeout 30 "$ASAY" link "$h" "$@" </dev/null 2>&1)
			out=$(grep -E '^(linked to|agent-say:)' <<<"$LOUT" | grep -v '^agent-say: WARNING' | head -n 1)
		}
		link_out "${largs[@]}"
		# Relinked, and turned away for its key: another key answers to it now. You see that one,
		# warned, and the link is bound to it only if you pick it here (by its fingerprint).
		if [[ $LOUT == *"check it, then link again and confirm the new key"* ]]; then
			read_host_keys "$h" --new
			keys=("${KEYS[@]}")
			((${#keys[@]})) || { flash "$h's host key isn't the one you confirmed, and ssh-keyscan shows no other, so it's not linked"; return; }
			labels=("No, don't link $h")
			for k in "${keys[@]}"; do labels+=("Yes, link: its key is $k"); done
			pick "WARNING: $h's HOST KEY CHANGED since you linked it" "${labels[@]}" && ((PICKED > 0)) || { flash "link cancelled"; return; }
			keys=("${keys[PICKED - 1]}") KEY_STATE=changed linked_msg=""
			largs=(--yes --fingerprint "${keys[0]}")
			flash "linking $h…"; draw
			link_out "${largs[@]}"
		fi
		# A host that wants a password: you log in once, in a popup, and the link is made over
		# that login. The password can only go to a computer holding a key you just confirmed
		# (agent-say's login checks it strictly before ssh asks), so none confirmed, no login.
		# Relinked, it is the key the link recorded (login_window with none given takes that).
		if [[ $out == *"$h needs a login"* ]]; then
			((${#keys[@]})) || { flash "no host key of $h to confirm, so no password is sent to it; not linked"; return; }
			[[ $KEY_STATE == recorded ]] && keys=()
			flash "logging in to $h…"; draw
			login_window "$h" "${keys[@]}" || { flash "not logged in to $h; not linked"; return; }
			flash "linking $h…"; draw
			link_out "${largs[@]}"
		fi
		clean out
		[[ -n $linked_msg && $out == "linked to "* ]] && out=$linked_msg
		flash "${out#agent-say: }" ;;
	u | U | d | D)
		local hosts=() labels=() d h
		for d in "$ASTATE"/links/*/; do
			[[ -f $d/on ]] || continue
			h=$(basename "$d")
			clean h
			hosts+=("$h") labels+=("$h  · $(grep -c . "$d/names" 2>/dev/null || echo 0) names")
		done
		((${#hosts[@]})) || { flash "nothing is linked"; return; }
		pick "UNLINK" "${labels[@]}" || { flash "unlink cancelled"; return; }
		h=${hosts[PICKED]}
		flash "unlinking $h…"; draw
		out=$(timeout 30 "$ASAY" unlink "$h" 2>&1 | tail -n 1)
		clean out
		[[ -d $ASTATE/links/$h ]] || rm -f "$RDIR/$h.rows" # what it kept of that computer
		flash "${out#agent-say: }" ;;
	v | V)
		# For another user's pane, here or on a linked computer: tmux-revive for that user.
		v_mode
		[[ $VMODE == install || $VMODE == update ]] && { user_note "$VMODE"; return; }
		[[ $VMODE == current ]] && { flash "${P_USER[SEL]} already has tmux-revive ${P_INST[SEL]}"; return; }
		# Otherwise update tmux-revive on the selected pane's linked computer, over the link's ssh.
		local h=${P_HOST[SEL]:-} last st msg w
		[[ -n $h ]] || { flash "V works on a linked computer's pane, or on another user's pane"; return; }
		[[ $h =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return
		pick "Update tmux-revive on $h?" "Yes, update it over ssh" "No" && ((PICKED == 0)) || { flash "update cancelled"; return; }
		flash "updating tmux-revive on $h…"; draw
		out=$(RTIMEOUT=300 remote_run "$h" "$REMOTE_UPDATE_CMD" | tail -c 4096)
		st=$?
		# Its last line, as text: the installer's colour codes (and any other escape sequence)
		# go whole, not just their ESC, and so does its "xx" or "!!" in front of the message.
		last=$(LC_ALL=C sed -E $'s#\e\\[[0-9:;<=>?]*[ -/]*[@-~]##g; s#\e\\][^\a\e]*(\a|\e\\\\)?##g; s#\e.##g' <<<"$out" |
			grep -v '^[[:space:]]*$' | tail -n 1)
		clean last
		[[ $last =~ ^[[:space:]]*(xx|!!|==\>)[[:space:]]+(.*)$ ]] && last=${BASH_REMATCH[2]}
		if ((st == 0)); then msg="on $h: " last=${last:-updated}
		elif ((st == 124 || st == 255)); then msg="on $h: couldn't be reached to update" last=""
		else msg="on $h: update failed${last:+: }"; fi
		# Cut to what the bar has room for, next to its keys.
		w=$((IW - ${#msg} - 4)); ((w < 20)) && w=20
		((${#last} > w)) && last="${last:0:w-1}…"
		flash "$msg$last"
		RFETCH_T[$h]=0 # and ask it for its rows, and so its version, again
		;;
	g | G | i | I) # I: the key it had before, kept so it still works
		# Access: agents on two linked computers asking to talk through this one (waiting), and
		# those you let (approved). Only here, by a key you press, can two of them be let talk.
		# An approval lasts SESSION_TTL (a day) from when it was given or refreshed; agent-say
		# clears what has lapsed first. Declined ones aren't listed: they lapse on their own.
		local ids=() labels=() d f t txt g a b w ttl now
		ttl=$(timeout 10 "$ASAY" _cull 2>/dev/null)
		[[ $ttl =~ ^[1-9][0-9]{0,9}$ ]] || ttl=86400
		printf -v now '%(%s)T' -1
		for d in "$ASTATE"/intros/*/; do
			[[ -f $d/from ]] || continue
			f=$(head -n 1 "$d/from") t=$(head -n 1 "$d/to")
			clean f t
			((${#ids[@]})) || ids+=("") labels+=("${NOTE}WAITING")
			ids+=("i $(basename "$d")") labels+=("${f:0:30} → ${t:0:30}")
		done
		local nw=${#ids[@]}
		while read -r g a b f t w _; do
			[[ $g == allow && $w =~ ^[0-9]{1,12}$ ]] && ((w + ttl > now)) || continue
			clean f t
			w=$((w + ttl - now))
			((${#ids[@]} > nw)) || ids+=("") labels+=("${NOTE}APPROVED")
			ids+=("g $a $b") labels+=("${f:0:30} → ${t:0:30} · $((w / 3600))h $((w % 3600 / 60))m left")
		done < <(cat "$ASTATE/grants" 2>/dev/null)
		((${#ids[@]})) || { flash "nothing waiting or approved"; return; }
		pick "ACCESS" "${labels[@]}" || return
		read -r g a b <<<"${ids[PICKED]}"
		if [[ $g == i ]]; then
			d="$ASTATE/intros/$a"
			[[ $a =~ ^[0-9a-f]{32}$ && -f $d/from ]] || { flash "that request is gone"; return; }
			f=$(head -n 1 "$d/from") t=$(head -n 1 "$d/to") txt=$(head -c 180 "$d/intro")
			clean f t txt
			# Its words (three lines at most), then the two choices. Approving takes a code typed
			# back in a popup, so agents on other computers can't approve it (one running as you
			# here could), and neither can a stray Enter here.
			labels=()
			while [[ -n $txt ]] && ((${#labels[@]} < 3)); do labels+=("$NOTE${txt:0:60}"); txt=${txt:60}; done
			# Its agent restarted since asking (its computer reports another session in that
			# pane, or none): what it sent is from a conversation that's over.
			local fs="" cur=""
			{ read -r fs <"$d/from-session"; } 2>/dev/null || true
			if [[ $fs == s:* && ${f#*@} =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
				cur=$(awk -v n="${f%@*}" '$1 == n {print $2; exit}' "$ASTATE/links/${f#*@}/sessions" 2>/dev/null)
				[[ "s:$cur@${f#*@}" == "$fs" ]] || labels+=("$NOTE${f%@*} has restarted since asking")
			fi
			local nt=${#labels[@]}
			PREV=(); draw # the list away first, so the two boxes never overlap
			pick "${f:0:24} → ${t:0:24}" "${labels[@]}" "Approve" "Deny" || { PREV=(); return; } # PREV: all of it drawn again over the box
			if ((PICKED == nt)); then
				out=$(code_popup "Allow $f to talk with $t?" allow approve "$a")
				PREV=()
				[[ -n $out ]] || out="not approved: the code didn't match, so it's still waiting"
			else
				out=$("$ASAY" _intro deny "$a" 2>&1 | tail -n 1)
			fi
		else
			# Refresh first, so a bare Enter takes nothing away.
			local l=${labels[PICKED]%% · *} lt=${labels[PICKED]:0:60}
			PREV=(); draw
			pick "$lt" "Refresh" "Cancel" || { PREV=(); return; }
			if ((PICKED == 0)); then
				# The same code popup as Approve: no agent can refresh its own access.
				out=$(code_popup "Refresh $l for another day?" refresh grant_refresh "$a" "$b")
				PREV=()
				if [[ $out == refreshed:* ]]; then out="refreshed: $l · $((ttl / 3600))h left"
				elif [[ -z $out ]]; then out="not refreshed: the code didn't match"; fi
			else
				out=$("$ASAY" revoke "$a" "$b" 2>&1) && out="cancelled: $l"
			fi
			out=${out##*$'\n'}
		fi
		PREV=() # the boxes drawn over, all of it again
		clean out
		flash "${out#agent-say: }" ;;
	p | P) PEEK=$((!PEEK)) ;;
	x | X) FULL=1 PEEK=1 ;; # the peek over the whole art; pressed again, it stays there
	c | C) FULL=0 ;;        # only c puts the art back
	enter | $'\t') [[ ${P_STATE[SEL]:-} == asking ]] && answer ;; # Tab: focus to the question
	a | A)
		SCENE=$(((SCENE + 1) % ${#SCENES[@]}))
		flash "art: ${TITLES[SCENE]}" ;;
	s | S)
		if "$BASH" "$REVIVE_ROOT/scripts/save.sh" manual >/dev/null 2>&1; then flash "saved"; else flash "save failed (see: tmux-revive log)"; fi ;;
	q | Q) exit 0 ;;
	'?') help_view ;; # quoted: a bare ? would match every key
	# A digit N goes to window N, as the # column and tmux's status bar number it: the first pane
	# on this computer, top of the list down, whose window is N (with several sessions, the
	# first session listed that has one). None there: the selection stays. Windows 10 and up,
	# and linked computers' panes, are reached with the arrows.
	[0-9])
		local w
		for w in "${!P_ID[@]}"; do
			[[ -z ${P_HOST[w]} && ${P_WP[w]%%.*} == "$1" ]] && { SEL=$w; break; }
		done ;;
	# The list goes round: up from the first pane is the last, down from the last the first.
	up) ((${#P_ID[@]})) && SEL=$(((SEL - 1 + ${#P_ID[@]}) % ${#P_ID[@]})) ;;
	down) ((${#P_ID[@]})) && SEL=$(((SEL + 1) % ${#P_ID[@]})) ;;
	esac
	SEL_ID=${P_ID[SEL]:-}
}

restore_term() {
	[[ -n ${STTY_SAVED:-} ]] && stty "$STTY_SAVED" 2>/dev/null
	printf '%s' "$e[?25h$e[?1049l"
}

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
if ((PEEKMODE)); then
	# The pane's bottom rows exactly, blank ones included (a $( ) would drop those).
	pane_here "$PEEK_ID" || exit 1 # no such pane
	mapfile -t L < <(tm capture-pane -p -t "$PEEK_ID" 2>/dev/null)
	end=$((${#L[@]} - 1))
	start=$((end - PEEK_N + 1))
	((start < 0)) && start=0
	for ((i = start; i <= end; i++)); do
		l=${L[i]}
		clean l
		printf '%s\n' "$l"
	done
	exit 0
fi
if ((KEYSMODE)); then
	# Asked for by another computer's panel: a pane id, then keys from the short list only.
	shift
	[[ ${1:-} =~ ^%[0-9]+$ ]] && (($# >= 2 && $# <= 17)) ||
		{ echo "usage: panel.sh --keys %PANE KEY... (1-16 keys)" >&2; exit 2; }
	for k in "${@:2}"; do key_ok "$k" || { echo "panel.sh --keys: not a key it sends" >&2; exit 2; }; done
	pane_here "$1" || exit 1
	keys_send "$@" && echo sent
	exit
fi
if ((SHOWMODE)); then
	# Once asked for by another computer's J, to select a pane here and switch the client used
	# last to it. That moved focus away from whoever was working here, so it changes nothing
	# now; an older computer's J that asks says it couldn't show it.
	echo "panel.sh --show is no longer supported; nothing was changed" >&2
	exit 1
fi
if ((ASKMODE)); then
	# For daemon.sh's question alerts: the agent panes whose screen reads as asking, by the
	# same look the panel takes (screen_state), without the panel's git and CPU work.
	while read -r pid ppid args; do PCHILD[$ppid]+="$pid " PARGS[$pid]=$args; done < <(ps -ww -eo pid=,ppid=,args= 2>/dev/null)
	while IFS=$'\t' read -r id loc ppid0 name; do
		q=("$ppid0") kind=""
		while ((${#q[@]})) && [[ -z $kind ]]; do
			p=${q[0]} q=("${q[@]:1}")
			kind=$(agent_kind "${PARGS[$p]:-}")
			# shellcheck disable=SC2206
			[[ -n ${PCHILD[$p]:-} ]] && q+=(${PCHILD[$p]})
		done
		[[ -n $kind && $(screen_state "$id") == asking ]] || continue
		clean loc name
		printf '%s\t%s\t%s\n' "$id" "$loc" "$name" # place before name: a name may be empty
	done < <(tm list-panes -a -F $'#{pane_id}\t#{session_name}:#{window_index}.#{pane_index}\t#{pane_pid}\t#{@agent}' 2>/dev/null)
	exit 0
fi
if ((ROWS)); then
	# CPU is measured between two looks. The look the last ask took, kept here, is the first
	# when it's from 1 to 60 s ago: then the CPU is over the time since (a panel asks every
	# 10 s), as this computer's own panel measures it between frames. Otherwise two looks 0.3 s
	# apart, in which an agent waiting at 1 or 2% rounds to nothing.
	rows_ticks_load "$RDIR/ticks"
	[[ -n $T_PREV ]] || { gather; sleep 0.3; }
	gather
	rows_ticks_save "$RDIR/ticks"
	# First, its version on a line of its own: a panel that doesn't know the line skips it,
	# since a row must start with a pane id.
	[[ -n $VERSION ]] && printf '#version %s\n' "$VERSION"
	[[ $ME =~ $USER_RE ]] && printf '#owner %s\n' "$ME"
	for i in "${!P_ID[@]}"; do
		[[ ${P_STATE[i]} == self ]] && continue
		folder=${P_DIR[i]##*/}
		# Whose pane it is, and whether that user has tmux-revive here, likewise.
		[[ ${P_USER[i]} =~ $USER_RE ]] && printf '#user %s %s %s\n' "${P_ID[i]}" "${P_USER[i]}" "${P_INST[i]:--}"
		# Context left goes on a line of its own: a panel from before it skips the line, where a
		# field added to the row would make it drop the row.
		[[ -n ${P_CTX[i]} ]] && printf '#ctx %s %s\n' "${P_ID[i]}" "${P_CTX[i]}"
		# Work going on in the background: the row says working, as a panel from before this
		# shows it, and a line before it says it takes input.
		st=${P_STATE[i]}
		[[ $st == agents ]] && { printf '#agents %s\n' "${P_ID[i]}"; st=working; }
		printf '%s\x1f' "${P_ID[i]}" "${P_LOC[i]}" "${P_NAME[i]}" "${P_APP[i]}" "$st" "$folder" "${P_GIT[i]}" "${P_CPU[i]}" "${P_MEM[i]}"
		printf '%s\n' "${P_AGENT[i]}"
	done
	exit 0
fi
if ((ONCE)); then
	TICK=${REVIVE_PANEL_TICK:-0} # tests draw particular frames of the artwork
	gather
	sleep 0.5 # CPU is measured between two looks
	gather
	# Tests pick the selected pane by its id (name@host for a linked computer's).
	for i in "${!P_ID[@]}"; do [[ -n ${REVIVE_PANEL_SEL:-} && ${P_ID[i]} == "$REVIVE_PANEL_SEL" ]] && SEL=$i; done
	draw
	exit 0
fi
[[ -t 0 && -t 1 ]] || { echo "tmux-revive panel needs a terminal" >&2; exit 1; }
printf '%s' "$e[?1049h$e[?25l$e[2J"
# Keys pressed while the panel is busy gathering must not be echoed: an arrow's ^[[A printed at
# the bottom line scrolls the whole screen. Echo stays off for the panel's whole run (keys are
# read one at a time anyway) and the terminal's own settings come back on exit.
STTY_SAVED=$(stty -g 2>/dev/null)
stty -echo -icanon 2>/dev/null
on_exit restore_term
# Other computers' screens it fetched go when it closes.
on_exit 'for f in "${!PEEK_FILES[@]}"; do rm -f "$f" "$f.fail"; done'
trap 'exit 0' INT TERM
trap 'printf "%s" "$e[2J"; PREV=() TCOLS="" ATOP=()' WINCH
case ${REVIVE_PANEL_SPLASH:-} in
1) splash ;;
0) ;;
*) [[ $(opt @revive-panel-splashed '') == 1 ]] || { splash; tm set-option -g @revive-panel-splashed 1 2>/dev/null; } ;;
esac
PREV=() # after the splash: paint the whole panel

declare -A SSH_SEEN=() LOGIN_SEEN=()
# keys KEY: act on KEY and on any keys already waiting behind it (a held arrow), so that they
# are drawn once. Keys that only move the selection set nav.
keys() {
	key=$1
	while :; do
		[[ -z $key || $key == $'\r' ]] && key=enter # read stops at the newline Enter sends
		if [[ $key == "$e" ]]; then
			rest=""
			IFS= read -rsn2 -t 0.05 rest || true
			case $rest in '[A') key=up ;; '[B') key=down ;; *) key="" ;; esac
		fi
		case $key in
		up | down | [0-9]) act "$key"; nav=1 ;;
		"") ;;
		*) act "$key"; nav=0; break ;;
		esac
		key=""
		read -t 0 && IFS= read -rsn1 key || break
	done
}
held=0
while :; do
	# Moving the selection only redraws from what was gathered last; everything is looked at
	# again on the next refresh or any other key, so the arrows stay quick.
	if ((!nav)); then
		gather
		for h in "${P_SSH[@]}" "${X_SSH[@]}"; do
			[[ -n $h && -z ${SSH_SEEN[$h]:-} ]] || continue
			SSH_SEEN[$h]=1
			linked "$h" || flash "new ssh: $h · L links it"
		done
		# A link whose login dropped (a reboot over there, the network gone): said once.
		for d in "$ASTATE"/links/*/; do
			h=$(basename "$d")
			[[ $h =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
			if [[ -f $d/on && -f $d/login ]]; then
				[[ -n ${LOGIN_SEEN[$h]:-} ]] || flash "$h needs login · L to type its password"
				LOGIN_SEEN[$h]=1
			else
				LOGIN_SEEN[$h]=""
			fi
		done
		TCOLS="" MSG_OLD=1 # looked at again along with the panes
	fi
	# Keep the same pane selected when panes come and go.
	if [[ -n $SEL_ID ]]; then
		for i in "${!P_ID[@]}"; do [[ ${P_ID[i]} == "$SEL_ID" ]] && SEL=$i; done
	fi
	((SEL >= ${#P_ID[@]})) && SEL=$((${#P_ID[@]} ? ${#P_ID[@]} - 1 : 0))
	SEL_ID=${P_ID[SEL]:-}
	# A key pressed while it gathered is taken first, so one draw shows both. Not twice running,
	# so keys arriving all the time can't keep the panel from drawing.
	if ((!nav && !held && ${#PREV[@]})) && read -t 0; then
		held=1 key=""
		IFS= read -rsn1 key
		keys "$key"
		continue
	fi
	held=0
	draw
	nav=0
	key=""
	if ! IFS= read -rsn1 -t "$REFRESH" key; then
		((TICK++)) # the animation moves on with the clock, not with keys
		continue
	fi
	keys "$key"
done
