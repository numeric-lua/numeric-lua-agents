#!/usr/bin/env python3
"""Create the eight permanent project agent sessions once.

Each project gets one DSH headless session, stored in
~/.config/numeric-lua/service-agents.json. The scheduler later resumes these
sessions by ID; it never creates a fresh agent.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path("/home/machine/Códigos/numeric-lua")
PROJECTS = ["luar", "luatorch", "numlua", "luaplotlib", "lua-polars",
            "lua-notebooks", "tensorflow-lua", "tensorflow-lua-addons"]
PROMPT = """You are the permanent project agent for {project}. Your working
directory is {path}. Read AGENTS.md, README.md, CHANGELOG.md and the docs before
future cycles. In future messages you will receive repeated five-task cycles and
must retain this project's context across them.

This bootstrap turn is read-only: inspect the repository and reply exactly
AGENT_READY. Do not modify, commit, push, tag or release anything yet."""


def main():
    home = Path.home()
    agents_path = Path(os.environ.get(
        "NUMERIC_LUA_SERVICE_AGENTS",
        home / ".config/numeric-lua/service-agents.json"))
    try:
        agents = json.loads(agents_path.read_text())
        if not isinstance(agents, dict):
            agents = {}
    except FileNotFoundError:
        agents = {}
    dsh = os.environ.get("NUMERIC_LUA_DSH", "dsh")
    dsh_home = os.environ.get("DSH_HOME", str(home / ".dsh"))
    failures = []
    for project in PROJECTS:
        if agents.get(project):
            print(f"{project}: already bound to {agents[project]}")
            continue
        cwd = ROOT / project
        if not (cwd / ".git").exists():
            failures.append(f"{project}: missing checkout {cwd}")
            continue
        prompt = PROMPT.format(project=project, path=cwd)
        env = os.environ.copy()
        env["DSH_HOME"] = dsh_home
        try:
            proc = subprocess.run(
                [dsh, "--profile", "headless", "--json", "-"],
                cwd=cwd, env=env, input=prompt + "\n", text=True,
                capture_output=True, timeout=300)
        except subprocess.TimeoutExpired:
            failures.append(f"{project}: bootstrap timed out")
            continue
        session_id = None
        final = ""
        for line in proc.stdout.splitlines():
            try:
                event = json.loads(line)
            except Exception:
                continue
            if event.get("type") == "session" and event.get("sessionId"):
                session_id = event["sessionId"]
            elif event.get("type") == "final":
                final = event.get("text", "")
        if proc.returncode != 0 or not session_id:
            failures.append(
                f"{project}: rc={proc.returncode} stderr={proc.stderr[-300:]}")
            continue
        agents[project] = session_id
        agents_path.parent.mkdir(parents=True, exist_ok=True)
        tmp = agents_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(agents, indent=2, sort_keys=True) + "\n")
        os.replace(tmp, agents_path)
        print(f"{project}: {session_id} final={final.strip()!r}")
    if failures:
        print("\nFailures:", file=sys.stderr)
        for failure in failures:
            print(" - " + failure, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
