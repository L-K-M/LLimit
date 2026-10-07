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

  /// A refresh cycle acts on accounts with complete credentials, and also prepares
  /// some first: it renews managed Claude profiles (reporting when that fails), and
  /// renews or adopts an imported OpenAI login's access token from its refresh token
  /// or ChatGPT account id.
  private static func isRefreshable(_ account: ProviderAccount) -> Bool {
    if account.hasRequiredCredentials { return true }
    let stored = account.credentials
    if account.provider == .anthropic, ClaudeCodeProfile.profile(from: stored) != nil,
       stored[CredentialField.anthropicAccessToken]?.isEnvironmentReference != true { return true }
    guard account.provider == .openAI, !CodexAccountProfile.isManaged(stored),
          stored[CredentialField.openAIAccessToken]?.isEnvironmentReference != true else { return false }

    let resolved = stored.resolvingEnvironmentReferences()
    if nonEmptyString(resolved[CredentialField.openAIAccountID]) != nil { return true }
    // External grants cannot be rotated into settings. Identity-matched file
    // adoption can still fill a literal access-token field without rotating.
    return stored[CredentialField.openAIRefreshToken]?.isEnvironmentReference != true
      && nonEmptyString(resolved[CredentialField.openAIRefreshToken]) != nil
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
  public private(set) var skipped: [ProviderRuntimeConfiguration] = []
  /// Accounts this cycle would have fetched if they were not signing in.
  public var skippedAccountIDs: Set<String> { Set(skipped.map(\.accountID)) }

  /// `failedPreparation` lists accounts whose credentials could not be prepared;
  /// the caller reports those failures itself.
  public init(configurations: [ProviderRuntimeConfiguration], failedPreparation: Set<String>,
              signingInAccountIDs: Set<String>) {
    for configuration in configurations where configuration.isEnabled
      && configuration.provider.hasRequiredCredentials(configuration.credentials)
      && !failedPreparation.contains(configuration.accountID) {
      if signingInAccountIDs.contains(configuration.accountID) {
        skipped.append(configuration)
      } else {
        fetched.append(configuration)
      }
    }
  }
}

public extension ProviderRuntimeConfiguration {
  /// Compare request-only values with current settings without saving resolved secrets.
  /// Revisions identify committed replacements even when a key later returns to its old value.
  func matchesCurrentAccount(
    _ account: ProviderAccount, expectedCredentialRevision: UUID? = nil, currentCredentialRevision: UUID? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    expectedCredentialRevision == currentCredentialRevision
      && account.isEnabled && account.id == accountID && account.provider == provider
      && account.runtimeConfiguration(environment: environment).credentials == credentials
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
