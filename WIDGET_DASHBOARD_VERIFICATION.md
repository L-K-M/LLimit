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

## Linux checks

With the supplied Swift toolchain, SDK and library paths:

```bash
swift test --package-path Packages/QuotaCore --sdk "$SDKROOT" --jobs 2 --filter DashboardPresentationTests
swift test --package-path Packages/QuotaCore --sdk "$SDKROOT" --jobs 2
swiftc -frontend -sdk "$SDKROOT" -parse LLimitWidgetExtension/QuotaTimelineProvider.swift LLimitWidgetExtension/LLimitQuotaWidget.swift
git diff --check
```

Fixtures use synthetic accounts and usage. They require no credentials or
provider requests. Syntax parsing does not type-check SwiftUI or WidgetKit.
Verified after the fix: all 19 dashboard regressions and all 435 QuotaCore tests
passed. Both changed UI files passed syntax parsing; the diff passed whitespace
checks.

## Native procedure (not run on Linux)

Use an isolated Xcode preview/test container with synthetic data. Preview both
dashboard sizes through `QuotaEntry.storedSettings` and `storedSnapshot`.
Keep the snapshot and its timestamps fixed while changing only settings.

| Fixture | Expected dashboard |
| --- | --- |
| Removed/disabled low-quota account; another account renamed | Only current enabled rows and names; summary and row limit exclude old accounts |
| Google `empty` metric, no percentage, aggregate usage `0` | `--`, no filled bar, no numeric "lowest" summary |
| Explicit unlimited metric only | `INF` and unlimited fill; no numeric 100% summary |
| Unknown limit plus unlimited metric | Unknown state, no unlimited fill for the account |
| Bounded metric with remaining `100` or `0` | Real full/empty geometry and matching percentage |
| Loaded settings with no accounts, including an old snapshot | "No accounts configured" |
| All configured accounts disabled | "No enabled accounts" |
| Enabled account with missing/empty snapshot | "Awaiting quota data" |
| Every enabled account fails, no last-good usage | "All accounts unavailable"; current failure count when enabled |
| Last-good usage retained alongside a current failure | Usage row and current failure count |
| Settings/snapshot `.unavailable` | "Storage unavailable", never onboarding |
| Missing settings with an existing snapshot | "Storage unavailable" |

Repeat unknown/unlimited cases with percentages hidden and dual limits enabled.
Status text must remain visible; unknown metrics must not become bar stops.
Check placeholder/gallery previews and the trend widget with existing history.

For the stored-entry boundary, load malformed synthetic settings and snapshot
files separately and request a widget reload. Both must yield storage-unavailable
states. App Group resolution/read failures must take the same path. Restore the
fixtures afterward. Keep the host's account credentials out of this container.

Native rendering, App Group access and accessibility require macOS. PR build
checks cover native compilation; they do not prove screenshots or VoiceOver.
