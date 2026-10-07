# llimitd — LLimit for Linux

A headless port of LLimit's quota tracking: a `llimit` CLI plus a refresh daemon,
reusing the verified `QuotaCore` package untouched. `llimit status --json` is the
credential-free display contract; drop-in bar modules for waybar, polybar and eww
live in [`examples/`](examples/).

## Layout

- `Sources/LLimitdCore/` — the testable core:
  - `LinuxPaths.swift` — XDG path resolution, replacing `Shared/SharedConstants.swift`.
  - `QuotaDaemon.swift` — headless orchestration (settings, refresh loop, account
    mutations, token hygiene), ported from `LLimitApp/AppModel.swift` +
    `Services/RefreshService.swift` minus `@MainActor`/Combine/Keychain/WidgetKit.
  - `SettingsLock.swift` — flock-based mutual exclusion for settings read-modify-write
    (daemon token refresh vs. concurrent `llimit accounts …`).
  - `StatusRenderer.swift` — human-readable status and the waybar JSON contract.
  - `StatusTemplate.swift` — `llimit status --format` templates.
  - `ScriptCommands.swift` — options and results of `status`, `check` and `pick`,
    ranked by QuotaCore's `HeadroomRanking`.
  - `QuotaAlerts.swift`, `AlertDelivery.swift`: opt-in alerts through QuotaCore's
    `QuotaEvents` detector, with dedupe state, notify-send and `--on-event` hooks.
- `Sources/llimit/` — the CLI executable (`main.swift`; `SnapshotCommands.swift`
  holds the snapshot-only `status`, `check` and `pick`).
- `examples/` — waybar / polybar / eww modules consuming `llimit status --json`,
  tmux and starship status lines, an agent wrapper built on `llimit pick`, and
  `--on-event` hooks in `examples/hooks/`.
- `tray/` — the tray icon (Python/PyGObject; see "Tray icon"). `llimit_tray.py`
  keeps its menu model as a pure function so it is unit-tested without GTK;
  `tray/tests/` holds those tests and `tray/icons/` the per-status SVGs.
- `systemd/` — user units replacing the macOS launch-at-login path.
- `packaging/build-deb.sh` — assembles the installable `.deb`.

## Files

| What | Where | Notes |
| --- | --- | --- |
| settings | `$XDG_CONFIG_HOME/LLimit/quota-settings.json` | mode 0600, the only file with credentials |
| settings lock | `$XDG_CONFIG_HOME/LLimit/quota-settings.lock` | flock sidecar; never holds data |
| snapshot | `$XDG_DATA_HOME/LLimit/quota-snapshot.json` | credential-free; the IPC contract |
| history | `$XDG_DATA_HOME/LLimit/quota-history.json` | credential-free |
| alerts state | `$XDG_DATA_HOME/LLimit/alerts-state.json` | mode 0600, credential-free; only written with alerts on |

XDG defaults (`~/.config`, `~/.local/share`) apply when the variables are unset;
relative XDG values are ignored per the spec. Run `llimit paths` to see the
resolved locations.

## Usage

```
llimit accounts list
llimit accounts add --provider anthropic        # prompts for that provider's fields
llimit accounts add --provider opencode-go      # prompts for your OpenCode Go API key
llimit accounts add --provider venice           # prompts for your Venice API key
llimit accounts add --provider cline            # prompts for your Cline API key
llimit accounts import                          # list discovered local logins, import one
llimit accounts enable|disable|remove <id>      # id may be a unique prefix, any case
llimit accounts rename <id> <name>
llimit accounts update <id> --set anthropic.access_token   # prompts, input hidden
llimit accounts reimport <id>                   # refresh credentials from a local login
llimit refresh                                  # one-shot fetch, writes the snapshot
llimit status                                   # human-readable
llimit status --json                            # waybar/polybar contract
llimit status --worst --format '{name} {remaining}'  # one short line, see below
llimit check anthropic --min 10                 # exit status for scripts
llimit pick --provider anthropic,openai         # account with the most quota left
llimit daemon                                   # refresh loop in the foreground
llimit daemon --notify                          # ...with desktop alerts (see "Alerts")
```

`status`, `check` and `pick` read only the snapshot, never the settings file, so
bars and prompts can poll them as often as they like.

Fetch errors never crash the daemon: a failed account records a `ProviderFailure`
and keeps showing its last-known usage (same `mergingStaleUsage(from:)` behavior as
the macOS app). The daemon reloads settings every cycle, so `llimit accounts …`
edits from another shell take effect without a restart.

`update`, `rename` and `reimport` change an account in place: its ID, history and
colors stay. Use them when a token expires instead of removing the account and
adding it again. `update --set key=value` sets a value directly. `--set key` with
no value prompts for it in a terminal, which keeps a secret out of your shell
history; press Enter to keep the current value. Without a terminal it fails
instead of saving nothing. `reimport` reads the login that a local tool
currently holds for the account's provider. When several are detected, choose
one with `--from <stable-id>`. A new Claude token or Venice key also clears
data that belonged to the old one: managed-profile details for Claude, and the
estimated DIEM allowance for Venice.

`accounts import` matches logins by their primary secret, the access token or
API key. If a detected login differs from your existing accounts of that
provider, such as a renewed Claude token, `import` asks whether to update one of
those accounts, add a new one, or skip. Without a terminal it skips the login,
prints the matching `reimport` command, and exits with status 1. Pass `--new`
to add it as a separate account.

If the settings file can't be read or parsed, every command that uses it stops
and names the file and the failing location, such as `accounts[0].provider`. The
message never quotes the file's contents. LLimit never overwrites the file and
keeps the saved snapshot. `llimit status`, `check` and `pick` read only the
snapshot, so they keep working. The daemon logs the problem once and skips
refreshes until the file is fixed.

OpenCode Go reports rolling, weekly, and monthly subscription limits. Add it with
`--provider opencode-go`, or import the `opencode-go` API key from OpenCode's
`auth.json` under `$XDG_DATA_HOME/opencode` (default `~/.local/share/opencode`).
The key is copied into LLimit's local settings. No OpenCode process is required
after import, and usage polling does not make inference requests.

Venice tracks daily DIEM and USD-denominated API credit balances. An Admin key
provides the daily DIEM allocation; other keys use an estimated upper bound from
the first positive balance, a balance increase, or a new server reset period.
The bound survives daemon restarts; percentages are marked `≈` and metrics expose
`estimated: true` in JSON. The first reading may already be partly spent. Import reads
`~/.venice/config.json` (`api_key`) or OpenCode's `venice` entry in `auth.json`.
USD and bundled credits remain amounts without percentages. These are API
balances, not web-app message/image quotas.

Cline tracks both billing modes. ClinePass, the monthly subscription, reports
five-hour, weekly, and monthly window limits with reset times; Cline credits, the
prepaid pay-as-you-go balance, has no reported total or reset and stays an amount
without a percentage. Add it with `--provider cline`, or import a Cline login from
`~/.cline/data/settings/providers.json` (`providers.cline.settings.apiKey` or
`settings.auth.accessToken`) and the legacy flat `~/.cline/data/secrets.json`
(`clineApiKey`). Only the access token is imported: LLimit does not renew Cline
sessions, so an expired one needs a fresh import. No Cline process is required
after import, and polling reads the account API without making inference requests.

## systemd

```
Packages/LLimitd/systemd/install.sh             # daemon service (default)
Packages/LLimitd/systemd/install.sh -- --timer  # one-shot service + 30-min timer
```

Units land in `~/.config/systemd/user/` and assume the binary at `~/.local/bin/llimit`.
The daemon service is the launch-at-login replacement (`WantedBy=default.target`);
the timer pair is an alternative for people who prefer no long-running process.

## Alerts

Alerts are off by default. With them on, the daemon tells you when quota runs
low, when a window that ran low resets, when an account needs a new sign-in,
and when a weekly or monthly window is about to reset mostly unused.

```
llimit daemon --notify                          # desktop notifications through notify-send
llimit daemon --on-event ~/bin/llimit-hook      # run your own executable per event
llimit daemon --notify --thresholds 30,10       # thresholds in % remaining (default 20,5)
LLIMIT_NOTIFY=1 llimit daemon                   # same as --notify; meant for the systemd unit
```

| `LLIMIT_EVENT` | when | severity |
| --- | --- | --- |
| `threshold` | remaining falls to or below a threshold; a drop past several sends one alert for the lowest | `critical` at the lowest threshold, otherwise `normal` |
| `reset` | a window that had reached the highest threshold resets and its quota comes back | `normal` |
| `failure` | an account fails authentication or its usage response cannot be read (network and rate-limit errors are ignored) | `critical` |
| `recovered` | that account refreshes successfully again | `normal` |
| `expiringUnused` | a weekly or monthly window resets within 24 hours with 50% or more left | `normal` |

Each alert is sent once, including for conditions that already hold when you
turn alerts on. A threshold fires again only after remaining climbs 5 points
above it or its window ends, and `expiringUnused` fires once per window. What was sent is recorded in `alerts-state.json`, so restarting the
daemon does not repeat alerts. Alerts need the daemon: `llimit refresh` and
the timer units do not send them.

`--notify` needs `notify-send` (`libnotify-bin` on Debian and Ubuntu). When it
is missing, the daemon logs one warning and keeps running without it.

### Hooks

`--on-event <cmd>` runs an executable (a path, or a name on `PATH`) once per
event, without a shell and without arguments. It inherits the daemon's
environment and receives the event only through these variables, which are
unset when they do not apply:

| variable | value |
| --- | --- |
| `LLIMIT_EVENT` | `threshold`, `reset`, `failure`, `recovered` or `expiringUnused` |
| `LLIMIT_SEVERITY` | `normal` or `critical` |
| `LLIMIT_ACCOUNT_ID`, `LLIMIT_ACCOUNT_NAME`, `LLIMIT_PROVIDER` | the account |
| `LLIMIT_METRIC`, `LLIMIT_METRIC_LABEL` | the limit's id and display label |
| `LLIMIT_REMAINING` | remaining percent, a whole number (`4`) |
| `LLIMIT_ESTIMATED` | `1` when that percentage is an estimate |
| `LLIMIT_THRESHOLD` | the threshold crossed, a whole number (`5`) |
| `LLIMIT_RESETS_AT` | when the current window resets, ISO 8601 |
| `LLIMIT_FAILURE_KIND` | `auth` or `decoding` |
| `LLIMIT_SUMMARY`, `LLIMIT_BODY` | a ready-made notification title and text |

Provider error messages and credentials are never passed. Hooks run one at a
time with stdin on `/dev/null`. One still running after 10 seconds is stopped
(SIGTERM, then SIGKILL, along with anything it started), so a slow hook never
delays a refresh. Examples: [`examples/hooks/notify-send.sh`](examples/hooks/notify-send.sh)
for custom desktop notifications and [`examples/hooks/ntfy.sh`](examples/hooks/ntfy.sh)
to push alerts to a phone through [ntfy](https://ntfy.sh).

### With systemd

The shipped unit leaves alerts off. Turn them on with a drop-in, which
survives reinstalls and package upgrades:

```
systemctl --user edit llimit.service
```

```ini
[Service]
Environment=LLIMIT_NOTIFY=1
```

For a hook, replace the command line in the same drop-in (`/usr/bin/llimit`
for the .deb):

```ini
[Service]
ExecStart=
ExecStart=%h/.local/bin/llimit daemon --on-event %h/.config/LLimit/hooks/ntfy.sh
Environment=NTFY_TOPIC=your-unguessable-topic
```

Then run `systemctl --user restart llimit.service`. Desktop notifications use
the session bus address the systemd user manager normally provides.

## Status bars

`llimit status --json` prints one JSON object (`text`, `tooltip`, `class`,
`percentage`, plus `accounts` and `failures` arrays) built only from the snapshot —
no credentials, ever. A failed or stale account is flagged per account, marked with
`!` in `text`, and raises the class to `warning`. Ready-made modules:

- `examples/waybar/` — `custom` module config + CSS for the `ok` / `warning` /
  `critical` / `error` / `empty` classes.
- `examples/polybar/` — `custom/script` module + `jq`-based renderer script.
- `examples/eww/` — `defpoll` widget; eww parses the JSON natively.

See [`examples/README.md`](examples/README.md) for the full key-by-key contract.

## Status lines and scripts

### Templates

`llimit status --format '<template>'` prints one expansion per account, joined
by `--separator` (default ` · `), for tmux, starship, i3blocks or a shell prompt:

```
$ llimit status --format '{name} {remaining}'
Claude 35% · Kimi 95% · OpenAI 55%
$ llimit status --worst --format '{name} {remaining} {kind}, resets in {reset}'
Claude 35% weekly, resets in 2d 3h
```

| placeholder | value |
| --- | --- |
| `{id}` | account id |
| `{name}` | account name |
| `{provider}` | provider id, e.g. `anthropic` |
| `{remaining}` | `42%`, `≈42%` when estimated, `unlimited`, or `n/a` without a percentage |
| `{metric}` | label of the limit behind `{remaining}`, e.g. `7-day limit` |
| `{kind}` | that limit's window: `session`, `daily`, `weekly`, `monthly`, `other` |
| `{reset}` | time until that limit resets, e.g. `3h 12m`; empty when unknown |
| `{class}` | `ok`, `warning` (< 40%), `critical` (< 15%), `error` (refresh failed), `empty` |
| `{age}` | age of the account's data, e.g. `4 min ago` |
| `{stale}` | `stale` when the data is older than two hours, otherwise empty |

`{remaining}` is the account's lowest remaining percentage, like the bar
headline; balances without a percentage show `n/a` (the `--json` output has
them). Unknown placeholders are printed as written. Values never contain line
breaks or tabs.

The other status options also work with the default and `--json` output:

- `--account <id|provider>` (repeatable) shows only those accounts. Ids may be
  shortened to a unique prefix; a provider id selects all of its accounts.
- `--worst` shows only the account with the least quota left, including stale or
  failing accounts with data on record.
- `--kind <kind>` ranks `--worst` and fills `{remaining}` from one window kind.
- `--watch [duration]` re-renders every interval (default 60s; a bare number is
  seconds, as in `--max-age`) until interrupted, flushing each render, for
  consumers that read a stream (i3blocks `interval=persist`, waybar without
  `interval`). Each distinct warning is printed to stderr only once.
- A provider or account with nothing in the snapshot selects nothing and gets a
  warning on stderr. A blank `--format` template is an error.

Without these options, `llimit status` and `llimit status --json` print exactly
what they always have.

### `check` and `pick`

```
llimit check <account-id|provider> [--min <pct>] [--max-age <duration>] [--kind <kind>]
llimit pick [--provider <id>[,<id>…]] [--kind <kind>] [--min <pct>] [--max-age <duration>] [--format <template>]
```

Both rank accounts by headroom: the lowest remaining percentage across an
account's limits (or across one `--kind` of window). Unlimited quota ranks above
every percentage, and ties go to the account whose limit resets sooner. Accounts
whose last refresh failed, or whose data is older than `--max-age` (default
`2h`; accepts `90s`, `30m`, `2h`, `1d`), are excluded. Raise `--max-age` if your
refresh interval is longer than two hours.

`check` reports on one account, or on the best account of a provider, and prints
one line. `pick` prints the best account as `<id><TAB><name>`, or through
`--format` with the template placeholders above; when nothing qualifies, stdout
stays empty and the reason goes to stderr. `--min` defaults to 1 (not exhausted).

| exit status | meaning |
| --- | --- |
| 0 | ok: at least `--min` percent left |
| 1 | below `--min` |
| 2 | stale or failing: no current data, refreshing may help |
| 3 | no data: no snapshot, unknown account, or no quota reported |
| 64 | usage error |

```
if llimit check anthropic --min 10 >/dev/null; then claude; else codex; fi
```

`examples/agent-wrapper/llimit-agent` does this with `pick`, and
`examples/tmux/` and `examples/starship/` show the templates in a status line and
a prompt.

## Tray icon

`llimit-tray` puts LLimit in the system tray and shows every account and every
limit in a popup — the Linux counterpart of the macOS menu-bar item.

```
$ llimit-tray                 # or: systemctl --user enable --now llimit-tray.service
```

It is a display surface only: it shells out to `llimit status --json` and never
reads the settings file, so it never touches credentials. Account management
stays in the CLI. The tray icon colour follows the same
`ok`/`warning`/`critical`/`error`/`empty` classes the bar modules use. An account
whose latest refresh failed shows "failed" in its header and an `Error:` row, and
reset countdowns tick between snapshot reads.

The popup, dumped straight off the D-Bus menu a panel would render:

```
Updated 4 min ago
---
Claude — 8% left
Session — 62% left · resets in 3h 12m
Weekly — 8% left · resets in 4d 2h
---
Zhipu AI — unlimited
Plan — unlimited
---
Refresh now
Quit
```

`--print-menu` prints exactly that without needing GTK, which is the quickest
way to check the tray sees your data:

```
llimit-tray --print-menu
```

Options: `--interval` (seconds between snapshot reads, default 60), `--llimit`
(path to the binary), `--icon-dir`, and `--show-label` to put the quota text
beside the icon. The label is exported as Ayatana's `XAyatanaLabel`, so panels
that only implement the strict KDE spec ignore it.

### Why this part is Python

The tray protocol is StatusNotifierItem over D-Bus, and the popup is a *second*
protocol (`com.canonical.dbusmenu`). Swift has no D-Bus binding, so a native
implementation means hand-marshalling both — roughly 1,000 lines that CI cannot
meaningfully exercise. PyGObject wraps them already, and the tray needs nothing
from QuotaCore but the JSON the CLI already emits.

The dependencies are therefore `Suggests`, not `Depends` — the daemon and bar
modules stay dependency-free, and a headless install pulls in no GTK:

```
sudo apt install python3-gi gir1.2-ayatanaappindicator3-0.1
```

### Desktop support

GNOME shows no tray icons without the AppIndicator extension; KDE, Cinnamon,
XFCE, MATE and most wlroots bars (waybar's `tray` module) show them natively.
On GNOME, the bar modules or the extension are the options.

## Install from .deb (no Swift toolchain needed)

Release builds attach `llimit_<version>_amd64.deb`: a fully static (musl) binary,
the systemd user units (packaged at `/usr/lib/systemd/user/`, pointing at
`/usr/bin/llimit`), and the bar examples at `/usr/share/llimit/examples/`.

```
sudo dpkg -i llimit_*_amd64.deb
systemctl --user enable --now llimit.service
llimit accounts add --provider anthropic    # or: llimit accounts import
```

To build the package yourself:

```
swift sdk install <static-linux SDK for your Swift version>   # once
swift build -c release --swift-sdk x86_64-swift-linux-musl --package-path Packages/LLimitd
Packages/LLimitd/packaging/build-deb.sh <version>
```

## Build & test

```
swift build --package-path Packages/LLimitd
swift test  --package-path Packages/LLimitd
```

No third-party dependencies; the only dependency is `../QuotaCore` by path.
