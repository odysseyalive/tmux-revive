# shellcheck shell=bash
# The control panel's help page: ? opens it in place of everything from the PANES band down,
# with the banner left above it. The words live in help.txt (its top says how to mark them
# up); this draws them BBS style, scrolls them, and runs the two buttons in the ads.
#
# Sourced by panel.sh, which gives it the colours, row/sect/tab, draw and flash. Run on its
# own, `help.sh --install workforce|playwright` is what an install button starts in a new tmux window.

HELP_FILE="$(dirname "${BASH_SOURCE[0]}")/help.txt"
HELP=0 HELP_TOP=0 HELP_VIEW=1 HELP_W=-1 HROWS=()
# Tests draw the help page with --once: REVIVE_PANEL_HELP=1 panel.sh --once. (Sourced with no
# arguments of its own, $1 here is panel.sh's.)
[[ ${REVIVE_PANEL_HELP:-} == 1 && ${1:-} == --once ]] && HELP=1

WF_URL=https://raw.githubusercontent.com/odysseyalive/claude-workforce/main/install
PW_URL=https://github.com/odysseyalive/playwright-mcp
PWI_URL=https://raw.githubusercontent.com/odysseyalive/playwright-mcp/main/install

# Claude Workforce's own one-line installer for this system, from its README: the bash one
# for Linux and macOS (WSL is Linux), the PowerShell one on Windows. What the confirmation
# shows is exactly what runs. REVIVE_WORKFORCE_INSTALL_CMD stands in for it in tests.
workforce_cmd() {
	if [[ -n ${REVIVE_WORKFORCE_INSTALL_CMD:-} ]]; then printf '%s' "$REVIVE_WORKFORCE_INSTALL_CMD"; return; fi
	case $(uname -s) in
	Linux | Darwin | *BSD) printf 'bash -c "$(curl -fsSL %s)"' "$WF_URL" ;;
	MINGW* | MSYS* | CYGWIN*) printf 'powershell.exe -NoProfile -Command "irm %s.ps1 | iex"' "$WF_URL" ;;
	*) return 1 ;;
	esac
}

# playwright-mcp's one-line installer, the same way (it also updates an install that's there).
# REVIVE_PLAYWRIGHT_INSTALL_CMD stands in for it in tests.
playwright_cmd() {
	if [[ -n ${REVIVE_PLAYWRIGHT_INSTALL_CMD:-} ]]; then printf '%s' "$REVIVE_PLAYWRIGHT_INSTALL_CMD"; return; fi
	case $(uname -s) in
	Linux | Darwin | *BSD) printf 'bash -c "$(curl -fsSL %s.sh)"' "$PWI_URL" ;;
	MINGW* | MSYS* | CYGWIN*) printf 'powershell.exe -NoProfile -Command "irm %s.ps1 | iex"' "$PWI_URL" ;;
	*) return 1 ;;
	esac
}
# what WHAT -> WNAME, WCMD, WWIN, WENV: the name shown, the installer's command, the window it
# runs in, and the stand-in tests set.
what() {
	case $1 in
	workforce) WNAME="Claude Workforce" WCMD=workforce_cmd WWIN=workforce WENV=REVIVE_WORKFORCE_INSTALL_CMD ;;
	playwright) WNAME="playwright-mcp" WCMD=playwright_cmd WWIN=playwright-mcp WENV=REVIVE_PLAYWRIGHT_INSTALL_CMD ;;
	*) return 1 ;;
	esac
}

# ------------------------------------------------------------------ the page
# help_wrap TEXT WIDTH -> WRAP: TEXT in lines of at most WIDTH, broken at spaces. Backticks
# mark commands and take no room; a word longer than a line is cut across lines.
help_wrap() {
	local w=$2 cur="" cl=0 word t wl
	local -a words
	WRAP=()
	read -ra words <<<"$1"
	for word in "${words[@]}"; do
		t=${word//\`/} wl=${#t}
		while ((wl > w)); do
			((cl)) && WRAP+=("$cur")
			WRAP+=("${word:0:w}")
			word=${word:w} t=${word//\`/} wl=${#t} cur="" cl=0
		done
		((wl)) || continue
		if ((cl == 0)); then cur=$word cl=$wl
		elif ((cl + 1 + wl <= w)); then cur+=" $word" cl=$((cl + 1 + wl))
		else WRAP+=("$cur") cur=$word cl=$wl; fi
	done
	((cl)) && WRAP+=("$cur")
	return 0
}
# help_ink LINE -> INK: the line in colour, `commands` in cyan. A command may run on into the
# next line of its paragraph, so whether one is open carries over in HCODE.
help_ink() {
	local s=$1
	INK=""
	((HCODE)) && INK=$BCYN
	while [[ $s == *'`'* ]]; do
		INK+=${s%%\`*} s=${s#*\`}
		if ((HCODE)); then HCODE=0 INK+=$R; else HCODE=1 INK+=$BCYN; fi
	done
	INK+=$s$R
}

# hpush CONTENT: one row of the page, inside the open box if there is one.
hpush() {
	[[ -z $1 ]] && HBLANK=1 || HBLANK=0
	if ((HBOX)); then padv "$1" $((HBW - 5)); HB+=("$HBC║$R $PADV $HBC║$R$GRY░$R"); return; fi
	if ((${#HPEND[@]})); then [[ -z $1 ]] && return; hflush; fi
	HROWS+=("$1")
}
# hhang PREFIX PREFIX-WIDTH TEXT: TEXT wrapped beside PREFIX, its later lines indented under it
hhang() {
	local i pad
	printf -v pad '%*s' "$2" ''
	help_wrap "$3" $((HCW - $2))
	HCODE=0
	for i in "${!WRAP[@]}"; do
		help_ink "${WRAP[i]}"
		if ((i == 0)); then hpush "$1$INK"; else hpush "$pad$INK"; fi
	done
	((${#WRAP[@]})) || hpush "$1"
}
hpara() { # the paragraph gathered so far, wrapped
	[[ -n $HPARA ]] || return 0
	hhang " " 1 "$HPARA"
	HPARA=""
}
# hrule WIDTH -> RULE: a line that fades out to the right, bright and heavy to faint and thin
hrule() {
	local q=$(($1 / 4)) r=""
	rep ━ "$q"; r+="$BCYN$REP"
	rep ━ "$q"; r+="$BBLU$REP"
	rep ─ "$q"; r+="$BLU$REP"
	rep ┄ $(($1 - 3 * q)); r+="$GRY$REP$R"
	RULE=$r
}
# hbutton KEY LABEL: a solid button, the key on a black cap at its left. Half blocks above and
# below pad it, and a fade frames it from outside: nothing shaded touches the words.
hbutton() {
	local fg bg cap blk n
	if ((HBN % 2)); then fg=$BLU bg="$e[44m$B$BWHT" cap="$e[40m$B$BWHT"
	else fg=$BYEL bg="$e[103m$B$e[30m" cap="$e[40m$B$BYEL"; fi
	HBN=$((HBN + 1))
	blk="$bg $cap $1 $R$bg  $2  $R"
	n=$((${#2} + 8))
	rep ▄ "$n"; hpush "     $fg$REP$R"
	hpush "  $fg░▒▓$R$blk$fg▓▒░$R"
	rep ▀ "$n"; hpush "     $fg$REP$R"
}
# The boxes. hbox_close lays the open one out: under the page, or, on a wide panel, beside the
# box before it (HPEND holds that one until its partner comes). hflush puts a lone one down.
hbox_close() {
	local bot sh blank i
	rep ═ $((HBW - 3)); bot="$HBC╚$REP╝$R$GRY░$R"
	rep ░ $((HBW - 1)); sh=" $GRY$REP$R"
	printf -v blank '%*s' $((HBW - 3)) ''
	blank="$HBC║$R$blank$HBC║$R$GRY░$R"
	HBOX=0 HBLANK=0
	if ((!HSIDE)); then HROWS+=("${HB[@]}" "$bot" "$sh"); return; fi
	if ((!${#HPEND[@]})); then HPEND=("${HB[@]}") HPEND_END=("$blank" "$bot" "$sh"); return; fi
	# Two boxes side by side end on the same row.
	while ((${#HPEND[@]} < ${#HB[@]})); do HPEND+=("${HPEND_END[0]}"); done
	while ((${#HB[@]} < ${#HPEND[@]})); do HB+=("$blank"); done
	HPEND+=("${HPEND_END[@]:1}") HB+=("$bot" "$sh")
	for i in "${!HB[@]}"; do HROWS+=("${HPEND[i]}  ${HB[i]}"); done
	HPEND=()
}
hflush() {
	((${#HPEND[@]})) || return 0
	HROWS+=("${HPEND[@]}" "${HPEND_END[@]:1}")
	HPEND=()
}

# The pictures .art puts by a section. HART_NAME is the picture's rows, every row the same
# width, and HART_NAME_ink paints them: a letter under each cell for its colour (see hart).
# Drawn the artpack way: solid blocks first, half blocks for the curves and the small parts,
# shades only as a short step from one colour to the next. Foreground colours only, and no
# black or white, so the page's own background shows through the gaps on a dark terminal
# or a light one, and the eyes and mouths are holes, not paint.
HART_talk=( # two agents talking: a message each way, trailing off where it came from
	"   ▄                         ▄   "
	" ▄▄█▄▄                     ▄▄█▄▄ "
	"██▄█▄██       ░░▒▒▓▓██►   ██▄█▄██"
	"██▀▀▀██   ◄██▓▓▒▒░░       ██▀▀▀██"
	" ▀▀▀▀▀                     ▀▀▀▀▀ "
)
HART_talk_ink=( # 1 and 2: the two beacons, taking turns (see HB1)
	"   1                         2   "
	" CCkCC                     MMkMM "
	"CCCCCCC       CCCCCCCCC   MMMMMMM"
	"CCCCCCC   MMMMMMMMM       MMMMMMM"
	" ccccc                     mmmmm "
)
HART_satellite=( # a satellite, its light blinking on top (L: see HLIT)
	"               ▪               "
	" ▄▄▄▄▄▄▄▄▄  ▄▄▄▄▄▄▄  ▄▄▄▄▄▄▄▄▄ "
	" █▒█▒█▒█▒█══███████══█▒█▒█▒█▒█ "
	" ▀▀▀▀▀▀▀▀▀  ▀▀▀█▀▀▀  ▀▀▀▀▀▀▀▀▀ "
)
HART_satellite_ink=(
	"               L               "
	" BBBBBBBBB  YYYrYyy  BBBBBBBBB "
	" BbBbBbBbBkkYYYYYyykkBbBbBbBbB "
	" bbbbbbbbb  yyykyyy  bbbbbbbbb "
)
# The beacons: colours no other ink uses, so help_frame can find them and let them go dark
# between blinks. The two agents' beacons take turns, one panel tick (about 2 s) each. The
# satellite's light comes on now and then: two ticks in seven, unevenly spaced.
HB1=$'\e[38;5;226m' HB2=$'\e[38;5;227m' HLIT=$'\e[38;5;196m'
# hart NAME: the picture HART_NAME, painted, for the section it follows the title of. Beside
# the section's text when the page is wide enough for both (hart_close puts it there), above
# the text when it's only wide enough for the picture, and left out when it isn't, or in a box.
hart() {
	[[ $1 =~ ^[a-z]+$ ]] && declare -p "HART_$1" "HART_$1_ink" >/dev/null 2>&1 || return 0
	((HBOX)) && return 0
	local -n g=HART_$1 p=HART_$1_ink
	local -A pal=([b]=$BLU [B]=$BBLU [c]=$CYN [C]=$BCYN [m]=$MAG [M]=$BMAG [y]=$YEL [Y]=$BYEL
		[g]=$GRN [G]=$BGRN [r]=$BRED [k]=$GRY [L]=$HLIT [1]=$HB1 [2]=$HB2)
	local i j c last s w=${#g[0]}
	local -a rows=()
	for i in "${!g[@]}"; do
		s="" last=" "
		for ((j = 0; j < w; j++)); do
			c=${p[i]:j:1}
			[[ $c == "$last" ]] || { s+=$R${pal[$c]:-}; last=$c; }
			s+=${g[i]:j:1}
		done
		rows+=("$s$R")
	done
	if ((HW - w - 4 >= 44)); then # the text keeps 44 columns beside it
		HART=("${rows[@]}") HARTW=$w HART_AT=${#HROWS[@]}
		((HHEAD_AT == HART_AT - 1)) && HART_AT=$HHEAD_AT # level with the title
	elif ((w < HW)); then
		for s in "${rows[@]}"; do HROWS+=(" $s"); done
		HROWS+=("") HBLANK=1
	fi
}
# hart_close: the picture hart held back, set beside the rows of its section. The text there
# was wrapped narrower to leave it room, and the title's rule stops short of it. A picture
# taller than its section gets rows of its own, and the blank row that ends the section stays
# clear of it.
hart_close() {
	((HARTW)) || return 0
	local i n=${#HART[@]} tw=$((HW - HARTW - 2)) blank=$HBLANK
	((blank)) && unset 'HROWS[-1]'
	while ((${#HROWS[@]} < HART_AT + n)); do HROWS+=(""); done
	for ((i = 0; i < n; i++)); do
		if ((HART_AT + i == HHEAD_AT)); then
			vlen "$HHEAD"
			hrule $((tw - VLEN))
			PADV=$HHEAD$RULE
		else padv "${HROWS[HART_AT + i]}" "$tw"; fi
		HROWS[HART_AT + i]="$PADV  ${HART[i]}"
	done
	((blank)) && HROWS+=("")
	HART=() HARTW=0
}

# help_build WIDTH -> HROWS: help.txt drawn for a page WIDTH characters wide
help_build() {
	local ln k t i c tw pad
	local -a tags=() big sun
	HW=$1 HROWS=() HBOX=0 HBLANK=1 HPARA="" HBC=$BMAG HB=() HPEND=() HPEND_END=() HBN=0
	HART=() HARTW=0 HHEAD_AT=-1 HHEAD=""
	HSIDE=$((HW >= 110)) HBW=$HW
	((HSIDE)) && HBW=$(((HW - 2) / 2))
	local boxes=0 heads=0 bcol=(5 6) hcol=(4 4 4) # every title on blue: the easiest to read
	# The banner: HELP in big letters going down a sunset, the .tag lines beside it, and the
	# sun itself going down behind a grid when there's room for it.
	if [[ -r $HELP_FILE ]]; then
		while IFS= read -r ln; do clean ln; [[ $ln == .tag\ * ]] && tags+=("${ln#.tag }"); done <"$HELP_FILE"
	fi
	local keep=("${BIG_ROWS[@]}")
	big_banner HELP "$B$BWHT" "$B$BYEL" "$YEL" "$BRED" "$BMAG"
	big=("${BIG_ROWS[@]}") BIG_ROWS=("${keep[@]}")
	sun=("$GRY ·    $BYEL▄▄▄▄▄▄▄$GRY    + $R" "$BYEL   ▄███████████▄   $R" "$YEL  ███████████████  $R"
		"$BRED  ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀  $R" "$BMAG   ▀▀▀▀▀▀▀▀▀▀▀▀▀   $R" "$MAG━┿━━━┿━━━┿━━━┿━━━┿━$R")
	vlen "${big[0]}"
	tw=$((HW - VLEN - 5)) # the room beside the letters
	local -a side=("" "" "" "" "" "")
	if ((${#tags[@]})); then
		tab "${tags[0]}" 4
		side[1]=$TAB
	fi
	if ((${#tags[@]} > 1)); then
		help_wrap "${tags[1]}" "$tw"
		for i in 0 1 2; do [[ -n ${WRAP[i]:-} ]] && side[i + 3]="$B$BCYN${WRAP[i]}$R"; done
	fi
	local sw=0
	for i in "${!side[@]}"; do vlen "${side[i]}"; ((VLEN > sw)) && sw=$VLEN; done
	HROWS+=("")
	for i in 0 1 2 3 4 5; do
		padv "${side[i]}" "$sw"
		t="  ${big[i]}   $PADV"
		((tw - sw >= 24)) && t+="    ${sun[i]}"
		HROWS+=("$t")
	done
	HBLANK=0
	if [[ ! -r $HELP_FILE ]]; then
		HROWS+=("" "  ${BRED}help.txt is missing from $(dirname "$HELP_FILE")$R")
		HELP_W=$HW
		return
	fi
	while IFS= read -r ln || [[ -n $ln ]]; do
		clean ln
		HCW=$((HBOX ? HBW - 5 : HW - 2))
		# Text that starts beside a picture is wrapped to leave it room; under it, it isn't.
		((HARTW && ${#HROWS[@]} < HART_AT + ${#HART[@]})) && HCW=$((HCW - HARTW - 2))
		case $ln in
		\;* | .tag\ *) continue ;;
		"") hpara; ((HBLANK)) || hpush "" ;;
		.art\ *) hpara; hart "${ln#.art }" ;;
		"= "*)
			hpara
			hart_close
			hflush
			((HBLANK)) || HROWS+=("")
			heads=$((heads + 1))
			tab "$heads ${ln#= }" "${hcol[(heads - 1) % 3]}"
			t=" $TAB " HHEAD=" $TAB " HHEAD_AT=${#HROWS[@]}
			vlen "$t"
			hrule $((HW - VLEN))
			HROWS+=("$t$RULE")
			HBLANK=0 ;;
		.box\ *)
			hpara
			hart_close
			((HBLANK || ${#HPEND[@]})) || HROWS+=("")
			c=${bcol[boxes % 2]} boxes=$((boxes + 1))
			HBC=$'\e'"[9${c}m"
			tab "${ln#.box }" 4 # the title on blue; the frame keeps its colour
			t="$HBC╔═$TAB"
			vlen "$t"
			rep ═ $((HBW - VLEN - 2))
			HB=("$t$HBC$REP╗$R ")
			HBOX=1
			hpush "" ;;
		.end)
			hpara
			((HBLANK)) || hpush ""
			hbox_close ;;
		.button\ *)
			hpara
			t=${ln#.button } k=${t%% *} t=${t#* }
			hbutton "$k" "$t" ;;
		"$ "*)
			hpara
			# Too long for a line: broken after a / or a space where there's one late enough.
			t=${ln#\$ } pad="     $GRY\$$R "
			while [[ -n $t ]]; do
				c=$((HCW - 8))
				if ((${#t} > c)); then
					k=${t:0:c} k=${k%[/ ]*}
					((${#k} >= c / 2)) && c=$((${#k} + 1))
				fi
				hpush "$pad$BCYN${t:0:c}$R"
				t=${t:c} pad="       "
			done ;;
		"- "*)
			hpara
			hhang "  $BYEL▪$R " 4 "${ln#- }" ;;
		[0-9].\ * | [0-9][0-9].\ *)
			hpara
			printf -v k '%2s' "${ln%%.*}"
			hhang " $B$BYEL$k$R$BBLU▸$R " 5 "${ln#*. }" ;;
		*) HPARA+="${HPARA:+ }$ln" ;;
		esac
	done <"$HELP_FILE"
	hpara
	hart_close
	((HBOX)) && hbox_close
	hflush
	HELP_W=$HW
}

# help_frame LINES BANNER-ROWS: draw() hands over here after the banner while the help page is
# open. The page fills the rest, with its keys on the bar at the bottom, and is painted.
help_frame() {
	local view=$(($1 - $2 - 5)) n i k last t
	((HELP_W == IW)) || help_build "$IW"
	n=${#HROWS[@]}
	((view < 1)) && view=1
	HELP_VIEW=$view
	((HELP_TOP > n - view)) && HELP_TOP=$((n - view))
	((HELP_TOP < 0)) && HELP_TOP=0
	sect "HELP · HOW TO USE REVIVE"
	for ((i = 0; i < view; i++)); do
		k=${HROWS[HELP_TOP + i]:-}
		t=${TICK:-0}
		if ((t % 2)); then k=${k//"$HB1"/"$GRY"}; else k=${k//"$HB2"/"$GRY"}; fi
		((t % 7 == 0 || t % 7 == 3)) || k=${k//"$HLIT"/"$GRY"}
		row "$k"
	done
	last=$((HELP_TOP + view < n ? HELP_TOP + view : n))
	kcs ↑↓ " scroll" PgUp/PgDn " page" i/p " install" Esc " close"
	k=$KC
	if [[ -n $FLASH ]] && ((SECONDS - FLASH_T < 5)); then k="$BGBLU$B$BWHT $FLASH $R  $k"; fi
	vlen "$k"
	i="$GRY$((HELP_TOP + 1))-$last of $n$R"
	((last < n)) && i+=" $BYEL▼$R"
	((HELP_TOP)) && i="$BYEL▲$R $i"
	k+="  "
	vlen "$k"
	local kl=$VLEN
	vlen "$i"
	((kl + VLEN <= IW)) && { rep ' ' $((IW - kl - VLEN)); k+="$REP$i"; }
	rep ═ $((W - 2))
	line "$FRAME╠$REP╣$R"
	row "$k"
	local sig="$BLU▓▒░$R$GRY tmux-revive bbs · est. 2026 $R$BLU░▒▓$R"
	vlen "$sig"
	rep ═ $((W - 4 - VLEN))
	line "$FRAME╚$REP$R$sig$FRAME══╝$R"
	if ((ONCE)); then printf '%s\n' "${OUT[@]}"; return; fi
	# As draw() paints: only the lines that changed, in one synchronized update.
	local buf=""
	for i in "${!OUT[@]}"; do
		[[ ${OUT[i]} == "${PREV[i]-}" ]] && continue
		buf+="$e[$((i + 1));1H${OUT[i]}$e[K"
	done
	((${#OUT[@]} < ${#PREV[@]})) && buf+="$e[$((${#OUT[@]} + 1));1H$e[J"
	PREV=("${OUT[@]}")
	[[ -n $buf ]] && printf '%s' "$e[?2026h$buf$e[?2026l"
}

# ------------------------------------------------------------------ keys
# help_view: the page stays up, redrawn every second (the clock, a resize), until Esc, x, q
# or ? again. ↑↓ scroll a line, PgUp/PgDn and Space a page, Home and End go to either end.
# Ctrl-C closes it too.
help_view() {
	local k rest seq st INTR=0 hsec=0
	HELP=1 HELP_TOP=0 PREV=()
	trap 'INTR=1' INT
	while :; do
		draw
		k=""
		IFS= read -rsn1 -t 1 k
		st=$?
		((INTR)) && break
		# Over 128: the second is up. The panel's clock moves on every other one (its REFRESH,
		# 2s), so the page's beacons blink as they would on the panel.
		if ((st)); then ((st > 128)) && { ((++hsec % 2)) || ((TICK++)); continue; }; break; fi
		case $k in
		x | X | q | Q | '?') break ;;
		' ') HELP_TOP=$((HELP_TOP + HELP_VIEW - 1)) ;;
		i | I) help_install workforce ;;
		p | P) help_install playwright ;;
		o | O) help_open "$PW_URL" ;;
		$'\e')
			rest="" seq=""
			IFS= read -rsn1 -t 0.05 rest
			[[ -z $rest ]] && break # a lone Esc closes it
			while IFS= read -rsn1 -t 0.03 rest; do seq+=$rest; [[ $rest == [@-~] || ${#seq} -gt 8 ]] && break; done
			case $seq in
			A) ((HELP_TOP--)) ;;
			B) ((HELP_TOP++)) ;;
			5~) HELP_TOP=$((HELP_TOP - HELP_VIEW + 1)) ;;
			6~) HELP_TOP=$((HELP_TOP + HELP_VIEW - 1)) ;;
			H | 1~ | 7~) HELP_TOP=0 ;;
			F | 4~ | 8~) HELP_TOP=${#HROWS[@]} ;;
			esac ;;
		esac
		# help_frame keeps HELP_TOP within the page.
	done
	HELP=0 PREV=()
	trap 'exit 0' INT
}

# help_confirm TITLE COMMAND: a popup like pick's showing the command that would run. Only y
# says yes; n, Esc or any other key says no (returns 1).
help_confirm() {
	local title=$1 rows cols w top left i k INTR=0 bg="$e[44m"
	local -a L=()
	rows=$(tput lines 2>/dev/null || echo 40) cols=$(tput cols 2>/dev/null || echo 80)
	w=$((cols - 8 < 76 ? cols - 8 : 76))
	help_wrap "$2" $((w - 8))
	L=("" "This runs $WNAME's installer:" "")
	for i in "${WRAP[@]}"; do L+=("  $BYEL$i"); done
	L+=("" "in a new tmux window, so you can watch it there." "")
	top=$(((rows - ${#L[@]} - 4) / 2)) left=$(((cols - w) / 2))
	((top < 1)) && top=1
	((left < 1)) && left=1
	rep ═ $((w - ${#title} - 11))
	printf '%s' "$e[$top;${left}H$BGBLU$BWHT╔═$R$BLU░▒▓$BGBLU$B$BWHT $title $R$BLU▓▒░$BGBLU$BWHT$REP╗$R"
	for i in "${!L[@]}"; do
		padv "$bg$BWHT${L[i]}" $((w - 4))
		printf '%s' "$e[$((top + 1 + i));${left}H$bg$BWHT║ $PADV$bg$BWHT ║$R$GRY░$R"
	done
	i=${#L[@]}
	padv "$B${BYEL}[y]$BWHT yes, run it     $B${BYEL}[n]$BWHT no, cancel" $((w - 4))
	printf '%s' "$e[$((top + 1 + i));${left}H$bg$BWHT║ $PADV$bg$BWHT ║$R$GRY░$R"
	rep ═ $((w - 2))
	printf '%s' "$e[$((top + 2 + i));${left}H$bg$BWHT╚$REP╝$R$GRY░$R"
	rep ░ "$w"
	printf '%s' "$e[$((top + 3 + i));$((left + 1))H$GRY$REP$R"
	trap 'INTR=1' INT
	k=""
	until IFS= read -rsn1 -t 0.2 k; do
		(($? <= 128 || INTR)) && { k=n; break; }
		k=""
	done
	trap 'INTR=1' INT # help_view's own, back
	PREV=()
	[[ $k == [yY] ]]
}

# The install button: ask, then run the installer in a new tmux window of its own, where its
# output and its question can be seen. Nothing runs without a y.
help_install() { # help_install workforce|playwright
	local cmd run
	what "$1" || return
	cmd=$("$WCMD") || { flash "no $WNAME installer for $OS"; return; }
	[[ -n ${!WENV:-} || $cmd == powershell* ]] || command -v curl >/dev/null ||
		{ flash "installing $WNAME needs curl"; return; }
	help_confirm "INSTALL ${WNAME^^}?" "$cmd" || { flash "install cancelled · nothing was run"; return; }
	# A new window gets tmux's environment, not the panel's: a stand-in goes along by hand.
	printf -v run '%q %q --install %q' "$BASH" "$REVIVE_ROOT/scripts/help.sh" "$1"
	[[ -n ${!WENV:-} ]] && printf -v run 'env %s=%q %s' "$WENV" "${!WENV}" "$run"
	tm new-window -n "$WWIN" "$run" ||
		{ flash "couldn't open a tmux window for the installer"; return; }
	[[ -n ${REVIVE_PANEL_POPUP:-} ]] && exit 0 # out of the way of the window it opened
	flash "installing in the new tmux window: $WWIN"
}

# The link button: the page in a browser, or the address to open by hand.
help_open() {
	local op=""
	if [[ $OS == Darwin ]] && command -v open >/dev/null; then op=open
	elif command -v xdg-open >/dev/null; then op=xdg-open; fi
	[[ -n $op ]] || { flash "open this in your browser: $1"; return; }
	"$op" "$1" </dev/null >/dev/null 2>&1 &
	disown 2>/dev/null
	flash "opening $1"
}

# ------------------------------------------------------------------ run on its own
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	# --install-workforce: what older panels run.
	case ${1:-} in --install) w=${2:-} ;; --install-workforce) w=workforce ;; *) w="" ;; esac
	what "$w" || { echo "usage: help.sh --install workforce|playwright" >&2; exit 2; }
	cmd=$("$WCMD") || { echo "There's no $WNAME installer for $(uname -s)."; exit 1; }
	printf 'Installing %s:\n  %s\n\n' "$WNAME" "$cmd"
	bash -c "$cmd"
	st=$?
	if ((st)); then printf '\nThe installer stopped (exit %s).' "$st"
	elif [[ $w == playwright ]]; then printf '\nDone. Restart Claude Code to use it.'
	else printf '\nDone.'; fi
	printf ' Press Enter to close this window.'
	read -r _
	exit "$st"
fi
