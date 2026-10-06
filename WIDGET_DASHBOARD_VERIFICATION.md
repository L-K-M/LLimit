# Dashboard truth verification

## Source reproduction

Baseline: `2d6ac1e`, `LLimitWidgetExtension/LLimitQuotaWidget.swift`.

- Small/medium dashboards read `snapshot.providers` directly, so removed,
  disabled and renamed accounts retain old rows, titles and summary values.
- `providerRemainingPercent` falls back to `100 - maxUsagePercent`. Google's
  `empty` metric has no percentage but aggregate usage `0`, producing a full
  bar and a "lowest 100% left" summary.
- Empty provider results always show onboarding. A first refresh containing
  only failures therefore says "No accounts configured" and hides its count.
- `QuotaTimelineProvider` turns failed settings/snapshot reads into defaults/nil,
  losing the distinction between missing data and unavailable storage.

Before the fix, a source-equivalent extraction of those policies ran against
`DashboardPresentationTests`: 19 tests, 42 failed assertions. Healthy 0%/100%
metrics, provider-preferred bounded stops and retained last-good usage passed.
The same fixtures exercise the production QuotaCore policy after the fix.

The guard-order follow-up reproduced two failures: loaded empty/all-disabled
settings lost to an unavailable snapshot. Enabled accounts still required a
readable snapshot; missing settings with an existing snapshot remained a storage
error. Aggregate-only fixtures now also reject "lowest" summaries at 0/80/100.

## Linux checks

With a standard installed Swift toolchain, no custom SDK is required:

```bash
swift test --package-path Packages/QuotaCore --jobs 2 --filter 'DashboardPresentationTests|AccountDisplayOrderTests'
swift test --package-path Packages/QuotaCore --jobs 2
swiftc -frontend -parse LLimitWidgetExtension/QuotaTimelineProvider.swift LLimitWidgetExtension/LLimitQuotaWidget.swift
git diff --check
```

This Linux host uses an optional, machine-local `SDKROOT`: an unpacked dependency
directory supplied outside the repository, with matching toolchain/runtime
library paths exported. For that setup, add `--sdk "$SDKROOT"` to `swift test`
and `-sdk "$SDKROOT"` to `swiftc`. Standard installations need neither override.

Fixtures use synthetic accounts and usage. They require no credentials or
provider requests. Syntax parsing does not type-check SwiftUI or WidgetKit.
Verified after the follow-up: 35 focused tests (22 dashboard, 13 account ordering)
and all 438 QuotaCore tests passed with the host override. Both UI files passed
syntax parsing; the diff passed whitespace checks.

## Native procedure (not run on Linux)

Use an isolated Xcode preview/test container with synthetic data. Preview both
dashboard sizes through `QuotaEntry.storedSettings` and `storedSnapshot`.
Keep the snapshot and its timestamps fixed while changing only settings.

| Fixture | Expected dashboard |
| --- | --- |
| Removed/disabled low-quota account; another account renamed | Only current enabled rows and names; summary and row limit exclude old accounts |
| Google `empty` metric, no percentage, aggregate usage `0` | `--`, no filled bar, no numeric "lowest" summary |
| Explicit unlimited metric only | Widget applies `INF` and unlimited fill; presentation yields no bounded bar stop or numeric 100% summary |
| Unknown limit plus unlimited metric | Unknown state, no unlimited fill for the account |
| Bounded metric with remaining `100` or `0` | Real full/empty geometry and matching percentage |
| Loaded settings with no accounts, including old/unavailable snapshot | "No accounts configured" |
| Loaded settings with all accounts disabled, including unavailable snapshot | "No enabled accounts" |
| Enabled account with missing/empty snapshot | "Awaiting quota data" |
| Every enabled account fails, no last-good usage | "All accounts unavailable"; current failure count when enabled |
| Last-good usage retained alongside a current failure | Usage row and current failure count |
| Settings `.unavailable` | "Storage unavailable", never onboarding |
| Enabled accounts with snapshot `.unavailable` | "Storage unavailable", never onboarding |
| Missing settings with an existing snapshot | "Storage unavailable" |

Repeat unknown/unlimited cases with percentages hidden and dual limits enabled.
Status text must remain visible; unknown metrics must not become bar stops.
Check placeholder/gallery previews and the trend widget with existing history.

For the stored-entry boundary, load malformed synthetic settings and snapshot
files separately and request a widget reload. Failed settings or an unreadable
snapshot required by enabled accounts must yield storage-unavailable states.
Successfully loaded empty/all-disabled settings take precedence over snapshot
errors. App Group resolution/read failures must take the same path. Restore the
fixtures afterward. Keep the host's account credentials out of this container.

Native rendering, App Group access and accessibility require macOS. PR build
checks cover native compilation; they do not prove screenshots or VoiceOver.
