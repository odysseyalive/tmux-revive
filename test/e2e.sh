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
# Run from inside tmux, $TMUX would point plain `tmux` at your server.
unset TMUX TMUX_PANE
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
cleanup() {
	t kill-server 2>/dev/null
	for k in sock2 sock3 sock4; do tmux -S "$T/$k" kill-server 2>/dev/null; done
	[[ -n ${KEEP:-} ]] || rm -rf "$T"
}
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
# The panel, the way `tmux-revive panel` runs it: bash .../scripts/panel.sh.
export AGENT_SAY_MAILBOX=$T/mail/mailbox.md AGENT_SAY_KNOWN_HOSTS=$T/known_hosts AGENT_SAY_KEYSCAN=false REVIVE_PANEL_SPLASH=0
t new-window -d -t agent -n panel -c "$T/proj" "$ROOT/bin/tmux-revive panel"
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

# Hostile input, all in one session dropped again after the restore: names
# that are tmux formats, forged Claude records, a planted Session.vim.
# #() jobs run with the server's environment; '##' makes a literal '#'.
export REVIVE_PWNED=$T/pwned
EVIL='x#(touch $REVIVE_PWNED)' EVILW='w#(touch $REVIVE_PWNED)'
t new-session -d -s "${EVIL//#/##}" -n "${EVILW//#/##}" -c "$T/proj" "$REVIVE_SHELL"
t new-window -t "=$EVIL" -c "$T/proj" "$REVIVE_SHELL"
t send-keys -t "=$EVIL:1" "$T/bin/claude forged-a" Enter
t new-window -t "=$EVIL" -c "$T/proj" "$REVIVE_SHELL"
t send-keys -t "=$EVIL:2" "$T/bin/claude forged-b" Enter
mkdir -p "$T/vimproj" && : >"$T/vimproj/Session.vim"
ln -s "$(command -v sleep)" "$T/bin/vim"
t new-window -t "=$EVIL" -c "$T/vimproj" "$REVIVE_SHELL"
t send-keys -t "=$EVIL:3" "$T/bin/vim 300" Enter
sleep 1
fa=$(pgrep -f "$T/bin/claude forged-a") fb=$(pgrep -f "$T/bin/claude forged-b")
# a: a shell command for an id, start time right. b: a real UUID, no procStart.
printf '{"pid":%s,"sessionId":"x; touch %s/pwned2","procStart":"%s"}' "$fa" "$T" "$(awk '{print $22}' /proc/"$fa"/stat)" >"$FAKEHOME/.claude/sessions/$fa.json"
printf '{"pid":%s,"sessionId":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}' "$fb" >"$FAKEHOME/.claude/sessions/$fb.json"

# A revive dir older versions left readable by everyone gets closed up.
mkdir -p "$REVIVE_DIR/snapshots" && chmod 755 "$REVIVE_DIR" && : >"$REVIVE_DIR/revive.log" && chmod 644 "$REVIVE_DIR/revive.log"

echo "save"
HOME=$FAKEHOME bash "$ROOT/scripts/save.sh" manual --quiet
state=$REVIVE_DIR/last/state.json
check "snapshot written" "[[ -f $state ]]"
check "revive dir is 700" "[[ \$(stat -c %a $REVIVE_DIR) == 700 ]]"
check "nothing in it readable by group or others" "[[ -z \$(find $REVIVE_DIR ! -type l -perm /077) ]]"
check "forged claude records ignored (bad id, no procStart)" "jq -e '[.. | objects | select(.kind? == \"claude\")] | length == 1' $state >/dev/null && ! grep -q -e pwned2 -e aaaaaaaa-bbbb $state"
check "Session.vim in the cwd does not add -S" "jq -e '.. | objects | select(.kind? == \"program\" and .cwd == \"$T/vimproj\") | .cmd | (test(\"vim 300\") and (test(\"-S\") | not))' $state >/dev/null"
check "claude pane resolved to its session" "jq -e '.. | objects | select(.kind? == \"claude\") | .cmd | test(\"--resume 11111111-2222-3333-4444-555555555555\")' $state >/dev/null"
check "prompt argument dropped, --model kept" "jq -e '.. | objects | select(.kind? == \"claude\") | .cmd | (test(\"resend\") | not) and test(\"--model opus\")' $state >/dev/null"
check "remote control carried over" "jq -e '.. | objects | select(.kind? == \"claude\") | .cmd | test(\"--remote-control demo\")' $state >/dev/null"
check "pager pane captured as a program" "jq -e '[.. | objects | select(.kind? == \"program\") | .cmd] | any(test(\"less\"))' $state >/dev/null"
check "panel captured as \`tmux-revive panel\` from its install" "jq -e --arg c \"$ROOT/bin/tmux-revive panel\" '[.. | objects | select(.kind? == \"program\") | .cmd] | index(\$c)' $state >/dev/null"
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

check "format names restored literally" "t has-session -t \"=\$EVIL\" && [[ \$(t display -p -t \"=\$EVIL:0\" '#{window_name}') == \"\$EVILW\" ]]"
check "format names did not run their #()" "[[ ! -e $T/pwned && ! -e $T/pwned2 ]]"
t kill-session -t "=$EVIL"
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
check "panel relaunched" "pgrep -f '$ROOT/scripts/panel.sh' >/dev/null"

if ((AGENTS)); then
	check "codex panes relaunched into their threads" "grep -q 'codexA resume 01aaaaaa-1111' $T/codex-launches && grep -q 'codexB resume 01aaaaaa-2222' $T/codex-launches"
	check "cursor relaunched into its chat" "grep -q 'cur --resume chat-abc123 --model gpt-9' $T/cursor-launches"
fi

echo "second restore is a no-op"
bash "$ROOT/scripts/restore.sh"
sleep 1
check "no duplicate claude" "[[ \$(wc -l <$T/claude-launches) -eq 1 ]]"

# The everyday flow, end to end, through tmux's own config: close the
# terminal you are attached from (a plain detach), "reboot", then type
# `tmux attach` in a new shell. No keys, no tmux-revive commands.
echo "close the terminal, reboot, tmux attach"
t kill-server
pkill -f "$T/bin/claude"
: >"$T/claude-launches"
unset REVIVE_SOCKET
cat >"$T/tmux.conf" <<CONF
set -g default-shell $REVIVE_SHELL
set -g @revive-interval 0
set -g @revive-shutdown-hook off
run-shell '$ROOT/revive.tmux'
CONF
# `tmux` here means the real tmux reading this config on the private socket.
real_tmux=$(command -v tmux)
printf '#!/bin/sh\nexec %q -S %q -f %q "$@"\n' "$real_tmux" "$T/sock2" "$T/tmux.conf" >"$T/bin/tmux"
chmod +x "$T/bin/tmux"
hash -r # forget the real tmux bash already looked up
[[ $(command -v tmux) == "$T/bin/tmux" ]] || { echo "refusing: plain tmux would reach a real server"; exit 1; }
rm -rf "$REVIVE_DIR"
export HOME=$FAKEHOME TMUX_REVIVE_BIN=$ROOT/bin/tmux-revive
tmux new-session -d -s agent -x 120 -y 40 -c "$T/proj"
sleep 1
check "no keys bound by default" "! tmux list-keys -T prefix | grep -q tmux-revive"
tmux send-keys -t agent "$T/bin/claude --model opus" Enter
sleep 1
cpid=$(pgrep -f "$T/bin/claude" | head -1)
start=$(awk '{print $22}' /proc/"$cpid"/stat 2>/dev/null)
rm -f "$FAKEHOME"/.claude/sessions/*.json
printf '{"pid":%s,"sessionId":"99999999-2222-3333-4444-555555555555","cwd":"%s","procStart":"%s"}' \
	"$cpid" "$T/proj" "$start" >"$FAKEHOME/.claude/sessions/$cpid.json"
script -qfc "tmux attach -t agent" /dev/null >/dev/null 2>&1 &
spid=$!
sleep 1
kill -HUP "$spid" 2>/dev/null # the terminal window closes
wait "$spid" 2>/dev/null
snapstate=$REVIVE_DIR/last/state.json
for _ in $(seq 50); do [[ -f $snapstate ]] && break; sleep 0.1; done
check "closing the terminal saved a snapshot" "jq -e '.reason == \"detach\"' $snapstate >/dev/null"
check "that snapshot holds the claude session" "jq -e '.. | objects | select(.kind? == \"claude\") | .cmd | test(\"--resume 99999999\")' $snapstate >/dev/null"

tmux kill-server
pkill -f "$T/bin/claude"
sleep 0.5
# A new terminal: an interactive shell with the installer's rc block, typing `tmux attach`.
script -qfc "bash --norc --noprofile -c '. $ROOT/scripts/shell.sh; tmux attach'" /dev/null >/dev/null 2>&1 &
spid=$!
sleep 3
out=$(tmux list-sessions -F '#{session_name}:#{session_attached}' 2>&1)
check "tmux attach after reboot is attached to the restored session ($out)" "[[ '$out' == 'agent:1' ]]"
check "claude resumed its exact conversation" "grep -q '^$T/proj --resume 99999999-2222-3333-4444-555555555555' $T/claude-launches"

# What you close stays closed: closing panes, windows and finally the last
# session (exiting tmux without detaching) must not come back next start.
echo "close things on purpose, exit tmux, start again"
snap_has() { jq -e "$1" "$REVIVE_DIR/last/state.json" >/dev/null 2>&1; }
wait_snap() { for _ in $(seq 100); do snap_has "$1" && return 0; sleep 0.1; done; return 1; }
tmux new-window -d -t agent -n extra -c "$T/proj"
tmux split-window -d -t agent:extra -c /tmp
bash "$ROOT/scripts/save.sh" manual --quiet
check "extra window saved" "snap_has '[.sessions[].windows[] | select(.name == \"extra\")] | length == 1'"
tmux send-keys -t agent:extra.1 'exit' Enter
check "typing exit in a pane saves without it" "wait_snap '.reason == \"close\" and ([.sessions[].windows[] | select(.name == \"extra\") | .panes[]] | length == 1)'"
tmux kill-window -t agent:extra
check "killing a window saves without it" "wait_snap '[.sessions[].windows[] | select(.name == \"extra\")] | length == 0'"
launches=$(wc -l <"$T/claude-launches")
tmux new-session -d -s last -c "$T/proj"
tmux kill-session -t agent
check "killing a session saves without it" "wait_snap '[.sessions[].name] == [\"last\"]'"
sleep 0.5
tmux send-keys -t last 'exit' Enter
check "typing exit in the last pane leaves an empty snapshot" "wait_snap '.sessions == [] and .reason == \"close\"'"
for _ in $(seq 50); do tmux has-session 2>/dev/null || break; sleep 0.1; done
check "tmux exited" "! tmux has-session 2>/dev/null"
check "the snapshot before it is still listed" "[[ \$(find $REVIVE_DIR/snapshots -mindepth 1 -maxdepth 1 | wc -l) -ge 2 ]]"
kill "$spid" 2>/dev/null
pkill -f "$T/bin/claude"
tmux new-session -d -s 0
sleep 2
check "a fresh tmux restores nothing" "[[ \$(tmux list-sessions -F '#{session_name}' | tr '\n' ' ') == '0 ' ]]"
check "claude was not relaunched" "[[ \$(wc -l <$T/claude-launches) -eq $launches ]]"
tmux kill-server
pkill -f "$T/bin/claude"

# A bare `tmux` hands off to `tmux-revive open`: one session attaches, several
# get a pick list (or, with no terminal to ask in, the most recent one).
echo "tmux opens a session, or a pick list"
calls=$T/tmux-calls
printf '#!/bin/sh\necho "$*" >>%q\nexec %q -S %q -f %q "$@"\n' "$calls" "$real_tmux" "$T/sock2" "$T/tmux.conf" >"$T/bin/tmux"
rm -rf "$REVIVE_DIR"
nsess() { tmux list-sessions 2>/dev/null | wc -l; }
tmux new-session -d -s solo -c "$T/proj"
sleep 1
script -qfc "bash --norc --noprofile -c '. $ROOT/scripts/shell.sh; tmux'" /dev/null >/dev/null 2>&1 &
spid=$!
for _ in $(seq 30); do [[ $(tmux list-clients -F x 2>/dev/null) ]] && break; sleep 0.1; done
out=$(tmux list-sessions -F '#{session_name}:#{session_attached}' 2>&1 | tr '\n' ' ')
check "bare tmux with one session attaches it, makes none ($out)" "[[ '$out' == 'solo:1 ' ]]"
kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null
tmux new-session -d -s older -c "$T/proj"
sleep 1.1
tmux new-session -d -s newer -c "$T/proj"
: >"$calls"
bash --norc --noprofile -c ". $ROOT/scripts/shell.sh; tmux" </dev/null >/dev/null 2>&1
id=$(tmux list-sessions -F '#{session_name} #{session_id}' | awk '$1 == "newer" { print $2 }')
check "no terminal, several sessions: attaches the most recent (by id), makes none" "[[ -n '$id' ]] && grep -qxF 'attach-session -t $id' $calls && [[ \$(nsess) -eq 3 ]]"
check "other tmux commands pass straight through" "bash --norc --noprofile -c '. $ROOT/scripts/shell.sh; tmux ls' | grep -q '^newer:'"

# A shell keeps the function it sourced; the app behind it is what updates.
mkdir -p "$T/app"
printf '#!/bin/sh\necho v1 "$@" >%q\n' "$T/handoff" >"$T/app/tr" && chmod +x "$T/app/tr"
TMUX_REVIVE_BIN=$T/app/tr bash --norc --noprofile -c ". $ROOT/scripts/shell.sh
	printf '#!/bin/sh\necho v2 \"\$@\" >%s\n' $T/handoff >$T/app/tr.new && chmod +x $T/app/tr.new && mv $T/app/tr.new $T/app/tr
	tmux attach -t x"
check "a shell from before an update runs the new app" "[[ \$(cat $T/handoff) == 'v2 open attach -t x' ]]"

# The pick list, driven through a pane of a second private server.
mkdir -p "$T/abin"
cp "$(command -v bash)" "$T/abin/crush"
printf '#!%s\nwhile :; do sleep 1; done\n' "$T/abin/crush" >"$T/bin/crush"
chmod +x "$T/bin/crush"
o() { "$real_tmux" -S "$T/sock3" -f /dev/null "$@"; }
PICK="env -u TMUX bash --norc --noprofile -c '. $ROOT/scripts/shell.sh; tmux; echo picker-exit-\$?; exec sleep 600'"
o new-session -d -s outer -x 150 -y 40 "sleep 600"
screen() { o capture-pane -p -t outer; }
wait_screen() { for _ in $(seq 50); do screen | grep -q -- "$1" && return 0; sleep 0.1; done; return 1; }
picker() { o respawn-pane -k -t outer "$PICK"; wait_screen 'enter attach'; }
row() { screen | sed -n "s/^.[ *]\{0,1\} *\([0-9]\)  $1 .*/\1/p" | head -1; }
keys() { o send-keys -t outer "$@"; sleep 0.4; }
# A confirmation drops keys sent with the one that asked for it (a paste can't answer
# it), so its answer goes in a keys call of its own.
on_screen() { [[ $(screen) == *"$1"* ]]; }
has() { # has NAME: a session by that exact name (=NAME would split at : and .)
	local n
	while IFS= read -r n; do [[ $n == "$1" ]] && return 0; done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)
	return 1
}
client_on() { for _ in $(seq 30); do [[ $(tmux list-clients -F '#{session_name}' 2>/dev/null) == "$1" ]] && return 0; sleep 0.1; done; return 1; }

picker
check "pick list shows sessions, windows and keys" "screen | grep -q 'solo .* 1 window ' && screen | grep -q 'x close'"
keys Escape
check "esc leaves without attaching" "wait_screen picker-exit-0 && [[ -z \$(tmux list-clients 2>/dev/null) ]]"

picker
keys "$(row older)" x
keys n
check "x, then n: nothing closed" "tmux has-session -t =older && screen | grep -q 'nothing closed'"
keys x
keys y
check "x, then y: that session is closed" "! tmux has-session -t =older 2>/dev/null"
check "closed is recorded, so it stays closed" "wait_snap '([.sessions[].name] | index(\"older\") | not) and ([.sessions[].name] | index(\"newer\"))'"
keys q

tmux new-session -d -s m1 -c "$T/proj"
tmux new-session -d -s m2 -c "$T/proj"
picker
keys "$(row m1)" Space
keys "$(row m2)" Space
check "space marks rows" "[[ \$(screen | grep -c '^\*') -eq 2 ]]"
keys x
check "one confirmation lists every marked session" "screen | grep -Eq 'close (m1, m2|m2, m1)\?'"
keys y
check "both marked sessions closed, the rest kept" "! tmux has-session -t =m1 2>/dev/null && ! tmux has-session -t =m2 2>/dev/null && tmux has-session -t =solo"

tmux new-session -d -s ag -c "$T/proj" "$T/bin/crush"
sleep 0.5
picker
check "a row names the agent running in it" "screen | grep -q ' ag .*crush'"
keys "$(row ag)" x
check "closing an agent session names the agent and asks for yes" "screen | grep -q 'ends crush in ag. type yes'"
keys y Enter
check "y is not enough for an agent session" "tmux has-session -t =ag && screen | grep -q 'nothing closed'"
keys x
keys yes Enter
check "yes closes it" "! tmux has-session -t =ag 2>/dev/null"
keys "$(row solo)" Enter
check "enter attaches the chosen session" "client_on solo"

picker
keys n
check "n makes a new session and attaches it" "client_on \$(tmux list-sessions -F '#{session_created} #{session_name}' | sort -n | tail -1 | cut -d' ' -f2) && [[ \$(nsess) -eq 3 ]]"

tmux new-session -d -s keep -c "$T/proj"
picker
keys "$(row keep)" a
check "a asks before closing every other session" "screen | grep -q 'close .*solo.*\[y/N\]'"
keys y
check "a keeps only the chosen one and attaches it" "client_on keep && [[ \$(tmux list-sessions -F '#{session_name}') == keep ]]"
check "the others are recorded closed" "wait_snap '[.sessions[].name] == [\"keep\"]'"
tmux new-session -d -s last -c "$T/proj"
picker
keys "$(row last)" x
keys y
check "one left: still waits for enter, attaches nothing" "! tmux has-session -t =last 2>/dev/null && screen | grep -q 'enter attach' && [[ -z \$(tmux list-clients 2>/dev/null) ]]"
keys x
keys y
check "none left: says so" "screen | grep -q 'no sessions left'"
keys Enter
check "none left: enter starts a fresh one" "for _ in \$(seq 30); do [[ \$(tmux list-clients 2>/dev/null) ]] && break; sleep 0.1; done; [[ \$(nsess) -eq 1 ]] && ! tmux has-session -t =keep 2>/dev/null"

# Names that aren't what they look like. tmux splits even an =exact target at : and .
# so the list acts by session id ($N), never by name.
tmux new-session -d -s victim -c "$T/proj"
tmux new-session -d -s victim:0 -c "$T/proj"
tmux new-session -d -s a:b.c -c "$T/proj"
picker
keys "$(row victim:0)" x
keys y
check "closing a decoy victim:0 closes the decoy, not victim" "! has victim:0 && has victim"
keys "$(row 'a:b\.c')" x
keys y
check "a session named a:b.c can be closed" "! has a:b.c && has victim"
keys q
n0=$(nsess)
o respawn-pane -k -t outer "$PICK"
o send-keys -t outer a y # typed right after `tmux`, before the list is up
wait_screen 'enter attach'
sleep 0.5
check "keys typed before the list draws answer nothing" "[[ \$(nsess) -eq $n0 ]] && has victim && ! on_screen '[y/N]' && [[ -z \$(tmux list-clients 2>/dev/null) ]]"
keys q
tmux new-session -d -s ren -c "$T/proj"
picker
r=$(row ren)
tmux rename-session -t =ren ren2 # after the list was drawn
keys "$r" x
keys y
check "a session renamed while the list was open isn't closed by its old row" "has ren2 && on_screen 'changed while the list was open' && on_screen ' ren2 '"
keys q
bidi=$'bidi\u202Eevil-and-then-a-long-tail'
tmux new-session -d -s "$bidi" -c "$T/proj"
picker
check "a name is shown without its bidi override" "on_screen ' bidievil-and-then-a-  ' && [[ \$(screen) != *$'\u202E'* ]]"
keys "$(row bidievil-and-then-a-)" x
check "the confirmation shows the whole name, cleaned" "on_screen 'close bidievil-and-then-a-long-tail?'"
keys n
check "n there: still there" "has \"\$bidi\""
keys q
o kill-server
tmux kill-server

# The installer loads tmux-revive into a running server, and says so loudly
# when that fails. All in a sandbox home with tmux on a private socket.
echo "installer"
inst() { # inst TMUX-WRAPPER: run install.sh in the sandbox, stdout+stderr to $T/inst.out
	mkdir -p "$T/ih" "$T/ib"
	cp "$1" "$T/ib/tmux"
	env -u REVIVE_DIR -u ZDOTDIR -u XDG_CONFIG_HOME HOME="$T/ih" XDG_DATA_HOME="$T/ih/.local/share" \
		TMUX_TMPDIR="$T/ih" CODEX_HOME="$T/ih/.codex" REVIVE_SOURCE="$ROOT" PATH="$T/ib:$PATH" \
		sh "$ROOT/install.sh" >"$T/inst.out" 2>&1
}
mkdir -p "$T/ih" && : >"$T/ih/.bashrc"
printf '#!/bin/sh\nexec %q -S %q -f /dev/null "$@"\n' "$real_tmux" "$T/sock4" >"$T/tmux-ok"
cat >"$T/tmux-bad" <<'EOF'
#!/bin/sh
case $1 in
-V) echo 'tmux 3.4' ;;
run-shell) printf 'boom: revive.tmux is broken\033]52;c;cHduZWQ=\a\302\2332J\033[2J\n' >&2; exit 1 ;;
show-option) exit 0 ;;
esac
exit 0
EOF
# revive.tmux stopped partway: its first option set, the rest (and its last step) never ran.
cat >"$T/tmux-half" <<EOF
#!/bin/sh
[ "\$1" = run-shell ] && exec $(printf %q "$T/tmux-ok") set-option -g @revive-bash /bin/bash
exec $(printf %q "$T/tmux-ok") "\$@"
EOF
chmod +x "$T/tmux-ok" "$T/tmux-bad" "$T/tmux-half"
# Started with the sandbox PATH: revive.tmux's own `tmux` calls must reach this server.
mkdir -p "$T/ib" && cp "$T/tmux-ok" "$T/ib/tmux"
PATH="$T/ib:$PATH" "$T/tmux-ok" new-session -d -s i
inst "$T/tmux-ok"; rc=$?
check "installer loads into the running server" "((rc == 0)) && grep -q 'running tmux server is protected' $T/inst.out && [[ -n \$($T/tmux-ok show -gqv @revive-loaded) ]]"
check "first install: tells open shells to restart" "grep -q 'exec \\\$SHELL -l' $T/inst.out"
inst "$T/tmux-bad"; rc=$?
check "a failed load is warned about, with tmux's error and the fix" "((rc == 0)) && grep -q 'did NOT load' $T/inst.out && grep -q 'boom: revive.tmux is broken' $T/inst.out && grep -q 'tmux source-file' $T/inst.out && ! grep -q 'is protected' $T/inst.out"
check "an update: no restart hint, the hand-off picks it up" "! grep -q 'exec \\\$SHELL -l' $T/inst.out"
no_esc() { local f; f=$(<"$T/inst.out"); [[ $f != *$'\e]52'* && $f != *$'\e[2J'* && $f != *$'\xc2\x9b'* ]]; }
check "tmux's error is printed without its escape sequences" "no_esc && grep -q 'boom: revive.tmux is broken' $T/inst.out"
loaded=$("$T/tmux-ok" show -gqv @revive-loaded)
inst "$T/tmux-half"; rc=$?
check "a revive.tmux that stops partway is reported as not loaded" "((rc == 0)) && grep -q 'did NOT load' $T/inst.out && ! grep -q 'is protected' $T/inst.out"
check "and the server's load mark is put back" "[[ -n '$loaded' && \$($T/tmux-ok show -gqv @revive-loaded) == '$loaded' ]]"
# An rc file with our BEGIN but no END is left alone, so nothing hands open shells off.
mv "$T/ih/.local/share/tmux-revive/app" "$T/app-was"
printf '%s\n' '# >>> tmux-revive >>>' >"$T/ih/.bashrc"
inst "$T/tmux-ok"
check "no restart hint when no rc file got the hand-off" "grep -q 'left it alone' $T/inst.out && ! grep -q 'exec \\\$SHELL -l' $T/inst.out"
"$T/tmux-ok" kill-server

echo "$pass passed, $fail failed"
((fail == 0))
