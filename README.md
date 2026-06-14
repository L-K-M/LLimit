# LLimit

**LLimit** is a macOS menu-bar app + desktop widgets that show how much of your
LLM subscription quota is left — across all the AI coding tools you already use.

The whole point is **zero configuration**: LLimit reads the credentials that tools
like Claude Code, Codex, GitHub Copilot and OpenCode *already wrote to disk when
you logged in*. You never paste a session token or API key.

## Supported providers & where the credentials come from

| Provider            | Detected from                                                                 |
| ------------------- | ----------------------------------------------------------------------------- |
| **Claude** (Anthropic) | Claude Code — macOS Keychain (`Claude Code-credentials`) or `~/.claude/.credentials.json`, or OpenCode |
| **OpenAI / ChatGPT**   | Codex CLI (`~/.codex/auth.json`) or OpenCode                                |
| **GitHub Copilot**     | `~/.config/github-copilot/{hosts,apps}.json`, `~/.copilot/config.json`, or OpenCode |
| **Zhipu AI**           | OpenCode (`zhipuai-coding-plan`)                                            |
| **Z.ai**               | OpenCode (`zai-coding-plan`)                                                |
| **Google (Antigravity)** | OpenCode (`~/.config/opencode/antigravity-accounts.json`)               |

Open **Settings → Sources** to see exactly what was detected (and a scan log if
something is missing). Toggle any source on/off and rename it. If you log into a
new tool, hit **Rescan**.

> Usage data is fetched directly from each provider's own API using your existing
> login. Credentials are read at runtime and **never written to LLimit's settings,
> the widget, logs, or anywhere on disk** — only per-source on/off + name
> preferences are saved.

## Requirements

- macOS 14+
- Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Build & run

```bash
brew install xcodegen      # if needed
xcodegen generate          # or: ./scripts/bootstrap.sh
open LLimit.xcodeproj
```

1. Select your Apple Developer **signing team** for both targets (`LLimit` and
   `LLimitWidgetExtension`). The App Group is `$(TeamIdentifierPrefix)group.ch.lkmc.llimit`.
2. Run the `LLimit` target. It lives in the menu bar (no Dock icon).
3. Sign in to at least one supported tool, click **Rescan**, then **Refresh now**.
4. Add the widget from the desktop / Notification Center gallery.

The first time LLimit reads Claude's token from the Keychain, macOS will ask you to
allow access — click **Always Allow**. (To skip the prompt entirely you can export
the token to a file once:
`security find-generic-password -s "Claude Code-credentials" -w > ~/.claude/.credentials.json`.)

## Why the app isn't sandboxed

To stay configuration-free, the host app must read dotfiles in your home directory
and the Claude Keychain item. The App Sandbox blocks that (or forces a "grant file
access" prompt per file). LLimit is distributed directly rather than through the Mac
App Store, so the host app runs unsandboxed while the **widget extension stays
sandboxed** and only ever reads the shared App Group container. See
[`AGENTS.md`](AGENTS.md) for the full architecture.

## How it works

1. The host app discovers credentials from local AI tools (`QuotaCore.CredentialDiscovery`).
2. `QuotaCoordinator` fetches usage from each provider's API in parallel.
3. The result is written as a `QuotaSnapshot` JSON file into the App Group container.
4. `WidgetCenter.reloadTimelines` nudges the widgets, which read the snapshot and render.

The pure-Swift core (`Packages/QuotaCore`) is covered by unit tests:

```bash
cd Packages/QuotaCore && swift test
```
