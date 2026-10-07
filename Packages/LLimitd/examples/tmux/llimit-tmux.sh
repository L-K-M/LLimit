#!/bin/sh
# tmux renderer for LLimit: the most constrained account, colored by the same
# `class` the bar modules use. tmux applies the #[fg=…] styles in #() output.

line=$(llimit status --worst --format '{class}|{stale}|{name} {remaining} {kind}' 2>/dev/null) || exit 0
[ -n "$line" ] || exit 0

class=${line%%|*}
rest=${line#*|}
stale=${rest%%|*}
text=${rest#*|}
# The class reflects the last known figures; say when they are over two hours old.
[ -z "$stale" ] || text="$text (stale)"

# Keep these in sync with the waybar/polybar/eww example palettes.
case "$class" in
  ok)             color='#a6e3a1' ;;  # green: at least 40% left
  warning)        color='#f9e2af' ;;  # yellow: below 40%, or a provider warning
  critical|error) color='#f38ba8' ;;  # red: below 15%, or the refresh failed
  *)              color='#6c7086' ;;  # grey: no percentage reported
esac

printf '#[fg=%s]%s#[default]\n' "$color" "$text"
