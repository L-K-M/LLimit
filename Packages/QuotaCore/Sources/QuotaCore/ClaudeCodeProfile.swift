import CoreFoundation
import Foundation

public struct ClaudeCodeIdentity: Equatable, Sendable {
  public let accountID: UUID
  public let organizationID: UUID
  public let email: String?

  public init(accountID: UUID, organizationID: UUID, email: String? = nil) {
    self.accountID = accountID
    self.organizationID = organizationID
    self.email = email?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
  }
}

public struct ClaudeCodeCredentials: Equatable, Sendable {
  public let accessToken: String
  public let expiresAt: Date?

  public init(accessToken: String, expiresAt: Date?) {
    self.accessToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
    self.expiresAt = expiresAt
  }
}

/// Ephemeral input for Claude Code's own renewal command. Never save this in
/// LLimit settings: the profile's CLI credential store owns refresh-token rotation.
public struct ClaudeCodeRenewalMaterial: Equatable, Sendable {
  public let refreshToken: String
  public let scopes: [String]

  public init(refreshToken: String, scopes: [String]) {
    self.refreshToken = refreshToken
    self.scopes = scopes
  }
}

public enum ClaudeCodeCredentialSource: String, Sendable {
  case managedProfile = "managed_profile"
  case linkedImport = "linked_import"
}

public enum ClaudeCodeCredentialReadiness: Equatable, Sendable {
  case ready
  case renewalRequired
  case missing
}

public enum ClaudeCodeLoginError: LocalizedError, Equatable {
  case unusableCredentials
  case identityMismatch
  case duplicateAccount

  public var errorDescription: String? {
    switch self {
    case .unusableCredentials: return "Claude Code did not save a usable login. Sign in again."
    case .identityMismatch: return "This login belongs to a different Claude account or organization."
    case .duplicateAccount: return "This Claude account and organization are already connected."
    }
  }
}

/// Pure profile parsing and adoption policy shared by the host and daemon. The
/// host supplies the private profile root; persisted settings never supply paths.
public struct ClaudeCodeProfile: Equatable, Sendable {
  public let id: UUID
  private static let renewalLeadTime: TimeInterval = 5 * 60
  private static let metadataKeys = [
    CredentialField.anthropicProfileID, CredentialField.anthropicAccountID,
    CredentialField.anthropicOrganizationID, CredentialField.anthropicEmail,
    CredentialField.anthropicExpiresAt, CredentialField.anthropicCredentialSource,
    CredentialField.anthropicRenewalPending
  ]

  public init(id: UUID = UUID()) {
    self.id = id
  }

  public func directory(under root: URL) -> URL {
    root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
  }

  public static func parseCredentials(_ data: Data) -> ClaudeCodeCredentials? {
    guard let oauth = oauthObject(data),
          let accessToken = nonemptyString(oauth["accessToken"] ?? oauth["access_token"])
    else { return nil }
    return ClaudeCodeCredentials(
      accessToken: accessToken, expiresAt: epoch(oauth["expiresAt"] ?? oauth["expires_at"]))
  }

  public static func parseRenewalMaterial(_ data: Data) -> ClaudeCodeRenewalMaterial? {
    guard let oauth = oauthObject(data),
          let refreshToken = nonemptyString(oauth["refreshToken"] ?? oauth["refresh_token"])
    else { return nil }

    let scopes: [String]
    if let values = oauth["scopes"] as? [String] {
      scopes = values
    } else if let value = oauth["scopes"] as? String {
      scopes = value.split(separator: " ").map(String.init)
    } else {
      return nil
    }
    // Each OAuth scope is a nonempty printable ASCII token. Reject malformed
    // arrays rather than changing the requested grant by dropping bad entries.
    guard !scopes.isEmpty, scopes.allSatisfy({ scope in
      !scope.isEmpty && scope.unicodeScalars.allSatisfy { scalar in
        scalar.value == 0x21 || (0x23...0x5B).contains(scalar.value) || (0x5D...0x7E).contains(scalar.value)
      }
    }) else { return nil }
    return ClaudeCodeRenewalMaterial(refreshToken: refreshToken, scopes: scopes)
  }

  /// Reads identity saved by a successful Claude Code sign-in. Callers must only
  /// associate it with credentials from that same completed profile login.
  public static func parseIdentity(_ data: Data) -> ClaudeCodeIdentity? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let account = (object["oauthAccount"] ?? object["oauth_account"]) as? [String: Any],
          let accountID = uuid(account["accountUuid"] ?? account["account_uuid"]),
          let organizationID = uuid(account["organizationUuid"] ?? account["organization_uuid"])
    else { return nil }
    return ClaudeCodeIdentity(
      accountID: accountID, organizationID: organizationID,
      email: nonemptyString(account["emailAddress"] ?? account["email_address"]))
  }

  public static func profile(from stored: [String: String]) -> ClaudeCodeProfile? {
    guard stored[CredentialField.anthropicCredentialSource] == ClaudeCodeCredentialSource.managedProfile.rawValue,
          let id = uuid(stored[CredentialField.anthropicProfileID])
    else { return nil }
    return ClaudeCodeProfile(id: id)
  }

  /// An unresolved renewal may still be writing credentials in another process.
  /// Removing its profile would race that write and discard the recovery state.
  public static func isRemovalBlocked(for stored: [String: String]) -> Bool {
    profile(from: stored) != nil && stored[CredentialField.anthropicRenewalPending] != nil
  }

  public static func identity(from stored: [String: String]) -> ClaudeCodeIdentity? {
    guard let accountID = uuid(stored[CredentialField.anthropicAccountID]),
          let organizationID = uuid(stored[CredentialField.anthropicOrganizationID])
    else { return nil }
    return ClaudeCodeIdentity(
      accountID: accountID, organizationID: organizationID,
      email: stored[CredentialField.anthropicEmail])
  }

  public static func credentials(from stored: [String: String]) -> ClaudeCodeCredentials? {
    guard let accessToken = nonemptyString(stored[CredentialField.anthropicAccessToken]) else { return nil }
    return ClaudeCodeCredentials(accessToken: accessToken, expiresAt: epoch(stored[CredentialField.anthropicExpiresAt]))
  }

  /// These values live only in the private credentials dictionary, so the normal
  /// settings redaction also removes profile IDs, identities, and email addresses.
  public static func storedCredentials(
    token: ClaudeCodeCredentials, identity: ClaudeCodeIdentity, profileID: UUID?
  ) -> [String: String] {
    var stored = [
      CredentialField.anthropicAccessToken: token.accessToken,
      CredentialField.anthropicAccountID: identity.accountID.uuidString,
      CredentialField.anthropicOrganizationID: identity.organizationID.uuidString,
      CredentialField.anthropicCredentialSource: profileID == nil
        ? ClaudeCodeCredentialSource.linkedImport.rawValue : ClaudeCodeCredentialSource.managedProfile.rawValue
    ]
    stored[CredentialField.anthropicProfileID] = profileID?.uuidString
    stored[CredentialField.anthropicEmail] = identity.email
    stored[CredentialField.anthropicExpiresAt] = token.expiresAt.map { String($0.timeIntervalSince1970) }
    return stored
  }

  /// A manual token edit detaches its old identity and renewal profile. Reusing
  /// those metadata would let a later refresh silently undo the user's edit.
  public static func clearManagedMetadata(from stored: [String: String]) -> [String: String] {
    stored.filter { !metadataKeys.contains($0.key) }
  }

  /// Associates only a completed interactive login. The caller excludes the
  /// reconnect target from `existingIdentities`; identical email addresses alone
  /// do not mean identical account/organization quotas.
  public static func loginCredentials(
    for stored: [String: String]?, credentials candidate: ClaudeCodeCredentials,
    identity candidateIdentity: ClaudeCodeIdentity, profileID: UUID,
    existingIdentities: [ClaudeCodeIdentity] = [], now: Date = Date()
  ) throws -> [String: String] {
    guard let expiry = candidate.expiresAt, expiry.timeIntervalSince1970.isFinite,
          readiness(for: candidate, now: now) == .ready
    else { throw ClaudeCodeLoginError.unusableCredentials }

    if let stored {
      let expected = identity(from: stored)
      let hasIdentityMetadata = stored[CredentialField.anthropicAccountID] != nil
        || stored[CredentialField.anthropicOrganizationID] != nil
      guard !hasIdentityMetadata || expected != nil else { throw ClaudeCodeLoginError.identityMismatch }
      if let expected {
        guard expected.accountID == candidateIdentity.accountID,
              expected.organizationID == candidateIdentity.organizationID
        else { throw ClaudeCodeLoginError.identityMismatch }
      }
    }
    guard !existingIdentities.contains(where: {
      $0.accountID == candidateIdentity.accountID && $0.organizationID == candidateIdentity.organizationID
    }) else { throw ClaudeCodeLoginError.duplicateAccount }

    return storedCredentials(token: candidate, identity: candidateIdentity, profileID: profileID)
  }

  public static func readiness(
    for credentials: ClaudeCodeCredentials?, now: Date = Date()
  ) -> ClaudeCodeCredentialReadiness {
    guard let credentials, !credentials.accessToken.isEmpty else { return .missing }
    // Older imports lack an expiry. Try usage once; authentication failure can
    // request renewal, rather than spawning a CLI on every quota refresh.
    guard let expiresAt = credentials.expiresAt else { return .ready }
    return expiresAt <= now.addingTimeInterval(renewalLeadTime) ? .renewalRequired : .ready
  }

  /// Adopt only a newly persisted, fresher token for the original account,
  /// organization, and profile. An unverified legacy import cannot opt itself in
  /// to automatic replacement just because another CLI login was discovered.
  public static func adoption(
    for stored: [String: String], credentials candidate: ClaudeCodeCredentials,
    identity candidateIdentity: ClaudeCodeIdentity, profileID: UUID?, now: Date = Date()
  ) -> [String: String]? {
    guard let storedIdentity = identity(from: stored),
          storedIdentity.accountID == candidateIdentity.accountID,
          storedIdentity.organizationID == candidateIdentity.organizationID,
          !candidate.accessToken.isEmpty,
          candidate.accessToken != stored[CredentialField.anthropicAccessToken],
          let candidateExpiry = candidate.expiresAt, candidateExpiry > now
    else { return nil }

    if let profileID {
      guard profile(from: stored)?.id == profileID else { return nil }
    } else {
      guard stored[CredentialField.anthropicCredentialSource] == ClaudeCodeCredentialSource.linkedImport.rawValue,
            stored[CredentialField.anthropicProfileID] == nil
      else { return nil }
    }
    if let storedExpiry = credentials(from: stored)?.expiresAt, candidateExpiry <= storedExpiry {
      return nil
    }

    var updated = stored
    let replacement = storedCredentials(token: candidate, identity: candidateIdentity, profileID: profileID)
    for key in metadataKeys { updated[key] = replacement[key] }
    updated[CredentialField.anthropicAccessToken] = candidate.accessToken
    return updated
  }

  private static func oauthObject(_ data: Data) -> [String: Any]? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    if let nested = object["claudeAiOauth"] ?? object["claude_ai_oauth"] {
      return nested as? [String: Any]
    }
    return object
  }

  private static func nonemptyString(_ value: Any?) -> String? {
    (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
  }

  private static func uuid(_ value: Any?) -> UUID? {
    nonemptyString(value).flatMap(UUID.init(uuidString:))
  }

  private static func epoch(_ value: Any?) -> Date? {
    let numeric: Double?
    if let value = value as? String {
      numeric = Double(value)
    } else if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
      numeric = value.doubleValue
    } else {
      numeric = nil
    }
    guard let numeric, numeric.isFinite, numeric > 0 else { return nil }
    // Claude Code persists milliseconds; imported credential formats also use
    // epoch seconds. Both are well below this threshold for real token lifetimes.
    return Date(timeIntervalSince1970: numeric > 100_000_000_000 ? numeric / 1000 : numeric)
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
