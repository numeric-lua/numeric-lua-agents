#!/usr/bin/env python3
"""Single-worker rotation service for the numeric-lua projects.

One project worker runs at a time.  The rotation gives luar every second slot
(50% of runs) and each of the other seven projects one slot per 14-run cycle.
The daemon sleeps outside the configured service window:

  weekdays (Mon-Fri)  07:00-22:00 America/Sao_Paulo
  weekends (Sat-Sun)  continuous

Security/safety: one host lock, one child process group, state and logs outside
the repositories, no shell interpolation for prompts.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import signal
import subprocess
import sys
import time
from datetime import datetime, timedelta, time as dtime
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path("/home/machine/Códigos/numeric-lua")
TZ = ZoneInfo("America/Sao_Paulo")
OPEN_HOUR = 7
CLOSE_HOUR = 22
STOP_GRACE = 20

PROJECTS = [
    "luatorch",
    "numlua",
    "luaplotlib",
    "lua-polars",
    "lua-notebooks",
    "tensorflow-lua",
    "tensorflow-lua-addons",
]

# luar every second slot: 7/14 = 50% luar, 7/14 shared by the other projects.
ROTATION = []
for project in PROJECTS:
    ROTATION.extend(["luar", project])

PROMPTS = {
    "luar": """You are the sole active project worker. Work only in /home/machine/Códigos/numeric-lua/luar.
Read AGENTS.md, doc/architecture.md, doc/roadmap.md, CHANGELOG and tests.
Define exactly FIVE concrete high-value tasks (JIT/FFI/runtime correctness or performance),
implement and test all five. You may use at most ONE DeepSeek Pro subagent at a time for heavy
JIT analysis or patch generation, but it must be read-only or use a separate worktree/patch:
you own all edits, tests, commits, pushes, tags and releases. Never run two subagents at once.
Follow the repo rules: edit src/ not vendor/, mark core edits /* LUAR */, no new runtime deps.
Run at minimum `make test`; add `make WITH_FFI=1 test`, `make JIT=0 test`, and ASAN when warranted.
You may push and cut a new release/tag when you judge appropriate. Report five tasks, commits,
exact tests, any tag/release, and risks.""",
    "luatorch": """You are the sole active project worker. Work only in /home/machine/Códigos/numeric-lua/luatorch.
Define exactly FIVE concrete tasks and implement all five, with tests and docs; prefer a safe
real-valued linalg/API gap. Keep C++ changes minimal. Run ./scripts/test.sh. You may push and cut
a release/tag when you judge appropriate. Do not spawn subagents. Report tasks, commits, tests, release.""",
    "numlua": """You are the sole active project worker. Work only in /home/machine/Códigos/numeric-lua/numlua.
Define exactly FIVE concrete NumPy-parity/IO tasks and implement all five with tests/docs. No new
runtime deps. Run ./scripts/test.sh and NUMLUA_DISABLE_ZLIB=1 ./scripts/test.sh. You may push and cut
a release/tag when appropriate. Do not spawn subagents. Report tasks, commits, tests, release.""",
    "luaplotlib": """You are the sole active project worker. Work only in /home/machine/Códigos/numeric-lua/luaplotlib.
Define exactly FIVE concrete renderer/API tasks and implement all five with tests/docs/visual QA.
Preserve cartesian behavior. Run ./scripts/test.sh, make examples, scripts/visual-qa.sh. You may push
and cut a release/tag when appropriate. Do not spawn subagents. Report tasks, commits, tests, release.""",
    "lua-polars": """You are the sole active project worker. Work only in /home/machine/Códigos/numeric-lua/lua-polars.
Define exactly FIVE concrete DataFrame/IO tasks and implement all five with tests/docs. Use
CARGO_BUILD_JOBS=1 and scripts/ensure-bridge.sh; avoid cold rebuilds. Run ./scripts/test.sh,
./scripts/smoke.sh, ./scripts/rockspec.sh. You may push and cut a release/tag when appropriate.
Do not spawn subagents. Report tasks, commits, tests, release.""",
    "lua-notebooks": """You are the sole active project worker. Work only in /home/machine/Códigos/numeric-lua/lua-notebooks.
Define exactly FIVE concrete user-facing tasks and implement all five with tests/docs/QA. Preserve
Neovim and visual baselines. Run make test, make test-nvim, make test-webapp, visual baseline and
relevant QA. You may push and cut a release/tag when appropriate. Do not spawn subagents.
Report tasks, commits, tests, release.""",
    "tensorflow-lua": """You are the sole active project worker. Work only in /home/machine/Códigos/numeric-lua/tensorflow-lua.
Read AGENTS.md/docs first. Define exactly FIVE concrete graph/eager/training/ops tasks with tests that
run without Python; check TF_Status and use ffi.gc. Reuse third_party/libtensorflow, never vendor it.
Run `make test`. You may push and cut a release/tag when appropriate. Do not spawn subagents.
Report tasks, commits, tests, release.""",
    "tensorflow-lua-addons": """You are the sole active project worker. Work only in
/home/machine/Códigos/numeric-lua/tensorflow-lua-addons. Read AGENTS.md and the parity table. Define
exactly FIVE concrete TensorFlow Addons parity tasks and implement all five using only the public
tensorflow API, with graph-mode session tests. Reuse ../tensorflow-lua/third_party/libtensorflow;
never add Python/Node/PyTorch runtime deps. Run
TENSORFLOW_ROOT="../tensorflow-lua/third_party/libtensorflow" ./scripts/test.sh. You may push and cut
a release/tag when appropriate. Do not spawn subagents. Report tasks, commits, tests, release.""",
}


def now_local() -> datetime:
    return datetime.now(TZ)


def is_open(dt: datetime) -> bool:
    """Weekends are continuous; weekdays are 07:00 <= t < 22:00."""
    if dt.weekday() >= 5:
        return True
    return OPEN_HOUR <= dt.hour < CLOSE_HOUR


def next_open(dt: datetime) -> datetime:
    if is_open(dt):
        return dt
    # Friday after close: the weekend opens immediately at Saturday 00:00.
    if dt.weekday() == 4 and dt.hour >= CLOSE_HOUR:
        return (dt + timedelta(days=1)).replace(
            hour=0, minute=0, second=0, microsecond=0)
    candidate = dt.replace(hour=OPEN_HOUR, minute=0, second=0, microsecond=0)
    if candidate <= dt:
        candidate += timedelta(days=1)
    while candidate.weekday() >= 5:
        candidate += timedelta(days=1)
    return candidate


def default_paths():
    home = Path(os.environ.get("HOME", str(Path.home())))
    state = Path(os.environ.get(
        "NUMERIC_LUA_SERVICE_STATE",
        home / ".local/state/numeric-lua/service"))
    return {
        "state": state / "state.json",
        "lock": state / "service.lock",
        "log": state / "service.log",
        "child_log_dir": state / "logs",
        "config": Path(os.environ.get(
            "NUMERIC_LUA_SERVICE_CONFIG",
            home / ".config/numeric-lua/service.json")),
    }


def load_config(paths):
    config = {
        "dsh": os.environ.get("NUMERIC_LUA_DSH", "dsh"),
        "profile": "headless",
        "projects": {name: str(ROOT / name) for name in ["luar"] + PROJECTS},
        "stop_grace_seconds": STOP_GRACE,
    }
    try:
        raw = json.loads(paths["config"].read_text())
        if isinstance(raw, dict):
            config.update(raw)
    except FileNotFoundError:
        pass
    except Exception as exc:  # malformed config must not silently run
        raise SystemExit(f"invalid config {paths['config']}: {exc}")
    return config


def load_state(path):
    try:
        data = json.loads(path.read_text())
        if not isinstance(data, dict):
            raise ValueError("not an object")
        return data
    except FileNotFoundError:
        return {"slot": 0, "runs": 0, "counts": {}, "history": []}
    except Exception as exc:
        raise SystemExit(f"invalid state {path}: {exc}")


def save_state(path, state):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    data = dict(state)
    data["history"] = data.get("history", [])[-50:]
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    os.replace(tmp, path)


def append_log(path, message):
    path.parent.mkdir(parents=True, exist_ok=True)
    stamp = now_local().strftime("%Y-%m-%d %H:%M:%S%z")
    with path.open("a", encoding="utf-8") as handle:
        handle.write(f"{stamp} {message}\n")


def acquire_lock(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = path.open("a+")
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.seek(0)
        holder = handle.read().strip()
        handle.close()
        return None, holder
    handle.seek(0)
    handle.truncate()
    handle.write(str(os.getpid()))
    handle.flush()
    return handle, None


def choose(state):
    slot = int(state.get("slot", 0)) % len(ROTATION)
    project = ROTATION[slot]
    state["slot"] = (slot + 1) % len(ROTATION)
    return project, slot


def run_once(paths, config, state, args):
    project, slot = choose(state)
    project_dir = Path(config["projects"].get(project, ROOT / project))
    if not (project_dir / ".git").exists():
        raise SystemExit(f"project checkout missing: {project_dir}")
    prompt = PROMPTS[project]
    stamp = now_local().strftime("%Y%m%d-%H%M%S")
    log_path = paths["child_log_dir"] / f"{stamp}-{project}.log"
    paths["child_log_dir"].mkdir(parents=True, exist_ok=True)
    dsh = config.get("dsh", "dsh")
    argv = [dsh, "--profile", config.get("profile", "headless"), "-"]
    env = os.environ.copy()
    env.setdefault("DSH_HOME", str(Path.home() / ".dsh"))
    append_log(paths["log"], f"start {project} slot={slot} dir={project_dir}")
    if args.dry_run:
        print(f"dry-run: {project} slot={slot} dir={project_dir}")
        print(prompt)
        return 0
    with log_path.open("w", encoding="utf-8") as log_handle:
        proc = subprocess.Popen(
            argv, cwd=project_dir, env=env, stdin=subprocess.PIPE,
            stdout=log_handle, stderr=subprocess.STDOUT,
            text=True, start_new_session=True)
        try:
            proc.stdin.write(prompt + "\n")
            proc.stdin.close()
        except BrokenPipeError:
            pass
        state.setdefault("counts", {})
        state["counts"][project] = int(state["counts"].get(project, 0)) + 1
        state["runs"] = int(state.get("runs", 0)) + 1
        state["active"] = {"project": project, "pid": proc.pid,
                           "started": now_local().isoformat(),
                           "log": str(log_path)}
        save_state(paths["state"], state)
        started = time.monotonic()
        try:
            while proc.poll() is None:
                if not args.ignore_window and not is_open(now_local()):
                    append_log(paths["log"], f"stop window closed for {project}")
                    _terminate(proc, config["stop_grace_seconds"])
                    break
                time.sleep(5)
        except KeyboardInterrupt:
            _terminate(proc, config["stop_grace_seconds"])
            raise
        code = proc.wait()
        duration = int(time.monotonic() - started)
        state.pop("active", None)
        state["history"].append({
            "project": project, "slot": slot, "returncode": code,
            "duration_seconds": duration, "log": str(log_path),
            "finished": now_local().isoformat(),
        })
        save_state(paths["state"], state)
        append_log(paths["log"],
                   f"finish {project} code={code} duration={duration}s log={log_path}")
    return code


def _terminate(proc, grace):
    if proc.poll() is not None:
        return
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        proc.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except ProcessLookupError:
            pass


def sleep_until_open():
    dt = now_local()
    if is_open(dt):
        return
    target = next_open(dt)
    seconds = max(1, int((target - dt).total_seconds()))
    append_log(paths["log"], f"outside window; sleeping {seconds}s until {target.isoformat()}")
    while seconds > 0:
        time.sleep(min(60, seconds))
        seconds -= min(60, seconds)
        if is_open(now_local()):
            return


def main():
    global paths
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--daemon", action="store_true", help="run forever")
    parser.add_argument("--once", action="store_true", help="run one worker")
    parser.add_argument("--dry-run", action="store_true", help="print next worker only")
    parser.add_argument("--status", action="store_true", help="print state")
    parser.add_argument("--plan", action="store_true", help="print 14-slot rotation")
    parser.add_argument("--ignore-window", action="store_true",
                        help="run even outside the service window (tests/manual)")
    parser.add_argument("--reset-slot", action="store_true", help="reset rotation slot")
    args = parser.parse_args()
    paths = default_paths()
    if args.plan:
        for index, project in enumerate(ROTATION):
            print(f"{index:2d} {project}")
        return 0
    config = load_config(paths)
    state = load_state(paths["state"])
    if args.status:
        print(json.dumps({"now": now_local().isoformat(),
                          "open": is_open(now_local()),
                          "slot": state.get("slot", 0),
                          "next": ROTATION[int(state.get("slot", 0)) % len(ROTATION)],
                          "runs": state.get("runs", 0),
                          "counts": state.get("counts", {}),
                          "active": state.get("active")},
                         indent=2, sort_keys=True))
        return 0
    if args.reset_slot:
        state["slot"] = 0
        save_state(paths["state"], state)
        print("slot reset")
        return 0
    if args.dry_run:
        project, _ = choose(state)
        print(f"dry-run: next={project}")
        print(PROMPTS[project])
        return 0
    if not (args.once or args.daemon):
        parser.error("choose --daemon, --once, --dry-run, --status, --plan, or --reset-slot")

    lock, holder = acquire_lock(paths["lock"])
    if lock is None:
        print(f"another service is running (holder {holder or 'unknown'})")
        return 0
    try:
        if args.once:
            if not args.ignore_window and not is_open(now_local()):
                print(f"window closed; next open {next_open(now_local()).isoformat()}")
                return 0
            return run_once(paths, config, state, args)
        while True:
            if not args.ignore_window and not is_open(now_local()):
                sleep_until_open()
                continue
            code = run_once(paths, config, state, args)
            if code not in (0, None):
                append_log(paths["log"], f"worker {code}; continuing")
            time.sleep(2)
    finally:
        try:
            fcntl.flock(lock, fcntl.LOCK_UN)
        finally:
            lock.close()


if __name__ == "__main__":
    sys.exit(main())
