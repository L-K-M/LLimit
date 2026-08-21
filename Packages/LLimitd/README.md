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
- `Sources/llimit/` — the CLI executable (`main.swift`).
- `examples/` — waybar / polybar / eww modules consuming `llimit status --json`.
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

XDG defaults (`~/.config`, `~/.local/share`) apply when the variables are unset;
relative XDG values are ignored per the spec. Run `llimit paths` to see the
resolved locations.

## Usage

```
llimit accounts list
llimit accounts add --provider anthropic        # prompts for that provider's fields
llimit accounts import                          # list discovered local logins, import one
llimit accounts enable|disable|remove <id>      # id may be a unique prefix
llimit refresh                                  # one-shot fetch, writes the snapshot
llimit status                                   # human-readable
llimit status --json                            # waybar/polybar contract
llimit daemon                                   # refresh loop in the foreground
```

Fetch errors never crash the daemon: a failed account records a `ProviderFailure`
and keeps showing its last-known usage (same `mergingStaleUsage(from:)` behavior as
the macOS app). The daemon reloads settings every cycle, so `llimit accounts …`
edits from another shell take effect without a restart.

## systemd

```
Packages/LLimitd/systemd/install.sh             # daemon service (default)
Packages/LLimitd/systemd/install.sh -- --timer  # one-shot service + 30-min timer
```

Units land in `~/.config/systemd/user/` and assume the binary at `~/.local/bin/llimit`.
The daemon service is the launch-at-login replacement (`WantedBy=default.target`);
the timer pair is an alternative for people who prefer no long-running process.

## Status bars

`llimit status --json` prints one JSON object (`text`, `tooltip`, `class`,
`percentage`, plus an `accounts` array) built only from the snapshot — no
credentials, ever. Ready-made modules:

- `examples/waybar/` — `custom` module config + CSS for the `ok` / `warning` /
  `critical` / `error` / `empty` classes.
- `examples/polybar/` — `custom/script` module + `jq`-based renderer script.
- `examples/eww/` — `defpoll` widget; eww parses the JSON natively.

See [`examples/README.md`](examples/README.md) for the full key-by-key contract.

## Tray icon

`llimit-tray` puts LLimit in the system tray and shows every account and every
limit in a popup — the Linux counterpart of the macOS menu-bar item.

```
$ llimit-tray                 # or: systemctl --user enable --now llimit-tray.service
```

It is a display surface only: it shells out to `llimit status --json` and never
reads the settings file, so it never touches credentials. Account management
stays in the CLI. The tray icon colour follows the same
`ok`/`warning`/`critical`/`error`/`empty` classes the bar modules use.

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
