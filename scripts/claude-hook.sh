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

# no_reply TRANSCRIPT SESSION, on Stop: a turn an agent-say message started (its prompt is
# [agent-msg from=X ...]) that sent X nothing tells X so, the way a reply to X goes, so X stops
# waiting: "(no reply) NAME finished the turn your message started and didn't reply.", after
# the message's re: line if it had one. Sent to X means an agent-say command naming X among
# the turn's tool calls, or a row from this pane to X in the mailbox since the turn began (not
# a notice's). Not for a turn a notice started (so two agents never trade them), one the user
# or anything else started, or a message from this pane itself; a turn cut short or failed
# fires no Stop. Once a turn (STATE/noreply/SESSION has its prompt's id). What it did goes to
# STATE/noreply.log, never to the screen.
no_reply() {
	local tr=$1 sid=$2 turn p uuid ts prompt from hdr rest you re c f text out
	# The turn: its prompt (the last one a person, a message or Claude Code itself started a turn
	# with, not a tool's result), then the commands its tool calls ran.
	turn=$(tail -c 4000000 "$tr" 2>/dev/null | grep -e '"type":"user"' -e '"tool_use"' | jq -Rr '
		def one: gsub("[\t\n\r]"; " ");
		fromjson? | select(.isSidechain | not)
		| . as $e | if .type == "user" then
			select((.isMeta | not) or .origin.kind != null) | .message.content as $c
			| if ($c | type) == "string" then $c
			elif ($c | type) == "array" and all($c[]; .type != "tool_result") then [$c[] | .text? // empty] | join(" ")
			else empty end
			| "P\t\($e.uuid // "-")\t\($e.timestamp // "")\t\(one)"
		elif .type == "assistant" then .message.content[]? | select(.type == "tool_use") | .input.command? | strings | "C\t\(one)"
		else empty end' 2>/dev/null | awk '/^P\t/ {b = ""} {b = b $0 "\n"} END {printf "%s", b}')
	IFS=$'\t' read -r p uuid ts prompt <<<"${turn%%$'\n'*}"
	[[ $p == P && $prompt =~ ^\[agent-msg\ from=([^]\ ]+)([^]]*)\]\ (.*)$ ]] || return 0
	from=${BASH_REMATCH[1]} hdr=${BASH_REMATCH[2]} rest=${BASH_REMATCH[3]}
	[[ $rest == '(no reply) '* ]] && return 0
	# This pane's name and the sender's, as the message's own reply command gives them.
	[[ $rest =~ --from\ ([^\ ]+)\ ([^\ ]+)\ \"\<your\ reply\>\"$ && ${BASH_REMATCH[2]} == "$from" ]] || return 0
	you=${BASH_REMATCH[1]}
	[[ $from != panel && $from != "$you" ]] || return 0 # the panel's M (you, typing), or itself
	[[ $hdr =~ \ re=([0-9a-f]{8}/i[0-9]{1,4})$ ]] && re=${BASH_REMATCH[1]}
	while IFS= read -r c; do
		[[ $c == C$'\t'*agent-say* ]] || continue
		c=" ${c//[\"\'\`;&|()<>]/ } "
		[[ $c == *" $from "* ]] && return 0
	done <<<"$turn"
	# agent-say's own functions, as below; only now, for the few turns a message started.
	# shellcheck source=../bin/agent-say
	source "$ROOT/bin/agent-say" || return 0
	set +eu
	[[ -n ${TMUX:-} ]] || tmux_server_above || return 0
	valid_sender "$from" && valid_sender "$you" || return 0
	[[ ${from%"@$LABEL"} != "${you%"@$LABEL"}" ]] || return 0
	ts=${ts:0:19}Z
	[[ $ts =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 0
	[[ -f $MAILBOX ]] && awk -v a="[$you" -v b="[$you@$LABEL" -v x="$from" -v y="${from%"@$LABEL"}@$LABEL" -v s="$ts" '
		$1 == "##" && ($2 == a || $2 == b) && $3 == "->" && ($4 == x || $4 == y) && substr($5, 1, 20) >= s && !index($0, "(no reply)") {f = 1} END {exit !f}' "$MAILBOX" && return 0
	[[ $sid =~ ^[A-Za-z0-9._-]{1,128}$ ]] || return 0
	f=$STATE/noreply/$sid
	[[ "$(cat "$f" 2>/dev/null)" != "$uuid $ts" ]] || return 0
	mkdir -p "$STATE/noreply" && printf '%s\n' "$uuid $ts" >"$f" || return 0
	text="(no reply) $you finished the turn your message started and didn't reply."
	[[ -n $re ]] && text="re: $re"$'\n'"$text"
	# As a reply goes, and quick: a pane someone types in, or scrolled back, gets it queued.
	# Tried once, whatever comes of it.
	c=()
	command -v timeout >/dev/null && c=(timeout 8)
	out=$(AGENT_SAY_TYPING_WAIT=0 AGENT_SAY_MODE_WAIT=0 "${c[@]}" "$ROOT/bin/agent-say" --from "$you" "$from" "$text" 2>&1 </dev/null)
	f=$STATE/noreply.log
	printf '%s %s -> %s: %s\n' "$(date -u +%FT%TZ)" "$you" "$from" "${out//$'\n'/ }" >>"$f"
	(($(wc -l <"$f") > 400)) && { tail -n 200 "$f" >"$f.$$" && mv -f "$f.$$" "$f"; }
	return 0
}

# `claude-hook.sh ctx`, on Stop, PostToolUse and a SessionStart after a compaction (async, so
# nothing waits on it): the context this session has left, worked out as the panel does and
# handed to agent-say, which keeps it for the panel as the tmux owner. The panel then needn't
# read this session's files, which it can't when it runs as someone else (a link's user, with
# agents running as root). On Stop, a no-reply notice too (no_reply).
if [[ ${1:-} == ctx ]]; then
	# shellcheck source=common.sh
	source "$ROOT/scripts/common.sh" || exit 0
	# Tabs run together when read, so an empty field (no agent_id) comes as "-".
	IFS=$'\t' read -r sid tr sub ev < <(jq -r '[.session_id // "", .transcript_path // "", .agent_id // "-", .hook_event_name // "-"] | @tsv')
	# A subagent's tool calls aren't the session's context.
	[[ -n $sid && $sub == - && $tr == /* && -f $tr ]] || exit 0
	pct=$(claude_ctx_file "$tr")
	[[ -n $pct ]] && "$ROOT/bin/agent-say" _ctx "$sid" "$pct" >/dev/null
	# In a subshell of its own: whatever it meets, this hook exits 0.
	[[ $ev == Stop ]] && (no_reply "$tr" "$sid")
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
name="" why=""
[[ -n $pane ]] && name=$(name_of "$pane")
# A tmux this user can't look at (another user's: su in one of its panes): agent-say, run in
# full, reaches it as its owner, or asks root's, or says why it can't.
if [[ -z $pane ]]; then
	r=$(AGENT_SAY_ASK_WAIT=2 "$ROOT/bin/agent-say" _pane </dev/null 2>&1) && read -r pane name <<<"$r" || why=${r#agent-say: }
	[[ $pane =~ ^%[0-9]+$ ]] || pane=""
	valid_name "$name" || name=""
fi

if [[ -n $name ]]; then
	where="This Claude Code session is in tmux pane $pane, named \"$name\" for agent-say."
elif [[ -n $why ]]; then
	where="This Claude Code session's tmux pane can't be reached by agent-say right now: $why"
else
	where="This Claude Code session is in a tmux pane with no agent-say name yet. Run $as name NAME to give it one."
fi
text="$where
To reach agents in other tmux panes, or on servers linked with agent-say, run $as through Bash. SendMessage and ListAgents only reach Claude sessions on this machine, so they can't reach those agents.
- $as list: every named pane, here and on linked servers (shown as name@server)
- $as NAME \"message\": send to one (use NAME@server for a linked server)
- $as show ID: read a message by the id in its notice
Messages and replies arrive as a prompt that starts with [agent-msg from=NAME ...] and ends with the exact command to answer with.
Your first message to any other agent, on this computer or another server, waits as an introduction until the user approves it in the tmux-revive panel. Add a one-line reason so they can decide: $as NAME --why \"short reason\" \"message\"."

jq=$(command -v jq) || jq=$ROOT/vendor/bin/jq
if [[ -x $jq ]]; then
	"$jq" -n --arg c "$text" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}'
else
	printf '%s\n' "$text" # plain stdout from a SessionStart hook reaches Claude too
fi
exit 0
