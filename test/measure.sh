#!/usr/bin/env bash
# Phase 7.2 of plan/rust-panel-2026-11-23.md: the Rust panel measured against the bash one, on
# this computer, on a private tmux server with the golden fixtures (never yours). Not part of
# test/all.sh: it takes several minutes, wants a quiet machine, and loads every core on purpose.
#
#   bash test/measure.sh            all of it
#   bash test/measure.sh draw       1. draw time per frame at 200x60, the same snapshot
#   bash test/measure.sh keys       2. key-to-screen time for an arrow, idle and at load ~12
#   bash test/measure.sh gather     3. gather round time with MEASURE_AGENTS more agent panes
#   bash test/measure.sh programs   4. programs started per refresh (strace), steady state
#
# MEASURE_MAXLOAD (2): each part waits until the 1-minute load is under it, at most MEASURE_WAIT
# seconds (900), then goes on and says what the load was. MEASURE_HOGS (12): busy loops for the
# loaded key run. MEASURE_KEYS (80): arrow samples per run. MEASURE_AGENTS (12): stand-in Claude
# Codes added to the fixture, each in a git repository of its own. MEASURE_STRACE_SECS (55):
# how long each panel is traced; the first 10 s are left out.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d /tmp/rpm.XXXXXX) # short: a socket path has a length limit
unset TMUX TMUX_PANE XDG_STATE_HOME # never your tmux, nor your state dir
RS=$ROOT/panel-rs/target/release/tmux-revive-panel
MAXLOAD=${MEASURE_MAXLOAD:-2} WAIT=${MEASURE_WAIT:-900} HOGS=${MEASURE_HOGS:-12}
NKEYS=${MEASURE_KEYS:-80} NAG=${MEASURE_AGENTS:-12} STSECS=${MEASURE_STRACE_SECS:-55}
RNOW=1795000000
sockets=() HOGPG=""
cleanup() {
	local s
	[[ -n $HOGPG ]] && kill -- -"$HOGPG" 2>/dev/null
	for s in "${sockets[@]}"; do tmux -S "$s" kill-server 2>/dev/null; done
	pkill -f -- "$T/" 2>/dev/null # a strace or panel the hangup left going
	sleep 0.5
	[[ -n ${KEEP:-} ]] || rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

# The golden script's fixtures, its panel environment and its stand-in agents, taken out of it
# with sed (it has no guard to be sourced with).
eval "$(sed -n -e '/^fixtures() {/,/^}/p' -e '/^env_for() {/,/^}/p' -e '/^agents_addon() {/,/^}/p' "$ROOT/test/panel-golden.sh")"

load1() { cut -d' ' -f1 /proc/loadavg; }
# quiet: wait until the 1-minute load is under MAXLOAD (other work on this machine), at most WAIT s
quiet() {
	local t0=$SECONDS
	while awk -v l="$(load1)" -v m="$MAXLOAD" 'BEGIN { exit !(l >= m) }'; do
		if ((SECONDS - t0 >= WAIT)); then
			echo "  (load $(load1) still over $MAXLOAD after ${WAIT}s: measuring anyway)"
			return 1
		fi
		echo "  waiting for a quiet machine: load $(load1) ($((SECONDS - t0))s)"
		sleep 30
	done
	echo "  load $(load1) (nproc $(nproc))"
}
# hogs_on / hogs_off: HOGS busy loops in a process group of their own
hogs_on() {
	setsid bash -c 'for ((i = 0; i < '"$HOGS"'; i++)); do (while :; do :; done) & done; wait' </dev/null >/dev/null 2>&1 &
	HOGPG=$!
	sleep 20 # the load average catches up a little; the run queue is full at once
}
hogs_off() { [[ -n $HOGPG ]] && kill -- -"$HOGPG" 2>/dev/null; HOGPG=""; sleep 2; }
# stats: numbers in on stdin, "median p95 max n" out
stats() { sort -n | awk '{ v[NR] = $1 } END { if (!NR) { print "- - - 0"; exit } m = v[int((NR + 1) / 2)]; p = v[int(NR * 0.95 + 0.999)]; if (p == "") p = v[NR]; printf "%.2f %.2f %.2f %d\n", m, p, v[NR], NR }'; }

# The bash panel from a copy of this tree whose gather notes its own wall time in
# MEASURE_GATHER_LOG (the shipped scripts/panel.sh is not changed).
mkdir -p "$T/root"
cp -r "$ROOT/scripts" "$ROOT/bin" "$ROOT/VERSION" "$T/root/"
sed -i -e 's/^gather() {$/gather() { local _mt=${EPOCHREALTIME\/.\/}; _m_gather; [[ -n ${MEASURE_GATHER_LOG:-} ]] \&\& echo "gather-us $((${EPOCHREALTIME\/.\/} - _mt))" >>"$MEASURE_GATHER_LOG"; }\n_m_gather() {/' "$T/root/scripts/panel.sh"
grep -q '^_m_gather() {$' "$T/root/scripts/panel.sh" || { echo "measure.sh: gather() not found in scripts/panel.sh" >&2; exit 1; }
SH="bash $T/root/scripts/panel.sh"

# The panel, and the test binary that holds measure_gather (built here, with your HOME: the
# fixture's environment has its own)
build() {
	cargo build --release --locked --quiet --manifest-path "$ROOT/panel-rs/Cargo.toml" </dev/null || exit 1
	TEXE=$(cargo test --release --locked --no-run --message-format=json --manifest-path "$ROOT/panel-rs/Cargo.toml" 2>/dev/null </dev/null |
		python3 -c 'import json, sys
for l in sys.stdin:
    j = json.loads(l)
    if j.get("executable") and j.get("profile", {}).get("test"): print(j["executable"])')
	[[ -x $TEXE ]] || { echo "measure.sh: no test binary from cargo" >&2; exit 1; }
}

# The fixture: the golden one (a shell, a question, an odd folder, three Claude Codes and a
# Codex with their records), and NAG more Claude Codes, each with a transcript, in a git
# repository with a change not committed.
S=$T/fx.sock D=$T/fx
setup() {
	fixtures "$D" "$S"
	agents_addon "$D" "$S"
	local i g h=$D/home
	for ((i = 1; i <= NAG; i++)); do
		g=$D/work/ag$i
		mkdir -p "$g"
		git -C "$g" init -q -b main && echo one >"$g/f" && git -C "$g" add f &&
			git -C "$g" -c user.name=t -c user.email=t@example.com commit -qm one && echo two >"$g/f"
		cp "$h/.claude/projects/-w/aaaa-1.jsonl" "$h/.claude/projects/-w/ag$i.jsonl"
		tmux -S "$S" new-window -d -t work -n "ag$i" -c "$g" "env HOME=$h bash $D/claude.sh $h idle ag$i"
	done
	tmux -S "$S" set-option -g window-size manual
	# The harness floor: a pane that sends back each key it gets, as soon as it gets it
	tmux -S "$S" new-window -d -t work -n echo "stty raw -echo; exec cat"
	tmux -S "$S" resize-window -t work:echo -x 200 -y 60
	env_for "$D" "$S"
	sleep 2 # the panes draw their screens, the agents write their records
}
# panel_up NAME CMD...: CMD live in window NAME at 200x60, the real clock and REFRESH
panel_up() {
	local n=$1
	shift
	tmux -S "$S" new-window -d -t work -n "$n" "env ${ENV[*]} AGENT_SAY_SSH=false $*"
	tmux -S "$S" resize-window -t "work:$n" -x 200 -y 60
	local i
	for i in $(seq 1 100); do
		tmux -S "$S" capture-pane -p -t "work:$n" | grep -q 'C O N T R O L' && return 0
		sleep 0.2
	done
	echo "  $n never drew its panel" >&2
	return 1
}
# panel_down NAME: its window gone, and everything in the pane's session with it (a strace can
# outlive the hangup and keep its panel going)
panel_down() {
	local sid
	sid=$(tmux -S "$S" display -p -t "work:$1" '#{pane_pid}' 2>/dev/null)
	[[ -n $sid ]] && pkill -TERM -s "$sid" 2>/dev/null
	tmux -S "$S" kill-window -t "work:$1" 2>/dev/null
	sleep 0.5
	[[ -n $sid ]] && pkill -KILL -s "$sid" 2>/dev/null
	return 0
}

# keylat.py SOCKET PANE N MODE OUT: N arrow keys sent through one tmux control-mode client, the
# time from writing send-keys to the end (?2026l) of the first frame that moves the selection
# (a row with ▶ other than the last one), in ms, one per line in OUT; MODE echo: to the first
# output at all (the floor). Keys go Down 5 times, then Up 5 times, a random 150-450 ms apart.
cat >"$T/keylat.py" <<'PY'
import os, random, re, select, subprocess, sys, time
sock, pane, n, mode, out = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5]
p = subprocess.Popen(["tmux", "-S", sock, "-C", "attach", "-t", "work"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0)
fd = p.stdout.fileno()
buf = b""
def lines(timeout):
    """(arrival time, line) for each line within timeout s"""
    global buf
    end = time.monotonic() + timeout
    while True:
        while b"\n" in buf:
            l, buf = buf.split(b"\n", 1)
            yield time.monotonic(), l
        left = max(0, end - time.monotonic())  # 0: only what has come in already
        r, _, _ = select.select([fd], [], [], left)
        if not r:
            return
        d = os.read(fd, 65536)
        if not d:
            return
        buf += d
unesc = lambda v: re.sub(rb"\\([0-7]{3})", lambda m: bytes([int(m.group(1), 8)]), v)
pre = b"%output " + pane.encode() + b" "
row = re.compile(rb"\x1b\[(\d+);1H(.*?)\x1b\[K", re.S)
frame = b""
sel = None
def frames(timeout):
    """(time, frame) for each whole frame the pane prints within timeout s"""
    global frame
    for t, l in lines(timeout):
        if not l.startswith(pre):
            continue
        frame += unesc(l[len(pre):])
        while b"\x1b[?2026l" in frame:
            f, frame = frame.split(b"\x1b[?2026l", 1)
            yield t, f
def selrow(f):
    for r, txt in row.findall(f):
        if "▶".encode() in txt:
            return int(r)
    return None
# what is selected now: the panel redrawn whole (C-l is not a key it has; a resize is)
if mode != "echo":
    for _ in frames(2.5):
        pass
res = []
keys = ["Down"] * 5 + ["Up"] * 5
miss = 0
for i in range(n):
    k = keys[i % len(keys)]
    for _ in frames(0):
        pass
    t0 = time.monotonic()
    p.stdin.write(("send-keys -t %s %s\n" % (pane, k)).encode())
    got = None
    for t, f in (frames(3) if mode != "echo" else ()):
        r = selrow(f)
        if r is not None and r != sel:
            sel = r
            got = t
            break
    if mode == "echo":
        for t, l in lines(3):
            if l.startswith(pre):
                got = t
                break
    if got is None:
        miss += 1
    else:
        res.append(((got - t0) * 1000, sel))
    time.sleep(random.uniform(0.15, 0.45))
p.stdin.close()
p.wait(timeout=5)
with open(out, "w") as o:
    for v, r in res[1:]:  # the first only finds where the selection is
        o.write("%.3f %s\n" % (v, r))  # and the row it moved to, for a closer look (KEEP=1)
print("    %d samples, %d with no frame in 3 s" % (len(res) - 1, miss), file=sys.stderr)
PY

# ------------------------------------------------------------------ 1. draw
draw() {
	echo "1. draw time per frame at 200x60 (REVIVE_PANEL_SIZES: K frames in one run minus 1, over K-1)"
	quiet
	mkdir -p "$T/snap"
	local sc id
	local -A selof=([shell]=work:0 [question]=work:asker [agent]=work:cl-wait)
	for sc in shell question agent; do
		id=$(tmux -S "$S" display -p -t "${selof[$sc]}" '#{pane_id}')
		env "${ENV[@]}" REVIVE_PANEL_NOW="$(date +%s)" REVIVE_PANEL_SEL="$id" COLUMNS=200 LINES=60 \
			REVIVE_PANEL_SNAP="save:$T/snap/$sc" timeout 120 bash "$ROOT/scripts/panel.sh" --once >/dev/null </dev/null
	done
	local p cmd k r t a b one many sizes
	for sc in shell question agent; do
		for p in bash rust; do
			if [[ $p == bash ]]; then cmd="bash $ROOT/scripts/panel.sh" k=${MEASURE_FRAMES_SH:-21}; else cmd=$RS k=${MEASURE_FRAMES_RS:-201}; fi
			# shellcheck disable=SC2086 # the panel is a command line
			env "${ENV[@]}" REVIVE_SOCKET="$T/no-such-socket" REVIVE_PANEL_NOW=$RNOW REVIVE_PANEL_SNAP="load:$T/snap/$sc" \
				REVIVE_PANEL_SIZES=200x60 $cmd --once >"$T/frame.$sc.$p" </dev/null
			for r in 1 2 3 4 5; do
				for t in 1 "$k"; do
					sizes=200x60
					[[ $t == 1 ]] || sizes=$(printf '200x60 %.0s' $(seq 1 "$k"))
					a=${EPOCHREALTIME/./}
					# shellcheck disable=SC2086
					env "${ENV[@]}" REVIVE_SOCKET="$T/no-such-socket" REVIVE_PANEL_NOW=$RNOW REVIVE_PANEL_SNAP="load:$T/snap/$sc" \
						REVIVE_PANEL_SIZES="$sizes" $cmd --once >/dev/null </dev/null
					b=${EPOCHREALTIME/./}
					echo $((b - a)) >>"$T/draw.$sc.$p.$t"
				done
			done
			one=$(stats <"$T/draw.$sc.$p.1" | cut -d' ' -f1) many=$(stats <"$T/draw.$sc.$p.$k" | cut -d' ' -f1)
			awk -v s="$sc" -v p="$p" -v o="$one" -v m="$many" -v k="$k" 'BEGIN { printf "  %-8s %-4s  one run %7.1f ms  per frame %7.2f ms  (K=%d)\n", s, p, o / 1000, (m - o) / (k - 1) / 1000, k }'
		done
		# what was timed is the same frame from both, and a whole one
		printf '  %-8s the same frame from both: %s (%s lines)\n' "$sc" "$(cmp -s "$T/frame.$sc.bash" "$T/frame.$sc.rust" && echo yes || echo NO)" "$(($(wc -l <"$T/frame.$sc.rust") - 1))"
	done
	echo "  load after: $(load1)"
}

# ------------------------------------------------------------------ 2. keys
keys_run() { # keys_run LABEL PANE MODE
	python3 "$T/keylat.py" "$S" "$2" "$NKEYS" "$3" "$T/keys.$1"
	printf '  %-22s median %s ms  p95 %s ms  max %s ms  (n %s)  load %s  %s\n' "$1" $(stats <"$T/keys.$1") "$(load1)" \
		"$(tmux -S "$S" display -p -t "$2" '#{pane_width}x#{pane_height}')"
	# by the row each key moved the selection to (which pane that is: the panel's PANES)
	[[ $3 == echo ]] || sort -k2n "$T/keys.$1" | awk '{ n[$2]++; s[$2] += $1; if ($1 > 20) o[$2]++ } END { for (r in n) printf "    row %s: n %d, mean %.1f ms, %d over 20 ms\n", r, n[r], s[r] / n[r], o[r] }' | sort -k2n
}
# keys_panels LOAD: each panel, with the peek off (as it starts by default: only a question's
# screen is shown, and looked at when the selection reaches it) and on (REVIVE_PANEL_PEEK=1:
# every pane's screen, looked at on each move, the frame waiting for it up to ROUND_WAIT)
keys_panels() {
	local p pk cmd id
	for pk in 0 1; do
		for p in bash rust; do
			if [[ $p == bash ]]; then cmd=$SH; else cmd=$RS; fi
			panel_up "k$p" "REVIVE_PANEL_PEEK=$pk $cmd" || continue
			id=$(tmux -S "$S" display -p -t "work:k$p" '#{pane_id}')
			sleep 3
			keys_run "$p-peek$pk-$1" "$id" panel
			panel_down "k$p"
		done
	done
}
keys() {
	echo "2. key-to-screen for an arrow (tmux control mode: send-keys written to the frame's end)"
	quiet
	local echo_id
	echo_id=$(tmux -S "$S" display -p -t work:echo '#{pane_id}')
	keys_run floor-idle "$echo_id" echo
	keys_panels idle
	hogs_on
	keys_run "floor-load$HOGS" "$echo_id" echo
	keys_panels "load$HOGS"
	hogs_off
}

# ------------------------------------------------------------------ 3. gather
gather_rs() { # gather_rs LOG: the panes collector's gather, timed in a test of its own
	env "${ENV[@]}" AGENT_SAY_SSH=false MEASURE_ROUNDS=${MEASURE_ROUNDS:-15} \
		"$TEXE" measure_gather --ignored --nocapture 2>"$1.err" </dev/null |
		awk '/^gather-us/ { print $2 }' >"$1"
	[[ -s $1 ]] || sed 's/^/    /' "$1.err" | tail -n 8
}
gather_sh() { # gather_sh LOG: the bash panel live for 32 s, its gathers noted by the copy's wrapper
	panel_up gsh "MEASURE_GATHER_LOG=$1.raw $SH" || return
	sleep 32
	panel_down gsh
	tail -n +3 "$1.raw" | awk '{ print $2 }' >"$1" # the two of the start (the loading screen) left out
}
gather() {
	echo "3. gather round time, $((NAG + 7)) panes ($((NAG + 5)) agents): bash's gather, the Rust panes collector's"
	quiet
	local l
	gather_sh "$T/g.bash.idle"
	gather_rs "$T/g.rust.idle"
	hogs_on
	gather_sh "$T/g.bash.load"
	gather_rs "$T/g.rust.load"
	hogs_off
	for l in bash.idle rust.idle bash.load rust.load; do
		printf '  %-10s median %s ms  p95 %s ms  max %s ms  (n %s)\n' "$l" $(awk '{ print $1 / 1000 }' "$T/g.$l" | stats)
	done
}

# ------------------------------------------------------------------ 4. programs
# progs.py DIR T0: strace -ff files in DIR, the programs started (execve = 0) after T0 + 10 s:
# per program, per refresh (a refresh: one tmux list-panes), tmux by subcommand, git's bursts
cat >"$T/progs.py" <<'PY'
import collections, glob, re, sys
d, t0 = sys.argv[1], float(sys.argv[2]) + 10
ex = re.compile(r'^(\d+\.\d+) execve\("([^"]*)", \[(.*?)\]\, .*\) = 0')
c = collections.Counter(); tm = collections.Counter(); git = []
for f in glob.glob(d + "/x.*"):
    for l in open(f, errors="replace"):
        m = ex.match(l)
        if not m or float(m.group(1)) < t0:
            continue
        prog = m.group(2).rsplit("/", 1)[-1]
        args = re.findall(r'"((?:[^"\\]|\\.)*)"', m.group(3))
        c[prog] += 1
        if prog == "tmux":
            sub = next((a for a in args[1:] if not a.startswith("-") and "/" not in a), "?")
            tm[sub] += 1
        if prog == "git":
            git.append(float(m.group(1)))
rounds = tm["list-panes"] or 1
print("    refreshes (list-panes): %d" % tm["list-panes"])
print("    per refresh: " + ", ".join("%s %.2f" % (k, v / rounds) for k, v in c.most_common()))
print("    tmux per refresh: " + ", ".join("%s %.2f" % (k, v / rounds) for k, v in tm.most_common()))
b, last = [], -99
for t in sorted(git):
    if t - last > 1:
        b.append(t - t0)
    last = t
print("    git: %d runs in %d bursts, at %s s" % (len(git), len(b), " ".join("%.1f" % x for x in b)))
for k in ("ps", "head", "readlink", "grep", "jq"):
    print("    %s: %d" % (k, c[k]))
PY
programs() {
	echo "4. programs started, strace of each live panel for ${STSECS}s, the first 10 s left out"
	command -v strace >/dev/null || { echo "  no strace"; return; }
	quiet
	local p cmd t0
	for p in bash rust; do
		if [[ $p == bash ]]; then cmd=$SH; else cmd=$RS; fi
		mkdir -p "$T/st.$p"
		t0=$(date +%s.%N)
		# the ssh sessions outside tmux looked at as by default (only this computer's process table)
		panel_up "s$p" "REVIVE_PANEL_OUTSIDE_SSH=1 strace -ff -qq -ttt -s 512 -e trace=execve -o $T/st.$p/x $cmd" || continue
		sleep "$STSECS"
		panel_down "s$p"
		echo "  $p"
		python3 "$T/progs.py" "$T/st.$p" "$t0"
	done
}

build
setup
case ${1:-all} in
draw) draw ;;
keys) keys ;;
gather) gather ;;
programs) programs ;;
all) draw; keys; gather; programs ;;
*) echo "usage: measure.sh [draw|keys|gather|programs]" >&2; exit 2 ;;
esac
