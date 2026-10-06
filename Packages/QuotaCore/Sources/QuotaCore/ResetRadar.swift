import Foundation

/// A single upcoming quota reset event across configured accounts.
public struct ResetRadarItem: Hashable, Identifiable, Sendable {
  public var id: String { "\(accountID)\u{0}\(metricID)" }
  public let accountID: String
  public let accountName: String
  public let provider: QuotaProvider
  public let metricID: String
  public let metricLabel: String
  public let windowKind: QuotaWindowKind
  public let remainingPercent: Int?
  public let remainingAmount: Double?
  public let usedDisplay: String?
  public let resetAt: Date
  public let countdown: String
  public let secondsUntilReset: TimeInterval

  public init(
    accountID: String,
    accountName: String,
    provider: QuotaProvider,
    metricID: String,
    metricLabel: String,
    windowKind: QuotaWindowKind,
    remainingPercent: Int? = nil,
    remainingAmount: Double? = nil,
    usedDisplay: String? = nil,
    resetAt: Date,
    countdown: String,
    secondsUntilReset: TimeInterval
  ) {
    self.accountID = accountID
    self.accountName = accountName
    self.provider = provider
    self.metricID = metricID
    self.metricLabel = metricLabel
    self.windowKind = windowKind
    self.remainingPercent = remainingPercent
    self.remainingAmount = remainingAmount
    self.usedDisplay = usedDisplay
    self.resetAt = resetAt
    self.countdown = countdown
    self.secondsUntilReset = secondsUntilReset
  }
}

/// Aggregates and ranks upcoming quota resets chronologically across all providers.
public enum ResetRadar {
  public static func upcomingResets(
    from snapshot: QuotaSnapshot?,
    now: Date = Date(),
    maxCount: Int = 10
  ) -> [ResetRadarItem] {
    guard let snapshot else { return [] }
    var items: [ResetRadarItem] = []

    for usage in snapshot.providers {
      let slots = limitSeriesSlots(for: usage.metrics)
      for (index, metric) in usage.metrics.enumerated() {
        guard let resetAt = metric.resetAt, resetAt > now else { continue }
        let interval = resetAt.timeIntervalSince(now)
        let kind = slots.count == usage.metrics.count
          ? slots[index].kind
          : QuotaWindowKind.classify(metricID: metric.id, label: metric.label)
        let item = ResetRadarItem(
          accountID: usage.accountID,
          accountName: usage.title,
          provider: usage.provider,
          metricID: metric.id,
          metricLabel: metric.label,
          windowKind: kind,
          remainingPercent: metric.remainingPercent,
          remainingAmount: metric.remainingAmount,
          usedDisplay: metric.usedDisplay,
          resetAt: resetAt,
          countdown: formatResetCountdown(to: resetAt, now: now),
          secondsUntilReset: interval
        )
        items.append(item)
      }
    }

    let sorted = items.sorted { lhs, rhs in
      if lhs.secondsUntilReset != rhs.secondsUntilReset {
        return lhs.secondsUntilReset < rhs.secondsUntilReset
      }
      return lhs.accountName < rhs.accountName
    }
    return Array(sorted.prefix(max(0, maxCount)))
  }
}
