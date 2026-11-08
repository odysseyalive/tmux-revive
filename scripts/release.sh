#!/usr/bin/env bash
# Cut a signed release (maintainer only). From a clean main:
#   scripts/release.sh [--dry-run] [--key PATH] [--out DIR] VERSION
# writes VERSION (committed if it changed), builds tmux-revive-VERSION.tar.gz with
# git archive, writes SHA256SUMS for it, signs that with an SSH key (ssh-keygen -Y
# sign, namespace tmux-revive-release), tags vVERSION, and prints the push and
# `gh release create` commands. It runs neither: publishing stays a deliberate step.
# --dry-run does it all in a throwaway clone and tags nothing.
# --key (or REVIVE_SIGNING_KEY, default ~/.ssh/id_ed25519): the private key's path, only
# ever handed to ssh-keygen; its .pub (or the agent) supplies the public half.
set -euo pipefail
NS=tmux-revive-release
dry=0 out="" key=${REVIVE_SIGNING_KEY:-$HOME/.ssh/id_ed25519} ver=""
die() { printf 'release: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
while (($#)); do
	case $1 in
	--dry-run) dry=1 ;;
	--key) (($# > 1)) || usage; key=$2; shift ;;
	--out) (($# > 1)) || usage; out=$2; shift ;;
	-h | --help) usage ;;
	-*) die "unknown option: $1" ;;
	*) [[ -z $ver ]] || usage; ver=${1#v} ;;
	esac
	shift
done
[[ $ver =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage
ROOT=$(git -C "$(dirname "${BASH_SOURCE[0]}")/.." rev-parse --show-toplevel) || die "not in a git checkout"
cd "$ROOT"

# --------------------------------------------------------------------- checks
[[ $(git symbolic-ref --short -q HEAD) == main ]] || die "not on main"
[[ -z $(git status --porcelain) ]] || die "the tree isn't clean; commit or stash first"
git rev-parse -q --verify "refs/tags/v$ver" >/dev/null && die "tag v$ver already exists"
cur=$(cat VERSION 2>/dev/null) || cur=0.0.0
[[ $(printf '%s\n%s\n' "$cur" "$ver" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1) == "$ver" ]] ||
	die "$ver is older than VERSION ($cur)"
# Its usage text lists -Y sign when it has it (it exits 1 on -?, hence no pipe).
kg=$(ssh-keygen '-?' 2>&1) || :
[[ $kg == *"-Y sign"* ]] || die "needs ssh-keygen with -Y sign (OpenSSH 8.1+)"
[[ -f $key ]] || die "no signing key at $key (--key PATH or REVIVE_SIGNING_KEY)"

T=$(mktemp -d "${TMPDIR:-/tmp}/revive-release.XXXXXX")
trap 'rm -rf "$T"' EXIT
# The public half: the .pub beside the key, else ssh-keygen -y (prints the public key only).
if [[ -f $key.pub ]]; then cp "$key.pub" "$T/key.pub"
else ssh-keygen -y -f "$key" >"$T/key.pub" || die "couldn't read the public key of $key"; fi
signer="$NS namespaces=\"$NS\" $(cut -d' ' -f1,2 "$T/key.pub")"
trusted=1
grep -qxF "ALLOWED_SIGNERS='$signer'" install.sh || trusted=0
if ((!trusted && !dry)); then
	die "install.sh doesn't trust this key, so nobody could install the release. Set its
ALLOWED_SIGNERS line to this, commit it, then rerun:
ALLOWED_SIGNERS='$signer'"
fi

# ---------------------------------------------------------------------- build
if [[ -z $out ]]; then out=$(mktemp -d "${TMPDIR:-/tmp}/tmux-revive-v$ver.XXXXXX")
else
	mkdir -p "$out"
	[[ -z $(ls -A "$out") ]] || die "$out isn't empty"
	out=$(cd "$out" && pwd)
fi
repo=$ROOT
if ((dry)); then
	# A throwaway clone: the VERSION commit and everything else happen there.
	git clone -q "$ROOT" "$T/repo"
	repo=$T/repo
	git -C "$repo" config user.name >/dev/null || git -C "$repo" config user.name "release dry run"
	git -C "$repo" config user.email >/dev/null || git -C "$repo" config user.email "dry-run@localhost"
fi
printf '%s\n' "$ver" >"$repo/VERSION"
if [[ -n $(git -C "$repo" status --porcelain VERSION) ]]; then
	git -C "$repo" add VERSION
	git -C "$repo" commit -q -m "release $ver" -- VERSION
	((dry)) || echo "committed VERSION $ver"
fi
tgz=tmux-revive-$ver.tar.gz
git -C "$repo" archive --format=tar.gz --prefix="tmux-revive-$ver/" -o "$out/$tgz" HEAD
if command -v sha256sum >/dev/null; then (cd "$out" && sha256sum "$tgz" >SHA256SUMS)
else (cd "$out" && shasum -a 256 "$tgz" >SHA256SUMS); fi
ssh-keygen -q -Y sign -f "$key" -n "$NS" "$out/SHA256SUMS" || die "signing failed"
# Check it the way install.sh will, before anything is published.
printf '%s\n' "$signer" >"$T/allowed_signers"
ssh-keygen -Y verify -f "$T/allowed_signers" -I "$NS" -n "$NS" -s "$out/SHA256SUMS.sig" <"$out/SHA256SUMS" >/dev/null 2>&1 ||
	die "the signature didn't verify"
commit=$(git -C "$repo" rev-parse HEAD)

# --------------------------------------------------------------------- report
if ((dry)); then
	echo "dry run: release $ver built from commit $commit (in a throwaway clone; no tag)"
else
	git tag -a "v$ver" -m "tmux-revive $ver" "$commit"
	echo "tagged v$ver at $commit"
fi
cat <<EOF

  $out/$tgz
  $out/SHA256SUMS
  $out/SHA256SUMS.sig

EOF
if ((!trusted)); then
	cat <<EOF
install.sh doesn't trust this key yet. Its allowed-signers line should read:

ALLOWED_SIGNERS='$signer'

EOF
fi
((dry)) && exit 0
cat <<EOF
Nothing is published yet. To publish, run:

  git push origin main v$ver
  gh release create v$ver --verify-tag --title "tmux-revive $ver" --generate-notes \\
    $(printf '%q' "$out/$tgz") $(printf '%q' "$out/SHA256SUMS") $(printf '%q' "$out/SHA256SUMS.sig")
EOF
