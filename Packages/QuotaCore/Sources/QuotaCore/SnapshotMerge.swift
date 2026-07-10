import Foundation

public extension QuotaSnapshot {
  /// Produces a snapshot that keeps this cycle's fresh results but backfills any account
  /// that failed this cycle with its last successful usage from `previous`.
  ///
  /// Without this, a single failed fetch (a transient network error, a 401 after a token
  /// expires, a rate-limit 429) drops the account from the snapshot entirely, so its ring
  /// vanishes from the widgets and menu bar. Carrying the last good `ProviderUsage` forward
  /// lets consumers render stale-but-useful data — its original `fetchedAt` still signals
  /// how old it is — while the `ProviderFailure` remains recorded so the error is still shown.
  func mergingStaleUsage(from previous: QuotaSnapshot?) -> QuotaSnapshot {
    guard let previous else { return self }

    let freshAccountIDs = Set(providers.map(\.accountID))
    // Accounts that failed this cycle and produced no fresh usage.
    let failedAccountIDs = Set(failures.map(\.accountID)).subtracting(freshAccountIDs)
    guard !failedAccountIDs.isEmpty else { return self }

    let carried = previous.providers.filter {
      failedAccountIDs.contains($0.accountID) && !freshAccountIDs.contains($0.accountID)
    }
    guard !carried.isEmpty else { return self }

    return QuotaSnapshot(
      version: version,
      generatedAt: generatedAt,
      providers: providers + carried,
      failures: failures
    )
  }

  /// Returns a copy of this snapshot with the usage/failure entries for `accountIDs`
  /// replaced by whatever `other` holds for those accounts. Used to splice a targeted
  /// re-fetch (e.g. an OpenAI-only retry) back into the full snapshot without re-fetching
  /// — or disturbing — the other providers.
  func replacingResults(forAccountIDs accountIDs: Set<String>, from other: QuotaSnapshot) -> QuotaSnapshot {
    guard !accountIDs.isEmpty else { return self }

    var mergedProviders = providers.filter { !accountIDs.contains($0.accountID) }
    var mergedFailures = failures.filter { !accountIDs.contains($0.accountID) }
    mergedProviders += other.providers.filter { accountIDs.contains($0.accountID) }
    mergedFailures += other.failures.filter { accountIDs.contains($0.accountID) }

    return QuotaSnapshot(
      version: version,
      generatedAt: generatedAt,
      providers: mergedProviders,
      failures: mergedFailures
    )
  }
}
