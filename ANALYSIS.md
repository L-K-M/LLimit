# LLimit — analysis and shovel-ready ideas

This document is the durable output of three independent full reviews of `main`
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

Review pass C (third independent pass; PRs open for review):

- **#63 `fix/provider-error-body-excerpt`** — provider error bodies are capped
  (~200 chars, whitespace-folded), bounded-decoded before tokenization, and
  scrubbed of credential-shaped tokens (Bearer/JWT/API-key prefixes) before
  they can persist into snapshots. Covers the exposure half of §1.2; the
  structured-failure fields there remain open.
- **#64 `fix/status-renderer-account-identity`** — failure rows name the
  account (recorded title → stale usage title → provider name), the JSON
  contract gains `failing`/`error`/`errorKind` per account row, duplicate
  failures collapse to the most actionable kind, any failure escalates a
  green bar to `warning`, and the tray keeps full error text in tooltips.
- **#68 `fix/venice-key-invalidation`** — Venice key edits no longer run a
  full history rewrite per keystroke: invalidation is debounced + flushed on
  termination, and quota estimates carry a key fingerprint so a stale
  estimate can't bind to a different key (§2.5 closed).
- **#74 `fix/store-file-permissions`** — snapshot and history files are
  written owner-only via a create-0600-then-`rename` helper, so no
  world-readable window exists and chmod failures log to stderr (§7.1,
  partially: directory mode and owner verification remain).
- **#76 `fix/history-dedup`** — `append` skips content-equivalent snapshots
  while the newest point is fresh (<1h) and folds the newer timestamp into it
  when stale, so flat stretches neither grow the file nor age out of
  `loadRecent` (§4.4's "stop appending carried values", §P3).
- **#78 `fix/store-corruption-quarantine`** — undecodable snapshot/history
  files move aside to `<name>.corrupt` with a logged trail
  (`reportPersistenceIssue`: os.Logger on Darwin, stderr on Linux) instead of
  failing forever (§7.2's quarantine half).
- **#79 `fix/app-group-store-nil`** — the App Group `SnapshotStore`
  convenience init is failable with an NSLog breadcrumb instead of
  force-unwrapping the container URL.
- **#81 `fix/opencode-go-rate-limited`** — OpenCode Go windows reporting
  `rate-limited` at any percent render exhausted instead of failing the
  fetch; the rule lives on `GoUsageWindow.isExhausted`/`effectivePercent`.
- **#85 `fix/settings-save-debounce`** — per-keystroke/color-drag bindings
  coalesce settings writes through a 400ms debounce, flushed synchronously on
  `willTerminate` (queue: nil — async hops can be dropped mid-quit) and on
  resign-active (§2.3's debounce half).
- **#86 `feat/env-credential-references`** — stored credential values may be
  `env:NAME` pointers resolved from the process environment at runtime;
  OpenAI grant rotation and live-file adoption never overwrite a reference,
  so secrets can live entirely outside the settings file (H6).
- **#87 `feat/pace-eta`** — `UsageMetric.paceEstimate`: burn-rate and
  exhaustion-ETA computed in QuotaCore from history, rendered on macOS
  dropdown rows (§11.1's engine; CLI/tray surfaces remain).
- **#88 `feat/cli-surface`** — `llimit compact` one-line status for prompts
  (§6.3), `llimit resets` upcoming-reset listing, and `llimit export` history
  export (§11.8).
- **#91 `fix/claude-ua-version`** — the Anthropic usage UA reads the detected
  Claude Code version (cached probe) instead of a frozen `claude-code/1.0.110`.
- **#97 `feat/llimit-check`** — `llimit check [--below pct] [--stale-hours h]`
  exits 1 with reason lines for low metrics, failures, and stale data —
  the scriptable alerting half (`llimit check || notify-send`).
- **#98 `feat/llimit-trend`** — `llimit trend [--days N]` renders per-account
  sparklines from the history file (forward-filled, per-series normalized).
- **#99 `feat/llimit-watch`** — `llimit status --watch [seconds]` repaints in
  place (ANSI clear+home) tracking daemon refreshes (D5's minimal form).
- **#100 `feat/threshold-alerts`** — `QuotaAlertEvaluator` (QuotaCore) +
  `UNUserNotificationCenter` delivery: warning/critical band crossings and
  per-kind failures notify once, re-arm on recovery; thresholds configurable
  in Settings → General (§4.6 closed; §11.9 minus quiet hours/Focus).

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
`AppModel.refreshNow` — `guard !isRefreshing, codexBusyAccounts.isEmpty else { return }`.
The menu-bar Refresh button appears dead: no message, no state change. Either
surface a notice ("Waiting for an OpenAI sign-in to finish") or let the refresh
run for the non-OpenAI accounts.
**Done when:** pressing Refresh during a Codex sign-in gives visible feedback.

### 1.2 ProviderFailure carries only a display string — exposure half fixed by #63
#63 lands the excerpt discipline: every client routes bodies through shared
`bodyExcerpt`/`sanitizeFailureText` helpers (cap, whitespace-fold, credential-
token scrub) before the message reaches `ProviderFailure`. What remains is the
structured-data half: `ProviderFailure` still captures only
`(accountID, provider, kind, message)` — no `failedAt: Date`,
`httpStatusCode: Int?`, or `retryAfter: Date?` — so surfaces cannot show
"failing for 3h" or "rate limited; retries in 2m", and 4.2's recency ordering
has nothing to sort on.

**Do:** persist a structured failure (kind, safe status, timestamp, retry time,
provider code, short allowlisted message); extract `Retry-After` headers into
`retryAfter`; keep raw diagnostics transient; redact every configured
credential value at the coordinator boundary; strip control characters and cap
lengths. New fields are additive Codable — verify an old snapshot still
decodes, and decide whether the archive needs a `formatVersion` gate at the
same time (see 7.3). Add serialization tests proving tokens never cross the
App Group boundary. (Backlog: "Failure-data redaction boundary".)

### 1.3 Dead code
- `LLimitWidgetExtension/LLimitQuotaWidget.swift` — `resetSummaries(for:at:)`
  and `dashboardBarPercents(for:)` are never called.
- `WidgetVisibilitySettings.showResetInfo` (Models.swift) is stored,
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
rewrites the whole archive; `AppModel.publishSnapshot` calls it on
`@MainActor`, then `reloadRecentHistory()` decodes the whole file
again for a two-day slice. At the 3000-entry cap that is two full JSON passes
per refresh on the UI thread. #76 reduced *how often* a write happens
(content-equivalent snapshots fold into the newest stored point), but each
distinct write still rewrites the whole archive.
**Do:** day-partitioned files or append-only records with indexed timestamps;
move encode/I/O off `@MainActor`; enforce byte-size as well as entry-count
retention; add a large-archive append-latency benchmark.

### 2.2 Sparklines rescan all history per metric, per render
`ProviderQuotaCard.sparkPoints` (LLimitApp/LLimitApp.swift) →
`SparkSeriesBuilder.points` walks every recent snapshot and does a
linear `first(where:)` per account and metric, for every card, on every
`TimelineView` tick, every `@Published` change, and every hover animation.
**Do:** precompute one `[accountID: [metricID: [SparkPoint]]]` map per snapshot
generation and hand it to the cards.

### 2.3 Settings persistence — debounce done, still on the main actor
#85 coalesced the hot binding paths through a 400ms debounce flushed
synchronously on `willTerminate`/`willResignActive`, so typing and color-drag
no longer stall the UI thread every keystroke. What remains:
`saveConfiguration()` still performs the local encode + App Group encode +
file writes on `@MainActor` (once per debounce flush), and the App Group copy
is rewritten even when the redacted payload is byte-identical.
**Do:** move JSON encoding and file I/O off `@MainActor` (detached task or
persistence actor) behind the existing dirty flag, and skip the App Group
write when the redacted payload is unchanged.

### 2.4 `AppModel.primaryColorsByAccountID` rebuilds `AppSettings` per access
`AppModel.primaryColorsByAccountID` calls `currentSettings()` (which maps
`providerStyleSettings` for all accounts) and is read from several view bodies.
Memoize it against the accounts/style revision.

### ~~2.5 Venice key invalidation runs a full history rewrite per keystroke~~ — fixed by #68
Deferred invalidation + a key fingerprint on VeniceQuotaEstimate, plus a
termination flush for pending invalidations. The underlying cost of a
full-archive rewrite per invalidation remains and is covered by 2.1.

## 3. Visual, layout and theming

### 3.1 The dashboard is hard-locked to dark — partially fixed
`LLimitApp.swift` (the dashboard window's content) forces
`.environment(\.colorScheme, .dark)` and `DashboardPalette` is a hand-tuned
graphite. #73 removed the forced
color scheme so the window follows the system appearance, but the graphite
palette still assumes a dark backdrop: a light desktop needs its own validated
palette and a contrast pass (status colors, hairlines, ring tracks). Treat it
as a designed feature, not a tweak. (Backlog: make the Default background
system-adaptive.)

### 3.2 Settings uses fixed 180 pt label columns
`settingsLabelWidth = 180` (SettingsView.swift) and the Appearance
section's fixed color columns get cramped at the 720 pt minimum window width
and in localized languages where labels are longer.
**Do:** an adaptive `Grid`/`Form` layout that stacks columns at narrow widths,
and wrap instead of clip.

### 3.3 Menu-bar icon grows linearly and never adapts
The menu-bar image builder in `LLimitApp.swift`:
`totalWidth = count * 3 + (count-1) * 1.5` — twelve
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
- `llimit status` failure rows: #64 made them severity-ranked per account;
  cross-account ordering is still `accountID`, not severity or recency
  (needs `failedAt` from 1.2 to do recency properly).

### 4.3 Refresh feedback is one overwritten global string
`AppModel.statusMessage` is a single `String`; a save failure can be replaced
immediately by a later "Refreshed N account(s)". Replace it with structured
notices carrying severity, account/context, timestamp and a recovery action,
and do not overwrite durability failures with later success text. (Backlog.)

### 4.4 Freshness is not modelled per account
Last-known usage is carried after a failure, but the aggregate snapshot time is
presented as if every account succeeded. Define one shared freshness model
(last attempt, last success, current failure, stale age), show it on every
surface (e.g. "updated 3h ago" on a carried-stale row), count only fresh
providers in summaries, and stop appending carried
values to history as new observations. (Backlog; partially addressed by #52;
#76 now deduplicates content-identical appends, and #64 surfaces failure state
per account row, but the explicit per-account freshness model is still absent.)

### 4.5 Onboarding
The empty state tells an unconfigured user to refresh. Make "Add your first
account" the primary action, add a guided first-run flow with opt-in discovery,
identity selection and a test connection, and add destructive-removal
confirmation with Undo. (Backlog.)

### ~~4.6 Configurable warning thresholds~~ — fixed by #100
`QuotaAlertSettings` exposes warning/critical percentages in Settings →
General, persisted in `AppSettings`. Remaining follow-up: apply the same
configured thresholds to the status `class` computation and widget tinting
(today they still use the hardcoded ~20% level).

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

### 6.3 Shell prompt / status line integration — mostly done by #88
`llimit compact` emits the one-line `Claude:84% GPT:62%` form for `starship`,
`tmux` and prompts. Remaining: ANSI color in compact output, and the Raycast /
Stream Deck angle (third-party widgets reading `llimit status --json`).

## 7. Security and credential handling

### 7.1 Enforce local file permissions — partially done by #74
#74 replaced the write-then-`try?`-chmod pattern with `writeOwnerOnlyAtomically`
(create temp `0600`, write, `rename`), so snapshot/history files are `0600`
with no world-readable window, and chmod/write failures are reported. Remaining:
parent directories are not explicitly restricted, the App Group copy should use
the narrowest functional mode, and nothing verifies regular-file type/owner
after replacement.
**Do:** create the local LLimit directory `0700`; verify regular-file type,
owner and final mode after replacement; treat verification failure as a save
failure; use `0600` locally and the narrowest functional mode in the App Group;
add first-save, overwrite, wrong-owner/type and permission-failure tests.

### 7.2 Stores are `@unchecked Sendable` with shared codecs — quarantine done by #78
#78 quarantines undecodable archives to `<name>.corrupt` with a logged trail, so
one malformed file no longer blocks all later loads/appends. The concurrency
half remains: `SettingsStore`, `SnapshotStore` and `QuotaHistoryStore` share
`JSONEncoder`/`JSONDecoder` instances and do unlocked read-modify-write, so
concurrent appends can still lose data.
**Do:** serialize in-process access (actors or explicit locking); create codecs
per operation or prove synchronization; add concurrent-append and
truncated-JSON tests.

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

1. **Burn-rate chip** — #87 landed the QuotaCore engine
   (`PaceEstimator` → `UsageMetric.paceEstimate`) and renders it on macOS
   dropdown rows. Remaining surfaces: `llimit status` lines, the tray, and the
   widget's `depletionWarnings` (which still uses its own math — converge on the
   shared estimator).
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
   menu bar. CLI side landed in #98 (`llimit trend` renders ASCII sparklines);
   the menu-bar/tray surfaces remain.
7. **Honesty mode** — visually distinguish verified, inferred and stale data
   (the `estimated` flag in the JSON contract is the seed).
8. **History export** — #88 landed `llimit export` (JSON and CSV). Remaining:
   an "Export History…" button in Settings → General with explicit privacy
   controls, for self-analysis of usage trends and spend.
9. **Threshold notifications** — core delivered by #100 (warning/critical
   crossings + failure alerts with persisted dedup keys, thresholds from
   `QuotaAlertSettings`) and #97 (`llimit check` for cron/`notify-send`).
   Remaining: quiet hours, Focus awareness, and reset-moment alerts.
10. **Shortcuts / App Intents** — read quota and trigger refresh.
11. **Signed auto-update** — Sparkle-style, after the signing/notarization
    work.
12. **Quota roulette / quick pick** — a button or `llimit pick` that randomly
    chooses an account with high headroom (>60%) to spread load and keep
    subscriptions balanced.
13. **"What changed" delta** — a subtle ▲/▼ next to a metric that moved since
    the last refresh, in the macOS dropdown and the tray. The history needed
    already exists (compare against the previous snapshot before overwriting).
14. **Reset radar for the macOS dropdown** — the CLI side exists (#51 `llimit
    resets`, plus #88's listing); add a "Next resets" section to the
    dropdown/dashboard answering "what frees up next?" across accounts.

## 12. `BACKLOG.md` items that are done or stale

Do not re-open these; remove them from `BACKLOG.md` when convenient.

- **"Check current failure before reporting carried usage as loaded"** — done:
  `SettingsView.accountDataStatus` checks `accountFailure` before `accountUsage`.
- **"Publish one lightweight entry with `.after(nextRefreshDate)`; do not clone
  the entry every five minutes"** — done: `QuotaTimelineProvider.getTimeline`
  emits a single entry with `.after(nextRefreshDate)`.
- **"Resolve whether the global 'Show percentages in all widgets' setting
  applies to provider tiles"** — the tiles never read
  `showPercentageValues`; the setting is dashboard-only in practice.
- **"Remove or consolidate ring/reset helpers superseded by the provider
  tile"** — `resetSummaries`/`dashboardBarPercents` are unused and can simply be
  deleted (item 1.3).

## 13. Suggested order

1. Merge/review the open PRs from all passes (#50–#59, #73, #63–#100 per the
   lists above).
2. Structured failure fields (1.2) and the remainder of file-permission
   enforcement (7.1) — the two remaining security items.
3. History storage + main-actor persistence (2.1, 2.3) and sparkline
   precomputation (2.2) — the remaining performance items with visible effect.
4. `llimit accounts set` (4.1) and burn-rate surfaces for CLI/tray (11.1) —
   cheap, high-value.
5. Freshness model (4.4), structured notices (4.3), widget accessibility (5.1).
6. Menu-bar icon modes (3.3), light-mode palette (3.1), provider registry (3.5).
7. Signing/notarization and the provider-fixture work, which are prerequisites
   for a trustworthy release.
