#!/bin/sh
# tmux-revive installer for Linux, macOS and WSL. No git, no compiling.
#
#   curl -fsSL https://raw.githubusercontent.com/odysseyalive/tmux-revive/main/install.sh | sh
#
# Options (after `sh -s --`):  --uninstall   --purge (uninstall + delete snapshots)
#                              --no-config   (don't touch tmux.conf, shell rc files,
#                                             or Claude Code / Codex settings)
# Environment:  REVIVE_REPO=owner/name   REVIVE_REF=branch|tag
#               REVIVE_SOURCE=/local/checkout   (install from a directory)
set -eu

REPO=${REVIVE_REPO:-odysseyalive/tmux-revive}
REF=${REVIVE_REF:-main}
DATA=${XDG_DATA_HOME:-$HOME/.local/share}/tmux-revive
APP=$DATA/app
BIN=$HOME/.local/bin
JQ_VERSION=1.7.1
BEGIN='# >>> tmux-revive >>>'
END='# <<< tmux-revive <<<'
# Markdown files get comment markers: a `#` line would render as a heading.
MD_BEGIN='<!-- >>> tmux-revive agent-say >>> -->'
MD_END='<!-- <<< tmux-revive agent-say <<< -->'
CODEX=${CODEX_HOME:-$HOME/.codex}
AGENT_SAY_PERM='Bash(agent-say:*)'

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die() { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

fetch() { # fetch URL FILE
	if have curl; then curl -fsSL "$1" -o "$2"
	elif have wget; then wget -qO "$2" "$1"
	else die "need curl or wget"; fi
}

# The config tmux actually loads: the first of these that exists.
tmux_conf() {
	for f in "$HOME/.tmux.conf" "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf"; do
		[ -f "$f" ] && { printf '%s' "$f"; return; }
	done
	if [ -d "${XDG_CONFIG_HOME:-$HOME/.config}/tmux" ]; then
		printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf"
	else
		printf '%s' "$HOME/.tmux.conf"
	fi
}

# Interactive shell rc files that exist, so a plain `tmux attach` after a
# reboot restores first (scripts/shell.sh).
shell_rcs() {
	for f in "$HOME/.bashrc" "${ZDOTDIR:-$HOME}/.zshrc"; do
		[ -f "$f" ] && printf '%s\n' "$f"
	done
}

strip_block() { # strip_block FILE [BEGIN END]: remove our block from FILE, in place
	[ -f "$1" ] || return 0
	awk -v b="${2:-$BEGIN}" -v e="${3:-$END}" '$0 == b { skip = 1; next } $0 == e { skip = 0; next } !skip' "$1" >"$1.revive.tmp" &&
		cat "$1.revive.tmp" >"$1" && rm -f "$1.revive.tmp"
}

# Claude Code config dirs: every ~/.claude* that has run Claude (same test as save.sh).
claude_dirs() {
	for d in "$HOME"/.claude*; do
		[ -d "$d/sessions" ] && printf '%s\n' "$d"
	done
}

jq_bin() {
	if have jq; then command -v jq
	elif [ -x "$APP/vendor/bin/jq" ]; then printf '%s' "$APP/vendor/bin/jq"
	fi
}

# Rewrite a JSON file with jq; leave it alone if it doesn't parse.
json_edit() { # json_edit FILE JQ-ARGS...
	jf=$1
	shift
	j=$(jq_bin)
	[ -n "$j" ] || return 1
	"$j" "$@" "$jf" >"$jf.revive.tmp" 2>/dev/null && cat "$jf.revive.tmp" >"$jf"
	rc=$?
	rm -f "$jf.revive.tmp"
	return $rc
}

# Let agents in tmux panes message each other with agent-say (see README).
agent_setup() {
	if [ -d "$CODEX" ] || have codex; then
		# Codex's sandbox blocks the tmux socket; this rule lets only agent-say out.
		mkdir -p "$CODEX/rules"
		cat >"$CODEX/rules/agent-say.rules" <<'RULES'
# Written by tmux-revive. agent-say types messages into other agents' tmux panes,
# which needs the tmux socket that Codex's sandbox blocks. Removed on uninstall.
prefix_rule(
    pattern = ["agent-say"],
    decision = "allow",
    justification = "agent-say only types into tmux panes; it needs the tmux socket",
)
RULES
		agents=$CODEX/AGENTS.md
		[ -f "$agents" ] && ! grep -qF "$MD_BEGIN" "$agents" && cp "$agents" "$agents.bak-revive-$(date +%Y%m%d%H%M%S)"
		strip_block "$agents" "$MD_BEGIN" "$MD_END"
		{
			[ -n "$(tail -n 1 "$agents" 2>/dev/null)" ] && printf '\n'
			printf '%s\n' "$MD_BEGIN"
			cat <<'NOTE'
## Messages from other agents

A prompt starting with `[agent-msg from=NAME ...]` was sent by another AI agent
in a tmux pane, not typed by the user, and the sender cannot see your chat
output. Answer it by running the `agent-say` command the message gives you.
To start a conversation yourself, run `agent-say --from codex NAME "message"`.
Reply only when there is something to say, never just to acknowledge.
NOTE
			printf '%s\n' "$MD_END"
		} >>"$agents"
		say "Codex can use agent-say (restart open Codex sessions to pick it up)"
	fi
	for d in $(claude_dirs); do
		f=$d/settings.json
		if [ -f "$f" ]; then
			grep -qF "$AGENT_SAY_PERM" "$f" && continue
			cp "$f" "$f.bak-revive-$(date +%Y%m%d%H%M%S)"
		else
			printf '{}\n' >"$f"
		fi
		if json_edit "$f" --arg p "$AGENT_SAY_PERM" '.permissions.allow += [$p]'; then
			say "Claude Code in $d can use agent-say without asking"
		else
			warn "couldn't update $f; allow $AGENT_SAY_PERM there yourself"
		fi
	done
}

agent_unsetup() {
	rm -f "$CODEX/rules/agent-say.rules"
	if grep -qF "$MD_BEGIN" "$CODEX/AGENTS.md" 2>/dev/null; then
		strip_block "$CODEX/AGENTS.md" "$MD_BEGIN" "$MD_END"
		say "removed agent-say from $CODEX/AGENTS.md"
	fi
	for d in $(claude_dirs); do
		f=$d/settings.json
		grep -qF "$AGENT_SAY_PERM" "$f" 2>/dev/null || continue
		json_edit "$f" --arg p "$AGENT_SAY_PERM" '.permissions.allow -= [$p]' &&
			say "removed the agent-say permission from $f"
	done
}

pkg_install() { # best effort with whatever package manager is here
	if have brew; then brew install "$@"
	elif have apt-get; then sudo apt-get update -qq && sudo apt-get install -y "$@"
	elif have dnf; then sudo dnf install -y "$@"
	elif have pacman; then sudo pacman -S --needed --noconfirm "$@"
	elif have zypper; then sudo zypper install -y "$@"
	elif have apk; then sudo apk add "$@"
	else return 1; fi
}

uninstall() {
	conf=$(tmux_conf)
	if grep -qF "$BEGIN" "$conf" 2>/dev/null; then
		strip_block "$conf"
		say "removed tmux-revive from $conf"
	fi
	for rc in $(shell_rcs); do
		grep -qF "$BEGIN" "$rc" && strip_block "$rc" && say "removed tmux-revive from $rc"
	done
	if have tmux && tmux info >/dev/null 2>&1; then
		tmux set-hook -gu 'client-detached[77]' 2>/dev/null || true
		pkill -f "$APP/scripts/daemon.sh" 2>/dev/null || true
	fi
	agent_unsetup
	rm -f "$BIN/tmux-revive" "$BIN/agent-say"
	rm -rf "$APP"
	if [ "${1:-}" = purge ]; then
		rm -rf "$DATA"
		say "deleted snapshots in $DATA"
	else
		say "snapshots kept in $DATA/snapshots (--purge deletes them)"
	fi
	say "tmux-revive uninstalled"
	exit 0
}

wire_config=1
for a in "$@"; do
	case $a in
	--uninstall) uninstall ;;
	--purge) uninstall purge ;;
	--no-config) wire_config=0 ;;
	*) die "unknown option: $a" ;;
	esac
done

OS=$(uname -s)
case $OS in
Linux | Darwin) ;;
MINGW* | MSYS* | CYGWIN*)
	die "tmux doesn't run natively on Windows. From PowerShell run:
    irm https://raw.githubusercontent.com/$REPO/$REF/install.ps1 | iex
  (it installs into WSL)" ;;
*) warn "untested OS: $OS, trying anyway" ;;
esac
grep -qi microsoft /proc/version 2>/dev/null && say "WSL detected"

# ------------------------------------------------------------- dependencies
if ! have tmux; then
	say "tmux not found, installing it"
	pkg_install tmux || die "install tmux with your package manager, then rerun"
fi
if [ "$OS" = Darwin ]; then
	ok=0
	for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do [ -x "$b" ] && ok=1; done
	if [ $ok = 0 ]; then
		say "macOS ships bash 3.2; installing a current bash with Homebrew"
		have brew || die "install Homebrew (https://brew.sh), then rerun"
		brew install bash
	fi
fi

# ------------------------------------------------------------------- fetch
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if [ -n "${REVIVE_SOURCE:-}" ]; then
	say "installing from $REVIVE_SOURCE"
	mkdir -p "$tmp/src"
	(cd "$REVIVE_SOURCE" && tar cf - --exclude=.git --exclude=.claude --exclude=vendor .) | (cd "$tmp/src" && tar xf -)
else
	say "downloading $REPO@$REF"
	fetch "https://codeload.github.com/$REPO/tar.gz/$REF" "$tmp/src.tgz" ||
		die "download failed: https://github.com/$REPO (ref $REF)"
	mkdir -p "$tmp/src"
	tar xzf "$tmp/src.tgz" -C "$tmp/src" --strip-components=1
fi
[ -f "$tmp/src/revive.tmux" ] || die "download doesn't look like tmux-revive"

# jq: use the system one, else a private static binary (no root needed).
if ! have jq; then
	arch=$(uname -m)
	case "$OS-$arch" in
	Linux-x86_64) asset=jq-linux-amd64 ;;
	Linux-aarch64 | Linux-arm64) asset=jq-linux-arm64 ;;
	Darwin-arm64) asset=jq-macos-arm64 ;;
	Darwin-x86_64) asset=jq-macos-amd64 ;;
	*) asset="" ;;
	esac
	if [ -n "$asset" ]; then
		say "jq not found, fetching a private copy ($asset $JQ_VERSION)"
		mkdir -p "$tmp/src/vendor/bin"
		base="https://github.com/jqlang/jq/releases/download/jq-$JQ_VERSION"
		fetch "$base/$asset" "$tmp/src/vendor/bin/jq"
		fetch "$base/sha256sum.txt" "$tmp/sums"
		want=$(awk -v a="$asset" '$2 == a { print $1 }' "$tmp/sums")
		if have sha256sum; then got=$(sha256sum "$tmp/src/vendor/bin/jq" | cut -d' ' -f1)
		else got=$(shasum -a 256 "$tmp/src/vendor/bin/jq" | cut -d' ' -f1); fi
		[ -n "$want" ] && [ "$want" = "$got" ] || die "jq checksum mismatch, aborting"
		chmod +x "$tmp/src/vendor/bin/jq"
	else
		pkg_install jq || die "install jq, then rerun"
	fi
fi

# ----------------------------------------------------------------- install
mkdir -p "$DATA"
rm -rf "$APP.old"
[ -d "$APP" ] && mv "$APP" "$APP.old"
mv "$tmp/src" "$APP"
rm -rf "$APP.old"
chmod +x "$APP/revive.tmux" "$APP/scripts/"*.sh "$APP/bin/tmux-revive" "$APP/bin/agent-say"
mkdir -p "$BIN"
ln -sf "$APP/bin/tmux-revive" "$BIN/tmux-revive"
ln -sf "$APP/bin/agent-say" "$BIN/agent-say"
say "installed to $APP"

# ------------------------------------------------------------ tmux config
if [ $wire_config = 1 ]; then
	conf=$(tmux_conf)
	mkdir -p "$(dirname "$conf")"
	touch "$conf"
	if ! grep -qF "$BEGIN" "$conf"; then
		cp "$conf" "$conf.bak-revive-$(date +%Y%m%d%H%M%S)"
	fi
	strip_block "$conf"
	# Last in the file, so its keys win over older save/restore plugins.
	{
		printf '\n%s\n' "$BEGIN"
		printf '%s\n' "# Saves on detach, every minute, and right before shutdown or sleep;"
		printf '%s\n' "# restores sessions, programs and Claude Code sessions on the next start."
		printf "run-shell '%s/revive.tmux'\n" "$APP"
		printf '%s\n' "$END"
	} >>"$conf"
	say "added tmux-revive to $conf"
	for rc in $(shell_rcs); do
		grep -qF "$BEGIN" "$rc" || cp "$rc" "$rc.bak-revive-$(date +%Y%m%d%H%M%S)"
		strip_block "$rc"
		{
			printf '\n%s\n' "$BEGIN"
			printf '%s\n' "# After a reboot, \`tmux attach\` restores your sessions before attaching."
			printf "TMUX_REVIVE_BIN='%s/bin/tmux-revive'\n" "$APP"
			printf "[ -f '%s/scripts/shell.sh' ] && . '%s/scripts/shell.sh'\n" "$APP" "$APP"
			printf '%s\n' "$END"
		} >>"$rc"
		say "added tmux-revive to $rc"
	done
	agent_setup
	if grep -Eq "^[[:space:]]*set(-option)?[[:space:]]+-g[[:space:]]+@continuum-restore[[:space:]]+['\"]?on" "$conf"; then
		warn "tmux-continuum auto-restore is on in $conf; turn it off or both will restore"
	fi
fi

# Start protecting the running server now; no restart needed.
if tmux info >/dev/null 2>&1; then
	tmux run-shell "$APP/revive.tmux"
	"$BIN/tmux-revive" save >/dev/null 2>&1 || true
	say "running tmux server is protected, first snapshot taken"
fi

case ":$PATH:" in *":$BIN:"*) ;; *) warn "$BIN is not on your PATH; add it to use the tmux-revive command" ;; esac

cat <<EOF

  Done. Nothing else to set up.

  Detaching saves. After a reboot, open a new terminal and run
  tmux  or  tmux attach  and every session comes back, with Claude Code
  resumed in the same conversation it was in. No keys to press.

  tmux-revive doctor               check everything is wired up
  tmux-revive update               get the latest version
  agent-say name claude            let agents in panes message each other

EOF
