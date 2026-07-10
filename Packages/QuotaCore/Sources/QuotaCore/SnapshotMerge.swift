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

  /// Removes data for accounts that are no longer active and applies current account names.
  /// The snapshot timestamp is intentionally preserved: changing configuration does not make
  /// previously fetched quota data fresh.
  func reconciled(with activeAccounts: [ProviderAccount]) -> QuotaSnapshot {
    let accountsByID = Dictionary(
      activeAccounts.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let accountsByProvider = Dictionary(grouping: activeAccounts, by: \.provider)

    func account(id: String, provider: QuotaProvider) -> ProviderAccount? {
      if let exact = accountsByID[id], exact.provider == provider {
        return exact
      }

      guard
        id == provider.rawValue,
        let providerAccounts = accountsByProvider[provider],
        providerAccounts.count == 1
      else {
        return nil
      }
      return providerAccounts[0]
    }

    let reconciledProviders = providers.compactMap { usage -> ProviderUsage? in
      guard let activeAccount = account(id: usage.accountID, provider: usage.provider) else {
        return nil
      }

      var reconciled = usage
      reconciled.accountID = activeAccount.id
      reconciled.title = activeAccount.resolvedDisplayName
      return reconciled
    }

    let reconciledFailures = failures.compactMap { failure -> ProviderFailure? in
      guard let activeAccount = account(id: failure.accountID, provider: failure.provider) else {
        return nil
      }

      var reconciled = failure
      reconciled.accountID = activeAccount.id
      return reconciled
    }

    return QuotaSnapshot(
      version: version,
      generatedAt: generatedAt,
      providers: reconciledProviders,
      failures: reconciledFailures
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
