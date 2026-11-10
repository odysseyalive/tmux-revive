#!/usr/bin/env bash
# tmux-revive panel on a private tmux server (never touches yours): what it shows, that it
# fits the terminal, and that its keys work.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/panel-test.XXXXXX")
unset TMUX TMUX_PANE XDG_STATE_HOME # never your state dir (agents run with it set)
export REVIVE_DIR=$T/data AGENT_SAY_MAILBOX=$T/mail/mailbox.md REVIVE_PANEL_REFRESH=1 REVIVE_PANEL_SPLASH=0
# Host keys come from the test's own known_hosts, never yours, and never from ssh-keyscan.
export AGENT_SAY_KNOWN_HOSTS=$T/known_hosts AGENT_SAY_KEYSCAN=false
tm() { tmux -L "revive-panel-test-$$" -f /dev/null "$@"; }
pass=0 fail=0
check() {
	if eval "$2"; then
		printf '  \033[32mpass\033[0m %s\n' "$1"; ((pass++))
	else
		printf '  \033[31mFAIL\033[0m %s\n' "$1"; ((fail++))
	fi
}
cleanup() {
	tm kill-server 2>/dev/null
	tmux -L "revive-alert-$$" -f /dev/null kill-server 2>/dev/null
	tmux -L "revive-panel-remote-$$" -f /dev/null kill-server 2>/dev/null
	tmux -L "revive-panel-scroll-$$" -f /dev/null kill-server 2>/dev/null
	[[ -n ${dpid:-} ]] && kill "$dpid" 2>/dev/null
	rm -rf "$T"
}
trap cleanup EXIT
# Cut short (timeout's TERM, Ctrl-C, a closed terminal): still clean up the private servers.
trap 'exit 1' INT TERM HUP
plain() { sed 's/\x1b\[[0-9;]*m//g'; }
screen() { tm capture-pane -p -t work:panel; }
wait_screen() { for _ in $(seq 1 30); do screen | grep -qF -- "$1" && return 0; sleep 0.2; done; return 1; }

tm new-session -d -s work -x 130 -y 40 "bash --norc --noprofile"
tm split-window -d -t work "top -d 5"
sleep 0.5

echo "one frame"
# Inside the private server, so the panel reads its panes, not yours.
frame() { tm run-shell "REVIVE_PANEL_PEEK=0 COLUMNS=$1 LINES=${2:-40} REVIVE_PANEL_ART=${3:-} REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX bash $ROOT/scripts/panel.sh --once" | plain; }
for size in "80 24" "100 40" "130 40" "200 60"; do
	read -r c l <<<"$size"
	shape=$(frame "$c" "$l" | awk '{w[length]=1; n++} END{for (k in w) printf "%s ", k; print "x " n}')
	check "it fills a ${c}x$l pane exactly ($shape)" "[[ '$shape' == '$c x $l' ]]"
done
for a in city mountains space circuit grid; do
	out=$(frame 120 45 "$a")
	check "the $a artwork draws and fits" "grep -q 'ART · ' <<<\"\$out\" && [[ \$(awk '{w[length]=1} END{for (k in w) n++; print n}' <<<\"\$out\") == 1 ]]"
done
# Calm artwork: from one frame to the next only a few cells of the art band change, and the
# scene beside the banner holds still.
artband() { tm run-shell "REVIVE_PANEL_PEEK=0 REVIVE_PANEL_TICK=$2 REVIVE_PANEL_ART=$1 COLUMNS=140 LINES=50 REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX bash $ROOT/scripts/panel.sh --once"; }
cat >"$T/calm.py" <<'PY'
import re, sys
T, top = sys.argv[1], int(sys.argv[2])
def grid(lines):
    rows = []
    for line in lines:
        row, col = [], ''
        for m in re.finditer(r'(\x1b\[[0-9;]*m)|(.)', line):
            if m.group(1): col = m.group(1)
            else: row.append((m.group(2), col))
        rows.append(row)
    return rows
def plain(line): return re.sub(r'\x1b\[[0-9;]*m', '', line)
frames = [open(f'{T}/f{t}', encoding='utf-8').read().split('\n') for t in range(4)]
bands, tails = [], []
for f in frames:
    i = next(n for n, l in enumerate(f) if 'ART · ' in plain(l))
    j = next(n for n, l in enumerate(f) if 'MESSAGES' in plain(l))
    bands.append(grid(f[i + 1:j]))
    tails.append([plain(l)[100:] for l in f[1:7]])  # the scene beside the banner
worst = max(sum(u != v for p, q in zip(a, b) for u, v in zip(p, q)) for a, b in zip(bands, bands[1:]))
still = all(t == tails[0] for t in tails)
print(f'worst={worst} banner_still={still}', file=sys.stderr)
sys.exit(0 if worst <= top and still else 1)
PY
calm() { # calm SCENE MAX
	local t
	for t in 0 1 2 3; do artband "$1" $t >"$T/f$t"; done
	python3 "$T/calm.py" "$T" "$2" 2>>"$T/calm.log"
}
check "night city: only a star and two windows change" "calm city 6"
check "mountains: only two stars change" "calm mountains 4"
check "circuit board: only three LEDs change" "calm circuit 6"
# Two clouds sliding a column as a whole touch every edge of their puffs at once.
check "neon grid: only two clouds drift" "calm grid 40"
check "deep space: the comet and two stars" "calm space 16"
cat >"$T/sun.py" <<'PY'
import re, sys
rows = [re.sub(r'\x1b\[[0-9;]*m', '', l) for l in sys.stdin.read().split('\n')]
band = rows[next(i for i, r in enumerate(rows) if 'ART · ' in r) + 1:]
hz = next(i for i, r in enumerate(band) if r.count('─') > 40)
sky = band[:hz]
# Each sun row between its own edges; a striped gap row uses the edges of the row above it
# (the sun narrows upward, so that span lies inside the gap).
top = next(i for i, r in enumerate(sky) if '█' in r)
span, bad = None, False
for r in sky[top:]:
    if '█' in r:
        span = (r.index('█'), r.rindex('█'))
    a, b = span
    bad |= any(ch in '*·.' for ch in r[a:b + 1])
sys.exit(1 if bad else 0)
PY
cat >"$T/dusk.py" <<'PY'
import re, sys
rows = [re.sub(r'\x1b\[[0-9;]*m', '', l) for l in sys.stdin.read().split('\n')]
band = rows[next(i for i, r in enumerate(rows) if 'ART · ' in r) + 1:]
hz = next(i for i, r in enumerate(band) if r.count('─') > 40)
sky = ''.join(r[2:-2] for r in band[:hz])
sys.exit(0 if not any(ch in sky for ch in '*·.') and ('▀' in sky or '▄' in sky) else 1)
PY
check "the sunset sky has clouds, not stars" "artband grid 1 | python3 $T/dusk.py && artband grid 5 | python3 $T/dusk.py"
check "and nothing shows through the sun" "artband grid 1 | python3 $T/sun.py"
out=$(frame 130)
check "a shell pane shows as a shell" "grep -q 'bash *· shell' <<<\"\$out\""
check "a program shows as running" "grep -q 'top *▸ running' <<<\"\$out\""
check "the command keys are listed" "grep -qF '[J]ump  [M]essage  [N]ame  [L]ink  [U]nlink  [P]eek  [A]rt  [S]ave  [Q]uit' <<<\"\$out\""
# Under heavy load one frame can come back short, so allow three looks; a real regression
# misses every time, and then the frame is printed to show what was seen.
narrow_ok() { local i f; for i in 1 2 3; do f=$(frame 80); grep -q 'top *▸ running' <<<"$f" && return 0; done; printf '%s\n' "$f" | grep -E '\[[0-9]\]' >&2; return 1; }
check "a narrow terminal still finds programs (ps not cut to COLUMNS)" "narrow_ok"

echo "peek"
# A pane whose screen ends in a blank row, under a numbered line: the peek box's bottom rows
# must be the pane's bottom rows, and it gets the room the artwork would have had.
tm new-window -d -t work -n numbers "seq -f 'row-%g' 1 200; sleep 300"
sleep 0.7
nid=$(tm display -p -t work:numbers '#{pane_id}')
pane_tail=$(tm capture-pane -p -t "$nid" | tail -2 | sed 's/[[:space:]]*$//' | tr '\n' '|')
peek=$(tm run-shell "REVIVE_PANEL_SEL=$nid COLUMNS=120 LINES=50 REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX bash $ROOT/scripts/panel.sh --once" | plain)
box_tail=$(awk '/PEEK · /{on=1; next} on && /MESSAGES|ART · /{exit} on' <<<"$peek" | tail -2 | sed 's/^║ │ \{0,1\}//; s/[[:space:]]*[▲▼░▓]\{0,1\}║$//; s/[[:space:]]*$//' | tr '\n' '|')
check "the peek's bottom rows are the pane's bottom rows ($pane_tail)" "[[ '$box_tail' == '$pane_tail' ]]"
# The peek gets about two thirds of the free rows, the artwork the rest.
prows=$(awk '/PEEK · /{on=1; next} on && /ART · |MESSAGES/{exit} on' <<<"$peek" | wc -l)
arows=$(awk '/ART · /{on=1; next} on && /MESSAGES/{exit} on' <<<"$peek" | wc -l)
check "the peek takes two thirds of the space, the artwork the rest ($prows, $arows)" "(( prows >= 14 && arows >= 3 && prows >= 2 * arows - 2 && prows <= 2 * arows + 4 ))"
check "the peek's title offers the full view" "grep -q 'PEEK · .*\[x\] full view' <<<\"\$peek\""
small=$(tm run-shell "REVIVE_PANEL_SEL=$nid COLUMNS=100 LINES=34 REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX bash $ROOT/scripts/panel.sh --once" | plain)
check "with too little left for the artwork, the peek takes it all" "grep -q 'PEEK · ' <<<\"\$small\" && ! grep -q 'ART · ' <<<\"\$small\" && [[ \$(wc -l <<<\"\$small\") == 34 ]]"
tm kill-window -t work:numbers

echo "keys"
tm new-window -d -t work -n panel "env REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX REVIVE_PANEL_REFRESH=1 bash $ROOT/scripts/panel.sh"
wait_screen 'C O N T R O L'
check "it labels its own pane" "screen | grep -q 'panel *✦ this panel'"
# Counted with grep -c, never grep -q at the end of a pipe (pipefail: a closed pipe fails it).
seen() { local n; n=$(screen | grep -cF -- "$1"); [[ $n == "${2:-1}" ]]; }
# The # cell is the pane's window.pane, as tmux's status bar numbers it: two panes in window
# 0 (the shell and top), the panel alone in window 1.
check "the # cell shows each pane's window.pane" "screen | grep -q '\[0\.0\] .*bash *· shell' && screen | grep -q '\[0\.1\] .*top *▸ running' && screen | grep -q '\[1\.0\] .*panel *✦ this panel'"
tm send-keys -t work:panel 1
check "a digit selects the first pane in that window" "wait_screen '[1.0] ▶'"
tm send-keys -t work:panel 0
check "in a window of two, the first of them" "wait_screen '[0.0] ▶'"
tm send-keys -t work:panel 7; sleep 0.5
check "a window with no panes leaves the selection where it was" "wait_screen '[0.0] ▶' && seen '] ▶'"
tm send-keys -t work:panel Down; wait_screen '[0.1] ▶' >/dev/null
tm send-keys -t work:panel n; sleep 0.5
tm send-keys -t work:panel 'top-watch' Enter
named() { for _ in $(seq 1 30); do tm list-panes -a -F '#{@agent}' | grep -qx "$1" && return 0; sleep 0.2; done; return 1; }
check "N renames the selected pane" "named top-watch && wait_screen '▶ top-watch'"
tm send-keys -t work:panel s
check "S saves" "wait_screen '(manual)'"
check "the peek box shows the selected pane" "screen | grep -q 'PEEK · top-watch'"
# x: the peek over the whole artwork, and x again keeps it there; only c brings the art back.
# Every row is repainted right.
whole() { local s; s=$(screen); [[ ${s%%$'\n'*} == ╔* && ${s##*$'\n'} == *╝ ]] && seen 'PEEK · ' && seen 'MESSAGES'; }
tm send-keys -t work:panel x
check "x gives the peek the artwork's space too" "wait_screen '[c] collapse' && seen 'ART · ' 0 && whole"
check "the full view's hint offers c to collapse, not x" "seen '[c] collapse' && seen '[x] full view' 0 && seen '[x] back' 0"
tm send-keys -t work:panel c
check "c collapses it back, artwork and all" "wait_screen '[x] full view' && wait_screen 'ART · ' && whole"
tm send-keys -t work:panel x; wait_screen '[c] collapse' >/dev/null
tm send-keys -t work:panel x; sleep 1.5
check "x again keeps it expanded" "seen '[c] collapse' && seen 'ART · ' 0 && seen '[x] full view' 0 && whole"
tm send-keys -t work:panel c
check "and c collapses it again" "wait_screen '[x] full view' && wait_screen 'ART · ' && whole"
tm send-keys -t work:panel p; sleep 1.5
check "P hides the peek box" "! screen | grep -q 'PEEK'"
tm send-keys -t work:panel Down
check "the arrow keys move the selection" "wait_screen '[1.0] ▶'"
# The list goes round: Down past the last pane comes back to the first, Up past the first to the last.
tm send-keys -t work:panel Down
check "Down from the last pane selects the first" "wait_screen '[0.0] ▶'"
tm send-keys -t work:panel 0; wait_screen '[0.0] ▶' >/dev/null
tm send-keys -t work:panel Up
check "Up from the first pane selects the last" "wait_screen '[1.0] ▶' && seen '] ▶' && seen '[1.1]' 0"
# Held arrows: quick to follow, nothing echoed, nothing scrolled.
tm send-keys -t work:panel Up Up
quick() { local s=$EPOCHREALTIME; tm send-keys -t work:panel Down; for _ in $(seq 1 40); do screen | grep -qF "[$1] ▶" && break; sleep 0.05; done; awk -v a=$s -v b=$EPOCHREALTIME 'BEGIN{exit !(b - a < 1.0)}'; }
wait_screen '[0.0] ▶' >/dev/null
check "an arrow key moves the selection within a second" "quick 0.1"
for _ in 1 2 3 4 5 6; do tm send-keys -t work:panel Down Up; done; sleep 1.5
check "held arrows echo nothing onto the screen" "! screen | grep -qF '^['"
check "and the frame never scrolls" "screen | head -1 | grep -q '^╔'"
tm send-keys -t work:panel m; sleep 0.5
check "M opens the message prompt, saying how to back out" "wait_screen 'Esc cancels'"
tm send-keys -t work:panel -l 'never sent'; sleep 0.3
tm send-keys -t work:panel Escape
check "Esc backs out of a message" "wait_screen 'message cancelled' && ! screen | grep -q 'Esc cancels'"
tm send-keys -t work:panel m; sleep 0.5
tm send-keys -t work:panel -l 'never sent either'; sleep 0.3
tm send-keys -t work:panel C-c; sleep 1
check "Ctrl-C backs out too, and the panel stays open" "tm list-windows -F '#{window_name}' | grep -qx panel && wait_screen 'C O N T R O L' && ! screen | grep -q 'Esc cancels'"
check "nothing was sent" "! grep -qs 'never sent' $AGENT_SAY_MAILBOX"
before=$(screen | grep -o 'ART · [a-z ]*' | head -1)
tm send-keys -t work:panel a
check "A switches the artwork ($before)" "for _ in \$(seq 1 20); do after=\$(screen | grep -o 'ART · [a-z ]*' | head -1); [[ -n \$after && \$after != '$before' ]] && break; sleep 0.2; done; [[ \$after != '$before' ]]"
tm send-keys -t work:panel q; sleep 1
check "Q quits" "! tm list-windows -F '#{window_name}' | grep -qx panel"
# An arrow redraws from what was gathered: the links and saves aren't looked at again for it.
# A tmux that logs what it's asked shows it (the saves ask it for @revive-interval).
mkdir -p "$T/shim"
printf '#!/bin/sh\necho "$*" >>"%s/shim.log"\nexec %s "$@"\n' "$T" "$(command -v tmux)" >"$T/shim/tmux"
chmod +x "$T/shim/tmux"
tm new-window -d -t work -n navp "env PATH=$T/shim:$PATH REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX REVIVE_PANEL_REFRESH=60 bash $ROOT/scripts/panel.sh"
nscreen() { tm capture-pane -p -t work:navp; }
wait_n() { for _ in $(seq 1 30); do nscreen | grep -qF -- "$1" && return 0; sleep 0.2; done; return 1; }
looks() { grep -c 'show-option -gqv @revive-interval' "$T/shim.log" 2>/dev/null; }
wait_n 'C O N T R O L' >/dev/null; sleep 0.5
tm send-keys -t work:navp 0; wait_n '[0.0] ▶' >/dev/null; sleep 0.3
l0=$(looks)
tm send-keys -t work:navp Down; wait_n '[0.1] ▶' >/dev/null
tm send-keys -t work:navp Down; wait_n '[1.0] ▶' >/dev/null
tm send-keys -t work:navp Up; wait_n '[0.1] ▶' >/dev/null; sleep 0.3
l1=$(looks)
check "an arrow redraws without looking at the links and saves again ($l0, $l1)" "(( l0 >= 1 && l1 == l0 ))"
tm send-keys -t work:navp a
check "any other key looks again" "for _ in \$(seq 1 20); do (( \$(looks) > l1 )) && break; sleep 0.2; done; (( \$(looks) > l1 ))"
tm kill-window -t work:navp

echo "help"
# Its own panel, with a stand-in browser opener and a stand-in installer: nothing here opens a
# browser or fetches anything.
mkdir -p "$T/stub"
printf '#!/bin/sh\nprintf "%%s\\n" "$1" >%s/opened\n' "$T" >"$T/stub/xdg-open"
chmod +x "$T/stub/xdg-open"
# The installer runs in a new tmux window, which takes the server's environment: the stand-in
# goes there too, so even if the panel failed to pass it along, the real one wouldn't run.
tm set-environment -g REVIVE_WORKFORCE_INSTALL_CMD "touch $T/installed"
tm set-environment -g REVIVE_PLAYWRIGHT_INSTALL_CMD "touch $T/pw-installed"
tm new-window -d -t work -n helpw "env PATH=$T/stub:$PATH REVIVE_WORKFORCE_INSTALL_CMD='touch $T/installed' REVIVE_PLAYWRIGHT_INSTALL_CMD='touch $T/pw-installed' REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX REVIVE_PANEL_REFRESH=1 bash $ROOT/scripts/panel.sh"
hscreen() { tm capture-pane -p -t work:helpw; }
hwait() { for _ in $(seq 1 30); do hscreen | grep -qF -- "$1" && return 0; sleep 0.2; done; return 1; }
hgone() { for _ in $(seq 1 30); do hscreen | grep -qF -- "$1" || return 0; sleep 0.2; done; return 1; }
hpos() { hscreen | grep -o '[0-9]*-[0-9]* of [0-9]*' | tail -1; } # the bar's "first-last of all"
hwhole() { local s; s=$(hscreen); [[ ${s%%$'\n'*} == ╔* && ${s##*$'\n'} == *╝ ]]; }
hwait 'C O N T R O L'
check "the command bar offers ? for help" "hscreen | grep -qF '[?] help'"
tm send-keys -t work:helpw '?'
check "? opens the help page, with its banner" "hwait 'C H E A T   S H E E T' && hscreen | grep -q 'HELP · HOW TO USE REVIVE'"
check "in place of the pane list, under the panel's banner" "! hscreen | grep -q '✦ this panel\|PANES\|MESSAGES' &&hscreen | grep -q 'C O N T R O L' && hwhole"
# Left open, the page keeps the panel's clock: the agents' beacons take turns, live.
beacons() { local i seen=""; for i in 1 2 3 4 5 6; do seen+=$(tm capture-pane -p -e -t work:helpw | grep -o $'\e\\[38;5;22[67]m' | sort -u | tr -d '\n'); sleep 0.8; done; printf '%s' "$seen"; }
check "left open, its beacons blink in turn" "b=\$(beacons); [[ \$b == *'226m'* && \$b == *'227m'* ]]"
# A short pane, so there's a page to scroll through.
tm resize-window -t work:helpw -x 130 -y 24; sleep 1.5
p0=$(hpos)
check "it says how much of the page shows ($p0)" "[[ '$p0' == 1-* ]] && [[ \${p0##* } -gt \${p0%% *} ]]"
tm send-keys -t work:helpw Down
check "Down scrolls a line" "hwait '▲ 2-'"
tm send-keys -t work:helpw NPage; sleep 0.5
p1=$(hpos)
check "PgDn scrolls a page ($p1)" "(( \${p1%%-*} > 10 )) && hwhole"
tm send-keys -t work:helpw End; sleep 0.5
p2=$(hpos) last=${p2#*-} last=${last%% *}
check "End shows the bottom: the ads ($p2)" "[[ $last == \${p2##* } ]] && hscreen | grep -q 'Install playwright-mcp'"
tm send-keys -t work:helpw Home
check "Home goes back to the top" "hwait ' 1-' && hscreen | grep -q 'C H E A T   S H E E T'"
tm resize-window -t work:helpw -x 130 -y 40; sleep 1
tm send-keys -t work:helpw i
check "i asks before installing, showing what it would run" "hwait 'yes, run it' && hscreen | grep -q 'touch $T/installed'"
tm send-keys -t work:helpw n
check "n says no, and nothing runs" "hwait 'install cancelled' && sleep 1 && [[ ! -e $T/installed ]] && ! tm list-windows -F '#{window_name}' | grep -qx workforce"
check "and the help page stays open" "hscreen | grep -q 'HELP · HOW TO USE' && ! hscreen | grep -q 'yes, run it'"
tm send-keys -t work:helpw i; hwait 'yes, run it' >/dev/null
tm send-keys -t work:helpw y
installed() { for _ in $(seq 1 30); do [[ -e $T/installed ]] && return 0; sleep 0.2; done; return 1; }
check "y runs the installer in a new tmux window" "installed && tm list-windows -F '#{window_name}' | grep -qx workforce"
tm kill-window -t work:workforce 2>/dev/null
tm send-keys -t work:helpw p
check "p asks before installing playwright-mcp, showing what it would run" "hwait \"This runs playwright-mcp's installer\" && hscreen | grep -q 'touch $T/pw-installed'"
tm send-keys -t work:helpw y
pwinstalled() { for _ in $(seq 1 30); do [[ -e $T/pw-installed ]] && return 0; sleep 0.2; done; return 1; }
check "and y runs it in a new tmux window of its own" "pwinstalled && tm list-windows -F '#{window_name}' | grep -qx playwright-mcp"
tm kill-window -t work:playwright-mcp 2>/dev/null
tm resize-window -t work:helpw -x 90 -y 30; sleep 1.5
check "a resize redraws it to the new size" "hwhole && [[ \$(hscreen | head -1 | awk '{print length}') == 90 && \$(hscreen | wc -l) == 30 ]] && hscreen | grep -q 'HELP · HOW TO USE'"
tm resize-window -t work:helpw -x 130 -y 40; sleep 0.5
tm send-keys -t work:helpw x
check "x closes it, back to the panes" "hgone 'HELP · HOW TO USE' && hwait 'PANES' && hscreen | grep -q 'this panel'"
tm send-keys -t work:helpw '?'; hwait 'HELP · HOW TO USE' >/dev/null
tm send-keys -t work:helpw Escape
check "Esc closes it too" "hgone 'HELP · HOW TO USE' && hwait 'PANES'"
tm send-keys -t work:helpw q; sleep 1
# The page drawn by itself at a few widths: every line fills the frame exactly.
hframe() { tm run-shell "REVIVE_PANEL_HELP=1 COLUMNS=$1 LINES=200 REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX bash $ROOT/scripts/panel.sh --once" | plain; }
for c in 60 80 100 160; do
	out=$(hframe $c)
	w=$((c < 80 ? 80 : c)) # the panel is never narrower than 80
	check "the help page fits $c columns ($(awk '{w[length]=1} END{for (k in w) printf "%s ", k}' <<<"$out"))" "grep -q 'Claude Workforce' <<<\"\$out\" && [[ \$(awk '{w[length]=1} END{for (k in w) printf \"%s \", k}' <<<\"\$out\") == '$w ' ]]"
	# Fitting by being cut short doesn't count: nothing on the page itself ends in a …
	check "and none of its lines is cut short at $c" "! sed -n '/HELP · HOW TO USE/,\$p' <<<\"\$out\" | grep -q '…'"
done
# The pictures .art puts by the sections: beside the words on a wide page, above them on a
# narrow one, whole either way.
talk='██▄█▄██       ░░▒▒▓▓██►   ██▄█▄██' sat='█▒█▒█▒█▒█══███████══█▒█▒█▒█▒█'
out=$(hframe 160)
check "at 160 columns two agents talk beside the first section" "grep -q '[a-z][.,]* .*$talk' <<<\"\$out\" && grep -q '1 Get your agents talking.*▄  ' <<<\"\$out\""
check "and a satellite, alone, beside the second" "grep -q 'Got agents on a remote server.*$sat' <<<\"\$out\" && grep -q 'Talk to your servers too.*▪' <<<\"\$out\" && ! grep -q '░▒▓█▓▒░' <<<\"\$out\""
out=$(hframe 100)
check "at 100 they still fit beside the words" "grep -q 'Revive lets any AI.*$talk' <<<\"\$out\" && grep -q 'Got agents on a remote server.*$sat' <<<\"\$out\""
out=$(hframe 80)
check "at 80 they go above the words instead" "grep -q '^║  $talk  *║\$' <<<\"\$out\" && grep -q '^║   $sat  *║\$' <<<\"\$out\" && ! grep -q 'Got agents.*█▒█' <<<\"\$out\""
# The satellite's light blinks with the panel's clock: lit one tick in three, dark between.
lit() { tm run-shell "REVIVE_PANEL_TICK=$1 REVIVE_PANEL_HELP=1 COLUMNS=160 LINES=200 REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX bash $ROOT/scripts/panel.sh --once" | grep -c $'\e\\[38;5;196m'; }
check "the satellite's light comes on now and then, and is dark between" "[[ \$(lit 0) -ge 1 && \$(lit 1) == 0 && \$(lit 2) == 0 && \$(lit 3) -ge 1 ]]"
beacon() { tm run-shell "REVIVE_PANEL_TICK=$1 REVIVE_PANEL_HELP=1 COLUMNS=160 LINES=200 REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX bash $ROOT/scripts/panel.sh --once" | grep -c $'\e\\[38;5;'"$2"'m'; }
check "the two agents' beacons take turns" "[[ \$(beacon 0 226) -ge 1 && \$(beacon 0 227) == 0 && \$(beacon 1 226) == 0 && \$(beacon 1 227) -ge 1 ]]"
# A few suggestions to get going, not a reference: the keys are on the panel already.
out=$(hframe 160)
check "it has no key reference or column list" "! grep -qiE 'key reference|What the columns mean|Remember the old BBS|^║ +\\[[^]]+\\] {2,}[A-Z]' <<<\"\$out\" && grep -q 'shop-dev' <<<\"\$out\" && grep -q 'press L' <<<\"\$out\""
hp=$(tm run-shell "REVIVE_PANEL_HELP=1 COLUMNS=160 LINES=55 REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX bash $ROOT/scripts/panel.sh --once" | plain | grep -o '[0-9]*-[0-9]* of [0-9]*' | tail -1)
check "at 160x55 it fits on one screen ($hp)" "[[ \$hp == 1-* && \${hp%% of*} == 1-\${hp##* } ]]"

echo "context left"
# Stand-in agents (copies of bash named claude and codex) with the records the real ones keep:
# Claude Code's session record and transcript, and a Codex rollout file held open.
H=$T/home
mkdir -p "$H/.claude/sessions" "$H/.claude/projects/-w" "$H/.codex/sessions/2026/01/01" "$T/bin"
cp "$(command -v bash)" "$T/bin/claude"; cp "$(command -v bash)" "$T/bin/codex"
ro=$H/.codex/sessions/2026/01/01/rollout-2026-01-01T00-00-00-x.jsonl
{
	echo '{"type":"event_msg","payload":{"type":"token_count","info":null}}'
	echo '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":200000},"model_context_window":250000}}}'
	echo '{"type":"event_msg","payload":{"type":"token_count","info":null}}'
} >"$ro"
tm new-window -d -t work -n cl "$T/bin/claude -c 'sleep 300; :'"
tm new-window -d -t work -n cx "$T/bin/codex -c 'exec 3<$ro; sleep 300; :'"
tm new-window -d -t work -n cl2 "$T/bin/claude -c 'sleep 300; :'"
sleep 0.5
clpid=$(tm display -p -t work:cl '#{pane_pid}')
printf '{"pid":%s,"sessionId":"s-1","status":"idle"}\n' "$clpid" >"$H/.claude/sessions/$clpid.json"
{
	echo '{"type":"assistant","message":{"model":"claude-haiku-4-5","usage":{"input_tokens":5,"cache_read_input_tokens":40000,"cache_creation_input_tokens":5000}}}'
	echo '{"type":"assistant","isSidechain":true,"message":{"model":"claude-haiku-4-5","usage":{"input_tokens":190000}}}'
	echo '{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":0}}}'
	echo '{"type":"user","message":{"content":"the word \"usage\" in a message"}}'
} >"$H/.claude/projects/-w/s-1.jsonl"
cframe() { tm run-shell "HOME=$H REVIVE_PANEL_PEEK=0 COLUMNS=${1:-130} LINES=45 REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX bash $ROOT/scripts/panel.sh --once" | plain; }
out=$(cframe)
check "a CTX LEFT column follows MEM" "grep -q 'MEM  CTX LEFT' <<<\"\$out\""
check "Claude Code's context left, from its transcript's last turn (45k of 200k: 77% left)" "grep -q 'claude .*M  ███▓· *77%' <<<\"\$out\""
check "Codex's, from the rollout file it holds open (200k of 250k)" "grep -q 'codex .*M  █···· *20%' <<<\"\$out\""
check "an agent with no record shows a dash" "[[ \$(grep -c 'claude .*·····    –' <<<\"\$out\") == 1 ]]"
check "a shell shows nothing there" "grep 'bash *· shell' <<<\"\$out\" | grep -qv '–\\|%.*%'"
out=$(cframe 80)
check "it stays in the narrowest panel" "grep -q 'codex .* 20% *║' <<<\"\$out\" && [[ \$(awk '{w[length]=1} END{for (k in w) n++; print n}' <<<\"\$out\") == 1 ]]"
# The columns fill the row at any width: CTX LEFT ends at the panel's right edge, no row is
# wider than the panel, and GIT has whatever room is spare.
for c in 80 120 160 200; do
	out=$(cframe "$c")
	check "at $c columns CTX LEFT ends at the right edge, and no row is wider" "grep -q 'codex .* 20% ║\$' <<<\"\$out\" && [[ \$(awk '{w[length]=1} END{for (k in w) printf \"%s \", k}' <<<\"\$out\") == '$c ' ]]"
done
# A two-digit window widens the # column to its label, and every row still fits exactly, the
# names still in one column under NAME.
tm new-window -d -t work:12 -n twelve "sleep 300"; sleep 0.5
namecol() { awk '/ NAME /{print index($0, " NAME ") + 1} /\[12\.0\]/{print index($0, "---")}' <<<"$1" | sort -u | wc -l; }
for c in 80 120 160 200; do
	out=$(cframe "$c")
	check "at $c columns a [12.0] label fits, its name under NAME, every row exactly $c wide" "grep -q '║ \[12\.0\] ' <<<\"\$out\" && [[ \$(namecol \"\$out\") == 1 ]] && grep -q 'codex .* 20% ║\$' <<<\"\$out\" && [[ \$(awk '{w[length]=1} END{for (k in w) printf \"%s \", k}' <<<\"\$out\") == '$c ' ]]"
done
# An unnamed pane's NAME is ---: [12.0] already says where it is. With a second tmux session,
# [12.0] could be in either, so its session's name instead. Every row still exactly fits.
out=$(cframe 130)
check "an unnamed pane's NAME is ---, not its place again" "grep -q '\[12\.0\]   --- ' <<<\"\$out\" && ! grep -q 'work:12' <<<\"\$out\""
tm new-session -d -s other -x 80 -y 24 "sleep 300"; sleep 0.5
for c in 80 120 160 200; do
	out=$(cframe "$c")
	check "at $c columns with two sessions, an unnamed pane's NAME is its session, every row exactly $c wide" "grep -q '\[12\.0\]   work ' <<<\"\$out\" && grep -q '\[0\.0\] .. other ' <<<\"\$out\" && ! grep -q -- ' --- ' <<<\"\$out\" && [[ \$(awk '{w[length]=1} END{for (k in w) printf \"%s \", k}' <<<\"\$out\") == '$c ' ]]"
done
tm kill-session -t other
tm kill-window -t work:twelve
gitw() { cframe "$1" | awk '/ NAME .* GIT /{print index($0, " CPU") - index($0, " GIT"); exit}'; }
check "a panel 70 columns wider gives GIT all 70 ($(gitw 160) -> $(gitw 230))" "[[ -n \$(gitw 160) ]] && (( \$(gitw 230) == \$(gitw 160) + 70 ))"
echo '{"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":500000}}}' >>"$H/.claude/projects/-w/s-1.jsonl"
out=$(cframe)
check "a Claude 5 model has a million-token window (500k: 50% left)" "grep -q 'claude .* 50%' <<<\"\$out\""
rows=$(tm run-shell "HOME=$H REVIVE_DIR=$REVIVE_DIR bash $ROOT/scripts/panel.sh --rows")
check "--rows gives each pane's context left on a line of its own, before its row" "grep -A1 '^#ctx %[0-9]* 20$' <<<\"\$rows\" | grep -q $'\x1fcodex\x1f'"
# Idle between turns while its agents work in the background (their output under its temp
# folder written to just now): WORKING, and its peek says it still takes input.
mkdir -p "$T/ltmp/claude-$UID/-w/s-1/tasks"
bgframe() { tm run-shell "HOME=$H CLAUDE_CODE_TMPDIR=$T/ltmp REVIVE_PANEL_SEL=$clid COLUMNS=${1:-130} LINES=45 REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX bash $ROOT/scripts/panel.sh --once" | plain; }
clid=$(tm display -p -t work:cl '#{pane_id}')
: >"$T/ltmp/claude-$UID/-w/s-1/tasks/b1.output"
out=$(bgframe)
check "idle with agents working in the background shows WORKING" "grep -q 'claude *. WORKING ' <<<\"\$out\" && ! grep -q 'AGENTS WORKING' <<<\"\$out\""
check "and its peek says it still takes input" "grep -q 'PEEK · .*agents busy, takes input' <<<\"\$out\""
check "and it counts as working" "grep -q '1 working' <<<\"\$out\""
for c in 80 200; do
	out=$(bgframe "$c")
	check "at $c columns every row is exactly $c wide" "grep -q 'claude *. WORKING ' <<<\"\$out\" && [[ \$(awk '{w[length]=1} END{for (k in w) printf \"%s \", k}' <<<\"\$out\") == '$c ' ]]"
done
# A record saying waiting (a dialog of its own open) needs you, agents or not.
printf '{"pid":%s,"sessionId":"s-1","status":"waiting","waitingFor":"dialog open"}\n' "$clpid" >"$H/.claude/sessions/$clpid.json"
touch "$T/ltmp/claude-$UID/-w/s-1/tasks/b1.output"
out=$(bgframe)
check "a record saying waiting is WAITING ON YOU, agents or not" "grep -q 'claude *◆ WAITING ON YOU' <<<\"\$out\""
printf '{"pid":%s,"sessionId":"s-1","status":"idle"}\n' "$clpid" >"$H/.claude/sessions/$clpid.json"
touch -d '-1 minute' "$T/ltmp/claude-$UID/-w/s-1/tasks/b1.output"
out=$(bgframe)
check "with that output a minute old, WAITING ON YOU again" "grep -q 'claude *◆ WAITING ON YOU' <<<\"\$out\""
# An agent inside one long command writes nothing while it runs: the command still running under
# it, started the way Claude Code starts one (a shell sourcing its shell-snapshots file), is
# work in the background, however stale the output. Another child (an MCP server) isn't.
mkdir -p "$T/shell-snapshots" "$T/bin/mcp"
: >"$T/shell-snapshots/snapshot-x.sh"
cp "$(command -v sleep)" "$T/bin/mcp/mcp-server"
tm kill-window -t work:cl
tm new-window -d -t work -n cl "$T/bin/claude -c '$T/bin/mcp/mcp-server 300 & bash -c \"source $T/shell-snapshots/snapshot-x.sh; sleep 300; :\" & wait'"
sleep 0.5
clpid=$(tm display -p -t work:cl '#{pane_pid}') clid=$(tm display -p -t work:cl '#{pane_id}')
printf '{"pid":%s,"sessionId":"s-1","status":"idle"}\n' "$clpid" >"$H/.claude/sessions/$clpid.json"
out=$(bgframe)
check "idle with a command still running under it shows WORKING, its output stale" "grep -q 'claude *. WORKING ' <<<\"\$out\""
check "and its peek says it still takes input" "grep -q 'PEEK · .*agents busy, takes input' <<<\"\$out\""
printf '{"pid":%s,"sessionId":"s-1","status":"busy"}\n' "$clpid" >"$H/.claude/sessions/$clpid.json"
out=$(bgframe)
check "a record saying busy is WORKING, without the takes-input peek" "grep -q 'claude *. WORKING ' <<<\"\$out\" && ! grep -q 'takes input' <<<\"\$out\""
# Claude Code says "shell" once its turn is over while a background shell it started still runs.
printf '{"pid":%s,"sessionId":"s-1","status":"shell"}\n' "$clpid" >"$H/.claude/sessions/$clpid.json"
out=$(bgframe)
check "a record saying shell (a background shell still running) is WORKING, and takes input" "grep -q 'claude *. WORKING ' <<<\"\$out\" && grep -q 'takes input' <<<\"\$out\""
printf '{"pid":%s,"sessionId":"s-1","status":"idle"}\n' "$clpid" >"$H/.claude/sessions/$clpid.json"
snap=$(pgrep -P "$clpid" -f 'source .*snapshot-x')
pkill -P "$snap"; kill "$snap"; sleep 0.3
out=$(bgframe)
check "with that command ended (an MCP server still running under it), WAITING ON YOU" "pgrep -P $clpid -f mcp-server >/dev/null && grep -q 'claude *◆ WAITING ON YOU' <<<\"\$out\""
tm kill-window -t work:cl; tm kill-window -t work:cx; tm kill-window -t work:cl2

echo "access"
# The key bar offers G only while there's something for it: access waiting, or approved and
# not lapsed. A declined one isn't something for G. Access shows in MESSAGES; LINKS · SAVES
# (the right-hand column, after the last │) keeps to links and saves.
side() { grep -F ' │ ' | sed 's/.* │ //'; }
iid=0123456789abcdef0123456789abcdef
check "with nothing waiting or approved, the bar has no [G]rant access" "! frame 200 50 | grep -qF '[G]rant access'"
mkdir -p "$T/mail/intros/$iid" && echo "x@far" >"$T/mail/intros/$iid/from" && echo "y@near" >"$T/mail/intros/$iid/to"
out=$(frame 200 50)
check "with one waiting, the bar offers [G]rant access" "grep -qF '[G]rant access' <<<\"\$out\""
check "and MESSAGES shows it waiting, not failed" "grep -qF '⚑ waiting for [G]rant access x@far→y@near' <<<\"\$out\" && ! grep -qF '✗' <<<\"\$out\""
check "and LINKS · SAVES has no access lines" "side <<<\"\$out\" | grep -qF 'SAVED' && ! side <<<\"\$out\" | grep -qE '⚑|waiting|approved|rant access'"
rm -rf "$T/mail/intros/$iid"
# The agent waiting for access shows it in its STATE, by its name@host: here, a pane named
# acc-sh on this computer.
tm set-option -p -t work:0.0 @agent acc-sh
mkdir -p "$T/mail/intros/$iid" && echo "acc-sh@$(hostname -s 2>/dev/null || uname -n)" >"$T/mail/intros/$iid/from" && echo "y@near" >"$T/mail/intros/$iid/to"
check "an agent waiting for access shows [G]RANT ACCESS in its STATE" "frame 200 50 | grep -cE 'acc-sh .*⚑ \[G\]RANT ACCESS' >/dev/null"
rm -rf "$T/mail/intros/$iid"
check "and once it's answered, its STATE is back" "! frame 200 50 | grep -cF 'RANT ACCESS' >/dev/null"
tm set-option -p -u -t work:0.0 @agent
printf 'deny s:c1@h s:d1@h c@h d@h %s\nallow s:a1@h s:b1@h a@h b@h %s\n' "$(date +%s)" $(($(date +%s) - 90000)) >"$T/mail/grants"
out=$(frame 200 50)
check "a declined one, or an approval that has lapsed, isn't offered, and has no approved line" "! grep -qF '[G]rant access' <<<\"\$out\" && ! grep -qF ' approved' <<<\"\$out\""
printf 'allow s:a1@h s:b1@h a@h b@h %s\n' "$(date +%s)" >>"$T/mail/grants"
out=$(frame 200 50)
check "an approved one is, with one summary line in MESSAGES" "grep -qF '[G]rant access' <<<\"\$out\" && [[ \$(grep -cF '✓ 1 approved · [G] to see' <<<\"\$out\") == 1 ]] && ! side <<<\"\$out\" | grep -qF 'approved'"
rm -f "$T/mail/grants"
# A held message waiting for access says so in MESSAGES: not failed, waiting on you. It stays
# at the top however many messages come after it, and goes once it's delivered.
mkdir -p "$T/mail/intros/$iid" && echo "lr@far" >"$T/mail/intros/$iid/from" && echo "dr@near" >"$T/mail/intros/$iid/to" && echo 1 >"$T/mail/intros/$iid/created"
mv "$AGENT_SAY_MAILBOX" "$T/mailbox.keep" 2>/dev/null
printf '## [lr@far -> dr@near 2026-11-09T19:00:00Z] #h1.0001 (held: waiting for access)\nplease run it\n\n' >"$AGENT_SAY_MAILBOX"
for m in 1 2 3 4 5 6 7 8 9 10; do printf '## [a@h -> b@h 2026-11-09T19:%02d:00Z] #m%s\nnote %s\n\n' "$m" "$m" "$m" >>"$AGENT_SAY_MAILBOX"; done
out=$(frame 200 50)
check "a held message shows waiting for [G]rant access, not ✗" "grep -qF '⚑ waiting for [G]rant access lr@far→dr@near · please run it' <<<\"\$out\" && ! grep -qF '✗' <<<\"\$out\" && ! grep -qF 'held ·' <<<\"\$out\""
check "and with many messages after it, it's still there, first" "grep -qF 'note 10' <<<\"\$out\" && ! grep -qF 'note 6' <<<\"\$out\" && grep -A1 'MESSAGES ▓▒░' <<<\"\$out\" | grep -qF 'waiting for [G]rant access lr@far'"
printf '## [lr@far -> dr@near 2026-11-09T19:54:00Z] #h1.0001 (delivered)\nplease run it\n\n' >>"$AGENT_SAY_MAILBOX"
rm -rf "$T/mail/intros/$iid"
out=$(frame 200 50)
check "once delivered, a plain delivered row" "grep -qF '✉ lr@far→dr@near please run it' <<<\"\$out\" && ! grep -qF 'waiting for' <<<\"\$out\""
rm -f "$AGENT_SAY_MAILBOX"; mv "$T/mailbox.keep" "$AGENT_SAY_MAILBOX" 2>/dev/null
# A held message's row says what became of it: held, then delivered (no ✗), under one id. One
# refused for an agent session that changed says the agent restarted, not the raw error.
mv "$AGENT_SAY_MAILBOX" "$T/mailbox.keep" 2>/dev/null
printf '## [lr@far -> dr@near 2026-11-09T19:00:00Z] #h1.0001 (held: waiting for access)\nplease run it\n\n## [cx@far -> dr@near 2026-11-09T19:01:00Z] #h2.0001 (NOT DELIVERED: agent-say: the agent session in dr has changed since it was given permission; not sent)\nold one\n\n## [lr@far -> dr@near 2026-11-09T19:54:00Z] #h1.0001 (delivered)\nplease run it\n\n' >"$AGENT_SAY_MAILBOX"
out=$(frame 200 50)
check "a held message, once delivered, shows as delivered, once" "[[ \$(grep -c 'please run it' <<<\"\$out\") == 1 ]] && grep -q '✉ lr@far→dr@near please run it' <<<\"\$out\""
check "one refused because its agent restarted says so" "grep -q '✗ cx@far→dr@near not delivered: dr restarted · old one' <<<\"\$out\""
rm -f "$AGENT_SAY_MAILBOX"; mv "$T/mailbox.keep" "$AGENT_SAY_MAILBOX" 2>/dev/null
# The I window, live. Its popup for the approval code is a stand-in here (no client is attached
# to show a real one): a tmux in front of the real one that runs the popup's own command, reads
# the code it shows and types back the right one, or a wrong one, as $T/popup.code says.
mkdir -p "$T/popbin"
cat >"$T/popbin/tmux" <<POP
#!/bin/bash
if [[ \$1 == display-popup ]]; then
	echo "\$*" >>"$T/popup.log"
	cmd=\${!#}
	coproc P { eval "\$cmd"; }
	buf=""
	while IFS= read -r -N1 -t 5 c <&"\${P[0]}"; do buf+=\$c; [[ \$buf =~ Type\ ([0-9]{4})\  ]] && break; done
	if [[ \$(cat "$T/popup.code") == right ]]; then echo "\${BASH_REMATCH[1]}" >&"\${P[1]}"; else echo 0000 >&"\${P[1]}"; fi
	wait "\$P_PID"
	exit 0
fi
exec $(command -v tmux) "\$@"
POP
chmod +x "$T/popbin/tmux"
ia=1111111111111111aaaaaaaaaaaaaaaa ib=2222222222222222bbbbbbbbbbbbbbbb
intro() { # intro ID FROM TO TEXT
	mkdir -p "$T/mail/intros/$1/held"
	echo "s:$1@${2#*@}" >"$T/mail/intros/$1/from-session"; echo "s:to$1@${3#*@}" >"$T/mail/intros/$1/to-session"
	echo "$2" >"$T/mail/intros/$1/from"; echo "$3" >"$T/mail/intros/$1/to"; printf '%s' "$4" >"$T/mail/intros/$1/intro"
	date +%s >"$T/mail/intros/$1/created"
}
intro $ia live-root@far.invalid dev-root@near.invalid 'may I ask dev-root about the failing build?'
intro $ib cx@far.invalid dev-root@near.invalid 'hello'
# The agent sessions each link reports in those panes now: the same ones that asked.
mkdir -p "$T/mail/links/far.invalid" "$T/mail/links/near.invalid"
printf 'live-root %s\ncx %s\n' $ia $ib >"$T/mail/links/far.invalid/sessions"
printf 'dev-root to%s\n' $ia >"$T/mail/links/near.invalid/sessions"
printf 'allow s:a1@far.invalid s:b1@near.invalid ann@far.invalid bob@near.invalid %s\ndeny s:c1@far.invalid s:d1@near.invalid cat@far.invalid dan@near.invalid %s\n' $(($(date +%s) - 3600)) "$(date +%s)" >"$T/mail/grants"
tm new-window -d -t work -n acc "env PATH=$T/popbin:\$PATH AGENT_SAY_SSH=false REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX REVIVE_PANEL_REFRESH=1 bash $ROOT/scripts/panel.sh"
ascreen() { tm capture-pane -p -t work:acc; }
wait_a() { for _ in $(seq 1 ${2:-30}); do ascreen | grep -cF -- "$1" >/dev/null && return 0; sleep 0.2; done; return 1; }
gone_a() { for _ in $(seq 1 30); do ascreen | grep -cF -- "$1" >/dev/null || return 0; sleep 0.2; done; return 1; }
akey() { tm send-keys -t work:acc "$@"; sleep 0.4; }
state() { { cat "$T/mail/grants"; ls "$T/mail/intros"; } 2>/dev/null | md5sum; }
wait_a 'C O N T R O L' >/dev/null
check "MESSAGES shows each waiting one, and the approved ones as a count" "wait_a 'waiting for [G]rant access live-root@far.invalid→dev' && wait_a 'waiting for [G]rant access cx@far.invalid→dev-root@near' && wait_a '✓ 1 approved · [G] to see'"
check "the bar offers [G]rant access" "wait_a '[G]rant access'"
before=$(state)
akey g
check "G opens ACCESS: WAITING, then APPROVED with the time left" "wait_a 'ACCESS' && wait_a 'WAITING' && wait_a 'APPROVED' && wait_a 'ann@far.invalid → bob@near.invalid · 2' && wait_a 'm left'"
check "each waiting one as FROM → TO, and no declined one" "ascreen | grep -qF '1  live-root@far.invalid → dev-root@near.invalid' && ascreen | grep -qF '2  cx@far.invalid' && ! ascreen | grep -qF 'cat@far.invalid'"
check "the headings aren't choices" "! ascreen | grep -qE '[0-9] (WAITING|APPROVED)'"
akey Escape
check "Esc closes it, nothing changed" "gone_a 'APPROVED' && [[ \$(state) == '$before' ]]"
akey i
check "I, the key it had before, still opens it" "wait_a 'ACCESS' && wait_a 'WAITING'"
akey 1
check "a waiting one shows its words, and Approve or Deny" "wait_a 'may I ask dev-root about the failing build?' && wait_a '1  Approve' && wait_a '2  Deny' && ! ascreen | grep -cF 'restarted' >/dev/null"
akey Escape; gone_a '2  Deny' >/dev/null
# Its agent restarted since asking (another session in that pane now): the window says so.
printf 'live-root s-new\ncx %s\n' $ib >"$T/mail/links/far.invalid/sessions"
akey g; wait_a 'WAITING' >/dev/null; akey 1
check "one whose agent restarted since asking says so" "wait_a 'live-root has restarted since asking' && wait_a '1  Approve'"
printf 'live-root %s\ncx %s\n' $ia $ib >"$T/mail/links/far.invalid/sessions"
akey Escape
check "Esc there closes it too, nothing changed" "gone_a '2  Deny' && [[ \$(state) == '$before' ]] && [[ ! -e $T/popup.log ]]"
echo wrong >"$T/popup.code"
akey g; wait_a 'WAITING' >/dev/null; akey 1; wait_a '1  Approve' >/dev/null; akey 1
check "Approve asks for the code in a popup; a wrong one approves nothing" "wait_a \"not approved: the code didn't match, so it's still waiting\" && grep -q '^display-popup ' $T/popup.log && [[ \$(state) == '$before' ]]"
echo right >"$T/popup.code"
akey g; wait_a 'WAITING' >/dev/null; akey 1; wait_a '1  Approve' >/dev/null; akey 1
check "the code typed back approves it" "wait_a 'allowed live-root@far.invalid to talk with dev-root@near.invalid' && [[ ! -e $T/mail/intros/$ia ]] && grep -q '^allow s:$ia@far.invalid s:to$ia@near.invalid live-root@far.invalid dev-root@near.invalid [0-9]*\$' $T/mail/grants"
akey g; wait_a 'WAITING' >/dev/null; akey 1; wait_a '2  Deny' >/dev/null; akey 2
check "Deny declines it" "wait_a 'declined cx@far.invalid to dev-root@near.invalid' && [[ ! -e $T/mail/intros/$ib ]] && grep -q '^deny s:$ib@far.invalid ' $T/mail/grants"
check "with nothing waiting, MESSAGES has no waiting line" "gone_a 'waiting for [G]rant access' && wait_a '✓ 2 approved'"
before=$(state)
akey g; wait_a 'APPROVED' >/dev/null
check "with nothing waiting, ACCESS lists only APPROVED" "! ascreen | grep -qF 'WAITING' && ascreen | grep -qF '1  ann@far.invalid → bob@near.invalid'"
akey 1
check "an approved one offers Refresh or Cancel" "wait_a '1  Refresh' && wait_a '2  Cancel'"
akey Escape
check "Esc there changes nothing" "gone_a '2  Cancel' && [[ \$(state) == '$before' ]]"
echo wrong >"$T/popup.code"; : >"$T/popup.log"
akey g; wait_a 'APPROVED' >/dev/null; akey 1; wait_a '1  Refresh' >/dev/null; akey 1
check "Refresh asks for the code in the same popup; a wrong one is turned away" "wait_a \"not refreshed: the code didn't match\" 60 && grep -q '^display-popup ' $T/popup.log"
check "and refreshes nothing" "[[ \$(state) == '$before' ]]"
echo right >"$T/popup.code"
start=$(date +%s)
akey g; wait_a 'APPROVED' >/dev/null; akey 1; wait_a '1  Refresh' >/dev/null; akey 1
check "Refresh restarts its day" "wait_a 'refreshed: ann@far.invalid → bob@near.invalid · 24h left' && awk -v s=$start '\$4 == \"ann@far.invalid\" && \$6 >= s {f = 1} END {exit !f}' $T/mail/grants"
check "and logs it" "grep -q ' refresh s:a1@far.invalid s:b1@near.invalid ' $T/mail/grants.log"
akey g; wait_a 'APPROVED' >/dev/null; akey 1; wait_a '2  Cancel' >/dev/null; akey 2
check "Cancel takes it away" "wait_a 'cancelled: ann@far.invalid → bob@near.invalid' && ! grep -q 'ann@far.invalid' $T/mail/grants && grep -q 'live-root@far.invalid' $T/mail/grants"
rm -f "$T/mail/grants"
check "with nothing left, the bar has no [G]rant access" "gone_a '[G]rant access' && gone_a ' approved'"
akey g
check "and G says there's nothing" "wait_a 'nothing waiting or approved'"
akey q
tm kill-window -t work:acc 2>/dev/null
rm -rf "$T/mail/intros" "$T/mail/grants"* "$T/popup.log"
echo "questions"
# A stand-in agent (a copy of bash named codex) asking a question the way Claude Code draws
# one. Every key it reads is logged to OUT.keys; the answer it got goes to OUT.
mkdir -p "$T/bin" && cp "$(command -v bash)" "$T/bin/codex"
cat >"$T/ask.sh" <<'ASK'
# A stand-in agent asking a question, as Claude Code draws one: history above, a rule, the
# question and its choices. Every key it reads goes to OUT.keys; the answer to OUT.
out=$1 sel=1 n=6 typed=""
opts=("Yes" "No" "Maybe" "Later" "Type something." "Chat about this")
stty -icanon -echo
show() {
	clear
	for i in $(seq 1 30); do echo "history line $i"; done
	# Claude Code's real layout: a rule, the header and question, choices 1-5, ANOTHER rule
	# before the last choice, then the footer. (A rule inside the dialog broke the old view.)
	echo; printf '─%.0s' {1..50}; echo
	echo " ☐ Cleanup"; echo; echo " Bash command:   rm -rf build"; echo " Do you want to proceed?"; echo
	for i in 1 2 3 4 5 6; do
		((i == 6)) && { printf '─%.0s' {1..50}; echo; }
		label=${opts[i-1]}
		((i == 5)) && [[ -n $typed ]] && label=$typed # typing on the free-text choice fills it in
		if ((i == sel)); then echo " ❯ $i. $label"; else echo "   $i. $label"; fi
		((i < 5)) && echo "      what choosing ${opts[i-1]} does"
	done
	echo; echo " Enter to select · ↑/↓ to navigate · Esc to cancel"
}
while :; do
	show
	IFS= read -rsn1 k
	if [[ $k == $'\e' ]]; then IFS= read -rsn2 -t 0.2 r; k+=$r; fi
	printf '%q\n' "$k" >>"$out.keys"
	case $k in
	$'\e[A') ((sel > 1)) && ((sel--)) ;;
	$'\e[B') ((sel < n)) && ((sel++)) ;;
	"") break ;;
	$'\x7f' | $'\b') ((sel == 5)) && typed=${typed%?} ;;
	*) ((sel == 5)) && [[ $k != $'\e'* ]] && typed+=$k ;; # as in Claude Code: type right in the dialog
	esac
done
if ((sel == 5)); then
	printf 'custom:%s\n' "$typed" >"$out"
else
	printf 'picked:%s\n' "$sel" >"$out"
fi
clear; echo "all done"; sleep 300
ASK
tm new-window -d -t work -n asker "$T/bin/codex $T/ask.sh $T/ans1"
tm set-option -p -t work:asker @agent asker
tm new-window -d -t work -n qpanel "env REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX REVIVE_PANEL_REFRESH=1 bash $ROOT/scripts/panel.sh"
qscreen() { tm capture-pane -p -t work:qpanel; }
wait_q() { for _ in $(seq 1 ${2:-40}); do qscreen | grep -qF -- "$1" && return 0; sleep 0.2; done; return 1; }
qhas() { local n; n=$(qscreen | grep -cF -- "$1"); ((n > 0)); }
qbox() { qscreen | sed -n '/QUESTION · /,/ART · \|MESSAGES/p'; }
wait_q 'asker'
for _ in $(seq 1 20); do qscreen | grep -q '▶ asker' && break; tm send-keys -t work:qpanel Down; sleep 0.3; done
check "a pane asking a question shows its question in place of the peek" "wait_q 'QUESTION · asker'"
# All of it, as in Claude Code: the question, the first and the last choice, and the footer,
# with the rule between choices 5 and 6 not cutting anything off.
for want in 'Do you want to proceed?' 'rm -rf build' '❯ 1. Yes' '5. Type something.' '6. Chat about this' 'Enter to select'; do
	check "the question view shows: $want" "(( \$(qbox | grep -cF -- '$want') > 0 ))"
done
lastrow() { tm capture-pane -p -t work:asker | tail -1 | sed 's/[[:space:]]*$//'; }
boxrow() { qbox | grep '│' | tail -1 | sed 's/^║[^│]*│ \{0,1\}//; s/[[:space:]]*[▲▼░▓]\{0,1\}║$//; s/[[:space:]]*$//'; }
# The question stands out: bold yellow; the highlighted choice on a band; the rest plainer.
qcolor() { tm capture-pane -e -p -t work:qpanel | grep -F -- "$1" | head -1; }
check "the question itself is bold yellow" "[[ \$(qcolor 'Do you want to proceed?') == *'93'* ]]"
check "the highlighted choice sits on a band" "[[ \$(qcolor '❯ 1. Yes') == *'44'* ]]"
check "the other choices don't" "[[ \$(qcolor '2. No') != *'44'* ]]"
check "its last row is the agent's last row" "[[ \"\$(boxrow)\" == \"\$(lastrow)\" ]]"
check "Enter offers to answer it, J the chat" "qhas '[Enter] answer' && qhas '[J] open the chat' && ! qhas '[Tab] answer'"
check "the messages step aside while a question shows" "! qhas 'MESSAGES'"
# Tab moves the focus to the question's window, but doesn't answer it: Enter does.
tm send-keys -t work:qpanel Tab
check "Tab only moves the focus to the question, sending nothing" "wait_q '▸ QUESTION · asker' && ! qhas 'ANSWERING' && [[ ! -s $T/ans1.keys ]]"
tm send-keys -t work:qpanel Enter
check "Enter answers, and Tab is the way back" "wait_q 'ANSWERING asker' && qhas 'Tab back to the panes'"
tm send-keys -t work:qpanel Tab
check "and Tab brings it back to the panes, sending nothing" "wait_q 'Enter returns to the question' && ! qhas 'ANSWERING' && [[ ! -s $T/ans1.keys ]]"
tm send-keys -t work:qpanel Enter
check "Enter starts answering, and says how to leave" "wait_q 'ANSWERING asker' && qhas 'Ctrl-] leaves'"
tm send-keys -t work:qpanel C-]
check "Ctrl-] leaves without sending anything" "wait_q 'left the question' && ! qhas 'ANSWERING' && [[ ! -s $T/ans1.keys && ! -e $T/ans1 ]]"
tm send-keys -t work:qpanel Enter; wait_q 'ANSWERING asker' >/dev/null
tm send-keys -t work:qpanel Down
check "keys reach the question, and the view follows it" "wait_q '❯ 2. No' 15"
tm send-keys -t work:qpanel Enter
check "Enter answers it (Down, Enter: choice 2)" "for _ in \$(seq 1 25); do [[ -s $T/ans1 ]] && break; sleep 0.2; done; [[ \$(cat $T/ans1 2>/dev/null) == picked:2 ]]"
check "answered, the view goes back to the peek" "wait_q 'PEEK · asker' 30 && ! qhas 'ANSWERING' && ! qhas 'QUESTION'"
# A custom answer: the free-text choice, typed text with spaces and an accent, a typo fixed.
tm respawn-pane -k -t work:asker "$T/bin/codex $T/ask.sh $T/ans2"
wait_q 'QUESTION · asker' 30 >/dev/null
tm send-keys -t work:qpanel Enter; wait_q 'ANSWERING asker' >/dev/null
for _ in 1 2 3 4; do tm send-keys -t work:qpanel Down; sleep 0.4; done
wait_q '❯ 5. Type something.' 15 >/dev/null
tm send-keys -t work:qpanel -l 'my custom answér'; sleep 0.3
tm send-keys -t work:qpanel -l 'X'; sleep 0.3
check "typed text shows in the question as it's typed" "wait_q 'my custom answérX' 15"
tm send-keys -t work:qpanel BSpace; sleep 0.3
tm send-keys -t work:qpanel Enter
check "a custom answer arrives exactly as typed" "for _ in \$(seq 1 25); do [[ -s $T/ans2 ]] && break; sleep 0.2; done; [[ \$(cat $T/ans2 2>/dev/null) == 'custom:my custom answér' ]]"
tm send-keys -t work:qpanel q
tm kill-window -t work:asker
# Answering looks at the agent's screen again right after a key is sent, not 0.3 s later; and a
# digit that starts typed text is sent on its own (in a menu it picks a choice). Seen by the
# tmux that logs what it's asked.
tm new-window -d -t work -n asker2 "$T/bin/codex $T/ask.sh $T/ans4"
tm set-option -p -t work:asker2 @agent asker2
tm new-window -d -t work -n qshim "env PATH=$T/shim:$PATH REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX REVIVE_PANEL_REFRESH=1 bash $ROOT/scripts/panel.sh"
sscreen() { tm capture-pane -p -t work:qshim; }
wait_s() { for _ in $(seq 1 ${2:-40}); do sscreen | grep -qF -- "$1" && return 0; sleep 0.2; done; return 1; }
wait_s 'asker2' >/dev/null
for _ in $(seq 1 20); do sscreen | grep -q '▶ asker2' && break; tm send-keys -t work:qshim Down; sleep 0.3; done
wait_s 'QUESTION · asker2' >/dev/null
tm send-keys -t work:qshim Enter; wait_s 'ANSWERING asker2' >/dev/null
for _ in 1 2 3 4; do tm send-keys -t work:qshim Down; sleep 0.4; done
wait_s '❯ 5. Type something.' 15 >/dev/null; sleep 0.5
caps() { grep -c "capture-pane -p -t $(tm display -p -t work:asker2 '#{pane_id}')\$" "$T/shim.log"; }
c0=$(caps)
tm send-keys -t work:qshim -l 'x'; sleep 0.45
c1=$(caps)
check "after a key, the agent's screen is looked at every few dozen ms ($((c1 - c0)) looks in 0.45 s)" "(( c1 - c0 >= 6 ))"
check "and the typed key shows" "wait_s '❯ 5. x' 10"
tm send-keys -t work:qshim -l '2xyz'; sleep 0.5
sends() { grep -c -- "send-keys -t $(tm display -p -t work:asker2 '#{pane_id}') -l -- $1\$" "$T/shim.log"; }
check "a digit typed with text after it is sent on its own" "(( \$(sends 2) == 1 && \$(sends xyz) == 1 ))"
tm send-keys -t work:qshim Enter
check "and the answer arrives whole" "for _ in \$(seq 1 25); do [[ -s $T/ans4 ]] && break; sleep 0.2; done; [[ \$(cat $T/ans4 2>/dev/null) == 'custom:x2xyz' ]]"
tm send-keys -t work:qshim q
tm kill-window -t work:asker2

echo "ssh links"
# Which host an ssh command line connects to, as agent-say link takes it.
dest() { bash -c 'source <(sed -n "/^ssh_dest() {/,/^}/p" "$1"); ssh_dest "$2"' _ "$ROOT/scripts/panel.sh" "$1"; }
check "ssh host" "[[ \$(dest 'ssh devbox') == devbox ]]"
check "ssh with options, a user and a command" "[[ \$(dest 'ssh -i /k -p 22 me@h.example ls -la') == h.example ]]"
check "ssh:// with a port" "[[ \$(dest 'ssh ssh://me@h2.example:2222') == h2.example ]]"
check "a jump host is skipped for the destination" "[[ \$(dest '/usr/bin/ssh -J jump h3 uptime') == h3 ]]"
check "not ssh, or a host that can't be one" "[[ -z \$(dest 'sshd -D') && -z \$(dest 'ssh \"bad;host\"') ]]"

# ssh outside tmux (another terminal) is found too; ssh that other tools start for themselves isn't.
bash -c 'exec -a "ssh me@outside.example" sleep 60' & o1=$!
bash -c 'exec -a "ssh -o BatchMode=yes linkpoll.example agent-say _sync x" sleep 60' & o2=$!
bash -c 'exec -a "ssh -o SendEnv=GIT_PROTOCOL git@gitfetch.example git-upload-pack x" sleep 60' & o3=$!
bash -c 'exec -a "ssh -x -oForwardAgent=no -s sftpcopy.example sftp" sleep 60' & o4=$!
sleep 0.5
out=$(frame 140 45)
check "an ssh session outside tmux is offered for linking" "grep -q 'outside.example · ssh in' <<<\"\$out\""
check "agent-say's own, git's and sftp's ssh aren't" "! grep -qE 'linkpoll.example|gitfetch.example|sftpcopy.example' <<<\"\$out\""
kill $o1 $o2 $o3 $o4 2>/dev/null; wait $o1 $o2 $o3 $o4 2>/dev/null
# Someone else's process saying "ssh evil.example" (even with a parent named kitty) is not
# yours to link. A ps that adds one of theirs and one of yours, as if they were running.
mkdir -p "$T/fakeps"
{
	printf '#!/bin/bash\n%q "$@"; st=$?\n' "$(command -v ps)"
	printf '[[ $* == *uid=* ]] && printf "%%s\\n" " 999990 1 %s 0 0.0 kitty" " 999991 999990 %s 0 0.0 ssh evil.example" " 999992 1 %s 0 0.0 ssh mine.example"\n' $((UID + 4242)) $((UID + 4242)) "$UID"
	printf 'exit $st\n'
} >"$T/fakeps/ps"
chmod +x "$T/fakeps/ps"
out=$(tm run-shell "PATH=$T/fakeps:\$PATH REVIVE_PANEL_PEEK=0 COLUMNS=140 LINES=45 REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX bash $ROOT/scripts/panel.sh --once" | plain)
check "only your own ssh outside tmux is offered, not another user's" "grep -c 'mine.example · ssh in' <<<\"\$out\" >/dev/null && ! grep -c 'evil.example' <<<\"\$out\" >/dev/null"

tm new-window -d -t work -n sshpanel "env REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX AGENT_SAY_SSH=false REVIVE_PANEL_REFRESH=1 bash $ROOT/scripts/panel.sh"
sshscreen() { tm capture-pane -p -t work:sshpanel; }
wait_ssh() { for _ in $(seq 1 40); do sshscreen | grep -qF -- "$1" && return 0; sleep 0.2; done; return 1; }
wait_ssh 'C O N T R O L'
# A pane connecting somewhere: a process whose command line is an ssh one.
tm new-window -d -t work -n remote "bash -c 'exec -a \"ssh -p 2222 me@devbox.example\" sleep 300'"
check "a new ssh connection is announced" "wait_ssh 'new ssh: devbox.example · L links it'"
check "and offered for linking" "wait_ssh 'devbox.example · ssh in'"
tm send-keys -t work:sshpanel u
check "U with nothing linked says so" "wait_ssh 'nothing is linked'"
tm send-keys -t work:sshpanel l; sleep 0.7
check "L opens a popup listing the ssh hosts" "wait_ssh 'LINK AGENTS ON' && sshscreen | grep -q 'devbox.example  · ssh in' && sshscreen | grep -q 'other host'"
check "the popup says how to close it" "sshscreen | grep -q 'Esc closes'"
# Every row of the popup has its right edge in the same column as the top-right corner.
popup_square() {
	sshscreen | awk '
		index($0, "LINK AGENTS ON") && !l { l = index($0, "╔"); r = index($0, "╗"); top = NR; next }
		l && NR > top && !done {
			c = substr($0, r, 1)
			if (c != "║" && c != "╝") bad = 1
			if (c == "╝") done = 1
		}
		END { exit !(l && r > l && done && !bad) }'
}
check "the popup's edges line up on every row" "popup_square"
tm send-keys -t work:sshpanel Escape
check "Esc closes the popup" "wait_ssh 'link cancelled' && ! sshscreen | grep -q 'LINK AGENTS ON'"
# Linking a host ssh has no key for asks you to confirm one first, as ssh would; No (the first
# choice, so a bare Enter) links nothing.
ssh-keygen -q -t ed25519 -N '' -C '' -f "$T/hostkey"
: >"$T/known_hosts"
fp=$(ssh-keygen -lf "$T/hostkey.pub" | awk '{print $2}')
tm send-keys -t work:sshpanel l; sleep 0.7; tm send-keys -t work:sshpanel Enter
check "picking a host ssh has no key for asks yes or no, and says none was found" "wait_ssh 'LINK devbox.example?' && wait_ssh 'no key found (not in known_hosts' && wait_ssh \"No, don't link\" && wait_ssh 'Yes, link devbox.example'"
tm send-keys -t work:sshpanel Enter
check "No links nothing" "wait_ssh 'link cancelled' && [[ ! -e $(dirname "$AGENT_SAY_MAILBOX")/links/devbox.example ]]"
# A host ssh already trusts (its key in known_hosts): only yes or no, Yes first, its key shown.
printf 'devbox.example %s\n' "$(cut -d' ' -f1,2 "$T/hostkey.pub")" >"$T/known_hosts"
tm send-keys -t work:sshpanel l; sleep 0.7; tm send-keys -t work:sshpanel Enter
check "a host ssh already trusts: one yes or no, with the key from your known_hosts, no list of keys" "wait_ssh 'LINK devbox.example?' && wait_ssh 'key from your known_hosts: $fp (ED25519)' && sshscreen | grep -q '1 *Yes, link devbox.example' && ! sshscreen | grep -q 'its key is'"
tm send-keys -t work:sshpanel Enter
check "Enter links it, and shows what happened" "wait_ssh \"couldn't run agent-say on devbox.example\""
# Pretend the link is up, then take it down with U.
st=$(dirname "$AGENT_SAY_MAILBOX"); mkdir -p "$st/links/devbox.example"; touch "$st/links/devbox.example/on"
# What the link lets that computer do shows beside it.
touch "$st/links/devbox.example/read-only"; printf 'me\nyou\n' >"$st/links/devbox.example/allow"
check "LINKS marks a read-only link and its allowlist" "wait_ssh 'devbox.example · read-only · only me,you'"
check "a linked host is no longer offered" "for _ in \$(seq 1 20); do sshscreen | grep -q 'devbox.example · ssh in' || break; sleep 0.2; done; ! sshscreen | grep -q 'devbox.example · ssh in'"
tm send-keys -t work:sshpanel u; sleep 0.7
check "U opens a popup listing the links" "wait_ssh 'UNLINK' && sshscreen | grep -q 'devbox.example  ·'"
tm send-keys -t work:sshpanel 1
check "a number picks from the list and unlinks it" "wait_ssh 'unlinked devbox.example' && [[ ! -e $st/links/devbox.example ]]"
# A link that fails (here: stopped on another key than the one linked). L offers to link it again:
# it unlinks, then links with the key ssh uses now, after one yes or no. Or unlinks it.
sk=$st/links/devbox.example
ssh-keygen -q -t ed25519 -N '' -C '' -f "$T/oldkey"
broken() { mkdir -p "$sk"; touch "$sk/on"; echo "$(ssh-keygen -lf "$T/oldkey.pub" | awk '{print $2}') (ED25519)" >"$sk/fingerprint"
	echo "stopped: host key changed since you linked it. Press L to link it again" >"$sk/error"; }
broken
check "LINKS says the failing link's error plainly" "wait_ssh 'devbox.example stopped: host key changed'"
tm send-keys -t work:sshpanel l; sleep 0.7
check "L offers the failing link, to link again" "wait_ssh 'LINK AGENTS ON' && sshscreen | grep -q 'devbox.example  · stopped: host key changed.* · link again'"
tm send-keys -t work:sshpanel Enter
check "picking it asks: leave it, link it again, or unlink it" "wait_ssh 'LINK devbox.example AGAIN?' && wait_ssh 'No, leave it as it is' && wait_ssh 'Yes, link devbox.example again' && wait_ssh 'Unlink devbox.example'"
tm send-keys -t work:sshpanel 2
# It was linked to another key: that is said, with No first, though known_hosts has this one.
check "linking again shows the key ssh uses now, warns it isn't the one linked before, No first" "wait_ssh \"WARNING: devbox.example's HOST KEY CHANGED\" && wait_ssh 'key from your known_hosts: $fp (ED25519)' && sshscreen | grep -q \"1 *No, don't link devbox.example\""
tm send-keys -t work:sshpanel 2
check "and yes unlinks the old one and links again (its old key and error gone)" "wait_ssh \"couldn't run agent-say on devbox.example\" && [[ ! -e $sk/on && ! -e $sk/error && ! -e $sk/fingerprint ]]"
broken
tm send-keys -t work:sshpanel l; sleep 0.7; wait_ssh 'link again' >/dev/null; tm send-keys -t work:sshpanel Enter
wait_ssh 'LINK devbox.example AGAIN?' >/dev/null; tm send-keys -t work:sshpanel 1
check "No there leaves it as it was" "wait_ssh 'link cancelled' && [[ -e $sk/on && -s $sk/error ]]"
tm send-keys -t work:sshpanel l; sleep 0.7; wait_ssh 'link again' >/dev/null; tm send-keys -t work:sshpanel Enter
wait_ssh 'LINK devbox.example AGAIN?' >/dev/null; tm send-keys -t work:sshpanel 3
check "Unlink there unlinks the failing link" "wait_ssh 'unlinked devbox.example' && [[ ! -e $sk ]]"
broken
tm send-keys -t work:sshpanel u; sleep 0.7; wait_ssh 'UNLINK' >/dev/null; tm send-keys -t work:sshpanel 1
check "and so does U" "wait_ssh 'unlinked devbox.example' && [[ ! -e $sk ]]"
# A link stopped on a failure (paused): LINKS says why, and L tries it once more, with its key.
mkdir -p "$sk"; touch "$sk/on" "$sk/paused"; echo "$fp (ED25519)" >"$sk/fingerprint"
echo "can't reach (connection timed out) · L to try again" >"$sk/error"
check "LINKS shows a stopped link's reason, and that L tries again" "wait_ssh \"devbox.example can't reach (connection timed out)\""
tm send-keys -t work:sshpanel l; sleep 0.7
check "L offers it, to try again" "wait_ssh 'LINK AGENTS ON' && sshscreen | grep -q \"devbox.example  · can't reach (connection timed out) · try again\""
tm send-keys -t work:sshpanel Enter
check "picking it tries once, with no questions, and says why it failed again" "wait_ssh 'devbox.example: ssh to devbox.example failed' && ! sshscreen | grep -q 'AGAIN?' && [[ -e $sk/paused && -e $sk/on ]] && grep -q 'L to try again' $sk/error"
tm send-keys -t work:sshpanel u; sleep 0.7; wait_ssh 'UNLINK' >/dev/null; tm send-keys -t work:sshpanel 1
check "U unlinks it" "wait_ssh 'unlinked devbox.example' && [[ ! -e $sk ]]"
tm send-keys -t work:sshpanel q
tm kill-window -t work:remote 2>/dev/null
# live.example: ssh keeps no key for it (known_hosts /dev/null, keys not checked), but an ssh
# connection of yours is open to it, through which its key file reads. That key is shown, as
# one seen for the first time, with No first.
{
	printf '#!/bin/bash\nT=%q\n' "$T"
	cat <<'EOF'
case " $* " in
*" -G "*) printf '%s\n' 'hostname live.example' 'userknownhostsfile /dev/null' 'stricthostkeychecking false'; exit 0 ;;
*" -O check "*) echo 'Master running (pid=4242)' >&2; exit 0 ;;
*" ControlMaster=no "*) cat "$T/hostkey.pub"; exit 0 ;;
esac
exit 255
EOF
} >"$T/livessh"
chmod +x "$T/livessh"
tm new-window -d -t work -n livepanel "env REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX AGENT_SAY_SSH=$T/livessh REVIVE_PANEL_REFRESH=1 bash $ROOT/scripts/panel.sh"
tm new-window -d -t work -n liveremote "bash -c 'exec -a \"ssh live.example\" sleep 300'"
lvs() { tm capture-pane -p -t work:livepanel; }
wait_lv() { for _ in $(seq 1 40); do lvs | grep -qF -- "$1" && return 0; sleep 0.2; done; return 1; }
wait_lv 'live.example · ssh in' >/dev/null
tm send-keys -t work:livepanel l; wait_lv 'LINK AGENTS ON' >/dev/null
n=$(lvs | grep -o '[1-9] *live.example  · ssh in' | head -c 1)
tm send-keys -t work:livepanel "$n"
check "a key read through your open ssh connection: shown, said to be seen for the first time, No first" "wait_lv 'key read through your open ssh connection: $fp (ED25519)' && wait_lv 'First time we see this key' && lvs | grep -q \"1 *No, don't link live.example\""
tm send-keys -t work:livepanel Enter
check "and Enter links nothing" "wait_lv 'link cancelled' && [[ ! -e $st/links/live.example ]]"
tm send-keys -t work:livepanel q
tm kill-window -t work:liveremote 2>/dev/null

echo "other computers"
# A second private tmux server stands in for a linked computer, and a fake ssh runs the
# panel there: whatever command it's given, it answers as that computer's panel would.
tmux -L "revive-panel-remote-$$" -f /dev/null new-session -d -s far -x 120 -y 30 "bash --norc --noprofile"
tmux -L "revive-panel-remote-$$" -f /dev/null split-window -d -t far "top -d 5"
tmux -L "revive-panel-remote-$$" -f /dev/null set-option -p -t far:0.1 @agent far-top
tmux -L "revive-panel-remote-$$" -f /dev/null set-option -p -t far:0.0 @agent far-sh
tmux -L "revive-panel-remote-$$" -f /dev/null send-keys -t far:0.0 'echo far-marker-$((6 * 7))' Enter
rsock=$(tmux -L "revive-panel-remote-$$" -f /dev/null display -p '#{socket_path}')
# agent-say there: in ~/.local/bin of a home of its own, with a tmux that reaches that server.
mkdir -p "$T/rhome/.local/bin" "$T/rbin"
ln -s "$ROOT/bin/agent-say" "$T/rhome/.local/bin/agent-say"
printf '#!/bin/sh\nexec %q -S %q -f /dev/null "$@"\n' "$(command -v tmux)" "$rsock" >"$T/rbin/tmux"
chmod +x "$T/rbin/tmux"
# The remote command is the last argument; only the two panel commands are answered, and the
# peek's id and count go through as plain arguments, never through a shell. agent-say name is
# run by a shell, as sshd would run it.
{
	printf '#!/bin/bash\nunset TMUX TMUX_PANE\nexport HOME=%q REVIVE_SOCKET=%q REVIVE_DIR=%q REVIVE_VERSION_FILE=%q CLAUDE_CODE_TMPDIR=%q\npanel=%q T=%q\n' "$T/rhome" "$rsock" "$T/remote-data" "$T/remote-version" "$T/rtmp" "$ROOT/scripts/panel.sh" "$T"
	cat <<'EOF'
cmd=${!#}
if [[ $cmd =~ \ panel\ --rows$ ]]; then exec bash "$panel" --rows
elif [[ $cmd == *' tmux-revive update '* && -e $T/update.fail ]]; then printf '\e[1;34m==>\e[0m downloading\n\e[1;31mxx\e[0m  download failed: https://github.com/odysseyalive/tmux-revive/releases/download/v9.9.9/%s.tar.gz\n' "$(printf 'x%.0s' {1..150})"; exit 1
elif [[ $cmd == *' tmux-revive update '* ]]; then printf '%s' "$cmd" >"$T/update.cmd"; printf 'downloading\ntmux-revive 9.9.9 installed\n\n'; exit 0
elif [[ $cmd == AGENT_SAY_PANE=* ]]; then printf '%s' "$cmd" >"$T/name.cmd"; HOME=$T/rhome PATH=$T/rbin:$PATH AGENT_SAY_MAILBOX=$T/rstate/mailbox.md exec bash -c "$cmd"
elif [[ $cmd =~ \ panel\ --peek\ \'([^\']*)\'\ ([^ ]*)$ ]]; then exec bash "$panel" --peek "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
elif [[ $cmd =~ \ panel\ --show\ \'([^\']*)\'$ ]]; then printf '%s' "$cmd" >"$T/show.cmd"; exec bash "$panel" --show "${BASH_REMATCH[1]}"
elif [[ $cmd =~ \ panel\ --keys\ \'([^\']*)\'((\ [^ ]+)+)$ ]]; then read -ra k <<<"${BASH_REMATCH[2]}"; exec bash "$panel" --keys "${BASH_REMATCH[1]}" "${k[@]}"
fi
exit 127
EOF
} >"$T/fakessh"
# An older tmux-revive over there: rows, but no --peek.
printf '#!/bin/bash\n[[ ${!#} == *--rows ]] && exec %q "$@"\nexit 1\n' "$T/fakessh" >"$T/oldssh"
printf '#!/bin/sh\nexit 255\n' >"$T/deadssh"
printf '#!/bin/sh\nexit 1\n' >"$T/norowssh" # reached, but its tmux-revive has no --rows
chmod +x "$T/fakessh" "$T/oldssh" "$T/deadssh" "$T/norowssh"
st=$(dirname "$AGENT_SAY_MAILBOX")
mkdir -p "$st/links/far.example"; touch "$st/links/far.example/on"; printf 'far-top\nfar-two\n' >"$st/links/far.example/names"
far() { tm run-shell "AGENT_SAY_SSH=$1 COLUMNS=140 LINES=50 REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX bash $ROOT/scripts/panel.sh --once" | plain; }
out=$(far "$T/fakessh")
check "panes are grouped by computer" "grep -q 'this computer' <<<\"\$out\" && grep -q 'FAR.EXAMPLE · linked' <<<\"\$out\""
check "a linked computer's panes show with their state" "grep -q 'far-top .*top *▸ running' <<<\"\$out\""
check "numbered by their window.pane over there" "grep -q '\[0\.1\] *far-top ' <<<\"\$out\" && grep -q '\[0\.0\] *far-sh ' <<<\"\$out\""
check "and its shell panes too" "grep -A3 'FAR.EXAMPLE' <<<\"\$out\" | grep -q 'bash *· shell'"
check "the whole frame still fits" "[[ \$(awk '{w[length]=1} END{for (k in w) n++; print n}' <<<\"\$out\") == 1 ]]"
# With a key confirmed for the link, the panel's calls are bound to it, as agent-say's are; a key
# revoked since the pin was built is refused on the very next call.
printf '#!/bin/bash\n[[ $1 == -G || $1 == -O ]] || echo "$*" >>%q\nexec %q "$@"\n' "$T/far.calls" "$T/fakessh" >"$T/logssh"; chmod +x "$T/logssh"
printf 'far.example %s\n' "$(cut -d' ' -f1,2 "$T/hostkey.pub")" >>"$T/known_hosts"
echo "$fp (ED25519)" >"$st/links/far.example/fingerprint"
rm -f "$st/panel/far.example.rows"*
out=$(far "$T/logssh")
check "with a key confirmed, the panel's calls to it are bound to the link's pin" "grep -q 'far-top' <<<\"\$out\" && grep -q 'StrictHostKeyChecking=yes -o UserKnownHostsFile=$st/links/far.example/pin ' $T/far.calls && [[ -s $st/links/far.example/pin ]]"
printf '@revoked * %s\n' "$(cut -d' ' -f1,2 "$T/hostkey.pub")" >>"$T/known_hosts"
: >"$T/far.calls"; rm -f "$st/panel/far.example.rows"*
far "$T/logssh" >/dev/null
check "a key revoked after the pin was built: the next call refuses, and the pin is gone" "[[ ! -s $T/far.calls && ! -e $st/links/far.example/pin ]]"
grep -v '^@revoked \|^far.example ' "$T/known_hosts" >"$T/known_hosts.new" && mv "$T/known_hosts.new" "$T/known_hosts"
rm -f "$st/links/far.example/fingerprint" "$st/links/far.example/pin"* "$st/panel/far.example.rows"*
# Agents there show the state that computer's own panel gives them. Stand-ins for Claude Code
# (copies of bash named claude): one working with no session record to go by (an older Claude
# Code, or a record kept where that panel can't see it), one whose record says busy, one
# whose record says idle, and one asking a question.
far_tm() { tmux -L "revive-panel-remote-$$" -f /dev/null "$@"; }
mkdir -p "$T/rhome/.claude/sessions"
far_cl() { # far_cl NAME COMMAND [STATUS]: a stand-in there, with a record saying STATUS if given
	far_tm new-window -d -t far -n "$1" "$T/bin/claude $2"
	far_tm set-option -p -t "far:$1" @agent "$1"
	[[ -n ${3:-} ]] || return 0
	sleep 0.3
	local p
	p=$(far_tm display -p -t "far:$1" '#{pane_pid}')
	printf '{"pid":%s,"sessionId":"s-%s","status":"%s"}\n' "$p" "$1" "$3" >"$T/rhome/.claude/sessions/$p.json"
}
far_cl cl-none "-c 'printf \"* Working (esc to interrupt)\\n\"; sleep 300; :'"
far_cl cl-busy "-c 'printf \"> \"; sleep 300; :'" busy
far_cl cl-idle "-c 'printf \"* Working (esc to interrupt)\\n\"; sleep 300; :'" idle
far_cl cl-ask "$T/ask.sh $T/ans-far-cl"
# Agents a Claude Code started work on in the background: their output files, under its temp
# folder's claude-UID/<folder>/<sessionId>/tasks/, written to just now (an agent's is a link to
# its transcript) or minutes ago. Idle with one fresh is working (and takes input); with only
# stale ones, waiting, unless a command it started still runs under it; busy is still working,
# and a question on screen still wins.
far_cl cl-bg "-c 'printf \"> \"; sleep 300; :'" idle
far_cl cl-stale "-c 'printf \"> \"; sleep 300; :'" idle
far_cl cl-snap "-c '$T/bin/mcp/mcp-server 300 & bash -c \"source $T/shell-snapshots/snapshot-x.sh; sleep 300; :\" & printf \"> \"; wait'" idle
far_cl cl-bgask "$T/ask.sh $T/ans-far-cl2" idle
bgtasks() { # bgtasks SESSION fresh|stale
	local d=$T/rtmp/claude-$UID/-w/$1/tasks
	mkdir -p "$d" "$T/rtmp/sub"
	: >"$d/old.output"; touch -d '-10 minutes' "$d/old.output"
	[[ $2 == fresh ]] || return 0
	: >"$T/rtmp/sub/$1.jsonl"; ln -sf "$T/rtmp/sub/$1.jsonl" "$d/agent.output"; touch -h -d '-10 minutes' "$d/agent.output"
}
for s in cl-bg cl-busy cl-bgask; do bgtasks "s-$s" fresh; done
bgtasks s-cl-stale stale
bgtasks s-cl-snap stale
sleep 0.5
rows=$(CLAUDE_CODE_TMPDIR=$T/rtmp REVIVE_SOCKET=$rsock REVIVE_DIR=$T/remote-data HOME=$T/rhome bash "$ROOT/scripts/panel.sh" --rows)
check "--rows there: an agent working with no record to go by is working, from its screen" "grep -q $'\x1fcl-none\x1fclaude\x1fworking\x1f' <<<\"\$rows\""
check "--rows there: a record that says busy is working, even with no sign on screen" "grep -q $'\x1fcl-busy\x1fclaude\x1fworking\x1f' <<<\"\$rows\""
check "--rows there: a record that says idle is waiting, whatever the screen says" "grep -q $'\x1fcl-idle\x1fclaude\x1fwaiting\x1f' <<<\"\$rows\""
check "--rows there: a question on screen is asking" "grep -q $'\x1fcl-ask\x1fclaude\x1fasking\x1f' <<<\"\$rows\""
check "--rows there: idle with agents working in the background is a line before a row saying working (as an older panel shows it)" "grep -B1 $'\x1fcl-bg\x1fclaude\x1fworking\x1f' <<<\"\$rows\" | grep -q '^#agents %[0-9]*\$'"
check "--rows there: idle with a command still running under it, its output stale, likewise" "grep -B1 $'\x1fcl-snap\x1fclaude\x1fworking\x1f' <<<\"\$rows\" | grep -q '^#agents %[0-9]*\$'"
check "--rows there: with only stale output, no such line" "! grep -B1 $'\x1fcl-stale\x1f' <<<\"\$rows\" | grep -q '^#agents' && grep -q $'\x1fcl-stale\x1fclaude\x1fwaiting\x1f' <<<\"\$rows\""
check "--rows there: busy, or asking, with fresh output: no such line" "[[ \$(grep -c '^#agents' <<<\"\$rows\") == 2 ]] && grep -q $'\x1fcl-bgask\x1fclaude\x1fasking\x1f' <<<\"\$rows\""
out=$(far "$T/fakessh")
check "here: a linked agent working with no record shows WORKING" "grep -q 'cl-none .*claude *. WORKING' <<<\"\$out\""
check "here: one whose record says busy shows WORKING" "grep -q 'cl-busy .*claude *. WORKING' <<<\"\$out\""
check "here: one whose record says idle shows WAITING ON YOU" "grep -q 'cl-idle .*claude *◆ WAITING ON YOU' <<<\"\$out\""
check "here: one asking a question shows NEEDS ANSWER" "grep -q 'cl-ask .*claude *? NEEDS ANSWER' <<<\"\$out\""
check "here: idle with agents working in the background shows WORKING" "grep -q 'cl-bg .*claude *. WORKING ' <<<\"\$out\""
check "here: idle with a command still running under it shows WORKING" "grep -q 'cl-snap .*claude *. WORKING ' <<<\"\$out\""
check "here: idle with only stale output shows WAITING ON YOU" "grep -q 'cl-stale .*claude *◆ WAITING ON YOU' <<<\"\$out\""
check "here: a question still wins over agents in the background" "grep -q 'cl-bgask .*claude *? NEEDS ANSWER' <<<\"\$out\""
check "and the frame is still exactly 140 wide" "[[ \$(awk '{w[length]=1} END{for (k in w) printf \"%s \", k}' <<<\"\$out\") == '140 ' ]]"
for w in cl-bg cl-stale cl-snap cl-bgask; do far_tm kill-window -t far:$w; done # room for the rows below
# Their CPU and context left, drawn as this computer's own are. A busy pane there; a Claude
# Code whose record names its transcript; and three with no record to be found, as over a
# link's ssh: one whose config folder is in its own environment and whose session is the
# folder it holds open under the temporary claude-UID/, one found from its working folder
# alone, and one sharing that folder with another, which can't be told apart and shows a dash.
turn() { printf '{"type":"assistant","message":{"model":"claude-haiku-4-5","usage":{"input_tokens":%s}}}\n' "$1"; }
far_tm new-window -d -t far -n spin "bash --norc -c 'while :; do :; done'"
far_tm set-option -p -t far:spin @agent far-spin
mkdir -p "$T/rhome/.claude/projects/-w"
turn 100000 >"$T/rhome/.claude/projects/-w/s-cl-idle.jsonl" # cl-idle's record names s-cl-idle: 50% left
fsid=0b1e2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d
mkdir -p "$T/tmpc/claude-1000/-x/$fsid/tasks" "$T/rcfg/projects/-x" "$T/cwd-one" "$T/cwd-two"
: >"$T/tmpc/claude-1000/-x/$fsid/tasks/t"
turn 150000 >"$T/rcfg/projects/-x/$fsid.jsonl" # 25% left
far_tm new-window -d -t far -n cl-fd -e CLAUDE_CONFIG_DIR="$T/rcfg" "$T/bin/claude -c 'exec 3<$T/tmpc/claude-1000/-x/$fsid/tasks/t; sleep 300; :'"
far_tm set-option -p -t far:cl-fd @agent cl-fd
far_tm new-window -d -t far -n cl-cwd -c "$T/cwd-one" "$T/bin/claude -c 'sleep 300; :'"
far_tm set-option -p -t far:cl-cwd @agent cl-cwd
far_tm new-window -d -t far -n cl-two -c "$T/cwd-two" "$T/bin/claude -c 'sleep 300; :'"
far_tm new-window -d -t far -n cl-two2 -c "$T/cwd-two" "$T/bin/claude -c 'sleep 300; :'"
far_tm set-option -p -t far:cl-two @agent cl-two
sleep 1.1 # transcripts written after their Claude Code started
slug=${T//[^A-Za-z0-9]/-}
mkdir -p "$T/rhome/.claude/projects/$slug-cwd-one" "$T/rhome/.claude/projects/$slug-cwd-two"
turn 20000 >"$T/rhome/.claude/projects/$slug-cwd-one/a.jsonl" # 90% left
turn 20000 >"$T/rhome/.claude/projects/$slug-cwd-two/b.jsonl"
rm -f "$st/panel/ticks" # no earlier ask to measure from: two looks
rows=$(REVIVE_SOCKET=$rsock REVIVE_DIR=$T/remote-data HOME=$T/rhome bash "$ROOT/scripts/panel.sh" --rows)
rcpu() { awk -F $'\x1f' -v n="$2" '$3 == n {print $8}' <<<"$1"; }
rctx() { grep -B1 $'\x1f'"$2"$'\x1f' <<<"$1" | sed -n 's/^#ctx %[0-9]* \([0-9]*\)$/\1/p'; }
check "--rows there: a busy pane's CPU, from two looks ($(rcpu "$rows" far-spin)%)" "(( \$(rcpu \"\$rows\" far-spin) >= 10 ))"
check "--rows there: context left from a record's transcript ($(rctx "$rows" cl-idle))" "[[ \$(rctx \"\$rows\" cl-idle) == 50 ]]"
check "--rows there: with no record, from its config folder and the session folder it holds open ($(rctx "$rows" cl-fd))" "[[ \$(rctx \"\$rows\" cl-fd) == 25 ]]"
check "--rows there: with no record, from its working folder ($(rctx "$rows" cl-cwd))" "[[ \$(rctx \"\$rows\" cl-cwd) == 90 ]]"
check "--rows there: not from a working folder another Claude Code shares" "[[ -z \$(rctx \"\$rows\" cl-two) ]] && grep -q $'\x1fcl-two\x1f' <<<\"\$rows\""
# A Claude Code that reports its own context left from its hook (claude-hook.sh ctx, through
# agent-say _ctx): taken even when its record and transcript can't be read, as when the panel
# there runs as another user than the agent. A report gone stale is not.
mkdir -p "$T/hooktr" "$T/cwd-hook"
turn 60000 >"$T/hooktr/s-hook.jsonl" # 70% left
printf '#!/bin/bash\nprintf %s %q | bash %q ctx\ntouch %q\n' "'%s\n'" \
	"{\"session_id\":\"s-hook\",\"transcript_path\":\"$T/hooktr/s-hook.jsonl\",\"hook_event_name\":\"Stop\"}" \
	"$ROOT/scripts/claude-hook.sh" "$T/ctxhook-ran" >"$T/hook-run.sh"
far_tm new-window -d -t far -n cl-hook -c "$T/cwd-hook" "$T/bin/claude -c 'sleep 0.3; bash $T/hook-run.sh; sleep 300; :'"
far_tm set-option -p -t far:cl-hook @agent cl-hook
hpane=$(far_tm display -p -t far:cl-hook '#{pane_id}') hpid=$(far_tm display -p -t far:cl-hook '#{pane_pid}')
for _ in $(seq 50); do [[ -f $T/ctxhook-ran ]] && break; sleep 0.1; done
cf=$AGENT_SAY_MAILBOX
cf=${cf%/*}/ctx/${hpane#%}
check "the ctx hook keeps its pane's context left through agent-say ($(cat "$cf" 2>/dev/null))" "read -r a b c d e <$cf && [[ \$a == $hpane && \$b == s-hook && \$c == 70 && \$e == $hpid ]] && (( \$(date +%s) - d < 60 ))"
chmod 000 "$T/hooktr/s-hook.jsonl"
rows=$(REVIVE_SOCKET=$rsock REVIVE_DIR=$T/remote-data HOME=$T/rhome bash "$ROOT/scripts/panel.sh" --rows)
check "--rows there: context left as its hook reported it, with its transcript unreadable ($(rctx "$rows" cl-hook))" "[[ \$(rctx \"\$rows\" cl-hook) == 70 ]]"
printf '%s s-hook 70 %s %s\n' "$hpane" $(($(date +%s) - 3600)) "$hpid" >"$cf"
rows=$(REVIVE_SOCKET=$rsock REVIVE_DIR=$T/remote-data HOME=$T/rhome bash "$ROOT/scripts/panel.sh" --rows)
check "--rows there: a report an hour old is not used" "[[ -z \$(rctx \"\$rows\" cl-hook) ]] && grep -q $'\x1fcl-hook\x1f' <<<\"\$rows\""
printf '%s s-hook 70 %s 1\n' "$hpane" "$(date +%s)" >"$cf"
rows=$(REVIVE_SOCKET=$rsock REVIVE_DIR=$T/remote-data HOME=$T/rhome bash "$ROOT/scripts/panel.sh" --rows)
check "--rows there: nor one from another process than the pane's Claude Code" "[[ -z \$(rctx \"\$rows\" cl-hook) ]]"
far_tm kill-window -t far:cl-hook
# Whose each pane is: --rows says, on a line before its row, the user its agent (or the program
# in it) runs as, and whether that user has tmux-revive there: owner (the tmux owner's own), the
# version that user's install recorded (agent-say _user-installed), or -. Other users stand in as
# a ps that gives a pane's process another uid (uid 0, and one named deploy by a getent).
mkdir -p "$T/uidps"
: >"$T/uidmap"
{
	printf '#!/bin/bash\n[[ $* == *uid=* ]] || exec %q "$@"\n' "$(command -v ps)"
	printf '%q "$@" | awk -v m=%q '\''BEGIN { while ((getline l < m) > 0) { split(l, a, " "); u[a[1]] = a[2] } } ($1 in u) { $3 = u[$1] } 1'\''\n' "$(command -v ps)" "$T/uidmap"
} >"$T/uidps/ps"
DEPLOY_UID=$((UID + 4243))
printf '#!/bin/sh\n[ "$1" = passwd ] && [ "$2" = %s ] && { echo "deploy:x:%s:%s::/home/deploy:/bin/sh"; exit 0; }\nexec %q "$@"\n' \
	"$DEPLOY_UID" "$DEPLOY_UID" "$DEPLOY_UID" "$(command -v getent)" >"$T/uidps/getent"
chmod +x "$T/uidps/ps" "$T/uidps/getent"
far_tm new-window -d -t far -n as-root "sleep 300"
far_tm new-window -d -t far -n as-deploy "sleep 300"
far_tm set-option -p -t far:as-root @agent as-root
far_tm set-option -p -t far:as-deploy @agent as-deploy
printf '%s 0\n%s %s\n' "$(far_tm display -p -t far:as-root '#{pane_pid}')" "$(far_tm display -p -t far:as-deploy '#{pane_pid}')" "$DEPLOY_UID" >"$T/uidmap"
rid() { far_tm display -p -t "far:$1" '#{pane_id}'; }
mkdir -p "$T/rst2/agent-say/users"
echo 1.0.9 >"$T/rst2/agent-say/users/deploy"
urows() { PATH="$T/uidps:$PATH" AGENT_SAY_MAILBOX=$T/rst2/agent-say/mailbox.md REVIVE_SOCKET=$rsock REVIVE_DIR=$T/remote-data HOME=$T/rhome bash "$ROOT/scripts/panel.sh" --rows; }
rows=$(urows)
check "--rows says whose tmux it is" "grep -qx '#owner $(id -un)' <<<\"\$rows\""
check "--rows: a pane running as another user with no tmux-revive: its user, and -" "grep -qx \"#user $(rid as-root) root -\" <<<\"\$rows\""
check "--rows: one whose user recorded a version: that version" "grep -qx \"#user $(rid as-deploy) deploy 1.0.9\" <<<\"\$rows\""
check "--rows: the owner's own: owner" "grep -qx \"#user $(rid 0.1) $(id -un) owner\" <<<\"\$rows\""
check "--rows: the line comes before its row, and a context line still sits right above the row" "grep -A1 \"^#user $(rid as-deploy) \" <<<\"\$rows\" | grep -q $'\x1fas-deploy\x1f'"
far_tm kill-window -t far:as-root; far_tm kill-window -t far:as-deploy
# Asked again a little later, it measures since the last ask, kept over there, in one look.
sleep 1.2
rows=$(REVIVE_SOCKET=$rsock REVIVE_DIR=$T/remote-data HOME=$T/rhome bash "$ROOT/scripts/panel.sh" --rows)
check "--rows asked again measures since the last ask, kept there ($(rcpu "$rows" far-spin)%)" "(( \$(rcpu \"\$rows\" far-spin) >= 10 )) && grep -q '^%[0-9]*:[0-9]* [0-9]*\$' $st/panel/ticks && [[ \$(stat -c %a $st/panel/ticks) == 600 ]]"
rm -f "$st/panel/far.example.rows"
for c in 80 120 160 200; do
	out=$(tm run-shell "AGENT_SAY_SSH=$T/fakessh COLUMNS=$c LINES=90 REVIVE_PANEL_PEEK=0 REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX bash $ROOT/scripts/panel.sh --once" | plain)
	check "at $c columns a linked busy pane shows its CPU, a linked Claude Code its CTX LEFT, rows exactly $c wide" "grep 'far-spin ' <<<\"\$out\" | grep -q '[░▒▓█][░▒▓█·]* *[1-9][0-9]*%' && grep -q 'cl-idle .*M  [█▓▒░·]\{5\}  50% ║\$' <<<\"\$out\" && grep -q 'cl-fd .* 25% ║\$' <<<\"\$out\" && grep -q 'cl-cwd .* 90% ║\$' <<<\"\$out\" && grep -q 'cl-two .*·····    – ║\$' <<<\"\$out\" && [[ \$(awk '{w[length]=1} END{for (k in w) printf \"%s \", k}' <<<\"\$out\") == '$c ' ]]"
done
# Rows in the older form (no version, no context lines) still draw their CPU and memory.
printf '%%5\x1f0:1.0\x1fold-cl\x1fclaude\x1fwaiting\x1fw\x1fmain\x1f42\x1f2097152\x1f1\n' >"$T/oldrows"
printf '#!/bin/sh\ncat %s\n' "$T/oldrows" >"$T/oldrowssh"; chmod +x "$T/oldrowssh"
rm -f "$st/panel/far.example.rows"
out=$(tm run-shell "AGENT_SAY_SSH=$T/oldrowssh COLUMNS=120 LINES=50 REVIVE_PANEL_PEEK=0 REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX bash $ROOT/scripts/panel.sh --once" | plain)
check "an older row still draws: its CPU meter, percent and memory, a dash for context" "grep -q 'old-cl .*██░··   42%    2.0G  ·····    – ║\$' <<<\"\$out\""
rm -f "$st/panel/far.example.rows"
for w in cl-none cl-busy cl-idle cl-ask spin cl-fd cl-cwd cl-two cl-two2; do far_tm kill-window -t far:$w; done
rm -rf "$T/rhome/.claude" "$st/panel/far.example.rows"*
farsel() { tm run-shell "AGENT_SAY_SSH=$1 REVIVE_PANEL_SEL=$2 COLUMNS=140 LINES=50 REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX bash $ROOT/scripts/panel.sh --once"; }
peekbox() { sed -n '/PEEK · /,/ART · \|MESSAGES/p'; }
out=$(farsel "$T/fakessh" far-sh@far.example | plain)
check "the peek at a linked computer's pane shows its screen" "peekbox <<<\"\$out\" | grep -q '^║ *│ far-marker-42'"
rm -f "$st/panel/far.example.peek-"*
out=$(farsel "$T/oldssh" far-sh@far.example | plain)
check "a tmux-revive there too old to peek says so" "grep -q 'far-sh' <<<\"\$out\" && peekbox <<<\"\$out\" | grep -qF 'on far.example: no peek (update tmux-revive there)'"
rm -f "$st/panel/far.example.rows"
out=$(farsel "$T/deadssh" far-top@far.example | plain)
check "and an unreachable one has no peek either" "peekbox <<<\"\$out\" | grep -qF 'on far.example: no peek'"
# Versions: a linked computer's rows say its version, which its owner's panes show in VER, in the
# warn colour when it's older than this one's. The headings say no version.
echo 1.1.0 >"$T/remote-version"; echo 1.2.0 >"$T/local-version"
farv() { rm -f "$st/panel/far.example.rows"*; tm run-shell "AGENT_SAY_SSH=$1 REVIVE_VERSION_FILE=$T/${2:-local-version} COLUMNS=140 LINES=50 REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX bash $ROOT/scripts/panel.sh --once"; }
me=$(id -un)
raw=$(farv "$T/fakessh") out=$(plain <<<"$raw")
check "a linked computer's panes show their user, and its version in VER, older in the warn colour" "grep -c 'far-top *$me *1\.1\.0 *top' <<<\"\$out\" >/dev/null && grep -cF $'\\e[93m1.1.0' <<<\"\$raw\" >/dev/null"
check "this computer's own panes show this one's version" "grep -c ' $me *1\.2\.0 *bash' <<<\"\$out\" >/dev/null"
check "the headings say no version" "grep -c 'FAR.EXAMPLE · linked · [0-9]* panes\{0,1\} *║' <<<\"\$out\" >/dev/null && grep -c 'this computer *║' <<<\"\$out\" >/dev/null && ! grep -c 'out of date' <<<\"\$out\" >/dev/null"
echo 1.2.0 >"$T/remote-version"
raw=$(farv "$T/fakessh")
check "the same version isn't in the warn colour" "grep -cF $'\\e[90m1.2.0' <<<\"\$raw\" >/dev/null && ! grep -cF $'\\e[93m1.2.0' <<<\"\$raw\" >/dev/null"
echo 1.1.0 >"$T/remote-version"
raw=$(farv "$T/fakessh" no-such-file)
check "with this computer's version unknown, none is in the warn colour" "grep -cF $'\\e[90m1.1.0' <<<\"\$raw\" >/dev/null && ! grep -cF $'\\e[93m1.1.0' <<<\"\$raw\" >/dev/null"
# One from before users (1.2.4): rows with no #owner or #user lines. Its rows show [V] in VER, in
# the warn colour, with no user, and V on them updates it over ssh, asked first, as before.
printf '#!/bin/bash\nif [[ ${!#} == *--rows ]]; then %q "$@" | grep -v "^#owner \\|^#user "; else exec %q "$@"; fi\n' "$T/fakessh" "$T/fakessh" >"$T/preuserssh"
chmod +x "$T/preuserssh"
rm -f "$st/panel/far.example.rows"*
raw=$(tm run-shell "AGENT_SAY_SSH=$T/preuserssh REVIVE_PANEL_SEL=far-top@far.example REVIVE_VERSION_FILE=$T/local-version COLUMNS=140 LINES=50 REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX bash $ROOT/scripts/panel.sh --once") out=$(plain <<<"$raw")
check "a linked computer from before users: its rows show [V] in VER, in the warn colour, no user" "grep -c '▶ far-top  *\[V\] *top' <<<\"\$out\" >/dev/null && grep -c 'far-sh  *\[V\] *bash' <<<\"\$out\" >/dev/null && grep -cF $'\\e[93m[V]' <<<\"\$raw\" >/dev/null"
check "and the bar offers V: update" "grep -F 'ump' <<<\"\$out\" | grep -cF '[V] update' >/dev/null"
check "this computer's own panes don't show [V]" "grep -c ' $me *1\.2\.0 *bash' <<<\"\$out\" >/dev/null"
rm -f "$st/panel/far.example.rows"* "$T/update.cmd"
tm new-window -d -t work -n oldpanel "env AGENT_SAY_SSH=$T/preuserssh REVIVE_VERSION_FILE=$T/local-version REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX REVIVE_PANEL_REFRESH=1 bash $ROOT/scripts/panel.sh"
oscreen() { tm capture-pane -p -t work:oldpanel; }
wait_o() { for _ in $(seq 1 ${2:-60}); do oscreen | grep -q -- "$1" && return 0; sleep 0.25; done; return 1; }
wait_o 'far-top  *\[V\]' >/dev/null
for _ in $(seq 1 20); do oscreen | grep -q '▶ far-top' && break; tm send-keys -t work:oldpanel Down; sleep 0.4; done
tm send-keys -t work:oldpanel v
check "V there asks to update that computer over ssh" "wait_o 'Update tmux-revive on far.example?' && oscreen | grep -qF 'Yes, update it over ssh'"
tm send-keys -t work:oldpanel Escape
check "and Esc updates nothing" "wait_o 'update cancelled' && [[ ! -e $T/update.cmd ]]"
tm send-keys -t work:oldpanel q
tm kill-window -t work:oldpanel 2>/dev/null
rm -f "$st/panel/far.example.rows"*
out=$(farv "$T/norowssh" | plain)
check "one that answers no rows shows its names, with no user or version" "grep -c 'FAR.EXAMPLE · linked · [0-9]* panes\{0,1\} *║' <<<\"\$out\" >/dev/null && grep -c 'far-two *◌ linked' <<<\"\$out\" >/dev/null"
# Its pane names alone carry no window.pane: those rows are counted instead.
check "and its names-only rows are numbered by their count" "grep -q '║ \[[1-9]\] *far-two ' <<<\"\$out\" && ! grep -q '\[[0-9]*\.[0-9]*\] *far-two' <<<\"\$out\""
out=$(farv "$T/deadssh" | plain)
check "one that can't be reached still has its heading" "grep -c 'FAR.EXAMPLE · linked · [0-9]* panes\{0,1\} *║' <<<\"\$out\" >/dev/null"
printf '#version 1.2.3;touch %s/pwn\n' "$T" >"$T/badver"; head -c 2000 /dev/zero | tr '\0' 9 >>"$T/badver"; printf '\n' >>"$T/badver"
printf '#!/bin/bash\n%q "$@" | sed 1d | cat %q -\n' "$T/fakessh" "$T/badver" >"$T/badverssh"; chmod +x "$T/badverssh"
out=$(farv "$T/badverssh" | plain)
check "a version line that isn't one is ignored" "grep -c 'far-top *$me  *top' <<<\"\$out\" >/dev/null && ! grep -c '1.2.3' <<<\"\$out\" >/dev/null && [[ ! -e $T/pwn ]]"
check "--rows says its version first" "[[ \$(REVIVE_SOCKET=$rsock REVIVE_DIR=$T/remote-data REVIVE_VERSION_FILE=$T/remote-version bash $ROOT/scripts/panel.sh --rows | head -n 1) == '#version 1.1.0' ]]"
# A panel from before versions reads those rows as before: the version line is skipped.
mkdir -p "$T/old/scripts"
if git -C "$ROOT" show d621bda:scripts/panel.sh >"$T/old/scripts/panel.sh" 2>/dev/null; then
	cp "$ROOT/scripts/common.sh" "$T/old/scripts/"
	rm -f "$st/panel/far.example.rows"*
	out=$(tm run-shell "AGENT_SAY_SSH=$T/fakessh COLUMNS=140 LINES=50 REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX bash $T/old/scripts/panel.sh --once" | plain)
	check "an older panel skips the version line" "grep -c 'far-top .*top *▸ running' <<<\"\$out\" >/dev/null && ! grep -c 'version' <<<\"\$out\" >/dev/null"
fi
rm -f "$st/panel/far.example.rows"*
# --peek itself: only a pane id and a line count get through.
rpanel() { REVIVE_SOCKET=$rsock REVIVE_DIR=$T/remote-data bash "$ROOT/scripts/panel.sh" "$@" 2>/dev/null; }
# Counted straight from the pipe: a $( ) would strip the blank bottom rows being checked for.
farid=$(tmux -L revive-panel-remote-$$ -f /dev/null display -p -t far:0.0 '#{pane_id}')
farh=$(tmux -L revive-panel-remote-$$ -f /dev/null display -p -t far:0.0 '#{pane_height}')
check "--peek prints the pane's bottom rows, blank ones too ($farh rows)" "(( \$(rpanel --peek $farid 60 | grep -c '^far-marker-42$') == 1 )) && [[ \$(rpanel --peek $farid 60 | wc -l) -eq $farh ]]"
check "--peek turns away a bad pane id or count" "! rpanel --peek 'far:0.0' 3 && ! rpanel --peek '%0;touch $T/pwn' 3 && ! rpanel --peek %0 0 && ! rpanel --peek %0 61 && ! rpanel --peek %0 && [[ ! -e $T/pwn ]]"
check "--peek at a pane that isn't there fails" "! rpanel --peek %999 5"
rm -f "$st/panel/far.example.rows"
out=$(far "$T/deadssh")
check "if it can't be asked, the link's names show instead" "grep -q 'far-two *◌ linked' <<<\"\$out\""
# Hostile rows from the other side: control characters, a bad state, junk lines.
printf '%%9\x1f0:0.0\x1fevil\x1fapp\x1b]52;c;aGk=\x07\x1fpwned\x1ffold\x1fmain\x1f99999\x1fabc\x1f1\nnot a row at all\n' >"$T/hostile"
printf '#!/bin/sh\ncat %s\n' "$T/hostile" >"$T/hostilessh"; chmod +x "$T/hostilessh"
rm -f "$st/panel/far.example.rows"
out=$(tm run-shell "AGENT_SAY_SSH=$T/hostilessh COLUMNS=140 LINES=50 REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX bash $ROOT/scripts/panel.sh --once")
check "rows from the other side are cleaned and checked" "grep -q 'evil' <<<\"\$out\" && ! grep -q \$'\\e]52' <<<\"\$out\" && ! grep -q 'pwned' <<<\"\$out\" && ! grep -q 'not a row' <<<\"\$out\""
# A hostile peek: escape sequences, a huge line, far too many lines.
python3 - "$T/hostilepeek" <<'PY2'
import sys
with open(sys.argv[1], 'w', encoding='utf-8') as f:
    for n in range(500):
        f.write(f'line-{n}\n')
    f.write('top\x1b]52;c;aGk=\x07\x1b[2Jbottom\x9b31m-end\n')
    f.write('W' * 200000 + '\n')
PY2
printf '#!/bin/bash\nif [[ ${!#} == *--peek* ]]; then cat %q; else cat %q; fi\n' "$T/hostilepeek" "$T/hostile" >"$T/hostilessh"
rm -f "$st/panel/far.example.rows" "$st/panel/far.example.peek-"*
out=$(farsel "$T/hostilessh" evil@far.example)
bare=$(sed 's/\x1b\[[0-9;]*m//g' <<<"$out")
check "a peek from the other side is cleaned" "peekbox <<<\"\$bare\" | grep -qF 'top]52;c;aGk=[2Jbottom31m-end' && ! LC_ALL=C grep -q '[[:cntrl:]]' <<<\"\$bare\""
check "and capped: no line past the frame, no more lines than the box" "[[ \$(awk '{w[length]=1} END{for (k in w) n++; print n}' <<<\"\$bare\") == 1 ]] && (( \$(peekbox <<<\"\$bare\" | grep -c '│') <= 60 )) && [[ \$(stat -c %s $st/panel/far.example.peek-9 2>/dev/null || echo 0) -le 65536 ]]"
# Rows from over there are capped in bytes too: an endless line can't freeze the panel.
printf '#!/bin/bash\nif [[ ${!#} == *--rows* ]]; then head -c 20000000 /dev/zero | tr "\\\\0" A; echo; cat %q; fi\n' "$T/hostile" >"$T/hugessh"; chmod +x "$T/hugessh"
rm -f "$st/panel/far.example.rows"
s0=$SECONDS
out=$(tm run-shell "AGENT_SAY_SSH=$T/hugessh COLUMNS=140 LINES=50 REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX bash $ROOT/scripts/panel.sh --once" | plain)
check "a huge reply from over there is cut to 256 KB ($((SECONDS - s0)) s)" "grep -c 'FAR.EXAMPLE' <<<\"\$out\" >/dev/null && (( \$(stat -c %s $st/panel/far.example.rows) <= 262144 && SECONDS - s0 < 30 ))"
# What's kept from other computers is yours alone; old screens go; no temporary files stay.
touch -d '-2 minutes' "$st/panel/far.example.peek-77"
farsel "$T/fakessh" far-sh@far.example >/dev/null
check "the cache is private (700, files 600)" "[[ \$(stat -c %a $st/panel) == 700 && \$(stat -c %a $st/panel/far.example.rows) == 600 ]] && ! find $st/panel -type f -perm /077 | grep -c . >/dev/null"
check "a peek over a minute old is deleted" "[[ ! -e $st/panel/far.example.peek-77 ]]"
check "and no temporary files are left" "! ls $st/panel | grep -cvE '^(ticks|far\\.example\\.(rows(\\.old)?|peek-[0-9]+(\\.fail)?))$' >/dev/null"
# Bidi overrides and zero-width characters from over there are stripped like controls.
printf '%%9\x1fbidi\xe2\x80\xae0:0\x1fzw\xe2\x80\x8bname\x1fapp\x1fwaiting\x1ffo\xe2\x81\xa6ld\x1fmain\x1f1\x1f1\x1f1\n' >"$T/bidirows"
printf '#!/bin/sh\ncat %s\n' "$T/bidirows" >"$T/bidissh"; chmod +x "$T/bidissh"
rm -f "$st/panel/far.example.rows"
out=$(tm run-shell "AGENT_SAY_SSH=$T/bidissh COLUMNS=140 LINES=50 REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX bash $ROOT/scripts/panel.sh --once" | plain)
check "bidi overrides and zero-width characters from over there are stripped" "grep -c 'zwname' <<<\"\$out\" >/dev/null && ! grep -c \$'\\u202e\\|\\u200b\\|\\u2066' <<<\"\$out\" >/dev/null"
# Live: select a pane on the linked computer, and the keys that can't act on it fade.
rm -f "$st/panel/far.example.rows"
tm new-window -d -t work -n farpanel "env AGENT_SAY_SSH=$T/fakessh REVIVE_VERSION_FILE=$T/local-version REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX REVIVE_PANEL_REFRESH=1 bash $ROOT/scripts/panel.sh"
farscreen() { tm capture-pane -p -t work:farpanel; }
for _ in $(seq 1 60); do farscreen | grep -q 'far-top' && break; sleep 0.25; done
for _ in $(seq 1 20); do farscreen | grep -q '▶ far-top' && break; tm send-keys -t work:farpanel Down; sleep 0.4; done
bar() { tm capture-pane -e -p -t work:farpanel | grep -F 'ump' | tail -1; }
grey=$'\e[90m[J]ump' lit=$'\e[93mS'
check "its peek tracks that pane's screen live" "for _ in \$(seq 1 30); do farscreen | sed -n '/PEEK · far-top/,\$p' | grep -c 'Mem' >/dev/null && break; sleep 0.3; done; farscreen | sed -n '/PEEK · far-top/,\$p' | grep -c 'Mem' >/dev/null"
# A linked computer's agent waiting for access: its row there says so, by NAME@HOST.
gid=0123456789abcdef0123456789abcdef
mkdir -p "$st/intros/$gid" && echo far-top@far.example >"$st/intros/$gid/from" && echo y@near >"$st/intros/$gid/to"
check "a linked computer's agent waiting for access shows [G]RANT ACCESS" "for _ in \$(seq 1 30); do farscreen | grep -cE 'far-top .*⚑ \[G\]RANT ACCESS' >/dev/null && break; sleep 0.2; done; farscreen | grep -cE 'far-top .*⚑ \[G\]RANT ACCESS' >/dev/null"
rm -rf "$st/intros/$gid"
check "and goes back once the request is gone" "for _ in \$(seq 1 30); do farscreen | grep -cF 'RANT ACCESS' >/dev/null || break; sleep 0.2; done; ! farscreen | grep -cF 'RANT ACCESS' >/dev/null"
check "on a linked computer's pane, J fades and N doesn't" "farscreen | grep -q '▶ far-top' && bar | grep -qF \"\$grey\" && bar | grep -qF $'\\e[93mN' && ! bar | grep -qF $'\\e[90m[N]ame'"
check "while keys that still work stay lit" "bar | grep -qF \"\$lit\""
# V: update tmux-revive over there, once confirmed, with a fixed command.
check "on a linked computer's pane, V offers an update" "bar | grep -cF $'\\e[93mV' >/dev/null && farscreen | grep -cF '[V] update' >/dev/null"
tm send-keys -t work:farpanel v
check "V asks first" "for _ in \$(seq 1 20); do farscreen | grep -c 'Update tmux-revive on far.example?' >/dev/null && break; sleep 0.2; done; farscreen | grep -c 'Yes, update it over ssh' >/dev/null"
tm send-keys -t work:farpanel Escape
check "and Esc updates nothing" "for _ in \$(seq 1 20); do farscreen | grep -c 'update cancelled' >/dev/null && break; sleep 0.2; done; farscreen | grep -c 'update cancelled' >/dev/null && [[ ! -e $T/update.cmd ]]"
tm send-keys -t work:farpanel v; sleep 0.5; tm send-keys -t work:farpanel Enter
check "yes runs tmux-revive update there and shows how it went" "for _ in \$(seq 1 30); do farscreen | grep -c 'on far.example: tmux-revive 9.9.9 installed' >/dev/null && break; sleep 0.2; done; farscreen | grep -c 'on far.example: tmux-revive 9.9.9 installed' >/dev/null"
check "with the fixed command, nothing else" "[[ \$(cat $T/update.cmd) == 'PATH=\"\$HOME/.local/bin:\$PATH\" tmux-revive update </dev/null 2>&1' ]]"
# An update that fails there in colour: the message shows as text, without its escape codes
# or its "xx", cut to fit the bar.
touch "$T/update.fail"
tm send-keys -t work:farpanel v; sleep 0.5; tm send-keys -t work:farpanel Enter
wait_fail() { for _ in $(seq 1 30); do farscreen | grep -cF 'on far.example: update failed: download failed: https://' >/dev/null && return 0; sleep 0.2; done; return 1; }
check "a failed update there shows its message, without escape codes or its xx" \
	"wait_fail && ! tm capture-pane -e -p -t work:farpanel | grep -F 'update failed' | grep -cE $'\\e\\\\[1;31m|\\\\[1;31m|\\\\[0mxx|xx  download' >/dev/null"
check "cut to fit the bar" "farscreen | grep -F 'update failed: download failed:' | grep -cF 'xxx…' >/dev/null"
rm -f "$T/update.fail"
# N: agent-say name runs over there, for that pane, by its id.
rtop=$(tmux -L revive-panel-remote-$$ -f /dev/null display -p -t far:0.1 '#{pane_id}')
wait_far() { for _ in $(seq 1 ${2:-30}); do farscreen | grep -cF -- "$1" >/dev/null && return 0; sleep 0.2; done; return 1; }
rename_far() { tm send-keys -t work:farpanel n; wait_far 'New name for' >/dev/null; tm send-keys -t work:farpanel -l "$1"; tm send-keys -t work:farpanel Enter; }
rename_far far-renamed
check "N names a linked computer's pane there" "wait_far \"on far.example: pane $rtop is now 'far-renamed'\" && [[ \$(tmux -L revive-panel-remote-$$ -f /dev/null display -p -t $rtop '#{@agent}') == far-renamed ]]"
check "with agent-say name, for that pane, nothing else" "[[ \$(cat $T/name.cmd) == \"AGENT_SAY_PANE='$rtop' PATH=\\\"\\\$HOME/.local/bin:\\\$PATH\\\" agent-say name 'far-renamed' </dev/null 2>&1\" ]]"
check "and its row shows the new name, still selected" "wait_far '▶ far-renamed' 40"
rm -f "$T/name.cmd"
rename_far "x';touch $T/pwn;'"
check "a name that can't be one never leaves here" "wait_far \"that can't be a name\" && [[ ! -e $T/name.cmd && ! -e $T/pwn ]]"
rename_far list
check "and one agent-say there turns away is refused there" "wait_far \"on far.example: 'list' can't be a name\" && [[ \$(tmux -L revive-panel-remote-$$ -f /dev/null display -p -t $rtop '#{@agent}') == far-renamed ]]"
# Read-only holds what that computer sends here; like V, naming there from here isn't that.
touch "$st/links/far.example/read-only"
rename_far far-top
check "on a read-only link too, as V and answering are" "wait_far \"on far.example: pane $rtop is now 'far-top'\" && wait_far '▶ far-top' 40"
# J on a linked computer's pane stays faded, even with a pane here ssh'd there, and moves no
# focus: not here, not in tmux over there. It only says so.
rt() { tmux -L "revive-panel-remote-$$" -f /dev/null "$@"; }
rt new-window -d -t far -n elsewhere "bash --norc --noprofile"; rt select-window -t far:elsewhere
tm new-window -d -t work -n farssh "bash -c 'exec -a \"ssh far.example\" sleep 300'"
herewin=$(tm display -p -t work '#{window_name}')
sleep 2.5
check "with a pane here ssh'd there, J stays faded" "farscreen | grep -q '▶ far-top' && bar | grep -qF \"\$grey\""
tm send-keys -t work:farpanel j
check "J there only says so" "wait_far 'J jumps to panes on this computer only'"
check "and moves nothing, here or over there" "[[ \$(tm display -p -t work '#{window_name}') == '$herewin' && \$(rt display -p -t far '#{window_name}') == elsewhere && ! -e $T/show.cmd ]]"
rm -f "$st/links/far.example/read-only"
tm kill-window -t work:farssh; rt kill-window -t far:elsewhere
tm send-keys -t work:farpanel 0
check "back on a pane here, J lights up again" "for _ in \$(seq 1 25); do farscreen | grep -q '\[0\.0\] ▶' && ! bar | grep -qF \"\$grey\" && break; sleep 0.2; done; farscreen | grep -q '\[0\.0\] ▶' && ! bar | grep -qF \"\$grey\""
tm send-keys -t work:farpanel q
tm kill-window -t work:farpanel 2>/dev/null
# Another user's pane on a linked computer (deploy, a stand-in as above): V runs nothing over
# ssh for them. It shows the command to run in their pane there, and copies it. The owner's pane
# there keeps V's update over ssh. A sudo here that logs anything asked of it.
INSTALL_CMD=$(grep -m1 -x 'curl -fsSL https://raw.githubusercontent.com/.*/install.sh | sh' "$ROOT/README.md")
mkdir -p "$T/usudo"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>%q\nexit 1\n' "$T/usudo.log" >"$T/usudo/sudo"
chmod +x "$T/usudo/sudo"
far_tm new-window -d -t far -n as-deploy "sleep 300"
far_tm set-option -p -t far:as-deploy @agent as-deploy
printf '%s %s\n' "$(far_tm display -p -t far:as-deploy '#{pane_pid}')" "$DEPLOY_UID" >>"$T/uidmap"
rm -f "$st/panel/far.example.rows"* "$st/users/deploy" "$T/far.calls"
echo 1.1.0 >"$T/remote-version"
tm new-window -d -t work -n vpanel "env PATH=$T/uidps:$T/usudo:\$PATH AGENT_SAY_SSH=$T/logssh REVIVE_VERSION_FILE=$T/local-version REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX REVIVE_PANEL_REFRESH=1 bash $ROOT/scripts/panel.sh"
rscreen() { tm capture-pane -p -t work:vpanel; }
wait_r() { for _ in $(seq 1 ${2:-60}); do rscreen | grep -q -- "$1" && return 0; sleep 0.25; done; return 1; }
gone_r() { for _ in $(seq 1 20); do rscreen | grep -q -- "$1" || return 0; sleep 0.25; done; return 1; }
rsel() { for _ in $(seq 1 40); do rscreen | grep -q "▶ $1 " && return 0; tm send-keys -t work:vpanel Down; sleep 0.3; done; return 1; }
check "a linked computer's pane of a user without tmux-revive shows [V]" "wait_r 'as-deploy *deploy *\[V\]'"
rsel as-deploy
check "and the bar offers V: install" "rscreen | grep -qF '[V] install'"
tm send-keys -t work:vpanel v
check "V there shows the install command for that user's pane, copied" "wait_r \"Run this in deploy's pane:\" && rscreen | grep -qF -- '$INSTALL_CMD' && [[ \$(tm show-buffer) == '$INSTALL_CMD' ]]"
tm send-keys -t work:vpanel x
gone_r "Run this in deploy's pane:" >/dev/null
mkdir -p "$st/users" && echo 1.0.0 >"$st/users/deploy"
rm -f "$st/panel/far.example.rows"*
check "one with an older version there shows it (once its rows are asked for again)" "wait_r 'as-deploy *deploy *1\.0\.0' 160"
rsel as-deploy
tm send-keys -t work:vpanel v
check "and V shows tmux-revive update" "wait_r \"Run this in deploy's pane:\" && [[ \$(tm show-buffer) == 'tmux-revive update' ]]"
tm send-keys -t work:vpanel x
gone_r "Run this in deploy's pane:" >/dev/null
check "nothing went over ssh for that user: no ssh -t, no sudo there or here" "[[ -s $T/far.calls ]] && ! grep -qE -- ' -t |sudo|tmux-revive update' $T/far.calls && [[ ! -e $T/usudo.log ]]"
rsel far-top
check "on the linked computer's owner's pane, V still updates that computer as before" "rscreen | grep -qF '[V] update' && { tm send-keys -t work:vpanel v; wait_r 'Update tmux-revive on far.example?'; }"
tm send-keys -t work:vpanel Escape
tm kill-window -t work:vpanel
rm -f "$st/users/deploy"
far_tm kill-window -t far:as-deploy
# A row from the link's names alone: J stays put there too, and asks nothing over there.
printf '#!/bin/bash\nprintf "%%s\\n" "${!#}" >>%q\nexit 1\n' "$T/ssh.log" >"$T/logssh"; chmod +x "$T/logssh"
sleep 0.5; rm -f "$st/panel/far.example.rows"*
tm new-window -d -t work -n farssh "bash -c 'exec -a \"ssh far.example\" sleep 300'"
tm new-window -d -t work -n farnames "env AGENT_SAY_SSH=$T/logssh REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX REVIVE_PANEL_REFRESH=1 bash $ROOT/scripts/panel.sh"
fn() { tm capture-pane -p -t work:farnames; }
for _ in $(seq 1 60); do fn | grep -q 'far-two *◌ linked' && break; sleep 0.25; done
for _ in $(seq 1 25); do fn | grep -q '▶ far-two' && break; tm send-keys -t work:farnames Down; sleep 0.4; done
tm select-window -t work:farnames; tm send-keys -t work:farnames j
check "J on a names-only row moves nothing, and asks nothing over there" "for _ in \$(seq 1 30); do fn | grep -c 'J jumps to panes on this computer only' >/dev/null && break; sleep 0.2; done; fn | grep -c 'J jumps to panes on this computer only' >/dev/null && [[ \$(tm display -p -t work '#{window_name}') == farnames ]] && ! grep -c -- '--show' $T/ssh.log >/dev/null && [[ ! -e $T/show.cmd ]]"
tm send-keys -t work:farnames q; tm kill-window -t work:farssh

# --keys: a pane id, then key names from a short list or lit:HEX text, nothing else.
hex() { printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'; }
check "--keys types into a pane over there" "[[ \$(rpanel --keys $farid lit:\$(hex 'echo keys-$((6 * 7))') Enter) == sent ]] && for _ in \$(seq 1 20); do tmux -L revive-panel-remote-$$ -f /dev/null capture-pane -p -t $farid | grep -c '^keys-42' >/dev/null && break; sleep 0.2; done && (( \$(tmux -L revive-panel-remote-$$ -f /dev/null capture-pane -p -t $farid | grep -c '^keys-42') >= 1 ))"
far_tm new-window -d -t far -n w2 "sleep 300"; far_tm select-window -t far:0
check "--show, which an older computer's J asks for, changes nothing and fails" "! rpanel --show \$(far_tm display -p -t far:w2 '#{pane_id}') && ! rpanel --show '%0;touch $T/pwn' && [[ ! -e $T/pwn && \$(far_tm display -p -t far '#{window_index}') == 0 ]]"
far_tm kill-window -t far:w2
check "--keys turns away a bad pane id" "! rpanel --keys 'far:0.0' Enter && ! rpanel --keys '%0;touch $T/pwn' Enter && ! rpanel --keys %999 Enter && ! rpanel --keys $farid && [[ ! -e $T/pwn ]]"
check "--keys turns away keys not on its list" "! rpanel --keys $farid 'Enter;touch $T/pwn' && ! rpanel --keys $farid F1 && ! rpanel --keys $farid 'send-keys' && ! rpanel --keys $farid '\$(touch $T/pwn)' && [[ ! -e $T/pwn ]]"
check "--keys text: no control characters, bidi overrides or endless text" "! rpanel --keys $farid lit:0a && ! rpanel --keys $farid lit:\$(hex \$'a\\e[2J') && ! rpanel --keys $farid lit:c29b && ! rpanel --keys $farid lit:\$(hex \$'\\u202e') && ! rpanel --keys $farid lit:00 && ! rpanel --keys $farid lit:\$(hex \$(printf 'a%.0s' {1..65})) && ! rpanel --keys $farid lit:4"

# A question on the linked computer, answered from here over the link. Over there you're busy
# in a pane of your own (far-sh): an agent there starting to ask must not move you off it (what
# a client on that session shows), nor anything here; only the keys you send while answering go
# anywhere.
far_tm select-window -t far:0; far_tm select-pane -t far:0.0
fclient() { far_tm display -p -t far '#{window_index}.#{pane_index}'; }
fwas=$(fclient) hwas=$(tm display -p -t work '#{window_name}')
tmux -L "revive-panel-remote-$$" -f /dev/null new-window -d -t far -n ask "$T/bin/codex $T/ask.sh $T/ans3"
tmux -L "revive-panel-remote-$$" -f /dev/null set-option -p -t far:ask @agent far-ask
sleep 0.5
rm -f "$st/panel/far.example.rows" "$st/panel/"*.peek-*
tm new-window -d -t work -n farq "env AGENT_SAY_SSH=$T/fakessh REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX REVIVE_PANEL_REFRESH=1 bash $ROOT/scripts/panel.sh"
fq() { tm capture-pane -p -t work:farq; }
wait_fq() { for _ in $(seq 1 ${2:-50}); do fq | grep -qF -- "$1" && return 0; sleep 0.2; done; return 1; }
wait_fq 'far-ask' 60 >/dev/null
for _ in $(seq 1 25); do fq | grep -q '▶ far-ask' && break; tm send-keys -t work:farq Down; sleep 0.4; done
check "a linked computer's question shows here" "wait_fq 'QUESTION · far-ask' 100 && wait_fq 'Do you want to proceed?'"
check "and moves no client's focus, there or here" "[[ '$fwas' == '0.0' && \$(fclient) == '$fwas' && \$(tm display -p -t work '#{window_name}') == '$hwas' ]]"
check "its question view offers Enter, not J" "fq | grep -qF '[Enter] answer' && ! fq | grep -qF 'open the chat'"
# Its highlighted choice sits on a band here too, before answering, once Enter starts it, and
# after a key moves it over the link.
fqcolor() { tm capture-pane -e -p -t work:farq | grep -F -- "$1" | head -1; }
wait_fqband() { for _ in $(seq 1 ${2:-50}); do [[ $(fqcolor "$1") == *'44'* ]] && return 0; sleep 0.2; done; return 1; }
check "a linked computer's highlighted choice sits on a band" "wait_fqband '❯ 1. Yes'"
tm send-keys -t work:farq Enter; wait_fq 'ANSWERING far-ask' >/dev/null
check "answering it, the highlighted choice is still on its band" "wait_fqband '❯ 1. Yes'"
tm send-keys -t work:farq Down
check "and its dialog follows the keys sent over the link" "wait_fq '❯ 2. No'"
check "the band moves with the highlighted choice" "wait_fqband '❯ 2. No' && [[ \$(fqcolor '1. Yes') != *'44'* ]]"
tm send-keys -t work:farq Enter
check "and is answered from here" "for _ in \$(seq 1 40); do [[ -s $T/ans3 ]] && break; sleep 0.2; done; [[ \$(cat $T/ans3 2>/dev/null) == picked:2 ]]"
check "then its peek comes back" "wait_fq 'PEEK · far-ask' 100 && ! fq | grep -c 'ANSWERING' >/dev/null"
check "answering it moved no client's focus either" "[[ \$(fclient) == '$fwas' && \$(tm display -p -t work '#{window_name}') == '$hwas' ]]"
tm send-keys -t work:farq q; sleep 0.5
check "the panel takes the screens it fetched with it" "! ls $st/panel/ 2>/dev/null | grep -c 'peek-' >/dev/null"

echo "a server that takes a password"
# pw.example is the same far computer behind a fake ssh that refuses BatchMode until a login
# (an ssh with ControlMaster=yes, its password typed) has left a master open: the marker file.
# Other hosts go to the plain fake ssh, as before. It presents the key named in pw.presented
# and checks it as ssh would: a login with StrictHostKeyChecking=yes only against its
# UserKnownHostsFile, a BatchMode call against known_hosts. Password prompts reached are
# counted in pw.prompts.
{
	printf '#!/bin/bash\nT=%q\n' "$T"
	cat <<'EOF'
echo "$*" >>"$T/pwssh.log"
[[ " $* " == *" pw.example "* ]] || exec "$T/fakessh" "$@"
m=$T/pw.master
fp=$(ssh-keygen -lf "$(cat "$T/pw.presented")" | awk '{print $2}')
holds() { [[ -r $1 ]] && ssh-keygen -lf "$1" 2>/dev/null | awk '{print $2}' | grep -qxF "$fp"; }
case " $* " in
*" -O check "*) [[ -e $m ]]; exit ;;
*" -O exit "*) rm -f "$m"; exit 0 ;;
*" -G "*) exit 0 ;;
*" ControlMaster=yes "*)
	if [[ " $* " == *" StrictHostKeyChecking=yes "* ]]; then
		holds "$(sed -n 's/.*UserKnownHostsFile=\([^ ]*\).*/\1/p' <<<"$*")" || { echo 'Host key verification failed.' >&2; exit 255; }
	fi
	echo prompt >>"$T/pw.prompts"
	IFS= read -rsp 'pw.example password: ' pw; echo
	[[ $pw == hunter2 ]] && { touch "$m"; exit 0; }
	echo 'Permission denied, please try again.' >&2; exit 255 ;;
esac
if [[ ! -e $m ]]; then
	kh=$T/known_hosts # a link's own calls are bound to its pin instead
	[[ " $* " == *" StrictHostKeyChecking=yes "* ]] && kh=$(sed -n 's/.*UserKnownHostsFile=\([^ ]*\).*/\1/p' <<<"$*")
	holds "$kh" || { echo 'Host key verification failed.' >&2; exit 255; }
	echo 'me@pw.example: Permission denied (publickey,password).' >&2; exit 255
fi
cmd=${!#}
[[ $cmd == *' agent-say _sync '* ]] &&
	exec env -u TMUX -u TMUX_PANE HOME="$T/rhome" PATH="$T/rbin:$PATH" AGENT_SAY_MAILBOX="$T/rstate/mailbox.md" bash -c "$cmd"
exec "$T/fakessh" "$@"
EOF
} >"$T/pwssh"
chmod +x "$T/pwssh"
echo "$T/hostkey.pub" >"$T/pw.presented"
prompts() { if [[ -f $T/pw.prompts ]]; then wc -l <"$T/pw.prompts"; else echo 0; fi; }
# ssh-keyscan for pw.example answers with its real key (whoever later answers to its name).
printf '#!/bin/sh\n[ "$(eval echo \\${$#})" = pw.example ] && echo "pw.example %s"\nexit 0\n' "$(cut -d' ' -f1,2 "$T/hostkey.pub")" >"$T/pwscan"
chmod +x "$T/pwscan"
printf 'pw.example %s\n' "$(cut -d' ' -f1,2 "$T/hostkey.pub")" >>"$T/known_hosts"
pwl=$st/links/pw.example
tm new-window -d -t work -n pwpanel "env AGENT_SAY_SSH=$T/pwssh AGENT_SAY_KEYSCAN=$T/pwscan AGENT_SAY_LOGIN_RETRY=600 REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX REVIVE_PANEL_REFRESH=1 bash $ROOT/scripts/panel.sh"
tm new-window -d -t work -n pwssh "bash -c 'exec -a \"ssh pw.example\" sleep 300'"
pws() { tm capture-pane -p -t work:pwpanel; }
wait_pw() { for _ in $(seq 1 ${2:-40}); do pws | grep -qF -- "$1" && return 0; sleep 0.2; done; return 1; }
# The login window (no client is attached here to show a popup): type into ssh's prompt there.
login_typed() {
	local w=""
	for _ in $(seq 1 50); do
		w=$(tm list-windows -t work -F '#{window_id} #{window_name}' | awk '$2 == "login" && $3 == "pw.example" {print $1}')
		[[ -n $w ]] && tm capture-pane -p -t "$w" | grep -q 'pw.example password:' && break
		sleep 0.2
	done
	[[ -n $w ]] || return 1
	tm send-keys -t "$w" -l "$1"; tm send-keys -t "$w" Enter
}
wait_pw 'C O N T R O L' >/dev/null
wait_pw 'pw.example · ssh in' >/dev/null
# pw.example is in known_hosts: ssh trusts it, so L asks only yes or no, and the password goes to that key.
tm send-keys -t work:pwpanel l; wait_pw 'LINK AGENTS ON' >/dev/null; tm send-keys -t work:pwpanel Enter
wait_pw 'key from your known_hosts' >/dev/null; tm send-keys -t work:pwpanel Enter
check "L on a host that wants a password opens a login, where ssh asks for it" "login_typed hunter2"
check "and once it's typed, the link is made" "wait_pw 'linked to pw.example' 75 && [[ -e $pwl/on && -e $T/pw.master ]]"
check "the poller and the panel's calls over it ask nothing more" "wait_pw 'far-top' 75 && [[ \$(grep -c 'ControlMaster=yes' $T/pwssh.log) == 1 ]]"
check "LINKS shows it linked" "wait_pw 'pw.example · linked' 50"
rm -f "$T/pw.master" # the login dropped: a reboot over there, or the network gone a while
check "a dropped login shows as needing one" "wait_pw 'pw.example · needs login · [L]og in' 75 && wait_pw 'pw.example needs login · L to type its password'"
check "its panes too, not as unreachable" "wait_pw 'needs login · L' 50 && ! pws | grep -q 'unreachable'"
pw_tries() { grep -c 'BatchMode=yes.* pw.example ' "$T/pwssh.log"; }
n=$(pw_tries); sleep 3
check "nothing is tried over ssh meanwhile, and no login opens by itself" "[[ \$(pw_tries) == $n ]] &&[[ \$(grep -c 'ControlMaster=yes' $T/pwssh.log) == 1 ]] && ! tm list-windows -t work -F '#{window_name}' | grep -q '^login'"
tm send-keys -t work:pwpanel l; wait_pw 'needs login: type its password' >/dev/null
check "L offers it first, to log in again" "pws | grep -q '1 *pw.example  · needs login: type its password'"
tm send-keys -t work:pwpanel Enter
check "and picking it opens the login again" "login_typed hunter2"
check "after which the link picks up by itself" "wait_pw 'logged in to pw.example' 50 && for _ in \$(seq 1 50); do [[ ! -e $pwl/login ]] && break; sleep 0.2; done; [[ ! -e $pwl/login ]] && wait_pw 'pw.example · linked' 75"
check "a host with a key (far.example) never got a login" "! grep 'ControlMaster=yes' $T/pwssh.log | grep -vq ' pw.example' && [[ ! -e $st/links/far.example/login ]]"
# Another computer answers to pw.example, with a key of its own: a key problem, not a login.
ssh-keygen -q -t ed25519 -N '' -C '' -f "$T/hostkey9"
echo "$T/hostkey9.pub" >"$T/pw.presented"
p=$(prompts); rm -f "$T/pw.master"
check "a link answered by another key stops on the key error, not 'needs login'" "for _ in \$(seq 1 75); do grep -q 'host key changed' $pwl/error 2>/dev/null && break; sleep 0.2; done; grep -q 'host key changed' $pwl/error && wait_pw 'pw.example stopped' 75 && ! pws | grep -q 'pw.example · needs login' && [[ ! -e $pwl/login && \$(prompts) == $p ]]"
# A first link, pw.example not in known_hosts yet: you confirm the key ssh-keyscan shows, and
# the login then goes only to a computer holding that key.
tm send-keys -t work:pwpanel q
AGENT_SAY_SSH=$T/pwssh "$ROOT/bin/agent-say" unlink pw.example >/dev/null 2>&1
grep -v '^pw.example ' "$T/known_hosts" >"$T/known_hosts.new" && mv "$T/known_hosts.new" "$T/known_hosts"
tm kill-window -t work:pwpanel 2>/dev/null
tm new-window -d -t work -n pwpanel "env AGENT_SAY_SSH=$T/pwssh AGENT_SAY_KEYSCAN=$T/pwscan AGENT_SAY_LOGIN_RETRY=600 REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX REVIVE_PANEL_REFRESH=1 bash $ROOT/scripts/panel.sh"
login_win() { tm list-windows -t work -F '#{window_id} #{window_name}' | awk '$2 == "login" && $3 == "pw.example" {print $1}'; }
link_pw() {
	wait_pw 'pw.example · ssh in' 50 >/dev/null
	tm send-keys -t work:pwpanel l; wait_pw 'LINK AGENTS ON' >/dev/null; tm send-keys -t work:pwpanel Enter
	wait_pw 'new host: first key seen' >/dev/null; tm send-keys -t work:pwpanel 2
}
link_pw
check "with another key presented, it stops there: no login opens, nothing is asked or linked" "wait_pw \"pw.example's host key isn't the one you confirmed; not linked\" 50 && [[ -z \$(login_win) && \$(prompts) == $p && ! -e $T/pw.master && ! -e $pwl/on ]]"
echo "$T/hostkey.pub" >"$T/pw.presented"
link_pw
check "with the key you confirmed, ssh asks for the password" "login_typed hunter2 && [[ \$(prompts) == \$(($p + 1)) ]]"
check "the link is made, and known_hosts has that key now" "wait_pw 'linked to pw.example' 75 && grep -q '^pw.example ssh-ed25519' $T/known_hosts"
tm send-keys -t work:pwpanel q
AGENT_SAY_SSH=$T/pwssh "$ROOT/bin/agent-say" unlink pw.example >/dev/null 2>&1
tm kill-window -t work:pwssh 2>/dev/null
# A slow link: each screen comes back 4 s after it was taken. A key sent while one is on its
# way must not wait for that old screen and only then ask again (8 s): it asks at once.
{
	printf '#!/bin/bash\nfake=%q log=%q\n' "$T/fakessh" "$T/slowpeeks"
	cat <<'EOF'
[[ ${!#} == *' panel --peek '* ]] || exec "$fake" "$@"
echo >>"$log"
o=$(mktemp) || exit 1
"$fake" "$@" >"$o"; st=$?
sleep 4; cat "$o"; rm -f "$o"
exit $st
EOF
} >"$T/slowssh"
chmod +x "$T/slowssh"
tmux -L "revive-panel-remote-$$" -f /dev/null new-window -d -t far -n slow "$T/bin/codex $T/ask.sh $T/ans7"
tmux -L "revive-panel-remote-$$" -f /dev/null set-option -p -t far:slow @agent far-slow
rm -f "$st/panel/far.example.rows" "$st/panel/"*.peek-*
tm new-window -d -t work -n farq "env AGENT_SAY_SSH=$T/slowssh REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX REVIVE_PANEL_REFRESH=1 bash $ROOT/scripts/panel.sh"
wait_fq 'far-slow' 60 >/dev/null
for _ in $(seq 1 25); do fq | grep -q '▶ far-slow' && break; tm send-keys -t work:farq Down; sleep 0.4; done
wait_fqband '❯ 1. Yes' 75 >/dev/null
tm send-keys -t work:farq Enter; wait_fq 'ANSWERING far-slow' >/dev/null
# Down just after a look has set off, so that look comes back with the screen before the key.
n=$(wc -l <"$T/slowpeeks")
for _ in $(seq 1 100); do (($(wc -l <"$T/slowpeeks") > n)) && break; sleep 0.05; done
tm send-keys -t work:farq Down
# Within 7 s of the key: one screen asked for after it (4 s and the asking), not two (8 s).
band_within() { local end=$((${EPOCHREALTIME/./} + $1 * 1000000)); while ((${EPOCHREALTIME/./} < end)); do [[ $(fqcolor "$2") == *'44'* ]] && return 0; sleep 0.1; done; return 1; }
check "on a slow link, the band follows a key without waiting out the screen already coming" "band_within 7 '❯ 2. No'"
tm send-keys -t work:farq C-]; sleep 0.3; tm send-keys -t work:farq q; sleep 5
check "the screen it didn't wait for is thrown away, not left behind" "! ls $st/panel/ | grep -cE 'peek-[0-9]+\\.' >/dev/null"

rm -rf "$st/links/far.example" "$st/panel"
tmux -L "revive-panel-remote-$$" -f /dev/null kill-server 2>/dev/null

echo "splash"
tm new-window -d -t work -n splash "env REVIVE_PANEL_SPLASH=1 REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX bash $ROOT/scripts/panel.sh"
check "the dial-up splash plays" "for _ in \$(seq 1 40); do tm capture-pane -p -t work:splash | grep -q 'CONNECT 33600' && break; sleep 0.1; done; tm capture-pane -p -t work:splash | grep -q 'CONNECT 33600'"
tm send-keys -t work:splash x
check "a key skips it to the panel" "for _ in \$(seq 1 30); do tm capture-pane -p -t work:splash | grep -q 'C O N T R O L' && break; sleep 0.2; done; tm capture-pane -p -t work:splash | grep -q 'C O N T R O L'"
tm send-keys -t work:splash q

echo "hostile text"
# Folder names, pane names, mail from linked machines and git config all come from elsewhere.
# None of it may put an escape sequence on the terminal or make the panel run a command.
raw() { tm run-shell "COLUMNS=140 LINES=50 REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX bash $ROOT/scripts/panel.sh --once"; }
evil="$T/evil"$'\e]52;c;cHduZWQ=\a\e[2Jdir'
mkdir -p "$evil"
mkdir -p "$T/mail"
printf '## [mallory -> panel 2026-11-07T10:00:00Z] #1\nhi\e]52;c;cHduZWQ=\athere\n\n' >>"$AGENT_SAY_MAILBOX"
printf '## [mallory -> panel 2026-11-07T10:01:00Z] #2\nrlo\xe2\x80\xaegnp.exe zero\xe2\x80\x8bwidth\n\n' >>"$AGENT_SAY_MAILBOX"
git init -q -b fsmtest "$T/fsm"
echo x >"$T/fsm/f" && git -C "$T/fsm" add f && git -C "$T/fsm" -c user.name=t -c user.email=t@t commit -q -m f
git -C "$T/fsm" config core.fsmonitor "touch $T/fsmonitor-ran; false"
git -C "$T/fsm" config core.hooksPath "$T/hooks"
mkdir -p "$T/hooks" && printf '#!/bin/sh\ntouch %s/hook-ran\n' "$T" >"$T/hooks/post-index-change" && chmod +x "$T/hooks/post-index-change"
echo y >"$T/fsm/f"
git init -q "$T/flt" && echo x >"$T/flt/f" && echo '* filter=x' >"$T/flt/.gitattributes"
git -C "$T/flt" add f .gitattributes && git -C "$T/flt" -c user.name=t -c user.email=t@t commit -q -m f
git -C "$T/flt" config filter.x.clean "touch $T/filter-ran; cat"
echo y >"$T/flt/f"
tm kill-window -t work:splash 2>/dev/null
tm new-window -d -t work -n evil -c "$evil" "bash --norc --noprofile"
tm new-window -d -t work -n fsm -c "$T/fsm" "bash --norc --noprofile"
tm new-window -d -t work -n flt -c "$T/flt" "bash --norc --noprofile"
tm set-option -p -t work:evil @agent $'bad\e]0;x\aname'
mkdir -p "$T/mail/links/faraway" && touch "$T/mail/links/faraway/on"
printf 'ssh: \e]52;c;eA==\adown\n' >"$T/mail/links/faraway/error"
sleep 0.5
out=$(raw)
# The frame with the panel's own colour codes taken out: no control character may be left.
bare=$(sed 's/\x1b\[[0-9;]*m//g' <<<"$out")
check "the folder name shows, its escape sequence doesn't" "grep -qF 'evil]52;c;cHduZWQ=[2Jdir' <<<\"\$bare\""
check "a pane name's escape is stripped" "grep -qF 'bad]0;xname' <<<\"\$bare\""
check "a link's error (remote ssh stderr) is stripped" "grep -qF 'ssh: ]52;c;eA==down' <<<\"\$bare\""
check "a mailbox body's OSC 52 is stripped" "grep -qF 'hi]52;c;cHduZWQ=there' <<<\"\$bare\""
check "and its bidi override and zero-width space" "grep -qF 'rlognp.exe zerowidth' <<<\"\$bare\""
check "the only escapes in a frame are the panel's own colours" "! LC_ALL=C grep -q '[[:cntrl:]]' <<<\"\$bare\""
check "git state still shows (branch, dirty)" "grep -qF 'fsmtest*' <<<\"\$bare\""
check "a repo's core.fsmonitor command never runs" "[[ ! -e $T/fsmonitor-ran ]]"
check "a repo's hooks never run" "[[ ! -e $T/hook-ran ]]"
check "a repo's own clean filter never runs" "[[ ! -e $T/filter-ran ]]"

echo "question alerts"
# daemon.sh on a server of its own says when an agent starts asking, panel or not. A client
# attached to that server runs in a window here, so its messages and bell can be seen.
at() { tmux -L "revive-alert-$$" -f /dev/null "$@"; }
at new-session -d -s asks -x 120 -y 40 "bash --norc --noprofile"
at send-keys -t asks:0 'echo "Do you want to proceed? (y/n)"' Enter # a shell, not an agent
at set-option -g display-time 30000
at set-option -g @revive-shutdown-hook off
at set-option -g @revive-interval 0
asock=$(at display -p '#{socket_path}')
client() { tm kill-window -t work:client 2>/dev/null; tm new-window -d -t work -n client "env -u TMUX tmux -L revive-alert-$$ -f /dev/null attach -t asks"; sleep 0.5; }
cscreen() { tm capture-pane -p -t work:client; }
bell() { [[ $(tm display -p -t work:client '#{window_bell_flag}') == 1 ]]; }
alerts() { local n; n=$(grep -c "question: $1" "$T/adata/revive.log" 2>/dev/null); echo "${n:-0}"; }
wait_alerts() { for _ in $(seq 1 40); do (($(alerts "$1") >= $2)) && return 0; sleep 0.25; done; return 1; }
client
REVIVE_SOCKET=$asock REVIVE_DIR=$T/adata REVIVE_DAEMON_TICK=1 bash "$ROOT/scripts/daemon.sh" </dev/null >/dev/null 2>&1 &
dpid=$!
at new-window -d -t asks -n q "$T/bin/codex $T/ask.sh $T/ans4"
at set-option -p -t asks:q @agent asker4
check "an agent asking a question is announced on the client" "wait_alerts asker4 1 && for _ in \$(seq 1 20); do cscreen | grep -c 'asker4 (asks:1.0) is asking a question' >/dev/null && break; sleep 0.2; done; cscreen | grep -c 'asker4 (asks:1.0) is asking a question' >/dev/null"
check "with a bell in the client showing its session" "for _ in \$(seq 1 20); do bell && break; sleep 0.2; done; bell"
sleep 3
check "once per question, not on every look" "[[ \$(alerts asker4) == 1 ]]"
check "--asking lists that pane, as the daemon reads it" "[[ \$(REVIVE_SOCKET=$asock bash $ROOT/scripts/panel.sh --asking) == \$(at display -p -t asks:q '#{pane_id}')\$'\\t'asks:1.0\$'\\t'asker4 ]]"
# Answered, then asked again: a new question, so a new alert. This time with the bell off.
at send-keys -t asks:q Enter; sleep 2.5
at set-option -g @revive-question-bell off
client
at respawn-pane -k -t asks:q "$T/bin/codex $T/ask.sh $T/ans5"
check "the next question is announced again" "wait_alerts asker4 2"
sleep 1.5
check "with @revive-question-bell off, no bell" "! bell"
at send-keys -t asks:q Enter; sleep 2.5
at set-option -g @revive-question-alert off
at respawn-pane -k -t asks:q "$T/bin/codex $T/ask.sh $T/ans6"
sleep 3
check "with @revive-question-alert off, none at all" "[[ \$(alerts asker4) == 2 ]]"
check "a pane that isn't an agent is never announced" "[[ \$(grep -c 'question:' $T/adata/revive.log) == 2 ]]"
kill "$dpid" 2>/dev/null
tm kill-window -t work:client 2>/dev/null
at kill-server 2>/dev/null

echo "other users in this tmux"
# Panes where another user works (sudo -i or su in one of your panes): USER says whose each is,
# VER which tmux-revive that user has, or [V] when they have none. V there runs nothing: it shows
# the command to run in their pane, and copies it. Stand-ins as above: the ps giving those
# panes' processes uid 0 and deploy's uid; a sudo and an ssh that log anything asked of them.
me=$(id -un)
mkdir -p "$T/umail/users"
tm new-window -d -t work -n lroot "sleep 300"; tm set-option -p -t work:lroot @agent l-root
tm new-window -d -t work -n ldeploy "sleep 300"; tm set-option -p -t work:ldeploy @agent l-deploy
printf '%s 0\n%s %s\n' "$(tm display -p -t work:lroot '#{pane_pid}')" "$(tm display -p -t work:ldeploy '#{pane_pid}')" "$DEPLOY_UID" >>"$T/uidmap"
echo 1.0.0 >"$T/umail/users/deploy"
echo 1.2.0 >"$T/local-version"
uframe() { tm run-shell "PATH=$T/uidps:\$PATH REVIVE_VERSION_FILE=$T/local-version REVIVE_PANEL_PEEK=0 COLUMNS=${2:-140} LINES=50 REVIVE_PANEL_SEL=${1:-none} REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$T/umail/mailbox.md bash $ROOT/scripts/panel.sh --once"; }
raw=$(uframe) out=$(plain <<<"$raw")
check "USER and VER come right after NAME" "grep -q ' NAME *USER *VER *APP ' <<<\"\$out\""
check "a pane where root works with no tmux-revive: root, and [V] in the warn colour" "grep -q 'l-root *root *\[V\] *sleep' <<<\"\$out\" && grep -qF $'\\e[93m[V]' <<<\"\$raw\""
check "one whose user has an older tmux-revive: that version, in the warn colour" "grep -q 'l-deploy *deploy *1\.0\.0 *sleep' <<<\"\$out\" && grep -qF $'\\e[93m1.0.0' <<<\"\$raw\""
check "your own panes: you, and this panel's version" "grep -q \" $me *1\.2\.0 *bash\" <<<\"\$out\""
lbar() { plain | grep -F 'ump' | tail -1; }
check "on root's pane the command bar offers V: install" "uframe \$(tm display -p -t work:lroot '#{pane_id}') | lbar | grep -qF '[V] install'"
check "on deploy's pane, V: update" "uframe \$(tm display -p -t work:ldeploy '#{pane_id}') | lbar | grep -qF '[V] update'"
check "on your own pane, no V" "! uframe \$(tm display -p -t work:0.0 '#{pane_id}') | lbar | grep -qF '[V]'"
for c in 80 120 160 200; do
	out=$(uframe none "$c" | plain)
	check "at $c columns every row is still exactly $c wide" "[[ \$(awk '{w[length]=1} END{for (k in w) printf \"%s \", k}' <<<\"\$out\") == '$c ' ]]"
done
out=$(uframe none 120 | plain)
check "at 120 columns USER and VER still show" "grep -q 'l-root *root *\[V\]' <<<\"\$out\""

tm new-window -d -t work -n upanel "env PATH=$T/uidps:$T/usudo:\$PATH REVIVE_VERSION_FILE=$T/local-version REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$T/umail/mailbox.md REVIVE_PANEL_REFRESH=1 bash $ROOT/scripts/panel.sh"
uscreen() { tm capture-pane -p -t work:upanel; }
wait_u() { for _ in $(seq 1 40); do uscreen | grep -q -- "$1" && return 0; sleep 0.25; done; return 1; }
usel() { for _ in $(seq 1 30); do uscreen | grep -q "▶ $1 " && return 0; tm send-keys -t work:upanel Down; sleep 0.3; done; return 1; }
gone_u() { for _ in $(seq 1 20); do uscreen | grep -q -- "$1" || return 0; sleep 0.25; done; return 1; }
wait_u 'l-root'
usel l-root
tm set-buffer -- before
tm send-keys -t work:upanel v
check "V on root's pane shows the install command to run in root's pane" "wait_u \"Run this in root's pane:\" && uscreen | grep -qF -- '$INSTALL_CMD'"
check "and copies it" "[[ \$(tm show-buffer) == '$INSTALL_CMD' ]] && wait_u 'Copied'"
tm send-keys -t work:upanel x
check "a key closes it" "gone_u \"Run this in root's pane:\""
usel l-deploy
tm send-keys -t work:upanel v
check "V on deploy's pane, with an older version: tmux-revive update, copied" "wait_u \"Run this in deploy's pane:\" && uscreen | grep -q '│* *tmux-revive update *║' && [[ \$(tm show-buffer) == 'tmux-revive update' ]]"
tm send-keys -t work:upanel x
gone_u "Run this in deploy's pane:" >/dev/null
check "nothing is run as another user: no sudo" "[[ ! -e $T/usudo.log ]]"
# Each user's own install or update keeps their version (agent-say _user-installed, run as the
# owner): two users in one tmux, each with their own.
echo 1.1.0 >"$T/umail/users/root"
check "two users in one tmux show their own versions" "wait_u 'l-root *root *1\.1\.0' && uscreen | grep -q 'l-deploy *deploy *1\.0\.0'"
echo 1.2.0 >"$T/umail/users/deploy"
check "one that's up to date gets no V" "wait_u 'l-deploy *deploy *1\.2\.0' && usel l-deploy && sleep 0.5 && ! uscreen | grep -F 'ump' | grep -qF '[V]'"
tm kill-window -t work:upanel; tm kill-window -t work:lroot; tm kill-window -t work:ldeploy

echo "scrolling windows"
# A private tmux of its own with more panes than PANES has room for: a pane full of numbered
# rows first, sleeps, and an agent asking a question last. A linked computer, fold.example,
# from rows kept as its panel would have fetched them (its ssh never answers), with one
# pane asking and one at a shell.
sm() { tmux -L "revive-panel-scroll-$$" -f /dev/null "$@"; }
sm new-session -d -s s -x 130 -y 30 "seq -f 'srow-%g' 1 200; sleep 300"
for i in $(seq 1 14); do sm new-window -d -t s: "sleep 300"; done
sm new-window -d -t s: -n asker "$T/bin/codex $T/ask.sh $T/ans9"
sm set-option -p -t s:asker @agent asker9
SMAIL=$T/smail/mailbox.md
mkdir -p "$T/smail/links/fold.example" "$T/smail/panel"
touch "$T/smail/links/fold.example/on"
printf 'fold-a\nfold-b\n' >"$T/smail/links/fold.example/names"
frows() { printf '#owner fx\n%s\n%s\n' "%1"$'\x1f'"main:7.0"$'\x1f'"fold-a"$'\x1f'"codex"$'\x1f'"asking"$'\x1f'"/tmp"$'\x1f\x1f'"0"$'\x1f'"1000"$'\x1f'"1" "%2"$'\x1f'"main:7.1"$'\x1f'"fold-b"$'\x1f'"bash"$'\x1f'"shell"$'\x1f'"/tmp"$'\x1f\x1f'"0"$'\x1f'"1000"$'\x1f'"0" >"$T/smail/panel/fold.example.rows"; }
frows
sleep 0.7
sframe() { sm run-shell "COLUMNS=130 LINES=${1:-30} REVIVE_PANEL_TICK=${2:-0} REVIVE_PANEL_PEEK=0 REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$SMAIL AGENT_SAY_SSH=$T/deadssh bash $ROOT/scripts/panel.sh --once"; }
plist() { awk '/PANES/{on=1; getline; next} on && / cpu /{exit} on'; } # the list's rows, under its column header
raw=$(sframe 30 0) out=$(plain <<<"$raw")
check "PANES with more rows than room scrolls: ▲, a track with its thumb, ▼ on its right edge" "[[ \$(plist <<<\"\$out\" | head -1) == *▲║ && \$(plist <<<\"\$out\" | tail -1) == *▼║ ]] && plist <<<\"\$out\" | grep -q '▓║$' && plist <<<\"\$out\" | grep -q '░║$'"
check "it keeps to half the room, and every row is still exactly 130 wide" "(( \$(plist <<<\"\$out\" | wc -l) <= 7 )) && [[ \$(awk '{w[length]=1} END{for (k in w) printf \"%s \", k}' <<<\"\$out\") == '130 ' ]]"
check "a question out of view below makes the ▼ blink bold yellow" "plist <<<\"\$raw\" | tail -1 | grep -qF $'\\e[1m\\e[93m\\e[5m▼' && ! plist <<<\"\$raw\" | head -1 | grep -qF $'\\e[93m\\e[5m▲'"
check "and on the next tick it goes dark, as the help page's beacons do" "sframe 30 1 | plist | tail -1 | grep -qF $'\\e[34m▼' && ! sframe 30 1 | plist | grep -qF $'\\e[93m\\e[5m▼'"
out=$(sframe 80 | plain)
check "with room for every row, no scroll bar" "plist <<<\"\$out\" | grep -q 'asker9' && ! plist <<<\"\$out\" | grep -q '[▲▼░▓]║$'"
check "a linked computer's heading counts its panes and the ones that need you" "grep -q 'FOLD.EXAMPLE · linked · 2 panes · 1 needs you' <<<\"\$out\""
# MESSAGES: older messages above the newest; a message not delivered scrolled off the top
# lights the ▲.
{
	printf '## [mailer@elsewhere -> asker9@here 2026-11-09 09:00:00] #m0 (NOT DELIVERED: no such pane)\nlost one\n'
	for i in 1 2 3 4 5 6 7 8 9; do printf '## [mailer@elsewhere -> asker9@here 2026-11-09 10:0%s:00] #m%s\nhello %s\n' "$i" "$i" "$i"; done
} >"$SMAIL"
raw=$(sframe 30 0) out=$(plain <<<"$raw")
mrows() { awk '/MESSAGES/{on=1; next} on && /^╠/{exit} on'; }
check "MESSAGES shows the newest, with a scroll bar beside it" "mrows <<<\"\$out\" | grep -q 'hello 9' && ! mrows <<<\"\$out\" | grep -q 'hello 1 ' && mrows <<<\"\$out\" | head -1 | grep -q '▲│'"
check "a message not delivered, scrolled out of view, makes its ▲ blink" "mrows <<<\"\$raw\" | head -1 | grep -qF $'\\e[1m\\e[93m\\e[5m▲'"
# Folded: the computer is its heading alone, saying how many of its panes need you.
mkdir -p "$REVIVE_DIR/panel/fold" && touch "$REVIVE_DIR/panel/fold/fold.example"
out=$(sframe 80 | plain)
check "a folded computer shows its heading alone, with · 1 needs you" "grep -q 'FOLD.EXAMPLE · linked · 2 panes · 1 needs you' <<<\"\$out\" && ! grep -q 'fold-a' <<<\"\$out\""
rm -f "$REVIVE_DIR/panel/fold/fold.example"
# The keys, in a live panel.
frows
sm new-window -d -t s: -n sp "env REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$SMAIL AGENT_SAY_SSH=$T/deadssh REVIVE_PANEL_REFRESH=1 bash $ROOT/scripts/panel.sh"
sscr() { sm capture-pane -p -t s:sp; }
wait_sp() { for _ in $(seq 1 ${2:-30}); do sscr | grep -qF -- "$1" && return 0; sleep 0.2; done; return 1; }
gone_sp() { for _ in $(seq 1 ${2:-30}); do sscr | grep -qF -- "$1" || return 0; sleep 0.2; done; return 1; }
wait_sp 'C O N T R O L' >/dev/null
check "PANES has the focus to start with: its title is highlighted" "wait_sp '▸ PANES'"
tm_s() { sm send-keys -t s:sp "$@"; }
tm_s Tab
check "Tab moves the focus to the peek" "wait_sp '▸ PEEK · ' && ! sscr | grep -qF '▸ PANES'"
check "where the arrows scroll, and the bar says so" "wait_sp '↑↓ PgUp PgDn scroll · Tab next window'"
check "the peek shows the bottom of its pane's screen" "wait_sp 'srow-200'"
tm_s PPage
check "PgUp scrolls the peek back up its screen" "gone_sp 'srow-200' && sscr | grep -q 'srow-1[0-9][0-9]'"
tm_s End
check "and End brings it back to the bottom" "wait_sp 'srow-200'"
tm_s Tab
check "Tab: then MESSAGES" "wait_sp '▸ MESSAGES'"
tm_s Tab
check "then LINKS · SAVES" "wait_sp '▸ LINKS · SAVES'"
tm_s Tab
check "and round to PANES again" "wait_sp '▸ PANES' && ! sscr | grep -qF '▸ LINKS'"
tm_s End
check "in PANES, End selects the last row and the view follows it off the top" "wait_sp '▶ fold-b' && gone_sp '[0.0]'"
tm_s Home
check "Home goes back to the first" "for _ in \$(seq 1 30); do sscr | grep -q '\[0\.0\] *▶' && break; sleep 0.2; done; sscr | grep -q '\[0\.0\] *▶'"
frows # kept fresh: rows over a minute old would mean that computer stopped answering
tm_s End; wait_sp '▶ fold-b' >/dev/null
tm_s Up; wait_sp '▶ fold-a' >/dev/null
tm_s Up
check "the arrows land on a linked computer's heading, and Enter offers to fold it" "wait_sp '▶▒░ FOLD.EXAMPLE' && wait_sp '[Enter] fold'"
tm_s Enter
check "Enter folds it to its heading line, saying what needs you" "wait_sp 'FOLD.EXAMPLE · linked · 2 panes · 1 needs you' && gone_sp 'fold-a' && wait_sp '[Enter] unfold'"
check "and the fold is kept for next time" "[[ -e $REVIVE_DIR/panel/fold/fold.example ]]"
tm_s Enter
check "Enter on it again unfolds it" "wait_sp 'fold-a' && [[ ! -e $REVIVE_DIR/panel/fold/fold.example ]]"
tm_s q
sm kill-server


echo "$pass passed, $fail failed"
((fail == 0))
