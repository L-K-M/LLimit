#!/usr/bin/env bash
# Installs the llimit binary and its systemd user units.
#
# Usage:
#   ./install.sh [path-to-llimit-binary] [--timer]
#
# Default mode installs the long-running daemon service (llimit.service), which
# honors the refresh interval from settings and restarts on failure. --timer
# installs the one-shot service + timer pair instead, refreshing every 30 min.
set -euo pipefail

BINARY="${1:-$(dirname "$0")/../.build/release/llimit}"
MODE="daemon"
for arg in "$@"; do
  if [[ "$arg" == "--timer" ]]; then
    MODE="timer"
  fi
done

if [[ ! -x "$BINARY" ]]; then
  echo "llimit binary not found or not executable: $BINARY" >&2
  echo "Build it first: swift build -c release --package-path Packages/LLimitd" >&2
  exit 1
fi

mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user"
install -m 0755 "$BINARY" "$HOME/.local/bin/llimit"
install -m 0644 "$(dirname "$0")"/llimit*.service "$(dirname "$0")"/llimit-refresh.timer \
  "$HOME/.config/systemd/user/"

systemctl --user daemon-reload
if [[ "$MODE" == "timer" ]]; then
  systemctl --user disable --now llimit.service 2>/dev/null || true
  systemctl --user enable --now llimit-refresh.timer
  echo "Installed. Timer llimit-refresh.timer is active (every 30 min)."
else
  systemctl --user disable --now llimit-refresh.timer 2>/dev/null || true
  systemctl --user enable --now llimit.service
  echo "Installed. Daemon llimit.service is running."
fi

echo "Check: systemctl --user status llimit*"
echo "Logs:  journalctl --user -u llimit.service -f"
