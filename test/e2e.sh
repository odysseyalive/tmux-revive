#!/usr/bin/env bash
# End-to-end test on a private tmux server (never touches yours):
# build sessions with a fake Claude Code process, save, kill the server,
# start a fresh one the way `tmux` does after a reboot, auto-restore, check.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/revive-e2e.XXXXXX")
# bash --norc everywhere: your rc files must not change PATH under the test,
# or a typed `claude` could reach the real CLI.
export REVIVE_SOCKET=$T/sock REVIVE_DIR=$T/data SHELL=/bin/bash
mkdir -p "$T/sh"
printf '#!/bin/sh\nexec /bin/bash --norc --noprofile "$@"\n' >"$T/sh/bash"
chmod +x "$T/sh/bash"
export REVIVE_SHELL=$T/sh/bash
FAKEHOME=$T/home
mkdir -p "$FAKEHOME/.claude/sessions" "$T/bin" "$T/proj"
PATH="$T/bin:$PATH"
t() { tmux -S "$REVIVE_SOCKET" -f /dev/null "$@"; }
pass=0 fail=0
check() {
	if eval "$2"; then
		printf '  \033[32mpass\033[0m %s\n' "$1"; ((pass++))
	else
		printf '  \033[31mFAIL\033[0m %s\n' "$1"; ((fail++))
	fi
}
cleanup() { t kill-server 2>/dev/null; [[ -n ${KEEP:-} ]] || rm -rf "$T"; }
trap cleanup EXIT

# A stand-in `claude` that records how it was launched and stays running.
cat >"$T/bin/claude" <<EOF
#!/usr/bin/env bash
echo "\$PWD \$*" >>"$T/claude-launches"
while :; do sleep 1; done
EOF
chmod +x "$T/bin/claude"

t new-session -d -s work -x 200 -y 50 -c "$T/proj" "$REVIVE_SHELL"
t set-option -g default-shell "$REVIVE_SHELL"
t split-window -h -t work:1 -c /tmp 2>/dev/null || t split-window -h -t work -c /tmp
t send-keys -t work:0.1 'echo marker-from-before-reboot' Enter
t new-window -t work -n pager -c "$T/proj" "less /etc/hostname"
t new-session -d -s agent -c "$T/proj"
t send-keys -t agent "$T/bin/claude --model opus 'do not resend this prompt'" Enter
sleep 1

# Register it the way Claude Code does: <config>/sessions/<pid>.json
cpid=$(pgrep -f "$T/bin/claude" | head -1)
start=$(awk '{print $22}' /proc/"$cpid"/stat 2>/dev/null)
printf '{"pid":%s,"sessionId":"11111111-2222-3333-4444-555555555555","cwd":"%s","procStart":"%s","name":"demo","bridgeSessionId":"session_x"}' \
	"$cpid" "$T/proj" "$start" >"$FAKEHOME/.claude/sessions/$cpid.json"

echo "save"
HOME=$FAKEHOME bash "$ROOT/scripts/save.sh" manual --quiet
state=$REVIVE_DIR/last/state.json
check "snapshot written" "[[ -f $state ]]"
check "claude pane resolved to its session" "jq -e '.. | objects | select(.kind? == \"claude\") | .cmd | test(\"--resume 11111111-2222-3333-4444-555555555555\")' $state >/dev/null"
check "prompt argument dropped, --model kept" "jq -e '.. | objects | select(.kind? == \"claude\") | .cmd | (test(\"resend\") | not) and test(\"--model opus\")' $state >/dev/null"
check "remote control carried over" "jq -e '.. | objects | select(.kind? == \"claude\") | .cmd | test(\"--remote-control demo\")' $state >/dev/null"
check "pager pane captured as a program" "jq -e '.. | objects | select(.kind? == \"program\") | .cmd | test(\"less\")' $state >/dev/null"
check "split pane cwd kept" "jq -e '[.sessions[] | select(.name==\"work\") | .windows[0].panes[].cwd] | index(\"/tmp\")' $state >/dev/null"

echo "reboot"
t kill-server
pkill -f "$T/bin/claude"
: >"$T/claude-launches"
t new-session -d -s 0 "$REVIVE_SHELL" # what a bare `tmux` makes
t set-option -g default-shell "$REVIVE_SHELL"
bash "$ROOT/scripts/restore.sh" --auto
sleep 2

sessions=$(t list-sessions -F '#{session_name}' | sort | tr '\n' ' ')
check "sessions back, placeholder gone ($sessions)" "[[ '$sessions' == 'agent work ' ]]"
check "work has 2 windows" "[[ \$(t list-windows -t work | wc -l) -eq 2 ]]"
check "first window has 2 panes" "[[ \$(t list-panes -t work:0 | wc -l) -eq 2 ]]"
check "layout restored exactly" "[[ \$(t display -p -t work:0 '#{window_layout}' | jq -c '[.L.c[].w]') == '[100,99]' ]]"
check "claude resumed exactly once, in its project" "[[ \$(wc -l <$T/claude-launches) -eq 1 ]] && grep -q '^$T/proj --resume 11111111-2222-3333-4444-555555555555' $T/claude-launches"
check "scrollback replayed" "t capture-pane -p -t work:0.1 -S -50 | grep -q marker-from-before-reboot"
check "pager relaunched" "t list-panes -a -F '#{pane_current_command}' | grep -q less"

echo "second restore is a no-op"
bash "$ROOT/scripts/restore.sh"
sleep 1
check "no duplicate claude" "[[ \$(wc -l <$T/claude-launches) -eq 1 ]]"

echo "$pass passed, $fail failed"
((fail == 0))
