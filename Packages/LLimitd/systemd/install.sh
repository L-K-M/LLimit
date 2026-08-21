#!/usr/bin/env bash
# Installs the llimit binary and its systemd user units.
#
# Usage:
#   ./install.sh [path-to-llimit-binary] [--timer] [--tray]
#
# Default mode installs the long-running daemon service (llimit.service), which
# honors the refresh interval from settings and restarts on failure. --timer
# installs the one-shot service + timer pair instead, refreshing every 30 min.
#
# --tray additionally installs the tray icon (llimit-tray.service). It needs
# GTK: sudo apt install python3-gi gir1.2-ayatanaappindicator3-0.1
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MODE="daemon"
TRAY="no"
BINARY=""
# Flags may appear in any position, so the binary is the first non-flag argument
# rather than simply $1 — otherwise `./install.sh --tray` would take "--tray" as
# the binary path and fail the executability check below with a confusing error.
for arg in "$@"; do
  case "$arg" in
    --timer) MODE="timer" ;;
    --tray)  TRAY="yes" ;;
    --*)     echo "unknown option: $arg" >&2; exit 2 ;;
    *)
      if [[ -n "$BINARY" ]]; then
        echo "unexpected extra argument: $arg" >&2
        exit 2
      fi
      BINARY="$arg"
      ;;
  esac
done
BINARY="${BINARY:-$HERE/../.build/release/llimit}"

if [[ ! -x "$BINARY" ]]; then
  echo "llimit binary not found or not executable: $BINARY" >&2
  echo "Build it first: swift build -c release --package-path Packages/LLimitd" >&2
  exit 1
fi

mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user"
install -m 0755 "$BINARY" "$HOME/.local/bin/llimit"
# Daemon/timer units only. The tray unit is handled below because its ExecStart
# has to be rewritten for a ~/.local install.
install -m 0644 "$HERE/llimit.service" "$HERE/llimit-refresh.service" \
  "$HERE/llimit-refresh.timer" "$HOME/.config/systemd/user/"

if [[ "$TRAY" == "yes" ]]; then
  install -d "$HOME/.local/share/llimit/tray/icons"
  install -m 0644 "$HERE/../tray/llimit_tray.py" "$HOME/.local/share/llimit/tray/llimit_tray.py"
  install -m 0644 "$HERE"/../tray/icons/*.svg "$HOME/.local/share/llimit/tray/icons/"
  # The packaged unit runs /usr/bin/llimit-tray; point it at this install instead.
  # /usr/bin/python3, not `env python3`: the GTK bindings are a distro package
  # and are only importable by the distro interpreter. Documentation= is dropped
  # because it points into /usr/share/doc, which a ~/.local install never creates.
  sed -e "s|ExecStart=/usr/bin/llimit-tray|ExecStart=/usr/bin/python3 $HOME/.local/share/llimit/tray/llimit_tray.py --llimit $HOME/.local/bin/llimit|" \
      -e "/^Documentation=/d" \
    "$HERE/llimit-tray.service" > "$HOME/.config/systemd/user/llimit-tray.service"
fi

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

if [[ "$TRAY" == "yes" ]]; then
  if systemctl --user enable --now llimit-tray.service 2>/dev/null; then
    echo "Tray llimit-tray.service is running."
  else
    echo "Tray unit installed but not started (no graphical session?)." >&2
  fi
  echo "Tray needs GTK: sudo apt install python3-gi gir1.2-ayatanaappindicator3-0.1"
fi

echo "Check: systemctl --user status llimit*"
echo "Logs:  journalctl --user -u llimit.service -f"
