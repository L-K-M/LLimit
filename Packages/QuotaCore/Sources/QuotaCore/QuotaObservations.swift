import Foundation

/// Successful source readings, independent of snapshot publication times.
public enum QuotaObservations {
  public static func extract(
    from snapshots: [QuotaSnapshot],
    accounts: [ProviderAccount],
    window: ClosedRange<Date>
  ) -> [ProviderUsage] {
    // Resolve legacy IDs before failure matching and dedupe. Disabled siblings
    // still make ownership ambiguous; visibility is the caller's decision.
    let reconciled = snapshots.map { $0.reconciled(with: accounts) }
    return successfulUsage(in: reconciled).filter { window.contains($0.fetchedAt) }
  }

  static func newSuccessfulUsage(in snapshot: QuotaSnapshot, excluding history: [QuotaSnapshot]) -> [ProviderUsage] {
    // Existing archives remain intact, including their carried copies. None
    // of those source timestamps represents a new observation on append.
    let recorded = Set(history.flatMap { $0.providers.map(FetchKey.init) })
    return successfulUsage(in: [snapshot]).filter { !recorded.contains(FetchKey($0)) }
  }

  private static func successfulUsage(in snapshots: [QuotaSnapshot]) -> [ProviderUsage] {
    var byFetch: [FetchKey: ProviderUsage] = [:]

    for snapshot in snapshots {
      let failed = Set(snapshot.failures.map { AccountKey(provider: $0.provider, accountID: $0.accountID) })

      for usage in snapshot.providers {
        let key = FetchKey(usage)
        guard !failed.contains(key.account) else { continue }
        if let previous = byFetch[key], previous.fetchedAt >= usage.fetchedAt { continue }

        // Prefer the unrounded source time over its persisted whole-second
        // copy. Apply window bounds afterward so rounding cannot invent a point.
        byFetch[key] = usage
      }
    }

    return byFetch.values.sorted { lhs, rhs in
      if lhs.fetchedAt != rhs.fetchedAt { return lhs.fetchedAt < rhs.fetchedAt }
      if lhs.provider != rhs.provider { return lhs.provider.rawValue < rhs.provider.rawValue }
      return lhs.accountID < rhs.accountID
    }
  }

  private struct AccountKey: Hashable {
    let provider: QuotaProvider
    let accountID: String
  }

  private struct FetchKey: Hashable {
    let account: AccountKey
    let second: TimeInterval

    init(_ usage: ProviderUsage) {
      account = AccountKey(provider: usage.provider, accountID: usage.accountID)
      // JSONEncoder's ISO-8601 dates discard subseconds. Two readings within
      // one persisted second cannot safely be distinguished across reloads.
      second = usage.fetchedAt.timeIntervalSince1970.rounded(.down)
    }
  }
}
