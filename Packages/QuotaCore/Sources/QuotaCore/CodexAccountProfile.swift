import Foundation

public struct CodexAccountIdentity: Codable, Hashable, Sendable {
  public let accountID: String
  public let userID: String
  public let email: String?

  public init(accountID: String, userID: String, email: String? = nil) {
    self.accountID = accountID
    self.userID = userID
    self.email = nonEmptyString(email)
  }

  public func matches(_ other: CodexAccountIdentity) -> Bool {
    accountID == other.accountID && userID == other.userID
  }
}

public enum CodexAccountProfileError: LocalizedError, Equatable {
  case unusableCredentials
  case identityMismatch
  case duplicateAccount

  public var errorDescription: String? {
    switch self {
    case .unusableCredentials: return "Codex did not save a usable ChatGPT login. Connect OpenAI again."
    case .identityMismatch: return "This login belongs to a different OpenAI account or workspace."
    case .duplicateAccount: return "This OpenAI account and workspace are already connected."
    }
  }
}

/// The official Codex process owns the profile's authentication file. LLimit
/// stores only this profile reference and identity, never a copy of its tokens.
public struct CodexAccountProfile: Hashable, Sendable {
  public let id: UUID

  public init(id: UUID = UUID()) {
    self.id = id
  }

  public func directory(under root: URL) -> URL {
    root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
  }

  public static func isManaged(_ credentials: [String: String]) -> Bool {
    credentials[CredentialField.openAICodexProfileID] != nil
  }

  public static func profile(from credentials: [String: String]) -> CodexAccountProfile? {
    guard let rawID = credentials[CredentialField.openAICodexProfileID],
          let id = UUID(uuidString: rawID)
    else { return nil }
    return CodexAccountProfile(id: id)
  }

  public static func identity(from credentials: [String: String]) -> CodexAccountIdentity? {
    guard let accountID = identifier(credentials[CredentialField.openAIAccountID]),
          let userID = identifier(credentials[CredentialField.openAICodexUserID])
    else { return nil }
    return CodexAccountIdentity(
      accountID: accountID, userID: userID, email: credentials[CredentialField.openAICodexEmail])
  }

  /// Reads the identity from the auth file written by the same successfully
  /// authenticated app-server. Decoding claims is not signature verification;
  /// callers must establish the server's authenticated state before using them.
  public static func parseIdentity(_ data: Data) throws -> CodexAccountIdentity {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tokens = object["tokens"] as? [String: Any],
          let accessToken = nonEmptyString(tokens["access_token"]),
          let idToken = nonEmptyString(tokens["id_token"]),
          let idClaims = jwtClaims(idToken)
    else { throw CodexAccountProfileError.unusableCredentials }

    if let mode = object["auth_mode"], mode as? String != "chatgpt" {
      throw CodexAccountProfileError.unusableCredentials
    }
    if nonEmptyString(object["OPENAI_API_KEY"]) != nil {
      throw CodexAccountProfileError.unusableCredentials
    }

    let accessClaims = jwtClaims(accessToken)
    if accessToken.split(separator: ".", omittingEmptySubsequences: false).count == 3,
       accessClaims == nil {
      throw CodexAccountProfileError.unusableCredentials
    }
    let claims = [idClaims, accessClaims].compactMap { $0 }
    let authClaims = try claims.compactMap { claims -> [String: Any]? in
      guard let raw = claims["https://api.openai.com/auth"] else { return nil }
      guard let auth = raw as? [String: Any] else { throw CodexAccountProfileError.unusableCredentials }
      return auth
    }
    let accountIDs = try values(named: ["chatgpt_account_id"], in: authClaims)
      + values(named: ["account_id"], in: [tokens])
    guard let accountID = accountIDs.first, Set(accountIDs).count == 1 else {
      throw CodexAccountProfileError.unusableCredentials
    }

    let userIDs = try values(named: ["chatgpt_user_id", "user_id"], in: authClaims)
    let subject = try values(named: ["sub"], in: [idClaims]).first
    guard Set(userIDs).count <= 1, let userID = userIDs.first ?? subject else {
      throw CodexAccountProfileError.unusableCredentials
    }
    return CodexAccountIdentity(
      accountID: accountID, userID: userID, email: nonEmptyString(idClaims["email"]))
  }

  public func credentials(identity: CodexAccountIdentity) -> [String: String] {
    var result = [
      CredentialField.openAICodexProfileID: id.uuidString,
      CredentialField.openAIAccountID: identity.accountID,
      CredentialField.openAICodexUserID: identity.userID
    ]
    result[CredentialField.openAICodexEmail] = identity.email
    return result
  }

  /// The caller excludes the reconnect target from existing identities. Email
  /// is display metadata; matching always binds the stable user and workspace.
  public func loginCredentials(
    for stored: [String: String]?, identity candidate: CodexAccountIdentity,
    existingIdentities: [CodexAccountIdentity] = []
  ) throws -> [String: String] {
    guard Self.identifier(candidate.accountID) != nil, Self.identifier(candidate.userID) != nil else {
      throw CodexAccountProfileError.unusableCredentials
    }
    if let stored {
      if Self.isManaged(stored) {
        guard Self.profile(from: stored) != nil,
              let expected = Self.identity(from: stored), expected.matches(candidate)
        else { throw CodexAccountProfileError.identityMismatch }
      } else if let accountID = stored[CredentialField.openAIAccountID], !accountID.isEmpty {
        guard Self.identifier(accountID) == candidate.accountID else {
          throw CodexAccountProfileError.identityMismatch
        }
      }
    }
    guard !existingIdentities.contains(where: { $0.matches(candidate) }) else {
      throw CodexAccountProfileError.duplicateAccount
    }
    return credentials(identity: candidate)
  }

  private static func values(named keys: [String], in objects: [[String: Any]]) throws -> [String] {
    try objects.flatMap { object in
      try keys.compactMap { key in
        guard let value = object[key], !(value is NSNull) else { return nil }
        guard let parsed = identifier(value) else { throw CodexAccountProfileError.unusableCredentials }
        return parsed
      }
    }
  }

  private static func identifier(_ value: Any?) -> String? {
    guard let value = value as? String, !value.isEmpty,
          value == value.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { return nil }
    return value
  }

  private static func jwtClaims(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
    var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    guard let data = Data(base64Encoded: payload) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }
}
