#!/bin/sh
# llimit --on-event hook: pushes each quota alert to your phone through ntfy
# (https://ntfy.sh). Needs curl.
#
#   NTFY_TOPIC   required. Anyone who knows a topic on the public server can
#                read it, so pick an unguessable name.
#   NTFY_SERVER  optional, default https://ntfy.sh
#   NTFY_TOKEN   optional access token for a protected topic
#
# The daemon runs this without a shell and without arguments. The event
# arrives in LLIMIT_* variables (see Packages/LLimitd/README.md, "Alerts").
set -eu

: "${NTFY_TOPIC:?set NTFY_TOPIC to your ntfy topic}"
server="${NTFY_SERVER:-https://ntfy.sh}"

priority=default
if [ "${LLIMIT_SEVERITY:-}" = critical ]; then
  priority=high
fi

# Header values are ASCII; RFC 2047 encoding keeps any account name intact.
title="=?UTF-8?B?$(printf '%s' "$LLIMIT_SUMMARY" | base64 | tr -d '\n')?="

set -- -fsS --max-time 8 -o /dev/null \
  -H "Title: $title" \
  -H "Priority: $priority" \
  -H "Tags: llimit,$LLIMIT_EVENT" \
  --data-binary "$LLIMIT_BODY"
if [ -n "${NTFY_TOKEN:-}" ]; then
  set -- "$@" -H "Authorization: Bearer $NTFY_TOKEN"
fi

# --max-time stays under the daemon's 10 s hook timeout.
exec curl "$@" "${server%/}/$NTFY_TOPIC"
