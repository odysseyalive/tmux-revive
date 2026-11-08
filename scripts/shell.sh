# shellcheck shell=sh
# Sourced from your shell rc (bash, zsh) by the installer. A bare `tmux`
# outside tmux, and `tmux attach`, go to `tmux-revive open`: after a reboot it
# starts the server and restores first; with several sessions it shows a pick
# list, with one it just attaches. The logic lives in the app, not here, so a
# shell opened before an update still gets the new behaviour. Every other tmux
# command passes straight through.
function tmux {
	case $#:${1-} in
	0:) [ -z "${TMUX-}" ] || { command tmux; return; } ;;
	*:a | *:at | *:att | *:atta | *:attac | *:attach | *:attach-session) ;;
	*) command tmux "$@"; return ;;
	esac
	# No app (uninstalled, say): plain tmux rather than a "not found".
	if command -v "${TMUX_REVIVE_BIN:-tmux-revive}" >/dev/null 2>&1; then
		"${TMUX_REVIVE_BIN:-tmux-revive}" open "$@"
	else
		command tmux "$@"
	fi
}
