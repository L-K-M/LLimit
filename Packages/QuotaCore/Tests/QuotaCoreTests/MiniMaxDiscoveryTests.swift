import XCTest
@testable import QuotaCore

final class MiniMaxDiscoveryTests: XCTestCase {
  private var home: URL!

  override func setUpWithError() throws {
    home = FileManager.default.temporaryDirectory.appendingPathComponent("llimit-minimax-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: home)
  }

  private func write(_ object: [String: Any], directory: String = ".local/share") throws {
    let url = home.appendingPathComponent(directory).appendingPathComponent("opencode/auth.json")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: object).write(to: url)
  }

  private func discover(environment: [String: String] = [:]) -> CredentialDiscoveryResult {
    CredentialDiscovery(homeDirectories: [home], environment: environment).discover()
  }

  func testImportsExactGlobalPlanEntryAndOnlyAPIKey() throws {
    try write(["minimax-coding-plan": [
      "type": "api", "key": "  minimax-plan-fixture\n", "refresh": "unrelated-refresh-fixture"
    ]])

    let result = discover()
    let account = try XCTUnwrap(result.credentials.first { $0.provider == .minimax })
    XCTAssertEqual(account.stableID, "minimax:opencode")
    XCTAssertEqual(account.suggestedName, "MiniMax M Plan")
    XCTAssertEqual(account.sourceLabel, "OpenCode (~/.local/share/opencode/auth.json)")
    XCTAssertEqual(account.credentials, [CredentialField.minimaxAPIKey: "minimax-plan-fixture"])
    XCTAssertTrue(account.provider.hasRequiredCredentials(account.credentials))
    XCTAssertFalse(result.diagnostics.joined().contains("minimax-plan-fixture"))
    XCTAssertFalse(result.diagnostics.joined().contains("unrelated-refresh-fixture"))
  }

  func testImportsLegacyOpenCodeConfigRoot() throws {
    try write(["minimax-coding-plan": ["type": "api", "key": "legacy-plan-fixture"]],
              directory: ".config")
    let account = try XCTUnwrap(discover().credentials.first { $0.provider == .minimax })
    XCTAssertEqual(account.credentials, [CredentialField.minimaxAPIKey: "legacy-plan-fixture"])
    XCTAssertEqual(account.sourceLabel, "OpenCode (~/.config/opencode/auth.json)")
  }

  func testHonorsAbsoluteXDGDataHomeAndRedactsDiagnostics() throws {
    try write(["minimax-coding-plan": ["type": "api", "key": "xdg-plan-fixture"]],
              directory: "custom-data")
    let result = discover(environment: ["XDG_DATA_HOME": home.appendingPathComponent("custom-data").path])
    XCTAssertEqual(result.credentials.first { $0.provider == .minimax }?.credentials,
                   [CredentialField.minimaxAPIKey: "xdg-plan-fixture"])
    XCTAssertFalse(result.diagnostics.joined().contains("xdg-plan-fixture"))
  }

  func testXDGPlanEntryTakesPrecedenceOverDefaultPath() throws {
    try write(["minimax-coding-plan": ["type": "api", "key": "default-plan-fixture"]])
    try write(["minimax-coding-plan": ["type": "api", "key": "xdg-plan-fixture"]],
              directory: "custom-data")
    let result = discover(environment: ["XDG_DATA_HOME": home.appendingPathComponent("custom-data").path])
    XCTAssertEqual(result.credentials.filter { $0.provider == .minimax }.map(\.credentials),
                   [[CredentialField.minimaxAPIKey: "xdg-plan-fixture"]])
  }

  func testRelativeXDGDataHomeIsIgnored() throws {
    try write(["minimax-coding-plan": ["type": "api", "key": "default-plan-fixture"]])
    let result = discover(environment: ["XDG_DATA_HOME": "custom-data"])
    XCTAssertEqual(result.credentials.first { $0.provider == .minimax }?.credentials,
                   [CredentialField.minimaxAPIKey: "default-plan-fixture"])
  }

  func testRejectsGenericChinaAndLookalikeProviderIDs() throws {
    let providerIDs = [
      "minimax", "minimax-cn", "minimax-cn-coding-plan", "minimax-china-coding-plan",
      "minimax-coding-plan-custom", "MiniMax-Coding-Plan"
    ]
    for providerID in providerIDs {
      try write([providerID: ["type": "api", "key": "unrelated-plan-fixture"]])
      XCTAssertFalse(discover().credentials.contains { $0.provider == .minimax }, providerID)
    }
  }

  func testRejectsOAuthBlankAndMalformedPlanEntries() throws {
    let entries: [Any] = [
      ["type": "oauth", "key": "oauth-fixture", "access": "access-fixture", "refresh": "refresh-fixture"],
      ["key": "untyped-fixture"], ["type": "api", "key": " \n"],
      ["type": "api", "key": 42], ["type": "api", "key": true], NSNull(), "malformed-fixture"
    ]
    for entry in entries {
      try write(["minimax-coding-plan": entry])
      let result = discover()
      XCTAssertFalse(result.credentials.contains { $0.provider == .minimax })
      XCTAssertFalse(result.diagnostics.joined().contains("fixture"))
    }
  }

  func testDoesNotImportGenericEnvironmentKey() {
    let result = discover(environment: ["MINIMAX_API_KEY": "env-fixture"])
    XCTAssertFalse(result.credentials.contains { $0.provider == .minimax })
    XCTAssertFalse(result.diagnostics.joined().contains("env-fixture"))
  }

  func testDeduplicatesSamePlanEntryInBothOpenCodeRoots() throws {
    let object = ["minimax-coding-plan": ["type": "api", "key": "same-plan-fixture"]]
    try write(object)
    try write(object, directory: ".config")
    let accounts = discover().credentials.filter { $0.provider == .minimax }
    XCTAssertEqual(accounts.count, 1)
    XCTAssertEqual(accounts.first?.sourceLabel, "OpenCode (~/.local/share/opencode/auth.json)")
  }
}
