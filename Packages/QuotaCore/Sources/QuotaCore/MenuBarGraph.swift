import Foundation

/// Rules behind the macOS menu-bar status item, kept free of AppKit so Linux
/// tests cover them; the app only draws. There is one bar per enabled account
/// in Settings order, with the usage projected exactly as
/// `orderedUsageForAccounts` does, plus a bar for an enabled account whose
/// refresh failed before any usage arrived. Height carries the level, and the
/// bar's style says whether that level is live, stale or carried past a
/// failure, so trouble shows without opening the dropdown.
public enum MenuBarGraph {
  /// Whether a bar's level reflects the latest refresh.
  public enum Freshness: Equatable, Sendable {
    case current
    /// No current failure, but the usage is older than the stale interval or
    /// one of its percentage windows has reset since the fetch, so the level is
    /// outdated.
    case stale
    /// The latest refresh failed. Any level is carried from an earlier success.
    case failing(QuotaErrorKind)

    public var isFailing: Bool {
      if case .failing = self { return true }
      return false
    }
  }

  /// What a bar's height can say about its account.
  public enum Level: Equatable, Sendable {
    /// The most constrained bounded window, clamped to 0...100.
    case remaining(percent: Int, isEstimated: Bool)
    /// Every reported limit is unlimited.
    case unlimited
    /// Usage without a percentage, such as a credit balance with no total.
    case amountOnly
    /// No usage yet: the account has only a failure.
    case unavailable
  }

  public struct Bar: Equatable, Sendable {
    public let accountID: String
    public let title: String
    public let level: Level
    public let freshness: Freshness
    /// The projected usage behind the level. Its metrics select the bar's
    /// identity color; nil when the account has only a failure.
    public let usage: ProviderUsage?
  }

  private static let staleRefreshIntervals = 2
  private static let minimumStaleInterval: TimeInterval = 3_600
  private static let secondsPerMinute = 60

  /// Usage older than two refresh intervals reads as stale, and never sooner
  /// than an hour, so one slow or skipped poll does not flag a healthy account.
  /// This matches the provider tile's local rule.
  public static func staleInterval(refreshIntervalMinutes: Int) -> TimeInterval {
    let range = AppSettings.refreshIntervalRange
    let minutes = min(max(refreshIntervalMinutes, range.lowerBound), range.upperBound)
    let interval = TimeInterval(minutes * secondsPerMinute * staleRefreshIntervals)
    return max(minimumStaleInterval, interval)
  }

  public static func bars(
    snapshot: QuotaSnapshot?,
    accounts: [ProviderAccount],
    now: Date,
    staleAfter: TimeInterval
  ) -> [Bar] {
    guard let snapshot else { return [] }

    let usageByAccountID = Dictionary(
      orderedUsageForAccounts(snapshot.providers, accounts: accounts).map { ($0.accountID, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let failuresByID = Dictionary(grouping: snapshot.failures, by: \.accountID)
    let accountsByProvider = Dictionary(grouping: accounts, by: \.provider)

    return accounts.filter(\.isEnabled).compactMap { account in
      let usage = usageByAccountID[account.id]
      // Same legacy rule as the usage projection: a provider-keyed failure
      // belongs to an account only when that provider has exactly one account.
      let exactFailure = failuresByID[account.id]?.first { $0.provider == account.provider }
      let legacyFailure = accountsByProvider[account.provider]?.count == 1
        ? failuresByID[account.provider.rawValue]?.first { $0.provider == account.provider }
        : nil
      let failure = exactFailure ?? legacyFailure

      // An account that has neither reported nor failed yet has nothing to show.
      guard usage != nil || failure != nil else { return nil }

      let freshness: Freshness
      if let failure {
        freshness = .failing(failure.kind)
      } else if let usage, isStale(usage, now: now, staleAfter: staleAfter) {
        freshness = .stale
      } else {
        freshness = .current
      }

      return Bar(
        accountID: account.id,
        title: account.resolvedDisplayName,
        level: usage.map(level(for:)) ?? .unavailable,
        freshness: freshness,
        usage: usage
      )
    }
  }

  /// Bar height for a level, or nil when the level has no height (an amount
  /// without a total, or no usage). Zero stays empty so an exhausted account
  /// reads as a bare track. Any remainder starts at `minimumVisibleHeight` and
  /// scales the rest linearly, so each percentage gets its own height: 1% and
  /// 12% no longer share one floor, and 100% fills the track.
  public static func barHeight(
    for level: Level,
    fullHeight: Double,
    minimumVisibleHeight: Double = 1
  ) -> Double? {
    let percent: Int
    switch level {
    case .remaining(let remaining, _):
      percent = clampPercent(remaining)
    case .unlimited:
      percent = 100
    case .amountOnly, .unavailable:
      return nil
    }

    guard percent > 0, fullHeight > 0 else { return 0 }
    let floor = min(max(minimumVisibleHeight, 0), fullHeight)
    return floor + (fullHeight - floor) * Double(percent) / 100
  }

  /// Status-item tooltip: a headline with counts, then one line per bar.
  public static func tooltip(for bars: [Bar]) -> String {
    summaryLines(for: bars).joined(separator: "\n")
  }

  /// VoiceOver label carrying the tooltip's content as sentences.
  public static func accessibilityLabel(for bars: [Bar]) -> String {
    summaryLines(for: bars).joined(separator: ". ") + "."
  }

  // MARK: - Private

  /// Mirrors the dashboard's headline rule: the most constrained bounded
  /// window, then unlimited, then the provider's own used percentage.
  private static func level(for usage: ProviderUsage) -> Level {
    let bounded = usage.metrics.filter { !$0.isUnlimited && $0.remainingPercent != nil }
    if let minimum = bounded.compactMap(\.remainingPercent).min() {
      let isEstimated = bounded.contains { $0.remainingPercent == minimum && $0.isPercentageEstimated }
      return .remaining(percent: clampPercent(minimum), isEstimated: isEstimated)
    }

    if usage.metrics.contains(where: \.isUnlimited) {
      return .unlimited
    }

    if let maxUsagePercent = usage.maxUsagePercent {
      return .remaining(percent: clampPercent(100 - maxUsagePercent), isEstimated: false)
    }

    return .amountOnly
  }

  private static func isStale(_ usage: ProviderUsage, now: Date, staleAfter: TimeInterval) -> Bool {
    if now.timeIntervalSince(usage.fetchedAt) > staleAfter {
      return true
    }

    // A percentage window that reset after the fetch makes the drawn level
    // known-wrong. A reset at or before the fetch is already in the value, and
    // amounts without a percentage never set the level.
    return usage.metrics.contains { metric in
      guard !metric.isUnlimited, metric.remainingPercent != nil, let resetAt = metric.resetAt else {
        return false
      }
      return resetAt > usage.fetchedAt && resetAt <= now
    }
  }

  private static func clampPercent(_ value: Int) -> Int {
    max(0, min(100, value))
  }

  private static func summaryLines(for bars: [Bar]) -> [String] {
    [headline(for: bars)] + bars.map(line(for:))
  }

  private static func headline(for bars: [Bar]) -> String {
    guard !bars.isEmpty else { return "LLimit: no quota data" }

    var parts = [bars.count == 1 ? "1 account" : "\(bars.count) accounts"]
    let failingCount = bars.filter(\.freshness.isFailing).count
    let staleCount = bars.filter { $0.freshness == .stale }.count
    if failingCount > 0 {
      parts.append("\(failingCount) failing")
    }
    if staleCount > 0 {
      parts.append("\(staleCount) stale")
    }
    return "LLimit: " + parts.joined(separator: ", ")
  }

  private static func line(for bar: Bar) -> String {
    let level = levelDescription(for: bar)
    switch bar.freshness {
    case .current:
      return "\(bar.title): \(level)"
    case .stale:
      return "\(bar.title): \(level), data is stale"
    case .failing(let kind):
      let reason = failureDescription(for: kind)
      guard bar.level != .unavailable else {
        return "\(bar.title): \(reason), no quota data"
      }
      return "\(bar.title): \(reason), last known \(level)"
    }
  }

  private static func levelDescription(for bar: Bar) -> String {
    switch bar.level {
    case .remaining(let percent, let isEstimated):
      return "\(isEstimated ? "estimated " : "")\(percent)% remaining"
    case .unlimited:
      return "unlimited"
    case .amountOnly:
      let amounts = (bar.usage?.metrics ?? []).compactMap { metric -> String? in
        guard !metric.isUnlimited, let amount = metric.usageLine else { return nil }
        return "\(metric.label) \(amount)"
      }
      return amounts.isEmpty ? "no percentage reported" : amounts.joined(separator: ", ")
    case .unavailable:
      return "no quota data"
    }
  }

  private static func failureDescription(for kind: QuotaErrorKind) -> String {
    switch kind {
    case .notConfigured:
      return "not configured"
    case .auth:
      return "authentication failed"
    case .network:
      return "network error"
    case .rateLimit:
      return "rate limited"
    case .decoding:
      return "unreadable response"
    case .api:
      return "provider error"
    case .unknown:
      return "refresh failed"
    }
  }
}
