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

ONCE=0 ROWS=0 PEEKMODE=0 KEYSMODE=0 ASKMODE=0
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
row() { # row CONTENT: one line inside the frame, cut or padded to the inner width
	local c=$1
	vlen "$c"
	((VLEN > IW)) && { c=$(trim_colored "$c" "$IW"); VLEN=$IW; }
	line "$FRAME║$R $c$(rep ' ' $((IW - VLEN))) $FRAME║$R"
}
# A section title on a solid blue band that fades into the black on both sides: shading as
# a short transition between two colours, the way the artpack groups used it.
# A question waiting on you gets the band in magenta, the colour of the asking state.
tab() { local c=${2:-4}; printf '%s' "$e[3${c}m░▒▓$e[4${c}m$B$BWHT $1 $R$e[3${c}m▓▒░$R"; } # tab TITLE [COLOUR 0-7]
sectk() { # sectk TITLE KEYS [COLOUR]: a divider with a title, and the keys for that section at its right end
	local t="$FRAME╠═$(tab "$1" "${3:-4}")" a
	vlen "$t"; a=$VLEN
	vlen "$2"
	line "$t$FRAME$(rep ═ $((W - 5 - a - VLEN)))$R $2 $FRAME══╣$R"
}
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
	local k
	if [[ ${3:-} == still ]]; then AT=0; else AT=$TICK; fi
	# The same frame again (answering a question redraws every 0.3 s) is kept, not redrawn.
	k="$SCENE $1 $2 $AT"
	if [[ -n ${ART_MEMO[$k]+set} ]]; then mapfile -t ART <<<"${ART_MEMO[$k]}"; return; fi
	canvas "$1" "$2"
	SEED=$((7919 * (SCENE + 1)))
	((ART_W > 0 && ART_H > 0)) && "scene_${SCENES[SCENE]}"
	emit
	((${#ART_MEMO[@]} > 6)) && ART_MEMO=()
	ART_MEMO[$k]=$(printf '%s\n' "${ART[@]}")
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

claude_status() { # Claude Code's own idle/busy, from its session record
	local f
	for f in "$HOME"/.claude*/sessions/"$1".json; do
		[[ -f $f ]] && { jq -r '.status // empty' "$f" 2>/dev/null; return; }
	done
}

# ------------------------------------------------------------------ context left
# How much of an agent's context window is still free, as a percentage, read from the
# record the agent itself keeps of its session: Claude Code's transcript (the session record
# under sessions/PID.json names it), Codex's rollout file (the file its process holds open).
# Each holds the tokens the last turn sent; Codex also says its window. Claude Code doesn't:
# REVIVE_CLAUDE_WINDOW when set, else a million for a model or setting that has one (the
# Claude 5 family, Opus and Sonnet 4.6 on, an [1m] model, or a session already past 200k),
# else 200k.
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
codex_ctx_file() { # a rollout file -> percent left
	local u w
	read -r u w < <(tail -c 2000000 "$1" 2>/dev/null | grep '"token_count"' |
		jq -Rr 'fromjson? | .payload | select(.type == "token_count" and .info)
			| "\(.info.last_token_usage.total_tokens) \(.info.model_context_window)"' 2>/dev/null | tail -n 1)
	ctx_pct "${u:-}" "${w:-}"
}
ctx_left() { # ctx_left KIND AGENT_PID PID... -> CTX: percent of its context window left, or nothing
	local kind=$1 apid=$2 f sid p
	shift 2
	CTX="" # set here, not printed: the files' answers are kept between frames
	case $kind in
	claude)
		for f in "$HOME"/.claude*/sessions/"$apid".json; do
			[[ -f $f ]] || continue
			sid=$(jq -r '.sessionId // empty' "$f" 2>/dev/null)
			[[ $sid =~ ^[A-Za-z0-9-]+$ ]] || return 0
			for f in "${f%/sessions/*}"/projects/*/"$sid".jsonl; do
				[[ -f $f ]] && { ctx_cached "$f" claude_ctx_file; return 0; }
			done
			return 0
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
}
lines_state() { # lines_state ARRAY: the same, for a screen already read (a linked computer's peek)
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
	if ((!prompt)) && [[ $tail =~ $Q_RE ]]; then echo asking
	elif [[ $tail =~ $W_RE ]]; then echo working
	else echo waiting; fi
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
	local p l f t=0
	for p in "$@"; do
		read -r l 2>/dev/null <"/proc/$p/stat" || continue # gone since ps ran
		read -ra f <<<"${l##*) }"
		t=$((t + f[11] + f[12]))
	done
	echo "$t"
}

# One record per pane, in these parallel arrays. P_RID is a linked computer's own pane id.
P_ID=() P_LOC=() P_NAME=() P_APP=() P_STATE=() P_DIR=() P_GIT=() P_CPU=() P_MEM=() P_CTX=() P_AGENT=() P_SSH=() P_HOST=() P_RID=()
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
	local pid ppid rss pcpu args id loc ppid0 cmd path name kind apid st q p tree cpu mem now dt t ssh ctx
	PCHILD=() PARGS=() PRSS=() PCPU=() PPAR=() PUID=() INPANE=()
	while read -r pid ppid uid rss pcpu args; do
		PCHILD[$ppid]+="$pid " PARGS[$pid]=$args PRSS[$pid]=$rss PCPU[$pid]=$pcpu PPAR[$pid]=$ppid PUID[$pid]=$uid
	done < <(ps -ww -eo pid=,ppid=,uid=,rss=,pcpu=,args= 2>/dev/null) # -ww: never cut to $COLUMNS
	now=${EPOCHREALTIME:-$SECONDS}
	P_ID=() P_LOC=() P_NAME=() P_APP=() P_STATE=() P_DIR=() P_GIT=() P_CPU=() P_MEM=() P_CTX=() P_AGENT=() P_SSH=() P_HOST=() P_RID=()
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
			if [[ -n $T_PREV && -n ${TICKS_PREV[$id]:-} ]]; then
				dt=$(awk -v a="$now" -v b="$T_PREV" 'BEGIN{printf "%.3f", a-b}')
				cpu=$(awk -v d=$((t - TICKS_PREV[$id])) -v c="$CLK" -v s="$dt" 'BEGIN{v = s > 0 ? d / c / s * 100 : 0; if (v < 0) v = 0; printf "%d", v + 0.5}')
			fi
			TICKS_PREV[$id]=$t
		else
			cpu=0
			for p in "${tree[@]}"; do cpu=$(awk -v a="$cpu" -v b="${PCPU[$p]:-0}" 'BEGIN{printf "%d", a + b + 0.5}'); done
		fi
		ctx=""
		if [[ $id == "${TMUX_PANE:-}" ]]; then
			st=self P_APP+=("panel") P_AGENT+=(0)
		elif [[ -n $kind ]]; then
			st=$(screen_state "$id")
			if [[ $kind == claude && $st != asking ]]; then
				[[ $(claude_status "$apid") == busy ]] && st=working || st=waiting
			fi
			ctx_left "$kind" "$apid" "${tree[@]}"
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
		P_SSH+=("$ssh") P_HOST+=("") P_RID+=("")
		P_ID+=("$id") P_LOC+=("$loc") P_NAME+=("$name") P_STATE+=("$st")
		P_DIR+=("$path") P_GIT+=("$(git_info "$path")") P_CPU+=("$cpu") P_MEM+=("$mem") P_CTX+=("$ctx")
	done < <(tm list-panes -a -F $'#{pane_id}\t#{session_name}:#{window_index}.#{pane_index}\t#{pane_pid}\t#{pane_current_command}\t#{pane_current_path}\t#{@agent}' 2>/dev/null)
	T_PREV=$now
	outside_ssh
	((ROWS)) || remote_panes
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
declare -A RFETCH_T=() RFETCH_PID=() PFETCH_T=() PFETCH_PID=() PEEK_FILES=() RVER=()
PEEK_EVERY=$REFRESH # seconds between asks for a linked pane's screen; none while answering
cache_dir() { # $RDIR, for this user only (an older panel made it with the default umask)
	[[ -d $RDIR ]] || mkdir -p "$RDIR"
	[[ -n $(find "$RDIR" -maxdepth 0 -perm 700 2>/dev/null) ]] || chmod 700 "$RDIR" 2>/dev/null
}
remote_run() { # remote_run HOST COMMAND: run it on that computer over the link's ssh connection
	# shellcheck disable=SC2086 # AGENT_SAY_SSH may carry its own arguments, as in agent-say
	timeout "${RTIMEOUT:-8}" ${AGENT_SAY_SSH:-ssh} -o BatchMode=yes -o ConnectTimeout=5 -o ControlMaster=auto \
		-o "ControlPath=$ASTATE/ssh-%C" -o ControlPersist=120 "$1" "$2" </dev/null 2>/dev/null
}
fetch_rows() { remote_run "$1" "$REMOTE_ROWS_CMD"; }
# rows_get HOST FILE: the rows into FILE, through a temporary file of its own (two panels may
# be asking at once). Capped in bytes: one endless line from over there must not freeze this.
rows_get() {
	local t st
	t=$(mktemp "$2.XXXXXX") || return
	fetch_rows "$1" | head -c 262144 >"$t"
	st=${PIPESTATUS[0]}
	if ((st == 0 || st == 141)); then mv -f "$t" "$2"; rm -f "$2.old"; return; fi # 141: cut off by head
	rm -f "$t"
	# Reached (ssh and timeout fail with 255 and 124), but no rows: a tmux-revive too old for them.
	((st == 124 || st == 255)) || : >"$2.old"
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
	peek_get "$1" "$2" "$3" "$4" &
	PFETCH_PID[$k]=$!
}
remote_peek() { # remote_peek LINES -> L: the selected linked pane's screen, or why it can't be shown
	local h=${P_HOST[SEL]} id=${P_RID[SEL]:-} n=$1 f l
	L=("" "  on $h: no peek (update tmux-revive there)")
	[[ ${P_STATE[SEL]:-} == unreachable ]] && L=("" "  on $h: can't be reached to peek")
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
	local d h f id loc name app st folder git cpu mem agent got v S=$'\x1f'
	local -A rctx
	P_GROUPS=0
	# Other computers' screens are kept no longer than they're shown: a minute at most.
	[[ -d $RDIR ]] && find "$RDIR" -maxdepth 1 \( -name '*.peek-*' -o -name '*.answered-*' \) -mmin +1 -delete 2>/dev/null
	for d in "$ASTATE"/links/*/; do
		[[ -f $d/on ]] || continue
		h=$(basename "$d")
		[[ $h =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
		if ((ONCE)); then remote_fetch "$h" now; else remote_fetch "$h"; fi
		f="$RDIR/$h.rows" got=0 RVER[$h]="" rctx=()
		# Rows a minute old or newer; older means that computer stopped answering.
		if [[ -s $f && -n $(find "$f" -mmin -1 2>/dev/null) ]]; then
			RVER[$h]=old # unless it says which version it is
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
				# Only a complete row from a pane: a %id first and the agent flag last.
				[[ $id =~ ^%[0-9]+$ && $agent =~ ^[01]$ ]] || continue
				# Cut before cleaning, so a huge field costs nothing to look at.
				loc=${loc:0:64} name=${name:0:64} app=${app:0:64} st=${st:0:16} folder=${folder:0:256} git=${git:0:128}
				clean loc name app st folder git
				[[ $name =~ ^[A-Za-z0-9][A-Za-z0-9_.:+=-]*$ ]] || name=""
				case $st in asking | working | waiting | shell | program) ;; *) st=program ;; esac
				[[ $st == asking && $f -ot $RDIR/$h.answered-${id#%} ]] && st=waiting # answered from here since
				[[ $cpu =~ ^[0-9]{1,4}$ ]] || cpu=0
				[[ $mem =~ ^[0-9]{1,10}$ ]] || mem=0
				[[ $agent == 1 ]] || agent=0
				P_ID+=("${name:+$name@$h}") P_LOC+=("${loc:0:20}") P_NAME+=("$name") P_APP+=("${app:0:12}")
				P_STATE+=("$st") P_DIR+=("${folder:0:40}") P_GIT+=("${git:0:30}") P_CPU+=("$cpu") P_MEM+=("$mem")
				P_CTX+=("${rctx[$id]:-}") P_AGENT+=("$agent") P_SSH+=("") P_HOST+=("$h") P_RID+=("$id")
				got=1
			done < <(head -n 200 "$f")
		fi
		if ((!got)); then
			# Names only, from the link.
			[[ -e $f.old ]] && RVER[$h]=old
			st=linked
			[[ -s $f || ! -s $d/error ]] || st=unreachable
			while IFS= read -r name; do
				[[ $name =~ ^[A-Za-z0-9][A-Za-z0-9_.:+=-]*$ ]] || continue
				P_ID+=("$name@$h") P_LOC+=("") P_NAME+=("$name") P_APP+=("") P_STATE+=("$st") P_DIR+=("")
				P_GIT+=("") P_CPU+=(0) P_MEM+=(0) P_CTX+=("") P_AGENT+=(0) P_SSH+=("") P_HOST+=("$h") P_RID+=("")
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
SPIN=(▖ ▘ ▝ ▗)

state_cell() { # coloured status, 18 characters wide
	case $1 in
	asking) printf '%s' "$B$BMAG$BLINK?$R$B$BMAG NEEDS ANSWER    $R" ;;
	working) printf '%s' "$BYEL${SPIN[TICK % 4]} WORKING         $R" ;;
	waiting) printf '%s' "$BGRN◆ WAITING ON YOU  $R" ;;
	shell) printf '%s' "$GRY· shell           $R" ;;
	self) printf '%s' "$BBLU✦ this panel      $R" ;;
	linked) printf '%s' "$GRY◌ linked          $R" ;;
	unreachable) printf '%s' "$BRED◌ unreachable     $R" ;;
	*) printf '%s' "$CYN▸ running         $R" ;;
	esac
}

draw_panes() {
	local i n=${#P_ID[@]} name key folder git cells mark wide=1 NW=10 FW=10 GW v
	# Worked out again on every frame, so a resized terminal gets them too. The name and folder
	# are as wide as their longest (10 to 29 and 10 to 35); GIT has the rest of the row, so
	# CTX LEFT ends at the panel's right edge. The rest of the row is fixed: the key 6, APP 10,
	# STATE 18, CPU and MEM 19, CTX LEFT 12, and a space after the name, folder and GIT.
	for ((i = 0; i < n; i++)); do
		name=${P_NAME[i]:-${P_LOC[i]}} folder=${P_DIR[i]/#$HOME/\~} folder=${folder##*/}
		((${#name} > NW)) && NW=${#name}
		((${#folder} > FW)) && FW=${#folder}
	done
	((NW > 29)) && NW=29
	((FW > 35)) && FW=35
	GW=$((IW - 68 - NW - FW))
	# A narrow panel cuts GIT first, down to 13, then the folder and the name, down to 10. Too
	# narrow for that, the folder and GIT go and the name has their room: the narrowest panel
	# takes the name down to 10 to keep CTX LEFT.
	v=$((13 - GW < FW - 10 ? 13 - GW : FW - 10)); ((v > 0)) && FW=$((FW - v)) GW=$((GW + v))
	v=$((13 - GW < NW - 10 ? 13 - GW : NW - 10)); ((v > 0)) && NW=$((NW - v)) GW=$((GW + v))
	((GW < 13)) && wide=0 NW=$((IW - 66))
	# Built from the same widths as the rows below, so the columns line up.
	local hdr="$(fld ' #' 6)$(fld NAME $((NW + 1)))$(fld APP 10)$(fld STATE 18)"
	((wide)) && hdr+="$(fld FOLDER $((FW + 1)))$(fld GIT $((GW + 1)))"
	hdr+="$(fld CPU 13)   MEM  $(fld 'CTX LEFT' 10)"
	row "$GRY$hdr$R"
	local group="-"
	for ((i = 0; i < n; i++)); do
		# One heading per computer, once panes from a linked one are listed.
		if ((P_GROUPS)) && [[ ${P_HOST[i]} != "$group" ]]; then
			group=${P_HOST[i]}
			if [[ -z $group ]]; then
				row "$BLU▓▒░$R $B$BWHT${HOST^^}$R $GRY· this computer${VERSION:+ · v$VERSION}$R"
			else
				# Its tmux-revive's version, from its rows: out of date next to this one, or too old
				# to say (it answers no rows, or rows without a version).
				v=${RVER[$group]:-}
				case $v in
				"") v="" ;;
				old) v=" $GRY·$R ${BYEL}too old to tell$R" ;;
				*)
					if [[ -n $VERSION ]] && ver_lt "$v" "$VERSION"; then v=" $GRY· v$v ·$R $B${BYEL}out of date$R"
					else v=" $GRY· v$v$R"; fi ;;
				esac
				row "$BLU▓▒░$R $B$BWHT${group^^}$R $GRY· linked$R$v"
			fi
		fi
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
			if [[ $git == *\* ]]; then cells+="$BYEL$(fld "$git" "$GW")$R "; else cells+="$GRN$(fld "$git" "$GW")$R "; fi
		fi
		# Names-only rows from a link have nothing measured: leave CPU and memory blank.
		if [[ ${P_STATE[i]} != linked && ${P_STATE[i]} != unreachable ]]; then
			cells+="$BCYN$(meter "${P_CPU[i]}")$R $(printf '%4s%%' "${P_CPU[i]}")  $(printf '%6s' "$(human "${P_MEM[i]}")")"
			cells+="  $(ctx_cell "${P_CTX[i]}" "${P_AGENT[i]}")"
		fi
		row "$cells"
	done
	((n)) || row "$GRY  no tmux panes found$R"
}

ctx_cell() { # ctx_cell PERCENT AGENT: context left as a meter, red as it runs out; a dash for
	# an agent that keeps no count the panel can read, nothing for anything else
	local c
	if [[ -z $1 ]]; then (($2)) && printf '%s' "$GRY·····    –$R"; return 0; fi
	if (($1 <= 15)); then c=$BRED; elif (($1 <= 40)); then c=$BYEL; else c=$BGRN; fi
	printf '%s' "$c$(meter "$1")$R $(printf '%3s%%' "$1")"
}
kc() { printf '%s' "$BBLU[$B$BYEL$1$R$BBLU]$R$BWHT$2$R"; } # kc KEY LABEL: a key as the command bar shows it
draw_peek() { # draw_peek LINES: the bottom of the selected pane's screen, or the question it's asking
	local -a L=()
	local id=${P_ID[SEL]:-} i end start shown=0 keys name=${P_NAME[SEL]:-${P_LOC[SEL]:-}}
	if [[ ${P_STATE[SEL]:-} == asking ]]; then
		draw_question "$1"
		return
	fi
	if ((FULL)); then keys="$(kc x " back")  $(kc c " collapse")"; else keys=$(kc x " full view"); fi
	sectk "PEEK · $name" "$keys"
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
	for ((i = start; i <= end; i++)); do row "$GRY│$R $DIM$(fld "${L[i]}" $((IW - 2)))$R"; done
}

# The question the selected pane is asking, in place of its peek: only the dialog at the
# bottom of its screen, bright, from the top of the box down. Enter answers it from here (keys
# go to the pane until Ctrl-]); a chat with the agent is J, in the pane itself.
draw_question() { # draw_question LINES
	local id=${P_ID[SEL]:-} i start keys name=${P_NAME[SEL]:-${P_LOC[SEL]:-}}
	if ((ANSWERING)); then
		keys="$B${BMAG}keys go to $name$R  $(kc Tab " back to panes")  $(kc "Ctrl-]" " leaves")"
	else
		keys="$(kc Tab " answer")  $(kc J " open the chat")  "
		if ((FULL)); then keys+="$(kc x " back")"; else keys+=$(kc x " full view"); fi
	fi
	sectk "QUESTION · $name" "$keys" 5
	if [[ -n ${P_HOST[SEL]:-} ]]; then
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
	for ((i = start; i <= end; i++)); do row "$BMAG│$R ${QSTYLE[i]:-$BWHT}$(fld "${L[i]}" $((IW - 2)))$R"; done
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

messages() { # -> MSG lines for the message center
	MSG=()
	local h b from to when id rest qn
	if [[ -f $AMAIL ]]; then
		while IFS=$'\t' read -r h b; do
			clean h b
			[[ $h =~ ^\#\#\ \[([^ ]+)\ -\>\ ([^ ]+)\ ([^]]+)\]\ \#([^ ]+)(.*)$ ]] || continue
			from=${BASH_REMATCH[1]} to=${BASH_REMATCH[2]} when=${BASH_REMATCH[3]} rest=${BASH_REMATCH[5]}
			when=${when:11:5}
			if [[ $rest == *"NOT DELIVERED"* ]]; then
				MSG+=("$GRY$when$R $BRED✗$R $BWHT$from$R$GRY→$R$BWHT$to$R $BRED${b}$R")
			elif [[ $rest == " (held: read-only link)" ]]; then
				MSG+=("$GRY$when$R $BYEL⏸$R $BWHT$from$R$GRY→$R$BWHT$to$R ${BYEL}held ·$R $GRY$b$R")
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
		art "$tw" "$BH" still # beside the banner the scene holds still
		for ((i = 0; i < BH; i++)); do row "${BAN[i]} ${ART[i]}"; done
	else
		for ((i = 0; i < BH; i++)); do row "${BAN[i]}"; done
	fi
	((HELP)) && { help_frame "$lines" "$BH"; return; } # the ? page takes everything below
	counts="$BYEL$w working$R$GRY · $R$BMAG$a asking$R"
	((a)) && counts="$BYEL$w working$R$GRY · $R$B$BMAG$BLINK$a asking$R"
	sect "PANES"
	draw_panes
	# CPU across every pane, as a running graph.
	for i in "${!P_CPU[@]}"; do [[ -z ${P_HOST[i]} ]] && total=$((total + P_CPU[i])); done
	CPU_HIST+=("$total")
	((${#CPU_HIST[@]} > 200)) && CPU_HIST=("${CPU_HIST[@]: -200}")
	vlen "$counts"
	row "$GRY cpu $R$(spark $((IW - 8 - VLEN)))  $counts"

	messages
	links_saves
	local bottom=$(( ${#MSG[@]} > ${#SIDE[@]} ? ${#MSG[@]} : ${#SIDE[@]} )) msgs=1
	# A question needs every row it can get: the messages step aside until it's answered.
	if [[ ${P_STATE[SEL]:-} == asking && ${P_STATE[SEL]:-} != self ]]; then msgs=0 bottom=-1; fi
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
		for l in "${ART[@]}"; do row "$l"; done
		avail=0
	fi
	for ((; avail > 0; avail--)); do row ""; done

	LW=$(((IW - 3) * 3 / 5)) RW=$((IW - 3 - LW))
	((msgs)) && sect "MESSAGES" "LINKS · SAVES" "$((LW + 1))"
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
	((!ANSWERING)) && [[ ${P_STATE[SEL]:-} == asking ]] && k="$B$BMAG[Tab]$R$B$BWHT answer$R  "
	# Keys that can't act on the selected pane are faded: on a linked computer's pane, nothing
	# to rename unless its rows say which pane it is, and nothing to jump to unless a pane
	# here is ssh'd there.
	local off=" " rh=${P_HOST[SEL]:-} j
	if [[ -n $rh ]]; then
		[[ -n ${P_RID[SEL]:-} ]] || off+="N "
		[[ -n ${P_NAME[SEL]:-} ]] || off+="M "
		off+="J "
		for j in "${!P_SSH[@]}"; do [[ ${P_SSH[j]} == "$rh" ]] && { off=${off/J /}; break; }; done
	fi
	local cs=("J:ump" "M:essage" "N:ame" "L:ink" "U:nlink")
	[[ -n $rh ]] && cs+=("V: update") # tmux-revive on that computer
	cs+=("P:eek" "A:rt" "S:ave" "Q:uit" "?: help")
	for c in "${cs[@]}"; do
		if [[ $off == *" ${c%%:*} "* ]]; then
			k+="$GRY[${c%%:*}]${c#*:}$R  "
		else
			k+="$BBLU[$B$BYEL${c%%:*}$R$BBLU]$R$BWHT${c#*:}$R  "
		fi
	done
	vlen "$k"
	((VLEN + 15 <= IW)) && k+="$GRY↑↓ 1-9 select$R"
	if [[ -n $FLASH ]] && ((SECONDS - FLASH_T < 5)); then k="$BGBLU$B$BWHT $FLASH $R  $k"; fi
	# While answering every key goes to the agent, so the bar says that and how to stop.
	((ANSWERING)) && k="$e[45m$B$BWHT ANSWERING ${P_NAME[SEL]:-${P_LOC[SEL]:-}} $R  $BMAG every key goes to its question ·$R $B${BYEL}Tab$R$BMAG back to the panes ·$R $B${BYEL}Ctrl-]$R$BMAG leaves$R"
	line "$FRAME╠$(rep ═ $((W - 2)))╣$R"
	row "$k"
	local sig="$BLU▓▒░$R$GRY tmux-revive bbs · est. 2026 $R$BLU░▒▓$R"
	vlen "$sig"
	line "$FRAME╚$(rep ═ $((W - 4 - VLEN)))$R$sig$FRAME══╝$R"

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
flash() { FLASH=$1 FLASH_T=$SECONDS; clean FLASH; } # agent-say's reply can quote anything

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
# it (returns 1). Ctrl-C closes it too, read in slices as in ask.
pick() {
	local title=$1 rows cols w h top left i k rest sel=0 line hint="↑↓ choose · Enter picks · Esc closes" INTR=0
	shift
	local -a items=("$@")
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
		line="$BGBLU$BWHT╔═$R$BLU░▒▓$BGBLU$B$BWHT $title $R$BLU▓▒░$BGBLU$BWHT$(rep ═ $((w - ${#title} - 11)))╗$R"
		printf '%s' "$e[$top;${left}H$line"
		printf '%s' "$e[$((top + 1));${left}H$bg$BWHT║$(rep ' ' $((w - 2)))║$R$GRY░$R"
		for ((i = 0; i < ${#items[@]}; i++)); do
			local key="  "
			((i < 9)) && key="$((i + 1)) "
			local txt
			txt=$(fld " $key ${items[i]}" $((w - 5)))
			if ((i == sel)); then
				printf '%s' "$e[$((top + 2 + i));${left}H$bg$BWHT║ $hi$B▶$txt$R$bg$BWHT ║$R$GRY░$R"
			else
				printf '%s' "$e[$((top + 2 + i));${left}H$bg$BWHT║  $BYEL$(fld "$key" 3)$BWHT$(fld "${items[i]}" $((w - 9)))  ║$R$GRY░$R"
			fi
		done
		printf '%s' "$e[$((top + 2 + ${#items[@]}));${left}H$bg$BWHT║$(rep ' ' $((w - 2)))║$R$GRY░$R"
		printf '%s' "$e[$((top + 3 + ${#items[@]}));${left}H$bg$BWHT║ $BCYN$(fld "$hint" $((w - 4)))$BWHT ║$R$GRY░$R"
		printf '%s' "$e[$((top + 4 + ${#items[@]}));${left}H$bg$BWHT╚$(rep ═ $((w - 2)))╝$R$GRY░$R"
		printf '%s' "$e[$((top + 5 + ${#items[@]}));$((left + 1))H$GRY$(rep ░ "$w")$R"
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
			'[A') ((sel > 0)) && ((sel--)) ;;
			'[B') ((sel < ${#items[@]} - 1)) && ((sel++)) ;;
			esac ;;
		[1-9]) ((k - 1 < ${#items[@]})) && sel=$((k - 1)) && { PICKED=$sel; trap 'exit 0' INT; return 0; } ;;
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

# answer: every key goes to the selected pane's question, as if typed in its own console,
# and the question redraws every 0.3 s to show it react. Ctrl-] (or Ctrl-C) leaves without
# sending anything; it ends by itself once the pane stops asking. Questions only: a chat
# with the agent is J, in its own pane.
answer() {
	local h=${P_HOST[SEL]:-} id=${P_ID[SEL]:-} k rest seq txt st got gone=0 why=left pend="" INTR=0 f
	local -a TOKS AL
	[[ ${P_STATE[SEL]:-} == asking ]] || return 0
	[[ -n $h ]] && id=${P_RID[SEL]:-}
	[[ $id =~ ^%[0-9]+$ ]] || return 0
	ANSWERING=1 PEEK_EVERY=0 PREV=()
	trap 'INTR=1' INT
	while :; do
		draw
		if [[ -n $pend ]]; then
			k=$pend pend=""
		else
			k="" got=1 st=0
			IFS= read -rsn1 -t 0.3 k || { st=$? got=0; }
			if ((!got)); then
				((st > 128 && !INTR)) || break # Ctrl-C, or the input closed
				# Still asking? Twice not, in a row, means answered (one look can catch a redraw).
				if [[ -n $h ]]; then
					f="$RDIR/$h.peek-${id#%}" AL=()
					[[ -f $f ]] && mapfile -t AL < <(tail -n 60 "$f")
					st=$(lines_state AL)
				else
					st=$(screen_state "$id")
				fi
				if [[ $st == asking ]]; then gone=0; else ((++gone >= 2)) && { why=answered; break; }; fi
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
			# Typed text (a custom answer) goes as it is, with whatever else is already waiting.
			txt=$k
			while ((${#txt} < 256)) && IFS= read -rsn1 -t 0.005 rest; do
				if [[ -z $rest ]]; then pend=$'\r'; break
				elif [[ $rest == [[:cntrl:]] ]]; then pend=$rest; break; fi
				txt+=$rest
			done
			clean txt
			lit_tokens "$txt" ;;
		esac
		((${#TOKS[@]})) || continue
		send_answer "${TOKS[@]}" || { why=failed; break; }
	done
	ANSWERING=0 PEEK_EVERY=$REFRESH PREV=()
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
act() {
	# A key may draw over the panel (popup, prompt) and return early: repaint it whole. Keys
	# that only move the selection don't, so they keep the line-by-line redraw.
	case $1 in up | down | [1-9]) ;; *) PREV=() ;; esac
	local id=${P_ID[SEL]:-} name=${P_NAME[SEL]:-${P_LOC[SEL]:-}} out
	case $1 in
	j | J)
		if [[ -n ${P_HOST[SEL]:-} ]]; then
			# Not a pane here: go to the pane that's ssh'd into that computer, if there is one.
			local h=${P_HOST[SEL]} j
			id=""
			for j in "${!P_SSH[@]}"; do [[ ${P_SSH[j]} == "$h" ]] && { id=${P_ID[j]}; name="${P_NAME[j]:-${P_LOC[j]}} (ssh to $h)"; break; }; done
			[[ -n $id ]] || { flash "${P_NAME[SEL]:-that pane} is on $h, and no pane here is ssh'd there"; return; }
		fi
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
		# Every ssh host not linked yet, the selected pane's first, then "other host...".
		local hosts=() labels=() seen=" " h i j
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
		# Its host key first, to confirm (agent-say asks the same on a terminal): say no, and
		# nothing is linked. No is first, so Enter alone doesn't trust a key.
		flash "reading $h's host key…"; draw
		local -a keys=()
		local k
		while IFS= read -r k; do
			[[ $k =~ ^SHA256:[A-Za-z0-9+/=]{1,64}\ \([A-Z0-9-]{1,16}\)$ ]] && keys+=("$k")
		done < <(timeout 20 "$ASAY" _host-keys "$h" </dev/null 2>/dev/null | head -n 8)
		PREV=()
		if ((${#keys[@]})); then
			labels=("No, don't link $h")
			for k in "${keys[@]}"; do labels+=("Yes, link: its key is $k"); done
		else
			labels=("No, don't link $h" "Yes, link (no key found in known_hosts or by ssh-keyscan)")
		fi
		pick "HOST KEY OF $h" "${labels[@]}" && ((PICKED > 0)) || { flash "link cancelled"; return; }
		flash "linking $h…"; draw
		out=$(timeout 30 "$ASAY" link "$h" --yes </dev/null 2>&1 | grep -E '^(linked to|agent-say:)' | head -n 1)
		clean out
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
		[[ -d $ASTATE/links/$h ]] || rm -f "$RDIR/$h.rows" "$RDIR/$h.rows.old" # what it kept of that computer
		flash "${out#agent-say: }" ;;
	v | V)
		# Update tmux-revive on the selected pane's linked computer, over the link's ssh.
		local h=${P_HOST[SEL]:-} last st
		[[ -n $h ]] || { flash "V updates a linked computer: select one of its panes"; return; }
		[[ $h =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return
		pick "Update tmux-revive on $h?" "Yes, update it over ssh" "No" && ((PICKED == 0)) || { flash "update cancelled"; return; }
		flash "updating tmux-revive on $h…"; draw
		out=$(RTIMEOUT=300 remote_run "$h" "$REMOTE_UPDATE_CMD" | tail -c 4096)
		st=$?
		last=$(grep -v '^[[:space:]]*$' <<<"$out" | tail -n 1)
		clean last
		last=${last:0:120}
		if ((st == 0)); then flash "on $h: ${last:-updated}"
		elif ((st == 124 || st == 255)); then flash "on $h: couldn't be reached to update"
		else flash "on $h: update failed${last:+: $last}"; fi
		RFETCH_T[$h]=0 # and ask it for its rows, and so its version, again
		;;
	p | P) PEEK=$((!PEEK)) ;;
	x | X) if ((FULL)); then FULL=0; else FULL=1 PEEK=1; fi ;; # the peek over the whole art, and back
	c | C) FULL=0 ;;
	enter | $'\t') [[ ${P_STATE[SEL]:-} == asking ]] && answer ;; # Tab: focus to the question
	a | A)
		SCENE=$(((SCENE + 1) % ${#SCENES[@]}))
		flash "art: ${TITLES[SCENE]}" ;;
	s | S)
		if "$BASH" "$REVIVE_ROOT/scripts/save.sh" manual >/dev/null 2>&1; then flash "saved"; else flash "save failed (see: tmux-revive log)"; fi ;;
	q | Q) exit 0 ;;
	'?') help_view ;; # quoted: a bare ? would match every key
	[1-9]) (($1 - 1 < ${#P_ID[@]})) && SEL=$(($1 - 1)) ;;
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
	gather
	sleep 0.3 # CPU is measured between two looks
	gather
	# First, its version on a line of its own: a panel that doesn't know the line skips it,
	# since a row must start with a pane id.
	[[ -n $VERSION ]] && printf '#version %s\n' "$VERSION"
	for i in "${!P_ID[@]}"; do
		[[ ${P_STATE[i]} == self ]] && continue
		folder=${P_DIR[i]##*/}
		# Context left goes on a line of its own: a panel from before it skips the line, where a
		# field added to the row would make it drop the row.
		[[ -n ${P_CTX[i]} ]] && printf '#ctx %s %s\n' "${P_ID[i]}" "${P_CTX[i]}"
		printf '%s\x1f' "${P_ID[i]}" "${P_LOC[i]}" "${P_NAME[i]}" "${P_APP[i]}" "${P_STATE[i]}" "$folder" "${P_GIT[i]}" "${P_CPU[i]}" "${P_MEM[i]}"
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
trap 'printf "%s" "$e[2J"; PREV=()' WINCH
case ${REVIVE_PANEL_SPLASH:-} in
1) splash ;;
0) ;;
*) [[ $(opt @revive-panel-splashed '') == 1 ]] || { splash; tm set-option -g @revive-panel-splashed 1 2>/dev/null; } ;;
esac
PREV=() # after the splash: paint the whole panel

declare -A SSH_SEEN=()
nav=0
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
	fi
	# Keep the same pane selected when panes come and go.
	if [[ -n $SEL_ID ]]; then
		for i in "${!P_ID[@]}"; do [[ ${P_ID[i]} == "$SEL_ID" ]] && SEL=$i; done
	fi
	((SEL >= ${#P_ID[@]})) && SEL=$((${#P_ID[@]} ? ${#P_ID[@]} - 1 : 0))
	SEL_ID=${P_ID[SEL]:-}
	draw
	nav=0
	key=""
	if ! IFS= read -rsn1 -t "$REFRESH" key; then
		((TICK++)) # the animation moves on with the clock, not with keys
		continue
	fi
	# Take this key and any already waiting (a held arrow), then draw once.
	while :; do
		[[ -z $key || $key == $'\r' ]] && key=enter # read stops at the newline Enter sends
		if [[ $key == "$e" ]]; then
			rest=""
			IFS= read -rsn2 -t 0.05 rest || true
			case $rest in '[A') key=up ;; '[B') key=down ;; *) key="" ;; esac
		fi
		case $key in
		up | down | [1-9]) act "$key"; nav=1 ;;
		"") ;;
		*) act "$key"; nav=0; break ;;
		esac
		key=""
		IFS= read -rsn1 -t 0.01 key || break
	done
done
