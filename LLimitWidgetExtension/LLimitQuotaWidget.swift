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
      if let emptyReason = chartData.emptyReason {
        let message = emptyMessage(for: emptyReason)
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
          // The reserved warning orange on a dark capsule: 5.1:1 (light) and
          // 5.5:1 (dark) against the default #5994F2 background.
          HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(warning.message)
              .lineLimit(1)
              .minimumScaleFactor(0.8)
            if chartData.warnings.count > 1 {
              Text("+\(chartData.warnings.count - 1)")
                .fixedSize()
            }
          }
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(Color.orange)
          .padding(.horizontal, 6)
          .padding(.vertical, 2.5)
          .background(Color.black.opacity(0.6), in: Capsule())
        }
      }
    }
    .padding(family == .systemSmall ? 7 : 9)
    .accessibilityLabel(trendAccessibilityLabel(days: days, warnings: chartData.warnings))
  }

  /// Each reason says what will (or will not) fill the chart, so the widget
  /// never promises data that cannot arrive.
  private func emptyMessage(for reason: TrendEmptyReason) -> (title: String, detail: String) {
    switch reason {
    case .noAccounts:
      return ("No accounts", "Add an account in LLimit to chart its quota")
    case .allHidden:
      return ("No accounts selected", "Choose accounts under Trend Widget in LLimit Settings")
    case .onlyUnlimited:
      return ("Unlimited plans only", "Every tracked limit reports unlimited — nothing to chart")
    case .onlyAmounts:
      return ("No limits to chart", "Your accounts report balances, which have no percentage to chart")
    case .refreshFailing:
      return ("No data to chart", "LLimit could not refresh your accounts. Open LLimit to check them")
    case .noHistory:
      return ("No history yet", "The chart fills in as LLimit refreshes")
    }
  }

  private func trendAccessibilityLabel(days: Int, warnings: [TrendWarning]) -> String {
    let start = entry.date.addingTimeInterval(-Double(days) * 86_400)
    let snapshots = entry.history + [entry.snapshot].compactMap { $0 }
    // Only charted accounts count: a hidden account's estimate is not on screen.
    let accountFilter = TrendChartAccountFilter(settings: entry.settings)
    let includesEstimates = snapshots.contains { snapshot in
      snapshot.generatedAt >= start && snapshot.generatedAt <= entry.date
        && snapshot.providers.contains { usage in
          accountFilter.includes(usage) && usage.metrics.contains(where: \.isPercentageEstimated)
        }
    }
    let chart = includesEstimates
      ? "Quota trend chart. Includes estimated remaining percentages."
      : "Quota trend chart."
    let spokenWarnings = warnings.map {
      " Warning: \($0.message.replacingOccurrences(of: "~", with: "about "))."
    }
    return chart + spokenWarnings.joined()
  }
}

/// How much of the time axis a chart labels.
private enum TrendAxisStyle {
  /// Percent labels plus as many hour, weekday or date ticks as fit.
  case full
  /// Only the start and "now": a small widget has no room for a scale.
  case endpoints
}

private struct TrendChartPlotView: View {
  let series: [TrendSeries]
  let startDate: Date
  let endDate: Date
  let axisStyle: TrendAxisStyle

  // Labels live in gutters beside and below the plot, never under the
  // newest data at its right edge.
  private static let percentGutterWidth: CGFloat = 17
  private static let timeGutterHeight: CGFloat = 11
  /// Keeps lines and endpoint dots off the plot's edges.
  private static let plotInset: CGFloat = 3
  /// Room per time label, so ticks thin out on narrow widgets.
  private static let timeLabelSpacing: CGFloat = 34
  private static let axisFontSize: CGFloat = 8
  /// Black behind the plot and its gutters. With it, 0.9-white axis labels
  /// measure 4.9:1 on the default #5994F2 background (4.5:1 under the
  /// top-right sheen, 5.8:1 along the darker bottom).
  private static let scrimOpacity = 0.3
  private static let axisLabelOpacity = 0.9
  /// Reset risers mark an event, not data, so they stay faint and uncased.
  private static let resetRiserWidth: CGFloat = 0.6
  private static let resetRiserOpacity = 0.3

  var body: some View {
    GeometryReader { proxy in
      let showsPercentLabels = axisStyle == .full
      let plotSize = CGSize(
        width: max(1, proxy.size.width - (showsPercentLabels ? Self.percentGutterWidth : 0)),
        height: max(1, proxy.size.height - Self.timeGutterHeight)
      )
      let ticks = timeTicks(plotWidth: plotSize.width)

      ZStack {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(Color.black.opacity(Self.scrimOpacity))

        // Horizontal grid lines at 0%, 25%, 50%, 75%, 100%
        ForEach([0, 25, 50, 75, 100], id: \.self) { level in
          Path { path in
            let y = yPosition(for: Double(level), in: plotSize)
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: plotSize.width, y: y))
          }
          .stroke(Color.white.opacity(level % 50 == 0 ? 0.13 : 0.07), lineWidth: 0.8)
        }

        // Vertical grid lines at the labeled ticks
        if axisStyle == .full {
          ForEach(ticks, id: \.date) { tick in
            Path { path in
              let x = xPosition(for: tick.date, in: plotSize)
              path.move(to: CGPoint(x: x, y: 0))
              path.addLine(to: CGPoint(x: x, y: plotSize.height))
            }
            .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
          }
        }

        if showsPercentLabels {
          ForEach([100, 50, 0], id: \.self) { level in
            Text("\(level)")
              .font(.system(size: Self.axisFontSize, weight: .medium))
              .monospacedDigit()
              .foregroundStyle(.white.opacity(Self.axisLabelOpacity))
              .position(
                x: plotSize.width + Self.percentGutterWidth / 2,
                y: max(yPosition(for: Double(level), in: plotSize), Self.axisFontSize / 2 + 1)
              )
          }
        }

        ForEach(ticks, id: \.date) { tick in
          Text(tick.label)
            .font(.system(size: Self.axisFontSize, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(.white.opacity(Self.axisLabelOpacity))
            .position(
              x: timeLabelCenter(for: tick, plotWidth: plotSize.width),
              y: plotSize.height + Self.timeGutterHeight / 2
            )
        }

        // Data lines (pre-sorted by draw priority). A dark casing keeps every
        // line separable from whatever background the widget sits on.
        ForEach(series) { line in
          let segments = TrendPathBuilder.segments(for: line.samples)
          let consumption = path(for: segments, kind: .consumption, in: plotSize)
          // Butt caps on dashed lines: round caps add the line width to every
          // dash and close the gaps that tell same-hue lines apart. The casing
          // stays solid so the gaps read as dark breaks.
          let stroke = StrokeStyle(
            lineWidth: line.lineWidth,
            lineCap: line.dashPattern.isEmpty ? .round : .butt,
            lineJoin: .round,
            dash: line.dashPattern
          )

          path(for: segments, kind: .reset, in: plotSize)
            .stroke(line.color.opacity(Self.resetRiserOpacity), lineWidth: Self.resetRiserWidth)
          consumption
            .stroke(Color.black.opacity(0.28), style: StrokeStyle(lineWidth: line.lineWidth + 1.5, lineCap: .round, lineJoin: .round))
          consumption
            .stroke(line.color.opacity(line.lineOpacity), style: stroke)

          // A retired line has no current value to mark.
          if !line.isRetired, let latest = line.samples.last {
            Circle()
              .fill(line.color)
              .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 0.8))
              .frame(width: 4.5, height: 4.5)
              .position(
                x: xPosition(for: latest.date, in: plotSize),
                y: yPosition(for: latest.remainingPercent, in: plotSize)
              )
          }
        }
      }
    }
  }

  private func timeTicks(plotWidth: CGFloat) -> [TrendAxisTick] {
    switch axisStyle {
    case .full:
      let maxLabels = max(1, Int(plotWidth / Self.timeLabelSpacing))
      return TrendAxisTicks.make(start: startDate, end: endDate, calendar: .current, locale: .current, maxLabels: maxLabels)
    case .endpoints:
      return TrendAxisTicks.endpoints(start: startDate, end: endDate, calendar: .current, locale: .current)
    }
  }

  /// Centers a label on its tick but keeps it inside the plot's width. The
  /// width is estimated: Text cannot be measured inside this layout pass.
  private func timeLabelCenter(for tick: TrendAxisTick, plotWidth: CGFloat) -> CGFloat {
    let halfWidth = min(plotWidth / 2, CGFloat(tick.label.count) * Self.axisFontSize * 0.29 + 1)
    let x = xPosition(for: tick.date, in: CGSize(width: plotWidth, height: 1))
    return min(max(x, halfWidth), plotWidth - halfWidth)
  }

  private func path(for segments: [TrendPathSegment], kind: TrendPathSegment.Kind, in plotSize: CGSize) -> Path {
    Path { path in
      for segment in segments where segment.kind == kind {
        guard let first = segment.samples.first else { continue }
        path.move(to: point(for: first, in: plotSize))
        for sample in segment.samples.dropFirst() {
          path.addLine(to: point(for: sample, in: plotSize))
        }
      }
    }
  }

  private func point(for sample: TrendSample, in plotSize: CGSize) -> CGPoint {
    CGPoint(
      x: xPosition(for: sample.date, in: plotSize),
      y: yPosition(for: sample.remainingPercent, in: plotSize)
    )
  }

  private func xPosition(for date: Date, in plotSize: CGSize) -> CGFloat {
    let duration = max(1, endDate.timeIntervalSince(startDate))
    let elapsed = min(max(date.timeIntervalSince(startDate), 0), duration)
    let usableWidth = max(0, plotSize.width - 2 * Self.plotInset)
    return Self.plotInset + CGFloat(elapsed / duration) * usableWidth
  }

  private func yPosition(for remainingPercent: Double, in plotSize: CGSize) -> CGFloat {
    let clamped = min(max(remainingPercent, 0), 100)
    let usableHeight = max(0, plotSize.height - 2 * Self.plotInset)
    return Self.plotInset + (1 - CGFloat(clamped / 100)) * usableHeight
  }
}

private struct TrendSeries: Identifiable {
  let id: String
  let samples: [TrendSample]
  let color: Color
  let lineWidth: CGFloat
  let lineOpacity: Double
  let dashPattern: [CGFloat]
  let drawPriority: Int
  let isRetired: Bool
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
  // Set exactly when there is nothing to chart, saying why.
  var emptyReason: TrendEmptyReason?
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
            primaryHexColor: entry.settings.primaryHexColor(for: usage.accountID),
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
            primaryHexColor: entry.settings.primaryHexColor(for: usage.accountID),
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
  let primaryHexColor: String?
  let showProgressBar: Bool
  let showPercentages: Bool
  let showDualLimitPercentages: Bool

  var body: some View {
    let metric = dashboardPrimaryMetric(for: usage)
    let dualPercent = showDualLimitPercentages ? dualLimitPercentText(for: usage) : nil
    let basePercent = metric?.remainingPercent ?? providerRemainingPercent(for: usage)
    let unlimited = metric?.isUnlimited ?? usage.metrics.contains(where: \.isUnlimited)

    HStack(spacing: 6) {
      Text(shortName + (!showPercentages && metric?.isPercentageEstimated == true ? " ≈" : ""))
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
        .frame(width: 58, alignment: .leading)

      if showProgressBar, basePercent != nil || unlimited {
        MiniProgressBar(
          percent: basePercent,
          unlimited: unlimited,
          tint: LimitKindColorScheme.accountAccent(for: usage.metrics, colors: kindColors, step: colorStep, primaryHexColor: primaryHexColor),
          stops: dashboardBarStops(for: usage, kindColors: kindColors, step: colorStep, primaryHexColor: primaryHexColor),
          showDualStops: showDualLimitPercentages
        )
          .frame(height: 5)
      } else {
        Spacer(minLength: 0)
      }

      if showPercentages || (basePercent == nil && metric?.usageLine != nil) {
        // Single mode labels the SAME metric the bar fills with
        // (dashboardPrimaryMetric), so the number can never contradict the bar.
        Text(dualPercent ?? percentText(for: metric))
          .font(.caption2.weight(.semibold))
          .monospacedDigit()
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .frame(width: basePercent == nil && !unlimited ? nil : (dualPercent == nil ? 40 : 72), alignment: .trailing)
          .accessibilityLabel(dualPercent == nil
            ? percentageAccessibilityText(for: metric)
            : dualLimitAccessibilityText(for: usage))
      }
    }
    .accessibilityElement(children: .combine)
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

private func dashboardBarPercents(for usage: ProviderUsage) -> [Int] {
  dashboardBarMetrics(for: usage)
    .map { max(0, min(100, $0.remainingPercent ?? 0)) }
    .sorted()
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

  let content = TrendSeriesBuilder.build(
    snapshots: snapshots,
    latest: entry.snapshot ?? snapshots.last,
    settings: entry.settings
  )
  if let emptyReason = content.emptyReason {
    return TrendChartData(series: [], startDate: startWindow, endDate: now, warnings: [], emptyReason: emptyReason)
  }

  var series: [TrendSeries] = []
  var forecastKeys: [QuotaForecast.SeriesKey] = []
  var warningLabels: [QuotaForecast.SeriesKey: String] = [:]
  let kindColors = entry.settings.widgetStyle.limitKindColors

  for account in content.accounts {
    let usage = account.usage
    // Color slots resolve against the account's full metric list so the chart
    // agrees with the rings and the dashboard about which color a metric owns.
    let primarySlot = primaryLimitSlot(for: usage.metrics)
    let primaryHexColor = entry.settings.primaryHexColor(for: usage.accountID)
    // Lines wear the account's color-scheme variant — the same colors as the
    // account's tile rings, which act as the chart's legend.
    let accountStep = accountColorStep(forAccountID: usage.accountID, in: entry.settings.accounts)
    // Two limits of ONE account can still resolve to the same hue (Claude's
    // two weeklies, a third per-model quota re-using an aux color). The tile
    // can't show those either, so the chart adds a dash for repeats. Live
    // lines claim the solid stroke before retired ones.
    var duplicateOrdinalByHex: [String: Int] = [:]
    let liveFirst = account.series.filter { !$0.isRetired } + account.series.filter(\.isRetired)

    for line in liveFirst {
      let slot = line.slot
      let baseHex = (slot == primarySlot ? primaryHexColor : nil) ?? kindColors.hexColor(for: slot)
      let duplicateOrdinal = duplicateOrdinalByHex[baseHex, default: 0]
      duplicateOrdinalByHex[baseHex] = duplicateOrdinal + 1
      let lineColor = LimitKindColorScheme.color(
        for: slot, colors: kindColors, step: accountStep,
        primarySlot: primarySlot, primaryHexColor: primaryHexColor
      )

      let style = seriesStyle(for: slot.kind)
      series.append(
        TrendSeries(
          id: line.id,
          samples: downsampleTrendSamples(line.samples, maxCount: 240),
          color: lineColor,
          lineWidth: style.lineWidth,
          lineOpacity: style.opacity,
          dashPattern: trendDashPattern(forDuplicateOrdinal: duplicateOrdinal),
          drawPriority: style.drawPriority,
          isRetired: line.isRetired
        )
      )

      // Retired lines have no current value to project. One forecast per
      // metric keeps warning ids unique.
      let key = QuotaForecast.SeriesKey(accountID: line.accountID, metricID: line.metricID)
      guard !line.isRetired, !forecastKeys.contains(key) else { continue }
      forecastKeys.append(key)
      warningLabels[key] = "\(compactProviderName(for: usage)) \(compactMetricLabel(line.label))"
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

  // The forecast reads the full loaded history, not the downsampled lines,
  // and only the current snapshot can vouch that a limit is live.
  let forecasts = QuotaForecast.depletionWarnings(
    for: forecastKeys,
    history: entry.history,
    latest: entry.snapshot,
    now: now,
    refreshInterval: TimeInterval(entry.refreshIntervalMinutes * 60)
  )
  let warnings = forecasts.map { forecast -> TrendWarning in
    let key = QuotaForecast.SeriesKey(accountID: forecast.accountID, metricID: forecast.metricID)
    let label = warningLabels[key] ?? forecast.metricLabel
    return TrendWarning(id: "\(forecast.accountID):\(forecast.metricID)", message: "\(label): \(forecast.timing(at: now))")
  }

  return TrendChartData(series: series, startDate: chartStart, endDate: now, warnings: warnings)
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

/// Same-hue repeats within one account: a long dash, dots, then dash-dot.
/// The rhythms stay distinct because dashed lines use butt caps. Four
/// same-hue lines happen when retired lines join live ones (an OpenAI slot
/// that changed window, a renamed per-model quota); a fifth repeats dash-dot.
private func trendDashPattern(forDuplicateOrdinal ordinal: Int) -> [CGFloat] {
  switch ordinal {
  case 0:
    return []
  case 1:
    return [5, 3]
  case 2:
    return [1.5, 2.5]
  default:
    return [5, 2.5, 1.5, 2.5]
  }
}

private func downsampleTrendSamples(_ samples: [TrendSample], maxCount: Int) -> [TrendSample] {
  let sorted = samples.sorted { $0.date < $1.date }
  guard sorted.count > maxCount, maxCount > 1 else {
    return sorted
  }

  let scale = Double(sorted.count - 1) / Double(maxCount - 1)
  var sampled: [TrendSample] = []
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
    return "Go"
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
    return "\(metric.isPercentageEstimated ? "≈" : "")\(remaining)%"
  }
  return metric.usageLine ?? "--"
}

private func percentageAccessibilityText(for metric: UsageMetric?) -> String {
  guard let metric, let remaining = metric.remainingPercent, !metric.isUnlimited else {
    return percentText(for: metric)
  }
  return "\(metric.isPercentageEstimated ? "Estimated " : "")\(remaining) percent remaining"
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

