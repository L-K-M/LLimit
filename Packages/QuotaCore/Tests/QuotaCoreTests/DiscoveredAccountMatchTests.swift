import Foundation
import XCTest
@testable import QuotaCore

final class DiscoveredAccountMatchTests: XCTestCase {
  // Authentication strings below are inert fixtures for local comparison tests.
  private func discovered(_ provider: QuotaProvider, _ credentials: [String: String]) -> DiscoveredCredential {
    DiscoveredCredential(stableID: "inert-discovery", provider: provider, suggestedName: "Imported fixture",
      sourceLabel: "Offline fixture", credentials: credentials)
  }

  func testMatchingPrimaryAuthenticationSurvivesNonAuthenticationSettingChanges() {
    let junie = discovered(.junie, [CredentialField.junieAPIKey: "same-key-fixture", CredentialField.junieCreditAllowance: "35"])
    XCTAssertTrue(junie.matchesStoredAccount(ProviderAccount(provider: .junie, credentials: [
      CredentialField.junieAPIKey: "same-key-fixture", CredentialField.junieCreditAllowance: "70"
    ])))
    let claude = discovered(.anthropic, [CredentialField.anthropicAccessToken: "same-access-fixture",
      CredentialField.anthropicEmail: "new@example.test"])
    XCTAssertTrue(claude.matchesStoredAccount(ProviderAccount(provider: .anthropic, credentials: [
      CredentialField.anthropicAccessToken: "same-access-fixture", CredentialField.anthropicEmail: "old@example.test"
    ])))
  }

  func testMatchingCredentialValueNeverCrossesProviderBoundary() {
    let candidate = discovered(.zhipu, [CredentialField.zhipuAPIKey: "shared-value-fixture"])
    XCTAssertFalse(candidate.matchesStoredAccount(ProviderAccount(provider: .zai, credentials: [
      CredentialField.zaiAPIKey: "shared-value-fixture"
    ])))
  }

  func testNonSecretMetadataCannotHideAnAccountWithDifferentAuthentication() {
    let cases: [(QuotaProvider, String, String, String)] = [
      (.gitHubCopilot, CredentialField.copilotPATToken, CredentialField.copilotUsername, "same-user"),
      (.googleAntigravity, CredentialField.googleRefreshToken, CredentialField.googleEmail, "same@example.test"),
      (.googleAntigravity, CredentialField.googleRefreshToken, CredentialField.googleProjectID, "same-project"),
      (.devin, CredentialField.devinAPIKey, CredentialField.devinAPIServer, "https://server.codeium.com"),
      (.junie, CredentialField.junieAPIKey, CredentialField.junieCreditAllowance, "35")
    ]
    for (provider, authenticationKey, metadataKey, sharedMetadata) in cases {
      let candidate = discovered(provider, [authenticationKey: "new-auth-fixture", metadataKey: sharedMetadata])
      let account = ProviderAccount(provider: provider, credentials: [authenticationKey: "old-auth-fixture", metadataKey: sharedMetadata])
      XCTAssertFalse(candidate.matchesStoredAccount(account), "Metadata key: \(metadataKey)")
    }
  }

  func testSharedRefreshGrantDoesNotReplacePrimaryAccessTokenMatching() {
    for (provider, accessKey, refreshKey) in [
      (QuotaProvider.openAI, CredentialField.openAIAccessToken, CredentialField.openAIRefreshToken),
      (.kimi, CredentialField.kimiAPIKey, CredentialField.kimiRefreshToken)
    ] {
      let candidate = discovered(provider, [accessKey: "new-access-fixture", refreshKey: "shared-refresh-fixture"])
      let account = ProviderAccount(provider: provider, credentials: [
        accessKey: "old-access-fixture", refreshKey: "shared-refresh-fixture"
      ])
      XCTAssertFalse(candidate.matchesStoredAccount(account), "Provider: \(provider)")
    }
  }

  func testEmptyAndEnvironmentReferenceAuthenticationNeverMatches() {
    for value in ["", " ", "\n", "env:FIXTURE_JUNIE_KEY"] {
      let candidate = discovered(.junie, [CredentialField.junieAPIKey: value])
      let account = ProviderAccount(provider: .junie, credentials: [CredentialField.junieAPIKey: value])
      XCTAssertFalse(candidate.matchesStoredAccount(account), "An unresolved or empty credential cannot identify an account")
    }
  }

  func testAuthenticationMustMatchAtTheSameCredentialKey() {
    let candidate = discovered(.kimi, [CredentialField.kimiAPIKey: "cross-key-fixture"])
    let account = ProviderAccount(provider: .kimi, credentials: [
      CredentialField.kimiAPIKey: "different-access-fixture", CredentialField.kimiRefreshToken: "cross-key-fixture"
    ])
    XCTAssertFalse(candidate.matchesStoredAccount(account))
  }

  func testOpenAIAccessTokenAlsoBindsTheWorkspaceAccountID() {
    let candidate = discovered(.openAI, [CredentialField.openAIAccessToken: "shared-access-fixture",
      CredentialField.openAIAccountID: "work-account"])
    XCTAssertTrue(candidate.matchesStoredAccount(ProviderAccount(provider: .openAI, credentials: [
      CredentialField.openAIAccessToken: "shared-access-fixture", CredentialField.openAIAccountID: "work-account"
    ])))
    XCTAssertFalse(candidate.matchesStoredAccount(ProviderAccount(provider: .openAI, credentials: [
      CredentialField.openAIAccessToken: "shared-access-fixture", CredentialField.openAIAccountID: "personal-account"
    ])))
  }

  func testGoogleRefreshGrantAlsoBindsTheQuotaProject() {
    let candidate = discovered(.googleAntigravity, [CredentialField.googleRefreshToken: "same-refresh-fixture",
      CredentialField.googleProjectID: "project-one", CredentialField.googleEmail: "new@example.test"])
    XCTAssertTrue(candidate.matchesStoredAccount(ProviderAccount(provider: .googleAntigravity, credentials: [
      CredentialField.googleRefreshToken: "same-refresh-fixture", CredentialField.googleProjectID: "project-one",
      CredentialField.googleEmail: "old@example.test"
    ])))
    XCTAssertFalse(candidate.matchesStoredAccount(ProviderAccount(provider: .googleAntigravity, credentials: [
      CredentialField.googleRefreshToken: "same-refresh-fixture", CredentialField.googleProjectID: "project-two"
    ])))
  }

  func testDevinServerUsesTheDefaultWhenOmittedAndSeparatesOtherEndpoints() {
    let implicit = discovered(.devin, [CredentialField.devinAPIKey: "same-devin-fixture"])
    let explicit = discovered(.devin, [CredentialField.devinAPIKey: "same-devin-fixture",
      CredentialField.devinAPIServer: "https://server.codeium.com"])
    XCTAssertTrue(implicit.matchesStoredAccount(ProviderAccount(provider: .devin, credentials: explicit.credentials)))
    XCTAssertTrue(explicit.matchesStoredAccount(ProviderAccount(provider: .devin, credentials: implicit.credentials)))
    XCTAssertFalse(implicit.matchesStoredAccount(ProviderAccount(provider: .devin, credentials: [
      CredentialField.devinAPIKey: "same-devin-fixture", CredentialField.devinAPIServer: "https://enterprise.example.test"
    ])))
  }

  func testCopilotPATMatchingRequiresTheSameCaseInsensitiveUsername() {
    let candidate = discovered(.gitHubCopilot, [CredentialField.copilotPATToken: "same-pat-fixture",
      CredentialField.copilotUsername: "FixtureUser"])
    XCTAssertTrue(candidate.matchesStoredAccount(ProviderAccount(provider: .gitHubCopilot, credentials: [
      CredentialField.copilotPATToken: "same-pat-fixture", CredentialField.copilotUsername: "fixtureuser"
    ])))
    XCTAssertFalse(candidate.matchesStoredAccount(ProviderAccount(provider: .gitHubCopilot, credentials: [
      CredentialField.copilotPATToken: "same-pat-fixture", CredentialField.copilotUsername: "another-user"
    ])))
  }

  func testActiveCopilotPATModeTakesPrecedenceOverLeftoverOAuth() {
    let candidate = discovered(.gitHubCopilot, [CredentialField.copilotPATToken: "new-pat-fixture",
      CredentialField.copilotUsername: "fixture-user", CredentialField.copilotOAuthToken: "shared-oauth-fixture"])
    let account = ProviderAccount(provider: .gitHubCopilot, credentials: [
      CredentialField.copilotPATToken: "old-pat-fixture", CredentialField.copilotUsername: "fixture-user",
      CredentialField.copilotOAuthToken: "shared-oauth-fixture"
    ])
    XCTAssertFalse(candidate.matchesStoredAccount(account))
    XCTAssertFalse(discovered(.gitHubCopilot, [CredentialField.copilotOAuthToken: "shared-oauth-fixture"])
      .matchesStoredAccount(account))
    XCTAssertTrue(candidate.matchesStoredAccount(ProviderAccount(provider: .gitHubCopilot, credentials: [
      CredentialField.copilotPATToken: "new-pat-fixture", CredentialField.copilotUsername: "fixture-user",
      CredentialField.copilotOAuthToken: "different-oauth-fixture"
    ])))
    let oauth = discovered(.gitHubCopilot, [CredentialField.copilotOAuthToken: "shared-oauth-fixture"])
    // CopilotClient chooses PAT mode from raw nonempty fields, even when invalid.
    // A leftover OAuth token therefore does not identify the active connection.
    for (pat, username) in [(" ", "fixture-user"), ("pat-fixture", " ")] {
      XCTAssertFalse(oauth.matchesStoredAccount(ProviderAccount(provider: .gitHubCopilot, credentials: [
        CredentialField.copilotPATToken: pat, CredentialField.copilotUsername: username,
        CredentialField.copilotOAuthToken: "shared-oauth-fixture"
      ])), "Raw PAT/username fields must retain PAT mode")
    }
  }

  func testManagedPrivateProfilesAreSeparateFromGlobalImports() {
    let profileID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    var codex = CodexAccountProfile(id: profileID).credentials(identity: CodexAccountIdentity(accountID: "workspace", userID: "member"))
    codex[CredentialField.openAIAccessToken] = "same-codex-access-fixture"
    XCTAssertFalse(discovered(.openAI, [CredentialField.openAIAccessToken: "same-codex-access-fixture",
      CredentialField.openAIAccountID: "workspace"]).matchesStoredAccount(ProviderAccount(provider: .openAI, credentials: codex)))

    let claude = ClaudeCodeProfile.storedCredentials(
      token: ClaudeCodeCredentials(accessToken: "same-claude-access-fixture", expiresAt: nil),
      identity: ClaudeCodeIdentity(accountID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        organizationID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!), profileID: profileID)
    XCTAssertFalse(discovered(.anthropic, [CredentialField.anthropicAccessToken: "same-claude-access-fixture"])
      .matchesStoredAccount(ProviderAccount(provider: .anthropic, credentials: claude)))
  }

  func testIncompleteManagedClaudeMetadataDoesNotTurnCachedTokensIntoGlobalImports() {
    let candidate = discovered(.anthropic, [CredentialField.anthropicAccessToken: "cached-claude-fixture"])
    var credentials = [CredentialField.anthropicAccessToken: "cached-claude-fixture",
      CredentialField.anthropicCredentialSource: ClaudeCodeCredentialSource.managedProfile.rawValue]
    XCTAssertFalse(candidate.matchesStoredAccount(ProviderAccount(provider: .anthropic, credentials: credentials)))
    credentials[CredentialField.anthropicProfileID] = "malformed-profile-fixture"
    XCTAssertFalse(candidate.matchesStoredAccount(ProviderAccount(provider: .anthropic, credentials: credentials)))

    credentials[CredentialField.anthropicProfileID] = nil
    credentials[CredentialField.anthropicCredentialSource] = ClaudeCodeCredentialSource.linkedImport.rawValue
    XCTAssertTrue(candidate.matchesStoredAccount(ProviderAccount(provider: .anthropic, credentials: credentials)))
  }
}
