#!/usr/bin/env bash
# Rebuild sessions, windows, pane layouts and relaunch the saved programs,
# resuming each Claude Code / Codex / Gemini pane into its exact session.
#
# usage: restore.sh [--auto] [--dry-run] [SNAPSHOT_DIR]
#   --auto     startup mode: only on a server under a minute old, once, and
#              replaces the empty session `tmux` creates on launch
#   --dry-run  print what would be restored, change nothing
set -uo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

auto=0 dry=0
while [[ ${1:-} == --* ]]; do
	case $1 in
	--auto) auto=1 ;;
	--dry-run) dry=1 ;;
	esac
	shift
done

# Startup restore announces when it is over, so `tmux-revive start` (behind
# a plain `tmux attach` after a reboot) knows when to attach.
((auto && !dry)) && on_exit "tm set-option -g @revive-done 1 2>/dev/null"

DIR=$(revive_dir)
snap=${1:-$DIR/last}
[[ -d $snap ]] || snap="$DIR/snapshots/$snap"
state=$snap/state.json
if [[ ! -f $state ]]; then
	((auto)) || msg "no snapshot to restore"
	exit 0
fi

# You closed everything before tmux exited: nothing to bring back.
if ((auto)) && [[ $(jq '.sessions | length' "$state") == 0 ]]; then
	rm -f "$DIR/.shutdown"
	exit 0
fi

if ((dry)); then
	jq -r '"snapshot \(.saved_at) on \(.host) (\(.reason))",
	  (.sessions[] | "session \(.name)", (.windows[] | "  window \(.index) \(.name)",
	    (.panes[] | "    pane \(.index) [\(.kind)] \(.cwd)\(if .cmd then "\n      $ " + .cmd else "" end)\(if .detail.exact == false then "\n      (best guess: the exact session could not be identified)" else "" end)")))' "$state"
	exit 0
fi

if ! take_lock "$DIR/.restore.lock"; then
	CLEANUP=() # another restore is running; it signals when done
	exit 0
fi

if ((auto)); then
	[[ $(opt @revive-auto-restore on) == on ]] || exit 0
	[[ $(tm show-option -gqv @revive-restored) == 1 ]] && exit 0
	# The `tmux` command creates its session right after the config loads.
	for _ in $(seq 30); do
		[[ -n $(tm list-sessions -F x 2>/dev/null) ]] && break
		sleep 0.1
	done
	started=$(tm display-message -p '#{start_time}' 2>/dev/null) || exit 0
	(($(date +%s) - started > 60)) && exit 0
	rm -f "$DIR/.shutdown" # this is the start after it
fi
tm set-option -g @revive-restored 1
tm set-option -g @revive-restoring 1
on_exit "tm set-option -gu @revive-restoring 2>/dev/null"

SHELLS=" sh bash zsh fish dash ksh tcsh nu "
# A placeholder is the empty session a fresh `tmux` makes: one window, one
# pane, an idle shell. Auto-restore replaces it instead of leaving it beside
# the restored ones.
is_placeholder() {
	local s=$1 panes cmd
	[[ $s =~ ^[0-9]+$ ]] || return 1 # you named it: not ours to replace
	panes=$(tm list-panes -s -t "=$s" -F '#{pane_current_command}' 2>/dev/null) || return 1
	[[ $(wc -l <<<"$panes") -eq 1 ]] || return 1
	cmd=${panes##*/}
	[[ $SHELLS == *" ${cmd#-} "* ]]
}

declare -a placeholders=() originals=()
if ((auto)); then
	while read -r s; do
		[[ -n $s ]] && is_placeholder "$s" && placeholders+=("$s")
	done < <(tm list-sessions -F '#{session_name}' 2>/dev/null)
fi
for i in "${!placeholders[@]}"; do
	tmp="_revive_placeholder_$i"
	originals[i]=${placeholders[i]}
	tm rename-session -t "=${placeholders[i]}" "$tmp"
	placeholders[i]=$tmp
done

# tmux expands formats (#{...}, and #() runs a command) in names, titles and
# start directories: a saved `#(...)` must come back as text, not run.
lit() { printf '%s' "${1//\#/##}"; }

init=$REVIVE_ROOT/scripts/pane-init.sh
pane_cmd() { # pane_cmd PANE_JSON -> shell command line for the new pane
	local cmd scroll cmdf=""
	cmd=$(jq -r '.cmd // empty' <<<"$1")
	scroll=$(jq -r '.scrollback // empty' <<<"$1")
	[[ -n $scroll ]] && scroll=$snap/$scroll
	# An nvim whose session was saved reopens it: windows, cursors, and its unsaved text. The
	# file names are checked, since they become a path; the session is nvim's own, written into
	# this private snapshot, never one found in the project.
	local ses uns
	read -r ses uns < <(jq -r '[.detail.session // "", .detail.unsaved // ""] | @tsv' <<<"$1")
	# nvim gets copies, which it deletes once read: the next save may replace the snapshot's own
	# before a slow start has read them.
	if [[ -n $cmd && $ses =~ ^nvim-[0-9]+-[0-9]+\.vim$ && $uns == "${ses%.vim}.json" && -f $snap/$ses && -f $snap/$uns ]]; then
		local sesf unsf
		sesf=$(mktemp "$DIR/panes/nvim.XXXXXX") && cp -p "$snap/$ses" "$sesf"
		unsf=$(mktemp "$DIR/panes/nvim.XXXXXX") && cp -p "$snap/$uns" "$unsf"
		# Its own command line (flags, files) with the session after it.
		cmd="REVIVE_NVIM_LUA=$(printf '%q' "$REVIVE_ROOT/scripts/nvim-revive.lua") REVIVE_NVIM_SESSION=$(printf '%q' "$sesf") REVIVE_NVIM_UNSAVED=$(printf '%q' "$unsf") $cmd"
		cmd+=" --cmd 'lua dofile(vim.env.REVIVE_NVIM_LUA).restore()' -S $(printf '%q' "$sesf")"
	fi
	if [[ -n $cmd ]]; then
		cmdf=$(mktemp "$DIR/panes/cmd.XXXXXX")
		printf '%s' "$cmd" >"$cmdf"
	fi
	printf '%q %q %q' "$init" "$scroll" "$cmdf"
}

restored=0 skipped=0 agents=0 first_session=""
while read -r sjson; do
	name=$(jq -r '.name' <<<"$sjson")
	if tm has-session -t "=$name" 2>/dev/null; then
		log "session '$name' already exists, skipped"
		((skipped++))
		continue
	fi
	[[ -z $first_session ]] && first_session=$name
	created=0
	while read -r wjson; do
		widx=$(jq -r '.index' <<<"$wjson")
		wname=$(jq -r '.name' <<<"$wjson")
		layout=$(jq -r '.layout' <<<"$wjson")
		# tmux >= 3.6 emits JSON layouts; older ones "csum,WxH,x,y...".
		if [[ $layout == '{'* ]]; then
			read -r W H < <(jq -r '"\(.L.w // 200) \(.L.h // 50)"' <<<"$layout")
		else
			read -r W H < <(sed -nE 's/^[^,]*,([0-9]+)x([0-9]+),.*/\1 \2/p' <<<"$layout")
		fi
		wid="" last="" active_pane=""
		mapfile -t panes < <(jq -c '.panes[]' <<<"$wjson")
		for pjson in "${panes[@]}"; do
			cwd=$(jq -r '.cwd' <<<"$pjson")
			[[ -d $cwd ]] || cwd=$HOME
			cmd=$(pane_cmd "$pjson")
			if [[ -z $wid ]]; then
				if ((created == 0)); then
					read -r wid last < <(tm new-session -d -P -F '#{window_id} #{pane_id}' \
						-s "$(lit "$name")" -n "$(lit "$wname")" -c "$(lit "$cwd")" -x "${W:-200}" -y "${H:-50}" "$cmd")
					tm move-window -s "$wid" -t "=$name:$widx" 2>/dev/null
					created=1
				else
					read -r wid last < <(tm new-window -d -P -F '#{window_id} #{pane_id}' \
						-t "=$name:$widx" -n "$(lit "$wname")" -c "$(lit "$cwd")" "$cmd")
				fi
			else
				# Split the newest pane so pane order matches the saved layout.
				last=$(tm split-window -d -P -F '#{pane_id}' -t "$last" -c "$(lit "$cwd")" "$cmd")
				tm select-layout -t "$wid" tiled >/dev/null 2>&1
			fi
			[[ $(jq -r '.active' <<<"$pjson") == true ]] && active_pane=$last
			title=$(jq -r '.title // empty' <<<"$pjson")
			[[ -n $title ]] && tm select-pane -t "$last" -T "$(lit "$title")"
			# Its agent-say name, and since when it has had it (the mail its pane may read starts
			# there): pane options, which a new server would not have otherwise.
			agent=$(jq -r '.agent // empty' <<<"$pjson")
			if [[ $agent =~ ^[A-Za-z0-9][A-Za-z0-9_.:+=-]*$ ]]; then
				tm set-option -p -t "$last" @agent "$agent"
				at=$(jq -r '.agent_at // empty' <<<"$pjson")
				[[ $at =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && tm set-option -p -t "$last" @agent-at "$at"
			fi
			[[ $(jq -r '.kind' <<<"$pjson") =~ ^(claude|codex|cursor|crush|gemini)$ ]] && ((agents++))
		done
		tm select-layout -t "$wid" "$layout" >/dev/null 2>&1
		if [[ $(jq -r '.auto_rename' <<<"$wjson") == true ]]; then
			tm set-window-option -t "$wid" automatic-rename on
		fi
		[[ -n $active_pane ]] && tm select-pane -t "$active_pane"
		[[ $(jq -r '.zoomed' <<<"$wjson") == true ]] && tm resize-pane -Z -t "${active_pane:-$last}"
		[[ $(jq -r '.active' <<<"$wjson") == true ]] && tm select-window -t "$wid"
	done < <(jq -c '.windows[]' <<<"$sjson")
	((restored++))
done < <(jq -c '.sessions | sort_by(-.last_attached) | .[]' "$state")

# Move anyone sitting in a placeholder to the restored session they used
# last, then drop the placeholders.
target=$(jq -r '.sessions | sort_by(-.last_attached) | .[0].name' "$state")
tm has-session -t "=$target" 2>/dev/null || target=$first_session
for i in "${!placeholders[@]}"; do
	p=${placeholders[i]}
	if [[ -n $target ]]; then
		while read -r client; do
			[[ -n $client ]] && tm switch-client -c "$client" -t "=$target"
		done < <(tm list-clients -t "=$p" -F '#{client_name}' 2>/dev/null)
		tm kill-session -t "=$p"
	else
		# Nothing was restored; give the session its name back.
		tm rename-session -t "=$p" "${originals[i]}" 2>/dev/null
	fi
done

msg "restored $restored sessions, resumed $agents agent sessions$( ((skipped)) && echo ", skipped $skipped already open")"
