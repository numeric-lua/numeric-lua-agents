# numeric-lua single-worker service

One project worker at a time, rotating across eight projects. Luar gets every
second slot (50%); each other project gets one slot per 14-run cycle.

    weekdays (Mon-Fri)  07:00-22:00 America/Sao_Paulo
    weekends (Sat-Sun)  continuous

Failed workers back off up to five minutes instead of hot-looping.
`max_worker_seconds` defaults to four hours and terminates a stuck worker.
The daemon sleeps outside the window. At the weekday close it sends SIGTERM to
the active worker's process group, waits 20 seconds, then SIGKILLs it.

## Contribution limit

Before each worker the scheduler asks GitHub for today's contribution square.
The default daily quota is **100 contributions**. When today's count reaches
`contribution_min`, the daemon sleeps until 00:05 the next day and resumes. Set
`"contribution_mode": "once"` to stop permanently instead. Disable the guard
with `"contribution_guard": false`.

## Persistent project agents

Run once (with `DEEPSEEK_API_KEY` available):

```sh
python3 service/bootstrap_agents.py
```

It creates exactly one headless session per project and stores the IDs in
`~/.config/numeric-lua/service-agents.json`. The scheduler only resumes those
sessions with `--session-id`; it never creates a fresh agent. Re-running the
bootstrap is safe and skips existing bindings. To deliberately reset one
project, remove its entry and re-run.

## Install

```sh
service/install.sh
```

This installs and starts the user unit `numeric-lua-service.service`. It also
creates `~/.config/numeric-lua/service.json` if absent; `dsh` may be replaced
with an absolute path there for non-login environments.

## Operations

```sh
systemctl --user status numeric-lua-service
systemctl --user stop numeric-lua-service
systemctl --user start numeric-lua-service
journalctl --user -u numeric-lua-service -f
python3 service/scheduler.py --status
python3 service/scheduler.py --plan
```

State and per-worker logs live under
`~/.local/state/numeric-lua/service/`. The service lock prevents two schedulers
from running. Only the luar prompt permits one subordinate DeepSeek Pro helper;
all other prompts forbid subagents.
