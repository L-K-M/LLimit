import Foundation

/// One limit's next reset, flattened out of its account so a consumer can list
/// every reset across providers in one chronological view (the "reset radar").
///
/// Only limits that carry an absolute `resetAt` can be scheduled. A rolling
/// balance or a window the provider does not date has no entry.
public struct UpcomingReset: Hashable, Sendable {
  public let accountID: String
  public let accountName: String
  public let provider: QuotaProvider
  public let metricID: String
  public let metricLabel: String
  public let resetAt: Date
  public let remainingPercent: Int?
  public let isUnlimited: Bool

  public init(
    accountID: String,
    accountName: String,
    provider: QuotaProvider,
    metricID: String,
    metricLabel: String,
    resetAt: Date,
    remainingPercent: Int?,
    isUnlimited: Bool
  ) {
    self.accountID = accountID
    self.accountName = accountName
    self.provider = provider
    self.metricID = metricID
    self.metricLabel = metricLabel
    self.resetAt = resetAt
    self.remainingPercent = remainingPercent
    self.isUnlimited = isUnlimited
  }

  /// Countdown to `resetAt` as of `now`, in the shared short form ("3h 12m").
  public func countdown(at now: Date) -> String {
    formatResetCountdown(to: resetAt, now: now)
  }
}

public extension QuotaSnapshot {
  /// Every limit that resets after `now` and no later than `window` from it,
  /// soonest first. Ties break by account then metric label so the order is
  /// stable between refreshes.
  func upcomingResets(now: Date = Date(), within window: TimeInterval) -> [UpcomingReset] {
    guard window > 0, window.isFinite else { return [] }
    let horizon = now.addingTimeInterval(window)

    var entries: [UpcomingReset] = []
    for usage in providers {
      for metric in usage.metrics {
        guard let resetAt = metric.resetAt, resetAt > now, resetAt <= horizon else { continue }
        entries.append(
          UpcomingReset(
            accountID: usage.accountID,
            accountName: usage.title,
            provider: usage.provider,
            metricID: metric.id,
            metricLabel: metric.label,
            resetAt: resetAt,
            remainingPercent: metric.remainingPercent,
            isUnlimited: metric.isUnlimited
          )
        )
      }
    }

    return entries.sorted { lhs, rhs in
      if lhs.resetAt != rhs.resetAt { return lhs.resetAt < rhs.resetAt }
      if lhs.accountName != rhs.accountName { return lhs.accountName < rhs.accountName }
      if lhs.metricLabel != rhs.metricLabel { return lhs.metricLabel < rhs.metricLabel }
      // Fully order equal keys: `sorted` is not stable, so identical triples
      // (two accounts sharing a title, or duplicate metric labels) would
      // otherwise flip between invocations.
      if lhs.accountID != rhs.accountID { return lhs.accountID < rhs.accountID }
      return lhs.metricID < rhs.metricID
    }
  }
}
