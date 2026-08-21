# llimitd — LLimit for Linux (Phase 1)

A headless port of LLimit's quota tracking: a `llimit` CLI plus a refresh daemon,
reusing the verified `QuotaCore` package untouched. No GUI, no tray — Phase 2 wires
`llimit status --json` into waybar/polybar.

## Layout

- `Sources/LLimitdCore/` — the testable core:
  - `LinuxPaths.swift` — XDG path resolution, replacing `Shared/SharedConstants.swift`.
  - `QuotaDaemon.swift` — headless orchestration (settings, refresh loop, account
    mutations, token hygiene), ported from `LLimitApp/AppModel.swift` +
    `Services/RefreshService.swift` minus `@MainActor`/Combine/Keychain/WidgetKit.
  - `StatusRenderer.swift` — human-readable status and the waybar JSON contract.
- `Sources/llimit/` — the CLI executable (`main.swift`).
- `systemd/` — user units replacing the macOS launch-at-login path.

## Files

| What | Where | Notes |
| --- | --- | --- |
| settings | `$XDG_CONFIG_HOME/LLimit/quota-settings.json` | mode 0600, the only file with credentials |
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

## Build & test

```
swift build --package-path Packages/LLimitd
swift test  --package-path Packages/LLimitd
```

No third-party dependencies; the only dependency is `../QuotaCore` by path.
