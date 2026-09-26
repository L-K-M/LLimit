import Foundation

/// A consistent read of one completed CLI profile login. Refresh material is
/// ephemeral and is passed only to Claude Code, never to a settings store.
public struct ClaudeCodeLogin: Equatable, Sendable {
  public let credentials: ClaudeCodeCredentials
  public let identity: ClaudeCodeIdentity
  public let renewal: ClaudeCodeRenewalMaterial?

  public init(credentials: ClaudeCodeCredentials, identity: ClaudeCodeIdentity, renewal: ClaudeCodeRenewalMaterial?) {
    self.credentials = credentials
    self.identity = identity
    self.renewal = renewal
  }
}

public enum ClaudeCodeRenewalError: LocalizedError, Equatable {
  case missingProfile
  case identityMismatch
  case reconnectRequired
  case missingRenewalMaterial
  case inProgress
  case renewalIncomplete

  public var errorDescription: String? {
    switch self {
    case .missingProfile:
      return "Connect this Claude account with its own Claude Code login to renew it."
    case .identityMismatch:
      return "The saved Claude Code profile belongs to a different account or organization. Reconnect this account."
    case .reconnectRequired:
      return "The previous Claude login renewal did not finish safely. Reconnect this account."
    case .missingRenewalMaterial:
      return "Claude Code has no saved refresh credentials for this account. Reconnect it."
    case .inProgress:
      return "Claude Code is still renewing this account. Refresh again after it finishes."
    case .renewalIncomplete:
      return "Claude Code did not save a fresh login. Reconnect this account."
    }
  }
}

/// Sequences durable markers around the CLI's rotating grant. Callers serialize
/// operations for each profile and make `persist` durable before it returns.
public enum ClaudeCodeRenewal {
  public static func prepare(
    stored: [String: String], force: Bool = false, now: Date = Date(),
    read: @Sendable () async throws -> ClaudeCodeLogin,
    persist: @Sendable ([String: String]) async throws -> Void,
    renew: @Sendable (ClaudeCodeRenewalMaterial) async throws -> Bool
  ) async throws -> [String: String] {
    guard let profile = ClaudeCodeProfile.profile(from: stored) else {
      throw ClaudeCodeRenewalError.missingProfile
    }
    let login = try await read()
    try requireIdentity(login.identity, matches: stored)

    // A process may have completed after a previous timeout or app exit. Adopt
    // its saved result before considering another rotation, including force mode.
    if let updated = freshAdoption(stored: stored, login: login, profile: profile, now: now) {
      try await persist(updated)
      return updated
    }
    guard stored[CredentialField.anthropicRenewalPending] == nil else {
      throw ClaudeCodeRenewalError.reconnectRequired
    }
    if !force, ClaudeCodeProfile.readiness(for: ClaudeCodeProfile.credentials(from: stored), now: now) == .ready {
      return stored
    }
    // If the profile store fell back to an older credential copy, its refresh
    // grant may already have been consumed by the token saved in LLimit.
    guard login.credentials.accessToken == stored[CredentialField.anthropicAccessToken] else {
      throw ClaudeCodeRenewalError.reconnectRequired
    }
    guard let material = login.renewal else { throw ClaudeCodeRenewalError.missingRenewalMaterial }

    // Never replay a potentially consumed refresh token after a crash, timeout,
    // or uncertain subprocess error. Only a newly persisted token clears this.
    var pending = stored
    pending[CredentialField.anthropicRenewalPending] = "true"
    try await persist(pending)
    guard try await renew(material) else { throw ClaudeCodeRenewalError.inProgress }

    let completed = try await read()
    try requireIdentity(completed.identity, matches: stored)
    guard let updated = freshAdoption(stored: pending, login: completed, profile: profile, now: now) else {
      throw ClaudeCodeRenewalError.renewalIncomplete
    }
    try await persist(updated)
    return updated
  }

  private static func requireIdentity(_ candidate: ClaudeCodeIdentity, matches stored: [String: String]) throws {
    guard let expected = ClaudeCodeProfile.identity(from: stored),
          expected.accountID == candidate.accountID,
          expected.organizationID == candidate.organizationID
    else { throw ClaudeCodeRenewalError.identityMismatch }
  }

  private static func freshAdoption(
    stored: [String: String], login: ClaudeCodeLogin, profile: ClaudeCodeProfile, now: Date
  ) -> [String: String]? {
    guard let expiry = login.credentials.expiresAt, expiry.timeIntervalSince1970.isFinite,
          ClaudeCodeProfile.readiness(for: login.credentials, now: now) == .ready
    else { return nil }
    return ClaudeCodeProfile.adoption(
      for: stored, credentials: login.credentials, identity: login.identity, profileID: profile.id, now: now)
  }
}
