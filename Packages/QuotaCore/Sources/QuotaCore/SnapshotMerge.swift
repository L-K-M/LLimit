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

    let freshAccountKeys = Set(providers.map(\.accountKey))
    // Accounts that failed this cycle and produced no fresh usage.
    let failedAccountKeys = Set(failures.map(\.accountKey)).subtracting(freshAccountKeys)
    guard !failedAccountKeys.isEmpty else { return self }

    let carried = previous.providers.filter { failedAccountKeys.contains($0.accountKey) }
      .map { $0.clearingElapsedWindows(at: generatedAt) }
    guard !carried.isEmpty else { return self }

    var merged = self
    merged.providers += carried
    return merged
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
      reconciled.title = activeAccount.resolvedDisplayName
      return reconciled
    }

    var reconciled = self
    reconciled.providers = reconciledProviders
    reconciled.failures = reconciledFailures
    return reconciled
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

    var merged = self
    merged.providers = mergedProviders
    merged.failures = mergedFailures
    return merged
  }
}

public extension ProviderUsage {
  /// A carried reading cannot describe a window that reset after it was fetched.
  /// Keep the window and reset date so displays can explain the missing reading.
  func clearingElapsedWindows(at now: Date) -> ProviderUsage {
    var cleared = self
    var changed = false
    for index in cleared.metrics.indices {
      let metric = cleared.metrics[index]
      guard !metric.isUnlimited, let resetAt = metric.resetAt, fetchedAt < resetAt, resetAt <= now else { continue }

      cleared.metrics[index].remainingPercent = nil
      cleared.metrics[index].remainingAmount = nil
      cleared.metrics[index].estimatedTotal = nil
      cleared.metrics[index].usedDisplay = nil
      cleared.metrics[index].resetIn = nil
      cleared.metrics[index].detail = "Window reset since the last successful refresh"
      changed = true
    }
    guard changed else { return self }

    cleared.maxUsagePercent = cleared.metrics.compactMap(\.remainingPercent).map { 100 - $0 }.max()
    return cleared
  }
}
