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

## Tray icon: assessed, not built

A StatusNotifierItem tray (the menu-bar equivalent) was scoped for Phase 2 and
cut, deliberately:

- SNI is D-Bus, and Swift has no D-Bus binding — it means a C system-library
  target against libdbus-1/sd-bus, hand-marshalled messages, and fd-watch
  integration with Swift concurrency (~1,000 lines, none of it meaningfully
  testable in CI without a session bus, a watcher, and eyeballs).
- The dropdown menu is a *second* protocol (`com.canonical.dbusmenu`).
- GNOME — the majority desktop — shows no tray icons at all without the
  AppIndicator extension, so the work would primarily serve KDE/Cinnamon/XFCE.
- The bar modules above already deliver the at-a-glance value on exactly the
  desktops where status bars are used, from a contract that already exists.

If a tray is revisited, the cheap route is a ~150-line helper in a language with
mature D-Bus/AppIndicator bindings (e.g. Python + PyGObject) polling
`llimit status --json` — not libdbus-from-Swift.

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
