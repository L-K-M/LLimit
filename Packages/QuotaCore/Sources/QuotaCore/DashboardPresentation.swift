import Foundation

/// Missing files and failed reads must not become the same dashboard state.
public enum DashboardStoredValue<Value: Sendable>: Sendable {
  case loaded(Value)
  case missing
  case unavailable

  public var value: Value? {
    guard case .loaded(let value) = self else { return nil }
    return value
  }
}

public struct DashboardPresentation: Sendable {
  public enum State: Equatable, Sendable {
    case ready
    case noAccounts
    case noEnabledAccounts
    case awaitingData
    case allFailed
    case storageUnavailable
  }

  public let state: State
  public let providers: [ProviderUsage]
  public let failures: [ProviderFailure]
  public var failureCount: Int { failures.count }

  public init(settings: DashboardStoredValue<AppSettings>, snapshot: DashboardStoredValue<QuotaSnapshot>) {
    guard case .loaded(let currentSettings) = settings else {
      if case .missing = settings, case .missing = snapshot {
        self.init(state: .noAccounts)
      } else {
        self.init(state: .storageUnavailable)
      }
      return
    }

    guard !currentSettings.accounts.isEmpty else {
      self.init(state: .noAccounts)
      return
    }

    let enabledAccounts = currentSettings.accounts.filter(\.isEnabled)
    guard !enabledAccounts.isEmpty else {
      self.init(state: .noEnabledAccounts)
      return
    }

    if case .unavailable = snapshot {
      self.init(state: .storageUnavailable)
      return
    }

    // Reconcile before risk sorting, summaries and the widget's row limit.
    let providers = orderedUsageForAccounts(snapshot.value?.providers ?? [], accounts: currentSettings.accounts)
      .sorted { lhs, rhs in
        let lhsRemaining = dashboardRemainingPercent(for: lhs) ?? Int.max
        let rhsRemaining = dashboardRemainingPercent(for: rhs) ?? Int.max
        if lhsRemaining != rhsRemaining { return lhsRemaining < rhsRemaining }
        return lhs.title < rhs.title
      }

    let failures = orderedFailuresForAccounts(snapshot.value?.failures ?? [], accounts: currentSettings.accounts)
    let state: State = providers.isEmpty
      ? (failures.count == enabledAccounts.count ? .allFailed : .awaitingData)
      : .ready
    self.init(state: state, providers: providers, failures: failures)
  }

  public var overviewSummary: String {
    guard !providers.isEmpty else { return "No accounts" }
    let accountCount = "\(providers.count) \(providers.count == 1 ? "account" : "accounts")"
    let boundedMetrics = providers.compactMap { dashboardPrimaryMetric(for: $0) }
      .filter { boundedRemainingPercent(for: $0) != nil }

    if let worstMetric = boundedMetrics.min(by: { (boundedRemainingPercent(for: $0) ?? Int.max) < (boundedRemainingPercent(for: $1) ?? Int.max) }),
       let remaining = boundedRemainingPercent(for: worstMetric) {
      let qualifier = worstMetric.isPercentageEstimated ? "≈" : ""
      return "\(accountCount), lowest \(qualifier)\(remaining)% left"
    }
    return "\(accountCount) tracked"
  }

  private init(state: State, providers: [ProviderUsage] = [], failures: [ProviderFailure] = []) {
    self.state = state
    self.providers = providers
    self.failures = failures
  }
}

/// Current names and Settings order, with the same sole-provider legacy rule
/// as usage projection. Obsolete, disabled and duplicate failures disappear.
public func orderedFailuresForAccounts(_ failures: [ProviderFailure], accounts: [ProviderAccount]) -> [ProviderFailure] {
  let failuresByKey = QuotaSnapshot(generatedAt: .distantPast, providers: [], failures: failures).preferredFailures
  let accountsByProvider = Dictionary(grouping: accounts, by: \.provider)

  return accounts.filter(\.isEnabled).compactMap { account in
    let key = QuotaAccountKey(provider: account.provider, accountID: account.id)
    let legacyKey = QuotaAccountKey(provider: account.provider, accountID: account.provider.rawValue)
    let legacy = accountsByProvider[account.provider]?.count == 1 ? failuresByKey[legacyKey] : nil
    guard var failure = failuresByKey[key] ?? legacy else { return nil }
    failure.accountID = account.id
    failure.title = account.resolvedDisplayName
    return failure
  }
}

public func dashboardPrimaryMetric(for usage: ProviderUsage) -> UsageMetric? {
  let boundedMetrics = usage.metrics.filter { boundedRemainingPercent(for: $0) != nil }

  if let mostConstrained = boundedMetrics.min(by: { (boundedRemainingPercent(for: $0) ?? Int.max) < (boundedRemainingPercent(for: $1) ?? Int.max) }) {
    return mostConstrained
  }

  // An unknown limit or amount-only balance is not an unlimited account.
  let nonUnlimitedMetrics = usage.metrics.filter { !$0.isUnlimited }
  return nonUnlimitedMetrics.first(where: { $0.usageLine != nil })
    ?? nonUnlimitedMetrics.first
    ?? usage.metrics.first(where: \.isUnlimited)
}

/// Aggregates cannot attribute a percentage to a quota window. Unlimited is a
/// separate display state, not a bounded 100% observation.
public func dashboardRemainingPercent(for usage: ProviderUsage) -> Int? {
  dashboardPrimaryMetric(for: usage).flatMap { boundedRemainingPercent(for: $0) }
}

/// Keep the provider-preferred tile pair; only bounded values make bar stops.
public func dashboardBarMetrics(for usage: ProviderUsage) -> [UsageMetric] {
  Array(defaultRingMetrics(for: usage).filter { boundedRemainingPercent(for: $0) != nil }.prefix(2))
}

private func boundedRemainingPercent(for metric: UsageMetric) -> Int? {
  guard !metric.isUnlimited, let remaining = metric.remainingPercent else { return nil }
  return max(0, min(100, remaining))
}
