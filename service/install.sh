#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
USER_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/numeric-lua/service"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/numeric-lua"
mkdir -p "$USER_UNIT_DIR" "$STATE_DIR" "$CONFIG_DIR"
if [ ! -f "$CONFIG_DIR/service.env" ]; then
  umask 077
  : > "$CONFIG_DIR/service.env"
  chmod 600 "$CONFIG_DIR/service.env"
  echo "write DEEPSEEK_API_KEY=... to $CONFIG_DIR/service.env" >&2
fi
if [ ! -f "$CONFIG_DIR/service.json" ]; then
  cat > "$CONFIG_DIR/service.json" <<JSON
{
  "dsh": "dsh",
  "profile": "headless",
  "stop_grace_seconds": 20
}
JSON
fi
install -m 644 "$ROOT/service/numeric-lua-service.service" \
  "$USER_UNIT_DIR/numeric-lua-service.service"
if [ ! -f "$CONFIG_DIR/service-agents.json" ]; then
  echo "No persistent agents configured yet; run:" >&2
  echo "  python3 $ROOT/service/bootstrap_agents.py" >&2
fi
systemctl --user daemon-reload
systemctl --user enable --now numeric-lua-service.service
systemctl --user --no-pager status numeric-lua-service.service | head -20
