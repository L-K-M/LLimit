# AGENTS.md

## What this is

**LLimit** is a self-contained macOS menu-bar app + WidgetKit widgets that display
remaining LLM subscription quota across multiple providers. **The app owns account
management**: the user adds/edits/removes accounts inside LLimit, including multiple
accounts per provider, and credentials are stored by LLimit. It does not depend on
any other tool at runtime.

`CredentialDiscovery` exists only as an *optional import shortcut* — it can detect a
login from a locally installed tool (Claude Code, Codex, Copilot, OpenCode) so the
user can one-click create a pre-filled account instead of pasting a token. Once
imported, the account is copied into and owned by LLimit.

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
- `LLimitWidgetExtension/` — dashboard, trend, and configurable provider/account widgets.
- `Shared/SharedConstants.swift` — App Group id + shared file paths, used by both targets.

## Data flow

1. The user manages `[ProviderAccount]` in Settings → Accounts (add/rename/enable/
   remove, multiple per provider, credentials entered or imported).
2. `AppModel.scanForDetectedCredentials()` (optional) runs `CredentialDiscovery().discover()`
   plus the macOS Keychain for Claude → `[DiscoveredCredential]`; `importAccount(from:)`
   copies one into a new owned account.
3. `QuotaCoordinator` fetches usage from each enabled account's provider in parallel.
4. The `QuotaSnapshot` is written to the App Group container; settings + history too.
5. `WidgetCenter.reloadAllTimelines()` triggers the widgets, which read the snapshot.

## Hard constraints

- Credentials are stored **locally only** in the app's own settings file
  (`~/Library/Application Support/LLimit/`, mode `600`). Anything written to the App
  Group / widget store or logs must be redacted via
  `AppSettings.redactedCredentials()` — the widget never needs credentials.
- The host app is **not sandboxed** (the import shortcut reads `~/.claude`, `~/.codex`,
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

### Widget registration

- Keep `REGISTER_WITH_LAUNCH_SERVICES: NO` on the host app target. Xcode must not
  register the intermediate `build/Build/Products/.../LLimit.app`; only the installed
  `/Applications/LLimit.app` may be registered.
- Do not remove the recursive `lsregister` cleanup/registration or `chronod` restart
  from `scripts/build.sh --install`. Registering both the intermediate and installed
  apps creates duplicate widget-extension `pluginUUID`s. WidgetKit then marks the
  extension bad with `Bundle version did not match; LaunchServices DB may need to be
  rebuilt`, and new widget kinds do not appear in the gallery.
- Keep the app and widget extension on the same, monotonically increasing
  `CURRENT_PROJECT_VERSION`, especially whenever the `WidgetBundle` catalog changes.
- Widgets carry NO widget-side configuration: the macOS "Edit Widget" flow never
  worked for this app across builds 7-13 (see ANALYSIS.md) regardless of intent
  shape, so the provider tiles are static slot widgets whose account assignment
  lives in the app (Settings → Widgets, `AppSettings.providerTileSlots`). Do not
  reintroduce `AppIntentConfiguration`/`WidgetConfigurationIntent` without new
  evidence that the Edit flow works on this system.
- Treat placed widget `kind` strings as frozen; changing one orphans placed tiles
  (Apple forums thread 746574). The slot count is compile-time (one Widget type
  per kind) — keep `AppSettings.providerTileSlotCount`, the
  `ProviderTileSlotNWidget` types, and `SharedConstants.providerSlotWidgetKinds`
  in sync when changing it.

```bash
xcodegen generate
open LLimit.xcodeproj            # set DEVELOPMENT_TEAM on both targets
cd Packages/QuotaCore && swift test
```
