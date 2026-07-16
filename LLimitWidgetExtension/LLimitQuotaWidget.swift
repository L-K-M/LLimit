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
      if chartData.series.isEmpty {
        Spacer(minLength: 0)
        Text(chartData.hasOnlyUnlimitedData ? "Unlimited plans only" : "No history yet")
          .font(.caption.weight(.semibold))
        Text(chartData.hasOnlyUnlimitedData
          ? "Every tracked limit reports unlimited — nothing to chart"
          : "Waiting for automatic refresh")
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
          showAxisLabels: family != .systemSmall
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        if let warning = chartData.warnings.first {
          Label {
            Text(warning.message)
              .lineLimit(1)
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
          }
          .font(.system(size: 8.5, weight: .semibold))
          .foregroundStyle(.orange)
          .padding(.horizontal, 6)
          .padding(.vertical, 2.5)
          .background(.orange.opacity(0.16), in: Capsule())
        }
      }
    }
    .padding(family == .systemSmall ? 7 : 9)
  }
}

private struct TrendChartPlotView: View {
  let series: [TrendSeries]
  let startDate: Date
  let endDate: Date
  let showAxisLabels: Bool

  var body: some View {
    GeometryReader { proxy in
      let width = max(1, proxy.size.width)
      let height = max(1, proxy.size.height)
      let boundaries = dayBoundaries()
      let labelStride = max(1, Int((Double(boundaries.count) / 6.0).rounded(.up)))

      ZStack {
        // Horizontal grid lines at 0%, 25%, 50%, 75%, 100%
        ForEach([0, 25, 50, 75, 100], id: \.self) { level in
          Path { path in
            let y = yPosition(for: Double(level), height: height)
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: width, y: y))
          }
          .stroke(Color.white.opacity(level % 50 == 0 ? 0.13 : 0.07), lineWidth: 0.8)
        }

        // Vertical day-separator lines at each midnight boundary
        ForEach(boundaries, id: \.timeIntervalSince1970) { date in
          Path { path in
            let x = xPosition(for: date, width: width)
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: height))
          }
          .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
        }

        if showAxisLabels {
          let weekdaySymbols = Calendar.current.veryShortWeekdaySymbols

          ForEach([100, 50, 0], id: \.self) { level in
            Text("\(level)")
              .font(.system(size: 6.5, weight: .medium))
              .monospacedDigit()
              .foregroundStyle(.white.opacity(0.42))
              .position(
                x: width - 7,
                y: min(max(yPosition(for: Double(level), height: height) + (level == 100 ? 5 : -5), 4), height - 4)
              )
          }

          ForEach(Array(boundaries.enumerated()), id: \.element.timeIntervalSince1970) { index, date in
            if index % labelStride == 0 {
              Text(weekdayLetter(for: date, symbols: weekdaySymbols))
                .font(.system(size: 6.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
                .position(x: xPosition(for: date, width: width) + 6, y: height - 5)
            }
          }
        }

        // Data lines (pre-sorted by draw priority). A dark casing keeps every
        // line separable from whatever background the widget sits on.
        ForEach(series) { line in
          if line.points.count >= 2 {
            let path = linePath(for: line, width: width, height: height)
            let casing = StrokeStyle(
              lineWidth: line.lineWidth + 1.5,
              lineCap: .round,
              lineJoin: .round,
              dash: line.dashPattern
            )
            let stroke = StrokeStyle(
              lineWidth: line.lineWidth,
              lineCap: .round,
              lineJoin: .round,
              dash: line.dashPattern
            )

            path.stroke(Color.black.opacity(0.28), style: casing)
            path.stroke(line.color.opacity(line.lineOpacity), style: stroke)
          }

          if let latest = line.points.last {
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

  /// Quota traces drain downward and refill in an instant. When a sample pair
  /// jumps upward a reset happened in between, so draw hold-then-snap instead
  /// of a misleading diagonal across the gap.
  private func linePath(for line: TrendSeries, width: CGFloat, height: CGFloat) -> Path {
    Path { path in
      var previous: TrendPoint?

      for point in line.points {
        let coordinate = CGPoint(
          x: xPosition(for: point.date, width: width),
          y: yPosition(for: point.remainingPercent, height: height)
        )

        if let previous {
          if point.remainingPercent > previous.remainingPercent + 4 {
            path.addLine(to: CGPoint(x: coordinate.x, y: yPosition(for: previous.remainingPercent, height: height)))
          }
          path.addLine(to: coordinate)
        } else {
          path.move(to: coordinate)
        }

        previous = point
      }
    }
  }

  private func weekdayLetter(for date: Date, symbols: [String]) -> String {
    let weekday = Calendar.current.component(.weekday, from: date)
    guard weekday >= 1, weekday <= symbols.count else {
      return ""
    }
    return symbols[weekday - 1]
  }

  private func dayBoundaries() -> [Date] {
    let calendar = Calendar.current
    var boundaries: [Date] = []
    // Start from the midnight after startDate, walk forward by day
    var current = calendar.startOfDay(for: startDate)
    if current <= startDate {
      current = calendar.date(byAdding: .day, value: 1, to: current) ?? current
    }
    while current < endDate {
      boundaries.append(current)
      current = calendar.date(byAdding: .day, value: 1, to: current) ?? endDate
    }
    return boundaries
  }

  private func xPosition(for date: Date, width: CGFloat) -> CGFloat {
    let duration = max(1, endDate.timeIntervalSince(startDate))
    let elapsed = min(max(date.timeIntervalSince(startDate), 0), duration)
    return CGFloat(elapsed / duration) * width
  }

  private func yPosition(for remainingPercent: Double, height: CGFloat) -> CGFloat {
    let clamped = min(max(remainingPercent, 0), 100)
    return (1 - CGFloat(clamped / 100)) * height
  }
}

private struct TrendPoint {
  let date: Date
  let remainingPercent: Double
}

private struct TrendSeries: Identifiable {
  let id: String
  let provider: QuotaProvider
  let metricID: String
  let metricLabel: String
  let displayLabel: String
  let points: [TrendPoint]
  let color: Color
  let resetAt: Date?
  let lineWidth: CGFloat
  let lineOpacity: Double
  let dashPattern: [CGFloat]
  let drawPriority: Int
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
  // True when history exists but every tracked metric reports unlimited —
  // there is genuinely nothing to chart, which is different from "no data".
  var hasOnlyUnlimitedData = false
}

private struct OverviewSmallQuotaView: View {
  let entry: QuotaEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text("LLM Quota")
          .font(.caption.weight(.semibold))
        Spacer()
        if entry.settings.widgetVisibility.showTimestamp, let snapshot = entry.snapshot {
          Text(snapshot.generatedAt, style: .time)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }

      if let snapshot = entry.snapshot, !snapshot.providers.isEmpty {
        let providerLimit = max(1, min(entry.settings.widgetVisibility.smallDashboardProviderLimit, 4))

        ForEach(sortedProviders(snapshot.providers).prefix(providerLimit)) { usage in
          CompactProviderUsageRow(
            usage: usage,
            kindColors: entry.settings.widgetStyle.limitKindColors,
            colorStep: accountColorStep(forAccountID: usage.accountID, in: entry.settings.accounts),
            showProgressBar: true,
            showPercentages: entry.settings.widgetVisibility.showPercentageValues,
            showDualLimitPercentages: entry.settings.widgetVisibility.showDualLimitPercentagesInDashboard
          )
        }

        if entry.settings.widgetVisibility.showOverviewMetricSummary {
          Text(overviewSummary(for: snapshot.providers))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        if entry.settings.widgetVisibility.showFailureCount, !snapshot.failures.isEmpty {
          Text("\(snapshot.failures.count) unavailable")
            .font(.caption2)
            .foregroundStyle(.orange)
        }
      } else {
        Spacer(minLength: 0)
        Text("No accounts configured")
          .font(.caption.weight(.semibold))
        Text("Add accounts in LLimit")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }
    }
    .padding(8)
  }

  private func sortedProviders(_ providers: [ProviderUsage]) -> [ProviderUsage] {
    providers.sorted { lhs, rhs in
      let lhsRemaining = providerRemainingPercent(for: lhs) ?? Int.max
      let rhsRemaining = providerRemainingPercent(for: rhs) ?? Int.max

      if lhsRemaining != rhsRemaining {
        return lhsRemaining < rhsRemaining
      }

      return lhs.title < rhs.title
    }
  }

  private func overviewSummary(for providers: [ProviderUsage]) -> String {
    guard !providers.isEmpty else {
      return "No accounts"
    }

    if let worstRemaining = providers.compactMap({ providerRemainingPercent(for: $0) }).min() {
      return "\(providers.count) accounts, lowest \(worstRemaining)% left"
    }

    return "\(providers.count) accounts tracked"
  }
}

private struct MediumCompactQuotaView: View {
  let entry: QuotaEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("LLM Quota")
          .font(.caption.weight(.semibold))
        Spacer()
        if entry.settings.widgetVisibility.showTimestamp, let snapshot = entry.snapshot {
          Text(snapshot.generatedAt, style: .time)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }

      if let snapshot = entry.snapshot, !snapshot.providers.isEmpty {
        let providerLimit = max(1, min(entry.settings.widgetVisibility.mediumProviderLimit, 12))

        ForEach(sortedProviders(snapshot.providers).prefix(providerLimit)) { usage in
          CompactProviderUsageRow(
            usage: usage,
            kindColors: entry.settings.widgetStyle.limitKindColors,
            colorStep: accountColorStep(forAccountID: usage.accountID, in: entry.settings.accounts),
            showProgressBar: entry.settings.widgetVisibility.showMediumProgressBars,
            showPercentages: entry.settings.widgetVisibility.showPercentageValues,
            showDualLimitPercentages: entry.settings.widgetVisibility.showDualLimitPercentagesInDashboard
          )
        }

        if entry.settings.widgetVisibility.showFailureCount, !snapshot.failures.isEmpty {
          Text("\(snapshot.failures.count) unavailable")
            .font(.caption2)
            .foregroundStyle(.orange)
        }
      } else {
        Spacer(minLength: 0)
        Text("No accounts configured")
          .font(.caption.weight(.semibold))
        Text("Add accounts in LLimit")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }
    }
    .padding(10)
  }

  private func sortedProviders(_ providers: [ProviderUsage]) -> [ProviderUsage] {
    providers.sorted { lhs, rhs in
      let lhsRemaining = providerRemainingPercent(for: lhs) ?? Int.max
      let rhsRemaining = providerRemainingPercent(for: rhs) ?? Int.max

      if lhsRemaining != rhsRemaining {
        return lhsRemaining < rhsRemaining
      }

      return lhs.title < rhs.title
    }
  }
}

private struct CompactProviderUsageRow: View {
  let usage: ProviderUsage
  let kindColors: LimitKindColors
  let colorStep: Int
  let showProgressBar: Bool
  let showPercentages: Bool
  let showDualLimitPercentages: Bool

  var body: some View {
    let metric = dashboardPrimaryMetric(for: usage)
    let dualPercent = showDualLimitPercentages ? dualLimitPercentText(for: usage) : nil
    let basePercent = metric?.remainingPercent ?? providerRemainingPercent(for: usage)
    let unlimited = metric?.isUnlimited ?? usage.metrics.contains(where: \.isUnlimited)

    HStack(spacing: 6) {
      Text(shortName)
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
        .frame(width: 58, alignment: .leading)

      if showProgressBar {
        MiniProgressBar(
          percent: basePercent,
          unlimited: unlimited,
          tint: LimitKindColorScheme.accountAccent(for: usage.metrics, colors: kindColors, step: colorStep),
          stops: dashboardBarStops(for: usage, kindColors: kindColors, step: colorStep),
          showDualStops: showDualLimitPercentages
        )
          .frame(height: 5)
      } else {
        Spacer(minLength: 0)
      }

      if showPercentages {
        // Single mode labels the SAME metric the bar fills with
        // (dashboardPrimaryMetric), so the number can never contradict the bar.
        Text(dualPercent ?? percentText(for: metric))
          .font(.caption2.weight(.semibold))
          .monospacedDigit()
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .frame(width: dualPercent == nil ? 40 : 72, alignment: .trailing)
      }
    }
  }

  private var shortName: String {
    compactProviderName(for: usage)
  }
}

private struct MiniProgressBar: View {
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
          .fill(Color.white.opacity(0.16))

        if unlimited {
          Capsule().fill(tint)
        } else if showDualStops, twoStops.count >= 2 {
          // Longer fill first so the shorter one stays visible on top; each
          // fill wears its own metric's identity color, the underlying longer
          // one dimmed so the overlap reads as two limits. Dim by position in
          // the draw order, not by percent — equal percents must still yield
          // one strong fill.
          let ordered = twoStops.sorted { $0.percent > $1.percent }

          ForEach(ordered) { stop in
            Capsule()
              .fill(stop.color.opacity(stop.id == ordered.first?.id ? 0.55 : 0.85))
              .frame(width: width * CGFloat(stop.percent) / 100.0)
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

private func dashboardPrimaryMetric(for usage: ProviderUsage) -> UsageMetric? {
  let boundedMetrics = usage.metrics
    .filter { !$0.isUnlimited }
    .compactMap { metric -> UsageMetric? in
      guard metric.remainingPercent != nil else {
        return nil
      }
      return metric
    }

  if let mostConstrained = boundedMetrics.min(by: { ($0.remainingPercent ?? Int.max) < ($1.remainingPercent ?? Int.max) }) {
    return mostConstrained
  }

  if let unlimitedMetric = usage.metrics.first(where: \.isUnlimited) {
    return unlimitedMetric
  }

  return usage.metrics.first(where: { $0.remainingPercent != nil }) ?? usage.metrics.first
}

private func providerRemainingPercent(for usage: ProviderUsage) -> Int? {
  let boundedRemaining = usage.metrics
    .filter { !$0.isUnlimited }
    .compactMap(\.remainingPercent)

  if let minimumRemaining = boundedRemaining.min() {
    return max(0, min(100, minimumRemaining))
  }

  if usage.metrics.contains(where: \.isUnlimited) {
    return 100
  }

  if let maxUsagePercent = usage.maxUsagePercent {
    return max(0, min(100, 100 - maxUsagePercent))
  }

  return nil
}

// The dashboard bar shows the same provider-preferred metric pair as the tile
// rings (defaultRingMetrics) so both surfaces show the same two limits in the
// same identity colors.
private func dashboardBarMetrics(for usage: ProviderUsage) -> [UsageMetric] {
  Array(
    defaultRingMetrics(for: usage)
      .filter { !$0.isUnlimited && $0.remainingPercent != nil }
      .prefix(2)
  )
}

private func dashboardBarStops(for usage: ProviderUsage, kindColors: LimitKindColors, step: Int) -> [DashboardBarStop] {
  let metricColors = LimitKindColorScheme.colors(for: usage.metrics, colors: kindColors, step: step)

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

private func dashboardBarPercents(for usage: ProviderUsage) -> [Int] {
  dashboardBarMetrics(for: usage)
    .map { max(0, min(100, $0.remainingPercent ?? 0)) }
    .sorted()
}

private func dualLimitPercentText(for usage: ProviderUsage) -> String? {
  let boundedPercentages = dashboardBarPercents(for: usage)

  guard boundedPercentages.count >= 2 else {
    return nil
  }

  return "\(boundedPercentages[0])% / \(boundedPercentages[1])%"
}

private func trendChartData(for entry: QuotaEntry, days: Int) -> TrendChartData {
  let clampedDays = max(1, min(30, days))
  let now = entry.date
  let startWindow = now.addingTimeInterval(-Double(clampedDays) * 86_400)

  var snapshots = entry.history.filter { snapshot in
    snapshot.generatedAt >= startWindow && snapshot.generatedAt <= now
  }

  if let current = entry.snapshot {
    let alreadyIncluded = snapshots.contains {
      abs($0.generatedAt.timeIntervalSince(current.generatedAt)) < 1
    }
    if !alreadyIncluded {
      snapshots.append(current)
    }
  }

  snapshots.sort { $0.generatedAt < $1.generatedAt }

  guard !snapshots.isEmpty else {
    return TrendChartData(series: [], startDate: startWindow, endDate: now, warnings: [])
  }

  struct SeriesKey: Hashable {
    let accountID: String
    let metricID: String
  }

  var pointsByKey: [SeriesKey: [TrendPoint]] = [:]
  var labelsByKey: [SeriesKey: String] = [:]
  var resetByKey: [SeriesKey: Date] = [:]
  var orderByAccount: [String: [String]] = [:]
  var usageByAccount: [String: ProviderUsage] = [:]
  var sawUnlimitedMetric = false
  let enabledAccounts = entry.settings.accounts.filter(\.isEnabled)
  let enabledAccountIDs = Set(enabledAccounts.map(\.id))
  let enabledAccountsByProvider = Dictionary(grouping: enabledAccounts, by: \.provider)

  for snapshot in snapshots {
    for usage in snapshot.providers {
      let isLegacySoleAccount = usage.accountID == usage.provider.rawValue
        && enabledAccountsByProvider[usage.provider]?.count == 1
      guard enabledAccountIDs.contains(usage.accountID) || isLegacySoleAccount else { continue }

      var metricOrder = orderByAccount[usage.accountID] ?? []
      usageByAccount[usage.accountID] = usage

      for metric in usage.metrics {
        // Unlimited metrics have no trend to chart — plotting them pins a
        // flat line at 100% and only adds noise.
        if metric.isUnlimited {
          sawUnlimitedMetric = true
          continue
        }
        guard metric.remainingPercent != nil else {
          continue
        }

        let resolvedID = metric.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? metric.label
          : metric.id

        if !metricOrder.contains(resolvedID) {
          metricOrder.append(resolvedID)
        }

        let key = SeriesKey(accountID: usage.accountID, metricID: resolvedID)
        let remaining = Double(metric.remainingPercent ?? 0)
        pointsByKey[key, default: []].append(TrendPoint(date: snapshot.generatedAt, remainingPercent: remaining))
        labelsByKey[key] = metric.label

        if let resetAt = metric.resetAt {
          resetByKey[key] = resetAt
        }
      }

      orderByAccount[usage.accountID] = metricOrder
    }
  }

  var series: [TrendSeries] = []
  let kindColors = entry.settings.widgetStyle.limitKindColors

  let accountOrder = usageByAccount.values.sorted { lhs, rhs in
    if lhs.provider.rawValue != rhs.provider.rawValue {
      return lhs.provider.rawValue < rhs.provider.rawValue
    }
    return lhs.title < rhs.title
  }

  for usage in accountOrder {
    let metricIDs = orderByAccount[usage.accountID] ?? []
    guard !metricIDs.isEmpty else {
      continue
    }

    // Resolve color slots against the account's full metric list so the chart
    // agrees with the rings and the dashboard about which color a metric owns.
    let accountSlots = limitSeriesSlots(for: usage.metrics)
    // Lines wear the account's color-scheme variant — the same colors as the
    // account's tile rings, which act as the chart's legend.
    let accountStep = accountColorStep(forAccountID: usage.accountID, in: entry.settings.accounts)
    // Two limits of ONE account can still resolve to the same hue (Claude's
    // two weeklies, a third per-model quota re-using an aux color). The tile
    // can't show those either, so the chart adds a dash for repeats.
    var duplicateOrdinalByHex: [String: Int] = [:]

    for metricID in metricIDs {
      let key = SeriesKey(accountID: usage.accountID, metricID: metricID)
      let points = downsampleTrendPoints(pointsByKey[key] ?? [], maxCount: 240)
      guard !points.isEmpty else {
        continue
      }

      let metricLabel = labelsByKey[key] ?? metricID
      let displayLabel: String
      if metricIDs.count > 1 {
        displayLabel = "\(compactProviderName(for: usage)) \(compactMetricLabel(metricLabel))"
      } else {
        displayLabel = compactProviderName(for: usage)
      }

      let slot: LimitSeriesSlot
      if let index = usage.metrics.firstIndex(where: { $0.id == metricID || $0.label == metricID }) {
        slot = accountSlots[index]
      } else {
        slot = LimitSeriesSlot(kind: QuotaWindowKind.classify(metricID: metricID, label: metricLabel))
      }

      let baseHex = kindColors.hexColor(for: slot)
      let duplicateOrdinal = duplicateOrdinalByHex[baseHex, default: 0]
      duplicateOrdinalByHex[baseHex] = duplicateOrdinal + 1
      let lineColor = LimitKindColorScheme.steppedColor(hex: baseHex, step: accountStep) ?? .white

      let style = seriesStyle(for: slot.kind)
      let dashPattern: [CGFloat]
      switch duplicateOrdinal {
      case 0:
        dashPattern = []
      case 1:
        dashPattern = [4, 2.5]
      default:
        dashPattern = [1.6, 2.4]
      }

      series.append(
        TrendSeries(
          id: "\(usage.accountID):\(metricID)",
          provider: usage.provider,
          metricID: metricID,
          metricLabel: metricLabel,
          displayLabel: displayLabel,
          points: points,
          color: lineColor,
          resetAt: resetByKey[key],
          lineWidth: style.lineWidth,
          lineOpacity: style.opacity,
          dashPattern: dashPattern,
          drawPriority: style.drawPriority
        )
      )
    }
  }

  // Fit the time domain to the data instead of anchoring at the configured
  // window: two days of history in a seven-day window otherwise huddles in
  // the right half of an empty chart.
  var chartStart = startWindow
  if let earliest = snapshots.first?.generatedAt {
    chartStart = max(startWindow, earliest)
  }
  let minimumSpan: TimeInterval = 6 * 3_600
  if now.timeIntervalSince(chartStart) < minimumSpan {
    chartStart = now.addingTimeInterval(-minimumSpan)
  }
  chartStart = chartStart.addingTimeInterval(-now.timeIntervalSince(chartStart) * 0.02)

  let warnings = depletionWarnings(for: series, now: now)
  return TrendChartData(
    series: series,
    startDate: chartStart,
    endDate: now,
    warnings: warnings,
    hasOnlyUnlimitedData: series.isEmpty && sawUnlimitedMetric
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

private func downsampleTrendPoints(_ points: [TrendPoint], maxCount: Int) -> [TrendPoint] {
  let sorted = points.sorted { $0.date < $1.date }
  guard sorted.count > maxCount, maxCount > 1 else {
    return sorted
  }

  let scale = Double(sorted.count - 1) / Double(maxCount - 1)
  var sampled: [TrendPoint] = []
  sampled.reserveCapacity(maxCount)

  for index in 0..<maxCount {
    let sourceIndex = min(sorted.count - 1, Int((Double(index) * scale).rounded()))
    sampled.append(sorted[sourceIndex])
  }

  return sampled
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

private func depletionWarnings(for series: [TrendSeries], now: Date) -> [TrendWarning] {
  series.compactMap { line in
    guard let resetAt = line.resetAt, resetAt > now else {
      return nil
    }

    let recentPoints = Array(line.points.suffix(8))
    guard recentPoints.count >= 2, let first = recentPoints.first, let last = recentPoints.last else {
      return nil
    }

    guard last.remainingPercent <= 60 else {
      return nil
    }

    let elapsed = last.date.timeIntervalSince(first.date)
    guard elapsed > 0 else {
      return nil
    }

    let slope = (last.remainingPercent - first.remainingPercent) / elapsed
    guard slope < -0.00001 else {
      return nil
    }

    let secondsToZero = last.remainingPercent / -slope
    guard secondsToZero.isFinite, secondsToZero > 0 else {
      return nil
    }

    let depletionDate = last.date.addingTimeInterval(secondsToZero)
    guard depletionDate < resetAt else {
      return nil
    }

    return TrendWarning(
      id: line.id,
      message: "\(line.displayLabel) may run out before reset"
    )
  }
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
    return "Google"
  case .gitHubCopilot:
    return "Copilot"
  }
}

private func compactProviderName(for usage: ProviderUsage) -> String {
  let trimmed = usage.title.trimmingCharacters(in: .whitespacesAndNewlines)
  if !trimmed.isEmpty {
    return trimmed
  }
  return compactProviderName(for: usage.provider)
}

private func resetSummaries(for metrics: [UsageMetric], at date: Date) -> [String] {
  metrics.compactMap { metric in
    guard let summary = metric.resetCountdown(at: date) else { return nil }
    return summary == "reset" ? "<1m" : summary
  }
}

private func percentText(for metric: UsageMetric?) -> String {
  guard let metric else { return "--" }
  if metric.isUnlimited {
    return "INF"
  }
  if let remaining = metric.remainingPercent {
    return "\(remaining)%"
  }
  return "--"
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

