# LLimit project analysis and remaining work

Consolidated on 2026-10-06 from the full pre-implementation review in `tmp.md`,
the earlier document at `756ce3c`, and fetched `origin/main:ANALYSIS.md` at
`54d423e` (including `e2d5e02` and the incoming third review pass).

The source reviews examined baseline `2d6ac1e652ac33724961a5a8bf8f43f0f8d31d2f`:
macOS app, widgets, QuotaCore, Linux CLI/daemon/tray, scripts, CI/release, and
`BACKLOG.md`. `tmp.md` records four independent GPT-6.1 Sol reviews; the incoming
main document records three review passes. This consolidation is
documentation-only, not a new code or PR review.

Each remaining item gives evidence, scope, and acceptance. Line references are
baseline starting points, not guaranteed current offsets. `Core/` means
`Packages/QuotaCore/Sources/QuotaCore/`; `Linux/` means
`Packages/LLimitd/Sources/LLimitdCore/`; other paths are repository-relative.
Check the implementation references before coding overlapping work.

## Evidence and validation limits

- The `tmp.md` baseline passed **416 QuotaCore**, **49 LLimitd**, and **23 tray**
  tests, plus shell syntax checks for build/release/widget diagnostics/Linux
  installation/packaging. Historical main CI run **37509656521** passed macOS
  build/integration and Linux checks.
- QuotaCore built in Swift 6 language mode. LLimitd's optional Swift 6 build
  failed at `StatusRenderer.swift:222` on a non-Sendable stored comparator;
  supported-mode tests passed. Async test fixtures also need synchronization work.
- The incoming review environment lacked Swift and relied on CI. It reports tray
  tests increasing **23 to 27** after countdown work. Its CI description includes
  macOS `xcodebuild`, QuotaCore tests, Linux QuotaCore/LLimitd tests, and
  `python3 -m unittest discover -s Packages/LLimitd/tray/tests`.
  `scripts/test-panel-geometry.sh` and `scripts/test-limit-colors.sh` cover pure logic.
- The coordinating agent reports the latest combined code passed **492 QuotaCore**
  and **57 LLimitd** tests. These are reported results, not rerun for this doc edit.
- Native rendering, Instruments, VoiceOver, live authentication, installed widgets,
  systemd upgrades, and packaged TLS were not exercised in this consolidation.
  Source counterexamples, reported implementations, and runtime hypotheses remain
  distinct. No credentials, other workers, or their PRs were inspected.
- Source inspection proves blocking work/full decoding, not measured stuttering,
  multi-second hangs, OOM, or a fixed WidgetKit memory limit. A 32-character paste
  normally causes one binding update, not 32 saves. The older **30 MB** budget is
  unverified; measure platform/process limits before using it as a crash threshold.

## Implementation ledger

### Our six implemented slices: open PRs

These scopes and open status come from the task handoff. CI/review monitoring and
final status updates belong to the coordinating agent. They are not merged work.

| PR | Branch | Retired instructions and retained implementation scope |
|---|---|---|
| [#66](https://github.com/L-K-M/LLimit/pull/66) | `sol/snapshot-only-status-20261006` | **L01 fully; Linux C03.** Snapshot-only status, clean JSON stdout, no credential-settings read, and failed-settings reconciliation guard preserving cached bytes. |
| [#67](https://github.com/L-K-M/LLimit/pull/67) | `sol/bottleneck-context-20261006` | **Bottleneck caption fully.** Gauge and caption identify the same actual limiting metric/reset, including ties, unknown, unlimited, and balance-only states, with accessible context and no extra poll. |
| [#70](https://github.com/L-K-M/LLimit/pull/70) | `sol/failure-redaction-20261006` | **New-failure portion of C01.** Safe provider/OAuth messages, configured-secret redaction and message bounds. Historical failure migration, structured metadata, and widget-safe DTO remain below. |
| [#69](https://github.com/L-K-M/LLimit/pull/69) | `sol/quota-schema-validation-20261006` | **A01/A02 fully.** Cline recognized windows require finite `percentUsed`; missing/null fails decoding, explicit zero/bare objects/`data:null` remain valid. Muse distinguishes absent from malformed subscription windows and requires recognizable completion; valid pay-as-you-go completion remains supported. Stacked on #70. |
| [#72](https://github.com/L-K-M/LLimit/pull/72) | `sol/dashboard-truth-20261006` | **W01/W02 fully; dashboard W03.** Attributable bounded values only, distinct unknown/unlimited/zero, current enabled membership/names before sorting/limiting, conservative legacy ownership, and truthful dashboard no-account/awaiting/failure/storage states. Per-account age and tile/trend load outcomes remain below. |
| [#75](https://github.com/L-K-M/LLimit/pull/75) | `sol/fetch-time-history-20261006` | **C02 fully.** Source-fetch-time extraction/append/chart semantics exclude failed/carried/sibling observations, retain fresh equal readings, and canonicalize only unambiguous legacy ownership without destroying archives. |

Integration order: **#70 before #69** because Muse guard/parser changes overlap.
#75 conservatively collapses same-account readings within one persisted fetch-second;
disabled siblings do not establish legacy ownership. Native layout, AX, live
providers, and installed-widget behavior still need runtime verification.

Retired baseline evidence remains traceable without repeating implementation tasks:

- **L01:** `Packages/LLimitd/Sources/llimit/main.swift:45-48,332-337` opened settings
  for status; bootstrap reconciliation could erase usage and save logs contaminate JSON.
- **C02:** `Core/SnapshotMerge.swift:12-30` retained original `fetchedAt`, but history
  stored merged snapshots; `LLimitApp/LLimitApp.swift:426-442` and
  `LLimitWidgetExtension/LLimitQuotaWidget.swift:773-775` plotted `generatedAt`.
  App `:1427-1440` added a point at now. Failures/targeted sibling polls invented
  flat observations, inflated forecasting evidence, and could bypass source-time windows.
- **A01:** `Core/Clients/ClineQuotaClient.swift:325-340,95-102` converted missing/null
  `percentUsed` into zero used/100% remaining.
- **A02:** `Core/Clients/MetaMuseQuotaClient.swift:85-127,189-217` could call malformed
  `weekly:{}` or an arbitrary HTTP-200 `{}` pay-as-you-go.
- **W01:** Unknown Google aggregate zero produced full bars/lowest 100% alongside
  `--` rows (`LLimitQuotaWidget.swift:415-416,495-514,635-650`). **W02:** snapshot
  names/membership survived edits (`:357-373,439-442`). **Dashboard W03:** initial
  failures/unreadable stores became no-account states (`:357-391,439-466`). These
  references use `LLimitWidgetExtension/LLimitQuotaWidget.swift`.

### Implementations reported by incoming main

All references below are retained as reports, including newly fetched pass-C
references. Their PRs, reviews, CI, and merge status were not checked. Do not infer
status from the incoming document's words “fixed,” “landed,” or “merged.”

- [#50](https://github.com/L-K-M/LLimit/pull/50), `linux-live-resets`: live
  `UsageMetric.resetCountdown(at:)` in status/tooltips, `resetAt` ISO timestamps
  and recomputed `resetSeconds` in metric JSON, ticking tray countdowns, and
  configured-interval staleness instead of a hardcoded two hours.
- [#51](https://github.com/L-K-M/LLimit/pull/51), `linux-reset-radar`:
  `llimit resets [--json] [--days N]`, pure
  `QuotaSnapshot.upcomingResets(now:within:)`, total ordering, 1–90-day validation,
  `snapshot`/`generatedAt` metadata, distinct missing data versus empty schedule,
  and stale-schedule indication (reported older-than-one-day policy).
- [#52](https://github.com/L-K-M/LLimit/pull/52), `history-skip-unchanged`:
  skip repeated accounts/failures while still advancing retention.
- [#53](https://github.com/L-K-M/LLimit/pull/53), `limit-color-palettes`:
  `LimitKindPalette` Standard/Ocean/Sunset/Forest/Vivid and Settings → Appearance
  picker across rings/bars/sparklines/menu/widgets/trend; `matching` defensively
  canonicalizes a copy. Validate contrast/CVD and canonical writes when extending it.
- [#54](https://github.com/L-K-M/LLimit/pull/54), `widget-failure-states`:
  cause-specific failures, shared dashboard empty view, unavailable account names,
  order-preserving deduplication, and medium-family `+N more`. Coordinate with #72.
- [#55](https://github.com/L-K-M/LLimit/pull/55), `provider-glyphs`:
  distinct Copilot/OpenCode Go/Cline and Zhipu/Z.ai symbols; compact OpenCode name
  is “OpenCode,” not “Go.”
- [#56](https://github.com/L-K-M/LLimit/pull/56), `settings-accessibility`:
  explicit hidden-control labels, described account-status dots, and textual
  “Refreshing.” This does not establish full widget semantics or native AX coverage.
- [#57](https://github.com/L-K-M/LLimit/pull/57): Venice-only coordinator estimate
  dispatch. The reviewed helper already guards non-Venice providers; the incoming
  “critical cross-provider bug” claim was not independently established.
- [#58](https://github.com/L-K-M/LLimit/pull/58): calm/cloudy/stormy dashboard
  header from headroom, failures, and estimates.
- [#59](https://github.com/L-K-M/LLimit/pull/59): trophy-tagged overview
  recommendation using the highest bounded remaining headroom.
- [#63](https://github.com/L-K-M/LLimit/pull/63), `fix/provider-error-body-excerpt`:
  bounded decoding, approximately 200-character whitespace-folded excerpts, and
  Bearer/JWT/API-key-shaped token scrubbing via `bodyExcerpt`/`sanitizeFailureText`.
  Compare with #70's allowlisted-public-message boundary; excerpt scrubbing alone
  does not establish safety for unknown reflected secrets or old persisted errors.
- [#64](https://github.com/L-K-M/LLimit/pull/64), `fix/status-renderer-account-identity`:
  failure title fallback (recorded title → cached usage title → provider), additive
  account JSON `failing`/`error`/`errorKind`, most-actionable duplicate collapse,
  failure escalation from green to warning, and full error tooltips in tray.
  Cross-account severity/recency ordering and all-failed health need separate checks.
- [#68](https://github.com/L-K-M/LLimit/pull/68), `fix/venice-key-invalidation`:
  deferred/debounced invalidation, termination flush, and estimate key fingerprint
  preventing attachment to a replacement key. Whole-archive purge cost remains.
- [#73](https://github.com/L-K-M/LLimit/pull/73): floating dashboard follows system
  appearance after removing forced dark mode; neutral palette validation remains.
- [#74](https://github.com/L-K-M/LLimit/pull/74), `fix/store-file-permissions`:
  `writeOwnerOnlyAtomically` creates a `0600` temporary file before rename for
  snapshots/history; chmod/write errors reach stderr. Local directories, settings
  credentials, type/owner verification, and shared-container compatibility remain.
- [#76](https://github.com/L-K-M/LLimit/pull/76), `fix/history-dedup`:
  skip content-equivalent points when newest is fresh (<1h), fold a newer timestamp
  into stale points to keep flat stretches recent. Reconcile with #52/#75 before
  integration: publication time cannot become source observation time, and genuinely
  fresh equal readings must not disappear. Sparse archives need preservation tests.
- [#78](https://github.com/L-K-M/LLimit/pull/78), `fix/store-corruption-quarantine`:
  undecodable snapshot/history moves to `<name>.corrupt`, with
  `reportPersistenceIssue` using Darwin os.Logger/Linux stderr. Quarantine does not
  establish settings recovery or serialized read-modify-write.
- [#79](https://github.com/L-K-M/LLimit/pull/79), `fix/app-group-store-nil`:
  failable App Group `SnapshotStore` convenience initializer and NSLog breadcrumb
  replace force unwrap; tile/trend still need explicit load outcomes and recovery.
- [#81](https://github.com/L-K-M/LLimit/pull/81), `fix/opencode-go-rate-limited`:
  `GoUsageWindow.isExhausted`/`effectivePercent` renders `rate-limited` windows as
  exhausted at any reported percent instead of failing the fetch.
- [#82](https://github.com/L-K-M/LLimit/pull/82): near-reset pulsing ring glow
  within five minutes, reported in reset-radar work. Anticipation is not verified
  replenishment; an observed-reset receipt remains a separate idea.
- [#85](https://github.com/L-K-M/LLimit/pull/85), `fix/settings-save-debounce`:
  400ms coalescing for keystrokes/color drags, synchronous `willTerminate` flush
  (observer queue nil; async hops may be dropped on quit), and resign-active flush.
  Debouncing does not establish off-main-actor I/O or measured responsiveness.
- [#86](https://github.com/L-K-M/LLimit/pull/86), `feat/env-credential-references`:
  `env:NAME` settings references resolved at runtime; OpenAI grant rotation and
  live-file adoption preserve the reference rather than overwriting it. Keep
  resolved values local and out of display stores/logs; preserve provenance.
- [#87](https://github.com/L-K-M/LLimit/pull/87), `feat/pace-eta`:
  `PaceEstimator`/`UsageMetric.paceEstimate` in QuotaCore and macOS dropdown
  burn-rate/ETA. CLI/tray/widget surfaces remain; reset/gap correctness must be proven
  before reusing an estimator or treating its existence as forecast validation.
- [#88](https://github.com/L-K-M/LLimit/pull/88), `feat/cli-surface`:
  `llimit compact`, reset listing, and JSON/CSV `llimit export`. Preserve prompt/export
  concepts without rebuilding these reported commands; verify exact flags first.
- [#91](https://github.com/L-K-M/LLimit/pull/91), `fix/claude-ua-version`:
  cached detected Claude Code version for Anthropic usage UA instead of frozen
  `claude-code/1.0.110`; synthetic sequencing does not prove every CLI version works.
- [#97](https://github.com/L-K-M/LLimit/pull/97), `feat/llimit-check`:
  `llimit check [--below pct] [--stale-hours h]`, exit 1 with reasons for low metrics,
  failures, and stale data; scriptable `llimit check || notify-send` hooks.
- [#98](https://github.com/L-K-M/LLimit/pull/98), `feat/llimit-trend`:
  `llimit trend [--days N]` per-account, normalized, forward-filled sparklines.
  Coordinate with #75: decorative filling is not a new observed sample or forecast
  evidence, and cross-series normalization must not imply comparable capacities.
- [#99](https://github.com/L-K-M/LLimit/pull/99), `feat/llimit-watch`:
  `llimit status --watch [seconds]`, ANSI clear/home repaint following daemon refreshes.
- [#100](https://github.com/L-K-M/LLimit/pull/100), `feat/threshold-alerts`:
  `QuotaAlertEvaluator`, `QuotaAlertSettings`, persisted dedup keys, warning/critical
  band crossings and per-kind failure notifications through
  `UNUserNotificationCenter`, rearming on recovery, Settings → General thresholds.
  Quiet hours, Focus awareness, reset notices, and shared status policy remain.
- AUTO/ESTIMATED badges: reported 8pt text, 0.85-opacity foreground, and explicit
  VoiceOver labels. Full metric/freshness/failure summaries remain separate.

## Boundaries every follow-up must preserve

- Settings credentials stay local; `AppSettings.redactedCredentials()` is required
  for shared settings. Snapshots/history/widgets/status/logs must also have safe
  failure strings and no resolved secrets. Linux display consumers read snapshots,
  never credential settings; preserve existing JSON keys when adding metadata.
- Imports are explicit, copied, LLimit-owned accounts. Optional discovery is not
  runtime ownership. Never substitute a global Claude token for every account.
  Match managed Claude profile UUID and verified account/organization identities.
- Managed Claude/Codex official CLIs own renewal/storage in private profile
  namespaces (`CLAUDE_CONFIG_DIR`/`CODEX_HOME`). Keep directories `0700`, credentials
  `0600`, verified identities, and global/imported/managed provenance separate.
  Acquire exclusive durable operation ownership before launch/read of renewal
  material. Preserve timed-out children and pending records until exit; no ambiguous
  rotating-grant replay, losing-owner cleanup, or deletion of pending namespaces.
  Orphaned Codex records require reconnecting into a fresh profile.
- Keep QuotaCore Foundation-only and low-level I/O behind application services.
  Fix the responsible boundary; no broad architecture rewrite is implied here.
- Color on rings/bars/traces is **limit-window/account identity**, not danger level
  or provider branding. Magnitude is geometry; warnings use reserved accents.
  Preserve `stableAccountOrder`, account variants, full-metric `primaryLimitSlot`,
  exact primary overrides, and compatibility-only legacy `WidgetRingColors`.
  Reorder/disable must not recolor accounts or retarget automatic tile assignments.
- Keep literal placed widget kinds frozen, app-owned slot assignments, nested
  bundles and sandboxed extension. Do not revive unsupported widget Edit/
  `AppIntentConfiguration`; quota/refresh automation intents are a separate proposal.
  Keep slot counts/loops synchronized and widget display text non-formatted.

## Correctness, privacy, and persistence

### C01. Historical failures and structured display boundary [high; partial]

**Evidence:** Baseline `Core/QuotaCoordinator.swift:59-81` copied typed/localized
errors; `Core/Clients/ChatGPTOAuth.swift:41-46` included refresh response text.
`Core/Models.swift:385-421` had only account/provider/kind/message failure fields.
Snapshots/history/log owners persisted those strings. #70 implements safe new
failures; incoming #63 reports excerpt sanitation. Neither reference establishes
migration of existing archives or a widget-specific credential-free projection.

**Work:** Migrate/filter historical errors on every relevant read/export/publication
path; use allowlisted public messages, not raw diagnostic bodies. Add backward-compatible
`failedAt: Date`, safe `httpStatusCode: Int?`, `retryAfter: Date?` from headers, and
safe provider code where justified. Define a bounded widget/display DTO; keep raw
diagnostics transient. Preserve reconnect, unsupported-key, and missing-CLI advice.
Surfaces can then distinguish “failing for 3h” from “retries in 2m.”

**Done:** Legacy snapshot/history fixtures with reflected access/refresh tokens,
unknown token-like values, HTML, controls, and oversized bodies leak nothing through
persisted/display/export/log output. Old Codable records still decode. Typed,
unexpected, OAuth, cooldown/countdown, and recency-ordering cases stay actionable.
Do not reopen #70's completed new-failure implementation.

### C03. macOS unreadable-settings guard [high; Linux retired in #66]

**Evidence:** `LLimitApp/AppModel.swift:120-154,1712-1727` substituted empty defaults
after load failure, then reconciled/saved against empty accounts. Linux counterpart
(`Linux/QuotaDaemon.swift:78-91,525-536`) is in #66.

**Work:** Distinguish unavailable settings from a successfully loaded empty
configuration. Block destructive macOS reconciliation; expose recovery state.

**Done:** Failed bootstrap preserves cached snapshot bytes and performs no
reconciliation writes. Intentionally empty loaded settings still remove obsolete
accounts. Do not rebuild the Linux guard.

### C04. Refresh publication can undo account changes [high]

**Evidence:** `AppModel.swift:199-212,248-271` validated Venice only;
`Linux/QuotaDaemon.swift:271-285,311-320` published captured results without a final
settings read. Remove/disable reconciled or purged during the fetch.

**Impact:** Removed/disabled accounts, old credentials/names, and purged history can
reappear; concurrent purge can lose unrelated samples.

**Work:** Validate the actual queried account revision at each commit; reconcile
current names/enabled IDs. Linux reloads under a short settings-lock publication
section and serializes snapshot/history mutations. Never hold settings locks over
network work; edits remain responsive.

**Done:** Barrier-controlled remove/disable/rename/key-change tests preserve current
configuration and unrelated history. Obsolete usage reaches no persistence boundary.
Settings three-way-merge tests alone do not prove publication correctness.

### C05. Concurrent refreshes lack a cross-process owner [high]

**Evidence:** `Linux/QuotaDaemon.swift:359-374,435-448`, one-shot CLI, and tray/Waybar
refresh clicks can run independently. Claude pending marker was not an exclusive
claim (`Core/ClaudeCodeRenewal.swift:65-94`, `AppModel.swift:1035-1093`). Duplicate
launch windows are source-confirmed; actual server revocation was not observed.

**Work:** Add durable exclusive refresh/per-profile operation ownership before
reading renewal material. Coalesce or report busy operations; keep settings locking
short and preserve uncertain rotating-grant children/markers.

**Done:** Two-process barriers launch one exchange/renewal, prevent older snapshot
overwrite, and keep edits responsive. Losing owners cannot clear winning records
or delete namespaces. Preserve existing managed-Codex operation guarantees.

### C06. Persistence failures can report success [high]

**Evidence:** `Linux/QuotaDaemon.swift:207-215,505-522` swallowed saves and purged
history before committing removal. `AppModel.swift:163-184,550-578,1603-1611`
left edits in memory; Auto-fill could replace save errors with success. Settings
often hides notices. A single `statusMessage` is overwritten by later refresh text.

**Work:** Return explicit durable outcomes. Save settings before destructive derived
cleanup. Roll back failed mutations or expose retryable unsaved drafts. Keep scoped
notices with severity, account/context, timestamp, and recovery action; later success
must not dismiss a durability failure.

**Done:** Inject failures for add/import/edit/enable/remove/Auto-fill. Durable state
stays unchanged, CLI exits nonzero, errors appear beside the operation, uncommitted
removal preserves history, and cleanup failures remain visible.

### C07. Imported OpenAI identity needs workspace and user binding [high]

**Evidence:** `Core/OpenAICredentialSync.swift:36-59` matched workspace/account ID,
not member/user ID; refresh acceptance could replace identity (`AppModel.swift:675-714`,
`Linux/QuotaDaemon.swift:438-448`). Managed Codex already recognizes the distinction.

**Work:** Verify both workspace and user for imported/manual token adoption and
refresh acceptance. Established identity is immutable; unknown identity requires
explicit reimport. Preserve managed-profile isolation and reported #86 references.

**Done:** Reject same-workspace/different-user JWTs and mismatched refresh results.
Same-user fresher tokens remain adoptable; missing identity cannot retarget an account.

### C08. Rotated grants need prompt durability [high]

**Evidence:** Linux proactive renewal batched changes until every account finished
(`QuotaDaemon.swift:258-268,385-406`); save failure was logged, then old credentials
could be reloaded next cycle.

**Work:** Persist each successful rotation before awaiting another account. Retain
unsaved replacement material so reload/retry cannot discard it or replay the old
grant. Report durability uncertainty, not ordinary refresh success.

**Done:** Block B after A rotates; A is already durable. With injected save failure,
the next cycle neither loses the replacement nor resubmits the old grant. Use
synthetic transport/storage, not real OAuth credentials; do not overwrite env references.

### C09. Private persistence needs creation-time and ownership guarantees [high]

**Evidence:** Baseline `Core/SettingsStore.swift:24-32` created unrestricted parents,
wrote atomically, then ignored chmod failure. Snapshot/history requested `0644`.
Incoming #74 reports owner-only atomic snapshot/history writes; credentials and
directory/type/owner guarantees remain separate.

**Work:** Encapsulate private atomic persistence: local credential directory `0700`,
temporary/replacement files `0600`, symlink/wrong-type/wrong-owner validation, final
mode checks, and explicit failures. Use the narrowest functional App Group mode
compatible with sandboxed widgets. Reuse reported #74 mechanics where applicable.

**Done:** First-save/overwrite/permission-failure/symlink/type/owner tests prove no
public credential temporary file and no falsely successful save. Verify replacement
and shared-container access, not only chmod after exposure.

### C10. Cancellation must not become ordinary failure [high]

**Evidence:** `Core/HTTPClient.swift:29-34` wrapped cancellation; coordinator captured
every error. Publication owners lacked a cancellation-before-commit guarantee.

**Work:** Preserve cancellation through transport/client/coordinator, stop retries,
and guard snapshot/history commits. Quota cancellation must not replay or destroy
uncertain official-CLI rotating-grant operations.

**Done:** Cancel a suspending fetch: no new snapshot/history write. Linux shutdown
signals do not replace good usage with shutdown-induced failures. Pending auth
children and durable operation records retain their owner until confirmed exit.

### C11. Recovery and schema evolution [medium]

**Evidence:** Decode failure blocked settings saves without last-good backup/guided
recovery; snapshot versions were unchecked and unknown providers could fail arrays.
Reported #78 quarantine and #79 failable container init do not establish recovery.

**Work:** Versioned envelopes, forward/downgrade policy, atomic last-good backups,
and reveal/export/restore/reset actions. Preserve originals and identify/quarantine
any skipped account records; no silent partial recovery or empty defaults.

**Done:** Truncated/newer/mixed-provider files preserve originals. Test restoration,
downgrade preservation, version validation, backup failures, and visible recovery.

## Providers and account setup

A01/A02 are retired in #69; remaining source-backed items follow.

| ID | Evidence | Scope and acceptance |
|---|---|---|
| A03 | Copilot retries 503 through auth paths then calls it `.auth` (`Core/Clients/CopilotClient.swift:144-158,216-225,274-287`). | Fallback only for verified compatibility statuses. First 503 makes one `.api` request; malformed successful exchange is `.decoding`; preserve 429 and supported auth fallback. |
| A04 | Managed Codex maps decoding/launch/timeout/storage/identity failures to `.auth` (`Core/CodexAccountService.swift:84-106,204-206`). | Map domain failures to sanitized actionable kinds: missing CLI configuration, malformed rates decoding, identity mismatch auth. Preserve every pending-operation guarantee. |
| A05 | Shared metadata blocks distinct imports (`AppModel.swift:583-588`; `Linux/QuotaDaemon.swift:227-235`). | Compare keyed provider-specific authenticators, not intersecting arbitrary values. Different Devin keys sharing a server/Google tokens sharing a project remain importable; identical keys deduplicate. |
| A06 | Any OpenCode Anthropic candidate suppresses ordinary Keychain discovery, even stale/different accounts (`AppModel.swift:501-519`; `Core/CredentialDiscovery.swift:364-367`). | Explicit Claude/all-provider scans include/deduplicate Keychain candidates. Other-provider scans never prompt Keychain. Distinct injected sources both appear. |
| A07 | Antigravity companion discovery ignores custom XDG data roots and returns one of several accounts (`CredentialDiscovery.swift:339-345,403-440`). | Reuse resolved OpenCode roots; enumerate distinct usable accounts without mixing token/project fields. Test custom roots, two accounts, and migration-root duplicates. |
| A08 | One pending OpenAI login blocks every refresh (`AppModel.swift:187-201,778-799,857-872`; `refreshNow` busy guard). | Skip/preserve only busy accounts. Unrelated provider refresh succeeds during browser login; no competing managed-profile request. Give visible waiting/busy feedback rather than a silent no-op. |

### Provider questions requiring sanitized fixtures

Incoming main also reports empty Anthropic recognized schemas, Zhipu responses
without supported limit types, and missing Google fractions treated as zero.
Retain these as validation candidates, not established additional endpoint defects.
Synthetic missing/empty/hostile-number tests should distinguish unknown from zero,
require recognizable success, and keep aggregate usage nil without bounded metrics.
Capture contracts before choosing new endpoint or absent-field semantics:

- Antigravity fixed model catalog and absent/unparseable fractions
  (`GoogleAntigravityClient.swift:18-23,50-79`): exhausted/unavailable semantics and
  current-model omission; missing data is not verified zero.
- Anthropic extra-usage credit-to-dollar scale (`AnthropicClient.swift:109-120`):
  response tied to known billing amount before changing units; private headers.
- Copilot current AI-credit versus legacy premium-request plans, organization scope,
  UTC reset boundaries, and exchanged-token validity for quota endpoints.
- Claude official CLI namespace/renewal compatibility and detected-version UA
  (reported #91); synthetic ordering is not compatibility with every version.
- OpenAI additional limits/credits/`allowed`/reached type/absolute reset fields:
  optional decoding only from captured contracts.
- Zhipu/Z.ai percentages/endpoints and private Google/Anthropic headers.

No additional code-established Venice, OpenCode Go, Kimi, Devin, or Zhipu client
defect warranted speculative API changes in the `tmp.md` review. Reported #81 is
retained without independent validation; provider APIs are undocumented and unstable.

## Performance, networking, and scheduling

| ID | Source-backed cost or risk | Scope and acceptance |
|---|---|---|
| F01 | `Core/QuotaHistoryStore.swift:19-40,55-73` decodes full archives before filtering, sorts twice on append, and caps entries, not bytes. App publication then reloads a two-day slice. | Benchmark 12 accounts/multiple metrics/3,000 entries and 45-day archives: append latency, UI stalls, widget RSS. Publish bounded `quota-trend.json` projection so windowed widget reads do not decode raw archives; downsample before sharing. Consider partitioned/indexed/append-only storage only with preservation tests and measured need. #52/#75/#76 semantics must survive. |
| F02 | Edits/publication synchronously encode/write/reload local/shared stores on `@MainActor` (`AppModel.swift:163-175,274-289,1759-1760,2020-2031`). Only timeline reloads were debounced at baseline; #85 reports edit debounce. | Serialize persistence behind an application service; move encode/I/O off main actor and skip identical redacted writes. Coordinate reported dirty flag/debounce, flush final edits on focus loss/close/termination and before Test Connection/Refresh; auth durability is immediate. Slow-storage tests plus Instruments verify responsive typing/resize and final durability. Earlier 500ms is a tuning candidate, not a durability rule; #85 reports 400ms. |
| F03 | Stores retain codecs under `@unchecked Sendable`; append/purge is unlocked read-modify-write and baseline corruption blocked future appends. | Operation-local codecs and serialized logical mutations; coordinate cross-process writers. Reuse/check reported #78 quarantine rather than rebuilding it. Concurrent append/purge, truncation/schema mismatch, and replacement failure preserve unrelated data and corruption evidence. |
| F04 | Metric rebuilds scan snapshots/accounts/metrics; hover/resize/minute ticks can repeat work; both dashboards use eager cards (`LLimitApp.swift:416-442,557-562,633-668,1397-1440`; `ProviderQuotaCard.sparkPoints`/`SparkSeriesBuilder.points`). | Precompute immutable `[accountID: [metricID: [SparkPoint]]]` on history changes, hoist lookups, and profile before lazy-card changes. Hover/resize must not rebuild unchanged series; moving windows stay correct. No measured stuttering claim. |
| F05 | `Core/HTTPClient.swift:14-28` uses shared URLSession, unbounded buffered bodies, request-only timeout, and one coordinator task per account; URL codes/cancellation collapse. | Dedicated ephemeral session with cookies/cache off, resource deadline, streaming body cap, host connection/concurrency bounds, preserved URL codes/cancellation. Test slow/oversized/many-account cases. Centralize verified transient classes (408/425/429, provider-specific 403, selected 5xx), Retry-After/GitHub rate headers, and a small jittered read-only retry budget. Never replay ambiguous OAuth exchanges. |
| F06 | A 29-minute-old snapshot with a 30-minute interval sleeps another 30 minutes after restart (`Linux/QuotaDaemon.swift:336-351,579-592`); manual refresh has no shared deadline. | Schedule from last attempt/success and remaining due time; inject clock/sleeper. Refresh fixture after one minute, overdue data immediately. Coalesce manual refresh/wake/network return, jitter/cooldown; suspend with no configured accounts. |
| F07 | Trend entries retain raw history/build all arrays before 240-point cap; tiles generate up to 37 entries for static states (`QuotaTimelineProvider.swift:5-10,55-68`; `ProviderQuotaWidget.swift:183-209`). | Compact projection, one entry for static states, explicit changing-state boundaries. Measure archive/render/RSS. Value sharing means 37 entries do not prove 37 deep heap copies; dashboard timeline already has one lightweight entry. |
| F08 | Transient App Group failures can leave display stores incomplete; reported #79 avoids a nil-container crash but does not repair publication. | Reconcile redacted settings/latest local snapshot at bootstrap; bounded retries and affected-timeline reload after repair. Inject transient failure; recover without another credential edit and expose load failure while unavailable. |
| F09 | Venice intermediate key edits can purge/rewrite the whole archive (`AppModel.swift:1601-1638`); reported #68 defers invalidation and fingerprints estimates. | Retain draft/commit semantics or clear old-key display state immediately, then purge once per committed replacement. Verify #68 before further debounce work. Typed/pasted key plus large archive: no per-character purge, no old estimate on new key, correct in-flight rejection, durable final edit. Paste is not established as 32 updates. |
| F10 | `AppModel.primaryColorsByAccountID` (`:1462`) constructs `currentSettings()`/all account styles per access across view bodies. | Profile, then memoize by account/style revision. Rename/reorder/enable/style changes invalidate the right projection; unrelated hover/state changes do not rebuild settings or alter stable identity. |

## Linux display, installation, and convenience

L01 is retired in #66. Baseline findings below must be reconciled with reported
#50/#51/#64/#88/#97–#99 before implementing overlapping behavior.

| ID | Evidence | Scope and acceptance |
|---|---|---|
| L02 | Cached failures can remain `class: ok`/“Updated just now”; failure alone need not mark stale (`Linux/StatusRenderer.swift:28,125-134,162-183`). | Fetch health from current failure IDs and per-account source age, not attempt time. Model last attempt/success/current failure/stale age consistently. All-failed cached data is error; partial failure visible; ID/name distinguishes same-provider accounts. Preserve JSON keys and snapshot-only reading. #64 reports partial escalation; #50 reports interval-aware staleness. |
| L03 | Tray hides spending warnings/errors when cached accounts exist (`Packages/LLimitd/tray/llimit_tray.py:138-159,301-304`); in-memory probes reproduced both. | Check reported #64, then expose remaining partial/auth/spending failures independent of account presence. Consume additive structured errors compatibly; preserve cached metrics/actions and safe full tooltips. |
| L04 | Reset strings freeze at fetch time (`StatusRenderer.swift:38-39,92-93`). | Reconcile reported #50 rather than rebuilding it. Advance time without fetching: human/JSON/tray countdown decreases, expired dates say reset due, whitespace-only legacy strings disappear. Threshold stays aligned with daemon interval; consider `--stale-after` only as a scoped contract change. |
| L05 | Installer `enable --now` does not replace an active daemon/tray (`Packages/LLimitd/systemd/install.sh:44-49,64-76`). | Restart active services after replacement/reload. First-install/upgrade fixtures verify running PID/version and optional tray behavior. |
| L06 | Installer ignores custom XDG config roots, emits unquoted home paths, and raw sed replacement mishandles `&` (`install.sh:44-49,59-61`). | Resolve valid XDG roots and properly quoted systemd argv. Test spaces, `&`, absolute/relative/unset XDG and exact executed paths. |
| L07 | `.deb` makes trust roots optional (`Packages/LLimitd/packaging/build-deb.sh:85-92`). | Depend on `ca-certificates`. Minimal install without recommendations reaches HTTP responses rather than TLS trust failure. Inspect control metadata and shipped binary. |
| L08 | README `install.sh -- --timer` is rejected by parser (`Packages/LLimitd/README.md:89`; installer:22-26); rejection reproduced pre-install. | Correct the documented command and execute that parser path successfully. |
| L09 | No in-place rename/update; noninteractive secrets use `--set` argv. | Transactional `llimit accounts set <id> [--name …] [--set key=value …]` under settings lock, plus stdin/file-descriptor secret input. Preserve IDs/history/tile slots, invalidate key-dependent estimates, keep secrets out of argv/history/diagnostics; inject durable-save failures. |
| L10 | Release hardcodes amd64 and does not smoke-test packaged binary (`build-deb.sh:89`; release workflow:123-133). | Fixture-XDG artifact smoke checks, then ARM64 if scoped. Validate binary/dependencies/units and GTK-free tray output; exercise installed CLI flags, not only source tests. |
| L11 | Incoming main proposes `--version`, `accounts list --json`, daemon `--quiet`, and cross-account severity/recency failure order; #64 reports per-account ranking only. | Embed release version; stable credential-free account metadata, clean JSON stdout/quiet daemon output. Test ordering with C01 timestamps and isolated fixtures; preserve documented machine contracts. |
| L12 | Amount-only tray accounts lack headline; reset radar has no dedicated tray section at baseline (`format_account_header`). | Display reported amount without percentage; integrate reported #51 radar. Test credits-only Cline, missing data versus empty schedule, absolute reset ordering and stale labels. |

## macOS usability, visuals, and accessibility

| ID | Evidence | Scope and acceptance |
|---|---|---|
| M01 | Empty state promotes ineffective Refresh; old failure-free snapshot can say “All accounts reporting” after adding unqueried accounts (`LLimitApp.swift:621-622,733-843`). | Derive account coverage/readiness/freshness; first-account action and scoped recovery notices. Fixtures: absent/disabled/incomplete/new/stale/busy accounts; no false all-reporting or silent no-op. |
| M02 | Baseline controls have empty semantic labels and menu graph exposes only “LLimit” (`SettingsView.swift:361-377,494-507,582-593,890-950,1121-1150`; app:169-171). | Coordinate reported #56 labels; fill remaining tile/color target/menu quota-summary gaps. Native AX/VoiceOver verifies distinct roles/names/values without surrounding-text navigation. |
| M03 | Settings loses estimate qualifiers and prints `--` for valid amounts (`SettingsView.swift:730-740,1294-1307`). | Shared presentation for reported/estimated percentage, amount, unlimited, unknown. Cover estimated Venice, `$4.25`, unlimited/absent values; never invent balance percentages. |
| M04 | Zero alpha serializes as nil and restores automatic opaque background (`AppModel.swift:1350-1356,1832-1842`). | Explicit transparency state; nil means automatic. Zero/partial/full alpha survives reload for global/widget/account controls; automatic and clear swatches differ. |
| M05 | Calculated nominal small-text contrast 3.77–4.02:1; Crazy Banana white-on-base about 2.03:1 (`LLimitApp.swift:242-250,521-525,1561-1577`; `WidgetStylePreset.swift:169-183`). | Raise essential small-text/bright-surface chrome contrast while preserving metric hues. Target 4.5:1 small text; capture actual normal/hover/bright/high-contrast pixels before native-ratio claims. |
| M06 | Reduce Motion gates rings, not bar springs/jump scrolling (`LLimitApp.swift:307-339,398,644-646`). | Apply preference consistently. Native geometry/scroll changes become immediate; ordinary animation remains available. |
| M07 | Preset matching compares legacy ring fields that no longer drive rendered metric colors (`WidgetStylePreset.swift:299-317`). | Match rendered properties, show affected longest window and real tile preview. Current/custom follows actual appearance; one-action reset to global. |
| M08 | Direct mutable `LimitKindColors` assignments bypass initializer normalization (`sessionHexColor`, `otherHexColors`); #53 reports defensive `matching` rebuild. | Canonical writes with existing normalizer; consider setters before widening visibility. Test lowercase/short/invalid assignments, uppercase canonical output and round trips; retain legacy matching behavior and validated palette. |
| M09 | System appearance alone does not validate a graphite light-surface palette. | Coordinate reported #73; validate text/hairlines/tracks/status accents/transparency on actual light/dark surfaces. Window identity remains separate from provider branding. |
| M10 | `WidgetVisibilitySettings.showResetInfo` is persisted but unused; `resetSummaries`/`dashboardBarPercents` reported dead (`Core/Models.swift`; widget). | Verify consumers; expose scoped reset preference or deliberately retire compatibility field. Delete only proven-unused helpers; retain round-trip compatibility and current reset presentation. |
| M11 | Color alone remains a state channel in sidebar/provider dots and summary controls; incoming main groups rings/menu bars with them. | Add check/warning/exclamation or textual/AX equivalents, honoring Differentiate Without Color. Keep identity-colored rings/menu bars as identity, not status; reserved accents carry danger. Extend reported #56 pattern with one state enum. |
| M12 | Literal `INF`/`--` appear in Settings/widgets/tray; incoming main reports no localization infrastructure. | Localized Unlimited/Unknown and semantic equivalents; String Catalog as a bounded project. Test hidden percentages/localized long labels without changing amount/unknown semantics. |

### Native layout/lifecycle hypotheses, not reproduced defects

- Fixed 180-point labels, split minimums, and nested Appearance rows
  (`SettingsView.swift:20-36,997-1017,1090-1099`): render 720×480 with long/localized
  names and larger text. Stack only failing rows with adaptive Grid/Form/
  `ViewThatFits`; every action remains reachable. Source widths do not prove clipping.
- Sign-in sheets: terminal minimum 820×550 exceeds Settings minimum; Codex width 520.
  Verify fitting, focus, and reachable actions on the visible display.
- Settings autosaves then centers (`LLimitApp.swift:62-65`): verify restore,
  hide/minimize/reopen/display-removal before changing lifecycle.
- Canceled detach may retain `hasDetached`/`suppressOpen` (`LLimitApp.swift:1129-1165`):
  cancel, close/reopen, then detach; change only if stuck.
- Test both resize grips, frame/content geometry, remembered-size clamping, display
  changes, and wide overview density with few accounts.
- Menu icon formula `count * 3 + (count - 1) * 1.5` implies ~52.5 points for twelve
  accounts; older 50–70-point estimate is not a native layout measurement. Non-template
  pale bars may wash out on light menu bars: test notch/display and Increase Contrast/
  Reduce Transparency before claiming crowding or poor contrast.

## Widgets and chart integrity

W01/W02 and dashboard W03 are retired in #72; C02 observation semantics are retired
in #75. Remaining load, sampling, forecast, and rendering work follows.

| ID | Evidence | Scope and acceptance |
|---|---|---|
| W03 | Tile/trend store failures can collapse into no-account/empty states (baseline timeline:71-90; `ProviderQuotaWidget.swift:288-303,557-568`); reported #79 makes one init failable. | Preserve explicit load outcomes for tiles/trend: no accounts, awaiting data, all-failed, stale, storage/App Group unavailable. Recovery advice must not invite duplicate accounts. Inject absent/corrupt/inaccessible container/settings/snapshot/history states; no false “No accounts configured.” Dashboard portion is in #72. |
| W04 | Base/deep/pale repeats after three accounts, dash patterns restart per account, and tiles are trend legend (`Core/ProviderMetricSelection.swift:168-170,194-204`; widget:815,851-868). | Stable central non-color account tags/pattern identity; validate any broader color design. Four/twelve/coincident/grayscale/custom-identical-color accounts remain traceable. Increasing modulus fails: higher steps all become pale. Rename/add/reorder/disable must not retarget identity. |
| W05 | Uniform `downsampleTrendPoints` loses zero at index 120 when 241 points become 240 (`LLimitQuotaWidget.swift:930-945`). | Chronological extrema-preserving buckets, endpoints/reset transitions, bounded output. Retain fixture's zero and short refill spikes; source-time observations survive display sampling. |
| W06 | `depletionWarnings` uses display-decimated last eight points across resets and `remainingPercent <= 60` gate (`LLimitQuotaWidget.swift:838-879,964-995`). | Estimate from fresh current-reset-segment observations before display sampling, with defined horizon/confidence. 10% pre-reset → 100% reset → 20% now warns about current depletion; stale/gapped/single-point data is not confident. Coordinate reported #87 before converging estimator implementations; correct semantics first. |
| W07 | Trend AX only “Quota trend chart”; hiding percentages loses dashboard numeric semantics; literal `INF`/`--` (`widget:130-143,207-235,520-534,1050-1065`). | Presentation-independent account/metric/value/reset/freshness/failure spoken summaries; hide decoration. Hidden percentages retain numeric semantics and named unknown/unlimited. Native traversal required; reported badge labels do not close this. |
| W08 | Light/custom backgrounds retain white/faint text/weak scrims (`ProviderQuotaWidget.swift:479-500,571-587,735-738,819-836`; trend:184-199). | Luminance-aware neutral chrome or controlled scrim, preserving identity hues/primary overrides. Capture white/black/saturated/transparent/high-contrast surfaces. |
| W09 | Tile last entry may precede stale threshold; delayed reload freezes “Data is current”/countdown (`ProviderQuotaWidget.swift:176-211,610-622,671-679`). | Explicit stale/reset boundary entries beyond requested reload and honest cached age. Inspect timeline without extra provider calls; verify delayed native delivery. macOS delay frequency is unmeasured. |
| W10 | “Unlimited plans only” means any unlimited metric was seen, even with unknown premium quota (`widget:124-125,745-762,908`). | Distinguish all-explicitly-unlimited from mixed unknown/non-chartable; unknown premium plus unlimited chat never says unlimited-only. |
| W11 | Dashboard/trend impose 72% alpha while tile/shared parsers retain RGBA (`widget:1092-1096`; tile:887-892; shared:161-165). | One tested component/background contract. Consolidate `normalizeHexColor`, `rgbaComponents`, `Color(providerTileHex:)`, `backgroundBaseColor`, `AppModel.parseHexColor`; do not add another parser. Transparent/quarter/half/full alpha matches before intentional effects. |
| W12 | Incoming main requests current-value/time/percentage context and multiple relevant trend warnings when space permits. | Add bounded summaries from corrected observations without obscuring traces. Fixture sparse/dense/multiple-warning layouts; disclose omitted warnings, retain unknown/freshness and accessibility context. |

### Widget visual/runtime checks

- Medium dashboard attempts up to twelve rows plus header/footer/padding without
  geometry-derived capacity. Render 1/2/6/12 accounts, dual values, failures, enlarged
  text; derive capacity, avoid fixed-width clipping, disclose omitted accounts.
  Consider medium tiles/`.systemLarge` dashboard only after overflow work; freeze kinds.
- Inspect 6.5-point axes and 7-point tile badges at actual desktop scaling.
- Segment gap-spanning solid paths and uncertain refill timing; a later observation
  does not establish continuous measurement or an exact reset instant.
- Validate auto-mapping, pinned assignments, `#N AUTO`, palettes, and source-account
  identity in installed tiles. Test light/dark/tinted/monochrome desktop presentation,
  Differentiate Without Color, Increase Contrast, Reduce Transparency/Motion, long
  names, every quota state, and maximum archives.
- Existing screenshots show cohesive rings/cards but dense traces, tiny axes, and
  prominent warnings. They are aesthetic context, not verified current pixels.

## Build, release, and documentation

1. **Widget-capable distribution [high].** `.github/workflows/release.yml:37-54`
   disables signing then ad-hoc signs without local entitlement/notarization gates.
   Scope Developer ID/provisioning, matched monotonic app/extension versions, hardened
   runtime, notarization/stapling and clean-Mac shared-data validation. Gate nested
   signatures/entitlements/architectures/Gatekeeper; unsupported smoke artifacts must
   not claim functional widget distribution. Preserve installed-only LaunchServices
   registration, recursive cleanup, `chronod` and NotificationCenter restart gates.
2. **Executable docs [medium].** `RELEASING.md:58-79` describes absent dispatch and
   secret-driven signing; README omits release stub's `--push`; `CICD.md` omits Linux,
   tray, and review workflows. Reconcile exact commands with parser/artifact checks.
   Retire resolved backlog entries without deleting remaining evidence.
3. **Focused CI [medium].** Select supported toolchain before tests, remove duplicate
   Core runs, check XcodeGen drift, pin relevant Actions/tooling, add meaningful
   lifecycle/rendering/concurrency/artifact gates. External `lkm-build`/`lkm-release`
   need pinned/bootstrap contract; generated project embeds local signing config.
   Portable tests do not prove native UI/live OAuth. Acceptance: relevant platform,
   options, and produced artifacts are exercised, not unrelated green jobs.
4. **Strict Swift migration [low].** Static/Sendable comparator, modern async test
   synchronization, then opt-in strict CI. No broad MainActor isolation to silence
   diagnostics; declared-language builds must stay green.
5. **Repository support [low].** Document vulnerability reporting/unsandboxed access,
   contribution/ownership/lint conventions; ignore result bundles/private signing
   material. Changelog/dependency updates already exist. Checksums/attestations and
   tested-main release gating are scoped release follow-ups, not new global policy.
6. **Provider metadata [low; optional consolidation].** Six exhaustive switches
   (`Models.displayName`, `credentialFields`, `ProviderMetricSelection.defaultRingMetrics`,
   widget `compactProviderName`, `ProviderTile.palette`, `ProviderMark.symbolName`)
   duplicate names/credential descriptors/default metric IDs/presentation identifiers.
   Preserve the proposed `ProviderDescriptor`/`ProviderMetadata` idea, but migrate one
   genuine duplication at a time. Foundation data may live in Core; rendering stays
   in UI. Provider brand metadata is not `LimitKindColors` window/account identity.
   Tests cover every provider, labels/defaults/icons/colors, and incomplete registration.

## Product, aesthetics, and useful delight

Proposals, not regressions. Check reported implementations first, then choose one
bounded follow-up with its acceptance condition; do not rebuild recorded features.

- **Guided first account:** explicit import/managed sign-in, source/account chooser,
  provider help, Test Connection, verified completion, in-place reimport. Setup works
  without README/surprise scan; complete credentials are not called verified.
- **Fast management:** search/filter/groups when needed, targeted refresh, snooze,
  reversible removal/confirmation/Undo, explicit visibility. Stable IDs/styles/history
  survive; cleanup, credential provenance and expiry consequences are clear.
- **Live theme preview:** tile/dashboard row/trend alongside controls; explicit
  system/solid/pattern/transparent backgrounds and reset-to-global. Preserve primary/
  window authority; accessible neutral chrome. Retain Catppuccin Mocha (rosewater/
  mauve/sapphire/dark slate), Nord (frost/snow/polar night), Tokyo Night (indigo/neon),
  Monokai Pro (amber/magenta/cyan/charcoal), coordinated with #53 palettes. Begin with
  surface treatments; palette/formula changes require contrast/CVD validation on
  graphite `#1D1F27` and widget blue `#5994F2`, not visual guesswork.
- **Quiet hierarchy:** consistent spacing/baselines/tabular numbers; name/value first,
  readable reset/age second; restrained stripes/gloss/reserved warnings. Controlled
  size/state/name captures have no clipping and respect accessibility.
- **In-app history/export:** reset/gap markers, selection/comparison, keyboard
  inspection, retention, credential-free CSV/JSON with source timestamps. Large
  archives do not block UI. Coordinate reported #88; retain
  `llimit export --format json|csv [--days 30]` as the original proposal, verify actual
  flags, and add Settings → General Export History. Quota deltas are not actual token
  consumption/cost without reported units; export privacy preview is explicit.
- **Reliable notices:** build on reported #97/#100, not new threshold engines.
  Opt-in low-quota/reset/reconnect notices, crossing dedupe, rearming, quiet hours,
  Focus awareness, stale suppression, Linux desktop/headless hooks. Warning/critical
  remaining thresholds (earlier 30%/15%) have valid ordering and shared status policy;
  unknown/stale data never crosses a band, offline failures do not spam. Thresholds
  drive reserved warning accents/status class, never identity ring/trace recoloring.
- **Help and updates:** About/build/version, launch-at-login approval, provider help,
  localization, redacted diagnostics preview/export, verified signed/Sparkle-style
  update path after signing/notarization. Explain host-running widget refresh needs.
- **Expiring headroom:** fresh comparable allowances resetting soon, actionable
  account links and uncertainty. Never rank dollars against percentages.
- **Runway/burn-rate chip:** coordinate #87, then expose safe estimator on status,
  tray, and widget rather than duplicate math. “At this pace, about 3 hours left”
  needs enough fresh reset-segmented observations/confidence; gaps suppress, resets
  restart. Correct W06 before moving existing math into a chip.
- **Focus-session receipt:** explicit Start/Stop reports per-account quota deltas
  with reset/estimate caveats; no extra inference calls or activity surveillance.
- **Quota passport:** one accessible clean handoff/chat summary of quota/reset/source
  ages; no credentials/emails, unknown remains unknown.
- **Reset radar/navigator:** coordinate #51/#88; chronological absolute server resets
  with account links and reported/estimated labels. Add “Next resets” to macOS
  dropdown/dashboard and tray; missing data differs from empty schedule, passed
  dates stay reset due until replenishment is observed.
- **Pacing guide/ring:** opt-in faint weekly/monthly comfortable-pace marker and
  explicit target date. “Ahead of pace” versus “On track” uses elapsed/consumed
  within known window (earlier example: 20% elapsed, 70% consumed). No invented
  start dates/totals or identity recoloring.
- **Observed reset receipt:** “Refilled 09:12” only after verified replenishment;
  optional restrained tick/ring bloom respects Reduce Motion. Reported #82 is
  countdown anticipation, not this receipt; no looping widget animation required.
- **Coverage rail:** neutral observed/missing-period strip, honest gaps and accessible
  explanation, without repainting identity traces.
- **Recovered-capacity marker:** neutral recent-minimum ring tick from compact
  published statistics; tiles still never load raw history.
- **Calm/menu mode:** quieter texture/typography, collected notices, bounded menu
  width with useful tooltip/AX. Offer current multi-bar, most-constrained single bar,
  fixed-width gauge/battery (earlier 18pt candidate), monochrome template/badge.
  Validate notch/light/dark/accessibility; hidden percentages retain health semantics.
- **Availability/recommendation map:** coordinate #59 overview; extend menu tooltip,
  snapshot-only status/JSON or optional `llimit recommend`. Rank fresh usable
  comparable headroom with reset proximity/spending blocks and disclosed uncertainty;
  unlike window percentages are not equal capacities. Never silently switch tool login.
- **Menu/tray sparkline:** optional bounded-width 24-hour constrained-account series;
  coordinate reported #98, preserve corrected observations/source gaps and normalization
  context. CLI forward fill must not become forecast evidence.
- **Honesty mode:** readable verified/inferred/estimated/stale/unknown across app,
  widgets/status, using shared semantics rather than more identity hues. Show last
  attempt/success/failure; count only fresh covered accounts in health claims.
- **Automation companions:** quota/read/refresh Shortcuts, tmux/Raycast/Stream Deck
  hooks consume credential-free snapshots. Coordinate #88/#99 compact/watch commands;
  retain `llimit prompt`/`llimit status --compact` as original proposals, optional
  ANSI `[Claude: 84% | GPT: 62%]`, not mandatory aliases. New providers require
  explicit auth/API maintenance scope, not guessed endpoints.
- **Quota weather:** coordinate #58 header; extend per-account copy/Linux surfaces,
  uncertainty and configurable policy. Earlier clear/cloudy/showers/storm examples:
  all >50%, one <30%, multiple constrained, verified exhaustion/rate limit. Stale/
  unknown is explicit; playful copy is not an untested forecast.
- **Quota roulette/quick pick:** optional button/`llimit pick` among fresh usable
  accounts above configurable headroom (earlier 60%); show eligibility. Never select
  stale/blocked/unknown accounts or silently change login.
- **What changed delta:** subtle up/down change on macOS/tray from previous real
  observation. Reset/estimate/key-change caveats and no change for carried stale
  values; current snapshot comparison alone must not invent measured consumption.

## Retained review lessons and stale findings

- `BACKLOG.md` is historical input. Its CI outage, global Claude-token replacement,
  automatic Settings scan, provider-unaware dashboard metric pairing, and cloned
  dashboard timelines are outdated; do not resurrect those tasks.
- `SettingsView.accountDataStatus` already checks current failure before carried
  usage. `QuotaTimelineProvider` already publishes one lightweight entry with
  `.after(nextRefreshDate)`. Static tile entries/raw trend payload are separate F07 work.
- Percentage visibility is dashboard-only at baseline: tiles do not read
  `showPercentageValues`. Clarify the label or deliberately extend scope; do not
  assert tile support. Dead reset helpers/unused visibility field remain M10, not done.
- Missing snapshot is not empty reset schedule; stale radar is not a fresh all-clear.
  Whitespace-only `resetIn` disappears in human/JSON/tray paths.
- No-op append still enforces retention. Sparse entries are source observations,
  not necessarily complete state at publication; compare #52/#75/#76 before changing
  archives. Publication timestamp folding and forward fill cannot create samples.
- One enum owns state rendered by color and AX. Compare underlying reset times,
  not a cross-module sentinel string.
- Shared `ISO8601DateFormatter` needs synchronization on corelibs; use supported
  value-type `ISO8601FormatStyle` or operation-local instances. Sorting needs a total
  comparator; Swift `sorted` does not supply stable tie behavior.
- Existing validated colors, full-metric slots, account provenance, and frozen widget
  kinds are constraints, not opportunities for speculative redesign.

## Suggested follow-up order and handoff

1. Reconcile overlapping reported implementations with the six open slices before
   choosing code work, especially #63/#70, #52/#76/#75, #54/#72, and #87/W06.
2. Prioritize remaining auth/publication/durability/cancellation boundaries C03–C10,
   historical/structured failure C01, and recovery C11. Unrelated green tests do
   not prove these invariants.
3. Measure and bound F01–F05/F09; compact widget projection, serialized persistence,
   and cached series before storage redesign. Verify scheduler F06 and repair F08.
4. Choose focused freshness/notices/accessibility, transactional Linux account edits,
   installer/TLS/artifact checks, and tile/trend load states using their fixtures.
5. Menu modes/light chrome/presets/optional metadata and novel features follow honest
   observations and forecast correctness. Signing/provider fixtures gate release claims.

The coordinating agent owns CI/GLM monitoring, final PR/status reconciliation, and
publication of this document. `tmp.md` records an original GLM exit target of two
rounds without applicable important findings or the requested timeout; no completed
round or approval is inferred here. Feature PRs remain open per the handoff. Retain
`tmp.md` until final `ANALYSIS.md` is pushed to main.
