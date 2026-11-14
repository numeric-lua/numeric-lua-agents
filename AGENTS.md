# AGENTS.md — numeric-lua-agents

Canonical rules for this repository. The organization-wide rules in
`../AGENTS.md` (once the workspace moves) also apply; this file adds the
scheduler-specific details.

## Non-negotiable safety

- **Never push to `main`.** Never merge, force-push, mark a draft PR ready,
  publish a package, create a release, or change GitHub organization settings.
  The coordinator does those.
- **No secrets** in tasks, prompts, queue files, commits, tests, logs, or
  screenshots. API keys belong in `~/.dsh` or a mode-600
  `~/.config/numeric-lua/agents.env` outside the repositories.
- **One agent at a time.** The scheduler must hold the host-wide `flock` for
  every mutating tick. Do not run the numeric scheduler and the Maria Padilha
  scheduler together unless both honor the same lock; as shipped they do not.
- **Worktrees and branches only.** Never run an agent in a coordinator checkout,
  never reuse a dirty checkout, and never delete another repository's worktree
  to recover from a failure.
- **Draft PRs only.** `push=false` and `open_pr=false` are the defaults. Keep
  them there until the coordinator has reviewed repeated agent branches.
- **Do not install or start the systemd timer during bring-up.** Validate with
  `--dry-run`, `--status`, and fake-`dsh` manual ticks.
- **Do not modify the Maria Padilha checkout.** This repository is an
  adaptation; it must stand alone.

## What to change

- Keep the scheduler dependency-free (Python standard library only).
- Preserve the Maria safety properties when editing: one agent, worktree per
  repository, same-timestamp/slug cross-repo branches, stop margin, boot-id
  checks, atomic state writes, config/state under the user's directories, and a
  dry run that writes nothing.
- A behavior change needs a test in `tests/promo-agents.sh`, including an
  error/fallback path. The suite must stay offline and must replace `dsh` with
  a shell stub.
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
bash tests/promo-agents.sh
```

Run it before handing off. It creates temporary repositories and local bare
remotes only; it does not use the network, a real `dsh`, `gh`, or systemd.

## Reporting

When handing off, say which files changed, the exact test command and result,
which paths need the coordinator (for example the luatorch path after the
organization transfer), and which safety behavior was intentionally left
manual.
