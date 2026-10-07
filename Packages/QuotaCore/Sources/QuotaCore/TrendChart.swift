import Foundation

/// One reading of a trend line, dated by the snapshot that recorded it.
public struct TrendSample: Hashable, Sendable {
  public let date: Date
  public let remainingPercent: Double

  public init(date: Date, remainingPercent: Double) {
    self.date = date
    self.remainingPercent = remainingPercent
  }
}

/// One line of the trend chart: an account's metric for as long as it kept
/// one window kind. OpenAI and Codex name windows by response slot, so a
/// `primary` that changes from a 5-hour to a 7-day window becomes two lines,
/// each styled and filtered by its own kind.
public struct TrendSeriesData: Identifiable, Sendable {
  public let accountID: String
  public let metricID: String
  /// The newest label recorded for this line.
  public let label: String
  public let slot: LimitSeriesSlot
  /// Chronological readings.
  public let samples: [TrendSample]
  /// The latest snapshot no longer reports this metric with this window
  /// kind, so the line is history only: no current value, no forecast.
  public let isRetired: Bool

  public var id: String { "\(accountID):\(metricID):\(slot.kind.rawValue)" }
}

/// The lines one account contributes, in first-seen metric order.
public struct TrendAccountSeries: Sendable {
  /// The account's newest usage in the chart window. Color slots resolve
  /// against its full metric list, like the tile rings.
  public let usage: ProviderUsage
  public let series: [TrendSeriesData]
}

/// Why the trend chart has nothing to draw, most specific first.
public enum TrendEmptyReason: Equatable, Sendable {
  /// No enabled accounts.
  case noAccounts
  /// The user hid every enabled account from the chart.
  case allHidden
  /// Every reported limit is unlimited.
  case onlyUnlimited
  /// The accounts report balances or other amounts without a percentage.
  case onlyAmounts
  /// No readings in the window, and the latest refresh failed for every
  /// charted account it tried.
  case refreshFailing
  /// No readings in the window yet.
  case noHistory
}

public struct TrendChartContent: Sendable {
  /// Accounts in chart order: provider, then title.
  public let accounts: [TrendAccountSeries]
  /// Set exactly when `accounts` is empty.
  public let emptyReason: TrendEmptyReason?
}

public enum TrendSeriesBuilder {
  /// Groups `snapshots` (the chart window, any order) into lines for the
  /// accounts the trend filter shows. `latest` decides which lines are
  /// retired and, when nothing charts, whether the refresh is failing.
  public static func build(
    snapshots: [QuotaSnapshot],
    latest: QuotaSnapshot?,
    settings: AppSettings
  ) -> TrendChartContent {
    guard settings.accounts.contains(where: \.isEnabled) else {
      return TrendChartContent(accounts: [], emptyReason: .noAccounts)
    }

    let accountFilter = TrendChartAccountFilter(settings: settings)
    guard !accountFilter.hidesEveryAccount else {
      return TrendChartContent(accounts: [], emptyReason: .allHidden)
    }

    struct SeriesKey: Hashable {
      let accountID: String
      let metricID: String
      let kind: QuotaWindowKind
    }

    var kindCache = WindowKindCache()
    var samplesByKey: [SeriesKey: [TrendSample]] = [:]
    var labelByKey: [SeriesKey: String] = [:]
    var keyOrderByAccount: [String: [SeriesKey]] = [:]
    var usageByAccount: [String: ProviderUsage] = [:]
    var sawUnlimitedMetric = false
    var sawAmountMetric = false

    for snapshot in snapshots.sorted(by: { $0.generatedAt < $1.generatedAt }) {
      for usage in snapshot.providers where accountFilter.includes(usage) {
        usageByAccount[usage.accountID] = usage
        var keyOrder = keyOrderByAccount[usage.accountID] ?? []

        for metric in usage.metrics {
          // Unlimited metrics have no trend: they would pin a flat line at 100%.
          if metric.isUnlimited {
            sawUnlimitedMetric = true
            continue
          }
          guard let remaining = metric.remainingPercent else {
            sawAmountMetric = true
            continue
          }

          let key = SeriesKey(
            accountID: usage.accountID,
            metricID: metric.trendSeriesID,
            kind: kindCache.kind(of: metric)
          )
          if samplesByKey[key] == nil {
            keyOrder.append(key)
          }
          samplesByKey[key, default: []].append(
            TrendSample(date: snapshot.generatedAt, remainingPercent: Double(remaining))
          )
          labelByKey[key] = metric.label
        }

        keyOrderByAccount[usage.accountID] = keyOrder
      }
    }

    var liveKeys: Set<SeriesKey> = []
    for usage in latest?.providers ?? [] {
      for metric in usage.metrics where !metric.isUnlimited && metric.remainingPercent != nil {
        liveKeys.insert(SeriesKey(accountID: usage.accountID, metricID: metric.trendSeriesID, kind: kindCache.kind(of: metric)))
      }
    }

    let showShortTermLimits = settings.widgetVisibility.showShortTermLimitsInTrend
    let accountOrder = usageByAccount.values.sorted { lhs, rhs in
      if lhs.provider.rawValue != rhs.provider.rawValue {
        return lhs.provider.rawValue < rhs.provider.rawValue
      }
      if lhs.title != rhs.title {
        return lhs.title < rhs.title
      }
      return lhs.accountID < rhs.accountID
    }

    var accounts: [TrendAccountSeries] = []
    for usage in accountOrder {
      let keys = keyOrderByAccount[usage.accountID] ?? []
      guard !keys.isEmpty else { continue }

      let accountSlots = limitSeriesSlots(for: usage.metrics)
      let series = keys.map { key -> TrendSeriesData in
        // The newest usage's slot when it still reports this metric with this
        // kind, so the line agrees with the rings about its color.
        let index = usage.metrics.indices.first { index in
          let metric = usage.metrics[index]
          return (metric.id == key.metricID || metric.label == key.metricID)
            && accountSlots[index].kind == key.kind
        }
        return TrendSeriesData(
          accountID: key.accountID,
          metricID: key.metricID,
          label: labelByKey[key] ?? key.metricID,
          slot: index.map { accountSlots[$0] } ?? LimitSeriesSlot(kind: key.kind),
          samples: samplesByKey[key] ?? [],
          isRetired: !liveKeys.contains(key)
        )
      }

      // With short-term limits hidden, the fast windows drop out while the
      // account also reports a longer one. Retired lines do not count as
      // "also reports", or a gone weekly would hide a live session window.
      let liveKinds = series.filter { !$0.isRetired }.map(\.slot.kind)
      let accountKinds = liveKinds.isEmpty ? series.map(\.slot.kind) : liveKinds
      let charted = showShortTermLimits
        ? series
        : series.filter { chartsAsLongTermLimit($0.slot.kind, accountKinds: accountKinds) }
      guard !charted.isEmpty else { continue }

      accounts.append(TrendAccountSeries(usage: usage, series: charted))
    }

    guard accounts.isEmpty else {
      return TrendChartContent(accounts: accounts, emptyReason: nil)
    }

    let emptyReason: TrendEmptyReason
    if sawAmountMetric {
      emptyReason = .onlyAmounts
    } else if sawUnlimitedMetric {
      emptyReason = .onlyUnlimited
    } else if let latest, isFailingEveryChartedAccount(latest, filter: accountFilter) {
      emptyReason = .refreshFailing
    } else {
      emptyReason = .noHistory
    }
    return TrendChartContent(accounts: [], emptyReason: emptyReason)
  }

  /// The latest refresh failed for every shown account it covered and
  /// fetched none of them, so waiting will not bring a line by itself.
  private static func isFailingEveryChartedAccount(_ snapshot: QuotaSnapshot, filter: TrendChartAccountFilter) -> Bool {
    let chartedFailures = snapshot.failures.filter { filter.includes(accountID: $0.accountID, provider: $0.provider) }
    return !chartedFailures.isEmpty && !snapshot.providers.contains { filter.includes($0) }
  }

  /// Classification parses id and label text; history repeats the same few
  /// metrics thousands of times.
  private struct WindowKindCache {
    private var kinds: [String: QuotaWindowKind] = [:]

    mutating func kind(of metric: UsageMetric) -> QuotaWindowKind {
      let cacheKey = "\(metric.id)\u{0}\(metric.label)"
      if let kind = kinds[cacheKey] {
        return kind
      }
      let kind = QuotaWindowKind.classify(metricID: metric.id, label: metric.label)
      kinds[cacheKey] = kind
      return kind
    }
  }
}

/// A run of a trend line drawn with one style.
public struct TrendPathSegment: Hashable, Sendable {
  public enum Kind: Hashable, Sendable {
    /// Quota draining or holding.
    case consumption
    /// The vertical refill at a reset: an event marker, not data to read.
    case reset
  }

  public let kind: Kind
  public let samples: [TrendSample]
}

public enum TrendPathBuilder {
  /// Splits a line into consumption runs and reset risers. Quota drains and
  /// then refills in an instant, so a refill draws hold-then-snap: the run
  /// holds its last level until the reset sample, then a riser climbs to the
  /// new level. Rises within `QuotaForecast.resetJumpThreshold` are rounding
  /// jitter and stay inside the run.
  public static func segments(for samples: [TrendSample]) -> [TrendPathSegment] {
    var segments: [TrendPathSegment] = []
    var run: [TrendSample] = []

    for sample in samples {
      guard let previous = run.last else {
        run.append(sample)
        continue
      }

      guard sample.remainingPercent > previous.remainingPercent + QuotaForecast.resetJumpThreshold else {
        run.append(sample)
        continue
      }

      let hold = TrendSample(date: sample.date, remainingPercent: previous.remainingPercent)
      run.append(hold)
      segments.append(TrendPathSegment(kind: .consumption, samples: run))
      segments.append(TrendPathSegment(kind: .reset, samples: [hold, sample]))
      run = [sample]
    }

    if !run.isEmpty {
      segments.append(TrendPathSegment(kind: .consumption, samples: run))
    }
    return segments
  }
}

public struct TrendAxisTick: Hashable, Sendable {
  public let date: Date
  public let label: String
}

/// Time-axis ticks that name what they mark: hours for short spans,
/// abbreviated weekdays up to about a week, and day-of-month beyond that.
public enum TrendAxisTicks {
  static let hourlySpanLimit: TimeInterval = 36 * 3_600
  static let weekdaySpanLimit: TimeInterval = 8 * 86_400
  private static let hourStrides = [1, 2, 3, 4, 6, 12]
  private static let dayStrides = [1, 2, 3, 5, 7, 10, 14]

  /// At most `maxLabels` ticks at local hour or midnight boundaries inside
  /// `start...end`. A midnight among hour ticks shows its weekday, and
  /// day-of-month ticks show the month at the first tick and at month changes.
  public static func make(start: Date, end: Date, calendar: Calendar, locale: Locale, maxLabels: Int) -> [TrendAxisTick] {
    guard end > start, maxLabels > 0 else { return [] }

    let span = end.timeIntervalSince(start)
    if span <= hourlySpanLimit {
      return hourTicks(start: start, end: end, calendar: calendar, locale: locale, maxLabels: maxLabels)
    }

    let midnights = localMidnights(start: start, end: end, calendar: calendar)
    let stride = dayStrides.first { (midnights.count + $0 - 1) / $0 <= maxLabels } ?? dayStrides[dayStrides.count - 1]
    let chosen = thinned(midnights.enumerated().filter { $0.offset % stride == 0 }.map(\.element), to: maxLabels)

    if span <= weekdaySpanLimit {
      let weekday = formatter(template: "EEE", calendar: calendar, locale: locale)
      return chosen.map { TrendAxisTick(date: $0, label: weekday.string(from: $0)) }
    }

    let dayOfMonth = formatter(template: "d", calendar: calendar, locale: locale)
    let monthAndDay = formatter(template: "MMMd", calendar: calendar, locale: locale)
    var previousMonth: Int?
    return chosen.map { date in
      let month = calendar.component(.month, from: date)
      defer { previousMonth = month }
      let label = month == previousMonth ? dayOfMonth.string(from: date) : monthAndDay.string(from: date)
      return TrendAxisTick(date: date, label: label)
    }
  }

  /// Just the chart's start and "now", for widgets too small for a scale.
  public static func endpoints(start: Date, end: Date, calendar: Calendar, locale: Locale) -> [TrendAxisTick] {
    guard end > start else { return [] }

    let span = end.timeIntervalSince(start)
    let template: String
    if span <= hourlySpanLimit {
      template = "jmm"
    } else if span <= weekdaySpanLimit {
      template = "EEE"
    } else {
      template = "MMMd"
    }
    let startLabel = formatter(template: template, calendar: calendar, locale: locale).string(from: start)
    return [TrendAxisTick(date: start, label: startLabel), TrendAxisTick(date: end, label: "now")]
  }

  private static func hourTicks(start: Date, end: Date, calendar: Calendar, locale: Locale, maxLabels: Int) -> [TrendAxisTick] {
    var hours: [Date] = []
    var next = calendar.dateInterval(of: .hour, for: start)?.end
    while let current = next, current <= end {
      hours.append(current)
      // Adding an hour steps through repeated and skipped DST hours.
      guard let following = calendar.date(byAdding: .hour, value: 1, to: current), following > current else { break }
      next = following
    }

    func hourOfDay(_ date: Date) -> Int { calendar.component(.hour, from: date) }
    let stride = hourStrides.first { stride in
      hours.filter { hourOfDay($0) % stride == 0 }.count <= maxLabels
    } ?? hourStrides[hourStrides.count - 1]
    let chosen = thinned(hours.filter { hourOfDay($0) % stride == 0 }, to: maxLabels)

    let hour = formatter(template: "j", calendar: calendar, locale: locale)
    let weekday = formatter(template: "EEE", calendar: calendar, locale: locale)
    return chosen.map { date in
      let label = hourOfDay(date) == 0 ? weekday.string(from: date) : hour.string(from: date)
      return TrendAxisTick(date: date, label: label)
    }
  }

  private static func localMidnights(start: Date, end: Date, calendar: Calendar) -> [Date] {
    var midnights: [Date] = []
    var current = calendar.startOfDay(for: start)
    if current <= start, let nextDay = calendar.date(byAdding: .day, value: 1, to: current) {
      current = calendar.startOfDay(for: nextDay)
    }
    while current <= end {
      midnights.append(current)
      guard let nextDay = calendar.date(byAdding: .day, value: 1, to: current) else { break }
      let following = calendar.startOfDay(for: nextDay)
      guard following > current else { break }
      current = following
    }
    return midnights
  }

  private static func thinned(_ dates: [Date], to maxCount: Int) -> [Date] {
    guard dates.count > maxCount else { return dates }
    let step = (dates.count + maxCount - 1) / maxCount
    return dates.enumerated().filter { $0.offset % step == 0 }.map(\.element)
  }

  private static func formatter(template: String, calendar: Calendar, locale: Locale) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.setLocalizedDateFormatFromTemplate(template)
    return formatter
  }
}
