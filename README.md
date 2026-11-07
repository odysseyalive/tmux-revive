# tmux-revive

Detach, shut the machine down, boot, type `tmux`: every session, window, split
and program comes back. Claude Code panes resume **the exact conversation**
they were in, with their Remote Control link restored. Codex, Cursor Agent
and Crush panes resume their exact sessions too.

## Install

Linux, macOS, WSL:

```sh
curl -fsSL https://raw.githubusercontent.com/odysseyalive/tmux-revive/main/install.sh | sh
```

Windows (PowerShell; installs into WSL, since tmux runs there):

```powershell
irm https://raw.githubusercontent.com/odysseyalive/tmux-revive/main/install.ps1 | iex
```

That is the whole setup. The installer downloads a tarball (no git, nothing to
compile), adds one marked block to the tmux config you already use (backing it
up first), fetches a checksummed private `jq` if you have none, and starts
protecting a tmux server that is already running. Rerunning it updates in place.

## Use

1. Work in tmux as usual. Detach (or don't).
2. Shut down.
3. After boot, run `tmux` (or `tmux-revive`, which also attaches when a server
   is already up).

| Key | Does |
| --- | --- |
| prefix + Ctrl-s | save now |
| prefix + Ctrl-r | restore the latest snapshot |
| prefix + Alt-r | show what a restore would bring back |

```
tmux-revive status     what the latest snapshot holds, and the exact resume commands
tmux-revive list       snapshots, newest first
tmux-revive restore 20261106T192239   restore an older snapshot
tmux-revive doctor     check that everything is wired up
tmux-revive uninstall [--purge]
```

## When it saves

- when you detach
- every 60 seconds, but only when something changed (unchanged snapshots are refreshed in place)
- **right before shutdown or suspend** (Linux with systemd): it holds a logind
  *delay* inhibitor, so logind waits while it takes a final snapshot with
  every process still alive. A save takes about 0.1 s; logind allows up to 5 s.
- never while the system is already going down (that would record half-dead panes)

## How it finds the exact Claude Code session

Every running Claude Code process writes `<config dir>/sessions/<pid>.json`
with its session ID, working directory, name and Remote Control bridge.
tmux-revive walks each pane's process tree, matches the pid, and checks the
process start time against the record's, so a stale file left by a crash can
never point at the wrong process. It reads every `~/.claude*` config dir and
puts `CLAUDE_CONFIG_DIR` back when a session used a non-default one.

On restore the pane runs, for example:

```
CLAUDE_CONFIG_DIR=~/.claude-brooke claude --resume 3caeeeb8-… --remote-control oa-work
```

The restore keeps flags like `--model`, `--permission-mode`, `--add-dir` and
`--dangerously-skip-permissions`. It drops a prompt argument, `-p`, and an old
`--continue`/`--resume`, so a restore never re-sends a prompt or forks the
conversation. Commands run through an interactive shell, so your PATH and
version managers apply. When the program exits you land in a shell in the same
directory.

### Other agents

| Agent | Resumes | How the session is found |
| --- | --- | --- |
| Codex | exact thread (`codex resume <id>`) | its log ties the process ID to a thread; else the one thread in that project touched since the process started; else the id it was launched with |
| Cursor Agent | exact chat (`cursor-agent --resume <id>`) | the chat `store.db` the process holds open |
| Crush | exact session (`crush --session <id>`) | the one session in that project touched since the process started; else `--session` from its command line |
| Gemini | latest session in that project | Gemini can't resume by ID |

When two instances of the same agent share a project and nothing pins one
to its session, tmux-revive won't guess. That pane reopens the agent's
picker (Codex, Cursor) or its most recent session (Crush), and
`tmux-revive status` marks it "best guess". Reading Codex and Crush state
needs `sqlite3`; without it those panes fall back the same way.

Other programs: `vim nvim man less tail top htop btop watch ssh mosh journalctl
lazygit lazydocker yazi ranger k9s` are relaunched with their arguments. nvim
and vim use `Session.vim` when one exists. Shell panes get their scrollback back.

## Options

```tmux
set -g @revive-interval 60          # seconds between saves, 0 = only detach/shutdown
set -g @revive-auto-restore on      # restore when a fresh server starts
set -g @revive-shutdown-hook on     # final save before shutdown/sleep
set -g @revive-claude-remote-control on
set -g @revive-programs 'vim nvim less htop'   # or ':all:'
set -g @revive-scrollback 2000      # lines per shell pane, 0 = off
set -g @revive-keep 30              # snapshots kept
set -g @revive-save-key C-s         # 'none' to unbind
set -g @revive-restore-key C-r
set -g @revive-status-key M-r
set -g @revive-dir '~/.local/share/tmux-revive'
set -g @revive-claude-dirs '~/work/.claude'   # extra Claude config dirs
```

Put these before the tmux-revive block in your config.

## Notes

- Auto-restore only runs on a server less than a minute old. It replaces only
  the default-numbered empty session a bare `tmux` creates, never one you
  named, and it skips sessions that already exist. Reloading your config never
  restores twice.
- macOS needs a current bash (the installer gets it from Homebrew). There is
  no shutdown hook on macOS, so saves come from detach and the interval.
- Windows: shutting Windows down stops WSL without notice, so the last snapshot
  is from your detach or the last interval.
- If tmux-continuum is also set to auto-restore, turn one of them off.

## Test

```sh
bash test/e2e.sh   # private tmux server, fake Claude process, simulated reboot
```
