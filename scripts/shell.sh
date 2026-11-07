# shellcheck shell=sh
# Sourced from your shell rc (bash, zsh) by the installer. After a reboot no
# tmux server is running, so `tmux attach` would just say "no sessions".
# This starts the server first, lets tmux-revive restore everything, then
# runs your command unchanged. A bare `tmux` outside tmux reattaches to the
# last session instead of opening a new one; `tmux new` still makes a new one.
# Every other tmux command passes straight through.
function tmux {
	if [ $# -eq 0 ] && [ -z "${TMUX-}" ]; then
		command tmux has-session 2>/dev/null || "${TMUX_REVIVE_BIN:-tmux-revive}" start 2>/dev/null
		if command tmux has-session 2>/dev/null; then
			command tmux attach
		else
			command tmux
		fi
		return
	fi
	case ${1-} in
	a | at | att | atta | attac | attach | attach-session)
		command tmux has-session 2>/dev/null || "${TMUX_REVIVE_BIN:-tmux-revive}" start 2>/dev/null
		;;
	esac
	command tmux "$@"
}
