# Bar module examples

`llimit status --json` prints one JSON object built **only** from the credential-free
snapshot file, so it is safe to hand to any status bar, widget toolkit, or script.
These are drop-in examples for the three most common consumers.

## The contract

```json
{
  "text": "Claude 82% · ChatGPT 45%",
  "tooltip": "Updated 3 min ago\nClaude: 5-hour limit 82% left …",
  "class": "ok",
  "percentage": 45,
  "accounts": [
    { "id": "…", "provider": "anthropic", "name": "Claude", "remainingPercent": 82, "stale": false }
  ]
}
```

| key | meaning |
| --- | --- |
| `text` | one-line summary; `!` marks failed or stale data |
| `tooltip` | multi-line detail (age, per-metric remaining %, errors) |
| `class` | `ok` / `warning` / `critical` / `error` / `empty` — see below |
| `percentage` | lowest remaining percent across accounts; omitted with no data |
| `accounts` | per-account objects for richer widgets (id, provider, name, remainingPercent, stale) |
| `failures` | one named entry per failed provider/account pair, with `errorKind` |
| `resets` | future resets within 7 days, with account/window context and amounts |

Account entries preserve all existing keys and add `failed`, `lastKnown` and
`fetchedAt`. `failed` means the latest refresh failed. `lastKnown` means the
displayed usage is failed or stale; a failed-only account has no reading.
Errors include `errorKind` and a bounded, plain-text `error`. Duplicate failures
keep the most actionable kind: auth, configuration, rate limit, API, decoding,
network, unknown.

Metrics retain `id`, `label`, `unlimited`, `remainingPercent`, `estimated`,
`resetIn`, `usageLine` and `detail`. Additions are `window`, `remainingAmount`,
`resetAt` (ISO 8601 UTC) and `resetSeconds`. `resetIn` and `resetSeconds` are
recomputed on each read; after reset, the former is omitted and the latter is
zero. A carried window that reset after its successful fetch loses its obsolete
reading. Unlimited and undated metrics keep their context.

Freshness uses the snapshot's optional refresh cadence: at least 60 minutes or
two intervals, whichever is longer. Legacy snapshots fall back to 2h. Rendering
never reopens settings to obtain the cadence.

`percentage` includes last-known readings. `class` uses current data:

| class | when |
| --- | --- |
| `ok` | every current account ≥ 40%, or amount-only/unlimited, with no warnings |
| `warning` | current account 15–39%, provider warning, failed or stale account |
| `critical` | current account < 15% |
| `error` | every account failed to refresh |
| `empty` | no snapshot yet |

Backward compatibility: keys are only ever **added**, never renamed or removed.

## Examples

- [`waybar/`](waybar/) — module config + CSS classes for `ok`/`warning`/`critical`/`error`/`empty`.
- [`polybar/`](polybar/) — `custom/script` module + a small `jq`-based renderer (polybar
  can't parse JSON itself).
- [`eww/`](eww/) — `defpoll` widget; eww parses the JSON output natively, including the
  `accounts` array.
- [`hooks/`](hooks/): not bar modules but `llimit daemon --on-event` hooks for alerts
  (notify-send, ntfy). See the "Alerts" section of the package README.

Each bar-module directory has a `screenshot.png` captured from the module actually running
(headless sway for waybar, Xvfb for polybar/eww) against a snapshot whose lowest
remaining quota is 5% — hence the `critical` color.

All three assume the `llimit` binary is on `PATH` and the daemon
(`systemctl --user enable --now llimit.service`) or the refresh timer is running.

[`tmux/`](tmux/) and [`starship/`](starship/) use snapshot-only templates.
[`agent-wrapper/`](agent-wrapper/) demonstrates `pick`; map account IDs to the
tool's actual login environment before running it.
