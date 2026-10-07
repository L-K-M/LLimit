import SwiftUI
import WidgetKit
import QuotaCore

struct LLimitWidget: Widget {
  private let kind = SharedConstants.widgetKind

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: QuotaTimelineProvider(includesHistory: false)) { entry in
      DashboardWidgetRootView(entry: entry)
        .quotaWidgetBackground(entry: entry, kind: .dashboard)
    }
    .configurationDisplayName("LLimit Dashboard")
    .description("Compact quota overview across all configured accounts.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

struct QuotaTrendChartWidget: Widget {
  private let kind = SharedConstants.trendWidgetKind

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: QuotaTimelineProvider(includesHistory: true)) { entry in
      TrendLineChartWidgetView(entry: entry)
        .quotaWidgetBackground(entry: entry, kind: .trend)
    }
    .configurationDisplayName("Quota Trend Chart")
    .description("History lines across all accounts and limits.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

private enum QuotaWidgetBackgroundKind {
  case dashboard
  case trend
}

private extension View {
  @ViewBuilder
  func quotaWidgetBackground(entry: QuotaEntry, kind: QuotaWidgetBackgroundKind) -> some View {
    let style = entry.backgroundStyle(for: kind)

    if style.useTransparentBackground {
      self.containerBackground(.clear, for: .widget)
    } else {
      self.containerBackground(for: .widget) {
        FancyWidgetBackground(baseColor: backgroundBaseColor(from: style.backgroundHexColor))
      }
    }
  }
}

private struct DashboardWidgetRootView: View {
  @Environment(\.widgetFamily) private var family
  let entry: QuotaEntry

  var body: some View {
    switch family {
    case .systemSmall:
      OverviewSmallQuotaView(entry: entry)
    default:
      MediumCompactQuotaView(entry: entry)
    }
  }
}

private struct TrendLineChartWidgetView: View {
  @Environment(\.widgetFamily) private var family
  let entry: QuotaEntry

  var body: some View {
    let days = max(1, min(30, entry.settings.widgetVisibility.trendHistoryDays))
    let chartData = trendChartData(for: entry, days: days)

    VStack(alignment: .leading, spacing: 4) {
      if let reason = chartData.emptyReason {
        let message = emptyMessage(for: reason)
        Spacer(minLength: 0)
        Text(message.title)
          .font(.caption.weight(.semibold))
        Text(message.detail)
          .font(.caption2)
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
      } else {
        // No legend by design: line colors match the account's tile rings and
        // dropdown rows exactly (same hue variant per account), so the circle
        // charts are the legend.
        // Least important windows first so the risk carriers (weekly/monthly)
        // draw on top; sorted once here, not per layout pass.
        TrendChartPlotView(
          series: chartData.series.sorted { $0.drawPriority < $1.drawPriority },
          startDate: chartData.startDate,
          endDate: chartData.endDate,
          axisStyle: family == .systemSmall ? .endpoints : .full
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        if let warning = chartData.warnings.first {
          HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(warning.message)
              .lineLimit(1)
              .minimumScaleFactor(0.8)
            if chartData.warnings.count > 1 {
              Text("+\(chartData.warnings.count - 1)").fixedSize()
            }
          }
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.orange)
          .padding(.horizontal, 6)
          .padding(.vertical, 2.5)
          // Preserve warning contrast against the default blue surface.
          .background(Color.black.opacity(0.6), in: Capsule())
        }
      }
    }
    .padding(family == .systemSmall ? 7 : 9)
    .accessibilityLabel(trendAccessibilityLabel(days: days, chartData: chartData))
  }

  private func emptyMessage(for reason: TrendEmptyReason) -> (title: String, detail: String) {
    switch reason {
    case .noAccounts:
      return ("No accounts", "Add an account in LLimit to chart its quota")
    case .allHidden:
      return ("No accounts selected", "Choose accounts under Trend Widget in LLimit Settings")
    case .onlyUnlimited:
      return ("Unlimited plans only", "Every tracked limit reports unlimited — nothing to chart")
    case .onlyAmounts:
      return ("No limits to chart", "Balances have no remaining percentage to chart")
    case .refreshFailing:
      return ("No data to chart", "Open LLimit to check failed refreshes")
    case .noHistory:
      return ("No history yet", "The chart fills in as LLimit refreshes")
    }
  }

  private func trendAccessibilityLabel(days: Int, chartData: TrendChartData) -> String {
    let start = entry.date.addingTimeInterval(-Double(days) * 86_400)
    let snapshots = entry.history + [entry.snapshot].compactMap { $0 }
    // Only charted accounts count: a hidden account's estimate is not on screen.
    let accountFilter = TrendChartAccountFilter(settings: entry.settings)
    let includesEstimates = QuotaObservations.extract(from: snapshots,
      accounts: entry.settings.accounts, window: start...entry.date).contains { usage in
      accountFilter.includes(usage) && usage.metrics.contains(where: \.isPercentageEstimated)
    }
    let chart = includesEstimates
      ? "Quota trend chart. Includes estimated remaining percentages."
      : "Quota trend chart."
    let stale = chartData.series.contains { $0.state == .stale } ? " Includes stale readings." : ""
    let warnings = chartData.warnings.map { " Warning: \($0.message.replacingOccurrences(of: "~", with: "about "))." }.joined()
    return chart + stale + warnings
  }
}

private enum TrendAxisStyle {
  case full, endpoints
}

private struct TrendChartPlotView: View {
  let series: [TrendSeries]
  let startDate: Date
  let endDate: Date
  let axisStyle: TrendAxisStyle
  private static let percentGutterWidth: CGFloat = 17
  private static let timeGutterHeight: CGFloat = 11
  private static let plotInset: CGFloat = 3
  private static let timeLabelSpacing: CGFloat = 34
  private static let axisFontSize: CGFloat = 8
  private static let axisGlyphWidthEms: CGFloat = 0.58

  var body: some View {
    GeometryReader { proxy in
      let showsPercentLabels = axisStyle == .full
      let width = max(1, proxy.size.width - (showsPercentLabels ? Self.percentGutterWidth : 0))
      let height = max(1, proxy.size.height - Self.timeGutterHeight)
      let ticks = timeTicks(width: width)

      ZStack {
        // Axis labels retain contrast on the blue widget background.
        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.3))
        // Horizontal grid lines at 0%, 25%, 50%, 75%, 100%
        ForEach([0, 25, 50, 75, 100], id: \.self) { level in
          Path { path in
            let y = yPosition(for: Double(level), height: height)
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: width, y: y))
          }
          .stroke(Color.white.opacity(level % 50 == 0 ? 0.13 : 0.07), lineWidth: 0.8)
        }

        if axisStyle == .full {
          ForEach(ticks, id: \.date) { tick in
            Path { path in
              let x = xPosition(for: tick.date, width: width)
              path.move(to: CGPoint(x: x, y: 0))
              path.addLine(to: CGPoint(x: x, y: height))
            }
            .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
          }
        }

        if showsPercentLabels {
          ForEach([100, 50, 0], id: \.self) { level in
            Text("\(level)")
              .font(.system(size: Self.axisFontSize, weight: .medium))
              .monospacedDigit()
              .foregroundStyle(.white.opacity(0.9))
              .position(
                x: width + Self.percentGutterWidth / 2,
                y: max(yPosition(for: Double(level), height: height), Self.axisFontSize / 2 + 1)
              )
          }

        }

        ForEach(ticks, id: \.date) { tick in
          Text(tick.label)
            .font(.system(size: Self.axisFontSize, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(.white.opacity(0.9))
            .position(x: timeLabelCenter(for: tick, width: width), y: height + Self.timeGutterHeight / 2)
        }

        // Data lines (pre-sorted by draw priority). A dark casing keeps every
        // line separable from whatever background the widget sits on.
        ForEach(series) { line in
          if line.points.count >= 2 {
            let segments = TrendPathBuilder.segments(for: line.points)
            let path = linePath(for: segments, kind: .consumption, width: width, height: height)
            let casing = StrokeStyle(
              lineWidth: line.lineWidth + 1.5,
              lineCap: .round,
              lineJoin: .round
            )
            let stroke = StrokeStyle(
              lineWidth: line.lineWidth,
              lineCap: line.dashPattern.isEmpty ? .round : .butt,
              lineJoin: .round,
              dash: line.dashPattern
            )

            linePath(for: segments, kind: .reset, width: width, height: height)
              .stroke(line.color.opacity(0.3), lineWidth: 0.6)
            path.stroke(Color.black.opacity(0.28), style: casing)
            path.stroke(line.color.opacity(line.lineOpacity), style: stroke)
          }

          if line.state == .current, let latest = line.points.last {
            Circle()
              .fill(line.color)
              .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 0.8))
              .frame(width: 4.5, height: 4.5)
              .position(
                x: xPosition(for: latest.date, width: width),
                y: yPosition(for: latest.remainingPercent, height: height)
              )
          }
        }
      }
    }
  }

  private func linePath(for segments: [TrendPathSegment], kind: TrendPathSegment.Kind, width: CGFloat, height: CGFloat) -> Path {
    Path { path in
      for segment in segments where segment.kind == kind {
        for (index, point) in segment.samples.enumerated() {
          let coordinate = CGPoint(x: xPosition(for: point.date, width: width),
            y: yPosition(for: point.remainingPercent, height: height))
          if index == 0 { path.move(to: coordinate) } else { path.addLine(to: coordinate) }
        }
      }
    }
  }

  private func timeTicks(width: CGFloat) -> [TrendAxisTick] {
    switch axisStyle {
    case .full:
      return TrendAxisTicks.make(start: startDate, end: endDate, calendar: .current, locale: .current,
        maxLabels: max(1, Int(width / Self.timeLabelSpacing)))
    case .endpoints:
      return TrendAxisTicks.endpoints(start: startDate, end: endDate, calendar: .current, locale: .current)
    }
  }

  private func timeLabelCenter(for tick: TrendAxisTick, width: CGFloat) -> CGFloat {
    let halfWidth = min(width / 2, CGFloat(tick.label.count) * Self.axisFontSize * Self.axisGlyphWidthEms / 2 + 1)
    return min(max(xPosition(for: tick.date, width: width), halfWidth), width - halfWidth)
  }

  private func xPosition(for date: Date, width: CGFloat) -> CGFloat {
    let duration = max(1, endDate.timeIntervalSince(startDate))
    let elapsed = min(max(date.timeIntervalSince(startDate), 0), duration)
    return Self.plotInset + CGFloat(elapsed / duration) * max(0, width - 2 * Self.plotInset)
  }

  private func yPosition(for remainingPercent: Double, height: CGFloat) -> CGFloat {
    let clamped = min(max(remainingPercent, 0), 100)
    return Self.plotInset + (1 - CGFloat(clamped / 100)) * max(0, height - 2 * Self.plotInset)
  }
}

private typealias TrendPoint = TrendSample

private struct TrendSeries: Identifiable {
  let id: String
  let points: [TrendPoint]
  let color: Color
  let lineWidth: CGFloat
  let lineOpacity: Double
  let dashPattern: [CGFloat]
  let drawPriority: Int
  let state: TrendSeriesState
}

private struct TrendWarning: Identifiable {
  let id: String
  let message: String
}

private struct TrendChartData {
  let series: [TrendSeries]
  let startDate: Date
  let endDate: Date
  let warnings: [TrendWarning]
  var emptyReason: TrendEmptyReason?
}

private struct OverviewSmallQuotaView: View {
  let entry: QuotaEntry

  var body: some View {
    let dashboard = entry.dashboard

    VStack(alignment: .leading, spacing: 5) {
      DashboardHeader(entry: entry)

      if dashboard.state == .ready {
        let providerLimit = max(1, min(entry.settings.widgetVisibility.smallDashboardProviderLimit, 4))

        ForEach(dashboard.providers.prefix(providerLimit)) { usage in
          CompactProviderUsageRow(
            usage: usage,
            kindColors: entry.settings.widgetStyle.limitKindColors,
            colorStep: accountColorStep(forAccountID: usage.accountID, in: entry.settings.accounts),
            primaryHexColor: entry.settings.primaryHexColor(for: usage.accountID),
            showProgressBar: true,
            showPercentages: entry.settings.widgetVisibility.showPercentageValues,
            showDualLimitPercentages: entry.settings.widgetVisibility.showDualLimitPercentagesInDashboard,
            freshness: entry.freshness(for: usage)
          )
        }

        if entry.settings.widgetVisibility.showOverviewMetricSummary {
          Text(dashboard.overviewSummary)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        if entry.settings.widgetVisibility.showFailureCount, !dashboard.failures.isEmpty {
          DashboardUnavailableSummary(failures: dashboard.failures, capacity: 1, layout: .compact)
        }
      } else {
        Spacer(minLength: 0)
        DashboardEmptyStateView(dashboard: dashboard, nameCapacity: 2)
        Spacer(minLength: 0)
      }
    }
    .padding(8)
  }

}

private struct MediumCompactQuotaView: View {
  private static let maximumSingleColumnRows = 6
  let entry: QuotaEntry

  var body: some View {
    let dashboard = entry.dashboard

    VStack(alignment: .leading, spacing: 6) {
      DashboardHeader(entry: entry)

      if dashboard.state == .ready {
        let providerLimit = max(1, min(entry.settings.widgetVisibility.mediumProviderLimit, 12))
        let rows = Array(dashboard.providers.prefix(providerLimit))

        if rows.count > Self.maximumSingleColumnRows {
          LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
            ForEach(rows) { usage in row(for: usage) }
          }
        } else {
          ForEach(rows) { usage in row(for: usage) }
        }

        if entry.settings.widgetVisibility.showFailureCount, !dashboard.failures.isEmpty {
          DashboardUnavailableSummary(failures: dashboard.failures, capacity: 2, layout: .compact)
        }
      } else {
        Spacer(minLength: 0)
        DashboardEmptyStateView(dashboard: dashboard, nameCapacity: 4)
        Spacer(minLength: 0)
      }
    }
    .padding(10)
  }

  private func row(for usage: ProviderUsage) -> some View {
    CompactProviderUsageRow(usage: usage, kindColors: entry.settings.widgetStyle.limitKindColors,
      colorStep: accountColorStep(forAccountID: usage.accountID, in: entry.settings.accounts),
      primaryHexColor: entry.settings.primaryHexColor(for: usage.accountID),
      showProgressBar: entry.settings.widgetVisibility.showMediumProgressBars,
      showPercentages: entry.settings.widgetVisibility.showPercentageValues,
      showDualLimitPercentages: entry.settings.widgetVisibility.showDualLimitPercentagesInDashboard,
      freshness: entry.freshness(for: usage))
  }
}

private struct DashboardHeader: View {
  let entry: QuotaEntry

  var body: some View {
    HStack {
      Text("LLM Quota").font(.caption.weight(.semibold))
      Spacer(minLength: 3)
      if let snapshot = entry.snapshot, !entry.dashboard.providers.isEmpty || !entry.dashboard.failures.isEmpty {
        let stale = DashboardTimeline.isStale(snapshot: snapshot, accounts: entry.settings.accounts,
          now: entry.date, refreshIntervalMinutes: entry.refreshIntervalMinutes)
        HStack(spacing: 3) {
          if stale {
            Image(systemName: "clock.arrow.circlepath").accessibilityHidden(true)
            Text("Stale")
          }
          if entry.settings.widgetVisibility.showTimestamp || stale {
            Text(snapshot.generatedAt, style: .time)
          }
        }
        .font(.caption2)
        .foregroundStyle(stale ? Color.orange : Color.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stale ? "Data is stale. Last updated" : "Updated") \(snapshot.generatedAt.formatted(date: .abbreviated, time: .shortened))")
      }
    }
  }
}

private struct DashboardEmptyStateView: View {
  let dashboard: DashboardPresentation
  let nameCapacity: Int

  var body: some View {
    if let message {
      Text(message.title).font(.caption.weight(.semibold))
      if !dashboard.failures.isEmpty {
        DashboardUnavailableSummary(failures: dashboard.failures, capacity: nameCapacity, layout: .expanded)
      }
      Text(message.detail).font(.caption2).foregroundStyle(.secondary)
    }
  }

  private var message: (title: String, detail: String)? {
    switch dashboard.state {
    case .noAccounts: return ("No accounts configured", "Add accounts in LLimit")
    case .noEnabledAccounts: return ("No enabled accounts", "Enable accounts in LLimit")
    case .awaitingData: return ("Awaiting quota data", "Waiting for automatic refresh")
    case .allFailed: return (dashboard.failureCount == 1 ? "Account unavailable" : "All accounts unavailable", "Check accounts in LLimit")
    case .storageUnavailable: return ("Storage unavailable", "Open LLimit to check shared data")
    case .ready: return nil
    }
  }
}

private struct DashboardUnavailableSummary: View {
  enum Layout { case compact, expanded }
  let failures: [ProviderFailure]
  let capacity: Int
  let layout: Layout

  private var names: [String] { failures.map { $0.title ?? $0.provider.displayName } }
  private var remaining: Int { max(0, failures.count - capacity) }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      if layout == .compact {
        Text("\(names.prefix(capacity).joined(separator: ", ")) unavailable\(remaining > 0 ? " +\(remaining) more" : "")")
          .lineLimit(1)
      } else {
        ForEach(Array(names.prefix(capacity).enumerated()), id: \.offset) { _, name in
          Text(name).lineLimit(1)
        }
        if remaining > 0 { Text("+\(remaining) more") }
      }
    }
    .font(.caption2)
    .foregroundStyle(.orange)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Unavailable accounts: " + names.joined(separator: ", "))
  }
}

private extension QuotaEntry {
  func freshness(for usage: ProviderUsage) -> MenuBarGraph.Freshness {
    MenuBarGraph.bars(snapshot: snapshot, accounts: settings.accounts, now: date,
      staleAfter: QuotaFreshness.maxAge(refreshIntervalMinutes: refreshIntervalMinutes))
      .first { $0.usage?.accountKey == usage.accountKey }?.freshness ?? .current
  }
}

private struct CompactProviderUsageRow: View {
  @Environment(\.widgetFamily) private var family
  let usage: ProviderUsage
  let kindColors: LimitKindColors
  let colorStep: Int
  let primaryHexColor: String?
  let showProgressBar: Bool
  let showPercentages: Bool
  let showDualLimitPercentages: Bool
  let freshness: MenuBarGraph.Freshness

  private var metric: UsageMetric? { dashboardPrimaryMetric(for: usage) }
  private var dualPercent: String? { showDualLimitPercentages ? dualLimitPercentText(for: usage) : nil }
  private var basePercent: Int? { dashboardRemainingPercent(for: usage) }
  private var unlimited: Bool { metric?.isUnlimited == true }

  var body: some View {
    Group {
      if family == .systemSmall {
        // Values keep their intrinsic width; the bar gets the full second line.
        VStack(spacing: 2) {
          HStack(spacing: 4) { nameAndStatus; valueText }
          bar
        }
      } else {
        HStack(spacing: 6) {
          nameAndStatus
          bar.frame(minWidth: 18, idealWidth: 40, maxWidth: 90)
          valueText
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(shortName). \(showDualLimitPercentages && dualPercent != nil ? dualLimitAccessibilityText(for: usage) : percentageAccessibilityText(for: metric)). \(freshnessDescription)")
  }

  private var nameAndStatus: some View {
    HStack(spacing: 3) {
      Text(shortName + (!showPercentages && metric?.isPercentageEstimated == true ? " ≈" : ""))
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .frame(maxWidth: .infinity, alignment: .leading)
      if freshness != .current {
        Image(systemName: freshness.isFailing ? "exclamationmark.triangle.fill" : "clock.arrow.circlepath")
          .foregroundStyle(.orange)
          .accessibilityHidden(true)
      }
    }
  }

  @ViewBuilder private var bar: some View {
    if showProgressBar, basePercent != nil || unlimited {
      MiniProgressBar(percent: basePercent, unlimited: unlimited,
        tint: LimitKindColorScheme.accountAccent(for: usage.metrics, colors: kindColors, step: colorStep, primaryHexColor: primaryHexColor),
        stops: dashboardBarStops(for: usage, kindColors: kindColors, step: colorStep, primaryHexColor: primaryHexColor),
        showDualStops: showDualLimitPercentages)
        .frame(height: 5)
    }
  }

  @ViewBuilder private var valueText: some View {
    if showPercentages || basePercent == nil {
      Text(dualPercent ?? percentText(for: metric))
        .font(.caption2.weight(.semibold))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .fixedSize(horizontal: basePercent != nil || unlimited, vertical: false)
        .layoutPriority(1)
    }
  }

  private var shortName: String {
    compactProviderName(for: usage)
  }

  private var freshnessDescription: String {
    switch freshness {
    case .current: return "Data is current."
    case .stale: return "Data is stale."
    case .failing: return "Refresh failed. Last known values."
    }
  }
}

private struct MiniProgressBar: View {
  private static let backing = Color(red: 29 / 255, green: 31 / 255, blue: 39 / 255)
  let percent: Int?
  let unlimited: Bool
  let tint: Color
  let stops: [DashboardBarStop]
  let showDualStops: Bool

  var body: some View {
    GeometryReader { proxy in
      let width = max(0, proxy.size.width)
      let clampedPercent = max(0, min(100, percent ?? 0))
      let twoStops = Array(stops.prefix(2))

      ZStack(alignment: .leading) {
        Capsule()
          .fill(Self.backing)

        if unlimited {
          Capsule().fill(tint)
        } else if showDualStops, twoStops.count >= 2 {
          // Two lanes preserve both identity hues without opacity destroying
          // their validated contrast against the graphite backing.
          ForEach(Array(twoStops.enumerated()), id: \.element.id) { index, stop in
            Capsule()
              .fill(stop.color)
              .frame(width: width * CGFloat(stop.percent) / 100.0, height: proxy.size.height / 2)
              .offset(y: index == 0 ? -proxy.size.height / 4 : proxy.size.height / 4)
          }

          ForEach(twoStops) { stop in
            Capsule()
              .fill(stop.color)
              .frame(width: 2.5)
              .position(
                x: markerPositionX(for: stop.percent, width: width),
                y: proxy.size.height / 2
              )
          }
        } else {
          Capsule()
            .fill(tint)
            .frame(width: width * CGFloat(clampedPercent) / 100.0)
        }
      }
      .clipShape(Capsule())
      .overlay(Capsule().strokeBorder(Self.backing, lineWidth: 0.75))
    }
  }

  private func markerPositionX(for percent: Int, width: CGFloat) -> CGFloat {
    let markerWidth: CGFloat = 2.5
    guard width > markerWidth else {
      return width / 2
    }
    let normalized = CGFloat(max(0, min(100, percent))) / 100.0
    let x = width * normalized
    return max(markerWidth / 2, min(width - markerWidth / 2, x))
  }
}

private struct DashboardBarStop: Identifiable {
  let metricIndex: Int
  let percent: Int
  let color: Color

  var id: String {
    "\(metricIndex)-\(percent)"
  }
}

private func dashboardBarStops(for usage: ProviderUsage, kindColors: LimitKindColors, step: Int, primaryHexColor: String?) -> [DashboardBarStop] {
  let metricColors = LimitKindColorScheme.colors(for: usage.metrics, colors: kindColors, step: step, primaryHexColor: primaryHexColor)

  return dashboardBarMetrics(for: usage).compactMap { metric in
    guard let index = usage.metrics.firstIndex(of: metric) else {
      return nil
    }
    return DashboardBarStop(
      metricIndex: index,
      percent: max(0, min(100, metric.remainingPercent ?? 0)),
      color: metricColors[index]
    )
  }
}

private func dualLimitPercentText(for usage: ProviderUsage) -> String? {
  let boundedMetrics = dashboardBarMetrics(for: usage)
    .sorted { ($0.remainingPercent ?? 0) < ($1.remainingPercent ?? 0) }

  guard boundedMetrics.count >= 2 else {
    return nil
  }

  return boundedMetrics.prefix(2).map { percentText(for: $0) }.joined(separator: " / ")
}

private func dualLimitAccessibilityText(for usage: ProviderUsage) -> String {
  dashboardBarMetrics(for: usage)
    .sorted { ($0.remainingPercent ?? 0) < ($1.remainingPercent ?? 0) }
    .prefix(2)
    .map { "\($0.label), \(percentageAccessibilityText(for: $0))" }
    .joined(separator: ". ")
}

private func trendChartData(for entry: QuotaEntry, days: Int) -> TrendChartData {
  let clampedDays = max(1, min(30, days))
  let now = entry.date
  let startWindow = now.addingTimeInterval(-Double(clampedDays) * 86_400)

  let snapshots = entry.history + [entry.snapshot].compactMap { $0 }
  let content = TrendSeriesBuilder.build(snapshots: snapshots, latest: entry.snapshot,
    settings: entry.settings, window: startWindow...now, now: now,
    refreshInterval: TimeInterval(entry.refreshIntervalMinutes * 60))
  if let reason = content.emptyReason {
    return TrendChartData(series: [], startDate: startWindow, endDate: now, warnings: [], emptyReason: reason)
  }

  var series: [TrendSeries] = []
  var forecastKeys: [QuotaForecast.SeriesKey] = []
  var warningLabels: [QuotaForecast.SeriesKey: String] = [:]
  let kindColors = entry.settings.widgetStyle.limitKindColors

  for account in content.accounts {
    let usage = account.usage

    // Resolve color slots against the account's full metric list so the chart
    // agrees with the rings and the dashboard about which color a metric owns.
    let primarySlot = primaryLimitSlot(for: usage.metrics)
    let primaryHexColor = entry.settings.primaryHexColor(for: usage.accountID)
    // Lines wear the account's color-scheme variant — the same colors as the
    // account's tile rings, which act as the chart's legend.
    let accountStep = accountColorStep(forAccountID: usage.accountID, in: entry.settings.accounts)
    // Two limits of ONE account can still resolve to the same hue (Claude's
    // two weeklies, a third per-model quota re-using an aux color). The tile
    // can't show those either, so the chart adds a dash for repeats.
    var duplicateOrdinalByHex: [String: Int] = [:]
    // Live identities keep the solid stroke when retired lines share a hue.
    let liveFirst = account.series.filter { !$0.isRetired } + account.series.filter(\.isRetired)
    for line in liveFirst {
      let slot = line.slot
      let key = QuotaForecast.SeriesKey(accountID: line.accountID, metricID: line.metricID)
      let displayLabel = "\(compactProviderName(for: usage)) \(compactMetricLabel(line.label))"

      let baseHex = (slot == primarySlot ? primaryHexColor : nil) ?? kindColors.hexColor(for: slot)
      let duplicateOrdinal = duplicateOrdinalByHex[baseHex, default: 0]
      duplicateOrdinalByHex[baseHex] = duplicateOrdinal + 1
      let lineColor = LimitKindColorScheme.color(
        for: slot, colors: kindColors, step: accountStep,
        primarySlot: primarySlot, primaryHexColor: primaryHexColor
      )

      let style = seriesStyle(for: slot.kind)
      let dashPattern: [CGFloat]
      switch duplicateOrdinal {
      case 0:
        dashPattern = []
      case 1:
        dashPattern = [5, 3]
      case 2:
        dashPattern = [1.5, 2.5]
      default:
        dashPattern = [5, 2.5, 1.5, 2.5]
      }

      series.append(
        TrendSeries(
          id: line.id,
          points: TrendPathBuilder.downsample(line.samples, maxCount: 240),
          color: lineColor,
          lineWidth: style.lineWidth,
          lineOpacity: style.opacity,
          dashPattern: dashPattern,
          drawPriority: style.drawPriority,
          state: line.state
        )
      )
      if line.state == .current, !forecastKeys.contains(key) {
        forecastKeys.append(key)
        warningLabels[key] = displayLabel
      }
    }
  }

  // Fit the time domain to the data instead of anchoring at the configured
  // window: two days of history in a seven-day window otherwise huddles in
  // the right half of an empty chart.
  var chartStart = startWindow
  if let earliest = series.flatMap(\.points).map(\.date).min() {
    chartStart = max(startWindow, earliest)
  }
  let minimumSpan: TimeInterval = 6 * 3_600
  if now.timeIntervalSince(chartStart) < minimumSpan {
    chartStart = now.addingTimeInterval(-minimumSpan)
  }
  chartStart = chartStart.addingTimeInterval(-now.timeIntervalSince(chartStart) * 0.02)

  // Forecast raw observations, never downsampled paths or decorative holds.
  let forecasts = QuotaForecast.depletionWarnings(for: forecastKeys, history: entry.history,
    latest: entry.snapshot, accounts: entry.settings.accounts, now: now,
    refreshInterval: TimeInterval(entry.refreshIntervalMinutes * 60))
  let warnings = forecasts.map { forecast in
    let key = QuotaForecast.SeriesKey(accountID: forecast.accountID, metricID: forecast.metricID)
    return TrendWarning(id: "\(forecast.accountID):\(forecast.metricID)",
      message: "\(warningLabels[key] ?? forecast.metricLabel): \(forecast.timing(at: now))")
  }
  return TrendChartData(
    series: series,
    startDate: chartStart,
    endDate: now,
    warnings: warnings
  )
}

/// Short windows churn constantly (a 5-hour limit saw-tooths all day) while
/// the weekly and monthly traces carry the real exhaustion risk, so the fast
/// windows render thinner and slightly dimmer and the slow ones sit on top.
private func seriesStyle(for kind: QuotaWindowKind) -> (lineWidth: CGFloat, opacity: Double, drawPriority: Int) {
  switch kind {
  case .session:
    return (1.5, 0.82, 0)
  case .daily:
    return (1.7, 0.9, 1)
  case .other:
    return (2.0, 1.0, 2)
  case .monthly:
    return (2.1, 1.0, 3)
  case .weekly:
    return (2.1, 1.0, 4)
  }
}

private func compactMetricLabel(_ label: String) -> String {
  let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
  if trimmed.count <= 12 {
    return trimmed
  }

  if let firstToken = trimmed.split(separator: " ").first {
    let token = String(firstToken)
    if token.count <= 12 {
      return token
    }
  }

  return String(trimmed.prefix(12))
}

private func compactProviderName(for provider: QuotaProvider) -> String {
  switch provider {
  case .anthropic:
    return "Claude"
  case .openAI:
    return "OpenAI"
  case .zhipu:
    return "Zhipu"
  case .zai:
    return "Z.ai"
  case .kimi:
    return "Kimi"
  case .googleAntigravity:
    return "Antigravity"
  case .gitHubCopilot:
    return "Copilot"
  case .devin:
    return "Devin"
  case .metaMuse:
    return "Muse"
  case .openCodeGo:
    return "OpenCode"
  case .venice:
    return "Venice"
  case .cline:
    return "Cline"
  }
}

private func compactProviderName(for usage: ProviderUsage) -> String {
  let trimmed = usage.title.trimmingCharacters(in: .whitespacesAndNewlines)
  if !trimmed.isEmpty {
    return trimmed
  }
  return compactProviderName(for: usage.provider)
}

private func percentText(for metric: UsageMetric?) -> String {
  guard let metric else { return "--" }
  if metric.isUnlimited {
    return "INF"
  }
  if let remaining = metric.remainingPercent {
    return "\(metric.isPercentageEstimated ? "≈" : "")\(max(0, min(100, remaining)))%"
  }
  return metric.usageLine ?? "--"
}

private func percentageAccessibilityText(for metric: UsageMetric?) -> String {
  guard let metric else { return "Unknown" }
  if metric.isUnlimited { return "Unlimited" }
  guard let remaining = metric.remainingPercent else { return metric.usageLine ?? "Unknown" }
  return "\(metric.isPercentageEstimated ? "Estimated " : "")\(max(0, min(100, remaining))) percent remaining"
}

private func backgroundBaseColor(from hexColor: String?) -> Color? {
  guard var raw = hexColor?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
    return nil
  }

  if raw.hasPrefix("#") {
    raw.removeFirst()
  }

  if raw.count == 3 || raw.count == 4 {
    raw = raw.map { "\($0)\($0)" }.joined()
  }

  guard (raw.count == 6 || raw.count == 8), let parsed = UInt64(raw, radix: 16) else {
    return nil
  }

  if raw.count == 6 {
    let red = Double((parsed >> 16) & 0xFF) / 255.0
    let green = Double((parsed >> 8) & 0xFF) / 255.0
    let blue = Double(parsed & 0xFF) / 255.0
    return Color(red: red, green: green, blue: blue)
  }

  let red = Double((parsed >> 24) & 0xFF) / 255.0
  let green = Double((parsed >> 16) & 0xFF) / 255.0
  let blue = Double((parsed >> 8) & 0xFF) / 255.0
  let alpha = max(0.72, Double(parsed & 0xFF) / 255.0)
  return Color(red: red, green: green, blue: blue, opacity: alpha)
}

private struct FancyWidgetBackground: View {
  let baseColor: Color?

  var body: some View {
    GeometryReader { proxy in
      let glowSize = max(proxy.size.width, proxy.size.height)

      ZStack {
        ContainerRelativeShape()
          .fill(baseGradient)

        ContainerRelativeShape()
          .fill(
            LinearGradient(
              colors: [
                Color.white.opacity(0.26),
                Color.white.opacity(0.09),
                Color.white.opacity(0.02),
                Color.clear
              ],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
          .blendMode(.screen)

        Ellipse()
          .fill(
            LinearGradient(
              colors: [
                Color.white.opacity(0.45),
                Color.white.opacity(0.08),
                Color.clear
              ],
              startPoint: .top,
              endPoint: .bottom
            )
          )
          .frame(width: glowSize * 0.88, height: glowSize * 0.42)
          .blur(radius: glowSize * 0.05)
          .offset(x: -proxy.size.width * 0.09, y: -proxy.size.height * 0.28)

        Ellipse()
          .fill(
            RadialGradient(
              colors: [
                (baseColor ?? Color(red: 0.49, green: 0.72, blue: 1)).opacity(0.36),
                Color.clear
              ],
              center: .center,
              startRadius: 0,
              endRadius: glowSize * 0.52
            )
          )
          .frame(width: glowSize, height: glowSize)
          .offset(x: proxy.size.width * 0.2, y: proxy.size.height * 0.18)

        ContainerRelativeShape()
          .fill(
            LinearGradient(
              colors: [
                Color.clear,
                Color.black.opacity(0.06),
                Color.black.opacity(0.11)
              ],
              startPoint: .top,
              endPoint: .bottom
            )
          )

        ContainerRelativeShape()
          .inset(by: 0.5)
          .stroke(Color.white.opacity(0.2), lineWidth: 1)

        ContainerRelativeShape()
          .inset(by: 0.5)
          .stroke(
            LinearGradient(
              colors: [
                Color.white.opacity(0.2),
                Color.white.opacity(0.04),
                Color.clear
              ],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            ),
            lineWidth: 0.8
          )
      }
    }
  }

  private var baseGradient: LinearGradient {
    let tint = baseColor ?? Color(red: 0.35, green: 0.58, blue: 0.95)
    return LinearGradient(
      colors: [
        tint.opacity(0.96),
        tint.opacity(0.9),
        tint.opacity(0.82)
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }
}

private extension QuotaEntry {
  func backgroundStyle(for kind: QuotaWidgetBackgroundKind) -> WidgetStyleSettings {
    switch kind {
    case .dashboard:
      return backgroundStyle(from: settings.widgetBackgroundSettings.dashboard)
    case .trend:
      return backgroundStyle(from: settings.widgetBackgroundSettings.trend)
    }
  }

  private func backgroundStyle(from override: WidgetBackgroundOverride) -> WidgetStyleSettings {
    let globalStyle = settings.widgetStyle

    guard override.useCustomBackground else {
      return globalStyle
    }

    let resolvedBackground = override.backgroundHexColor ?? globalStyle.backgroundHexColor

    return WidgetStyleSettings(
      backgroundHexColor: resolvedBackground,
      ringColors: globalStyle.ringColors,
      limitKindColors: globalStyle.limitKindColors,
      useTransparentBackground: override.useTransparentBackground
    )
  }
}
