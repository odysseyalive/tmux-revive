#!/usr/bin/env bash
# First process of every restored pane: replay the saved scrollback, run the
# saved command through an interactive shell (so the user's rc files, PATH and
# version managers apply), then hand the pane to a normal login shell.
#
# usage: pane-init.sh SCROLLBACK_FILE|"" COMMAND_FILE|""
scroll=${1:-} cmdf=${2:-}
shell=${REVIVE_SHELL:-$(tmux show-option -gqv default-shell 2>/dev/null)}
[[ -x $shell ]] || shell=${SHELL:-/bin/sh}

[[ -n $scroll && -s $scroll ]] && cat "$scroll"

if [[ -n $cmdf && -f $cmdf ]]; then
	cmd=$(<"$cmdf")
	rm -f "$cmdf"
	printf '\033[2m[tmux-revive] %s\033[0m\n' "$cmd"
	"$shell" -i -c "$cmd"
	status=$?
	((status)) && printf '\033[2m[tmux-revive] exited %d; you are in a shell in the same directory.\033[0m\n' "$status"
fi

exec -a "-${shell##*/}" "$shell"
