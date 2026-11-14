#!/bin/sh
# Install the numeric-lua scheduler timer as a system unit. Run with sudo:
#   sudo ./systemd/install.sh
#
# Safety checks:
#   - refuses to run without root (systemctl would fail anyway);
#   - refuses when the scheduler config is missing;
#   - refuses when a unit file is missing;
#   - rewrites the canonical checkout/config paths in the service to the
#     checkout this script actually lives in, so a staging copy does not point
#     at a path that does not exist yet.
#
# This starts the timer (enable --now), exactly like the Maria installer. Do
# not run it during bring-up; review several manual branches first.
set -eu

canonical_repo=/home/machine/Códigos/numeric-lua/numeric-lua-agents
canonical_config=/home/machine/.config/numeric-lua/agents.toml
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
config=${NUMERIC_LUA_AGENTS_CONFIG:-$canonical_config}

if [ "$(id -u)" -ne 0 ]; then
    echo "install.sh: run with sudo (system units)" >&2
    exit 1
fi

if [ ! -f "$config" ]; then
    echo "install.sh: missing $config; install the scheduler config first" >&2
    exit 1
fi

for unit in "$repo/systemd/numeric-lua-agents.service" \
            "$repo/systemd/numeric-lua-agents.timer"; do
    if [ ! -f "$unit" ]; then
        echo "install.sh: missing unit $unit" >&2
        exit 1
    fi
done

# Substitute the canonical paths. The sed delimiter is '|'; paths with '|' are
# not supported (and are not expected here).
sed -e "s|$canonical_repo|$repo|g" \
    -e "s|$canonical_config|$config|g" \
    "$repo/systemd/numeric-lua-agents.service" \
    > /etc/systemd/system/numeric-lua-agents.service
install -m 644 "$repo/systemd/numeric-lua-agents.timer" \
    /etc/systemd/system/numeric-lua-agents.timer

systemctl daemon-reload
systemctl enable --now numeric-lua-agents.timer
systemctl list-timers numeric-lua-agents.timer --all
