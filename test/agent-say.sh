#!/usr/bin/env bash
# agent-say on a private tmux server (never touches yours): delivery, names,
# long messages by id, and the cases where it must refuse to type.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/agent-say-test.XXXXXX")
unset TMUX TMUX_PANE XDG_RUNTIME_DIR
export TMPDIR=$T AGENT_SAY_MAILBOX=$T/mailbox.md AGENT_SAY_ENTER_DELAY=0.1 AGENT_SAY_MODE_WAIT=1
mkdir -p "$T/bin"
real_tmux=$(command -v tmux)
printf '#!/bin/sh\nexec %q -S %q -f /dev/null "$@"\n' "$real_tmux" "$T/sock" >"$T/bin/tmux"
chmod +x "$T/bin/tmux"
PATH="$T/bin:$PATH"
hash -r
[[ $(command -v tmux) == "$T/bin/tmux" ]] || { echo "refusing: tmux would reach a real server"; exit 1; }
say() { "$ROOT/bin/agent-say" "$@"; }
pass=0 fail=0
check() {
	if eval "$2"; then
		printf '  \033[32mpass\033[0m %s\n' "$1"; ((pass++))
	else
		printf '  \033[31mFAIL\033[0m %s\n' "$1"; ((fail++))
	fi
}
cleanup() { tmux kill-server 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

# Stand-in agents: `cat` shows whatever is typed into it, the way a prompt would.
tmux new-session -d -s s -x 200 -y 50 cat
A=$(tmux display -p -t s '#{pane_id}')
B=$(tmux split-window -d -P -F '#{pane_id}' -t s cat)
SH=$(tmux new-window -d -P -F '#{pane_id}' -t s 'exec /bin/bash --norc --noprofile')
sleep 0.5
AGENT_SAY_PANE=$A say name alpha >/dev/null
AGENT_SAY_PANE=$B say name beta >/dev/null
AGENT_SAY_PANE=$SH say name idle >/dev/null
seen() { tmux capture-pane -p -J -t "$1" -S -100 | grep -qF -- "$2"; }

echo "delivery"
AGENT_SAY_PANE=$A say beta "hello beta" >/dev/null
check "short message typed into the pane, with a reply command" "seen $B '[agent-msg from=alpha' && seen $B 'hello beta -- To answer, run the shell command: agent-say --from beta alpha'"
check "mailbox is private (600)" "[[ \$(stat -c %a $AGENT_SAY_MAILBOX) == 600 ]]"

long=$(printf 'line %s\n' $(seq 1 60))
AGENT_SAY_PANE=$A say beta - <<<"$long" >/dev/null
id=$(tmux capture-pane -p -J -t "$B" -S -100 | sed -n 's/.*agent-say show \([0-9-]*\)\..*/\1/p' | tail -1)
check "long message arrives as a notice with an id ($id)" "[[ -n '$id' ]]"
AGENT_SAY_PANE=$A say beta "a later short one" >/dev/null
check "show <id> prints exactly that message" "say show '$id' | grep -q 'line 60' && ! say show '$id' | grep -q 'later short'"

echo "refusals"
out=$(AGENT_SAY_PANE=$A say idle "rm -rf ~" 2>&1)
check "a pane at a shell prompt is refused ($out)" "[[ '$out' == *'prompt that would run the message as a command'* ]]"
check "nothing was typed into the shell" "! seen $SH 'agent-msg'"

tmux copy-mode -t "$B"
out=$(AGENT_SAY_PANE=$A say beta "while scrolled" 2>&1)
check "a pane in copy mode is refused after waiting" "[[ '$out' == *'copy mode'* ]]"
tmux send-keys -t "$B" -X cancel

out=$(AGENT_SAY_PANE=$B say name alpha 2>&1)
check "naming a second pane alpha warns" "[[ '$out' == *'also named'* ]]"
out=$(AGENT_SAY_PANE=$SH say alpha "who gets this" 2>&1)
check "sending to a name two panes share is refused" "[[ '$out' == *'more than one pane'* ]] && ! seen $A 'who gets this'"
AGENT_SAY_PANE=$B say name beta >/dev/null

check "a name can't contain @" "! AGENT_SAY_PANE=$A say name 'a@b' 2>/dev/null"
check "an unknown pane id is refused" "! say %999 'hi' 2>/dev/null"

echo "locks"
lock="$T/agent-say-$(id -u)-${B#%}.lock"
mkdir "$lock" && echo 999999 >"$lock/pid" # left behind by a sender that was killed
check "a lock left by a dead sender is cleared" "AGENT_SAY_PANE=$A say beta 'after stale lock' >/dev/null && seen $B 'after stale lock'"
check "the lock is released after sending" "[[ ! -e $lock ]]"

echo "naming renames the window and the agent's session"
# Stand-in agents named like the real ones. Each records what is typed into it, and shows a
# "working" line until a flag file appears, the way a busy agent does.
export HOME=$T/home AGENT_SAY_RENAME_WAIT=20
mkdir -p "$HOME/.claude/sessions" "$T/cx"
for a in claude codex; do
	cat >"$T/bin/$a" <<EOF
#!/usr/bin/env bash
while [[ ! -e $T/$a.idle ]]; do printf '\r* Working (esc to interrupt) %s' "\$SECONDS"; sleep 0.2; done
clear; echo '> '
while IFS= read -r line; do echo "\$line" >>$T/$a.typed; done
EOF
	chmod +x "$T/bin/$a"
done
typed() { [[ -f $T/$1.typed ]] && grep -qxF -- "$2" "$T/$1.typed"; }
wait_typed() { for _ in $(seq 60); do typed "$1" "$2" && return 0; sleep 0.25; done; return 1; }

C=$(tmux new-window -d -P -F '#{pane_id}' -t s "$T/bin/claude")
sleep 0.5
cpid=$(pgrep -f "^bash $T/bin/claude\$")
printf '{"pid":%s,"name":"auto-1","nameSource":"derived","status":"busy"}' "$cpid" >"$HOME/.claude/sessions/$cpid.json"
out=$(AGENT_SAY_PANE=$C say name gamma 2>&1)
check "naming says the claude session will follow" "[[ '$out' == *'claude session will be renamed'* ]]"
check "window renamed (the pane has it to itself)" "[[ \$(tmux display -p -t $C '#{window_name}') == gamma ]]"
sleep 2
check "nothing typed while claude is working" "! typed claude '/rename gamma'"
touch "$T/claude.idle"
printf '{"pid":%s,"name":"auto-1","nameSource":"derived","status":"idle"}' "$cpid" >"$HOME/.claude/sessions/$cpid.json"
check "/rename typed once claude is idle" "wait_typed claude '/rename gamma'"
check "the pane lock was released" "[[ -z \$(find $T -maxdepth 1 -name 'agent-say-*.lock') ]]"

printf '{"pid":%s,"name":"from-claude","nameSource":"user","status":"idle"}' "$cpid" >"$HOME/.claude/sessions/$cpid.json"
out=$(AGENT_SAY_PANE=$C say name 2>&1)
check "no name given: the claude session's own name is used" "[[ \$(tmux display -p -t $C '#{@agent}') == from-claude ]]"
check "and it isn't typed back as a rename" "[[ '$out' != *'will be renamed'* ]]"
out=$(AGENT_SAY_PANE=$SH say name 2>&1)
check "no name given in a plain shell pane is refused" "grep -q 'no name of its own' <<<\"\$out\""
out=$(AGENT_SAY_PANE=$A say name alpha2 2>&1)
check "a pane sharing its window leaves the window name alone" "[[ '$out' == *'window not renamed'* ]]"

# Codex runs commands in a shared background server, outside any pane: agent-say finds the
# one Codex pane working in the command's directory.
X=$(tmux new-window -d -P -F '#{pane_id}' -t s -c "$T/cx" "$T/bin/codex")
sleep 0.5
out=$(cd "$T/cx" && TMUX_PANE=$A bash -c 'exec -a "codex app-server" bash -c "\"\$0\" name delta; true" '"$ROOT/bin/agent-say" 2>&1)
check "from inside codex's server, the codex pane in this directory is found ($out)" "[[ \$(tmux display -p -t $X '#{@agent}') == delta ]] && [[ \$(tmux display -p -t $A '#{@agent}') != delta ]]"
sleep 1.5
check "nothing typed while codex shows it is working" "! typed codex '/rename delta'"
touch "$T/codex.idle"
check "/rename typed once codex is idle" "wait_typed codex '/rename delta'"

echo "$pass passed, $fail failed"
((fail == 0))
