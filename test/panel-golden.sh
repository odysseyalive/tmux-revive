#!/usr/bin/env bash
# The Rust panel is checked against the bash one, frame for frame (plan/rust-panel-2026-11-23.md).
# Everything runs on private tmux servers and in a folder of its own (never yours):
#
#   bash test/panel-golden.sh          all of it: snaps, components, render, twins
#   bash test/panel-golden.sh snaps    snapshots saved by --once from a fixture server, each loaded
#                                      back and drawn: the same frame as the save run drew, at every
#                                      size alone as in one REVIVE_PANEL_SIZES run (tier 1's ground)
#   bash test/panel-golden.sh components  until the Rust panel draws a frame: what it has ported,
#                                      call by call, against panel.sh's own functions (needs cargo,
#                                      or GOLDEN_RS); the art at the sizes the frames draw it
#   bash test/panel-golden.sh render   every scenario at every size, panel A's frames against B's,
#                                      byte for byte (tier 1)
#   bash test/panel-golden.sh twins    A and B live, each on a server of its own with the same
#                                      fixtures, the same keys sent to both, their screens and
#                                      cursors compared with CPU, memory and the cpu graph masked
#                                      (tier 3)
#
# GOLDEN_A and GOLDEN_B: the two panels, as commands: A bash scripts/panel.sh, B the Rust one,
# panel-rs/target/release/tmux-revive-panel (built here with cargo unless GOLDEN_B is given). The
# twins are B only once the Rust panel runs live (Phase 3): until then GOLDEN_TWINS_B, bash by
# default, stands in for it there. A's frames are kept in
# GOLDEN_CACHE (~/.cache/tmux-revive/golden), under the sha256 of the panel's scripts, VERSION,
# this file and the scenario's snapshot, so a change that touches only B renders only B. With
# the same command on both sides, B renders afresh and A comes from the cache when it can: run
# twice, that is the harness proving itself stable. GOLDEN_NOCACHE=1 renders both.
# GOLDEN_SWEEP=1: every width from 80 to 220 in steps of 7, not just the named grid.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/panel-golden.XXXXXX")
unset TMUX TMUX_PANE XDG_STATE_HOME # never your tmux, nor your state dir
GOLDEN_A=${GOLDEN_A:-bash $ROOT/scripts/panel.sh}
RS_BIN=$ROOT/panel-rs/target/release/tmux-revive-panel
GOLDEN_B=${GOLDEN_B:-$RS_BIN}
GOLDEN_TWINS_B=${GOLDEN_TWINS_B:-bash $ROOT/scripts/panel.sh}
# The Rust panel, built when it is the one B runs.
build_b() {
	[[ $GOLDEN_B == "$RS_BIN" ]] || return 0
	command -v cargo >/dev/null || { echo "  no cargo to build panel-rs with (or set GOLDEN_B)" >&2; return 1; }
	cargo build --release --locked --quiet --manifest-path "$ROOT/panel-rs/Cargo.toml"
}
CACHE=${GOLDEN_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/tmux-revive/golden}
# The clock: the save runs' is now (a linked computer's rows have to be fresh), and every frame
# drawn from a snapshot is drawn at RNOW, the times in it moved along to match.
SNOW=$(date +%s) RNOW=1795000000
GRID=""
for w in 80 100 130 200; do for h in 24 40 60; do GRID+="${w}x$h "; done; done
if [[ ${GOLDEN_SWEEP:-} == 1 ]]; then
	GRID=""
	for ((w = 80; w <= 220; w += 7)); do for h in 24 40 60; do GRID+="${w}x$h "; done; done
fi
pass=0 fail=0
check() {
	if eval "$2"; then
		printf '  \033[32mpass\033[0m %s\n' "$1"; ((pass++))
	else
		printf '  \033[31mFAIL\033[0m %s\n' "$1"; ((fail++))
	fi
}
sockets=()
cleanup() {
	local s
	for s in "${sockets[@]}"; do tmux -S "$s" kill-server 2>/dev/null; done
	[[ -n ${KEEP:-} ]] || rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP
plain() { sed 's/\x1b\[[0-9;]*m//g'; }
# A notice long enough to wrap to three lines in its box (70 columns at most).
LONG_NOTICE="linked to far.example with the key from your known_hosts: SHA256:Xq3v9yTzW1bK8mPpL0aRfE6cD2sN4uH7jG5iO1kQwYc. Its panes show in PANES once its first rows came in, and B unlinks it."

# fixtures DIR SOCKET [links]: a tmux server at SOCKET, its panes, and the state a panel run with
# DIR's environment (env_for) reads: a shell with text on its screen, a stand-in agent (a copy of
# bash named codex) asking a question, a pane in a folder whose name isn't UTF-8, messages, an
# access request waiting, a save. With "links": three linked computers, answered by a fake ssh
# (far.example with rows and a peek, folded.example folded, Zed.example unreachable), and a ps
# that adds ssh sessions outside tmux, two to one host.
fixtures() {
	local d=$1 s=$2 st=$1/state
	mkdir -p "$d/home" "$d/data/snapshots/s1" "$st/intros/i1" "$d/bin" "$d/work/shop" "$d/work/"$'caf\xe9-\xff' "$d/fakeps"
	echo 9.9.0 >"$d/version"
	cp "$(command -v bash)" "$d/bin/codex"
	cat >"$d/ask.sh" <<'ASK'
# A stand-in agent asking a question, as Claude Code draws one: history above (a long line
# among it), a rule, a tab bar, the question, its choices (one to type into) and the footer.
stty -echo -icanon 2>/dev/null
clear
for i in 1 2 3 4 5 6; do echo "history line $i"; done
echo "a long line of history that goes on and on past the width of the peek box, so that it wraps onto the rows under it, $(printf 'word %.0s' {1..30})"
echo; printf '─%.0s' {1..50}; echo
printf '←  \e[48;5;153m ☐ Cleanup \e[49m  ✔ Submit  →\n'; echo
echo " Do you want to proceed?"; echo
echo " ❯ 1. Yes"; echo "      what choosing Yes does"
echo "   2. No"; echo "   3. Type something."
echo; echo " Enter to select · ↑/↓ to navigate · Esc to cancel"
sleep 100000
ASK
	cat >"$d/shop.sh" <<'SH'
cd "$1" && clear && printf 'make: Nothing to be done for all.\n\e[1;32mok\e[0m tests passed · 12 of 12\nwide: %s\n' "$(printf '±%.0s' {1..150})"
exec bash --norc --noprofile
SH
	tmux -S "$s" -f /dev/null new-session -d -s work -x 130 -y 40 -c "$d/work/shop" "bash $d/shop.sh $d/work/shop"
	sockets+=("$s")
	tmux -S "$s" new-window -d -t work -n asker -c "$d/work" "$d/bin/codex $d/ask.sh"
	tmux -S "$s" set-option -p -t work:asker @agent asker
	tmux -S "$s" new-window -d -t work -n odd -c "$d/work/"$'caf\xe9-\xff' "bash --norc --noprofile"
	tmux -S "$s" set-option -p -t work:odd @agent "odd-one"
	# Messages: delivered ones, one held, one not delivered; an access request waiting on you.
	cat >"$st/mailbox.md" <<'MAIL'
## [asker@golden -> shop@golden 2026-11-23T09:01:00Z] #m1
tests are green, merging now
## [shop@golden -> asker@golden 2026-11-23T09:02:00Z] #m2
thanks · rebasing mine on top
## [far-top@far.example -> asker@golden 2026-11-23T09:03:00Z] #h1795000000.1 (held: waiting for access)
can I read your build log?
## [asker@golden -> gone@golden 2026-11-23T09:04:00Z] #m3 (NOT DELIVERED: no such session)
are you still there?
## [asker@golden -> shop@golden 2026-11-23T09:05:00Z] #m4
one more for the scroll
## [shop@golden -> asker@golden 2026-11-23T09:06:00Z] #m5
and another
MAIL
	echo far-top@far.example >"$st/intros/i1/from"
	echo asker@golden >"$st/intros/i1/to"
	echo 1795000000 >"$st/intros/i1/created"
	echo "can I read your build log?" >"$st/intros/i1/intro"
	printf '{"saved_at":"2026-11-23T08:30:00Z","reason":"auto"}\n' >"$d/data/snapshots/s1/state.json"
	ln -s snapshots/s1 "$d/data/last"
	[[ ${3:-} == links ]] || return 0
	local h
	for h in far.example folded.example Zed.example; do mkdir -p "$st/links/$h"; : >"$st/links/$h/on"; done
	printf 'far-top\nfar-claude\n' >"$st/links/far.example/names"
	printf 'fold-sh\n' >"$st/links/folded.example/names"
	printf 'zed-a\nzed-b\n' >"$st/links/Zed.example/names"
	echo "ssh: connect to host Zed.example port 22: Connection refused" >"$st/links/Zed.example/error"
	mkdir -p "$d/data/panel/fold" && : >"$d/data/panel/fold/folded.example"
	# The fake ssh: the host is the next to last argument, the command the last.
	{
		printf '#!/bin/bash\nhost=${*: -2:1} cmd=${!#} S=$%s\n' "'\\x1f'"
		cat <<'SSH'
[[ $host == Zed.example ]] && exit 255
if [[ $cmd == *' panel --rows' ]]; then
	echo '#version 1.2.0'
	if [[ $host == far.example ]]; then
		echo '#ctx %2 37'
		printf '%s\n' "%1${S}far:0.1${S}far-top${S}top${S}program${S}srv${S}main${S}12${S}204800${S}0"
		printf '%s\n' "%2${S}far:1.0${S}far-claude${S}claude${S}asking${S}api${S}main*${S}3${S}512000${S}1"
	else
		printf '%s\n' "%1${S}fold:0.0${S}fold-sh${S}bash${S}shell${S}home${S}${S}0${S}4096${S}0"
	fi
	exit 0
fi
if [[ $cmd == *' panel --peek '* ]]; then
	printf 'top - 10:00:00 up 3 days,  1 user,  load average: 0.10, 0.20, 0.30\nTasks: 99 total\n\n  PID USER  %%CPU COMMAND\n  101 srv    12.0 node\n'
	exit 0
fi
exit 127
SSH
	} >"$d/bin/fakessh"
	chmod +x "$d/bin/fakessh"
	# A ps with your own ssh sessions taken out and three made up: two to alpha.example (one
	# under a kitty, one not) and one to zeta.example, out of order.
	{
		printf '#!/bin/bash\nif [[ $* != *uid=* ]]; then exec %q "$@"; fi\n' "$(command -v ps)"
		printf '%q "$@" | awk '"'"'$6 !~ /(^|\\/)ssh$/'"'"'\n' "$(command -v ps)"
		printf 'printf "%%s\\n" " 999993 1 %s 0 0.0 ssh me@zeta.example" " 999990 1 %s 0 0.0 kitty" " 999991 999990 %s 0 0.0 ssh alpha.example" " 999992 1 %s 0 0.0 ssh alpha.example"\n' "$UID" "$UID" "$UID" "$UID"
	} >"$d/fakeps/ps"
	chmod +x "$d/fakeps/ps"
}
# env_for DIR SOCKET: the environment a panel on that fixture runs in (an env argument list).
env_for() {
	ENV=(HOME="$1/home" USER=golden LC_ALL=C.UTF-8 TZ=UTC TERM=xterm-256color REVIVE_SOCKET="$2" REVIVE_DIR="$1/data"
		AGENT_SAY_MAILBOX="$1/state/mailbox.md" AGENT_SAY_SSH="$1/bin/fakessh" REVIVE_VERSION_FILE="$1/version"
		REVIVE_PANEL_SPLASH=0 REVIVE_PANEL_LOADBOX=0 REVIVE_PANEL_OUTSIDE_SSH=0 REVIVE_PANEL_TIP_SECS=30
		REVIVE_PANEL_ART=city REVIVE_PANEL_PEEK=1 CODEX_HOME="$1/home/.codex" CLAUDE_CONFIG_DIR="$1/home/.claude")
}
# Drawing from a snapshot needs no tmux, no files and no other computer: the socket is one that
# isn't there, so a look that slipped through would find nothing, never your tmux.
RENV=(HOME=/tmp/golden/home USER=golden LC_ALL=C.UTF-8 TZ=UTC TERM=xterm-256color REVIVE_SOCKET="$T/no-such-socket"
	REVIVE_DIR="$T/rdir" AGENT_SAY_MAILBOX="$T/rstate/mailbox.md" AGENT_SAY_SSH=false REVIVE_PANEL_TIP_SECS=30
	REVIVE_PANEL_SPLASH=0 REVIVE_PANEL_LOADBOX=0 REVIVE_PANEL_NOW=$RNOW)

# snapshot records: snap_get FILE -> SN, SK, SV (as the panel reads them); snap_put_all FILE writes them.
snap_get() {
	local n k v
	SN=() SK=() SV=()
	while IFS= read -r -d '' n && IFS= read -r -d '' k && IFS= read -r -d '' v; do SN+=("$n") SK+=("$k") SV+=("$v"); done <"$1"
}
snap_put_all() { local i; for i in "${!SN[@]}"; do printf '%s\0%s\0%s\0' "${SN[i]}" "${SK[i]}" "${SV[i]}"; done >"$1"; }
# snapedit IN OUT EDIT...: IN with each EDIT made, into OUT. NAME=VALUE sets a variable,
# NAME[KEY]=VALUE one element, NAME=() empties an array; NAME+=VALUE adds an element at the end.
snapedit() {
	local in=$1 out=$2 e n k v i last
	shift 2
	snap_get "$in"
	for e; do
		if [[ $e =~ ^([A-Z_]+)=\(\)$ ]]; then
			n=${BASH_REMATCH[1]}
			for i in "${!SN[@]}"; do [[ ${SN[i]} == "$n" ]] && unset "SN[i]" "SK[i]" "SV[i]"; done
		elif [[ $e =~ ^([A-Z_]+)\+=(.*)$ ]]; then
			n=${BASH_REMATCH[1]} v=${BASH_REMATCH[2]} last=-1
			for i in "${!SN[@]}"; do [[ ${SN[i]} == "$n" ]] && ((SK[i] > last)) && last=${SK[i]}; done
			SN+=("$n") SK+=($((last + 1))) SV+=("$v")
		elif [[ $e =~ ^([A-Z_]+)(\[([^]]*)\])?=(.*)$ ]]; then
			n=${BASH_REMATCH[1]} k=${BASH_REMATCH[3]} v=${BASH_REMATCH[4]}
			for i in "${!SN[@]}"; do [[ ${SN[i]} == "$n" && ${SK[i]} == "$k" ]] && unset "SN[i]" "SK[i]" "SV[i]"; done
			SN+=("$n") SK+=("$k") SV+=("$v")
		else
			echo "snapedit: can't read $e" >&2; return 1
		fi
	done
	SN=("${SN[@]}") SK=("${SK[@]}") SV=("${SV[@]}")
	snap_put_all "$out"
}
# snapclone IN OUT FROM N: IN with N more panes, each a copy of pane FROM's P_* records, put after
# the last, named clone-1 .. clone-N (PANES with more rows than it has room for).
snapclone() {
	local in=$1 out=$2 from=$3 n=$4 i j top=-1
	snap_get "$in"
	for i in "${!SN[@]}"; do [[ ${SN[i]} == P_ID ]] && ((SK[i] > top)) && top=${SK[i]}; done
	for i in "${!SN[@]}"; do
		[[ ${SN[i]} == P_* && ${SK[i]} == "$from" ]] || continue
		for ((j = 1; j <= n; j++)); do
			SN+=("${SN[i]}") SK+=($((top + j)))
			case ${SN[i]} in
			P_ID) SV+=("%9$j") ;;
			P_NAME) SV+=("clone-$j") ;;
			P_WP) SV+=("9.$j") ;;
			*) SV+=("${SV[i]}") ;;
			esac
		done
	done
	snap_put_all "$out"
}
# snapfix IN OUT DIR: a saved snapshot made the same from one run to the next, so A's cached frames
# hold: the fixture's folder becomes /tmp/golden, this computer and you "golden", CPU and memory
# fixed figures, and the times it measured moved from the save's clock to RNOW.
snapfix() {
	local i v d=$3 me host shift=$((RNOW - SNOW))
	me=$(id -un) host=$(hostname -s 2>/dev/null || uname -n)
	snap_get "$1"
	for i in "${!SN[@]}"; do
		v=${SV[i]//"$d"/\/tmp\/golden}
		case ${SN[i]} in
		HOST) v=golden ;;
		P_USER) [[ $v == "$me" ]] && v=golden ;;
		P_CPU) v=$((SK[i] % 3 * 21)) ;;
		P_MEM) v=$((SK[i] * 91237 + 2048)) ;;
		CPU_HIST) v=$((SK[i] * 17 + 3)) ;;
		SECONDS) v=2 ;;
		W_SINCE | P_LIM) [[ $v =~ ^[0-9]+$ ]] && v=$((v + shift)) ;;
		esac
		v=${v//"$host"/golden}
		SV[i]=$v
	done
	snap_put_all "$2"
}

# ------------------------------------------------------------------ snaps
# save NAME SEL [ENV...]: a --once on the fixture, its snapshot kept as NAME (the frame it drew as
# NAME.direct). SEL is the selected pane's window name, a linked pane's NAME@HOST, or "".
save() {
	local name=$1 sel=$2 id=""
	shift 2
	case $sel in
	*@*) id=$sel ;;
	?*) id=$(tmux -S "$FS" display -p -t "work:$sel" '#{pane_id}') ;;
	esac
	env "${ENV[@]}" REVIVE_PANEL_NOW="$SNOW" REVIVE_PANEL_SEL="$id" COLUMNS=130 LINES=45 "$@" \
		REVIVE_PANEL_SNAP="save:$T/snap/$name.raw" timeout 120 bash "$ROOT/scripts/panel.sh" --once >"$T/snap/$name.direct" </dev/null
	# And a --once with no snapshot at all, which draws from its own looks as it goes.
	env "${ENV[@]}" REVIVE_PANEL_NOW="$SNOW" REVIVE_PANEL_SEL="$id" COLUMNS=130 LINES=45 "$@" \
		timeout 120 bash "$ROOT/scripts/panel.sh" --once </dev/null | python3 "$T/mask.py" >"$T/snap/$name.plain"
	SAVED+=("$name")
}
snaps() {
	echo "snapshots"
	mkdir -p "$T/snap" "$T/fx"
	FS=$T/fx.sock
	fixtures "$T/fx" "$FS" links
	env_for "$T/fx" "$FS"
	sleep 1 # the panes draw their screens
	SAVED=()
	save shell 0
	save shell-hidden 0 REVIVE_PANEL_PEEK=0
	save outside 0 REVIVE_PANEL_PEEK=0 REVIVE_PANEL_OUTSIDE_SSH=1 PATH="$T/fx/fakeps:$PATH"
	save question asker
	save odd odd
	save linked far-top@far.example
	save linked-ask far-claude@far.example
	save help 0 REVIVE_PANEL_HELP=1
	save tick7 0 REVIVE_PANEL_PEEK=0 REVIVE_PANEL_TICK=7 REVIVE_PANEL_ART=space
	# A notice's box over the panel, short, and long enough to wrap to several lines.
	save notice 0 "REVIVE_PANEL_NOTICE=saved"
	save notice-long 0 "REVIVE_PANEL_NOTICE=$LONG_NOTICE"
	local n s ok
	for n in "${SAVED[@]}"; do
		# Loaded back, at the size it was saved at and the save's own clock: the frame the save drew.
		env "${ENV[@]}" REVIVE_PANEL_NOW="$SNOW" COLUMNS=130 LINES=45 REVIVE_SOCKET="$T/no-such-socket" \
			REVIVE_PANEL_SNAP="load:$T/snap/$n.raw" bash "$ROOT/scripts/panel.sh" --once >"$T/snap/$n.load" </dev/null
		check "$n: saved, then loaded, it draws the frame the save drew" "[[ -s $T/snap/$n.direct ]] && cmp -s $T/snap/$n.direct $T/snap/$n.load"
		# The snapshot's frame is a plain --once's: what snap_look read for it is what draw reads.
		check "$n: and that is the frame a --once with no snapshot draws (CPU and memory masked)" "python3 $T/mask.py <$T/snap/$n.direct | cmp -s - $T/snap/$n.plain"
		snapfix "$T/snap/$n.raw" "$T/snap/$n" "$T/fx"
	done
	# Where you are in the panel can't be set from outside for a --once: these change it in a
	# snapshot (the plan's scenario list, Phase 1.4, is built out from here).
	local -a ql
	snap_get "$T/snap/question"
	ql=()
	for n in "${!SN[@]}"; do [[ ${SN[n]} == SCREEN ]] && ql+=("QL+=${SV[n]}"); done
	snapedit "$T/snap/question" "$T/snap/answering" ANSWERING=1 "${ql[@]}"
	snapedit "$T/snap/question" "$T/snap/answering-flash" ANSWERING=1 QON=1 "${ql[@]}" "FLASH=a letter goes in the box: press E first" FLASH_T=1
	snapedit "$T/snap/shell" "$T/snap/flash" "FLASH=saved · 3 sessions" FLASH_T=0
	snapedit "$T/snap/shell" "$T/snap/focus-messages" FOCUS=2 MMAN=1 MO=1
	snapedit "$T/snap/shell" "$T/snap/focus-links" FOCUS=3 SO=1
	snapedit "$T/snap/shell" "$T/snap/focus-peek" FOCUS=1 PB=3
	snapedit "$T/snap/linked" "$T/snap/heading" HSEL=far.example
	snapedit "$T/snap/linked" "$T/snap/folded" "FOLD[far.example]=1" HSEL=far.example
	snapedit "$T/snap/help" "$T/snap/help-scrolled" HELP_TOP=30
	# A notice over the ? page; one waiting while a question is answered (no box till it's done);
	# and a second behind the first, which shows only once that one is closed.
	snapedit "$T/snap/help" "$T/snap/help-notice" "NOTICES+=open this in your browser: https://example.com/tmux-revive/help"
	snapedit "$T/snap/answering" "$T/snap/answering-notice" "NOTICES+=saved"
	snapedit "$T/snap/notice" "$T/snap/notice-queued" "NOTICES+=a second notice, shown after the first"
	# The rows' other states (the fixture's panes are 0 shell, 1 asker, 2 odd-one, 3-4 on
	# Zed.example, 5-6 on far.example, 7 on folded.example): a usage limit that lifts today and
	# one another day, ready (after a limit, and on a new plan), waiting on you by age and by
	# who began the turn, idle, a server still running, busy in the background, a login, the
	# panel itself; an ACCOUNT, an old VER and [U], context running low. Selected, the limited
	# pane, the planned one and the server's give the peek's other titles.
	local -a st=(
		P_STATE[0]=limit "P_LIM[0]=$((RNOW + 3600))" P_STATE[2]=waiting "W_SINCE[2]=$((RNOW - 120))" W_FROM[2]=u
		P_STATE[3]=waiting "W_SINCE[3]=$((RNOW - 1200))" W_FROM[3]=a P_STATE[4]=ready P_LWHY[4]=plan
		P_STATE[5]=waiting "W_SINCE[5]=$((RNOW - 9000))" W_FROM[5]=u P_SRV[5]=1 P_STATE[6]=agents P_STATE[7]=login
		"P_ACCT[1]=me@example.com" P_USER[3]=root P_INST[3]=1.0.0 P_USER[4]=deploy
		P_CTX[0]=10 P_AGENT[0]=1 P_CTX[2]=30 P_AGENT[2]=1 P_CTX[6]=90
	)
	snapedit "$T/snap/shell" "$T/snap/states" "${st[@]}"
	snapedit "$T/snap/states" "$T/snap/states-plan" SEL=4 SEL_ID=
	st=(
		P_STATE[0]=limit "P_LIM[0]=$((RNOW + 2 * 86400 + 240))" P_STATE[2]=waiting "W_SINCE[2]=$((RNOW - 1500))" W_FROM[2]=u
		P_STATE[3]=waiting "W_SINCE[3]=$((RNOW - 3000))" W_FROM[3]=u P_STATE[4]=ready P_STATE[5]=waiting
		"W_SINCE[5]=$((RNOW - 60))" W_FROM[5]=u P_SRV[5]=1 P_STATE[6]=working P_STATE[7]=self P_STATE[1]=limit
		"FOLD[folded.example]="
	)
	snapedit "$T/snap/shell" "$T/snap/states2" "${st[@]}"
	snapedit "$T/snap/states2" "$T/snap/states2-server" SEL=5 SEL_ID=
	snapedit "$T/snap/states2" "$T/snap/states2-agents" SEL=6 SEL_ID= P_STATE[6]=agents
	# More panes than PANES has room for: it scrolls, the selection kept in view, the arrows lit
	# for rows that need you above and below it.
	snapclone "$T/snap/shell" "$T/snap/many0" 0 25
	snapedit "$T/snap/many0" "$T/snap/many" P_STATE[9]=asking P_STATE[30]=asking SEL=20 SEL_ID=%920
	snapedit "$T/snap/many0" "$T/snap/many-top" P_STATE[30]=asking
	rm -f "$T/snap/many0"
	# The cpu graph with history: a few samples (a panel just opened) and more than it keeps.
	local -a hist=()
	for n in $(seq 0 11); do hist+=("CPU_HIST[$n]=$((n * 9 % 40))"); done
	snapedit "$T/snap/shell-hidden" "$T/snap/spark-short" "${hist[@]}"
	hist=()
	for n in $(seq 0 229); do hist+=("CPU_HIST[$n]=$((n * 37 % 101))"); done
	snapedit "$T/snap/shell-hidden" "$T/snap/spark-long" "${hist[@]}"
	for s in 0 1 2 3 4; do
		for n in 0 1 7; do snapedit "$T/snap/shell-hidden" "$T/snap/scene$s-tick$n" SCENE=$s TICK=$n; done
	done
	# One REVIVE_PANEL_SIZES run is the same as a run for each size alone: nothing a frame
	# changes is carried into the next.
	for n in shell question answering linked help folded notice-long help-notice; do
		env "${RENV[@]}" REVIVE_PANEL_SIZES="80x24 200x60 100x40 130x24" REVIVE_PANEL_SNAP="load:$T/snap/$n" \
			bash "$ROOT/scripts/panel.sh" --once </dev/null | grep -av '^--- ' >"$T/snap/$n.sizes"
		ok=1
		for s in 80x24 200x60 100x40 130x24; do
			env "${RENV[@]}" COLUMNS=${s%x*} LINES=${s#*x} REVIVE_PANEL_SNAP="load:$T/snap/$n" bash "$ROOT/scripts/panel.sh" --once </dev/null
		done >"$T/snap/$n.alone"
		check "$n: four sizes in one run draw as four runs of one size" "cmp -s $T/snap/$n.sizes $T/snap/$n.alone"
	done
	# And the scenarios show what they're for (a stand-in for reading the frames). grep -c, not
	# -q, at the end of a pipe: pipefail fails a pipe that grep closed early.
	# sframe NAME [COLS LINES]: the scenario's frame, plain (130x45 unless given).
	sframe() { env "${RENV[@]}" COLUMNS=${2:-130} LINES=${3:-45} REVIVE_PANEL_SNAP="load:$T/snap/$1" bash "$ROOT/scripts/panel.sh" --once </dev/null | plain; }
	check "outside: two ssh sessions to one host and one to another, sorted (by host, then where)" "sframe outside | grep -ao '[a-z]*\.example · ssh in [a-z ]*' | tr '\n' '|' | grep -cx 'alpha.example · ssh in a terminal |zeta.example · ssh in a terminal |' >/dev/null"
	check "question: the question shows" "sframe question | grep -ac 'QUESTION · asker' >/dev/null"
	check "answering: the ANSWERING bar" "sframe answering | grep -ac 'ANSWERING asker' >/dev/null"
	check "linked: its peek, from the fake ssh" "sframe linked | grep -ac 'load average: 0.10' >/dev/null"
	check "linked: Zed.example can't be reached" "sframe linked | grep -ac '● Zed.example ssh: connect to host' >/dev/null"
	check "folded: far.example folded to its heading" "sframe folded | grep -ac '▶.*FAR.EXAMPLE · linked · 2 panes' >/dev/null && ! sframe folded | grep -ac '0\\.1\\] *far-top' >/dev/null"
	check "help: the ? page" "sframe help | grep -ac 'HELP · HOW TO USE REVIVE' >/dev/null"
	check "notice: its box, over the panel" "sframe notice | tail -n 1 | grep -ac '║ saved .*Esc closes' >/dev/null && sframe notice | grep -ac 'C O N T R O L' >/dev/null"
	check "notice-long: wrapped at 80 columns to three lines or more, with the hint under them" "[[ \$(sframe notice-long 80 24 | tail -n 1 | grep -ao 'H║ [^║]*║' | wc -l) -ge 5 ]] && sframe notice-long 80 24 | tail -n 1 | grep -ac 'H║ SHA256:Xq3v9y' >/dev/null"
	check "notice-queued: the first notice shows, the second waits" "cmp -s <(sframe notice) <(sframe notice-queued)"
	check "answering-notice: no box while a question is answered" "! sframe answering-notice | grep -ac 'Esc closes' >/dev/null && sframe answering-notice | grep -ac 'ANSWERING asker' >/dev/null"
	check "help-notice: the box over the ? page" "sframe help-notice | grep -ac 'HELP · HOW TO USE REVIVE' >/dev/null && sframe help-notice | tail -n 1 | grep -ac 'Esc closes' >/dev/null"
	check "the scenes differ" "[[ \$(for s in 0 1 2 3 4; do sframe scene\$s-tick0 | md5sum; done | sort -u | wc -l) == 5 ]]"
	# Drawn from a snapshot, the panel starts no program at all once it has read it.
	if command -v strace >/dev/null; then
		env "${RENV[@]}" COLUMNS=130 LINES=45 REVIVE_PANEL_SNAP="load:$T/snap/linked" \
			strace -f -qq -e trace=execve,openat -o "$T/strace" bash "$ROOT/scripts/panel.sh" --once >/dev/null </dev/null
		check "drawn from a snapshot, nothing is run once it's read" "! awk '/snap\\/linked\"/{on=1; next} on' $T/strace | grep -c execve >/dev/null"
		env "${RENV[@]}" COLUMNS=80 LINES=24 REVIVE_PANEL_SNAP="load:$T/snap/notice-long" \
			strace -f -qq -e trace=execve,openat -o "$T/strace" bash "$ROOT/scripts/panel.sh" --once >/dev/null </dev/null
		check "nor with a notice's box drawn over it" "! awk '/snap\\/notice-long\"/{on=1; next} on' $T/strace | grep -c execve >/dev/null"
	else
		echo "  (strace not installed: the check that a snapshot's frame runs nothing is skipped)"
	fi
	tmux -S "$FS" kill-server 2>/dev/null
}

# ------------------------------------------------------------------ components
# Until the Rust panel draws a whole frame (plan Phase 1.3, steps 4 to 9), what it has ported is
# compared one call at a time: panel-rs/tests/component.sh cuts bash's own functions out of
# scripts/panel.sh and runs the calls of panel-rs/tests/calls.py, and `tmux-revive-panel
# --component` runs the same, byte for byte. The art is drawn at the sizes bash's frames draw it
# at (a scene snapshot at every size of the grid), beside the banner, and at a few small sizes.
# GOLDEN_RS: the binary (default: built here with cargo). bash's results are cached as A's
# frames are. This stage goes once render compares whole frames.
components() {
	echo "components (until a frame is drawn): panel.sh's functions against tmux-revive-panel --component"
	[[ -d $T/snap ]] || { echo "  no snapshots: run with snaps first (or no argument)" >&2; ((fail++)); return; }
	local rs=${GOLDEN_RS:-$ROOT/panel-rs/target/release/tmux-revive-panel} cs=$ROOT/panel-rs/tests/component.sh
	local py=$ROOT/panel-rs/tests/calls.py d=$T/comp sizes g key f loc tz n ok
	if [[ -z ${GOLDEN_RS:-} ]]; then
		command -v cargo >/dev/null || { echo "  no cargo to build panel-rs with (or set GOLDEN_RS)" >&2; ((fail++)); return; }
		cargo build --release --locked --quiet --manifest-path "$ROOT/panel-rs/Cargo.toml" || { ((fail++)); return; }
	fi
	mkdir -p "$CACHE" "$d"
	# The art in each frame of the grid: IW wide (W is 80 at least), as many rows as are under ART ·.
	sizes=$(env "${RENV[@]}" REVIVE_PANEL_SIZES="$GRID" REVIVE_PANEL_SNAP="load:$T/snap/scene0-tick0" bash "$ROOT/scripts/panel.sh" --once </dev/null | plain |
		awk '/^--- /{split($2, s, "x"); w = (s[1] < 80 ? 80 : s[1]) - 4; on = 0; next} /ART ·/{on = 1; n = 0; next} on && /^║/{n++; next} on{print w "x" n; on = 0}' | sort -u | tr '\n' ' ')
	echo "  the frames draw the art at: ${sizes:-nowhere}"
	# bash's results for a call list, from the cache when the functions and calls are the same.
	bashrun() { # bashrun NAME: $d/NAME.in through component.sh -> $d/NAME.a
		key=$(cat "$cs" "$ROOT/scripts/panel.sh" "$d/$1.in" | sha256sum | cut -c1-64)
		if [[ ${GOLDEN_NOCACHE:-} != 1 && -s $CACHE/comp-$key ]]; then cp "$CACHE/comp-$key" "$d/$1.a"
		else
			LC_ALL=C.UTF-8 TZ=UTC bash "$cs" <"$d/$1.in" >"$d/$1.a"
			[[ ${GOLDEN_NOCACHE:-} == 1 ]] || cp "$d/$1.a" "$CACHE/comp-$key"
		fi
	}
	for g in prims banner art; do
		python3 -I "$py" "$g" "$sizes" >"$d/$g.in"
		bashrun "$g"
		LC_ALL=C.UTF-8 TZ=UTC "$rs" --component <"$d/$g.in" >"$d/$g.b"
		n=$(grep -ac '' "$d/$g.a")
		check "$g: $n calls, bash's and Rust's results the same bytes" "((n > 0)) && cmp -s $d/$g.a $d/$g.b"
		cmp -s "$d/$g.a" "$d/$g.b" || echo "    $(diff <(grep -an '' "$d/$g.a") <(grep -an '' "$d/$g.b") | grep -ac '^<') calls differ; the first at line $(cmp "$d/$g.a" "$d/$g.b" | awk '{print $NF}')"
	done
	# Fresh frames are compared, never bash's memo of them: the memo must draw the same. Each scene
	# and size at TICK 1 then 7, so the scenes that only blink serve 7 from 1's memo.
	python3 -I "$py" memo "$sizes" >"$d/memo.in"
	python3 -I "$py" fresh "$sizes" >"$d/fresh.in"
	: >"$d/hits"
	COMPONENT_MEMO_LOG=$d/hits LC_ALL=C.UTF-8 TZ=UTC bash "$cs" <"$d/memo.in" >"$d/memo.a"
	bashrun fresh
	n=$(grep -c hit "$d/hits")
	check "art: bash's frames from its memo ($n served from it) are the ones it draws afresh" "((n > 0)) && cmp -s $d/memo.a $d/fresh.a"
	# The clock and the */ globs' order, under each locale and zone.
	mkdir -p "$d/globs"/{B,a,_c,Zed.example,far.example,.hidden,é,"x y"} "$d/globs/"$'caf\xe9'
	python3 -I "$py" locale "$d/globs" >"$d/locale.in"
	ok=1
	for loc in C.UTF-8 en_US.UTF-8 C; do
		for tz in UTC America/New_York Asia/Kolkata; do
			LC_ALL=$loc TZ=$tz bash "$cs" <"$d/locale.in" >"$d/locale.a"
			LC_ALL=$loc TZ=$tz "$rs" --component <"$d/locale.in" >"$d/locale.b"
			cmp -s "$d/locale.a" "$d/locale.b" || { ok=0; echo "    differs under LC_ALL=$loc TZ=$tz"; }
		done
	done
	check "strftime and the */ glob's order, under three locales and three zones" "((ok))"
	# Every scenario's snapshot reads and draws (render compares what it draws).
	ok=1
	for f in "$T"/snap/*; do
		[[ ${f##*/} == *.* ]] && continue
		env "${RENV[@]}" "$rs" --once --snapshot "$f" </dev/null >/dev/null 2>&1 || { ok=0; echo "    ${f##*/} doesn't draw"; }
	done
	check "every scenario's snapshot reads and draws" "((ok))"
}

# ------------------------------------------------------------------ render
render() {
	echo "render (tier 1): A ${GOLDEN_A}, B ${GOLDEN_B}"
	[[ -d $T/snap ]] || { echo "  no snapshots: run with snaps first (or no argument)" >&2; ((fail++)); return; }
	build_b || { ((fail++)); return; }
	local f n key base grid frames=0 differ=0 hit=0 scen=0
	base=$(cat "$ROOT/scripts/panel.sh" "$ROOT/scripts/help.sh" "$ROOT/scripts/help.txt" "$ROOT/scripts/common.sh" \
		"$ROOT/VERSION" "$ROOT/test/panel-golden.sh" | sha256sum)
	mkdir -p "$CACHE" "$T/out"
	for f in "$T"/snap/*; do
		n=${f##*/}
		[[ $n == *.* ]] && continue
		# The ? page is also drawn 160 wide: two boxes side by side, the pictures beside the words.
		grid=$GRID
		[[ $n == help* ]] && grid+=" 160x24 160x40 160x60"
		key=$({ echo "$base $GOLDEN_A $grid $RNOW"; cat "$f"; } | sha256sum | cut -c1-64)
		if [[ ${GOLDEN_NOCACHE:-} != 1 && -s $CACHE/$key ]]; then
			cp "$CACHE/$key" "$T/out/$n.a"; ((hit++))
		else
			# shellcheck disable=SC2086 # GOLDEN_A is a command line
			env "${RENV[@]}" REVIVE_PANEL_SIZES="$grid" REVIVE_PANEL_SNAP="load:$f" $GOLDEN_A --once >"$T/out/$n.a" </dev/null
			[[ ${GOLDEN_NOCACHE:-} == 1 ]] || cp "$T/out/$n.a" "$CACHE/$key"
		fi
		# shellcheck disable=SC2086
		env "${RENV[@]}" REVIVE_PANEL_SIZES="$grid" REVIVE_PANEL_SNAP="load:$f" $GOLDEN_B --once >"$T/out/$n.b" </dev/null
		frames=$((frames + $(grep -ac '^--- ' "$T/out/$n.a"))) scen=$((scen + 1))
		if ! cmp -s "$T/out/$n.a" "$T/out/$n.b"; then
			((differ++))
			echo "    $n differs at: $(diff <(grep -an '' "$T/out/$n.a") <(grep -an '' "$T/out/$n.b") | head -1)"
		fi
	done
	echo "  $frames frames, $scen scenarios, $hit from the cache, $differ scenarios differ"
	check "every scenario, every size: A and B draw the same bytes" "((differ == 0 && frames > 0))"
}

# ------------------------------------------------------------------ twins
cat >"$T/mask.py" <<'PY'
import re, sys
# mask.py < CAPTURE (capture-pane -e): what may differ between two panels measuring their own
# machine taken out: each row's CPU meter, percent and memory, and the cpu graph's row. And the
# banner's CRT cursor, which blinks with TICK: the ? page moves TICK on every two seconds, by
# each panel's own clock, so after it the two can be a tick apart.
esc = r"(?:\x1b\[[0-9;:]*m)*"
cell = "[█▓▒░·]" + esc
meter = re.compile(esc.join([cell] * 5) + esc + r" +[0-9]+%" + esc + r" +[0-9.]+[KMG]")
for line in sys.stdin.read().split("\n"):
    plain = re.sub(r"\x1b\[[0-9;:]*m", "", line)
    if re.search(r"║ cpu ", plain):
        print("<the cpu graph>"); continue
    if "C O N T R O L" in plain:
        line = re.sub(r"(\$" + esc + " " + esc + r")[█ ]", r"\1<cursor>", line, count=1)
    print(meter.sub("<cpu mem>", line))
PY
twin_up() { # twin_up DIR SOCKET PANEL: the fixture, and PANEL live in a window of its own
	local d=$1 s=$2
	fixtures "$d" "$s"
	env_for "$d" "$s"
	# shellcheck disable=SC2145
	tmux -S "$s" new-window -d -t work -n panel "env ${ENV[*]} REVIVE_PANEL_REFRESH=60 REVIVE_PANEL_NOW=$RNOW AGENT_SAY_SSH=false $3"
}
shot() { # shot SOCKET: its panel's screen, coloured and masked, then the cursor
	tmux -S "$1" capture-pane -e -p -t work:panel | python3 "$T/mask.py"
	tmux -S "$1" display -p -t work:panel 'cursor #{cursor_x},#{cursor_y},#{cursor_flag}'
}
settle() { # settle SOCKET TEXT: until its panel shows TEXT and holds still for half a second
	local a b i
	for i in $(seq 1 60); do
		a=$(shot "$1")
		if [[ $a == *"$2"* ]]; then sleep 0.5; b=$(shot "$1"); [[ $a == "$b" ]] && return 0; fi
		sleep 0.3
	done
	return 1
}
twins() {
	echo "twins (tier 3): A ${GOLDEN_A}, B ${GOLDEN_TWINS_B}"
	local A=$T/twa.sock B=$T/twb.sock step keys text
	twin_up "$T/twa" "$A" "$GOLDEN_A"
	twin_up "$T/twb" "$B" "$GOLDEN_TWINS_B"
	# Each step: the keys sent to both (tmux send-keys names), and what the screen then shows.
	local -a steps=(
		"|C O N T R O L"
		"Down|QUESTION · asker"
		"Down|odd-one"
		"J|▸ PEEK"
		"J|▸ MESSAGES"
		"Up|▸ MESSAGES"
		"K K|▸ PANES"
		"f|be folded"
		"x|be folded"
		"Escape|▸ PANES"
		"?|HELP · HOW TO USE REVIVE"
		"j j|HELP · HOW TO USE REVIVE"
		"Escape|▸ PANES"
		"Up m|MESSAGE TO asker"
		"h i|MESSAGE TO asker"
		"Escape|▸ PANES"
	)
	for step in "${steps[@]}"; do
		keys=${step%%|*} text=${step#*|}
		# shellcheck disable=SC2086 # one tmux key name each
		[[ -n $keys ]] && for k in $keys; do tmux -S "$A" send-keys -t work:panel "$k"; tmux -S "$B" send-keys -t work:panel "$k"; sleep 0.1; done
		settle "$A" "$text" && settle "$B" "$text"
		# The ? page moves on its own every second (its art, the banner's cursor), each panel on
		# its own clock: shots of the two a moment apart, until a pair agrees.
		for _ in 1 2 3 4 5 6 7 8; do
			shot "$A" >"$T/shot.a"
			shot "$B" >"$T/shot.b"
			cmp -s "$T/shot.a" "$T/shot.b" && break
			sleep 0.2
		done
		check "after '${keys:-the start}': the same screen and cursor ($text)" "grep -aqF -- '$text' $T/shot.a && cmp -s $T/shot.a $T/shot.b"
		cmp -s "$T/shot.a" "$T/shot.b" || diff "$T/shot.a" "$T/shot.b" | head -6 | sed 's/^/      /'
	done
}

case ${1:-all} in
snaps) snaps ;;
render) snaps >/dev/null; render ;;
components) snaps >/dev/null; components ;;
twins) twins ;;
all) snaps; components; render; twins ;;
*) echo "usage: panel-golden.sh [snaps|components|render|twins]" >&2; exit 2 ;;
esac
printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
