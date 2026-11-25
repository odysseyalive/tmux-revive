#!/usr/bin/env bash
# The Rust panel is checked against the bash one, frame for frame (plan/rust-panel-2026-11-23.md).
# Everything runs on private tmux servers and in a folder of its own (never yours):
#
#   bash test/panel-golden.sh          all of it: snaps, render, twins
#   bash test/panel-golden.sh snaps    snapshots saved by --once from a fixture server, each loaded
#                                      back and drawn: the same frame as the save run drew, at every
#                                      size alone as in one REVIVE_PANEL_SIZES run (tier 1's ground)
#   bash test/panel-golden.sh render   every scenario at every size, panel A's frames against B's,
#                                      byte for byte (tier 1)
#   bash test/panel-golden.sh live-once  A and B each gathering for itself from one fixture
#                                      (no snapshot to load): their saved snapshots record by record
#                                      and their plain frames, CPU and memory masked (tier 2)
#   bash test/panel-golden.sh twins    A and B live, each on a server of its own with the same
#                                      fixtures, the same keys sent to both, their screens and
#                                      cursors compared with CPU, memory and the cpu graph masked
#                                      (tier 3)
#   bash test/panel-golden.sh live     the Rust panel live (B) against bash (A), twins' way, every
#                                      key its own (no hand-over), answering a question included
#   bash test/panel-golden.sh live-ubg the end of live alone: U, B and G, the Rust panel's own,
#                                      against bash's
#   bash test/panel-golden.sh live-answer  live's answering alone: a twin of bash's, above the
#                                      question masked, and PANES going on while it answers
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
sockets=() POLLERS=()
# poller STATE HOST: a stand-in for HOST's link poller (a process named as agent-say's), its pid
# in the link's folder as agent-say keeps it: that link works. pollers_stop ends them all.
poller() {
	bash -c 'exec -a "agent-say _poll $0" sleep 100000' "$2" </dev/null >/dev/null 2>&1 &
	POLLERS+=($!)
	echo $! >"$1/links/$2/pid"
}
pollers_stop() {
	((${#POLLERS[@]})) && kill "${POLLERS[@]}" 2>/dev/null
	POLLERS=()
}
cleanup() {
	local s
	for s in "${sockets[@]}"; do tmux -S "$s" kill-server 2>/dev/null; done
	pollers_stop
	[[ -n ${KEEP:-} ]] || rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP
plain() { sed 's/\x1b\[[0-9;]*m//g'; }
# A notice longer than the key bar (since 1.2.57 a notice is the key bar's flash, never a box).
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
	# HOME and CODEX_HOME the fixture's: the panel reads a codex pane's sign-in from its own
	# environment, and the real one's ~/.codex/auth.json has no place in a test.
	tmux -S "$s" new-window -d -t work -n asker -c "$d/work" "env HOME=$d/home CODEX_HOME=$d/home/.codex $d/bin/codex $d/ask.sh"
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
if [[ $cmd == *' agent-say name '* ]]; then
	n=${cmd##* name \'} n=${n%%\'*}
	echo "pane %1 is now '$n'"
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
	# far.example's link works; folded.example's poller isn't running, Zed.example's failed.
	poller "$T/fx/state" far.example
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
	# A notice, short and long: on the key bar since 1.2.57, with no box over the panel.
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
	# A link working: its heading and its LINKS row say linked. One that isn't, failed (Zed) or
	# its poller not running (folded), whatever the reason: not connected, and [B]ridge, in both.
	check "linked: far.example's link works: linked, on its heading and in LINKS" "sframe linked | grep -ac 'FAR.EXAMPLE · linked · 2 panes' >/dev/null && sframe linked | grep -ac '● far.example · linked · 2 names' >/dev/null"
	check "linked: Zed.example's failed: not connected · [B]ridge on its heading, its error not shown" "sframe linked | grep -ac 'ZED.EXAMPLE · not connected · \\[B\\]ridge · 2 panes *║' >/dev/null && ! sframe linked | grep -ac 'Connection refused' >/dev/null"
	check "linked: and in LINKS, for it and for folded.example, whose poller isn't running" "sframe linked | grep -ac '● Zed.example · not connected · \\[B\\]ridge' >/dev/null && sframe linked | grep -ac '● folded.example · not connected · \\[B\\]ridge' >/dev/null && ! sframe linked | grep -ac 'not running' >/dev/null"
	check "linked: B in the panel's key style, then ridge, on the heading" "env \"\${RENV[@]}\" COLUMNS=130 LINES=45 REVIVE_PANEL_SNAP=load:$T/snap/linked bash $ROOT/scripts/panel.sh --once </dev/null | grep -a 'ZED.EXAMPLE' | grep -acF $'\\e[90m· not connected ·\\e[0m \\e[94m[\\e[1m\\e[93mB\\e[0m\\e[94m]\\e[0m\\e[97mridge\\e[0m' >/dev/null"
	check "linked: at 80 columns too, with its pane count" "sframe linked 80 40 | grep -ac 'ZED.EXAMPLE · not connected · \\[B\\]ridge · 2 panes' >/dev/null"
	check "folded: far.example folded to its heading" "sframe folded | grep -ac '▶.*FAR.EXAMPLE · linked · 2 panes' >/dev/null && ! sframe folded | grep -ac '0\\.1\\] *far-top' >/dev/null"
	check "help: the ? page" "sframe help | grep -ac 'HELP · HOW TO USE REVIVE' >/dev/null"
	check "notice: on the key bar, no box over the panel" "sframe notice | grep -ac ' saved .*\\[O\\]pen' >/dev/null && ! sframe notice | grep -ac 'Esc closes' >/dev/null && sframe notice | grep -ac 'C O N T R O L' >/dev/null"
	check "notice-long: on the key bar at 80 columns too, no box" "sframe notice-long 80 24 | grep -ac '║ *linked to far.example' >/dev/null && ! sframe notice-long 80 24 | grep -ac 'Esc closes' >/dev/null"
	check "answering-notice: no box while a question is answered" "! sframe answering-notice | grep -ac 'Esc closes' >/dev/null && sframe answering-notice | grep -ac 'ANSWERING asker' >/dev/null"
	check "help-notice: the box over the ? page" "sframe help-notice | grep -ac 'HELP · HOW TO USE REVIVE' >/dev/null && sframe help-notice | tail -n 1 | grep -ac 'Esc closes' >/dev/null"
	# The cpu graph draws the history it has: 12 samples and the frame's own after a grey floor;
	# 230 fill it, no floor. (cframe: the cpu row as drawn, its colours kept.)
	cframe() { env "${RENV[@]}" COLUMNS=130 LINES=45 REVIVE_PANEL_SNAP="load:$T/snap/$1" bash "$ROOT/scripts/panel.sh" --once </dev/null | grep -a ' cpu '; }
	check "spark-short: a grey floor, then its 13 samples in colour" "[[ \$(cframe spark-short | grep -ao $'\\e\\[\\(34\\|94\\|96\\|93\\)m[▁▂▃▄▅▆▇█]' | wc -l) == 13 ]] && cframe spark-short | grep -aq $'\\e\\[90m▁'"
	check "spark-long: no floor, every cell a sample" "! cframe spark-long | grep -aq $'\\e\\[90m▁'"
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
		# Under 23 lines the peek isn't drawn, so a focus on it goes back to PANES: draw starts
		# again (FOCUS=0; draw), keeping what its first pass changed.
		[[ $n == focus-* ]] && grid+=" 80x20 130x14"
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

# ------------------------------------------------------------------ live --once
# mail_addon DIR (tier 2 only): more for MESSAGES and LINKS · SAVES: approvals, a queue, more access requests
# than are shown, a peer checking in, a read-only link limited to two names, and a link whose
# poller runs (a process named as agent-say's)
mail_addon() {
	local d=$1 st=$1/state now i
	now=$(date +%s)
	printf 'allow a b c d %s\nallow a b c d 5\ndeny a b c d %s\nallow x\n' "$now" "$now" >"$st/grants"
	mkdir -p "$st/queue" && : >"$st/queue/msg.1" && : >"$st/queue/msg.2" && : >"$st/queue/msg.3.err"
	for i in 2 3 4; do mkdir -p "$st/intros/i$i"; echo "p$i@far.example" >"$st/intros/i$i/from"; echo asker@golden >"$st/intros/i$i/to"; echo $((1795000000 + i * 60)) >"$st/intros/i$i/created"; done
	printf 'no newline' >"$st/intros/i4/from"
	mkdir -p "$st/peers/peer.example" && : >"$st/peers/peer.example/alive"
	: >"$st/links/folded.example/read-only"; printf 'fold-sh\nother\n' >"$st/links/folded.example/allow"
	poller "$st" far.example
}
# agents_addon DIR SOCKET: stand-in Claude Codes and a Codex in a window each, with the files the
# panel reads for them under DIR/home (their HOME too): session records, transcripts (context
# used, the last prompt, a usage limit), an account and plan, a Codex rollout. Tier 2 only: the
# tier-1 scenarios address the fixture's rows by number.
agents_addon() {
	local d=$1 s=$2 h=$1/home now
	now=$(date +%s)
	mkdir -p "$h/.claude/sessions" "$h/.claude/projects/-w" "$h/.codex/sessions/2026/11/24" "$d/work/cx"
	printf '{"oauthAccount":{"emailAddress":"ada.lovelace@example.com","planDisplayName":"Max","organizationRateLimitTier":"t1","userRateLimitTier":null,"seatTier":"s","hasExtraUsageEnabled":false}}\n' >"$h/.claude.json"
	# claude NAME STATUS SID: a process named claude that writes its own record, then sleeps
	cat >"$d/claude.sh" <<'CL'
h=$1 st=$2 sid=$3 now=$(date +%s)
printf '{"pid":%s,"sessionId":"%s","status":"%s","statusUpdatedAt":%s000,"startedAt":%s000}\n' $$ "$sid" "$st" $((now - 30)) $((now - 3000)) >"$h/.claude/sessions/$$.json"
exec -a claude sleep 100000
CL
	local t=$h/.claude/projects/-w
	{
		printf '{"type":"user","timestamp":"2026-11-24T10:00:00.000Z","message":{"content":"[agent-msg from=bob@x] please look"}}\n'
		printf '{"type":"assistant","timestamp":"2026-11-24T10:00:05.000Z","message":{"model":"claude-opus-5","usage":{"input_tokens":1000,"cache_read_input_tokens":250000,"cache_creation_input_tokens":0}}}\n'
	} >"$t/aaaa-1.jsonl"
	{
		printf '{"type":"user","timestamp":"2026-11-24T09:00:00.000Z","message":{"content":[{"type":"text","text":"fix the build please"}]}}\n'
		printf '{"type":"assistant","timestamp":"2026-11-24T09:00:05.000Z","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":50000,"cache_read_input_tokens":0,"cache_creation_input_tokens":100}}}\n'
		printf '{"type":"assistant","timestamp":"2026-11-24T09:01:00.000Z","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"You'"'"'ve hit your session limit · resets 10pm (Europe/Paris)"}]}}\n'
	} >"$t/bbbb-2.jsonl"
	tmux -S "$s" new-window -d -t work -n cl-wait -c "$d/work" "env HOME=$h bash $d/claude.sh $h idle aaaa-1"
	tmux -S "$s" new-window -d -t work -n cl-limit -c "$d/work" "env HOME=$h bash $d/claude.sh $h idle bbbb-2"
	tmux -S "$s" new-window -d -t work -n cl-busy -c "$d/work" "env HOME=$h bash $d/claude.sh $h busy cccc-3"
	tmux -S "$s" set-option -p -t work:cl-wait @agent cl-wait
	# A Codex at its prompt: its rollout names its folder, a start after its own and its tokens.
	cat >"$d/codex.sh" <<'CX'
h=$1 cwd=$2
r=$h/.codex/sessions/2026/11/24/rollout-2026-11-24T10-00-00-0000aaaa-0000-0000-0000-000000000001.jsonl
ts=$(date -u -d @$(( $(date +%s) + 1 )) +%Y-%m-%dT%H:%M:%S.000Z)
printf '{"timestamp":"%s","type":"session_meta","payload":{"cwd":"%s","timestamp":"%s"}}\n' "$ts" "$cwd" "$ts" >"$r"
printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":64000},"model_context_window":256000}}}\n' "$ts" >>"$r"
exec -a codex sleep 100000
CX
	# The Codex works in a repository with a change not yet committed (GIT: main*), and the
	# busy Claude Code in one that sets its own clean filter (no dirty check there: GIT: main).
	local g
	for g in "$d/work/cx" "$d/work/flt"; do
		mkdir -p "$g"
		git -C "$g" init -q -b main && echo one >"$g/f" && git -C "$g" add f &&
			git -C "$g" -c user.name=t -c user.email=t@example.com commit -qm one && echo two >"$g/f"
	done
	git -C "$d/work/flt" config filter.x.clean cat
	# And the Claude Code at its limit in one with a submodule whose own config sets a clean filter
	# (touching a marker) its .gitattributes uses, with a change in it: git_info must never run
	# status inside it, so the filter never runs (checked after the scenarios).
	(
		export GIT_CONFIG_GLOBAL=/dev/null
		gg() { git -c user.name=t -c user.email=t@example.com -c protocol.file.allow=always "$@"; }
		mkdir -p "$d/work/smsub" "$d/work/sm"
		gg -C "$d/work/smsub" init -q -b main && echo "* filter=x" >"$d/work/smsub/.gitattributes" && echo a >"$d/work/smsub/f" &&
			gg -C "$d/work/smsub" add . && gg -C "$d/work/smsub" commit -qm s
		gg -C "$d/work/sm" init -q -b main && gg -C "$d/work/sm" submodule add -q ../smsub sub && gg -C "$d/work/sm" commit -qm p
		git -C "$d/work/sm/sub" config filter.x.clean "touch $d/submodule-filter-ran; cat"
		echo b >>"$d/work/sm/sub/f"
	)
	tmux -S "$s" respawn-pane -k -t work:cl-limit -c "$d/work/sm" "env HOME=$h bash $d/claude.sh $h idle bbbb-2"
	tmux -S "$s" respawn-pane -k -t work:cl-busy -c "$d/work/flt" "env HOME=$h bash $d/claude.sh $h busy cccc-3"
	tmux -S "$s" new-window -d -t work -n cx-wait -c "$d/work/cx" "env HOME=$h CODEX_HOME=$h/.codex bash $d/codex.sh $h $d/work/cx"
}
# snapdiff.py A B: two snapshots' records, NAME[INDEX], that differ, with what CPU and memory
# measured over wall time (and SECONDS, SCENE's pick) taken out. Exit 1 when any differ.
cat >"$T/snapdiff.py" <<'PY'
import sys
def recs(f):
    d = open(f, "rb").read().split(b"\0")
    r = {}
    for i in range(0, len(d) - 2, 3):
        n, k, v = d[i], d[i + 1], d[i + 2]
        if n in (b"P_CPU", b"P_MEM", b"CPU_HIST", b"SECONDS"):
            v = b"<masked>"
        r[(n, k)] = v
    return r
a, b = recs(sys.argv[1]), recs(sys.argv[2])
bad = sorted(k for k in set(a) | set(b) if a.get(k) != b.get(k))
for n, k in bad:
    print("      %s[%s]: A %r, B %r" % (n.decode(), k.decode(errors="replace"), a.get((n, k)), b.get((n, k))))
sys.exit(1 if bad else 0)
PY
# Tier 2: each panel's --once gathers for itself from one fixture (no snapshot to load), and the
# two are compared: their snapshots (REVIVE_PANEL_SNAP=save:) record by record, and the frames
# of a plain --once, with CPU, memory and the cpu graph masked (mask.py). The notice scenarios
# aren't here: REVIVE_PANEL_NOTICE isn't gathered (Phase 2 leaves notices to the notice rework).
# GOLDEN_ORDER=ba runs B before A in each scenario (they share the fixture's cache folder).
liveonce() {
	echo "live --once (tier 2): A ${GOLDEN_A}, B ${GOLDEN_B}"
	build_b || { ((fail++)); return; }
	mkdir -p "$T/lo"
	local LS=$T/lo.sock sc name sel id x side sdiff=0 fdiff=0 n=0
	fixtures "$T/lx" "$LS" links
	agents_addon "$T/lx" "$LS"
	mail_addon "$T/lx"
	env_for "$T/lx" "$LS"
	sleep 2 # the panes draw their screens, the agents write their records
	# NAME SEL [ENV...], as save's
	local -a scen=(
		"shell 0" "shell-hidden 0 REVIVE_PANEL_PEEK=0" "outside 0 REVIVE_PANEL_PEEK=0 REVIVE_PANEL_OUTSIDE_SSH=1 REVIVE_PANEL_PROCS=ps PATH=$T/lx/fakeps:$PATH"
		"question asker" "odd odd" "linked far-top@far.example" "linked-ask far-claude@far.example" "help 0 REVIVE_PANEL_HELP=1"
		"tick7 0 REVIVE_PANEL_PEEK=0 REVIVE_PANEL_TICK=7 REVIVE_PANEL_ART=space" "cl-limit cl-limit" "cl-wait cl-wait" "cx-wait cx-wait"
	)
	for sc in "${scen[@]}"; do
		read -ra x <<<"$sc"
		name=${x[0]} sel=${x[1]} id=""
		case $sel in
		*@*) id=$sel ;;
		?*) id=$(tmux -S "$LS" display -p -t "work:$sel" '#{pane_id}') ;;
		esac
		for side in $([[ ${GOLDEN_ORDER:-} == ba ]] && echo b a || echo a b); do
			local cmd=$GOLDEN_A
			[[ $side == b ]] && cmd=$GOLDEN_B
			# shellcheck disable=SC2086 # the panel is a command line
			env "${ENV[@]}" REVIVE_PANEL_NOW="$SNOW" REVIVE_PANEL_SEL="$id" COLUMNS=130 LINES=45 "${x[@]:2}" \
				REVIVE_PANEL_SNAP="save:$T/lo/$name.$side.snap" timeout 120 $cmd --once </dev/null | python3 "$T/mask.py" >"$T/lo/$name.$side.saved"
			# shellcheck disable=SC2086
			env "${ENV[@]}" REVIVE_PANEL_NOW="$SNOW" REVIVE_PANEL_SEL="$id" COLUMNS=130 LINES=45 "${x[@]:2}" \
				timeout 120 $cmd --once </dev/null | python3 "$T/mask.py" >"$T/lo/$name.$side"
		done
		n=$((n + 1))
		if ! python3 "$T/snapdiff.py" "$T/lo/$name.a.snap" "$T/lo/$name.b.snap" >"$T/lo/$name.sdiff"; then
			sdiff=$((sdiff + 1))
			echo "    $name: snapshots differ in $(grep -c . "$T/lo/$name.sdiff") records:"
			head -n "${GOLDEN_SHOW:-12}" "$T/lo/$name.sdiff"
		fi
		if ! cmp -s "$T/lo/$name.a" "$T/lo/$name.b"; then
			fdiff=$((fdiff + 1))
			echo "    $name: frames differ at: $(diff <(grep -an '' "$T/lo/$name.a") <(grep -an '' "$T/lo/$name.b") | head -1)"
		fi
	done
	tmux -S "$LS" kill-server 2>/dev/null
	pollers_stop
	echo "  $n scenarios: $sdiff with snapshots that differ, $fdiff with frames that differ"
	check "git_info ran no filter of a submodule's own config (neither panel)" "[[ ! -e $T/lx/submodule-filter-ran ]]"
	check "every scenario: A and B gather the same snapshot (CPU and memory masked)" "((sdiff == 0 && n > 0))"
	check "every scenario: a plain --once of A and of B draw the same frame (CPU and memory masked)" "((fdiff == 0 && n > 0))"
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
sys.stdout.reconfigure(errors="surrogateescape")
for line in sys.stdin.buffer.read().decode("utf-8", "surrogateescape").split("\n"):
    plain = re.sub(r"\x1b\[[0-9;:]*m", "", line)
    if re.search(r"║ +cpu ", plain):
        print("<the cpu graph>"); continue
    if "C O N T R O L" in plain:
        line = re.sub(r"(\$" + esc + " " + esc + r")[█ ]", r"\1<cursor>", line, count=1)
    print(meter.sub("<cpu mem>", line))
PY
cat >"$T/box.py" <<'PY'
import re, sys
# box.py TITLE < CAPTURE (capture-pane -e): only the box titled TITLE (pick's, note's), its
# shadow too, cell by cell with each cell's colours and attributes as tmux keeps them, so what
# differs around it (the panel going on under it) doesn't count.
title = sys.argv[1]
sys.stdout.reconfigure(errors="surrogateescape")
rows = []
for line in sys.stdin.buffer.read().decode("utf-8", "surrogateescape").split("\n"):
    a, cells, i = {}, [], 0
    while i < len(line):
        m = re.match(r"\x1b\[([0-9;:]*)m", line[i:])
        if m:
            ps = [int(x) if x else 0 for x in re.split("[;:]", m.group(1))] or [0]
            j = 0
            while j < len(ps):
                p = ps[j]
                if p == 0: a = {}
                elif p in (38, 48) and j + 1 < len(ps):
                    n = 3 if ps[j + 1] == 5 else 5
                    a["fg" if p == 38 else "bg"] = tuple(ps[j:j + n]); j += n - 1
                elif 30 <= p <= 37 or 90 <= p <= 97: a["fg"] = p
                elif 40 <= p <= 47 or 100 <= p <= 107: a["bg"] = p
                elif p == 39: a.pop("fg", None)
                elif p == 49: a.pop("bg", None)
                elif p == 22: a.pop(1, None); a.pop(2, None)
                elif 23 <= p <= 29: a.pop(p - 20, None)
                else: a[p] = 1
                j += 1
            i += m.end()
            continue
        cells.append((tuple(sorted(a.items(), key=str)), line[i])); i += 1
    rows.append(cells)
plain = ["".join(c for _, c in r) for r in rows]
top = next(i for i, l in enumerate(plain) if " " + title + " " in l and "╔" in l)
left = plain[top].index("╔")
right = plain[top].index("╗", left)
bot = next(i for i in range(top + 1, len(plain)) if plain[i][left:left + 1] == "╚")
# the frame's top row, the rows with their shadow cell at the right, and the shadow row under it
print(top, left, rows[top][left:right + 1])
for i in range(top + 1, bot + 1):
    print(i, left, rows[i][left:right + 2])
print(bot + 1, left + 1, rows[bot + 1][left + 1:right + 2])
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

# ------------------------------------------------------------------ live (Phase 3)
# The Rust panel live (GOLDEN_B) against the bash one (GOLDEN_A), each on a server of its own
# with the same fixtures, the same keys sent to both: moves, the art, the peek, the focus, f on
# a pane here (nothing to fold), compared as twins compares them. N (rename) and D (detach) and
# their boxes, the Rust panel's own. Enter on the question answers it, the Rust panel's own too,
# backed out of with Esc; answering is checked further on (live_answer). No key runs the bash
# panel: the hand-over is gone, and lv_shim's log of one stays empty.
lv_cmd() { tmux -S "$1" display -p -t work:panel '#{pane_current_command}'; }
# lv_bash SOCKET: its panel has a bash panel running for it (a hand-over, which must not happen)
lv_bash() { ps -o args= --ppid "$(tmux -S "$1" display -p -t work:panel '#{pane_pid}')" 2>/dev/null | grep -q 'scripts/panel\.sh'; }
# lv_shim DIR: a bash on the Rust panel's PATH that notes in DIR/handoffs every bash panel run
# from it (none should be), then runs the real bash
lv_shim() {
	mkdir -p "$1"
	printf '#!%s\n[[ $* == *scripts/panel.sh* ]] && echo "${REVIVE_PANEL_HANDOFF:-?}" >>%q\nexec %q "$@"\n' \
		"$(command -v bash)" "$1/handoffs" "$(command -v bash)" >"$1/bash"
	chmod +x "$1/bash"
	: >"$1/handoffs"
}
# lv_step SA SB KEYS TEXT LABEL: KEYS sent to both panels, then the same screen and cursor, TEXT on it
lv_step() {
	local k i
	# shellcheck disable=SC2086 # one tmux key name each
	[[ -n $3 ]] && for k in $3; do tmux -S "$1" send-keys -t work:panel "$k"; tmux -S "$2" send-keys -t work:panel "$k"; sleep 0.15; done
	settle "$1" "$4" && settle "$2" "$4"
	for i in 1 2 3 4 5 6 7 8; do
		shot "$1" >"$T/shot.a"
		shot "$2" >"$T/shot.b"
		cmp -s "$T/shot.a" "$T/shot.b" && break
		sleep 0.2
	done
	LV_TEXT=$4 # the text by name, so a quote in it is just a quote
	check "$5after '$3': the same screen and cursor ($4)" "grep -aqF -- \"\$LV_TEXT\" $T/shot.a && cmp -s $T/shot.a $T/shot.b"
	[[ -n ${GOLDEN_DEBUG:-} ]] && plain <"$T/shot.a" | grep -E '▶|▓▒░ [A-Z]|^║ \[' | cut -c1-80
	# the text never came: the bottom of A's screen, to see what it says instead
	grep -aqF -- "$LV_TEXT" "$T/shot.a" || plain <"$T/shot.a" | tail -n 4 | head -n 2 | sed 's/^/      A: /'
	cmp -s "$T/shot.a" "$T/shot.b" || diff "$T/shot.a" "$T/shot.b" | head -${GOLDEN_DIFF:-6} | sed 's/^/      /'
}
live() {
	build_b || return 1
	echo "live (Phase 3): A ${GOLDEN_A}, B ${GOLDEN_B}"
	local A=$T/lva.sock B=$T/lvb.sock step keys text i
	twin_up "$T/lva" "$A" "$GOLDEN_A"
	lv_shim "$T/lvb-shim"
	twin_up "$T/lvb" "$B" "env PATH=$T/lvb-shim:$PATH $GOLDEN_B"
	check "B is the Rust panel" "for _ in \$(seq 1 25); do [[ \$(lv_cmd $B) == tmux-revive-pan* ]] && break; sleep 0.2; done; [[ \$(lv_cmd $B) == tmux-revive-pan* ]]"
	local -a steps=(
		"|C O N T R O L"
		"Down|QUESTION · asker"
		"Down|odd-one"
		"Up|QUESTION · asker"
		"Up Up|odd-one"
		"0|PEEK"
		"p|ART · night city"
		"a|ART · mountains"
		"A|ART · deep space"
		"P|PEEK"
		"J|▸ PEEK"
		"J|▸ MESSAGES"
		"Up Up|▸ MESSAGES"
		"K K|▸ PANES"
		"f|▸ PANES"
		"x|▸ PANES"
		"Escape|▸ PANES"
		"j|QUESTION · asker"
		"N|New name for"
		"Escape|rename cancelled"
		"Enter|ANSWERING asker"
		"Escape|left the question"
	)
	for step in "${steps[@]}"; do
		keys=${step%%|*} text=${step#*|}
		# shellcheck disable=SC2086 # one tmux key name each
		[[ -n $keys ]] && for k in $keys; do tmux -S "$A" send-keys -t work:panel "$k"; tmux -S "$B" send-keys -t work:panel "$k"; sleep 0.15; done
		settle "$A" "$text" && settle "$B" "$text"
		for i in 1 2 3 4 5 6 7 8; do
			shot "$A" >"$T/shot.a"
			shot "$B" >"$T/shot.b"
			cmp -s "$T/shot.a" "$T/shot.b" && break
			sleep 0.2
		done
		check "after '${keys:-the start}': the same screen and cursor ($text)" "grep -aqF -- '$text' $T/shot.a && cmp -s $T/shot.a $T/shot.b"
		cmp -s "$T/shot.a" "$T/shot.b" || diff "$T/shot.a" "$T/shot.b" | head -${GOLDEN_DIFF:-6} | sed 's/^/      /'
		[[ $keys == N || $keys == Enter ]] && check "$keys is the Rust panel's own (no hand-over)" "! lv_bash $B && [[ \$(lv_cmd $B) == tmux-revive-pan* ]]"
	done
	check "and B is the Rust panel again" "! lv_bash $B && [[ \$(lv_cmd $B) == tmux-revive-pan* ]]"
	check "with the same pane selected (asker)" "tmux -S $B capture-pane -p -t work:panel | grep -q '▶.*asker'"
	# S saves in Rust, and G with nothing to list (the fixture's intro is days old: G's _cull, by
	# the clock and not REVIVE_PANEL_NOW, clears it) stays in Rust, saying nothing. After the
	# hand-overs above, so no bash panel gathered fresh shows a screen the other has yet to.
	lv_step "$A" "$B" s "saved" "S: "
	lv_step "$A" "$B" g "C O N T R O L" "G with nothing waiting: "
	check "S and the empty G did not go to the bash panel" "! lv_bash $B && [[ -e $T/lvb-shim/handoffs && ! -s $T/lvb-shim/handoffs ]]"
	# One made now waits: G's box is the Rust panel's own too, as bash's.
	local tw
	for tw in lva lvb; do
		mkdir -p "$T/$tw/state/intros/i9"
		echo near@far.example >"$T/$tw/state/intros/i9/from"; echo asker@golden >"$T/$tw/state/intros/i9/to"
		date +%s >"$T/$tw/state/intros/i9/created"; echo "may I see the log?" >"$T/$tw/state/intros/i9/intro"
	done
	# Both look again (a key that does nothing), so A's key bar has G too, and the flash before is gone.
	sleep 5
	lv_step "$A" "$B" x "rant access" "an intro waiting: "
	lv_step "$A" "$B" g "LINK AGENTS TOGETHER" "an intro waiting: "
	check "G with an intro waiting stayed in Rust (no hand-over)" "! lv_bash $B && [[ \$(lv_cmd $B) == tmux-revive-pan* ]]"
	lv_step "$A" "$B" Escape "▸ PANES" "an intro waiting: "
	check "no hand-over at all: Enter (answering), N, S and G, empty or not, stayed in Rust" "[[ -e $T/lvb-shim/handoffs && ! -s $T/lvb-shim/handoffs ]]"
	# N on a pane here: the ask line on the bottom row as bash's, what's typed shown (Backspace
	# too), Enter renames it (agent-say name) and says so; then back to its own name.
	lv_step "$A" "$B" N "New name for asker:" "N here: "
	lvtyped() { tmux -S "$A" capture-pane -p -t work:panel | grep -qF "$1" && tmux -S "$B" capture-pane -p -t work:panel | grep -qF "$1"; }
	lv_step "$A" "$B" "t m p" "Enter sends" "N here: "
	check "N here: what's typed shows on both" "lvtyped 'New name for asker: tmp▏ Enter sends · Esc cancels'"
	lv_step "$A" "$B" BSpace "Enter sends" "N here: "
	check "N here: Backspace takes the last off on both" "lvtyped 'New name for asker: tm▏ Enter sends'"
	lv_step "$A" "$B" Enter "is now 'tm'" "N here: "
	check "N here: the pane is renamed on both" "tmux -S $A list-panes -a -F '#{@agent}' | grep -qx tm && tmux -S $B list-panes -a -F '#{@agent}' | grep -qx tm"
	lv_step "$A" "$B" x "C O N T R O L" "N here: "
	check "N here: the row goes by its new name on both" "tmux -S $A capture-pane -p -t work:panel | grep -q '▶.* tm ' && tmux -S $B capture-pane -p -t work:panel | grep -q '▶.* tm '"
	lv_step "$A" "$B" N "New name for tm:" "N here: "
	lv_step "$A" "$B" "a s k e r Enter" "is now 'asker'" "N here: "
	lv_step "$A" "$B" x "C O N T R O L" "N here: "
	check "N here: and by its own again" "tmux -S $B capture-pane -p -t work:panel | grep -q '▶.*asker'"
	# D: the pick box as bash's, a move in it, Esc and No cancelling, Ctrl-C closing it with the
	# panel going on, and Yes with no client to detach.
	lv_step "$A" "$B" D "DETACH TMUX?" "D: "
	lv_step "$A" "$B" Down "DETACH TMUX?" "D: "
	lv_step "$A" "$B" Up "DETACH TMUX?" "D: "
	lv_step "$A" "$B" Escape "detach cancelled" "D: "
	lv_step "$A" "$B" "D 1" "detach cancelled" "D, No: "
	lv_step "$A" "$B" D "DETACH TMUX?" "D: "
	lv_step "$A" "$B" C-c "detach cancelled" "D, Ctrl-C: "
	check "D, Ctrl-C: the box closed and neither panel ended" "[[ \$(lv_cmd $B) == tmux-revive-pan* && \$(lv_cmd $A) == bash ]]"
	lv_step "$A" "$B" "D 2" "couldn't detach" "D, Yes with no client: "
	check "N and D did not go to the bash panel" "! lv_bash $B && [[ -e $T/lvb-shim/handoffs && ! -s $T/lvb-shim/handoffs ]]"
	# M: edit_box as bash's, kept above the question's peek; what's typed and the cursor (in
	# each shot), Alt-Enter's new line, the cursor moved, a paste of 40 lines that scrolls it,
	# PgUp back to its top, Esc and Ctrl-C cancelling, then one sent through agent-say.
	lv_step "$A" "$B" m "MESSAGE TO asker" "M: "
	lv_step "$A" "$B" "h i Space t h e r e" "hi there" "M: "
	lv_step "$A" "$B" "M-Enter s e c o n d" "second" "M, Alt-Enter: "
	lv_step "$A" "$B" "Left Left Up End Home Right" "second" "M, the cursor moved: "
	lv_step "$A" "$B" "BSpace DC" "second" "M, Backspace and Delete: "
	# A resize under the box: drawn again at the new size (bash's on its WINCH), then back.
	for s in "$A" "$B"; do tmux -S "$s" resize-window -t work:panel -x 112 -y 34; done
	lv_step "$A" "$B" "" "second" "M, resized: "
	for s in "$A" "$B"; do tmux -S "$s" resize-window -t work:panel -x 130 -y 40; done
	lv_step "$A" "$B" "" "second" "M, resized back: "
	{ for i in $(seq -w 1 40); do printf 'line %s\n' "$i"; done; for i in $(seq -f %04g 1 30); do printf 'w%s ' "$i"; done; } >"$T/paste.txt"
	for s in "$A" "$B"; do tmux -S "$s" load-buffer -b ptest "$T/paste.txt"; tmux -S "$s" paste-buffer -p -d -b ptest -t work:panel; done
	lv_step "$A" "$B" "" "w0030" "M, a paste of 40 lines: "
	lv_step "$A" "$B" "PPage PPage PPage" "MESSAGE TO asker" "M, PgUp: "
	lv_step "$A" "$B" "NPage End" "MESSAGE TO asker" "M, PgDn: "
	lv_step "$A" "$B" Escape "message cancelled" "M, Esc: "
	lv_step "$A" "$B" "m x y" "xy" "M: "
	lv_step "$A" "$B" C-c "message cancelled" "M, Ctrl-C: "
	check "M, Ctrl-C: the box closed and neither panel ended" "[[ \$(lv_cmd $B) == tmux-revive-pan* && \$(lv_cmd $A) == bash ]]"
	lv_step "$A" "$B" "m Space Space Enter" "message cancelled" "M, only spaces: "
	# Sent to odd-one, a shell: agent-say turns it away on both ("not sent", said on the key
	# bar), and the box is gone (test/panel.sh delivers one to a stand-in agent either way).
	lv_step "$A" "$B" "Down m" "MESSAGE TO odd-one" "M: "
	lv_step "$A" "$B" "o n e M-Enter t w o Enter" "just a bash prompt" "M, sent: "
	check "M, sent: the box gone on both, and nothing delivered to a shell" "! grep -aq 'MESSAGE TO' $T/shot.a && ! grep -aq 'MESSAGE TO' $T/shot.b && ! grep -qx two $T/lva/state/mailbox.md && ! grep -qx two $T/lvb/state/mailbox.md"
	lv_step "$A" "$B" "Up" "QUESTION · asker" "M, back to asker: "
	# The ? page: scrolling, a page, the ends, an install button's confirm box (n: nothing
	# runs), Ctrl-C and Esc closing it.
	lv_step "$A" "$B" "?" "HELP · HOW TO USE REVIVE" "?: "
	lv_step "$A" "$B" "j j Down" "HELP · HOW TO USE REVIVE" "?, down: "
	lv_step "$A" "$B" "k Up" "HELP · HOW TO USE REVIVE" "?, up: "
	lv_step "$A" "$B" "NPage Space" "HELP · HOW TO USE REVIVE" "?, a page: "
	lv_step "$A" "$B" "End" "HELP · HOW TO USE REVIVE" "?, End: "
	lv_step "$A" "$B" "PPage Home" "HELP · HOW TO USE REVIVE" "?, Home: "
	lv_step "$A" "$B" "i" "yes, run it" "?, install: "
	lv_step "$A" "$B" "n" "install cancelled · nothing was run" "?, n: "
	check "?, n: nothing ran" "! tmux -S $A list-windows -F '#W' | grep -qx workforce && ! tmux -S $B list-windows -F '#W' | grep -qx workforce"
	lv_step "$A" "$B" "p" "This runs playwright-mcp's installer" "?, install: "
	lv_step "$A" "$B" "Escape" "install cancelled · nothing was run" "?, Esc on the confirm: "
	# The cancel's flash runs out first: the Rust panel drops it at its next draw (a look under
	# the page), bash only on a key, so a Ctrl-C near its 5 s would compare two moments.
	sleep 5.5
	lv_step "$A" "$B" "C-c" "▸ PANES" "?, Ctrl-C: "
	check "?, Ctrl-C: the page closed and neither panel ended" "[[ \$(lv_cmd $B) == tmux-revive-pan* && \$(lv_cmd $A) == bash ]]"
	lv_step "$A" "$B" "? x" "▸ PANES" "?, x: "
	lv_step "$A" "$B" "? Escape" "▸ PANES" "?, Esc: "
	check "M and ? did not go to the bash panel" "! lv_bash $B && [[ -e $T/lvb-shim/handoffs && ! -s $T/lvb-shim/handoffs ]]"
	# O on a pane here: the Rust panel opens it itself, as bash does. A client attached to each
	# server (from a tmux of their own, at a size the panels' windows ignore) is switched to it.
	local K=$T/lvk.sock
	sockets+=("$K")
	tmux -S "$K" -f /dev/null new-session -d -s k -x 100 -y 30 "env -u TMUX -u TMUX_PANE tmux -S $A attach -f ignore-size -t work"
	tmux -S "$K" new-window -d -t k "env -u TMUX -u TMUX_PANE tmux -S $B attach -f ignore-size -t work"
	for _ in $(seq 1 25); do [[ -n $(tmux -S "$A" list-clients) && -n $(tmux -S "$B" list-clients) ]] && break; sleep 0.2; done
	lv_step "$A" "$B" O "▸ PANES" ""
	check "O: tmux's client went to the pane on both (asker)" "[[ \$(tmux -S $A list-clients -F '#{window_name}') == asker && \$(tmux -S $B list-clients -F '#{window_name}') == asker ]]"
	check "O did not go to the bash panel" "[[ -e $T/lvb-shim/handoffs && ! -s $T/lvb-shim/handoffs ]]"
	tmux -S "$K" kill-server 2>/dev/null
	# REVIVE_PANEL_POPUP: the panel closes once O has opened the pane (bash's exit 0).
	local s
	for s in "$A" "$B"; do
		tmux -S "$s" select-window -t work:odd
		local cmd=$GOLDEN_A
		[[ $s == "$B" ]] && cmd="env PATH=$T/lvb-shim:$PATH $GOLDEN_B"
		env_for "${s%.sock}" "$s"
		# shellcheck disable=SC2145
		tmux -S "$s" new-window -d -t work -n pop "env ${ENV[*]} REVIVE_PANEL_REFRESH=60 REVIVE_PANEL_NOW=$RNOW AGENT_SAY_SSH=false REVIVE_PANEL_POPUP=1 $cmd"
	done
	for s in "$A" "$B"; do
		for _ in $(seq 1 40); do tmux -S "$s" capture-pane -p -t work:pop 2>/dev/null | grep -q '▶' && break; sleep 0.2; done
		tmux -S "$s" send-keys -t work:pop O
	done
	for s in "$A" "$B"; do
		local who=A
		[[ $s == "$B" ]] && who=B
		check "$who with REVIVE_PANEL_POPUP: O opens the pane and the panel closes" "for _ in \$(seq 1 25); do tmux -S $s list-windows -F '#W' | grep -qx pop || break; sleep 0.2; done; ! tmux -S $s list-windows -F '#W' | grep -qx pop && [[ \$(tmux -S $s display -p -t work '#I') == 0 ]]"
	done
	check "O in the popup did not go to the bash panel" "[[ -e $T/lvb-shim/handoffs && ! -s $T/lvb-shim/handoffs ]]"
	# Outside tmux (no TMUX): O selects the pane, puts the terminal back and becomes `tmux attach
	# -t SESSION`. A tmux on PATH notes an attach and ends there (never your server); the rest
	# go to the real one.
	local at=$T/lv-attach
	mkdir -p "$at"
	printf '#!%s\nif [[ $1 == attach ]]; then echo "$*" >%q/attach.last.$REVIVE_NAME; exit 0; fi\nexec %q "$@"\n' \
		"$(command -v bash)" "$at" "$(command -v tmux)" >"$at/tmux"
	chmod +x "$at/tmux"
	for s in "$A" "$B"; do
		tmux -S "$s" select-window -t work:odd
		local cmd=$GOLDEN_A who=A
		[[ $s == "$B" ]] && cmd="env PATH=$at:$T/lvb-shim:$PATH $GOLDEN_B" who=B
		env_for "${s%.sock}" "$s"
		# TMUX_TMPDIR: a tmux with no -S that slipped past the stand-in finds no server, not yours
		# shellcheck disable=SC2145
		tmux -S "$s" new-window -d -t work -n out "env -u TMUX -u TMUX_PANE TMUX_TMPDIR=$at PATH=$at:$PATH REVIVE_NAME=$who ${ENV[*]} REVIVE_PANEL_REFRESH=60 REVIVE_PANEL_NOW=$RNOW AGENT_SAY_SSH=false $cmd"
	done
	for s in "$A" "$B"; do
		for _ in $(seq 1 40); do tmux -S "$s" capture-pane -p -t work:out 2>/dev/null | grep -q '▶' && break; sleep 0.2; done
		tmux -S "$s" send-keys -t work:out O
	done
	for who in A B; do
		s=$A
		[[ $who == B ]] && s=$B
		check "$who outside tmux: O selects the pane and becomes tmux attach -t work" "for _ in \$(seq 1 25); do tmux -S $s list-windows -F '#W' | grep -qx out || break; sleep 0.2; done; ! tmux -S $s list-windows -F '#W' | grep -qx out && [[ \$(tmux -S $s display -p -t work '#I') == 0 && \$(cat $at/attach.last.$who 2>/dev/null) == 'attach -t work' ]]"
	done
	check "O outside tmux did not go to the bash panel" "[[ -e $T/lvb-shim/handoffs && ! -s $T/lvb-shim/handoffs ]]"
	# A pane appearing between the pane list and the agents' look: a tmux on the Rust panel's
	# PATH opens a window ahead of every other just before the batched look at the agents'
	# screens. The asking agent's state stays on its own row, never the newcomer's.
	local C=$T/lvc.sock shim=$T/lvc-shim
	mkdir -p "$shim"
	printf '#!/bin/bash\nif [[ $* == *display-message* && $* == *@@revive-* && ! -e %q ]]; then : >%q; %q -S %q new-window -d -b -t work:0 -n intruder "bash --norc --noprofile"; %q -S %q set-option -p -t work:intruder @agent intruder; fi\nexec %q "$@"\n' \
		"$shim/done" "$shim/done" "$(command -v tmux)" "$C" "$(command -v tmux)" "$C" "$(command -v tmux)" >"$shim/tmux"
	chmod +x "$shim/tmux"
	twin_up "$T/lvc" "$C" "env PATH=$shim:$PATH $GOLDEN_B"
	lvc() { tmux -S "$C" capture-pane -p -t work:panel; }
	for _ in $(seq 1 40); do [[ -e $shim/done ]] && lvc | grep -q 'NEEDS ANSWER' && break; sleep 0.2; done
	check "the look at the agents in the gather a pane was opened in put its state on its own row" "lvc | grep 'asker' | grep -q 'NEEDS ANSWER' && ! lvc | grep -q intruder"
	tmux -S "$C" send-keys -t work:panel x # any key looks again
	check "a pane opened between the pane list and the agents' look shows, not asking" "for _ in \$(seq 1 40); do lvc | grep -q 'intruder' && break; sleep 0.2; done; [[ -e $shim/done ]] && lvc | grep -q intruder && ! lvc | grep 'intruder' | grep -q 'NEEDS ANSWER'"
	check "and the agent asking still shows NEEDS ANSWER on its own row" "lvc | grep 'asker' | grep -q 'NEEDS ANSWER'"
	# Linked computers (a fake ssh, never a real one), the peek off: headings, folding (f, F,
	# Enter on a heading) and the arrows across a folded heading, on both panels.
	local D=$T/lvd.sock E=$T/lve.sock d
	for d in lvd lve; do
		fixtures "$T/$d" "$T/$d.sock" links
		env_for "$T/$d" "$T/$d.sock"
		local cmd=$GOLDEN_A
		[[ $d == lve ]] && lv_shim "$T/lve-shim" && cmd="env PATH=$T/lve-shim:$PATH $GOLDEN_B"
		# shellcheck disable=SC2145
		tmux -S "$T/$d.sock" new-window -d -t work -n panel "env ${ENV[*]} REVIVE_PANEL_REFRESH=60 REVIVE_PANEL_NOW=$RNOW REVIVE_PANEL_PEEK=0 AGENT_SAY_KEYSCAN=false AGENT_SAY_KNOWN_HOSTS=$T/$d/kh AGENT_SAY_TEST_NO_LINK_KEY=1 $cmd"
	done
	settle "$D" far-top && settle "$E" far-top
	local -a lsteps=("|far-top" "End|▸ PANES" "Down|▸ PANES" "f|▸ PANES" "Up|▸ PANES" "Down|▸ PANES" "Down|▸ PANES" "Up Up|▸ PANES" "Enter|▸ PANES" "F|▸ PANES" "Down|▸ PANES" "F|▸ PANES" "Home|▸ PANES" "PPage|▸ PANES" "NPage|▸ PANES")
	for step in "${lsteps[@]}"; do
		keys=${step%%|*} text=${step#*|}
		# shellcheck disable=SC2086
		[[ -n $keys ]] && for k in $keys; do tmux -S "$D" send-keys -t work:panel "$k"; tmux -S "$E" send-keys -t work:panel "$k"; sleep 0.15; done
		settle "$D" "$text" && settle "$E" "$text"
		for i in 1 2 3 4 5 6 7 8; do
			shot "$D" >"$T/shot.a"
			shot "$E" >"$T/shot.b"
			cmp -s "$T/shot.a" "$T/shot.b" && break
			sleep 0.2
		done
		check "linked: after '${keys:-the start}': the same screen and cursor" "grep -aqF -- '$text' $T/shot.a && cmp -s $T/shot.a $T/shot.b"
		[[ -n ${GOLDEN_DEBUG:-} ]] && plain <"$T/shot.b" | grep -E '▶|▓▒░ [A-Z]' | cut -c1-70
		cmp -s "$T/shot.a" "$T/shot.b" || diff "$T/shot.a" "$T/shot.b" | head -${GOLDEN_DIFF:-6} | sed 's/^/      /'
	done
	# Keys the key bar fades say why, from the Rust panel itself (no hand-over, so no gather
	# first): O on a linked computer's pane, N on one whose rows haven't come (no P_RID), and
	# O and M on a heading.
	# End: fold-sh, on folded.example (opened by F), its rows in. Up three times: far.example's
	# two panes, then Zed.example's last, a name only (the link unreachable: no rows, no
	# P_RID). f there folds Zed.example to its heading, selected; f again opens it.
	lv_step "$D" "$E" End "fold-sh" "linked: "
	lv_step "$D" "$E" O "O opens panes on this computer only" "linked: "
	lv_step "$D" "$E" "Up Up Up" "zed-b" "linked: "
	lv_step "$D" "$E" N "on Zed.example: can" "linked: "
	lv_step "$D" "$E" O "O opens panes on this computer only" "linked: "
	lv_step "$D" "$E" f "ZED.EXAMPLE" "linked: "
	lv_step "$D" "$E" O "select one of Zed.example" "linked: "
	lv_step "$D" "$E" M "select one of Zed.example" "linked: "
	lv_step "$D" "$E" N "select one of Zed.example" "linked: "
	lv_step "$D" "$E" f "zed-a" "linked: "
	check "linked: none of these keys went to the bash panel" "[[ -e $T/lve-shim/handoffs && ! -s $T/lve-shim/handoffs ]]"
	# N on a read-only link's pane that can act (rows, so a P_RID): not faded, so it goes on to
	# bash's rename box, as V and answering do there; read-only holds only what comes here.
	: >"$T/lvd/state/links/far.example/read-only"
	: >"$T/lve/state/links/far.example/read-only"
	lv_step "$D" "$E" "Down Down Down" "far-top" "linked: "
	lv_step "$D" "$E" N "New name for far-top on far.example:" "linked, read-only: "
	lv_step "$D" "$E" Escape "rename cancelled" "linked, read-only: "
	# A name that can't be one there, then one that can: agent-say name runs there (the fake
	# ssh answers as it would), and what it says is said here.
	lv_step "$D" "$E" "N a Space b Enter" "be a name: use letters" "linked: "
	lv_step "$D" "$E" "N n e w Enter" "on far.example: pane %1 is now 'new'" "linked: "
	check "linked: N on a pane with rows stayed in Rust, as every key here did" "! lv_bash $E && [[ -e $T/lve-shim/handoffs && ! -s $T/lve-shim/handoffs ]]"
	# A pane opened while D's box is up: the Rust panel goes on looking under it (REFRESH 1
	# here), so PANES shows it with the box still up, where bash's is frozen; the box itself,
	# and the cursor, as bash's.
	local F=$T/lvf.sock G=$T/lvg.sock
	for d in lvf lvg; do
		fixtures "$T/$d" "$T/$d.sock"
		env_for "$T/$d" "$T/$d.sock"
		local cmd=$GOLDEN_A
		[[ $d == lvg ]] && cmd=$GOLDEN_B
		# shellcheck disable=SC2145
		tmux -S "$T/$d.sock" new-window -d -t work -n panel "env ${ENV[*]} REVIVE_PANEL_REFRESH=1 REVIVE_PANEL_NOW=$RNOW AGENT_SAY_SSH=false $cmd"
	done
	lvp() { tmux -S "$1" capture-pane -p -t work:panel; }
	for s in "$F" "$G"; do for _ in $(seq 1 50); do lvp "$s" | grep -q '▶' && break; sleep 0.2; done; done
	for s in "$F" "$G"; do tmux -S "$s" send-keys -t work:panel D; done
	check "a pane opened under D's box: both show the box" "for _ in \$(seq 1 40); do lvp $F | grep -q 'DETACH TMUX?' && lvp $G | grep -q 'DETACH TMUX?' && break; sleep 0.2; done; lvp $F | grep -q 'DETACH TMUX?' && lvp $G | grep -q 'DETACH TMUX?'"
	for s in "$F" "$G"; do
		tmux -S "$s" new-window -d -t work -n newcomer "bash --norc --noprofile"
		tmux -S "$s" set-option -p -t work:newcomer @agent newcomer
	done
	check "a pane opened under D's box: the Rust panel's PANES shows it, the box still up" "for _ in \$(seq 1 40); do lvp $G | grep -q newcomer && break; sleep 0.2; done; lvp $G | grep -q newcomer && lvp $G | grep -q 'DETACH TMUX?'"
	check "a pane opened under D's box: bash's panel is frozen under its box" "! lvp $F | grep -q newcomer"
	sleep 1.5 # a look or two more under it
	for s in "$F" "$G"; do
		tmux -S "$s" capture-pane -e -p -t work:panel | python3 "$T/box.py" 'DETACH TMUX?' >"$T/box.$(basename "$s")"
		tmux -S "$s" display -p -t work:panel 'cursor #{cursor_x},#{cursor_y},#{cursor_flag}' >>"$T/box.$(basename "$s")"
	done
	check "a pane opened under D's box: the box, its colours and the cursor are bash's" "[[ -s $T/box.lvf.sock ]] && cmp -s $T/box.lvf.sock $T/box.lvg.sock"
	cmp -s "$T/box.lvf.sock" "$T/box.lvg.sock" || diff "$T/box.lvf.sock" "$T/box.lvg.sock" | head -6 | cut -c1-300 | sed 's/^/      /'
	for s in "$F" "$G"; do tmux -S "$s" send-keys -t work:panel Escape; done
	check "a pane opened under D's box: Esc, and both show it" "for _ in \$(seq 1 40); do lvp $F | grep -q newcomer && lvp $G | grep -q newcomer && break; sleep 0.2; done; lvp $F | grep -q 'detach cancelled' && lvp $G | grep -q 'detach cancelled' && lvp $F | grep -q newcomer"
	live_answer
	live_ubg
}

# Answering a question, the Rust panel's own (plan Phase 5). A twin of bash's: the question and
# the ANSWERING bar the same, cell for cell, everything above the question masked (bash holds
# the banner and PANES still while it answers, the Rust panel goes on updating them); a letter
# the free-text choice keeps, E's box (compared as a box), Esc closing it, Esc leaving. Then the
# Rust panel alone, looking every second: a pane opened while it answers shows in PANES within
# two refreshes, the question still being answered.
# ashot SOCKET: shot, with every row above the question's title masked
ashot() { shot "$1" | awk '!q && /QUESTION · / {q = 1} q {print; next} {print "<above the question>"}'; }
la_step() { # la_step SA SB KEYS TEXT LABEL: KEYS to both, then the same question and bar (ashot)
	local k i
	# shellcheck disable=SC2086 # one tmux key name each
	[[ -n $3 ]] && for k in $3; do tmux -S "$1" send-keys -t work:panel "$k"; tmux -S "$2" send-keys -t work:panel "$k"; sleep 0.15; done
	settle "$1" "$4" && settle "$2" "$4"
	for i in 1 2 3 4 5 6 7 8; do
		ashot "$1" >"$T/shot.a"
		ashot "$2" >"$T/shot.b"
		cmp -s "$T/shot.a" "$T/shot.b" && break
		sleep 0.2
	done
	LV_TEXT=$4
	shot "$1" >"$T/full.a" # TEXT may be in a box over the rows masked
	check "$5after '$3': the same question, bar and cursor, above it masked ($4)" "grep -aqF -- \"\$LV_TEXT\" $T/full.a && grep -aqF 'QUESTION · ' $T/shot.a && cmp -s $T/shot.a $T/shot.b"
	grep -aqF -- "$LV_TEXT" "$T/full.a" || plain <"$T/shot.a" | tail -n 4 | head -n 2 | sed 's/^/      A: /'
	cmp -s "$T/shot.a" "$T/shot.b" || diff "$T/shot.a" "$T/shot.b" | head -${GOLDEN_DIFF:-6} | sed 's/^/      /'
}
live_answer() {
	local A=$T/lqa.sock B=$T/lqb.sock R=$T/lqr.sock s
	twin_up "$T/lqa" "$A" "$GOLDEN_A"
	lv_shim "$T/lqb-shim"
	twin_up "$T/lqb" "$B" "env PATH=$T/lqb-shim:$PATH $GOLDEN_B"
	lv_step "$A" "$B" "" "C O N T R O L" "answering: "
	lv_step "$A" "$B" Down "QUESTION · asker" "answering: "
	la_step "$A" "$B" Enter "ANSWERING asker" "answering: "
	check "answering: the question offers [E]nter only on its free-text choice, not here" "! grep -aqF '[E]nter' $T/shot.b"
	la_step "$A" "$B" x "[E]nter to type" "answering, a letter it keeps: "
	la_step "$A" "$B" E "ANSWER · asker" "answering, E: "
	for s in "$A" "$B"; do
		tmux -S "$s" capture-pane -e -p -t work:panel | python3 "$T/box.py" 'ANSWER · asker' >"$T/abox.$(basename "$s")"
		tmux -S "$s" display -p -t work:panel 'cursor #{cursor_x},#{cursor_y},#{cursor_flag}' >>"$T/abox.$(basename "$s")"
	done
	check "answering, E: the answer's box, its colours and the cursor are bash's" "[[ -s $T/abox.lqa.sock ]] && cmp -s $T/abox.lqa.sock $T/abox.lqb.sock"
	cmp -s "$T/abox.lqa.sock" "$T/abox.lqb.sock" || diff "$T/abox.lqa.sock" "$T/abox.lqb.sock" | head -6 | cut -c1-300 | sed 's/^/      /'
	la_step "$A" "$B" "h i" "ANSWER · asker" "answering, typed in E's box: "
	la_step "$A" "$B" Escape "closed; nothing was sent" "answering, Esc on the box: "
	la_step "$A" "$B" Escape "left the question" "answering, Esc: "
	check "answering: no hand-over, the Rust panel's own" "! lv_bash $B && [[ -e $T/lqb-shim/handoffs && ! -s $T/lqb-shim/handoffs ]]"
	tmux -S "$A" kill-server 2>/dev/null
	tmux -S "$B" kill-server 2>/dev/null
	# The Rust panel alone, looking every second.
	fixtures "$T/lqr" "$R"
	env_for "$T/lqr" "$R"
	# shellcheck disable=SC2145
	tmux -S "$R" new-window -d -t work -n panel "env ${ENV[*]} REVIVE_PANEL_REFRESH=1 REVIVE_PANEL_NOW=$RNOW AGENT_SAY_SSH=false $GOLDEN_B"
	lqr() { tmux -S "$R" capture-pane -p -t work:panel; }
	for _ in $(seq 1 50); do lqr | grep -q '▶' && break; sleep 0.2; done
	for _ in $(seq 1 20); do lqr | grep -q '▶.*asker' && break; tmux -S "$R" send-keys -t work:panel Down; sleep 0.3; done
	tmux -S "$R" send-keys -t work:panel Enter
	for _ in $(seq 1 40); do lqr | grep -q 'ANSWERING asker' && break; sleep 0.2; done
	tmux -S "$R" new-window -d -t work -n newcomer "bash --norc --noprofile"
	tmux -S "$R" set-option -p -t work:newcomer @agent newcomer
	local t0 t1
	t0=$(date +%s%N)
	for _ in $(seq 1 50); do lqr | grep -q 'newcomer' && break; sleep 0.1; done
	t1=$(date +%s%N)
	check "answering: a pane opened in another window shows in PANES within two refreshes ($(((t1 - t0) / 1000000)) ms)" "lqr | grep -q newcomer && (((t1 - t0) / 1000000 <= 2500))"
	check "answering: and the question is still being answered" "lqr | grep -q 'ANSWERING asker' && lqr | grep -q 'QUESTION · asker'"
	tmux -S "$R" send-keys -t work:panel Escape
	check "answering: Esc leaves it, the newcomer still shown" "for _ in \$(seq 1 25); do lqr | grep -q 'left the question' && break; sleep 0.2; done; lqr | grep -q 'left the question' && lqr | grep -q newcomer"
	tmux -S "$R" kill-server 2>/dev/null
}

# U, B and G, the Rust panel's own: their boxes and flashes against bash's, live, on the linked
# computers' fixture. Both panels run from a copy of this tree ($T/tree) whose bin/agent-say
# answers for a few made-up hosts (their host keys, a link that gives a link key line, one
# turned away for another key, a login) and is the real one for the rest; a tmux in front of
# the real one stands in for the code popup (Esc in it, as no client is attached to show one);
# tmux-revive update here is a stand-in installer (REVIVE_SOURCE) and there the fake ssh's,
# both held until a gate file is there, so the two lists can be compared mid-way.
live_ubg() {
	local H=$T/lvh.sock I=$T/lvi.sock TR=$T/tree d s
	mkdir -p "$TR"
	tar -C "$ROOT" --exclude=./.git --exclude=./panel-rs/target --exclude=./.claude -cf - . | tar -C "$TR" -xf -
	mkdir -p "$TR/panel-rs/target/release"
	cp "$GOLDEN_B" "$TR/panel-rs/target/release/tmux-revive-panel"
	cat >"$TR/bin/agent-say" <<ASAY
#!/bin/bash
REAL=$(printf %q "$ROOT/bin/agent-say")
if [[ \${BASH_SOURCE[0]} != "\$0" ]]; then source "\$REAL"; return; fi
echo "\$*" >>"\$(dirname "\${AGENT_SAY_MAILBOX:-/nonexistent/x}")/asay.log"
case \$1 in _host-keys | link | _login) echo "\${AGENT_SAY_SCAN_ID:-none} \$1 \${2:-}" >>"\$(dirname "\${AGENT_SAY_MAILBOX:-/nonexistent/x}")/scan.log" ;; esac
case "\$1 \${2:-}" in
"_host-keys keyhost.example") printf 'state: unknown\nSHA256:KeyHost0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa (ED25519)\n'; exit 0 ;;
"_host-keys changed.example")
	if [[ \${3:-} == --new ]]; then printf 'SHA256:NewKey1bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb (ED25519)\n'
	else printf 'state: trusted\nSHA256:OldKey0cccccccccccccccccccccccccccccccccccccccc (ED25519)\n'; fi
	exit 0 ;;
"link keyhost.example") printf 'linked to keyhost.example\nlink key: set up; one line is yours to place\nlink key line, put it in ~/.ssh/authorized_keys there: restrict,command="agent-say _link" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOv4Q0bFz2k9yW3mXr7Pq8sTu1VcL6nJ0hGdE5aB2cK9 link@golden\n'; exit 0 ;;
"link changed.example") echo "agent-say: changed.example answers with another host key; check it, then link again and confirm the new key"; exit 1 ;;
"_login pw.example") [[ \${3:-} == --check ]] && exit 1; exit 0 ;;
esac
exec "\$REAL" "\$@"
ASAY
	chmod +x "$TR/bin/agent-say"
	local shim=$T/lvubg-shim
	mkdir -p "$shim"
	printf '#!/bin/bash\nif [[ " $* " == *" display-popup "* ]]; then st=$(dirname "$AGENT_SAY_MAILBOX"); echo "$*" >>"$st/popup.log"; printf "\\37" >"$st/intros/.allow.out"; exit 0; fi\nexec %q "$@"\n' "$(command -v tmux)" >"$shim/tmux"
	chmod +x "$shim/tmux"
	lv_shim "$T/lvi-shim"
	for d in lvh lvi; do
		s=$T/$d.sock
		fixtures "$T/$d" "$s" links
		# A link that waits for its login.
		mkdir -p "$T/$d/state/links/pw.example" && : >"$T/$d/state/links/pw.example/on" && : >"$T/$d/state/links/pw.example/login"
		# An intro waiting now, to approve or deny.
		local id=9999999999999999aaaaaaaaaaaaaaaa
		mkdir -p "$T/$d/state/intros/$id/held"
		echo near@far.example >"$T/$d/state/intros/$id/from"; echo asker@golden >"$T/$d/state/intros/$id/to"
		echo "s:$id@far.example" >"$T/$d/state/intros/$id/from-session"; echo "s:to$id@golden" >"$T/$d/state/intros/$id/to-session"
		date +%s >"$T/$d/state/intros/$id/created"; printf 'may I see the build log? it failed twice tonight' >"$T/$d/state/intros/$id/intro"
		echo "to see why it failed" >"$T/$d/state/intros/$id/why"
		# tmux-revive update, here and there: logged, then held until the gate is there.
		mkdir -p "$T/$d/src"
		printf '#!/bin/sh\necho run >>%q\n[ -e %q ] && { echo "mv: cannot move: Permission denied"; exit 1; }\nwhile [ ! -e %q ]; do sleep 0.1; done\necho "==> tmux-revive 1.0.0 -> 9.9.9, release v9.9.9"\n' \
			"$T/$d/update.log" "$T/$d/update.perm" "$T/$d/update.gate" >"$T/$d/src/install.sh"
		{
			printf '#!/bin/bash\nT=%q\n' "$T/$d"
			cat <<'SSH'
cmd=${!#}
if [[ $cmd == *' tmux-revive update '* && ${*: -2:1} != Zed.example ]]; then
	echo "${*: -2:1}" >>"$T/update.calls"
	while [[ ! -e $T/update.gate ]]; do sleep 0.1; done
	echo "==> tmux-revive 1.2.0 -> 9.9.9, release v9.9.9"; exit 0
fi
SSH
			printf 'exec %q "$@"\n' "$T/$d/bin/fakessh"
		} >"$T/$d/bin/updssh"
		chmod +x "$T/$d/bin/updssh"
		env_for "$T/$d" "$s"
		local cmd="bash $TR/scripts/panel.sh" path=$shim:$PATH
		[[ $d == lvi ]] && cmd=$TR/panel-rs/target/release/tmux-revive-panel path=$T/lvi-shim:$path
		# shellcheck disable=SC2145
		tmux -S "$s" new-window -d -t work -n panel "env ${ENV[*]} PATH=$path AGENT_SAY_SSH=$T/$d/bin/updssh REVIVE_SOURCE=$T/$d/src REVIVE_PANEL_REFRESH=60 REVIVE_PANEL_NOW=$RNOW REVIVE_PANEL_PEEK=0 AGENT_SAY_KEYSCAN=false AGENT_SAY_KNOWN_HOSTS=$T/$d/kh AGENT_SAY_TEST_NO_LINK_KEY=1 $cmd"
	done
	check "U B G: B is the Rust panel" "for _ in \$(seq 1 25); do [[ \$(lv_cmd $I) == tmux-revive-pan* ]] && break; sleep 0.2; done; [[ \$(lv_cmd $I) == tmux-revive-pan* ]]"
	settle "$H" far-top && settle "$I" far-top
	both() { [[ $(cat "$T/lvh/$1" 2>/dev/null) == "$2" && $(cat "$T/lvi/$1" 2>/dev/null) == "$2" ]]; }
	# U: every job at once, each once; Zed.example (unreachable) done first, the rest held.
	lv_step "$H" "$I" U "unreachable" "U: "
	check "U: the list mid-way, its bar at 1/4" "grep -aqF ' 1/4' $T/shot.b"
	check "U: this computer and each linked one updated once, asking nothing" "for _ in \$(seq 1 25); do both update.log run && break; sleep 0.2; done; both update.log run && [[ \$(sort $T/lvh/update.calls) == \$'far.example\\nfolded.example' && \$(sort $T/lvi/update.calls) == \$'far.example\\nfolded.example' ]]"
	: >"$T/lvh/update.gate"; : >"$T/lvi/update.gate"
	lv_step "$H" "$I" "" "4/4" "U, the gate open: "
	tmux -S "$I" capture-pane -p -t work:panel >"$T/ubg-done.b"
	check "U: the list ticked to done on its own (1.0.0 → 9.9.9 here, 1.2.0 → 9.9.9 there)" "grep -aq 'this computer .*1\\.0\\.0 → 9\\.9\\.9' $T/ubg-done.b && grep -aq 'far\\.example .*1\\.2\\.0 → 9\\.9\\.9' $T/ubg-done.b"
	lv_step "$H" "$I" Escape "▸ PANES" "U: "
	# Closed while it runs: the bar says so, and U shows that round again, never a second try.
	rm -f "$T"/lv[hi]/update.gate "$T"/lv[hi]/update.log "$T"/lv[hi]/update.calls
	lv_step "$H" "$I" U "unreachable" "U again: "
	lv_step "$H" "$I" Escape "still updating · U shows it" "U, closed while it runs: "
	lv_step "$H" "$I" U "updating…" "U while it runs: "
	check "U while it runs: nothing tried twice" "both update.log run && [[ \$(wc -l <$T/lvi/update.calls) == 2 && \$(wc -l <$T/lvh/update.calls) == 2 ]]"
	: >"$T/lvh/update.gate"; : >"$T/lvi/update.gate"
	lv_step "$H" "$I" "" "4/4" "U while it runs, the gate open: "
	lv_step "$H" "$I" Escape "▸ PANES" "U: "
	# Not this user's to update: [I], and I shows the command for their pane, copied.
	: >"$T/lvh/update.perm"; : >"$T/lvi/update.perm"
	lv_step "$H" "$I" U "no permission" "U, no permission: "
	lv_step "$H" "$I" "" "4/4" "U, no permission: "
	lv_step "$H" "$I" i "Run this in" "U, I: "
	check "U, I: the command is in tmux's paste buffer on both" "[[ \$(tmux -S $H show-buffer) == 'tmux-revive update' && \$(tmux -S $I show-buffer) == 'tmux-revive update' ]]"
	lv_step "$H" "$I" x "I: command" "U, I, a key: "
	lv_step "$H" "$I" Escape "▸ PANES" "U: "
	# B: the list (a link waiting for its login first, the failing one, the linked ones, other
	# host…); LINK AGAIN? for a link, and Esc there brings the list back as it was (going back:
	# act runs again, the list answered as it was, unseen).
	lv_step "$H" "$I" B "ATTACH SERVERS" "B: "
	lv_step "$H" "$I" "Down Down" "ATTACH SERVERS" "B: "
	lv_step "$H" "$I" Enter "LINK far.example AGAIN?" "B, relink: "
	lv_step "$H" "$I" Escape "ATTACH SERVERS" "B, going back: "
	tmux -S "$I" capture-pane -p -t work:panel >"$T/ubg-back.b" # unmasked: the cpu graph's row is under the box
	check "B, going back: the list as it was, far.example still highlighted" "grep -aq '▶ 3 *far\\.example' $T/ubg-back.b"
	lv_step "$H" "$I" Escape "▸ PANES" "B: "
	# The link waiting for its login: a login window (no client to show a popup), then its check.
	lv_step "$H" "$I" "B 1" "▸ PANES" "B, needs login: "
	check "B, needs login: a login window ran agent-say _login, then its check, on both" "for _ in \$(seq 1 25); do grep -q '^_login pw.example --check' $T/lvh/state/asay.log && grep -q '^_login pw.example --check' $T/lvi/state/asay.log && break; sleep 0.2; done; grep -qx '_login pw.example' $T/lvi/state/asay.log && grep -q '^_login pw.example --check' $T/lvi/state/asay.log && grep -qx '_login pw.example' $T/lvh/state/asay.log"
	lv_step "$H" "$I" "" "▸ PANES" "B, needs login, its check done: "
	# Another host, typed: a new key to confirm, then the link key's line to place.
	lv_step "$H" "$I" "B 5" "Host to link" "B, other host: "
	lv_step "$H" "$I" "keyhost.example" "keyhost.example" "B, other host: "
	lv_step "$H" "$I" Enter "LINK keyhost.example?" "B, a new key: "
	lv_step "$H" "$I" 2 "LINK KEY FOR keyhost.example" "B, the link key's line: "
	lv_step "$H" "$I" Enter "▸ PANES" "B, linked: "
	# scanids DIR HOST: the AGENT_SAY_SCAN_ID each agent-say call for HOST had, one per line
	scanids() { awk -v h="$2" '$3 == h {print $1}' "$1/state/scan.log" | sort -u; }
	check "B: the key read and the link of one B shared one scan (AGENT_SAY_SCAN_ID), on both" "[[ \$(scanids $T/lvi keyhost.example) == b* && \$(scanids $T/lvi keyhost.example | wc -l) == 1 && \$(scanids $T/lvh keyhost.example) == b* && \$(scanids $T/lvh keyhost.example | wc -l) == 1 && \$(grep -c keyhost.example $T/lvi/state/scan.log) == 2 ]]"
	# A trusted key, and the link turned away for another: the changed key, No first.
	lv_step "$H" "$I" "B 5" "Host to link" "B, changed key: "
	lv_step "$H" "$I" "changed.example Enter" "LINK changed.example?" "B, changed key: "
	lv_step "$H" "$I" Enter "HOST KEY CHANGED" "B, changed key: "
	lv_step "$H" "$I" 1 "▸ PANES" "B, changed key, No: "
	# G: the list, an intro's box, Esc back to the list; Approve's popup closed with Esc brings
	# the intro's box back; Deny declines it.
	lv_step "$H" "$I" G "LINK AGENTS TOGETHER" "G: "
	lv_step "$H" "$I" 1 "Approve" "G, an intro: "
	lv_step "$H" "$I" Escape "LINK AGENTS TOGETHER" "G, going back: "
	lv_step "$H" "$I" 1 "Approve" "G, an intro: "
	lv_step "$H" "$I" 1 "Approve" "G, the code popup closed: "
	check "G: Approve opened the code popup on both, and Esc in it brought the intro's box back" "grep -q 'display-popup' $T/lvh/state/popup.log && grep -q 'display-popup' $T/lvi/state/popup.log && grep -aq 'to see why it failed' $T/shot.b"
	lv_step "$H" "$I" 2 "declined" "G, Deny: "
	check "G, Deny: declined on both" "[[ ! -e $T/lvh/state/intros/9999999999999999aaaaaaaaaaaaaaaa && ! -e $T/lvi/state/intros/9999999999999999aaaaaaaaaaaaaaaa ]]"
	check "U, B and G did not go to the bash panel" "! lv_bash $I && [[ -e $T/lvi-shim/handoffs && ! -s $T/lvi-shim/handoffs ]]"
}

case ${1:-all} in
snaps) snaps ;;
render) snaps >/dev/null; render ;;
live-once) liveonce ;;
twins) twins ;;
live) live ;;
live-ubg) build_b && live_ubg ;; # U, B and G alone, as live ends with them
live-answer) build_b && live_answer ;; # answering alone, as live runs it before U, B and G
all) snaps; render; liveonce; twins; live ;; # tier 2 (live-once) and the live twins gate a release (plan 7.3)
*) echo "usage: panel-golden.sh [snaps|render|live-once|twins|live|live-ubg|live-answer]" >&2; exit 2 ;;
esac
printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
