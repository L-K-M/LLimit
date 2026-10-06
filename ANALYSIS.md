# LLimit Architecture & Feature Analysis

This document compiles high-quality, shovel-ready architectural improvements, bug fixes, performance optimizations, and feature enhancements for LLimit across macOS and Linux.

---

## 1. Performance and Responsiveness Optimizations

### 1.1 Asynchronous & Debounced Settings Persistence
- **Affected Area**: `LLimitApp/AppModel.swift:163-185, 1170-1206, 1589-1625`
- **Problem**: In `SettingsView`, every keystroke in account name (`TextField`) or credential fields triggers SwiftUI binding setters that invoke `updateAccount` -> `saveConfiguration()`. `saveConfiguration()` synchronously performs JSON encoding, creates directories, and executes atomic file writes to both the local settings file (`~/Library/Application Support/LLimit/quota-settings.json`) and the App Group container synchronously on `@MainActor`. This causes noticeable typing lag and stuttering in Settings.
- **Solution**:
  - Debounce configuration disk writes with a short delay (e.g., 500ms after the user stops typing).
  - Move JSON encoding and file I/O off `@MainActor` onto a detached background task or dedicated persistence actor.
  - Flush pending writes immediately on window close, application termination, or when explicit actions (like "Test Connection" or "Refresh All") are triggered.

### 1.2 Eliminate Venice API Key Invalidation Avalanche
- **Affected Area**: `LLimitApp/AppModel.swift:1601-1614, 1627-1638`
- **Problem**: In `updateAccount`, when any edit occurs to an account with `provider == .venice`, if the key value differs, `invalidateVeniceUsage()` is invoked immediately on every single keystroke. This method loads the complete 45-day `quota-history.json` archive, filters out the account, re-encodes up to 3,000 snapshots, and writes it back to disk on `@MainActor`. Typing or pasting a 32-character Venice key triggers 32 full history load-decode-filter-encode-save cycles on the main thread, resulting in severe multi-second UI hangs.
- **Solution**: Defer Venice usage invalidation until the user finishes editing (e.g. on focus loss, Return key, or when the account is verified/refreshed), rather than on intermediate partial keystrokes.

### 1.3 Compact Trend Data Transfer for WidgetKit Memory Budget
- **Affected Area**: `Packages/QuotaCore/Sources/QuotaCore/QuotaHistoryStore.swift:31-41`, `LLimitWidgetExtension/LLimitQuotaWidget.swift:72-74`
- **Problem**: `QuotaHistoryStore.loadRecent(days:maxEntries:now:)` decodes the full history JSON file into memory before filtering for the requested cutoff date. In macOS WidgetKit, extension processes operate under a strict 30MB memory limit enforced by `chronod`. A 45-day history archive with thousands of snapshots can easily exceed this limit during JSON parsing, causing the widget extension to crash or fail to refresh.
- **Solution**: Maintain a compact, pre-filtered trend snapshot DTO (`quota-trend.json`) containing only downsampled points for the widget, updated during the app's refresh cycle so widgets never need to parse full history archives.

---

## 2. Core Architecture and Code Quality

### 2.1 Unified Provider Metadata Definition
- **Affected Area**: `QuotaProvider` enum in `Models.swift`, `ProviderMetricSelection.swift`, `WidgetStylePreset.swift`, `LLimitApp.swift`
- **Problem**: Adding or updating a provider currently requires modifying at least 6 separate exhaustive switches across `Models.displayName`, `Models.credentialFields`, `ProviderMetricSelection.defaultRingMetrics`, `WidgetStylePreset.compactProviderName`, `ProviderTile.palette`, and `ProviderMark.symbolName`.
- **Solution**: Introduce a unified `ProviderDescriptor` or `ProviderMetadata` registry in `QuotaCore`. Each provider defines its display name, default ring metrics, brand color palette, SF Symbol / icon name, and required credential descriptors in one canonical location.

### 2.2 Structured Failure Diagnostics and Retry Timing
- **Affected Area**: `Packages/QuotaCore/Sources/QuotaCore/Models.swift:385-421`
- **Problem**: `ProviderFailure` only captures `(accountID, provider, kind, message)`. It lacks `failedAt: Date`, `httpStatusCode: Int?`, and `retryAfter: Date?`.
- **Solution**: Extend `ProviderFailure` with timestamp and optional retry metadata (e.g., extracted from `Retry-After` HTTP headers). This allows display surfaces (status bars, widgets, and dropdown cards) to display actionable countdowns ("Rate limited; retries in 2m" or "Server 503; backing off") rather than static error text.

---

## 3. UI, UX, and Layout Improvements

### 3.1 Configurable Menu Bar Icon Modes
- **Affected Area**: `LLimitApp/LLimitApp.swift:185-214`
- **Problem**: `MenuBarIcon` computes `totalWidth = providers.count * barWidth + (providers.count - 1) * barSpacing`. With 8-12 accounts configured, the menu bar item stretches to 50-70 points wide, crowding out other status items on MacBook displays with camera notches.
- **Solution**: Add an "Icon Display Mode" preference in Settings:
  1. *Multi-bar* (current default: one bar per account).
  2. *Most constrained account* (compact single bar showing the lowest remaining quota).
  3. *Aggregate gauge / battery style* (fixed width 18pt ring or gauge).
  4. *Monochrome template icon* (system symbol with optional badge dot).

### 3.2 Adaptive Settings Layout & Non-Color Accessibility
- **Affected Area**: `LLimitApp/Views/SettingsView.swift:20, 103-106, 381`
- **Problem**: `settingsLabelWidth = 180` is hardcoded. On smaller windows or localized languages, labels clip or push input fields beyond the visible boundary. Account status in the sidebar uses colored dots without non-color indicators, making it hard for colorblind users to distinguish states.
- **Solution**:
  - Replace fixed-width rows with adaptive SwiftUI `Grid` or `Form` layouts that wrap naturally.
  - Complement colored status dots with subtle symbols or VoiceOver labels (e.g. checkmark for active, warning triangle for rate-limited, exclamation for auth failure) for "Differentiate Without Color" accessibility.

---

## 4. Shovel-Ready Feature Ideas

### 4.1 "Best Account / Model to Burn" Recommendation Engine
- **Concept**: Intelligently recommends the best account/provider to use for the next large task.
- **Value**: Instead of mentally scanning 6 different gauges, a single clear recommendation ("Use Claude: 85% remaining, resets in 42m" or "Use OpenAI: 92% headroom") saves time and prevents unnecessary rate-limit exhaustion.
- **Algorithm**: Rank accounts by remaining percentage headroom, weighted by proximity to reset (spending quota right before a reset is optimal).
- **Surfaces**: Expose in the menu-bar dashboard header card, `llimit status --json`, and an optional `llimit recommend` CLI command.

### 4.2 Shell Prompt & CLI Companion Integration
- **Concept**: Lightweight command to output a one-line status string formatted for shell prompts (`starship`, `zsh`, `bash`, `tmux`).
- **Command**: `llimit prompt` or `llimit status --compact`.
- **Output**: `[Claude: 84% | GPT: 62%]` with ANSI color formatting.
- **Value**: Gives developers continuous quota visibility directly in their terminal workflows.

### 4.3 History Data Export (JSON & CSV)
- **Concept**: Command and UI button to export historical quota snapshots.
- **Value**: Allows users to analyze their usage trends over weeks/months, calculate actual token consumption, and budget AI expenses.
- **Command**: `llimit export --format json|csv [--days 30]`.
- **macOS**: "Export History..." button in Settings → General.

### 4.4 Configurable Warning & Alert Thresholds
- **Concept**: Allow users to configure when warnings trigger (currently hardcoded to 80% used / 20% remaining).
- **Settings**: Low quota threshold (e.g. 15% remaining), warning threshold (e.g. 30% remaining).
- **Value**: Power users can align thresholds with their preferred buffer before switching accounts.

---

## 5. Delight & Aesthetic Enhancements

### 5.1 Popular Developer Theme Presets
- Add well-known developer color palettes alongside existing presets in `WidgetStylePreset.swift`:
  - **Catppuccin Mocha**: Rosewater/Mauve/Sapphire on dark slate.
  - **Nord**: Frost blue and snow storm on polar night.
  - **Tokyo Night**: Deep indigo with neon accents.
  - **Monokai Pro**: Vivid amber, magenta, and cyan on charcoal.

### 5.2 Quota Pacing Indicator (Burn Rate vs Time Remaining)
- Shows whether current usage is "Ahead of Pace" (burning too fast before reset) or "On Track" (sustainable pace).
- Example: If 20% of the weekly window has elapsed but 70% of the quota is consumed, flag "Ahead of pace (burning fast)".

### 5.3 Quota Weather Report
- Translates multi-account quota state into playful meteorological copy in the dashboard:
  - ☀️ *Clear Skies*: All accounts > 50% headroom.
  - ⛅ *Partly Cloudy*: 1 account < 30% headroom.
  - 🌧️ *Showers*: Multiple accounts constrained.
  - ⛈️ *Storm Warning*: Rate limits active or exhaustion imminent.

### 5.4 Quota Roulette / Quick Pick
- Quirky developer feature: A button or command that randomly picks an account with high headroom (> 60%) to distribute load and keep subscriptions balanced.
