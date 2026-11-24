#!/usr/bin/env bash
# Everything the old GitHub CI ran, here on this machine: the suites, then shellcheck when it
# is installed. Run before a release. panel-golden builds the Rust panel with cargo (or takes
# GOLDEN_B, a built one) and compares its frames with bash's.
#   bash test/all.sh            all suites
#   bash test/all.sh panel e2e  just those
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
export TERM=${TERM:-xterm-256color}

suites=("$@")
((${#suites[@]})) || suites=(e2e agent-say panel panel-golden release)

declare -A result
failed=0
for s in "${suites[@]}"; do
	printf '\n\033[1m== %s ==\033[0m\n' "$s"
	start=$SECONDS
	if bash "test/$s.sh"; then result[$s]="pass"; else result[$s]="FAIL"; failed=1; fi
	result[$s]+=" ($((SECONDS - start))s)"
done

if (($# == 0)); then
	printf '\n\033[1m== shellcheck ==\033[0m\n'
	if command -v shellcheck >/dev/null; then
		if shellcheck --severity=error bin/* scripts/*.sh install.sh revive.tmux test/*.sh; then
			result[shellcheck]="pass"
		else
			result[shellcheck]="FAIL"; failed=1
		fi
		suites+=(shellcheck)
	else
		echo "shellcheck not installed, skipped (sudo pacman -S shellcheck)"
	fi
fi

printf '\n\033[1m== summary ==\033[0m\n'
for s in "${suites[@]}"; do printf '  %-11s %s\n' "$s" "${result[$s]}"; done
exit "$failed"
