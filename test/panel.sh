#!/usr/bin/env bash
# tmux-revive panel on a private tmux server (never touches yours): what it shows, that it
# fits the terminal, and that its keys work.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/panel-test.XXXXXX")
unset TMUX TMUX_PANE
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
	[[ -n ${dpid:-} ]] && kill "$dpid" 2>/dev/null
	rm -rf "$T"
}
trap cleanup EXIT
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
box_tail=$(awk '/PEEK · /{on=1; next} on && /MESSAGES|ART · /{exit} on' <<<"$peek" | tail -2 | sed 's/^║ │ \{0,1\}//; s/[[:space:]]*║$//; s/[[:space:]]*$//' | tr '\n' '|')
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
tm send-keys -t work:panel 2
check "a number selects that pane" "wait_screen '[2] ▶'"
tm send-keys -t work:panel n; sleep 0.5
tm send-keys -t work:panel 'top-watch' Enter
named() { for _ in $(seq 1 30); do tm list-panes -a -F '#{@agent}' | grep -qx "$1" && return 0; sleep 0.2; done; return 1; }
check "N renames the selected pane" "named top-watch && wait_screen '▶ top-watch'"
tm send-keys -t work:panel s
check "S saves" "wait_screen '(manual)'"
check "the peek box shows the selected pane" "screen | grep -q 'PEEK · top-watch'"
# x: the peek over the whole artwork; x again or c back. Every row is repainted right.
# Counted with grep -c, never grep -q at the end of a pipe (pipefail: a closed pipe fails it).
seen() { local n; n=$(screen | grep -cF -- "$1"); [[ $n == "${2:-1}" ]]; }
whole() { local s; s=$(screen); [[ ${s%%$'\n'*} == ╔* && ${s##*$'\n'} == *╝ ]] && seen 'PEEK · ' && seen 'MESSAGES'; }
tm send-keys -t work:panel x
check "x gives the peek the artwork's space too" "wait_screen '[x] back' && seen '[c] collapse' && seen 'ART · ' 0 && whole"
tm send-keys -t work:panel c
check "c collapses it back, artwork and all" "wait_screen '[x] full view' && wait_screen 'ART · ' && whole"
tm send-keys -t work:panel x; wait_screen '[x] back' >/dev/null
tm send-keys -t work:panel x
check "and x again snaps it back too" "wait_screen '[x] full view' && seen 'ART · ' && whole"
tm send-keys -t work:panel p; sleep 1.5
check "P hides the peek box" "! screen | grep -q 'PEEK'"
tm send-keys -t work:panel Down
check "the arrow keys move the selection" "wait_screen '[3] ▶'"
# The list goes round: Down past the last pane comes back to the first, Up past the first to the last.
tm send-keys -t work:panel Down
check "Down from the last pane selects the first" "wait_screen '[1] ▶'"
tm send-keys -t work:panel 1; wait_screen '[1] ▶' >/dev/null
tm send-keys -t work:panel Up
check "Up from the first pane selects the last" "wait_screen '[3] ▶' && seen '[4]' 0"
# Held arrows: quick to follow, nothing echoed, nothing scrolled.
tm send-keys -t work:panel Up Up
quick() { local s=$EPOCHREALTIME; tm send-keys -t work:panel Down; for _ in $(seq 1 40); do screen | grep -qF "[$1] ▶" && break; sleep 0.05; done; awk -v a=$s -v b=$EPOCHREALTIME 'BEGIN{exit !(b - a < 1.0)}'; }
wait_screen '[1] ▶' >/dev/null
check "an arrow key moves the selection within a second" "quick 2"
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
echo '{"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":500000}}}' >>"$H/.claude/projects/-w/s-1.jsonl"
out=$(cframe)
check "a Claude 5 model has a million-token window (500k: 50% left)" "grep -q 'claude .* 50%' <<<\"\$out\""
rows=$(tm run-shell "HOME=$H REVIVE_DIR=$REVIVE_DIR bash $ROOT/scripts/panel.sh --rows")
check "--rows gives each pane's context left on a line of its own, before its row" "grep -A1 '^#ctx %[0-9]* 20$' <<<\"\$rows\" | grep -q $'\x1fcodex\x1f'"
tm kill-window -t work:cl; tm kill-window -t work:cx; tm kill-window -t work:cl2

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
boxrow() { qbox | grep '│' | tail -1 | sed 's/^║[^│]*│ \{0,1\}//; s/[[:space:]]*║$//; s/[[:space:]]*$//'; }
# The question stands out: bold yellow; the highlighted choice on a band; the rest plainer.
qcolor() { tm capture-pane -e -p -t work:qpanel | grep -F -- "$1" | head -1; }
check "the question itself is bold yellow" "[[ \$(qcolor 'Do you want to proceed?') == *'93'* ]]"
check "the highlighted choice sits on a band" "[[ \$(qcolor '❯ 1. Yes') == *'44'* ]]"
check "the other choices don't" "[[ \$(qcolor '2. No') != *'44'* ]]"
check "its last row is the agent's last row" "[[ \"\$(boxrow)\" == \"\$(lastrow)\" ]]"
check "Tab offers to answer it, J the chat" "qhas '[Tab] answer' && qhas '[J] open the chat'"
check "the messages step aside while a question shows" "! qhas 'MESSAGES'"
# Tab moves the focus into the question and back to the panes.
tm send-keys -t work:qpanel Tab
check "Tab moves the focus into the question" "wait_q 'ANSWERING asker' && qhas 'Tab back to the panes'"
tm send-keys -t work:qpanel Tab
check "and Tab brings it back to the panes, sending nothing" "wait_q 'Tab returns to the question' && ! qhas 'ANSWERING' && [[ ! -s $T/ans1.keys ]]"
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
# Linking asks you to confirm the host's key first; No (the first choice, so a bare Enter) links nothing.
ssh-keygen -q -t ed25519 -N '' -C '' -f "$T/hostkey"
printf 'devbox.example %s\n' "$(cut -d' ' -f1,2 "$T/hostkey.pub")" >"$T/known_hosts"
fp=$(ssh-keygen -lf "$T/hostkey.pub" | awk '{print $2}')
tm send-keys -t work:sshpanel l; sleep 0.7; tm send-keys -t work:sshpanel Enter
check "picking a host shows its key to confirm" "wait_ssh 'HOST KEY OF devbox.example' && wait_ssh 'its key is $fp (ED25519)' && wait_ssh \"No, don't link\""
tm send-keys -t work:sshpanel Enter
check "No links nothing" "wait_ssh 'link cancelled' && [[ ! -e $(dirname "$AGENT_SAY_MAILBOX")/links/devbox.example ]]"
tm send-keys -t work:sshpanel l; sleep 0.7; tm send-keys -t work:sshpanel Enter; wait_ssh 'HOST KEY OF' >/dev/null; tm send-keys -t work:sshpanel 2
check "Yes links the chosen host and shows what happened" "wait_ssh \"couldn't run agent-say on devbox.example\""
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
tm send-keys -t work:sshpanel q
tm kill-window -t work:remote 2>/dev/null

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
	printf '#!/bin/bash\nunset TMUX TMUX_PANE\nexport REVIVE_SOCKET=%q REVIVE_DIR=%q REVIVE_VERSION_FILE=%q\npanel=%q T=%q\n' "$rsock" "$T/remote-data" "$T/remote-version" "$ROOT/scripts/panel.sh" "$T"
	cat <<'EOF'
cmd=${!#}
if [[ $cmd =~ \ panel\ --rows$ ]]; then exec bash "$panel" --rows
elif [[ $cmd == *' tmux-revive update '* ]]; then printf '%s' "$cmd" >"$T/update.cmd"; printf 'downloading\ntmux-revive 9.9.9 installed\n\n'; exit 0
elif [[ $cmd == AGENT_SAY_PANE=* ]]; then printf '%s' "$cmd" >"$T/name.cmd"; HOME=$T/rhome PATH=$T/rbin:$PATH AGENT_SAY_MAILBOX=$T/rstate/mailbox.md exec bash -c "$cmd"
elif [[ $cmd =~ \ panel\ --peek\ \'([^\']*)\'\ ([^ ]*)$ ]]; then exec bash "$panel" --peek "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
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
check "a linked computer's panes show with their state" "grep -q 'far-top *top *▸ running' <<<\"\$out\""
check "and its shell panes too" "grep -A3 'FAR.EXAMPLE' <<<\"\$out\" | grep -q 'bash *· shell'"
check "the whole frame still fits" "[[ \$(awk '{w[length]=1} END{for (k in w) n++; print n}' <<<\"\$out\") == 1 ]]"
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
# Versions: a linked computer's rows say its version, and its heading compares it with this one's.
echo 1.1.0 >"$T/remote-version"; echo 1.2.0 >"$T/local-version"
farv() { rm -f "$st/panel/far.example.rows"*; tm run-shell "AGENT_SAY_SSH=$1 REVIVE_VERSION_FILE=$T/${2:-local-version} COLUMNS=140 LINES=50 REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX bash $ROOT/scripts/panel.sh --once" | plain; }
out=$(farv "$T/fakessh")
check "an older linked computer shows its version, out of date" "grep -c 'FAR.EXAMPLE · linked · v1.1.0 · out of date' <<<\"\$out\" >/dev/null && grep -c 'this computer · v1.2.0' <<<\"\$out\" >/dev/null"
echo 1.2.0 >"$T/remote-version"
out=$(farv "$T/fakessh")
check "the same version isn't" "grep -c 'FAR.EXAMPLE · linked · v1.2.0 *║' <<<\"\$out\" >/dev/null"
echo 1.1.0 >"$T/remote-version"
out=$(farv "$T/fakessh" no-such-file)
check "with this computer's version unknown, nothing is called out of date" "grep -c 'FAR.EXAMPLE · linked · v1.1.0 *║' <<<\"\$out\" >/dev/null && ! grep -c 'out of date' <<<\"\$out\" >/dev/null"
out=$(farv "$T/norowssh")
check "one that answers no rows is too old to tell" "grep -c 'FAR.EXAMPLE · linked · too old to tell' <<<\"\$out\" >/dev/null && grep -c 'far-two *◌ linked' <<<\"\$out\" >/dev/null"
out=$(farv "$T/deadssh")
check "one that can't be reached isn't called old" "grep -c 'FAR.EXAMPLE · linked *║' <<<\"\$out\" >/dev/null"
printf '#version 1.2.3;touch %s/pwn\n' "$T" >"$T/badver"; head -c 2000 /dev/zero | tr '\0' 9 >>"$T/badver"; printf '\n' >>"$T/badver"
printf '#!/bin/bash\n%q "$@" | sed 1d | cat %q -\n' "$T/fakessh" "$T/badver" >"$T/badverssh"; chmod +x "$T/badverssh"
out=$(farv "$T/badverssh")
check "a version line that isn't one is ignored" "grep -c 'FAR.EXAMPLE · linked · too old to tell' <<<\"\$out\" >/dev/null && grep -c 'far-top' <<<\"\$out\" >/dev/null && ! grep -c '1.2.3' <<<\"\$out\" >/dev/null && [[ ! -e $T/pwn ]]"
check "--rows says its version first" "[[ \$(REVIVE_SOCKET=$rsock REVIVE_DIR=$T/remote-data REVIVE_VERSION_FILE=$T/remote-version bash $ROOT/scripts/panel.sh --rows | head -n 1) == '#version 1.1.0' ]]"
# A panel from before versions reads those rows as before: the version line is skipped.
mkdir -p "$T/old/scripts"
if git -C "$ROOT" show d621bda:scripts/panel.sh >"$T/old/scripts/panel.sh" 2>/dev/null; then
	cp "$ROOT/scripts/common.sh" "$T/old/scripts/"
	rm -f "$st/panel/far.example.rows"*
	out=$(tm run-shell "AGENT_SAY_SSH=$T/fakessh COLUMNS=140 LINES=50 REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX bash $T/old/scripts/panel.sh --once" | plain)
	check "an older panel skips the version line" "grep -c 'far-top *top *▸ running' <<<\"\$out\" >/dev/null && ! grep -c 'version' <<<\"\$out\" >/dev/null"
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
check "and no temporary files are left" "! ls $st/panel | grep -cvE '^far\\.example\\.(rows(\\.old)?|peek-[0-9]+(\\.fail)?)$' >/dev/null"
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
check "on a linked computer's pane, J fades and N doesn't" "farscreen | grep -q '▶ far-top' && bar | grep -qF \"\$grey\" && bar | grep -qF $'\\e[93mN' && ! bar | grep -qF $'\\e[90m[N]ame'"
check "while keys that still work stay lit" "bar | grep -qF \"\$lit\""
# V: update tmux-revive over there, once confirmed, with a fixed command.
check "on a linked computer's pane, V offers an update" "bar | grep -cF $'\\e[93mV' >/dev/null && farscreen | grep -c 'out of date' >/dev/null"
tm send-keys -t work:farpanel v
check "V asks first" "for _ in \$(seq 1 20); do farscreen | grep -c 'Update tmux-revive on far.example?' >/dev/null && break; sleep 0.2; done; farscreen | grep -c 'Yes, update it over ssh' >/dev/null"
tm send-keys -t work:farpanel Escape
check "and Esc updates nothing" "for _ in \$(seq 1 20); do farscreen | grep -c 'update cancelled' >/dev/null && break; sleep 0.2; done; farscreen | grep -c 'update cancelled' >/dev/null && [[ ! -e $T/update.cmd ]]"
tm send-keys -t work:farpanel v; sleep 0.5; tm send-keys -t work:farpanel Enter
check "yes runs tmux-revive update there and shows how it went" "for _ in \$(seq 1 30); do farscreen | grep -c 'on far.example: tmux-revive 9.9.9 installed' >/dev/null && break; sleep 0.2; done; farscreen | grep -c 'on far.example: tmux-revive 9.9.9 installed' >/dev/null"
check "with the fixed command, nothing else" "[[ \$(cat $T/update.cmd) == 'PATH=\"\$HOME/.local/bin:\$PATH\" tmux-revive update </dev/null 2>&1' ]]"
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
rm -f "$st/links/far.example/read-only"
tm send-keys -t work:farpanel 1
check "back on a pane here, J lights up again" "for _ in \$(seq 1 25); do farscreen | grep -q '\[1\] ▶' && ! bar | grep -qF \"\$grey\" && break; sleep 0.2; done; farscreen | grep -q '\[1\] ▶' && ! bar | grep -qF \"\$grey\""
tm send-keys -t work:farpanel q

# --keys: a pane id, then key names from a short list or lit:HEX text, nothing else.
hex() { printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'; }
check "--keys types into a pane over there" "[[ \$(rpanel --keys $farid lit:\$(hex 'echo keys-$((6 * 7))') Enter) == sent ]] && for _ in \$(seq 1 20); do tmux -L revive-panel-remote-$$ -f /dev/null capture-pane -p -t $farid | grep -c '^keys-42' >/dev/null && break; sleep 0.2; done && (( \$(tmux -L revive-panel-remote-$$ -f /dev/null capture-pane -p -t $farid | grep -c '^keys-42') >= 1 ))"
check "--keys turns away a bad pane id" "! rpanel --keys 'far:0.0' Enter && ! rpanel --keys '%0;touch $T/pwn' Enter && ! rpanel --keys %999 Enter && ! rpanel --keys $farid && [[ ! -e $T/pwn ]]"
check "--keys turns away keys not on its list" "! rpanel --keys $farid 'Enter;touch $T/pwn' && ! rpanel --keys $farid F1 && ! rpanel --keys $farid 'send-keys' && ! rpanel --keys $farid '\$(touch $T/pwn)' && [[ ! -e $T/pwn ]]"
check "--keys text: no control characters, bidi overrides or endless text" "! rpanel --keys $farid lit:0a && ! rpanel --keys $farid lit:\$(hex \$'a\\e[2J') && ! rpanel --keys $farid lit:c29b && ! rpanel --keys $farid lit:\$(hex \$'\\u202e') && ! rpanel --keys $farid lit:00 && ! rpanel --keys $farid lit:\$(hex \$(printf 'a%.0s' {1..65})) && ! rpanel --keys $farid lit:4"

# A question on the linked computer, answered from here over the link.
tmux -L "revive-panel-remote-$$" -f /dev/null new-window -d -t far -n ask "$T/bin/codex $T/ask.sh $T/ans3"
tmux -L "revive-panel-remote-$$" -f /dev/null set-option -p -t far:ask @agent far-ask
sleep 0.5
rm -f "$st/panel/far.example.rows" "$st/panel/"*.peek-*
tm new-window -d -t work -n farq "env AGENT_SAY_SSH=$T/fakessh REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX REVIVE_PANEL_REFRESH=1 bash $ROOT/scripts/panel.sh"
fq() { tm capture-pane -p -t work:farq; }
wait_fq() { for _ in $(seq 1 ${2:-50}); do fq | grep -qF -- "$1" && return 0; sleep 0.2; done; return 1; }
wait_fq 'far-ask' 60 >/dev/null
for _ in $(seq 1 25); do fq | grep -q '▶ far-ask' && break; tm send-keys -t work:farq Down; sleep 0.4; done
check "a linked computer's question shows here" "wait_fq 'QUESTION · far-ask' && wait_fq 'Do you want to proceed?'"
tm send-keys -t work:farq Enter; wait_fq 'ANSWERING far-ask' >/dev/null
tm send-keys -t work:farq Down
check "and its dialog follows the keys sent over the link" "wait_fq '❯ 2. No'"
tm send-keys -t work:farq Enter
check "and is answered from here" "for _ in \$(seq 1 40); do [[ -s $T/ans3 ]] && break; sleep 0.2; done; [[ \$(cat $T/ans3 2>/dev/null) == picked:2 ]]"
check "then its peek comes back" "wait_fq 'PEEK · far-ask' 100 && ! fq | grep -c 'ANSWERING' >/dev/null"
tm send-keys -t work:farq q; sleep 0.5
check "the panel takes the screens it fetched with it" "! ls $st/panel/ 2>/dev/null | grep -c 'peek-' >/dev/null"

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

echo "$pass passed, $fail failed"
((fail == 0))
