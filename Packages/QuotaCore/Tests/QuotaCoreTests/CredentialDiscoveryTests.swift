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
    CredentialDiscovery(homeDirectories: [home], environment: [:]).discover().credentials
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
      "kimi-for-coding": {"type":"api","key":"kimi-key"},
      "github-copilot": {"type":"oauth","refresh":"gho_refresh"}
    }
    """#, to: ".local", "share", "opencode", "auth.json")

    let result = discover()
    XCTAssertEqual(result.first { $0.stableID == "zhipu:opencode" }?.credentials[CredentialField.zhipuAPIKey], "zhipu-key")
    XCTAssertEqual(result.first { $0.stableID == "zai:opencode" }?.credentials[CredentialField.zaiAPIKey], "zai-key")
    XCTAssertEqual(result.first { $0.stableID == "kimi:opencode" }?.credentials[CredentialField.kimiAPIKey], "kimi-key")
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
    XCTAssertEqual(kimi?.credentials[CredentialField.kimiRefreshToken], "r")
    XCTAssertEqual(kimi?.sourceLabel, "Kimi CLI (~/.kimi)")
  }

  func testSkipsExpiredKimiTokenWithMillisecondEpoch() throws {
    // 1e12 ms = 2001; a millisecond expiry must not defeat the check.
    try write(#"{"access_token":"kimi-stale-ms","expires_at":1000000000000}"#,
              to: ".kimi", "credentials", "kimi-code.json")

    let result = CredentialDiscovery(homeDirectories: [home], environment: [:]).discover()
    XCTAssertTrue(result.credentials.filter { $0.provider == .kimi }.isEmpty)
    XCTAssertTrue(result.diagnostics.contains { $0.contains("Kimi: token expired") })
  }

  func testKeepsKimiTokenWithZeroExpiry() throws {
    // kimi-cli writes expires_at 0.0 when the expiry is unknown.
    try write(#"{"access_token":"kimi-zero","expires_at":0.0}"#, to: ".kimi", "credentials", "kimi-code.json")
    XCTAssertEqual(discover().first { $0.provider == .kimi }?.credentials[CredentialField.kimiAPIKey], "kimi-zero")
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

    let result = CredentialDiscovery(homeDirectories: [home], environment: [:]).discover()
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

  // MARK: - Antigravity

  func testDiscoversAntigravitySessionFile() throws {
    try write(#"{"refreshToken":"ag-refresh","projectId":"proj-1","email":"dev@example.com"}"#,
              to: ".gemini", "antigravity", "session.json")

    let google = discover().first { $0.provider == .googleAntigravity }
    XCTAssertEqual(google?.stableID, "google-antigravity:antigravity:dev@example.com")
    XCTAssertEqual(google?.suggestedName, "Google Antigravity (dev@example.com)")
    XCTAssertEqual(google?.credentials[CredentialField.googleRefreshToken], "ag-refresh")
    XCTAssertEqual(google?.credentials[CredentialField.googleProjectID], "proj-1")
    XCTAssertEqual(google?.credentials[CredentialField.googleEmail], "dev@example.com")
  }

  func testDiscoversAntigravityCLITokenWithSnakeCaseKeys() throws {
    try write(#"{"access_token":"ya29.stale","refresh_token":"ag-cli-refresh","expires_in":3599,"project_id":"proj-2"}"#,
              to: ".gemini", "antigravity-cli", "antigravity-oauth-token")

    let google = discover().first { $0.provider == .googleAntigravity }
    XCTAssertEqual(google?.credentials[CredentialField.googleRefreshToken], "ag-cli-refresh")
    XCTAssertEqual(google?.credentials[CredentialField.googleProjectID], "proj-2")
  }

  func testFallsBackToAntigravityAuthTokenFile() throws {
    try write(#"{"refresh_token":"ag-auth-refresh","managedProjectId":"managed-3"}"#,
              to: ".gemini", "antigravity-cli", "antigravity-auth-token")

    let google = discover().first { $0.provider == .googleAntigravity }
    XCTAssertEqual(google?.credentials[CredentialField.googleRefreshToken], "ag-auth-refresh")
    XCTAssertEqual(google?.credentials[CredentialField.googleProjectID], "managed-3")
  }

  func testDiscoversJetskiStandaloneToken() throws {
    try write(#"{"tokens":{"refresh_token":"ag-jetski","projectId":"proj-4"}}"#,
              to: ".gemini", "jetski-standalone-oauth-token")

    let google = discover().first { $0.provider == .googleAntigravity }
    XCTAssertEqual(google?.credentials[CredentialField.googleRefreshToken], "ag-jetski")
    XCTAssertEqual(google?.credentials[CredentialField.googleProjectID], "proj-4")
  }

  func testImportsAntigravityLoginWithoutProjectID() throws {
    // A project-less login still imports: the user supplies the one field the
    // provider reports as missing.
    try write(#"{"refreshToken":"ag-no-project"}"#, to: ".gemini", "antigravity", "session.json")

    let result = CredentialDiscovery(homeDirectories: [home], environment: [:]).discover()
    let google = result.credentials.first { $0.provider == .googleAntigravity }
    XCTAssertEqual(google?.credentials[CredentialField.googleRefreshToken], "ag-no-project")
    XCTAssertNil(google?.credentials[CredentialField.googleProjectID])
    XCTAssertEqual(google?.suggestedName, "Google Antigravity")
    XCTAssertTrue(result.diagnostics.contains { $0.contains("without a project id") })
  }

  func testPrefersFirstProbedAntigravityStoreWithoutMixingStores() throws {
    // The two stores can hold two different Google accounts, so the first
    // probed one wins whole: its token must never be paired with the other's
    // project id.
    try write(#"{"refreshToken":"ag-session","email":"first@example.com"}"#,
              to: ".gemini", "antigravity", "session.json")
    try write(#"{"refresh_token":"ag-older","projectId":"other-account-project","email":"second@example.com"}"#,
              to: ".gemini", "antigravity-cli", "antigravity-oauth-token")

    let google = discover().filter { $0.provider == .googleAntigravity }
    XCTAssertEqual(google.count, 1)
    XCTAssertEqual(google.first?.credentials[CredentialField.googleRefreshToken], "ag-session")
    XCTAssertEqual(google.first?.credentials[CredentialField.googleEmail], "first@example.com")
    XCTAssertNil(google.first?.credentials[CredentialField.googleProjectID])
  }

  func testTakesAntigravityEmailFromGeminiIDToken() throws {
    try write(#"{"refreshToken":"ag-refresh","projectId":"proj-5"}"#,
              to: ".gemini", "antigravity", "session.json")
    try write(#"{"id_token":"eyJhbGciOiAiUlMyNTYiLCAidHlwIjogIkpXVCJ9.eyJlbWFpbCI6ICJnZW1pbmlAZXhhbXBsZS5jb20iLCAic3ViIjogIjEyMyJ9.sig"}"#, to: ".gemini", "oauth_creds.json")

    let google = discover().first { $0.provider == .googleAntigravity }
    XCTAssertEqual(google?.credentials[CredentialField.googleEmail], "gemini@example.com")
    XCTAssertEqual(google?.suggestedName, "Google Antigravity (gemini@example.com)")
  }

  func testReportsAntigravityStoreWithoutRefreshToken() throws {
    try write(#"{"access_token":"ya29.only"}"#, to: ".gemini", "antigravity", "session.json")

    let result = CredentialDiscovery(homeDirectories: [home], environment: [:]).discover()
    XCTAssertTrue(result.credentials.filter { $0.provider == .googleAntigravity }.isEmpty)
    XCTAssertTrue(result.diagnostics.contains { $0.contains("no refresh token in") })
  }

  func testDiscoversOpenCodeAntigravityAccountsUnderDataHome() throws {
    try write(#"""
    {
      "version": 3,
      "accounts": [
        {"email":"old@example.com","refreshToken":"oc-old","projectId":"p-old","lastUsed":1},
        {"email":"new@example.com","refreshToken":"oc-new","projectId":"p-new","lastUsed":2}
      ]
    }
    """#, to: ".local", "share", "opencode", "antigravity-accounts.json")

    let google = discover().first { $0.stableID == "google-antigravity:opencode:new@example.com" }
    XCTAssertEqual(google?.credentials[CredentialField.googleRefreshToken], "oc-new")
    XCTAssertEqual(google?.credentials[CredentialField.googleProjectID], "p-new")
    XCTAssertEqual(google?.sourceLabel, "OpenCode (~/.local/share/opencode/antigravity-accounts.json)")
  }

  func testDecodesBase64URLEncodedGeminiIDToken() throws {
    // Real id_token payloads are base64url, and Data(base64Encoded:) rejects that
    // alphabet's '-' and '_'. This fixture contains both, so it fails if the
    // decoder ever stops translating them.
    let jwt = "eyJhbGciOiAiUlMyNTYiLCAidHlwIjogIkpXVCJ9.eyJlbWFpbCI6ICJnZW1pbmlAZXhhbXBsZS5jb20iLCAibmFtZSI6ICJ6REw_YWt-Sn5rR09ES2RpbloifQ.sig"
    let payload = jwt.split(separator: ".")[1]
    XCTAssertTrue(payload.contains("-"), "fixture must exercise base64url '-'")
    XCTAssertTrue(payload.contains("_"), "fixture must exercise base64url '_'")

    try write(#"{"refreshToken":"ag-refresh","projectId":"proj-6"}"#,
              to: ".gemini", "antigravity", "session.json")
    try write(#"{"id_token":"\#(jwt)"}"#, to: ".gemini", "oauth_creds.json")

    let google = discover().first { $0.provider == .googleAntigravity }
    XCTAssertEqual(google?.credentials[CredentialField.googleEmail], "gemini@example.com")
  }

  func testDiagnosesAntigravityNameBorrowedFromGeminiCLI() throws {
    // The Gemini CLI can be signed into a different Google account, so borrowing
    // its identity to label the account has to be visible.
    try write(#"{"refreshToken":"ag-refresh","projectId":"proj-7"}"#,
              to: ".gemini", "antigravity", "session.json")
    try write(#"{"id_token":"eyJhbGciOiAiUlMyNTYiLCAidHlwIjogIkpXVCJ9.eyJlbWFpbCI6ICJnZW1pbmlAZXhhbXBsZS5jb20iLCAibmFtZSI6ICJ6REw_YWt-Sn5rR09ES2RpbloifQ.sig"}"#, to: ".gemini", "oauth_creds.json")

    let result = CredentialDiscovery(homeDirectories: [home], environment: [:]).discover()
    XCTAssertTrue(result.diagnostics.contains { $0.contains("taken from the Gemini CLI login") })
  }

  func testDedupesSameOpenCodeAntigravityAccountInBothRoots() throws {
    // A migrated OpenCode install can leave the old config-root file behind.
    let accounts = #"{"accounts":[{"email":"dup@example.com","refreshToken":"oc-dup","projectId":"p-dup"}]}"#
    try write(accounts, to: ".local", "share", "opencode", "antigravity-accounts.json")
    try write(accounts, to: ".config", "opencode", "antigravity-accounts.json")

    let google = discover().filter { $0.provider == .googleAntigravity }
    XCTAssertEqual(google.count, 1)
    // Pin which root survived: a count of 1 alone would also hold if a root
    // stopped being scanned, which is what the companion test below rules out.
    XCTAssertEqual(google.first?.sourceLabel, "OpenCode (~/.local/share/opencode/antigravity-accounts.json)")
  }

  func testReadsOpenCodeAntigravityAccountsFromConfigRoot() throws {
    // The config root was the only one LLimit ever read, so losing it would
    // break existing installs silently.
    try write(#"{"accounts":[{"email":"cfg@example.com","refreshToken":"oc-cfg","projectId":"p-cfg"}]}"#,
              to: ".config", "opencode", "antigravity-accounts.json")

    let google = discover().filter { $0.provider == .googleAntigravity }
    XCTAssertEqual(google.count, 1)
    XCTAssertEqual(google.first?.credentials[CredentialField.googleRefreshToken], "oc-cfg")
    XCTAssertEqual(google.first?.sourceLabel, "OpenCode (~/.config/opencode/antigravity-accounts.json)")
  }

  func testDiscoversDevinCLICredentialsTOML() throws {
    try write("""
      windsurf_api_key = "devin-session-abc"
      api_server_url = "https://server.codeium.com"
      devin_webapp_host = "app.devin.ai"
      devin_api_url = "https://api.devin.ai"
      """,
      to: ".local", "share", "devin", "credentials.toml")

    let devin = discover().first { $0.provider == .devin }
    XCTAssertEqual(devin?.credentials[CredentialField.devinAPIKey], "devin-session-abc")
    XCTAssertEqual(devin?.credentials[CredentialField.devinAPIServer], "https://server.codeium.com")
    XCTAssertEqual(devin?.suggestedName, "Devin")
    XCTAssertEqual(devin?.sourceLabel, "Devin CLI (~/.local/share/devin/credentials.toml)")
  }

  func testDiscoversDevinCredentialsUnderXDGDataHome() throws {
    let xdg = home.appendingPathComponent("xdg-data")
    let file = xdg.appendingPathComponent("devin/credentials.toml")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try #"windsurf_api_key = "devin-xdg-key""#.data(using: .utf8)!.write(to: file)

    let result = CredentialDiscovery(
      homeDirectories: [home],
      environment: ["XDG_DATA_HOME": xdg.path]
    ).discover()

    let devin = result.credentials.filter { $0.provider == .devin }
    XCTAssertEqual(devin.count, 1)
    XCTAssertEqual(devin.first?.credentials[CredentialField.devinAPIKey], "devin-xdg-key")
  }

  func testDevinTOMLParsesCommentsAndLiteralStrings() throws {
    try write("""
      # written by devin auth login
      windsurf_api_key = 'devin-literal-key' # trailing comment
      api_server_url = "https://server.example.com" # comment
      """,
      to: ".local", "share", "devin", "credentials.toml")

    let devin = discover().first { $0.provider == .devin }
    XCTAssertEqual(devin?.credentials[CredentialField.devinAPIKey], "devin-literal-key")
    XCTAssertEqual(devin?.credentials[CredentialField.devinAPIServer], "https://server.example.com")
  }

  func testDevinFileWithoutKeyIsDiagnosticOnly() throws {
    try write(#"devin_webapp_host = "app.devin.ai""#,
              to: ".local", "share", "devin", "credentials.toml")

    let result = CredentialDiscovery(homeDirectories: [home], environment: [:]).discover()
    XCTAssertTrue(result.credentials.filter { $0.provider == .devin }.isEmpty)
    XCTAssertTrue(result.diagnostics.contains { $0.contains("no windsurf_api_key") })
  }
}
