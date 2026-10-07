import Foundation

public struct TrendSample: Hashable, Sendable {
  public let date: Date
  public let remainingPercent: Double
  public let resetAt: Date?

  public init(date: Date, remainingPercent: Double, resetAt: Date? = nil) {
    self.date = date
    self.remainingPercent = remainingPercent
    self.resetAt = resetAt
  }
}

public enum TrendSeriesState: Sendable {
  case current, stale, retired
}

/// Metric identity includes its kind: response slots can change windows.
public struct TrendSeriesData: Identifiable, Sendable {
  public let accountID: String
  public let metricID: String
  public let label: String
  public let slot: LimitSeriesSlot
  public let samples: [TrendSample]
  public let state: TrendSeriesState
  public var isRetired: Bool { state == .retired }
  public var isStale: Bool { state == .stale }
  public var id: String { "\(accountID):\(metricID):\(slot.kind.rawValue)" }
}

public struct TrendAccountSeries: Sendable {
  public let usage: ProviderUsage
  public let series: [TrendSeriesData]
}

public enum TrendEmptyReason: Equatable, Sendable {
  case noAccounts, allHidden, onlyUnlimited, onlyAmounts, refreshFailing, noHistory
}

public struct TrendChartContent: Sendable {
  public let accounts: [TrendAccountSeries]
  public let emptyReason: TrendEmptyReason?
}

public enum TrendSeriesBuilder {
  public static func build(
    snapshots: [QuotaSnapshot], latest: QuotaSnapshot?, settings: AppSettings,
    window: ClosedRange<Date> = Date.distantPast...Date.distantFuture,
    now: Date = Date(), refreshInterval: TimeInterval = TimeInterval(AppSettings.refreshIntervalRange.lowerBound * 60)
  ) -> TrendChartContent {
    guard settings.accounts.contains(where: \.isEnabled) else {
      return TrendChartContent(accounts: [], emptyReason: .noAccounts)
    }
    let filter = TrendChartAccountFilter(settings: settings)
    guard !filter.hidesEveryAccount else {
      return TrendChartContent(accounts: [], emptyReason: .allHidden)
    }

    struct Key: Hashable {
      let accountID: String
      let metricID: String
      let kind: QuotaWindowKind
      init(_ usage: ProviderUsage, _ metric: UsageMetric) {
        accountID = usage.accountID
        metricID = metric.trendSeriesID
        kind = QuotaWindowKind.classify(metricID: metric.id, label: metric.label)
      }
    }

    var samples: [Key: [TrendSample]] = [:]
    var labels: [Key: String] = [:]
    var order: [String: [Key]] = [:]
    var usages: [String: ProviderUsage] = [:]
    var sawUnlimited = false
    var sawAmounts = false

    let observations = QuotaObservations.extract(from: snapshots, accounts: settings.accounts, window: window)
    for usage in observations where filter.includes(usage) {
      usages[usage.accountID] = usage
      for metric in usage.metrics {
        if metric.isUnlimited { sawUnlimited = true; continue }
        guard let remaining = metric.remainingPercent else { sawAmounts = true; continue }
        let key = Key(usage, metric)
        if samples[key] == nil { order[usage.accountID, default: []].append(key) }
        samples[key, default: []].append(TrendSample(date: usage.fetchedAt,
          remainingPercent: Double(clampPercent(remaining)), resetAt: metric.resetAt))
        labels[key] = metric.label
      }
    }

    let current = latest?.reconciled(with: settings.accounts)
    var reportedKeys: Set<Key> = []
    var freshKeys: Set<Key> = []
    for usage in usages.values {
      let failed = current?.failures.contains { $0.accountID == usage.accountID && $0.provider == usage.provider } ?? false
      // A failed refresh cannot prove retirement or revive a previous kind.
      let reported = failed ? usage : current?.providers.first { $0.accountID == usage.accountID } ?? usage
      let keys = reported.metrics.filter { !$0.isUnlimited && $0.remainingPercent != nil }.map { Key(reported, $0) }
      reportedKeys.formUnion(keys)
      if !failed, current?.providers.contains(where: { $0.accountID == usage.accountID }) == true,
         QuotaForecast.isFresh(reported, now: now, refreshInterval: refreshInterval) {
        freshKeys.formUnion(keys)
      }
    }
    let accountOrder = usages.values.sorted {
      ($0.provider.rawValue, $0.title, $0.accountID) < ($1.provider.rawValue, $1.title, $1.accountID)
    }
    var accounts: [TrendAccountSeries] = []
    for usage in accountOrder {
      let slots = limitSeriesSlots(for: usage.metrics)
      let series = (order[usage.accountID] ?? []).map { key in
        let index = usage.metrics.indices.first { usage.metrics[$0].trendSeriesID == key.metricID && slots[$0].kind == key.kind }
        return TrendSeriesData(accountID: key.accountID, metricID: key.metricID,
          label: labels[key] ?? key.metricID, slot: index.map { slots[$0] } ?? LimitSeriesSlot(kind: key.kind),
          samples: samples[key] ?? [], state: freshKeys.contains(key) ? .current : reportedKeys.contains(key) ? .stale : .retired)
      }
      let liveKinds = series.filter { !$0.isRetired }.map(\.slot.kind)
      let kinds = liveKinds.isEmpty ? series.map(\.slot.kind) : liveKinds
      let charted = settings.widgetVisibility.showShortTermLimitsInTrend ? series
        : series.filter { chartsAsLongTermLimit($0.slot.kind, accountKinds: kinds) }
      if !charted.isEmpty { accounts.append(TrendAccountSeries(usage: usage, series: charted)) }
    }
    guard accounts.isEmpty else { return TrendChartContent(accounts: accounts, emptyReason: nil) }

    let failing = current.map { snapshot in
      !snapshot.failures.filter { filter.includes(accountID: $0.accountID, provider: $0.provider) }.isEmpty
        && !snapshot.providers.contains { usage in
          filter.includes(usage) && !snapshot.failures.contains { $0.accountID == usage.accountID && $0.provider == usage.provider }
        }
    } ?? false
    let reason: TrendEmptyReason = sawAmounts ? .onlyAmounts : sawUnlimited ? .onlyUnlimited : failing ? .refreshFailing : .noHistory
    return TrendChartContent(accounts: [], emptyReason: reason)
  }
}

extension UsageMetric {
  var trendSeriesID: String {
    id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? label : id
  }
}

public struct TrendPathSegment: Hashable, Sendable {
  public enum Kind: Hashable, Sendable {
    case consumption, reset
  }
  public let kind: Kind
  public let samples: [TrendSample]
}

public enum TrendPathBuilder {
  public static func downsample(_ samples: [TrendSample], maxCount: Int) -> [TrendSample] {
    guard samples.count > maxCount, maxCount > 1 else { return samples }
    var selected: Set<Int> = [0, samples.count - 1]
    for index in samples.indices.dropFirst() where isReset(from: samples[index - 1], to: samples[index]) {
      selected.insert(index - 1)
      selected.insert(index)
    }

    // Reset boundaries outrank the drawing budget; never smooth them away.
    let remaining = maxCount - selected.count
    if remaining > 0 {
      let scale = Double(samples.count - 1) / Double(remaining + 1)
      for index in 1...remaining { selected.insert(Int((Double(index) * scale).rounded())) }
    }
    return selected.sorted().map { samples[$0] }
  }

  /// Hold-then-snap refills are event markers, not a diagonal consumption rate.
  public static func segments(for samples: [TrendSample]) -> [TrendPathSegment] {
    var segments: [TrendPathSegment] = []
    var run: [TrendSample] = []
    for sample in samples {
      guard let previous = run.last else { run.append(sample); continue }
      guard isReset(from: previous, to: sample) else { run.append(sample); continue }

      let hold = TrendSample(date: sample.date, remainingPercent: previous.remainingPercent)
      run.append(hold)
      segments.append(TrendPathSegment(kind: .consumption, samples: run))
      segments.append(TrendPathSegment(kind: .reset, samples: [hold, sample]))
      run = [sample]
    }
    if !run.isEmpty { segments.append(TrendPathSegment(kind: .consumption, samples: run)) }
    return segments
  }

  private static func isReset(from previous: TrendSample, to sample: TrendSample) -> Bool {
    (previous.resetAt.map { $0 <= sample.date } ?? false)
      || sample.remainingPercent > previous.remainingPercent + QuotaForecast.resetJumpThreshold
  }
}

public struct TrendAxisTick: Hashable, Sendable {
  public let date: Date
  public let label: String
}

/// Local hour, weekday and date ticks with a bounded label budget.
public enum TrendAxisTicks {
  private static let hourlySpanLimit: TimeInterval = 36 * 3_600
  private static let weekdaySpanLimit: TimeInterval = 8 * 86_400
  private static let hourStrides = [1, 2, 3, 4, 6, 12]
  private static let dayStrides = [1, 2, 3, 5, 7, 10, 14]

  public static func make(start: Date, end: Date, calendar: Calendar, locale: Locale, maxLabels: Int) -> [TrendAxisTick] {
    guard end > start, maxLabels > 0 else { return [] }
    let span = end.timeIntervalSince(start)
    if span <= hourlySpanLimit {
      return hourTicks(start: start, end: end, calendar: calendar, locale: locale, maxLabels: maxLabels)
    }

    let midnights = localMidnights(start: start, end: end, calendar: calendar)
    let stride = dayStrides.first { (midnights.count + $0 - 1) / $0 <= maxLabels } ?? dayStrides[dayStrides.count - 1]
    // End-anchor day ticks: readers look at the recent end first.
    let chosen = thinned(midnights.enumerated().filter { (midnights.count - 1 - $0.offset) % stride == 0 }.map(\.element), to: maxLabels)
    if span <= weekdaySpanLimit {
      let weekday = formatter(template: "EEE", calendar: calendar, locale: locale)
      return chosen.map { TrendAxisTick(date: $0, label: weekday.string(from: $0)) }
    }

    let day = formatter(template: "d", calendar: calendar, locale: locale)
    let monthDay = formatter(template: "MMMd", calendar: calendar, locale: locale)
    var previousMonth: Int?
    return chosen.map { date in
      let month = calendar.component(.month, from: date)
      defer { previousMonth = month }
      return TrendAxisTick(date: date, label: (month == previousMonth ? day : monthDay).string(from: date))
    }
  }

  public static func endpoints(start: Date, end: Date, calendar: Calendar, locale: Locale) -> [TrendAxisTick] {
    guard end > start else { return [] }
    let span = end.timeIntervalSince(start)
    let template = span <= hourlySpanLimit ? "jmm" : span <= weekdaySpanLimit ? "EEE" : "MMMd"
    return [TrendAxisTick(date: start, label: formatter(template: template, calendar: calendar, locale: locale).string(from: start)),
      TrendAxisTick(date: end, label: "now")]
  }

  private static func hourTicks(start: Date, end: Date, calendar: Calendar, locale: Locale, maxLabels: Int) -> [TrendAxisTick] {
    func hourOfDay(_ date: Date) -> Int { calendar.component(.hour, from: date) }
    var hours: [Date] = []
    var next = calendar.dateInterval(of: .hour, for: start)?.end
    while let current = next, current <= end {
      // Keep the first occurrence of a repeated fall-back hour.
      if hours.last.map(hourOfDay) != hourOfDay(current) { hours.append(current) }
      guard let following = calendar.date(byAdding: .hour, value: 1, to: current), following > current else { break }
      next = following
    }
    let stride = hourStrides.first { stride in hours.filter { hourOfDay($0) % stride == 0 }.count <= maxLabels }
      ?? hourStrides[hourStrides.count - 1]
    let chosen = thinned(hours.filter { hourOfDay($0) % stride == 0 }, to: maxLabels)
    let hour = formatter(template: "j", calendar: calendar, locale: locale)
    let weekday = formatter(template: "EEE", calendar: calendar, locale: locale)
    return chosen.map { TrendAxisTick(date: $0, label: (hourOfDay($0) == 0 ? weekday : hour).string(from: $0)) }
  }

  private static func localMidnights(start: Date, end: Date, calendar: Calendar) -> [Date] {
    var dates: [Date] = []
    var current = calendar.startOfDay(for: start)
    if current <= start, let next = calendar.date(byAdding: .day, value: 1, to: current) {
      current = calendar.startOfDay(for: next)
    }
    while current <= end {
      dates.append(current)
      guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
      let following = calendar.startOfDay(for: next)
      guard following > current else { break }
      current = following
    }
    return dates
  }

  private static func thinned(_ dates: [Date], to maxCount: Int) -> [Date] {
    guard dates.count > maxCount else { return dates }
    let step = (dates.count + maxCount - 1) / maxCount
    return dates.enumerated().filter { (dates.count - 1 - $0.offset) % step == 0 }.map(\.element)
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
