# shellcheck shell=bash
# The control panel's help page: ? opens it in place of everything from the PANES band down,
# with the banner left above it. The words live in help.txt (its top says how to mark them
# up); this draws them BBS style, scrolls them, and runs the two buttons in the ads.
#
# Sourced by panel.sh, which gives it the colours, row/sect/tab, draw and flash. Run on its
# own, `help.sh --install-workforce` is what the install button starts in a new tmux window.

HELP_FILE="$(dirname "${BASH_SOURCE[0]}")/help.txt"
HELP=0 HELP_TOP=0 HELP_VIEW=1 HELP_W=-1 HROWS=()
# Tests draw the help page with --once: REVIVE_PANEL_HELP=1 panel.sh --once. (Sourced with no
# arguments of its own, $1 here is panel.sh's.)
[[ ${REVIVE_PANEL_HELP:-} == 1 && ${1:-} == --once ]] && HELP=1

WF_URL=https://raw.githubusercontent.com/odysseyalive/claude-workforce/main/install
PW_URL=https://github.com/odysseyalive/playwright-mcp

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
	if ((HBOX)); then padv "$1" $((HW - 5)); HROWS+=("$HBC║$R $PADV $HBC║$R$GRY░$R")
	else HROWS+=("$1"); fi
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
	hhang "" 0 "$HPARA"
	HPARA=""
}

# help_build WIDTH -> HROWS: help.txt drawn for a page WIDTH characters wide
help_build() {
	local ln k t i c pad
	local -a tags=() letters=("" "" "")
	HW=$1 HROWS=() HBOX=0 HBLANK=1 HPARA="" HBC=$BMAG
	local boxes=0 bcol=(5 6)
	# The banner: HELP in block letters, the .tag lines beside it.
	if [[ -r $HELP_FILE ]]; then
		while IFS= read -r ln; do clean ln; [[ $ln == .tag\ * ]] && tags+=("${ln#.tag }"); done <"$HELP_FILE"
	fi
	local -A HG=([H]="█ █|█▀█|▀ ▀" [E]="█▀▀|█▀▀|▀▀▀" [L]="█  |█  |▀▀▀" [P]="█▀█|█▀▀|▀  ")
	local -a parts shade=("$B$BWHT" "$BCYN" "$BBLU")
	for c in H E L P; do
		IFS='|' read -ra parts <<<"${HG[$c]}"
		for i in 0 1 2; do letters[i]+="${parts[i]} "; done
	done
	HROWS+=("")
	for i in 0 1 2; do
		t=${tags[i]:-}
		if ((i == 0)) && [[ -n $t ]]; then t="$BBLU░▒▓$R$B$BWHT $t $R$BBLU▓▒░$R"
		elif ((i == 1)); then t="$B$BCYN$t$R"
		else t="$GRY$t$R"; fi
		HROWS+=("  $BLU░▒▓$R ${shade[i]}${letters[i]}$R$BLU▓▒░$R   $t")
	done
	rep ▀ $((HW - 4))
	HROWS+=("  $BLU$REP$R")
	if [[ ! -r $HELP_FILE ]]; then
		HROWS+=("" "  ${BRED}help.txt is missing from $(dirname "$HELP_FILE")$R")
		HELP_W=$HW
		return
	fi
	while IFS= read -r ln || [[ -n $ln ]]; do
		clean ln
		HCW=$((HBOX ? HW - 5 : HW - 2))
		case $ln in
		\;* | .tag\ *) continue ;;
		"") hpara; ((HBLANK)) || hpush "" ;;
		"= "*)
			hpara
			((HBLANK)) || HROWS+=("")
			tab "${ln#= }" 4
			t=$TAB
			vlen "$t"
			rep ─ $((HW - VLEN - 1))
			HROWS+=("$t$BLU$REP$R")
			HROWS+=("") HBLANK=1 ;;
		.box\ *)
			hpara
			((HBLANK)) || HROWS+=("")
			c=${bcol[boxes % 2]} boxes=$((boxes + 1))
			HBC=$'\e'"[9${c}m"
			tab "${ln#.box }" "$c"
			t="$HBC╔═$TAB"
			vlen "$t"
			rep ═ $((HW - VLEN - 2))
			HROWS+=("$t$HBC$REP╗$R")
			HBOX=1
			hpush "" ;;
		.end)
			hpara
			((HBLANK)) || hpush ""
			rep ═ $((HW - 3))
			t=$REP
			rep ░ $((HW - 1))
			HROWS+=("$HBC╚$t╝$R$GRY░$R" " $GRY$REP$R")
			HBOX=0 HBLANK=0 ;;
		.button\ *)
			hpara
			t=${ln#.button } k=${t%% *} t=${t#* }
			c=${HBC/9/4} # the box's colour as a background
			hpush "  $HBC░▒▓$R$e[103m$e[30m$B [$k] $R$c$B$BWHT $t $R$HBC▓▒░$R  $GRY← press $k$R" ;;
		"$ "*)
			hpara
			# Too long for a line: broken after a / or a space where there's one late enough.
			t=${ln#\$ } pad="  $GRY\$$R "
			while [[ -n $t ]]; do
				c=$((HCW - 4))
				if ((${#t} > c)); then
					k=${t:0:c} k=${k%[/ ]*}
					((${#k} >= c / 2)) && c=$((${#k} + 1))
				fi
				hpush "$pad$BCYN${t:0:c}$R"
				t=${t:c} pad="    "
			done ;;
		\[*\]\ *)
			hpara
			k=${ln%%]*} k=${k#[} t=${ln#*] }
			printf -v pad '%*s' $((7 - ${#k})) ''
			hhang " $BBLU[$B$BYEL$k$R$BBLU]$R$pad" 10 "$t" ;;
		\<*\>\ *)
			hpara
			k=${ln%%>*} k=${k#<} t=${ln#*> }
			fld "$k" 9
			hhang " $B$BCYN$FLD$R" 10 "$t" ;;
		"- "*)
			hpara
			hhang "  $BYEL▪$R " 4 "${ln#- }" ;;
		[0-9].\ * | [0-9][0-9].\ *)
			hpara
			k=${ln%%.*}
			hhang " $B$BYEL$(printf '%2s' "$k")$R$BBLU▸$R " 5 "${ln#*. }" ;;
		*) HPARA+="${HPARA:+ }$ln" ;;
		esac
	done <"$HELP_FILE"
	hpara
	((HBOX)) && { rep ═ $((HW - 3)); HROWS+=("$HBC╚$REP╝$R"); }
	HELP_W=$HW
}

# help_frame LINES BANNER-ROWS: draw() hands over here after the banner while the help page is
# open. The page fills the rest, with its keys on the bar at the bottom, and is painted.
help_frame() {
	local view=$(($1 - $2 - 5)) n i k last
	((HELP_W == IW)) || help_build "$IW"
	n=${#HROWS[@]}
	((view < 1)) && view=1
	HELP_VIEW=$view
	((HELP_TOP > n - view)) && HELP_TOP=$((n - view))
	((HELP_TOP < 0)) && HELP_TOP=0
	sect "HELP · HOW TO USE REVIVE"
	for ((i = 0; i < view; i++)); do row "${HROWS[HELP_TOP + i]:-}"; done
	last=$((HELP_TOP + view < n ? HELP_TOP + view : n))
	kcs ↑↓ " scroll" PgUp/PgDn " page" i " install" o " open" Esc " close"
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
	local k rest seq st INTR=0
	HELP=1 HELP_TOP=0 PREV=()
	trap 'INTR=1' INT
	while :; do
		draw
		k=""
		IFS= read -rsn1 -t 1 k
		st=$?
		((INTR)) && break
		if ((st)); then ((st > 128)) && continue; break; fi # over 128: the second is up
		case $k in
		x | X | q | Q | '?') break ;;
		' ') HELP_TOP=$((HELP_TOP + HELP_VIEW - 1)) ;;
		i | I) help_install ;;
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
	L=("" "This runs Claude Workforce's installer:" "")
	for i in "${WRAP[@]}"; do L+=("  $BYEL$i"); done
	L+=("" "in a new tmux window, so you can watch it and answer" "its question there." "")
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
help_install() {
	local cmd
	cmd=$(workforce_cmd) || { flash "no Claude Workforce installer for $OS"; return; }
	[[ -n ${REVIVE_WORKFORCE_INSTALL_CMD:-} || $cmd == powershell* ]] || command -v curl >/dev/null ||
		{ flash "installing Claude Workforce needs curl"; return; }
	help_confirm "INSTALL CLAUDE WORKFORCE?" "$cmd" || { flash "install cancelled · nothing was run"; return; }
	# A new window gets tmux's environment, not the panel's: a stand-in goes along by hand.
	local run
	printf -v run '%q %q --install-workforce' "$BASH" "$REVIVE_ROOT/scripts/help.sh"
	[[ -n ${REVIVE_WORKFORCE_INSTALL_CMD:-} ]] && printf -v run 'env REVIVE_WORKFORCE_INSTALL_CMD=%q %s' "$REVIVE_WORKFORCE_INSTALL_CMD" "$run"
	tm new-window -n workforce "$run" ||
		{ flash "couldn't open a tmux window for the installer"; return; }
	[[ -n ${REVIVE_PANEL_POPUP:-} ]] && exit 0 # out of the way of the window it opened
	flash "installing in the new tmux window: workforce"
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
	[[ ${1:-} == --install-workforce ]] || { echo "usage: help.sh --install-workforce" >&2; exit 2; }
	cmd=$(workforce_cmd) || { echo "There's no Claude Workforce installer for $(uname -s)."; exit 1; }
	printf 'Installing Claude Workforce:\n  %s\n\n' "$cmd"
	bash -c "$cmd"
	st=$?
	if ((st)); then printf '\nThe installer stopped (exit %s).' "$st"; else printf '\nDone.'; fi
	printf ' Press Enter to close this window.'
	read -r _
	exit "$st"
fi
