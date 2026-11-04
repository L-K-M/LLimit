import Foundation
import XCTest
@testable import QuotaCore

final class CommandCodeDiscoveryTests: XCTestCase {
  private var home: URL!

  override func setUpWithError() throws {
    home = FileManager.default.temporaryDirectory.appendingPathComponent("llimit-command-code-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: home)
  }

  private func write(_ object: Any, file: String = "auth.json") throws {
    let directory = home.appendingPathComponent(".commandcode")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent(file))
  }

  private func result(environment: [String: String] = [:]) -> CredentialDiscoveryResult {
    CredentialDiscovery(homeDirectories: [home], environment: environment).discover()
  }

  func testImportsOnlyTheProductionTopLevelAPIKey() throws {
    try write([
      "apiKey": "user_inert-command-code-key", "userId": "inert-user", "userName": "Fixture account",
      "keyName": "Fixture key", "authenticatedAt": "2026-11-04T00:00:00Z",
      "anthropic": ["type": "oauth", "accessToken": "inert-access", "refreshToken": "inert-refresh"],
      "codex": ["access_token": "inert-codex", "refresh_token": "inert-codex-refresh"]
    ])
    let found = result()
    let credential = try XCTUnwrap(found.credentials.first { $0.provider == .commandCode })
    XCTAssertEqual(credential.stableID, "command-code:cli")
    XCTAssertEqual(credential.suggestedName, "Command Code")
    XCTAssertEqual(credential.sourceLabel, "Command Code (~/.commandcode/auth.json)")
    XCTAssertEqual(credential.credentials, [CredentialField.commandCodeAPIKey: "user_inert-command-code-key"])
    XCTAssertFalse(found.diagnostics.joined().contains("user_inert-command-code-key"))
    XCTAssertFalse(found.diagnostics.joined().contains("inert-refresh"))
  }

  func testIgnoresStagingLocalEnvironmentAndNestedProviderCredentials() throws {
    try write(["apiKey": "inert-staging"], file: "auth.staging.json")
    try write(["apiKey": "inert-local"], file: "auth.local.json")
    try write(["anthropic": ["apiKey": "inert-other-provider"], "providers": ["command-code": ["key": "inert-nested"]]])
    XCTAssertFalse(result(environment: ["COMMAND_CODE_API_KEY": "inert-environment-key"]).credentials.contains { $0.provider == .commandCode })
  }

  func testRejectsMalformedKeysWithoutLeakingThemIntoDiagnostics() throws {
    let values: [Any] = ["", " ", "user_key with spaces", "\tuser_key", "user_key\n", "user_key\u{0}",
                         "user_é", "env:COMMAND_CODE_API_KEY", "$COMMAND_CODE_API_KEY", "${COMMAND_CODE_API_KEY}",
                         "{env:COMMAND_CODE_API_KEY}", "!command",
                         String(repeating: "a", count: 32_769), 42, NSNull()]
    for value in values {
      try write(["apiKey": value])
      let found = result()
      XCTAssertFalse(found.credentials.contains { $0.provider == .commandCode }, "Invalid key accepted")
      XCTAssertFalse(found.diagnostics.joined().contains("user_key"))
    }
    try write(["apiKey", "inert-array"])
    XCTAssertFalse(result().credentials.contains { $0.provider == .commandCode })
  }

  func testStoredAccountMatchingUsesOnlyTheSamePrimaryKeyAndProvider() {
    let imported = DiscoveredCredential(stableID: "fixture", provider: .commandCode,
      suggestedName: "Fixture", sourceLabel: "Fixture", credentials: [CredentialField.commandCodeAPIKey: "user_inert-key"])
    XCTAssertTrue(imported.matchesStoredAccount(ProviderAccount(provider: .commandCode,
      credentials: [CredentialField.commandCodeAPIKey: "user_inert-key"], subscriptionPricing: SubscriptionPricing(amount: 20))))
    XCTAssertFalse(imported.matchesStoredAccount(ProviderAccount(provider: .commandCode,
      credentials: [CredentialField.commandCodeAPIKey: "user_other-key"])))
    XCTAssertFalse(imported.matchesStoredAccount(ProviderAccount(provider: .cline,
      credentials: [CredentialField.clineAPIKey: "user_inert-key"])))
  }

  func testProviderCatalogAndCredentialIdentityAreConsistent() {
    XCTAssertEqual(QuotaProvider.commandCode.rawValue, "command-code")
    XCTAssertEqual(QuotaProvider.commandCode.displayName, "Command Code")
    XCTAssertEqual(QuotaProvider.commandCode.credentialFields.map(\.key), [CredentialField.commandCodeAPIKey])
    XCTAssertTrue(QuotaProvider.commandCode.credentialFields.allSatisfy { $0.isSecret && $0.isRequired })
    for query in ["Command Code", "CommandCode", "commandcode.ai", "cmd"] {
      XCTAssertEqual(ProviderCatalog.search(query).map(\.provider), [.commandCode])
    }
    let usage = ProviderUsage(provider: .commandCode, title: "Fixture", metrics: [
      UsageMetric(id: "monthly-credits", label: "Monthly credits", remainingAmount: 20),
      UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 80),
      UsageMetric(id: "five-hour", label: "5-hour", remainingPercent: 70)
    ], fetchedAt: Date())
    XCTAssertEqual(defaultRingMetrics(for: usage).map(\.id), ["five-hour", "weekly"])
  }
}
