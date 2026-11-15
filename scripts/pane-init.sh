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
	# +m: no job control, so the command runs in this script's process group.
	# With job control the interactive shell hands the terminal to the
	# command's own group, and when the command exits nothing hands it back:
	# the shell exec'd below then starts in a background group, zsh fails its
	# first terminal read ("error on TTY read") and exits, and the window
	# closes with it. Sharing the group means Ctrl-C reaches this script too,
	# so it waits the interrupt out (a handler, not '', which the command
	# would inherit as ignored) and carries on to the shell.
	trap : INT QUIT
	"$shell" -i +m -c "$cmd"
	status=$?
	trap - INT QUIT
	((status)) && printf '\033[2m[tmux-revive] exited %d; you are in a shell in the same directory.\033[0m\n' "$status"
fi

exec -a "-${shell##*/}" "$shell"
