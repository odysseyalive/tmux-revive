![tmux-revive: terminal panes lighting back up, with messages flying between them and out to another computer](assets/header.png)

# tmux-revive

Here's the whole idea. You turn your computer off, turn it back on, type
`tmux`, and everything is right where you left it. Every session, every
window and split, and the programs that were running in them. Your AI coding
agents pick up **the exact conversation** they were in, too. That covers
Claude Code (Remote Control link and all), Codex, Cursor Agent and Crush.

It also comes with a little extra called `agent-say`. It lets those agents
send each other messages, even across accounts and across computers. More on
that in [Agents talking to each other](#agents-talking-to-each-other).

## Install

On Linux, macOS or WSL:

```sh
curl -fsSL https://raw.githubusercontent.com/odysseyalive/tmux-revive/main/install.sh | sh
```

On Windows, use PowerShell. It installs into WSL, since that's where tmux
actually runs:

```powershell
irm https://raw.githubusercontent.com/odysseyalive/tmux-revive/main/install.ps1 | iex
```

And that's it. That's the setup. If tmux is already running, it's protected
from that moment on. When you want the newest version later, run
`tmux-revive update`. (Curious what the installer touches on your computer?
It's all listed [further down](#what-the-installer-changes).)

## Everyday use

Honestly, there's nothing new to learn.

1. **Work in tmux the way you always do.**
2. **Leave the way you always do.** Detach with prefix + d, or just close the
   terminal window. Your work is saved.
3. **Shut down or restart** whenever you feel like it.
4. **Come back.** Open a terminal and type `tmux` or `tmux attach`.
   Everything reopens, and your agents carry on with their conversations.

**Rather start with a clean slate?** Then close things yourself. Type `exit`
in a pane, close a window, or close a session. tmux-revive remembers that you
closed them, and they stay closed. Close everything and the next `tmux` starts
empty. And if you closed something by mistake, don't panic. Every earlier save
is kept (see below).

### Handy commands

```
tmux-revive status     what would come back right now, pane by pane
tmux-revive list       every save, newest first
tmux-revive restore 20261106T192239   bring back an older save
tmux-revive doctor     check that everything is working
tmux-revive update     install the latest version (your saves are kept)
tmux-revive uninstall  remove it (add --purge to also delete your saves)
```

## When it saves

You never have to save by hand. It takes care of that:

- when you detach or close your terminal
- when you close a pane, window or session, so what you closed stays closed
- every minute, if anything changed
- **right before your computer shuts down or goes to sleep** (Linux), while
  every program is still running

What it will never do is save while the computer is in the middle of shutting
down. By then programs are being killed off, and the save would be missing
them.

## Agents talking to each other

`agent-say` lets an AI agent in one tmux pane send a message to an agent in
another pane. Claude Code can ask Codex to review its work, say, and Codex's
answer comes back to Claude Code. The message gets typed into the other pane
as if you'd typed it yourself, so any agent can read it. There's nothing else
to run. No server, no plugin.

### 1. Give each pane a name

You only do this once per pane. In Claude Code, type this into its prompt
(the `!` runs it as a command):

```
! agent-say name claude
```

Or just ask the agent: "name this pane claude with agent-say". That works in
Codex too.

That one name actually does three things:

- **The pane** gets the name, so other agents can send it messages. The name
  belongs to the pane, not the agent, so it sticks around when you restart the
  agent there.
- **The tmux window** gets renamed too, so you can spot it in your status bar.
  This part is skipped when the window is split between several panes.
- **The agent's own session** is renamed with its `/rename` command. That's
  the name you see when resuming and in Remote Control. Here's the catch. The
  agent is busy running the naming command at that very moment, so `agent-say`
  waits until it has finished and is waiting on you (up to 30 minutes), then
  types `/rename` for it. It never types into a question the agent is asking
  you, or into a prompt where you've already started typing.

| Agent | Session renamed? |
| --- | --- |
| Claude Code | yes |
| Codex | yes |
| Cursor Agent | yes |
| Crush, Gemini | no, they have no rename command; only the pane and window are named |

**Already named your session?** Run `agent-say name` with no name, and the
pane borrows the name the session already has (Claude Code and Codex).

**Codex** is a little different. It runs its commands outside its own pane,
so `agent-say` goes looking for the Codex pane working in the same folder. If
two Codex panes are working in the same folder, it can't tell them apart. In
that case, name the pane in the terminal before you start Codex:

```sh
agent-say name codex
codex
```

`agent-say list` shows every pane and its name.

A name can use letters, digits and `. _ - : + =`. It has to start with a
letter or digit, and it can't have spaces or `@`. It also can't be one of
agent-say's own words, which are `name`, `list`, `read`, `show`, `link` and
`unlink`.

### 2. Ask your agent to send a message

Just say it in plain words, the way you'd ask a person:

> Use agent-say to ask codex to review parser.py and tell you what breaks.

The agent runs `agent-say codex "review parser.py ..."`. The other agent sees
the message, along with the exact command it should use to answer:

```
[agent-msg from=claude 04:24Z] review parser.py and tell me what breaks -- To answer, run the shell command: agent-say --from codex claude "<your reply>"
```

### 3. The answer comes back by itself

The other agent does the work and answers. Its reply shows up in the first
pane as a new message, and the first agent carries on. You just sit back and
watch.

Long messages show up as a short note with an ID. The agent reads the whole
thing with `agent-say show <id>`.

### Another computer you ssh into

Picture two terminals. One is in tmux on your own computer. In the other, you
ssh into a server and run tmux there. Claude Code or Codex is running in each.
You link them once, from **your own computer**, using the same name you'd type
after `ssh`:

```sh
agent-say link devbox
```

From then on, agents on either side reach each other by the names you gave
their panes, as if they were all on one computer:

```sh
agent-say codex "run the tests on the server and tell me what fails"   # here -> there
agent-say claude "all green"                                           # there -> here
```

Replies find their own way back. If the same name exists on both computers,
add `@` and the computer to pick one, like `codex@devbox` or
`claude@<your computer>`. `agent-say list` shows the names on both sides.

So how does it work? Your computer checks in with the server over ssh every
couple of seconds, in the same direction you already connect. Each check-in
swaps the pane names on both sides and brings back anything the server's
agents sent you. Your computer never has to accept a connection. That means
it works from behind a home router, or on a laptop with no ssh server at all.

What it needs:

- `agent-say` on the server. Run the installer there too.
- ssh that logs in without asking for a password (key-based login). You can
  test that with `ssh -o BatchMode=yes devbox true`.

`agent-say link` shows your links and whether they're running.
`agent-say unlink devbox` stops one. Links come back on their own when tmux
starts after a reboot.

**The other side says a name doesn't exist?** The server only learns your
computer's names through the link, and the link has to be started from your
computer. Run `agent-say link` here, and `devbox` should be listed as running.
After that, `agent-say list` on the server shows your names with `@` and your
computer's name.

Here's what happens to messages over a link:

- **Someone is typing in the pane a message is for.** It waits, and the link
  tries again at each check-in for about a minute. Each message is delivered
  once.
- **The link goes down** (your computer is off or asleep, or tmux isn't
  running). Messages already waiting on the server are delivered when the
  link comes back. Once your computer has missed check-ins for about a minute,
  the server stops taking new ones. A send from there fails with an error, so
  the agent knows it didn't arrive.
- **You unlink.** The server is told, if it can be reached, and the messages
  it was still holding for you go into its mailbox, marked NOT DELIVERED.
- **A message shows up for a name your computer doesn't have.** It goes into
  your mailbox, marked NOT DELIVERED.
- **Nothing that arrives over a link can run a command on your computer.**
  Every name, sender and address from the other side is checked, and a message
  can only be typed into an agent pane by its name.

You can also send to a server you haven't linked, with `agent-say
codex@devbox "..."`. That's fine for a one-off message, but a reply then needs
the server to be able to ssh back to you.

Different accounts on one computer don't need anything special. Each agent
keeps its own login. They just need to be in the same tmux.

### Built-in safety

`agent-say` won't type a message anywhere it could do harm. It refuses, and
tells you why, when:

- **the pane has no agent running**, just a command prompt. The message would
  be run as a command there.
- **the pane is scrolled back** (tmux copy mode). The message would get lost.
  It waits 10 seconds for you to scroll back down first.
- **two panes share a name.** It has no way of knowing which one you meant.
  Rename one, or send to a pane ID like `%3` from `agent-say list`.

Messages to the same pane wait their turn, so two can't get mixed into one.
If a sender crashes partway through, the next message cleans up what it left
behind.

A few things worth keeping in mind:

- **Anything that can run `agent-say` can type into your agents.** I'd treat
  it like access to your terminal, because that's more or less what it is.
  Agents are told to treat these messages as coming from a colleague, not from
  you, and to check with you before anything risky.
- **Two agents that answer everything can chat forever.** Really. Say when no
  reply is needed.
- **Your drafts are safe in Claude Code and Codex.** If you've started typing
  in an agent's prompt, a message waits for you to send or clear it (up to a
  minute, then it's refused) instead of landing on top of your text. A
  `/rename` waits the same way. In other agents `agent-say` can't see the
  prompt, so a message typed while you're typing there can still get mixed in.

Every message is also kept in `~/.local/state/agent-say/mailbox.md`, which
only you can read. `agent-say read 5` shows the last five, and
`agent-say read 5 claude` shows the last five sent to `claude`. Once the
mailbox passes 1 MB, it moves to `mailbox.md.1` and a fresh one starts.

**Settings** (environment variables): `AGENT_SAY_ENTER_DELAY` (0.4 seconds
between typing a message and pressing Enter; raise it if a busy agent leaves
a message unsent), `AGENT_SAY_INLINE_MAX` (300 characters before a message
counts as long), `AGENT_SAY_MODE_WAIT` (10 seconds), `AGENT_SAY_RENAME_WAIT` (1800 seconds), `AGENT_SAY_TYPING_WAIT` (60 seconds), `AGENT_SAY_LINK_INTERVAL` (2 seconds), `AGENT_SAY_MAILBOX`,
`AGENT_SAY_MAILBOX_MAX`, `AGENT_SAY_SSH`, `AGENT_SAY_REMOTE_CMD`,
`AGENT_SAY_HOST`.

## Options

These are optional settings for your tmux config. Put them **before** the
tmux-revive block in that file.

```tmux
set -g @revive-interval 60          # seconds between saves, 0 = only detach/shutdown
set -g @revive-auto-restore on      # reopen everything when tmux starts fresh
set -g @revive-shutdown-hook on     # final save before shutdown/sleep
set -g @revive-claude-remote-control on
set -g @revive-programs 'vim nvim less htop'   # programs to reopen, or ':all:'
set -g @revive-scrollback 2000      # lines of history kept per shell pane, 0 = off
set -g @revive-keep 30              # how many saves to keep
set -g @revive-save-key C-s         # optional keys; none are set by default
set -g @revive-restore-key C-r
set -g @revive-status-key M-r
set -g @revive-dir '~/.local/share/tmux-revive'
set -g @revive-claude-dirs '~/work/.claude'   # extra Claude config dirs
```

## Good to know

- **`tmux kill-server` doesn't count as closing things.** As far as tmux can
  tell, it looks just like the computer shutting down, so everything comes
  back next time. If you want to start fresh, close your sessions instead.
- **Reloading your tmux config** never reopens things a second time. Reopening
  only happens when tmux has just started. It never replaces a session you
  named, and it skips sessions that are already open.
- **macOS** needs a newer bash, and the installer gets it from Homebrew. macOS
  also gives no warning before shutdown, so the last save is from your last
  detach, or at most a minute old.
- **Windows** stops WSL without warning when it shuts down, so the same goes
  for Windows.
- **tmux-continuum:** if it's also set to restore automatically, turn one of
  the two off.

## Under the hood

### Finding the exact Claude Code conversation

Every running Claude Code process writes `<config dir>/sessions/<pid>.json`
with its session ID, working directory, name and Remote Control link.
tmux-revive walks each pane's processes and matches them to those files. It
checks the process start time too, so a file left behind by a crash can never
point at the wrong process. It reads every `~/.claude*` config dir, and it
sets `CLAUDE_CONFIG_DIR` again when a session used a non-default one.

When it reopens, the pane runs something like this:

```
CLAUDE_CONFIG_DIR=~/.claude-brooke claude --resume 3caeeeb8-… --remote-control oa-work
```

It keeps flags like `--model`, `--permission-mode`, `--add-dir` and
`--dangerously-skip-permissions`. It drops a prompt, `-p`, and an old
`--continue`/`--resume`, so reopening never sends a prompt twice or splits the
conversation in two. Commands run through your normal shell setup, so your
PATH and version managers still apply. When the program exits, you're left in
a shell in the same folder.

### Other agents and programs

| Agent | Reopens | How the session is found |
| --- | --- | --- |
| Codex | exact thread (`codex resume <id>`) | its log ties the process to a thread; else the one thread in that project touched since the process started; else the ID it was launched with |
| Cursor Agent | exact chat (`cursor-agent --resume <id>`) | the chat `store.db` the process holds open |
| Crush | exact session (`crush --session <id>`) | the one session in that project touched since the process started; else `--session` from its command line |
| Gemini | latest session in that project | Gemini can't reopen a session by ID |

Sometimes two copies of the same agent are working in the same project, and
nothing ties one of them to its session. tmux-revive won't guess. That pane
opens the agent's session picker (Codex, Cursor) or its most recent session
(Crush), and `tmux-revive status` marks it "best guess". Codex and Crush need
`sqlite3` installed for this. Without it, they fall back the same way.

These programs reopen with their arguments: `vim nvim man less tail top htop
btop watch ssh mosh journalctl lazygit lazydocker yazi ranger k9s`. vim and
nvim use `Session.vim` when there is one. Plain shell panes get their recent
history back.

### Saving on shutdown and on close

On Linux with systemd, tmux-revive asks the system to wait a moment before
shutdown or sleep (a logind *delay* inhibitor). A save takes about 0.1 s, and
the system allows up to 5 s. Plenty of room.

tmux normally quits the instant its last session closes, before it can tell
anyone. That's a problem if you want to notice that someone closed
everything. So tmux-revive turns tmux's `exit-empty` option off, saves an
empty snapshot, then quits tmux itself. If you had already turned
`exit-empty` off, tmux keeps running, just as you set it.

### What the installer changes

- One marked block in your tmux config, and a few lines in `~/.bashrc` /
  `~/.zshrc` so `tmux attach` reopens everything after a restart.
- A private copy of `jq` (checksummed) if you don't already have one.
- **Claude Code:** each `~/.claude*` config dir that has run Claude gets
  `Bash(agent-say:*)` in its `settings.json`, so sending doesn't ask for
  permission. It also gets a short note in its `CLAUDE.md` explaining what
  `[agent-msg …]` messages are.
- **Codex:** `~/.codex/rules/agent-say.rules` lets only `agent-say` out of
  Codex's sandbox. Without it, the sandbox blocks tmux with "Operation not
  permitted". The same note goes in `~/.codex/AGENTS.md`, telling Codex to
  sign its messages `--from codex`. Restart any Codex session that was already
  open.

Every file is backed up before its first change (`*.bak-revive-<time>`). A
`settings.json` that isn't valid JSON is left alone, with a warning.
`tmux-revive update` and `uninstall` keep all of this in step, and the
installer's `--no-config` option skips it.

## Test

```sh
bash test/e2e.sh        # private tmux server, fake agents, simulated reboot
bash test/agent-say.sh  # agent-say delivery, names and refusals, on a private server
```
