# Rewrite the interactive panel in Rust, byte for byte, with sections that update on their own

Written 2026-11-23, against HEAD `475f43a` ("release 1.2.54"). A plan only; nothing in it has been built. Line numbers are for that commit.

Revised the same day after an independent design review. Each finding was checked against the tree at `475f43a` before it was folded in; the citations below are what that check found.

## Decided (not reopened here)

These come from the request that commissioned this plan. They are the user's words as relayed in it, not quoted from a file (unverified: relayed in the task brief, 2026-11-23):

- Rewrite the interactive local panel, `scripts/panel.sh`, in Rust: "keep all the existing functionality" and "keep the interface exactly the same".
- "realtime screen updates where different windows didn't affect each other".
- The screen is byte-identical to bash. Port the line-building code directly. Use raw escapes or crossterm, never ratatui layout. Keep the changed-lines diff and the `?2026` synchronized-output wrapping.
- The oracle is `bash scripts/panel.sh --once`.
- These stay in bash, unchanged: `--rows --peek --keys --paste --show --asking --running`, and `bin/agent-say`.
- The bash panel stays the fallback wherever there is no binary.
- Platforms: Linux x86_64, Linux ARM64 and macOS. Windows goes through WSL and gets the Linux build.
- No GitHub CI. Releases are built and signed locally. Users download a prebuilt binary and never compile anything.
- **Q2, decided by the user (2026-11-23): keep both in step**, "just in case of incompatibilities". Every panel change lands in bash and Rust in the same commit, and tier 2 (`--once` bash vs Rust) stays a release gate for good. What that costs, and how it is made cheaper, is in "The cost of keeping both in step" below.

### Decided by the reviewer, not the user (reversible)

The design review that led to this revision made one decision of its own and marked it reversible. It is not the user's, and the user can overturn it:

- **Composite screens.** The Rust panel can show states bash never draws: PANES updating behind a modal, or while answering (bash freezes the rows above the question in `ATOP`, `scripts/panel.sh:3068-3074`, and gathers nothing while a modal is up). For these, every element stays byte-identical to bash: the modal box, and the panel under it as bash draws it at a matching moment. The composite as a whole is checked as screen-equal with its dynamic regions masked (tier 3, below).

## Problem

### One loop does everything, in order

The live panel is one bash loop: gather, then draw, then wait for a key (`scripts/panel.sh:5143-5199`):

- `gather` (`scripts/panel.sh:1710`) does all of this before anything is drawn:
  - reads the whole process table through `ps` (`:1716`);
  - lists panes (`:1728`);
  - for each pane, walks its process tree, measures CPU from `/proc/PID/stat` ticks (`:1746-1762`) and runs `git_info` (`:1805`, up to four `git` runs per folder every 15 s: `symbolic-ref`, `rev-parse` if that fails, `config`, `status`, `:1528-1548`);
  - then `agents_look` (`:1643`): one batched `tmux capture-pane` for the agents' screens (`:1649-1650`), one `jq` over the Claude Code records (`:1669`), then per agent `claude_look`, `ctx_left`, `limit_look` and `claude_acct`/`codex_acct`, which use further `jq`, `stat` and `head`;
  - then `outside_ssh` and `remote_panes` (`:1816`).
- `draw` (`scripts/panel.sh:3041`) then calls `messages` and `links_saves` (`:3083`). These run `awk`, `find`, `wc` and `jq` from inside the draw (`:2909-2911`, `:2927`).
- `draw` does more I/O of its own than that, which matters for testing (Phase 0.1):
  - the peek's `tmux capture-pane -p` (`:2621`) and the question's (`:2737`);
  - `qhi`'s coloured `capture-pane -e -p` for a question's tab bar (`:2759`);
  - for a linked pane, `remote_peek` (`:1987`), which under `--once` asks over ssh there and then (`peek_fetch … now`, `:1995`) and checks the file's age with `find -mmin -1` (`:1996`);
  - `draw_panes` reads `$ASTATE/intros/*/from` (`:2351`).
- A key pressed meanwhile waits for all of it. Arrow keys skip `gather` (`nav=1`, `:5130`; checked at `:5146`) but still run a full `draw` (`:5190`).

### Answering a question freezes the page

`answer()` (`scripts/panel.sh:3991-4122`) is a loop of its own. While it runs, the main loop doesn't:

- No `gather` runs. `draw` reuses the rows above the question from the first frame, `ATOP` (`:3068-3074`). The comment says so: "nothing above the question can change (no panes are gathered meanwhile)".
- Messages aren't looked at (`MSG_OLD=1` when `ask`, `:3080-3081`).
- The one thing it speeds up is the linked peek: `PEEK_EVERY=0` (`:3998`) removes the gap between asks (`:1866`, `:1969`), so the question's screen is fetched as often as it can be.

That is the user's complaint: pressing Enter to answer stops the rest of the page updating.

Because nothing is gathered, `SEL` cannot move while bash answers, and bash relies on that: `send_answer` (`:3852-3864`), `paste_answer` (`:3835-3850`), `question_look` (`:3868-3880`) and `q_fresh` (`:3924-3946`) all read `P_ID[SEL]`, `P_HOST[SEL]` and `P_RID[SEL]` afresh on every call, though `answer()` copied `h` and `id` into locals at the start (`:3992-3996`). In bash that is safe. In a panel whose PANES keeps updating it is not: the main loop re-picks `SEL` by `SEL_ID` after every gather (`:5173-5176`), so a pane appearing above the asking one would move the keys to a different pane.

### Measured baseline: the numbers to beat

(unverified: measured by the user in an earlier session and relayed in the task brief; not re-measured for this plan, because a live `--once` would ask the user's linked production servers for rows.)

- At load ~12 on 4 cores, `gather` took 0.4–2.5 s per round, and `draw` took 0.2–0.5 s.
- A cold `--once` ran about 370 programs (88 `head`, 87 `readlink`, 49 `git`, 28 `grep`, 13 `jq`, …) and took 4–16 s at load 20.

## Approach

### One binary, `tmux-revive-panel`, for the live panel and `--once` only

- Every remote and daemon mode keeps going to bash, so linked servers and `daemon.sh` see no change:
  - `bin/tmux-revive:336` forwards every argument to `scripts/panel.sh` today.
  - Links call `tmux-revive panel --rows/--peek/--keys/--paste` (`scripts/panel.sh:1855-1858`).
  - The daemon calls `panel.sh --asking/--running` directly (`scripts/daemon.sh:88`, `:118`).
- The dispatcher sends only a bare `panel` (and `--once`) to the binary.
- Inside the binary, the work splits into three layers:
  1. **Render.** A direct port of the line builders. Pure functions from a `Snapshot` plus UI state to `Vec<Vec<u8>>` (bash's `OUT[]`, as byte strings: see Bash-compat semantics), then the same diff-and-`?2026` writer as `scripts/panel.sh:3248-3256`.
  2. **Collectors.** One thread per data source. Each publishes an immutable, versioned snapshot behind an `Arc` swap and never touches the terminal.
  3. **UI thread.** Input and drawing, never blocking. Anything that waits on a program (ssh, `agent-say`, `tmux display-popup -E`, `save.sh`) runs on a worker, and its result comes back as an event. Multi-step key flows run on a flow thread of their own (below).

### Why not the alternatives

- **ratatui:** ruled out by the user. It would also lay cells out itself, which breaks byte identity.
- **A faster bash panel** (fewer forks, background subshells): it can't make `answer()` and the rest of the page run at once without rebuilding the program as an event loop. Bash has no threads; subshells can't share arrays back without files.
- **A persistent tmux control-mode client** (`tmux -C`) in place of `list-panes`/`capture-pane` execs: worth having later. But the test suite's tmux shim counts exact argv (`test/panel.sh:343-359`, `:1337-1344`), so the first version runs the same tmux commands, with the same arguments, from `PATH`.

### Concurrency design

The UI thread owns `UiState`: selection, focus, scroll offsets, modal stack, flash, `PREV`, TICK. It loops on `poll(2)` over stdin and an eventfd/self-pipe that collectors and workers write to, with a timeout for the animation tick (bash's `read -t $REFRESH`, `:5193-5196`). On each wake it:

1. drains stdin into key events (the same sequence parsing as `keys()`, `:5103-5141`, and the modals' own parsers);
2. applies them to `UiState`;
3. if anything changed (input, a new snapshot version, the tick), renders from the latest snapshots and writes the diff.

A render that reads only in-memory snapshots has no I/O, so an arrow key costs one render.

| Collector | Replaces | Cadence | Notes |
|---|---|---|---|
| `procs` | `ps -ww -eo pid=,ppid=,uid=,rss=,pcpu=,args=` (`:1716`), `tree_ticks` (`:1550`), `proc_cwd` readlink (`:1153`), `proc_start` (`:1157`), `lbox_young` (`:4841`), `listen_load`'s `ss -Hltnp`, else `lsof -nP -iTCP -sTCP:LISTEN -Fp` (`:836-846`) | every REFRESH (2 s, `:55`) and on a "look again" kick | Reads `/proc` directly on Linux, taking a process's name from its argv (`/proc/PID/cmdline`) as `ps args=` does, never from the 15-character `comm`. macOS has no `/proc`: bash's own fallback runs `ps` and sums `pcpu` (`:1763-1771`), and `lsof` for cwd (`:1155`), so the macOS backend runs `ps`/`lsof` the same way. A `ps` backend selectable by env serves the test stubs (see Test seams). |
| `tmux` | `list-panes -a -F …` (`:1728`), the batched agent `capture-pane` (`:1649-1650`), `opt @revive-interval` (`links_saves`, `:2925`) | every REFRESH | Same argv as bash, through `tmux` on PATH, honouring `REVIVE_SOCKET`/`REVIVE_UMASK` as `tm()` does (`scripts/common.sh:17-23`). |
| `agents` | `claude_record`, `claude_look`, `claude_transcript`, `codex_rollout`, `ctx_left`, `limit_look`, `claude_acct`/`codex_acct`, `wait_watch` (`:680-1500`) | after each `procs`+`tmux` pair | `jq` replaced by `serde_json`, filter by filter (bash-compat step). Keeps bash's mtime caches (`ctx_cached` `:1043`, `lim_cached` `:1426`) and 30 s caches (`:1095`, `:1190`). |
| `git` | `git_info` (`:1528`) | per folder, 15 s TTL as now (`:1533`) | A small worker pool. It runs `git` with the same `pgit` flags (`:1527`), including the repo-filter check (`:1538-1543`). It never blocks a render: a miss shows the last value, or nothing. |
| `links` | `remote_fetch`/`rows_get`/`fetch_rows` (`:1925-1945`), `remote_panes` (`:2007`) | per host, ≥10 s apart, one in flight (`:1940-1942`) | Calls `remote_run` semantics (`:1874-1924`) unchanged, including `agent-say _key-opts/_ride/_pin`. Writes the same `$RDIR/HOST.rows` cache files, so bash and Rust panels can share it. |
| `peek` | local `capture-pane` for the selected pane; `peek_fetch`/`peek_get`/`peek_drop` for linked ones (`:1949-1986`); `qhi`'s `capture-pane -e` (`:2759`) | REFRESH | Only the selected pane, as now (`:3097-3104`). While answering, the send worker looks at the frozen pane instead (below). |
| `mail` | `messages` (`:2837`), `links_saves` (`:2915`), `fold_load` (`:2224`), intros (`:2351`, `:2844`)/grants/queue | REFRESH, and on a "look again" kick | These move out of the draw path entirely. |
| `upd` | `upd_job`/`upd_poll` (`:4170`, `:4234`) | event-driven (child exit) | Each `U` job is a child process. Its result comes back as an event. |

**PANES is published as one generation.** `gather` builds the agent rows positionally: `A_AT` holds indexes into `P_ID` (`:1779`), and `agents_look` writes `P_*[A_AT[j]]` back by those indexes (`:1661-1684`). If `procs`, `tmux` and `agents` published separately, a render could join a new pane list with agent results computed for the old one. So the three publish one `PanesGen`, keyed by pane id (`P_ID`), and a render reads exactly one generation. `git` results join by folder and `links` by host; a stale value there is the last value, never another pane's.

**The loading bar is fed by progress events.** `load_bar` runs inside `gather`: once the pane list is in (`:1731`), after each pane (`:1807`), after the agents (`:1810`) and at the end (`:1818`); the loading box's spinner is drawn at `:4817`. The collectors publish per-pane progress events (`done`, `total`) so the loading screen counts off the same steps.

**Answering targets a frozen pane.** When answering starts, the UI thread records the target `(host, P_ID, P_RID)` and the pane's display name (used by the ANSWERING bar, `:3227`, and the "has its answer" flash, `:4118`). Every send, paste and look while answering takes that frozen target, never `SEL`. `P_STATE == asking` is still read from the snapshot for drawing. Answering ends as bash's does, from the looks (Q7).

**Decisions made after a send run in the send worker.** Several of `answer()`'s decisions depend on a look taken after the previous keys have landed:

- Enter on a free-text dialog runs `q_fresh` first (`:4064-4068`), because Enter on the empty "Type something" row declines the whole question (`:4060-4061`);
- `free_answer` looks (`q_fresh`) before and after each step of moving onto and emptying the row (`:3954`, `:3968-3977`), then pastes (`:3979`);
- `q_fresh` looks until the screen holds still, so "the keys just sent have landed" (`:3921-3923`, `:3936-3940`).

And the token mapping itself depends on the last look: `QFREE`/`QON` (`:4048-4056`) are set by `question_free` after each loop pass's look (`:4009-4011`), which runs after sends and on every idle 0.3 s poll alike; the same look feeds the answered test (`:4013-4022`). So the UI thread does not turn keys into tokens. It forwards raw keys, in order, to one send worker per frozen target. The worker owns the question state, `QFREE`, `QFREEN`, `QFTXT`, `QON`, `QEMPTY`, `QHAS`, `QCUR`, `QASK`, `QLAST` (`:3957-3978`, `:4048-4067`), and runs `answer()`'s whole look loop: the 40 ms and 0.3 s polls (`:4030-4037`), `question_free` after each look, and the answered test. It maps each key with `answer()`'s rules, runs every send and every deciding look in order, and publishes its looks to the UI as display events. `free_answer`'s `edit_box` sits between two looks (`:3954-3968`): the worker posts "open the answer box" to the UI and blocks on a channel for the box's result (text or cancel), then carries on. While answering, the `peek` collector does not look at the frozen pane; the worker's looks are what is drawn, so the display and the decisions come from the same look, as in bash.

**Multi-step key flows run on a flow thread.** The B flow (`:4404-4585`) and the G flow (`:4587-4682`) are sequential scripts: up to five `pick`s and an `ask` in B (`:4446`, `:4450`, `:4474`, `:4514`, `:4546`, `:4577`), three `pick`s and two `code_popup`s in G (`:4612`, `:4656`, `:4658`, `:4668`, `:4671`), with ssh and `agent-say` calls between. Each open flow runs on its own thread, written as the same straight-line code as bash, and blocks on a channel for each pick, ask or popup result; the UI thread draws the modal and answers the channel. No hand-written state machines.

**Terminal modes stay as bash's.** The panel runs with `stty -echo -icanon` only (`:5085`): `ISIG` stays on, so Ctrl-C arrives as SIGINT (`trap 'exit 0' INT TERM` `:5089`; while answering `trap 'INTR=1' INT` `:4000`, read at `:4039`), and `ICRNL` stays on, so Enter arrives as `\n` (the main loop also takes `\r`, `:5112`). The Rust panel sets the same termios flags and handles SIGINT through a self-pipe that the UI loop polls. Raw mode (`-icrnl -isig`, with its own reader) is only for `edit_box` (`:3403-3407`), as in bash.

### Rules carried over as hard constraints

These are rules, not tuning:

- **No ssh attempt while a link has `login` or `paused`** (`:1880`). The user was banned once for repeated attempts (unverified: memory note `no-connection-retries`).
- **One fetch in flight per host,** at most one every 10 s (`:1940-1942`). Peek fetches are at most one per `PEEK_EVERY` (`:1969-1970`).
- **No retries anywhere.** A failed fetch leaves `.fail`/stale rows exactly as bash does (`:1956-1961`).
- **Keys and pastes are checked** by `key_ok`/`paste_ok` semantics (`:3776`, `:3811`) before anything is sent.
- **Which keys look again.** The keys that only redraw are `up down pgup pgdn home end J K 0-9` (`nav=1`, `:5130`; `j`/`k` become down/up first, `:5127`). `p P a A` draw at once from what was gathered and then look again (`:5131-5134`). Every other key looks again (`:5136`). The suite asserts the first (`test/panel.sh:357`, counting `show-option -gqv @revive-interval` in the shim log, `:349`) and the last with `a` (`:358-359`).
- **Each collector is independent.** A slow `git`, a hung ssh, or the answer dialog's 40 ms polling delays only its own section.

### The one intended behaviour change

While answering, bash freezes everything above the question (`ATOP`, `:3068-3074`). The Rust panel keeps updating the banner, PANES and the spark. MESSAGES and LINKS · SAVES stay hidden while the selected pane asks, as bash's layout hides them (`msgs=0`, `:3062-3063`); their collectors keep running, so they are current the moment the question goes. This is the user's request.

Byte identity is still defined frame by frame: given the same snapshot, the Rust frame equals bash's. Only the moment snapshots change differs. The same holds behind a modal: bash gathers nothing while `pick`, `ask`, `note` or `edit_box` is up, and the Rust panel keeps updating underneath. These composites have no bash oracle; they are checked as the reviewer's decision above says.

### How byte identity is reached and checked

- **Port the builders, don't reinterpret them.** Every function in the Render group below is translated line for line, with its bash name kept as a comment. Bash stores results in globals (`REP`, `FLD`, `PADV`, `ART`…). In Rust they become return values.
- **Bash-compat semantics, made explicit** (Step 1.2). Each is a Rust helper with its own unit tests against bash:
  - **Strings are byte strings** (`Vec<u8>`/`&[u8]`) from collection to the writer, never `String`. Text from panes, files and other computers need not be valid UTF-8.
  - `${#s}`, `${s:0:n}` and `printf '%*s'` widths count characters the way bash decodes them: a valid UTF-8 sequence is one character, and each byte that doesn't decode is one character. Re-runnable: `printf 'x\xffy' | bash -c 'IFS= read -r s; echo ${#s}'` prints `3`, and `LC_ALL=en_US.UTF-8 bash -c 's=$'"'"'\xe2\x82'"'"'z; echo ${#s}'` prints `3` (a cut-short sequence counts per byte). `fld` (`:92-95`) and `padv` (`:101-104`) pad an empty string, so byte widths never enter. Rust uses a decoder with exactly that rule, never `unicode-width` and never `str::chars()` (which can't hold invalid bytes).
  - `vlen` strips only `ESC[` digits/`;` `m` (`:96-100`).
  - `clean` drops `[[:cntrl:]]`, C1 (U+0080–U+009F) and the listed bidi and zero-width characters (`:105-117`).
  - Shell arithmetic is signed 64-bit with truncating division. `rnd` is `(SEED*1103515245+12345) & 2147483647`, `RV = SEED >> 8`, seeded `7919*(SCENE+1)` (`:309`, `:380`).
  - `printf '%(fmt)T'` goes through libc `strftime` with `TZ`, and with `LC_TIME` for `%a`/`%b` (`:3001`, `:3010`, `:1493-1498`, `:1331`, `:1365`, `:1372`, `:2893`, `:4595`). Rust calls libc `localtime_r`+`strftime`, not chrono.
  - **`=~` is POSIX ERE through libc.** `man bash`: "the string to the right of the operator is considered a POSIX extended regular expression and matched accordingly (using the POSIX regcomp and regexec interfaces …)". `panel.sh` has 145 lines with `=~` (157 uses; `grep -c '=~' scripts/panel.sh`, `grep -o '=~' scripts/panel.sh | wc -l`). Rust calls libc `regcomp(REG_EXTENDED)`/`regexec`, not the `regex` crate, whose syntax and bracket classes differ. Two sites run under `shopt -s nocasematch` (`:1349-1351`, `:1518-1522`) and need `REG_ICASE`.
  - **Glob order is collation order.** `man bash` (GLOBSORT): with it unset, "pathname expansion uses the historical behavior of sorting by name, in ascending lexicographic order as determined by the LC_COLLATE shell variable". Re-runnable: in a directory holding `B/ a/ _c/`, `LC_ALL=en_US.UTF-8 bash -c 'echo */'` prints `a/ B/ _c/` and `LC_ALL=C` prints `B/ _c/ a/`. The order-visible globs are `links/*/` (`:2014`, rows of linked computers; `:2934`, LINKS · SAVES rows; `:4412`, `:4431`, B's lists; `:5157`, which decides which login flash is shown last), `peers/*/` (`:2958`, LINKS rows) and `intros/*/` (`:2351`, `:2844`, `:4596`, `:4627`, G's lists). Rust lists the directory and sorts with libc `strcoll` under the same locale.
  - **Hash iteration order.** `outside_ssh` walks `${!PARGS[@]}` (`:2146`), an associative array (`declare -A … PARGS`, `:625`), so `X_SSH`/`X_WHERE` come out in bash's hash order, which orders the LINKS rows (`:2974-2979`) and B's list (`:4425-4428`). Rust can't reproduce that order. Fix: sort them in bash, `X_SSH` and `X_WHERE` together as pairs, by (host, where) (Step 0.1): hosts are not de-duplicated (`:2167`) and the lists show the first `X_WHERE` for a host, so sorting by host alone would leave a tie in hash order, and the same in Rust. The comparison is byte order (C), not the locale's collation: as built, `xssh_sort` keys each pair as `host\x1fwhere` (`\x1f` sorts before every character a host or a cleaned `where` can hold) and insertion-sorts with `[[ > ]]` under `local LC_ALL=C`, with no fork, and only when there are two or more; Rust sorts the same keys with a plain byte comparison. This changes the order of those rows in the live bash panel too; it lands in both. The other loops over associative arrays (`:983`, `:1122`, `:1206`, `:1844`, `:5088`; swept with `grep -nE '\$\{!(NAMES)\[@\]\}'` over every `declare -A` name, plus the `local -A` loops at `:1813` and `:4702-4703`) don't decide anything visible: `:1122` and `:1206` look for any peer in the same folder, `:983` copies, `:1844` writes a cache file, `:5088` removes files.
  - The panel forces a UTF-8 locale when the charmap isn't one (`:44-49`). The Rust panel does the same `setlocale` dance.
  - The `ART_MEMO` cache (`:366-386`) is an optimisation with no visible effect. Port it or not, but frames must match with or without it.
- **The oracle is made deterministic first** (Phase 0). Several inputs to `--once` are not pinned today:

  | Input | Where | How it is pinned |
  |---|---|---|
  | Wall clock in the banner | `:3001`, `:3010` | test-only `REVIVE_PANEL_NOW=EPOCH` (Q1) |
  | "Now" in wait colour, limit time, approved count | `:1024`, `:1494`, `:2908` | same hook |
  | Tip rotation | `tip_line`, `SECONDS / TIP_SECS` (`:2592`) | `SECONDS` counts from the shell's start, through both gathers and `sleep 0.5` (`:5060-5062`), so it is not ~0. The snapshot carries `SECONDS` as `draw` sees it, and Rust renders with it; tier 2 masks the tip line. `REVIVE_PANEL_TIP_SECS` (exists, `:2588`) is set only in tier 1 |
  | CPU between two gathers 0.5 s apart | `:5060-5062`, `:1746-1762` | snapshot hook (Q1); in the live-collector tier, CPU and spark cells are masked |
  | Random scene | `SCENE=$((RANDOM % ${#SCENES[@]}))` (`:299`) | `REVIVE_PANEL_ART` (exists, `:300`) |
  | Art animation frame | `TICK` | `REVIVE_PANEL_TICK` (exists, `:5059`) |
  | Selection | `SEL` | `REVIVE_PANEL_SEL` (exists, `:5064`) |
  | Peek on | `PEEK` | `REVIVE_PANEL_PEEK` (exists, `:2172`) |
  | Help page | `HELP` | `REVIVE_PANEL_HELP` (exists, `scripts/help.sh:17`; used by `hframe`, `test/panel.sh:455`) |
  | Loading box | `LBOX` | `REVIVE_PANEL_LOADBOX` (exists, `:4837`, `:4874`) |
  | Draw-time I/O: peek and question captures, `qhi`'s coloured capture, `remote_peek`'s fetch and its `-mmin` check, intros, folds | `:2621`, `:2737`, `:2759`, `:1995-1996`, `:2351`, `:5065` | in the snapshot (0.1); read from it in load mode |
  | UI state with no hook | `FOCUS PB MO SO MMAN` (`:2190`), `HSEL` (`:2222`), `FLASH`/`FLASH_T` (`:2172`, shown while `SECONDS - FLASH_T < 5`, `:3224`), `HELP_TOP` (`scripts/help.sh:11`), `ANSWERING QON QFREE QEMPTY QHAS` (`:2172-2173`) and `QL` (set by `question_look`, `:3868-3880`) | in the snapshot (0.1) |
  | Host name, user | `HOST` (`:57`), `$USER` (`:3004`) | same process environment for both |

- **Three test tiers:**
  1. **Render goldens (strict bytes).** Bash `--once` with `REVIVE_PANEL_SNAP=save:F` writes what `gather` produced and what `draw` would read from outside. Then `bash panel.sh --once` with `REVIVE_PANEL_SNAP=load:F` and `tmux-revive-panel --once --snapshot F` both render from it, and the outputs are compared with `cmp`. This isolates the port of `draw` from collection. It includes the ANSWERING bar, which is built into `OUT[]` (`:3226-3234`), from the snapshot's UI state.
  2. **Collector goldens.** Both `--once` runs run against the private tmux fixtures of `test/panel.sh` with their own gathers. They are compared byte for byte after masking the CPU and memory columns (memory is a live RSS sum, `:1744`), the spark row and the tip line, which are measured over wall time. This proves the collectors find the same panes, agents, states, context, limits, git and links.
  3. **Live twins.** Things `--once` can't reach, because they are written straight to the terminal outside `OUT[]`, or are composites:
     - `pick`, `ask`, `note`, `edit_box`;
     - the loading screen and loading box;
     - the splash;
     - the code and login popups;
     - answering and modals over a panel that keeps updating (the composites).

     How the twins run:
     - **Two separate private tmux servers** (`tmux -L twin-bash`, `tmux -L twin-rs`) with identical fixtures, one panel each. In one server each panel would list the other's pane, as a program the other can't match: a pane counts as `self` only when its id is the panel's own `TMUX_PANE` (`:1773-1774`).
     - `REVIVE_PANEL_REFRESH=60` so TICK holds still, and a live-mode clock hook (`REVIVE_PANEL_NOW`, Q1) so the banner clock matches.
     - The same keys are sent to both, and `tmux capture-pane -e -p` outputs are compared as screens, not raw byte streams: the two diff writers may emit different update sequences for the same final screen. The writer itself is byte-checked separately (Step 3.1).
     - Masks: CPU, spark and memory cells always. For the answering and modal twins, the banner and PANES are masked too (bash's are frozen; Rust's update). The modal box and the question area are compared unmasked.
     - The cursor is compared too, through `tmux display -p -t … '#{cursor_x},#{cursor_y},#{cursor_flag}'`: `edit_box` places and shows it (`:3662`); everywhere else it is hidden and parked at the top (`:3255`, `:5080`).

### Distribution

- **Build.** `scripts/release.sh` builds the binaries from the release commit, after its `VERSION` commit (`scripts/release.sh:72-77`), with `cargo zigbuild` for each target:
  - `x86_64-unknown-linux-gnu.2.17`, `aarch64-unknown-linux-gnu.2.17`;
  - `x86_64-apple-darwin`, `aarch64-apple-darwin`, or one `universal2-apple-darwin`.

  This is unverified until tried: `zig` and `cargo-zigbuild` are not installed here (`which zig cargo-zigbuild` finds neither; `rustc 1.99.1` and `cargo` are in `/usr/bin`).
- **Sign.** The release puts each binary as its own asset, `tmux-revive-panel-VERSION-OS-ARCH`, and adds a line for each to the signed `SHA256SUMS`. Old installers keep working: they accept only the line matching `^[0-9a-f]{64}  tmux-revive-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz$` and require exactly one such line (`install.sh:187-189`). An asset name that doesn't end `.tar.gz` doesn't match.
- **Why not a pinned sha256 in `install.sh`, as jq has** (`install.sh:29-39`):
  - jq's sum is pinned because jq comes from a third party, "so a tampered release can't vouch for itself" (`install.sh:30-31`).
  - The panel binary is built from the same commit as `install.sh`, so a sum pinned in `install.sh` can't describe it.
  - The signed `SHA256SUMS` is already the trust root for the tarball (`install.sh:184-200`), so it vouches for the binary the same way.
  - Asset selection follows jq's `uname` table (`install.sh:722-728`).
- **Fetch.** A release install hands over to the release's own installer, `_REVIVE_ORIGIN=… REVIVE_SOURCE=$tmp/src sh $tmp/src/install.sh` (`install.sh:701-702`). That installer re-copies the source with `--exclude=vendor` (`install.sh:696`), then moves `$tmp/src` into place: the old `$APP` is moved aside, `mv "$tmp/src" "$APP"`, and the old one removed (`install.sh:752-755`). So:
  - the outer installer passes the verified `SHA256SUMS` path on (`_REVIVE_SUMS`, next to `_REVIVE_ORIGIN`);
  - the inner one downloads the asset into `$tmp/src/vendor/bin/tmux-revive-panel`, as jq goes into `$tmp/src/vendor/bin/jq` (`install.sh:731-737`), so it moves into `$APP` with everything else. Anything written into `$APP` before `:752-755` would be thrown away with the old tree.

  An older outer installer passes nothing (Q4).
- **No compiling.** `install.sh:2` promises "No git, no compiling", and it is kept: no path in `install.sh` runs `cargo`. A follow-main install (`REVIVE_REF`, `install.sh:704-716`) has no release assets and gets the bash panel.

## Feature inventory

Every function in `scripts/panel.sh`: 181 at `475f43a`, by `grep -n '^[a-zA-Z_][a-zA-Z0-9_]*()' scripts/panel.sh | wc -l`. Each is assigned to a Rust module and a phase. "Bash only" means it stays in `panel.sh`, not ported.

### Remote and daemon modes: bash only, unchanged

- Mode parsing: `:28-42`.
- `--peek`: `:4921-4936`.
- `--keys`: `:4938-4946`.
- `--paste`: `:4948-4955`.
- `--show`: `:4957-4963`.
- `--asking`: `:4964-4984`.
- `--running`: `:4985-5010`.
- `--rows`: `:5011-5057`.
- Their helpers stay too, for these modes and as the bash fallback:
  - `rows_ticks_load` (`:1823`), `rows_ticks_save` (`:1837`);
  - `keys_send` (`:3797`), `paste_send` (`:3827`), `paste_hex` (`:3822`), `pane_here` (`:3851`).

  The Rust panel reimplements `key_ok` (`:3776`), `lit_tokens` (`:3790`), `paste_ok` (`:3811`) and the local `keys_send`/`paste_send` for its own answering. The bash copies are untouched.

### Render: Phase 1 (strict goldens)

- Primitives:
  - `rep` `:91`, `fld` `:92`, `vlen` `:96`, `padv` `:101`, `clean` `:113`, `line` `:118`, `row` `:119`, `sbar` `:138`;
  - `tab` `:162`, `seg` `:166`, `sectk` `:179`, `sect` `:185`, `sect2` `:188`;
  - `trim_colored` `:3259`, `kc` `:2564`, `kcs` `:2565`, `wstyle` `:2204`, `ver_lt` `:63`.
- Banners and gauges:
  - `banner_rows` `:202`, `big_banner` `:221`, `monitor` `:260`, `spark` `:279`, `meter` `:608`, `human` `:617`;
  - `state_cell` `:2296`, `ctx_cell` `:2554`, `tip_line` `:2590` with the `TIPS` list (ends `:2586`).
- Art:
  - `canvas` `:304`, `put` `:305`, `rnd` `:309`, `emit` `:310`, `stars` `:342`, `twinkle` `:354`, `art` `:366`;
  - the five scenes `scene_city` `:388`, `scene_mountains` `:439`, `scene_space` `:499`, `scene_circuit` `:523`, `scene_grid` `:566`;
  - their helpers `tri` `:420`, `pixel_cell` `:429`, `mpix` `:483`, `cloud` `:557`.
  - `SCENES`/`TITLES` are at `:296-297`.
- Frame:
  - `draw` `:3041`, `draw_top` `:2986`, `draw_panes` `:2347`;
  - `draw_peek` `:2601`, `blank_tail` `:2633`, `peek_wrap` `:2648`, `peek_rows` `:2682`;
  - `draw_question` `:2718`, `qhi` `:2753`, `question_parts` `:2794`;
  - `lim_when` `:1489`, `wait_colour` `:1019`;
  - the key bar and ANSWERING bar (`:3217-3238`).
- Navigation model (pure state):
  - `panes_rows` `:2238`, `nav_at` `:2247`, `nav_stop` `:2257`, `nav_go` `:2266`, `sel_fix` `:2285`, `tab_next` `:2192`;
  - `scroll` `:4746`, `fold_toggle` `:2225`.
- Help page: `scripts/help.sh`, 22 functions. It is drawn in place of everything below the banner (`:3025`), from `scripts/help.txt`:
  - `help_wrap` `:71`, `help_ink` `:93`, `hpush` `:105`, `hhang` `:112`, `hpara` `:123`, `hrule` `:129`;
  - `hbutton` `:142`, `hbtn_flush` `:155`, `hbox_close` `:163`, `hflush` `:179`, `hart` `:224`, `hart_close` `:254`;
  - `help_build` `:270`, `help_frame` `:398`, `help_view` `:457`, `help_confirm` `:501`, `help_install` `:539`, `help_open` `:556`;
  - `what` `:59`, `workforce_cmd` `:27`, `codex_cmd` `:38`, `playwright_cmd` `:49`.

  The Rust panel reads the same `help.txt` at run time.
- **Constants to port verbatim** (regexes go through `regcomp`, above):
  - `Q_RE`, `W_RE` (`:660-661`), `VER_RE` (`:60`), `KEY_RE` (`:3775`), `PW_STUB` (`:2647`), `EB_RE` (`:3531`);
  - `REMOTE_ROWS_CMD`, `REMOTE_PEEK_CMD`, `REMOTE_KEYS_CMD`, `REMOTE_PASTE_CMD`, `REMOTE_UPDATE_CMD`, `REMOTE_NAME_CMD` and `PASTE_SINCE` (`:1855-1864`);
  - `SHELLS` (`:628`).

### Collectors: Phase 2

- `procs`:
  - `gather` `:1710` (its tree walk, CPU and memory);
  - `agent_kind` `:664`, `shell_job` `:633`, `SHELLS` `:628`;
  - `tree_ticks` `:1550`, `usecs` `:1564`, `proc_cwd` `:1153`, `proc_start` `:1157`;
  - `user_of` `:1580`, `user_inst` `:1594`, `own_plain` `:707`;
  - `outside_ssh` `:2142`, `ssh_dest` `:1617`, `snapshot_cmd` `:818`, `listen_load` `:836` (`ss -Hltnp`, else `lsof`, `:840-846`), `bg_serving` `:850`.
- `tmux`:
  - the pane list (`:1728`);
  - `agents_look` `:1643` (screens batched);
  - `screen_state` `:1501`, `lines_state` `:1506`.
- `agents`:
  - `claude_record` `:680`, `acct_read` `:722`, `claude_acct` `:747`, `codex_acct` `:783`;
  - `claude_look` `:876`, `claude_turn_from` `:929`, `iso_epoch` `:951`, `mail_times` `:963`, `wait_watch` `:980`;
  - `fstamp` `:1042`, `ctx_cached` `:1043`, `codex_ctx_file` `:1050`, `codex_wait_at` `:1063`, `codex_waits` `:1073`;
  - `claude_transcript` `:1091`, `codex_meta` `:1169`, `codex_rollout` `:1181`, `ctx_reported` `:1251`, `claude_tfile` `:1261`, `ctx_left` `:1281`;
  - `tz_off` `:1329`, `local_epoch` `:1334`, `lim_reset` `:1344`, `lim_at` `:1382`;
  - `claude_limit_file` `:1388`, `codex_limit_file` `:1402`, `lim_cached` `:1426`, `lim_base` `:1437`, `limit_look` `:1456`;
  - `ctx_pct` and `claude_ctx_file` (`scripts/common.sh:125`, `:131`).
- `git`: `pgit` `:1527`, `git_info` `:1528`.
- `links`:
  - `ssh_dest` `:1617`, `linked` `:1635`, `cache_dir` `:1867`, `remote_run` `:1874`;
  - `fetch_rows` `:1925`, `rows_get` `:1928`, `remote_fetch` `:1936`, `remote_panes` `:2007`.
- `peek`: `peek_get` `:1949`, `peek_fetch` `:1963`, `peek_drop` `:1982`, `remote_peek` `:1987`.
- `mail`:
  - `messages` `:2837`, `links_saves` `:2915`, `fold_load` `:2224`;
  - the `SSH_SEEN` and `LOGIN_SEEN` flashes (`:5148-5166`).
- **`jq` filters to port exactly.** Each gets a fixture test against `jq` itself:
  - `scripts/panel.sh:730` (run with the account programs below as its arguments), `:885`, `:944`, `:1053`, `:1065`, `:1176`, `:1290`, `:1391`, `:1405`, `:1669`, `:2927`;
  - the account programs `CL_PLAN_JQ`, `CX_TOKEN_JQ`, `CX_PLAN_JQ`, `CL_ACCT_JQ` (`:742-746`); `CX_TOKEN_JQ` decodes a JWT with `@base64d` and `fromjson?` (`:743-744`);
  - `scripts/common.sh:138`.
- **Environment the collectors read**, each honoured as bash does:
  - `REVIVE_PANEL_OUTSIDE_SSH` (`:2140`, `:2145`), `REVIVE_PANEL_LOADBOX` (`:4837`, `:4874`), `REVIVE_VERSION_FILE` (`:61`, `:4242`);
  - `AGENT_SAY_SSH` and `RTIMEOUT` (`:1891`, `:1912`, `:1922`; `RTIMEOUT=300` for a remote update, `:4227`), `AGENT_SAY_MAILBOX` (`:52`, `:3285`, `:3317`);
  - `CODEX_HOME` (`:714`, `:790`, `:796`), `CLAUDE_CONFIG_DIR` (`:684`, `:692`, `:712`);
  - `REVIVE_DIR`, else the tmux option `@revive-dir`, else `${XDG_DATA_HOME:-$HOME/.local/share}/tmux-revive` (`scripts/common.sh:32-35`);
  - `PATH` with `$REVIVE_ROOT/vendor/bin` put first when it exists (`scripts/common.sh:7`), so the private jq, and every program the panel runs, resolve the same way.

### Interactive loop: Phase 3

- Startup:
  - the UTF-8 locale (`:44-49`);
  - splash (`splash` `:4775`, the `REVIVE_PANEL_SPLASH`/`@revive-panel-splashed` logic `:5091-5095`);
  - the loading screen (`loading` `:4799`, `load_bar` `:4815`, with `LOAD_AT` cleared once the first look is in, `:5168`), fed by the collectors' progress events;
  - the loading box: `lbox_young` `:4841`, `lbox_count` `:4851`, `lbox_off` `:4868`, `lbox_check` `:4870`, `lbox_draw` `:4891`, and keys while it is up (`:5106-5111`).
- Terminal:
  - the alternate screen, hidden cursor and `stty -echo -icanon` (`:5079-5085`), with `ISIG` and `ICRNL` left on;
  - restoring on exit (`restore_term` `:4768`);
  - removing fetched peek files on exit (`:5088`);
  - INT and TERM (`:5089`);
  - WINCH (`:5090`);
  - stderr to `$RDIR/panel.err`, capped at 64 KB (`:5075-5079`).
- Loop:
  - the gather/draw cadence `REVIVE_PANEL_REFRESH` (`:55`);
  - TICK advancing only on a timeout (`:5195`);
  - a full repaint every 15 s (`:5189`);
  - the held-key-during-gather rule (`:5180-5186`);
  - keeping `SEL_ID` across pane changes (`:5172-5176`);
  - `UPD_N` polling (`:5170`).
- Key decoding: `keys()` (`:5103-5141`). It handles escape sequences, Tab, j/k, the batching of held arrows, and the immediate draw for `p P a A`.
- Flash: `flash` (`:3273`), shown for 5 s on the key bar (`:3224`).
- The tip line: under a hidden peek's title (`:3121-3130`).

### Keys and modals: Phase 4

The bindings in `act()` (`:4344-4741`; case labels found with `awk 'NR>=4344 && NR<=4745 && /^\t[^\t#].*\)( |$)/' scripts/panel.sh`):

| Key | Does | Lines |
|---|---|---|
| `o O` | open the pane (switch-client/select-window/select-pane); outside tmux, `exec tmux attach`; popup mode exits | `:4354-4370` |
| `m M` | message the pane through `edit_box`, then `agent-say --from panel` | `:4371-4378` |
| `n N` | rename, here (`agent-say name`) or on a linked host (`remote_run name`) through `ask` | `:4379-4403` |
| `b B` | link, relink, login, unlink and link-key flow: `pick`, `read_host_keys`, `login_window`, `agent-say link/unlink` (a flow thread) | `:4404-4585` |
| `u U` | update jobs (`upd_show`) | `:4586` |
| `g G i I` | access: intros and grants, `code_popup` approve/refresh, deny/revoke (a flow thread) | `:4587-4682` |
| `p P` | peek on or off | `:4683` |
| `Enter` | fold/unfold a heading, or `answer()` on an asking pane | `:4686-4688` |
| `f` / `F` | fold one computer / all of them | `:4691-4705` |
| `a A` | next art scene | `:4706-4708` |
| `s S` | `save.sh manual` | `:4709-4710` |
| `d D` | detach after a `pick` confirm | `:4713-4718` |
| `q Q` | quit | `:4719` |
| `?` | help page (`help_view`) | `:4720` |
| `0-9` | jump to tmux window N (0 is 10 when there's no window 0) | `:4726-4734` |
| arrows, PgUp/PgDn, Home/End | `scroll` in the focused window | `:4735` |
| `J` / `K` | focus the next or previous window | `:4737-4738` |

Modals and popups:

- `pick` (`:3674`): `PKEYS`, `PKROWS`, `PHINT`, `PSEL`, `PTICK`, `PBAR`; the `NOTE` lines.
- `ask` (`:3334`) and `text_clean` (`:3380`).
- `edit_box` (`:3395`) with `eb_ins` `:3471`, `eb_wrap` `:3477`, `eb_line` `:3497`, `eb_max` `:3504`, `eb_move` `:3508`, `eb_paint` `:3532`, `eb_draw` `:3594`. It has its own `?2026` write, which also places and shows the cursor (`:3662`), and its own `cat`-pipe input under `stty -icrnl -isig` (`:3403-3407`).
- `note` (`:4312`).
- `code_popup` (`:3278`) and `login_window` (`:3311`). Both are tmux popups or windows running bash and `agent-say`. The Rust panel runs the same commands and keeps drawing underneath.
- `read_host_keys` (`:3297`).
- `user_note` (`:4129`) and `unlink_host` (`:4148`).
- Update jobs: `upd_add` `:4166`, `upd_job` `:4170`, `upd_running` `:4181`, `upd_last` `:4188`, `upd_users` `:4197`, `upd_start` `:4210`, `upd_poll` `:4234`, `upd_lines` `:4251`, `upd_tick` `:4292`, `upd_show` `:4295`.
- `help_view` and the help-page buttons: `help_confirm`, `help_install`, `help_open` in `scripts/help.sh`.

### Answering: Phase 5

- `answer` (`:3991-4122`), `question_look` (`:3868`), `question_free` (`:3892`), `q_fresh` (`:3924`), `free_answer` (`:3952`).
- `send_answer` (`:3852`), `paste_answer` (`:3835`), `key_ok`, `lit_tokens`, `paste_ok`.
- The rules:
  - the ANSWERING bar (`:3226-3231`);
  - a free-text choice's j/k/E/digit/Space handling (`:4045-4056`);
  - Esc versus sequences (`:4072-4089`);
  - a digit sent alone (`:4096-4106`);
  - at most three batched sends before a redraw (`:4003-4004`);
  - 40 ms polling after a key (`:4030-4036`);
  - "answered" after two looks in a row that aren't asking (`:4022`);
  - `peek_drop` after each send (`:4110`);
  - the `.answered-ID` marker (`:4120`).

## Steps

Each phase ends with something runnable and tested. Until Phase 6, the dispatcher's default stays bash, so the panel users run is the bash one throughout.

### Phase 0: Make the oracle deterministic, and let the suite take any panel

Phase 0 edits `scripts/panel.sh` more than a pair of `--once` hooks: the snapshot has to cover everything `draw` reads from outside, and the twins need a clock hook in the live panel too (Q1). Every edit is inert unless its variable is set, except the `X_SSH` sort, which is a deliberate change to the live order.

- **0.1** Add test hooks to `scripts/panel.sh` (Q1):
  - `REVIVE_PANEL_SNAP=save:FILE|load:FILE`, `--once` only, around the two gathers at `:5060-5062`. The file is NUL-separated `name\0index\0value\0` records, written by `printf`, so any bytes survive. It holds every array and variable that `draw` reads and that something other than `draw` writes:
    - `P_*`, `W_SINCE`, `W_FROM`, `X_SSH`, `X_WHERE`;
    - `RVER`, `ROWNER`, `P_GROUPS`, `P_SRV`, `P_LIM`, `P_LWHY`;
    - `MSG`, `SIDE`, `MOLD`, `MWAIT`, `INTRO_ON` (from `messages`/`links_saves`);
    - `VERSION`, which `draw_panes` compares against (`:2386`, `:2493`) and which comes from a file (`:61`) that every release changes;
    - `SECONDS` as `draw` sees it (the tip, `:2592`; the flash age, `:3224`);
    - `CPU_HIST`, which `draw_top` appends to (`:3033-3034`), saved as it stands before the draw;
    - the selected pane's screen as `draw_peek`/`draw_question` would read it (`:2621`, `:2737`, or `remote_peek`'s file and its `-mmin -1` answer, `:1995-1996`), and `qhi`'s coloured capture (`:2759`);
    - the intros list `draw_panes` reads (`:2351`), and `FOLD` (`fold_load`, `:5065`);
    - UI state: `FOCUS PO PB MO SO MMAN PB_FOR` (`:2190`), `HSEL` (`:2222`), `FLASH` and its age, `HELP`/`HELP_TOP` (`scripts/help.sh:11`), `ANSWERING`, `QFREE`, `QFREEN`, `QON`, `QEMPTY`, `QHAS` (`:2172-2173`), and `QL` (`:3868-3880`).

    In load mode `draw` skips `messages` and `links_saves` (`:3083`), the captures, `remote_peek`'s fetch and `fold_load`, and uses the loaded values, so tier 1 isolates layout entirely. `draw` itself changes state (`CPU_HIST`, `PB_FOR` `:3060`, `PREV`), so every render re-loads the snapshot first.

    **As built, and where the list above was short.** Checked against what `draw` and its callees read (a sweep of the uppercase names in `draw`, `draw_top`, `draw_panes`, `draw_peek`, `draw_question`, `qhi`, `remote_peek`, `tip_line`, the cells, the art and `help_frame`), the list above missed state the frame depends on. The snapshot (`SNAP_VARS` in `scripts/panel.sh`) also carries:
    - `SEL` and `SEL_ID` (the selected row; `PB_FOR` is keyed on `SEL_ID`), `PEEK`, `PEEK_SEL`, `PEEK_ALL` (whether the peek shows; `draw` clears `PEEK` when the selection moves);
    - `WON`, which `wstyle`/`tab_next` read from the last frame before `draw` sets it (`:3065` then `:3109` at `475f43a`), and `ATOP`/`ATOP_BH`, which `draw` fills on the first answering frame and reuses after: both must start as a fresh panel has them on every render, or the second size of a `REVIVE_PANEL_SIZES` run inherits the first's;
    - `HOST` (the banner and the heading of this computer), `SCENE` (picked with `$RANDOM` unless `REVIVE_PANEL_ART` names one, `:299-300`), `TICK`;
    - `INTROS` (the senders `draw_panes` reads, through a new `intros_look`), `SCREEN_ID`/`SCREEN`/`SCREEN_E` (the selected local pane's `capture-pane -p` and `-e -p`, as tmux gave them, before `clean`), and `RPEEK_FOR`/`RPEEK_AT`/`RPEEK` (a linked pane's peek: `new` with its last 60 lines as they came, `fail`, or nothing yet, through a new `peek_look`).

    Not carried, so the harness sets them the same for save and load: `HOME` (a folder's `~`), `USER`, `AGENT_SAY_HOST`, `TZ`, the locale, `REVIVE_PANEL_TIP_SECS`, `REVIVE_DIR`, and the help page's install-command variables.

    The draw-time I/O is read **eagerly**, before `draw`, by `snap_look`: both captures of the selected pane, or its linked peek, `intros_look`, `messages` and `links_saves`. Reading it inside `draw` would miss what the save run's size didn't draw (no peek below `avail >= 4`, no messages while asking) but another size does. The save run's own frame is then drawn from the same values, so it equals the load run's byte for byte. `draw`'s sites take the snapshot's value whenever `SNAP` is set: `pane_screen ARRAY %ID [-e]` in `draw_peek`, `draw_question` and `qhi`; `remote_peek`; `draw_panes`'s intros; and the `messages; links_saves` call, which is skipped. A capture whose pane isn't `SCREEN_ID` (or `RPEEK_FOR`) gives nothing.

    Format details: a variable's record has an empty index; an array has one record per element (so sparse ones such as `P_LIM`, `P_SRV`, `W_SINCE` keep their indexes) and an empty one has none. Names and types (scalar, indexed, associative) come from `SNAP_VARS`, never from the file: the loader empties every array, then applies only records whose name is listed, with an index of `^[0-9]{1,9}$` for an indexed array (a bash subscript is arithmetic, so anything else could run code) and non-empty for an associative one. No `eval`, no `${x@a}`. `SECONDS` is saved as `draw` saw it and loaded into `SNAP_SECS`, which `tip_line`, the key bar's flash age and `help_frame`'s read as `${SNAP_SECS:-$SECONDS}`: assigning `SECONDS` itself would drift by a second at a boundary. In load mode the size is `COLUMNS`/`LINES` (100×40 without them) and `tput` is never run; `strace -f -e trace=execve` shows no program started after the snapshot is opened.
  - `REVIVE_PANEL_SIZES="80x24 100x40 …"`, `--once` with `load:` only: render the loaded snapshot once per size in one process, each preceded by a `--- COLSxLINES` line. This replaces one bash start per frame (see the cost section). The Rust binary takes the same variable.
  - `REVIVE_PANEL_NOW=EPOCH`, read through a `now_s` helper at the draw-path clock reads: `:1024`, `:1494`, `:2908`, `:3001`, `:3010`. The gather path has more (`:912`, `:981`, `:1164`, `:1217`, `:1257`, `:1483`, `:2093`, `:2096`, `:2112`), and so do `lbox_check` (`:4879`) and G's `now` (`:4595`). The file-age checks `find -mmin -1` (`:1996`, `:2962`) are clock-dependent too: their answers go in the snapshot. Tier 1 doesn't need them (the snapshot holds their results); tier 2 needs them pinned too, or its fixtures kept far enough from every threshold that a second's drift can't flip a state. Recommendation: route them through `now_s` as well, in the same step. Unlike the other hooks, this one is honoured in the live panel too, for the tier-3 twins (Q1).
    - **As built:** `now_s` sets `NOW` (the file's helper-sets-a-variable pattern, no `$( )`) from `NOW_PIN`, which is `REVIVE_PANEL_NOW` checked once at startup (`^[0-9]{1,12}$`, else ignored). Every site listed above goes through it, gather path, `lbox_check` and G's `now` included. `NOW_PIN` is cleared in `--rows/--peek/--keys/--paste/--show/--asking/--running`, which share the gather path: the remote and daemon modes never see a pinned clock. The `find -mmin -1` checks (`remote_peek`, `remote_panes`, `links_saves`) go through `young FILE`, which runs the same `find` when the clock isn't pinned and compares the file's `stat` mtime with `NOW` (under 60 s) when it is. `--rows`'s own `NOW_S` and the `-mmin +1 -delete` cleanup are untouched; `codex_rollout`'s `find -mmin -N` window is `now - start`, which a pinned `NOW` leaves the same.
  - In `outside_ssh` (`:2142-2168`), sort `X_SSH` and `X_WHERE` together by (host, where) before returning. This is the fix for hash order above; it changes the live order of the LINKS `ssh in …` rows (`:2974-2979`) and B's list (`:4425-4428`) for every user.
  - None of these touches the remote modes. `test/panel.sh` must pass unchanged after this step, apart from any check that pinned the old `X_SSH` order (none expected; to confirm, grep its `ssh in` assertions).
- **0.2** Add `PANEL` to `test/panel.sh` (default `bash $ROOT/scripts/panel.sh`) and use it at:
  - 36 of the 37 `--once` lines (`grep -c -- '--once' test/panel.sh`); `:2053` runs the old d621bda panel and stays bash;
  - the 29 live-panel windows (`grep -n 'bash \$ROOT/scripts/panel.sh"' test/panel.sh`: lines 253, 346, 373, 942, 1060, 1148, 1328, 1354, 1488, 1606, 1798, 1810, 1814, 2027, 2111, 2233, 2266, 2368, 2398, 2464, 2511, 2544, 2563, 2704, 2800, 2911, 2934, 2944, 2957).

  Leave `--rows` and the old-version panel (`:2050-2058`) on bash.
- **0.3** Add `test/panel-golden.sh`. It builds a scenario list and diffs the two panels with `cmp` (tier 1), and `capture-pane -e` plus the cursor on two private servers (tier 3). It keeps bash's tier-1 outputs in a cache (see the cost section). Until Phase 1 lands, both sides are bash, which proves the harness itself is stable: 20 runs in a row with no diff.

  **As built.** `bash test/panel-golden.sh [snaps|render|twins]` (no argument: all three). The two panels are `GOLDEN_A` and `GOLDEN_B`, command lines, both `bash scripts/panel.sh` by default.
  - **snaps** builds a fixture tmux server (`REVIVE_SOCKET` under its own `mktemp -d`, its own `HOME`, `REVIVE_DIR`, mailbox and state): a shell with text, a stand-in agent (bash copied as `codex`) asking a question with a tab bar and a long wrapped line, a pane in a folder whose name is not UTF-8, messages (delivered, held, not delivered), an access request, a save, three links answered by a fake ssh (`far.example` with rows and a peek, `folded.example` folded, `Zed.example` unreachable with an error; its capital Z sorts it differently under C and en_US), and a `ps` stub that hides your own ssh sessions and adds three outside ones, two to one host. It saves 9 snapshots with `--once` (the save runs pin `REVIVE_PANEL_NOW` to the real time, or the fake rows would be over a minute old) and checks each loaded back draws exactly the frame its save run drew: Verification (d). UI state that `--once` can't be given from outside (answering, a flash, each window focused and scrolled, a heading selected, a folded computer, the help page scrolled, the five scenes at TICK 0, 1 and 7) is made by editing records (`snapedit`), for 33 scenarios. Then `snapfix` makes each snapshot the same from run to run (the fixture folder, host and user names fixed, CPU and memory fixed figures, `W_SINCE`/`P_LIM` moved to the frames' clock `RNOW`), so the cache key holds. It also checks that a `REVIVE_PANEL_SIZES` run equals one run per size, and (with `strace`) that a load runs no program after reading the snapshot.
  - **render** draws every scenario at the named grid (80, 100, 130, 200 × 24, 40, 60; `GOLDEN_SWEEP=1` for 80 to 220 in steps of 7), `--- COLSxLINES` separated, A against B with `cmp`. A's output is cached in `GOLDEN_CACHE` (default `~/.cache/tmux-revive/golden`) under the sha256 of the four scripts, `VERSION`, the harness, `GOLDEN_A`, the grid, `RNOW` and the snapshot. The snapshots are regenerated each run rather than committed under `test/golden/`: committed ones would carry this machine's paths and names, and `snapfix` makes regenerated ones identical anyway. The frames are drawn under `LC_ALL=C.UTF-8`, `TZ=UTC`, `USER=golden` and a `REVIVE_SOCKET` that does not exist.
  - **twins** starts two fixture servers (no links: the fetches' timing would differ), a live panel in each with `REVIVE_PANEL_REFRESH=60` and `REVIVE_PANEL_NOW`, sends the same keys to both (selection, J/K focus, scrolling, `?` and its scroll, Esc, M's edit box with text typed, Esc), waits for each screen to show the expected text and hold still, and compares `capture-pane -e -p` plus `#{cursor_x},#{cursor_y},#{cursor_flag}`, with each row's CPU meter, percent and memory, and the cpu graph row, masked. Not foreseen above: the `?` page animates every second on each panel's own clock (`help_view`, its art and the banner's cursor), so a comparison takes up to eight pairs of shots a moment apart and passes on the first pair that agrees.

### Phase 1: The render core, from snapshots (`--once --snapshot`)

- **1.1** Create the crate at `panel-rs/` with `Cargo.toml` and `src/`:
  - `main.rs`: argument handling, `--once`, `--snapshot`, `--probe`;
  - `render/`: the primitives, `banner.rs`, `art.rs`, `frame.rs`, `panes.rs`, `peek.rs`, `question.rs`, `help.rs`;
  - `compat.rs`: the bash semantics;
  - `snapshot.rs`: the reader for 0.1's format.

  Dependencies: `libc` (termios, poll, strftime, setlocale, strcoll, regcomp/regexec) and `serde_json`. No crossterm: the input parsing mirrors bash's own, and raw escapes are what bash writes. No `regex` crate.
- **1.2** `compat.rs`: the byte-string type and bash's character decoding, `vlen`, `clean`, `printf %*s`, 64-bit wrapping arithmetic, `strftime`, ERE through `regcomp` (with `REG_ICASE` for the `nocasematch` sites), and `strcoll`-sorted directory listing. Each helper has a cargo test that runs the bash one-liner it replaces (`bash -c 'source <(sed -n …)'`, as `test/panel.sh:1383-1395` already does) over the same inputs. The inputs include CJK, combining marks, C1 controls, bidi characters, an over-long line, and **invalid UTF-8** (a lone `\xff`, a cut-short sequence, an overlong encoding). Every constant in the inventory's list gets a match/no-match table checked against `[[ =~ ]]`.
- **1.3** Port the Render group in this order:
  1. primitives;
  2. banner, monitor and spark;
  3. art (the five scenes, with TICK);
  4. `draw_panes` and the cells;
  5. peek;
  6. question;
  7. messages and links layout (from the `MSG`/`SIDE` strings in the snapshot);
  8. the key bar and the ANSWERING bar;
  9. help.

  Dual landing starts here (see the cost section): from the commit that ports a function, any change to that bash function lands with its Rust port.
- **1.4** Tier-1 goldens. The named grid is widths 80, 100, 130, 200 by heights 24, 40, 60 for each scenario below; the full sweep in Risks adds every width from 80 to 220 in steps of 7.
  - panes only;
  - peek shown and hidden;
  - a question with a free-text choice and a wrapped long line;
  - answering, with and without a flash (the ANSWERING bar);
  - messages with a held access request;
  - links and saves with errors, and two or more outside-ssh rows (sorted order);
  - a linked computer open and folded;
  - each of the five scenes at TICK 0, 1 and 7;
  - the help page at 80, 160 and 24 rows, and scrolled (`HELP_TOP`);
  - focus on each window (J), and each window scrolled (`PB`, `MO`, `SO`);
  - a heading selected (`HSEL`);
  - a pane and a folder name with invalid UTF-8 and with characters that sort differently under `C` and the UTF-8 locale;
  - the loading box (from the box function alone).

  **Ships:** `tmux-revive-panel --once --snapshot F`, and `bash test/panel-golden.sh render` passes.

### Phase 2: Collectors, and a real `--once`

- **2.1** `procs`. `/proc` on Linux (names from `cmdline`), and on macOS `ps -ww -eo pid=,ppid=,uid=,rss=,pcpu=,args=` exactly as bash runs it (`:1716`). The CPU formula is bash's integer rounding (`:1753-1760`). `listen_load`'s `ss`, else `lsof` (`:840-846`), run as bash runs them. Add `REVIVE_PANEL_PROCS=ps` to force the `ps` backend. The suite's `ps` stubs need it: `fakeps` `test/panel.sh:1485`, `uidps` `:2233`, `:2688` and the `upanel` window at `:2704`.
- **2.2** `tmux`, `agents` (with the `jq` ports, each fixture-tested against `jq`), `git`, `links` (with the hard constraints above, and the same cache files) and `peek`. `procs`, `tmux` and `agents` publish one `PanesGen` keyed by pane id; a test interleaves a pane appearing between the pane list and the agent look and checks that no agent result lands on the wrong row.
- **2.3** `mail`: `messages` and `links_saves` as collectors. Their `awk`/`find`/`wc`/`jq` become Rust reads of the same files, with `strcoll` order for the globs.
- **2.4** `--once` runs every collector twice, 0.5 s apart, as bash does (`:5060-5062`), then renders.
- **2.5** Tier-2 goldens, made from the existing `test/panel.sh` fixtures by running each `--once` site with both panels:
  - context left (`:503-848`);
  - access (`:849`);
  - questions (`:1077`);
  - ssh links (`:1457`);
  - other computers (`:1620`), including hostile and huge rows (`:2073`, `:2094`, `:2107`);
  - a server that takes a password (`:2416`);
  - hostile text (`:2569`);
  - other users (`:2676`);
  - scrolling windows (`:2744`).

  **Ships:** `PANEL="$ROOT/panel-rs/target/release/tmux-revive-panel" bash test/panel.sh` passes its `--once` checks. A program count is recorded under `strace -f -e trace=execve` (Verification).

### Phase 3: The live panel, with no modals yet

- **3.1** The writer: changed lines only, `ESC[row;1H…ESC[K`, the `ESC[J` tail, everything inside `ESC[?2026h … ESC[H ESC[?2026l` (`:3248-3256`). A cargo test feeds the same `PREV`/`OUT` pairs to this writer and to bash's loop, extracted with sed, and compares the bytes.
- **3.2** The UI thread: poll on stdin, the wake fd and the SIGINT self-pipe; termios as bash sets it (`-echo -icanon`, `ISIG` and `ICRNL` on); key decoding as `keys()`; nav, scroll, J/K, 0-9, p/P, a/A, f/F, Enter on a heading, q; flash; the tip; the 15 s full repaint; WINCH; the loading screen (from progress events), loading box and splash; and stderr to `panel.err`.
- **3.3** Wire the collectors in, with the key sets of the hard constraint above:
  - `up down pgup pgdn home end J K 0-9` (and `j`/`k`) render from the current snapshots and kick nothing;
  - `p P a A` render at once, then kick `tmux` and `mail`;
  - every other key kicks `tmux` and `mail`.

  This keeps `test/panel.sh:357-359` true.
- **3.4** Add an opt-in to `bin/tmux-revive`: `REVIVE_PANEL_RS=1 tmux-revive panel` runs the binary. It is off by default.

  **Ships:** the user can run the Rust panel by choice. The live-panel checks in `test/panel.sh` that need no modal pass under `PANEL=…`. Tier 3 covers the loading box (`lboxp`, `:1798-1814`) and the splash (`:2562`).

### Phase 4: Every key and modal

- **4.1** Modals become a stack in `UiState`. Each frame is base rows, then the top modal painted over them in the same `?2026` block. A modal is repainted whenever a base line under it changed, so collectors keep updating PANES behind a `pick` without tearing it. The B and G flows run on flow threads that block on a channel per pick, ask or popup (Concurrency design).
- **4.2** Port the modals, each byte for byte against bash's direct writes:
  - `pick`, with the `PTICK` live list for `U`;
  - `ask`;
  - `note`;
  - `edit_box`, with bracketed paste (`?2004h`) and the CR/LF distinction bash gets from `stty -icrnl -isig` and a `cat` pipe (`:3403-3407`). The Rust panel switches to the same `-icrnl -isig` while the box is open and back on close; it needs no `cat`;
  - the help page's keys.
- **4.3** Port `act()`'s keys from the table above. Every external call (`agent-say`, `save.sh`, `tmux display-popup -E`, `tmux detach-client`, `exec tmux attach`) runs on a worker or flow thread, except the `exec`, which restores the terminal and replaces the process as bash does (`:4365-4369`).
- **4.4** Tier-3 twins:
  - M (edit box, including the 40-line paste test at `test/panel.sh:329-334`, and the cursor position);
  - N (ask);
  - B (each pick: needs-login, relink, link key, changed host key);
  - G (intros and grants);
  - U (update list ticking);
  - D (confirm);
  - `?` (help scroll and buttons);
  - the `REVIVE_PANEL_POPUP=1` exit on O;
  - a pane created in the fixture server while a `pick` is open: the box matches bash's unmasked, PANES masked.

  **Ships:** `PANEL=… bash test/panel.sh` passes everything except the "questions" section.

### Phase 5: Answering, without freezing the page

- **5.1** `Answering` becomes a UI mode, not a loop, as Concurrency design says:
  - on Enter on an asking pane, freeze the target `(host, P_ID, P_RID)` and its display name;
  - raw keys go, in order, to that target's send worker, which owns the question state, maps keys to tokens with `answer()`'s rules, and runs `q_fresh`, `free_answer`'s steps and the Enter guard in order with the sends;
  - `free_answer`'s box: the worker asks the UI to open `edit_box` and blocks on its result;
  - the worker polls the frozen pane every 40 ms for 12 polls after a send (`poll=12`, `:4111`), otherwise at 0.3 s (`:4037`), runs `question_free` and the answered test on each look, and publishes each look for drawing;
  - SIGINT and Ctrl-] leave (`:4000`, `:4039`, `:4058`);
  - answered-detection, `.answered-ID` and the flashes are as bash has them;
  - a pane that goes away ends answering as in bash, through the looks (Q7).
- **5.2** Everything else keeps updating while answering: PANES, the banner clock, the spark, and the art tick. Messages and links stay hidden while the selected pane asks, as `draw` hides them (`:3062-3063`). That is layout, not freezing.
- **5.3** Tests:
  - the existing "questions" section (`test/panel.sh:1077-1456`), including the shim count `(( c1 - c0 >= 6 ))` at `:1341` and "a digit typed with text after it is sent on its own" at `:1345`;
  - a new check: while answering, a pane created in another window appears in PANES within two refreshes. This is the user's requirement, as a test;
  - a new check: while answering, a pane created so that it sorts above the asking one; keys typed next still reach the asking pane (`tm capture-pane` of both), not the one now at its index;
  - a new check: Enter typed straight after a Down on a free-text dialog, with the cursor landing on the empty "Type something" row, opens the box and sends no Enter;
  - a tier-3 twin of answering, banner and PANES masked, the question and the bar unmasked.

  **Ships:** feature parity.

### Phase 6: Build, sign, install and pick the binary

- **6.1** In `scripts/release.sh`, after the tarball (`:79`), build the four targets with `cargo zigbuild --release --locked` in `$repo`. Copy them to `$out` as `tmux-revive-panel-$ver-{linux-x86_64,linux-arm64,macos-x86_64,macos-arm64}`, add their lines to `SHA256SUMS` where it is written (`:80-81`), before it is signed (`:82`), and add them to the printed `gh release create` line (`:116`).
  - If a target fails, the release fails. Releasing without one binary is not an option (Q3).
  - The macOS binaries need an ad-hoc code signature to run on Apple Silicon. Whether zig's linker provides it is unverified. `rcodesign sign` (apple-codesign, runs on Linux) is the fallback.
- **6.2** In `install.sh`:
  - the outer `fetch_release` exports `_REVIVE_SUMS` (the verified file) with `_REVIVE_ORIGIN` (`:701`);
  - the inner run, after the jq block (`:719-741`) and outside its `if ! have jq` (so it runs whether or not jq was fetched), picks the asset by the same `uname` table, reads the version from `$tmp/src/VERSION` and calls `release_base` itself (in the inner run `VER` and `RB` are empty: `VER` is set only in `fetch_release`, `install.sh:191`, and `release_base`'s only caller is `fetch_release`, `:170`; the inner run takes the `REVIVE_SOURCE` branch, `:690-696`), downloads it with `rget "tags/v$VER"` into `$tmp/src/vendor/bin/tmux-revive-panel` (`mkdir -p` first, as `:731`), compares it to its `SHA256SUMS` line, and `chmod 0755`. `mv "$tmp/src" "$APP"` (`:754`) then carries it into place;
  - then the install-time probe: `"$tmp/src/vendor/bin/tmux-revive-panel" --probe` must print `ok <VERSION>` matching `$tmp/src/VERSION`. A binary that won't load here (too old a glibc, a musl system, an unsigned macOS binary killed at launch) fails this, and it is deleted;
  - on any failure (download, sum, probe) it deletes the file, so nothing half-checked moves into `$APP`, warns, and continues, because the bash panel works. It never dies.
- **6.3** `bin/tmux-revive:336`: route to the binary for `panel` with no arguments or with `--once`, when all of these hold:
  - `$ROOT/vendor/bin/tmux-revive-panel` is executable (`-x`);
  - `REVIVE_PANEL_BASH` is not `1`;
  - until 7.1, `REVIVE_PANEL_RS=1` is set (3.4's opt-in). 7.1 drops this condition.

  No probe at launch: it would cost a process start on every panel open, and the base macOS has no `timeout` to bound it (unverified: not checked on a Mac here; note that `remote_run` already calls `timeout`, `:1891`, `:1912`, `:1922`, so linked use on a Mac needs one installed). The install-time probe stands in for it. If `exec` itself fails (the file vanished, wrong architecture, `ENOEXEC`), fall back to bash: a non-interactive bash exits when `exec` fails unless `shopt -s execfail` is set (`man bash`, `execfail`), so the dispatcher sets it and follows the `exec` with `exec "$BASH" "$ROOT/scripts/panel.sh" "$@"`. A binary that `exec`s and then dies (a loader error after the system call succeeded) is not caught there; the install-time probe is what covers that, and `REVIVE_PANEL_BASH=1` is the user's way out.

  Otherwise `exec "$BASH" scripts/panel.sh "$@"`, as now. Any first argument among `--rows --peek --keys --paste --show --asking --running` always goes to bash. `revive.tmux:53-54` calls `bin/tmux-revive panel`, so it needs no edit.
- **6.4** `scripts/save.sh:397-405` recognises the live panel only as `bash …/scripts/panel.sh`. Add the binary's argv, `…/vendor/bin/tmux-revive-panel` with no `--` argument, which also maps to `tmux-revive panel`. Otherwise a reboot would lose the panel window.
- **6.5** Tests:
  - `test/release.sh`: binary lines in `SHA256SUMS`, a tampered binary refused (and not left in `$APP/vendor/bin`), a binary whose probe fails removed, an old installer still accepting the release;
  - `test/e2e.sh:159` and `:200`: also accept the binary's process;
  - a dispatcher check: a missing binary, a non-executable one, one that fails to `exec`, and each remote flag, all end in bash.

  **Ships:** a release with binaries, still off by default, because 6.3's routing waits on 7.1.

### Phase 7: Default on, measure, and keep bash honest

- **7.1** Turn routing on by default: drop 6.3's `REVIVE_PANEL_RS=1` condition.
- **7.2** Measure against the baseline on the same machine and load:
  - draw time per frame;
  - key-to-screen time;
  - `gather` round time;
  - programs started per round.

  Targets:
  - a frame renders in under 5 ms at 200×60;
  - an arrow key reaches the screen in under 20 ms at load 12;
  - steady state on Linux runs no `ps`, `head`, `readlink`, `grep` or `jq`, and `git` only on a 15 s cache miss;
  - `tmux` per refresh no more than bash's own, because the argv is kept the same: bash runs `list-panes` (`:1728`), the batched agent capture (`:1650`), `show-option @revive-interval` (`:2925`), the peek or question capture (`:2621`/`:2737`) and, on a question with a tab bar, `qhi`'s capture (`:2759`): four or five. Fewer comes only with control mode, later;
  - on macOS, `ps` and `lsof` stay, as bash's fallback has them (`:1763-1771`, `:1155`).
- **7.3** The keep-both-in-step rule is already in force by now (it started per function in Phase 1). From here, tier 2 is a release gate.

## The cost of keeping both in step

The user decided that every panel change lands in bash and Rust in the same commit (Decided, Q2). This section sizes that and lists what makes it cheaper, all inside that decision.

### Size

- **Churn.** `scripts/panel.sh` had 121 commits from the repository's first commit (2026-11-06, `git log --reverse --format='%ad %h' --date=short | head -1`) to `475f43a`, adding 7154 lines and removing 1955 (`git log --since=2026-10-24 --numstat --format= 475f43a -- scripts/panel.sh | awk '{a+=$1;d+=$2} END{print a,d}'`). That is about 7.6 commits a day over 16 days, on 12 of which it changed. `scripts/help.sh` and `scripts/help.txt` had 22 (`git log --since=2026-10-24 --oneline 475f43a -- scripts/help.sh scripts/help.txt | wc -l`).
- **What each panel commit then costs:** the bash edit, the Rust edit, and a tier-1 and tier-2 run. If the pace holds, the port must also keep up with a moving target while it is written: every commit after `475f43a` touching a function already ported is work on two sides.
- **Test time.** Tier 1's full sweep is 21 widths (80 to 220 in steps of 7) by 3 heights by about 30 scenarios: 21 × 3 × 30 ≈ 1,900 frames. One `bash panel.sh --once` per frame is about 1,900 bash starts, each sourcing a 5,199-line script (`wc -l scripts/panel.sh`), before any Rust run (the scenario count of about 30 is an estimate from 1.4's list with variants; unverified until the list is written).

### Making it cheaper

- **(a) Cache bash's tier-1 outputs.** `test/panel-golden.sh` keys the cache on the sha256 of `scripts/panel.sh`, `scripts/help.sh`, `scripts/help.txt`, `scripts/common.sh` (sourced by the panel), `VERSION` (read by the panel, `:61`, unless the snapshot carries it), the scenario snapshot files and the golden script itself, and regenerates bash's frames only when that key changes. A Rust-only commit then costs only Rust renders. Without the snapshot files and `common.sh` in the key, a changed fixture would pass against stale goldens.
- **(b) Render every size in one bash process.** `REVIVE_PANEL_SIZES` (0.1) renders a loaded snapshot at every size in one `--once` run, re-loading the snapshot before each size because `draw` changes state (`CPU_HIST`, `PB_FOR` `:3060`). About 30 bash starts instead of about 1,900.
- **(c) Dual landing starts in Phase 1, per function.** From the commit that ports a function, a change to it lands in both. At the end of each phase, `git log 475f43a.. -- scripts/panel.sh scripts/help.sh scripts/help.txt` lists the bash commits made during the port (none yet: `git log --oneline 475f43a.. -- scripts/panel.sh | wc -l` prints `0`). Each is checked against the functions ported so far and against the phase about to start; any that touched a ported function and didn't land in Rust is ported before the phase closes. So drift is caught phase by phase, not at parity.

## How `test/panel.sh` maps onto this

The file is 2967 lines (`wc -l test/panel.sh`) and calls `panel.sh` 90 times (`grep -c 'scripts/panel.sh' test/panel.sh`).

| Kind | Where | Under the Rust panel |
|---|---|---|
| `--once` frames | 37 lines, 36 of them this panel (`:2053` is the d621bda one). Helpers `frame` `:146`, `artband` `:158`, `hframe` `:455`, `lit` `:486`, `beacon` `:488`, `cframe` `:527`, `bgframe` `:753`, `far` `:1665`, `farsel` `:1992`, `farv` `:2005`, `raw` `:2572`, `uframe` `:2688`, `sframe` `:2761`, plus inline ones | Run with `PANEL=` set to the binary: same assertions. The golden runner also runs both and diffs them (tiers 1 and 2). |
| Live panels in windows | 29 windows (Phase 0.2's list) | Same assertions through `PANEL=`. The shim counts (`:346-361`, `:1337-1345`) hold because the Rust panel runs the same tmux argv from PATH. |
| Remote and daemon modes | the `--rows` runs (`:580`, `:602`, `:687`, `:726`, `:811`, `:1736`, `:1779`, `:1869`, `:1897`, `:1900`, `:1903`, `:1936`, `:1947`, `:2047`), `rpanel` (`:2058`), `kupdate` (`:2307`) | Stay bash, unchanged. They test what linked servers run. |
| Bash function bodies pulled out with sed | `msq` `:1383-1387`, `question_free` `:1395`, `:1423`, `ssh_dest` `:1459`, `remote_run` `rr` `:2334` | Keep for bash. Add Rust unit tests with the same inputs and expected outputs (`question_parts` styles, `question_free`, `ssh_dest`, the `remote_run` command shapes). |
| Old-version compatibility | `d621bda`'s panel (`:2050-2056`) | Unchanged: it is the remote side. |
| PATH stubs | `shim/tmux` `:343`, `fakeps` `:1485`, `uidps` `:1910-1921`, `usudo` `:2225-2227`, `stub/xdg-open` `:366` | `tmux`, `sudo` and `xdg-open` are found on PATH as bash finds them. `ps` stubs need `REVIVE_PANEL_PROCS=ps` (2.1), which `PANEL=` sets in those runs. |

`test/all.sh` runs the suites in order (`test/all.sh:12`). `panel-golden` is added to its default list once Phase 1 lands. Per the memory note `no-github-ci`, all suites are run locally before a release (unverified: memory note).

## Files touched

- **New:**
  - `panel-rs/Cargo.toml`, `panel-rs/Cargo.lock`;
  - `panel-rs/src/**`: `main.rs`, `compat.rs`, `snapshot.rs`, `render/*`, `collect/{procs,tmux,agents,git,links,peek,mail,upd}.rs`, `ui/{loop,keys,modal,pick,ask,note,editbox,answer,flow,help}.rs`, `writer.rs`;
  - `panel-rs/tests/*`;
  - `test/panel-golden.sh`, and its scenario snapshots under `test/golden/`.
- **`scripts/panel.sh`:** the test hooks of 0.1 (`REVIVE_PANEL_SNAP` covering draw-time I/O and UI state, `REVIVE_PANEL_SIZES`, `REVIVE_PANEL_NOW` including the live panel), and the `X_SSH`/`X_WHERE` sort. After that, every panel change, as the keep-in-step rule says.
- **`test/panel.sh`:** the `PANEL` variable at its call sites (0.2), `REVIVE_PANEL_PROCS=ps` with the `ps` stubs, and the new answering checks (5.3).
- **`test/all.sh`:** add `panel-golden`.
- **`scripts/release.sh`:** cross-builds, assets, `SHA256SUMS` lines, the publish command.
- **`test/release.sh`:** binary assets in a release, a refused or failed-probe binary not installed.
- **`install.sh`:** `_REVIVE_SUMS` hand-off, binary fetch, verification and probe into `$tmp/src/vendor/bin/`, uninstall removes it (it lives under `$APP`).
- **`bin/tmux-revive`:** routing at `:336`, with `execfail` and the bash fallback.
- **`scripts/save.sh`:** recognise the binary as the live panel (`:397-405`).
- **`test/e2e.sh`:** `:159`, `:200`.
- **`.gitignore`:** `panel-rs/target/`.
- **`README.md` / `docs/COMMANDS.md`:** `REVIVE_PANEL_BASH=1`, and that the panel is a prebuilt binary with a bash fallback. Its wording goes through the oa-work pane for the user's voice (unverified: memory note `voice-edits-via-oa-work`).
- **Unchanged:** `bin/agent-say`, `scripts/daemon.sh`, `revive.tmux`, and the remote and daemon mode code of `scripts/panel.sh`.

## Verification

Commands for when the work is done. None of them were run for this plan.

- **Tier 1:** `bash test/panel-golden.sh render` reports 0 differing frames over every scenario in 1.4 and the full width sweep.
- **Tier 2:** `bash test/panel-golden.sh live-once` reports 0 differing frames after masking CPU, memory, spark and the tip.
- **Tier 3:** `bash test/panel-golden.sh twins` reports 0 differing captures and cursors, on two private servers, with the masks of tier 3.
- **Whole suite against Rust:** `PANEL="$PWD/panel-rs/target/release/tmux-revive-panel" bash test/panel.sh` passes all checks.
- **Whole suite against bash:** `bash test/panel.sh` with no `PANEL` passes all checks, so the fallback is still tested.
- **The rest:** `bash test/all.sh` passes. `cargo test --manifest-path panel-rs/Cargo.toml` passes.
- **Programs started.** `strace -f -qq -e trace=execve -o /tmp/x bash scripts/panel.sh --once` against the private fixture server, then `grep -c execve /tmp/x`. Compare with the same for the binary. Expect the binary's count on Linux to be the `tmux` and `git` calls, `ss` when a background command needs it, and the links collector's `timeout`/`ssh`/`agent-say` runs (`:1891-1922`), which it keeps.
- **Independence**, on a loaded machine (`stress -c 8`, or the user's own load):
  - while answering a question in a pane, an agent in another window changes state, and its row changes within 2 REFRESH;
  - while answering, keys still reach the frozen pane after PANES reorders;
  - arrow keys stay under 20 ms (timed with `script -t` or tmux's `pipe-pane` timestamps).
- **Drift.** At the end of each phase, `git log 475f43a.. -- scripts/panel.sh scripts/help.sh scripts/help.txt` has no commit touching a ported function without a matching Rust change.
- **Release.** `scripts/release.sh --dry-run --key ~/.ssh/tmux_revive_release X.Y.Z` produces four binaries and a `SHA256SUMS` with five lines that verifies. The key path is from the memory note `release-signing-key` (unverified: memory note).
- **Install.** `bash test/release.sh` passes.
- **Real systems, done by the user:**
  - a fresh install on macOS (arm64), Linux ARM64 and WSL shows the panel through the binary (`ps` shows `tmux-revive-panel`);
  - `REVIVE_PANEL_BASH=1 tmux-revive panel` shows the bash one.

  Linked production servers are not part of this: their remote modes don't change (unverified: memory notes `francis-runs-server-installs`, `jailed-servers-production-only`).

## Open questions

- **Q1. Test hooks in the bash panel, now including the live one.**
  - Phase 0.1 adds `REVIVE_PANEL_SNAP` and `REVIVE_PANEL_SIZES` under `--once` only. But the twins need the banner clock pinned in the live panel, so `REVIVE_PANEL_NOW` must be honoured outside `--once` too, and the snapshot hook now reaches into `draw_peek`, `draw_question`, `qhi`, `draw_panes` and the `--once` path's `fold_load`. These are edits to the fallback that every user runs, inert unless the variable is set.
  - Alternatives: libfaketime (Arch `extra/libfaketime 0.9.13`, not installed) to freeze the clock with no bash edit. It covers the clock only, not the CPU measured over 0.5 s or the draw-time I/O. Its behaviour around `sleep 0.5` under a frozen clock is unverified, and it is awkward on macOS. Or mask the banner clock in tier 3 and keep `REVIVE_PANEL_NOW` `--once` only.
  - **Decided (2026-11-23, reversible):** the hooks, with `REVIVE_PANEL_NOW` live too, because the clock also drives the wait colours, limit times and approved count (`:1024`, `:1494`, `:2908`), which cell masks would have to chase. If the user prefers no live hook, masking the fixed-width `%H:%M:%S` field (`:3001`, `:3010`) as a cell works for the banner alone.
- **Q3. A release when a target fails to build.**
  - **Recommendation:** the release fails. A release missing one platform's binary would silently fall back to bash there, which is safe but invisible. Better to notice at release time.
- **Q4. Older installers.**
  - An outer installer from before `_REVIVE_SUMS` won't pass the sums, so that first update installs no binary.
  - Option: the inner installer fetches and verifies `SHA256SUMS` and `.sig` itself, with its own `ALLOWED_SIGNERS`.
  - **Recommendation:** do that as a fallback when `_REVIVE_SUMS` is absent. It is a few lines, reusing `rget` and `ssh-keygen -Y verify`, and every update then gets the binary at once.
- **Q5. glibc or static musl on Linux.**
  - **glibc 2.17:** keeps `strftime`, `strcoll`, `regcomp` and `LC_TIME` identical to bash (`%a` in the banner, `:3001`), but doesn't run on musl systems such as Alpine. There the install-time probe fails, the binary is removed, and bash runs.
  - **Static musl:** runs anywhere, but its `strftime`, `strcoll` and `regcomp` differ from glibc's, so day names, glob order and regex matching could differ from bash's.
  - **Recommendation:** glibc 2.17 through zigbuild's version suffix, with the probe as the safety net (unverified: zigbuild's glibc-version targeting, not tried here).
- **Q6. A developer install from a checkout** (`REVIVE_SOURCE`, which excludes `vendor`, `install.sh:696`).
  - **Recommendation:** copy `panel-rs/target/release/tmux-revive-panel` into `$tmp/src/vendor/bin/` (where it moves into `$APP` with the rest, `install.sh:754`) when it exists and is newer than `panel-rs/src`, then probe it as 6.2 does. Otherwise use bash. Users never take this path, so "no compiling" holds.
- **Q7. The answered pane goes away while answering.**
  - Bash has a behaviour here, though not through PANES: a gone local pane makes `capture-pane` return nothing (`:3876`), and a failed linked fetch deletes the peek file (`:1960`), so `lines_state` stops saying asking and after two looks answering ends as `why=answered` (`:4022`), with the "… has its answer" flash (`:4118`). A send to the gone pane fails first if a key is typed (`:4109`).
  - Options: keep bash's rule exactly (the send worker's looks end it, two looks later, with bash's flash); or end at once when the id leaves PANES, with a different flash.
  - **Decided (2026-11-23, reversible):** keep bash's rule, so the behaviour has an oracle and the PANES generation is not a second way to end answering. Ending at once would be a further intended change, and needs the user's say.

## Risks

- **Byte identity drifts in places the goldens don't cover.** The danger is a screen state no scenario reaches. Mitigations:
  - tier 1 runs every width from 80 to 220, in steps of 7, for every scenario, made affordable by (a) and (b) of the cost section;
  - the `compat.rs` tests fuzz `fld`, `padv` and `trim_colored` against bash with random coloured strings, including invalid UTF-8.
- **Collectors read differently from bash.** A `/proc` reader that sees a different process tree from `ps -eo` breaks this. Examples: threads, zombies, a process that exits mid-read, or kernel threads with empty args, which `agent_kind` and `shell_job` see differently. Mitigation: a cargo test that compares the `/proc` and `ps` backends' trees on the live machine.
- **Locale-dependent behaviour.** Glob order and ERE matching follow libc and the locale. They match bash only if the Rust panel runs under the same locale bash forced (`:44-49`) and links the same libc family (Q5).
- **macOS.** Untested here. Points of risk:
  - no `/proc`, so `claude_transcript` returns nothing (`:1100`) and the Rust panel must do the same, not "improve" it;
  - `ps` `pcpu` rounding (`:1764-1770`);
  - `lsof` for cwd;
  - `strftime`, `strcoll` and `regcomp` differences from glibc;
  - code signing (6.1), caught at install by the probe.

  The cross-build itself is unverified until tried. If zig can't link for darwin without an SDK, the macOS build needs a Mac (Q3 then decides whether a release can be cut from Arch alone).
- **The binary's name in another panel.** A panel lists another panel's pane by `#{pane_current_command}` (`:1728`, `:1786`); bash's shows as the script `panel.sh` (`shell_job`, `:633-653`), the binary's as `tmux-revive-panel`. On tmux 3.8 on Linux that name is not cut to the 15-character `comm`: a private-server test with a binary of that name gave `#{pane_current_command}` = `tmux-revive-panel`, while `ps -o comm=` gave `tmux-revive-pan`. Older tmux versions and macOS were not tried (unverified). Either way the row text differs between the two panels, which tier 3 avoids by running each twin on its own server.
- **The tmux shim tests** pin the exact tmux argv (`test/panel.sh:349`, `:1337`, `:1344`). Moving to control mode later breaks them, and would need the tests to change in the same commit.
- **Ordering of sends while answering.** With sends on a worker, a key typed during a slow ssh send queues behind it. That matches bash, where it waits in the tty buffer. But the "at most three batches before a redraw" rule (`:4003`) must still bound the screen lag, or the view appears frozen, the very thing being fixed.
- **Two panels at once** (bash and Rust together on one machine) share `$RDIR` caches and `$UPD_DIR`. Rows and peek files are written through temporary files and `mv` (`:1931-1934`, `:1957-1958`), so they are safe. `upd_start` does `rm -rf "$UPD_DIR"` (`:4213`), so a `U` in one wipes the other's job files. The twins run on separate tmux servers but the same `$RDIR` unless their fixtures give each its own `REVIVE_DIR`; they should.
- **Keeping both in step slips.** At the measured pace, a week without dual landing is dozens of commits to reconcile. The per-phase drift check (c) bounds it to one phase.
- **Hard to reverse.** Release assets and `SHA256SUMS` lines are public once published. A bad binary is mitigated by the install-time probe, `REVIVE_PANEL_BASH=1`, and the next release. The routing change in `bin/tmux-revive` is a one-line revert. The `X_SSH` sort is a visible change in the bash panel and is not reverted with it.
- **`save.sh` recognition.** If 6.4 is missed, a reboot restores a shell where the panel was. `test/e2e.sh:200` catches it only once updated.
