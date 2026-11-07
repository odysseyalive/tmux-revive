![tmux-revive: a watercolor laptop whose tmux panes are lighting back up, with notes passed between them and a cable out to one server in another room](assets/header-night.png)

# tmux-revive

The idea is simple. You shut your computer down, turn it back on, type
`tmux`, and everything is right where you left it. Your sessions, windows and
splits all come back with the programs that were running in them. And your AI
coding agents? They pick up **the exact conversation** they were in, too. That
covers Claude Code (Remote Control link and all), Codex, Cursor Agent and Crush.

There's a little extra in the box, too, called `agent-say`. It lets those
agents send each other messages, even across accounts and across computers.

## Contents

- [Install](#install)
- [Everyday use](#everyday-use)
- [Handy commands](#handy-commands)
- [Control panel](#control-panel)
- [Agents talking to each other](#agents-talking-to-each-other)
- [Linking AI sessions across multiple computers](#linking-ai-sessions-across-multiple-computers)
- [Options](#options)

## Install

On Linux, macOS or WSL:

```sh
curl -fsSL https://raw.githubusercontent.com/odysseyalive/tmux-revive/main/install.sh | sh
```

On Windows, in PowerShell (it installs into WSL):

```powershell
irm https://raw.githubusercontent.com/odysseyalive/tmux-revive/main/install.ps1 | iex
```

That's it. If tmux is already running, it's protected from now on. The
installer backs up every file before it touches it, and `tmux-revive uninstall`
undoes all of it.

## Everyday use

There's nothing new to learn. Work in tmux the way you always have, detach or
close the terminal, shut down, and when you come back, type `tmux`. Everything
reopens.

It saves on its own when you detach or close something, every minute if
anything changed, and on Linux right before shutdown or sleep.

Want a clean slate? Close the panes, windows or sessions yourself. What you
close stays closed.

## Handy commands

What would come back right now:

```sh
tmux-revive status
```

Every save, newest first:

```sh
tmux-revive list
```

Bring back an older save (use a name from `list`):

```sh
tmux-revive restore 20261106T192239
```

Check that everything is working:

```sh
tmux-revive doctor
```

Install the latest version (your saves are kept):

```sh
tmux-revive update
```

Remove it (add `--purge` to also delete your saves):

```sh
tmux-revive uninstall
```

## Control panel

Remember the old BBS screens? This is a live one for every pane. It shows
what's running in each, and whether each AI agent is working, waiting on you,
or stuck on a question before it can go on. CPU, memory and git status are
there too, along with recent agent messages, links and saves.

```sh
tmux-revive panel
```

Pick a pane by its number or with the arrow keys, then press a letter. **J**
jumps to it, **M** messages it, **N** names it, and **P** shows or hides a
quick peek at its screen. **S** saves right now, and **Q** quits.

## Agents talking to each other

`agent-say` lets an agent in one tmux pane send a message to an agent in
another pane, and the answer finds its way back on its own.

First, give each pane a name. You only do this once. In Claude Code, type this
into its prompt:

```
! agent-say name shop-dev
```

Pick a name that won't get mixed up with what the agents are talking about.
Send a message to `api` or `tests` and it reads like just another topic in
the conversation, and `claude` could be any Claude pane at all. The project
plus the pane's job, so `shop-dev` or `shop-review`, keeps things clear.

Then just ask your agent in plain words:

> Use agent-say to ask shop-review to review parser.py and tell you what breaks.

See every pane and its name:

```sh
agent-say list
```

Read the last five messages:

```sh
agent-say read 5
```

A word of caution. Anything that can run `agent-say` can type into your
agents, so treat it the way you'd treat access to your terminal.

## Linking AI sessions across multiple computers

Link tmux on your computer to tmux on a server, and the agents on both sides
can talk to each other by name. Run this once on **your own computer**, using
the same name you'd type after `ssh`:

```sh
agent-say link devbox
```

The server needs `agent-say` installed too, and ssh has to log in without
asking for a password. You can test that with:

```sh
ssh -o BatchMode=yes devbox true
```

Then send by name, the same as before:

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

Each link connects just two computers. So if you link to two servers, each one
can talk to you, but they can't talk to each other.

## Options

Options go in your tmux config, **before** the tmux-revive block. The one
you'll most likely want is the number of seconds between saves:

```tmux
set -g @revive-interval 60
```

Want the panel to pop up with a key? This one uses prefix + P:

```tmux
set -g @revive-panel-key P
```
