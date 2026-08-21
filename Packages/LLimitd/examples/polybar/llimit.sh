#!/bin/sh
# polybar renderer for LLimit.
#
# `llimit status --json` emits the bar contract (see examples/README.md); polybar
# can't parse JSON, so this script converts it to polybar's text formatting:
# foreground color from `class`, plus the one-line `text`.
#
# Requires: jq. Install alongside the [module/llimit] block in llimit.ini.

json=$(llimit status --json 2>/dev/null) || exit 0
[ -n "$json" ] || exit 0

text=$(printf '%s' "$json" | jq -r '.text // "LLimit"')
class=$(printf '%s' "$json" | jq -r '.class // "empty"')

# Keep these in sync with the waybar/eww example palettes.
case "$class" in
  ok)       color='#a6e3a1' ;;  # green: every account ≥ 40% remaining
  warning)  color='#f9e2af' ;;  # yellow: some account below 40%
  critical) color='#f38ba8' ;;  # red: some account below 15%
  error)    color='#f38ba8' ;;  # red: every account failed to refresh
  *)        color='#6c7086' ;;  # grey: empty / no snapshot yet
esac

echo "%{F$color}$text%{F-}"
