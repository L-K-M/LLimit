import Foundation

/// Entry dates are display-state boundaries, not a repeating widget poll.
public enum DashboardTimeline {
  // The shared age policy uses `>`; render one second beyond its boundary.
  private static let boundaryDelay: TimeInterval = 1

  public static func entryDates(snapshot: QuotaSnapshot?, accounts: [ProviderAccount], now: Date,
                                refreshIntervalMinutes: Int) -> [Date] {
    guard let snapshot else { return [now] }
    let usages = orderedUsageForAccounts(snapshot.providers, accounts: accounts)
    let failures = orderedFailuresForAccounts(snapshot.failures, accounts: accounts)
    guard !usages.isEmpty || !failures.isEmpty else { return [now] }

    let maxAge = QuotaFreshness.maxAge(refreshIntervalMinutes: refreshIntervalMinutes)
    var dates: Set<Date> = [now]
    for sourceDate in [snapshot.generatedAt] + usages.map(\.fetchedAt) {
      let transition = sourceDate.addingTimeInterval(maxAge + boundaryDelay)
      if transition.timeIntervalSince1970.isFinite, transition > now { dates.insert(transition) }
    }
    for usage in usages {
      for metric in usage.metrics {
        guard !metric.isUnlimited, metric.remainingPercent != nil, let reset = metric.resetAt,
              reset > usage.fetchedAt, reset > now else { continue }
        dates.insert(reset)
      }
    }
    func state(at date: Date) -> ([MenuBarGraph.Freshness], Bool) {
      (MenuBarGraph.bars(snapshot: snapshot, accounts: accounts, now: date, staleAfter: maxAge).map(\.freshness),
       isStale(snapshot: snapshot, accounts: accounts, now: date, refreshIntervalMinutes: refreshIntervalMinutes))
    }
    var previous = state(at: now)
    var entries = [now]
    for date in dates.sorted().dropFirst() {
      let next = state(at: date)
      guard next.0 != previous.0 || next.1 != previous.1 else { continue }
      entries.append(date)
      previous = next
    }
    return entries
  }

  public static func isStale(snapshot: QuotaSnapshot?, accounts: [ProviderAccount], now: Date,
                             refreshIntervalMinutes: Int) -> Bool {
    guard let snapshot else { return false }
    let maxAge = QuotaFreshness.maxAge(refreshIntervalMinutes: refreshIntervalMinutes)
    if QuotaFreshness.isStale(fetchedAt: snapshot.generatedAt, in: snapshot, now: now, maxAge: maxAge) { return true }
    if orderedUsageForAccounts(snapshot.providers, accounts: accounts).contains(where: {
      QuotaFreshness.isStale(fetchedAt: $0.fetchedAt, in: snapshot, now: now, maxAge: maxAge)
    }) { return true }
    return MenuBarGraph.bars(snapshot: snapshot, accounts: accounts, now: now, staleAfter: maxAge)
      .contains { $0.freshness == .stale }
  }
}
