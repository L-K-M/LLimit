# LLimit Active Roadmap

Last reconciled from the full `sol.md` review on 2026-07-10. The complete evidence,
file references, rationale, requested-widget design, and idea inventory remain in
`sol.md` (PR #7). This document intentionally contains only work that is unresolved or
awaiting validation.

## Validation status

The review-cycle implementations are merged. The combined `QuotaCore` suite passes 65 tests
on Swift 6.0.3/Linux, and all widget sources pass a syntax parse. GitHub macOS jobs still fail
before checkout because no runner is assigned (`runner_id: 0`, zero steps, no logs). Local
testing now uses Xcode 17F113 with the macOS 26.5 SDK; visual and WidgetKit runtime QA remain
manual.

## Immediate release blockers

### Signed, widget-capable distribution

The release workflow still builds without signing and then ad-hoc signs without App Group
entitlements. Official downloads therefore cannot deliver working widgets.

- Implement Developer ID signing for the host and embedded widget extension.
- Provision the same App Group on both targets.
- Enable hardened runtime and notarize/staple the final distributed container.
- Verify app and extension entitlements with `codesign -d --entitlements :-`.
- Verify nested signatures with `codesign --verify --deep --strict` and Gatekeeper with
  `spctl` on a clean Mac.
- Until complete, label downloads as non-widget smoke builds rather than functional releases.

### Failure-data redaction boundary

Provider clients can place complete HTTP response bodies or arbitrary localized errors in
`ProviderFailure.message`. Snapshot and history stores persist that text into the App Group.

- Replace persisted raw text with structured kind, safe status, retry time, provider code,
  and an allowlisted short user message.
- Redact every configured credential value at the coordinator boundary as defense in depth.
- Strip control characters and cap message/body length.
- Keep detailed response diagnostics transient and outside widget storage.
- Introduce a minimal widget snapshot DTO that excludes detailed errors and unnecessary PII.
- Add serialization tests proving tokens and token-like reflected values never cross the
  boundary.

### Honest OAuth ownership

Copied rotating/short-lived OAuth credentials do not become independent merely because they
are saved in LLimit. A source tool and LLimit can invalidate each other's refresh grants.

- Preferred: implement a first-party LLimit authorization flow that obtains a distinct grant.
- Otherwise: model accounts explicitly as linked-source accounts and make one local store
  authoritative.
- Never describe linked rotating credentials as independent or safe after removing the source
  tool.
- Make rotated-token persistence transactional and fail visibly if durability is uncertain.
- Validate the refreshed account identity before replacing credentials.
- Handle expired, revoked, reused, and mismatched refresh grants as distinct recovery states.

## Data correctness

### Fresh, stale, failed, and unknown state

Last-known usage is intentionally carried after a failed poll, but aggregate snapshot time is
currently presented as if every account succeeded. Merged stale values are also appended as
new trend observations.

- Add explicit per-account freshness/last-success state.
- Show stale age on menu, Settings, dashboard, trend, and provider tile.
- Count only genuinely fresh providers in refresh summaries.
- Check current failure before reporting that an account has loaded data.
- Define a stale-data TTL and eventually suppress or strongly de-emphasize obsolete values.
- Append only fresh observations to history, or deduplicate by
  `(accountID, metricID, fetchedAt)`.
- Timestamp trend points with `ProviderUsage.fetchedAt`, not aggregate `generatedAt`.
- Segment forecasts and lines around resets, stale periods, and missing intervals.

### Settings recovery and schema migration

PR #8 prevents unreadable settings from being silently decoded and overwritten. Recovery is
still manual.

- Add a last-known-good backup before atomic replacement.
- Add a versioned settings envelope and explicit migrations.
- Offer a visible recovery flow: reveal file, restore backup, export unreadable source, or
  explicitly reset.
- If lossy per-account recovery is added, quarantine skipped raw records and identify them;
  never silently discard them.
- Validate `QuotaSnapshot.version` and define downgrade behavior.

### Cancellation and configuration races

Cancellation currently becomes a normal provider failure, and refresh persistence can race
with account edits.

- Preserve `CancellationError` and `URLError.cancelled` through HTTP and coordinator layers.
- Check cancellation immediately before snapshot/history writes.
- Return an unsaved result from `RefreshService`.
- Track a configuration revision and discard/filter results when it changes.
- Cancel active account work on credential, enablement, or removal changes.
- Revalidate active IDs immediately before every persistence boundary.
- Add suspending-client tests proving canceled or obsolete work cannot write data.

## Credential security

### Enforce local permissions

The credential-bearing settings store writes first and ignores chmod failure.

- Create the local LLimit directory with mode `0700`.
- Ensure temporary and replacement credential files are `0600` before exposure.
- Verify regular-file type, owner, and final mode after replacement.
- Treat permission failure as a save failure.
- Use `0600` for local snapshot/history as well; apply the narrowest functional mode in the
  App Group.
- Add first-save, overwrite, wrong-owner/type, and permission-failure tests.

### Claude account provenance

The current Claude workaround reads one local token and can apply it to every enabled Claude
OAuth account. File discovery also wins before the often-fresher Keychain.

- Store source stable ID and source account identity with each linked account.
- Refresh only the account tied to that source.
- Compare expiry metadata and choose the genuinely freshest token.
- Never infer provenance solely from an `sk-ant-oat` prefix.
- Remove the README/diagnostic command that redirects a Keychain secret into plaintext.
- If export instructions remain, require `umask 077` and explicit mode `600`.

### Optional Keychain-backed LLimit storage

Offer Keychain as an opt-in credential store while retaining an understandable local-file
mode. Define backup, migration, export, and headless behavior before implementation.

## Storage and performance

### Replace whole-file history archives

Dashboard history loading is addressed by PR #13, but the trend path still decodes the full
archive before filtering, and every append rewrites both complete local and App Group arrays.

- Prefer SQLite, append-only records, or day-partitioned files with indexed timestamps.
- Maintain a compact, already-windowed widget trend DTO.
- Enforce byte-size as well as entry-count retention.
- Downsample before crossing into WidgetKit.
- Preserve append order rather than sorting twice per append.
- Move encoding and file I/O off `@MainActor`.
- Add large-archive peak-memory and append-latency benchmarks.

### Synchronize stores and recover corruption

The stores claim `@unchecked Sendable` while sharing codecs and performing unlocked
read-modify-write operations. A corrupt history file permanently blocks new appends.

- Serialize in-process access with actors or explicit locking.
- Coordinate cross-process file access where read-modify-write is unavoidable.
- Create codecs per operation or otherwise prove codec synchronization.
- Quarantine corrupt archives and seed a new store from current data.
- Use a record format where one malformed entry does not invalidate all history.
- Add concurrent append, truncated JSON, schema mismatch, failed replacement, and recovery
  tests.

### Debounce actual settings writes

Widget reloads are debounced, but every name, credential, and color character still performs
local and App Group encoding/writes on the main actor.

- Debounce text/color persistence and flush on focus loss, window close, termination, and
  security-critical credential rotation.
- Avoid App Group writes when only credential values changed and the redacted payload is
  unchanged.
- Put persistence behind a dedicated actor.

## Network layer

### Dedicated resource-bounded HTTP client

- Replace `URLSession.shared` with a dedicated ephemeral session.
- Disable cookies and URL cache for account-isolated auth traffic.
- Set request and resource deadlines and a connection limit.
- Enforce response-body size while receiving data.
- Preserve structured `URLError.Code` and cancellation.
- Normalize parser errors to `.decoding` and retain only safe status metadata.

### Rate limits and scheduling

- Centralize classification for 408, 425, 429, provider-specific 403 limits, and 5xx.
- Honor `Retry-After` and relevant GitHub headers.
- Add per-provider/host concurrency limits and credential deduplication.
- Track jittered cooldown state and show the next eligible refresh.
- Add a short manual-refresh cooldown.
- Do not blindly retry rotating OAuth requests after ambiguous network timeouts.
- Build one scheduler from last attempt, last success, snapshot age, wake, and network return.
- Reset the schedule after manual attempts and coalesce concurrent refreshes.

## Provider correctness

All provider API changes below require sanitized live fixtures and request-contract tests
before merging because most endpoints are private or unstable.

### Copilot billing generation

- Verify the current AI-credit billing endpoint and legacy premium-request eligibility.
- Support current plans, including Max if applicable.
- Support organization/enterprise billing scopes where available.
- Do not infer a limit from undocumented synthetic response fields.
- Fix fallback classification so 5xx is API failure and malformed 2xx is decoding failure.
- Bound the private fallback sequence with one overall deadline.
- Set monthly reset boundaries to UTC after confirming GitHub semantics.

### Provider schema validation

Anthropic, Zhipu, and Google can currently interpret missing values as empty, fully healthy,
or fully exhausted data.

- Treat missing percentage/fraction as unknown, never zero.
- Require recognized metrics and valid bounded fields before success.
- Return `.decoding` when no supported schema is present unless the provider explicitly says
  unlimited/no-limit.
- Keep aggregate usage `nil` when no bounded metric exists.

### OpenAI usage model

After PR #6, extend decoding only with verified fixtures for credits, spend control,
additional limits, reached type, `allowed`, and absolute reset timestamps. Render additional
limits dynamically instead of hardcoding exactly two windows.

### Google token reuse

Cache access tokens in an actor keyed by credential identity until shortly before
`expires_in`. Keep the cache memory-only and bound refresh concurrency.

### Endpoint watchlist

- Anthropic private usage endpoint, beta header, and hardcoded Claude Code User-Agent.
- Google private endpoint, model IDs, Windows User-Agent, and embedded installed-app client
  credential.
- ChatGPT refresh request's extra scope.
- Zhipu/Z.ai percentage semantics and possible `open.bigmodel.cn` host.
- Copilot private endpoints and emulated editor headers.

Do not make speculative endpoint edits without captured evidence.

## Discovery and import

### Multi-account discovery

- Emit every usable Google account rather than only one.
- Stop assigning fixed stable IDs to distinct OpenCode credentials.
- Build identity from provider plus non-secret account ID/source path, or a keyed fingerprint.
- Fingerprint sorted `key=value` pairs, not values alone.
- Present an account/source chooser for autofill and import.
- Warn before replacing credentials and merge only fields supplied by the selected source.
- Compare provider-specific secret identity rather than any overlapping metadata value.

### Current paths and metadata

- Read explicit OpenCode `accountId` before JWT inference.
- Honor `XDG_DATA_HOME`, `XDG_CONFIG_HOME`, `CODEX_HOME`, and supported keyring modes.
- Inject path resolvers for tests.
- Validate Claude expiry metadata and report "found but expired" separately.

### Async, explicit scanning

- Do not auto-scan on Settings appearance.
- Run file discovery off the main actor and show progress.
- Start with exact supported Keychain services.
- Ask before enumerating/reading broader Claude-like services.
- Tighten raw token validation.
- Never trigger a surprise Keychain prompt during background refresh.

## App behavior and UX

### Actionable state surfaces

- Distinguish unconfigured, awaiting first refresh, failure-only, partial, stale, and loaded
  menu states.
- Show failure-only snapshots instead of "No quota data yet."
- Use account names, not only provider names, in failures.
- Replace global `statusMessage` with structured, contextual notices and recovery actions.
- Do not overwrite save/OAuth durability failures with later success text.
- Report incomplete/skipped accounts separately from network failures.
- Model incomplete, unverified, verified, disabled, refreshing, stale, and failed states.

### Onboarding and account operations

- Add a guided first-run flow with opt-in discovery, identity selection, provider help, test
  connection, and completion.
- Make "Add Your First Account" the primary empty-state action.
- Add destructive-removal confirmation, explicit history handling, and Undo/grace period.
- Add targeted account refresh; until then label the account-page action "Refresh All."
- Trim credentials on commit/import so newline-pasted tokens cannot be "complete" but invalid.
- Add reorder, search, groups, duplicate, snooze, and explicit widget visibility controls.

### Scalable menu-bar UI

- Consider `.menuBarExtraStyle(.window)` with a fixed-width scrollable summary.
- Offer worst-account, aggregate gauge, top-N, monochrome, and percentage icon modes.
- Cap menu-bar width and expose a useful tooltip/accessibility summary.
- Add upcoming-reset and per-account enable/snooze shortcuts.

### Settings layout and accessibility

- Replace fixed 180-point labels/two fixed color columns with adaptive Grid/Form layout.
- Stack style columns at narrow widths or raise the actual minimum width.
- Label every hidden-label picker, toggle, stepper, color picker, and spinner for VoiceOver.
- Do not use status color as the only channel.
- Preserve a textual "Refreshing" label while showing progress.
- Expand Overview beyond the first metric and add freshness/error badges.
- Center Settings only when no saved frame exists, deminiaturize before showing, and remove
  the redundant `WindowAccessor` mutation loop.

### Appearance model cleanup

- Model backgrounds explicitly as system, color-with-alpha, pattern, or transparent.
- Stop overloading `nil` and forcing alpha to at least 72 percent.
- Make the aggregate "Default" background genuinely system-adaptive.
- Either connect per-account backgrounds to a visible widget mode or remove/relabel them.
- Expose or remove the unused `showResetInfo` setting.
- Derive text/chrome contrast from selected background luminance.
- Add an explicit "Reset to Global" action for account style overrides.

### Platform polish

- Use standard "Settings...", "click", and "Unlimited" terminology.
- Add About, Help, version/build, safe diagnostics, and an update path.
- Model full launch-at-login state, including "Requires approval," and refresh it on
  activation.
- Add String Catalog localization and locale-aware number/duration formatting.

## Widget follow-up

### Validate and extend provider tiles

- Build 7 exports valid `ProviderQuotaIntent` metadata and launches the extension, but
  `chronod` returns only the two static descriptors and omits
  `ch.lkmc.llimit.widget.provider-quota`.
- Build 9 gave the intent/query stable identifiers, hardened installation validation and
  PlugInKit registration, and temporarily added static and parameterless App Intent probes.
  The macOS Widget Gallery displayed all five descriptors, including the real configurable
  `ch.lkmc.llimit.widget.provider-quota`, proving App Intent extraction and runtime descriptor
  registration work with Xcode 17F113 and the macOS 26.5 SDK.
- Build 10 removed both diagnostic probes while retaining the registration hardening. The
  provider tile appeared, but its App Entity configuration remained unusable. Build 11 replaced
  that graph with a primitive account-ID parameter, but retained the same widget kind while
  changing the intent identity and parameter schema. Build 12 gives the tile and intent fresh
  identities so WidgetKit cannot decode an older tile with incompatible cached metadata.
- Run `./scripts/build.sh --clean --install --run` on macOS and confirm Edit Widget opens the
  Account picker for `ch.lkmc.llimit.widget.provider-quota.v2` on a newly added tile before
  closing this blocker.
- Remove pre-build-12 provider tiles before testing; the v1 intent payload is intentionally not
  migrated because its schema changed repeatedly during development.
- Test AppIntent account configuration on macOS 14+.
- Capture small-widget screenshots against the supplied reference in light/dark desktop
  contexts.
- Verify long names, one/two/no bounded metrics, unlimited, stale, failed, disabled, removed,
  and multiple same-provider accounts.
- Run VoiceOver, Increase Contrast, Differentiate Without Color, Reduce Transparency, and
  Reduce Motion checks.
- Add optional outer/inner metric selection for Claude Opus and additional Copilot/Google
  limits.
- Decide whether the global "Show percentages" preference should affect provider tiles or be
  relabeled as dashboard-specific.
- Consider a medium provider-detail family after the small composition is stable.
- Add widget deep links to the selected account after defining an app URL scheme.
- Decide whether per-account background choices should override provider-toned tile palettes.

### Existing dashboard

- Define provider-aware visible metrics rather than silently taking the first two.
- Never infer 100 percent remaining from absent aggregate data.
- Derive row capacity from geometry and cap medium rows to what can fit.
- Use `ViewThatFits` or family-specific layouts instead of fixed widths.
- Carry explicit entry state so load failure is not shown as no accounts.
- Communicate that network refresh requires the host app to be running and show data age.

### Trend chart

- Add selected-series configuration or a compact legend.
- Assign stable per-account/metric colors.
- Show current value and time/percentage context.
- Preserve extrema during downsampling.
- Segment paths around resets and large gaps.
- Pad plot edges so endpoints do not clip.
- Base depletion warnings on enough fresh, reset-segmented samples.
- Show more than one relevant warning when space permits.

### Widget accessibility contract

Every widget state must expose provider/account, metric names, remaining values, reset times,
freshness, and current failure without relying on color or visibility preferences. Decorative
tracks/backgrounds should be hidden from accessibility.

## Build, CI, and release engineering

### Restore runnable CI first

Current Actions jobs fail before checkout with no assigned runner. Determine whether this is
macOS runner availability, billing/quota, repository Actions policy, or workflow restrictions.
Do not use red checks from zero-step jobs as code-quality evidence.

### Canonical project generation

- Quote the intended Swift language mode in `project.yml`; unquoted `5.10` currently becomes
  `5.1` in the generated project.
- Make `project.yml` canonical and add an XcodeGen regeneration/diff check.
- Put team and identifier overrides in ignored local `.xcconfig` or environment settings.
- Parameterize bundle/App Group IDs for forks.
- Only choose development signing when a matching identity exists.
- Resolve documentation disagreement over Xcode minimum; current configuration is effectively
  Xcode 16.2-oriented.

### CI structure

- Select the toolchain before tests and remove the duplicate package test pass.
- Add Ubuntu Swift CI for QuotaCore.
- Add macOS app/widget test targets and integration tests.
- Verify embedded extension, matching versions, architectures, signatures, entitlements,
  hardened runtime, and notarization in release gates.
- Collect coverage and establish a modest regression threshold.
- Validate semantic-version tags and require release commits to be on protected `main` with
  successful CI.
- Split read-only build from protected publication; disable persisted checkout credentials.

### Supply chain and artifacts

- Pin Actions to full commit SHAs and automate updates.
- Avoid floating Homebrew dependencies where built-in tools suffice.
- Pin or vendor `lkm-release` and validate its version/diff.
- Validate DMGs, app/extension versions, architectures, signatures, and notarization.
- Publish checksums and artifact attestations.
- Make signing/notarization fail closed rather than silently producing a release.

### Test coverage priorities

- Request-contract/fixture tests for OpenAI, Zhipu/Z.ai, Google, HTTP, and all status classes.
- Assert Anthropic mandatory URL, headers, and User-Agent.
- Add malformed JSON, hostile number, missing field, empty schema, oversized body, timeout,
  cancellation, 401/403/429/5xx, and retry metadata cases.
- Add App Group/redacted sync, scheduler, token orchestration, snapshot reconciliation, widget
  loading, and bundle smoke tests.
- Add Swift 6 strict-concurrency compilation and Thread Sanitizer runs on macOS.

### Repository policy

- Add `SECURITY.md` explaining unsandboxed credential access and vulnerability reporting.
- Add `CONTRIBUTING.md`, `CODEOWNERS`, changelog, formatting/lint policy, and action update
  configuration.
- Ignore result bundles and private signing material (`.p12`, `.p8`, provisioning profiles).
- Document the embedded Google installed-app credential as public-client material; rotate it
  if it was ever intended to be confidential.

## Product backlog

1. Threshold, reset, and authentication-failure notifications with deduplication and quiet
   hours.
2. In-app history with reset markers, account comparison, and retention controls.
3. Burn-rate/time-to-exhaustion forecasts with confidence and reset awareness.
4. Reset radar: one chronological list of upcoming resets across providers.
5. CSV/JSON history export with privacy controls.
6. Shortcuts/App Intents for reading quota and triggering refresh.
7. Signed auto-update flow, such as Sparkle.
8. Wake/network-aware refresh and optional battery/low-power policy.
9. More providers only after auth/API maintenance cost is accepted: Gemini CLI, OpenRouter
   credits, Cursor, Mistral/Le Chat, xAI, and GitHub Models are candidates.
10. A redacted CLI/status-line companion for shell prompts, Raycast, Stream Deck, or tmux.

## Delight backlog

- **Best model to burn:** recommend the account with the most current headroom.
- **Quota weather:** translate a confidence-aware forecast into calm, cloudy, or stormy copy.
- **Pacing rings:** make a weekly quota last until a chosen date and show ahead/behind pace.
- **Reset celebration:** a restrained ring bloom or icon bounce that respects Reduce Motion.
- **Mood gauge:** optional calm/concerned/sweating menu states with non-color equivalents.
- **Menu sparkline:** 24-hour history for the most constrained account.
- **Quota roulette:** choose a provider weighted by current headroom.
- **Focus-session budget:** report quota consumed during a Focus interval.
- **Honesty mode:** label private, inferred, stale, and verified provider data differently.

## Recommended order

1. Restore macOS Actions and validate the merged app/widget with Xcode 16.2.
2. Ship a correctly signed/notarized widget-capable release pipeline.
3. Enforce the failure redaction boundary and settings-file permissions.
4. Correct freshness/history semantics and refresh cancellation/races.
5. Make OAuth ownership/provenance honest, especially Claude multi-account behavior.
6. Replace whole-file history storage and main-actor persistence.
7. Add provider contract fixtures, then update Copilot/OpenAI/Google behavior from evidence.
8. Complete onboarding, accessible state surfaces, and adaptive Settings/dashboard layouts.
9. Validate and extend provider tiles, then build notifications/history/forecast features.
