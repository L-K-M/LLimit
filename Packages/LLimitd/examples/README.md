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
    {
      "id": "…", "provider": "anthropic", "name": "Claude",
      "remainingPercent": 82, "stale": false,
      "metrics": [
        {
          "id": "five_hour", "label": "5-hour limit", "unlimited": false,
          "remainingPercent": 82, "resetIn": "3h 12m",
          "resetAt": "2023-11-15T01:25:20Z", "resetSeconds": 11520
        }
      ]
    }
  ]
}
```

| key | meaning |
| --- | --- |
| `text` | one-line summary, one segment per account |
| `tooltip` | multi-line detail (age, per-metric remaining %, errors) |
| `class` | `ok` / `warning` / `critical` / `error` / `empty` — see below |
| `percentage` | lowest remaining percent across accounts; omitted with no data |
| `accounts` | per-account objects for richer widgets (id, provider, name, remainingPercent, stale) |
| `accounts[].metrics` | every limit as its own row (`id`, `label`, `unlimited`, `remainingPercent`, `usageLine`, `detail`) |
| `accounts[].metrics[].resetIn` | the fetch-time countdown string (frozen until the next refresh) |
| `accounts[].metrics[].resetAt` | absolute reset time, ISO 8601 UTC |
| `accounts[].metrics[].resetSeconds` | seconds until `resetAt`, recomputed on every read — use this (or `resetAt`) for a live countdown |

`stale` is true once an account's data is older than the staleness threshold, which is
derived from the configured refresh interval (`StatusRenderer.staleThreshold`); a slow
interval does not flag healthy accounts.

`class` is derived from the lowest remaining percentage across accounts:

| class | when |
| --- | --- |
| `ok` | every account ≥ 40% remaining |
| `warning` | some account 15–39% remaining |
| `critical` | some account < 15% remaining |
| `error` | every account failed to refresh |
| `empty` | no snapshot yet |

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
