# tmux-revive installer for Windows.
#
#   irm https://raw.githubusercontent.com/odysseyalive/tmux-revive/main/install.ps1 | iex
#
# tmux has no native Windows build, so tmux-revive lives where tmux does:
# inside WSL. This script checks WSL is there and runs the Linux installer in
# your default distro. Uninstall: set $env:REVIVE_ARGS = "--uninstall" first.
$ErrorActionPreference = 'Stop'
$repo = if ($env:REVIVE_REPO) { $env:REVIVE_REPO } else { 'odysseyalive/tmux-revive' }
$ref  = if ($env:REVIVE_REF)  { $env:REVIVE_REF }  else { 'main' }
$url  = "https://raw.githubusercontent.com/$repo/$ref/install.sh"

function Say($m)  { Write-Host "==> $m" -ForegroundColor Cyan }
function Fail($m) { Write-Host "xx  $m" -ForegroundColor Red; exit 1 }

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    Fail "WSL is not installed. In an administrator PowerShell run:  wsl --install  then reboot and run this again."
}

# `wsl -l -q` prints UTF-16; strip the NULs before looking at it.
$distros = (wsl.exe -l -q 2>$null) -replace "`0", '' | Where-Object { $_.Trim() }
if (-not $distros) {
    Fail "WSL has no Linux distribution yet. Run:  wsl --install -d Ubuntu  then run this again."
}

Say "installing into WSL ($(($distros | Select-Object -First 1).Trim()))"
# The values go across as environment variables (WSLENV), never pasted into the command, so
# a quote in one can't change what runs. The installer is saved to a file and run only if
# the download worked: a pipe into sh would run a cut-off download and report success.
# The command has no double quotes, which Windows PowerShell 5 mangles on the way to wsl.exe;
# IFS= and set -f keep the unquoted expansions whole, and only REVIVE_ARGS is split.
$cmd = 'set -f; IFS=; f=$(mktemp) || exit 1; trap ''rm -f -- $f'' EXIT; ' +
       'if command -v curl >/dev/null; then curl -fsSL -o $f $REVIVE_URL; else wget -qO $f -- $REVIVE_URL; fi || ' +
       '{ echo download failed: $REVIVE_URL >&2; exit 1; }; IFS='' ''; sh $f $REVIVE_ARGS'
$saved = @{ WSLENV = $env:WSLENV; REVIVE_URL = $env:REVIVE_URL; REVIVE_REPO = $env:REVIVE_REPO; REVIVE_REF = $env:REVIVE_REF; REVIVE_ARGS = $env:REVIVE_ARGS }
try {
    # Only a REVIVE_REF you set goes across: left empty, the installer picks signed releases
    # (or main, until there's a release key) itself.
    $env:REVIVE_URL = $url; $env:REVIVE_REPO = $repo; $env:REVIVE_REF = if ($saved.REVIVE_REF) { $saved.REVIVE_REF } else { '' }
    $env:WSLENV = (@($env:WSLENV, 'REVIVE_URL/u', 'REVIVE_REPO/u', 'REVIVE_REF/u', 'REVIVE_ARGS/u') | Where-Object { $_ }) -join ':'
    wsl.exe -e sh -c $cmd
    $code = $LASTEXITCODE
} finally {
    # irm | iex runs in your own session: put its environment back as it was.
    foreach ($k in $saved.Keys) {
        if ($null -eq $saved[$k]) { Remove-Item "env:$k" -ErrorAction SilentlyContinue } else { Set-Item "env:$k" $saved[$k] }
    }
}
if ($code -ne 0) { Fail "the installer inside WSL failed (exit $code)" }

Write-Host ""
Write-Host "  Windows note: shutting Windows down stops WSL without warning, so the"
Write-Host "  last snapshot is the one taken on detach or within the last minute."
Write-Host "  After a reboot open your WSL terminal and run:  tmux"
