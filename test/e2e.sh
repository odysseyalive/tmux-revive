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

# Stand-ins for Codex and Cursor that expose sessions the way the real ones
# do (needs sqlite3): Codex through its logs/state databases, Cursor through
# the chat store.db it holds open.
AGENTS=0
if command -v sqlite3 >/dev/null; then
	AGENTS=1
	export CODEX_HOME=$T/codex CURSOR_CONFIG_DIR=$T/cursor
	mkdir -p "$CODEX_HOME" "$T/codexA" "$T/codexB" "$T/cur"
	sqlite3 "$CODEX_HOME/logs_2.sqlite" "create table logs(id integer primary key, ts integer, ts_nanos integer, thread_id text, process_uuid text)"
	sqlite3 "$CODEX_HOME/state_5.sqlite" "create table threads(id text primary key, cwd text, source text, archived integer, updated_at integer)"
	for tool in codex; do
		printf '#!/usr/bin/env bash\necho "$PWD $*" >>"%s/%s-launches"\nwhile :; do sleep 1; done\n' "$T" "$tool" >"$T/bin/$tool"
		chmod +x "$T/bin/$tool"
	done
	CHASH=$(printf '%s' "$T/cur" | md5sum | cut -c1-32)
	STORE=$CURSOR_CONFIG_DIR/chats/$CHASH/chat-abc123/store.db
	mkdir -p "$(dirname "$STORE")" && : >"$STORE"
	printf '#!/usr/bin/env bash\necho "$PWD $*" >>"%s/cursor-launches"\nexec 3<"%s"\nwhile :; do sleep 1; done\n' "$T" "$STORE" >"$T/bin/cursor-agent"
	chmod +x "$T/bin/cursor-agent"

	t new-session -d -s cx -c "$T/codexA" "$REVIVE_SHELL"
	t send-keys -t cx "CODEX_HOME=$CODEX_HOME $T/bin/codex" Enter
	t new-window -t cx -c "$T/codexB" "$REVIVE_SHELL"
	t send-keys -t cx:1 "CODEX_HOME=$CODEX_HOME $T/bin/codex resume 01aaaaaa-0000-7000-8000-000000000000" Enter
	t new-session -d -s cu -c "$T/cur" "$REVIVE_SHELL"
	t send-keys -t cu "CURSOR_CONFIG_DIR=$CURSOR_CONFIG_DIR $T/bin/cursor-agent --model gpt-9 'old prompt'" Enter
	sleep 1.5
	now=$(date +%s)
	pidA=$(pgrep -f "^bash $T/bin/codex\$")
	# A: the log ties its pid to a thread. B: only the state table knows.
	sqlite3 "$CODEX_HOME/logs_2.sqlite" "insert into logs(ts, ts_nanos, thread_id, process_uuid) values ($now, 0, '01aaaaaa-1111-7000-8000-000000000001', 'pid:$pidA:x')"
	sqlite3 "$CODEX_HOME/state_5.sqlite" "insert into threads values ('01aaaaaa-2222-7000-8000-000000000002', '$T/codexB', 'cli', 0, $now), ('01aaaaaa-3333-7000-8000-000000000003', '$T/codexB', 'cli', 0, $((now - 86400)))"
fi

echo "save"
HOME=$FAKEHOME bash "$ROOT/scripts/save.sh" manual --quiet
state=$REVIVE_DIR/last/state.json
check "snapshot written" "[[ -f $state ]]"
check "claude pane resolved to its session" "jq -e '.. | objects | select(.kind? == \"claude\") | .cmd | test(\"--resume 11111111-2222-3333-4444-555555555555\")' $state >/dev/null"
check "prompt argument dropped, --model kept" "jq -e '.. | objects | select(.kind? == \"claude\") | .cmd | (test(\"resend\") | not) and test(\"--model opus\")' $state >/dev/null"
check "remote control carried over" "jq -e '.. | objects | select(.kind? == \"claude\") | .cmd | test(\"--remote-control demo\")' $state >/dev/null"
check "pager pane captured as a program" "jq -e '.. | objects | select(.kind? == \"program\") | .cmd | test(\"less\")' $state >/dev/null"
check "split pane cwd kept" "jq -e '[.sessions[] | select(.name==\"work\") | .windows[0].panes[].cwd] | index(\"/tmp\")' $state >/dev/null"

if ((AGENTS)); then
	cx() { jq -r --arg d "$1" '.. | objects | select(.kind? == "'"$2"'" and .cwd == $d) | .cmd' "$state"; }
	check "codex: thread found through its process log" "[[ \$(cx $T/codexA codex) == *'resume 01aaaaaa-1111-7000-8000-000000000001' ]]"
	check "codex: resumed-then-switched thread found by recency, not argv" "[[ \$(cx $T/codexB codex) == *'resume 01aaaaaa-2222-7000-8000-000000000002' ]]"
	check "codex: CODEX_HOME carried over" "[[ \$(cx $T/codexA codex) == CODEX_HOME=* ]]"
	check "cursor: chat id from its open store.db, --model kept, prompt dropped" "[[ \$(cx $T/cur cursor) == 'cursor-agent --resume chat-abc123 --model gpt-9' ]]"
	pkill -f "$T/bin/codex"; pkill -f "$T/bin/cursor-agent"
fi

echo "reboot"
t kill-server
pkill -f "$T/bin/claude"
: >"$T/claude-launches"
t new-session -d -s 0 "$REVIVE_SHELL" # what a bare `tmux` makes
t set-option -g default-shell "$REVIVE_SHELL"
bash "$ROOT/scripts/restore.sh" --auto
sleep 2

sessions=$(t list-sessions -F '#{session_name}' | sort | tr '\n' ' ')
want='agent work '
((AGENTS)) && want='agent cu cx work '
check "sessions back, placeholder gone ($sessions)" "[[ '$sessions' == '$want' ]]"
check "work has 2 windows" "[[ \$(t list-windows -t work | wc -l) -eq 2 ]]"
check "first window has 2 panes" "[[ \$(t list-panes -t work:0 | wc -l) -eq 2 ]]"
check "layout restored exactly" "[[ \$(t display -p -t work:0 '#{window_layout}' | jq -c '[.L.c[].w]') == '[100,99]' ]]"
check "claude resumed exactly once, in its project" "[[ \$(wc -l <$T/claude-launches) -eq 1 ]] && grep -q '^$T/proj --resume 11111111-2222-3333-4444-555555555555' $T/claude-launches"
check "scrollback replayed" "t capture-pane -p -t work:0.1 -S -50 | grep -q marker-from-before-reboot"
check "pager relaunched" "t list-panes -a -F '#{pane_current_command}' | grep -q less"

if ((AGENTS)); then
	check "codex panes relaunched into their threads" "grep -q 'codexA resume 01aaaaaa-1111' $T/codex-launches && grep -q 'codexB resume 01aaaaaa-2222' $T/codex-launches"
	check "cursor relaunched into its chat" "grep -q 'cur --resume chat-abc123 --model gpt-9' $T/cursor-launches"
fi

echo "second restore is a no-op"
bash "$ROOT/scripts/restore.sh"
sleep 1
check "no duplicate claude" "[[ \$(wc -l <$T/claude-launches) -eq 1 ]]"

echo "$pass passed, $fail failed"
((fail == 0))
