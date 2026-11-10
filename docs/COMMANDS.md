# tmux-revive reference

Everything tmux-revive and `agent-say` can do, all in one place. For the quick
start, see the [README](../README.md).

## Contents

- [Install](#install)
- [Everyday use](#everyday-use)
- [tmux-revive commands](#tmux-revive-commands)
- [Control panel](#control-panel)
- [agent-say: agents talking to each other](#agent-say-agents-talking-to-each-other)
- [Linking computers](#linking-computers)
- [Settings](#settings)
- [Environment variables](#environment-variables)
- [Releases and signing](#releases-and-signing)
- [Uninstall](#uninstall)
- [Troubleshooting](#troubleshooting)

## Install

On Linux, macOS or WSL:

```sh
curl -fsSL https://raw.githubusercontent.com/odysseyalive/tmux-revive/main/install.sh | sh
```

On Windows, in PowerShell (it installs into WSL, since tmux has no native Windows
build):

```powershell
irm https://raw.githubusercontent.com/odysseyalive/tmux-revive/main/install.ps1 | iex
```

If tmux is already running, it's protected from now on. The installer backs up
every file before it touches it, and `tmux-revive uninstall` undoes all of it.

tmux-revive needs tmux 3.2 or newer. The installer checks for it before it
downloads anything. If tmux is missing or too old, it stops and prints the
command that installs tmux on your system, such as `sudo apt install tmux` on
Ubuntu or `brew install tmux` on macOS. Run that, then run the installer again.

Installer options go after `sh -s --`:

| Option | What it does |
|---|---|
| `--uninstall` | remove tmux-revive |
| `--purge` | uninstall and delete your saves too |
| `--no-config` | don't touch tmux.conf, shell rc files, or Claude Code / Codex settings |

For example:

```sh
curl -fsSL https://raw.githubusercontent.com/odysseyalive/tmux-revive/main/install.sh | sh -s -- --no-config
```

On Windows, set `$env:REVIVE_ARGS = "--uninstall"` before running the PowerShell line
to uninstall.

You can also load it from tmux.conf yourself:

```tmux
run-shell ~/.local/share/tmux-revive/revive.tmux
```

or with TPM: `set -g @plugin 'odysseyalive/tmux-revive'`.

## Everyday use

There's nothing new to learn. Work in tmux the way you always have, detach or
close the terminal, shut down, and when you come back, type `tmux`. Everything
reopens: sessions, windows, splits, the programs running in them, and your AI
agents in the exact conversation they were in. That covers Claude Code (Remote
Control link and all), Codex, Cursor Agent and Crush.

The installer adds a small `tmux` wrapper to your shell. A bare `tmux` outside
tmux, and `tmux attach`, go to `tmux-revive open`. Every other tmux command
passes straight through.

With one session, `tmux` attaches it. With several, it lists them first. Pick one
with the arrows or its number and press Enter, or press `n` for a new one. `x`
closes the highlighted session (Space marks several), and `a` closes all the
others and carries on in this one. A session with an agent running in it asks you
to type `yes`, since closing it ends that conversation.

It saves on its own when you detach or close something, every minute if
anything changed, and on Linux right before shutdown or sleep.

Want a clean slate? Close the panes, windows or sessions yourself. What you
close stays closed.

## tmux-revive commands

| Command | What it does |
|---|---|
| `tmux-revive` | start tmux, restore, and attach |
| `tmux-revive open [attach ARGS]` | the same, with a pick list when there are several sessions |
| `tmux-revive start` | start tmux and restore, without attaching |
| `tmux-revive save` | save right now |
| `tmux-revive restore [SNAPSHOT]` | restore the latest save, or a named one |
| `tmux-revive status [SNAPSHOT]` | what a restore would bring back right now |
| `tmux-revive panel` | the live control panel |
| `tmux-revive list` | every save, newest first |
| `tmux-revive log` | recent activity |
| `tmux-revive doctor` | check that everything is working |
| `tmux-revive update` | install the latest signed release (your saves are kept) |
| `tmux-revive update --version X` | install signed release X |
| `tmux-revive update --main` | follow `main` instead (not signed) |
| `tmux-revive version` | what's installed and where it came from |
| `tmux-revive uninstall [--purge]` | remove it (`--purge` also deletes your saves) |

Bring back an older save by using a name from `list`:

```sh
tmux-revive restore 20261106T192239
```

`update` shows the version it moves from and to, and checks the new release
against the key in the copy you already have. Going back to an older version is
allowed only with `--version`.

## Control panel

```sh
tmux-revive panel
```

Run it inside tmux. To open it with a key instead, see `@revive-panel-key` under
[Settings](#settings).

Remember the old BBS screens? This is a live one for every pane. It shows
what's running in each, and whether each AI agent is working, waiting on you,
or stuck on a question before it can go on. CPU, memory and git status are
there too, along with recent agent messages, links and saves. Every time it
opens, one of five pieces of old-school ANSI art fills whatever space is left
over, sized to your pane.

Each pane is numbered the way tmux's status bar numbers it, window then pane:
`[3.1]` is pane 1 in window 3.

**USER** is the user working in the pane, and **VER** the tmux-revive that user
has, in yellow when it's older than yours. `[V]` means they don't have it yet.
A linked computer on tmux-revive 1.2.4 or older can't say who's working in its
panes, so all its rows show `[V]`. Press **V** there to update it over ssh.

**CTX LEFT** shows how much of each agent's context window is still free. It goes
green, then yellow at 40%, then red at 15%. It reads Claude Code's and Codex's own
session records, and other agents show a dash. Claude Code doesn't record its
window size, so the panel assumes a million tokens for models that have one and
200k otherwise. Set `REVIVE_CLAUDE_WINDOW` to override it.

Claude Code also reports its own context left after each tool call and each turn,
through a hook the installer adds (more on that under agent-say below). The panel
trusts that report first, so CTX LEFT works even when the panel can't read the
session's files, like on a server where you link in as one user and the agents run
as root. A report older than 10 minutes is ignored (`REVIVE_CTX_TTL`, in seconds).

### Keys

| Key | What it does |
|---|---|
| Up / Down | pick a pane (the list wraps around), or scroll the window you tabbed to |
| PgUp / PgDn, Home / End | a page at a time, or to the top or bottom |
| Tab (Shift-Tab) | move to the next window (or back): PANES, PEEK, MESSAGES, LINKS · SAVES |
| `0`-`9` | go to that window's first pane |
| `J` | jump to the pane on this computer (when the panel is a popup, it closes) |
| `M` | message the pane's agent |
| `N` | name the pane |
| `P` | show or hide a quick peek at its screen |
| `X` | spread the peek over the artwork too |
| `C` | put the artwork back |
| Enter | answer the question the selected agent is asking, or fold a linked computer's heading |
| `L` | link a computer you ssh into |
| `U` (or `D`) | unlink a computer |
| `V` | update tmux-revive on a linked computer, or copy the install or update command for another user's pane |
| `G` | grant access: agents on linked computers waiting to talk, and the ones you approved |
| `A` | swap the artwork |
| `S` | save right now |
| `?` | the help page |
| `Q` | quit |

### Scrolling

When a window has more than fits, a scroll bar shows on its right edge. Press
**Tab** to move to that window (its title lights up), then scroll it with the
arrows, PgUp and PgDn. In PANES the arrows still pick a pane, and the list
follows. If something that needs you is scrolled out of view, like a question or
an access request, the arrow on that side blinks yellow.

PANES takes about half the screen at most, so the peek always has room.

On a linked computer's heading, **Enter** folds its panes into that one line,
which still says how many need you. Press Enter again to open it. Folds are
remembered for next time.

### Answering questions

When the selected agent is asking a question, the peek shows the question instead.
Press **Enter** to answer it right there. Your keys go to the agent as if you were
in its pane, typed answers included, until it has its answer or you press
**Ctrl-]**. For a real chat with the agent, **J** takes you to its pane.

You don't need the panel open to hear about questions. When any agent starts
asking one, tmux shows a message naming the pane and rings the bell, once per
question. See `@revive-question-alert` and `@revive-question-bell` to turn these
off.

### Linked computers in the panel

When a pane ssh's into another computer, the panel spots it and offers to link the
agents there. **L** links it and **U** unlinks it. Linking is one yes or no. The
panel finds the key ssh uses for that computer (your known_hosts, or the ssh
connection you have open to it) and shows it, and pops up a box for the password
if the server takes one. If the key isn't in your known_hosts, you haven't
confirmed it yet, so No comes first. A link that stops working shows why in LINKS,
and **L** on it tries it once more. **L** on a working link links it again or
unlinks it.

Once linked, that computer's panes show up in the list too, grouped under its
name, with their USER and VER. Select one of your panes there and press **V** to
update tmux-revive over ssh, once you say yes. On another user's pane there, **V**
gives you the command to run in it (see Several users in one tmux). **N** names one of its panes over ssh.

**J** is faded on its panes. Nothing there moves your focus, here or in tmux over
there, so a question on that computer can't pull you away from what you're doing.

## agent-say: agents talking to each other

`agent-say` lets an agent in one tmux pane send a message to an agent in another
pane, and the answer finds its way back on its own. It works across accounts, and
across different AI interfaces like Claude Code and Codex.

First, give each pane a name. You only do this once. Press **N** in the panel,
or in Claude Code, type this into its prompt:

```
! agent-say name shop-dev
```

Pick a name that won't get mixed up with what the agents are talking about.
Send a message to `api` or `tests` and it reads like just another topic in
the conversation, and `claude` could be any Claude pane at all. The project
plus the pane's job, so `shop-dev` or `shop-review`, keeps things clear.

Then just ask your agent in plain words:

> Use agent-say to ask shop-review to review parser.py and tell you what breaks.

### Commands

| Command | What it does |
|---|---|
| `agent-say name [name]` | name this pane. It also renames its window and the agent's session (Claude Code, Codex, Cursor). With no name, it uses the agent session's own name |
| `agent-say list` | every pane and its name |
| `agent-say <to> <message...>` | send. `<to>` is a name, a `%pane-id`, or `name@ssh-host` |
| `agent-say <to> -` | send the message read from stdin |
| `agent-say show <id>` | one message, by the id its notice gave |
| `agent-say read [n] [name]` | the last n mailbox entries (default 20), optionally only those to `name` |
| `agent-say link [ssh-host]` | link to tmux on a computer you ssh into. No host: list your links |
| `agent-say unlink <ssh-host>` | stop that link |
| `agent-say intros` | introductions waiting, and the permissions you gave |
| `agent-say revoke <sender> <recipient>` | take back a permission (as `intros` shows it) |

`--from <label>`, before `<to>`, overrides the sender label.

Read the last five messages:

```sh
agent-say read 5
```

Only a pane with an agent running in it gets typed into, and not while it's
scrolled back in copy mode. Every message is also written to the mailbox
(`~/.local/state/agent-say/mailbox.md`), so long text is read from there and
nothing gets lost.

A word of caution. Anything that can run `agent-say` can type into your
agents, so treat it the way you'd treat access to your terminal.

Claude Code has its own SendMessage and ListAgents, but they only reach Claude
sessions on the same computer, so left alone its agents never think to try
`agent-say`. The installer fixes that with a small hook in Claude Code's
`settings.json` (`~/.claude`, or `CLAUDE_CONFIG_DIR`, and root's too when
installed as root). When a Claude Code session starts in a tmux pane, the hook
tells it the pane's name, the `agent-say` commands, and that a first message to
another server waits for your OK in the panel. Outside tmux it says nothing.

The same hook also reports the session's context left after each tool call and
each turn, for the panel's CTX LEFT. `--no-config` skips it, uninstall takes it
out, and `tmux-revive doctor` shows whether it's there.

Sessions started as another user, like root after `sudo -i`, get the hook from
that user's own tmux-revive (see below).

### Several users in one tmux

Names, links and the mailbox belong to whoever started tmux. Other users can work
inside that tmux too, like root after `sudo -i` or `su -` in one of your panes, or
a user after `su - name` in a pane of root's tmux. When their agents run
`agent-say`, it runs as the user who owns that tmux, with that user's links and
mailbox. So everyone in that tmux sees the same names, and they can message each
other and anyone on its links.

- Install tmux-revive once, as the user who starts tmux.
- Link to that computer as that same user. A link logs in as one user and only
  sees that user's tmux.
- Every other user working in your tmux can have tmux-revive too, so their
  agents get the agent-say note and report their context left. Until they do,
  their VER in the panel shows `[V]`. Select one of their panes and press **V**
  for the command to run in that pane. It's copied, ready to paste. If they
  have an older version, **V** gives you `tmux-revive update` instead.
- Their install tells your tmux which version they have. A user other than root
  needs the same `sudo` as for `agent-say` below, or VER keeps showing `[V]`.
- Without their own, their agents can still message: the messages they get show
  the full path to run.
- A user other than root, in someone else's tmux, needs permission to run commands
  as the tmux owner with `sudo` and no password. Without it, `agent-say` says so
  and does nothing.
- Installed as root, tmux-revive also puts `agent-say` in `/usr/local/bin`, so
  every user can run it.

Agents still need your permission to talk across links, same as before.

## Linking computers

Link tmux on your computer to tmux on a server, and the agents on both sides
can talk to each other by name. Run this once on **your own computer**, using
the same name you'd type after `ssh` (or press **L** in the panel):

```sh
agent-say link devbox
```

The server needs `agent-say` installed too. With an ssh key, the link logs in on
its own. A server that only takes a password works too. ssh asks you for it once
(in a small popup when you press **L** in the panel), and the link keeps that
connection open. tmux-revive never sees or stores the password, and ssh only asks
for it after the server has shown the host key you confirmed. If the connection
drops, say that server reboots or the network goes away for a while, the panel
marks the link `needs login` and **L** asks for the password again. Nothing logs
back in by itself.

Linking follows your ssh setup. The host is resolved the way `ssh -G` resolves it,
with its `HostName`, `Port`, `HostKeyAlias` and known_hosts files.

If ssh already trusts the server (its key is in a known_hosts file ssh reads for
it), it links with no questions, and that key is recorded with the link. Linking
it again while it still has the key you confirmed asks nothing either. Otherwise
it shows you one fingerprint, for the key type ssh would pick, and asks you to confirm
it, as ssh does for a key it hasn't seen. With no key in known_hosts (say
`UserKnownHostsFile /dev/null`) but an ssh connection of yours open to it through a
`ControlMaster`, that key is read through your connection, with no new one made.
From a script, add `--yes` once you've checked it, or `--fingerprint 'SHA256:...
(TYPE)'` to link it to exactly that key.

While an ssh connection of yours is open to the server, the link uses it instead
of its own, but only when ssh checked the server's key as it opened it (your config
checks host keys, and your known_hosts has the key the link was confirmed with).

A link that can't reach its server doesn't keep trying, so a server's fail2ban
never takes it for an attack. If a working link drops, it tries once more right
away, then stops and LINKS says why, like `can't reach (connection timed out) · L
to try again`. Nothing reconnects by itself after that, not even when tmux starts
again. **L** in the panel, or `agent-say link <host>`, tries once more. ssh's own
error is kept in `links/<host>/log` in agent-say's state folder.

If that key changes later, or you revoke it (`@revoked` in known_hosts), the link
stops and `agent-say link` says so. It stays stopped until you link again and
confirm the new key. Every connection the link makes is tied to the key you
confirmed, whatever your ssh config says about known_hosts. ssh itself turns away
a server showing any other key, and the link stops there.

### Limits

You can limit what the other computer may do here:

```sh
agent-say link devbox --read-only        # its messages wait in the mailbox, never typed in
agent-say link devbox --allow shop-dev   # its messages may reach only these panes
```

`--allow` takes a comma-separated list. `--read-write` and `--allow-all` undo
those, and `agent-say link` on its own lists your links with their key and limits.

### Sending across

Send by name, the same as before:

```sh
agent-say shop-review "run the tests and tell me what fails"
```

If a name exists on both sides, add the computer:

```sh
agent-say shop-review@devbox "run the tests"
```

Stop a link:

```sh
agent-say unlink devbox
```

### Two servers, through your computer

Link to two servers and your computer passes messages between them. Each server
sees the other's panes in `agent-say list` (as `tt-dev@dev  (via laptop)`), and
a plain name works as long as only one pane anywhere has it.

The first time an agent on one server writes to an agent on the other, the message
waits on your computer as an introduction. The other server gets nothing until you
allow it. The panel's MESSAGES area shows it at the top as **waiting for [G]rant
access**, and the asking agent's STATE
blinks **[G]RANT ACCESS**. Press **G** to grant access,
pick it, read why it's asking, and choose Approve or Deny.

The same goes for every pair of agents, not only across servers. That means two agents on
your computer, or an agent on a server and one on your computer, either way. What you
send yourself, from a shell or the panel, needs no permission.

Approve shows a four-digit code in a popup for you to type back. Then it delivers
the introduction and anything sent since, in order, and the two can talk both ways.
If both agents wrote before you answered, one Approve covers both, and each gets
what the other sent. Deny drops them, and neither agent can write to the other again.

An agent can restart while it waits. Approve covers whoever is in those two panes
now. If the recipient restarted, it still gets what waited. If the sender restarted,
what it sent earlier is dropped, because it may have sent it again. The panel tells
you before you choose. MESSAGES shows each waiting message as waiting, then as
delivered or not delivered with the reason, and a sender whose message didn't get
through is told so it can send it again. While any approval is in force, MESSAGES
ends with one line counting them.

Permission is per pair of agent sessions, so a new session in a pane asks again.
**G** also lists what you've approved. Pick one to Refresh it for another 24 hours (with a code, as for Approve),
or to Remove it. Esc closes without changing anything. The sending agent is
told plainly what happened (`introduction sent`, `held`, `declined`). At most 5
messages wait per pair, and 3 introductions per server. `agent-say intros` lists
them from a terminal.

Anything kept about agent sessions lasts 24 hours. A permission lapses a day after
you gave it (**G** shows how long each has left), and the next message between
those two is an introduction again. An introduction nobody answers lapses after a
day, along with what it held. A session that runs longer than that is rare, and if
one does, something is wrong. Each lapse is logged, and `agent-say intros` shows
recent ones.

A message from another server is never typed into the agent's prompt as if you
wrote it. The agent is told one is waiting and reads it with `agent-say show`,
marked as coming from another agent, not from you.

Your computer and both servers need this version. What a server sends through your
computer also follows its own link's limits. `--read-only` holds it in your
mailbox, and an `--allow` list has to name the far pane as `tt-dev@dev`.

A Mac can't tell a login over ssh from an agent that left its pane, so there a
message sent from outside any tmux pane is refused, including what your computer
hands a Mac server it links to.

### What this does and doesn't protect

Every agent needs your permission to talk with another, on one computer or across
two. Agents on your servers can't allow anything, since they can't touch your
computer's files. So a rogue server can't reach your computer's agents or your
other servers' agents without you. Your computer names each sender's server itself,
from the link it came in on.

Within one server, though, an agent's session is whatever that server says it is.
A rogue process there could pass for another agent on the same server, but only
one still running under the same pane name, and only to the agents you allowed
that one to reach.

Agents on your own computer run as you, and a determined one could get around the
popup (for Approve and Refresh alike), or around agent-say altogether. The popup's
code stops keys typed into the panel and agents on other computers, not an agent here
that sets out to get past it. It could type `agent-say` into a shell pane
of yours with `tmux send-keys`, or run it over `ssh` to its own computer, and pass
for you. Every permission given is logged with what gave it (`agent-say intros`
shows them). For real isolation on your computer, deny agents `tmux send-keys` and
writes under `~/.local/state/agent-say` (in Claude Code, a `permissions.deny` rule
such as `Bash(tmux send-keys:*)`), or run them as another user.

## Settings

Settings go in your tmux config, **before** the tmux-revive block. For example:

```tmux
set -g @revive-interval 60
set -g @revive-panel-key P
```

| Setting | Default | What it does |
|---|---|---|
| `@revive-interval` | `60` | seconds between saves (only when something changed) |
| `@revive-panel-key` | `none` | a prefix key that opens the panel in a popup, e.g. `P` for prefix + P |
| `@revive-save-key` | `none` | a prefix key that saves right now |
| `@revive-restore-key` | `none` | a prefix key that restores the latest save |
| `@revive-status-key` | `none` | a prefix key that shows `tmux-revive status` in a popup |
| `@revive-programs` | see below | programs a pane comes back running |
| `@revive-question-alert` | `on` | the message when an agent asks a question |
| `@revive-question-bell` | `on` | the bell with that message |
| `@revive-auto-restore` | `on` | restore on the first start after a reboot |
| `@revive-shutdown-hook` | `on` | on Linux, save right before shutdown or sleep |
| `@revive-claude-remote-control` | `on` | bring back a Claude Code session's Remote Control link too |
| `@revive-claude-dirs` | empty | extra Claude Code config dirs to look in, besides `~/.claude*` and `$CLAUDE_CONFIG_DIR` |
| `@revive-keep` | `30` | how many saves to keep |
| `@revive-scrollback` | `2000` | lines of scrollback saved per pane |
| `@revive-dir` | `~/.local/share/tmux-revive` | where saves live |
| `@revive-bash` | found on its own | the bash 4+ to run with |

Besides AI agents, a pane comes back running the program it had open if that
program is on the `@revive-programs` list (the default is shown, the panel included).
Add your own to it, or set it to `:all:` to relaunch anything. It's a list because
relaunching a build, a `git push` or an `rm` after a reboot would run it again:

```tmux
set -g @revive-programs 'vim nvim vi man less more tail top htop btop watch ssh mosh journalctl lazygit lazydocker yazi ranger k9s tmux-revive'
```

Turn off the alert when an agent asks a question, or just its bell:

```tmux
set -g @revive-question-alert off
set -g @revive-question-bell off
```

## Environment variables

Installer:

| Variable | What it does |
|---|---|
| `REVIVE_VERSION=x.y.z` | install that signed release (default: the latest) |
| `REVIVE_REF=main` | follow a branch, tag or commit instead (not signed) |
| `REVIVE_REPO=owner/name` | install from another GitHub repo |
| `REVIVE_SOURCE=/path` | install from a local checkout |

Panel:

| Variable | Default | What it does |
|---|---|---|
| `REVIVE_CLAUDE_WINDOW` | 1M or 200k | Claude Code's context window size, for CTX LEFT |
| `REVIVE_PANEL_ART` | random | which artwork to start with |
| `REVIVE_PANEL_REFRESH` | `2` | seconds between refreshes |
| `REVIVE_PANEL_SPLASH` | first open only | `1` always shows the welcome screen, `0` never |

agent-say:

| Variable | Default | What it does |
|---|---|---|
| `AGENT_SAY_MAILBOX` | `~/.local/state/agent-say/mailbox.md` | the mailbox file |
| `AGENT_SAY_MAILBOX_MAX` | `1048576` | bytes before the older half moves to `mailbox.md.1` |
| `AGENT_SAY_ENTER_DELAY` | `0.4` | seconds between typing a message and pressing Enter |
| `AGENT_SAY_INLINE_MAX` | `300` | longer messages are read from the mailbox |
| `AGENT_SAY_MODE_WAIT` | `10` | seconds to wait for a pane to leave copy mode |
| `AGENT_SAY_TYPING_WAIT` | `60` | seconds to wait for someone to finish typing in a pane |
| `AGENT_SAY_MSG_MAX` | `65536` | bytes a message keeps; past that it is cut, with a note |
| `AGENT_SAY_QUEUE_MAX` | `50` | messages waiting at once |
| `AGENT_SAY_QUEUE_MAX_AGE` | `86400` | seconds a queued message keeps trying |
| `AGENT_SAY_SESSION_TTL` | `86400` | seconds a permission, an unanswered introduction or a relayed sender is kept |
| `AGENT_SAY_HOST` | short hostname | this computer's name, as others address it |
| `AGENT_SAY_LINK_INTERVAL` | `2` | seconds between link check-ins |
| `AGENT_SAY_REMOTE_CMD` | `agent-say` in `~/.local/bin` or PATH | how to run agent-say on the other computer |
| `AGENT_SAY_SSH` | `ssh` | the ssh command to use |

## Releases and signing

The installer installs the latest release, but only after checking it. The
release's `SHA256SUMS` has to carry a signature from the release key written into
`install.sh` itself, and the tarball has to match it. If anything doesn't check
out, it stops, installs nothing, and tells you why. It never falls back to
something unchecked. The check uses `ssh-keygen -Y verify` (OpenSSH 8.1 or later).

To install a particular version, pin it:

```sh
curl -fsSL https://raw.githubusercontent.com/odysseyalive/tmux-revive/main/install.sh | REVIVE_VERSION=1.0.0 sh
```

To follow `main` instead, set `REVIVE_REF=main` (or a branch, tag or commit). That
isn't signed. It trusts HTTPS and the GitHub account, and installs the exact
commit the branch pointed at.

Once installed, `tmux-revive update` checks each new release against the key in
the copy you already have.

## Uninstall

```sh
tmux-revive uninstall
```

Add `--purge` to also delete your saves. The installer's `--uninstall` and
`--purge` options do the same.

## Troubleshooting

- `tmux-revive doctor` checks the moving parts.
- `tmux-revive log` shows recent activity, including failed saves.
- `tmux-revive status` shows what a restore would bring back.
- tmux-revive needs bash 4 or newer. On macOS: `brew install bash`.
- It needs `jq`. The installer uses your system's, or fetches a checked copy.
- If tmux-continuum's auto-restore is on, turn it off, or both will restore.
- Installing a signed release needs OpenSSH 8.1 or later, for `ssh-keygen -Y verify`.
- A linked server needs `agent-say` in `~/.local/bin` or on its PATH, or set
  `AGENT_SAY_REMOTE_CMD`.
- An agent running as root (`sudo -i`, `sudo claude`) inside your tmux says "no
  pane named ..." for names your link knows? Update agent-say on that computer. It
  now uses the links and mailbox of whoever started the tmux it's in. See [Several
  users in one tmux](#several-users-in-one-tmux).
- A link reports "tmux here runs as root, not admin: link as root"? The agents on
  that computer are in root's tmux, but the link logs in as admin. Link as the
  user who starts tmux there (`User root` for that host in `~/.ssh/config`), or
  start tmux as the user the link logs in as.
