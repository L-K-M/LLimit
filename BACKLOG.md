# LLimit Backlog

Consolidated from the repository reviews and reconciled against `main` at `bac7666` on
2026-07-17. This is the maintained list of unresolved work only. Completed findings and
superseded implementation plans have been removed.

Provider APIs in this document are mostly private or unstable. Any provider behavior marked
for verification requires sanitized live fixtures and request-contract tests before an
implementation change is merged.

## Current validation state

- The last recorded `QuotaCore` run passed 65 tests on Swift 6.0.3/Linux.
- Widget sources passed syntax parsing. Recorded local widget testing used Xcode 17F113 and the
  macOS 26.5 SDK.
- GitHub macOS jobs most recently failed before checkout with no runner assigned. Restore the
  jobs before treating their red status as code-quality evidence.
- AppIntent extraction and widget descriptor registration work locally. Widget-side
  configuration proved unusable across builds 7-13 and was replaced by static slot tiles
  (build 14+), which still need clean-install runtime validation.

## Release blockers

### Signed, widget-capable distribution

Official artifacts are built without signing, then ad-hoc signed without the App Group
entitlements needed by the app and widget. The downloadable build therefore cannot reliably
deliver the product's primary widget feature.

- Sign the host and embedded extension with Developer ID identities and matching App Group
  provisioning.
- Enable hardened runtime, notarize the distributed artifact, and staple the ticket.
- Carry the existing local bundle checks into the release gate: matching app/extension
  versions, nested signatures, widget sandboxing, matching App Group entitlements, AppIntent
  metadata, and the current provider widget kind.
- Also verify architectures, hardened-runtime flags, `codesign --verify --deep --strict`,
  `codesign -d --entitlements :-`, and Gatekeeper with `spctl` on a clean Mac.
- Make signing and notarization fail closed. Do not silently publish an ad-hoc fallback as a
  functional release.
- Until this is complete, label downloads as non-widget smoke builds and state clearly that
  no widget data-sharing fallback exists.
- If unsigned smoke builds remain a product requirement, explicitly evaluate whether a secure
  non-App-Group snapshot channel is viable; otherwise document that it is unsupported.

### Failure-data redaction boundary

Provider clients can place complete HTTP response bodies or arbitrary localized errors in
`ProviderFailure.message`. Snapshots and history persist that text into the App Group, where it
can expose reflected account data, credential-like values, HTML, control characters, or large
payloads to the widget.

- Persist structured failures only: kind, safe HTTP status, retry time, provider code, and a
  short allowlisted user message.
- Keep raw response diagnostics transient and outside snapshot, history, logs, and widget data.
- Redact every configured credential value at the coordinator boundary as defense in depth.
- Strip control characters and cap all persisted message fields and response diagnostics.
- Introduce a minimal widget snapshot DTO that excludes detailed errors, credentials, email
  subtitles, and unrelated account data.
- Add serialization tests proving tokens and token-like reflected values never cross the App
  Group boundary.

### Honest OAuth ownership

Copied rotating or short-lived OAuth credentials do not become independent grants merely
because LLimit stores them. Source tools and LLimit can invalidate one another's refresh tokens,
and the product currently claims stronger credential ownership than the implementation offers.

- Prefer first-party LLimit authorization flows that obtain distinct grants.
- Otherwise model accounts explicitly as linked-source accounts and make one local source
  authoritative.
- Classify credentials as static, first-party OAuth, or linked-source. Expose source, expiry,
  renewal, reauthorization, and removal consequences in the UI.
- Never describe linked credentials as independent or safe after removing the source tool.
- Make rotated-token persistence transactional and fail visibly if durability is uncertain.
- Validate account identity before replacing access or refresh credentials.
- Handle expired, revoked, reused, mismatched, and `invalid_grant` refresh states separately.
- Do not replace refresh or durability failures with a generic "use a ChatGPT token, not a
  platform API key" diagnosis.
- Decide whether manual OpenAI OAuth accounts are supported. If so, expose an optional secret
  refresh-token field; otherwise direct users to a first-party or linked-source flow.
- Always offer an Update/Re-import action even when immutable metadata such as `account_id`
  matches an existing account.

## Data correctness

### Fresh, stale, failed, and unknown state

Last-known usage is carried after a failed poll, but aggregate snapshot time is still presented
as if all accounts succeeded and carried values are appended as new trend observations. The menu
dashboard now shows per-account fetched age and marks failed carried values as last known; the
remaining surfaces and history semantics still need one shared model.

- Add explicit per-account last-attempt, last-success, freshness, and current-failure state.
- Show stale age in Settings, static dashboard, trend, and provider tile.
- In Settings, check current failure before reporting that carried usage is loaded successfully.
- Count only genuinely fresh providers in refresh summaries.
- Define one shared stale-data TTL and suppression or de-emphasis policy; replace the provider
  tile's local display-only heuristic.
- Append only fresh observations to history, or deduplicate by
  `(accountID, metricID, fetchedAt)`.
- Timestamp trend points with `ProviderUsage.fetchedAt`, not aggregate `generatedAt`.
- Segment trend lines and forecasts around resets, stale periods, and missing intervals.

### Settings recovery and schema migration

Unreadable settings no longer silently decode as an empty account list, but recovery remains
manual and persisted formats do not have a complete migration policy.

- Write a last-known-good backup before atomic replacement.
- Add a versioned settings envelope and explicit forward and downgrade migrations.
- Offer a visible recovery flow to reveal the source, restore a backup, export unreadable data,
  or explicitly reset.
- If lossy per-account recovery is added, quarantine skipped raw records and identify them.
  Never silently discard them.
- Validate `QuotaSnapshot.version` and define unsupported-version and downgrade behavior.
- Complete migration of legacy provider-keyed history and any remaining stored records to stable
  account UUIDs, then remove sole-account/provider-key fallback reads.

### Cancellation and account-edit races

Cancellation can become a normal provider failure, and refresh results can be persisted after an
account is edited, disabled, or removed.

- Preserve `CancellationError` and `URLError.cancelled` through HTTP, clients, and coordinator.
- Check cancellation immediately before snapshot and history persistence.
- Return an unsaved result from `RefreshService`.
- Track a configuration revision and discard or filter results when it changes.
- Cancel active account work on credential, enablement, and removal changes.
- Revalidate enabled account IDs immediately before every persistence boundary.
- Add suspending-client tests proving canceled and obsolete work cannot write data.

## Credential security

### Enforce local permissions

The credential-bearing settings store applies `0600` only after replacement and ignores chmod
failure. Parent directories are not explicitly restricted, while snapshots and history request
`0644` despite containing account metadata.

- Create the local LLimit directory with mode `0700`.
- Ensure temporary and replacement credential files are `0600` before exposure.
- Verify regular-file type, owner, and final mode after replacement.
- Treat permission or ownership verification failure as a save failure.
- Use `0600` for local snapshot/history and the narrowest functional App Group mode.
- Add first-save, overwrite, wrong-owner/type, and permission-failure tests.

### Claude account provenance and recovery

The current workaround can apply one local Claude token to every enabled OAuth-like Claude
account. File discovery wins before the often-fresher Keychain, and provenance is inferred from
a token prefix rather than a source identity.

- Store source stable ID and source account identity on every linked account.
- Refresh only the account tied to that exact source; never infer provenance solely from an
  `sk-ant-oat` prefix.
- Compare expiry metadata and choose the genuinely freshest credential, preferring Keychain
  when timestamps cannot distinguish candidates.
- On an Anthropic authentication failure, re-read only the linked source and retry once.
- If LLimit implements its own Anthropic refresh grant, first verify the live OAuth endpoint,
  client identity, rotation behavior, and persistence contract.
- Remove the README and diagnostic command that redirects a Keychain secret into a plaintext
  credential file. If export instructions remain, require `umask 077` and explicit mode `600`.
- Never trigger a surprise Keychain prompt during background refresh.

### Optional Keychain-backed storage

Offer Keychain as an opt-in LLimit credential store while retaining an understandable local-file
mode. Define migration, backup, export, recovery, and headless behavior before implementation.

## Storage and performance

### Replace whole-file history archives

The static dashboard no longer loads history, but the trend path decodes the complete archive
before filtering. Every append still loads, filters, sorts, and rewrites full local and App Group
arrays.

- Prefer SQLite, append-only records, or day-partitioned files with indexed timestamps.
- Maintain a compact, already-windowed widget trend DTO.
- Enforce byte-size as well as entry-count retention.
- Downsample before data crosses into WidgetKit.
- Preserve append order rather than sorting multiple times per append.
- Move encoding and file I/O off `@MainActor`.
- Add large-archive peak-memory and append-latency benchmarks.

### Synchronize stores and recover corruption

Stores claim `@unchecked Sendable` while sharing codecs and performing unlocked read-modify-write
operations. Concurrent appends can lose data, and a malformed history array permanently blocks
later appends.

- Serialize in-process access with actors or explicit locking.
- Coordinate cross-process file access where read-modify-write remains necessary.
- Create codecs per operation or otherwise prove codec synchronization.
- Quarantine corrupt archives and seed a new store from current data.
- Use a record format where one malformed entry does not invalidate all history.
- Add concurrent append, truncated JSON, schema mismatch, failed replacement, and recovery tests.

### Debounce actual settings writes

Widget reloads are coalesced, but every name, credential, and color edit still performs local and
App Group encoding and writes on the main actor.

- Debounce text and color persistence.
- Flush on focus loss, window close, termination, and security-critical credential rotation.
- Avoid App Group writes when only credentials changed and the redacted payload is identical.
- Put persistence behind a dedicated actor.

### Repair App Group state at bootstrap

A transient App Group write failure can leave widgets empty until another settings save or
refresh occurs.

- Reconcile redacted settings and the latest local snapshot into the App Group during bootstrap.
- Retry transient synchronization failures with bounded backoff.
- Reload affected timelines after successful repair.

## Network layer

### Dedicated resource-bounded HTTP client

The default client has a request timeout but still uses `URLSession.shared`, buffers unbounded
responses, shares cookies/cache state, and erases structured URL errors and cancellation.

- Use a dedicated ephemeral session with cookies and URL cache disabled.
- Retain the request deadline and add a resource deadline and connection limit.
- Enforce response-body limits while receiving data.
- Preserve `URLError.Code` and cancellation.
- Normalize parser failures to `.decoding` and retain only safe status metadata.

### Rate limits, retries, and scheduling

- Centralize classification for transient network failures, 408, 425, 429, provider-specific
  secondary-limit 403 responses, and selected 5xx responses.
- Honor `Retry-After` and relevant GitHub rate-limit headers.
- Add a small jittered retry budget for idempotent quota requests.
- Never automatically replay rotating OAuth exchanges after an ambiguous timeout.
- Add per-provider or host concurrency limits and deduplicate identical credentials.
- Track jittered cooldown state and show the next eligible refresh time.
- Add a short manual-refresh cooldown.
- Build one scheduler from last attempt, last success, snapshot age, wake, and network return.
- Reset due time after manual attempts and coalesce concurrent refreshes.
- Suspend scheduling when no complete enabled account exists and avoid redundant polls while the
  snapshot remains fresh.
- Consider longer intervals in Low Power Mode without compromising user-selected freshness.

## Provider correctness

### Copilot billing and fallback behavior

The public billing path appears tied to legacy premium-request plans and hardcoded allowances.
Private fallback failures are broadly collapsed into authentication errors, organization billing
is not represented, and month boundaries use local time.

- Verify current AI-credit billing endpoints and legacy premium-request eligibility with live
  fixtures.
- Support current plans, including Max if applicable, and organization/enterprise scopes where
  available.
- Do not infer a denominator from undocumented or synthetic response fields.
- Surface empty organization-billed usage as unknown or unsupported, not confident zero usage.
- Remove the session-token exchange/replay fallback unless a live fixture proves the resulting
  token is accepted by the target endpoint.
- Fall through only for verified compatibility statuses.
- Preserve 5xx as API failures and malformed 2xx as decoding failures.
- Bound the fallback sequence with one overall deadline.
- Set monthly reset boundaries to UTC after confirming GitHub semantics and test exact epochs in
  multiple time zones.

### Provider schema validation

Anthropic can accept an empty recognized schema, Zhipu can succeed when it finds no supported
limit type, and Google treats missing `remainingFraction` as zero remaining.

- Treat missing percentages and fractions as unknown, never as zero.
- Require recognized metrics and bounded valid fields before reporting success.
- Return `.decoding` when no supported schema is present unless the provider explicitly declares
  unlimited or no-limit behavior.
- Keep aggregate usage `nil` when no bounded metric exists.
- Test missing fields, empty payloads, unknown metric types, hostile numbers, and explicit
  unlimited states for every provider.

### OpenAI usage model

Extend decoding only after capturing fixtures for credits, spend control, additional limits,
reached type, `allowed`, and absolute reset timestamps. Render verified additional limits
dynamically rather than hardcoding exactly two windows. Keep new fields optional and forward-
compatible, and present credit balance or unlimited state plus precise exhaustion reasons.

### Google token reuse and naming

- Cache access tokens in an actor keyed by credential identity until shortly before `expires_in`.
- Keep the cache memory-only and bound refresh concurrency.
- Choose one user-facing name, such as Google Antigravity, and use it consistently across
  account creation, discovery, widgets, diagnostics, and accessibility text.

### Endpoint watchlist

- Capture the current Claude Code User-Agent from a real client and verify the Anthropic private
  usage endpoint and beta header.
- Test persistent Anthropic 429 responses without `Retry-After` and remove unsupported "safe
  polling" claims.
- Verify Google's private endpoint, fixed model IDs, Windows User-Agent, and embedded installed-
  app client credential assumptions.
- Verify whether ChatGPT token refresh should send the extra scope currently used.
- Verify Zhipu/Z.ai percentage semantics and whether Zhipu requires `open.bigmodel.cn`.
- Verify Copilot private endpoints and emulated editor headers.
- Do not make speculative endpoint edits without sanitized captured evidence.

## Discovery and import

### Multi-account discovery and replacement

- Emit every usable Google account instead of selecting only one.
- Stop assigning fixed stable IDs to distinct OpenCode credentials.
- Build identity from provider plus a non-secret account ID/source path, or a keyed fingerprint
  of sorted `key=value` pairs.
- For per-account autofill, show a source/account chooser when multiple candidates exist.
- Mask secrets, warn before replacement, and merge only fields supplied by the selected source.
- Compare provider-specific secret identity instead of any overlapping metadata value.

### Current paths, metadata, and diagnostics

- Read explicit OpenCode `accountId` before JWT inference.
- Honor `XDG_DATA_HOME`, `XDG_CONFIG_HOME`, `CODEX_HOME`, and supported keyring modes.
- Make provider, XDG, and Codex path resolution injectable for tests.
- Preserve and validate Claude expiry metadata, reporting "found but expired" separately.
- Emit `apps.json` and `hosts.json` discovery diagnostics from matches in the current file, not
  cumulative results, and test each source independently.

### Async, explicit scanning

Opening Settings still performs broad discovery and Keychain work on the main actor and can
trigger unexpected permission prompts.

- Do not auto-scan on Settings appearance.
- Run file discovery off the main actor and show progress.
- Start with exact supported Keychain services.
- Ask before enumerating or reading broader Claude-like services.
- Tighten raw-token validation.

## App behavior and UX

### Actionable account state

- Distinguish unconfigured, awaiting-first-refresh, and explicitly age-stale states in the menu.
- Replace global `statusMessage` with structured notices carrying severity, account/context,
  timestamp, and recovery action.
- Do not overwrite save, OAuth, or credential-durability failures with later success text.
- Report incomplete/skipped accounts separately from network failures.
- Model incomplete, unverified, verified, disabled, refreshing, stale, and failed states. Use
  "Complete" rather than "Ready" until a connection succeeds.
- Show per-account last attempt, last success/failure, request latency, credential source,
  reauthorization action, and sanitized copyable diagnostics.
- Deep-link widget tiles and menu failures to the exact account after defining an app URL scheme.

### Onboarding and account operations

- Add a guided first-run flow with opt-in discovery, identity selection, provider help, test
  connection, and completion.
- Make "Add Your First Account" the primary empty-state action; do not tell an unconfigured user
  to refresh.
- Add destructive-removal confirmation, explicit history handling, and Undo or a grace period.
- Add targeted account refresh; until then label the account-page action "Refresh All Accounts."
- Trim manually entered credentials on commit and defensively normalize at the import boundary so
  newline-pasted values cannot be complete but invalid.
- Add reorder, search, groups, duplicate, snooze, and explicit widget-visibility controls.

### Menu-bar icon and quick actions

The menu content is now a fixed-width scrollable window, but the status-item icon still grows
with account count and has only a generic accessibility label.

- Offer fixed-width worst-account, aggregate-gauge, top-N, monochrome, and percentage modes.
- Cap status-item width and expose a useful tooltip and quota accessibility summary.
- Make the status-item icon adapt to light/dark menu bars, Increase Contrast, and Reduce
  Transparency instead of relying on a non-template provider-colored image.
- Add per-account enable and snooze shortcuts.

### Settings layout and accessibility

- Replace fixed 180-point labels and two fixed color columns with adaptive `Grid` or `Form`
  layouts.
- Stack style columns at narrow widths or raise the true minimum window width.
- Label every hidden-label picker, toggle, stepper, color picker, and spinner for VoiceOver.
- Do not use status color as the only state channel.
- Preserve a textual "Refreshing" label in Settings while showing progress.
- Expand Overview beyond the first metric and add freshness/error badges and flexible names.
- Center Settings only when no saved frame exists, deminiaturize before showing, and remove the
  redundant `WindowAccessor` mutation loop.
- Title the window "LLimit Settings."

### Appearance model cleanup

- Model backgrounds explicitly as system, color-with-alpha, pattern, or transparent.
- Stop overloading `nil` and forcing selected alpha to at least 72 percent.
- Make the aggregate Default background genuinely system-adaptive.
- Expose or remove the unused `showResetInfo` setting.
- Derive text and chrome contrast from selected background luminance and environment.
- Add an explicit "Reset to Global" action for account style overrides.
- Remove or consolidate ring/reset helpers superseded by the provider tile.
- Consolidate the five hex parsers (QuotaCore `normalizeHexColor`,
  `LimitKindColorScheme.rgbaComponents`, `Color(providerTileHex:)`, `backgroundBaseColor`,
  `NSColor(hexString:)`/AppModel) behind one tested QuotaCore component parser for app and
  widget consumers.
- Have provider clients declare the window kind on `UsageMetric` where real data exists (OpenAI
  reports `limit_window_seconds`) so `QuotaWindowKind.classify`'s label parsing becomes a
  fallback instead of the source of truth.
- Consider lifting `limitKindColors` out of per-scope `WidgetStyleSettings` into a single
  settings-level field so effective-style merges stop hand-patching the global palette back in.

### Platform polish

- Use standard "Settings..." wording and replace the remaining macOS "tap" instruction.
- Replace `INF` with localized "Unlimited" or an accessible infinity representation.
- Replace `--` with an accessible "Unknown" representation.
- Add About, Help, version/build, and an audited user-facing diagnostics export.
- Model full launch-at-login state, including "Requires approval," and refresh it on activation.
- Add a String Catalog and locale-aware number and duration formatting.

## Widgets

### Validate the provider slot tiles

Widget-side configuration was abandoned after the Edit Widget flow stayed dead across every
intent shape tried (builds 7-13, including a fresh `.v3` identity retest under Apple's canonical
`AppEntity` + `EntityQuery`; no build ever opened the Edit sheet for any intent from this app).
Build 14 (extended to eight slots in build 16) replaced the single configurable tile with static
slot widgets ("Provider Tile 1"…"8", kinds `ch.lkmc.llimit.widget.provider-tile.slot1..8` —
WidgetKit registers kinds at compile time, so the count cannot be dynamic). Account selection
lives in LLimit → Settings → Widgets (`AppSettings.providerTileSlots`, synced through the App
Group store; the app reloads widget timelines on every assignment change). Unassigned tiles
auto-fill with the enabled accounts not pinned to any tile
(`providerTileAutoCandidates`/`providerTileAutoRank`), so auto tiles never duplicate pinned ones,
and each wears a "#N AUTO" badge so desktop tiles can be matched to Settings rows. Explicit
states cover disabled accounts, removed accounts ("Tile N — reassign"), more tiles than accounts,
and no accounts at all. There is no Edit menu item on static widgets, so the broken flow can no
longer be reached.

- Validate on macOS: `./scripts/build.sh --clean --install --run`, add Provider Tiles 1-4,
  confirm each auto-maps to a distinct account with the #N badge, then pin assignments in
  Settings → Widgets and confirm the badge disappears and tiles update immediately.
- Remove all pre-build-14 provider tiles; the v1-v3 intent payloads and kinds are intentionally
  not migrated.
- If tiles stay invisible during Space-switch transitions and pop in only after the desktop
  settles, reset the per-extension `.chrono-timeline` archives with
  `./scripts/widget-diagnostics.sh --reset-chrono-cache`; reinstalls do not clear that on-disk
  state, and chronod's reload bookkeeping may be failure-throttled from earlier crash storms.
- If widget-side configuration is ever revisited (e.g. after a macOS fix), the historical
  diagnostic ladder was: fresh tile after full removal → `log stream` on
  NotificationCenter/chronod/appintentsd while clicking Edit → `killall NotificationCenter
  chronod WidgetCenter` → fresh macOS user account → Feedback with sysdiagnose; next code
  experiment would be ExtensionKit packaging (`Contents/Extensions` +
  `EXAppExtensionAttributes`) instead of legacy NSExtension.
- Capture screenshots in light and dark desktop contexts and compare them to the supplied
  reference composition.
- Treat reference fidelity as an acceptance checklist: provider-themed diagonal stripes in one
  `Canvas`, a translucent inset scrim, 12-o'clock rounded arcs, distinct ring widths and spacing,
  a two-line short-name fallback, and footer markers tied to their corresponding rings.
- Validate the intended palettes: Claude terracotta/sand/cream; OpenAI graphite/mint/soft white;
  Copilot indigo/violet/cyan; Zhipu cobalt/sky/lavender; Z.ai walnut/amber/pale gold; and restrained
  Google blue/red/yellow/green stripes with a neutral dark scrim.
- Keep user presets and per-account overrides authoritative, and validate automatic luminance
  contrast rather than accepting any broadly similar gradient.
- Test one, two, and more than two metrics; long names; multiple accounts for one provider;
  unlimited, unknown, first-refresh, stale, failed, disabled, and removed states.
- Test a maximum-size history archive and prove the provider tile never reads it.
- Render unknown quota with a neutral or indeterminate track, never as a healthy full or empty
  ring.
- Run VoiceOver, Increase Contrast, Differentiate Without Color, Reduce Transparency, and Reduce
  Motion checks.
- Include provider, account, metric names, values, reset times, stale age, and current failure in
  the tile accessibility summary.
- Implement and validate `.systemMedium`, or explicitly approve a scope change from the original
  small-and-medium specification.
- Resolve whether the global "Show percentages in all widgets" setting applies to provider tiles
  or relabel it as dashboard-specific.
- Publish one lightweight current entry with `.after(nextRefreshDate)` unless a reset boundary
  requires another entry. Do not clone the full entry every five minutes merely to update text.
- Add widget deep links after the app URL scheme is defined.

### Existing dashboard widgets

- Make static-dashboard dual-limit bars and labels provider-aware rather than silently showing the
  first two candidate metrics; retain its current most-constrained primary-metric selection.
- Never infer 100 percent remaining from absent aggregate data.
- Derive row capacity from geometry and cap medium rows to what actually fits.
- Remove fixed-width columns or add `ViewThatFits` inside the existing family-specific views.
- Model unconfigured, awaiting first refresh, loaded, partial, stale, file-load failure, and App
  Group unavailable as distinct entry states.
- Show failure-only snapshots instead of "No accounts configured."
- Explain that networking requires the host app to run, encourage Launch at Login, and show data
  age prominently.
- Evaluate `.systemLarge` for a complete multi-account dashboard after small/medium overflow work.

### Trend chart

- Add selected-series configuration; the provider tiles double as the legend (build 19), so the
  chart deliberately has no in-chart legend.
- Show current value and time/percentage context.
- Preserve extrema during downsampling.
- Segment paths around large gaps (reset boundaries already render as vertical snaps).
- Pad plot edges so endpoint marks do not clip.
- Base depletion warnings on enough fresh, reset-segmented samples.
- Show more than one relevant warning when space permits.

### Widget accessibility contract

Static dashboard and trend widgets still need semantic summaries. Every state must expose provider,
account, metric names, remaining values, reset times, freshness, and failure without relying on
color or hidden visual percentages. Hide decorative tracks and backgrounds from accessibility and
adapt to contrast, transparency, motion, and Differentiate Without Color settings.

## Build, CI, and release engineering

### Restore runnable CI

Determine whether zero-step macOS jobs are caused by runner availability, billing/quota,
repository Actions policy, or workflow restrictions. Restore runnable checks before relying on CI
for merge or release confidence.

### Canonical project generation

- Make `project.yml` canonical and add an XcodeGen regeneration/diff check.
- Put team and identifier overrides in ignored local `.xcconfig` files or environment settings.
- Remove the current drift where `project.yml` has a blank team but the generated project embeds
  a maintainer team.
- Parameterize bundle and App Group IDs for forks.
- Select development signing only when a matching identity exists.
- Establish and test one supported Xcode minimum. Repository guidance says Xcode 15+, CI pins
  Xcode 16.2, and recorded local validation used Xcode 17F113.

### CI structure and release policy

- Select the toolchain before tests and remove the duplicate package test pass.
- Add Ubuntu Swift CI for QuotaCore.
- Add macOS app/widget test targets and integration tests.
- Add Swift 6 strict-concurrency compilation and Thread Sanitizer runs on macOS.
- Collect coverage and establish a modest regression threshold.
- Validate semantic-version tags and require release commits to be on protected `main` with
  successful CI.
- Split read-only build from protected publication and disable persisted checkout credentials.
- Ensure arbitrary `v*` tags cannot publish an untested credential-reading app.

### Supply chain, artifacts, and documentation

- Pin Actions to full commit SHAs and automate controlled updates.
- Avoid floating Homebrew dependencies where built-in tools suffice.
- Pin or vendor `lkm-build`/`lkm-release` and validate their versions and output.
- Validate DMGs, app/extension versions, architectures, signatures, entitlements, and
  notarization.
- Publish checksums and artifact attestations.
- Make `RELEASING.md` describe the one executable release path exactly, including triggers,
  scripts, required secrets, signing, and notarization. Remove claims for nonexistent workflow
  dispatch or conditional signing behavior.

### Test coverage priorities

- Add request-contract and fixture tests for OpenAI, Copilot, Zhipu/Z.ai, Google, HTTP, and every
  status class, including Copilot headers, fallback sequence, malformed responses, and status
  classification.
- Assert Anthropic method, URL, mandatory headers, and User-Agent.
- Cover malformed JSON, hostile numbers, missing fields, empty schema, oversized body, timeout,
  cancellation, 401/403/429/5xx, and retry metadata.
- Add App Group/redacted-sync, scheduler, token orchestration, snapshot reconciliation, widget
  loading, and final-bundle smoke tests.
- Add clean-install provider-intent configuration tests where WidgetKit automation permits.

### Repository policy

- Add `SECURITY.md` explaining unsandboxed credential access and vulnerability reporting.
- Add `CONTRIBUTING.md`, `CODEOWNERS`, a changelog, formatting/lint policy, and action-update
  configuration.
- Ignore result bundles and private signing material such as `.p12`, `.p8`, and provisioning
  profiles.
- Document the embedded Google installed-app credential as public-client material and rotate it
  if it was ever intended to be confidential.

## Product backlog

1. Add configurable per-metric threshold notifications, such as 80 and 95 percent used, plus
   reset and authentication-failure alerts with deduplication, quiet hours, and Focus-aware
   suppression or post-Focus summaries where APIs permit.
2. Add in-app history with reset markers, account comparison, retention controls, and a compact
   view that does not require installing a widget.
3. Add burn-rate and time-to-exhaustion forecasts with confidence and reset awareness. Surface
   an "at this rate" estimate in the app and menu, including whether exhaustion precedes reset.
4. Add a reset radar: one chronological list of upcoming resets across providers.
5. Add CSV/JSON history export with explicit privacy controls.
6. Add Shortcuts/App Intents for reading quota and triggering refresh.
7. Add a signed auto-update flow such as Sparkle.
8. Add wake/network-aware refresh and an optional battery/Low Power policy.
9. Add more providers only after accepting their authentication and API maintenance cost.
   Candidates are Gemini CLI, OpenRouter credits, Cursor, Mistral/Le Chat, xAI, and GitHub
   Models.
10. Add a redacted CLI/status-line companion for shell prompts, Raycast, Stream Deck, or tmux.

## Delight backlog

- **Best model to burn:** recommend the account with the most current headroom.
- **Quota weather:** translate a confidence-aware forecast into calm, cloudy, or stormy copy.
- **Pacing rings:** make a weekly quota last until a chosen date and show ahead/behind pace.
- **Reset celebration:** use a restrained ring bloom or icon bounce that respects Reduce Motion.
- **Mood gauge:** offer calm/concerned/sweating menu states with non-color equivalents.
- **Menu sparkline:** show 24-hour history for the most constrained account.
- **Quota roulette:** choose a provider weighted by current headroom.
- **Focus-session budget:** report quota consumed during a Focus interval.
- **Honesty mode:** label private, inferred, stale, and verified provider data differently.

## Recommended order

1. Restore macOS Actions and runtime-validate the v2 provider widget picker.
2. Ship a correctly signed and notarized widget-capable release pipeline.
3. Enforce failure redaction and credential-file permissions.
4. Correct freshness/history semantics and refresh cancellation/configuration races.
5. Make OAuth ownership and Claude account provenance honest.
6. Replace whole-file history storage and main-actor persistence.
7. Add provider contract fixtures, then change Copilot, OpenAI, Google, Anthropic, or Zhipu
   behavior only from captured evidence.
8. Complete onboarding, actionable account states, accessible Settings, and adaptive widget
   layouts.
9. Finish provider-tile configuration and visual validation before notifications, history, and
   forecasting features.
