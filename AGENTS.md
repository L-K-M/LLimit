# AGENTS.md

## What this is

**LLimit** is a standalone macOS menu-bar app + WidgetKit widgets that display
remaining LLM subscription quota across multiple providers. Its defining feature is
**zero-configuration credential auto-discovery**: it reads credentials that locally
installed AI tools already wrote, so the user never pastes a token.

Providers: Claude (Anthropic), OpenAI/ChatGPT, GitHub Copilot, Zhipu, Z.ai, Google
(Antigravity).

## Layout

- `Packages/QuotaCore` — pure-Foundation Swift package (the "brain"). No SwiftUI /
  AppKit / WidgetKit. **Compiles and is unit-tested on Linux** (`swift test`), so put
  all non-UI logic here.
  - `CredentialDiscovery.swift` — scans local config files for credentials.
  - `Clients/*.swift` — one `QuotaProviderClient` per provider API.
  - `QuotaCoordinator.swift` — fans out client calls in parallel into a `QuotaSnapshot`.
  - `Models.swift`, `*Store.swift`, `Utilities.swift`.
- `LLimitApp/` — the menu-bar app (`MenuBarExtra`), `AppModel`, settings UI.
- `LLimitWidgetExtension/` — dashboard + trend widgets and their timeline provider.
- `Shared/SharedConstants.swift` — App Group id + shared file paths, used by both targets.

## Data flow

1. `AppModel.rescanSources()` runs `CredentialDiscovery().discover()` (plus the macOS
   Keychain for Claude) → `[DiscoveredCredential]`.
2. Discovered credentials are merged with persisted per-source preferences (enabled /
   name), keyed by a deterministic `stableID`, into `[ProviderAccount]`.
3. `QuotaCoordinator` fetches usage from each enabled provider in parallel.
4. The `QuotaSnapshot` is written to the App Group container; settings + history too.
5. `WidgetCenter.reloadAllTimelines()` triggers the widgets, which read the snapshot.

## Hard constraints

- **Never persist or log credentials.** Only `enabled` + display-name preferences are
  saved (`ProviderAccount.redactedCredentials()`); credentials are re-discovered at
  runtime each launch.
- The host app is **not sandboxed** (it must read `~/.claude`, `~/.codex`,
  `~/.config/github-copilot`, `~/.local/share/opencode`, and the Keychain). The widget
  extension **stays sandboxed**; it only reads the App Group container.
- Adding a `QuotaProvider` case is a breaking change for exhaustive `switch`es: update
  `Models.displayName`, `Models.credentialFields`, and the widget's `compactProviderName`.
- Provider APIs are undocumented and unstable. Fail gracefully (`ProviderFailure`) and
  keep showing the last good snapshot.

## Adding a provider

1. Add the case to `QuotaProvider` (+ `displayName`, `credentialFields`, widget name).
2. Add credential keys to `CredentialField`.
3. Add a `QuotaProviderClient` in `Clients/` and register it in `QuotaCoordinator.live()`.
4. Teach `CredentialDiscovery` where that tool stores its credentials.
5. Add unit tests (discovery parsing + client decoding) — these run on Linux.

## Provider API notes

- **Anthropic**: `GET https://api.anthropic.com/api/oauth/usage` with `Authorization:
  Bearer`, `anthropic-beta: oauth-2025-04-20`, and a `User-Agent: claude-code/<ver>`
  (mandatory — without it the endpoint hard rate-limits). Returns `five_hour`,
  `seven_day`, `seven_day_opus` windows with `utilization` (0–100) + `resets_at`.
  Poll no faster than ~3 min; LLimit's ≥15 min interval is safe.
- **OpenAI**: ChatGPT web endpoint `https://chatgpt.com/backend-api/wham/usage` with the
  Codex/OpenCode OAuth access token + `ChatGPT-Account-Id`.
- **Copilot**: GitHub internal `copilot_internal/user` (OAuth) or the public premium-
  request billing API (PAT + username).

## Build

Requires macOS 14+, Xcode 15+, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
open LLimit.xcodeproj            # set DEVELOPMENT_TEAM on both targets
cd Packages/QuotaCore && swift test
```
