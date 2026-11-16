# numeric-lua agents

Organization tooling for the `numeric-lua` project. This repository is **not**
shipped with any library; it schedules headless DSH agents during provider
discount ("promo") hours so the coordinator can review small, focused changes.

The scheduler is adapted from the Maria Padilha scheduler. It preserves the
same safety model — one agent at a time, worktrees and branches, a stop margin,
state under the user's config/state directories, and a dry run that writes
nothing — and adds optional pushed branches, draft PRs, or tested fast-forwards
to `main`. Pushes are disabled by default; direct-main mode requires both
`push = true` and `push_main = true`.

1. tasks that may name several repositories;
2. a configurable host-wide `fcntl.flock` held for the whole tick.

`promo-agents` starts at most one headless agent at a time inside a configured
window. Repositories are picked round-robin. The agent works in a throwaway git
worktree on `agent/<timestamp>-<slug>`; the scheduler stops it before the
window closes, runs the repository's tests, commits whatever is left, and
leaves the branch for review. With `push_main = true` it first requires the
tests to pass, fast-forwards the main checkout, and pushes `origin/main`; a
dirty or diverged main is reported instead of forced.

The scheduler does not invent work. The coordinator (the human plus the main
DSH session) owns the queues. An empty queue idles unless maintenance rounds
are explicitly enabled.

> **Promo-hour warning.** The discount windows are configuration, not a
> hardcoded promise. Provider peak/off-peak hours and prices change. Verify the
> current published schedule before enabling the timer or leaving it enabled:
> <https://api-docs.deepseek.com/news/news260813> and
> <https://api-docs.deepseek.com/quick_start/pricing>. The example windows are
> copied from the Maria scheduler and are placeholders.

## Safety model

- **One agent at a time.** A cross-repository task runs one repository's agent
  after another, never in parallel. All worktrees are created before the first
  agent starts, so the branches share one timestamp and slug, but only one
  `dsh` process is alive.
- **Worktrees and branches only.** The main checkout is never checked out to an
  agent branch. A dirty checkout is refused.
- **Draft PRs only.** A PR is created only when `push = true`,
  `open_pr = true`, the push succeeded, and the branch has commits ahead of
  `main`. It is always `--draft`; the scheduler never marks it ready, never
  requests review, never merges, and never force-pushes.
- **No push to `main`.** The branch name must start with `agent/`; otherwise the
  scheduler refuses to push or open a PR.
- **Stop margin.** No launch after `end - stop_margin_minutes`; a running agent
  is sent `SIGTERM` to its process group, given `stop_grace_seconds`, then
  `SIGKILL`ed. Finalization still runs tests and commits.
- **State outside the repositories.** Queues default to
  `~/.config/numeric-lua/agents/queue/<repo>`; state, worktrees, logs, and the
  lock default under `~/.local/state/numeric-lua/`.
- **Dry run writes nothing.** `--dry-run` does not create a lock file, state
  file, log, worktree, branch, queue entry, or directory. `--enqueue --dry-run`
  is the same for the queue.
- **Reboot safety.** Each running record stores the boot id. A PID from an
  earlier boot is finalized but never signalled, because it may belong to
  something else now.

### Host-wide lock

Every mutating tick takes an exclusive non-blocking `fcntl.flock` on
`lock.path` (default `~/.local/state/numeric-lua/agents.lock`) and holds it for
the entire tick. `--daemon` holds it for the daemon's lifetime; `--stop` takes
it too. If the lock is busy, the scheduler prints `another scheduler tick is
running` and exits 0 without starting or stopping anything.

This guarantees that **numeric-lua scheduler instances configured with the same
lock path cannot overlap themselves**. It prevents the Maria Padilha scheduler
and the numeric-lua scheduler from running agents simultaneously **only if both
schedulers use the same lock**. As shipped, Maria's scheduler hardcodes its own
lock under its state directory and does not read this config. Until Maria is
patched (or both are pointed at one shared lock), run only one of the two
schedulers. The lock file also contains the holder's PID for diagnostics; the
`flock` is authoritative, not the file contents.

## Requirements

- Python 3.11 or newer (`tomllib`)
- `git`
- a `dsh` executable on `PATH` (or configured as an absolute path)
- optional: `gh` for `open_pr = true`; without it the scheduler logs a skip

## Setup

1. Create the config:

   ```sh
   mkdir -p ~/.config/numeric-lua/agents/queue/luatorch
   install -m 600 example.toml ~/.config/numeric-lua/agents.toml
   ```

2. Edit the windows, timezone, stop margin, lock path, and repository paths.
   The example uses the canonical organization paths
   `~/Códigos/numeric-lua/<repo>`. A missing path is a refused launch, not a
   fallback.

3. Check the resolved configuration without writing anything:

   ```sh
   ./promo-agents --config ~/.config/numeric-lua/agents.toml --print-config
   ./promo-agents --config ~/.config/numeric-lua/agents.toml --dry-run
   ./promo-agents --config ~/.config/numeric-lua/agents.toml --status
   ```

4. Run one tick with a fake `dsh` during bring-up, as the test suite does.
   Then run one manual tick against a real checkout and review the branch
   before enabling the timer.

### Configuration

`example.toml` documents every key. The important ones:

| key | meaning |
| --- | --- |
| `schedule.windows` | `start`/`end` local times and optional `days` |
| `schedule.timezone` | IANA zone; `UTC` in the example |
| `schedule.stop_margin_minutes` | no launch and hard stop before the window ends |
| `schedule.stop_grace_seconds` | SIGTERM grace before SIGKILL |
| `schedule.max_tasks_per_day` | task cap across the promo day; 0 disables |
| `agent.command` | command list, default `["dsh", "--profile", "headless"]` |
| `maintenance.enabled` | opt-in; example default `false` |
| `lock.path` | host-wide flock path |
| `repos.<id>.path` | checkout path |
| `repos.<id>.queue` | task queue directory |
| `repos.<id>.tests` | command list; run from the worktree after the agent exits |
| `repos.<id>.push` | example default `false` |
| `repos.<id>.open_pr` | example default `false`; requires a successful push |

`repos.<id>.queue` is optional and defaults to
`~/.config/numeric-lua/agents/queue/<id>`. Repository ids are also the names
used in cross-repo front matter.

## Queues and cross-repo tasks

A task is a Markdown brief, not a vague goal. Without front matter, the task
targets the repository whose queue contains it — the original Maria behavior:

```sh
./promo-agents --config ~/.config/numeric-lua/agents.toml \
    --enqueue luatorch <<'EOF'
# Add broadcasting tests

Cover scalar, row, and column broadcasting. Acceptance: tests fail before the
implementation and pass after it. Do not touch the fusion compiler.
EOF
```

To target several repositories, use the simple front matter:

```markdown
---
title: Add numlua broadcasting tests
repos: luatorch, numlua
---

Implement ... Acceptance: ...
```

`title` and `repos` are the only recognized keys. `repos` is a comma-separated
list (surrounding `[` `]` and quotes are accepted); unknown keys are ignored.
The front matter must be the very first thing in the file and the opening `---`
must have a closing `---`; a malformed header makes the task invalid, and the
scheduler logs it and skips that file rather than guessing. Without front
matter, or with an empty `repos:` line, the task falls back to the queue's
repository.

Enqueue directly:

```sh
./promo-agents --config ~/.config/numeric-lua/agents.toml \
    --enqueue luatorch,numlua --title "Add numlua broadcasting tests" \
    --body "Implement ... Acceptance: ..."
```

`--enqueue` accepts one repository or a comma-separated list. A list writes the
task to the first repository's queue and adds `repos:` front matter. A task can
also be written into one queue with front matter naming other repositories; the
scheduler validates every name against the configured repositories.

The scheduler picks the oldest task in each queue (filename order), rotating
across repositories. A task naming several repositories counts as **one** task
against `max_tasks_per_day`.

### What a multi-repo tick does

1. Preflights every named repository. A missing checkout or dirty working tree
   is recorded failure for that repository; the unstarted, healthy repositories
   still proceed. If none is eligible, the task stays queued.
2. Picks one `agent/<timestamp>-<slug>` branch name and creates a worktree for
   each eligible repository under
   `~/.local/state/numeric-lua/agents/worktrees/<repo>/<slug>`. A worktree
   creation failure is recorded per repository; the others continue.
3. Starts one agent for the first repository. The others wait.
4. On a later tick, when that agent exits, runs that repository's tests,
   commits any changes on the same branch, optionally pushes the branch,
   opens a draft PR, or fast-forwards `main` when `push_main = true`. Then it
   starts the next repository's agent, still one at a time.
5. When all repositories are done (or stopped at the margin), the task moves to
   `done/` and a summary with per-repository failures is written to state.
   Worktrees and branches are preserved for review.

If one repository fails, its failure is recorded but no other worktree is
deleted. The task is not merged, retried automatically, or marked successful.
If the window ends mid-task, the pending repositories are marked
`stopped before launch`; the completed ones keep their commits.

A single-repository task uses the same machinery with one worktree, so ticks
behave like Maria's scheduler. Because only one agent may run, a multi-repo
task can span several ticks; `--daemon` starts the next repository about 30
seconds after the previous agent exits.

### Draft PRs and linking

With `push = true` and `open_pr = true`, each repository that was pushed and has
commits gets a **draft** PR against `main`. Its body names the shared task
group, all target repositories, and every sibling branch, so the PRs can be
cross-linked by the coordinator. The scheduler does not create a PR for an
empty branch, an existing open PR, or a failed push, and it never merges or
marks a PR ready. `open_pr = true` without `push = true` does nothing.

## CLI

```text
--config PATH        config file (default ~/.config/numeric-lua/agents.toml)
--state-dir PATH     state, worktrees, logs (default ~/.local/state/numeric-lua/agents)
--once               run one tick (also the default when no action is given)
--dry-run            print decisions; write nothing
--status             show the window, running group, queues, lock, and state dir
--stop               stop the current agent and finalize its work
--daemon             tick every 30 seconds, holding the host lock
--print-config       print the resolved config as JSON; write nothing
--enqueue REPO[,REPO...]  queue a task (body from stdin or --body)
--title TEXT         task title override for --enqueue
--body TEXT          task body instead of stdin
```

`--title`/`--body` require `--enqueue`. `--enqueue` cannot be combined with
`--status`, `--stop`, `--once`, `--daemon`, or `--print-config`.

## What a tick does

- Outside every window: stops and finalizes any running agent, then returns.
- Inside the stop margin: same, and never launches.
- With a running group: if its current agent is alive, reports
  `one at a time`; if it exited, finalizes that repository, then starts the next
  pending repository (unless the margin was reached).
- Without a running group: checks the daily cap, scans repositories round-robin
  for a queued task, and launches the first eligible one. Empty queues with
  `maintenance.enabled = false` are skipped (`queue empty (maintenance
  disabled)`).
- Maintenance, when enabled, asks the agent to make one concrete improvement;
  an empty round is valid. A failed launch does not consume a maintenance
  round.
- Only one repository is launched per tick, even when several are pending.

## State and stopping

`--state-dir` defaults to `~/.local/state/numeric-lua/agents/` and contains
`state.json`, `agents.log`, `logs/`, and `worktrees/`. The state records the
group, branch, per-repository PID and boot id, log path, tests, failures, and the
last 50 finished groups. `state.json` is written atomically (temp file +
rename).

At the margin `SIGTERM` goes to the agent's process group; after
`stop_grace_seconds` the scheduler sends `SIGKILL`. Finalization then runs tests,
commits any coherent changes, and records the result. A failed commit or push is
logged; the worktree is never deleted. A record with an unusable PID is never
passed to `killpg`; a record from a previous boot is never signalled.

## Tests

The suite is offline, uses only temporary repositories, and replaces `dsh`
with a shell stub:

```sh
bash tests/promo-agents.sh
```

It covers configuration errors, dry-run/no-write, enqueue, one-repo ticks,
cross-repo worktrees/branches/commits, dirty-checkout refusal, stop margin,
host lock, no push/PR when disabled, and linked draft PRs when enabled.

## Timer

The systemd **user** bus is not available in the current LightDM session, so
the units are system units that run as the checkout owner. They live in
`systemd/`:

- `numeric-lua-agents.service` — one `--once` tick
- `numeric-lua-agents.timer` — every five minutes across the configured windows
- `install.sh` — root-only installer; checks the config exists, rewrites the
  unit paths to this checkout, installs, reloads, and enables the timer

```sh
install -m 600 example.toml ~/.config/numeric-lua/agents.toml
sudo ./systemd/install.sh
```

Do **not** install or enable the timer during bring-up. Validate with the fake
`dsh` suite, then `--dry-run`, then one manual `--once` against a real
repository, and only enable the timer after the coordinator has reviewed
several branches. The installer intentionally uses `enable --now` like Maria's;
running it starts the timer.

The service passes `HOME`, the user's PATH (including `~/.npm-global/bin` where
`dsh` may live), the config path, and an optional
`~/.config/numeric-lua/agents.env` (mode 600). Put `DEEPSEEK_API_KEY=...` there
if DSH reports `MISSING_CREDENTIAL`; never commit it. `KillMode=process` keeps a
detached agent alive when the oneshot tick exits. `TimeoutStartSec=900` allows
finalization tests to finish.

## Operational rules

- Defaults keep `push = false`, `open_pr = false`, and `push_main = false`.
  Enable direct-main mode only with explicit coordinator authorization; the
  branch and worktree survive even if the fast-forward fails.
- Keep a generous stop margin. A hard kill can leave uncommitted work; the
  scheduler commits what it can, but no guarantee is absolute.
- Never put credentials, tokens, or private screenshots in a task, prompt,
  commit, queue, or test.
- Do not queue a task to keep an agent busy. If there is nothing worth doing,
  leave the queue empty and let the window idle.
- Run only one scheduler until the Maria scheduler honors the same host lock.
  The numeric scheduler's own lock prevents overlapping numeric ticks, not a
  Maria tick that uses a different lock file.
- The coordinator owns merges, releases, package publishes, and organization
  settings. The scheduler never performs them.
