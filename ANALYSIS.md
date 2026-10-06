# LLimit — analysis and shovel-ready ideas

This document is the durable output of two independent full reviews of `main`
at `2d6ac1e` ("Add twelve widget slots and a resizable dropdown"), consolidated
here. Between them the reviews read every surface: the macOS app
(`LLimitApp/`), the widget extension (`LLimitWidgetExtension/`), the shared
brain (`Packages/QuotaCore`), the Linux port (`Packages/LLimitd`: CLI, daemon,
Python tray), the build/CI scripts, and the existing `BACKLOG.md`.

It is deliberately a list of **work an agent can pick up and finish**, not a
narrative. Every item names the files to touch and how to know it is done.

It complements `BACKLOG.md`, which remains the exhaustive historical list.
Where an item here overlaps a backlog entry, the backlog entry is the older and
broader statement; the item here is the sharper cut. Section 12 lists backlog
entries that are already **done** or **stale** so they are not re-litigated.

## How the review was validated

- Swift toolchain is not available in the review environment, so Swift changes
  are verified by CI: `.github/workflows/ci.yml` runs the macOS `xcodebuild`
  build plus `swift test` for `QuotaCore`, and a Linux SwiftPM job that runs
  `swift test` for **both** `QuotaCore` and `LLimitd`, plus the Python tray
  tests (`python3 -m unittest discover -s Packages/LLimitd/tray/tests`).
- Tray tests were run locally during the review (23 → 27 passing after the
  countdown change).
- `scripts/test-panel-geometry.sh` and `scripts/test-limit-colors.sh` exercise
  pure logic outside the app build.

## Shipped or in-review from the review passes

Delete each entry (and the matching ✅-marked item below) as the PR merges.

Review pass A (PRs #50–#56, open for review):

- **#50 `linux-live-resets`** — `llimit status`, its tooltip, and the tray
  printed the fetch-time `resetIn` string verbatim, so a countdown frozen at
  the last refresh was repeated until the next one. Now rendered with
  `UsageMetric.resetCountdown(at:)`, and the metric JSON carries `resetAt`
  (ISO 8601) plus a recomputed `resetSeconds` so the tray ticks between
  refreshes. Also derived the `stale` flag from the configured refresh
  interval instead of a hardcoded two hours.
- **#51 `linux-reset-radar`** — `llimit resets [--json] [--days N]`: every
  upcoming reset across accounts, soonest first, from a new pure
  `QuotaSnapshot.upcomingResets(now:within:)` in `QuotaCore`. Missing data is
  distinguished from an empty schedule (`snapshot: false` / a "no quota data
  yet" message). Ordering is total. `--days` outside 1–90 is rejected.
- **#52 `history-skip-unchanged`** — `QuotaHistoryStore.append` skips a
  snapshot whose accounts and failures repeat the newest stored entry (a
  carried-stale refresh, a repeated identical failure), except when that append
  would roll the retention window forward.
- **#53 `limit-color-palettes`** — `LimitKindPalette` (Standard, Ocean, Sunset,
  Forest, Vivid) in `QuotaCore`, plus a palette picker in Settings → Appearance
  that retints rings, bars, sparklines, the menu bar, widgets and the trend
  chart at once.
- **#54 `widget-failure-states`** — the dashboard widgets no longer say "No
  accounts configured" when every account merely *failed*; states are split by
  cause, the medium family names the unavailable accounts (with a `+N more`
  overflow and order-preserving de-duplication), and both families share one
  empty-state view.
- **#55 `provider-glyphs`** — GitHub Copilot, OpenCode Go and Cline all drew the
  same code glyph and Zhipu shared a bolt with Z.ai; each provider now has a
  distinct SF Symbol. OpenCode Go's compact widget name is "OpenCode", not "Go".
- **#56 `settings-accessibility`** — explicit `accessibilityLabel` on every
  hidden-label Settings control, a described (not decorative) account status
  dot, and a textual "Refreshing" that survives the spinner.

Review pass B (parallel review, different agent):

- **#57** — critical bug fix: `QuotaCoordinator` applied `VeniceQuotaEstimate`
  to all provider results; filtered to `.venice` only. (Open.)
- **#58** — quota weather: calm/cloudy/stormy state pill in the dashboard
  header from lowest remaining percentage, failures, and estimates. (Open.)
- **#59** — best model to burn: trophy-tagged row in the overview showing the
  account with the highest bounded remaining headroom. (Open.)
- **#73** — adaptive dashboard: removed the forced
  `.environment(\.colorScheme, .dark)`; the floating window respects the system
  light/dark preference. (Open.)
- **#82** — reset celebration glow: subtle pulsing ring glow when a metric
  reset is within 5 minutes. (Merged.)
- **Accessibility badges** (`#N AUTO`, `ESTIMATED`) updated with larger font
  (8pt), higher contrast (0.85 opacity), and explicit VoiceOver labels.

### Review-driven refinements worth remembering

Each PR absorbed one or more automated review rounds. The changes those rounds
produced are the same traps a future PR will hit:

- A missing snapshot must never render as an empty schedule; the reset radar
  says "no quota data yet", its JSON carries `snapshot`/`generatedAt`, and it
  flags data older than a day so an all-clear from stale data does not read as
  fresh.
- A no-op history append must still prune expired rows, or a long failure
  streak leaves them on disk.
- A whitespace-only `resetIn` must be dropped at every layer (human text, JSON,
  tray fallback), or a consumer renders "resets in ".
- A state encoded twice (dot color and accessibility value) drifts; give it one
  enum.
- Do not key behavior on a sentinel string from another module ("reset");
  compare the underlying times.
- Caching an `ISO8601DateFormatter` in a shared `static let` is a trap: it is
  not thread-safe in `swift-corelibs-foundation`. Use the value-type
  `ISO8601FormatStyle` (where available) or a fresh formatter per call.
- Ordering claims need a total comparator, because `sorted` is not stable.

---

## 1. Correctness and data integrity

### 1.1 Silent refresh no-op while a Codex login is in progress
`LLimitApp/AppModel.swift:187` — `guard !isRefreshing, codexBusyAccounts.isEmpty else { return }`.
The menu-bar Refresh button appears dead: no message, no state change. Either
surface a notice ("Waiting for an OpenAI sign-in to finish") or let the refresh
run for the non-OpenAI accounts.
**Done when:** pressing Refresh during a Codex sign-in gives visible feedback.

### 1.2 Raw HTTP bodies reach persisted, widget-visible failure text
`Clients/AnthropicClient.swift:58-59` appends the response body to the
`ProviderClientError` message, which becomes `ProviderFailure.message` and is
persisted into the snapshot/history and rendered in widgets and `llimit status`.
The same shape appears in other clients. This is a data-exposure path, not just
robustness.

At the same time `ProviderFailure` only captures `(accountID, provider, kind,
message)`: it lacks `failedAt: Date`, `httpStatusCode: Int?`, and
`retryAfter: Date?`, so surfaces cannot show actionable countdowns ("rate
limited; retries in 2m") instead of static error text.

**Do:** persist a structured failure (kind, safe status, timestamp, retry time,
provider code, short allowlisted message); extract `Retry-After` headers into
`retryAfter`; keep raw diagnostics transient; redact every configured
credential value at the coordinator boundary; strip control characters and cap
lengths. Add serialization tests proving tokens never cross the App Group
boundary. (Backlog: "Failure-data redaction boundary".)

### 1.3 Dead code
- `LLimitWidgetExtension/LLimitQuotaWidget.swift` — `resetSummaries(for:at:)`
  and `dashboardBarPercents(for:)` are never called.
- `WidgetVisibilitySettings.showResetInfo` (`Models.swift:1247`) is stored,
  decoded and round-tripped but no surface reads it. Expose it (a real "show
  reset info" toggle) or delete it.
**Done when:** `grep` finds no unused declarations and the settings round-trip
test still passes.

### 1.4 Trend/sparkline points are stamped with the aggregate snapshot time
`AppModel.publishSnapshot` and the widget trend use `QuotaSnapshot.generatedAt`
as the x value, but a carried-stale account's data was fetched earlier
(`ProviderUsage.fetchedAt`). Trend lines and depletion warnings therefore
attribute old data to the refresh time.
**Do:** timestamp trend points with `ProviderUsage.fetchedAt`, and segment
lines around stale periods, resets and missing intervals. (Backlog covers the
same ground.)

## 2. Performance and responsiveness

### 2.1 Whole-file history rewrite on the main actor, every refresh
`QuotaHistoryStore.append` loads, filters, sorts, re-encodes and atomically
rewrites the whole archive; `AppModel.publishSnapshot` (`:276`) calls it on
`@MainActor`, then `reloadRecentHistory()` (`:1759`) decodes the whole file
again for a two-day slice. At the 3000-entry cap that is two full JSON passes
per refresh on the UI thread.
**Do:** day-partitioned files or append-only records with indexed timestamps;
move encode/I/O off `@MainActor`; enforce byte-size as well as entry-count
retention; add a large-archive append-latency benchmark.

### 2.2 Sparklines rescan all history per metric, per render
`LLimitApp/LLimitApp.swift:1427` (`ProviderQuotaCard.sparkPoints`) →
`SparkSeriesBuilder.points` (`:412`) walks every recent snapshot and does a
linear `first(where:)` per account and metric, for every card, on every
`TimelineView` tick, every `@Published` change, and every hover animation.
**Do:** precompute one `[accountID: [metricID: [SparkPoint]]]` map per snapshot
generation and hand it to the cards.

### 2.3 Settings persistence is not debounced
Every keystroke in a credential or name field runs `saveConfiguration()` →
local encode + App Group encode + `WidgetCenter.reloadAllTimelines()`
(`AppModel.updateAccount` → `saveConfiguration`), synchronously on
`@MainActor`, which makes typing in Settings lag.
**Do:** debounce text/color persistence (~500 ms after typing stops), move
JSON encoding and file I/O off `@MainActor` (detached task or persistence
actor), flush on focus loss, window close, termination and credential
rotation, and skip the App Group write when the redacted payload is unchanged.

### 2.4 `AppModel.primaryColorsByAccountID` rebuilds `AppSettings` per access
`AppModel.swift:1462` calls `currentSettings()` (which maps
`providerStyleSettings` for all accounts) and is read from several view bodies.
Memoize it against the accounts/style revision.

### 2.5 Venice key invalidation runs a full history rewrite per keystroke
`AppModel.updateAccount` (`:1601-1614, 1627-1638`): when an edit to a `.venice`
account changes the key, `invalidateVeniceUsage()` runs immediately — it loads
the whole 45-day `quota-history.json`, filters out the account, re-encodes up
to 3,000 snapshots, and writes it back on `@MainActor`. Pasting a 32-character
key triggers ~32 full load-decode-filter-encode-save cycles and multi-second
hangs.
**Do:** defer invalidation until editing finishes (focus loss, Return, or the
account's next verified refresh), not per keystroke. Composes with 2.3's
debounce.

## 3. Visual, layout and theming

### 3.1 The dashboard is hard-locked to dark — partially fixed
`LLimitApp.swift:601` forces `.environment(\.colorScheme, .dark)` and
`DashboardPalette` (`:241`) is a hand-tuned graphite. #73 removed the forced
color scheme so the window follows the system appearance, but the graphite
palette still assumes a dark backdrop: a light desktop needs its own validated
palette and a contrast pass (status colors, hairlines, ring tracks). Treat it
as a designed feature, not a tweak. (Backlog: make the Default background
system-adaptive.)

### 3.2 Settings uses fixed 180 pt label columns
`SettingsView.swift:20` (`settingsLabelWidth = 180`) and the Appearance
section's fixed color columns get cramped at the 720 pt minimum window width
and in localized languages where labels are longer.
**Do:** an adaptive `Grid`/`Form` layout that stacks columns at narrow widths,
and wrap instead of clip.

### 3.3 Menu-bar icon grows linearly and never adapts
`LLimitApp.swift:174-218`: `totalWidth = count * 3 + (count-1) * 1.5` — twelve
accounts is ~52 pt of status item, crowding other items on notched MacBooks.
The image is `isTemplate = false` with pale provider colors, so it can wash out
on a light menu bar and ignores Increase Contrast / Reduce Transparency.
`accessibilityLabel` is just "LLimit".
**Do:** offer icon display modes — multi-bar (current), most-constrained
single bar, fixed-width aggregate gauge/battery, monochrome template with a
badge dot; cap the width; add a useful tooltip and a quota accessibility
summary; adapt to light/dark, Increase Contrast and Reduce Transparency.

### 3.4 One shared hex parser
Five hex parsers exist (`QuotaCore.normalizeHexColor`,
`LimitKindColorScheme.rgbaComponents`, `Color(providerTileHex:)`,
`backgroundBaseColor`, `AppModel.parseHexColor`). Consolidate behind one tested
`QuotaCore` parser used by app and widget. (Backlog.)

### 3.5 Provider identity is declared in three places — unify it
`ProviderMark` (glyph), `ProviderTile.palette` (widget gradient) and
`LimitKindColors` (identity) each encode provider identity separately, and
`AGENTS.md` counts six exhaustive `switch`es that must change together when
adding a provider (`displayName`, `credentialFields`, `defaultRingMetrics`,
`compactProviderName`, `ProviderTile.palette`, `ProviderMark.symbolName`).
**Do:** a single `ProviderDescriptor`/`ProviderMetadata` registry in
`QuotaCore` carrying display name, default ring metrics, brand colors,
SF Symbol, compact name and credential descriptors in one place, so the app,
widgets and CLI cannot drift.

### 3.6 Canonicalize `LimitKindColors` at write time
`LimitKindColors` normalizes hex only in its initializer; its public setters
(`sessionHexColor = …`, `otherHexColors = …`) store whatever they are given, so
a lowercased or malformed value can persist and compare unequal to the same
color written canonically. #53 works around this in
`LimitKindPalette.matching` with a defensive rebuild, but the durable fix is a
`didSet` (or `private(set)` plus setters) on each hex property that runs the
same normalizer, keeping legacy values readable through `matching`'s copy.
**Done when:** `LimitKindColors(sessionHexColor: "#abc…").sessionHexColor` and
a direct assignment of a lowercase hex both read back uppercase, and the store
round-trip tests still pass.

### 3.7 More named style presets
#53 added a curated `LimitKindPalette` picker (Standard, Ocean, Sunset, Forest,
Vivid); the same mechanism could host well-known developer themes — Catppuccin
Mocha, Nord, Tokyo Night, Monokai Pro — each needing a contrast pass for text
and ring tracks. Small, self-contained additions to `WidgetStylePreset.swift` /
`LimitKindPalette.swift`.

## 4. UX and interaction

### 4.1 No way to edit a Linux account after creation
`llimit accounts` has add/import/enable/disable/remove but no rename or
credential update. Fixing a typo'd token means remove + re-add, losing history
and tile slots.
**Do:** `llimit accounts set <id> [--name …] [--set key=value …]` under the
settings lock, with tests in `LLimitdCoreTests`.

### 4.2 CLI ergonomics
- No `--version` (the `.deb` and systemd units would use it).
- No `llimit accounts list --json` for scripting.
- `llimit status` sorts failures by `accountID`, not severity or recency.

### 4.3 Refresh feedback is one overwritten global string
`AppModel.statusMessage` is a single `String`; a save failure can be replaced
immediately by a later "Refreshed N account(s)". Replace it with structured
notices carrying severity, account/context, timestamp and a recovery action,
and do not overwrite durability failures with later success text. (Backlog.)

### 4.4 Freshness is not modelled per account
Last-known usage is carried after a failure, but the aggregate snapshot time is
presented as if every account succeeded. Define one shared freshness model
(last attempt, last success, current failure, stale age), show it on every
surface, count only fresh providers in summaries, and stop appending carried
values to history as new observations. (Backlog; partially addressed by #52.)

### 4.5 Onboarding
The empty state tells an unconfigured user to refresh. Make "Add your first
account" the primary action, add a guided first-run flow with opt-in discovery,
identity selection and a test connection, and add destructive-removal
confirmation with Undo. (Backlog.)

### 4.6 Configurable warning thresholds
The low-quota warning level is hardcoded (~20% remaining / 80% used). Let users
set low and warning thresholds (e.g. 15% / 30% remaining) in Settings and in
`quota-settings.json`, so power users can pick their buffer before switching
accounts. Thresholds feed the status `class`, widget tinting and (future)
notifications.

## 5. Accessibility

### 5.1 Widget accessibility contract (not covered by #56)
The static dashboard and trend widgets still lack semantic summaries: every
state must expose provider, account, metric names, remaining values, reset
times, freshness and failure without relying on color or hidden percentages.
Hide decorative tracks/backgrounds; adapt to Increase Contrast, Reduce
Transparency, Reduce Motion and Differentiate Without Color.

### 5.2 Localize the sentinel strings
`INF` and `--` are emitted as literal text (Settings `percentText`, widget
`percentText`, tray). Use localized "Unlimited" / "Unknown" with accessible
equivalents. Add a String Catalog; there is currently no localization
infrastructure at all, so this is a standalone project.

### 5.3 Status color is the only channel in places
Account sidebar dots, provider status dots, menu-bar bars and ring fills encode
state by color — hard to distinguish for colorblind users. Provide non-color
equivalents (checkmark / warning triangle / exclamation overlays; the sidebar
row's accessibility value added in #56 is the pattern; extend it to the
dashboard and widgets) honoring Differentiate Without Color.

## 6. Linux, CLI and tray

### 6.1 Tray parity gaps
- `format_account_header` (`tray/llimit_tray.py`) shows no headline when an
  account has only amount-style metrics (a credits-only Cline account shows
  just "Cline"), while the macOS card shows the balance line.
- The tray could pin the reset radar (#51) as its own section.
- `llimit daemon` writes startup lines to stdout; add `--quiet`/`--version` for
  the systemd unit.

### 6.2 `llimit status --json` staleness is now interval-aware (#50)
Keep the threshold in step with the daemon when new callers render the contract
(e.g. a future `--stale-after` flag).

### 6.3 Shell prompt / status line integration
A lightweight command that emits a one-line status for `starship`, `tmux`,
`zsh`/`bash` prompts: `llimit prompt` or `llimit status --compact` →
`[Claude: 84% | GPT: 62%]` with ANSI colors. Continuous quota visibility in the
terminal for near-zero cost. Same family: Raycast / Stream Deck widgets reading
`llimit status --json`.

## 7. Security and credential handling

### 7.1 Enforce local file permissions
`SettingsStore.save` applies `0600` with `try?` (failure ignored);
`SnapshotStore`/`QuotaHistoryStore` request `0644` for files that contain
account metadata. Parent directories are not explicitly restricted.
**Do:** create the local LLimit directory `0700`; verify regular-file type,
owner and final mode after replacement; treat verification failure as a save
failure; use `0600` locally and the narrowest functional mode in the App Group;
add first-save, overwrite, wrong-owner/type and permission-failure tests.

### 7.2 Stores are `@unchecked Sendable` with shared codecs
`SettingsStore`, `SnapshotStore` and `QuotaHistoryStore` share `JSONEncoder`/
`JSONDecoder` instances and do unlocked read-modify-write. Concurrent appends
can lose data, and one malformed entry permanently blocks later appends.
**Do:** serialize in-process access (actors or explicit locking); create codecs
per operation or prove synchronization; quarantine corrupt archives and reseed;
add concurrent-append and truncated-JSON tests.

### 7.3 Settings recovery and schema migration
Recovery from an unreadable settings file is manual. Add a last-known-good
backup before atomic replacement, a versioned envelope with forward/downgrade
migrations, and a visible recovery flow (reveal, restore backup, export,
reset). Validate `QuotaSnapshot.version`. (Backlog.)

## 8. Widgets

### 8.1 Trend chart
- Preserve extrema during downsampling (`downsampleTrendPoints` samples
  uniformly, so a spike or trough between samples is lost).
- Show the current value and time/percentage context.
- Base depletion warnings on enough fresh, reset-segmented samples (currently
  the last 8 points with a `remainingPercent <= 60` gate).
- Show more than one relevant warning when space permits.
- Memory budget: `QuotaHistoryStore.loadRecent(days:maxEntries:now:)` decodes
  the whole history file before filtering, and WidgetKit extensions die at
  ~30 MB under `chronod`. Write a compact, pre-filtered `quota-trend.json` DTO
  (downsampled points only) during the app's refresh so widgets never parse
  the full archive.

### 8.2 Dashboard widgets
- Derive row capacity from geometry instead of a fixed provider limit.
- Remove fixed-width columns or use `ViewThatFits`.
- Evaluate `.systemLarge` for a full multi-account dashboard.

### 8.3 Provider tiles
Runtime validation on macOS is still outstanding (see `BACKLOG.md` for the full
ladder): auto-mapping, the `#N AUTO` badge, pinned assignments, light/dark
desktop contexts, and the intended per-provider palettes.

## 9. Network layer

### 9.1 Dedicated, resource-bounded HTTP client
`URLSessionHTTPClient` uses `URLSession.shared` with a request timeout only: it
shares cookies/cache, buffers unbounded responses, and collapses structured
`URLError`s and cancellation into a generic `.network` failure.
**Do:** an ephemeral session (cookies and URL cache off), a resource deadline,
a connection limit, a response-body cap enforced while receiving, and preserved
`URLError.Code`/cancellation. (Backlog.)

### 9.2 Retry, rate-limit and scheduling policy
Centralize transient-failure classification (network, 408, 425, 429,
provider-specific 403, selected 5xx), honor `Retry-After` and GitHub
rate-limit headers, add a small jittered retry budget for idempotent reads,
never replay rotating OAuth exchanges after an ambiguous timeout, add per-host
concurrency limits, and build one scheduler from last attempt/last success/
snapshot age/wake/network-return. (Backlog.)

## 10. Provider correctness

### 10.1 Validate schemas instead of trusting them
Anthropic can accept an empty recognized schema, Zhipu can succeed with no
supported limit type, and Google treats a missing `remainingFraction` as zero.
Treat missing percentages as unknown, require recognized metrics before
reporting success, and keep aggregate usage `nil` when no bounded metric
exists. Add missing-field / empty-payload / hostile-number tests per provider.

### 10.2 Copilot, OpenAI, Google, Zhipu, Anthropic endpoint verification
All provider APIs here are private and unstable; change behaviour only from
captured, sanitized fixtures. `BACKLOG.md` lists the specific endpoints and
fields to verify — do not make speculative edits.

## 11. Delight and novel features

Ideas that are cheap, self-contained and genuinely useful. Each should be its
own PR.

1. **Burn-rate chip** — lift the widget's `depletionWarnings` math into
   `QuotaCore` and surface "at this rate, empty by 14:20 (before reset)" in
   `llimit status`, the tray and the dashboard. The math already exists but is
   invisible outside the widget.
2. **Best model to burn** — #59 added the dashboard recommendation row; the
   remaining surfaces are a one-liner in `llimit status`, the menu-bar
   tooltip, and an optional `llimit recommend` command. Rank by remaining
   headroom weighted by proximity to reset.
3. **Quota weather** — #58 shipped the calm/cloudy/stormy state pill; extend
   to playful copy per account and to the Linux status/tray
   (☀️ clear >50% everywhere … ⛈️ storm when rate-limited or nearly empty).
4. **Reset celebration** — #82 merged the pulsing ring glow near reset;
   optional extras: a subtle tick/animation at the moment of reset (respect
   Reduce Motion).
5. **Pacing ring** — make a weekly quota last until a chosen date: show
   "ahead of pace (burning fast)" vs "on track" from elapsed-vs-consumed
   within the window.
6. **Menu sparkline** — 24 h history for the most constrained account in the
   menu bar.
7. **Honesty mode** — visually distinguish verified, inferred and stale data
   (the `estimated` flag in the JSON contract is the seed).
8. **History export** — `llimit export --format json|csv [--days 30]` plus an
   "Export History…" button in Settings → General, with explicit privacy
   controls, for self-analysis of usage trends and spend.
9. **Threshold notifications** — per-metric 80%/95% plus reset and
   auth-failure alerts, with deduplication, quiet hours and Focus awareness
   (thresholds configurable per 4.6).
10. **Shortcuts / App Intents** — read quota and trigger refresh.
11. **Signed auto-update** — Sparkle-style, after the signing/notarization
    work.
12. **Quota roulette / quick pick** — a button or `llimit pick` that randomly
    chooses an account with high headroom (>60%) to spread load and keep
    subscriptions balanced.

## 12. `BACKLOG.md` items that are done or stale

Do not re-open these; remove them from `BACKLOG.md` when convenient.

- **"Check current failure before reporting carried usage as loaded"** — done:
  `SettingsView.accountDataStatus` checks `accountFailure` before `accountUsage`
  (`:1207`).
- **"Publish one lightweight entry with `.after(nextRefreshDate)`; do not clone
  the entry every five minutes"** — done: `QuotaTimelineProvider.getTimeline`
  (`:43-53`) emits a single entry with `.after(nextRefreshDate)`.
- **"Resolve whether the global 'Show percentages in all widgets' setting
  applies to provider tiles"** — the tiles never read
  `showPercentageValues`; the setting is dashboard-only in practice.
- **"Remove or consolidate ring/reset helpers superseded by the provider
  tile"** — `resetSummaries`/`dashboardBarPercents` are unused and can simply be
  deleted (item 1.3).

## 13. Suggested order

1. Merge/review the open PRs from both passes (#50–#59, #73).
2. Failure-text redaction + structured failures (1.2) and file-permission
   enforcement (7.1) — the two remaining security items.
3. History storage + main-actor persistence (2.1, 2.3) and sparkline
   precomputation (2.2) — the remaining performance items with visible effect.
4. Burn-rate chip (11.1) and `llimit accounts set` (4.1) — cheap, high-value.
5. Freshness model (4.4), structured notices (4.3), widget accessibility (5.1).
6. Signing/notarization and the provider-fixture work, which are prerequisites
   for a trustworthy release.
