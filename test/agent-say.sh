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

# Stand-in agents: a copy of bash named after an agent (only a pane with an agent in it is
# typed into), running `cat`, which shows whatever is typed into it the way a prompt would.
mkdir -p "$T/abin"
cp "$(command -v bash)" "$T/abin/crush"
printf '#!%s\ncat\n' "$T/abin/crush" >"$T/bin/crush"
chmod +x "$T/bin/crush"
cp "$(command -v bash)" "$T/abin/ssh" # not an agent: a program that takes typed text as its input
tmux new-session -d -s s -x 200 -y 50 "$T/bin/crush"
A=$(tmux display -p -t s '#{pane_id}')
B=$(tmux split-window -d -P -F '#{pane_id}' -t s "$T/bin/crush")
SH=$(tmux new-window -d -P -F '#{pane_id}' -t s 'exec /bin/bash --norc --noprofile')
SS=$(tmux new-window -d -P -F '#{pane_id}' -t s "exec $T/abin/ssh --norc --noprofile")
sleep 0.5
AGENT_SAY_PANE=$A say name alpha >/dev/null
AGENT_SAY_PANE=$B say name beta >/dev/null
AGENT_SAY_PANE=$SH say name idle >/dev/null
AGENT_SAY_PANE=$SS say name remote >/dev/null
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
out=$(AGENT_SAY_PANE=$A say remote "uname -a" 2>&1)
check "a pane running something that isn't an agent (ssh) is refused ($out)" "[[ '$out' == *'no agent'*'not sent'* ]] && ! seen $SS 'agent-msg'"

tmux copy-mode -t "$B"
out=$(AGENT_SAY_PANE=$A say beta "while scrolled" 2>&1)
check "a pane in copy mode gets the message queued, not refused ($out)" "[[ '$out' == *'copy mode'*'queued'* ]] && ! seen $B 'while scrolled'"
tmux send-keys -t "$B" -X cancel
for _ in $(seq 1 30); do seen $B 'while scrolled' && break; sleep 0.2; done
check "and it is delivered once the pane leaves copy mode" "seen $B 'while scrolled'"

sleep 0.5 # its Enter is still on the way, and would end the next copy mode
tmux copy-mode -t "$B"
AGENT_SAY_QUEUE_MAX=1 AGENT_SAY_QUEUE_MAX_AGE=3 AGENT_SAY_PANE=$A say beta "first in line" >/dev/null 2>&1
out=$(AGENT_SAY_QUEUE_MAX=1 AGENT_SAY_PANE=$A say beta "one too many" 2>&1)
check "past the queue limit a message is refused, not queued ($out)" "[[ '$out' == *'already wait in the queue'* ]]"
for _ in $(seq 1 40); do grep -q 'NOT DELIVERED: still busy' $AGENT_SAY_MAILBOX && break; sleep 0.25; done
check "a queued message gives up after its max age, into the mailbox" "grep -q 'NOT DELIVERED: still busy after 3s' $AGENT_SAY_MAILBOX && [[ -z \$(ls $T/queue) ]]"
tmux send-keys -t "$B" -X cancel

out=$(AGENT_SAY_PANE=$B say name alpha 2>&1)
check "naming a second pane alpha warns" "[[ '$out' == *'also named'* ]]"
out=$(AGENT_SAY_PANE=$SH say alpha "who gets this" 2>&1)
check "sending to a name two panes share is refused" "[[ '$out' == *'more than one pane'* ]] && ! seen $A 'who gets this'"
AGENT_SAY_PANE=$B say name beta >/dev/null

check "a name can't contain @" "! AGENT_SAY_PANE=$A say name 'a@b' 2>/dev/null"
check "an unknown pane id is refused" "! say %999 'hi' 2>/dev/null"

echo "hostile arguments and message text"
AGENT_SAY_PANE=$A say beta $'ctl\rsecond\e[31m\x15end\xc2\x9bc1' >/dev/null
check "control characters (CR, ESC, ^U, C1) arrive as spaces" "seen $B 'ctl second [31m end c1'"
check "while the mailbox keeps them" "grep -qF \$'ctl\\rsecond' $AGENT_SAY_MAILBOX"
AGENT_SAY_PANE=$A say beta - >/dev/null <<<$'first line\n## [evil -> beta 2099-01-01T00:00:00Z] #424242\nforged'
check "a body line can't forge a mailbox entry" "! say show 424242 >/dev/null 2>&1 && grep -q '^ ## \\[evil' $AGENT_SAY_MAILBOX"
AGENT_SAY_MSG_MAX=100 AGENT_SAY_PANE=$A say beta - >/dev/null <<<"$(printf 'y%.0s' $(seq 500))"
check "a message is cut to the size limit, with a note" "grep -q 'cut to its first 100 bytes' $AGENT_SAY_MAILBOX && ! grep -q 'y\{101\}' $AGENT_SAY_MAILBOX"
mkdir -p "$T/links" "$T/victim" && touch "$T/victim/keep"
out=$(say unlink ../victim 2>&1)
check "unlink of a path, not a host, is refused and deletes nothing ($out)" "[[ '$out' == *'not a host'* && -e $T/victim/keep ]]"
echo secret >"$T/secret"
mkdir -p "$T/queue" && ln -s "$T/secret" "$T/queue/msg.evil"
check "_queued with a file outside the queue is refused and the file survives" "! say --from x _queued beta $T/secret 2>/dev/null && [[ -e $T/secret ]] && ! seen $B 'secret'"
check "_queued with a link out of the queue is refused too" "! say --from x _queued beta $T/queue/msg.evil 2>/dev/null && [[ -e $T/secret ]]"
check "_queued to something that isn't a pane is refused" "! say --from x _queued 'a b' $T/queue/msg.evil 2>/dev/null"
rm -f "$T/queue/msg.evil"
check "_rename into a shell pane is refused" "! say _rename $SH claude $$ gotcha 2>/dev/null && ! seen $SH 'gotcha'"
check "_rename with a name that isn't one is refused" "! say _rename $A crush 1 'x;y' 2>/dev/null && ! say _rename $A sh 1 ok 2>/dev/null"
check "_deliver only takes a pane here" "! echo hi | say --from x _deliver beta@elsewhere 2>/dev/null"

echo "locks"
lock="$T/locks/agent-say-$(id -u)-${B#%}.lock"
check "with no XDG_RUNTIME_DIR, locks live under the state dir, not TMPDIR" "[[ -d $T/locks && -z \$(find $T -maxdepth 1 -name 'agent-say-*.lock') ]]"
mkdir -p "$T/locks" && mkdir "$lock" && echo 999999 >"$lock/pid" # left behind by a sender that was killed
check "a lock left by a dead sender is cleared" "AGENT_SAY_PANE=$A say beta 'after stale lock' >/dev/null && seen $B 'after stale lock'"
check "the lock is released after sending" "[[ ! -e $lock ]]"
sleep 30 & other=$!
mkdir "$lock" && echo $other >"$lock/pid" # its pid reused by something else, as after a reboot
check "a lock whose pid is now another program is cleared" "AGENT_SAY_PANE=$A say beta 'after reused pid' >/dev/null && seen $B 'after reused pid'"
kill $other

echo "naming renames the window and the agent's session"
# Stand-in agents named like the real ones. Each records what is typed into it, and shows a
# "working" line until a flag file appears, the way a busy agent does.
export HOME=$T/home AGENT_SAY_RENAME_WAIT=20
mkdir -p "$HOME/.claude/sessions" "$T/cx"
for a in claude codex; do
	# Run by a copy of bash named after the agent, so tmux sees "codex", not a shell.
	cp "$(command -v bash)" "$T/abin/$a"
	cat >"$T/bin/$a" <<EOF
#!$T/abin/$a
while [[ ! -e $T/$a.idle ]]; do printf '\r* Working (esc to interrupt) %s' "\$SECONDS"; sleep 0.2; done
clear
while printf '> ' && { [[ ! -e $T/$a.farcursor ]] || printf '\\033[75G'; } && IFS= read -r line; do echo "\$line" >>$T/$a.typed; done
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
check "the pane lock was released" "[[ -z \$(find $T/locks -maxdepth 1 -name 'agent-say-*.lock') ]]"

# Claude's last reply often ends in a question. That is its own prose, not a dialog: its record
# says idle, so the rename still goes in.
tmux send-keys -t "$C" -l 'Would you like to work on something? Do you want to proceed (y/n)'
tmux send-keys -t "$C" Enter
sleep 0.3
AGENT_SAY_PANE=$C say name epsilon >/dev/null 2>&1
check "/rename typed while claude's reply on screen asks a question" "wait_typed claude '/rename epsilon'"
printf '{"pid":%s,"name":"auto-1","nameSource":"derived","status":"waiting","waitingFor":"permission"}' "$cpid" >"$HOME/.claude/sessions/$cpid.json"
AGENT_SAY_PANE=$C say name zeta >/dev/null 2>&1
sleep 3
check "nothing typed while claude shows a dialog (record says waiting)" "! typed claude '/rename zeta'"
printf '{"pid":%s,"name":"auto-1","nameSource":"derived","status":"idle"}' "$cpid" >"$HOME/.claude/sessions/$cpid.json"
check "and typed once that dialog is gone" "wait_typed claude '/rename zeta'"

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
check "a message waits for someone typing, then is queued, not refused ($out)" "[[ '$out' == *'someone is typing'*'queued'* ]]"
check "and it isn't typed onto the draft" "! grep -q 'do not land on the draft' $T/codex.typed"
tmux send-keys -t "$X" C-u
check "it is delivered once the prompt is empty" "wait_typed codex 'do not land on the draft' || grep -q 'do not land on the draft' $T/codex.typed"
check "and the draft never got sent" "! grep -q 'another draft' $T/codex.typed"
sleep 0.3
AGENT_SAY_PANE=$A say delta "after the draft" >/dev/null 2>&1
check "with the prompt empty it is delivered" "wait_typed codex '[agent-msg from=alpha2 \$(date -u +%H:%MZ)] after the draft -- To answer, run the shell command: agent-say --from delta alpha2 \"<your reply>\"' || grep -q 'after the draft' $T/codex.typed"

# An idle prompt can leave the cursor far to the right of an empty prompt: that is not typing.
touch "$T/codex.farcursor"
AGENT_SAY_PANE=$A say delta "redraw" >/dev/null 2>&1; sleep 0.5
out=$(AGENT_SAY_TYPING_WAIT=1 AGENT_SAY_PANE=$A say delta "cursor far right" 2>&1)
check "an empty prompt with the cursor far right is not taken for typing ($out)" "[[ '$out' == sent* ]]"
rm -f "$T/codex.farcursor"; AGENT_SAY_PANE=$A say delta "redraw" >/dev/null 2>&1; sleep 0.3

echo "a link to a machine you ssh into"
# A second private tmux server stands in for the machine you ssh into, and a fake ssh runs
# commands "there": its own tmux, state and mailbox. Nothing reaches a real ssh or tmux.
mkdir -p "$T/rbin" "$T/rstate" "$T/rtmp" "$T/rhome"
printf '#!/bin/sh\nexec %q -S %q -f /dev/null "$@"\n' "$real_tmux" "$T/rsock" >"$T/rbin/tmux"
chmod +x "$T/rbin/tmux"
cat >"$T/bin/fakessh" <<EOF
#!/usr/bin/env bash
echo "\$*" >>$T/ssh.log
while [[ \$1 == -* ]]; do case \$1 in -O) [[ \$2 == check ]] && exit 255; exit 0 ;; -o | -p | -i) shift 2 ;; *) shift ;; esac; done
shift # the host
exec env -u AGENT_SAY_PANE -u AGENT_SAY_LOCAL_ONLY PATH="$T/rbin:\$PATH" XDG_STATE_HOME=$T/rstate \\
	AGENT_SAY_MAILBOX=$T/rstate/agent-say/mailbox.md AGENT_SAY_HOST=devbox-1 TMPDIR=$T/rtmp HOME=$T/rhome \\
	bash -c "\$*"
EOF
chmod +x "$T/bin/fakessh"
export AGENT_SAY_SSH=$T/bin/fakessh AGENT_SAY_REMOTE_CMD=$ROOT/bin/agent-say AGENT_SAY_HOST=laptop AGENT_SAY_LINK_INTERVAL=0.3
# The host keys it checks come from a known_hosts file of the test's own, never ssh-keyscan.
ssh-keygen -q -t ed25519 -N '' -C '' -f "$T/hostkey1" && ssh-keygen -q -t ed25519 -N '' -C '' -f "$T/hostkey2"
printf 'devbox %s\n' "$(cut -d' ' -f1,2 "$T/hostkey1.pub")" >"$T/known_hosts"
fp1=$(ssh-keygen -lf "$T/hostkey1.pub" | awk '{print $2}') fp2=$(ssh-keygen -lf "$T/hostkey2.pub" | awk '{print $2}')
export AGENT_SAY_KNOWN_HOSTS=$T/known_hosts AGENT_SAY_KEYSCAN=false
there() { "$T/bin/fakessh" devbox "$*"; }
"$T/rbin/tmux" new-session -d -s r -x 200 -y 50 "$T/bin/crush"
RC=$("$T/rbin/tmux" display -p -t r '#{pane_id}')
there "AGENT_SAY_PANE=$RC $ROOT/bin/agent-say name codex" >/dev/null
LC=$(tmux new-window -d -P -F '#{pane_id}' -t s "$T/bin/crush")
sleep 0.3
AGENT_SAY_PANE=$LC say name me >/dev/null
seen_there() { "$T/rbin/tmux" capture-pane -p -J -t "$RC" -S -100 | grep -qF -- "$1"; }
wait_seen() { for _ in $(seq 40); do seen "$1" "$2" && return 0; sleep 0.25; done; return 1; }

out=$(say link devbox 2>&1 </dev/null)
check "a first link shows the host key and, off a terminal, wants --yes ($fp1)" "[[ \$out == *\"devbox's host key:\"*'$fp1 (ED25519)'*'--yes'* && ! -e \$(dirname $AGENT_SAY_MAILBOX)/links/devbox/on ]]"
out=$(say link devbox --yes 2>&1 </dev/null)
check "link reaches the other machine and lists its panes ($out)" "[[ \$out == *'Its panes: codex'* ]]"
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
# A pane over there renamed from here, the way the panel's N does it: the link carries the new name back.
mkdir -p "$T/rhome/.local/bin" && ln -sf "$ROOT/bin/agent-say" "$T/rhome/.local/bin/agent-say"
there "AGENT_SAY_PANE='$RC' PATH=\"\$HOME/.local/bin:\$PATH\" agent-say name 'codex2' </dev/null 2>&1" >/dev/null
check "a pane renamed over ssh shows here by its new name" "for _ in \$(seq 20); do say list | grep -q 'codex2@devbox' && break; sleep 0.25; done; say list | grep -q 'codex2@devbox' && ! say list | grep -q 'codex@devbox'"
there "AGENT_SAY_PANE='$RC' PATH=\"\$HOME/.local/bin:\$PATH\" agent-say name 'codex' </dev/null 2>&1" >/dev/null
for _ in $(seq 20); do say list | grep -q ' codex@devbox' && break; sleep 0.25; done
out=$(AGENT_SAY_PANE=$LC say '-oProxyCommand=x@devbox' 'hi' 2>&1)
check "name@host with a name that isn't one is refused ($out)" "[[ '$out' == *'is not a pane name'* ]]"
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

echo "link trust"
lk=$(dirname "$AGENT_SAY_MAILBOX")/links/devbox
mailcount() { local n; n=$(grep -c -- "$1" "$AGENT_SAY_MAILBOX"); echo "${n:-0}"; }
wait_mail() { for _ in $(seq 40); do (($(mailcount "$1") >= ${2:-1})) && return 0; sleep 0.25; done; return 1; }
check "the confirmed key is kept with the link" "[[ \$(cat $lk/fingerprint) == '$fp1 (ED25519)' ]]"
out=$(say link devbox --read-only 2>&1 </dev/null)
check "changing a link's mode asks nothing again ($out)" "[[ '$out' == *'Read-only'* && '$out' != *'host key'* ]]"
out=$(say link)
check "link lists the mode and the key ($out)" "[[ '$out' == 'devbox  running  read-only  key: $fp1 (ED25519)  names: codex '* ]]"
there "$ROOT/bin/agent-say --from codex me@laptop 'read only please'" >/dev/null
check "a read-only link's message is held in the mailbox" "wait_mail 'held: read-only link' && grep -A1 'held: read-only link' $AGENT_SAY_MAILBOX | grep -c 'read only please' >/dev/null"
check "and not typed in" "! seen $LC 'read only please'"
check "and the other side has it acknowledged, not fetched again" "for _ in \$(seq 20); do [[ -z \$(ls $outbox) ]] && break; sleep 0.2; done; [[ -z \$(ls $outbox) && \$(mailcount 'held: read-only') == 1 ]]"
check "it may still see the names here" "[[ -n \$(find $T/rstate/agent-say/peers/laptop/names -newermt '-3 seconds') ]] && grep -cx me $T/rstate/agent-say/peers/laptop/names >/dev/null"
out=$(say link devbox --read-write --allow me,alpha2 2>&1 </dev/null)
check "an allowlist is set ($out)" "[[ '$out' == *'can reach only: alpha2,me.'* && ! -e $lk/read-only ]]"
there "$ROOT/bin/agent-say --from codex delta@laptop 'not for delta'" >/dev/null
there "$ROOT/bin/agent-say --from codex me@laptop 'allowed to me'" >/dev/null
check "an allowlisted name gets its message" "wait_seen $LC 'allowed to me'"
check "another name's is NOT DELIVERED, not allowed" "wait_mail 'NOT DELIVERED: not allowed' && ! grep -c 'not for delta' $T/codex.typed >/dev/null"
check "--allow takes only names a pane can have" "! say link devbox --allow 'x;y' </dev/null 2>/dev/null && ! say link devbox --allow '' </dev/null 2>/dev/null && [[ \$(paste -sd, $lk/allow) == alpha2,me ]]"
say link devbox --allow-all </dev/null >/dev/null
check "--allow-all lifts it" "[[ ! -e $lk/allow ]]"
# The host's key changes (another computer answers to devbox now): the poller stops.
printf 'devbox %s\n' "$(cut -d' ' -f1,2 "$T/hostkey2.pub")" >"$T/known_hosts"
check "a changed host key stops the poller" "for _ in \$(seq 40); do pgrep -f 'agent-say _poll devbox' >/dev/null || break; sleep 0.25; done; ! pgrep -f 'agent-say _poll devbox' >/dev/null"
out=$(say link)
check "and link says why ($out)" "[[ \$out == *'not running'*'host key changed'* ]]"
there "$ROOT/bin/agent-say --from codex me@laptop 'while the key is wrong'" >/dev/null
sleep 1
check "nothing comes in from it meanwhile" "! seen $LC 'while the key is wrong' && [[ -n \$(ls $outbox) ]]"
out=$(say link devbox 2>&1 </dev/null)
check "linking again shows the new key, warns, and wants --yes ($fp2)" "[[ \$out == *'$fp2'*'WARNING'*'$fp1'*'--yes'* ]] && ! pgrep -f 'agent-say _poll devbox' >/dev/null"
say link devbox --yes </dev/null >/dev/null 2>&1
check "confirmed, the link runs again and what waited arrives" "wait_seen $LC 'while the key is wrong' && [[ \$(cat $lk/fingerprint) == '$fp2 (ED25519)' ]]"

say _resume-links; say _resume-links; sleep 0.5
check "starting the link twice runs one poller" "[[ \$(pgrep -fc 'agent-say _poll devbox') -eq 1 ]]"

# Stop the poller (as a reboot would), then queue: the message waits, and unlink marks it.
pkill -f 'agent-say _poll devbox'; sleep 0.3
there "$ROOT/bin/agent-say --from codex me@laptop 'never fetched'" >/dev/null
say unlink devbox >/dev/null
sleep 0.5
check "unlink stops it" "! pgrep -f 'agent-say _poll devbox' >/dev/null"
check "and the other side marks what it held as NOT DELIVERED" "grep -q 'NOT DELIVERED: laptop unlinked' $T/rstate/agent-say/mailbox.md && [[ -z \$(ls $outbox) ]]"

echo "a link to a server that takes a password"
# pwbox is the same machine, behind a fake ssh that refuses BatchMode until a login (an ssh
# with ControlMaster=yes, its password typed) has left a master open: the marker file.
cat >"$T/bin/pwssh" <<EOF
#!/usr/bin/env bash
echo "\$*" >>$T/pwssh.log
m=$T/pw.master
case " \$* " in
*" -O check "*) [[ -e \$m ]]; exit ;;
*" -O exit "*) rm -f \$m; exit 0 ;;
*" -G "*) exit 0 ;;
*" ControlMaster=yes "*)
	IFS= read -rsp 'pwbox password: ' pw; echo
	[[ \$pw == hunter2 ]] && { touch \$m; exit 0; }
	echo 'Permission denied, please try again.' >&2; exit 255 ;;
esac
[[ -e \$m ]] || { echo 'me@pwbox: Permission denied (publickey,password).' >&2; exit 255; }
exec $T/bin/fakessh "\$@"
EOF
chmod +x "$T/bin/pwssh"
printf 'pwbox %s\n' "$(cut -d' ' -f1,2 "$T/hostkey2.pub")" >>"$T/known_hosts"
pw() { AGENT_SAY_SSH=$T/bin/pwssh AGENT_SAY_LOGIN_RETRY=600 say "$@"; }
pl=$(dirname "$AGENT_SAY_MAILBOX")/links/pwbox
batch_tries() { grep -c 'BatchMode=yes' "$T/pwssh.log"; }
out=$(pw link pwbox --yes 2>&1 </dev/null)
check "off a terminal, it isn't linked and says it needs a login ($out)" "[[ \$out == *'pwbox needs a login'* && ! -e $pl/on ]] && ! pgrep -f 'agent-say _poll pwbox' >/dev/null"
pw _login pwbox <<<wrong >/dev/null 2>&1
check "a wrong password opens no login" "! pw _login pwbox --check && [[ ! -e $T/pw.master ]]"
pw _login pwbox <<<hunter2 >/dev/null 2>&1
check "the right one, typed into ssh, leaves a login open" "pw _login pwbox --check"
out=$(pw link pwbox --yes 2>&1 </dev/null)
check "the link is then made over that login, with no prompt ($out)" "[[ \$out == *'linked to pwbox'*'Its panes: codex'* ]]"
there "$ROOT/bin/agent-say --from codex me@laptop 'over the password link'" >/dev/null
check "and its poller brings messages over it" "wait_seen $LC 'over the password link'"
rm -f "$T/pw.master" # the login dropped: a reboot over there, or the network gone a while
check "a dropped login shows as needing one, not as a failure to reach it" "for _ in \$(seq 40); do [[ -e $pl/login ]] && break; sleep 0.25; done; [[ -e $pl/login ]] && say link | grep -q '^pwbox  running.*needs login: pwbox asks for a password'"
n=$(batch_tries); sleep 3
check "while it waits for a login it doesn't keep trying ssh ($n tries)" "[[ \$(batch_tries) == $n ]]"
pw _login pwbox <<<hunter2 >/dev/null 2>&1
there "$ROOT/bin/agent-say --from codex me@laptop 'after logging in again'" >/dev/null
check "logged in again, the link picks up by itself" "wait_seen $LC 'after logging in again' && [[ ! -e $pl/login ]]"
# On a terminal, link asks for the password itself, through ssh (script gives it a terminal).
rm -f "$T/pw.master"
for _ in $(seq 40); do [[ -e $pl/login ]] && break; sleep 0.25; done
out=$(printf 'hunter2\n' | AGENT_SAY_SSH=$T/bin/pwssh script -qec "$ROOT/bin/agent-say link pwbox" /dev/null 2>&1)
check "on a terminal, link logs in with ssh's own prompt ($out)" "[[ \$out == *'pwbox password:'*'linked to pwbox'* ]] && pw _login pwbox --check"
check "a host with a key never got a login: no ssh with ControlMaster=yes" "grep -c ' devbox ' $T/ssh.log >/dev/null && ! grep -q 'ControlMaster=yes' $T/ssh.log"
pw unlink pwbox >/dev/null 2>&1
check "unlink closes the login with it" "[[ ! -e $T/pw.master ]] && ! pgrep -f 'agent-say _poll pwbox' >/dev/null"
"$T/rbin/tmux" kill-server

echo "$pass passed, $fail failed"
((fail == 0))
