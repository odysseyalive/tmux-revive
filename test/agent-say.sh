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
mkdir -p "$HOME/.claude/sessions" "$T/cx" "$T/abin"
for a in claude codex; do
	# Run by a copy of bash named after the agent, so tmux sees "codex", not a shell.
	cp "$(command -v bash)" "$T/abin/$a"
	cat >"$T/bin/$a" <<EOF
#!$T/abin/$a
while [[ ! -e $T/$a.idle ]]; do printf '\r* Working (esc to interrupt) %s' "\$SECONDS"; sleep 0.2; done
clear
while printf '> ' && IFS= read -r line; do echo "\$line" >>$T/$a.typed; done
EOF
	chmod +x "$T/bin/$a"
done
typed() { [[ -f $T/$1.typed ]] && grep -qxF -- "$2" "$T/$1.typed"; }
wait_typed() { for _ in $(seq 60); do typed "$1" "$2" && return 0; sleep 0.25; done; return 1; }

C=$(tmux new-window -d -P -F '#{pane_id}' -t s "$T/bin/claude")
sleep 0.5
cpid=$(pgrep -f "^$T/abin/claude $T/bin/claude\$")
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
sleep 0.5
tmux send-keys -t "$X" -l 'half a sentence'
sleep 3
check "nothing typed while someone has a draft in the prompt" "! typed codex '/rename delta' && ! typed codex 'half a sentence/rename delta'"
tmux send-keys -t "$X" C-u
check "/rename typed once codex is idle and its prompt is empty" "wait_typed codex '/rename delta'"
check "and the draft never got sent" "! grep -q 'half a sentence' $T/codex.typed"

tmux send-keys -t "$X" -l 'another draft'
out=$(AGENT_SAY_TYPING_WAIT=1 AGENT_SAY_PANE=$A say delta "do not land on the draft" 2>&1)
check "a message waits for someone typing, then is refused ($out)" "grep -q 'someone is typing' <<<\"\$out\""
tmux send-keys -t "$X" C-u
sleep 0.3
AGENT_SAY_PANE=$A say delta "after the draft" >/dev/null 2>&1
check "with the prompt empty it is delivered" "wait_typed codex '[agent-msg from=alpha2 \$(date -u +%H:%MZ)] after the draft -- To answer, run the shell command: agent-say --from delta alpha2 \"<your reply>\"' || grep -q 'after the draft' $T/codex.typed"

echo "a link to a machine you ssh into"
# A second private tmux server stands in for the machine you ssh into, and a fake ssh runs
# commands "there": its own tmux, state and mailbox. Nothing reaches a real ssh or tmux.
mkdir -p "$T/rbin" "$T/rstate" "$T/rtmp" "$T/rhome"
printf '#!/bin/sh\nexec %q -S %q -f /dev/null "$@"\n' "$real_tmux" "$T/rsock" >"$T/rbin/tmux"
chmod +x "$T/rbin/tmux"
cat >"$T/bin/fakessh" <<EOF
#!/usr/bin/env bash
while [[ \$1 == -* ]]; do case \$1 in -o | -p | -i) shift 2 ;; *) shift ;; esac; done
shift # the host
exec env -u AGENT_SAY_PANE -u AGENT_SAY_LOCAL_ONLY PATH="$T/rbin:\$PATH" XDG_STATE_HOME=$T/rstate \\
	AGENT_SAY_MAILBOX=$T/rstate/agent-say/mailbox.md AGENT_SAY_HOST=devbox-1 TMPDIR=$T/rtmp HOME=$T/rhome \\
	bash -c "\$*"
EOF
chmod +x "$T/bin/fakessh"
export AGENT_SAY_SSH=$T/bin/fakessh AGENT_SAY_REMOTE_CMD=$ROOT/bin/agent-say AGENT_SAY_HOST=laptop AGENT_SAY_LINK_INTERVAL=0.3
there() { "$T/bin/fakessh" devbox "$*"; }
"$T/rbin/tmux" new-session -d -s r -x 200 -y 50 cat
RC=$("$T/rbin/tmux" display -p -t r '#{pane_id}')
there "AGENT_SAY_PANE=$RC $ROOT/bin/agent-say name codex" >/dev/null
LC=$(tmux new-window -d -P -F '#{pane_id}' -t s cat)
sleep 0.3
AGENT_SAY_PANE=$LC say name me >/dev/null
seen_there() { "$T/rbin/tmux" capture-pane -p -J -t "$RC" -S -100 | grep -qF -- "$1"; }
wait_seen() { for _ in $(seq 40); do seen "$1" "$2" && return 0; sleep 0.25; done; return 1; }

out=$(say link devbox 2>&1)
check "link reaches the other machine and lists its panes ($out)" "[[ '$out' == *'Its panes: codex'* ]]"
check "the link keeps running in the background" "say link | grep -q '^devbox  running'"
AGENT_SAY_PANE=$LC say codex "ping from here" >/dev/null
check "a plain name reaches the pane on the linked machine" "seen_there '[agent-msg from=me@laptop' && seen_there 'ping from here'"
check "its reply command points back here" "seen_there 'agent-say --from codex me@laptop'"
there "$ROOT/bin/agent-say --from codex me@laptop 'pong from codex'" >/dev/null
check "a reply from there arrives here, with no way in to this machine" "wait_seen $LC 'pong from codex'"
check "and says who sent it, as an address that works from here" "seen $LC '[agent-msg from=codex@devbox'"
there "$ROOT/bin/agent-say --from codex me 'plain name back'" >/dev/null
check "the other side can use a plain name too" "wait_seen $LC 'plain name back'"
check "list shows the linked machine's names" "say list | grep -q 'codex@devbox'"
there "$ROOT/bin/agent-say --from codex nobody@laptop 'lost'" >/dev/null
sleep 1.5
check "a message for a name that isn't here lands in the mailbox, marked" "grep -q 'NOT DELIVERED' $AGENT_SAY_MAILBOX"

echo "the link is robust against the other side"
outbox=$T/rstate/agent-say/peers/laptop/outbox
forge() { printf '%s\n%s\n%s' "$2" codex "$3" >"$outbox/$1"; } # what a compromised server could queue
forge 20990101000000-1-1 'x@-oProxyCommand=touch${IFS}'"$T"'/pwned' 'run this'
forge 20990101000000-1-2 '%0' 'straight to a pane id'
forge 20990101000000-1-3 'read' 'a name that is a command'
sleep 2
check "a forged address can't make this machine run anything" "[[ ! -e $T/pwned ]]"
check "forged addresses are refused into the mailbox, not delivered" "[[ \$(grep -c 'is not a pane name' $AGENT_SAY_MAILBOX) -ge 3 ]]"
check "and acknowledged, so they aren't fetched again" "[[ -z \$(ls $outbox) ]]"
check "a pane can't be named like a command" "! AGENT_SAY_PANE=$LC say name read 2>/dev/null"
check "a sender name with a space is refused" "! AGENT_SAY_PANE=$LC say --from 'a b' codex 'x' 2>/dev/null"

"$T/rbin/tmux" set-option -p -t "$RC" -u @agent # nothing named on the other side
there "$ROOT/bin/agent-say --from codex me 'with nothing named there'" >/dev/null 2>&1
there "$ROOT/bin/agent-say --from codex me@laptop 'with nothing named there'" >/dev/null
check "the link still works when the other side has no named panes" "wait_seen $LC 'with nothing named there'"
"$T/rbin/tmux" set-option -p -t "$RC" @agent codex

# Someone typing in the pane a message is for: the link retries instead of stalling.
tmux send-keys -t "$X" -l 'my draft'
sleep 0.5
there "$ROOT/bin/agent-say --from codex delta@laptop 'after your draft'" >/dev/null
sleep 2
check "a message waits while someone types there" "! grep -q 'after your draft' $T/codex.typed"
check "and the link keeps checking in meanwhile" "[[ -n \$(find $T/rstate/agent-say/peers/laptop/alive -newermt '-2 seconds') ]]"
tmux send-keys -t "$X" C-u
check "it is delivered once the prompt is empty" "wait_typed codex '[agent-msg from=codex@devbox \$(date -u +%H:%MZ)] after your draft -- To answer, run the shell command: agent-say --from delta codex@devbox \"<your reply>\"' || grep -q 'after your draft' $T/codex.typed"
check "and only once" "[[ \$(grep -c 'after your draft' $T/codex.typed) -eq 1 ]]"

say _resume-links; say _resume-links; sleep 0.5
check "starting the link twice runs one poller" "[[ \$(pgrep -fc 'agent-say _poll devbox') -eq 1 ]]"

# Stop the poller (as a reboot would), then queue: the message waits, and unlink marks it.
pkill -f 'agent-say _poll devbox'; sleep 0.3
there "$ROOT/bin/agent-say --from codex me@laptop 'never fetched'" >/dev/null
say unlink devbox >/dev/null
sleep 0.5
check "unlink stops it" "! pgrep -f 'agent-say _poll devbox' >/dev/null"
check "and the other side marks what it held as NOT DELIVERED" "grep -q 'NOT DELIVERED: laptop unlinked' $T/rstate/agent-say/mailbox.md && [[ -z \$(ls $outbox) ]]"
"$T/rbin/tmux" kill-server

echo "$pass passed, $fail failed"
((fail == 0))
