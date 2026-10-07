import Foundation

/// A bounded quota window that runs out before it resets at its current pace.
public struct QuotaDepletionWarning: Hashable, Sendable {
  public let accountID: String
  public let metricID: String
  public let metricLabel: String
  /// When the window reaches 0% at its pace since the last reset.
  public let depletionAt: Date
  /// The reset the latest snapshot reports for the window.
  public let resetAt: Date

  /// "out in ~1d 4h, resets in 3d 2h", measured from `now`.
  public func timing(at now: Date) -> String {
    "out in ~\(Self.approximateDuration(depletionAt.timeIntervalSince(now))), "
      + "resets in \(Self.approximateDuration(resetAt.timeIntervalSince(now)))"
  }

  /// The two most significant units: a forecast is not minute-accurate.
  private static func approximateDuration(_ interval: TimeInterval) -> String {
    let minutes = max(1, Int((max(0, interval) / 60).rounded()))
    let days = minutes / 1_440
    let hours = (minutes % 1_440) / 60
    let remainingMinutes = minutes % 60

    if days > 0 {
      return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
    }
    if hours > 0 {
      return remainingMinutes > 0 ? "\(hours)h \(remainingMinutes)m" : "\(hours)h"
    }
    return "\(remainingMinutes)m"
  }
}

/// Projects whether a quota window runs out before its reset.
///
/// Only live, fresh data may warn: the metric must be in the latest snapshot,
/// the account must not be failing, and its last fetch must be recent. The
/// pace is the window's average since its last reset, measured on raw
/// samples, so one burst inside a quiet week does not raise an alarm.
public enum QuotaForecast {
  public struct SeriesKey: Hashable, Sendable {
    public let accountID: String
    public let metricID: String

    public init(accountID: String, metricID: String) {
      self.accountID = accountID
      self.metricID = metricID
    }
  }

  struct Sample: Equatable {
    let date: Date
    let remainingPercent: Double
    let resetAt: Date?
  }

  /// A refill larger than this many percentage points is a reset; smaller
  /// rises are rounding jitter. Shared with the trend chart's reset risers.
  static let resetJumpThreshold: Double = 4
  /// Data older than this many refresh intervals is too stale to project.
  static let freshnessIntervals: Double = 2
  static let minimumSampleCount = 4
  static let minimumObservedSpan: TimeInterval = 3_600
  /// Share of the window that must be observed before its pace counts.
  static let minimumWindowFraction = 0.1

  /// Warnings for `keys`, earliest depletion first. `history` may include
  /// `latest`; `refreshInterval` is the app's refresh cadence in seconds.
  public static func depletionWarnings(
    for keys: [SeriesKey],
    history: [QuotaSnapshot],
    latest: QuotaSnapshot?,
    now: Date,
    refreshInterval: TimeInterval
  ) -> [QuotaDepletionWarning] {
    guard let latest else { return [] }

    let snapshots = (history + [latest]).sorted { $0.generatedAt < $1.generatedAt }
    let warnings = keys.compactMap { key in
      depletionWarning(for: key, snapshots: snapshots, latest: latest, now: now, refreshInterval: refreshInterval)
    }
    return warnings.sorted { lhs, rhs in
      if lhs.depletionAt != rhs.depletionAt {
        return lhs.depletionAt < rhs.depletionAt
      }
      if lhs.accountID != rhs.accountID {
        return lhs.accountID < rhs.accountID
      }
      return lhs.metricID < rhs.metricID
    }
  }

  private static func depletionWarning(
    for key: SeriesKey,
    snapshots: [QuotaSnapshot],
    latest: QuotaSnapshot,
    now: Date,
    refreshInterval: TimeInterval
  ) -> QuotaDepletionWarning? {
    guard
      !latest.failures.contains(where: { $0.accountID == key.accountID }),
      let usage = latest.providers.first(where: { $0.accountID == key.accountID }),
      now.timeIntervalSince(usage.fetchedAt) <= freshnessIntervals * refreshInterval,
      let metric = usage.metrics.first(where: { $0.trendSeriesID == key.metricID }),
      !metric.isUnlimited,
      metric.remainingPercent != nil,
      let resetAt = metric.resetAt,
      resetAt > now,
      let windowLength = nominalWindowLength(
        for: QuotaWindowKind.classify(metricID: metric.id, label: metric.label)
      )
    else {
      return nil
    }

    let window = currentWindow(of: samples(for: key, in: snapshots))
    guard
      window.count >= minimumSampleCount,
      let first = window.first,
      let last = window.last
    else {
      return nil
    }

    let span = last.date.timeIntervalSince(first.date)
    guard span >= max(minimumObservedSpan, minimumWindowFraction * windowLength) else {
      return nil
    }

    let consumed = first.remainingPercent - last.remainingPercent
    guard consumed > 0 else { return nil }

    let depletionAt = last.date.addingTimeInterval(last.remainingPercent / consumed * span)
    guard depletionAt > now, depletionAt < resetAt else { return nil }

    return QuotaDepletionWarning(
      accountID: key.accountID,
      metricID: key.metricID,
      metricLabel: metric.label,
      depletionAt: depletionAt,
      resetAt: resetAt
    )
  }

  /// One sample per provider fetch, dated by `fetchedAt`: snapshots that
  /// carried a failed account's last usage forward repeat an old reading.
  static func samples(for key: SeriesKey, in snapshots: [QuotaSnapshot]) -> [Sample] {
    var samples: [Sample] = []
    for snapshot in snapshots {
      guard
        let usage = snapshot.providers.first(where: { $0.accountID == key.accountID }),
        let metric = usage.metrics.first(where: { $0.trendSeriesID == key.metricID }),
        !metric.isUnlimited,
        let remaining = metric.remainingPercent
      else {
        continue
      }
      if let previous = samples.last, usage.fetchedAt <= previous.date {
        continue
      }
      samples.append(Sample(date: usage.fetchedAt, remainingPercent: Double(remaining), resetAt: metric.resetAt))
    }
    return samples
  }

  /// The samples since the last reset: after the last refill, and after the
  /// last moment an earlier sample said its window would reset.
  static func currentWindow(of samples: [Sample]) -> [Sample] {
    var window: [Sample] = []
    for sample in samples {
      if let previous = window.last {
        let refilled = sample.remainingPercent > previous.remainingPercent + resetJumpThreshold
        let previousWindowEnded = previous.resetAt.map { $0 <= sample.date } ?? false
        if refilled || previousWindowEnded {
          window.removeAll()
        }
      }
      window.append(sample)
    }
    return window
  }

  /// Providers report no window length, only wording. Session windows run a
  /// few hours, where the one-hour minimum span dominates anyway. Windows
  /// without a known cadence get no forecast.
  private static func nominalWindowLength(for kind: QuotaWindowKind) -> TimeInterval? {
    switch kind {
    case .session:
      return 5 * 3_600
    case .daily:
      return 86_400
    case .weekly:
      return 7 * 86_400
    case .monthly:
      return 30 * 86_400
    case .other:
      return nil
    }
  }
}

extension UsageMetric {
  /// The key a metric's trend line and forecast use: its id, or its label
  /// when a provider sends a blank id.
  var trendSeriesID: String {
    id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? label : id
  }
}
