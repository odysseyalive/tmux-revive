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
# REVIVE_PANEL_POPUP=1 (set by @revive-panel-key) closes the panel after O opens a pane, since a
# popup would otherwise sit on top of the pane it opened.
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
SELBG="$e[48;5;236m" # the selected row's faint background, with the focus in PANES
# A question's highlighted choice, and the tab it highlights (Submit, Next): bold bright text
# on a teal band. A fixed colour, not the palette's, so it shows on any (a palette blue was
# hard to see on some); reverse video made the text the dark background, the band darker.
QBAND="$e[48;5;31m"
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
	# RBAR set (a scroll bar's cell, from sbar): the row is one narrower and the cell sits
	# against the frame's right edge. ROWL and ROWR: the colours of its left and right edges,
	# the focus colour on the rows of the window that has the focus.
	local c=$1 pad w=$IW
	[[ -n $RBAR ]] && w=$((IW - 1))
	if [[ -n ${2:-} ]]; then VLEN=$2; else vlen "$c"; fi
	((VLEN > w)) && { trim_colored "$c" "$w"; c=$TRIM VLEN=$w; }
	printf -v pad '%*s' $((w - VLEN)) ''
	line "$ROWL║$R $c$pad ${RBAR:+$RBAR$R}$ROWR║$R"
}
RBAR="" ROWL=$FRAME ROWR=$FRAME
# sbar HEIGHT TOTAL OFFSET UP DOWN [COLOUR] -> SB[0..HEIGHT-1]: a BBS scroll bar for a window
# HEIGHT rows tall showing TOTAL rows from OFFSET down: ▲, a ░ track with a ▓ thumb sized and
# placed by the view, ▼. Nothing when it all fits. UP or DOWN 1: something waiting on you is
# out of view that way, and that arrow blinks bold yellow: lit one tick, dark the next (as the
# help page's beacons), so it blinks even where the terminal ignores the blink code.
sbar() {
	local h=$1 n=$2 o=$3 c=${6:-$FRAME} hot up dn t s p i
	SB=()
	((n > h && h > 0)) || return 0
	if ((TICK % 2)); then hot=$c; else hot=$B$BYEL$BLINK; fi
	up="$c▲" dn="$c▼"
	(($4)) && up="$hot▲"
	(($5)) && dn="$hot▼"
	if ((h == 1)); then
		if (($4 && !$5)) || ((o >= n - h)); then SB=("$up$R"); else SB=("$dn$R"); fi
		return 0
	fi
	SB[0]="$up$R" SB[h - 1]="$dn$R"
	t=$((h - 2))
	s=$((t * h / n))
	((s < 1)) && s=1
	p=$((((t - s) * o * 2 / (n - h) + 1) / 2))
	for ((i = 0; i < t; i++)); do
		if ((i >= p && i < p + s)); then SB[i + 1]="$c▓$R"; else SB[i + 1]="$c░$R"; fi
	done
}
# A section title on a solid blue band that fades into the black on both sides: shading as
# a short transition between two colours, the way the artpack groups used it.
# A question waiting on you gets the band in magenta, the colour of the asking state.
tab() { local c=${2:-4}; TAB="$e[3${c}m░▒▓$e[4${c}m$B$BWHT $1 $R$e[3${c}m▓▒░$R"; } # tab TITLE [COLOUR 0-7] -> TAB
# seg TAB HINT KEYS WIDTH BORDER -> SEG: a divider's run, WIDTH wide, in BORDER: ═, the title
# band, ═ up to the keys at its right end, ══. HINT goes before the keys; short of room it's
# all that's kept, and shorter still it's cut.
seg() {
	local k=$3 a r
	[[ -n $2 ]] && k="$2${k:+  $k}"
	vlen "$1"; a=$VLEN
	r=$(($4 - a - 6))
	vlen "$k"
	((VLEN > r)) && [[ -n $2 ]] && { k=$2; vlen "$k"; }
	((VLEN > r)) && { if ((r > 1)); then trim_colored "$k" "$r"; k=$TRIM VLEN=$r; else k="" VLEN=0; fi; }
	if [[ -n $k ]]; then rep ═ $(($4 - a - VLEN - 5)); SEG="$5═$1$5$REP$R $k $5══"
	else rep ═ $(($4 - a - 1)); SEG="$5═$1$5$REP"; fi
}
# sectk TITLE KEYS [COLOUR [BORDER [HINT]]]: a divider with a title, and the keys for that
# section at its right end, HINT ("[⇧J] focus") first. BORDER: its rule's colour (FRAME).
sectk() {
	local b=${4:-$FRAME}
	tab "$1" "${3:-4}"
	seg "$TAB" "${5:-}" "$2" $((W - 2)) "$b"
	line "$b╠$SEG$b╣$R"
}
sect() { sectk "$1" "" "${2:-4}" "${3:-}" "${4:-}"; } # sect TITLE [COLOUR [BORDER [HINT]]]
# sect2 SPLIT-AT JOIN TITLE COLOUR BORDER HINT TITLE COLOUR BORDER HINT: a divider over two
# windows side by side, each half as sect's, joined at SPLIT-AT by a ╤ in JOIN's colour.
sect2() {
	local l
	tab "$3" "$4"
	seg "$TAB" "$6" "" $(($1 + 1)) "$5"
	l="$5╠$SEG$2╤"
	tab "$7" "$8"
	seg "$TAB" "${10}" "" $((W - $1 - 4)) "$9"
	line "$l$SEG$9╣$R"
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
	# Only the cells drawn on are visited (put sets CH and CO together); the empty sky between
	# them goes in as one run of spaces. Visiting every cell made the art most of a frame.
	local r=0 c=0 i x out="" cur="" pad
	ART=()
	for i in "${!CO[@]}"; do
		while ((i / ART_W > r)); do
			if ((c < ART_W)); then
				[[ -z $cur ]] || out+=$R
				printf -v pad '%*s' $((ART_W - c)) ''
				out+=$pad
			fi
			ART+=("$out$R") out="" cur="" c=0 r=$((r + 1))
		done
		x=$((i % ART_W))
		if ((x > c)); then
			[[ -z $cur ]] || out+=$R cur=""
			printf -v pad '%*s' $((x - c)) ''
			out+=$pad
		fi
		[[ ${CO[i]} == "$cur" ]] || { cur=${CO[i]}; out+="$R$cur"; }
		out+=${CH[i]:- } c=$((x + 1))
	done
	for (( ; r < ART_H; r++)); do
		if ((c < ART_W)); then
			[[ -z $cur ]] || out+=$R
			printf -v pad '%*s' $((ART_W - c)) ''
			out+=$pad
		fi
		ART+=("$out$R") out="" cur="" c=0
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
# Every how many frames each scene (as SCENES) looks the same again: city, mountains and circuit
# only blink, on odd and even frames (AT % 2). Space's comet and the grid's clouds travel, so
# theirs (0) is too long to keep. A scene whose animation changes must change its number here.
ART_LOOP=(2 2 0 2 0)
declare -A ART_MEMO=() ART_ROWS=()
art() { # art WIDTH HEIGHT [still] -> ART rows of the current scene; "still" stops its animation
	local k i n
	if [[ ${3:-} == still ]]; then AT=0; else AT=$TICK; fi
	# The same frame again (a redraw that only moved the selection, or a scene come round to a
	# frame it drew already) is kept, not redrawn: drawing one is most of what a frame costs.
	i=$AT
	((ART_LOOP[SCENE])) && i=$((AT % ART_LOOP[SCENE]))
	k="$SCENE $1 $2 $i"
	if [[ -n ${ART_MEMO[$k]+set} ]]; then
		ART=() n=${ART_MEMO[$k]}
		for ((i = 0; i < n; i++)); do ART+=("${ART_ROWS[$k:$i]}"); done
		return
	fi
	canvas "$1" "$2"
	SEED=$((7919 * (SCENE + 1)))
	((ART_W > 0 && ART_H > 0)) && "scene_${SCENES[SCENE]}"
	emit
	((${#ART_MEMO[@]} > 6)) && ART_MEMO=() ART_ROWS=()
	ART_MEMO[$k]=${#ART[@]}
	for i in "${!ART[@]}"; do ART_ROWS[$k:$i]=${ART[i]}; done
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
# An agent asking you something: a permission prompt or a multiple-choice question. Claude
# Code's last step of a question, "Ready to submit your answers?", has no footer: named here,
# or Enter on a multi-select's Submit seemed to answer it, and the panel stopped there.
Q_RE='do you want to|would you like to|allow (once|always)|\(y/n\)|\[y/n\]|enter to select|esc to cancel|trust (this|the) folder|yes, proceed|press enter to continue|ready to submit your answers'
W_RE='esc to interrupt|ctrl\+c to interrupt'
# The line a question's dialog starts under: a horizontal rule, or the top of a box.

agent_kind() { # agent_kind ARGS -> AKIND: claude/codex/cursor/crush/gemini or nothing (as agent-say does)
	AKIND=""
	case " $1 " in
	*app-server*) ;;
	*/claude\ * | " claude "* | *" claude --"*) AKIND=claude ;;
	*/codex\ * | " codex "*) AKIND=codex ;;
	*cursor-agent*) AKIND=cursor ;;
	*/crush\ * | " crush "*) AKIND=crush ;;
	*/gemini\ * | *" gemini "*) AKIND=gemini ;;
	esac
}

# One running as another user (in root's tmux, a pane where root ran su - USER) keeps it in its
# own config, which its environment names, readable here only as root: looked for there again
# every 30 s until found.
declare -A CL_EREC=() CL_EREC_T=() CL_TROK=()
claude_record() { # claude_record PID -> RECORD: Claude Code's session record for it, or nothing
	local f e
	local -a d=()
	RECORD=""
	for f in "$HOME"/.claude*/sessions/"$1".json ${CLAUDE_CONFIG_DIR:+"$CLAUDE_CONFIG_DIR/sessions/$1.json"}; do
		[[ -f $f ]] && { RECORD=$f; return; }
	done
	[[ $1 =~ ^[0-9]+$ && -r /proc/$1/environ ]] || return 0
	if [[ -z ${CL_EREC[$1]:-} ]] && { [[ -z ${CL_EREC_T[$1]:-} ]] || ((SECONDS - CL_EREC_T[$1] >= 30)); }; then
		CL_EREC_T[$1]=$SECONDS
		while IFS= read -r -d '' e; do
			case $e in
			CLAUDE_CONFIG_DIR=/*) d=("${e#*=}" "${d[@]}") ;;
			HOME=/*) d+=("${e#*=}/.claude") ;;
			esac
		# 2> before <: the other way round, a file gone or unreadable (the process ended since)
		# is reported to the screen before stderr is put away.
		done 2>/dev/null <"/proc/$1/environ"
		for f in "${d[@]}"; do
			own_plain "$f/sessions/$1.json" "$(stat -c %u "/proc/$1" 2>/dev/null)" && { CL_EREC[$1]=$f/sessions/$1.json; break; }
		done
	fi
	[[ -n ${CL_EREC[$1]:-} && -f ${CL_EREC[$1]} ]] && RECORD=${CL_EREC[$1]}
	return 0
}
# own_plain FILE UID: FILE is UID's, reached by no symbolic link. Its user says where those
# files are (its environment), so nothing of anyone else's is read for it.
own_plain() {
	[[ -f $1 && $2 =~ ^[0-9]+$ && "$(realpath -e -- "$1" 2>/dev/null)" == "$1" && "$(stat -c %u -- "$1" 2>/dev/null)" == "$2" ]]
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
	if [[ -n ${JQ_ST[$RECORD]+set} ]]; then
		CST=${JQ_ST[$RECORD]} sid=${JQ_SID[$RECORD]} # read already, with the other agents' (agents_look)
	else
		IFS=$'\t' read -r CST sid < <(jq -r '[.status // "", .sessionId // ""] | @tsv' "$RECORD" 2>/dev/null)
	fi
	CL_REC=$RECORD CL_SID=$sid # ctx_left, next, needs the session too: one jq for both
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
	done 2>/dev/null <"/proc/$pid/environ"
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
# Codex 0.167 on keeps no rollout open in its own process: a shared app-server daemon, not in
# the pane, writes it. Its rollout is then looked for in its sessions folder (CODEX_HOME from
# its own environment, else its HOME's .codex): one whose first line (session_meta) names its
# working folder and a start no more than 2 s before its own, the newest written since it
# started (a /new starts another). One started before it only for a `codex resume`, then the
# newest written since. With another codex in the same folder, a rollout is the one's started
# last before it, within 120 s (a /new there isn't followed), and one claimed for another pane
# is never taken. Nothing sure: nothing shown. Looked for again every 30 s.
declare -A CX_RO=() CX_RO_T=() CX_START=() CX_META=() CX_CLAIM=()
proc_cwd() { # proc_cwd PID: its working folder
	if [[ -e /proc/$1/cwd ]]; then readlink "/proc/$1/cwd" 2>/dev/null
	else lsof -a -d cwd -p "$1" -Fn 2>/dev/null | sed -n 's/^n//p'; fi
}
proc_start() { # proc_start PID -> PSTART: when it started, in seconds since the epoch (worked out once)
	local e
	PSTART=${CX_START[$1]:-}
	[[ -n $PSTART ]] && return 0
	e=$(ps -o etime= -p "$1" 2>/dev/null)
	e=${e//[[:space:]]/}
	[[ $e =~ ^(([0-9]+)-)?(([0-9]+):)?([0-9]+):([0-9]+)$ ]] || return 0
	PSTART=$((${EPOCHSECONDS:-$(date +%s)} - 10#${BASH_REMATCH[2]:-0} * 86400 - 10#${BASH_REMATCH[4]:-0} * 3600 - 10#${BASH_REMATCH[5]} * 60 - 10#${BASH_REMATCH[6]}))
	CX_START[$1]=$PSTART
}
codex_meta() { # codex_meta FILE...: CX_META[FILE]=its session's folder TAB its start (epoch), from line 1
	local f
	local -a l=() m=()
	for f in "$@"; do [[ -n ${CX_META[$f]+set} ]] || l+=("$f"); done
	((${#l[@]})) || return 0
	# One line in and one out per file, a bad or empty first line too, so they stay paired.
	mapfile -t m < <(for f in "${l[@]}"; do printf '%s\n' "$(head -n 1 -- "$f" 2>/dev/null)"; done |
		jq -Rr '(fromjson? // {}) | (.payload // {}) | [(.cwd // "" | tostring),
			((.timestamp // "") | tostring | sub("\\.[0-9]+"; "") | (fromdateiso8601? // ""))] | @tsv' 2>/dev/null)
	# Kept only once read whole: a first line still being written is read again next time.
	for f in "${!l[@]}"; do [[ ${m[f]:-} =~ ^/.*$'\t'[0-9]+$ ]] && CX_META[${l[f]}]=${m[f]}; done
}
codex_rollout() { # codex_rollout PID -> ROLLOUT, or nothing
	local pid=$1 e d="" cwd p c t f mt now best="" bt=0 st resume=0 owner os
	local -a peers=() files=()
	local -A pst=()
	ROLLOUT=""
	if [[ -n ${CX_RO_T[$pid]:-} ]] && ((SECONDS - CX_RO_T[$pid] < 30)); then
		[[ -f ${CX_RO[$pid]} ]] && ROLLOUT=${CX_RO[$pid]}
		return 0
	fi
	CX_RO[$pid]="" CX_RO_T[$pid]=$SECONDS
	proc_start "$pid"
	st=$PSTART
	cwd=$(proc_cwd "$pid")
	[[ -n $st && -n $cwd ]] || return 0
	[[ -r /proc/$pid/environ ]] && while IFS= read -r -d '' e; do
		case $e in
		CODEX_HOME=/*) d=${e#*=} ;;
		HOME=/*) [[ -n $d ]] || d=${e#*=}/.codex ;;
		esac
	done 2>/dev/null <"/proc/$pid/environ"
	[[ -n $d ]] || d=${CODEX_HOME:-$HOME/.codex}
	[[ -d $d/sessions ]] || return 0
	[[ " ${PARGS[$pid]:-} " == *" resume "* ]] && resume=1
	# The other codex processes in the same folder (a wrapper's codex under it is the same one).
	for p in "${!PARGS[@]}"; do
		[[ $p == "$pid" ]] && continue
		agent_kind "${PARGS[$p]}"
		[[ $AKIND == codex ]] || continue
		agent_kind "${PARGS[${PPAR[$p]:-0}]:-}"
		[[ $AKIND == codex ]] && continue
		c=$(proc_cwd "$p")
		[[ $c == "$cwd" ]] || continue
		proc_start "$p"
		[[ -n $PSTART ]] && peers+=("$p") pst[$p]=$PSTART
	done
	now=${EPOCHSECONDS:-$(date +%s)}
	mapfile -t files < <(find "$d/sessions" -type f -name 'rollout-*.jsonl' -mmin -$(((now - st) / 60 + 2)) 2>/dev/null)
	((${#files[@]})) || return 0
	codex_meta "${files[@]}"
	for f in "${files[@]}"; do
		IFS=$'\t' read -r c t <<<"${CX_META[$f]}"
		[[ $c == "$cwd" && $t =~ ^[0-9]+$ ]] || continue
		mt=$(stat -c %Y -- "$f" 2>/dev/null || stat -f %m -- "$f" 2>/dev/null)
		[[ $mt =~ ^[0-9]+$ ]] && ((mt >= st)) || continue
		# Another user's (found by its environment): the file must be its own too.
		[[ ${PUID[$pid]:-$UID} == "$UID" ]] || own_plain "$f" "${PUID[$pid]}" || continue
		owner=${CX_CLAIM[$f]:-}
		[[ -n $owner && $owner != "$pid" && -n ${PARGS[$owner]:-} ]] && continue
		if ((t >= st - 2)); then
			# Started after it: its own, unless another here started later, still before it.
			os=$st
			for p in "${peers[@]}"; do
				((pst[$p] > os && pst[$p] <= t + 2)) && os=${pst[$p]}
			done
			((os == st)) || continue
			((${#peers[@]} == 0 || t - st <= 120)) || continue
		else
			((resume && ${#peers[@]} == 0)) || continue
		fi
		((mt > bt)) && best=$f bt=$mt
	done
	[[ -n $best ]] || return 0
	CX_CLAIM[$best]=$pid CX_RO[$pid]=$best ROLLOUT=$best
}
# ctx_reported PANE AGENT_PID [SESSION] -> CTX: what the Claude Code in PANE last reported,
# if it was that process (and that session, when known) and within REVIVE_CTX_TTL (600 s).
ctx_reported() {
	local f=$ASTATE/ctx/${1#%} id sid pct at pid
	[[ -f $f ]] || return 0
	read -r id sid pct at pid _ 2>/dev/null <"$f" || return 0
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
		if [[ -n $RECORD && $RECORD == "${CL_REC:-}" ]]; then sid=$CL_SID
		elif [[ -n $RECORD ]]; then sid=$(jq -r '.sessionId // empty' "$RECORD" 2>/dev/null); fi
		ctx_reported "$pane" "$apid" "$sid"
		[[ -n $CTX ]] && return 0
		if [[ -z $RECORD ]]; then
			claude_transcript "$apid"
			[[ -n $TRANSCRIPT ]] && ctx_cached "$TRANSCRIPT" claude_ctx_file
			return 0
		fi
		[[ $sid =~ ^[A-Za-z0-9-]+$ ]] || return 0
		for f in "${RECORD%/sessions/*}"/projects/*/"$sid".jsonl; do
			[[ -f $f ]] || continue
			# A record found by its environment (another user's): its transcript must be its own too.
			if [[ $RECORD == "${CL_EREC[$apid]:-}" ]]; then
				[[ -n ${CL_TROK[$f]:-} ]] || { own_plain "$f" "$(stat -c %u -- "$RECORD")" && CL_TROK[$f]=1; } || continue
			fi
			ctx_cached "$f" claude_ctx_file
			return 0
		done ;;
	codex)
		for p in "$@"; do
			while IFS= read -r f; do
				[[ $f == */sessions/*/rollout-*.jsonl && -f $f ]] && { ctx_cached "$f" codex_ctx_file; return 0; }
			done < <(open_files "$p")
		done
		codex_rollout "$apid"
		[[ -n $ROLLOUT ]] && ctx_cached "$ROLLOUT" codex_ctx_file ;;
	esac
}

screen_state() { # screen_state PANE -> LSTATE: asking / working / waiting, read off the bottom of the screen
	local -a SL
	mapfile -t SL < <(tm capture-pane -p -t "$1" 2>/dev/null)
	lines_state SL
}
lines_state() { # lines_state ARRAY -> LSTATE: the same, for a screen already read (a linked computer's peek)
	local -n L=$1
	local n=0 i tail="" prompt=0
	for ((i = ${#L[@]} - 1; i >= 0 && n < 12; i--)); do
		[[ ${L[i]} =~ ^[[:space:]]*$ ]] && continue
		((n++))
		tail+="${L[i]}"$'\n'
		# The agent's own input prompt near the bottom: it is waiting for you, not asking.
		# A menu's cursor isn't it: on a numbered choice, or set apart by a gap, as on a
		# multi-select's "❯    Submit" (read as the prompt, Enter there left the question).
		if ((n <= 6)) && [[ ${L[i]//$'\xc2\xa0'/ } =~ ^(❯|›|\>)\ ? ]] && ! [[ ${L[i]} =~ ^(❯|›|\>)[[:space:]]+[0-9]+\. || ${L[i]} =~ ^(❯|›|\>)[[:space:]]{2,}[^[:space:]] ]]; then prompt=1; fi
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
git_info() { # git_info DIR -> GITI: "branch" or "branch*" (uncommitted changes), cached 15 s
	# Not called in a $( ): the cache must outlive the call, or git runs for every pane every frame.
	local d=$1 b dirty filters
	# No folder (tmux can't read the cwd of a process that isn't yours): no key for the cache.
	[[ -n $d ]] || { GITI=""; return; }
	if [[ -n ${GIT_T[$d]:-} ]] && ((SECONDS - GIT_T[$d] < 15)); then GITI=${GIT[$d]}; return; fi
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
	GIT[$d]=$b GIT_T[$d]=$SECONDS GITI=$b
}

STAT_RE='^([^ ]+ +){11}([0-9-]+) +([0-9-]+) +([0-9-]+) +([0-9-]+)'
tree_ticks() { # tree_ticks PID... -> TICKS: CPU ticks used so far by these processes (Linux)
	# Their children's that have ended count too (cutime, cstime), so a command an agent ran
	# between two looks still shows, where it would drop out of the tree uncounted.
	local p l t=0
	for p in "$@"; do
		read -r l 2>/dev/null <"/proc/$p/stat" || continue # gone since ps ran
		# Fields 14-17 (utime stime cutime cstime): the 12th to 15th after the name's ")".
		[[ ${l##*) } =~ $STAT_RE ]] || continue
		t=$((t + BASH_REMATCH[2] + BASH_REMATCH[3] + BASH_REMATCH[4] + BASH_REMATCH[5]))
	done
	TICKS=$t
}
# usecs TIME -> US: a time as EPOCHREALTIME gives it (or whole seconds) in microseconds, so the
# CPU sums are done in the shell's integers rather than an awk run for each pane.
usecs() {
	local s=${1%%[.,]*} f=000000
	[[ $1 == *[.,]* ]] && f=${1#*[.,]}000000
	US=$((10#$s * 1000000 + 10#${f:0:6}))
}

# One record per pane, in these parallel arrays. P_RID is a linked computer's own pane id,
# P_WP the pane's window.pane as tmux's status bar numbers it (empty when not known). P_USER is
# the user its agent (or the program it runs) runs as, empty when not known; P_INST whether that
# user has tmux-revive: "owner" (it's the tmux owner's own), a version, or empty (none known).
P_ID=() P_LOC=() P_NAME=() P_APP=() P_STATE=() P_DIR=() P_GIT=() P_CPU=() P_MEM=() P_CTX=() P_AGENT=() P_SSH=() P_HOST=() P_RID=() P_WP=() P_USER=() P_INST=()
ME=$(id -un 2>/dev/null)
USER_RE='^[A-Za-z_][A-Za-z0-9_.-]{0,31}$'
declare -A UNAMES=() UHOMES=() UAPPS=()
user_of() { # user_of UID -> UNAME: its user name (the number if it has none)
	local n="" h=""
	if [[ -z ${UNAMES[$1]+x} ]]; then
		IFS=: read -r n _ _ _ _ h _ < <(getent passwd "$1" 2>/dev/null)
		[[ -n $n ]] || n=$(id -un "$1" 2>/dev/null)
		[[ $n =~ $USER_RE ]] || n=$1
		UNAMES[$1]=$n UHOMES[$1]=$h
	fi
	UNAME=${UNAMES[$1]}
}
# user_inst NAME UID PID -> INST: as P_INST. Another user's install, where it can be read (as
# root, in root's tmux): its own app folder, as install.sh finds it (XDG_DATA_HOME as that
# user's process has it, else their home's), looked for once a user. Else what their install
# left here (agent-say _user-installed), when their home can't be looked in.
user_inst() {
	local v="" e d="" a=""
	INST=owner
	[[ $1 == "$ME" ]] && return 0
	INST=""
	if [[ -n ${2:-} && -z ${UAPPS[$2]+x} ]]; then
		[[ ${UHOMES[$2]:-} == /* ]] && d=${UHOMES[$2]}/.local/share
		if [[ ${3:-} =~ ^[0-9]+$ && -r /proc/$3/environ && "$(stat -c %u "/proc/$3" 2>/dev/null)" == "$2" ]]; then
			while IFS= read -r -d '' e; do [[ $e == XDG_DATA_HOME=/* ]] && d=${e#*=}; done 2>/dev/null <"/proc/$3/environ"
		fi
		UAPPS[$2]=${d:+$d/tmux-revive/app}
	fi
	[[ -n ${2:-} ]] && a=${UAPPS[$2]}
	[[ -n $a && -f $a/VERSION && ! -L $a/VERSION ]] && read -r v 2>/dev/null <"$a/VERSION"
	[[ $v =~ $VER_RE ]] && { INST=$v; return 0; }
	v=""
	[[ $1 =~ $USER_RE && -f $ASTATE/users/$1 ]] && read -r v 2>/dev/null <"$ASTATE/users/$1"
	[[ $v =~ $VER_RE ]] && INST=$v
	return 0
}
P_GROUPS=0
# ssh_dest ARGS -> SSHD: the host an `ssh ...` command line connects to, as agent-say link takes
# it (no user@, no port), or nothing. Options that take a value are skipped with their value.
ssh_dest() {
	local -a a
	local i d
	SSHD=""
	[[ $1 == *ssh* ]] || return 0 # most command lines: no need to split them
	read -ra a <<<"$1"
	[[ ${a[0]##*/} == ssh ]] || return 0
	for ((i = 1; i < ${#a[@]}; i++)); do
		case ${a[i]} in
		-[BbcDEeFIiJLlmOoPpQRSWw]) ((i++)) ;;
		-*) ;;
		*)
			d=${a[i]#ssh://} d=${d##*@} d=${d%%:*}
			[[ $d =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && SSHD=$d
			return 0 ;;
		esac
	done
}
linked() { [[ -f $ASTATE/links/$1/on ]]; }
# agents_look: P_STATE and P_CTX for the agent panes gather listed (A_AT, the row of each, with
# A_KIND, A_PID and A_TREE). A run of tmux for each agent's screen and of jq for each Claude
# Code record is what made a look at the panes slow on a busy machine: here it's one of each,
# a marker line after each screen to tell them apart. tmux stops at a pane that has closed
# meanwhile, and jq at a record caught half written: those after it are looked at one by one,
# the way they were before.
declare -A JQ_ST=() JQ_SID=()
agents_look() {
	local i j n=0 kind apid st mark f s sid
	local -a cmd=() out=() recs=() ast=() SL
	JQ_ST=() JQ_SID=()
	((${#A_AT[@]})) || return 0
	mark="@@revive-$RANDOM$RANDOM$RANDOM@@"
	for i in "${A_AT[@]}"; do cmd+=(capture-pane -p -t "${P_ID[i]}" \; display-message -p "$mark" \;); done
	mapfile -t out < <(tm "${cmd[@]:0:${#cmd[@]}-1}" 2>/dev/null)
	j=0
	for i in "${!out[@]}"; do
		((j < ${#A_AT[@]})) || break
		[[ ${out[i]} == "$mark" ]] || continue
		SL=("${out[@]:n:i-n}")
		lines_state SL
		ast[j]=$LSTATE n=$((i + 1)) j=$((j + 1))
	done
	for ((; j < ${#A_AT[@]}; j++)); do screen_state "${P_ID[A_AT[j]]}"; ast[j]=$LSTATE; done
	# Claude Code's records, for the agents whose screen isn't asking.
	for j in "${!A_AT[@]}"; do
		[[ ${A_KIND[j]} == claude && ${ast[j]} != asking ]] || continue
		claude_record "${A_PID[j]}"
		[[ -n $RECORD ]] && recs+=("$RECORD")
	done
	if ((${#recs[@]})); then
		while IFS=$'\t' read -r f s sid; do
			[[ -n $f && -z ${JQ_ST[$f]+set} ]] && JQ_ST[$f]=$s JQ_SID[$f]=$sid
		done < <(jq -r '[input_filename, .status // "", .sessionId // ""] | @tsv' "${recs[@]}" 2>/dev/null)
	fi
	for j in "${!A_AT[@]}"; do
		i=${A_AT[j]} kind=${A_KIND[j]} apid=${A_PID[j]} st=${ast[j]}
		CL_REC="" # what claude_look read is for this pane only
		# Claude Code's record says for itself whether it is busy, and outranks the screen.
		# With nothing in it to go by (no record found for this process, or one with no
		# status), the screen decides, as it does for the other agents. Idle while work it
		# started goes on in the background is working, but takes input.
		if [[ $kind == claude && $st != asking ]]; then
			claude_look "$apid"
			case $CST in busy) st=working ;; "") ;; *) st=waiting; ((CBG)) && st=agents ;; esac
		fi
		# shellcheck disable=SC2086
		ctx_left "$kind" "$apid" "${P_ID[i]}" ${A_TREE[j]}
		P_STATE[i]=$st P_CTX[i]=$CTX
	done
	JQ_ST=() JQ_SID=()
}
gather() {
	local pid ppid rss pcpu args id loc ppid0 cmd path name kind apid st q p tree cpu mem now dt t ssh ctx k all
	local -A tnow=()
	PCHILD=() PARGS=() PRSS=() PCPU=() PPAR=() PUID=() INPANE=()
	# Read from a string, not straight from ps: read takes a pipe a byte at a time, and every
	# process's whole command line is in there.
	all=$(ps -ww -eo pid=,ppid=,uid=,rss=,pcpu=,args= 2>/dev/null) # -ww: never cut to $COLUMNS
	while read -r pid ppid uid rss pcpu args; do
		[[ -n $pid ]] || continue
		PCHILD[$ppid]+="$pid " PARGS[$pid]=$args PRSS[$pid]=$rss PCPU[$pid]=$pcpu PPAR[$pid]=$ppid PUID[$pid]=$uid
	done <<<"$all"
	now=${EPOCHREALTIME:-$SECONDS}
	P_ID=() P_LOC=() P_NAME=() P_APP=() P_STATE=() P_DIR=() P_GIT=() P_CPU=() P_MEM=() P_CTX=() P_AGENT=() P_SSH=() P_HOST=() P_RID=() P_WP=() P_USER=() P_INST=()
	A_AT=() A_KIND=() A_PID=() A_TREE=()
	while IFS=$'\t' read -r id loc ppid0 cmd path name; do
		clean loc cmd path name
		# The pane's process tree, breadth-first, and the first agent in it.
		tree=() q=("$ppid0") kind="" apid=""
		while ((${#q[@]})); do
			p=${q[0]} q=("${q[@]:1}")
			tree+=("$p") INPANE[$p]=1
			if [[ -z $kind ]]; then agent_kind "${PARGS[$p]:-}"; kind=$AKIND; [[ -n $kind ]] && apid=$p; fi
			# shellcheck disable=SC2206
			[[ -n ${PCHILD[$p]:-} ]] && q+=(${PCHILD[$p]})
		done
		mem=0
		for p in "${tree[@]}"; do mem=$((mem + ${PRSS[$p]:-0})); done
		# CPU now, not the lifetime average ps reports: ticks used since the last frame.
		if [[ -r /proc/$ppid0/stat ]]; then
			tree_ticks "${tree[@]}"
			t=$TICKS
			cpu=0
			# Kept by pane and its process: a pane id tmux gives out again is another pane.
			if [[ -n $T_PREV && -n ${TICKS_PREV[$id:$ppid0]:-} ]]; then
				# The time between the looks in ms, then ticks / CLK_TCK / seconds as a whole
				# percent, rounded half up; none over no time, and never below 0.
				usecs "$now"
				dt=$US
				usecs "$T_PREV"
				dt=$(((dt - US + 500) / 1000))
				k=$((t - TICKS_PREV[$id:$ppid0]))
				((dt > 0 && k > 0)) && cpu=$(((2 * k * 100000 + CLK * dt) / (2 * CLK * dt)))
			fi
			tnow[$id:$ppid0]=$t
		else
			# ps's own figure (macOS): a percent with decimals, summed and rounded at each step.
			cpu=0
			for p in "${tree[@]}"; do
				[[ ${PCPU[$p]:-0} =~ ^([0-9]*)(\.([0-9]*))? ]]
				dt=${BASH_REMATCH[3]}000
				cpu=$((((cpu + 10#0${BASH_REMATCH[1]}) * 1000 + 10#${dt:0:3} + 500) / 1000))
			done
		fi
		ctx=""
		if [[ $id == "${TMUX_PANE:-}" ]]; then
			st=self P_APP+=("panel") P_AGENT+=(0)
		elif [[ -n $kind ]]; then
			# Its state and context left are looked at once every pane is listed (agents_look):
			# then one tmux reads all the agents' screens, and one jq Claude Code's records.
			st=agent
			A_AT+=("${#P_ID[@]}") A_KIND+=("$kind") A_PID+=("$apid") A_TREE+=("${tree[*]}")
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
				ssh_dest "${PARGS[$p]:-}"
				ssh=$SSHD
				[[ -n $ssh ]] && break
			done
		fi
		# window.pane from the place: tmux allows no : or . in a session name.
		# Whose it is: its agent's user, else the deepest process in it (root's shell after sudo -i).
		p=${apid:-${tree[${#tree[@]} - 1]}}
		UNAME=""
		[[ -n ${PUID[$p]:-} ]] && user_of "${PUID[$p]}"
		user_inst "$UNAME" "${PUID[$p]:-}" "$p"
		P_SSH+=("$ssh") P_HOST+=("") P_RID+=("") P_WP+=("${loc##*:}") P_USER+=("$UNAME") P_INST+=("$INST")
		P_ID+=("$id") P_LOC+=("$loc") P_NAME+=("$name") P_STATE+=("$st")
		git_info "$path"
		P_DIR+=("$path") P_GIT+=("$GITI") P_CPU+=("$cpu") P_MEM+=("$mem") P_CTX+=("$ctx")
	done < <(tm list-panes -a -F $'#{pane_id}\t#{session_name}:#{window_index}.#{pane_index}\t#{pane_pid}\t#{pane_current_command}\t#{pane_current_path}\t#{@agent}' 2>/dev/null)
	agents_look
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
	} 2>/dev/null <"$1"
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
	# Nor while it is stopped on a failure: each try would be one more failed connection there
	# (a server's fail2ban counts them). It waits for you to press B.
	[[ -f $ASTATE/links/$1/login || -f $ASTATE/links/$1/paused ]] && return 255
	# Bound to the host key you confirmed for the link, as agent-say's own calls are: ssh checks
	# it against the link's pin, whatever the ssh config says. agent-say _pin checks it afresh
	# on every call (a key revoked since, the fingerprint changed) and rebuilds it as needed; a
	# link it refuses gets nothing sent.
	local l=$ASTATE/links/$1 pin=() p
	# Or through your own open ssh connection to it, as the link's poller goes (agent-say _ride
	# says when, and how: it shows the key confirmed for the link, and no new connection is made).
	if [[ -s $l/fingerprint ]] && mapfile -t pin < <(timeout 20 "$ASAY" _ride "$1" </dev/null 2>/dev/null) && ((${#pin[@]})); then
		# shellcheck disable=SC2086
		timeout "${RTIMEOUT:-8}" ${AGENT_SAY_SSH:-ssh} "${pin[@]}" "$1" "$2" </dev/null 2>/dev/null
		return
	fi
	pin=()
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
	[[ ${P_STATE[SEL]:-} == login ]] && L=("" "  on $h: needs login · press B to type its password")
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
		# A link waiting for its login (press B) shows its names, marked so, and isn't asked.
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
# REVIVE_PANEL_OUTSIDE_SSH=0 skips this look (the tests: a panel there must not see the ssh
# sessions open in your own terminals).
outside_ssh() {
	local pid a h up where c
	X_SSH=() X_WHERE=()
	[[ ${REVIVE_PANEL_OUTSIDE_SSH:-1} == 0 ]] && return
	for pid in "${!PARGS[@]}"; do
		[[ -n ${INPANE[$pid]:-} || ${PUID[$pid]:-} != "$UID" ]] && continue
		a=${PARGS[$pid]}
		[[ $a == *ssh* ]] || continue # most of them: no need to look closer
		ssh_dest "$a"
		h=$SSHD
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
SEL=0 SEL_ID="" PEEK=${REVIVE_PANEL_PEEK:-1} ANSWERING=0 FLASH="" FLASH_T=0 TICK=0
# nav: this frame only moves the selection. Then the messages, links and saves (MSG, SIDE) are
# kept from the last frame, unless MSG_OLD says they're due a look (new panes were gathered,
# or they were hidden). TCOLS and TLINES: the terminal's size, asked again with the panes.
nav=0 MSG=() SIDE=() MSG_OLD=1 TCOLS="" TLINES=""
# While answering: the rows above the question kept from its first frame (ATOP, the banner's
# height ATOP_BH), and the pane's screen as answer() last read it (QL cleaned for drawing,
# QRAW as it came, QSHOT the same as one string).
ATOP=() ATOP_BH=3 QL=() QRAW=() QSHOT=""
SPIN=(▖ ▘ ▝ ▗)
# The windows: 0 PANES, 1 PEEK (or the question), 2 MESSAGES, 3 LINKS · SAVES. J moves FOCUS
# along the ones drawn (WON, from the last frame); the arrows and PgUp/PgDn/Home/End scroll
# the focused one. Each window's view: PO the first PANES row shown (it follows the selection),
# PB how far the peek is scrolled back from the bottom of the screen, MO and SO the first
# MESSAGES and LINKS · SAVES rows shown. MMAN: MESSAGES scrolled by hand (otherwise it shows
# the newest, and never scrolls a waiting access request off its top). WH: each one's height
# last drawn, for a page's worth. PB_FOR: whose screen PB is for.
FOCUS=0 PO=0 PB=0 MO=0 SO=0 MMAN=0 PB_FOR="" MOLD=0 MWAIT=-1
WON=(1 0 0 0) WH=(1 1 1 1)
tab_next() { # tab_next [STEP] -> NEXTW: the window J (STEP 1) or K (3) moves the focus to
	local j f=$FOCUS
	NEXTW=$FOCUS
	for j in 1 2 3 4; do f=$(((f + ${1:-1}) % 4)); ((WON[f])) && { NEXTW=$f; return; }; done
}
# wstyle ASKING -> WF the window with the focus (the question's while answering it), WB each
# window's border colour and WK the key hint on its title. The focused one's border is bright
# cyan, as its title band, or bright magenta on a question, the asking colour; the others are
# FRAME. "[⇧J] focus" (Shift-J, not j) goes on the window J moves to next and "[⇧K] focus" on the
# one K moves to, both going round; with two windows they're the same one, "[⇧J/⇧K] focus". None
# with one window, nor while answering, where every key but Ctrl-] goes to the agent and the
# question says so.
wstyle() {
	WF=$FOCUS WB=("$FRAME" "$FRAME" "$FRAME" "$FRAME") WK=("" "" "" "")
	((ANSWERING)) && WF=1
	if ((WF == 1 && $1)); then WB[1]=$BMAG; else WB[WF]=$BCYN; fi
	((ANSWERING)) && return
	local nj
	tab_next; nj=$NEXTW
	tab_next 3
	((nj == FOCUS)) && return
	if ((NEXTW == nj)); then kc ⇧J/⇧K " focus"; WK[nj]=$KC; return; fi
	kc ⇧J " focus"; WK[nj]=$KC
	kc ⇧K " focus"; WK[NEXTW]=$KC
}
WF=0 WB=() WK=()
# HSEL: a linked computer's heading is selected (f on one of its panes folds it to that line,
# a row the arrows stop on; Enter opens it again). SEL stays on one of its panes, so the rest
# still has a pane.
# FOLD: the computers folded, kept in REVIVE_DIR so they stay folded the next time.
HSEL="" FOLDDIR="$DIR/panel/fold"
declare -A FOLD=()
fold_load() { local f; FOLD=(); for f in "$FOLDDIR"/*; do [[ -f $f ]] && FOLD[${f##*/}]=1; done; }
fold_toggle() { # fold_toggle HOST
	[[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return
	if [[ -n ${FOLD[$1]:-} ]]; then
		unset "FOLD[$1]"
		rm -f "$FOLDDIR/$1"
	else
		FOLD[$1]=1
		mkdir -p "$FOLDDIR" && : >"$FOLDDIR/$1"
	fi
}
# panes_rows -> NAV: the PANES list top down, one entry a row: a pane's index, or h:HOST for a
# computer's heading (h: alone for this computer's, which doesn't fold). A folded computer's
# panes aren't in it.
panes_rows() {
	local i g=-
	NAV=()
	for ((i = 0; i < ${#P_ID[@]}; i++)); do
		if ((P_GROUPS)) && [[ ${P_HOST[i]} != "$g" ]]; then g=${P_HOST[i]}; NAV+=("h:$g"); fi
		[[ -n ${P_HOST[i]} && -n ${FOLD[${P_HOST[i]}]:-} ]] && continue
		NAV+=("$i")
	done
}
nav_at() { # nav_at -> NAT: where the selection is in NAV
	local i
	NAT=0
	for i in "${!NAV[@]}"; do
		if [[ -n $HSEL ]]; then [[ ${NAV[i]} == "h:$HSEL" ]] && { NAT=$i; return; }
		elif [[ ${NAV[i]} == "$SEL" ]]; then NAT=$i; return; fi
	done
}
# nav_stop INDEX: is that row of NAV one the selection stops on? A pane, or a folded
# computer's heading (its one row). An open computer's heading isn't, nor this computer's.
nav_stop() {
	local h=${NAV[$1]}
	[[ $h == h:* ]] || return 0
	h=${h#h:}
	[[ -n $h && -n ${FOLD[$h]:-} ]]
}
# nav_go INDEX [STEP]: select that row of NAV, or failing that the next stop STEP (1 or -1)
# away, or at the end of the list the nearest stop back. A heading selects one of its
# computer's panes behind it.
nav_go() {
	local k=${#NAV[@]} i=$1 d=${2:-1} j
	((k)) || return
	((i < 0)) && i=0
	((i >= k)) && i=$((k - 1))
	j=$i
	while ((j >= 0 && j < k)) && ! nav_stop "$j"; do j=$((j + d)); done
	if ((j < 0 || j >= k)); then j=$i; while ((j >= 0 && j < k)) && ! nav_stop "$j"; do j=$((j - d)); done; fi
	((j < 0 || j >= k)) && return
	i=$j
	if [[ ${NAV[i]} == h:* ]]; then
		HSEL=${NAV[i]#h:}
		for j in "${!P_HOST[@]}"; do [[ ${P_HOST[j]} == "$HSEL" ]] && { SEL=$j; break; }; done
	else
		HSEL="" SEL=${NAV[i]}
	fi
}
# sel_fix: after the panes are gathered again. A heading whose computer has gone is let go; a
# pane selected inside a folded computer gives way to its heading.
sel_fix() {
	local j h=""
	if [[ -n $HSEL ]]; then
		for j in "${!P_HOST[@]}"; do [[ ${P_HOST[j]} == "$HSEL" ]] && { h=$HSEL; SEL=$j; break; }; done
		HSEL=$h
	fi
	h=${P_HOST[SEL]:-}
	((P_GROUPS)) && [[ -z $HSEL && -n $h && -n ${FOLD[$h]:-} ]] && HSEL=$h
	SEL_ID=${P_ID[SEL]:-}
}

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
	login) CELL="$BYEL◌ needs login · B $R" ;;
	*) CELL="$CYN▸ running         $R" ;;
	esac
}

draw_panes() {
	local i n=${#P_ID[@]} name key folder git cells mark wide=1 NW=10 FW=10 GW v KW=3 pad UW=4 VW=3 us=1 extra
	# Who waits for access (G): each introduction's sender, as NAME@HOST.
	local gw=" " st d f
	for d in "$ASTATE"/intros/*/; do [[ -f $d/from ]] && read -r f <"$d/from" && gw+="$f "; done
	local -a lab=() nm=() ver=() stc=() need=()
	local -A ses=() many=() cnt=() needc=()
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
		# VER: the row's user's tmux-revive, or [U] when that user has none (U has the command
		# to install it). A linked computer whose rows say nothing of whose tmux it is has a
		# tmux-revive from before users: [U] there too, as U updates it.
		v=${P_INST[i]:-}
		if [[ $v == owner ]]; then
			v=$VERSION
			[[ -n ${P_HOST[i]} ]] && { v=${RVER[${P_HOST[i]}]:-}; [[ $v =~ $VER_RE ]] || v=""; }
		elif [[ -z $v && -n ${P_USER[i]:-} ]]; then v="[U]"
		elif [[ -n ${P_HOST[i]} && -n ${P_RID[i]:-} && -z ${ROWNER[${P_HOST[i]}]:-} ]]; then v="[U]"; fi
		ver[i]=$v
		((${#v} > VW)) && VW=${#v}
		((${#P_USER[i]} > UW)) && UW=${#P_USER[i]}
		# Its agent waiting for access through here: said in its STATE, unless it asks a question.
		st=${P_STATE[i]}
		[[ $st != asking && -n ${P_NAME[i]} && $gw == *" ${P_NAME[i]}@${P_HOST[i]:-${AGENT_SAY_HOST:-$HOST}} "* ]] && st=grant
		# Whether the row needs you (a question, access waiting, [U]), and how many on each
		# computer do, for its heading.
		stc[i]=$st need[i]=0 key=${P_HOST[i]:-.}
		cnt[$key]=$((${cnt[$key]:-0} + 1))
		[[ $st == asking || $st == grant || $v == "[U]" ]] && need[i]=1 needc[$key]=$((${needc[$key]:-0} + 1))
	done
	((NW > 29)) && NW=29
	((FW > 35)) && FW=35
	((UW > 10)) && UW=10
	((VW > 11)) && VW=11
	# More rows than the list has room for (PH, from draw): it scrolls, and its rows are one
	# narrower for the scroll bar.
	local tot=${#NAV[@]} cw=$IW
	((tot > PH)) && cw=$((IW - 1))
	# USER and VER, and a space after each.
	extra=$((UW + VW + 2))
	GW=$((cw - 65 - KW - NW - FW - extra))
	# A narrow panel cuts GIT first, down to 13, then the folder and the name, down to 10. Too
	# narrow for that, the folder and GIT go and the name has their room: the narrowest panel
	# takes the name down to 10 to keep CTX LEFT.
	v=$((13 - GW < FW - 10 ? 13 - GW : FW - 10)); ((v > 0)) && FW=$((FW - v)) GW=$((GW + v))
	v=$((13 - GW < NW - 10 ? 13 - GW : NW - 10)); ((v > 0)) && NW=$((NW - v)) GW=$((GW + v))
	((GW < 13)) && wide=0 NW=$((cw - 63 - KW - extra))
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
	((tot > PH)) && RBAR=" "
	row "$GRY$hdr$R"
	RBAR=""
	# The list's rows (NAV's order), and which need you, before the window's share is cut out.
	local -a lr=() ln=()
	local en c group sl
	for en in "${NAV[@]}"; do
		# One heading per computer, once panes from a linked one are listed: a linked one's says
		# how many panes it has and how many of them need you, which shows when it's folded.
		if [[ $en == h:* ]]; then
			group=${en#h:}
			if [[ -z $group ]]; then
				lr+=("$BLU▓▒░$R $B$BWHT${HOST^^}$R $GRY· this computer$R") ln+=(0)
				continue
			fi
			c=${cnt[$group]:-0}
			if [[ $HSEL == "$group" ]]; then mark="$BYEL▶$R$BLU▒░$R $REV$B$BCYN${group^^}$R"; else mark="$BLU▓▒░$R $B$BWHT${group^^}$R"; fi
			mark+=" $GRY· linked · $c pane"
			((c == 1)) || mark+=s
			mark+=$R
			((${needc[$group]:-0})) && mark+=" $GRY·$R $B$BMAG${needc[$group]} needs you$R"
			lr+=("$mark") ln+=($((${needc[$group]:-0} > 0)))
			continue
		fi
		i=$en
		name=${nm[i]}
		printf -v pad '%*s' $((KW - ${#lab[i]} - 2)) ''
		if [[ -n ${lab[i]} ]]; then key="$BBLU[$BWHT$B${lab[i]}$R$BBLU]$R$pad"; else key="$GRY ·$R$pad"; fi
		folder=${P_DIR[i]/#$HOME/\~}
		folder=${folder##*/}
		git=${P_GIT[i]}
		cells="$key "
		sl=0; [[ -z $HSEL ]] && ((i == SEL)) && sl=1
		if ((sl)); then mark="$BYEL▶$R"; else mark=" "; fi
		cells+="$mark "
		fld "$name" "$NW"
		if ((sl)); then cells+="$REV$BCYN$FLD$R "
		elif [[ -z ${P_NAME[i]} ]]; then cells+="$GRY$FLD$R "
		else cells+="$BWHT$FLD$R "; fi
		if ((us)); then
			fld "${P_USER[i]:-}" "$UW"
			cells+="$CYN$FLD$R "
			fld "${ver[i]}" "$VW"
			if [[ ${ver[i]} == "[U]" ]]; then cells+="$BYEL$FLD$R "
			elif [[ -n ${ver[i]} && -n $VERSION ]] && ver_lt "${ver[i]}" "$VERSION"; then cells+="$BYEL$FLD$R "
			else cells+="$GRY$FLD$R "; fi
		fi
		fld "${P_APP[i]}" 9
		if ((P_AGENT[i])); then cells+="$BCYN$FLD$R "; else cells+="$CYN$FLD$R "; fi
		state_cell "${stc[i]}"
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
		lr+=("$cells") ln+=("${need[i]}")
	done
	((n)) || { row "$GRY  no tmux panes found$R"; return; }
	# The window: PH rows from PO, moved just enough to keep the selection in view. Rows that
	# need you above or below it light that end's arrow.
	nav_at
	((NAT < PO)) && PO=$NAT
	((NAT >= PO + PH)) && PO=$((NAT - PH + 1))
	((PO > tot - PH)) && PO=$((tot - PH))
	((PO < 0)) && PO=0
	local up=0 dn=0
	for ((i = 0; i < tot; i++)); do
		((ln[i])) || continue
		((i < PO)) && up=1
		((i >= PO + PH)) && dn=1
	done
	sbar "$PH" "$tot" "$PO" "$up" "$dn" "${WB[0]}"
	local w
	for ((i = 0; i < PH && PO + i < tot; i++)); do
		RBAR=${SB[i]:-}
		c=${lr[PO + i]}
		# With the focus in PANES, the selected row has a faint background right across, so its
		# numbers on the far right are easy to match to its name. Every reset puts it back.
		if ((WF == 0 && PO + i == NAT)); then
			w=$IW
			[[ -n $RBAR ]] && w=$((IW - 1))
			vlen "$c"
			((VLEN > w)) && { trim_colored "$c" "$w"; c=$TRIM VLEN=$w; }
			printf -v pad '%*s' $((w - VLEN)) ''
			c="$SELBG${c//$R/$R$SELBG}$pad$R"
			row "$c" "$w"
		else
			row "$c"
		fi
	done
	RBAR=""
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
	local id=${P_ID[SEL]:-} i keys name=${P_NAME[SEL]:-${P_LOC[SEL]:-}} fc=4 ft=""
	if [[ ${P_STATE[SEL]:-} == asking ]]; then
		draw_question "$1"
		return
	fi
	((WF == 1)) && fc=6 ft="▸ "
	kc p " hide"
	# Its agents working in the background don't keep it from taking what you type.
	if [[ ${P_STATE[SEL]:-} == agents ]]; then sectk "${ft}PEEK · $name · agents busy, takes input" "$KC" $fc "${WB[1]}" "${WK[1]}"; else sectk "${ft}PEEK · $name" "$KC" $fc "${WB[1]}" "${WK[1]}"; fi
	if [[ -n ${P_HOST[SEL]:-} ]]; then
		remote_peek 60 # all it may ask for, to scroll back through
	elif [[ -n $id ]]; then
		mapfile -t L < <(tm capture-pane -p -t "$id" 2>/dev/null)
		for i in "${!L[@]}"; do clean "L[$i]"; done # capture-pane passes C1 characters through
	fi
	peek_rows "$1" "$GRY" 0 "${WB[1]}"
}
# peek_rows LINES COLOUR STYLED BAR-COLOUR: the bottom of its screen (L), row for row: the box's
# last line is the pane's last line, blank or not, and it reads upward from there, each after
# a │ in COLOUR. STYLED 1: each line in its QSTYLE colour (the question), else dim. A screen
# shorter than the box is padded above, so the bottoms still line up; a taller one scrolls
# back PB rows from the bottom, with a scroll bar in BAR-COLOUR.
peek_rows() {
	local h=$1 c=$2 n=${#L[@]} start i w=$((IW - 2)) vw=$IW st a b
	((PB > n - h)) && PB=$((n - h))
	((PB < 0)) && PB=0
	start=$((n - h - PB))
	((start < 0)) && start=0
	sbar "$h" "$n" "$start" 0 0 "$4"
	((${#SB[@]})) && w=$((IW - 3)) vw=$((IW - 1))
	for ((i = n; i < h; i++)); do row "$c│$R"; done
	for ((i = 0; i < h && start + i < n; i++)); do
		RBAR=${SB[i]:-}
		fld "${L[start + i]}" "$w"
		if (($3)); then st=${QSTYLE[start + i]:-$BWHT}; else st=$DIM; fi
		if (($3)) && [[ -n ${QHI[start + i]:-} ]]; then
			read -r a b <<<"${QHI[start + i]}"
			row "$c│$R $st${FLD:0:a}$QBAND$B$BWHT${FLD:a:b}$R$st${FLD:a+b}$R" "$vw"
		else
			row "$c│$R $st$FLD$R" "$vw"
		fi
	done
	RBAR=""
}

# The question the selected pane is asking, in place of its peek: only the dialog at the
# bottom of its screen, bright, from the top of the box down. Enter answers it from here (keys
# go to the pane until Ctrl-]); a chat with the agent is O, in the pane itself.
draw_question() { # draw_question LINES
	local id=${P_ID[SEL]:-} i keys name=${P_NAME[SEL]:-${P_LOC[SEL]:-}} ft=""
	if ((ANSWERING)); then
		kcs "Esc" " or" "Ctrl-]" " leaves"
		keys="$B${BMAG}keys go to $name$R  $KC"
	else
		if [[ -n ${P_HOST[SEL]:-} ]]; then kcs Enter " answer"; else kcs Enter " answer" O " open the chat"; fi
		keys=$KC
	fi
	# Focused, or answering, its title says so; its band stays magenta, the asking colour.
	((WF == 1)) && ft="▸ "
	sectk "${ft}QUESTION · $name" "$keys" 5 "${WB[1]}" "${WK[1]}"
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
	question_parts
	QHI=()
	[[ -z ${P_HOST[SEL]:-} && -n $id ]] && qhi "$id"
	peek_rows "$1" "$BMAG" 1 "$BMAG"
}

# qhi %ID -> QHI[i]="START LENGTH": on a question's tab bar ("←  ☐ Fruit  ✔ Submit  →"), the
# tab Claude Code highlights, which it marks only by a background colour that the plain
# capture loses. Read from the pane's coloured capture, SGR codes only; START counts
# characters of the plain line, which is the same text. Drawn on the QBAND (peek_rows).
qhi() {
	local i s p c pos st en on
	local -a E P
	QHI=()
	for i in "${!L[@]}"; do [[ ${L[i]} =~ ^[[:space:]]*←.*→[[:space:]]*$ ]] && break; done
	[[ ${L[i]:-} =~ ^[[:space:]]*←.*→[[:space:]]*$ ]] || return 0
	mapfile -t E < <(tm capture-pane -e -p -t "$1" 2>/dev/null)
	for i in "${!L[@]}"; do
		[[ ${L[i]} =~ ^[[:space:]]*←.*→[[:space:]]*$ ]] || continue
		s=${E[i]:-} pos=0 st=-1 en=-1 on=0
		while [[ -n $s ]]; do
			if [[ $s =~ ^$e\[([0-9\;:]*)m ]]; then
				s=${s:${#BASH_REMATCH[0]}}
				IFS=';' read -ra P <<<"${BASH_REMATCH[1]:-0}"
				((${#P[@]})) || P=(0)
				for ((c = 0; c < ${#P[@]}; c++)); do
					p=${P[c]%%:*}
					case $p in
					"" | 0 | 27 | 49) on=0 ;;
					7 | 4[0-7] | 10[0-7]) on=1 ;;
					48) on=1; [[ ${P[c + 1]:-} == 5 ]] && ((c += 2)); [[ ${P[c + 1]:-} == 2 ]] && ((c += 4)) ;;
					38 | 58) [[ ${P[c + 1]:-} == 5 ]] && ((c += 2)); [[ ${P[c + 1]:-} == 2 ]] && ((c += 4)) ;;
					esac
				done
			else
				[[ ${s:0:1} == "$e" ]] && { s=${s:1}; continue; } # any other escape: not text
				if ((on)) && [[ ${s:0:1} != " " || $st -ge 0 ]]; then ((st < 0)) && st=$pos; [[ ${s:0:1} != " " ]] && en=$pos; fi
				s=${s:1} pos=$((pos + 1))
			fi
		done
		((st >= 0 && en >= st)) && QHI[i]="$st $((en - st + 1))"
	done
}

# question_parts: a colour for each line of L by what it is, so the question stands out:
# the question itself bold yellow, the highlighted choice bold bright white on a band, the other
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
		# The highlighted choice brighter than the rest, on the QBAND.
		elif [[ ${L[i]} =~ ^[[:space:]│]*❯.*\[[^[:space:]]\] ]]; then QSTYLE[i]=$QBAND$B$BGRN # highlighted, and ticked
		elif [[ ${L[i]} =~ ^[[:space:]│]*❯ ]]; then QSTYLE[i]=$QBAND$B$BWHT  # the highlighted choice
		elif [[ ${L[i]} =~ ^[[:space:]│]*[0-9]+\.[[:space:]]*\[[^[:space:]]\] ]]; then QSTYLE[i]=$B$BGRN # a ticked choice ([✔], as Claude Code greens it)
		elif [[ ${L[i]} =~ ^[[:space:]│]*(\[.\][[:space:]]*)?[0-9]+\. ]]; then QSTYLE[i]=$BWHT # a choice
		else QSTYLE[i]=$GRY; fi                                               # a choice's description
	done
}

messages() { # -> MSG lines for the message center; INTRO_ON
	MSG=()
	local h b from to when id rest qn why k i j d c f t gn now more
	local -a H=() BS=() WAIT=() ASKS=() OLDM=()
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
				WAIT+=("$GRY$when$R $B$BYEL$BLINK⚑$R $B${BMAG}waiting for [G]rant access$R $BWHT$from$R$GRY→$R$BWHT$to$R $GRY· $b$R")
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
		# The last four show under the waiting ones; older ones sit above them (OLDM), to scroll
		# back to.
		if ((${#MSG[@]} > 4)); then OLDM=("${MSG[@]:0:${#MSG[@]}-4}") MSG=("${MSG[@]: -4}"); fi
	fi
	# One waiting whose held rows are older than the ones read: from its introduction instead.
	for d in "${ASKS[@]}"; do
		c=$(head -n 1 "$d/created" 2>/dev/null)
		[[ -n $c && -n ${shown[$c]:-} ]] && continue
		f=$(head -n 1 "$d/from") t=$(head -n 1 "$d/to") b=$(head -c 200 "$d/intro" 2>/dev/null)
		clean f t b
		[[ $c =~ ^[0-9]{1,12}$ ]] && TZ=UTC printf -v when '%(%H:%M)T' "$c" || when="--:--"
		WAIT+=("$GRY$when$R $B$BYEL$BLINK⚑$R $B${BMAG}waiting for [G]rant access$R $BWHT$f$R$GRY→$R$BWHT$t$R${b:+ $GRY· $b$R}")
	done
	# Waiting ones first, so other messages never push them off: a few, then a count.
	if ((${#WAIT[@]} > 3)); then
		more=$((${#WAIT[@]} - 2))
		WAIT=("${WAIT[@]:0:2}" "$B$BYEL$BLINK⚑$R $B$BMAG$more more waiting for [G]rant access$R")
	fi
	((${#WAIT[@]} + ${#MSG[@]})) || MSG+=("$GRY no messages yet · ask an agent to use agent-say$R")
	MSG=("${OLDM[@]}" "${WAIT[@]}" "${MSG[@]}")
	MOLD=${#OLDM[@]}                     # how many older ones sit above
	MWAIT=$((${#WAIT[@]} ? MOLD : -1)) # where the waiting ones start, if any
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
	# The folders in snapshots/ (as find -type d counts them: dot ones too, no links), without a
	# find and a wc each frame.
	n=0
	for d in "$DIR"/snapshots/* "$DIR"/snapshots/.[!.]* "$DIR"/snapshots/..?*; do
		[[ -d $d && ! -L $d ]] && ((n++))
	done
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
			SIDE+=("$BYEL●$R $BWHT$h$R$mode $BYEL· needs login ·$R $BBLU[$B${BYEL}B$R$BBLU]$R${BWHT} log in$R")
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
	# ssh connections in panes that aren't linked yet: offered for linking with B.
	local i seen=" "
	for i in "${!P_SSH[@]}"; do
		h=${P_SSH[i]}
		[[ -z $h || $seen == *" $h "* ]] && continue
		seen+="$h "
		linked "$h" && continue
		SIDE+=("$BYEL◇$R $BWHT$h$R $GRY· ssh in ${P_NAME[i]:-${P_LOC[i]}} ·$R $BBLU[$B${BYEL}B$R$BBLU]$R${BWHT}ridge?$R")
	done
	for i in "${!X_SSH[@]}"; do
		h=${X_SSH[i]}
		[[ $seen == *" $h "* ]] && continue
		seen+="$h "
		linked "$h" && continue
		SIDE+=("$BYEL◇$R $BWHT$h$R $GRY· ssh in ${X_WHERE[i]} ·$R $BBLU[$B${BYEL}B$R$BBLU]$R${BWHT}ridge?$R")
	done
	((${#SIDE[@]} > 2)) || SIDE+=("$GRY  no links · ssh to a host and press B$R")
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
	if ((lines - PH >= 30)); then
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
	if ((WF == 0)); then sect "▸ PANES" 6 "${WB[0]}" "${WK[0]}"; else sect PANES 4 "${WB[0]}" "${WK[0]}"; fi
	ROWL=${WB[0]} ROWR=${WB[0]}
	draw_panes
	# CPU across every pane, as a running graph.
	for i in "${!P_CPU[@]}"; do [[ -z ${P_HOST[i]} ]] && total=$((total + P_CPU[i])); done
	CPU_HIST+=("$total")
	((${#CPU_HIST[@]} > 200)) && CPU_HIST=("${CPU_HIST[@]: -200}")
	vlen "$counts"
	spark $((IW - 8 - VLEN))
	row "$GRY cpu $R$SPARK  $counts"
	ROWL=$FRAME ROWR=$FRAME
}

draw() {
	local cols lines n i LW RW avail peek_h=0 l r BH=3 PH sst=""
	[[ -n $TCOLS ]] || TCOLS=$(tput cols 2>/dev/null || echo 100) TLINES=$(tput lines 2>/dev/null || echo 40)
	cols=$TCOLS lines=$TLINES
	((ONCE)) && cols=${COLUMNS:-$cols} lines=${LINES:-$lines}
	W=$((cols < 80 ? 80 : cols)) IW=$((W - 4))
	OUT=()
	n=${#P_ID[@]}
	# PANES takes about half of what the banner, bars and messages leave, so the peek keeps
	# its room; it scrolls past that.
	panes_rows
	PH=${#NAV[@]}
	i=$(((lines - 16) / 2))
	((i < 3)) && i=3
	((PH > i)) && PH=$i
	((PH)) || PH=1 # "no tmux panes found"
	# The selected pane's state; none while a heading is selected (no peek, no question).
	[[ -n $HSEL ]] || sst=${P_STATE[SEL]:-}
	# Another pane selected: its peek starts at the bottom of its screen.
	[[ "$SEL_ID|$HSEL" == "$PB_FOR" ]] || PB=0 PB_FOR="$SEL_ID|$HSEL"
	# A question needs every row it can get: the messages step aside until it's answered.
	local msgs=1 ask=0
	[[ $sst == asking ]] && msgs=0 ask=1
	# The styles for PANES's title, drawn first: whether J goes to PANES next turns on the
	# windows after the focused one, MESSAGES and LINKS · SAVES, known already.
	WON[2]=$msgs WON[3]=$msgs
	wstyle $ask
	if ((ANSWERING && ${#ATOP[@]})); then
		# Answering: nothing above the question can change (no panes are gathered meanwhile),
		# so those rows are kept from the first frame, and only the question and the bar drawn.
		OUT=("${ATOP[@]}") BH=$ATOP_BH
	else
		draw_top || return
		((ANSWERING)) && ATOP=("${OUT[@]}") ATOP_BH=$BH
	fi

	# Nor are the messages looked at meanwhile. Moving the selection can't change them, so
	# they're kept.
	local bottom=-1 bcap
	if ((ask)); then
		MSG_OLD=1
	else
		((nav && !MSG_OLD)) || { messages; links_saves; MSG_OLD=0; }
		# As tall as they are without the older messages kept above, and a quarter of the height
		# at most (4 rows at least): MESSAGES and LINKS · SAVES scroll past that.
		bottom=$((${#MSG[@]} - MOLD))
		((${#SIDE[@]} > bottom)) && bottom=${#SIDE[@]}
		bcap=$((lines / 4))
		((bcap < 4)) && bcap=4
		((bottom > bcap)) && bottom=$bcap
	fi
	# Fixed rows: frame 2, banner, section bars 3, column header 1, totals 1, keys 1. The peek
	# takes all the rest. Hidden (P), only its title stays, offering P to show it, and the
	# scene fills the space below, so the panel fills its pane. With nothing to peek at (a
	# heading, the panel's own pane) neither shows. A question shows even with the peek
	# hidden: it's waiting on you.
	avail=$((lines - BH - 8 - PH - bottom))
	# No peek at the panel's own pane: it would only show itself. Nor at a heading.
	local show=0 bar=0
	if ((n && avail >= 4)) && [[ -n $sst && $sst != self ]]; then
		if ((PEEK)) || [[ $sst == asking ]]; then show=1; else bar=1; fi
	fi
	# The windows drawn, for J and K; one that's gone hands the focus back to PANES, drawn again.
	WON=(1 "$show" "$msgs" "$msgs")
	((ANSWERING || WON[FOCUS])) || { FOCUS=0; draw; return; }
	wstyle $ask
	if ((show)); then
		# All the room, title and all.
		peek_h=$avail avail=0
		ROWL=${WB[1]} ROWR=${WB[1]}
		draw_peek $((peek_h - 1))
		ROWL=$FRAME ROWR=$FRAME
	elif ((bar)); then
		kc p " show"
		sectk "PEEK · ${P_NAME[SEL]:-${P_LOC[SEL]:-}}" "$KC" 4
		avail=$((avail - 1))
	fi
	if ((avail >= 3)); then
		sect "ART · ${TITLES[SCENE]}"
		art "$IW" $((avail - 1))
		for l in "${ART[@]}"; do row "$l" "$IW"; done
		avail=0
	fi
	for ((; avail > 0; avail--)); do row ""; done

	WH=("$PH" $((peek_h - 1)) "$bottom" "$bottom")
	LW=$(((IW - 3) * 3 / 5)) RW=$((IW - 3 - LW))
	if ((msgs)); then
		# The │ between them, and the ╤ over it, are the focused one's edge when either is.
		local mt="MESSAGES" st="LINKS · SAVES" mc=4 sc=4 mid=$FRAME
		((WF == 2)) && mt="▸ $mt" mc=6 mid=${WB[2]}
		((WF == 3)) && st="▸ $st" sc=6 mid=${WB[3]}
		sect2 "$((LW + 1))" "$mid" "$mt" $mc "${WB[2]}" "${WK[2]}" "$st" $sc "${WB[3]}" "${WK[3]}"
		# MESSAGES shows its newest unless scrolled by hand, but never past the first access
		# waiting on you. Rows waiting on you (access, or a message not delivered) out of view
		# light that end's arrow.
		local mn=${#MSG[@]} up=0 dn=0 lw=$LW rw=$RW
		local -a msb ssb
		((MMAN)) || { MO=$((mn - bottom)); ((MWAIT >= 0 && MWAIT < MO)) && MO=$MWAIT; }
		((MO > mn - bottom)) && MO=$((mn - bottom))
		((MO < 0)) && MO=0
		((SO > ${#SIDE[@]} - bottom)) && SO=$((${#SIDE[@]} - bottom))
		((SO < 0)) && SO=0
		for ((i = 0; i < mn; i++)); do
			[[ ${MSG[i]} == *"waiting for [G]rant access"* || ${MSG[i]} == *"✗"* ]] || continue
			((i < MO)) && up=1
			((i >= MO + bottom)) && dn=1
		done
		sbar "$bottom" "$mn" "$MO" "$up" "$dn" "${WB[2]}"
		msb=("${SB[@]}")
		sbar "$bottom" "${#SIDE[@]}" "$SO" 0 0 "${WB[3]}"
		ssb=("${SB[@]}")
		ROWL=${WB[2]} ROWR=${WB[3]}
		((${#msb[@]})) && lw=$((LW - 1))
		((${#ssb[@]})) && rw=$((RW - 1))
		for ((i = 0; i < bottom; i++)); do
			l=${MSG[MO + i]:-} r=${SIDE[SO + i]:-}
			vlen "$l"
			((VLEN > lw)) && { trim_colored "$l" "$lw"; l=$TRIM; }
			vlen "$l"
			rep ' ' $((lw - VLEN))
			l+=$REP
			((${#msb[@]})) && l+=" ${msb[i]}"
			vlen "$r"
			((VLEN > rw)) && { trim_colored "$r" "$rw"; r=$TRIM; }
			RBAR=${ssb[i]:-}
			if ((${#msb[@]})); then row "$l$mid│$R $r"; else row "$l $mid│$R $r"; fi
		done
		RBAR="" ROWL=$FRAME ROWR=$FRAME
	fi

	# Command bar.
	local k=""
	((!ANSWERING)) && [[ $sst == asking ]] && k="$B$BMAG[Enter]$R$B$BWHT answer$R  "
	# Keys that can't act on the selected pane are faded: on a linked computer's pane, nothing
	# to rename unless its rows say which pane it is, and never O: opening it would move
	# focus somewhere you may be busy (another pane, or tmux over there). On a heading, none
	# of the pane's own keys.
	local off=" " rh=${P_HOST[SEL]:-}
	if [[ -n $HSEL ]]; then
		off+="O M N "
	elif [[ -n $rh ]]; then
		[[ -n ${P_RID[SEL]:-} ]] || off+="N "
		[[ -n ${P_NAME[SEL]:-} ]] || off+="M "
		off+="O "
	fi
	local cs=("O:pen" "M:essage" "N:ame" "B:ridge" "U:pdate")
	# f on a linked computer's pane or heading: fold that computer to its heading, or open it.
	# (F, every one at once, is the help page's.)
	local fh=${HSEL:-${P_HOST[SEL]:-}}
	if [[ -n $fh ]]; then
		if [[ -n ${FOLD[$fh]:-} ]]; then cs+=("F: unfold"); else cs+=("F:old"); fi
	fi
	((${INTRO_ON:-0})) && cs+=("G:rant access")
	cs+=("A:rt" "S:ave" "Q:uit" "?: help")
	for c in "${cs[@]}"; do
		if [[ $off == *" ${c%%:*} "* ]]; then
			k+="$GRY[${c%%:*}]${c#*:}$R  "
		else
			k+="$BBLU[$B$BYEL${c%%:*}$R$BBLU]$R$BWHT${c#*:}$R  "
		fi
	done
	vlen "$k"
	# How to move: in PANES the arrows select, elsewhere they scroll. J is on the title of the
	# window it goes to.
	if ((FOCUS)); then
		if ((VLEN + 19 <= IW)); then k+="$GRY↑↓ PgUp PgDn scroll$R"
		elif ((VLEN + 9 <= IW)); then k+="$GRY↑↓ scroll$R"; fi
	elif ((VLEN + 15 <= IW)); then k+="$GRY↑↓ 0-9 select$R"; fi
	if [[ -n $FLASH ]] && ((SECONDS - FLASH_T < 5)); then k="$BGBLU$B$BWHT $FLASH $R  $k"; fi
	# While answering every key goes to the agent, so the bar says that and how to stop.
	((ANSWERING)) && k="$e[45m$B$BWHT ANSWERING ${P_NAME[SEL]:-${P_LOC[SEL]:-}} $R  $BMAG every key goes to its question ·$R $B${BYEL}Esc$R$BMAG or $B${BYEL}Ctrl-]$R$BMAG leaves$R"
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
		# once. A twinkling star then rewrites one line, not the whole screen. The cursor is left
		# at the top: at the bottom right, past the last cell, a single character written there
		# would scroll the whole panel.
		local buf="" i
		for i in "${!OUT[@]}"; do
			[[ ${OUT[i]} == "${PREV[i]-}" ]] && continue
			buf+="$e[$((i + 1));1H${OUT[i]}$e[K"
		done
		((${#OUT[@]} < ${#PREV[@]})) && buf+="$e[$((${#OUT[@]} + 1));1H$e[J"
		PREV=("${OUT[@]}")
		[[ -n $buf ]] && printf '%s' "$e[?2026h$buf$e[H$e[?2026l"
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
	# agent-say is read in first for its input box; the code is made after, in the popup only.
	pc=$(printf '%q ' bash -c 'export AGENT_SAY_MAILBOX="$3"; o=$4 s=$5; source "$s" || exit 1; c=$(( $(od -An -N4 -tu4 /dev/urandom) % 9000 + 1000 )); input_box ACCESS "Type $c and press Enter to $2" plain "Anything else counts as no · Esc cancels" "$1" && [[ $BOX_REPLY == "$c" ]] || exit 1; export AGENT_SAY_APPROVE_CODE="$c"; shift 5; "$@" "$c" >"$o" 2>&1' _ "$q" "$verb" "$AMAIL" "$out" "$ASAY" "$@")
	rm -f "$out"
	# Tall enough for the question whole, however long the names in it are (it wraps, never cut).
	tm display-popup -E -w 76 -h $((12 + ${#q} / 60)) "$pc" 2>/dev/null
	tail -n 1 "$out" 2>/dev/null || true
	rm -f "$out"
}

# read_host_keys HOST [--new | --fresh] -> KEYS: its key fingerprints, the one ssh would use
# first, and KEY_STATE: where they came from (agent-say's key_state: recorded, trusted (your
# known_hosts), live (read through your open ssh connection), changed, unknown (first seen by
# ssh-keyscan); anything else is taken as unknown).
read_host_keys() {
	local k
	KEYS=() KEY_STATE=unknown
	while IFS= read -r k; do
		if [[ $k =~ ^state:\ (recorded|trusted|live|changed|unknown)$ ]]; then KEY_STATE=${BASH_REMATCH[1]}
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
	cmd=$(printf '%q ' env AGENT_SAY_MAILBOX="$AMAIL" ${AGENT_SAY_SCAN_ID:+AGENT_SAY_SCAN_ID="$AGENT_SAY_SCAN_ID"} ${AGENT_SAY_SSH:+AGENT_SAY_SSH="$AGENT_SAY_SSH"} \
		${AGENT_SAY_KNOWN_HOSTS:+AGENT_SAY_KNOWN_HOSTS="$AGENT_SAY_KNOWN_HOSTS"} \
		${AGENT_SAY_KEYSCAN:+AGENT_SAY_KEYSCAN="$AGENT_SAY_KEYSCAN"} "$ASAY" _login "$h" "$@")
	if [[ -n $(tm list-clients -F x 2>/dev/null) ]]; then
		tm display-popup -E -w 84 -h 14 "$cmd" 2>/dev/null # returns when it closes
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
# shadow, listing ITEMs. ↑↓ (j k) or 1-9 choose, Enter picks (-> PICKED, the index), Esc or q closes
# it (returns 1). Ctrl-C closes it too, read in slices as in ask. An ITEM starting with $NOTE
# is a line to read (a heading, some words), not a choice: unnumbered, and never picked.
# Set for one call (PKEYS=u pick ...): PKEYS, letters that also pick the highlighted item
# (-> PKEY, the letter; Enter leaves it empty), on the items PKROWS lists (" 0 3 ");
# PHINT, the hint line instead of the usual one; PSEL, the item highlighted first; PTICK, a function run every 0.2 s that returns 0 when PITEMS holds the items anew
# (as many, and no wider).
NOTE=$'\x1f' # clean takes control characters out of anything shown, so none can start with it
pick() {
	local title=$1 rows cols w h top left i k rest sel=-1 line hint=${PHINT:-"↑↓ choose · Enter picks · Esc closes"} INTR=0
	shift
	local -a items=("$@") ch=() num=()
	PKEY=""
	for i in "${!items[@]}"; do
		[[ ${items[i]} == "$NOTE"* ]] && continue
		num[i]=${#ch[@]} ch+=("$i")
		((sel < 0)) && sel=$i
	done
	((${#ch[@]})) || return 1
	[[ -n ${PSEL:-} && -n ${num[PSEL]:-} ]] && sel=$PSEL
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
		if [[ -n ${PBAR:-} && ${!PBAR:-} =~ ^([0-9]+)\ ([1-9][0-9]*)$ ]]; then
			# PBAR: the name of a variable holding "DONE TOTAL", drawn as a bar in the blank row.
			local pd=${BASH_REMATCH[1]} pt=${BASH_REMATCH[2]} pl pw pf
			pl=" $pd/$pt"
			pw=$((w - 6 - ${#pl})) pf=$((pw * pd / pt))
			rep █ "$pf"; local pon=$REP
			rep ░ $((pw - pf))
			printf '%s' "$e[$((top + 2 + ${#items[@]}));${left}H$bg$BWHT║  $BCYN$pon$CYN$REP$BWHT$pl  ║$R$GRY░$R"
		else
			printf '%s' "$e[$((top + 2 + ${#items[@]}));${left}H$bg$BWHT║$blank║$R$GRY░$R"
		fi
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
			[[ -n ${PTICK:-} ]] && "$PTICK" && { k=TICK; break; }
		done
		case $k in
		TICK) items=("${PITEMS[@]}") ;;
		CLOSE | q | Q) trap 'exit 0' INT; return 1 ;;
		$'\e')
			rest=""
			IFS= read -rsn2 -t 0.05 rest || true
			case $rest in
			'') trap 'exit 0' INT; return 1 ;; # a lone Esc closes the window
			'[A') ((num[sel] > 0)) && sel=${ch[num[sel] - 1]} ;;
			'[B') ((num[sel] < ${#ch[@]} - 1)) && sel=${ch[num[sel] + 1]} ;;
			esac ;;
		k) ((num[sel] > 0)) && sel=${ch[num[sel] - 1]} ;;
		j) ((num[sel] < ${#ch[@]} - 1)) && sel=${ch[num[sel] + 1]} ;;
		[1-9]) ((k - 1 < ${#ch[@]})) && sel=${ch[k - 1]} && { PICKED=$sel; trap 'exit 0' INT; return 0; } ;;
		"") PICKED=$sel; trap 'exit 0' INT; return 0 ;; # Enter
		*)
			[[ ${#k} == 1 && -n ${PKEYS:-} && $PKEYS == *"${k,,}"* ]] || continue
			[[ ${PKROWS:-} == *" $sel "* ]] || continue
			PICKED=$sel PKEY=${k,,}
			trap 'exit 0' INT; return 0 ;;
		esac
	done
}

# ------------------------------------------------------------------ answering a question
# Keys for a question, as they travel: tmux key names from a short list, or literal text as
# lit:HEX. Hex, so no shell on the way, here or on a linked computer, can read anything into
# it. Checked before a command line is built from them, and again where they're sent.
# No Escape: in Claude Code's question it cancels, and the agent is told you declined.
KEY_RE='^(Up|Down|Left|Right|Home|End|PPage|NPage|IC|DC|Enter|Tab|BTab|BSpace|Space|C-[a-z])$'
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
# a second after a key is sent, to show it react, and every 0.3 s otherwise. Esc, Ctrl-] (or
# Ctrl-C) leave without sending anything; it ends by itself once the pane stops asking.
# Questions only: a chat with the agent is O, in its own pane.
answer() {
	local h=${P_HOST[SEL]:-} id=${P_ID[SEL]:-} k rest seq txt st got gone=0 why=left pend="" INTR=0 f
	local shot="" sent=0 skips=0 idle=0 poll=0 tl=0 w to
	local -a TOKS AL
	[[ ${P_STATE[SEL]:-} == asking ]] || return 0
	[[ -n $h ]] && id=${P_RID[SEL]:-}
	[[ $id =~ ^%[0-9]+$ ]] || return 0
	ANSWERING=1 PEEK_EVERY=0 PREV=() ATOP=() QL=() QRAW=() QSHOT="" PB=0 # the dialog, at the bottom
	trap 'INTR=1' INT
	while :; do
		# Keys already waiting behind the ones just sent go first, so they reach the agent together
		# and are drawn once; but no more than three times running, so the view can't freeze.
		if ((sent && skips < 3)) && { [[ -n $pend ]] || read -t 0; }; then
			((skips++))
		else
			skips=0
			tl=${EPOCHREALTIME//[.,]/} # in µs: when this look began
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
			if ((poll)); then
				# 40 ms from the start of the last look, not from its end: a slow look (a busy
				# computer) doesn't stretch the time between them.
				w=$((40000 - (${EPOCHREALTIME//[.,]/} - tl)))
				((w < 1000)) && w=1000
				printf -v to '0.%06d' "$w"
				IFS= read -rsn1 -t "$to" k || { st=$? got=0; }
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
		$'\t') TOKS=(Tab) ;;
		$'\x7f' | $'\b') TOKS=(BSpace) ;;
		$'\e')
			# A lone Esc is Escape; the arrows and the like arrive as sequences.
			rest="" seq=""
			IFS= read -rsn1 -t 0.03 rest
			case $rest in
			# Esc leaves, like Ctrl-]: sent on, it would cancel the question and the agent
			# would be told you declined. What you ticked stays there, sent only by its Submit.
			# A sequence that came in too slowly to tell from Esc is let go of, not left
			# for the panel to read as keys of its own.
			"") while IFS= read -rsn1 -t 0.05 rest; do :; done; break ;;
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
	answered)
		flash "${P_NAME[SEL]:-${P_LOC[SEL]:-the pane}} has its answer"
		# Rows from over there asked for before this still say asking: they don't count now.
		[[ -n $h ]] && { : >"$RDIR/$h.answered-${id#%}"; RFETCH_T[$h]=0; } ;;
	esac
}

PREV=()
# user_note install|update USER [HOST]: the command that installs or updates tmux-revive for
# USER, to run in their own pane (on HOST, a linked computer): shown in a box over the panel,
# and put in tmux's paste buffer. Nothing is run for them from here. The install command is
# README.md's.
user_note() {
	local u=$2 cmd="tmux-revive update" who="$2's pane" f l
	[[ $u =~ $USER_RE ]] || return
	[[ -n ${3:-} ]] && who+=" on $3"
	if [[ $1 == install ]]; then
		cmd=""
		for f in "$REVIVE_ROOT/README.md" "$REVIVE_ROOT/install.sh"; do
			while IFS= read -r l; do
				l=${l#\#   }
				[[ $l =~ ^curl\ -fsSL\ https://[A-Za-z0-9./_-]+/install\.sh\ \|\ sh$ ]] && { cmd=$l; break 2; }
			done 2>/dev/null <"$f"
		done
		[[ -n $cmd ]] || return
	fi
	# Into tmux's paste buffer, and the system clipboard too where the terminal allows (-w).
	tm set-buffer -w -- "$cmd" 2>/dev/null || tm set-buffer -- "$cmd" 2>/dev/null
	note "$1 for $u" "Run this in $who:" "" "$cmd" "" "Copied. Paste it there, or press prefix ]."
}
# unlink_host HOST: agent-say unlink, and what it said on the bar.
unlink_host() {
	local out
	flash "unlinking $1…"; draw
	out=$(timeout 30 "$ASAY" unlink "$1" 2>&1 | tail -n 1)
	clean out
	[[ -d $ASTATE/links/$1 ]] || rm -f "$RDIR/$1.rows" # what it kept of that computer
	flash "${out#agent-say: }"
}

# U: tmux-revive updated everywhere it can be, all at once, in a popup that shows each line
# as it goes: this computer's (yours), and each linked computer's over its link. Each is tried
# once; one that fails says so and is never tried again until you press U again (a server's
# fail2ban counts every try). Another user's install, here or there, is theirs to update:
# nothing runs as them. Its line has [I], and I shows the command to run in their pane.
# UPD_KIND: job (here, or HOST over ssh), skip (a link waiting for you: not tried), or note
# (an [I] line); UPD_ARG: the host, or for a note "install|update USER [HOST]".
UPD_DIR="$RDIR/update"
UPD_N=0 UPD_NAME=() UPD_KIND=() UPD_ARG=() UPD_TEXT=() UPD_PID=() UPD_SEEN=() PITEMS=() PKROWS=" " UPD_BAR=""
upd_add() { # upd_add KIND NAME ARG [TEXT]
	UPD_KIND[UPD_N]=$1 UPD_NAME[UPD_N]=$2 UPD_ARG[UPD_N]=$3 UPD_TEXT[UPD_N]=${4:-} UPD_SEEN[UPD_N]=""
	UPD_N=$((UPD_N + 1))
}
upd_job() { # upd_job N COMMAND...: in the background, its output to UPD_DIR/N.out, how it ended to N.st
	local n=$1 f="$UPD_DIR/$1"
	shift
	# HUP ignored: a popup panel closed mid-install mustn't cut the installer short.
	(
		trap '' HUP
		"$@" </dev/null >"$f.out" 2>&1
		echo $? >"$f.tmp" && mv -f "$f.tmp" "$f.st"
	) &
	UPD_PID[n]=$!
}
upd_running() {
	local p
	for p in "${UPD_PID[@]}"; do kill -0 "$p" 2>/dev/null && return 0; done
	return 1
}
# upd_last FILE -> LAST: its last line, as text: the installer's colour codes (and any other
# escape sequence) go whole, not just their ESC, and so does its "xx" or "!!" in front.
upd_last() {
	LAST=$(tail -c 4096 "$1" 2>/dev/null | LC_ALL=C sed -E $'s#\e\\[[0-9:;<=>?]*[ -/]*[@-~]##g; s#\e\\][^\a\e]*(\a|\e\\\\)?##g; s#\e.##g' |
		grep -v '^[[:space:]]*$' | tail -n 1)
	clean LAST
	[[ $LAST =~ ^[[:space:]]*(xx|!!|==\>)[[:space:]]+(.*)$ ]] && LAST=${BASH_REMATCH[2]}
}
# upd_users HOST (this computer: ""): an [I] line for each other user there whose tmux-revive
# isn't current (none, or older than the owner's). A computer whose rows don't say whose its
# tmux is (from before users) has none.
upd_users() {
	local i u v own=$ME ref=$VERSION
	[[ -n $1 ]] && own=${ROWNER[$1]:-} ref=${RVER[$1]:-}
	[[ -n $own ]] || return
	for i in "${!P_ID[@]}"; do
		[[ ${P_HOST[i]} == "$1" ]] || continue
		u=${P_USER[i]:-} v=${P_INST[i]:-}
		[[ $u =~ $USER_RE && $u != "$own" && $v != owner && $seen != *" $u@$1 "* ]] || continue
		seen+="$u@$1 "
		if [[ -z $v ]]; then upd_add note "$u${1:+@$1}" "install $u $1" "not installed"
		elif [[ $v =~ $VER_RE && $ref =~ $VER_RE ]] && ver_lt "$v" "$ref"; then upd_add note "$u${1:+@$1}" "update $u $1" "has $v"; fi
	done
}
upd_start() {
	local h d seen=" "
	cache_dir
	rm -rf "$UPD_DIR"; mkdir -p "$UPD_DIR"
	UPD_N=0 UPD_NAME=() UPD_KIND=() UPD_ARG=() UPD_TEXT=() UPD_PID=() UPD_SEEN=()
	upd_add job "this computer" ""
	upd_job 0 timeout 600 "$REVIVE_ROOT/bin/tmux-revive" update
	upd_users ""
	# Each linked computer, once; one waiting for a login or stopped on a failure isn't tried
	# (remote_run wouldn't either): B is where you try it again.
	for d in "$ASTATE"/links/*/; do
		h=$(basename "$d")
		[[ -f $d/on && $h =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
		if [[ -f $d/login ]]; then upd_add skip "$h" "" "skipped: needs login · B"
		elif [[ -f $d/paused ]]; then upd_add skip "$h" "" "skipped: link stopped · B"
		else
			upd_add job "$h" "$h"
			RTIMEOUT=300 upd_job $((UPD_N - 1)) remote_run "$h" "$REMOTE_UPDATE_CMD"
		fi
		upd_users "$h"
	done
}
# upd_poll: what finished since last looked at: this computer's tmux-revive read again, a
# linked computer asked for its rows (and so its version) again.
upd_poll() {
	local i st
	for ((i = 0; i < UPD_N; i++)); do
		[[ ${UPD_KIND[i]} == job && -z ${UPD_SEEN[i]} && -s $UPD_DIR/$i.st ]] || continue
		UPD_SEEN[i]=1
		read -r st <"$UPD_DIR/$i.st"
		[[ $st == 0 ]] || continue
		if [[ -z ${UPD_ARG[i]} ]]; then
			VERSION=$(head -n 1 "${REVIVE_VERSION_FILE:-$REVIVE_ROOT/VERSION}" 2>/dev/null | head -c 32)
			[[ $VERSION =~ $VER_RE ]] || VERSION=""
		else
			RFETCH_T[${UPD_ARG[i]}]=0
		fi
	done
}
# upd_lines -> PITEMS: the popup's lines, each as wide as the others; PKROWS: those with [I];
# UPD_BAR: "FINISHED TOTAL" of the updates run, for the progress bar. Returns 1 when none changed.
upd_lines() {
	local i s st h mark l v was="${PITEMS[*]-}" fin=0 tot=0
	PITEMS=() PKROWS=" "
	for ((i = 0; i < UPD_N; i++)); do
		s=${UPD_TEXT[i]} mark="" h=${UPD_ARG[i]}
		case ${UPD_KIND[i]} in
		note) mark=1 ;;
		job)
			tot=$((tot + 1))
			[[ -s $UPD_DIR/$i.st ]] && fin=$((fin + 1))
			if [[ ! -s $UPD_DIR/$i.st ]]; then s="updating…"
			else
				read -r st <"$UPD_DIR/$i.st"
				upd_last "$UPD_DIR/$i.out"
				# Its result, from the installer's "tmux-revive 1.2.19 -> 1.2.20" line (its last line is
				# only the end of its help, cut to a stray letter here).
				if ((st == 0)); then
					s=updated
					v=$(grep -oE 'tmux-revive [0-9]+\.[0-9]+\.[0-9]+ -> [0-9]+\.[0-9]+\.[0-9]+' "$UPD_DIR/$i.out" | tail -n 1)
					[[ $v =~ ([0-9.]+)\ -\>\ ([0-9.]+)$ ]] &&
						if [[ ${BASH_REMATCH[1]} == "${BASH_REMATCH[2]}" ]]; then s="already ${BASH_REMATCH[2]}"; else s="${BASH_REMATCH[1]} → ${BASH_REMATCH[2]}"; fi
				elif [[ -n $h ]] && ((st == 124 || st == 255)); then s="unreachable"
				elif grep -qiE 'permission denied|operation not permitted' "$UPD_DIR/$i.out"; then
					# Not the link's user's to update: [I], with tmux-revive update for its owner's pane
					# (UPD_TEXT holds what user_note is given, as UPD_ARG does for a note).
					s="no permission"
					if [[ -z $h ]]; then UPD_TEXT[i]="update $ME" mark=1
					elif [[ -n ${ROWNER[$h]:-} ]]; then UPD_TEXT[i]="update ${ROWNER[$h]} $h" mark=1; fi
				else s="failed${LAST:+: $LAST}"; fi
			fi ;;
		esac
		fld "${UPD_NAME[i]}" 22
		l="$FLD  "
		fld "$s" 36
		l+=$FLD
		if [[ -n $mark ]]; then l+="  [I]" PKROWS+="$i "; else l+="     "; fi
		PITEMS+=("$l")
	done
	UPD_BAR="$fin $tot"
	[[ ${PITEMS[*]} != "$was" ]]
}
upd_tick() { upd_poll; upd_lines; }
# U: a new round, or, while the last one still runs, that one shown again (never a second try
# at any of it). Enter or I on an [I] line: its command, copied; Enter elsewhere, or Esc, closes.
upd_show() {
	local sel=0 a
	((UPD_N)) && upd_running || upd_start
	while :; do
		upd_poll; upd_lines
		PTICK=upd_tick PBAR=UPD_BAR PKEYS=i PSEL=$sel PHINT="↑↓ choose · I: command · Esc closes" pick "UPDATE" "${PITEMS[@]}" || break
		sel=$PICKED
		[[ $PKROWS == *" $sel "* ]] || break
		[[ ${UPD_KIND[sel]} == note ]] && a=${UPD_ARG[sel]} || a=${UPD_TEXT[sel]}
		PREV=(); draw # the list away first, so the two boxes never overlap
		# shellcheck disable=SC2086 # mode, user and host: checked words
		user_note $a
		PREV=(); draw
	done
	upd_running && flash "still updating · U shows it"
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
	case $1 in up | down | pgup | pgdn | home | end | J | K | [0-9]) ;; *) PREV=() ;; esac
	local id=${P_ID[SEL]:-} name=${P_NAME[SEL]:-${P_LOC[SEL]:-}} out
	# A heading selected: the keys for a pane wait for one.
	if [[ -n $HSEL ]]; then
		case $1 in o | O | m | M | n | N) flash "select one of ${HSEL}'s panes for that"; return ;; esac
	fi
	case $1 in
	o | O)
		# Panes on this computer only. On a linked computer's row O does nothing but say so:
		# focus moves only where you press O, never in tmux over there.
		[[ -n ${P_HOST[SEL]:-} ]] && { flash "O opens panes on this computer only"; return; }
		[[ -n $id ]] || return
		if [[ -n ${TMUX:-} ]]; then
			tm switch-client -t "$id" 2>/dev/null
			tm select-window -t "$id" 2>/dev/null
			tm select-pane -t "$id" 2>/dev/null
			[[ -n ${REVIVE_PANEL_POPUP:-} ]] && exit 0
			flash "opened $name"
		else
			tm select-window -t "$id" 2>/dev/null
			tm select-pane -t "$id" 2>/dev/null
			restore_term
			exec tmux attach -t "${P_LOC[SEL]%%:*}" 2>&1 # its messages on the screen again
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
	b | B)
		# Every step of this B (its key shown, the link, a login) shares one ssh-keyscan of the
		# host: each scan is a connection that never logs in, which servers count against you.
		export AGENT_SAY_SCAN_ID="b$$$RANDOM$SECONDS"
		# Links waiting for their login first, then every ssh host not linked yet (the selected
		# pane's first), then the links there are to link again (one that fails first), then
		# "other host...". U on a link's line unlinks it (kr: those lines).
		local hosts=() labels=() seen=" " h i j d why pass l kr=" " hint=""
		for d in "$ASTATE"/links/*/; do
			[[ -f $d/on && -f $d/login ]] || continue
			h=$(basename "$d")
			[[ $h =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
			kr+="${#hosts[@]} "
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
		for pass in error ok; do
			for d in "$ASTATE"/links/*/; do
				h=$(basename "$d")
				[[ -f $d/on && $seen != *" $h "* && $h =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
				why=$(head -n 1 "$d/error" 2>/dev/null)
				why=${why% · [LB] to try again} # L: what agent-say wrote before B
				clean why
				l=""
				if [[ $pass == error && -f $d/paused ]]; then l="$h  · ${why:0:40} · try again"
				elif [[ $pass == error && -n $why ]]; then l="$h  · ${why:0:40} · link again"
				elif [[ $pass == ok && -z $why ]]; then l="$h  · linked · link again"; fi
				[[ -n $l ]] && kr+="${#hosts[@]} " seen+="$h " hosts+=("$h") labels+=("$l")
			done
		done
		hosts+=("") labels+=("other host… (type its name)")
		[[ $kr != " " ]] && hint="↑↓ choose · Enter picks · U unlinks · Esc closes"
		PKEYS=u PKROWS=$kr PHINT=$hint pick "ATTACH SERVERS" "${labels[@]}" || { flash "link cancelled"; return; }
		h=${hosts[PICKED]}
		[[ $PKEY == u ]] && { unlink_host "$h"; return; }
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
		# A link there already (working or not): link it again, fresh, with the key ssh uses for it
		# now, or unlink it. Nothing changes until you say which.
		# A link stopped on a failure is tried again, once, with the key it has (should another key
		# answer, you are shown that one, as below).
		local again="" was=""
		if linked "$h" && [[ -f $ASTATE/links/$h/paused ]]; then
			flash "trying $h again…"; draw
		elif linked "$h"; then
			pick "LINK $h AGAIN?" "${NOTE}It unlinks, then links again with the key ssh uses now." \
				"No, leave it as it is" "Yes, link $h again" "Unlink $h" && ((PICKED > 1)) || { flash "link cancelled"; return; }
			((PICKED == 3)) && { unlink_host "$h"; return; }
			again=1 was=$(cat "$ASTATE/links/$h/fingerprint" 2>/dev/null)
		fi
		# Its host key, found the way ssh itself has it: the one in your known_hosts, else the one
		# your open ssh connection to it uses, else (a host never connected to) the one ssh-keyscan
		# shows first, of the type ssh would pick. You only say yes or no to linking; a key ssh
		# hasn't seen before, or one that changed, has No first, so Enter alone doesn't take it.
		flash "reading $h's host key…"; draw
		# What link is told: the keys shown here (--fingerprint), so it is bound to exactly those,
		# never to what it might scan a moment later; or, linking with no key found, that none is
		# to be taken (--no-key). A relink gives none: it keeps the one recorded, and refuses another.
		local -a keys largs=() yn notes
		local k linked_msg="" note title first
		read_host_keys "$h" ${again:+--fresh}
		keys=("${KEYS[@]}")
		PREV=()
		if [[ $KEY_STATE == recorded ]]; then
			linked_msg="relinked $h with the key you confirmed"
		else
			# Only a key from your known_hosts (ssh itself trusts it) has Yes first. One read through
			# your open connection, or shown by ssh-keyscan, is whatever answers there says: seen for
			# the first time, to check.
			title="LINK $h?" yn=("No, don't link $h" "Yes, link $h") first=""
			case $KEY_STATE in
				trusted) note="key from your known_hosts" yn=("${yn[1]}" "${yn[0]}") ;;
				live) note="key read through your open ssh connection" first=1 ;;
				changed) note="its key now"; title="WARNING: $h's HOST KEY CHANGED since you linked it" ;;
				*) note="new host: first key seen" first=1 ;;
			esac
			# Linked before, and none of the keys you confirmed then is among these: say so, whatever
			# vouches for them now (your known_hosts too may have changed).
			if [[ -n $was ]] && ((${#keys[@]})) && ! grep -qxF -f <(printf '%s\n' "${keys[@]}") <<<"$was"; then
				title="WARNING: $h's HOST KEY CHANGED since you linked it" yn=("No, don't link $h" "Yes, link $h")
			fi
			if ((${#keys[@]})); then note+=": ${keys[0]}"; else note="no key found (not in known_hosts, no answer to ssh-keyscan)" first=""; fi
			notes=("$NOTE$note")
			[[ -n $first ]] && notes+=("${NOTE}First time we see this key, so check it matches your server.")
			pick "$title" "${notes[@]}" "${yn[@]}" || { flash "link cancelled"; return; }
			PICKED=$((PICKED - ${#notes[@]} + 1))
			[[ ${yn[PICKED - 1]} == Yes* ]] || { flash "link cancelled"; return; }
			if [[ $KEY_STATE == trusted ]]; then
				for k in "${keys[@]}"; do largs+=(--fingerprint "$k"); done
				linked_msg="linked to $h with the key from your known_hosts: ${keys[0]}"
			elif ((${#keys[@]})); then
				keys=("${keys[0]}")
				largs=(--yes --fingerprint "${keys[0]}")
				[[ $KEY_STATE == live ]] && linked_msg="linked to $h with the key its open ssh connection uses: ${keys[0]}"
			else
				largs=(--yes --no-key)
			fi
			KEY_STATE=given
		fi
		if [[ -n $again ]]; then
			flash "unlinking $h…"; draw
			timeout 30 "$ASAY" unlink "$h" >/dev/null 2>&1
			rm -f "$RDIR/$h.rows"
		fi
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
			pick "WARNING: $h's HOST KEY CHANGED since you linked it" "${NOTE}its key now: ${keys[0]}" "No, don't link $h" "Yes, link $h" &&
				((PICKED == 2)) || { flash "link cancelled"; return; }
			keys=("${keys[0]}") KEY_STATE=changed linked_msg=""
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
		# Tried once and failed: why, in a few words, as LINKS shows it.
		if [[ $out != "linked to "* && -f $ASTATE/links/$h/paused ]]; then
			out=$(head -n 1 "$ASTATE/links/$h/error" 2>/dev/null)
			clean out
			out="$h: $out"
		fi
		flash "${out#agent-say: }" ;;
	u | U) upd_show ;;
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
		pick "LINK AGENTS TOGETHER" "${labels[@]}" || return
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
			# First, why it asks: one short line agent-say kept (its --why, or how its message
			# opens). When both wrote first, the other way's too (by its names, as agent-say's
			# intros_between finds it), the earlier one first.
			local wd wy wf wt wc wl=()
			for wd in "$d" "$ASTATE"/intros/*/; do
				((${#wl[@]} < 2)) || break
				wy="" wf="" wt="" wc=0
				{ read -r wf <"$wd/from"; read -r wt <"$wd/to"; read -r wc <"$wd/created"; } 2>/dev/null || true
				clean wf wt
				[[ $wd == "$d" ]] || [[ $wf == "$t" && $wt == "$f" ]] || continue
				{ read -r wy <"$wd/why"; } 2>/dev/null || wy=$(head -c 60 "$wd/intro" 2>/dev/null)
				clean wy
				((${#wy} > 80)) && wy="${wy:0:79}…"
				[[ $wc =~ ^[0-9]+$ ]] || wc=0
				wl+=("$wc${NOTE}${wf%@*}${NOTE}$wy")
			done
			if ((${#wl[@]} == 1)); then labels+=("${NOTE}why: ${wl[0]##*"$NOTE"}")
			elif ((${#wl[@]} == 2)); then
				((${wl[1]%%"$NOTE"*} < ${wl[0]%%"$NOTE"*})) && wl=("${wl[1]}" "${wl[0]}")
				for wd in "${wl[@]}"; do wd=${wd#*"$NOTE"}; labels+=("${NOTE}why (${wd%%"$NOTE"*}): ${wd#*"$NOTE"}"); done
			fi
			wc=${#labels[@]}
			while [[ -n $txt ]] && ((${#labels[@]} < wc + 3)); do labels+=("$NOTE${txt:0:60}"); txt=${txt:60}; done
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
			pick "$lt" "Refresh" "Remove" || { PREV=(); return; }
			if ((PICKED == 0)); then
				# The same code popup as Approve: no agent can refresh its own access.
				out=$(code_popup "Refresh $l for another day?" refresh grant_refresh "$a" "$b")
				PREV=()
				if [[ $out == refreshed:* ]]; then out="refreshed: $l · $((ttl / 3600))h left"
				elif [[ -z $out ]]; then out="not refreshed: the code didn't match"; fi
			else
				out=$("$ASAY" revoke "$a" "$b" 2>&1) && out="removed: $l"
			fi
			out=${out##*$'\n'}
		fi
		PREV=() # the boxes drawn over, all of it again
		clean out
		flash "${out#agent-say: }" ;;
	p | P) PEEK=$((!PEEK)) ;;
	# Enter: on a linked computer's heading, fold it to that line (or open it again); on a pane
	# asking a question, answer it.
	enter)
		if [[ -n $HSEL ]]; then fold_toggle "$HSEL"; [[ -n ${FOLD[$HSEL]:-} ]] || PO=$((1 << 30)) # opened: its panes into view, under its heading
		elif [[ ${P_STATE[SEL]:-} == asking ]]; then answer; fi ;;
	# f: fold the selected pane's linked computer to its heading, which the selection moves to
	# (on a folded heading, open it again, as Enter does).
	f)
		if [[ -n $HSEL ]]; then act enter; return
		elif [[ -z ${P_HOST[SEL]:-} ]]; then flash "this computer can't be folded"; return; fi
		fold_toggle "${P_HOST[SEL]}" && HSEL=${P_HOST[SEL]} ;;
	# F, a shortcut the help page tells of, not the bar: fold every linked computer (never
	# this one), or, with all of them folded already, open them all. A selection inside one folded moves to its heading.
	F)
		local -A seen=()
		local h all=1
		for h in "${P_HOST[@]}"; do [[ -n $h ]] && seen[$h]=1; done
		((${#seen[@]})) || { flash "nothing is bridged"; return; }
		for h in "${!seen[@]}"; do [[ -n ${FOLD[$h]:-} ]] || all=0; done
		for h in "${!seen[@]}"; do ((all)) || [[ -z ${FOLD[$h]:-} ]] && fold_toggle "$h"; done
		if ((all)); then HSEL=""
		elif [[ -n ${P_HOST[SEL]:-} ]]; then HSEL=${P_HOST[SEL]}; fi ;;
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
	# and linked computers' panes, are reached with the arrows (or j and k).
	[0-9])
		local w
		for w in "${!P_ID[@]}"; do
			[[ -z ${P_HOST[w]} && ${P_WP[w]%%.*} == "$1" ]] && { SEL=$w HSEL=""; break; }
		done ;;
	up | down | pgup | pgdn | home | end) scroll "$1" ;;
	# J: the focus to the next window drawn, round to the first (K: the one before).
	J) tab_next; FOCUS=$NEXTW ;;
	K) tab_next 3; FOCUS=$NEXTW ;;
	esac
	SEL_ID=${P_ID[SEL]:-}
}
# scroll KEY: up, down, pgup, pgdn, home or end in the focused window. In PANES they move the
# selection, a folded computer's heading included, and the view follows it; the arrows go
# round (up from the first row is the last). Elsewhere they scroll; draw keeps each view in
# range.
scroll() {
	local pg=$((WH[FOCUS] > 1 ? WH[FOCUS] - 1 : 1)) d k i j
	case $1 in up) d=-1 ;; down) d=1 ;; pgup) d=-pg ;; pgdn) d=pg ;; home) d=-100000 ;; end) d=100000 ;; esac
	case $FOCUS in
	0)
		panes_rows
		nav_at
		k=${#NAV[@]}
		((k)) || return
		if [[ $1 == up || $1 == down ]]; then
			i=$NAT
			for ((j = 0; j < k; j++)); do i=$(((i + d + k) % k)); nav_stop "$i" && break; done # an open heading isn't a stop
			nav_go "$i" "$d"
		else
			nav_go $((NAT + d)) $((d > 0 ? 1 : -1))
		fi ;;
	1) PB=$((PB - d)) ;; # up is further back
	2) MO=$((MO + d)) MMAN=1; [[ $1 == end ]] && MMAN=0 ;; # End: the newest again, and kept there
	3) SO=$((SO + d)) ;;
	esac
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
			agent_kind "${PARGS[$p]:-}"
			kind=$AKIND
			# shellcheck disable=SC2206
			[[ -n ${PCHILD[$p]:-} ]] && q+=(${PCHILD[$p]})
		done
		[[ -n $kind ]] || continue
		screen_state "$id"
		[[ $LSTATE == asking ]] || continue
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
	fold_load
	sel_fix
	draw
	exit 0
fi
[[ -t 0 && -t 1 ]] || { echo "tmux-revive panel needs a terminal" >&2; exit 1; }
# Only the frames may reach the screen. A stray message from bash or a command lands where the
# last frame left the cursor, often the bottom row, and scrolls the whole panel up; only the
# rows that change are drawn again, so the rest stayed out of place until it was restarted.
# Messages go to a file of yours alone instead, emptied once it passes 64 KB.
cache_dir
PANEL_ERR=$RDIR/panel.err
[[ -n $(find "$PANEL_ERR" -size +64k 2>/dev/null) ]] && rm -f "$PANEL_ERR"
(umask 077; : >>"$PANEL_ERR") 2>/dev/null
exec 2>>"$PANEL_ERR" || exec 2>/dev/null
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
fold_load
# keys KEY: act on KEY and on any keys already waiting behind it (a held arrow), so that they
# are drawn once. Keys that only move the selection set nav.
keys() {
	key=$1
	while :; do
		[[ -z $key || $key == $'\r' ]] && key=enter # read stops at the newline Enter sends
		if [[ $key == "$e" ]]; then
			# A sequence: ESC [ or ESC O, then up to its final character (PgUp is ESC [ 5 ~).
			rest="" seq=""
			IFS= read -rsn1 -t 0.05 rest || true
			if [[ $rest == '[' || $rest == O ]]; then
				while IFS= read -rsn1 -t 0.05 rest; do seq+=$rest; [[ $rest == [@-~] || ${#seq} -gt 8 ]] && break; done
			fi
			case $seq in
			A) key=up ;; B) key=down ;; 5~) key=pgup ;; 6~) key=pgdn ;;
			H | 1~ | 7~) key=home ;; F | 4~ | 8~) key=end ;; *) key="" ;; # Left, Right, Shift-Tab: nothing
			esac
		fi
		[[ $key == $'\t' ]] && key="" # Tab does nothing: J and K move between windows
		# j and k move in the focused window, as Down and Up do; J and K (in act) between windows.
		case $key in j) key=down ;; k) key=up ;; esac
		case $key in
		# Moving the selection, scrolling and moving the focus only redraw.
		up | down | pgup | pgdn | home | end | J | K | [0-9]) act "$key"; nav=1 ;;
		# Keys that only change the view (peek, art) are drawn at once from
		# what was gathered last, then looked at again like any other key: on a busy machine
		# the look at every pane is what takes the time.
		p | P | a | A) act "$key"; nav=1; draw; nav=0; break ;;
		"") ;;
		*) act "$key"; nav=0; break ;;
		esac
		key=""
		read -t 0 && IFS= read -rsn1 key || break
	done
}
held=0 SSH_FIRST=1 FULL_T=$SECONDS
while :; do
	# Moving the selection only redraws from what was gathered last; everything is looked at
	# again on the next refresh or any other key, so the arrows stay quick.
	if ((!nav)); then
		gather
		for h in "${P_SSH[@]}" "${X_SSH[@]}"; do
			[[ -n $h && -z ${SSH_SEEN[$h]:-} ]] || continue
			SSH_SEEN[$h]=1
			# Only one opened since the panel started: those open before are in LINKS already
			# ([B]ridge?), and a flash for each would cover the key bar as it opens.
			((SSH_FIRST)) || linked "$h" || flash "new ssh: $h · B bridges it"
		done
		SSH_FIRST=0
		# A link whose login dropped (a reboot over there, the network gone): said once.
		for d in "$ASTATE"/links/*/; do
			h=$(basename "$d")
			[[ $h =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
			if [[ -f $d/on && -f $d/login ]]; then
				[[ -n ${LOGIN_SEEN[$h]:-} ]] || flash "$h needs login · B to type its password"
				LOGIN_SEEN[$h]=1
			else
				LOGIN_SEEN[$h]=""
			fi
		done
		TCOLS="" MSG_OLD=1 # looked at again along with the panes
		((UPD_N)) && upd_poll # what U started, finished since
	fi
	# Keep the same pane selected when panes come and go.
	if [[ -n $SEL_ID ]]; then
		for i in "${!P_ID[@]}"; do [[ ${P_ID[i]} == "$SEL_ID" ]] && SEL=$i; done
	fi
	((SEL >= ${#P_ID[@]})) && SEL=$((${#P_ID[@]} ? ${#P_ID[@]} - 1 : 0))
	sel_fix
	# A key pressed while it gathered is taken first, so one draw shows both. Not twice running,
	# so keys arriving all the time can't keep the panel from drawing.
	if ((!nav && !held && ${#PREV[@]})) && read -t 0; then
		held=1 key=""
		IFS= read -rsn1 key
		keys "$key"
		continue
	fi
	held=0
	# All of it drawn again every 15 s, not only what changed: anything else that reached the
	# screen (a program writing to the terminal itself) is gone within that.
	((SECONDS - FULL_T >= 15)) && PREV=() FULL_T=$SECONDS
	draw
	nav=0
	key=""
	if ! IFS= read -rsn1 -t "$REFRESH" key; then
		((TICK++)) # the animation moves on with the clock, not with keys
		continue
	fi
	keys "$key"
done
