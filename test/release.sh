#!/usr/bin/env bash
# Signed releases end to end, offline and in a temp dir: a throwaway key signs
# releases built by scripts/release.sh from a copy of this tree, served from a
# local directory (REVIVE_RELEASE_BASE), installed into a sandbox home. Never
# touches your home, your tmux, your keys or the network.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/revive-release.XXXXXX")
unset TMUX TMUX_PANE SSH_AUTH_SOCK REVIVE_REF REVIVE_VERSION REVIVE_SOURCE REVIVE_REPO REVIVE_SIGNING_KEY
pass=0 fail=0
check() {
	if eval "$2"; then
		printf '  \033[32mpass\033[0m %s\n' "$1"; ((pass++))
	else
		printf '  \033[31mFAIL\033[0m %s\n' "$1"; ((fail++))
	fi
}
cleanup() { [[ -n ${KEEP:-} ]] || rm -rf "$T"; }
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N '' -C revive-test -f "$T/key"
ssh-keygen -q -t ed25519 -N '' -C someone-else -f "$T/other"
signer="tmux-revive-release namespaces=\"tmux-revive-release\" $(cut -d' ' -f1,2 "$T/key.pub")"

# A repo of this tree as it is (uncommitted work too), its installer trusting the test key.
mkdir -p "$T/repo"
(cd "$ROOT" && git ls-files -co --exclude-standard -z | xargs -0 tar cf - 2>/dev/null) | (cd "$T/repo" && tar xf -)
sed -i.bak "s|^ALLOWED_SIGNERS=.*|ALLOWED_SIGNERS='$signer'|" "$T/repo/install.sh" && rm "$T/repo/install.sh.bak"
git -C "$T/repo" init -q -b main
git -C "$T/repo" add -A
git -C "$T/repo" -c user.name=t -c user.email=t@localhost commit -q -m base
REPO_SHA=$(git -C "$T/repo" rev-parse HEAD)

# No server anywhere: the installer finds no tmux to load into.
mkdir -p "$T/ib"
printf '#!/bin/sh\nexit 1\n' >"$T/ib/tmux"
chmod +x "$T/ib/tmux"
H=$T/h APP=$T/h/.local/share/tmux-revive/app
# inst [VAR=VALUE...] CMD...: run CMD in the sandbox home, stdout+stderr to $T/out.
inst() {
	env -u ZDOTDIR HOME="$H" XDG_DATA_HOME="$H/.local/share" XDG_CONFIG_HOME="$H/.config" \
		XDG_STATE_HOME="$H/.local/state" XDG_CACHE_HOME="$H/.cache" TMUX_TMPDIR="$H" CODEX_HOME="$H/.codex" \
		REVIVE_RELEASE_BASE="$T/rel" PATH="$T/ib:$PATH" "$@" >"$T/out" 2>&1
}
fresh() { rm -rf "$H"; mkdir -p "$H"; }
installed() { [[ $(cat "$APP/VERSION" 2>/dev/null) == "$1" ]]; }
said() { grep -qF -- "$1" "$T/out"; }

echo "release.sh"
rel() { bash "$T/repo/scripts/release.sh" "$@" >"$T/out" 2>&1; }
rel --dry-run --key "$T/key" --out "$T/rel/download/v1.0.0" 1.0.0; rc=$?
check "a dry run builds the tarball, SHA256SUMS and its signature" \
	"((rc == 0)) && [[ -s $T/rel/download/v1.0.0/tmux-revive-1.0.0.tar.gz && -s $T/rel/download/v1.0.0/SHA256SUMS && -s $T/rel/download/v1.0.0/SHA256SUMS.sig ]]"
check "and tags nothing, prints no publish commands" "! said 'gh release' && [[ -z \$(git -C $T/repo tag) ]]"
check "a key install.sh already trusts: no line to paste" "! said 'ALLOWED_SIGNERS='"
check "the private key is never printed" "! grep -q 'PRIVATE KEY' $T/out"
rel --dry-run --key "$T/key" --out "$T/rel/download/v1.1.0" 1.1.0
check "a dry run leaves the tree alone" "[[ -z \$(git -C $T/repo status --porcelain) && \$(cat $T/repo/VERSION) == 1.0.0 ]]"
check "the tarball holds the new VERSION" "[[ \$(tar xzOf $T/rel/download/v1.1.0/tmux-revive-1.1.0.tar.gz tmux-revive-1.1.0/VERSION) == 1.1.0 ]]"
mkdir -p "$T/rel/latest" && ln -s ../download/v1.1.0 "$T/rel/latest/download"
rel --dry-run --key "$T/other" --out "$T/o" 1.1.0
check "a dry run with another key prints the line to paste" "said \"ALLOWED_SIGNERS='tmux-revive-release namespaces=\\\"tmux-revive-release\\\" ssh-ed25519 \""
rel --dry-run --key "$T/key" --out "$T/o2" 0.9.0; rc=$?
check "a version older than VERSION is refused" "((rc != 0)) && said 'older than VERSION'"
echo dirt >>"$T/repo/README.md"
rel --dry-run --key "$T/key" --out "$T/o3" 1.1.0; rc=$?
check "a tree that isn't clean is refused" "((rc != 0)) && said 'clean'"
git -C "$T/repo" checkout -q README.md

git clone -q "$T/repo" "$T/maint"
git -C "$T/maint" config user.name t && git -C "$T/maint" config user.email t@localhost
bash "$T/maint/scripts/release.sh" --key "$T/other" --out "$T/o4" 1.2.0 >"$T/out" 2>&1; rc=$?
check "a real release with a key install.sh doesn't trust is refused" "((rc != 0)) && said \"doesn't trust\" && [[ -z \$(git -C $T/maint tag) ]]"
bash "$T/maint/scripts/release.sh" --key "$T/key" --out "$T/o5" 1.2.0 >"$T/out" 2>&1; rc=$?
check "a real release commits VERSION, tags it, prints the push and gh commands" \
	"((rc == 0)) && [[ \$(git -C $T/maint cat-file -t v1.2.0) == tag && \$(git -C $T/maint show v1.2.0:VERSION) == 1.2.0 ]] && said 'git push origin main v1.2.0' && said 'gh release create v1.2.0'"
check "and pushes nothing" "[[ -z \$(git -C $T/repo tag) && \$(git -C $T/repo rev-parse HEAD) == $REPO_SHA ]]"

echo "install"
fresh
inst sh "$T/repo/install.sh" --no-config; rc=$?
check "a good release installs (the latest)" "((rc == 0)) && installed 1.1.0 && said 'signed by the release key'"
check "it says where it came from" "grep -qxF 'release v1.1.0 (signature verified)' $APP/INSTALLED"
inst "$H/.local/bin/tmux-revive" version
check "tmux-revive version prints it" "said 'tmux-revive 1.1.0' && said 'installed from release v1.1.0 (signature verified)'"
check "--no-config reached the release's own installer" "[[ ! -e $H/.tmux.conf && ! -e $H/.config/tmux ]]"
fresh
inst env REVIVE_VERSION=1.0.0 sh "$T/repo/install.sh" --no-config; rc=$?
check "REVIVE_VERSION pins that release" "((rc == 0)) && installed 1.0.0"
inst "$H/.local/bin/tmux-revive" update --no-config; rc=$?
check "update moves to the latest release, saying from and to" "((rc == 0)) && installed 1.1.0 && said '1.0.0 -> 1.1.0'"
inst "$H/.local/bin/tmux-revive" update --version 1.0.0 --no-config; rc=$?
check "update --version goes to that one, even back" "((rc == 0)) && installed 1.0.0 && said '1.1.0 -> 1.0.0'"
inst "$H/.local/bin/tmux-revive" update --no-config
rm "$T/rel/latest/download" && ln -s ../download/v1.0.0 "$T/rel/latest/download"
inst "$H/.local/bin/tmux-revive" update --no-config; rc=$?
check "a 'latest' older than what's installed is refused" "((rc != 0)) && installed 1.1.0 && said 'refusing to go back'"
rm "$T/rel/latest/download" && ln -s ../download/v1.1.0 "$T/rel/latest/download"

# bad NAME: a copy of the good release dir, for NAME's tampering.
bad() { rm -rf "$T/bad"; mkdir -p "$T/bad/download" "$T/bad/latest"; cp -r "$T/rel/download/v1.1.0" "$T/bad/download/"; ln -s ../download/v1.1.0 "$T/bad/latest/download"; B=$T/bad/download/v1.1.0; }
refused() { # refused WHAT EXPECTED-MESSAGE
	fresh
	inst env REVIVE_RELEASE_BASE="$T/bad" sh "$T/repo/install.sh" --no-config; rc=$?
	msg=$2
	check "$1 is refused, nothing installed" "((rc != 0)) && said \"\$msg\" && [[ ! -e $APP && ! -e $H/.local/bin/tmux-revive ]]"
}
bad; printf x >>"$B/tmux-revive-1.1.0.tar.gz"
refused "a tampered tarball" "doesn't match its signed checksum"
bad; printf x >>"$B/tmux-revive-1.1.0.tar.gz"
sed -i.bak "s/^[0-9a-f]*/$(sha256sum "$B/tmux-revive-1.1.0.tar.gz" | cut -d' ' -f1)/" "$B/SHA256SUMS"
refused "a SHA256SUMS changed to match a tampered tarball" "NOT signed by the tmux-revive release key"
bad; rm "$B/SHA256SUMS.sig"
refused "a missing signature" "has no signature"
bad; cp "$T/rel/download/v1.0.0/SHA256SUMS.sig" "$B/SHA256SUMS.sig"
refused "a signature of something else" "NOT signed by the tmux-revive release key"
bad; rm "$B/SHA256SUMS.sig"; ssh-keygen -q -Y sign -f "$T/other" -n tmux-revive-release "$B/SHA256SUMS"
refused "a signature by another key" "NOT signed by the tmux-revive release key"
bad; rm "$B/SHA256SUMS.sig"; ssh-keygen -q -Y sign -f "$T/key" -n file "$B/SHA256SUMS"
refused "the right key signing for another purpose (namespace)" "NOT signed by the tmux-revive release key"
bad; rm -rf "$B"; cp -r "$T/rel/download/v1.0.0" "$B"
fresh
inst env REVIVE_RELEASE_BASE="$T/bad" REVIVE_VERSION=1.1.0 sh "$T/repo/install.sh" --no-config; rc=$?
check "an older signed release passed off as the one pinned is refused" "((rc != 0)) && said 'asked for v1.1.0' && [[ ! -e $APP ]]"

mkdir -p "$T/empty"
fresh
inst env REVIVE_RELEASE_BASE="$T/empty" sh "$T/repo/install.sh" --no-config; rc=$?
check "no release yet: says so, and how to follow main" "((rc != 0)) && said 'no release yet' && said 'REVIVE_REF=main' && [[ ! -e $APP ]]"
inst env REVIVE_VERSION=9.9.9 sh "$T/repo/install.sh" --no-config; rc=$?
check "a pinned version that doesn't exist is refused" "((rc != 0)) && said 'no release v9.9.9' && [[ ! -e $APP ]]"
# Until the maintainer puts the release key in, installs follow main as before, and say so.
sed "s|^ALLOWED_SIGNERS=.*|ALLOWED_SIGNERS='tmux-revive-release namespaces=\"tmux-revive-release\" REPLACE-WITH-THE-RELEASE-PUBLIC-KEY'|" "$ROOT/install.sh" >"$T/nokey-install.sh"
inst sh "$T/nokey-install.sh" --no-config; rc=$?
check "an installer without a release key yet follows main, and says so" "said 'no release key yet: following main'"
inst env REVIVE_VERSION=1.0.0 sh "$T/nokey-install.sh" --no-config; rc=$?
check "but a pinned version needs the key" "((rc != 0)) && said 'needs signed releases'"
fresh
for b in http://example.com/x relative/dir "$T/nope"; do
	inst env REVIVE_RELEASE_BASE="$b" sh "$T/repo/install.sh" --no-config; rc=$?
	check "REVIVE_RELEASE_BASE=$b is refused" "((rc != 0)) && said 'REVIVE_RELEASE_BASE' && [[ ! -e $APP ]]"
done
inst env REVIVE_VERSION=1.0.0 REVIVE_REF=main sh "$T/repo/install.sh" --no-config; rc=$?
check "REVIVE_VERSION with REVIVE_REF is refused" "((rc != 0)) && said 'pick one'"

# ssh-keygen too old for -Y, then none at all.
mkdir -p "$T/old"
printf '#!/bin/sh\necho "ssh-keygen: illegal option -- Y" >&2\necho "usage: ssh-keygen [-q] [-b bits]" >&2\nexit 1\n' >"$T/old/ssh-keygen"
chmod +x "$T/old/ssh-keygen"
inst env PATH="$T/old:$T/ib:$PATH" sh "$T/repo/install.sh" --no-config; rc=$?
check "an ssh-keygen without -Y verify: a clear error" "((rc != 0)) && said 'too old to check signatures' && [[ ! -e $APP ]]"
mkdir -p "$T/nossh"
for d in /usr/bin /bin; do
	for f in "$d"/*; do
		n=${f##*/}
		[[ $n == ssh-keygen || -e $T/nossh/$n || ! -x $f ]] || ln -s "$f" "$T/nossh/$n"
	done
done
inst env PATH="$T/ib:$T/nossh" sh "$T/repo/install.sh" --no-config; rc=$?
check "no ssh-keygen: a clear error" "((rc != 0)) && said 'needs ssh-keygen' && [[ ! -e $APP ]]"

# Following main: a stand-in curl answers GitHub's API with a commit and serves this
# repo's tarball and installer, so the unsigned path runs offline.
echo "follow main"
mkdir -p "$T/fc"
git -C "$T/repo" archive --format=tar.gz --prefix=tmux-revive-main/ -o "$T/main.tgz" HEAD
cat >"$T/fc/curl" <<EOF
#!/bin/sh
url="" o=""
while [ \$# -gt 0 ]; do case \$1 in https://*) url=\$1 ;; -o) o=\$2; shift ;; esac; shift; done
echo "\$url" >>"$T/curl.log"
case \$url in
https://api.github.com/repos/*/commits/main) printf %s $REPO_SHA ;;
https://codeload.github.com/*/tar.gz/$REPO_SHA) cp "$T/main.tgz" "\$o" ;;
https://raw.githubusercontent.com/*/$REPO_SHA/install.sh) cp "$T/repo/install.sh" "\$o" ;;
*) exit 22 ;;
esac
EOF
chmod +x "$T/fc/curl"
fresh
inst env REVIVE_REF=main PATH="$T/fc:$T/ib:$PATH" sh "$T/repo/install.sh" --no-config; rc=$?
check "REVIVE_REF=main still installs main, by commit" \
	"((rc == 0)) && installed 1.0.0 && grep -qx 'https://codeload.github.com/odysseyalive/tmux-revive/tar.gz/$REPO_SHA' $T/curl.log"
check "and records it as unsigned" "grep -qxF 'main at commit $REPO_SHA (not signed)' $APP/INSTALLED"
check "and checks no signature" "! said 'signed by the release key'"
inst env REVIVE_VERSION=1.1.0 sh "$T/repo/install.sh" --no-config
: >"$T/curl.log"
inst env PATH="$T/fc:$T/ib:$PATH" "$H/.local/bin/tmux-revive" update --main --no-config; rc=$?
check "update --main follows main again, from and to shown" \
	"((rc == 0)) && said 'updating from 1.1.0 to main (not signed)' && said '1.1.0 -> 1.0.0, commit $REPO_SHA (not signed)' && grep -q 'raw.githubusercontent.com/.*/$REPO_SHA/install.sh' $T/curl.log"

echo "$pass passed, $fail failed"
((fail == 0))
