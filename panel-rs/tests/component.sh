#!/usr/bin/env bash
# component.sh: scripts/panel.sh's own drawing functions, cut out of it and called one at a time,
# for comparing with `tmux-revive-panel --component` (test-only; it goes when tier 1 compares
# whole frames, plan Phase 1.3). The calls come on stdin, each ARGC\0 then ARGC fields
# NAME\0ARG\0...; each call's results go to stdout, every one followed by \0, then \n.
#
# What is cut out: the "colours" section through to "gathering" (colours, rep .. sect2, the
# banners, monitor, spark, the artwork, meter, human) and trim_colored, kc, kcs. Not the top of
# the file: it looks for the revive folder, which can ask your tmux. Run it under the locale and
# TZ the comparison wants (LC_ALL=C.UTF-8 TZ=UTC in the tests).
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
P=$ROOT/scripts/panel.sh
OS=$(uname -s) # common.sh's: the CRT's prompt is made from it
code=$(awk '/^# -+ colours$/{on=1} /^# -+ gathering$/{on=0} on' "$P")
for f in rep fld vlen padv clean row sbar tab seg sectk sect sect2 banner_rows big_banner monitor spark \
	canvas put rnd emit stars twinkle art scene_city tri pixel_cell scene_mountains mpix scene_space \
	scene_circuit cloud scene_grid meter human; do
	[[ $code == *$'\n'"$f() {"* ]] || { echo "component.sh: $f isn't between colours and gathering in panel.sh" >&2; exit 2; }
done
fns=""
for f in trim_colored kc kcs; do
	# NAME() { ... } on one line, or from NAME() { to the first } alone on a line.
	fn=$(awk -v f="$f" 'index($0, f "() {") == 1 { if ($0 ~ /; \}$/) { print; exit } on = 1 } on { print } on && /^\}$/ { exit }' "$P")
	[[ -n $fn ]] || { echo "component.sh: no $f in panel.sh" >&2; exit 2; }
	fns+=$fn$'\n'
done
eval "$code"
eval "$fns"
TICK=0 W=80 IW=76

o() { printf '%s\0' "$@"; }
call() {
	local f=$1 i v
	shift
	case $f in
	set)
		case $1 in TICK | W | IW | RBAR | ROWL | ROWR | SCENE) printf -v "$1" '%s' "$2" ;; *) echo "component.sh: can't set $1" >&2; exit 2 ;; esac ;;
	hist) CPU_HIST=("$@") ;;
	len) o "${#1}" ;;
	clean) v=$1; clean v; o "$v" ;;
	strftime) printf -v v "%($1)T" "$2"; o "$v" ;;
	globdirs) v=("$1"/*/); o "${v[@]}" ;;
	ere)
		[[ ${3:-} == icase ]] && shopt -s nocasematch
		if [[ $2 =~ $1 ]]; then o 1 "${BASH_REMATCH[@]}"; else o 0; fi
		shopt -u nocasematch ;;
	rep) rep "$@"; o "$REP" ;;
	fld) fld "$@"; o "$FLD" ;;
	vlen) vlen "$@"; o "$VLEN" ;;
	padv) padv "$@"; o "$PADV" ;;
	trim_colored) trim_colored "$@"; o "$TRIM" ;;
	line | row | sectk | sect | sect2) OUT=(); "$f" "$@"; o "${OUT[@]}" ;;
	sbar) sbar "$@"; for i in "${!SB[@]}"; do o "$i" "${SB[i]}"; done ;;
	tab) tab "$@"; o "$TAB" ;;
	seg) seg "$@"; o "$SEG" ;;
	kc | kcs) "$f" "$@"; o "$KC" ;;
	meter) meter "$@"; o "$METER" ;;
	human) human "$@"; o "$HUMAN" ;;
	banner_rows) banner_rows "$@"; o "${BANNER[@]}" ;;
	big_banner) big_banner "$@"; o "${BIG_ROWS[@]}" ;;
	monitor) monitor "$@"; o "${MON[@]}" ;;
	spark) spark "$@"; o "$SPARK" ;;
	tri) tri "$@"; o "$TRI" ;;
	# Always drawn afresh: from the memo, a frame of the animation would be one drawn before.
	art) ART_MEMO=() ART_ROWS=(); art "$@"; o "${ART[@]}" ;;
	# With the memo, as the panel draws (the same frame as afresh, or the memo is visible).
	art_memo) art "$@"; o "${ART[@]}" ;;
	*) echo "component.sh: no such call $f" >&2; exit 2 ;;
	esac
}
while IFS= read -r -d '' argc; do
	args=()
	for ((j = 0; j < argc; j++)); do IFS= read -r -d '' a; args+=("$a"); done
	call "${args[@]}"
	printf '\n'
done
