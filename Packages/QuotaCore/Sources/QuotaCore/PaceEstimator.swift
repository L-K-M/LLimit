import Foundation

/// Burn-rate projection for a single metric, derived from recorded history.
/// Providers report only remaining quota and a reset date — never a rate — so
/// pace is estimated from the metric's own samples inside the current window.
public struct PaceEstimate: Codable, Hashable, Sendable {
  public enum Trend: String, Codable, Hashable, Sendable {
    /// Not measurably draining.
    case steady
    /// Draining, but projected to reach the reset with quota left.
    case onTrack
    /// Projected to hit 0% before the reset.
    case runsOut
  }

  public let trend: Trend
  /// Percentage points consumed per hour (> 0 while draining).
  public let burnRatePerHour: Double
  /// When the metric reaches 0% at the current pace (only when `.runsOut`).
  public let exhaustionAt: Date?
  /// Projected % still remaining at `resetAt`.
  public let projectedPercentAtReset: Int
  /// Display-ready one-liner computed at estimate time, e.g.
  /// "runs out in ~1h20m" or "≈24% at reset". Snapshots persist it alongside
  /// `resetIn`, which is likewise a stored display string.
  public let summary: String

  static func make(
    trend: Trend, burnRatePerHour: Double, exhaustionAt: Date?,
    projectedPercentAtReset: Int, now: Date
  ) -> PaceEstimate {
    let summary: String
    switch trend {
    case .steady:
      summary = "holding steady"
    case .runsOut:
      if let exhaustionAt {
        let seconds = max(0, Int(exhaustionAt.timeIntervalSince(now)))
        summary = seconds < 60
          ? "running out now"
          : "runs out in ~\(formatShortDuration(seconds: seconds))"
      } else {
        summary = "running out"
      }
    case .onTrack:
      summary = "≈\(projectedPercentAtReset)% at reset"
    }
    return PaceEstimate(
      trend: trend, burnRatePerHour: burnRatePerHour,
      exhaustionAt: exhaustionAt, projectedPercentAtReset: projectedPercentAtReset,
      summary: summary
    )
  }
}

public enum PaceEstimator {
  /// Estimate pace from `(date, percent)` samples inside the current window.
  /// Window boundaries are detected as upward jumps (a reset restores
  /// percent), so history overlapping the previous window is safe. Returns nil
  /// with fewer than two usable samples or a span under 15 minutes.
  public static func estimate(
    points: [(date: Date, percent: Double)],
    now: Date,
    resetAt: Date,
    maxLookback: TimeInterval
  ) -> PaceEstimate? {
    let cutoff = now - maxLookback
    let samples = points
      .filter { $0.date >= cutoff && $0.date <= now }
      .sorted { $0.date < $1.date }
    guard samples.count >= 2 else { return nil }

    // Keep only samples since the last reset: remainingPercent is
    // monotonically non-increasing inside a window, so a >4pt rise marks a
    // boundary.
    var windowStart = 0
    for i in 1..<samples.count where samples[i].percent - samples[i - 1].percent > 4 {
      windowStart = i
    }
    let window = Array(samples[windowStart...])
    guard window.count >= 2,
          let first = window.first, let last = window.last else { return nil }

    let spanHours = last.date.timeIntervalSince(first.date) / 3_600
    guard spanHours >= 0.25 else { return nil }

    let rate = (first.percent - last.percent) / spanHours
    let hoursToReset = resetAt.timeIntervalSince(now) / 3_600
    guard hoursToReset > 0 else { return nil }

    let projected = min(100, max(0, Int((last.percent - rate * hoursToReset).rounded())))

    if rate <= 0.05 {
      return PaceEstimate.make(
        trend: .steady, burnRatePerHour: max(0, rate),
        exhaustionAt: nil, projectedPercentAtReset: projected, now: now
      )
    }

    let exhaustionAt = now.addingTimeInterval(last.percent / rate * 3_600)
    if exhaustionAt < resetAt {
      return PaceEstimate.make(
        trend: .runsOut, burnRatePerHour: rate,
        exhaustionAt: exhaustionAt, projectedPercentAtReset: projected, now: now
      )
    }
    return PaceEstimate.make(
      trend: .onTrack, burnRatePerHour: rate,
      exhaustionAt: nil, projectedPercentAtReset: projected, now: now
    )
  }

  /// Generous lookback caps per window kind — long enough to cover one full
  /// window plus clock skew; boundary detection trims any overshoot.
  static func maxLookback(for kind: QuotaWindowKind) -> TimeInterval? {
    switch kind {
    case .session: return 8 * 3_600
    case .daily: return 30 * 3_600
    case .weekly: return 9 * 86_400
    case .monthly: return 34 * 86_400
    case .other: return nil
    }
  }
}

public extension QuotaSnapshot {
  /// Returns a copy with `paceEstimate` filled in on metrics that have enough
  /// recorded history in their current window to project. Metrics without a
  /// remaining percentage, a future reset, or a classifiable window are left
  /// untouched.
  func applyingPaceEstimates(from history: [QuotaSnapshot], now: Date = Date()) -> QuotaSnapshot {
    var copy = self
    for usageIndex in copy.providers.indices {
      for metricIndex in copy.providers[usageIndex].metrics.indices {
        let metric = copy.providers[usageIndex].metrics[metricIndex]
        guard let remaining = metric.remainingPercent,
              let resetAt = metric.resetAt, resetAt > now,
              let lookback = PaceEstimator.maxLookback(
                for: QuotaWindowKind.classify(metricID: metric.id, label: metric.label)
              ) else { continue }

        let accountID = copy.providers[usageIndex].accountID
        var points: [(date: Date, percent: Double)] = history.compactMap { past in
          guard let usage = past.providers.first(where: { $0.accountID == accountID }),
                let sample = usage.metrics.first(where: { $0.id == metric.id }),
                let percent = sample.remainingPercent else { return nil }
          return (past.generatedAt, Double(percent))
        }
        points.append((now, Double(remaining)))

        if let estimate = PaceEstimator.estimate(
          points: points, now: now, resetAt: resetAt, maxLookback: lookback
        ) {
          copy.providers[usageIndex].metrics[metricIndex].paceEstimate = estimate
        }
      }
    }
    return copy
  }
}
