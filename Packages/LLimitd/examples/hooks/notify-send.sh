#!/bin/sh
# llimit --on-event hook: one desktop notification per event, with an icon per
# event type. `llimit daemon --notify` already shows every event without a
# script; start from this one to change the wording, icons or which events
# notify.
#
# The daemon runs this without a shell and without arguments. The event
# arrives in LLIMIT_* variables (see Packages/LLimitd/README.md, "Alerts").
set -eu

case "${LLIMIT_EVENT:-}" in
  threshold | failure) icon=dialog-warning ;;
  reset | recovered) icon=dialog-information ;;
  expiringUnused) icon=appointment-soon ;;
  *) exit 0 ;; # an event type from a newer llimit
esac

urgency=normal
if [ "${LLIMIT_SEVERITY:-}" = critical ]; then
  urgency=critical
fi

exec notify-send --app-name=LLimit --urgency="$urgency" --icon="$icon" \
  -- "$LLIMIT_SUMMARY" "$LLIMIT_BODY"
