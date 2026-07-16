import Foundation
import SwiftUI
import WidgetKit
import QuotaCore

// The provider tiles deliberately have NO widget-side configuration. The macOS
// "Edit Widget" flow proved unreliable across builds 7-13 (see ANALYSIS.md), so
// account selection lives in LLimit's Settings instead: each numbered tile reads
// its slot assignment from the shared settings file, and the app reloads widget
// timelines whenever an assignment changes. Unassigned tiles auto-fill with the
// enabled accounts not pinned to any tile (AppSettings.providerTileAutoCandidates)
// and wear a #N badge, so placing tiles 1..N maps them 1:1 onto accounts with no
// setup and auto tiles never duplicate pinned ones.
//
// WidgetKit registers widget kinds at compile time, one type per kind — the slot
// count cannot be dynamic. Keep these types in sync with
// AppSettings.providerTileSlotCount.

struct ProviderTileSlot1Widget: Widget {
  var body: some WidgetConfiguration {
    providerTileConfiguration(slotIndex: 0, displayName: "Provider Tile 1")
  }
}

struct ProviderTileSlot2Widget: Widget {
  var body: some WidgetConfiguration {
    providerTileConfiguration(slotIndex: 1, displayName: "Provider Tile 2")
  }
}

struct ProviderTileSlot3Widget: Widget {
  var body: some WidgetConfiguration {
    providerTileConfiguration(slotIndex: 2, displayName: "Provider Tile 3")
  }
}

struct ProviderTileSlot4Widget: Widget {
  var body: some WidgetConfiguration {
    providerTileConfiguration(slotIndex: 3, displayName: "Provider Tile 4")
  }
}

struct ProviderTileSlot5Widget: Widget {
  var body: some WidgetConfiguration {
    providerTileConfiguration(slotIndex: 4, displayName: "Provider Tile 5")
  }
}

struct ProviderTileSlot6Widget: Widget {
  var body: some WidgetConfiguration {
    providerTileConfiguration(slotIndex: 5, displayName: "Provider Tile 6")
  }
}

struct ProviderTileSlot7Widget: Widget {
  var body: some WidgetConfiguration {
    providerTileConfiguration(slotIndex: 6, displayName: "Provider Tile 7")
  }
}

struct ProviderTileSlot8Widget: Widget {
  var body: some WidgetConfiguration {
    providerTileConfiguration(slotIndex: 7, displayName: "Provider Tile 8")
  }
}

// configurationDisplayName/description MUST be plain, non-formatted text: an
// interpolated string literal becomes a LocalizedStringKey with format
// arguments, and WidgetKit fatal-errors on those when archiving the gallery
// metadata ("Formatted text for `configurationDisplayName` is not supported"),
// killing the whole extension. Hence literal per-slot names + Text(verbatim:).
private func providerTileConfiguration(
  slotIndex: Int,
  displayName: String
) -> some WidgetConfiguration {
  StaticConfiguration(
    kind: SharedConstants.providerSlotWidgetKinds[slotIndex],
    provider: ProviderTileTimelineProvider(slotIndex: slotIndex)
  ) { entry in
    ProviderQuotaTileView(entry: entry)
      .providerTileBackground(entry: entry)
  }
  .configurationDisplayName(Text(verbatim: displayName))
  .description(Text(verbatim: "Quota rings for one LLimit account. Assign accounts in LLimit's Settings → Widgets."))
  .supportedFamilies([.systemSmall])
  .contentMarginsDisabled()
}

/// The account a tile resolved for display.
struct ProviderTileSelection: Sendable {
  let id: String
  let displayName: String
  let provider: QuotaProvider
}

extension ProviderTileSelection {
  init(_ account: ProviderAccount) {
    self.init(
      id: account.id,
      displayName: account.resolvedDisplayName,
      provider: account.provider
    )
  }
}

/// How the tile's account was resolved, so the view can explain every state
/// instead of silently showing the wrong thing.
enum ProviderTileAccountState: Sendable {
  case configured
  /// Unassigned slot showing the Nth enabled account automatically.
  case autoSelected
  case accountDisabled
  case accountRemoved
  /// Unassigned slot whose number exceeds the enabled-account count.
  case awaitingAccount
  case noAccounts
}

struct ProviderQuotaEntry: TimelineEntry {
  let date: Date
  let slotIndex: Int
  let account: ProviderTileSelection?
  let accountState: ProviderTileAccountState
  let usage: ProviderUsage?
  let failure: ProviderFailure?
  /// Effective style for the shown account: per-account override merged with
  /// the global style, same resolution as the dashboard widget.
  let style: WidgetStyleSettings
  let refreshIntervalMinutes: Int
  /// Which color-scheme variant this account wears (accountColorStep) — the
  /// rings double as the trend chart's legend, so tiles for different
  /// accounts must never share an exact scheme.
  var accountColorStep = 0
}

struct ProviderTileTimelineProvider: TimelineProvider {
  let slotIndex: Int

  func placeholder(in context: Context) -> ProviderQuotaEntry {
    Self.sampleEntry(slotIndex: slotIndex, at: Date())
  }

  func getSnapshot(in context: Context, completion: @escaping (ProviderQuotaEntry) -> Void) {
    if context.isPreview {
      completion(Self.sampleEntry(slotIndex: slotIndex, at: Date()))
      return
    }
    completion(loadEntry(at: Date()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<ProviderQuotaEntry>) -> Void) {
    let now = Date()
    let entry = loadEntry(at: now)
    let refreshMinutes = min(max(entry.refreshIntervalMinutes, 15), 180)
    let refreshInterval = TimeInterval(refreshMinutes) * 60
    let nextRefresh = now.addingTimeInterval(refreshInterval)

    var entryDates: Set<Date> = [now, nextRefresh]
    var offset: TimeInterval = 5 * 60
    while offset < refreshInterval {
      entryDates.insert(now.addingTimeInterval(offset))
      offset += 5 * 60
    }
    if let usage = entry.usage {
      for resetAt in defaultRingMetrics(for: usage).compactMap(\.resetAt)
        where resetAt > now && resetAt < nextRefresh
      {
        entryDates.insert(resetAt)
      }
    }

    let entries = entryDates.sorted().map { date in
      ProviderQuotaEntry(
        date: date,
        slotIndex: entry.slotIndex,
        account: entry.account,
        accountState: entry.accountState,
        usage: entry.usage,
        failure: entry.failure,
        style: entry.style,
        refreshIntervalMinutes: entry.refreshIntervalMinutes,
        accountColorStep: entry.accountColorStep
      )
    }
    completion(Timeline(entries: entries, policy: .after(nextRefresh)))
  }

  private func loadEntry(at date: Date) -> ProviderQuotaEntry {
    let settings = loadSettings()
    let allAccounts = settings.accounts
    let enabledAccounts = allAccounts.filter(\.isEnabled)

    let accountState: ProviderTileAccountState
    let effectiveAccount: ProviderAccount?
    let selection: ProviderTileSelection?

    if let assignedID = settings.providerTileAssignment(forSlot: slotIndex) {
      if let match = enabledAccounts.first(where: { $0.id == assignedID }) {
        accountState = .configured
        effectiveAccount = match
        selection = ProviderTileSelection(match)
      } else if let disabled = allAccounts.first(where: { $0.id == assignedID }) {
        accountState = .accountDisabled
        effectiveAccount = nil
        selection = ProviderTileSelection(disabled)
      } else {
        accountState = .accountRemoved
        effectiveAccount = nil
        selection = nil
      }
    } else {
      // Unassigned slot: auto-fill from the enabled accounts that are not
      // pinned to any tile, so auto tiles never duplicate pinned ones and
      // placing tiles 1..N covers all accounts without any configuration.
      let candidates = settings.providerTileAutoCandidates()
      let rank = settings.providerTileAutoRank(forSlot: slotIndex) ?? 0
      if candidates.indices.contains(rank) {
        accountState = .autoSelected
        effectiveAccount = candidates[rank]
        selection = ProviderTileSelection(candidates[rank])
      } else if enabledAccounts.isEmpty {
        accountState = .noAccounts
        effectiveAccount = nil
        selection = nil
      } else {
        accountState = .awaitingAccount
        effectiveAccount = nil
        selection = nil
      }
    }

    let snapshot = loadSnapshot()
    let usage = effectiveAccount.flatMap { account in
      snapshot?.providers.first(where: { $0.accountID == account.id })
        ?? legacyUsage(for: account, in: snapshot, accounts: allAccounts)
    }
    let failure = effectiveAccount.flatMap { account in
      snapshot?.failures.first(where: { $0.accountID == account.id })
        ?? legacyFailure(for: account, in: snapshot, accounts: allAccounts)
    }

    // Hoisted into typed locals: this construction once tripped the type
    // checker's per-expression budget on CI (Swift "unable to type-check
    // this expression in reasonable time").
    let style: WidgetStyleSettings = effectiveStyle(for: selection?.id, settings: settings)
    let refreshMinutes: Int = max(15, settings.refreshIntervalMinutes)
    let colorStep: Int = selection.map { accountColorStep(forAccountID: $0.id, in: allAccounts) } ?? 0
    return ProviderQuotaEntry(
      date: date,
      slotIndex: slotIndex,
      account: selection,
      accountState: accountState,
      usage: usage,
      failure: failure,
      style: style,
      refreshIntervalMinutes: refreshMinutes,
      accountColorStep: colorStep
    )
  }

  private func loadSettings() -> AppSettings {
    guard
      let fileURL = try? SharedPaths.settingsFileURL(),
      let settings = try? SettingsStore(fileURL: fileURL).load()
    else {
      return .default
    }
    return settings
  }

  private func loadSnapshot() -> QuotaSnapshot? {
    guard let fileURL = try? SharedPaths.snapshotFileURL() else { return nil }
    return try? SnapshotStore(
      fileURL: fileURL,
      appGroupIdentifier: SharedConstants.appGroupIdentifier
    ).load()
  }

  private func legacyUsage(
    for account: ProviderAccount,
    in snapshot: QuotaSnapshot?,
    accounts: [ProviderAccount]
  ) -> ProviderUsage? {
    guard accounts.filter({ $0.provider == account.provider }).count == 1 else { return nil }
    return snapshot?.providers.first {
      $0.provider == account.provider && $0.accountID == account.provider.rawValue
    }
  }

  private func legacyFailure(
    for account: ProviderAccount,
    in snapshot: QuotaSnapshot?,
    accounts: [ProviderAccount]
  ) -> ProviderFailure? {
    guard accounts.filter({ $0.provider == account.provider }).count == 1 else { return nil }
    return snapshot?.failures.first {
      $0.provider == account.provider && $0.accountID == account.provider.rawValue
    }
  }

  private func effectiveStyle(for accountID: String?, settings: AppSettings) -> WidgetStyleSettings {
    guard let accountID else { return settings.widgetStyle }
    let override = settings.styleOverride(for: accountID)
    guard override.useCustomStyle else { return settings.widgetStyle }
    // Limit-kind colors are global identity — per-account overrides only
    // customize the background.
    return WidgetStyleSettings(
      backgroundHexColor: override.style.backgroundHexColor ?? settings.widgetStyle.backgroundHexColor,
      ringColors: override.style.ringColors,
      limitKindColors: settings.widgetStyle.limitKindColors,
      useTransparentBackground: override.style.useTransparentBackground
    )
  }

  private static func sampleEntry(slotIndex: Int, at date: Date) -> ProviderQuotaEntry {
    let account = ProviderTileSelection(id: "sample-zai", displayName: "Z.ai", provider: .zai)
    // Hoisted into typed locals: the nested single-expression construction
    // once tripped the type checker's per-expression budget on CI.
    let tokensReset: TimeInterval = 3 * 3_600 + 44 * 60
    let mcpReset: TimeInterval = 6 * 86_400 + 19 * 3_600 + 43 * 60
    let metrics: [UsageMetric] = [
      UsageMetric(
        id: "tokens",
        label: "Token limit",
        remainingPercent: 82,
        resetAt: date.addingTimeInterval(tokensReset)
      ),
      UsageMetric(
        id: "mcp",
        label: "MCP monthly quota",
        remainingPercent: 64,
        resetAt: date.addingTimeInterval(mcpReset)
      )
    ]
    let usage = ProviderUsage(
      accountID: account.id,
      provider: .zai,
      title: account.displayName,
      metrics: metrics,
      fetchedAt: date
    )
    return ProviderQuotaEntry(
      date: date,
      slotIndex: slotIndex,
      account: account,
      accountState: .configured,
      usage: usage,
      failure: nil,
      style: WidgetStyleSettings(),
      refreshIntervalMinutes: 30,
      // Gallery previews cycle the scheme variants so slots visibly differ.
      accountColorStep: slotIndex % accountColorVariantCount
    )
  }
}

private struct ProviderQuotaTileView: View {
  let entry: ProviderQuotaEntry

  var body: some View {
    // The gradient container background is the tile's only frame; anything drawn
    // near the edge reads as a second border inside the system's rounded corner.
    Group {
      if
        let account = entry.account,
        let usage = entry.usage,
        !defaultRingMetrics(for: usage).isEmpty
      {
        loadedContent(account: account, usage: usage)
      } else if let account = entry.account {
        unavailableContent(account: account, hasUsageWithoutPercentage: entry.usage != nil)
      } else {
        switch entry.accountState {
        case .accountRemoved:
          slotPlaceholder(
            symbol: "questionmark.circle",
            message: "Assigned account no longer exists — reassign in LLimit's Settings"
          )
        case .awaitingAccount:
          slotPlaceholder(
            symbol: "person.crop.circle.badge.plus",
            message: "No account left for this tile — lower-numbered tiles cover them all. Add an account or assign one in LLimit's Settings"
          )
        default:
          noAccountsContent
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilitySummary)
  }

  private func loadedContent(account: ProviderTileSelection, usage: ProviderUsage) -> some View {
    let metrics = defaultRingMetrics(for: usage)
    let tints = ringTints(for: metrics, in: usage)

    return VStack(spacing: 5) {
      ProviderConcentricRings(
        metrics: metrics,
        name: account.displayName,
        tints: tints
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      resetFooter(metrics: metrics, tints: tints)
    }
    .padding(.horizontal, 14)
    .padding(.top, 13)
    .padding(.bottom, 12)
    .overlay(alignment: .topTrailing) {
      if isStale(usage) {
        Image(systemName: "exclamationmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.orange, .black.opacity(0.35))
          .padding(10)
          .accessibilityHidden(true)
      }
    }
    .overlay(alignment: .topLeading) {
      // Number badge only while the tile is auto-mapped, so users can match
      // desktop tiles to the numbered rows in Settings → Widgets.
      if entry.accountState == .autoSelected {
        Text("#\(entry.slotIndex + 1) AUTO")
          .font(.system(size: 7, weight: .bold))
          .tracking(0.5)
          .foregroundStyle(.white.opacity(0.6))
          .padding(.horizontal, 5)
          .padding(.vertical, 2)
          .background(.black.opacity(0.25), in: Capsule())
          .padding(10)
          .accessibilityHidden(true)
      }
    }
  }

  private func unavailableContent(
    account: ProviderTileSelection,
    hasUsageWithoutPercentage: Bool
  ) -> some View {
    VStack(spacing: 7) {
      Image(systemName: unavailableSymbol(hasUsageWithoutPercentage: hasUsageWithoutPercentage))
        .font(.title2)
      Text(account.displayName)
        .font(.headline)
        .lineLimit(2)
        .multilineTextAlignment(.center)
      Text(unavailableMessage(hasUsageWithoutPercentage: hasUsageWithoutPercentage))
        .font(.caption2)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding(16)
  }

  private func unavailableSymbol(hasUsageWithoutPercentage: Bool) -> String {
    switch entry.accountState {
    case .accountDisabled:
      return "pause.circle"
    default:
      if entry.failure != nil { return "exclamationmark.triangle.fill" }
      return hasUsageWithoutPercentage ? "questionmark.circle" : "arrow.clockwise.circle"
    }
  }

  private func unavailableMessage(hasUsageWithoutPercentage: Bool) -> String {
    switch entry.accountState {
    case .accountDisabled:
      return "Account disabled in LLimit"
    default:
      if entry.failure != nil { return "Quota unavailable" }
      return hasUsageWithoutPercentage ? "Quota percentage unavailable" : "Refresh in LLimit"
    }
  }

  private func slotPlaceholder(symbol: String, message: String) -> some View {
    VStack(spacing: 7) {
      Image(systemName: symbol)
        .font(.title2)
      Text("Tile \(entry.slotIndex + 1)")
        .font(.headline)
      Text(message)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding(14)
  }

  private var noAccountsContent: some View {
    VStack(spacing: 7) {
      Image(systemName: "gauge.with.dots.needle.bottom.50percent")
        .font(.title2)
      Text("No accounts yet")
        .font(.headline)
      Text("Add an account in LLimit to fill this tile")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding(16)
  }

  private func resetFooter(metrics: [UsageMetric], tints: [Color]) -> some View {
    HStack(spacing: 6) {
      ForEach(Array(metrics.prefix(2).enumerated()), id: \.offset) { index, metric in
        if index > 0 {
          Text("•")
            .foregroundStyle(.white.opacity(0.42))
        }
        Image(systemName: index == 0 ? "circle" : "smallcircle.filled.circle")
          .font(.system(size: 7, weight: .bold))
          .foregroundStyle(index < tints.count ? tints[index] : .white)
        Text(resetSummary(for: metric))
          .font(.caption2.weight(.semibold))
          .monospacedDigit()
          .lineLimit(1)
      }
    }
    .foregroundStyle(.white.opacity(0.72))
    .frame(height: 13)
  }

  /// Each ring wears its metric's limit-kind identity color, resolved against
  /// the account's full metric list so the tile, the dashboard, and the trend
  /// chart always agree about which color a limit owns.
  private func ringTints(for metrics: [UsageMetric], in usage: ProviderUsage) -> [Color] {
    let metricColors = LimitKindColorScheme.colors(
      for: usage.metrics,
      colors: entry.style.limitKindColors,
      step: entry.accountColorStep
    )

    return metrics.map { metric in
      guard let index = usage.metrics.firstIndex(of: metric) else {
        return LimitKindColorScheme.color(hex: entry.style.limitKindColors.hexColor(for: .other)) ?? .white
      }
      return metricColors[index]
    }
  }

  private func isStale(_ usage: ProviderUsage) -> Bool {
    if entry.failure != nil { return true }
    if defaultRingMetrics(for: usage).contains(where: { metric in
      guard let resetAt = metric.resetAt else { return false }
      return resetAt <= entry.date
    }) {
      return true
    }
    let refreshMinutes = min(max(entry.refreshIntervalMinutes, 15), 180)
    let staleAfter = max(3_600, TimeInterval(refreshMinutes) * 120)
    return entry.date.timeIntervalSince(usage.fetchedAt) > staleAfter
  }

  private var accessibilitySummary: String {
    guard let account = entry.account else {
      switch entry.accountState {
      case .accountRemoved:
        return "LLimit provider tile \(entry.slotIndex + 1). The assigned account no longer exists. Reassign it in LLimit's settings."
      case .awaitingAccount:
        return "LLimit provider tile \(entry.slotIndex + 1). No account left for this tile; lower-numbered tiles cover them all. Add another account or assign one in LLimit's settings."
      default:
        return "LLimit provider quota. Add an account in LLimit."
      }
    }

    if entry.accountState == .accountDisabled {
      return "\(account.displayName). Account is disabled in LLimit."
    }

    guard let usage = entry.usage else {
      if let failure = entry.failure {
        return "\(account.displayName). Quota unavailable. \(failure.kind.rawValue)."
      }
      return "\(account.displayName). No quota data. Refresh in LLimit."
    }

    let metrics = defaultRingMetrics(for: usage)
    guard !metrics.isEmpty else {
      if let failure = entry.failure {
        return "\(account.displayName). Quota unavailable. \(failure.kind.rawValue)."
      }
      return "\(account.displayName). Quota percentage unavailable."
    }

    let metricSummary = metrics.map { metric in
      let quota: String
      if metric.isUnlimited {
        quota = "unlimited"
      } else if let remaining = metric.remainingPercent {
        quota = "\(remaining) percent remaining"
      } else {
        quota = "remaining quota unknown"
      }
      let reset = resetSummary(for: metric, expanded: true)
      return "\(metric.label), \(quota), \(reset)"
    }.joined(separator: ". ")

    let freshness = isStale(usage) ? "Data is stale." : "Data is current."
    let failureState = entry.failure == nil ? "" : " Latest refresh failed."
    return "\(account.displayName). \(metricSummary). \(freshness)\(failureState)"
  }

  private func resetSummary(for metric: UsageMetric, expanded: Bool = false) -> String {
    if let resetAt = metric.resetAt {
      let interval = resetAt.timeIntervalSince(entry.date)
      guard interval.isFinite, interval > 0 else { return expanded ? "reset due" : "now" }
      let totalMinutes = Int(min(interval / 60, 525_600))
      let days = totalMinutes / 1_440
      let hours = (totalMinutes % 1_440) / 60
      let minutes = totalMinutes % 60

      let compact: String
      if days > 0 {
        compact = hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
      } else if hours > 0 {
        compact = minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
      } else {
        compact = "\(minutes)m"
      }
      return expanded ? "resets in \(compact)" : compact
    }

    let fallback = metric.resetIn?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let fallback, !fallback.isEmpty {
      return expanded ? "resets in \(fallback)" : fallback
    }
    return expanded ? "reset time unknown" : "--"
  }
}

private struct ProviderConcentricRings: View {
  let metrics: [UsageMetric]
  let name: String
  let tints: [Color]

  var body: some View {
    GeometryReader { proxy in
      let side = min(proxy.size.width, proxy.size.height)
      let outer = metrics.first
      let inner = metrics.dropFirst().first

      ZStack {
        if let outer {
          ProviderTileRing(
            metric: outer,
            color: tints.first ?? .white,
            lineWidth: max(9, side * 0.095)
          )
          .frame(width: side, height: side)
        }

        if let inner {
          ProviderTileRing(
            metric: inner,
            color: tints.dropFirst().first ?? .white,
            lineWidth: max(7, side * 0.08)
          )
          .frame(width: side * 0.62, height: side * 0.62)
        }

        Text(name)
          .font(.subheadline.weight(.bold))
          .foregroundStyle(.white)
          .shadow(color: .black.opacity(0.35), radius: 2)
          .lineLimit(2)
          .minimumScaleFactor(0.68)
          .multilineTextAlignment(.center)
          .frame(width: side * (inner == nil ? 0.56 : 0.48))
      }
      .frame(width: side, height: side)
      .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
    }
  }
}

private struct ProviderTileRing: View {
  let metric: UsageMetric
  let color: Color
  let lineWidth: CGFloat

  var body: some View {
    ZStack {
      Circle()
        .strokeBorder(Color.white.opacity(0.14), lineWidth: lineWidth)
      if progress > 0.001 {
        Circle()
          .trim(from: 0, to: progress)
          .stroke(
            AngularGradient(
              gradient: Gradient(colors: [color.opacity(0.55), color]),
              center: .center,
              startAngle: .degrees(0),
              endAngle: .degrees(360 * progress)
            ),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
          )
          .rotationEffect(.degrees(-90))
          .shadow(color: color.opacity(0.45), radius: 2.5)
          .padding(lineWidth / 2)
      }
    }
  }

  private var progress: CGFloat {
    if metric.isUnlimited { return 1 }
    return CGFloat(max(0, min(100, metric.remainingPercent ?? 0))) / 100
  }
}

private extension View {
  /// Honors the effective style like the dashboard widget: transparent wins,
  /// then a custom background color, then the provider-toned gradient.
  @ViewBuilder
  func providerTileBackground(entry: ProviderQuotaEntry) -> some View {
    if entry.style.useTransparentBackground {
      self.containerBackground(.clear, for: .widget)
    } else {
      self.containerBackground(for: .widget) {
        ProviderTileBackground(
          provider: entry.account?.provider,
          customHexColor: entry.style.backgroundHexColor
        )
      }
    }
  }
}

private struct ProviderTileBackground: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  let provider: QuotaProvider?
  let customHexColor: String?

  var body: some View {
    ContainerRelativeShape()
      .fill(
        LinearGradient(
          colors: palette,
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
      .overlay {
        ContainerRelativeShape()
          .fill(
            LinearGradient(
              colors: [
                Color.white.opacity(reduceTransparency ? 0.05 : 0.15),
                Color.clear,
                Color.black.opacity(0.16)
              ],
              startPoint: .top,
              endPoint: .bottom
            )
          )
      }
  }

  private var palette: [Color] {
    // A configured background color replaces the provider tint; the gloss
    // overlay above still gives the flat color its dimensionality.
    if let customHexColor, let custom = Color(providerTileHex: customHexColor) {
      return [custom, custom]
    }

    switch provider {
    case .anthropic:
      return [Color(red: 0.72, green: 0.39, blue: 0.25), Color(red: 0.38, green: 0.21, blue: 0.16)]
    case .openAI:
      return [Color(red: 0.19, green: 0.36, blue: 0.34), Color(red: 0.08, green: 0.14, blue: 0.15)]
    case .gitHubCopilot:
      return [Color(red: 0.34, green: 0.24, blue: 0.62), Color(red: 0.12, green: 0.13, blue: 0.28)]
    case .zhipu:
      return [Color(red: 0.24, green: 0.45, blue: 0.74), Color(red: 0.16, green: 0.22, blue: 0.43)]
    case .zai:
      return [Color(red: 0.63, green: 0.44, blue: 0.27), Color(red: 0.35, green: 0.22, blue: 0.12)]
    case .kimi:
      return [Color(red: 0.52, green: 0.27, blue: 0.55), Color(red: 0.24, green: 0.13, blue: 0.30)]
    case .googleAntigravity:
      return [Color(red: 0.28, green: 0.48, blue: 0.75), Color(red: 0.25, green: 0.24, blue: 0.38)]
    case nil:
      return [Color(red: 0.32, green: 0.39, blue: 0.52), Color(red: 0.16, green: 0.2, blue: 0.29)]
    }
  }
}

private extension Color {
  init?(providerTileHex value: String) {
    var raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.hasPrefix("#") { raw.removeFirst() }
    if raw.count == 3 || raw.count == 4 {
      raw = raw.map { "\($0)\($0)" }.joined()
    }
    guard (raw.count == 6 || raw.count == 8), let parsed = UInt64(raw, radix: 16) else {
      return nil
    }

    if raw.count == 6 {
      self = Color(
        red: Double((parsed >> 16) & 0xFF) / 255,
        green: Double((parsed >> 8) & 0xFF) / 255,
        blue: Double(parsed & 0xFF) / 255
      )
    } else {
      self = Color(
        red: Double((parsed >> 24) & 0xFF) / 255,
        green: Double((parsed >> 16) & 0xFF) / 255,
        blue: Double((parsed >> 8) & 0xFF) / 255,
        opacity: Double(parsed & 0xFF) / 255
      )
    }
  }
}
