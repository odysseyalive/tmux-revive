# tmux-revive

Detach, shut the machine down, boot, type `tmux`: every session, window, split
and program comes back. Claude Code panes resume **the exact conversation**
they were in, with their Remote Control link restored. Codex, Cursor Agent
and Crush panes resume their exact sessions too.

It also ships `agent-say`, which lets those agents message each other across
panes, accounts and machines. See [Agents talking to each other](#agents-talking-to-each-other).

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
protecting a tmux server that is already running. It also lets Claude Code
and Codex use [`agent-say`](#agents-talking-to-each-other). Rerunning it, or
running `tmux-revive update`, updates in place.

## Use

1. Work in tmux as usual. Detach the usual way: prefix + d, or just close the
   terminal. That saves.
2. Shut down.
3. After boot, open a terminal and run `tmux` or `tmux attach`. Everything is
   back, Claude Code included, in the conversation it was in.

There are no keys to press and nothing to run. The installer adds a few lines
to your `~/.bashrc` / `~/.zshrc` so `tmux attach` (`tmux a`) restores before
it attaches when no server is running yet; a bare `tmux` restores on its own.

```
tmux-revive status     what the latest snapshot holds, and the exact resume commands
tmux-revive list       snapshots, newest first
tmux-revive restore 20261106T192239   restore an older snapshot
tmux-revive doctor     check that everything is wired up
tmux-revive update     install the latest version (snapshots are kept)
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

## Agents talking to each other

`agent-say` lets Claude Code, Codex, or any agent in a tmux pane send a
message to any other. It works when the two are logged into different
accounts, and it works with an agent on another machine over ssh. There's no
Remote Control, no server and no MCP. A message is typed into the other pane
the way you would type it, so the agent there reads it like any other prompt.

```sh
agent-say name claude      # once per pane: give it a name (before or after starting the agent)
agent-say codex "review parser.py and tell me what breaks"
agent-say list             # panes and their names
agent-say read 5 claude    # the last 5 messages sent to claude
```

The receiving agent sees one line, including the exact command to answer with:

```
[agent-msg from=claude 04:24Z] review parser.py and tell me what breaks -- To answer, run the shell command: agent-say --from codex claude "<your reply>"
```

Every message is also saved in a mailbox file
(`~/.local/state/agent-say/mailbox.md`). Long or multi-line messages
(`agent-say codex - < notes.md`) show up in the pane as a one-line notice
pointing at the mailbox. Sends to the same pane take turns, so two messages
sent at once can't run together into one prompt.

The installer sets up both agents, and `tmux-revive update` and `uninstall`
keep that setup in step. `--no-config` skips it. Restart any Codex session
that was already open.

- **Claude Code:** every Claude config dir (`~/.claude*` that has run Claude)
  gets `Bash(agent-say:*)` in its `settings.json` allow list, so sending
  doesn't prompt.
- **Codex:** its sandbox blocks the tmux socket ("Operation not permitted").
  `~/.codex/rules/agent-say.rules` is a
  [rule](https://developers.openai.com/codex/rules) that lets only
  `agent-say` run outside the sandbox. A marked block in `~/.codex/AGENTS.md`
  tells Codex what `[agent-msg …]` lines are. Without it, Codex tends to
  answer in its own pane, where the sender never sees the reply.

Files are backed up before their first change (`*.bak-revive-<time>`). A
`settings.json` that isn't valid JSON is left alone with a warning.

Codex runs its commands in a shared background process that isn't inside any
pane, so it can't work out which pane it's in. Replies already contain the
right `--from`. When Codex starts a conversation itself, it passes
`--from codex`, as its `AGENTS.md` block says to.

**Different accounts:** the two agents only need to run on the same tmux
server. Each keeps its own login (`CLAUDE_CONFIG_DIR`, Codex auth, and so on).

**Over ssh:** `agent-say codex@devbox "..."` runs `agent-say` on `devbox`
over ssh (key auth, no password prompt) and sends the message as data, so
quotes and `$(...)` arrive unchanged. `devbox` needs `agent-say` in
`~/.local/bin` or on its PATH; running the installer there does that. Replies
come back to `claude@yourhost`, which only works if `devbox` can ssh back to
you. If it can't, ssh into one machine and run both agents in its tmux, which
needs no ssh setup at all.

Be careful with two things. Anything that can run `agent-say` can type into
your agents, so treat it like shell access. And two agents that answer every
message will keep going forever, so say when no reply is needed. Settings:
`AGENT_SAY_ENTER_DELAY` (0.4 s between typing and Enter; raise it if a busy
agent leaves a message unsent), `AGENT_SAY_INLINE_MAX` (300 characters),
`AGENT_SAY_MAILBOX`, `AGENT_SAY_SSH`, `AGENT_SAY_REMOTE_CMD`, `AGENT_SAY_HOST`.

## Options

```tmux
set -g @revive-interval 60          # seconds between saves, 0 = only detach/shutdown
set -g @revive-auto-restore on      # restore when a fresh server starts
set -g @revive-shutdown-hook on     # final save before shutdown/sleep
set -g @revive-claude-remote-control on
set -g @revive-programs 'vim nvim less htop'   # or ':all:'
set -g @revive-scrollback 2000      # lines per shell pane, 0 = off
set -g @revive-keep 30              # snapshots kept
set -g @revive-save-key C-s         # optional keys; none are bound by default
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
