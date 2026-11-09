#!/usr/bin/env bash
# Claude Code SessionStart hook, registered in settings.json by install.sh. In a tmux pane
# it tells the agent that agents in other panes and on linked servers are reached with
# agent-say: Claude Code's own SendMessage and ListAgents only reach Claude sessions on
# the same machine, so without this an agent tries those, gets "Not sent", and stops.
# Outside tmux it prints nothing. It must stay fast: Claude's first answer waits for it.
exec 2>/dev/null # a stray error would show as a hook error on every session start
self=${BASH_SOURCE[0]}
while [[ -L $self ]]; do
	t=$(readlink "$self")
	[[ $t == /* ]] && self=$t || self=$(dirname "$self")/$t
done
ROOT="$(cd "$(dirname "$self")/.." && pwd)" || exit 0
((BASH_VERSINFO[0] >= 4)) || exit 0 # agent-say needs bash 4

# agent-say's own functions, the way the panel uses them: sourced, nothing run.
# shellcheck source=../bin/agent-say
source "$ROOT/bin/agent-say" || exit 0
set +eu

# In tmux: $TMUX, or a tmux server above us (sudo and su - clear $TMUX).
[[ -n ${TMUX:-} ]] || tmux_server_above || exit 0

as=agent-say
command -v agent-say >/dev/null || as=$(printf %q "$ROOT/bin/agent-say")
pane=$(self_pane)
name=""
[[ -n $pane ]] && name=$(name_of "$pane")

if [[ -n $name ]]; then
	where="This Claude Code session runs in tmux pane $pane, named \"$name\" for agent-say."
else
	where="This Claude Code session runs in a tmux pane with no agent-say name yet; $as name NAME gives it one."
fi
text="$where
Agents in other tmux panes, and on servers linked with agent-say, are reached with $as through Bash. SendMessage and ListAgents only reach Claude sessions on this same machine, so they can't reach those agents.
- $as list: every named pane, here and on linked servers (as name@server)
- $as NAME \"message\": send to one (NAME@server for a linked server)
- $as show ID: read a message by the id its notice gave
A message or reply arrives as a prompt starting with [agent-msg from=NAME ...], and ends with the exact command to answer it with.
The first message to an agent on another server waits as an introduction until the user approves it in the tmux-revive panel."

jq=$(command -v jq) || jq=$ROOT/vendor/bin/jq
if [[ -x $jq ]]; then
	"$jq" -n --arg c "$text" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}'
else
	printf '%s\n' "$text" # plain stdout from a SessionStart hook reaches Claude too
fi
exit 0
