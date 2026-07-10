# LLimit Review

Reviewed against `main` at `57c8416` on 2026-07-10.

## Scope and method

This review covers the complete repository: the Foundation-only `QuotaCore` package,
provider clients and credential discovery, the macOS menu-bar app, WidgetKit extension,
shared App Group plumbing, persistence, tests, build scripts, CI, release workflow, and
documentation. It also evaluates the requested provider-specific concentric-ring widget
against the supplied reference image.

The review used parallel static audits followed by direct source inspection. The working
tree was clean. The current Linux environment does not have Swift or Xcode installed, so
`swift test` could not be run locally (`swift: command not found`) and macOS layouts could
not be previewed. Existing GitHub CI is green through PR #6. Provider endpoints are mostly
undocumented, so findings that depend on current external API behavior are explicitly
marked as requiring live verification.

This document is the full review record. `ANALYSIS.md` should become the maintained,
unresolved roadmap after accepted fixes are implemented; completed findings should remain
here for provenance but not in the active roadmap.

## Executive summary

LLimit has good foundations: a pure-Foundation core, value-oriented models, parallel
per-account refreshes, atomic JSON replacement, redacted widget settings, a sandboxed
extension, and focused tests for several regressions. It is already substantially better
than a typical first version of a menu-bar quota utility.

The product is not distribution-ready yet. The most important issues are:

1. GitHub release artifacts are ad-hoc signed without the App Group entitlements, so the
   downloadable build cannot support the product's headline widget feature.
2. One malformed persisted account silently turns the complete account list into `[]`.
   A later save can permanently overwrite every valid account and credential.
3. Removing or disabling accounts does not reconcile snapshots, so deleted accounts can
   remain visible in the app and widgets indefinitely.
4. Failed accounts are carried forward correctly for resilience, but are labeled and
   graphed as freshly fetched. Repeated failures manufacture false trend observations.
5. Arbitrary provider response bodies can become persisted widget-visible failure text.
   This crosses the intended redaction boundary and can expose account data or inflate files.
6. Claude/OpenAI OAuth ownership does not match the documented self-contained model.
   Imported rotating or short-lived tokens remain coupled to source tools, and the Claude
   refresh workaround can overwrite multiple Claude accounts with one local login.
7. Dashboard widgets decode full trend history they never display. History appends also
   rewrite complete archives on the app's main actor.
8. The existing widget has several disconnected controls and dormant ring code, but no
   configurable account widget. The requested design is a strong fit for a new AppIntent
   provider tile rather than six duplicated widget implementations.

## Existing strengths

- `QuotaCore` is pure Foundation and structured to run on Linux.
- Models are predominantly value types with explicit `Sendable` conformance.
- Refreshes use structured concurrency and isolate one account's failure from others.
- Coordinator output is deterministically ordered.
- Current snapshots and settings use atomic file replacement.
- Widget settings are written through `AppSettings.redactedCredentials()`.
- The host is intentionally unsandboxed for optional import; the widget remains sandboxed.
- Absolute reset dates are already present in provider metrics.
- Stale merging preserves the original `ProviderUsage.fetchedAt`, which enables a correct
  freshness UI without changing all provider clients.
- Visibility limits and color strings receive some normalization during decoding.
- Existing tests cover persistence round trips, stale merge behavior, history windows,
  utility parsing, Anthropic decoding, Copilot fractional values, and OAuth basics.
- Widget reload requests are now debounced, avoiding one previously severe WidgetKit
  throttling problem.

## Work already completed or in flight

Do not reimplement these as new work:

| Item | State |
| --- | --- |
| Copilot fractional quota decoding | Merged in PR #1 |
| Carry last-known usage after a failed refresh | Merged in PR #3 |
| Widget reload debounce | Merged in PR #4 |
| Initial Claude live-token reread | Merged in PR #5, but incomplete; see `AUTH-2` |
| OpenAI/Codex live-token synchronization and reactive 401 recovery | Open PR #6 with green CI; review and merge rather than duplicate |
| Widget history return-window cap | Merged in PR #2, but decoding is still unbounded; see `PERF-1` |

## Severity and confidence

- **Critical:** can cause credential/data loss, defeats a primary product feature, or
  materially compromises credential handling.
- **High:** incorrect behavior or serious friction likely to affect normal users.
- **Medium:** bounded correctness, performance, UX, or maintainability issue.
- **Low:** polish, hygiene, or uncommon edge case.
- **Confirmed:** follows directly from current source behavior.
- **High confidence:** strongly supported but may require macOS/runtime confirmation.
- **Verify externally:** depends on an unstable provider or Apple distribution contract.

## Critical findings

### `REL-1`: Published releases do not have working widgets

**Severity:** Critical. **Confidence:** Confirmed.

`.github/workflows/release.yml:37-55` disables code signing and then runs ad-hoc
`codesign --deep --sign -` without entitlements. Both targets require the same App Group
(`LLimitApp/LLimitApp.entitlements:14-17` and
`LLimitWidgetExtension/LLimitWidgetExtension.entitlements:5-10`). `SharedPaths` returns an
error when the group container is unavailable (`Shared/SharedConstants.swift:90-101`).
The local build script explicitly admits that ad-hoc builds cannot support widgets, while
the release notes warn only about Gatekeeper.

**Impact:** A user can download the official artifact, install the widget, and receive no
shared settings or quota snapshot. The release does not deliver its defining feature.

**Recommendation:** Require Developer ID signing, matching App Group provisioning,
hardened runtime, and notarization for both app and embedded extension. Verify final
entitlements with `codesign -d --entitlements :-`, verify nested signatures with
`codesign --verify --deep --strict`, and test App Group access on a clean Mac. Until this
pipeline exists, do not present ad-hoc assets as widget-capable releases and state the
limitation prominently.

### `DATA-1`: One malformed account can silently erase every account

**Severity:** Critical. **Confidence:** Confirmed.

`AppSettings.init(from:)` wraps decoding the entire `[ProviderAccount]` value in `try?`
(`Models.swift:1117-1124`). A single unknown provider, missing field, wrong value type, or
future schema value therefore changes the whole account list to `[]` while
`SettingsStore.load()` reports success. `AppModel` sees no load error. Any later appearance
or account edit atomically replaces the credential-bearing file with the empty list.

**Impact:** A damaged entry or downgrade from a future schema can appear as total account
loss and can become permanent on the next save.

**Recommendation:** If the `accounts` key exists but is malformed, fail the settings load
and preserve the source file. Block automatic saves after a failed load until recovery is
explicit. Add a last-known-good backup and versioned migration envelope. If lossy
per-account recovery is later desired, quarantine skipped raw records and tell the user;
never silently discard them.

### `DATA-2`: Deleted and disabled accounts remain visible indefinitely

**Severity:** Critical. **Confidence:** Confirmed.

Removal and enable toggles only save settings (`AppModel.swift:229-234`, `505-513`). They
do not filter the in-memory snapshot, rewrite local/App Group snapshots, or purge history.
When no complete enabled account remains, `refreshNow()` returns early without writing an
empty snapshot (`AppModel.swift:153-160`). Widgets render every account in the stale
snapshot without joining against current settings (`LLimitQuotaWidget.swift:240-251`,
`320-331`).

**Impact:** A removed, disabled, or credential-cleared account can remain in the menu bar
and widgets across relaunches. Old account names, email subtitles, and history also remain.

**Recommendation:** Add one central snapshot reconciliation operation for all account
mutations. Filter usage and failures to enabled account IDs, project current display names,
persist the filtered or empty snapshot locally and to the App Group, and reload affected
widgets. Explicit deletion should purge the account's history or offer a clearly worded
retain-history option.

### `DATA-3`: Stale carried usage is reported and graphed as fresh

**Severity:** Critical. **Confidence:** Confirmed.

`QuotaSnapshot.mergingStaleUsage` correctly keeps failed accounts' prior usage and original
`fetchedAt`. The resulting snapshot nevertheless gets a new `generatedAt`, is appended to
history, and is counted as refreshed (`AppModel.swift:163-183`). App and widget headers show
the aggregate snapshot time. Account settings check for usage before checking the current
failure (`SettingsView.swift:941-950`). Trend points are timestamped with
`snapshot.generatedAt`, not `usage.fetchedAt` (`LLimitQuotaWidget.swift:703-724`).

**Impact:** Weeks-old quota can say "Updated just now." Every failed poll creates another
fake flat history sample. Burn-rate forecasts and reset interpretations become unreliable.

**Recommendation:** Model or derive freshness per account. Show last successful fetch age
and a stale badge, count only fresh successes in summaries, and expire carried data after a
documented TTL. Build history from fresh observations using `usage.fetchedAt`, deduplicate
`(accountID, metricID, fetchedAt)`, and do not append carried values as new samples.

### `SEC-1`: Raw failure text crosses the widget redaction boundary

**Severity:** Critical. **Confidence:** Confirmed persistence path; provider secret echo is
conditional.

`QuotaCoordinator` copies `ProviderClientError.message` or arbitrary
`localizedDescription` into `ProviderFailure` (`QuotaCoordinator.swift:51-73`). OpenAI,
Zhipu, Google, and Copilot can construct those messages from complete server bodies. The
message is then written verbatim to snapshot and history files, including the App Group.
There is no snapshot redaction step, message length cap, or control-character filtering.

**Impact:** Provider diagnostics, account identifiers, reflected input, HTML, or token-like
values can persist in widget-readable files and visible UI. Repeated large error bodies can
also bloat history and WidgetKit memory.

**Recommendation:** Persist structured failures only: kind, safe status code, retry time,
and a short allowlisted user message. Keep raw response diagnostics transient and outside
the widget data model. At the coordinator boundary, redact configured credential values,
strip control characters, and cap message length. A dedicated widget snapshot DTO should
exclude detailed errors and unnecessary PII such as email subtitles.

### `AUTH-1`: Imported rotating OAuth tokens are not independent owned credentials

**Severity:** Critical. **Confidence:** High; verify exact provider rotation behavior before
shipping a replacement flow.

Credential discovery copies OpenAI/Codex and OpenCode refresh tokens. LLimit can exchange
and persist a rotated token without updating the source tool. Whichever client refreshes
first can invalidate the other's copy. Similar documentation claims that imported Claude
credentials are independently owned, but only a short-lived access token is stored.

**Impact:** LLimit can break a source tool's login or lose its own login after the source
tool rotates. A crash between server rotation and durable save can strand the account.

**Recommendation:** The robust product solution is LLimit's own OAuth authorization flow
with its own grant. Otherwise, model the account as explicitly linked to a local source and
make that source authoritative. Do not describe copied rotating credentials as independent.
Open PR #6 is a pragmatic linked-source mitigation for OpenAI and should be reviewed rather
than duplicated.

## High-priority correctness and security findings

### `AUTH-2`: Claude live-token adoption breaks multiple-account semantics

**Severity:** High. **Confidence:** Confirmed.

`refreshLiveClaudeTokens()` obtains one local token and writes it into every enabled Claude
account whose current value is empty or starts with `sk-ant-oat` (`AppModel.swift:440-457`).
Provenance is inferred from a token prefix, so two Claude subscriptions can silently become
the same account. `currentLocalClaudeToken()` also returns the first file-discovered token
before consulting the usually fresher macOS Keychain (`AppModel.swift:464-479`).

**Recommendation:** Persist source provenance and source account identity. Refresh only the
account linked to that exact source. Compare expiry metadata and prefer the genuinely newest
credential. A hand-imported OAuth token must never be overwritten merely because its prefix
resembles Claude Code.

### `SEC-2`: Credential file mode `0600` is best-effort

**Severity:** High. **Confidence:** Confirmed.

`SettingsStore.save()` writes credentials and then ignores any chmod failure with `try?`
(`SettingsStore.swift:24-33`). The parent directory is not explicitly restricted.

**Recommendation:** Create the local settings directory as `0700`, ensure replacement files
are `0600`, verify owner/type/mode after replacement, and propagate a failure rather than
claiming a successful save. Add POSIX-mode tests for first save and overwrite. App Group
snapshot/history files should also use the narrowest practical permissions.

### `CORE-1`: Non-finite and out-of-range provider values can crash the app

**Severity:** High. **Confidence:** Confirmed.

`parseNumeric` accepts any `NSNumber` and strings such as `NaN` or `inf`
(`Utilities.swift:30-55`). `percentRemaining`, `formatIntLike`, and several provider clients
perform trapping `Double` to `Int` conversions. JSON booleans can also bridge as numeric
`NSNumber` values.

**Impact:** An undocumented API returning malformed or extreme values can terminate the
menu-bar app rather than producing a provider failure.

**Recommendation:** Reject non-finite values and `CFBoolean`, check bounds before integer
conversion, and enforce plausible ranges for percentages, quantities, dates, years, and
months. Add tests for NaN, infinity, exponent overflow, booleans, negative totals, and values
beyond `Int.max`.

### `CORE-2`: Unbounded persisted refresh intervals can overflow or explode timelines

**Severity:** High. **Confidence:** Confirmed.

`AppSettings` never normalizes `refreshIntervalMinutes` (`Models.swift:1054-1067`,
`1117-1121`). `AppModel` and the widget clamp only the minimum. `Int.max * 60` can trap;
a merely huge interval makes `QuotaTimelineProvider` construct five-minute entries until
that boundary.

**Recommendation:** Normalize the model to a documented range, for example 15 to 180
minutes, during initialization, decoding, and encoding. Use overflow-safe duration
construction and independently cap WidgetKit entry counts.

### `CORE-3`: Cancellation becomes a persisted provider failure

**Severity:** High. **Confidence:** Confirmed.

`URLSessionHTTPClient` converts every error into `.network`; the coordinator converts all
remaining errors, including cancellation, into `.unknown`. Canceling an automatic refresh
task can therefore produce, merge, save, and announce a failure snapshot.

**Recommendation:** Preserve `CancellationError` and `URLError.cancelled`, make refresh
cancellation observable to callers, and check cancellation immediately before persistence.
Add a suspending mock client test asserting that canceled work writes no snapshot/history.

### `CORE-4`: Account edits can race with an in-flight refresh

**Severity:** High. **Confidence:** Confirmed.

Refresh captures configurations, suspends for network calls, and persists inside
`RefreshService` before `AppModel` can validate current settings. Removing, disabling, or
editing an account during the request can resurrect obsolete data afterward.

**Recommendation:** Return an unsaved refresh result, track a configuration revision,
cancel active work on account mutation, and filter/revalidate enabled account IDs immediately
before all persistence.

### `PROV-1`: Current Copilot billing support appears obsolete

**Severity:** High. **Confidence:** Verify externally against current GitHub plans and APIs.

The public path uses legacy `premium_request/usage`, hardcoded allowances, and no Copilot Max
tier (`CopilotClient.swift:16-22`, `67-105`). Current GitHub billing has reportedly moved
most individual plans to AI credits, while premium requests remain for limited legacy plans.
Business/Enterprise organization billing is not handled.

**Recommendation:** Confirm current official endpoints and fixtures. Support AI-credit and
positively identified legacy billing separately, add current plans, and support organization
scope where possible. Never infer a denominator from a synthetic response field.

### `PROV-2`: Schema drift is often treated as valid zero/full quota

**Severity:** High. **Confidence:** Confirmed local behavior.

Anthropic can return a successful empty metric, Zhipu defaults missing percentage to zero
usage, and Google defaults missing `remainingFraction` to zero remaining. Some clients accept
responses with no recognized metrics as success.

**Impact:** A changed provider payload can replace last-known-good data with a confident but
wrong 100%, 0%, or "No quota data" state instead of activating stale fallback.

**Recommendation:** Represent missing values as unknown. Require a recognized schema and
valid bounded fields before success. Return `.decoding` when no supported metric exists,
unless the provider explicitly declares an unlimited/no-limit state.

### `PROV-3`: Long-term token lifecycle is incomplete

**Severity:** High. **Confidence:** Confirmed.

Claude exposes only an access-token field; discovery drops available refresh and expiry
metadata. OpenAI has an internal refresh-token key but does not expose it in manual account
fields. Imported credentials can therefore expire without an honest reauthorization state.

**Recommendation:** Define each provider credential as one of: first-party OAuth, static,
or linked-source. Show expiry/renewal status and reauthorization actions. Do not silently
turn source-tool rereads into an undocumented runtime dependency.

## Persistence, concurrency, and data quality

### `STORE-1`: History load and append are whole-file operations

**Severity:** High performance risk. **Confidence:** Confirmed.

`loadRecent()` first loads and decodes the entire archive, then filters it
(`QuotaHistoryStore.swift:19-40`). `append()` loads, appends, filters, sorts, and rewrites the
entire archive; `save()` sorts again. AppModel does this for local and App Group histories.

**Recommendation:** Move to SQLite, append-only records, or day-partitioned files. Enforce
entry and byte limits. Maintain a compact widget-specific recent-history file and flatten or
downsample series before WidgetKit reads it.

### `STORE-2`: `@unchecked Sendable` stores are not synchronized

**Severity:** Medium-High. **Confidence:** Confirmed.

All stores retain shared encoders/decoders and promise `Sendable` without synchronization.
Concurrent history appends can both read the same old array, then last-writer-wins one entry.

**Recommendation:** Serialize in-process access with actors or locks, create codecs per
operation, and use file coordination/locking for cross-process read-modify-write. Remove
unchecked conformance if cross-task use is not supported.

### `STORE-3`: Corrupt history permanently blocks new history

**Severity:** Medium. **Confidence:** Confirmed.

One malformed or truncated history file makes every later append fail because append cannot
decode the previous array. The UI continues without an actionable recovery path.

**Recommendation:** Quarantine corrupt archives, seed a new archive from current data, keep
a backup, and surface a recoverable diagnostic. A per-record format should allow one bad
record to be skipped without invalidating all history.

### `STORE-4`: Frozen `resetIn` strings override authoritative dates

**Severity:** Medium. **Confidence:** Confirmed.

Providers often persist both `resetAt` and a fetch-time `resetIn`. Menu and latent widget
helpers prefer the string, so "20m" can still display after 25 minutes or after the reset.

**Recommendation:** Treat `resetAt` as authoritative and derive display text at render time
using the timeline entry date. Use textual reset values only when no date is available.

### `STORE-5`: Snapshot and history files are broader than necessary

**Severity:** Medium. **Confidence:** Confirmed mode, conditional exposure.

Snapshot/history saves attempt `0644`, despite containing account names, email subtitles,
quota data, and currently arbitrary diagnostics. Parent-directory ACLs reduce typical macOS
exposure, but the mode is unnecessarily broad.

**Recommendation:** Use `0600` for local data. For App Group files, rely on group container
access while still applying the narrowest functional mode. Minimize the widget DTO.

## Provider and network findings

### `HTTP-1`: Resource isolation and response limits are missing

**Severity:** Medium-High. **Confidence:** Confirmed.

The default client uses `URLSession.shared`, buffers unlimited response data, has only a
per-request timeout, shares cookie/cache behavior, and loses structured `URLError` details.

**Recommendation:** Use a dedicated ephemeral session with cookies/cache disabled, request
and resource timeouts, constrained connections, response-size limits, preserved error codes,
and cancellation propagation.

### `HTTP-2`: Rate-limit handling is inconsistent and has no cooldown

**Severity:** Medium-High. **Confidence:** Confirmed local behavior.

Only some paths classify 429. No client honors `Retry-After`; GitHub secondary-rate-limit
403 responses can look like auth failures; all accounts fan out without per-host limits.
Manual refresh has no cooldown.

**Recommendation:** Centralize safe status classification for 408/425/429/5xx, preserve
retry metadata, add per-provider concurrency limits and jittered cooldowns, deduplicate
identical credentials, and throttle manual refresh. Do not blindly retry rotating OAuth
exchanges after ambiguous timeouts.

### `PROV-4`: OpenAI usage fields are incomplete

**Severity:** Medium. **Confidence:** Verify externally.

The client supports one primary rate limit and two windows, but current upstream schemas
reportedly include credits, spend control, additional limits, reached type, `allowed`, and
absolute reset timestamps.

**Recommendation:** Track optional forward-compatible fields and render dynamic additional
limits, credit balance/unlimited state, and precise exhaustion reasons.

### `PROV-5`: Copilot fallback misclassifies outages as auth errors

**Severity:** Medium. **Confidence:** Confirmed.

Private fallback paths return `nil` for broad non-2xx responses and malformed token data,
then eventually report authentication failure after multiple requests.

**Recommendation:** Fall through only on expected compatibility statuses. Preserve 5xx as
API errors, malformed 2xx as decoding errors, and one overall sequence deadline.

### `PROV-6`: Google refreshes an access token for every quota request

**Severity:** Medium. **Confidence:** Confirmed.

`expires_in` is ignored and the access token is discarded after one fetch.

**Recommendation:** Cache access tokens in an actor keyed by credential identity until a
safe pre-expiry margin. Keep them in memory only.

### `PROV-7`: Copilot monthly reset uses local time instead of UTC

**Severity:** Medium. **Confidence:** High; verify GitHub boundary semantics.

`monthEndDate` and `startOfNextMonth` inherit the current calendar timezone. If GitHub resets
at UTC midnight, displayed reset time shifts by the local offset and DST.

**Recommendation:** Set the provider calendar to UTC and test exact epochs under multiple
timezones.

### `PROV-8`: Invalid JSON is inconsistently classified

**Severity:** Low-Medium. **Confidence:** Confirmed.

Wrong top-level JSON becomes `.decoding`, while parser errors escape as arbitrary errors and
become `.unknown`. Safe HTTP status metadata is dropped from `ProviderFailure`.

**Recommendation:** Normalize parser errors to `.decoding` and preserve a sanitized status,
provider code, and retry time in the failure model.

### `PROV-9`: Provider endpoint watchlist

**Severity:** Variable. **Confidence:** Verify externally before changing behavior.

- Anthropic uses a hardcoded old Claude Code User-Agent and private usage endpoint.
- Google uses a private endpoint, fixed model IDs, a Windows User-Agent, and an embedded
  installed-app OAuth client credential.
- ChatGPT token refresh sends an extra scope compared with current Codex behavior.
- Zhipu/Z.ai percentage semantics and candidate field names are guessed.
- Copilot private endpoints emulate editor headers and may disappear at any time.
- The Zhipu host may need `open.bigmodel.cn`, but this must be proven with live fixtures.

**Recommendation:** Capture sanitized real fixtures, add contract tests, monitor schema
changes, and avoid speculative endpoint edits without live verification.

## Credential discovery findings

### `DISC-1`: Discovery silently drops valid multiple accounts

**Severity:** Medium-High. **Confidence:** Confirmed.

OpenCode candidates can share fixed stable IDs, only one Google account is selected, and
deduplication drops repeated IDs before comparing credential identities. Fingerprints omit
field names.

**Recommendation:** Emit every usable account. Base stable identity on provider plus a
non-secret account identifier/source path, or use a keyed cryptographic fingerprint of
sorted `key=value` pairs.

### `DISC-2`: Current storage locations and metadata are incomplete

**Severity:** Medium. **Confidence:** Confirmed local behavior; external paths may evolve.

Discovery ignores explicit OpenCode `accountId`, custom XDG paths, `CODEX_HOME`, keyring
storage, and Claude expiry metadata.

**Recommendation:** Use injectable path resolvers, honor documented environment variables,
prefer explicit account IDs over JWT inference, and distinguish expired discoveries from
usable credentials.

### `DISC-3`: Scanning is synchronous, broad, and surprising

**Severity:** High UX/performance risk. **Confidence:** Confirmed.

Opening Settings can automatically perform file I/O and enumerate every generic-password
Keychain item on the main actor (`SettingsView.swift:45-48`, `AppModel.swift:241-264`,
`322-371`). It then reads any service containing "claude" and accepts a lenient raw token.
This can stall the UI or trigger unexpected permission prompts.

**Recommendation:** Scan only after explicit user action, perform file discovery off the
main actor, start from exact supported Keychain services, show progress, and ask before
reading broader candidates.

### `DISC-4`: The documented Keychain workaround writes a plaintext token unsafely

**Severity:** High. **Confidence:** Confirmed.

README and diagnostics suggest redirecting a Keychain secret with `>` to
`~/.claude/.credentials.json`, which may be created with `0644` under a common umask and
then shadows fresher Keychain data.

**Recommendation:** Remove this command. Prefer Keychain authorization. If an export is
ever documented, require `umask 077` and explicit `chmod 600`.

## Refresh and application behavior

### `APP-1`: Failure-only snapshots are hidden in the menu

**Severity:** High. **Confidence:** Confirmed.

Menu details render only when `snapshot.providers` is non-empty. A first refresh where every
account fails falls into "No quota data yet" and hides the actual failures.

**Recommendation:** Distinguish no configuration, awaiting first refresh, failure-only,
partial, stale, and loaded states. Show account-aware recovery actions.

### `APP-2`: Refresh scheduling can nearly double configured staleness

**Severity:** High. **Confidence:** Confirmed.

Bootstrap checks freshness once, but the refresh loop always sleeps a full interval. A
29-minute-old snapshot with a 30-minute interval can wait another 30 minutes. Manual refresh
does not reset the timer and can be followed by an immediate automatic request.

**Recommendation:** Use one scheduler based on `lastAttemptAt`, `lastSuccessAt`, and current
snapshot age. Coalesce concurrent requests, reset due time after every attempt, observe wake
and network recovery, and enforce a manual cooldown.

### `APP-3`: Save errors can be overwritten by success messages

**Severity:** High. **Confidence:** Confirmed.

Persistence communicates only through one mutable `statusMessage`. Autofill and refresh
completion overwrite failures. This is especially dangerous after OAuth rotation.

**Recommendation:** Make saves return `Result`, require durable save before reporting
success, and use structured notices with severity, context, timestamp, and recovery action.

### `APP-4`: Main-actor disk work occurs on every text edit

**Severity:** High performance risk. **Confidence:** Confirmed.

Name and credential bindings synchronously encode and atomically write local and App Group
settings on every character. Widget reload is debounced; writes are not. History append and
full App Group rewrite also originate from the main actor.

**Recommendation:** Serialize persistence through a storage actor, debounce text/color
edits, flush on focus loss/window close/termination, and avoid App Group writes when only
redacted credential values changed.

### `APP-5`: Autofill is unsafe with multiple accounts

**Severity:** High. **Confidence:** Confirmed.

Autofill takes the first matching provider, replaces the whole credential dictionary, and
does not show a source/account chooser. Duplicate detection compares any credential value,
so matching non-secret metadata can hide a distinct login.

**Recommendation:** Present detected identities, mask secrets, compare provider-specific
credential identity, warn before overwrite, and merge only supplied fields.

### `APP-6`: Incomplete accounts disappear from refresh reporting

**Severity:** Medium. **Confidence:** Confirmed.

Incomplete accounts are filtered before the coordinator and produce no failure when another
account can refresh. Validation trims whitespace, but raw untrimmed credentials are retained
and sent.

**Recommendation:** Trim credentials on commit/import and report skipped/incomplete accounts
separately from network failures.

### `APP-7`: Account status semantics are misleading

**Severity:** Medium. **Confidence:** Confirmed.

"Ready" means only that required fields are non-empty. Disabled or failed accounts can still
show positive states, and stale carried data wins over current failures in the detail view.

**Recommendation:** Model explicit incomplete, unverified, verified, disabled, refreshing,
stale, and failed states. Use "Complete" until a connection succeeds.

### `APP-8`: Per-account Refresh Now refreshes all accounts

**Severity:** Medium. **Confidence:** Confirmed.

The button appears inside one account's Actions section but calls global `refreshNow()`.

**Recommendation:** Implement targeted refresh or label it "Refresh All Accounts."

### `APP-9`: Menu failures lose account identity and do not scale

**Severity:** Medium. **Confidence:** Confirmed.

Failures display only provider names. Every metric becomes a menu row, and the menu-bar icon
width grows linearly with account count.

**Recommendation:** Use account titles, stale age, and concise error kind. Consider a
`.window` menu-bar popover with scrolling. Offer fixed-width icon modes: worst account,
aggregate gauge, top-N, monochrome, or percentage text.

### `APP-10`: Onboarding sends users to an action that cannot work

**Severity:** Medium. **Confidence:** Confirmed.

With no accounts the menu says to use Refresh Now, but refresh can only update a status
message that is not visible there. The Settings empty state has no direct primary button.

**Recommendation:** Make "Add Your First Account" primary, open a guided first-run flow, and
include test-connection and explicit opt-in import steps.

### `APP-11`: Duplicate display names are easy to generate

**Severity:** Low-Medium. **Confidence:** Confirmed.

Default naming uses the current count. Deleting one of two accounts and adding another can
create a second "OpenAI 2."

**Recommendation:** Choose the first unused numeric suffix case-insensitively.

### `APP-12`: Window restoration and redundant mutation need cleanup

**Severity:** Low-Medium. **Confidence:** Confirmed.

The settings window registers autosave then always centers, does not explicitly
deminiaturize, and `WindowAccessor` asynchronously reapplies sizing on every SwiftUI update
despite the AppKit controller already configuring the window.

**Recommendation:** Center only without a saved frame, deminiaturize before showing, remove
the accessor, and title the window "LLimit Settings."

## Widget correctness and performance

### `PERF-1`: Every dashboard widget decodes full trend history

**Severity:** High. **Confidence:** Confirmed.

Dashboard and trend widgets use the same provider and entry type. Every timeline loads
history, and `loadRecent()` decodes the entire file before filtering. Dashboard views never
render `history`.

**Recommendation:** Split dashboard and trend providers/entries. Dashboard entries should
contain no history. The app should maintain a bounded, already-windowed trend DTO.

### `PERF-2`: Timeline entries duplicate large immutable payloads

**Severity:** Medium-High. **Confidence:** Confirmed.

The provider emits an entry every five minutes until the refresh boundary, each carrying
the complete settings, snapshot, and history. At 180 minutes this creates 37 nearly
identical entries.

**Recommendation:** Publish one lightweight current entry with `.after(nextRefreshDate)`.
Use absolute-date/timer text for countdown progression rather than cloning quota data.

### `WID-1`: Dashboard can hide the most constrained metric

**Severity:** High. **Confidence:** Confirmed.

Provider ordering considers every bounded metric, but bars and percentages use only the
first two candidate metrics. Claude, Copilot, and Google can expose three or four metrics.
A row may sort as critical because its third metric is low while displaying two healthy
values. Unknown aggregate data can also fall back to 100% via `maxUsagePercent == 0`.

**Recommendation:** Define stable provider-aware metric selection, allow explicit metric
configuration in provider tiles, and never infer healthy full quota from absent data.

### `WID-2`: Missing data and storage errors are conflated with no accounts

**Severity:** High. **Confidence:** Confirmed.

Load failures become `nil`/defaults, then widget views say "No accounts configured."
Failure-only snapshots are also hidden when no provider usage exists.

**Recommendation:** Carry explicit entry state: unconfigured, awaiting first refresh,
loaded, partial, stale, load failed, and App Group unavailable.

### `WID-3`: Widgets depend on the host app running but do not say so

**Severity:** High product issue. **Confidence:** Confirmed.

Widget timelines only reread files; all networking runs in the menu-bar app. If the app is
quit or not launched at login, the widget can display old data indefinitely without a stale
warning.

**Recommendation:** Explain this dependency, encourage Launch at Login, show data age, and
render stale state prominently.

### `WID-4`: Small and medium layouts can overflow

**Severity:** Medium-High. **Confidence:** High; requires macOS preview confirmation.

Small rows reserve fixed widths that exceed realistic content width once padding and widget
margins are included. Medium permits 12 rows, which cannot fit in standard system-medium
height. Long account names receive a fixed 58-point frame.

**Recommendation:** Derive row capacity from geometry, cap medium to a realistic count,
use `ViewThatFits` or family-specific layouts, and avoid fixed widths in system-small.

### `WID-5`: Trend visualization lacks enough context

**Severity:** Medium. **Confidence:** Confirmed.

There is no legend, axis label, current value, or account identity. Global styles can assign
the same color to multiple accounts. Lines connect across resets/missing periods,
uniform-index downsampling can remove extrema, endpoint marks can clip, and depletion risk
uses as few as two stale points.

**Recommendation:** Add selected-series configuration or a compact legend, stable colors,
reset/missing-data segmentation, extrema-preserving downsampling, plot padding, current
values, and forecasts based only on fresh samples.

### `WID-6`: Appearance settings do not match rendering

**Severity:** Medium. **Confidence:** Confirmed.

- `ConcentricQuotaChart` exists but is unused.
- "Circle graph colors" currently style bars/lines rather than circles.
- `showResetInfo` is stored but not exposed/used.
- Per-account background controls do not affect aggregate widget backgrounds.
- Selected background alpha is forced to at least 72%.
- The "Default" preset renders a fixed blue gradient rather than a system-adaptive surface.

**Recommendation:** Make each control correspond to visible output, remove dead controls,
or connect them through the new provider tile. Honor alpha or model background modes
explicitly. Derive text/chrome contrast from selected luminance and environment.

### `WID-7`: Widget accessibility is insufficient

**Severity:** High UX. **Confidence:** Confirmed.

Rows, rings, progress bars, and trends lack meaningful accessibility summaries. Color is the
only severity/series channel when values are hidden. Decorative effects do not respond to
increased contrast or reduced transparency.

**Recommendation:** Expose each tile/row as a concise semantic summary with provider,
metric names, remaining values, resets, freshness, and failure state. Hide decorative
elements. Preserve percentages for VoiceOver regardless of visual preferences, and adapt to
contrast/transparency settings.

### `WID-8`: Bootstrap does not repair missing App Group files

**Severity:** Medium. **Confidence:** Confirmed.

Bootstrap reads local state but does not proactively copy redacted settings/latest snapshot
to the App Group. A prior transient failure can leave widgets empty until another save or
refresh.

**Recommendation:** Reconcile App Group state during bootstrap and retry transient failures
with bounded backoff.

## Requested provider-specific widget

### Product direction

Add one configurable **Provider Quota Tile** widget, not six separate code implementations.
Each installed instance should select one LLimit account through `AppIntentConfiguration`.
Users can then add one tile per Claude/OpenAI/Copilot/Zhipu/Z.ai/Google account, including
multiple accounts of the same provider. Gallery recommendations can make them feel like
individual provider widgets without duplicating logic or widget kinds.

Recommended kind: `ch.lkmc.llimit.widget.account-quota`.

The existing dashboard and trend kinds should remain for installed-widget compatibility.

### Reference-image composition

The supplied image uses a square, rounded tile with vivid diagonal background stripes, a
soft translucent rounded inset panel, two thick concentric quota rings, a short centered
provider label, and two reset durations along the bottom. The visual hierarchy is excellent
for a small widget: identity in the center, quota shape at a glance, reset timing below.

Recommended `.systemSmall` implementation:

1. Let WidgetKit own the outer rounded shape via `containerBackground` and
   `ContainerRelativeShape`.
2. Draw diagonal provider-themed stripes in one `Canvas`, clipped to the container. Avoid a
   large `ForEach` of rotated rectangles.
3. Add a warm/cool translucent scrim behind rings and footer to stabilize contrast.
4. Fit the ring region from available geometry, reserving roughly 22 to 26 points for reset
   durations.
5. Use `strokeBorder` tracks and trimmed arcs starting at 12 o'clock with rounded caps.
6. Use an outer stroke around 9 to 11 points and an inner stroke around 7 to 9 points, with
   visible spacing between tracks.
7. Put the account/provider name in the center, limited to two lines with conservative
   scaling. Use the custom account name when it is short; otherwise prefer the provider.
8. Pair each footer duration with the corresponding ring using color dots and VoiceOver
   labels, for example `2h 05m  |  3d 06h`.
9. Recompute reset text from `resetAt`; never display frozen fetch-time strings.
10. Preserve a clear stale/failure treatment: rings may remain, but add a warning badge and
    "Updated ... ago" accessibility state.

### Configuration model

Define an `AccountEntity` containing only stable account ID, display name, and provider.
The entity query reads redacted App Group settings; credentials never enter the extension.
The intent should support:

- Account selection.
- Outer and inner metric selection, with an automatic provider-aware default.
- Optional provider palette versus account custom style.
- Optional display of percentages in the center.
- Optional striped/solid/system background mode.

Use one lightweight timeline entry containing only the selected account, at most two
normalized ring metrics, absolute reset dates, generated/fetched times, matching failure,
and resolved style. Do not carry complete settings, all accounts, or history.

### Stable metric defaults

Metric identity must remain stable between refreshes; do not reorder rings based on which is
currently lower.

| Provider | Outer ring | Inner ring |
| --- | --- | --- |
| Claude | `five_hour` | `seven_day` |
| OpenAI | `primary` | `secondary` |
| Zhipu/Z.ai | `tokens` | `mcp` |
| Copilot | `premium` | first stable bounded chat/completions metric |
| Google | preferred stable model pair, initially G3 Pro and G3 Flash if present |

Claude Opus and additional Copilot/Google metrics should be selectable. If only one valid
metric exists, render one centered ring rather than an empty inner track. Unknown values
should use an indeterminate/neutral track, never a healthy full ring.

### Provider palettes

Use accessible, recognizable palettes without depending on trademarks or remote assets:

- Claude: warm terracotta, sand, cream.
- OpenAI: graphite, mint, soft white.
- Copilot: indigo, violet, cyan.
- Zhipu: cobalt, sky, lavender.
- Z.ai: walnut, amber, pale gold, close to the supplied reference.
- Google: restrained blue/red/yellow/green stripes with a neutral dark scrim.

User presets and per-account overrides should remain authoritative. Add automatic contrast
checks; do not assume white text is readable on every custom background.

### Accessibility contract

Treat the full tile as one meaningful element, for example:

> Claude. Five-hour quota, 64 percent remaining, resets in 2 hours 5 minutes. Weekly
> quota, 48 percent remaining, resets in 3 days 6 hours. Updated 12 minutes ago.

Staleness and failure must always be announced. Hide stripes, tracks, and highlights from
accessibility. Differentiate outer/inner limits by labels and stroke width, not color alone.
Respect increased contrast and reduced transparency.

### Validation matrix

- Small and medium families.
- One, two, and more than two provider metrics.
- Long account names and multiple accounts for one provider.
- Unlimited, unknown, first-refresh, stale, failed, and removed states.
- Light/dark appearance, increased contrast, reduced transparency, and VoiceOver.
- Full history archive present, proving the provider tile does not load it.
- Correct App Group behavior in a signed/notarized clean install.

## General visual and layout review

### `UX-1`: Settings minimum width conflicts with fixed content widths

**Severity:** High visual issue. **Confidence:** High.

The window allows 720 points, while the sidebar, fixed 180-point labels, and two roughly
200-point ring color columns exceed available detail width. The vertical ScrollView offers
no horizontal recovery.

**Recommendation:** Use adaptive `Grid`/`Form` layouts, stack ring columns at narrow widths,
reduce fixed label widths, or raise the true minimum width.

### `UX-2`: Destructive removal has no confirmation or undo

**Severity:** High UX. **Confidence:** Confirmed.

"Remove Account" immediately deletes credentials and style. Combined with ghost snapshots,
the user can lose configuration while still seeing old data.

**Recommendation:** Confirm with the account name, explain history handling, and offer Undo
or a short deletion grace period.

### `UX-3`: Accessibility labels are missing in Settings

**Severity:** High UX. **Confidence:** Confirmed.

Many `Picker("")`, `Toggle("")`, `ColorPicker("")`, and empty-label steppers have no
accessible label. Status is frequently color-only, and buttons replace labels with
unlabeled spinners.

**Recommendation:** Use `LabeledContent`, meaningful native labels, accessibility values,
symbols/text in addition to color, and a persistent "Refreshing" label.

### `UX-4`: Overview hides most quota information

**Severity:** Medium. **Confidence:** Confirmed.

Only the first metric per account appears. Important weekly/model-specific limits are hidden,
account names are fixed to 110 points, and errors are truncated.

**Recommendation:** Use a compact account table with important metrics, progress bars,
freshness/error badges, flexible names, and disclosure for details.

### `UX-5`: Background opacity semantics are contradictory

**Severity:** Medium. **Confidence:** Confirmed.

Near-zero color alpha becomes `nil`, while `nil` means default system/fixed gradient rather
than transparent. The setter also disables transparent mode.

**Recommendation:** Model background explicitly as system, solid/color (including alpha),
pattern, or transparent. Do not overload `nil`.

### `UX-6`: Provider style toggling destroys customization

**Severity:** Medium. **Confidence:** Confirmed.

Every transition to enabled override replaces the stored account style with the current
global style.

**Recommendation:** Preserve dormant override values and provide an explicit "Reset to
Global" action.

### `UX-7`: Terminology and platform conventions need polishing

**Severity:** Low. **Confidence:** Confirmed.

Use "Settings..." instead of "Open Settings," "click" rather than "tap" on macOS,
"Unlimited" instead of `INF`, and add About, Help, version/build, and diagnostics actions.

### `UX-8`: Localization is absent

**Severity:** Low-Medium. **Confidence:** Confirmed.

All visible and accessibility strings are hardcoded English. Duration and number formatting
is also largely fixed-format.

**Recommendation:** Add a String Catalog and locale-aware number/duration formatting after
the state model stabilizes.

## Build, CI, release, and repository hygiene

### `BUILD-1`: YAML coercion changes Swift 5.10 to 5.1

**Severity:** High build hygiene. **Confidence:** Confirmed.

`project.yml` uses unquoted `SWIFT_VERSION: 5.10`; the generated project contains `5.1`.
The compiler version and language mode are also conceptually different.

**Recommendation:** Quote the intended supported language mode and regenerate deliberately.
Make `project.yml` the canonical source and check generation drift in CI.

### `BUILD-2`: Project generation and signing sources contradict each other

**Severity:** High. **Confidence:** Confirmed.

`project.yml` leaves the team blank, the committed project contains a maintainer team, the
build script calls the project authoritative and warns not to regenerate, while README tells
contributors to regenerate. Fixed bundle/group identifiers complicate forks.

**Recommendation:** Make XcodeGen canonical. Put team and identifier overrides in ignored
local `.xcconfig` files/environment, parameterize identifiers, and only choose development
signing when a matching identity exists.

### `BUILD-3`: Release documentation describes a pipeline that does not exist

**Severity:** High. **Confidence:** Confirmed.

`RELEASING.md` claims workflow dispatch, `scripts/build.sh`, and signing/notarization secrets;
the actual workflow has none of those and always publishes ad-hoc artifacts.

**Recommendation:** Implement one exact documented release path or remove the claims.
Production release should fail closed when signing/notarization inputs are missing.

### `CI-1`: Any `v*` tag can publish an untested credential-reading app

**Severity:** High security/release risk. **Confidence:** Confirmed.

Release accepts any `v*` tag, runs no tests, grants write permission to the full job, and CI
does not run for tags. A tag can point to an unreviewed commit.

**Recommendation:** Validate semantic version tags and require the commit to be on protected
`main` with a successful CI result. Split read-only build and protected publish jobs; disable
checkout credential persistence.

### `CI-2`: CI duplicates tests and does not verify Linux compatibility

**Severity:** Medium. **Confidence:** Confirmed.

QuotaCore tests run before selecting Xcode and then run again. There is no Ubuntu job despite
the stated Linux compatibility, no app test target, and no coverage reporting.

**Recommendation:** Select/pin the toolchain first, run one package test pass per intended
platform, add Ubuntu Swift CI, and add macOS app/widget tests and bundle smoke checks.

### `CI-3`: Dependencies and release tools are mutable

**Severity:** Medium. **Confidence:** Confirmed.

Actions use mutable major tags, Homebrew installs floating packages, and `lkm-release` is an
unpinned executable discovered from `PATH`.

**Recommendation:** Pin actions by commit SHA, automate updates, minimize permissions, and
vendor or version-check release logic.

### `TEST-1`: Unstable provider clients lack contract coverage

**Severity:** High engineering risk. **Confidence:** Confirmed.

There are no dedicated OpenAI, Zhipu/Z.ai, Google, or HTTP client test files. Existing
Anthropic mocks do not assert mandatory request details. App, widget, App Group, signing,
scheduling, and credential orchestration have no automated tests.

**Recommendation:** Add request-contract and fixture tests for every client: method, URL,
headers, auth, body, normal variants, empty payloads, malformed data, hostile numbers,
401/403/429/5xx, cancellation, and timeouts. Add macOS integration tests and final bundle
entitlement/signature assertions.

### `REPO-1`: Security and contribution hygiene are missing

**Severity:** Medium. **Confidence:** Confirmed.

There is no `SECURITY.md`, `CONTRIBUTING.md`, `CODEOWNERS`, changelog, action update config,
or lint/format policy. `.gitignore` does not cover result bundles and common signing files.

**Recommendation:** Start with a vulnerability policy that explains local credential
handling and the unsandboxed host. Ignore signing material/results, add automated action
updates, publish checksums/provenance, and maintain a changelog.

## Missing features with high product value

1. **Provider/account widget tiles:** the requested concentric ring design, configurable per
   account through AppIntent.
2. **Threshold and reset notifications:** per-metric low-quota, auth failure, and reset
   alerts with deduplication and quiet hours.
3. **In-app history:** charts, reset markers, account comparison, and retention controls.
4. **Burn-rate forecasting:** "At this pace, Claude runs out around 15:00, before reset."
5. **Guided first run:** opt-in detection, identity chooser, provider-specific guidance,
   test connection, and completion state.
6. **Targeted refresh and diagnostics:** latency, last success/failure, source provenance,
   safe copyable diagnostics, and reauthorize actions.
7. **Wake/network-aware refresh:** retry when connectivity returns and refresh after sleep
   without violating provider cooldowns.
8. **Widget and menu deep links:** tap a tile/failure to open the exact account.
9. **Account organization:** reorder, search, groups, duplicate, snooze, and visibility.
10. **History export:** CSV/JSON with explicit privacy controls.
11. **Optional Keychain storage:** an opt-in alternative to the mode-600 JSON credential
    file, while preserving portability and transparent backups.
12. **Update mechanism:** Sparkle or another signed direct-distribution update flow.
13. **Shortcuts/App Intents:** "Get remaining quota for Claude" and "Refresh LLimit."
14. **More providers:** only after auth/API maintenance costs are accepted; candidates
    include Gemini CLI, OpenRouter credits, Cursor, Mistral/Le Chat, xAI, and GitHub Models.

## Delightful and quirky opportunities

- **Best model to burn:** recommend the account with the most headroom right now.
- **Quota weather:** "Sunny: comfortably through the day" versus "Storm: five-hour wall
  around 15:00," backed by real forecast confidence.
- **Pacing rings:** let a user make weekly quota last until Friday and show ahead/behind
  pace like a fitness goal.
- **Reset celebration:** a restrained ring bloom or menu-bar bounce after a real reset,
  respecting Reduce Motion.
- **Mood gauge:** a subtle calm/concerned/sweating menu icon state, optional and accessible.
- **Menu sparkline:** 24-hour history for the most constrained account.
- **Reset radar:** one chronological list of upcoming resets across providers.
- **Quota roulette:** a playful "pick my provider" action weighted by remaining headroom.
- **Focus-session budget:** track quota consumed during a selected Focus interval and show a
  summary when it ends.
- **Tiny CLI/status-line companion:** read a dedicated redacted local snapshot for tmux,
  shell prompts, Raycast, or Stream Deck.
- **Honesty mode:** show confidence badges when a provider endpoint is private, stale, or
  inferred rather than presenting every value as equally authoritative.

## Recommended implementation sequence

The following are high-confidence and reasonably bounded. Each should use its own branch and
PR. AppModel-heavy changes should be kept small and rebased in order to limit conflicts.

| Order | Branch | Finding | Reason |
| --- | --- | --- | --- |
| 1 | `fix/settings-account-decode` | `DATA-1` | Prevents catastrophic silent credential loss; core-only with tests |
| 2 | `fix/numeric-input-hardening` | `CORE-1` | Prevents provider-controlled crashes; core/provider tests |
| 3 | `fix/refresh-interval-bounds` | `CORE-2` | Prevents overflow and timeline explosion; mostly core-only |
| 4 | `fix/account-snapshot-reconciliation` | `DATA-2` | Removes ghost accounts immediately; core helper plus AppModel |
| 5 | `fix/reset-countdown-freshness` | `STORE-4` | Correct visible countdowns; menu/widget focused |
| 6 | `perf/dashboard-timeline-payload` | `PERF-1`, `PERF-2` | Removes unnecessary widget memory/CPU work |
| 7 | `fix/provider-style-preservation` | `UX-6` | Small, isolated user-facing data-loss fix |
| 8 | `fix/unique-account-names` | `APP-11` | Small, isolated multi-account polish |
| 9 | `feat/provider-quota-widget` | Requested widget, `WID-6` | Highest requested product value; builds on existing rings |
| 10 | `docs/analysis-roadmap` | Documentation reconciliation | Preserve unresolved work after implementation |

Additional high-value changes such as stale-history semantics, failure DTO/redaction,
storage actors, OAuth ownership, release signing, async Keychain discovery, and provider API
updates require broader design decisions, live-provider fixtures, signing credentials, or
larger migrations. They belong in `ANALYSIS.md` until those prerequisites are available.

## Definition of done for the project

LLimit should not call itself release-ready until all of the following are true:

1. Official artifacts are Developer ID signed/notarized and retain verified App Group
   entitlements for app and widget.
2. Settings corruption cannot silently erase credentials, and credential permissions are
   enforced rather than attempted.
3. Removed/disabled accounts disappear immediately from every surface.
4. Fresh, stale, unknown, and failed data are distinct in app, history, and widgets.
5. Raw provider response bodies and credential-like values never enter widget stores.
6. OAuth account ownership/linkage is honest and cannot overwrite unrelated accounts.
7. Provider contracts have request/response/error fixtures and hostile-input tests.
8. Dashboard widgets do not load trend archives, and WidgetKit entry payloads are bounded.
9. Core accessibility flows work without color, and the requested provider tile passes
   VoiceOver/contrast/reduced-transparency checks.
10. CI tests QuotaCore on Linux, builds/tests macOS targets, and verifies final signatures,
    entitlements, embedded extension, versions, and release provenance.
