# Bar module examples

`llimit status --json` prints one JSON object built **only** from the credential-free
snapshot file, so it is safe to hand to any status bar, widget toolkit, or script.
These are drop-in examples for the three most common consumers.

## The contract

```json
{
  "text": "Claude 82%! · ChatGPT 45%",
  "tooltip": "Updated 3 min ago\nClaude (last known, 2 h ago): 5-hour limit 82% left …\nClaude: ERROR Token expired …",
  "class": "warning",
  "percentage": 45,
  "accounts": [
    {
      "id": "…", "provider": "anthropic", "name": "Claude", "remainingPercent": 82,
      "stale": false, "failed": true, "lastKnown": true, "errorKind": "auth",
      "error": "Token expired …", "fetchedAt": "2026-10-07T10:02:11Z",
      "metrics": [
        { "id": "five-hour", "label": "5-hour limit", "remainingPercent": 82, "unlimited": false,
          "resetIn": "2h 10m", "resetAt": "2026-10-07T14:15:00Z" }
      ]
    }
  ],
  "failures": [
    { "id": "…", "provider": "anthropic", "name": "Claude", "errorKind": "auth" }
  ]
}
```

| key | meaning |
| --- | --- |
| `text` | one-line summary, one segment per account; a trailing `!` marks a failed or stale account |
| `tooltip` | multi-line detail (age, per-metric remaining %, warnings, errors) |
| `class` | `ok` / `warning` / `critical` / `error` / `empty` — see below |
| `percentage` | lowest remaining percent across accounts, last-known values included; omitted with no data |
| `accounts` | per-account objects for richer widgets, including accounts that failed without any data |
| `failures` | one entry per failed account: `id`, `provider`, `name`, `errorKind` (no message) |

Each `accounts` entry:

| key | meaning |
| --- | --- |
| `id`, `provider`, `name` | the account; `name` is its display name |
| `remainingPercent` | its most-consumed limit, or `null` without a percentage |
| `stale` | data older than 6 hours (twice the longest refresh interval): the daemon is not refreshing |
| `failed` | the latest refresh of this account failed |
| `lastKnown` | the numbers shown come from an earlier successful refresh |
| `errorKind` | with `failed`: `auth`, `network`, `rateLimit`, `decoding`, `api`, `notConfigured` or `unknown` |
| `error` | with `failed`: the error as one plain line of at most 160 characters |
| `fetchedAt` | ISO 8601 time of the data shown; absent when the account has no data |
| `warning`, `estimated` | present only when set |
| `metrics` | one object per limit: `id`, `label`, `unlimited`, and when known `remainingPercent`, `estimated`, `resetIn`, `resetAt`, `usageLine`, `detail` |

`resetIn` is counted down when `llimit status` runs and is omitted once the reset has
passed; `resetAt` is the ISO 8601 reset time, for consumers that count down themselves.
When a failed account's window resets, its last-known reading is dropped, because it
describes the previous window.

`class` is derived from the lowest remaining percentage among accounts with current data
(neither failed nor stale):

| class | when |
| --- | --- |
| `ok` | every account ≥ 40% remaining, none failed or stale |
| `warning` | some account 15–39% remaining, or an account failed, is stale, or reports a warning |
| `critical` | some account with current data < 15% remaining |
| `error` | every account failed to refresh |
| `empty` | no snapshot yet |

A failed or stale account raises the class to `warning` at most: its numbers are last
known, not current.

Error text, account names and limit labels are plain text. Bars that parse markup must
escape them, as the waybar example does with `"escape": true` and the polybar script does
for polybar's `%{…}` tags.

Backward compatibility: keys are only ever **added**, never renamed or removed.

## Examples

- [`waybar/`](waybar/) — module config + CSS classes for `ok`/`warning`/`critical`/`error`/`empty`.
- [`polybar/`](polybar/) — `custom/script` module + a small `jq`-based renderer (polybar
  can't parse JSON itself).
- [`eww/`](eww/) — `defpoll` widget; eww parses the JSON output natively, including the
  `accounts` array.

Each directory has a `screenshot.png` captured from the module actually running
(headless sway for waybar, Xvfb for polybar/eww) against a snapshot whose lowest
remaining quota is 5% — hence the `critical` color.

All three assume the `llimit` binary is on `PATH` and the daemon
(`systemctl --user enable --now llimit.service`) or the refresh timer is running.
