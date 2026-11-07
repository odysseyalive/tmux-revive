# shellcheck shell=sh
# Sourced from your shell rc (bash, zsh) by the installer. After a reboot no
# tmux server is running, so `tmux attach` would just say "no sessions".
# This starts the server first, lets tmux-revive restore everything, then
# runs your command unchanged. Every other tmux command passes straight through.
function tmux {
	case ${1-} in
	a | at | att | atta | attac | attach | attach-session)
		command tmux has-session 2>/dev/null || "${TMUX_REVIVE_BIN:-tmux-revive}" start 2>/dev/null
		;;
	esac
	command tmux "$@"
}
