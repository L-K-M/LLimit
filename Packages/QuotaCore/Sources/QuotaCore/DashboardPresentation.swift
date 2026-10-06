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
  public let failureCount: Int

  public init(settings: DashboardStoredValue<AppSettings>, snapshot: DashboardStoredValue<QuotaSnapshot>) {
    guard case .loaded(let currentSettings) = settings else {
      if case .missing = settings, case .missing = snapshot {
        self.init(state: .noAccounts)
      } else {
        self.init(state: .storageUnavailable)
      }
      return
    }

    if case .unavailable = snapshot {
      self.init(state: .storageUnavailable)
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

    // Reconcile before risk sorting, summaries and the widget's row limit.
    let providers = orderedUsageForAccounts(snapshot.value?.providers ?? [], accounts: currentSettings.accounts)
      .sorted { lhs, rhs in
        let lhsRemaining = dashboardRemainingPercent(for: lhs) ?? Int.max
        let rhsRemaining = dashboardRemainingPercent(for: rhs) ?? Int.max
        if lhsRemaining != rhsRemaining { return lhsRemaining < rhsRemaining }
        return lhs.title < rhs.title
      }

    let failureCount = Self.currentFailureCount(snapshot.value?.failures ?? [], accounts: currentSettings.accounts)
    let state: State = providers.isEmpty
      ? (failureCount == enabledAccounts.count ? .allFailed : .awaitingData)
      : .ready
    self.init(state: state, providers: providers, failureCount: failureCount)
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

  private init(state: State, providers: [ProviderUsage] = [], failureCount: Int = 0) {
    self.state = state
    self.providers = providers
    self.failureCount = failureCount
  }

  private static func currentFailureCount(_ failures: [ProviderFailure], accounts: [ProviderAccount]) -> Int {
    let failuresByID = Dictionary(grouping: failures, by: \.accountID)
    let accountsByProvider = Dictionary(grouping: accounts, by: \.provider)

    // Match the usage reconciliation's exact/sole-provider ownership rules.
    return accounts.filter(\.isEnabled).filter { account in
      if failuresByID[account.id]?.contains(where: { $0.provider == account.provider }) == true {
        return true
      }
      guard accountsByProvider[account.provider]?.count == 1 else { return false }
      return failuresByID[account.provider.rawValue]?.contains(where: { $0.provider == account.provider }) == true
    }.count
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
