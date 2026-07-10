import AppIntents
import Foundation
import SwiftUI
import WidgetKit
import QuotaCore

struct ProviderAccountEntity: AppEntity {
  static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "LLimit Account")
  static var defaultQuery = ProviderAccountQuery()

  let id: String
  let displayName: String
  let provider: QuotaProvider

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(
      title: "\(displayName)",
      subtitle: "\(provider.displayName)"
    )
  }
}

struct ProviderAccountQuery: EntityQuery {
  func entities(for identifiers: [ProviderAccountEntity.ID]) async throws -> [ProviderAccountEntity] {
    let requested = Set(identifiers)
    return try loadEntities().filter { requested.contains($0.id) }
  }

  func suggestedEntities() async throws -> [ProviderAccountEntity] {
    try loadEntities()
  }

  private func loadEntities() throws -> [ProviderAccountEntity] {
    let settingsURL = try SharedPaths.settingsFileURL()
    let settings = try SettingsStore(fileURL: settingsURL).load()
    return settings.accounts
      .filter(\.isEnabled)
      .map(ProviderAccountEntity.init)
  }
}

private extension ProviderAccountEntity {
  init(_ account: ProviderAccount) {
    id = account.id
    displayName = account.resolvedDisplayName
    provider = account.provider
  }
}

struct ProviderQuotaIntent: WidgetConfigurationIntent {
  static var title: LocalizedStringResource = "Provider Quota"
  static var description = IntentDescription("Choose the LLimit account shown by this quota tile.")

  @Parameter(title: "Account")
  var account: ProviderAccountEntity?

  static var parameterSummary: some ParameterSummary {
    Summary("Show \(\.$account)")
  }
}

struct ProviderQuotaEntry: TimelineEntry {
  let date: Date
  let account: ProviderAccountEntity?
  let usage: ProviderUsage?
  let failure: ProviderFailure?
  let ringColors: WidgetRingColors
  let refreshIntervalMinutes: Int
}

struct ProviderQuotaTimelineProvider: AppIntentTimelineProvider {
  func placeholder(in context: Context) -> ProviderQuotaEntry {
    Self.sampleEntry(at: Date())
  }

  func snapshot(for configuration: ProviderQuotaIntent, in context: Context) async -> ProviderQuotaEntry {
    if context.isPreview {
      return Self.sampleEntry(at: Date())
    }
    return loadEntry(for: configuration, at: Date())
  }

  func timeline(for configuration: ProviderQuotaIntent, in context: Context) async -> Timeline<ProviderQuotaEntry> {
    let now = Date()
    let entry = loadEntry(for: configuration, at: now)
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
        account: entry.account,
        usage: entry.usage,
        failure: entry.failure,
        ringColors: entry.ringColors,
        refreshIntervalMinutes: entry.refreshIntervalMinutes
      )
    }
    return Timeline(entries: entries, policy: .after(nextRefresh))
  }

  private func loadEntry(for configuration: ProviderQuotaIntent, at date: Date) -> ProviderQuotaEntry {
    let settings = loadSettings()
    let enabledAccounts = settings.accounts.filter(\.isEnabled)
    let selectedAccount = configuration.account
      .flatMap { selected in enabledAccounts.first(where: { $0.id == selected.id }) }
    let accountEntity = selectedAccount.map(ProviderAccountEntity.init)

    let snapshot = loadSnapshot()
    let usage = selectedAccount.flatMap { account in
      snapshot?.providers.first(where: { $0.accountID == account.id })
        ?? legacyUsage(for: account, in: snapshot, accounts: settings.accounts)
    }
    let failure = selectedAccount.flatMap { account in
      snapshot?.failures.first(where: { $0.accountID == account.id })
        ?? legacyFailure(for: account, in: snapshot, accounts: settings.accounts)
    }

    return ProviderQuotaEntry(
      date: date,
      account: accountEntity ?? configuration.account,
      usage: usage,
      failure: failure,
      ringColors: ringColors(for: selectedAccount, settings: settings),
      refreshIntervalMinutes: max(15, settings.refreshIntervalMinutes)
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

  private func ringColors(for account: ProviderAccount?, settings: AppSettings) -> WidgetRingColors {
    guard let account else { return settings.widgetStyle.ringColors }
    let override = settings.styleOverride(for: account.id)
    return override.useCustomStyle ? override.style.ringColors : settings.widgetStyle.ringColors
  }

  private static func sampleEntry(at date: Date) -> ProviderQuotaEntry {
    let account = ProviderAccountEntity(id: "sample-zai", displayName: "Z.ai", provider: .zai)
    return ProviderQuotaEntry(
      date: date,
      account: account,
      usage: ProviderUsage(
        accountID: account.id,
        provider: .zai,
        title: account.displayName,
        metrics: [
          UsageMetric(
            id: "tokens",
            label: "Token limit",
            remainingPercent: 82,
            resetAt: date.addingTimeInterval(3 * 3_600 + 44 * 60)
          ),
          UsageMetric(
            id: "mcp",
            label: "MCP monthly quota",
            remainingPercent: 64,
            resetAt: date.addingTimeInterval(6 * 86_400 + 19 * 3_600 + 43 * 60)
          )
        ],
        fetchedAt: date
      ),
      failure: nil,
      ringColors: WidgetRingColors.defaults(for: .warm),
      refreshIntervalMinutes: 30
    )
  }
}

struct ProviderQuotaWidget: Widget {
  var body: some WidgetConfiguration {
    AppIntentConfiguration(
      kind: SharedConstants.providerWidgetKind,
      intent: ProviderQuotaIntent.self,
      provider: ProviderQuotaTimelineProvider()
    ) { entry in
      ProviderQuotaTileView(entry: entry)
        .containerBackground(for: .widget) {
          ProviderTileBackground(provider: entry.account?.provider)
        }
    }
    .configurationDisplayName("Provider Quota Tile")
    .description("Concentric quota rings for one LLimit account. Add one tile per account.")
    .supportedFamilies([.systemSmall])
    .contentMarginsDisabled()
  }
}

private struct ProviderQuotaTileView: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  let entry: ProviderQuotaEntry

  var body: some View {
    ZStack {
      ContainerRelativeShape()
        .inset(by: 7)
        .fill(Color.black.opacity(reduceTransparency ? 0.38 : 0.22))
        .overlay {
          ContainerRelativeShape()
            .inset(by: 7)
            .stroke(Color.white.opacity(0.34), lineWidth: 0.8)
        }

      if
        let account = entry.account,
        let usage = entry.usage,
        !defaultRingMetrics(for: usage).isEmpty
      {
        loadedContent(account: account, usage: usage)
      } else if let account = entry.account {
        unavailableContent(account: account, hasUsageWithoutPercentage: entry.usage != nil)
      } else {
        unconfiguredContent
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilitySummary)
  }

  private func loadedContent(account: ProviderAccountEntity, usage: ProviderUsage) -> some View {
    let metrics = defaultRingMetrics(for: usage)

    return VStack(spacing: 4) {
      ProviderConcentricRings(
        metrics: metrics,
        name: account.displayName,
        colors: entry.ringColors
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      resetFooter(metrics: metrics)
    }
    .padding(.horizontal, 13)
    .padding(.top, 12)
    .padding(.bottom, 11)
    .overlay(alignment: .topTrailing) {
      if isStale(usage) {
        Image(systemName: "exclamationmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.orange, .black.opacity(0.35))
          .padding(12)
          .accessibilityHidden(true)
      }
    }
  }

  private func unavailableContent(
    account: ProviderAccountEntity,
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
    }
    .padding(18)
  }

  private func unavailableSymbol(hasUsageWithoutPercentage: Bool) -> String {
    if entry.failure != nil { return "exclamationmark.triangle.fill" }
    return hasUsageWithoutPercentage ? "questionmark.circle" : "arrow.clockwise.circle"
  }

  private func unavailableMessage(hasUsageWithoutPercentage: Bool) -> String {
    if entry.failure != nil { return "Quota unavailable" }
    return hasUsageWithoutPercentage ? "Quota percentage unavailable" : "Refresh in LLimit"
  }

  private var unconfiguredContent: some View {
    VStack(spacing: 7) {
      Image(systemName: "gauge.with.dots.needle.bottom.50percent")
        .font(.title2)
      Text("Choose an account")
        .font(.headline)
      Text("Edit this widget or add an account in LLimit")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding(18)
  }

  private func resetFooter(metrics: [UsageMetric]) -> some View {
    HStack(spacing: 6) {
      ForEach(Array(metrics.prefix(2).enumerated()), id: \.offset) { index, metric in
        if index > 0 {
          Text("•")
            .foregroundStyle(.white.opacity(0.42))
        }
        Image(systemName: index == 0 ? "circle" : "smallcircle.filled.circle")
          .font(.system(size: 7, weight: .bold))
          .foregroundStyle(ringColor(for: metric, layer: index == 0 ? .outer : .inner))
        Text(resetSummary(for: metric))
          .font(.caption2.weight(.semibold))
          .monospacedDigit()
          .lineLimit(1)
      }
    }
    .foregroundStyle(.white.opacity(0.72))
    .frame(height: 13)
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
      return "LLimit provider quota. Choose an account in the widget settings."
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

  private func ringColor(for metric: UsageMetric, layer: WidgetRingLayer) -> Color {
    let role: WidgetRingColorRole
    if metric.isUnlimited {
      role = .unlimited
    } else if (metric.remainingPercent ?? 0) >= 70 {
      role = .high
    } else if (metric.remainingPercent ?? 0) >= 40 {
      role = .medium
    } else {
      role = .low
    }
    return Color(providerTileHex: entry.ringColors.hexColor(for: role, layer: layer)) ?? .white
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
  let colors: WidgetRingColors

  var body: some View {
    GeometryReader { proxy in
      let side = min(proxy.size.width, proxy.size.height)
      let outer = metrics.first
      let inner = metrics.dropFirst().first

      ZStack {
        if let outer {
          ProviderTileRing(
            metric: outer,
            color: color(for: outer, layer: .outer),
            lineWidth: max(9, side * 0.095)
          )
          .frame(width: side, height: side)
        }

        if let inner {
          ProviderTileRing(
            metric: inner,
            color: color(for: inner, layer: .inner),
            lineWidth: max(7, side * 0.08)
          )
          .frame(width: side * 0.62, height: side * 0.62)
        }

        Text(name)
          .font(.subheadline.weight(.bold))
          .foregroundStyle(.white)
          .lineLimit(2)
          .minimumScaleFactor(0.68)
          .multilineTextAlignment(.center)
          .frame(width: side * (inner == nil ? 0.56 : 0.48))
      }
      .frame(width: side, height: side)
      .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
    }
  }

  private func color(for metric: UsageMetric, layer: WidgetRingLayer) -> Color {
    let role: WidgetRingColorRole
    if metric.isUnlimited {
      role = .unlimited
    } else if (metric.remainingPercent ?? 0) >= 70 {
      role = .high
    } else if (metric.remainingPercent ?? 0) >= 40 {
      role = .medium
    } else {
      role = .low
    }
    return Color(providerTileHex: colors.hexColor(for: role, layer: layer)) ?? .white
  }
}

private struct ProviderTileRing: View {
  let metric: UsageMetric
  let color: Color
  let lineWidth: CGFloat

  var body: some View {
    ZStack {
      Circle()
        .strokeBorder(Color.white.opacity(0.2), lineWidth: lineWidth)
      Circle()
        .trim(from: 0, to: progress)
        .stroke(
          color,
          style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        )
        .rotationEffect(.degrees(-90))
        .padding(lineWidth / 2)
    }
  }

  private var progress: CGFloat {
    if metric.isUnlimited { return 1 }
    return CGFloat(max(0, min(100, metric.remainingPercent ?? 0))) / 100
  }
}

private struct ProviderTileBackground: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  let provider: QuotaProvider?

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
                Color.white.opacity(reduceTransparency ? 0.06 : 0.24),
                Color.clear,
                Color.black.opacity(0.2)
              ],
              startPoint: .top,
              endPoint: .bottom
            )
          )
      }
  }

  private var palette: [Color] {
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
