import XCTest
@testable import QuotaCore

final class CodexAccountProfileTests: XCTestCase {
  private let namespace = "https://api.openai.com/auth"

  func testParsesMatchingUserAndWorkspaceWithoutCopyingTokens() throws {
    let profile = CodexAccountProfile()
    let identity = try CodexAccountProfile.parseIdentity(auth(
      idClaims: [namespace: ["chatgpt_account_id": "workspace", "chatgpt_user_id": "member"], "sub": "login-subject", "email": " a@example.test "],
      accessClaims: [namespace: ["chatgpt_account_id": "workspace", "user_id": "member"]]))
    XCTAssertEqual(identity, CodexAccountIdentity(accountID: "workspace", userID: "member", email: "a@example.test"))
    let credentials = profile.credentials(identity: identity)
    XCTAssertEqual(Set(credentials.keys), [CredentialField.openAICodexProfileID, CredentialField.openAIAccountID, CredentialField.openAICodexUserID, CredentialField.openAICodexEmail])
    XCTAssertEqual(CodexAccountProfile.profile(from: credentials), profile)
    XCTAssertEqual(CodexAccountProfile.identity(from: credentials), identity)
    XCTAssertFalse(try String(decoding: JSONEncoder().encode(credentials), as: UTF8.self).contains("sensitive"))
  }

  func testIDTokenSubjectIsStableUserFallback() throws {
    let identity = try CodexAccountProfile.parseIdentity(auth(idClaims: ["sub": "subject"], accessClaims: [:]))
    XCTAssertEqual(identity.userID, "subject")
    XCTAssertEqual(identity.accountID, "workspace")
    XCTAssertNil(identity.email)
  }

  func testJWTAccountIdentityCanReplaceMissingExplicitAccountID() throws {
    let identity = try CodexAccountProfile.parseIdentity(auth(
      idClaims: ["sub": "subject"],
      accessClaims: [namespace: ["chatgpt_account_id": "workspace"]], accountID: nil))
    XCTAssertEqual(identity.accountID, "workspace")
  }

  func testAccountIDsMustAgreeAcrossBothTokensAndExplicitMetadata() throws {
    let invalidFiles = [
      auth(idClaims: ["sub": "subject", namespace: ["chatgpt_account_id": "other"]], accessClaims: [:]),
      auth(idClaims: ["sub": "subject"], accessClaims: [namespace: ["chatgpt_account_id": "other"]]),
      auth(idClaims: ["sub": "subject", namespace: ["chatgpt_account_id": "one"]], accessClaims: [namespace: ["chatgpt_account_id": "two"]], accountID: nil)
    ]
    for data in invalidFiles { assertUnusable(data) }
  }

  func testUserClaimsMustAgreeAcrossTokensAndAliases() throws {
    assertUnusable(auth(
      idClaims: [namespace: ["chatgpt_user_id": "one"]],
      accessClaims: [namespace: ["chatgpt_user_id": "two"]]))
    assertUnusable(auth(
      idClaims: [namespace: ["chatgpt_user_id": "one", "user_id": "two"]], accessClaims: [:]))
  }

  func testRejectsMissingMalformedAndAPIKeyCredentialsWithoutEchoingInput() throws {
    let inputs = [
      "", "sensitive malformed input", "[]", "{}",
      #"{"OPENAI_API_KEY":"sensitive-api-key"}"#,
      #"{"tokens":{"access_token":"sensitive-access","id_token":"not-a-jwt","account_id":"workspace"}}"#,
      #"{"tokens":{"access_token":"","id_token":"sensitive-invalid","account_id":"workspace"}}"#
    ]
    for input in inputs { assertUnusable(Data(input.utf8)) }
    assertUnusable(auth(idClaims: [:], accessClaims: [:]))
    assertUnusable(auth(idClaims: ["sub": "subject"], accessClaims: [:], accountID: nil))
    assertUnusable(auth(idClaims: ["sub": "subject"], accessClaims: [:], accountID: " workspace"))
    assertUnusable(auth(idClaims: ["sub": "subject\n"], accessClaims: [:]))
    assertUnusable(auth(idClaims: ["sub": "subject", namespace: "sensitive-invalid"], accessClaims: [:]))
    var apiKeyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: auth(idClaims: ["sub": "subject"], accessClaims: [:])) as? [String: Any])
    apiKeyObject["auth_mode"] = "apikey"
    assertUnusable(try JSONSerialization.data(withJSONObject: apiKeyObject))
  }

  func testMalformedMarkerRemainsManagedAndCannotFallBackToImports() {
    for marker in ["", "../../another-profile", "invalid"] {
      let credentials = [CredentialField.openAICodexProfileID: marker]
      XCTAssertTrue(CodexAccountProfile.isManaged(credentials))
      XCTAssertNil(CodexAccountProfile.profile(from: credentials))
    }
    XCTAssertFalse(CodexAccountProfile.isManaged([:]))
  }

  func testProfilesHaveIndependentDirectoriesUnderSuppliedRoot() {
    let root = URL(fileURLWithPath: "/private/profiles", isDirectory: true)
    let first = CodexAccountProfile()
    let second = CodexAccountProfile()
    XCTAssertNotEqual(first.directory(under: root), second.directory(under: root))
    XCTAssertEqual(first.directory(under: root).lastPathComponent, first.id.uuidString.lowercased())
    XCTAssertEqual(first.directory(under: root).deletingLastPathComponent().path, root.path)
  }

  func testReconnectBindsUserAndWorkspaceButAllowsChangedEmail() throws {
    let old = CodexAccountProfile().credentials(identity: CodexAccountIdentity(accountID: "workspace", userID: "member", email: "old@example.test"))
    let profile = CodexAccountProfile()
    let identity = CodexAccountIdentity(accountID: "workspace", userID: "member", email: "new@example.test")
    let updated = try profile.loginCredentials(for: old, identity: identity)
    XCTAssertEqual(CodexAccountProfile.identity(from: updated), identity)
    XCTAssertEqual(CodexAccountProfile.profile(from: updated), profile)
    for different in [CodexAccountIdentity(accountID: "other", userID: "member"), CodexAccountIdentity(accountID: "workspace", userID: "other")] {
      XCTAssertThrowsError(try profile.loginCredentials(for: old, identity: different)) {
        XCTAssertEqual($0 as? CodexAccountProfileError, .identityMismatch)
      }
    }
  }

  func testFirstLoginAcceptsDefaultEmptyManualFields() throws {
    let identity = CodexAccountIdentity(accountID: "workspace", userID: "member")
    let profile = CodexAccountProfile()
    let updated = try profile.loginCredentials(for: [
      CredentialField.openAIAccessToken: "", CredentialField.openAIAccountID: "", CredentialField.openAIRefreshToken: ""
    ], identity: identity)
    XCTAssertEqual(updated, profile.credentials(identity: identity))
  }

  func testConnectingImportedAccountPreservesItsExistingWorkspaceBinding() throws {
    let identity = CodexAccountIdentity(accountID: "workspace", userID: "member")
    let profile = CodexAccountProfile()
    XCTAssertNoThrow(try profile.loginCredentials(for: [CredentialField.openAIAccountID: "workspace"], identity: identity))
    for accountID in ["other-workspace", " ", " workspace"] {
      XCTAssertThrowsError(try profile.loginCredentials(for: [CredentialField.openAIAccountID: accountID], identity: identity)) {
        XCTAssertEqual($0 as? CodexAccountProfileError, .identityMismatch)
      }
    }
  }

  func testMalformedManagedReconnectFailsClosed() throws {
    let candidate = CodexAccountIdentity(accountID: "workspace", userID: "member")
    let profile = CodexAccountProfile()
    var old = profile.credentials(identity: candidate)
    old[CredentialField.openAICodexUserID] = nil
    XCTAssertThrowsError(try profile.loginCredentials(for: old, identity: candidate))
    old = profile.credentials(identity: candidate)
    old[CredentialField.openAICodexProfileID] = "malformed"
    XCTAssertThrowsError(try profile.loginCredentials(for: old, identity: candidate))
  }

  func testDuplicateDetectionBindsUserAndWorkspaceInsteadOfEmail() throws {
    let profile = CodexAccountProfile()
    let identity = CodexAccountIdentity(accountID: "workspace", userID: "member", email: "a@example.test")
    XCTAssertThrowsError(try profile.loginCredentials(for: nil, identity: identity, existingIdentities: [
      CodexAccountIdentity(accountID: "workspace", userID: "member", email: "changed@example.test")
    ])) {
      XCTAssertEqual($0 as? CodexAccountProfileError, .duplicateAccount)
    }
    XCTAssertNoThrow(try profile.loginCredentials(for: nil, identity: identity, existingIdentities: [
      CodexAccountIdentity(accountID: "other-workspace", userID: "member", email: "a@example.test"),
      CodexAccountIdentity(accountID: "workspace", userID: "another-member", email: "a@example.test")
    ]))
  }

  func testManagedCredentialMetadataRedactsLikeOtherCredentials() throws {
    var settings = AppSettings.default
    settings.accounts = [ProviderAccount(provider: .openAI, credentials: CodexAccountProfile().credentials(
      identity: CodexAccountIdentity(accountID: "workspace", userID: "member", email: "private@example.test")))]
    XCTAssertTrue(settings.redactedCredentials().accounts[0].credentials.isEmpty)
  }

  func testManagedReadinessRequiresProfileAndIdentityInsteadOfToken() {
    let metadata = CodexAccountProfile().credentials(identity: CodexAccountIdentity(accountID: "workspace", userID: "member"))
    XCTAssertTrue(ProviderAccount(provider: .openAI, credentials: metadata).hasRequiredCredentials)
    for missingKey in [CredentialField.openAIAccountID, CredentialField.openAICodexUserID] {
      var incomplete = metadata
      incomplete[missingKey] = nil
      incomplete[CredentialField.openAIAccessToken] = "stale-copy"
      let account = ProviderAccount(provider: .openAI, credentials: incomplete)
      XCTAssertFalse(account.hasRequiredCredentials)
      XCTAssertEqual(account.missingCredentialLabels, ["Reconnect OpenAI"])
    }
    var invalid = metadata
    invalid[CredentialField.openAICodexProfileID] = "malformed"
    XCTAssertFalse(ProviderAccount(provider: .openAI, credentials: invalid).hasRequiredCredentials)
    XCTAssertTrue(ProviderAccount(provider: .openAI, credentials: [CredentialField.openAIAccessToken: "manual"]).hasRequiredCredentials)
  }

  private func auth(idClaims: [String: Any], accessClaims: [String: Any], accountID: String? = "workspace") -> Data {
    var tokens = ["id_token": jwt(idClaims), "access_token": jwt(accessClaims), "refresh_token": "sensitive-refresh"]
    tokens["account_id"] = accountID
    return try! JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": tokens])
  }

  private func jwt(_ claims: [String: Any]) -> String {
    let payload = try! JSONSerialization.data(withJSONObject: claims).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return "header.\(payload).sensitive-signature"
  }

  private func assertUnusable(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try CodexAccountProfile.parseIdentity(data), file: file, line: line) {
      XCTAssertEqual($0 as? CodexAccountProfileError, .unusableCredentials, file: file, line: line)
      XCTAssertFalse($0.localizedDescription.contains("sensitive"), file: file, line: line)
    }
  }
}
