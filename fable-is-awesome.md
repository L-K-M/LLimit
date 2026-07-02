# fable-is-awesome.md

A thorough review of **LLimit** by Claude Fable 5, with love and respect for the
work Claude 4.8 already put in. This is a genuinely nice codebase: a clean
`QuotaCore` package with real unit tests, a Linux-testable "brain", sensible
model/Codable design with legacy-migration decoders, and a lot of thought in the
widget styling system. The bones are good. The problems below are mostly about
**credential lifecycle** (why everything except Z.ai is broken) and **widget
refresh mechanics** (why the widgets "don't quite work"), plus a long tail of
polish, performance, and feature ideas.

> **Method & honesty note.** This review combines a full manual read of every
> source file with a multi-agent review pass. The provider-path agents (Claude,
> OpenAI, Copilot) completed and did external API research; the widget / app-UI /
> core / build / product agents were cut off by a session limit, so those sections
> are from my own first-hand reading. Findings that depend on **external API facts**
> (exact OAuth endpoints, client ids, response field types) are marked
> **⚠︎ verify** — they come from web research and community reports, not from
> Anthropic/OpenAI/GitHub documentation I could authoritatively confirm here, and
> must be re-checked before shipping. Confidence is stated per finding.

---

## TL;DR — the one-paragraph diagnosis

**Z.ai works because it uses a long-lived static API key. Almost everything else
is broken because it uses a short-lived OAuth token that LLimit imports once and
never refreshes correctly.** Claude Code access tokens expire in ~8 hours and
LLimit has no Anthropic refresh path at all; the OpenAI path *does* refresh but
fights with the Codex CLI over a rotating refresh token; and Copilot's JSON
decoder crashes on the fractional numbers the real quota API returns. The desktop
widgets "don't quite work" for three compounding reasons: (1) the official
GitHub-release build is ad-hoc signed, which strips the App Group entitlement so
widgets can't even register; (2) `WidgetCenter.reloadAllTimelines()` fires on
*every keystroke* in Settings, tripping WidgetKit's reload budget and freezing the
widget on stale data; and (3) the widget decodes the **entire** history file (up
to 6'000 snapshots) on every timeline refresh, which can blow the extension's tight
memory budget and get it killed. Fix the credential lifecycle and the widget
refresh/signing story and LLimit goes from "only Z.ai works" to "actually great."

---

## Severity legend

- 🔴 **Critical** — breaks a core flow (a provider fetch, widget rendering) for real users.
- 🟠 **Major** — wrong behaviour a real user will hit.
- 🟡 **Minor** — edge case, quality, or friction.
- ⚪ **Polish / idea** — cosmetic, or a net-new feature/idea.

---

## 1. Provider support — why everything but Z.ai is broken

### 🔴 P1. Claude (Anthropic): no OAuth token refresh — 401s within hours *(confidence: high)*
`CredentialDiscovery.swift:87`, `AppModel.swift` (`refreshExpiringChatGPTTokens`, `claudeToken`), `AnthropicClient.swift:44`

Claude Code stores `{ "claudeAiOauth": { "accessToken", "refreshToken", "expiresAt" } }`.
LLimit imports **only** `accessToken` and throws away the refresh token and expiry at
every discovery site (`scanClaudeCode`, the OpenCode `anthropic` branch, and the
Keychain reader). The proactive-refresh routine `refreshExpiringChatGPTTokens()`
filters `provider == .openAI` only — there is **no Anthropic equivalent**. Claude
Code access tokens live ~8 hours, so within hours of import every fetch returns 401
("Sign in again with Claude Code") and the account is dead forever, even though
Claude Code itself keeps working (it silently refreshes its own copy). This is the
single clearest match for "Claude is broken, Z.ai works."

**Fix (preferred, safe & robust):** on each refresh cycle — and reactively on a 401 —
**re-read the user's own `~/.claude/.credentials.json` / Keychain item** and adopt the
token Claude Code has *already* refreshed, instead of fetching with the frozen
imported copy. This keeps LLimit reading only the user's own local credential and
avoids performing OAuth token exchange itself.
**Fix (alternative):** capture `refreshToken`/`expiresAt` and add a
`refreshExpiringClaudeTokens()` mirroring the OpenAI path. ⚠︎ verify the exact
Anthropic OAuth token endpoint and client id before implementing — community
implementations disagree (`console.anthropic.com/v1/oauth/token` vs `/api/oauth/token`),
and this makes LLimit an OAuth client rather than a passive reader.

### 🟠 P2. Claude: stale credential file permanently shadows the live Keychain token *(confidence: high)*
`AppModel.swift:243`, `:367`

The Keychain is consulted **only** when file discovery finds nothing
(`if !result.credentials.contains(where: { $0.provider == .anthropic })`). On macOS the
Keychain is the *live* store (Claude Code keeps rotating it); a `~/.claude/.credentials.json`
file, when present, is usually a one-time dump that goes stale. So a dead file token
always wins over the live Keychain token. Worse, LLimit's own diagnostic tells the
user to `security find-generic-password -s 'Claude Code-credentials' -w > ~/.claude/.credentials.json`
— i.e. to *create* the shadowing file. Combined with P1, that makes auth unrecoverable
through the app's own remediation path. `expiresAt` is also never checked at import, so
an already-expired token imports as "Ready".

**Fix:** discover both sources, prefer the one with the later `expiresAt` (or Keychain
on macOS when timestamps are absent); skip/flag file tokens whose `expiresAt` is past;
remove or rephrase the "dump to a file" tip.

### 🟠 P3. Claude: spoofed User-Agent is wrong and the endpoint hard-429s pollers, with no backoff *(confidence: medium — ⚠︎ verify)*
`AnthropicClient.swift:18`

The transport (URL, method, `anthropic-beta: oauth-2025-04-20`, Bearer, response
parsing) checks out. But the `User-Agent: claude-code/1.0.110` reportedly does not match
Claude Code's real format (`claude-cli/<ver> (external, cli)`), and the OAuth usage
endpoint is reported to persistently 429 third-party pollers with no `Retry-After`.
LLimit surfaces the 429 and just retries next cycle — which can keep the account
rate-limited indefinitely.

**Fix:** add exponential backoff / a cool-down on 429 (skip that account for a multiple
of the interval), keep the last good snapshot visible during cool-down, and correct the
"safe polling window" comment. Match the real UA string if UA mimicry is intended.

### 🔴 P4. OpenAI: rotating refresh token fights the Codex CLI, permanently breaking both *(confidence: high)*
`AppModel.swift:409`

The HTTP layer is correct (`chatgpt.com/backend-api/wham/usage`, `ChatGPT-Account-Id`,
matching response structs). The bug is **credential lifecycle**: OpenAI uses *rotating*
refresh tokens — each refresh invalidates the previous one for sibling clients. LLimit
imports a one-time copy and refreshes independently, so as soon as the Codex CLI (or
LLimit) refreshes, the other side's stored refresh token is dead. Result: `400
invalid_grant` (printed only), then the usage call 401s forever — or, in the reverse
order, LLimit logs the user out of Codex.

**Fix:** for Codex-sourced accounts, re-read `~/.codex/auth.json` at fetch time and use
Codex's maintained token, refreshing only as a fallback; when `refresh` fails with
`invalid_grant`, re-scan the file to pick up Codex's rotated tokens before surfacing an
error.

### 🟠 P5. OpenAI: no reactive refresh on 401 (trusts only JWT `exp`) *(confidence: high)*
`AppModel.swift:406`, `OpenAIClient.swift`

`refreshExpiringChatGPTTokens()` skips refreshing whenever the JWT `exp` is >300 s away,
and `OpenAIClient` has no 401→refresh→retry path. A token revoked server-side while `exp`
is still days out wedges the provider: every cycle says "not expired", so the valid
refresh token is never used.

**Fix:** on a 401 with a refresh token present, refresh and retry once (or mark the token
expired so the next cycle refreshes).

### 🟡 P6. OpenAI: several lifecycle papercuts *(confidence: high)*
- **Disabled accounts still refresh** (`AppModel.swift:396`): the refresh loop filters by
  provider but not `isEnabled`, so a *disabled* OpenAI account keeps hitting
  `auth.openai.com` and rotating the shared refresh token — actively breaking the user's
  Codex login for an account they turned off. Filter to `isEnabled`.
- **"Added" badge blocks re-import** (`AppModel.swift:315`): `isDetectedCredentialImported`
  matches on *any* overlapping credential value, including the immutable `account_id`, so
  after tokens go stale the obvious "Import again" recovery path shows a green "Added"
  checkmark instead. Compare only secret fields, or offer "Re-import / Update".
- **Silent refresh failures + misleading 401 copy** (`AppModel.swift:420`): refresh failures
  go to `print` only, then the user sees "use a valid ChatGPT token, not a platform API
  key" — the wrong diagnosis. Record a `ProviderFailure` with an actionable message.
- **No manual refresh-token field** (`Models.swift:63`): manual OpenAI accounts can't store
  a refresh token, so they inevitably die; imported refresh tokens are invisible/uneditable.
  Add an optional secret "Refresh token" field.

### 🔴 P7. Copilot: JSON decoder crashes on fractional quota numbers *(confidence: high — ⚠︎ verify field types)*
`CopilotClient.swift:416` (`InternalQuotaDetail`), `:364` (`BillingUsageResponse.UsageItem`)

Premium requests bill in fractional multiples (0.25×/0.33× models), so `quota_remaining`,
`remaining`, `grossQuantity`, `netQuantity` come back as **numbers like `1327.56`**, but
the structs decode them as `Int`. `JSONDecoder` throws "does not fit in Int", the OAuth
path's *working* first attempt aborts, and the provider fails for essentially every active
user — "works" only right after a reset when values are still integral. This is a strong
second candidate (with P1/P4) for "the other providers are broken."

**Fix:** decode all numeric quota fields as `Double`, round only for display, and make
non-essential fields optional so schema drift can't take down the whole fetch.

### 🟡 P8. Copilot: smaller correctness/UX issues *(confidence: medium — ⚠︎ verify)*
- **Phantom `limit` field** (`:366`): the billing API has no `limit`, so `inferredLimit` is
  always nil and — without a manually entered tier — the ring/percentage never renders.
- **Dead session-token fallback** (`:152`): exchanges a Copilot session token then replays it
  against `api.github.com`, where it's never valid; adds two wasted round-trips (one to a
  404 path) before failing.
- **Swallowed status codes** (`:222`): every non-2xx (401/404/500) collapses into the same
  "configure a PAT" message; user can't tell "re-login" from "GitHub down" from "no Copilot".
- **Untrimmed credentials** (`:32`): validation trims but the client uses raw values, so a PAT
  pasted with a trailing newline shows "Ready" yet always 401s. Trim at the edge.
- **Org-billed users misdirected** (`:24`): the personal billing API excludes org seats; empty
  `usageItems` renders a confident but wrong "0 / limit, 100% left". Surface an error instead.
- **Misattributed discovery diagnostic** (`CredentialDiscovery.swift:159`): `hosts.json` is
  reported as the source whenever `apps.json` already produced a token.

### 🟠 P9. Zhipu vs Z.ai: same client, different host — Zhipu endpoint likely wrong *(confidence: medium — ⚠︎ verify)*
`QuotaCoordinator.swift:16-24`

Zhipu and Z.ai share `ZhipuQuotaClient`; Z.ai works, so the auth header format (raw key,
no `Bearer`) and response envelope (`success`/`code`/`data.limits[]`) are right. The one
material difference is the host: Zhipu points at `https://bigmodel.cn/api/monitor/usage/quota/limit`.
The likely correct host is **`https://open.bigmodel.cn/...`** (the documented Zhipu Open
Platform host); `bigmodel.cn` may not serve this API path. ⚠︎ verify the correct Zhipu
coding-plan usage host/path (cross-check the OpenCode `zhipuai-coding-plan` plugin), then
fix the URL in `QuotaCoordinator.live()`.

### 🟡 P10. Google (Antigravity): fragile, unverified, secret in source *(confidence: medium)*
`GoogleAntigravityClient.swift`

- Response shape (`models[key].quotaInfo.remainingFraction`, `resetTime`) and the
  `fetchAvailableModels` endpoint are **unverified** and have **no tests** — ⚠︎ verify.
- The OAuth **client secret is hardcoded** at `:16`. For an installed-app "public client"
  this is the known pattern rather than a true secret, but it's worth a comment and, ideally,
  moving provider constants somewhere they're clearly flagged.
- The access token is re-fetched from `oauth2.googleapis.com/token` on **every** poll with no
  caching; cache it until near expiry.
- `displayName` for `.googleAntigravity` is "Google Cloud" while everything else says "Google"
  / "Antigravity" — pick one label.

### 🟠 P11. A single failed fetch drops the provider from the snapshot entirely *(confidence: high)*
`QuotaCoordinator.swift:93`, `RefreshService.swift`

Each snapshot is built only from the current cycle's successes; a failure yields a
`ProviderFailure` but **no** carried-over usage. The new snapshot overwrites the old, so
the first failed Claude/OpenAI/Copilot cycle makes that ring **vanish** from the widgets
instead of showing stale-but-useful data. This is a big part of the "widgets don't quite
work" feeling once P1/P4/P7 kick in.

**Fix:** merge with the previous snapshot — for accounts that failed this cycle, retain the
last good `ProviderUsage` (its `fetchedAt` already communicates staleness) alongside the
failure, so widgets render stale data with an error badge.

### 🟡 P12. No HTTP retry/backoff; provider clients almost entirely untested *(confidence: high)*
`HTTPClient.swift`, `Packages/QuotaCore/Tests/…`

10 s timeout, no retry, no transient-error tolerance, no awareness of offline/captive-portal
states. And of six providers, only **Anthropic** has a client test — OpenAI, Copilot, Zhipu,
and Google have **zero** client decoding tests. P7 (the Copilot `Int` crash) is exactly the
kind of bug a decoding test would have caught. Add fixture-based decode tests for every client.

---

## 2. Desktop widgets — why they "don't quite work"

### 🔴 W1. Official release builds ship without the App Group entitlement → widgets can't register *(confidence: high)*
`scripts/build.sh`, `.github/workflows/release.yml`

The GitHub-release build is **ad-hoc signed** (`codesign --sign -`), and the script/README
themselves state ad-hoc mode has "NO entitlements, so the widget will NOT work." App Groups
on macOS require a provisioning-profile-backed entitlement; an ad-hoc binary can't claim
`$(TeamIdentifierPrefix)group.ch.lkmc.llimit`. So the **downloadable** app has a
non-functional headline feature — the widgets only ever work in a locally dev-signed build.

**Fix:** the honest path is a Developer ID signed + notarized release (needs signing secrets
in CI). At minimum, document loudly that widgets require a self-signed local build, and
consider a non-App-Group fallback (see W2) so a shared container isn't the only channel.

### 🔴 W2. `reloadAllTimelines()` fires on every keystroke → WidgetKit throttles into staleness *(confidence: high)*
`AppModel.swift:1088` (`reloadWidgetTimelines`), called from `saveConfiguration` / `refreshNow`

Every edit — typing in a credential/name field, toggling a switch, moving a colour picker —
runs `updateAccount → saveConfiguration → reloadWidgetTimelines()`. WidgetKit budgets timeline
reloads aggressively; hammering it means later, *meaningful* reloads get dropped and the widget
sits on stale data. Each keystroke also does two synchronous JSON file writes (local + app group).

**Fix:** debounce/coalesce saves (e.g. 0.5–1 s after the last edit), and only call
`reloadAllTimelines()` when data the widget actually renders changed (a new snapshot, or
style/visibility settings) — never on every character.

### 🔴 W3. Widget decodes the entire history file on every timeline refresh → memory-kill risk *(confidence: high)*
`QuotaTimelineProvider.swift:114` (`loadHistory`), `QuotaHistoryStore.swift`

The trend widget loads and decodes the **whole** history array — capped at **6'000 snapshots /
120 days**, pretty-printed with sorted keys — on every timeline build. Widget extensions have a
tight memory budget (~30 MB); a large history file can push decode over it and get the extension
jetsammed, which reads to the user as a blank/placeholder widget. The trend chart only ever needs
`trendHistoryDays` (≤30) of data.

**Fix:** store history as compact JSON; have the widget read only the last N days (a windowed
read, or a separate small "recent" file the app maintains for the widget); cap widget-side history
well below the app-side cap.

### 🟡 W4. `FancyWidgetBackground` ignores light/dark; "system/Default" is always blue-ish *(confidence: medium)*
`LLimitQuotaWidget.swift` (`FancyWidgetBackground`, `backgroundBaseColor`)

With the default/system style, `backgroundBaseColor(nil)` → `FancyWidgetBackground(baseColor: nil)`
falls back to a fixed blue gradient rather than adapting to the system light/dark widget background.
Grid/ring chrome is drawn with `Color.white.opacity(...)`, which is invisible/ugly on light
backgrounds. The "Default" preset therefore doesn't look like a native macOS widget.

**Fix:** when no explicit colour is set, use the system material (`containerBackground(.fill.tertiary…)`
or an adaptive colour) and derive chrome opacity from the colour scheme.

### 🟡 W5. Dead widget code and settings that render nothing *(confidence: high)*
- `ConcentricQuotaChart` and `CircularQuotaRing` are defined but **not used** by any current
  widget view (dashboards use `MiniProgressBar`; trend uses line paths). The elaborate
  "Circle graph colors" / inner-vs-outer ring settings UI configures rings **no widget draws** —
  the colours are only reused for bars/lines. This is confusing to a user tweaking "circle" colours.
- `WidgetVisibilitySettings.showResetInfo` is persisted and toggle-able but **never read** by any
  widget view — a dead setting.
- `resetSummaries` / `relativeResetSummary` are unused, and `relativeResetSummary` uses `Date()`
  instead of the timeline entry date (a latent bug if ever wired up).

**Fix:** either restore a concentric-ring widget family (nice!) so the ring settings mean something,
or relabel the settings as "meter colours" and delete the dead code.

### ⚪ W6. Widget capability gaps *(ideas)*
- No `.systemLarge` family (lots of room for a proper multi-account dashboard).
- No **configurable** widget (`AppIntentConfiguration`) to pick *which* account a widget shows —
  every widget shows the same global list.
- No `widgetURL` deep-linking (tapping a widget could open Settings to that account).
- "INF"/"--" text for unlimited/unknown instead of a nicer "∞"/em-dash.

---

## 3. Performance & stuttering

### 🟠 PERF1. Credential scan runs synchronously on the main actor (file IO + full Keychain enumeration) *(confidence: high)*
`SettingsView.swift:47` → `AppModel.scanForDetectedCredentials()`

Opening Settings calls `scanForDetectedCredentials()` on the `@MainActor`. It does multi-path
file IO, then `SecItemCopyMatching(kSecMatchLimitAll)` over **all** generic-password items (can be
thousands on a dev Mac — slow), then per-candidate data reads that can each raise a **synchronous
modal Keychain prompt**. Net effect: Settings can freeze/beachball on open, and a Keychain dialog
can appear with no user action. This is a concrete source of the reported stutter.

**Fix:** make the scan `async` and run discovery + attribute enumeration off the main actor,
publishing results back on `@MainActor`. Defer the data-reading (prompting) Keychain call to an
explicit user action, as the `autofillCredentials` comment already intends.

### 🟠 PERF2. Every keystroke writes two JSON files + reloads widgets *(confidence: high)*
`AppModel.swift` (`saveConfiguration`)

See W2. Beyond the widget-reload throttling, each edit synchronously encodes and writes the full
settings JSON *and* a redacted app-group copy on the main thread. Debounce writes; move encoding
off the main actor.

### 🟡 PERF3. History is fully rewritten every refresh, in two places *(confidence: high)*
`QuotaHistoryStore.append` (local + app-group)

`append` does load-all → append → filter → sort → write-all, pretty-printed, for both the local and
app-group history files, every refresh. With a large history that's meaningful IO and CPU each cycle.
Consider an append-friendly format or at least compact encoding and a smaller retention cap.

### 🟡 PERF4. No refresh on wake / network change *(confidence: high)*
`AppModel.restartAutoRefreshLoop`

The auto-refresh loop is a plain `Task.sleep(interval)`. After the Mac sleeps through a tick the data
is stale until the next full interval, and there's no refresh on network reachability change. Observe
`NSWorkspace.didWakeNotification` and trigger a refresh (respecting a min-interval) on wake.

### ⚪ PERF5. Battery/energy hygiene *(idea)*
Polling every 15–180 min is fine, but there's no pause when there are no enabled accounts, when the
snapshot is fresh, or when the machine is on battery and the app is background-only. Minor, but nice
for a menu-bar resident.

---

## 4. App logic, UX & visual issues

### 🟠 UX1. Failures surfaced only via a single overwritten `statusMessage` *(confidence: high)*
`AppModel.statusMessage`, `LLimitApp.swift`, `SettingsView.swift`

`statusMessage` is one global string that any operation overwrites, and per-provider failures show
only in the Overview card / menu. There's no persistent, per-account error surface (the menu shows a
flat "provider: message"). Users can't easily tell *which* account needs attention or *why*.

**Fix:** attach errors to accounts (badge in the sidebar row + a clear reason on the account page),
and stop clobbering unrelated status text.

### 🟡 UX2. No onboarding / first-run guidance *(confidence: high)*
First launch is a bare menu-bar icon; the only guidance is empty-state text inside Settings. A
first-run panel ("Add your first account → detected logins → Refresh") would help a lot, especially
since the menu-bar-only model gives no Dock affordance.

### 🟡 UX3. Menu-bar icon issues *(confidence: high)*
`LLimitApp.swift` (`MenuBarIcon`)

- Bars are drawn with `isTemplate = false` and provider colours, so they don't adapt to light vs dark
  menu bars and ignore "Reduce transparency"/accessibility.
- Icon width **grows with account count** (~30 px for 6 accounts) — can crowd a busy menu bar.
- No text/percentage display option, no tooltip, and the empty state is a generic `chart.bar.fill`.

**Fix:** offer display modes (worst-% text, single aggregate bar, monochrome template), cap the bar
count, and add a tooltip with the worst account.

### 🟡 UX4. `WindowAccessor` reconfigures the window on every SwiftUI update *(confidence: medium)*
`SettingsView.swift:1050`

`updateNSView` dispatches a window reconfigure (`styleMask`, min/max size) async on *every* view
update. It works, but it's wasteful and order-dependent. Since the app already hosts Settings in a
real AppKit `NSWindow` (`SettingsWindowController`), the `WindowAccessor` hack inside `SettingsView`
looks redundant — the window controller already sets the resizable mask and min size. Consider
removing the in-view accessor entirely.

### 🟡 UX5. Duplicate-name and matching heuristics get fragile with multiple accounts *(confidence: medium)*
`AppModel.nextDisplayName`, `SettingsView` (`soleConfiguredAccount`, `accountUsage`)

`nextDisplayName` counts existing accounts, so after deletions you can get two "OpenAI 2"s. And a
lot of `SettingsView` logic exists to reconcile snapshots keyed by `provider.rawValue` vs by
`accountID` ("Refresh again to match this account"). Since accounts already have stable UUIDs and
`ProviderUsage.accountID` is set from them, the provider-keyed fallback path is legacy cruft that
creates confusing "refresh again" states. Consider always keying by `accountID` and dropping the
fallback.

### ⚪ UX6. Code duplication: hex-colour parsing exists 4× *(polish)*
`Models.swift` (`normalizeHexColor`), `AppModel` (`parseHexColor`), `LLimitApp` (`NSColor(hexString:)`),
`LLimitQuotaWidget` (`Color(hexColor:)`). Consolidate into one `QuotaCore` hex utility.

### ⚪ UX7. Localization / number formatting *(polish)*
`Utilities.swift` (`formatIntLike`, `formatTokensMillions`)

Numbers are formatted with hardcoded US conventions and no `Locale`. For a Swiss author/audience the
convention is a decimal point with an apostrophe thousands separator (e.g. `1'024`). Route
user-visible numbers through a `NumberFormatter`. (Provider-supplied strings are en-centric, so this
is low priority, but the token/credit displays are LLimit's own.)

### ⚪ UX8. Accessibility *(polish)*
Menu-bar icon has a generic "LLimit" a11y label (no quota info); widget views have no VoiceOver
summaries; colour is the only channel for high/medium/low (add shape/label for colour-blind users).

---

## 5. Missing features users of a quota tracker will expect

1. **Threshold & reset notifications** *(high value)* — `UserNotifications` alerts at, say, 80%/95%
   used, and "your Claude 5-hour window just reset." The data and per-metric percentages already exist.
2. **In-app history chart** *(high value)* — history is collected (`QuotaHistoryStore`) but only ever
   shown in the *widget*. Surface a Swift Charts view inside the app (Overview) so history is visible
   without adding a widget.
3. **Burn-rate & time-to-exhaustion forecasting** *(high value)* — `depletionWarnings` logic already
   exists in the trend widget; promote it to a first-class "at this rate you'll run out in ~3 h
   (before reset)" line in the app and menu.
4. **Reset countdowns in the menu bar** — show the nearest reset ("Claude 5-h resets in 42m").
5. **More providers** — Google Gemini CLI (`~/.gemini/oauth_creds.json`), OpenRouter (credit balance
   API), Cursor, Mistral / Le Chat, xAI Grok, GitHub Models. Discovery + a client each.
6. **Export** — CSV/JSON export of history for the data-minded.
7. **Per-account enable/snooze from the menu** — quick toggle without opening Settings.
8. **Optional Keychain storage for LLimit's own credentials** — today they're plaintext on disk
   (mode 600, documented). Offer opt-in Keychain storage for the security-conscious.
9. **Auto-update (Sparkle)** — a directly-distributed app has no update path today.
10. **Schema-version migration** — `QuotaSnapshot.version` exists but is never checked; wire up real
    migration so future format changes don't silently fail to decode.

---

## 6. Novel, cool, delightful, or quirky ideas

- **"Which model should I burn?" nudge.** A tiny menu line that recommends the provider/account with
  the most headroom right now ("Most free: Z.ai, 88% left") — turns quota tracking into a decision aid.
- **Reset confetti / mood emoji.** When a window resets, briefly animate the widget or flip the
  menu-bar glyph to a happy state; when you're near a limit, a subtle "sweating" mood. Charming, cheap,
  and it makes the abstract number *felt*.
- **Menu-bar "fuel gauge" mode.** A single horizontal gauge that reads like a car fuel meter for your
  most-constrained account, with the needle colour tracking high/medium/low.
- **Sparkline in the menu.** A 24-h mini sparkline of your worst account right in the dropdown, using
  the history you already store.
- **Focus/Do-Not-Disturb integration.** Suppress "near limit" alerts while a Focus mode is on, or
  surface a gentle "you've used 90% during this Focus session" summary when it ends.
- **Shortcuts / AppIntents actions.** "Get remaining quota for Claude" as a Shortcuts action, so users
  can build their own automations (Stream Deck, raycast, etc.).
- **Tiny CLI companion (`llimit`).** Read the same App Group snapshot and print a status line — perfect
  for tmux/starship prompts. (Careful: the App Group is the widget channel; a CLI would need its own
  read path or the local snapshot file.)
- **"Quota budget" pacing.** Let the user say "make my weekly Claude limit last until Friday" and show a
  pace line (ahead/behind budget), like a fitness ring for tokens.
- **Weather-style forecast.** "Sunny: you'll comfortably finish the day" vs "Storm: you'll hit the
  5-hour wall around 15:00." A friendly gloss on the burn-rate math.

---

## 7. Suggested implementation order (and branch plan)

Grouped to minimize merge conflicts (each group touches mostly disjoint files). Highest impact first.

| # | Branch | Scope | Confidence |
| - | ------ | ----- | ---------- |
| 1 | `fix/copilot-fractional-decode` | P7: `Double` decode + optional fields in `CopilotClient` structs (+ decode test) | high |
| 2 | `fix/snapshot-merge-stale` | P11: merge last-good usage on failure (`RefreshService`/`AppModel`) | high |
| 3 | `fix/widget-reload-debounce` | W2/PERF2: debounce saves, reload widgets only on real data change | high |
| 4 | `fix/async-credential-scan` | PERF1: move discovery/Keychain scan off the main actor | high |
| 5 | `fix/claude-token-refresh` | P1/P2: re-read live Claude credential (file+Keychain, prefer freshest) at fetch/401 | high (safe variant) |
| 6 | `fix/openai-codex-lifecycle` | P4/P5/P6: re-read Codex file, refresh-on-401, skip disabled, re-import UX | high |
| 7 | `fix/widget-history-window` | W3/PERF3: windowed/compact history read for the widget | high |
| 8 | `fix/zhipu-endpoint-host` | P9: correct Zhipu host (⚠︎ verify first) | medium |
| 9 | `chore/copilot-robustness` | P8: trim creds, status-code messaging, drop dead session-token path | medium |
| 10 | `feat/threshold-notifications` | Feature 1: UserNotifications near-limit/reset alerts | high value |
| 11 | `feat/in-app-history-chart` | Feature 2: Swift Charts history view in the app | high value |
| 12 | `chore/dead-widget-code` | W5/UX6: delete unused ring code or relabel; consolidate hex parsing | high |

Items requiring live external verification before merge are marked ⚠︎ in the findings above; those
branches should confirm the API fact first and note it in the PR.

---

*Reviewed with care. The credential-lifecycle fixes (P1, P4, P7) plus the widget refresh/signing
fixes (W1–W3) are the difference between "only Z.ai works" and a tool you'd happily recommend.
Nice work, 4.8 — let's make it shine. — Fable 5* ✨
