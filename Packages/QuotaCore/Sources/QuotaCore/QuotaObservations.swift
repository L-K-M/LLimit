import Foundation

/// Successful source readings, independent of publication time.
public enum QuotaObservations {
  public static func extract(
    from snapshots: [QuotaSnapshot],
    accounts: [ProviderAccount]? = nil,
    window: ClosedRange<Date>
  ) -> [ProviderUsage] {
    // Disabled siblings still make legacy ownership ambiguous.
    let reconciled = accounts.map { accounts in snapshots.map { $0.reconciled(with: accounts) } } ?? snapshots
    return successfulUsage(in: reconciled).filter { window.contains($0.fetchedAt) }
  }

  static func newSuccessfulUsage(in snapshot: QuotaSnapshot, excluding history: [QuotaSnapshot]) -> [ProviderUsage] {
    // Old archives may contain carried copies. None is a new fetch on append.
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

        // Prefer source precision over the persisted whole-second copy.
        // Bounds apply after dedup so rounding cannot invent an endpoint.
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
      // ISO-8601 archive dates lose subseconds across reloads.
      second = usage.fetchedAt.timeIntervalSince1970.rounded(.down)
    }
  }
}
