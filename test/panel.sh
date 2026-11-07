#!/usr/bin/env bash
# tmux-revive panel on a private tmux server (never touches yours): what it shows, that it
# fits the terminal, and that its keys work.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/panel-test.XXXXXX")
unset TMUX TMUX_PANE
export REVIVE_DIR=$T/data AGENT_SAY_MAILBOX=$T/mail/mailbox.md REVIVE_PANEL_REFRESH=1
tm() { tmux -L "revive-panel-test-$$" -f /dev/null "$@"; }
pass=0 fail=0
check() {
	if eval "$2"; then
		printf '  \033[32mpass\033[0m %s\n' "$1"; ((pass++))
	else
		printf '  \033[31mFAIL\033[0m %s\n' "$1"; ((fail++))
	fi
}
cleanup() { tm kill-server 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
plain() { sed 's/\x1b\[[0-9;]*m//g'; }
screen() { tm capture-pane -p -t work:panel; }
wait_screen() { for _ in $(seq 1 30); do screen | grep -qF -- "$1" && return 0; sleep 0.2; done; return 1; }

tm new-session -d -s work -x 130 -y 40 "bash --norc --noprofile"
tm split-window -d -t work "top -d 5"
sleep 0.5

echo "one frame"
# Inside the private server, so the panel reads its panes, not yours.
frame() { tm run-shell "COLUMNS=$1 LINES=40 REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX bash $ROOT/scripts/panel.sh --once" | plain; }
for c in 80 100 130; do
	widths=$(frame "$c" | awk '{print length}' | sort -u | tr '\n' ' ')
	check "every line is exactly $c wide ($widths)" "[[ '$widths' == '$c ' ]]"
done
out=$(frame 130)
check "a shell pane shows as a shell" "grep -q 'bash *· shell' <<<\"\$out\""
check "a program shows as running" "grep -q 'top *▸ running' <<<\"\$out\""
check "the command keys are listed" "grep -qF '[J]ump  [M]essage  [N]ame  [P]eek  [S]ave  [Q]uit' <<<\"\$out\""
check "a narrow terminal still finds programs (ps not cut to COLUMNS)" "frame 80 | grep -q 'top *▸ running'"

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
tm send-keys -t work:panel p; sleep 1.5
check "P hides the peek box" "! screen | grep -q 'PEEK'"
tm send-keys -t work:panel Down
check "the arrow keys move the selection" "wait_screen '[3] ▶'"
tm send-keys -t work:panel q; sleep 1
check "Q quits" "! tm list-windows -F '#{window_name}' | grep -qx panel"

echo "$pass passed, $fail failed"
((fail == 0))
