import Foundation

/// Whether a manual refresh can do anything right now, and why not when it cannot.
/// Refresh controls are disabled only for the non-`ready` states.
public enum RefreshAvailability: Equatable, Sendable {
  case ready
  case refreshing
  /// Every enabled account is waiting on an open browser sign-in.
  case waitingForSignIn(QuotaProvider)
  case noCompleteAccounts

  public init(isRefreshing: Bool, accounts: [ProviderAccount], signingInAccountIDs: Set<String>) {
    if isRefreshing {
      self = .refreshing
      return
    }

    let enabled = accounts.filter(\.isEnabled)
    if enabled.contains(where: { Self.isRefreshable($0) && !signingInAccountIDs.contains($0.id) }) {
      self = .ready
      return
    }

    // A new account has no credentials until its sign-in completes, so waiting
    // is the accurate reason even when it is not refreshable yet.
    if let waiting = enabled.first(where: { signingInAccountIDs.contains($0.id) }) {
      self = .waitingForSignIn(waiting.provider)
      return
    }

    self = .noCompleteAccounts
  }

  public var allowsRefresh: Bool { self == .ready }

  /// Why Refresh is unavailable, or nil when it can run.
  public var reason: String? {
    switch self {
    case .ready:
      return nil
    case .refreshing:
      return "A refresh is already running"
    case .waitingForSignIn(let provider):
      return "Waiting for \(provider.displayName) sign-in"
    case .noCompleteAccounts:
      return "No enabled accounts with complete credentials"
    }
  }

  /// Tooltip for Refresh controls.
  public var help: String { reason ?? "Fetch current usage" }

  /// A refresh cycle acts on accounts with complete credentials, and also on
  /// managed Claude profiles, which it renews first and reports when that fails.
  private static func isRefreshable(_ account: ProviderAccount) -> Bool {
    account.hasRequiredCredentials || ClaudeCodeProfile.profile(from: account.credentials) != nil
  }
}

/// The accounts one refresh cycle fetches.
///
/// An open OpenAI browser sign-in may replace its account's credentials and
/// retire the previous Codex profile when it completes, so the cycle leaves that
/// account alone instead of waiting for the sign-in: it is skipped, and keeps its
/// last results through `QuotaSnapshot.carryingResults(forSkippedAccountIDs:from:)`.
public struct RefreshSelection: Sendable {
  public private(set) var fetched: [ProviderRuntimeConfiguration] = []
  /// Accounts this cycle would have fetched if they were not signing in.
  public private(set) var skippedAccountIDs: Set<String> = []

  /// `failedPreparation` lists accounts whose credentials could not be prepared;
  /// the caller reports those failures itself.
  public init(configurations: [ProviderRuntimeConfiguration], failedPreparation: Set<String>,
              signingInAccountIDs: Set<String>) {
    for configuration in configurations where configuration.isEnabled
      && configuration.provider.hasRequiredCredentials(configuration.credentials)
      && !failedPreparation.contains(configuration.accountID) {
      if signingInAccountIDs.contains(configuration.accountID) {
        skippedAccountIDs.insert(configuration.accountID)
      } else {
        fetched.append(configuration)
      }
    }
  }
}

public extension QuotaSnapshot {
  /// Keeps the last results of accounts this cycle skipped (see `RefreshSelection`).
  /// Like `mergingStaleUsage`, carried usage keeps its original `fetchedAt`, so it
  /// still reads as stale. Unlike a failed fetch, a skipped account was not asked
  /// at all, so an earlier failure also stands until a real fetch replaces it.
  func carryingResults(forSkippedAccountIDs accountIDs: Set<String>, from previous: QuotaSnapshot?) -> QuotaSnapshot {
    guard let previous else { return self }
    return replacingResults(forAccountIDs: accountIDs, from: previous)
  }
}
