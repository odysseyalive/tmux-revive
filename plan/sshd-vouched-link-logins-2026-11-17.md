# Let sshd vouch for link logins instead of inspecting /proc

Written 2026-11-17. A plan only; nothing in it has been built.

## Problem

On a linked server, `agent-say` has to tell two callers apart:

- a link login from your laptop, which counts as a person, so its `--from` name is trusted;
- an agent on that same server, whose message must go through the approval index.

Today it works this out from the server's own process and network state:

- `sending_agent` walks up the process tree. If it finds no pane and no agent but does find an ssh server, it returns "a person" (`bin/agent-say:1264`).
- That ssh-server test is a chain of heuristics, added in commits `33ee5c7`, `6a134a1`, `0527eae`, `bd5ce62`, `be01334` and `97db986`:
  - `ssh_server_pid` (`bin/agent-say:1140`) recognises sshd, including the non-dumpable side of a non-root login, by its name and a root parent.
  - `ssh_from_elsewhere` (`bin/agent-say:1166`) requires the login to come from another computer.
  - `host_namespaces` (`bin/agent-say:1187`) requires the kernel's first user and pid namespaces, read from nsfs inodes.
  - `ssh_local_conn` (`bin/agent-say:1195`) looks for a connection from this computer in init's TCP table.

Every one of these reads what the caller's own namespaces show. The automated security review found a way past each fix in turn. The latest finding still stands against 1.2.44: inside a user and mount namespace it creates itself, the caller can bind-mount a real nsfs file of its own over `/proc/$BASHPID/ns/user`. The inode `stat` then reads is a genuine one (unverified: reported by the security review, not reproduced here). The limit is structural. A script running in an environment the caller controls cannot prove where it is running.

### What the trust model already gives up

The boundary is the approval index: grants and introductions, approved by you in the panel. It exists to stop rogue agents (unverified: memory note `trust-model-agents-not-users`, from a decision on 2026-11-09). The index is a set of plain files in the link user's own state directory:

- `$STATE/grants` (`bin/agent-say:1382`), whose format is documented at `bin/agent-say:1375`.

An agent that runs as the same Unix user as the link login can already:

- write an `allow` line into `$STATE/grants` directly;
- rewrite `~/.local/bin/agent-say`, which is what `REMOTE_CMD` runs (`bin/agent-say:327`);
- add any key it likes to `~/.ssh/authorized_keys`.

None of these needs an ssh trick. So against an agent with a shell as the link user, **no check inside agent-say can hold**, whether it inspects `/proc` or relies on a forced command. The ssh-spoofing gap matters only where agents on a server run as a **different** Unix user from the link login, and cannot write that user's files.

Whether that is true on your servers isn't known. On dev.tickettomato.com the link logs in as `admin` (`ssh -G dev.tickettomato.com` reports `user admin`), and its panes are named `tt-dev-ada` and `tt-dev-root` (`~/.local/state/agent-say/links/dev.tickettomato.com/names`). Which Unix user each of those agents runs as was not checked.

## User layouts it must support

Revised 2026-11-17 after your reply: "this needs to be flexible for root or other users, even under jailed shell." Every one of these layouts has to keep working with no extra step:

1. **Root's tmux with a few panes as another user.** You log in as root and start tmux there, and some panes run as a user (`su - <user>`) who has their own tmux-revive install.
2. **A user's tmux with root tabs.** You log in as the user, start tmux as that user, and run `sudo -i` in other tabs for root.
3. **All one user**, root or not.
4. **A jailed shell**, for example a restricted or chrooted login shell.

Your earlier notes say the same. Setups mix root and users both ways, and should be "flexible" and "frictionless": no sudo setup, no passwords, no extra steps (unverified: memory note `any-user-mix-in-tmux`, 2026-11-10). Users who share a tmux are trusted admins, and the approval index is the boundary against agents (unverified: memory note `trust-model-agents-not-users`).

agent-say already handles layouts 1 to 3 on the delivery side:
- It finds the tmux server above itself and runs again as that server's owner (`bin/agent-say:158-170`).
- Root drops to the owner with `setpriv` or `runuser`; anyone else uses only `sudo -n` (`bin/agent-say:285-290`).
- In root's tmux, a user who can't become root asks root's agent-say instead (`ask_owner`, `bin/agent-say:206`).

The link design must not undo any of that, and must not ask for a dedicated user or an `sshd_config` change.

## Approach

Let sshd decide, using credentials an agent on the server does not have:

- A dedicated **link key** pair is generated on the laptop. Its private half never leaves the laptop.
- On each server, the key's `authorized_keys` entry is restricted:
  `restrict,command="<agent-say> _link" ssh-ed25519 AAAA… agent-say-link@<laptop>`
- sshd runs only `agent-say _link` for that key, and puts the requested command in `SSH_ORIGINAL_COMMAND`.
- `_link` parses `SSH_ORIGINAL_COMMAND` against every command that travels over a link today, and runs only those. In that process, and only there, the caller counts as a link. Two sets of commands use the link:
  - **agent-say's own:** `_sync LABEL`, `--from NAME TO -` and notices (`bin/agent-say:1354`, `1887`, `2680`).
  - **The panel's, sent through `remote_run`** (`scripts/panel.sh:1587`): `tmux-revive panel --rows`, `--peek`, `--keys` and `--paste`, `tmux-revive update`, and `agent-say name` (`scripts/panel.sh:1571-1580`).
  Under a forced command, every session on that connection becomes `_link`, so any command left off the list breaks: peek, rows, answering, remote update and naming.
- Everything else, including any plain login, is never taken for a link or a person by its process ancestry. Inside `_link`, provenance comes from sshd, through the key, not from `/proc`.

Why this shape:

- sshd, a root process, enforces the forced command: a login with the link key can only run `_link`.
- But `_link` can't tell that sshd started it: any local process can run `SSH_ORIGINAL_COMMAND='…' agent-say _link` itself. What stops that from mattering is which user it runs as, not a check inside `_link`:
  - **An agent running as another user** runs agent-say as itself, with its own state, and never reaches the login user's panes. The only bridges between users are:
    - `ask_owner` → `_serve`, which refuses every `_*` command, `link` and `unlink` for another user's pane (`bin/agent-say:2005-2008`);
    - re-running as the tmux owner (`bin/agent-say:285-290`), which needs root or `sudo -n` to that owner, so the caller already has the owner's powers.
    `LINK_CALL` must never cross either bridge. It is set only inside the `_link` process and is cleared at startup, so a re-run or a `_serve` request starts without it. Step 6 tests this.
  - **An agent running as the login user, or as root,** can already do anything; see below. Namespace and `/proc` tricks no longer matter, because nothing is read from `/proc`.
- Not before all user code, though. sshd runs the forced command through the link user's login shell (the passwd shell, `-c`), so that user's shell startup files run first, for example zsh's `.zshenv`, or the `.bashrc` that bash sources under sshd. `restrict` turns off `~/.ssh/rc`, not those files. So anyone who can write as the link user can still run code ahead of `_link`.
- The rejected alternatives:
  - A shared token kept on the server. Anything the link user can read, an agent running as that user can read.
  - More `/proc` checks. The security review found a way around each of the last five (commits `6a134a1`, `0527eae`, `bd5ce62`, `be01334`, `97db986`). `33ee5c7` was the original delivery fix, not one of these.

What it protects, and what it doesn't, in the layouts above:

- **An agent running as a different, non-root user from the link login can't pass for the link.** It can't use the laptop's key, can't write the login user's `authorized_keys`, and can't write that user's shell startup files. Two examples:
  - In layout 1, the link logs in as root, and the agents in `su - <user>` panes are this case.
  - In layout 2, the link logs in as the user, and agents running as any other non-root user are this case.
- **An agent running as the link login user, or as root, isn't stopped**, by this design or by anything else in agent-say. It can add its own `command="… _link"` key, put code in a shell startup file that runs before `_link`, or simply write an `allow` line into `$STATE/grants`. That fits the trust model: the approval index is agent-say's cooperative boundary, not a sandbox. The plan doesn't try to close it, because that would need a dedicated user or an `sshd_config` change, which you've ruled out.
- **What it fixes outright:**
  - Link trust no longer depends on `/proc`. The `/proc` checks are what kept being worked around.
  - The `/proc` checks also fail closed wherever `/proc` isn't the host's: a server that is a container, and possibly a chroot jail with no `/proc` mounted (unverified: not tested on a jail).

No `sshd_config` change, no sudo and no separate user is needed. The key line goes in the login user's own `~/.ssh/authorized_keys`, whichever user that is (Step 8).

### Password logins

Some links log in with a password through a master connection that `ssh_login` opens (`bin/agent-say:791`, design comment at `bin/agent-say:678-689`). A forced command attaches to a key, not to a password. A server linked by password therefore has no key for sshd to vouch with. It either:
- moves to the link key, or
- keeps today's fallback (see Migration), with its known limits.

Which links use passwords today isn't recorded in one place. The panel showed efwnow-server, odysseyalive.com and realamish-root as "needs login · B to type its password" (unverified: panel screenshot earlier this session).

## Steps

1. **Link key on the laptop.**
   - Add `link_key` to `bin/agent-say`. It creates `$STATE/link-key` (ed25519, no passphrase, mode 600) on first use, with `ssh-keygen -q -t ed25519 -N '' -C agent-say-link@$LABEL`, and prints the public half.
   - Show the public half in the panel's link view and in `agent-say link <host>` output, with the exact `authorized_keys` line to paste.
2. **Use the key for link traffic.**
   - Today `ssh_to` (`bin/agent-say:630`) rides your own master when one is open (`riding`, `bin/agent-say:667`), otherwise it uses `SSH_OPTS` (`bin/agent-say:341`) with your default identities.
   - Add `-o IdentitiesOnly=yes -i "$STATE/link-key"` for hosts marked key-linked (`$STATE/links/<host>/linkkey`).
   - Don't ride your own master for those hosts. A master logged in with your personal key isn't the forced-command key, so `_link` wouldn't run.
   - The link's own master socket stays separate from yours. Every session multiplexed over it inherits the forced command.
   - **Key traffic needs a ControlPath of its own.** The password login's master uses the same `$CONTROL` as `SSH_OPTS` (`bin/agent-say:805`, `bin/agent-say:341`). Key traffic riding that master would ignore `-i`, run no forced command, and pass Step 8's test `_sync` without the key ever being used. So key-linked hosts get `$STATE/links/<host>/linkmux`, and Step 8's test checks that it went over that socket with the key (`ssh -O check` on it).
   - Everything else that reaches the host is sorted by which login it needs:
     - Over the link key: unlink's `_sync` notice (`bin/agent-say:2296-2297`) and the panel's `remote_run` (`scripts/panel.sh:1587`).
     - Not over the link key: `master_keys` runs `cat $HOSTKEY_FILES` (`bin/agent-say:658`), and adding or removing the key line edits `authorized_keys`. Neither is a link command, so neither goes on `_link`'s list. Both use the login you make when linking: your own key, or the password through `ssh_login`. Unlink after a host is key-only therefore removes the line with one more of those logins, started by you.
3. **`_link` on the server.**
   - Add a `_link)` case beside `_sync)` (`bin/agent-say:2588`).
   - It requires `SSH_ORIGINAL_COMMAND`, splits it with the same validation the existing entry points use (`valid_host`, `valid_name`), and allows only:
     - `_sync LABEL`;
     - `--from NAME TO -`, with `AGENT_SAY_VIA=` / `AGENT_SAY_TO_SESSION=` / `AGENT_SAY_LOCAL_ONLY=1` / `AGENT_SAY_NOTICE=1` prefixes, as `REMOTE_CMD` builds them at `bin/agent-say:1353-1354`, `bin/agent-say:1887` and `bin/agent-say:2680`;
     - the panel's commands listed under Approach, with their arguments checked as `panel.sh --keys` and `--paste` already check them (`key_ok`, `paste_ok`).
   - `SSH_ORIGINAL_COMMAND` arrives as the full `printf %q`-quoted string, `PATH="$HOME/.local/bin:$PATH"` prefix and `NAME=value` assignments included. `_link` must parse it without `eval`: a small tokenizer that accepts only that quoting, and refuses anything else (`;`, `$(`, a backquote, a redirect other than `</dev/null 2>&1`).
   - **Jailed shells:** sshd runs the forced command through the login user's shell (the passwd shell, `-c`), so a jailed shell decides whether `_link` can start at all:
     - A restricted bash (`rbash`), tested on the laptop on 2026-11-17 with `/usr/bin/rbash -c '<command>'`:
       - `PATH="$HOME/.local/bin:$PATH" agent-say --help`, the shape of today's `REMOTE_CMD` (`bin/agent-say:327`), printed `PATH: readonly variable` and still ran `agent-say`. That was only because `~/.local/bin` was already on PATH, so on an rbash login whose PATH lacks it, today's links would fail to find agent-say (inferred, not tested on a real rbash login).
       - `/home/francis/.local/bin/agent-say --help` was refused: `restricted: cannot specify '/' in command names`.
       - `agent-say --help`, a bare name on PATH, ran.
     - So under rbash the forced command has to be the bare name `agent-say _link`, with agent-say on the login's PATH, not an absolute path. Step 8 detects an rbash login and writes the bare form for it.
     - A chroot jail (jailkit and similar) needs agent-say and its tools (bash, tmux, jq, ps) inside the jail. A command-limited jail shell, such as jailkit's `jk_lsh`, needs agent-say on its allowed list (unverified: not tested).
     - The plan doesn't guess. Step 6 adds a jailed-shell check, and Verification needs one real jailed login before release.
   - Simpler alternative worth weighing first: change the laptop to send a plain, unquoted request (`_link sync LABEL`, `_link send FROM TO`, with the message on stdin), so `_link` never parses shell. That changes both sides at once, which Step 7's migration has to account for.
   - It sets an internal flag, `LINK_CALL=1`, which can't be set from outside (cleared at startup like `LINK_TRY` at `bin/agent-say:39`). It then runs the matching code path.
4. **Trust `_link`.**
   - In `sending_agent` (`bin/agent-say:1240`), add `[[ -n $LINK_CALL ]] && return 0` ahead of the pane walk.
   - During the migration window (Step 7), the `sshd && !agent` branch (`bin/agent-say:1264`) stays for links not yet moved to the key. Step 5 removes it.
   - Leave the pane walk for local callers unchanged. The callers that depend on it are at `bin/agent-say:1835`, `1872`, `1900` and `2159`.
5. **Remove the heuristics.**
   - Delete `ssh_server_pid`, `ssh_named`, `ssh_from_elsewhere`, `host_namespaces` and `ssh_local_conn` (`bin/agent-say:1140-1214`), and the `ssh_server_pid "$pid" "$below"` call and the `below` variable in `sending_agent`.
   - Do this only after the migration window in Step 7.
6. **Tests (`test/agent-say.sh`).**
   - The suite's "remote" is `fakessh` (`test/agent-say.sh:261`) running a patched copy of agent-say under a bash copy named `sshd` (`test/agent-say.sh:296`, `311-319`).
   - Change `fakessh` to behave like a forced command: export `SSH_ORIGINAL_COMMAND="$cmd"` and run `agent-say _link` instead of `bash -c "$cmd"`. Drop the two `sed` patches at `test/agent-say.sh:315-316`.
   - New checks:
     - a link call through `_link` is delivered under its `--from`;
     - after Step 5 only: the same command run without `_link` (plain `bash -c`, as an agent ssh-ing in with its own key would) is refused. Until then the old path is still live, so this check would prove nothing;
     - `agent-say _link` run directly by an agent in another user's pane, with a crafted `SSH_ORIGINAL_COMMAND`, doesn't deliver into the owner's panes, including through `ask_owner`/`_serve`;
     - on a password-linked stand-in, key traffic goes over `linkmux`, not the password master;
     - `_link` refuses any `SSH_ORIGINAL_COMMAND` that isn't on its list (a shell command, `;`, a different subcommand);
     - `LINK_CALL` set in the environment is ignored;
     - for each layout, with the existing multi-user stand-ins: a root link whose message reaches a pane owned by another user; a user link whose message reaches a pane in that user's tmux that is running `sudo -i` as root; and an agent in a pane of another user than the login is refused when it ssh's in with its own key;
     - `_link` started from `rbash -c` (layout 4) gets through, or fails with a clear message rather than silently.
   - Delete the heuristic checks:
     - stand-in sshd / non-dumpable / namespace / TCP-table tests (`test/agent-say.sh:725-761`);
     - the detached-`sshd` refusals that only test the old path.
   - Keep "an agent's detached child is refused" in the local form.
7. **Migration and compatibility.**
   - A server still on 1.2.40–1.2.44 keeps working with a laptop on the new version that hasn't been given the key yet. The laptop sends the same commands with the same `REMOTE_CMD`, and the old server judges them with its heuristics.
   - Once a host is marked key-linked, the laptop sends link traffic with the link key. That needs the new server version (`_link`) and the `authorized_keys` line, both installed by you.
   - New laptop + old server + key installed means the forced command names `_link`, which the old server doesn't have, so every call fails loudly. The panel should say "update tmux-revive there" for that host, the same way it already handles a server too old to peek (`scripts/panel.sh`, "no peek (update tmux-revive there)").
   - For one release, the server keeps the old heuristic path for calls that don't come through `_link`, so not-yet-migrated links still work. The release after that removes it (Step 5).
8. **Setup per server: automatic, started by you.**
   - Linking a server (panel `B`, or `agent-say link <host>`) already logs in once as whichever user the link uses. That might be root, a user, or one of several users with their own installs.
   - Over that same login, the new version adds the restricted key line to that user's own `~/.ssh/authorized_keys`. It creates `~/.ssh` (700) and the file (600) if missing, and leaves any line already there alone.
   - Then it runs one `_sync` with the key, a single attempt with no retries. Only if that works does it write `$STATE/links/<host>/linkkey`.
   - The forced command names the login user's installed agent-say by absolute path, found the way `REMOTE_CMD` finds it: `PATH="$HOME/.local/bin:$PATH" command -v agent-say` (`bin/agent-say:327`), because a non-interactive ssh login often lacks `~/.local/bin` on its PATH.
   - The exception is an rbash login, which refuses any command name containing `/`: there it writes the bare name, and only if `agent-say` is on that login's PATH as set. If it isn't, the panel says so and stops. See Q5.
   - A link logs in as the tmux owner (`bin/agent-say:158-160`). So in layout 1 there is one link, root's, using root's install; the users' panes are reached through root's agent-say. A user's own tmux on the same server, if any, gets its own link.
   - **If the line can't be written,** link setup says so and keeps the link as it is. That happens when `~/.ssh/authorized_keys` isn't writable, or when sshd reads keys from a root-owned file such as `/etc/ssh/authorized_keys/%u`, which is common in jails. In that case the panel shows the line for you to place.
   - Several laptops linking the same server each add their own line with their own key, distinguished by the comment `agent-say-link@<laptop>`.
   - **Existing links:** the panel offers "use link key" once the server is on the new version. Pressing it does the same thing over the link's current login.
   - **Unlink** removes that laptop's line from the server again.
   - All of it starts from your key press in the panel. No agent runs installs on your servers.

## Files touched

- `bin/agent-say`: `link_key`, adding and removing the key line in link and unlink, the `_link` case, `LINK_CALL`, `ssh_to` key options, `sending_agent`, and later deletion of `bin/agent-say:1140-1214`.
- `scripts/panel.sh`: `remote_run` uses the link key for key-linked hosts. The link view shows the key line, a "use link key" action, and "update tmux-revive there" when `_link` is missing.
- `test/agent-say.sh`: `fakessh` as a forced command, new `_link` checks, and removal of the heuristic checks.
- `test/panel.sh`: a check for each panel command over a key-linked host (rows, peek, keys, paste, update, name).
- `docs/COMMANDS.md`: what the link key is, what its line in `authorized_keys` allows, and how unlink removes it.

## Verification

- `bash test/agent-say.sh` passes, including the new `_link` checks and the refusal of the same command outside `_link`.
- `bash test/panel.sh` and `bash test/e2e.sh` pass.
- On a server you've set up:
  - oa-work → tt-dev-ada is delivered;
  - after Step 5 only (during the migration window the old path still accepts it): `ssh <server> 'agent-say --from oa-work@<laptop> tt-dev-ada -'` with your personal key, not the link key, is refused;
  - `grep agent-say-link ~/.ssh/authorized_keys` as the link's login user shows exactly one restricted line per laptop.
- The heuristic functions are gone: `grep -c 'host_namespaces\|ssh_local_conn' bin/agent-say` prints 0 after Step 5.
- The panel still works over a key-linked host: rows, peek, answering a question, `U` update, and naming a pane there.
- On your real servers, done by you through the panel: a root-tmux server with `su - user` panes (odysseyalive.com or realamish-root), and a user-tmux server with `sudo -i` tabs. Jailed servers are production only and are not tested (Decisions, Q4).

## Decisions (2026-11-17)

- **Q1: build it.** Your words: "Q1 sure, build it."
- **Q4: no testing on a real jailed server.** Your words: "I only have production servers with jailed shell. I can't consent to testing." Jailed-shell support is tested only locally (a restricted bash, plus a chroot made on the laptop) and ships described as untested on real jailed servers.
- **Q2, Q3, Q5: the recommendations are taken**, as part of "build it": the plain `_link` protocol, password-linked servers moved to the key at their first login, and the panel showing the one root step on rbash or jailed servers.

## Open questions

- **Q1. Is it worth building, given what it can't stop?**
  - It removes the `/proc` treadmill, works in containers, and protects against agents of any user other than the link login. It doesn't stop an agent that runs as the link login user or as root, and nothing in agent-say can (Approach).
  - **Recommendation:** build it. It ends the run of heuristic patches, and it makes the link work in places the heuristics fail closed.
- **Q2. Quoted commands or a plain request protocol?** (Step 3)
  - **Recommendation:** the plain protocol (`_link sync LABEL`, `_link send FROM TO`, the message on stdin). `_link` then never parses shell, which also matters in a jailed shell.
- **Q3. Password-linked servers.**
  - The first link login can still use the password. After that, link traffic uses the key, so the password is needed only at setup.
  - **Recommendation:** move them to the key during that first login (Step 8).
- **Q5. A jailed or rbash server where agent-say isn't on the login's PATH.**
  - Placing it there, or adding it to `jk_lsh`'s allowed list, is a root step on that server: the one extra step this plan can't remove.
  - **Recommendation:** the panel detects it and shows the exact step; you do it once per such server.
- **Q4. Which server has a jailed shell?**
  - The plan needs one real jailed login to verify against before release.
  - **Recommendation:** you name one, or the jailed-shell support ships marked untested.

## Risks

- **Locking out a link.** Marking a host key-linked before its `authorized_keys` line or the new version is in place makes every call to it fail. The "use link key" action should run one `_sync` over the key first and refuse to switch if it fails. That is a single attempt; there are no retries (unverified: memory note `no-connection-retries`).
- **Riding your master.** Key-linked hosts stop riding your own ssh master, so they open their own connection. A server with `MaxSessions`/`MaxStartups` limits or fail2ban sees one more login source. A wrong key there means refused logins in its auth log, which once led to a ban (unverified: memory note `no-connection-retries`).
- **Key file on the laptop.** `$STATE/link-key` is an unencrypted key that reaches every linked server's `_link`. It needs mode 600, and the README should say what it grants. The forced command limits it to `_link`.
- **`restrict` turns off a PTY and forwarding** for link-key sessions. Nothing in today's link traffic needs either, as far as the commands listed in Approach go, but no test covers it yet. Step 6 should run each listed command over the key.
- **Writing to `authorized_keys` on your servers.** Link setup appends one line and unlink removes it. Both match on the exact comment, never by line number, and keep a backup copy (`authorized_keys.agent-say.bak`) the first time. A bug here could lock out a login, so the tests need a fixture file with other keys that must come through unchanged.
- **Breaking the panel over links.** If `_link`'s list misses one of the panel's `remote_run` commands, that feature quietly stops working for key-linked hosts. The test suite needs a check for each.
