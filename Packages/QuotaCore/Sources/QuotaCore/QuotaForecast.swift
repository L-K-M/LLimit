import Foundation

/// Measured burn rate and projection from the same guarded source samples.
public struct PaceEstimate: Codable, Hashable, Sendable {
  public enum Trend: String, Codable, Hashable, Sendable {
    case steady, onTrack, runsOut
  }

  public let trend: Trend
  public let burnRatePerHour: Double
  public let exhaustionAt: Date?
  public let projectedPercentAtReset: Int
  public let summary: String
  public let validUntil: Date?

  public func isValid(at now: Date) -> Bool {
    guard let validUntil, now <= validUntil else { return false }
    return exhaustionAt.map { $0 > now } ?? true
  }

  public func displayText(at now: Date) -> String {
    let rate = "≈\(String(format: "%.1f", burnRatePerHour))%/h"
    guard trend == .runsOut, let exhaustionAt else { return "\(rate) · \(summary)" }
    return "\(rate) · runs out in ~\(formatShortDuration(seconds: max(0, Int(exhaustionAt.timeIntervalSince(now)))))"
  }
}

public struct QuotaDepletionWarning: Hashable, Sendable {
  public let accountID: String
  public let metricID: String
  public let metricLabel: String
  public let depletionAt: Date
  public let resetAt: Date

  public func timing(at now: Date) -> String {
    "out in ~\(Self.approximateDuration(depletionAt.timeIntervalSince(now))), "
      + "resets in \(Self.approximateDuration(resetAt.timeIntervalSince(now)))"
  }

  private static func approximateDuration(_ interval: TimeInterval) -> String {
    let minutes = max(1, Int((max(0, interval) / 60).rounded()))
    let days = minutes / 1_440
    let hours = (minutes % 1_440) / 60
    let remainingMinutes = minutes % 60
    if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
    if hours > 0 { return remainingMinutes > 0 ? "\(hours)h \(remainingMinutes)m" : "\(hours)h" }
    return "\(remainingMinutes)m"
  }
}

/// One engine for chart warnings, dropdown ETA and snapshot/CLI pace fields.
public enum QuotaForecast {
  public struct SeriesKey: Hashable, Sendable {
    public let accountID: String
    public let metricID: String
    public init(accountID: String, metricID: String) {
      self.accountID = accountID
      self.metricID = metricID
    }
  }

  private struct MeasurementKey: Hashable {
    let provider: QuotaProvider
    let series: SeriesKey
  }

  private struct Sample {
    let date: Date
    let remaining: Double
    let resetAt: Date?
    let kind: QuotaWindowKind
    let duration: TimeInterval?
  }

  static let resetJumpThreshold: Double = 4
  private static let freshnessIntervals: Double = 2
  private static let minimumRefreshInterval = TimeInterval(AppSettings.refreshIntervalRange.lowerBound * 60)
  private static let minimumSampleCount = 4
  private static let minimumObservedSpan: TimeInterval = 3_600
  private static let minimumWindowFraction = 0.1
  private static let lowRemainingPercent: Double = 25
  private static let recentPaceSpan: TimeInterval = 2 * 3_600
  private static let resetTolerance: TimeInterval = 5 * 60
  private static let secondsPerHour: TimeInterval = 3_600

  public static func isFresh(_ usage: ProviderUsage, now: Date, refreshInterval: TimeInterval) -> Bool {
    let age = now.timeIntervalSince(usage.fetchedAt)
    return age >= 0 && age <= freshnessIntervals * cadence(refreshInterval)
  }

  private static func cadence(_ interval: TimeInterval) -> TimeInterval {
    interval.isFinite ? max(interval, minimumRefreshInterval) : minimumRefreshInterval
  }

  public static func measurements(
    history: [QuotaSnapshot], latest: QuotaSnapshot?, accounts: [ProviderAccount]? = nil,
    now: Date, refreshInterval: TimeInterval
  ) -> [SeriesKey: PaceEstimate] {
    guard let latest else { return [:] }
    let current = accounts.map { latest.reconciled(with: $0) } ?? latest
    let observations = QuotaObservations.extract(from: history + [current], accounts: accounts,
      window: Date.distantPast...now)
    var grouped: [MeasurementKey: [Sample]] = [:]
    for usage in observations {
      for metric in usage.metrics where !metric.isUnlimited {
        guard let remaining = metric.remainingPercent, (0...100).contains(remaining) else { continue }
        let key = MeasurementKey(provider: usage.provider,
          series: SeriesKey(accountID: usage.accountID, metricID: metric.trendSeriesID))
        grouped[key, default: []].append(Sample(date: usage.fetchedAt, remaining: Double(remaining),
          resetAt: metric.resetAt, kind: QuotaWindowKind.classify(metricID: metric.id, label: metric.label),
          duration: QuotaPace.windowSeconds(for: metric, provider: usage.provider)))
      }
    }

    var results: [SeriesKey: PaceEstimate] = [:]
    for usage in current.providers {
      guard !current.failures.contains(where: { $0.accountID == usage.accountID && $0.provider == usage.provider }),
            isFresh(usage, now: now, refreshInterval: refreshInterval) else { continue }
      for metric in usage.metrics {
        guard !metric.isUnlimited, let remaining = metric.remainingPercent, (0...100).contains(remaining),
              let resetAt = metric.resetAt, resetAt > now,
              let duration = QuotaPace.windowSeconds(for: metric, provider: usage.provider),
              QuotaPace(metric: metric, provider: usage.provider, fetchedAt: usage.fetchedAt, now: now) != nil else { continue }
        let key = SeriesKey(accountID: usage.accountID, metricID: metric.trendSeriesID)
        let start = resetAt.addingTimeInterval(-duration)
        let raw = grouped[MeasurementKey(provider: usage.provider, series: key)] ?? []
        let window = currentWindow(raw.filter { $0.date >= start && $0.date <= usage.fetchedAt },
          maximumGap: freshnessIntervals * cadence(refreshInterval))
        guard let last = window.last, last.date == usage.fetchedAt,
              last.kind == QuotaWindowKind.classify(metricID: metric.id, label: metric.label),
              let estimate = measure(window, duration: duration, resetAt: resetAt,
                now: now, refreshInterval: cadence(refreshInterval),
                validUntil: min(resetAt, usage.fetchedAt.addingTimeInterval(freshnessIntervals * cadence(refreshInterval)))) else { continue }
        results[key] = estimate
      }
    }
    return results
  }

  public static func depletionWarnings(
    for keys: [SeriesKey], history: [QuotaSnapshot], latest: QuotaSnapshot?,
    accounts: [ProviderAccount]? = nil, now: Date, refreshInterval: TimeInterval
  ) -> [QuotaDepletionWarning] {
    guard let latest else { return [] }
    let current = accounts.map { latest.reconciled(with: $0) } ?? latest
    let estimates = measurements(history: history, latest: current, accounts: accounts,
      now: now, refreshInterval: refreshInterval)
    return Set(keys).compactMap { key -> QuotaDepletionWarning? in
      guard let estimate = estimates[key], estimate.trend == .runsOut,
            let depletionAt = estimate.exhaustionAt,
            let metric = current.providers.first(where: { $0.accountID == key.accountID })?.metrics.first(where: { $0.trendSeriesID == key.metricID }),
            let resetAt = metric.resetAt else { return nil }
      return QuotaDepletionWarning(accountID: key.accountID, metricID: key.metricID,
        metricLabel: metric.label, depletionAt: depletionAt, resetAt: resetAt)
    }.sorted {
      ($0.depletionAt, $0.accountID, $0.metricID) < ($1.depletionAt, $1.accountID, $1.metricID)
    }
  }

  private static func currentWindow(_ samples: [Sample], maximumGap: TimeInterval) -> [Sample] {
    var window: [Sample] = []
    for sample in samples {
      if let previous = window.last {
        let ended = previous.resetAt.map { $0 <= sample.date } ?? false
        let changedReset = previous.resetAt.flatMap { before in sample.resetAt.map { abs(before.timeIntervalSince($0)) > resetTolerance } } ?? false
        let stamped = previous.resetAt != nil && sample.resetAt != nil
        let refill = !stamped && sample.remaining > previous.remaining + resetJumpThreshold
        let gap = sample.date.timeIntervalSince(previous.date) > maximumGap
        let changedDuration = previous.duration.flatMap { before in sample.duration.map { before != $0 } } ?? false
        if ended || changedReset || refill || gap || changedDuration || sample.kind != previous.kind { window.removeAll() }
      }
      window.append(sample)
    }
    return window
  }

  private static func measure(
    _ window: [Sample], duration: TimeInterval, resetAt: Date, now: Date,
    refreshInterval: TimeInterval, validUntil: Date
  ) -> PaceEstimate? {
    guard window.count >= minimumSampleCount, let first = window.first, let last = window.last else { return nil }
    let span = last.date.timeIntervalSince(first.date)
    guard span >= max(minimumObservedSpan, minimumWindowFraction * duration) else { return nil }

    let averageRate = max(0, (first.remaining - last.remaining) / span)
    var rate = averageRate
    // A brief burst only changes the warning once little quota remains.
    if last.remaining <= lowRemainingPercent {
      let recentSpan = max(recentPaceSpan, Double(minimumSampleCount - 1) * refreshInterval)
      if let index = window.lastIndex(where: { $0.date <= last.date.addingTimeInterval(-recentSpan) }),
         window.count - index >= minimumSampleCount {
        let anchor = window[index]
        rate = max(rate, (anchor.remaining - last.remaining) / last.date.timeIntervalSince(anchor.date))
      }
    }

    let projected = clampPercent(Int((last.remaining - rate * resetAt.timeIntervalSince(last.date)).rounded()))
    guard rate > 0 else {
      return PaceEstimate(trend: .steady, burnRatePerHour: 0, exhaustionAt: nil,
        projectedPercentAtReset: Int(last.remaining), summary: "holding steady", validUntil: validUntil)
    }
    let depletion = last.date.addingTimeInterval(last.remaining / rate)
    guard depletion > now else { return nil }
    if depletion < resetAt {
      let seconds = Int(depletion.timeIntervalSince(now))
      return PaceEstimate(trend: .runsOut, burnRatePerHour: rate * secondsPerHour, exhaustionAt: depletion,
        projectedPercentAtReset: projected, summary: "runs out in ~\(formatShortDuration(seconds: seconds))", validUntil: validUntil)
    }
    return PaceEstimate(trend: .onTrack, burnRatePerHour: rate * secondsPerHour, exhaustionAt: nil,
      projectedPercentAtReset: projected, summary: "≈\(projected)% at reset", validUntil: validUntil)
  }
}

public extension QuotaSnapshot {
  func applyingPaceEstimates(
    from history: [QuotaSnapshot], accounts: [ProviderAccount]? = nil,
    now: Date = Date(), refreshInterval: TimeInterval = TimeInterval(AppSettings.refreshIntervalRange.lowerBound * 60)
  ) -> QuotaSnapshot {
    let estimates = QuotaForecast.measurements(history: history, latest: self, accounts: accounts,
      now: now, refreshInterval: refreshInterval)
    var copy = self
    for usageIndex in copy.providers.indices {
      for metricIndex in copy.providers[usageIndex].metrics.indices {
        let metric = copy.providers[usageIndex].metrics[metricIndex]
        let key = QuotaForecast.SeriesKey(accountID: copy.providers[usageIndex].accountID, metricID: metric.trendSeriesID)
        // Failed, stale or retired measurements must clear a carried estimate.
        copy.providers[usageIndex].metrics[metricIndex].paceEstimate = estimates[key]
      }
    }
    return copy
  }
}
