import SwiftUI
import WidgetKit
import QuotaCore

struct LLimitWidget: Widget {
  private let kind = SharedConstants.widgetKind

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: QuotaTimelineProvider()) { entry in
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
    StaticConfiguration(kind: kind, provider: QuotaTimelineProvider()) { entry in
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
  let entry: QuotaEntry

  var body: some View {
    let days = max(1, min(30, entry.settings.widgetVisibility.trendHistoryDays))
    let chartData = trendChartData(for: entry, days: days)

    VStack(alignment: .leading, spacing: 0) {
      if chartData.series.isEmpty {
        Spacer(minLength: 0)
        Text("No history yet")
          .font(.caption.weight(.semibold))
        Text("Waiting for automatic refresh")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
      } else {
        TrendChartPlotView(
          series: chartData.series,
          startDate: chartData.startDate,
          endDate: chartData.endDate
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        if let warning = chartData.warnings.first {
          Text("Risk: \(warning.message)")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
            .lineLimit(1)
            .padding(.top, 4)
        }
      }
    }
    .padding(6)
  }
}

private struct TrendChartPlotView: View {
  let series: [TrendSeries]
  let startDate: Date
  let endDate: Date

  var body: some View {
    GeometryReader { proxy in
      let width = max(1, proxy.size.width)
      let height = max(1, proxy.size.height)

      ZStack {
        // Horizontal grid lines at 0%, 25%, 50%, 75%, 100%
        ForEach([0, 25, 50, 75, 100], id: \.self) { level in
          Path { path in
            let y = yPosition(for: Double(level), height: height)
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: width, y: y))
          }
          .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
        }

        // Vertical day-separator lines at each midnight boundary
        ForEach(dayBoundaries(), id: \.timeIntervalSince1970) { date in
          Path { path in
            let x = xPosition(for: date, width: width)
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: height))
          }
          .stroke(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
        }

        // Data lines
        ForEach(series) { line in
          if line.points.count >= 2 {
            Path { path in
              for (index, point) in line.points.enumerated() {
                let coordinate = CGPoint(
                  x: xPosition(for: point.date, width: width),
                  y: yPosition(for: point.remainingPercent, height: height)
                )

                if index == 0 {
                  path.move(to: coordinate)
                } else {
                  path.addLine(to: coordinate)
                }
              }
            }
            .stroke(line.color.opacity(0.95), style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
          }

          if let latest = line.points.last {
            Circle()
              .fill(line.color)
              .frame(width: 4, height: 4)
              .position(
                x: xPosition(for: latest.date, width: width),
                y: yPosition(for: latest.remainingPercent, height: height)
              )
          }
        }
      }
    }
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
            ringColors: entry.style(for: usage.accountID).ringColors,
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
            ringColors: entry.style(for: usage.accountID).ringColors,
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
  let ringColors: WidgetRingColors
  let showProgressBar: Bool
  let showPercentages: Bool
  let showDualLimitPercentages: Bool

  var body: some View {
    let metric = dashboardPrimaryMetric(for: usage)
    let dualStops = dashboardBarStops(for: usage)
    let dualPercent = showDualLimitPercentages ? dualLimitPercentText(for: usage) : nil
    let percentDisplay = dualPercent ?? dashboardPercentDisplayText(for: usage)
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
          ringColors: ringColors,
          dualStops: dualStops,
          showDualStops: showDualLimitPercentages
        )
          .frame(height: 5)
      } else {
        Spacer(minLength: 0)
      }

      if showPercentages {
        Text(percentDisplay ?? percentText(for: metric))
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

private struct ConcentricQuotaChart: View {
  enum CenterLabelStyle {
    case metrics
    case hidden
  }

  let metrics: [UsageMetric]
  let ringColors: WidgetRingColors
  var centerLabelStyle: CenterLabelStyle = .metrics

  var body: some View {
    GeometryReader { proxy in
      let side = min(proxy.size.width, proxy.size.height)
      let outerMetric = metrics.first
      let innerMetric = metrics.dropFirst().first

      ZStack {
        if let outerMetric {
          CircularQuotaRing(
            metric: outerMetric,
            lineWidth: max(8, side * 0.12),
            ringColors: ringColors,
            ringLayer: .outer
          )
            .frame(width: side, height: side)
        }

        if let innerMetric {
          CircularQuotaRing(
            metric: innerMetric,
            lineWidth: max(6, side * 0.1),
            ringColors: ringColors,
            ringLayer: .inner
          )
            .frame(width: side * 0.64, height: side * 0.64)
        }

        if centerLabelStyle == .metrics {
          VStack(spacing: 1) {
            if let outerMetric {
              Text(percentText(for: outerMetric))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
            } else {
              Text("--")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }

            if let innerMetric {
              Text(percentText(for: innerMetric))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
          }
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
  }
}

private struct CircularQuotaRing: View {
  let metric: UsageMetric
  let lineWidth: CGFloat
  let ringColors: WidgetRingColors
  let ringLayer: WidgetRingLayer

  var body: some View {
    ZStack {
      Circle()
        .stroke(Color.white.opacity(0.16), lineWidth: lineWidth)

      Circle()
        .trim(from: 0, to: progress)
        .stroke(
          ringColor(for: metric, colors: ringColors, layer: ringLayer),
          style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        )
        .rotationEffect(.degrees(-90))
    }
  }

  private var progress: CGFloat {
    if metric.isUnlimited {
      return 1
    }
    let value = CGFloat(metric.remainingPercent ?? 0)
    return max(0, min(1, value / 100))
  }
}

private struct MiniProgressBar: View {
  let percent: Int?
  let unlimited: Bool
  let ringColors: WidgetRingColors
  let dualStops: [DashboardBarStop]
  let showDualStops: Bool

  var body: some View {
    GeometryReader { proxy in
      let width = max(0, proxy.size.width)
      let clampedPercent = max(0, min(100, percent ?? 0))
      let twoStops = dualStops.prefix(2)

      ZStack(alignment: .leading) {
        Capsule()
          .fill(Color.white.opacity(0.16))

        if unlimited {
          Capsule().fill(unlimitedColor(for: ringColors, layer: .outer))
        } else if showDualStops, twoStops.count >= 2 {
          ForEach(Array(twoStops).sorted(by: { $0.percent > $1.percent })) { stop in
            Capsule()
              .fill(ringColor(for: stop.percent, colors: ringColors, layer: stop.layer).opacity(stop.layer == .inner ? 0.55 : 0.82))
              .frame(width: width * CGFloat(stop.percent) / 100.0)
          }

          ForEach(Array(twoStops)) { stop in
            Capsule()
              .fill(ringColor(for: stop.percent, colors: ringColors, layer: stop.layer))
              .frame(width: 2.5)
              .position(
                x: markerPositionX(for: stop.percent, width: width),
                y: proxy.size.height / 2
              )
          }
        } else {
          Capsule()
            .fill(progressColor)
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

  private var progressColor: Color {
    ringColor(for: percent ?? 0, colors: ringColors, layer: .outer)
  }
}

private struct DashboardBarStop: Identifiable {
  let layer: WidgetRingLayer
  let percent: Int

  var id: String {
    "\(layer.rawValue)-\(percent)"
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

private func dashboardBarStops(for usage: ProviderUsage) -> [DashboardBarStop] {
  let metrics = chartMetrics(for: usage)
  var stops: [DashboardBarStop] = []

  if let first = metrics.first, !first.isUnlimited, let remaining = first.remainingPercent {
    stops.append(DashboardBarStop(layer: .outer, percent: max(0, min(100, remaining))))
  }

  if let second = metrics.dropFirst().first, !second.isUnlimited, let remaining = second.remainingPercent {
    stops.append(DashboardBarStop(layer: .inner, percent: max(0, min(100, remaining))))
  }

  return stops
}

private func dualLimitPercentText(for usage: ProviderUsage) -> String? {
  let boundedPercentages = dashboardBarStops(for: usage)
    .map(\.percent)
    .sorted()

  guard boundedPercentages.count >= 2 else {
    return nil
  }

  return "\(boundedPercentages[0])% / \(boundedPercentages[1])%"
}

private func dashboardPercentDisplayText(for usage: ProviderUsage) -> String? {
  let boundedPercentages = dashboardBarStops(for: usage)
    .map(\.percent)
    .sorted()

  if let worst = boundedPercentages.first {
    return "\(worst)%"
  }

  if usage.metrics.contains(where: \.isUnlimited) {
    return "INF"
  }

  return nil
}

private func chartMetrics(for usage: ProviderUsage) -> [UsageMetric] {
  let candidates = usage.metrics.filter { $0.remainingPercent != nil || $0.isUnlimited }
  if candidates.isEmpty {
    return usage.metrics
  }
  return Array(candidates.prefix(2))
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

  for snapshot in snapshots {
    for usage in snapshot.providers {
      var metricOrder = orderByAccount[usage.accountID] ?? []
      usageByAccount[usage.accountID] = usage

      for metric in usage.metrics {
        guard metric.remainingPercent != nil || metric.isUnlimited else {
          continue
        }

        let resolvedID = metric.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? metric.label
          : metric.id

        if !metricOrder.contains(resolvedID) {
          metricOrder.append(resolvedID)
        }

        let key = SeriesKey(accountID: usage.accountID, metricID: resolvedID)
        let remaining = metric.isUnlimited ? 100 : Double(metric.remainingPercent ?? 0)
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

    for (metricIndex, metricID) in metricIDs.enumerated() {
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

      let lineColor = trendLineColor(for: usage.accountID, metricIndex: metricIndex, entry: entry)

      series.append(
        TrendSeries(
          id: "\(usage.accountID):\(metricID)",
          provider: usage.provider,
          metricID: metricID,
          metricLabel: metricLabel,
          displayLabel: displayLabel,
          points: points,
          color: lineColor,
          resetAt: resetByKey[key]
        )
      )
    }
  }

  let warnings = depletionWarnings(for: series, now: now)
  return TrendChartData(series: series, startDate: startWindow, endDate: now, warnings: warnings)
}

private func trendLineColor(for accountID: String, metricIndex: Int, entry: QuotaEntry) -> Color {
  let colorSlots: [(WidgetRingColorRole, WidgetRingLayer)] = [
    (.high, .outer),
    (.high, .inner),
    (.medium, .outer),
    (.medium, .inner),
    (.low, .outer),
    (.low, .inner),
    (.unlimited, .outer),
    (.unlimited, .inner)
  ]

  let slot = colorSlots[metricIndex % colorSlots.count]
  let ringColors = entry.style(for: accountID).ringColors
  let hex = ringColors.hexColor(for: slot.0, layer: slot.1)
  return Color(hexColor: hex) ?? .white
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

private func resetSummaries(for metrics: [UsageMetric]) -> [String] {
  metrics.compactMap { metric in
    if let resetIn = metric.resetIn?.trimmingCharacters(in: .whitespacesAndNewlines), !resetIn.isEmpty {
      let normalized = normalizedResetSummary(resetIn)
      return normalized.isEmpty ? nil : normalized
    }

    if let resetAt = metric.resetAt {
      let relative = relativeResetSummary(until: resetAt)
      return relative.isEmpty ? nil : relative
    }

    return nil
  }
}

private func normalizedResetSummary(_ rawValue: String) -> String {
  let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
  let lowercased = value.lowercased()

  if lowercased == "reset" {
    return "<1m"
  }

  if lowercased.hasPrefix("reset in ") {
    return String(value.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  if lowercased.hasPrefix("in ") {
    return String(value.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  if lowercased.hasPrefix("reset ") {
    return String(value.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  return value
}

private func relativeResetSummary(until date: Date) -> String {
  let seconds = max(0, Int(date.timeIntervalSinceNow))
  if seconds < 60 {
    return "<1m"
  }

  let totalHours = seconds / 3600
  let minutes = (seconds % 3600) / 60

  if totalHours >= 24 {
    let days = totalHours / 24
    let hours = totalHours % 24
    return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
  }

  if totalHours > 0 {
    return minutes > 0 ? "\(totalHours)h \(minutes)m" : "\(totalHours)h"
  }

  return "\(minutes)m"
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

private func ringColor(for metric: UsageMetric, colors: WidgetRingColors, layer: WidgetRingLayer) -> Color {
  if metric.isUnlimited {
    return unlimitedColor(for: colors, layer: layer)
  }

  return ringColor(for: metric.remainingPercent ?? 0, colors: colors, layer: layer)
}

private func ringColor(for remainingPercent: Int, colors: WidgetRingColors, layer: WidgetRingLayer) -> Color {
  let value = max(0, min(100, remainingPercent))

  if value >= 70 { return Color(hexColor: colors.hexColor(for: .high, layer: layer)) ?? .green }
  if value >= 40 { return Color(hexColor: colors.hexColor(for: .medium, layer: layer)) ?? .yellow }
  return Color(hexColor: colors.hexColor(for: .low, layer: layer)) ?? .red
}

private func unlimitedColor(for colors: WidgetRingColors, layer: WidgetRingLayer) -> Color {
  Color(hexColor: colors.hexColor(for: .unlimited, layer: layer)) ?? .blue
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

  func style(for accountID: String) -> WidgetStyleSettings {
    let globalStyle = settings.widgetStyle
    let override = settings.styleOverride(for: accountID)

    guard override.useCustomStyle else {
      return globalStyle
    }

    let resolvedBackground = override.style.backgroundHexColor ?? globalStyle.backgroundHexColor

    return WidgetStyleSettings(
      backgroundHexColor: resolvedBackground,
      ringColors: override.style.ringColors,
      useTransparentBackground: override.style.useTransparentBackground
    )
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
      useTransparentBackground: override.useTransparentBackground
    )
  }
}

private extension Color {
  init?(hexColor: String?) {
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
      self = Color(red: red, green: green, blue: blue)
      return
    }

    let red = Double((parsed >> 24) & 0xFF) / 255.0
    let green = Double((parsed >> 16) & 0xFF) / 255.0
    let blue = Double((parsed >> 8) & 0xFF) / 255.0
    let alpha = Double(parsed & 0xFF) / 255.0
    self = Color(red: red, green: green, blue: blue, opacity: alpha)
  }
}
