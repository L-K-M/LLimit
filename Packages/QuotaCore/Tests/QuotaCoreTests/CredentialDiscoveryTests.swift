import XCTest
@testable import QuotaCore

final class CredentialDiscoveryTests: XCTestCase {
  private var home: URL!

  override func setUpWithError() throws {
    home = FileManager.default.temporaryDirectory.appendingPathComponent("llimit-disc-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: home)
  }

  private func write(_ json: String, to components: String...) throws {
    let url = components.reduce(home!) { $0.appendingPathComponent($1) }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try json.data(using: .utf8)!.write(to: url)
  }

  private func discover() -> [DiscoveredCredential] {
    CredentialDiscovery(homeDirectories: [home]).discover().credentials
  }

  func testDiscoversClaudeCodeNestedToken() throws {
    try write(#"{"claudeAiOauth":{"accessToken":"sk-claude-abc","refreshToken":"r","expiresAt":1}}"#,
              to: ".claude", ".credentials.json")

    let claude = discover().first { $0.provider == .anthropic }
    XCTAssertEqual(claude?.stableID, "anthropic:claude-code")
    XCTAssertEqual(claude?.credentials[CredentialField.anthropicAccessToken], "sk-claude-abc")
  }

  func testDiscoversClaudeCodeFlatToken() throws {
    try write(#"{"accessToken":"sk-flat-123"}"#, to: ".claude", ".credentials.json")
    XCTAssertEqual(discover().first?.credentials[CredentialField.anthropicAccessToken], "sk-flat-123")
  }

  func testDiscoversCodexWithAccountID() throws {
    try write(#"{"tokens":{"access_token":"sk-codex","account_id":"acc_42"},"OPENAI_API_KEY":null}"#,
              to: ".codex", "auth.json")

    let openai = discover().first { $0.provider == .openAI }
    XCTAssertEqual(openai?.stableID, "openai:codex")
    XCTAssertEqual(openai?.credentials[CredentialField.openAIAccessToken], "sk-codex")
    XCTAssertEqual(openai?.credentials[CredentialField.openAIAccountID], "acc_42")
  }

  func testDiscoversOpenCodeMultipleProviders() throws {
    try write(#"""
    {
      "anthropic": {"type":"oauth","access":"sk-claude-oc"},
      "openai": {"type":"oauth","access":"sk-openai-oc"},
      "zhipuai-coding-plan": {"type":"api","key":"zhipu-key"},
      "zai-coding-plan": {"type":"api","key":"zai-key"},
      "github-copilot": {"type":"oauth","refresh":"gho_refresh"}
    }
    """#, to: ".local", "share", "opencode", "auth.json")

    let result = discover()
    XCTAssertEqual(result.first { $0.stableID == "zhipu:opencode" }?.credentials[CredentialField.zhipuAPIKey], "zhipu-key")
    XCTAssertEqual(result.first { $0.stableID == "zai:opencode" }?.credentials[CredentialField.zaiAPIKey], "zai-key")
    XCTAssertEqual(result.first { $0.stableID == "github-copilot:opencode" }?.credentials[CredentialField.copilotOAuthToken], "gho_refresh")
    XCTAssertNotNil(result.first { $0.stableID == "anthropic:opencode" })
    XCTAssertNotNil(result.first { $0.stableID == "openai:opencode" })
  }

  func testDiscoversCopilotEditorHostsFile() throws {
    try write(#"{"github.com":{"oauth_token":"gho_editor","user":"octocat"}}"#,
              to: ".config", "github-copilot", "hosts.json")

    let copilot = discover().first { $0.provider == .gitHubCopilot }
    XCTAssertEqual(copilot?.credentials[CredentialField.copilotOAuthToken], "gho_editor")
    XCTAssertEqual(copilot?.credentials[CredentialField.copilotUsername], "octocat")
    XCTAssertEqual(copilot?.suggestedName, "Copilot (@octocat)")
  }

  func testDedupesIdenticalTokenFromTwoSources() throws {
    // Same Claude token written by both Claude Code and OpenCode -> one entry.
    try write(#"{"claudeAiOauth":{"accessToken":"sk-same"}}"#, to: ".claude", ".credentials.json")
    try write(#"{"anthropic":{"type":"oauth","access":"sk-same"}}"#, to: ".config", "opencode", "auth.json")

    let anthropic = discover().filter { $0.provider == .anthropic }
    XCTAssertEqual(anthropic.count, 1)
    XCTAssertEqual(anthropic.first?.stableID, "anthropic:claude-code") // first source wins
  }

  func testKeepsDistinctTokensFromTwoSources() throws {
    try write(#"{"claudeAiOauth":{"accessToken":"sk-one"}}"#, to: ".claude", ".credentials.json")
    try write(#"{"anthropic":{"type":"oauth","access":"sk-two"}}"#, to: ".config", "opencode", "auth.json")
    XCTAssertEqual(discover().filter { $0.provider == .anthropic }.count, 2)
  }

  func testReturnsEmptyWhenNothingInstalled() {
    XCTAssertTrue(discover().isEmpty)
  }

  func testDiscoversKimiCLIToken() throws {
    try write(#"{"access_token":"kimi-token-1","refresh_token":"r","expires_at":4102444800.0}"#,
              to: ".kimi", "credentials", "kimi-code.json")

    let kimi = discover().first { $0.provider == .kimi }
    XCTAssertEqual(kimi?.stableID, "kimi:kimi-cli")
    XCTAssertEqual(kimi?.credentials[CredentialField.kimiAPIKey], "kimi-token-1")
    XCTAssertEqual(kimi?.sourceLabel, "Kimi CLI (~/.kimi)")
  }

  func testDiscoversStandaloneKimiCodeToken() throws {
    try write(#"{"access_token":"kimi-token-2","expires_at":4102444800.0}"#,
              to: ".kimi-code", "credentials", "kimi-code.json")

    let kimi = discover().first { $0.provider == .kimi }
    XCTAssertEqual(kimi?.stableID, "kimi:kimi-code")
    XCTAssertEqual(kimi?.credentials[CredentialField.kimiAPIKey], "kimi-token-2")
  }

  func testSkipsExpiredKimiToken() throws {
    try write(#"{"access_token":"kimi-stale","expires_at":1000000000.0}"#,
              to: ".kimi", "credentials", "kimi-code.json")

    let result = CredentialDiscovery(homeDirectories: [home]).discover()
    XCTAssertTrue(result.credentials.filter { $0.provider == .kimi }.isEmpty)
    XCTAssertTrue(result.diagnostics.contains { $0.contains("Kimi: token expired") })
  }

  func testKeepsKimiTokenWithoutExpiry() throws {
    try write(#"{"access_token":"kimi-no-expiry"}"#, to: ".kimi", "credentials", "kimi-code.json")
    XCTAssertEqual(discover().first { $0.provider == .kimi }?.credentials[CredentialField.kimiAPIKey], "kimi-no-expiry")
  }

  func testDedupesIdenticalKimiTokenFromBothInstalls() throws {
    try write(#"{"access_token":"kimi-same","expires_at":4102444800.0}"#, to: ".kimi", "credentials", "kimi-code.json")
    try write(#"{"access_token":"kimi-same","expires_at":4102444800.0}"#, to: ".kimi-code", "credentials", "kimi-code.json")

    let kimi = discover().filter { $0.provider == .kimi }
    XCTAssertEqual(kimi.count, 1)
    XCTAssertEqual(kimi.first?.stableID, "kimi:kimi-cli") // first source wins
  }
}
