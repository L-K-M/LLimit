import Foundation

/// Request and carry ownership for one cycle. Credentials stay in memory only.
public struct RefreshProvenance: Sendable {
  private struct Capture: Sendable {
    let configuration: ProviderRuntimeConfiguration
    let revision: UUID?
  }

  private var queries: [QuotaAccountKey: Capture] = [:]
  private var carries: [QuotaAccountKey: Capture] = [:]

  public init(configurations: [ProviderRuntimeConfiguration], carriedConfigurations: [ProviderRuntimeConfiguration] = [],
              credentialRevisions: [String: UUID] = [:]) {
    recordQueries(configurations, credentialRevisions: credentialRevisions)
    for configuration in carriedConfigurations {
      let key = Self.key(configuration)
      carries[key] = Capture(configuration: configuration, revision: credentialRevisions[configuration.accountID])
      queries[key] = nil
    }
  }

  /// A retry owns results only after its actual request credentials are captured.
  public mutating func recordQueries(_ configurations: [ProviderRuntimeConfiguration], credentialRevisions: [String: UUID]) {
    for configuration in configurations {
      let key = Self.key(configuration)
      // Query bookkeeping must not reassign an unfetched carry to a new login.
      guard carries[key] == nil else { continue }
      queries[key] = Capture(configuration: configuration, revision: credentialRevisions[configuration.accountID])
    }
  }

  public func matchesQuery(_ account: ProviderAccount, credentialRevisions: [String: UUID],
                           environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    guard let capture = queries[QuotaAccountKey(provider: account.provider, accountID: account.id)] else { return false }
    return Self.matches(capture, account: account, revisions: credentialRevisions, environment: environment)
  }

  public func validated(_ result: QuotaSnapshot, accounts: [ProviderAccount], credentialRevisions: [String: UUID],
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> QuotaSnapshot {
    let accountsByKey = Dictionary(accounts.map { (QuotaAccountKey(provider: $0.provider, accountID: $0.id), $0) },
                                   uniquingKeysWith: { first, _ in first })
    let valid = Set(queries.merging(carries) { _, carry in carry }.compactMap { key, capture -> QuotaAccountKey? in
      guard let account = accountsByKey[key],
            Self.matches(capture, account: account, revisions: credentialRevisions, environment: environment) else { return nil }
      return key
    })
    var validated = result
    validated.providers.removeAll { !valid.contains($0.accountKey) }
    validated.failures.removeAll { !valid.contains($0.accountKey) }
    return validated
  }

  private static func key(_ configuration: ProviderRuntimeConfiguration) -> QuotaAccountKey {
    QuotaAccountKey(provider: configuration.provider, accountID: configuration.accountID)
  }

  private static func matches(_ capture: Capture, account: ProviderAccount, revisions: [String: UUID],
                              environment: [String: String]) -> Bool {
    capture.configuration.matchesCurrentAccount(account, expectedCredentialRevision: capture.revision,
                                                 currentCredentialRevision: revisions[account.id], environment: environment)
  }
}
