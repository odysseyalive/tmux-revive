#!/usr/bin/env bash
# tmux-revive panel on a private tmux server (never touches yours): what it shows, that it
# fits the terminal, and that its keys work.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/panel-test.XXXXXX")
unset TMUX TMUX_PANE
export REVIVE_DIR=$T/data AGENT_SAY_MAILBOX=$T/mail/mailbox.md REVIVE_PANEL_REFRESH=1 REVIVE_PANEL_SPLASH=0
tm() { tmux -L "revive-panel-test-$$" -f /dev/null "$@"; }
pass=0 fail=0
check() {
	if eval "$2"; then
		printf '  \033[32mpass\033[0m %s\n' "$1"; ((pass++))
	else
		printf '  \033[31mFAIL\033[0m %s\n' "$1"; ((fail++))
	fi
}
cleanup() { tm kill-server 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
plain() { sed 's/\x1b\[[0-9;]*m//g'; }
screen() { tm capture-pane -p -t work:panel; }
wait_screen() { for _ in $(seq 1 30); do screen | grep -qF -- "$1" && return 0; sleep 0.2; done; return 1; }

tm new-session -d -s work -x 130 -y 40 "bash --norc --noprofile"
tm split-window -d -t work "top -d 5"
sleep 0.5

echo "one frame"
# Inside the private server, so the panel reads its panes, not yours.
frame() { tm run-shell "COLUMNS=$1 LINES=${2:-40} REVIVE_PANEL_ART=${3:-} REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX bash $ROOT/scripts/panel.sh --once" | plain; }
for size in "80 24" "100 40" "130 40" "200 60"; do
	read -r c l <<<"$size"
	shape=$(frame "$c" "$l" | awk '{w[length]=1; n++} END{for (k in w) printf "%s ", k; print "x " n}')
	check "it fills a ${c}x$l pane exactly ($shape)" "[[ '$shape' == '$c x $l' ]]"
done
for a in city mountains ocean space circuit rain grid; do
	out=$(frame 120 45 "$a")
	check "the $a artwork draws and fits" "grep -q 'ART · ' <<<\"\$out\" && [[ \$(awk '{w[length]=1} END{for (k in w) n++; print n}' <<<\"\$out\") == 1 ]]"
done
out=$(frame 130)
check "a shell pane shows as a shell" "grep -q 'bash *· shell' <<<\"\$out\""
check "a program shows as running" "grep -q 'top *▸ running' <<<\"\$out\""
check "the command keys are listed" "grep -qF '[J]ump  [M]essage  [N]ame  [L]ink  [U]nlink  [P]eek  [A]rt  [S]ave  [Q]uit' <<<\"\$out\""
# Under heavy load one frame can come back short, so allow three looks; a real regression
# misses every time, and then the frame is printed to show what was seen.
narrow_ok() { local i f; for i in 1 2 3; do f=$(frame 80); grep -q 'top *▸ running' <<<"$f" && return 0; done; printf '%s\n' "$f" | grep -E '\[[0-9]\]' >&2; return 1; }
check "a narrow terminal still finds programs (ps not cut to COLUMNS)" "narrow_ok"

echo "keys"
tm new-window -d -t work -n panel "env REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX REVIVE_PANEL_REFRESH=1 bash $ROOT/scripts/panel.sh"
wait_screen 'C O N T R O L'
check "it labels its own pane" "screen | grep -q 'panel *✦ this panel'"
tm send-keys -t work:panel 2
check "a number selects that pane" "wait_screen '[2] ▶'"
tm send-keys -t work:panel n; sleep 0.5
tm send-keys -t work:panel 'top-watch' Enter
named() { for _ in $(seq 1 30); do tm list-panes -a -F '#{@agent}' | grep -qx "$1" && return 0; sleep 0.2; done; return 1; }
check "N renames the selected pane" "named top-watch && wait_screen '▶ top-watch'"
tm send-keys -t work:panel s
check "S saves" "wait_screen '(manual)'"
check "the peek box shows the selected pane" "screen | grep -q 'PEEK · top-watch'"
tm send-keys -t work:panel p; sleep 1.5
check "P hides the peek box" "! screen | grep -q 'PEEK'"
tm send-keys -t work:panel Down
check "the arrow keys move the selection" "wait_screen '[3] ▶'"
tm send-keys -t work:panel m; sleep 0.5
check "M opens the message prompt, saying how to back out" "wait_screen 'Esc cancels'"
tm send-keys -t work:panel -l 'never sent'; sleep 0.3
tm send-keys -t work:panel Escape
check "Esc backs out of a message" "wait_screen 'message cancelled' && ! screen | grep -q 'Esc cancels'"
tm send-keys -t work:panel m; sleep 0.5
tm send-keys -t work:panel -l 'never sent either'; sleep 0.3
tm send-keys -t work:panel C-c; sleep 1
check "Ctrl-C backs out too, and the panel stays open" "tm list-windows -F '#{window_name}' | grep -qx panel && wait_screen 'C O N T R O L' && ! screen | grep -q 'Esc cancels'"
check "nothing was sent" "! grep -qs 'never sent' $AGENT_SAY_MAILBOX"
before=$(screen | grep -o 'ART · [a-z ]*' | head -1)
tm send-keys -t work:panel a
check "A switches the artwork ($before)" "for _ in \$(seq 1 20); do after=\$(screen | grep -o 'ART · [a-z ]*' | head -1); [[ -n \$after && \$after != '$before' ]] && break; sleep 0.2; done; [[ \$after != '$before' ]]"
tm send-keys -t work:panel q; sleep 1
check "Q quits" "! tm list-windows -F '#{window_name}' | grep -qx panel"

echo "ssh links"
# Which host an ssh command line connects to, as agent-say link takes it.
dest() { bash -c 'source <(sed -n "/^ssh_dest() {/,/^}/p" "$1"); ssh_dest "$2"' _ "$ROOT/scripts/panel.sh" "$1"; }
check "ssh host" "[[ \$(dest 'ssh devbox') == devbox ]]"
check "ssh with options, a user and a command" "[[ \$(dest 'ssh -i /k -p 22 me@h.example ls -la') == h.example ]]"
check "ssh:// with a port" "[[ \$(dest 'ssh ssh://me@h2.example:2222') == h2.example ]]"
check "a jump host is skipped for the destination" "[[ \$(dest '/usr/bin/ssh -J jump h3 uptime') == h3 ]]"
check "not ssh, or a host that can't be one" "[[ -z \$(dest 'sshd -D') && -z \$(dest 'ssh \"bad;host\"') ]]"

# ssh outside tmux (another terminal) is found too; ssh that other tools start for themselves isn't.
bash -c 'exec -a "ssh me@outside.example" sleep 60' & o1=$!
bash -c 'exec -a "ssh -o BatchMode=yes linkpoll.example agent-say _sync x" sleep 60' & o2=$!
bash -c 'exec -a "ssh -o SendEnv=GIT_PROTOCOL git@gitfetch.example git-upload-pack x" sleep 60' & o3=$!
bash -c 'exec -a "ssh -x -oForwardAgent=no -s sftpcopy.example sftp" sleep 60' & o4=$!
sleep 0.5
out=$(frame 140 45)
check "an ssh session outside tmux is offered for linking" "grep -q 'outside.example · ssh in' <<<\"\$out\""
check "agent-say's own, git's and sftp's ssh aren't" "! grep -qE 'linkpoll.example|gitfetch.example|sftpcopy.example' <<<\"\$out\""
kill $o1 $o2 $o3 $o4 2>/dev/null; wait $o1 $o2 $o3 $o4 2>/dev/null

tm new-window -d -t work -n sshpanel "env REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX AGENT_SAY_SSH=false REVIVE_PANEL_REFRESH=1 bash $ROOT/scripts/panel.sh"
sshscreen() { tm capture-pane -p -t work:sshpanel; }
wait_ssh() { for _ in $(seq 1 40); do sshscreen | grep -qF -- "$1" && return 0; sleep 0.2; done; return 1; }
wait_ssh 'C O N T R O L'
# A pane connecting somewhere: a process whose command line is an ssh one.
tm new-window -d -t work -n remote "bash -c 'exec -a \"ssh -p 2222 me@devbox.example\" sleep 300'"
check "a new ssh connection is announced" "wait_ssh 'new ssh: devbox.example · L links it'"
check "and offered for linking" "wait_ssh 'devbox.example · ssh in'"
tm send-keys -t work:sshpanel u
check "U with nothing linked says so" "wait_ssh 'nothing is linked'"
tm send-keys -t work:sshpanel l; sleep 0.7
check "L opens a popup listing the ssh hosts" "wait_ssh 'LINK AGENTS ON' && sshscreen | grep -q 'devbox.example  · ssh in' && sshscreen | grep -q 'other host'"
check "the popup says how to close it" "sshscreen | grep -q 'Esc closes'"
# Every row of the popup has its right edge in the same column as the top-right corner.
popup_square() {
	sshscreen | awk '
		index($0, "LINK AGENTS ON") && !l { l = index($0, "╔"); r = index($0, "╗"); top = NR; next }
		l && NR > top && !done {
			c = substr($0, r, 1)
			if (c != "║" && c != "╝") bad = 1
			if (c == "╝") done = 1
		}
		END { exit !(l && r > l && done && !bad) }'
}
check "the popup's edges line up on every row" "popup_square"
tm send-keys -t work:sshpanel Escape
check "Esc closes the popup" "wait_ssh 'link cancelled' && ! sshscreen | grep -q 'LINK AGENTS ON'"
tm send-keys -t work:sshpanel l; sleep 0.7; tm send-keys -t work:sshpanel Enter
check "Enter links the chosen host and shows what happened" "wait_ssh \"couldn't run agent-say on devbox.example\""
# Pretend the link is up, then take it down with U.
st=$(dirname "$AGENT_SAY_MAILBOX"); mkdir -p "$st/links/devbox.example"; touch "$st/links/devbox.example/on"
check "a linked host is no longer offered" "for _ in \$(seq 1 20); do sshscreen | grep -q 'devbox.example · ssh in' || break; sleep 0.2; done; ! sshscreen | grep -q 'devbox.example · ssh in'"
tm send-keys -t work:sshpanel u; sleep 0.7
check "U opens a popup listing the links" "wait_ssh 'UNLINK' && sshscreen | grep -q 'devbox.example  ·'"
tm send-keys -t work:sshpanel 1
check "a number picks from the list and unlinks it" "wait_ssh 'unlinked devbox.example' && [[ ! -e $st/links/devbox.example ]]"
tm send-keys -t work:sshpanel q
tm kill-window -t work:remote 2>/dev/null

echo "splash"
tm new-window -d -t work -n splash "env REVIVE_PANEL_SPLASH=1 REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX bash $ROOT/scripts/panel.sh"
check "the dial-up splash plays" "for _ in \$(seq 1 40); do tm capture-pane -p -t work:splash | grep -q 'CONNECT 33600' && break; sleep 0.1; done; tm capture-pane -p -t work:splash | grep -q 'CONNECT 33600'"
tm send-keys -t work:splash x
check "a key skips it to the panel" "for _ in \$(seq 1 30); do tm capture-pane -p -t work:splash | grep -q 'C O N T R O L' && break; sleep 0.2; done; tm capture-pane -p -t work:splash | grep -q 'C O N T R O L'"
tm send-keys -t work:splash q

echo "hostile text"
# Folder names, pane names, mail from linked machines and git config all come from elsewhere.
# None of it may put an escape sequence on the terminal or make the panel run a command.
raw() { tm run-shell "COLUMNS=130 LINES=50 REVIVE_DIR=$REVIVE_DIR AGENT_SAY_MAILBOX=$AGENT_SAY_MAILBOX bash $ROOT/scripts/panel.sh --once"; }
evil="$T/evil"$'\e]52;c;cHduZWQ=\a\e[2Jdir'
mkdir -p "$evil"
mkdir -p "$T/mail"
printf '## [mallory -> panel 2026-11-07T10:00:00Z] #1\nhi\e]52;c;cHduZWQ=\athere\n\n' >>"$AGENT_SAY_MAILBOX"
git init -q -b fsmtest "$T/fsm"
echo x >"$T/fsm/f" && git -C "$T/fsm" add f && git -C "$T/fsm" -c user.name=t -c user.email=t@t commit -q -m f
git -C "$T/fsm" config core.fsmonitor "touch $T/fsmonitor-ran; false"
git -C "$T/fsm" config core.hooksPath "$T/hooks"
mkdir -p "$T/hooks" && printf '#!/bin/sh\ntouch %s/hook-ran\n' "$T" >"$T/hooks/post-index-change" && chmod +x "$T/hooks/post-index-change"
echo y >"$T/fsm/f"
git init -q "$T/flt" && echo x >"$T/flt/f" && echo '* filter=x' >"$T/flt/.gitattributes"
git -C "$T/flt" add f .gitattributes && git -C "$T/flt" -c user.name=t -c user.email=t@t commit -q -m f
git -C "$T/flt" config filter.x.clean "touch $T/filter-ran; cat"
echo y >"$T/flt/f"
tm kill-window -t work:splash 2>/dev/null
tm new-window -d -t work -n evil -c "$evil" "bash --norc --noprofile"
tm new-window -d -t work -n fsm -c "$T/fsm" "bash --norc --noprofile"
tm new-window -d -t work -n flt -c "$T/flt" "bash --norc --noprofile"
tm set-option -p -t work:evil @agent $'bad\e]0;x\aname'
mkdir -p "$T/mail/links/faraway" && touch "$T/mail/links/faraway/on"
printf 'ssh: \e]52;c;eA==\adown\n' >"$T/mail/links/faraway/error"
sleep 0.5
out=$(raw)
# The frame with the panel's own colour codes taken out: no control character may be left.
bare=$(sed 's/\x1b\[[0-9;]*m//g' <<<"$out")
check "the folder name shows, its escape sequence doesn't" "grep -qF 'evil]52;c;cHduZWQ=[2Jdir' <<<\"\$bare\""
check "a pane name's escape is stripped" "grep -qF 'bad]0;xname' <<<\"\$bare\""
check "a link's error (remote ssh stderr) is stripped" "grep -qF 'ssh: ]52;c;eA==down' <<<\"\$bare\""
check "a mailbox body's OSC 52 is stripped" "grep -qF 'hi]52;c;cHduZWQ=there' <<<\"\$bare\""
check "the only escapes in a frame are the panel's own colours" "! LC_ALL=C grep -q '[[:cntrl:]]' <<<\"\$bare\""
check "git state still shows (branch, dirty)" "grep -qF 'fsmtest*' <<<\"\$bare\""
check "a repo's core.fsmonitor command never runs" "[[ ! -e $T/fsmonitor-ran ]]"
check "a repo's hooks never run" "[[ ! -e $T/hook-ran ]]"
check "a repo's own clean filter never runs" "[[ ! -e $T/filter-ran ]]"

echo "$pass passed, $fail failed"
((fail == 0))
