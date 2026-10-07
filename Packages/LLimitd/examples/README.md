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
| `text` | one-line summary, one segment per account |
| `tooltip` | multi-line detail (age, per-metric remaining %, errors) |
| `class` | `ok` / `warning` / `critical` / `error` / `empty` — see below |
| `percentage` | lowest remaining percent across accounts; omitted with no data |
| `accounts` | per-account objects for richer widgets (id, provider, name, remainingPercent, stale) |

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

## Status lines and scripts

These use `llimit status --format`, `llimit check` and `llimit pick` (see
[`../README.md`](../README.md#status-lines-and-scripts) for placeholders and exit
statuses). Like `--json`, they read only the snapshot and need no `jq`.

- [`tmux/`](tmux/) — `status-right` showing the account with the least quota
  left, colored by `{class}` with the bar palette.
- [`starship/`](starship/) — a `custom` prompt module, optionally shown only
  while a provider runs low.
- [`agent-wrapper/`](agent-wrapper/) — `llimit-agent` starts Claude Code or
  Codex, whichever account has the most quota left.
