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

# `claude-hook.sh ctx`, on Stop, PostToolUse and a SessionStart after a compaction (async, so
# nothing waits on it): the context this session has left, worked out as the panel does and
# handed to agent-say, which keeps it for the panel as the tmux owner. The panel then needn't
# read this session's files, which it can't when it runs as someone else (a link's user, with
# agents running as root).
if [[ ${1:-} == ctx ]]; then
	# shellcheck source=common.sh
	source "$ROOT/scripts/common.sh" || exit 0
	IFS=$'\t' read -r sid tr sub < <(jq -r '[.session_id // "", .transcript_path // "", .agent_id // ""] | @tsv')
	# A subagent's tool calls aren't the session's context.
	[[ -n $sid && -z $sub && $tr == /* && -f $tr ]] || exit 0
	pct=$(claude_ctx_file "$tr")
	[[ -n $pct ]] || exit 0
	"$ROOT/bin/agent-say" _ctx "$sid" "$pct" >/dev/null
	exit 0
fi

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
	where="This Claude Code session is in tmux pane $pane, named \"$name\" for agent-say."
else
	where="This Claude Code session is in a tmux pane with no agent-say name yet. Run $as name NAME to give it one."
fi
text="$where
To reach agents in other tmux panes, or on servers linked with agent-say, run $as through Bash. SendMessage and ListAgents only reach Claude sessions on this machine, so they can't reach those agents.
- $as list: every named pane, here and on linked servers (shown as name@server)
- $as NAME \"message\": send to one (use NAME@server for a linked server)
- $as show ID: read a message by the id in its notice
Messages and replies arrive as a prompt that starts with [agent-msg from=NAME ...] and ends with the exact command to answer with.
Your first message to any other agent, on this computer or another server, waits as an introduction until the user approves it in the tmux-revive panel. Add a one-line reason to help them decide: $as NAME --why \"short reason\" \"message\"."

jq=$(command -v jq) || jq=$ROOT/vendor/bin/jq
if [[ -x $jq ]]; then
	"$jq" -n --arg c "$text" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}'
else
	printf '%s\n' "$text" # plain stdout from a SessionStart hook reaches Claude too
fi
exit 0
