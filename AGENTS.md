# AGENTS.md — numeric-lua-agents

Canonical rules for this repository. The organization-wide rules in
`../AGENTS.md` (once the workspace moves) also apply; this file adds the
scheduler-specific details.

## Runners

Two runners live here; run at most one of them.

- `service/scheduler.py` is the **permanent project service**, installed as
  `numeric-lua-service.service`. It resumes one fixed headless session per
  project, one worker at a time, in the project's main checkout. Workers commit
  to `main` and push after tests pass. It stops for the day at the GitHub
  contribution quota.
- `promo-agents` is the **queue scheduler**. It works coordinator-written task
  briefs in worktrees and branches and, by default, does not push.

## Non-negotiable safety

- **Releases are coordinator-only.** Never create a tag or GitHub release, bump
  a version or rockspec, publish a package, mark a draft PR ready, force-push,
  or change GitHub organization settings. The service prompts encode this in
  `WORK_RULES`.
- **Pushes to `main` are allowed for the permanent service and
  coordinator-authorized maintenance**, after the repository's tests pass.
  The queue scheduler never pushes `main`; with `push = true` and
  `push_main = true` it may fast-forward a tested branch, and only when the
  coordinator configured that repository explicitly.
- **No secrets** in tasks, prompts, queue files, commits, tests, logs, or
  screenshots. API keys belong in `~/.dsh` or a mode-600
  `~/.config/numeric-lua/agents.env` outside the repositories.
- **One agent at a time.** The scheduler must hold the host-wide `flock` for
  every mutating tick. Do not run the numeric scheduler and the Maria Padilha
  scheduler together unless both honor the same lock; as shipped they do not.
- **Checkout isolation.** The queue scheduler uses worktrees and refuses dirty
  checkouts. The permanent service is the coordinator-authorized exception: it
  runs in the project's main checkout, one worker at a time, and must leave the
  checkout clean. Never run a manual agent in a checkout while a service worker
  owns it.
- **Draft PRs only.** `push=false` and `open_pr=false` are the queue defaults.
  Keep them there until the coordinator has reviewed repeated agent branches.
- **The systemd units are coordinator-managed.** Do not install, start, stop, or
  reconfigure the service or the queue timer during bring-up. Validate with
  `--dry-run`, `--status`, and fake-`dsh` ticks.
- **Do not modify the Maria Padilha checkout.** This repository is an
  adaptation; it must stand alone.

## What to change

- Keep the scheduler dependency-free (Python standard library only).
- Preserve the Maria safety properties when editing: one agent, worktree per
  repository, same-timestamp/slug cross-repo branches, stop margin, boot-id
  checks, atomic state writes, config/state under the user's directories, and a
  dry run that writes nothing.
- A behavior change needs a test: queue changes go in `tests/promo-agents.sh`,
  service changes in `service/tests/test_scheduler.py`. Cover an error or
  fallback path. Both suites stay offline and replace `dsh` with a shell stub.
- Do not add automatic merging, ready-for-review transitions, force pushes,
  release steps, or a second lock implementation.

## Cross-repo tasks

The front matter is deliberately small:

```markdown
---
title: Add numlua broadcasting tests
repos: luatorch, numlua
---
Task body...
```

- `title` and `repos` are the only recognized keys.
- `repos` is comma-separated; unknown repository names make the task invalid.
- No front matter (or an empty `repos:`) falls back to the queue's repository.
- A multi-repo task gets one worktree and one branch with the same timestamp and
  slug per repository. Repository agents run sequentially, one at a time.
- Per-repository tests run before commit. Changes are committed per repository;
  pushes/PRs happen only when the repository config enables them. A failure in
  one repository is recorded and never discards another worktree.

A task must be a focused brief with acceptance criteria. Do not invent filler
work; empty queues are allowed.

## Tests

```sh
python3 service/tests/test_scheduler.py   # service
bash tests/promo-agents.sh                # queue scheduler
```

Run both before handing off. They create temporary repositories and local bare
remotes only; they do not use the network, a real `dsh`, `gh`, or systemd.

## Reporting

When handing off, say which files changed, the exact test command and result,
which unit needs a restart for the change to take effect, and which safety
behavior was intentionally left manual.
