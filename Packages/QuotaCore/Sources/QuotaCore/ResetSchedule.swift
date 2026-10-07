import Foundation

/// One chronological reset, with enough context for amount-only and unlimited limits.
public struct UpcomingReset: Hashable, Sendable {
  public let accountID: String
  public let accountName: String
  public let provider: QuotaProvider
  public let metricID: String
  public let metricLabel: String
  public let windowKind: QuotaWindowKind
  public let resetAt: Date
  public let remainingPercent: Int?
  public let remainingAmount: Double?
  public let usageLine: String?
  public let isEstimated: Bool
  public let isUnlimited: Bool

  public func countdown(at now: Date) -> String { formatResetCountdown(to: resetAt, now: now) }
}

public extension QuotaSnapshot {
  /// Only future absolute dates inside a finite horizon are scheduled. Failed
  /// accounts are omitted: carried reset dates do not establish current quota.
  func upcomingResets(now: Date = Date(), within window: TimeInterval) -> [UpcomingReset] {
    guard window > 0, window.isFinite else { return [] }
    let horizon = now.addingTimeInterval(window)
    guard horizon.timeIntervalSince1970.isFinite else { return [] }
    let failures = preferredFailures
    var entries: [UpcomingReset] = []
    for usage in providers where failures[usage.accountKey] == nil {
      for metric in usage.metrics {
        guard let resetAt = metric.resetAt, resetAt > now, resetAt <= horizon else { continue }
        entries.append(UpcomingReset(
          accountID: usage.accountID, accountName: usage.title, provider: usage.provider,
          metricID: metric.id, metricLabel: metric.label,
          windowKind: QuotaWindowKind.classify(metricID: metric.id, label: metric.label),
          resetAt: resetAt, remainingPercent: metric.remainingPercent, remainingAmount: metric.remainingAmount,
          usageLine: metric.usageLine, isEstimated: metric.isPercentageEstimated, isUnlimited: metric.isUnlimited
        ))
      }
    }
    return entries.sorted {
      if $0.resetAt != $1.resetAt { return $0.resetAt < $1.resetAt }
      if $0.accountName != $1.accountName { return $0.accountName < $1.accountName }
      if $0.metricLabel != $1.metricLabel { return $0.metricLabel < $1.metricLabel }
      if $0.provider != $1.provider { return $0.provider.rawValue < $1.provider.rawValue }
      if $0.accountID != $1.accountID { return $0.accountID < $1.accountID }
      return $0.metricID < $1.metricID
    }
  }
}
