import Foundation

/// Snapshot identity includes the provider, including legacy provider-keyed accounts.
public struct QuotaAccountKey: Hashable, Sendable {
  public let provider: QuotaProvider
  public let accountID: String

  public init(provider: QuotaProvider, accountID: String) {
    self.provider = provider
    self.accountID = accountID
  }
}

public extension ProviderUsage {
  var accountKey: QuotaAccountKey { QuotaAccountKey(provider: provider, accountID: accountID) }
}

public extension ProviderFailure {
  var accountKey: QuotaAccountKey { QuotaAccountKey(provider: provider, accountID: accountID) }
}

public extension QuotaSnapshot {
  /// Keep the most actionable failure per account. Equal priorities retain input order.
  var preferredFailures: [QuotaAccountKey: ProviderFailure] {
    Dictionary(failures.map { ($0.accountKey, $0) }, uniquingKeysWith: {
      failurePriority($0.kind) <= failurePriority($1.kind) ? $0 : $1
    })
  }

  private func failurePriority(_ kind: QuotaErrorKind) -> Int {
    switch kind {
    case .auth: return 0
    case .notConfigured: return 1
    case .rateLimit: return 2
    case .api: return 3
    case .decoding: return 4
    case .network: return 5
    case .unknown: return 6
    }
  }
}
