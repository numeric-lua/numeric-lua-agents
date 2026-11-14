#!/usr/bin/env bash
# Contract tests for the numeric-lua promo scheduler.
#
# The scheduler spends money and runs detached agents, so the promises are
# narrow: it never starts outside a window, never signals a PID it does not own,
# never loses what an agent produced, and never pushes/merges by default. The
# suite is offline: `dsh` and `gh` are shell stubs, and remotes are local bare
# repositories.

set -uo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
agents="$root/promo-agents"
tmp=$(mktemp -d)
pids=()

cleanup() {
    # Kill any detached fake agents left by a failing test.
    if [ -d "$tmp" ]; then
        python3 - "$tmp" > "$tmp/stray-pids" 2>/dev/null <<'PY' || true
import glob
import json
import sys

for path in glob.glob(sys.argv[1] + "/state-*/state.json"):
    try:
        state = json.load(open(path))
    except Exception:
        continue
    for group in state.get("running", {}).values():
        for record in group.get("records", {}).values():
            pid = int(record.get("pid", 0))
            if pid > 0:
                print(pid)
PY
        while IFS= read -r pid; do
            [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
        done < "$tmp/stray-pids"
    fi
    for pid in ${pids[@]+"${pids[@]}"}; do
        kill -9 "$pid" 2>/dev/null
    done
    rm -rf "$tmp"
}
trap cleanup EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

export TESTS_LOG="$tmp/tests.log"
export GH_LOG="$tmp/gh.log"
mkdir -p "$tmp/bin"
: > "$TESTS_LOG"
: > "$GH_LOG"

cat > "$tmp/bin/dsh" <<'SH'
#!/bin/sh
# Offline stand-in for a headless DSH agent. Runs in the worktree.
if [ -n "${DSH_INVOCATIONS:-}" ]; then
    printf '%s\n' "$PWD" >> "$DSH_INVOCATIONS"
fi
if [ -n "${DSH_ARGS_LOG:-}" ]; then
    printf '%s\n' "$*" >> "$DSH_ARGS_LOG"
fi
printf '%s\n' "$PWD" > agent-ran.txt
if [ -n "${DSH_SLEEP:-}" ]; then
    sleep "$DSH_SLEEP"
fi
exit 0
SH
chmod +x "$tmp/bin/dsh"

cat > "$tmp/bin/gh" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "${GH_LOG:?}"
case "$1 $2" in
    "pr list") printf '%s\n' "${FAKE_PR_COUNT:-0}" ;;
    "pr create") printf '%s\n' "https://example.invalid/pr/1" ;;
    *)
        printf 'unexpected gh call: %s\n' "$*" >&2
        exit 2
        ;;
esac
SH
chmod +x "$tmp/bin/gh"

cat > "$tmp/test-ok.sh" <<'SH'
#!/bin/sh
printf '%s\n' "$PWD" >> "${TESTS_LOG:?}"
exit 0
SH
cat > "$tmp/test-fail.sh" <<'SH'
#!/bin/sh
printf '%s\n' "$PWD" >> "${TESTS_LOG:?}"
exit 1
SH
chmod +x "$tmp/test-ok.sh" "$tmp/test-fail.sh"

export PATH="$tmp/bin:$PATH"

make_repo() {
    local dir=$1
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    git -C "$dir" config user.email tests@numeric-lua.invalid
    git -C "$dir" config user.name "numeric-lua tests"
    printf 'repo\n' > "$dir/README.md"
    git -C "$dir" add -A
    git -C "$dir" commit -qm "init"
}

make_origin() {
    local repo=$1 bare=$2
    rm -rf "$bare"
    git init -q --bare "$bare"
    git -C "$repo" remote remove origin 2>/dev/null || true
    git -C "$repo" remote add origin "$bare"
    git -C "$repo" push -qu origin main
}

read -r inside_start inside_end past_start past_end latest_start latest_end < <(
    python3 - <<'PY'
from datetime import datetime, timedelta, timezone

now = datetime.now(timezone.utc)

def hhmm(when):
    return when.strftime("%H:%M")

print(
    hhmm(now - timedelta(hours=1)), hhmm(now + timedelta(hours=2)),
    hhmm(now - timedelta(hours=3)), hhmm(now - timedelta(hours=2)),
    hhmm(now - timedelta(hours=1)), hhmm(now + timedelta(minutes=10)),
)
PY
)

write_single() {
    local name=$1 start=$2 end=$3 repo=$4 queue=$5 push=${6:-false} open_pr=${7:-false}
    cat > "$tmp/$name.toml" <<EOF
[schedule]
timezone = "UTC"
stop_margin_minutes = 25
stop_grace_seconds = 2
[[schedule.windows]]
days = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
start = "$start"
end = "$end"

[agent]
command = ["dsh", "--profile", "headless"]

[maintenance]
enabled = false
min_round_seconds = 0

[lock]
path = "$tmp/$name.lock"

[repos.demo]
path = "$repo"
queue = "$queue"
tests = ["sh", "$tmp/test-ok.sh"]
push = $push
open_pr = $open_pr
EOF
}

write_pair() {
    local name=$1 start=$2 end=$3 push=$4 open_pr=$5 tests_a=$6 tests_b=$7
    cat > "$tmp/$name.toml" <<EOF
[schedule]
timezone = "UTC"
stop_margin_minutes = 25
stop_grace_seconds = 2
[[schedule.windows]]
days = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
start = "$start"
end = "$end"

[agent]
command = ["dsh", "--profile", "headless"]

[maintenance]
enabled = false
min_round_seconds = 0

[lock]
path = "$tmp/$name.lock"

[repos.alpha]
path = "$tmp/$name-alpha"
queue = "$tmp/$name-qa"
tests = ["sh", "$tests_a"]
push = $push
open_pr = $open_pr

[repos.beta]
path = "$tmp/$name-beta"
queue = "$tmp/$name-qb"
tests = ["sh", "$tests_b"]
push = $push
open_pr = $open_pr
EOF
}

agent_branch_count() {
    git -C "$1" for-each-ref --format='%(refname:short)' refs/heads/agent 2>/dev/null | wc -l | tr -d ' '
}

agent_branch() {
    git -C "$1" for-each-ref --format='%(refname:short)' refs/heads/agent 2>/dev/null | head -1
}

group_pid() {
    python3 - "$1" <<'PY' 2>/dev/null || true
import json
import sys

try:
    state = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit
for group in state.get("running", {}).values():
    name = group.get("current")
    if name:
        print(group.get("records", {}).get(name, {}).get("pid", 0))
        raise SystemExit
PY
}

wait_for_agent_exit() {
    local state=$1 pid
    for _ in $(seq 1 100); do
        pid=$(group_pid "$state")
        [ -n "$pid" ] || return 1
        if ! kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

queue_count() {
    find "$1" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' '
}

# ---------------------------------------------------------------------------
# Fixtures

mkdir -p "$tmp/repo" "$tmp/queue-inside" "$tmp/queue-outside" \
         "$tmp/queue-late" "$tmp/queue-dirty" "$tmp/queue-lock" \
         "$tmp/queue-one" "$tmp/queue-status"
make_repo "$tmp/repo"

write_single inside "$inside_start" "$inside_end" "$tmp/repo" "$tmp/queue-inside"
write_single outside "$past_start" "$past_end" "$tmp/repo" "$tmp/queue-outside"
write_single late "$latest_start" "$latest_end" "$tmp/repo" "$tmp/queue-late"
write_single dirty "$inside_start" "$inside_end" "$tmp/repo" "$tmp/queue-dirty"
write_single locktest "$inside_start" "$inside_end" "$tmp/repo" "$tmp/queue-lock"
write_single status "$inside_start" "$inside_end" "$tmp/repo" "$tmp/queue-status"

echo "usage"

out=$("$agents" --help 2>&1)
status=$?
if [ "$status" -eq 0 ]; then ok "--help exits 0"; else bad "--help exits 0" "status=$status"; fi
for flag in --once --enqueue --dry-run --status --print-config; do
    if printf '%s' "$out" | grep -q -- "$flag"; then
        ok "--help documents $flag"
    else
        bad "--help documents $flag" "$out"
    fi
done

"$agents" --config "$tmp/missing.toml" > /dev/null 2>"$tmp/err"
status=$?
if [ "$status" -eq 2 ] && grep -q "no config" "$tmp/err"; then
    ok "a missing config exits 2 with a message"
else
    bad "a missing config exits 2 with a message" "$(cat "$tmp/err")"
fi

cat > "$tmp/empty-windows.toml" <<'EOF'
[schedule]
windows = []
EOF
"$agents" --config "$tmp/empty-windows.toml" > /dev/null 2>"$tmp/err"
status=$?
if [ "$status" -ne 0 ] && grep -q "windows is empty" "$tmp/err"; then
    ok "an empty window list is a configuration error"
else
    bad "an empty window list is a configuration error" "$(cat "$tmp/err")"
fi

cat > "$tmp/bad-clock.toml" <<'EOF'
[schedule]
[[schedule.windows]]
start = "25:00"
end = "26:00"
EOF
"$agents" --config "$tmp/bad-clock.toml" > /dev/null 2>"$tmp/err"
status=$?
if [ "$status" -ne 0 ] && grep -q "not HH:MM" "$tmp/err"; then
    ok "a malformed clock is refused"
else
    bad "a malformed clock is refused" "$(cat "$tmp/err")"
fi

cat > "$tmp/bad-day.toml" <<'EOF'
[schedule]
[[schedule.windows]]
days = ["funday"]
start = "10:00"
end = "11:00"
EOF
"$agents" --config "$tmp/bad-day.toml" > /dev/null 2>"$tmp/err"
status=$?
if [ "$status" -ne 0 ] && grep -q "unknown day" "$tmp/err"; then
    ok "an unknown day is refused"
else
    bad "an unknown day is refused" "$(cat "$tmp/err")"
fi

out=$("$agents" --config "$tmp/inside.toml" --print-config 2>&1)
status=$?
if [ "$status" -eq 0 ] && printf '%s' "$out" | grep -Fq "\"path\": \"$tmp/repo\""; then
    ok "--print-config shows the resolved repository path"
else
    bad "--print-config shows the resolved repository path" "$out"
fi
if printf '%s' "$out" | grep -Fq "\"push\": false" &&
   printf '%s' "$out" | grep -Fq "\"open_pr\": false"; then
    ok "--print-config shows the safe defaults"
else
    bad "--print-config shows the safe defaults" "$out"
fi
if [ ! -e "$tmp/inside.lock" ] && [ ! -e "$tmp/state-print" ]; then
    ok "--print-config writes no lock or state"
else
    bad "--print-config writes no lock or state"
fi

echo "windows and dry run"

printf '# Outside task\n\nBody.\n' > "$tmp/queue-outside/001-outside.md"
out=$("$agents" --config "$tmp/outside.toml" --state-dir "$tmp/state-outside" --dry-run 2>&1)
if printf '%s' "$out" | grep -q "outside a discount window"; then
    ok "outside a window, nothing starts"
else
    bad "outside a window, nothing starts" "$out"
fi
if [ ! -e "$tmp/state-outside" ] && [ ! -e "$tmp/outside.lock" ] &&
   [ "$(agent_branch_count "$tmp/repo")" -eq 0 ] &&
   [ "$(queue_count "$tmp/queue-outside")" -eq 1 ]; then
    ok "outside a window, a dry run writes nothing"
else
    bad "outside a window, a dry run writes nothing" "$(find "$tmp/state-outside" 2>/dev/null)"
fi

printf '# Late task\n\nBody.\n' > "$tmp/queue-late/001-late.md"
out=$("$agents" --config "$tmp/late.toml" --state-dir "$tmp/state-late" --once 2>&1)
if printf '%s' "$out" | grep -q "inside the stop margin"; then
    ok "the stop margin is respected"
else
    bad "the stop margin is respected" "$out"
fi
if [ "$(agent_branch_count "$tmp/repo")" -eq 0 ] &&
   [ "$(queue_count "$tmp/queue-late")" -eq 1 ] &&
   [ ! -e "$tmp/state-late" ]; then
    ok "the stop margin launches nothing and keeps the task"
else
    bad "the stop margin launches nothing and keeps the task" "$(find "$tmp/state-late" 2>/dev/null)"
fi

printf '# Fix the widget\n\nBody.\n' > "$tmp/queue-inside/001-fix.md"
out=$("$agents" --config "$tmp/inside.toml" --state-dir "$tmp/state-dry" --dry-run 2>&1)
if printf '%s' "$out" | grep -q "would start demo"; then
    ok "inside a window, a queued task would start"
else
    bad "inside a window, a queued task would start" "$out"
fi
if printf '%s' "$out" | grep -q "task:"; then
    ok "the dry run names the task"
else
    bad "the dry run names the task" "$out"
fi
if [ ! -e "$tmp/state-dry" ] && [ ! -e "$tmp/inside.lock" ] &&
   [ "$(agent_branch_count "$tmp/repo")" -eq 0 ] &&
   [ ! -e "$tmp/state-dry/worktrees" ] &&
   [ "$(queue_count "$tmp/queue-inside")" -eq 1 ]; then
    ok "a dry run writes no state, lock, worktree, branch, or queue change"
else
    bad "a dry run writes no state, lock, worktree, branch, or queue change" \
        "$(find "$tmp/state-dry" 2>/dev/null)"
fi

printf '# Dirty task\n\nBody.\n' > "$tmp/queue-dirty/001-dirty.md"
printf 'dirty\n' > "$tmp/repo/dirty.txt"
out=$("$agents" --config "$tmp/dirty.toml" --state-dir "$tmp/state-dry-dirty" --dry-run 2>&1)
if printf '%s' "$out" | grep -q "would skip demo" &&
   printf '%s' "$out" | grep -q "dirty working tree"; then
    ok "a dry run reports a dirty checkout instead of starting"
else
    bad "a dry run reports a dirty checkout instead of starting" "$out"
fi
rm -f "$tmp/repo/dirty.txt"

out=$("$agents" --config "$tmp/inside.toml" --state-dir "$tmp/state-status" --status 2>&1)
if printf '%s' "$out" | grep -q "demo: queued (001-fix.md)"; then
    ok "--status names the queued task"
else
    bad "--status names the queued task" "$out"
fi
if [ ! -e "$tmp/state-status" ] && [ ! -e "$tmp/inside.lock" ]; then
    ok "--status writes nothing"
else
    bad "--status writes nothing"
fi

mv "$tmp/queue-inside/001-fix.md" "$tmp/fix-task.md"
out=$("$agents" --config "$tmp/inside.toml" --state-dir "$tmp/state-maintenance" --dry-run 2>&1)
if printf '%s' "$out" | grep -q "queue empty (maintenance disabled)"; then
    ok "maintenance is disabled by default"
else
    bad "maintenance is disabled by default" "$out"
fi
mv "$tmp/fix-task.md" "$tmp/queue-inside/001-fix.md"

echo "coordinator queue"

rm -f "$tmp/queue-inside"/*.md
printf '# Add the queue test\n\nWrite the thing.\n' \
    | "$agents" --config "$tmp/inside.toml" --enqueue demo > "$tmp/enq.out" 2>"$tmp/enq.err"
status=$?
queued=$(find "$tmp/queue-inside" -maxdepth 1 -name '*.md' -type f | sort | head -1)
if [ "$status" -eq 0 ] && [ -n "$queued" ]; then
    ok "--enqueue writes a task file"
else
    bad "--enqueue writes a task file" "$(cat "$tmp/enq.err")"
fi
if [ -n "$queued" ] && head -n1 "$queued" | grep -q "Add the queue test"; then
    ok "the queued task keeps its heading"
else
    bad "the queued task keeps its heading"
fi
out=$("$agents" --config "$tmp/inside.toml" --state-dir "$tmp/state-status" --status 2>&1)
if printf '%s' "$out" | grep -q "demo: queued ("; then
    ok "--status lists the enqueued task"
else
    bad "--status lists the enqueued task" "$out"
fi
out=$("$agents" --config "$tmp/inside.toml" --state-dir "$tmp/state-enqueue" --dry-run 2>&1)
if printf '%s' "$out" | grep -q "would start demo"; then
    ok "an enqueued task is picked before maintenance"
else
    bad "an enqueued task is picked before maintenance" "$out"
fi
printf '# dry\n\nbody\n' | "$agents" --config "$tmp/inside.toml" --enqueue demo --dry-run >/dev/null 2>&1
count=$(queue_count "$tmp/queue-inside")
if [ "$count" -eq 1 ]; then
    ok "--enqueue --dry-run writes nothing"
else
    bad "--enqueue --dry-run writes nothing" "count=$count"
fi
"$agents" --config "$tmp/inside.toml" --enqueue nope >/dev/null 2>"$tmp/enq.err"
status=$?
if [ "$status" -eq 2 ] && grep -q "unknown repository" "$tmp/enq.err"; then
    ok "an unknown repository is refused"
else
    bad "an unknown repository is refused" "$(cat "$tmp/enq.err")"
fi
"$agents" --config "$tmp/inside.toml" --title "orphan" >/dev/null 2>"$tmp/enq.err"
status=$?
if [ "$status" -eq 2 ]; then
    ok "--title without --enqueue is refused"
else
    bad "--title without --enqueue is refused" "status=$status"
fi
printf '' | "$agents" --config "$tmp/inside.toml" --enqueue demo >/dev/null 2>"$tmp/enq.err"
status=$?
if [ "$status" -eq 2 ] && grep -q "needs a body" "$tmp/enq.err"; then
    ok "an empty task body is refused"
else
    bad "an empty task body is refused" "$(cat "$tmp/enq.err")"
fi
"$agents" --config "$tmp/inside.toml" --enqueue demo \
    --body $'---\ntitle: broken\n' >/dev/null 2>"$tmp/enq.err"
status=$?
if [ "$status" -eq 2 ] && grep -q "no closing" "$tmp/enq.err"; then
    ok "malformed front matter is refused at enqueue time"
else
    bad "malformed front matter is refused at enqueue time" "$(cat "$tmp/enq.err")"
fi
"$agents" --config "$tmp/inside.toml" --enqueue demo \
    --body $'---\ntitle: broken\nrepos: demo, nope\n---\nBody.\n' >/dev/null 2>"$tmp/enq.err"
status=$?
if [ "$status" -eq 2 ] && grep -q "unknown repository" "$tmp/enq.err"; then
    ok "an unknown repository in front matter is refused"
else
    bad "an unknown repository in front matter is refused" "$(cat "$tmp/enq.err")"
fi
rm -f "$tmp/queue-inside"/*.md

make_repo "$tmp/enq-alpha"
make_repo "$tmp/enq-beta"
write_pair enq "$inside_start" "$inside_end" false false "$tmp/test-ok.sh" "$tmp/test-ok.sh"
"$agents" --config "$tmp/enq.toml" --enqueue alpha,beta \
    --title "Shared queue task" --body "Body." >/dev/null 2>"$tmp/enq.err"
status=$?
cross_task=$(find "$tmp/enq-qa" -maxdepth 1 -name '*.md' -type f 2>/dev/null | head -1)
if [ "$status" -eq 0 ] && [ -n "$cross_task" ] &&
   head -n1 "$cross_task" | grep -q '^---$' &&
   grep -q '^title: Shared queue task$' "$cross_task" &&
   grep -q '^repos: alpha, beta$' "$cross_task"; then
    ok "--enqueue a,b writes cross-repo front matter"
else
    bad "--enqueue a,b writes cross-repo front matter" "$(cat "$cross_task" 2>/dev/null; cat "$tmp/enq.err")"
fi
"$agents" --config "$tmp/enq.toml" --enqueue alpha \
    --body $'---\ntitle: Front matter task\nrepos: alpha, beta\n---\nBody.\n' \
    >/dev/null 2>"$tmp/enq.err"
status=$?
front_task=$(grep -l '^title: Front matter task$' "$tmp/enq-qa"/*.md 2>/dev/null | head -1)
if [ "$status" -eq 0 ] && [ -n "$front_task" ] &&
   grep -q '^title: Front matter task$' "$front_task"; then
    ok "--enqueue preserves incoming front matter"
else
    bad "--enqueue preserves incoming front matter" "$(cat "$tmp/enq.err")"
fi
rm -f "$tmp/enq-qa"/*.md

echo "safety"

# A record from a previous boot must never be signalled: the PID may now belong
# to something else entirely.
sleep 60 &
victim=$!
pids+=("$victim")
mkdir -p "$tmp/state-boot"
python3 - "$tmp/state-boot/state.json" "$victim" <<'PY'
import json
import sys

path, pid = sys.argv[1], int(sys.argv[2])
json.dump({
    "running": {"stale-group": {
        "id": "stale-group",
        "title": "stale",
        "task": "",
        "body": "",
        "branch": "agent/stale",
        "repos": ["demo"],
        "pending": [],
        "current": "demo",
        "records": {"demo": {
            "pid": pid,
            "boot": "00000000-0000-0000-0000-000000000000",
            "worktree": "/nonexistent",
            "branch": "agent/stale",
        }},
        "failures": {},
        "done": [],
    }},
    "finished": [],
}, open(path, "w"))
PY
"$agents" --config "$tmp/inside.toml" --state-dir "$tmp/state-boot" --stop > /dev/null 2>&1
status=$?
if [ "$status" -eq 0 ] && kill -0 "$victim" 2>/dev/null; then
    ok "a PID from an earlier boot is not signalled"
else
    bad "a PID from an earlier boot is not signalled" "status=$status"
fi
if grep -q "earlier boot" "$tmp/state-boot/agents.log"; then
    ok "the stale record is reported"
else
    bad "the stale record is reported"
fi

# pid 0 must never reach killpg: that would signal the scheduler's own group.
mkdir -p "$tmp/state-zero"
python3 - "$tmp/state-zero/state.json" <<'PY'
import json
import sys

json.dump({
    "running": {"zero-group": {
        "id": "zero-group",
        "title": "zero",
        "task": "",
        "body": "",
        "branch": "agent/zero",
        "repos": ["demo"],
        "pending": [],
        "current": "demo",
        "records": {"demo": {
            "pid": 0,
            "worktree": "/nonexistent",
            "branch": "agent/zero",
        }},
        "failures": {},
        "done": [],
    }},
    "finished": [],
}, open(sys.argv[1], "w"))
PY
python3 - "$agents" "$tmp/inside.toml" "$tmp/state-zero" <<'PY'
import os
import sys

os.setpgrp()
os.execv(sys.executable, [
    sys.executable, sys.argv[1], "--config", sys.argv[2],
    "--state-dir", sys.argv[3], "--stop",
])
PY
status=$?
if [ "$status" -eq 0 ]; then
    ok "a record without a pid never signals a process group"
else
    bad "a record without a pid never signals a process group" "exit $status"
fi

# A dirty checkout is refused and its task stays queued.
printf 'dirty\n' > "$tmp/repo/dirty.txt"
DSH_INVOCATIONS="$tmp/dsh-dirty.log" \
    "$agents" --config "$tmp/dirty.toml" --state-dir "$tmp/state-dirty" --once \
    > "$tmp/dirty.out" 2>&1
status=$?
if [ "$status" -eq 0 ] && grep -q "dirty working tree" "$tmp/dirty.out"; then
    ok "a dirty checkout is reported"
else
    bad "a dirty checkout is reported" "$(cat "$tmp/dirty.out")"
fi
if [ "$(agent_branch_count "$tmp/repo")" -eq 0 ] &&
   [ "$(queue_count "$tmp/queue-dirty")" -eq 1 ] &&
   [ ! -e "$tmp/dsh-dirty.log" ]; then
    ok "a dirty checkout starts no agent and keeps the task"
else
    bad "a dirty checkout starts no agent and keeps the task" \
        "$(cat "$tmp/state-dirty/agents.log" 2>/dev/null)"
fi
rm -f "$tmp/repo/dirty.txt"

# The host lock is exclusive: a second tick must idle without doing any work.
printf '# Lock task\n\nBody.\n' > "$tmp/queue-lock/001-lock.md"
DSH_INVOCATIONS="$tmp/dsh-lock.log" python3 - \
    "$tmp/locktest.lock" "$agents" "$tmp/locktest.toml" "$tmp/state-lock" <<'PY' \
    > "$tmp/lock.out" 2>&1
import fcntl
import os
import subprocess
import sys

lock_path, agents, config, state_dir = sys.argv[1:5]
handle = open(lock_path, "a+")
fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
result = subprocess.run(
    [agents, "--config", config, "--state-dir", state_dir, "--once"],
    capture_output=True, text=True, env=os.environ.copy(),
)
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
sys.exit(result.returncode)
PY
status=$?
if [ "$status" -eq 0 ] && grep -q "another scheduler tick is running" "$tmp/lock.out"; then
    ok "a busy host lock idles the tick"
else
    bad "a busy host lock idles the tick" "$(cat "$tmp/lock.out")"
fi
if [ "$(agent_branch_count "$tmp/repo")" -eq 0 ] &&
   [ ! -e "$tmp/state-lock/state.json" ] &&
   [ ! -e "$tmp/dsh-lock.log" ]; then
    ok "a busy host lock writes no state and starts no agent"
else
    bad "a busy host lock writes no state and starts no agent"
fi

echo "one repository lifecycle"

make_repo "$tmp/repo-one"
make_origin "$tmp/repo-one" "$tmp/origin-one.git"
write_single one "$inside_start" "$inside_end" "$tmp/repo-one" "$tmp/queue-one"
printf '# Fix the widget\n\nBody.\n' > "$tmp/queue-one/001-fix.md"
before_tests=$(wc -l < "$TESTS_LOG")
: > "$GH_LOG"
DSH_INVOCATIONS="$tmp/dsh-one.log" DSH_ARGS_LOG="$tmp/args-one.log" \
    "$agents" --config "$tmp/one.toml" --state-dir "$tmp/state-one" --once \
    > "$tmp/one-tick1.out" 2>&1
status=$?
pid=$(group_pid "$tmp/state-one/state.json")
if [ "$status" -eq 0 ] && [ -n "$pid" ] && [ "$(agent_branch_count "$tmp/repo-one")" -eq 1 ]; then
    ok "one-repo tick creates a worktree branch and starts one agent"
else
    bad "one-repo tick creates a worktree branch and starts one agent" "$(cat "$tmp/one-tick1.out")"
fi
wait_for_agent_exit "$tmp/state-one/state.json"
"$agents" --config "$tmp/one.toml" --state-dir "$tmp/state-one" --once \
    > "$tmp/one-tick2.out" 2>&1
status=$?
branch=$(agent_branch "$tmp/repo-one")
running=$(python3 -c "import json; print(len(json.load(open('$tmp/state-one/state.json'))['running']))" 2>/dev/null)
if [ "$status" -eq 0 ] && [ "$running" -eq 0 ]; then
    ok "the next tick finalizes the exited agent"
else
    bad "the next tick finalizes the exited agent" "$(cat "$tmp/one-tick2.out")"
fi
if [ -n "$branch" ] && git -C "$tmp/repo-one" rev-parse --verify -q "$branch" > /dev/null; then
    ok "the agent's branch survives the stop"
else
    bad "the agent's branch survives the stop" "$branch"
fi
worktree="$tmp/state-one/worktrees/demo/${branch#agent/}"
ran=$(git -C "$tmp/repo-one" show "$branch:agent-ran.txt" 2>/dev/null)
if [ "$ran" = "$worktree" ]; then
    ok "the agent's work is committed before finalizing"
else
    bad "the agent's work is committed before finalizing" "ran=$ran worktree=$worktree"
fi
last_test=$(tail -n1 "$TESTS_LOG" 2>/dev/null)
if [ "$(wc -l < "$TESTS_LOG")" -eq $((before_tests + 1)) ] && [ "$last_test" = "$worktree" ]; then
    ok "the repository tests run in the worktree"
else
    bad "the repository tests run in the worktree" "last=$last_test"
fi
if [ "$(queue_count "$tmp/queue-one")" -eq 0 ] &&
   find "$tmp/queue-one/done" -name '*001-fix.md' -print -quit | grep -q .; then
    ok "a finished task moves to done/"
else
    bad "a finished task moves to done/" "$(find "$tmp/queue-one" -type f)"
fi
if [ "$(git -C "$tmp/origin-one.git" for-each-ref --format='%(refname:short)' refs/heads/agent | wc -l | tr -d ' ')" -eq 0 ] &&
   [ ! -s "$GH_LOG" ]; then
    ok "push=false and open_pr=false push no branch and call no gh"
else
    bad "push=false and open_pr=false push no branch and call no gh" "$(cat "$GH_LOG")"
fi
if [ -s "$tmp/dsh-one.log" ] && [ "$(wc -l < "$tmp/dsh-one.log")" -eq 1 ] &&
   grep -q -- "--profile headless" "$tmp/args-one.log"; then
    ok "the configured agent command receives the headless profile"
else
    bad "the configured agent command receives the headless profile" "$(cat "$tmp/args-one.log" 2>/dev/null)"
fi
if python3 -c "import json,sys; s=json.load(open('$tmp/state-one/state.json')); sys.exit(0 if s['finished'][-1]['failures']=={} and s['finished'][-1]['done']==['demo'] else 1)"; then
    ok "the finished summary records a clean single-repo task"
else
    bad "the finished summary records a clean single-repo task"
fi

echo "one agent at a time"

make_repo "$tmp/two-alpha"
make_repo "$tmp/two-beta"
mkdir -p "$tmp/two-qa" "$tmp/two-qb"
write_pair two "$inside_start" "$inside_end" false false "$tmp/test-ok.sh" "$tmp/test-ok.sh"
printf '# First task\n\nBody.\n' > "$tmp/two-qa/001-first.md"
printf '# Second task\n\nBody.\n' > "$tmp/two-qb/001-second.md"
DSH_SLEEP=5 DSH_INVOCATIONS="$tmp/dsh-two.log" \
    "$agents" --config "$tmp/two.toml" --state-dir "$tmp/state-two" --once \
    > "$tmp/two-tick1.out" 2>&1
first=$(agent_branch_count "$tmp/two-alpha")
second=$(agent_branch_count "$tmp/two-beta")
if [ $((first + second)) -eq 1 ] && [ "$second" -eq 0 ]; then
    ok "only one repository starts per --once"
else
    bad "only one repository starts per --once" "one=$first two=$second"
fi
out=$("$agents" --config "$tmp/two.toml" --state-dir "$tmp/state-two" --once 2>&1)
if printf '%s' "$out" | grep -q "agent already running"; then
    ok "a running agent blocks the next launch"
else
    bad "a running agent blocks the next launch" "$out"
fi
if [ "$(agent_branch_count "$tmp/two-beta")" -eq 0 ]; then
    ok "the second repository waits while the first agent runs"
else
    bad "the second repository waits while the first agent runs"
fi
"$agents" --config "$tmp/two.toml" --state-dir "$tmp/state-two" --stop \
    > /dev/null 2>&1
if [ "$(python3 -c "import json; print(len(json.load(open('$tmp/state-two/state.json'))['running']))")" -eq 0 ] &&
   find "$tmp/two-qa/done" -name '*001-first.md' -print -quit | grep -q . &&
   [ "$(queue_count "$tmp/two-qb")" -eq 1 ]; then
    ok "stopping finalizes only the running task"
else
    bad "stopping finalizes only the running task"
fi

echo "cross-repository task"

make_repo "$tmp/cross-alpha"
make_repo "$tmp/cross-beta"
make_origin "$tmp/cross-alpha" "$tmp/cross-alpha-origin.git"
make_origin "$tmp/cross-beta" "$tmp/cross-beta-origin.git"
mkdir -p "$tmp/cross-qa" "$tmp/cross-qb"
write_pair cross "$inside_start" "$inside_end" false false "$tmp/test-ok.sh" "$tmp/test-ok.sh"
cat > "$tmp/cross-qa/001-shared.md" <<'EOF'
---
title: Cross feature
repos: alpha, beta
---
Implement the shared change.
EOF
before_tests=$(wc -l < "$TESTS_LOG")
export DSH_INVOCATIONS="$tmp/dsh-cross.log"
"$agents" --config "$tmp/cross.toml" --state-dir "$tmp/state-cross" --once \
    > "$tmp/cross-tick1.out" 2>&1
a_branch=$(agent_branch "$tmp/cross-alpha")
b_branch=$(agent_branch "$tmp/cross-beta")
current=$(python3 -c "import json; g=list(json.load(open('$tmp/state-cross/state.json'))['running'].values())[0]; print(g['current'])" 2>/dev/null)
if [ -n "$a_branch" ] && [ "$a_branch" = "$b_branch" ] && [ "$current" = "alpha" ] &&
   [ -d "$tmp/state-cross/worktrees/alpha/${a_branch#agent/}" ] &&
   [ -d "$tmp/state-cross/worktrees/beta/${b_branch#agent/}" ]; then
    ok "a cross-repo task creates both worktrees on the same branch"
else
    bad "a cross-repo task creates both worktrees on the same branch" \
        "a=$a_branch b=$b_branch current=$current"
fi
if [ "$(wc -l < "$tmp/dsh-cross.log" 2>/dev/null)" -eq 1 ]; then
    ok "only the first repository's agent runs"
else
    bad "only the first repository's agent runs" "$(cat "$tmp/dsh-cross.log" 2>/dev/null)"
fi
wait_for_agent_exit "$tmp/state-cross/state.json"
"$agents" --config "$tmp/cross.toml" --state-dir "$tmp/state-cross" --once \
    > "$tmp/cross-tick2.out" 2>&1
current=$(python3 -c "import json; g=list(json.load(open('$tmp/state-cross/state.json'))['running'].values())[0]; print(g['current'])" 2>/dev/null)
if [ "$current" = "beta" ] && [ "$(wc -l < "$tmp/dsh-cross.log")" -eq 2 ] &&
   [ "$(wc -l < "$TESTS_LOG")" -eq $((before_tests + 1)) ]; then
    ok "the next repository starts only after the first is finalized"
else
    bad "the next repository starts only after the first is finalized" \
        "current=$current invocations=$(wc -l < "$tmp/dsh-cross.log") tests=$(wc -l < "$TESTS_LOG")"
fi
wait_for_agent_exit "$tmp/state-cross/state.json"
"$agents" --config "$tmp/cross.toml" --state-dir "$tmp/state-cross" --once \
    > "$tmp/cross-tick3.out" 2>&1
a_worktree="$tmp/state-cross/worktrees/alpha/${a_branch#agent/}"
b_worktree="$tmp/state-cross/worktrees/beta/${b_branch#agent/}"
a_ran=$(git -C "$tmp/cross-alpha" show "$a_branch:agent-ran.txt" 2>/dev/null)
b_ran=$(git -C "$tmp/cross-beta" show "$b_branch:agent-ran.txt" 2>/dev/null)
if [ "$a_ran" = "$a_worktree" ] && [ "$b_ran" = "$b_worktree" ]; then
    ok "both repositories commit their own work"
else
    bad "both repositories commit their own work" "a=$a_ran b=$b_ran"
fi
if [ "$(wc -l < "$TESTS_LOG")" -eq $((before_tests + 2)) ] &&
   grep -Fq "$a_worktree" "$TESTS_LOG" && grep -Fq "$b_worktree" "$TESTS_LOG"; then
    ok "each repository's configured tests run"
else
    bad "each repository's configured tests run" "$(tail -n2 "$TESTS_LOG")"
fi
if python3 -c "import json,sys; s=json.load(open('$tmp/state-cross/state.json')); f=s['finished'][-1]; sys.exit(0 if f['done']==['alpha','beta'] and f['failures']=={} else 1)" &&
   [ "$(agent_branch_count "$tmp/cross-alpha")" -eq 1 ] &&
   [ "$(agent_branch_count "$tmp/cross-beta")" -eq 1 ] &&
   find "$tmp/cross-qa/done" -name '*001-shared.md' -print -quit | grep -q .; then
    ok "the cross-repo task finalizes once with both repositories"
else
    bad "the cross-repo task finalizes once with both repositories" \
        "$(cat "$tmp/state-cross/state.json")"
fi
if [ "$(git -C "$tmp/cross-alpha-origin.git" for-each-ref --format='%(refname:short)' refs/heads/agent | wc -l | tr -d ' ')" -eq 0 ] &&
   [ "$(git -C "$tmp/cross-beta-origin.git" for-each-ref --format='%(refname:short)' refs/heads/agent | wc -l | tr -d ' ')" -eq 0 ] &&
   [ ! -s "$GH_LOG" ]; then
    ok "a disabled cross-repo task pushes nothing and opens no PR"
else
    bad "a disabled cross-repo task pushes nothing and opens no PR" "$(cat "$GH_LOG")"
fi
unset DSH_INVOCATIONS

echo "cross-repository failure handling"

make_repo "$tmp/xfail-alpha"
make_repo "$tmp/xfail-beta"
mkdir -p "$tmp/xfail-qa" "$tmp/xfail-qb"
write_pair xfail "$inside_start" "$inside_end" false false "$tmp/test-ok.sh" "$tmp/test-fail.sh"
cat > "$tmp/xfail-qa/001-xfail.md" <<'EOF'
---
title: Failing cross task
repos: alpha, beta
---
One repository's tests fail.
EOF
DSH_INVOCATIONS="$tmp/dsh-xfail.log" \
    "$agents" --config "$tmp/xfail.toml" --state-dir "$tmp/state-xfail" --once \
    > /dev/null 2>&1
wait_for_agent_exit "$tmp/state-xfail/state.json"
"$agents" --config "$tmp/xfail.toml" --state-dir "$tmp/state-xfail" --once \
    > /dev/null 2>&1
wait_for_agent_exit "$tmp/state-xfail/state.json"
"$agents" --config "$tmp/xfail.toml" --state-dir "$tmp/state-xfail" --once \
    > /dev/null 2>&1
a_branch=$(agent_branch "$tmp/xfail-alpha")
b_branch=$(agent_branch "$tmp/xfail-beta")
if python3 -c "import json,sys; s=json.load(open('$tmp/state-xfail/state.json')); f=s['finished'][-1]; sys.exit(0 if f['done']==['alpha','beta'] and 'tests exit 1' in f['failures'].get('beta','') else 1)" &&
   [ -n "$a_branch" ] && [ -n "$b_branch" ] &&
   [ -d "$tmp/state-xfail/worktrees/alpha/${a_branch#agent/}" ] &&
   [ -d "$tmp/state-xfail/worktrees/beta/${b_branch#agent/}" ]; then
    ok "a failed repository is recorded and the other worktree is preserved"
else
    bad "a failed repository is recorded and the other worktree is preserved" \
        "$(cat "$tmp/state-xfail/state.json")"
fi
if [ -f "$tmp/state-xfail/worktrees/alpha/${a_branch#agent/}/agent-ran.txt" ] &&
   find "$tmp/xfail-qa/done" -name '*001-xfail.md' -print -quit | grep -q .; then
    ok "a partially failed task still finalizes its work"
else
    bad "a partially failed task still finalizes its work"
fi

echo "draft pull requests"

make_repo "$tmp/pr-alpha"
make_repo "$tmp/pr-beta"
make_origin "$tmp/pr-alpha" "$tmp/pr-alpha-origin.git"
make_origin "$tmp/pr-beta" "$tmp/pr-beta-origin.git"
mkdir -p "$tmp/pr-qa" "$tmp/pr-qb"
write_pair pr "$inside_start" "$inside_end" true true "$tmp/test-ok.sh" "$tmp/test-ok.sh"
cat > "$tmp/pr-qa/001-pr.md" <<'EOF'
---
title: Linked PR task
repos: alpha, beta
---
Open linked drafts.
EOF
: > "$GH_LOG"
DSH_INVOCATIONS="$tmp/dsh-pr.log" \
    "$agents" --config "$tmp/pr.toml" --state-dir "$tmp/state-pr" --once \
    > /dev/null 2>&1
wait_for_agent_exit "$tmp/state-pr/state.json"
"$agents" --config "$tmp/pr.toml" --state-dir "$tmp/state-pr" --once \
    > /dev/null 2>&1
wait_for_agent_exit "$tmp/state-pr/state.json"
"$agents" --config "$tmp/pr.toml" --state-dir "$tmp/state-pr" --once \
    > /dev/null 2>&1
a_branch=$(agent_branch "$tmp/pr-alpha")
b_branch=$(agent_branch "$tmp/pr-beta")
creates=$(grep -c 'pr create --draft' "$GH_LOG" 2>/dev/null || true)
if [ "$creates" -eq 2 ] &&
   [ "$(git -C "$tmp/pr-alpha-origin.git" for-each-ref --format='%(refname:short)' refs/heads/agent | wc -l | tr -d ' ')" -eq 1 ] &&
   [ "$(git -C "$tmp/pr-beta-origin.git" for-each-ref --format='%(refname:short)' refs/heads/agent | wc -l | tr -d ' ')" -eq 1 ]; then
    ok "push=true pushes each branch and opens one draft PR per repository"
else
    bad "push=true pushes each branch and opens one draft PR per repository" \
        "$(cat "$GH_LOG")"
fi
if grep -q -- '--base main' "$GH_LOG" &&
   grep -q -- "--head $a_branch" "$GH_LOG" &&
   grep -q -- "--head $b_branch" "$GH_LOG"; then
    ok "draft PRs target main from the agent branches"
else
    bad "draft PRs target main from the agent branches" "$(cat "$GH_LOG")"
fi
if grep -Fq 'Repositories: alpha, beta' "$GH_LOG" &&
   grep -Fq -- "- alpha: \`$a_branch\`" "$GH_LOG" &&
   grep -Fq -- "- beta: \`$b_branch\`" "$GH_LOG" &&
   grep -Fq "Task group: ${a_branch#agent/}" "$GH_LOG"; then
    ok "draft PR bodies link the shared task group and sibling branches"
else
    bad "draft PR bodies link the shared task group and sibling branches" \
        "$(cat "$GH_LOG")"
fi
if ! grep -q 'pr merge' "$GH_LOG" && ! grep -q 'pr ready' "$GH_LOG"; then
    ok "the scheduler never merges or marks a PR ready"
else
    bad "the scheduler never merges or marks a PR ready" "$(cat "$GH_LOG")"
fi

echo "daily task cap"

make_repo "$tmp/repo-limit"
mkdir -p "$tmp/queue-limit"
printf '# Limit one\n\nBody.\n' > "$tmp/queue-limit/001-one.md"
printf '# Limit two\n\nBody.\n' > "$tmp/queue-limit/002-two.md"
cat > "$tmp/limit.toml" <<EOF
[schedule]
timezone = "UTC"
stop_margin_minutes = 25
stop_grace_seconds = 2
max_tasks_per_day = 1
[[schedule.windows]]
start = "$inside_start"
end = "$inside_end"

[agent]
command = ["dsh", "--profile", "headless"]

[maintenance]
enabled = false

[lock]
path = "$tmp/limit.lock"

[repos.demo]
path = "$tmp/repo-limit"
queue = "$tmp/queue-limit"
tests = ["sh", "$tmp/test-ok.sh"]
EOF
DSH_INVOCATIONS="$tmp/dsh-limit.log" \
    "$agents" --config "$tmp/limit.toml" --state-dir "$tmp/state-limit" --once \
    > /dev/null 2>&1
wait_for_agent_exit "$tmp/state-limit/state.json"
"$agents" --config "$tmp/limit.toml" --state-dir "$tmp/state-limit" --stop \
    > /dev/null 2>&1
out=$("$agents" --config "$tmp/limit.toml" --state-dir "$tmp/state-limit" --once 2>&1)
if printf '%s' "$out" | grep -q "daily task limit reached (1)"; then
    ok "max_tasks_per_day refuses a second task"
else
    bad "max_tasks_per_day refuses a second task" "$out"
fi
if [ "$(find "$tmp/queue-limit/done" -name '*.md' 2>/dev/null | wc -l)" -eq 1 ] &&
   [ "$(queue_count "$tmp/queue-limit")" -eq 1 ]; then
    ok "the daily cap still completes one task"
else
    bad "the daily cap still completes one task" "$(find "$tmp/queue-limit" -type f)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
