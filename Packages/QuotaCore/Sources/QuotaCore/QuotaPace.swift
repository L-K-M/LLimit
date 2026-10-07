import Foundation

/// How a window's consumption compares with spending it evenly until its own
/// reset. "40% left" means something different on day 2 and on day 6 of a
/// weekly window; pace says whether the quota is on track to last.
///
/// Pace needs the window's length. It comes from `UsageMetric.windowSeconds`
/// when the provider reports it as data, or from a metric id whose documented
/// API key fixes it (Anthropic `five_hour`, Cline `weekly`). It is never
/// inferred from label text. Monthly and rolling windows have no pace: a month
/// has no fixed length, and a rolling window has no single reset to pace to.
public struct QuotaPace: Equatable, Sendable {
  /// Share of the window that had elapsed when the metric was read, in 0..<1.
  public let elapsedFraction: Double

  /// Used percent minus elapsed percent, in percentage points. Positive means
  /// the window is being spent faster than evenly, so it would run out before
  /// its reset at that rate.
  public let delta: Double

  /// Readings within this many points of even pace read as "on pace", so
  /// rounding and the minutes between refreshes do not flip the phrase.
  static let onPacePoints = 3

  /// Server rounding and clock skew can put a fresh window's reset slightly
  /// more than one window away. A reset further out than this share of the
  /// window contradicts the reported length, so it has no pace.
  static let resetOvershootTolerance = 0.05

  private static let fiveHours: TimeInterval = 5 * 3_600
  private static let sevenDays: TimeInterval = 7 * 86_400

  /// - Parameters:
  ///   - fetchedAt: when `metric` was read. Elapsed time is measured at this
  ///     instant so used and elapsed describe the same moment; measuring at
  ///     display time would drift a stale reading toward "under pace".
  ///   - now: the display time. A window that has reset since the reading has
  ///     no pace, because its used share belongs to the window that ended.
  public init?(metric: UsageMetric, provider: QuotaProvider, fetchedAt: Date, now: Date) {
    guard
      !metric.isUnlimited,
      let remainingPercent = metric.remainingPercent,
      let resetAt = metric.resetAt,
      resetAt > now,
      let windowSeconds = Self.windowSeconds(for: metric, provider: provider),
      let elapsedFraction = Self.elapsedFraction(resetAt: resetAt, windowSeconds: windowSeconds, at: fetchedAt)
    else { return nil }

    let usedPercent = Double(100 - clampPercent(remainingPercent))
    self.elapsedFraction = elapsedFraction
    delta = usedPercent - elapsedFraction * 100
  }

  /// Where an even-pace tick sits on a remaining-quota bar or ring, in 0...1.
  public var evenPaceRemainingFraction: Double {
    1 - elapsedFraction
  }

  /// "12% over pace", "on pace" or "8% under pace". "Over" means more of the
  /// window is used than has elapsed, so it would run out before its reset;
  /// "ahead of pace" would read as good news for the same reading.
  public var phrase: String {
    let points = Int(abs(delta).rounded())
    guard points >= Self.onPacePoints else { return "on pace" }
    return delta > 0 ? "\(points)% over pace" : "\(points)% under pace"
  }

  /// The window's length: the provider's reported length, else the length a
  /// documented metric id fixes. Nil when neither states one.
  public static func windowSeconds(for metric: UsageMetric, provider: QuotaProvider) -> TimeInterval? {
    if let reported = metric.windowSeconds {
      return reported > 0 ? TimeInterval(reported) : nil
    }
    return documentedWindowSeconds(metricID: metric.id, provider: provider)
  }

  private static func documentedWindowSeconds(metricID: String, provider: QuotaProvider) -> TimeInterval? {
    switch provider {
    case .anthropic:
      // The OAuth usage keys name their window, including model-specific
      // variants such as `seven_day_opus`.
      if metricID == "five_hour" || metricID.hasPrefix("five_hour_") { return fiveHours }
      if metricID == "seven_day" || metricID.hasPrefix("seven_day_") { return sevenDays }
      return nil
    case .cline:
      // ClinePass window types. A month has no fixed length, so `monthly`
      // has no pace.
      switch metricID {
      case "five_hour": return fiveHours
      case "weekly": return sevenDays
      default: return nil
      }
    default:
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

/// A reported window length in seconds, or nil unless `count` is a positive
/// length that fits an `Int`. Counts come from untrusted payloads, so the
/// conversion must never trap.
func reportedWindowSeconds(count: Int, unitSeconds: Int) -> Int? {
  guard count > 0 else { return nil }

  let (seconds, overflow) = count.multipliedReportingOverflow(by: unitSeconds)
  return overflow ? nil : seconds
}
