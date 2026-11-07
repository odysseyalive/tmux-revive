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
$extra = if ($env:REVIVE_ARGS) { $env:REVIVE_ARGS } else { '' }
$cmd = "if command -v curl >/dev/null; then curl -fsSL '$url'; else wget -qO- '$url'; fi | REVIVE_REPO='$repo' REVIVE_REF='$ref' sh -s -- $extra"
wsl.exe -e sh -c $cmd
if ($LASTEXITCODE -ne 0) { Fail "the installer inside WSL failed (exit $LASTEXITCODE)" }

Write-Host ""
Write-Host "  Windows note: shutting Windows down stops WSL without warning, so the"
Write-Host "  last snapshot is the one taken on detach or within the last minute."
Write-Host "  After a reboot open your WSL terminal and run:  tmux"
