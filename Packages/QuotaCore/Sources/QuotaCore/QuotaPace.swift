import Foundation

/// Consumption relative to even spending through a window's reset.
/// Duration comes from reported data or stable API ids, never label text.
public struct QuotaPace: Equatable, Sendable {
  public let elapsedFraction: Double
  /// Used minus elapsed, in percentage points. Positive means faster spending.
  public let delta: Double

  private static let onPacePoints = 3
  private static let resetOvershootTolerance = 0.05
  private static let fiveHours: TimeInterval = 5 * 3_600
  private static let sevenDays: TimeInterval = 7 * 86_400

  public init?(metric: UsageMetric, provider: QuotaProvider, fetchedAt: Date, now: Date) {
    guard
      !metric.isUnlimited,
      let remainingPercent = metric.remainingPercent,
      let resetAt = metric.resetAt,
      resetAt > now,
      let windowSeconds = Self.windowSeconds(for: metric, provider: provider),
      let elapsedFraction = Self.elapsedFraction(resetAt: resetAt, windowSeconds: windowSeconds, at: fetchedAt)
    else { return nil }

    // Compare consumption and elapsed time at the same reading. Display time
    // only invalidates readings whose window has since reset.
    self.elapsedFraction = elapsedFraction
    delta = Double(100 - clampPercent(remainingPercent)) - elapsedFraction * 100
  }

  public var evenPaceRemainingFraction: Double { 1 - elapsedFraction }

  public var phrase: String {
    let points = Int(abs(delta).rounded())
    guard points >= Self.onPacePoints else { return "on pace" }
    return delta > 0 ? "\(points)% over pace" : "\(points)% under pace"
  }

  public static func windowSeconds(for metric: UsageMetric, provider: QuotaProvider) -> TimeInterval? {
    if let reported = metric.windowSeconds {
      return reported > 0 ? TimeInterval(reported) : nil
    }
    return documentedWindowSeconds(metricID: metric.id, provider: provider)
  }

  private static func documentedWindowSeconds(metricID: String, provider: QuotaProvider) -> TimeInterval? {
    switch provider {
    case .anthropic:
      if metricID == "five_hour" || metricID.hasPrefix("five_hour_") { return fiveHours }
      if metricID == "seven_day" || metricID.hasPrefix("seven_day_") { return sevenDays }
      return nil
    case .cline:
      switch metricID {
      case "five_hour": return fiveHours
      case "weekly": return sevenDays
      default: return nil
      }
    default:
      // Monthly, rolling, and undocumented ids have no inferred duration.
      return nil
    }
  }

  private static func elapsedFraction(resetAt: Date, windowSeconds: TimeInterval, at date: Date) -> Double? {
    let remaining = resetAt.timeIntervalSince(date)
    guard remaining.isFinite, remaining > 0, windowSeconds.isFinite, windowSeconds > 0 else { return nil }

    let elapsed = 1 - remaining / windowSeconds
    guard elapsed >= -resetOvershootTolerance else { return nil }
    return max(0, elapsed)
  }
}

/// Reject nonpositive and overflowing durations from untrusted payloads.
func reportedWindowSeconds(count: Int, unitSeconds: Int) -> Int? {
  guard count > 0, unitSeconds > 0 else { return nil }
  let (seconds, overflow) = count.multipliedReportingOverflow(by: unitSeconds)
  return overflow ? nil : seconds
}
