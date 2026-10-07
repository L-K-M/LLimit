import Foundation
import XCTest
@testable import QuotaCore

final class ClaudeCodeProfileTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private let profileID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  private let otherProfileID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
  private let accountID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
  private let otherAccountID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
  private let organizationID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
  private let otherOrganizationID = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!

  private var identity: ClaudeCodeIdentity {
    ClaudeCodeIdentity(accountID: accountID, organizationID: organizationID, email: "one@example.com")
  }

  private func token(_ access: String, expiresIn interval: TimeInterval? = 3600) -> ClaudeCodeCredentials {
    ClaudeCodeCredentials(accessToken: access, expiresAt: interval.map { now.addingTimeInterval($0) })
  }

  private var stored: [String: String] {
    ClaudeCodeProfile.storedCredentials(token: token("old"), identity: identity, profileID: profileID)
  }

  func testGlobalLoginCannotReplaceManagedProfileToken() {
    XCTAssertNil(ClaudeCodeProfile.adoption(
      for: stored, credentials: token("global", expiresIn: 7200), identity: identity,
      profileID: nil, now: now))
  }

  func testAnotherAccountOrOrganizationCannotReplaceToken() {
    for mismatch in [
      ClaudeCodeIdentity(accountID: otherAccountID, organizationID: organizationID),
      ClaudeCodeIdentity(accountID: accountID, organizationID: otherOrganizationID)
    ] {
      XCTAssertNil(ClaudeCodeProfile.adoption(
        for: stored, credentials: token("other", expiresIn: 7200), identity: mismatch,
        profileID: profileID, now: now))
    }
  }

  func testAnotherProfileCannotReplaceTokenEvenForSameIdentity() {
    XCTAssertNil(ClaudeCodeProfile.adoption(
      for: stored, credentials: token("other", expiresIn: 7200), identity: identity,
      profileID: otherProfileID, now: now))
  }

  func testUnverifiedLegacyTokenCannotBeAutomaticallyReplaced() {
    XCTAssertNil(ClaudeCodeProfile.adoption(
      for: [CredentialField.anthropicAccessToken: "old"], credentials: token("global"),
      identity: identity, profileID: nil, now: now))
  }

  func testNewerTokenIsAdoptedOnlyForMatchingProfileAndIdentity() throws {
    var pending = stored
    pending[CredentialField.anthropicRenewalPending] = "true"
    let updated = try XCTUnwrap(ClaudeCodeProfile.adoption(
      for: pending, credentials: token("new", expiresIn: 7200), identity: identity,
      profileID: profileID, now: now))
    XCTAssertEqual(updated[CredentialField.anthropicAccessToken], "new")
    XCTAssertEqual(ClaudeCodeProfile.identity(from: updated), identity)
    XCTAssertEqual(ClaudeCodeProfile.profile(from: updated)?.id, profileID)
    XCTAssertEqual(ClaudeCodeProfile.credentials(from: updated)?.expiresAt, now.addingTimeInterval(7200))
    XCTAssertNil(updated[CredentialField.anthropicRenewalPending])
  }

  func testExpiredStaleAndUnknownExpiryTokensCannotDowngradeStoredToken() {
    for interval: TimeInterval? in [-1, 3000, 3600, nil] {
      XCTAssertNil(ClaudeCodeProfile.adoption(
        for: stored, credentials: token("candidate", expiresIn: interval), identity: identity,
        profileID: profileID, now: now))
    }
  }

  func testUnchangedTokenIsNotEvidenceThatRenewalCompleted() {
    XCTAssertNil(ClaudeCodeProfile.adoption(
      for: stored, credentials: token("old", expiresIn: 7200), identity: identity,
      profileID: profileID, now: now))
  }

  func testLinkedImportRequiresIdentityAndCannotTakeManagedProfileToken() throws {
    let imported = ClaudeCodeProfile.storedCredentials(token: token("old"), identity: identity, profileID: nil)
    XCTAssertNotNil(ClaudeCodeProfile.adoption(
      for: imported, credentials: token("new", expiresIn: 7200), identity: identity,
      profileID: nil, now: now))
    XCTAssertNil(ClaudeCodeProfile.adoption(
      for: imported, credentials: token("new", expiresIn: 7200), identity: identity,
      profileID: profileID, now: now))
  }

  func testParsesCamelCaseCredentialsWithoutRetainingRefreshToken() throws {
    let data = Data(#"{"claudeAiOauth":{"accessToken":"access","refreshToken":"never-copy","expiresAt":1800003600000}}"#.utf8)
    let credentials = try XCTUnwrap(ClaudeCodeProfile.parseCredentials(data))
    XCTAssertEqual(credentials, token("access"))
    let stored = ClaudeCodeProfile.storedCredentials(token: credentials, identity: identity, profileID: profileID)
    XCTAssertFalse(stored.values.contains("never-copy"))
    XCTAssertFalse(stored.keys.contains { $0.lowercased().contains("refresh") })
  }

  func testParsesSnakeCaseAndFlatCredentialsWithEpochSeconds() {
    for json in [
      #"{"claude_ai_oauth":{"access_token":"access","expires_at":"1800003600"}}"#,
      #"{"access_token":"access","expires_at":1800003600}"#
    ] {
      XCTAssertEqual(ClaudeCodeProfile.parseCredentials(Data(json.utf8)), token("access"))
    }
  }

  func testParsesEphemeralRenewalMaterialWithScopesArrayOrString() {
    for scopes in [#"["user:profile","user:inference"]"#, #""user:profile user:inference""#] {
      let json = "{\"claudeAiOauth\":{\"refreshToken\":\"secret\",\"scopes\":\(scopes)}}"
      XCTAssertEqual(ClaudeCodeProfile.parseRenewalMaterial(Data(json.utf8)),
                     ClaudeCodeRenewalMaterial(refreshToken: "secret", scopes: ["user:profile", "user:inference"]))
    }
    let snake = #"{"refresh_token":"secret","scopes":["user:profile"]}"#
    XCTAssertEqual(ClaudeCodeProfile.parseRenewalMaterial(Data(snake.utf8))?.refreshToken, "secret")
  }

  func testRenewalRequiresBothRefreshTokenAndScopes() {
    for json in ["{}", #"{"refreshToken":"secret"}"#, #"{"refreshToken":"secret","scopes":[]}"#,
                 #"{"refreshToken":" ","scopes":["user:profile"]}"#] {
      XCTAssertNil(ClaudeCodeProfile.parseRenewalMaterial(Data(json.utf8)))
    }
  }

  func testRejectsMalformedNestedCredentialsInsteadOfUsingUnrelatedFlatToken() {
    let data = Data(#"{"claudeAiOauth":null,"accessToken":"unrelated","refreshToken":"unrelated","scopes":["user:profile"]}"#.utf8)
    XCTAssertNil(ClaudeCodeProfile.parseCredentials(data))
    XCTAssertNil(ClaudeCodeProfile.parseRenewalMaterial(data))
  }

  func testRejectsMalformedRenewalScopeArrayWithoutSilentlyDroppingElements() {
    for scopes in [#"["user:profile",""]"#, #"["user:profile user:inference"]"#,
                   #"["user:profile",5]"#, #""user:profile\u0000""#] {
      let json = "{\"refreshToken\":\"secret\",\"scopes\":\(scopes)}"
      XCTAssertNil(ClaudeCodeProfile.parseRenewalMaterial(Data(json.utf8)))
    }
  }

  func testRejectsMissingTokenAndTreatsInvalidExpiryAsUnknown() {
    for json in ["{}", #"{"accessToken":" "}"#, "not json"] {
      XCTAssertNil(ClaudeCodeProfile.parseCredentials(Data(json.utf8)))
    }
    for expiry in ["0", "-1", "true", #""garbage""#] {
      let json = "{\"accessToken\":\"access\",\"expiresAt\":\(expiry)}"
      XCTAssertEqual(ClaudeCodeProfile.parseCredentials(Data(json.utf8)), token("access", expiresIn: nil))
    }
  }

  func testParsesAccountAndOrganizationIdentityFromCLIConfig() throws {
    let json = """
      {"oauthAccount":{"accountUuid":"\(accountID)","organizationUuid":"\(organizationID)","emailAddress":"one@example.com"}}
      """
    XCTAssertEqual(ClaudeCodeProfile.parseIdentity(Data(json.utf8)), identity)
  }

  func testRejectsIncompleteOrMalformedIdentity() {
    for json in [
      "{}", #"{"oauthAccount":{"emailAddress":"one@example.com"}}"#,
      "{\"oauthAccount\":{\"accountUuid\":\"\(accountID)\"}}",
      #"{"oauthAccount":{"accountUuid":"invalid","organizationUuid":"invalid"}}"#
    ] {
      XCTAssertNil(ClaudeCodeProfile.parseIdentity(Data(json.utf8)))
    }
  }

  func testRenewalPolicyUsesFiveMinuteSafetyWindow() {
    XCTAssertEqual(ClaudeCodeProfile.readiness(for: token("token", expiresIn: 301), now: now), .ready)
    for interval: TimeInterval in [300, 0, -1] {
      XCTAssertEqual(ClaudeCodeProfile.readiness(for: token("token", expiresIn: interval), now: now), .renewalRequired)
    }
    XCTAssertEqual(ClaudeCodeProfile.readiness(for: nil, now: now), .missing)
    XCTAssertEqual(ClaudeCodeProfile.readiness(for: token(" "), now: now), .missing)
    XCTAssertEqual(ClaudeCodeProfile.readiness(for: token("token", expiresIn: nil), now: now), .ready)
  }

  func testProfilePathIsDerivedOnlyFromValidatedUUID() {
    let root = URL(fileURLWithPath: "/private/test/ClaudeProfiles", isDirectory: true)
    let profile = ClaudeCodeProfile(id: profileID)
    XCTAssertEqual(profile.directory(under: root).deletingLastPathComponent().path, root.path)
    XCTAssertEqual(profile.directory(under: root).lastPathComponent, profileID.uuidString.lowercased())
    var malicious = stored
    malicious[CredentialField.anthropicProfileID] = "../../.claude"
    XCTAssertNil(ClaudeCodeProfile.profile(from: malicious))
  }

  func testManualTokenEditCanDetachProfileWithoutRemovingToken() {
    var credentials = stored
    credentials["unrelated"] = "retained"
    credentials[CredentialField.anthropicRenewalPending] = "true"
    XCTAssertEqual(ClaudeCodeProfile.clearManagedMetadata(from: credentials), [
      CredentialField.anthropicAccessToken: "old", "unrelated": "retained"
    ])
  }

  func testAutomaticAdoptionCannotReplaceEnvironmentManagedToken() {
    var external = stored
    external[CredentialField.anthropicAccessToken] = "env:CLAUDE_TOKEN"

    let adopted = ClaudeCodeProfile.adoption(
      for: external, credentials: token("new", expiresIn: 7200), identity: identity, profileID: profileID, now: now)

    XCTAssertNil(adopted, "The variable owner, not CLI adoption, controls this token")
    XCTAssertEqual(external[CredentialField.anthropicAccessToken], "env:CLAUDE_TOKEN")
  }

  func testAutomaticAdoptionPreservesEnvironmentMetadata() throws {
    var external = stored
    external[CredentialField.anthropicEmail] = "env:CLAUDE_EMAIL"
    let adopted = try XCTUnwrap(ClaudeCodeProfile.adoption(
      for: external, credentials: token("new", expiresIn: 7200), identity: identity, profileID: profileID, now: now))

    XCTAssertEqual(adopted[CredentialField.anthropicAccessToken], "new")
    XCTAssertEqual(adopted[CredentialField.anthropicEmail], "env:CLAUDE_EMAIL")
  }

  func testSettingsRedactionRemovesAllProfileMetadata() {
    let account = ProviderAccount(provider: .anthropic, displayName: "Claude", credentials: stored)
    let settings = AppSettings(accounts: [account])
    XCTAssertTrue(settings.redactedCredentials().accounts[0].credentials.isEmpty)
  }

  func testCompletedInitialLoginCreatesIndependentProfile() throws {
    let result = try ClaudeCodeProfile.loginCredentials(
      for: nil, credentials: token("first"), identity: identity, profileID: profileID, now: now)
    XCTAssertEqual(ClaudeCodeProfile.profile(from: result)?.id, profileID)
    XCTAssertEqual(ClaudeCodeProfile.identity(from: result), identity)
  }

  func testCompletedReconnectRetainsAccountIdentityButCanReplaceProfile() throws {
    var pending = stored
    pending[CredentialField.anthropicRenewalPending] = "true"
    let result = try ClaudeCodeProfile.loginCredentials(
      for: pending, credentials: token("reconnected"), identity: identity, profileID: otherProfileID, now: now)
    XCTAssertEqual(ClaudeCodeProfile.profile(from: result)?.id, otherProfileID)
    XCTAssertNil(result[CredentialField.anthropicRenewalPending])
  }

  func testCompletedReconnectRejectsDifferentOrMalformedStoredIdentity() {
    let different = ClaudeCodeIdentity(accountID: otherAccountID, organizationID: organizationID)
    var malformed = stored
    malformed[CredentialField.anthropicOrganizationID] = "broken"
    for candidate in [(stored, different), (malformed, identity)] {
      XCTAssertThrowsError(try ClaudeCodeProfile.loginCredentials(
        for: candidate.0, credentials: token("new"), identity: candidate.1, profileID: profileID, now: now)) {
        XCTAssertEqual($0 as? ClaudeCodeLoginError, .identityMismatch)
      }
    }
  }

  func testCompletedLoginRejectsUnknownOrNearlyExpiredCredentials() {
    for credentials in [token(" "), token("new", expiresIn: nil), token("new", expiresIn: 300),
                        token("new", expiresIn: -1)] {
      XCTAssertThrowsError(try ClaudeCodeProfile.loginCredentials(
        for: nil, credentials: credentials, identity: identity, profileID: profileID, now: now)) {
        XCTAssertEqual($0 as? ClaudeCodeLoginError, .unusableCredentials)
      }
    }
  }

  func testCompletedLoginDetectsDuplicateAccountAndOrganizationNotEmail() throws {
    let changedEmail = ClaudeCodeIdentity(accountID: accountID, organizationID: organizationID, email: "new@example.com")
    XCTAssertThrowsError(try ClaudeCodeProfile.loginCredentials(
      for: nil, credentials: token("new"), identity: changedEmail, profileID: profileID,
      existingIdentities: [identity], now: now)) {
      XCTAssertEqual($0 as? ClaudeCodeLoginError, .duplicateAccount)
    }
    let differentOrganization = ClaudeCodeIdentity(accountID: accountID, organizationID: otherOrganizationID, email: identity.email)
    XCTAssertNoThrow(try ClaudeCodeProfile.loginCredentials(
      for: nil, credentials: token("new"), identity: differentOrganization, profileID: profileID,
      existingIdentities: [identity], now: now))
  }
}
