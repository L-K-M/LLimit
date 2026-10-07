import XCTest
@testable import QuotaCore
@testable import LLimitdCore

/// Settings integrity on Linux: an unreadable settings file must not cost the saved
/// snapshot, failed saves must not report success, and account edits keep ids.
final class AccountIntegrityTests: XCTestCase {
  private var tempDirectory: URL!
  private var logLines: [String] = []

  override func setUp() {
    super.setUp()
    tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    logLines = []
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: tempDirectory)
    super.tearDown()
  }

  private func makeDaemon(coordinator: QuotaCoordinator? = nil) -> QuotaDaemon {
    let paths = LinuxPaths(
      configHome: tempDirectory.appendingPathComponent("config", isDirectory: true),
      dataHome: tempDirectory.appendingPathComponent("data", isDirectory: true)
    )
    let daemon = QuotaDaemon(
      paths: paths,
      coordinator: coordinator ?? QuotaCoordinator(clients: []),
      makeDiscovery: { CredentialDiscovery(homeDirectories: [self.tempDirectory], environment: [:]) },
      log: { self.logLines.append($0) }
    )
    daemon.loadConfiguration()
    return daemon
  }

  /// One refreshed Zhipu account, so the snapshot and history have content.
  private func makeRefreshedAccount() async throws -> (QuotaDaemon, ProviderAccount) {
    let daemon = makeDaemon(coordinator: QuotaCoordinator(clients: [FixedUsageClient(provider: .zhipu, remaining: 64)]))
    let account = try daemon.addAccount(provider: .zhipu, credentials: [CredentialField.zhipuAPIKey: "zhipu-key"])
    await daemon.refreshNow()
    XCTAssertEqual(daemon.snapshot?.providers.map(\.accountID), [account.id])
    return (daemon, account)
  }

  private func writeSettingsFile(_ text: String, paths: LinuxPaths) throws {
    try FileManager.default.createDirectory(
      at: paths.settingsFileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(text.utf8).write(to: paths.settingsFileURL)
  }

  /// Turns the settings path into a non-empty directory, so the next save fails
  /// (even as root) while the daemon still holds the settings it loaded.
  private func breakSettingsSaves(paths: LinuxPaths) throws {
    try FileManager.default.removeItem(at: paths.settingsFileURL)
    try FileManager.default.createDirectory(at: paths.settingsFileURL, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: paths.settingsFileURL.appendingPathComponent("occupied"))
  }

  // MARK: - Unreadable settings keep the snapshot

  func testUnreadableSettingsDoNotEraseSnapshot() async throws {
    let (daemon, account) = try await makeRefreshedAccount()
    let snapshotBefore = try Data(contentsOf: daemon.paths.snapshotFileURL)
    try writeSettingsFile(#"{"accounts": [ {"provider": "zhipu", "#, paths: daemon.paths)

    let reader = makeDaemon()

    XCTAssertEqual(try Data(contentsOf: reader.paths.snapshotFileURL), snapshotBefore)
    XCTAssertEqual(reader.snapshot?.providers.map(\.accountID), [account.id])
  }

  func testRefreshCycleWithUnreadableSettingsKeepsSnapshotAndLogsOnce() async throws {
    let (daemon, _) = try await makeRefreshedAccount()
    let snapshotBefore = try Data(contentsOf: daemon.paths.snapshotFileURL)
    let secret = "sk-ant-oat-must-not-be-logged"
    try writeSettingsFile(
      #"{"accounts": [{"id": "A", "provider": "retired-provider", "displayName": "A", "isEnabled": true, "credentials": {"anthropic.access_token": "\#(secret)"}}]}"#,
      paths: daemon.paths
    )
    logLines = []

    let cycler = makeDaemon(coordinator: QuotaCoordinator(clients: [FixedUsageClient(provider: .zhipu, remaining: 10)]))
    await cycler.refreshCycle(bootstrap: true)
    await cycler.refreshCycle(bootstrap: false)
    await cycler.refreshCycle(bootstrap: false)

    XCTAssertEqual(try Data(contentsOf: cycler.paths.snapshotFileURL), snapshotBefore)
    XCTAssertFalse(logLines.contains { $0.contains("No enabled provider") }, "\(logLines)")
    let settingsLines = logLines.filter { $0.contains(cycler.paths.settingsFileURL.path) }
    XCTAssertEqual(settingsLines.count, 1, "\(logLines)")
    XCTAssertTrue(settingsLines.first?.contains("accounts[0].provider") == true, "\(settingsLines)")
    XCTAssertFalse(logLines.contains { $0.contains(secret) || $0.contains("retired-provider") }, "\(logLines)")
  }

  // MARK: - Failed saves are failures

  func testMutationsThrowWhenTheSaveFails() async throws {
    let (daemon, account) = try await makeRefreshedAccount()
    try breakSettingsSaves(paths: daemon.paths)

    XCTAssertThrowsError(try daemon.addAccount(provider: .kimi, credentials: [CredentialField.kimiAPIKey: "k"]))
    XCTAssertThrowsError(try daemon.setAccountEnabled(account.id, false))
  }

  func testFailedRemoveKeepsHistoryAndSnapshot() async throws {
    let (daemon, account) = try await makeRefreshedAccount()
    let historyBefore = try Data(contentsOf: daemon.paths.historyFileURL)
    let snapshotBefore = try Data(contentsOf: daemon.paths.snapshotFileURL)
    try breakSettingsSaves(paths: daemon.paths)

    XCTAssertThrowsError(try daemon.removeAccount(account.id))

    XCTAssertEqual(try Data(contentsOf: daemon.paths.historyFileURL), historyBefore)
    XCTAssertEqual(try Data(contentsOf: daemon.paths.snapshotFileURL), snapshotBefore)
  }

  func testEditingSettingsRefusesAnUnreadableFile() throws {
    let daemon = makeDaemon()
    let corrupt = #"{"accounts": [{"credentials": {"kimi.api_key": "secret-value"}}"#
    try writeSettingsFile(corrupt, paths: daemon.paths)

    var ran = false
    XCTAssertThrowsError(try daemon.editingSettings { ran = true }) { error in
      let description = error.localizedDescription
      XCTAssertTrue(description.contains(daemon.paths.settingsFileURL.path), description)
      XCTAssertTrue(description.contains("not valid JSON"), description)
      XCTAssertFalse(description.contains("secret-value"), description)
    }
    XCTAssertFalse(ran)
    XCTAssertEqual(try String(contentsOf: daemon.paths.settingsFileURL, encoding: .utf8), corrupt)
  }

  // MARK: - Account id resolution

  func testBlankAccountIDMatchesNothing() throws {
    let daemon = makeDaemon()
    try daemon.addAccount(provider: .zai, credentials: [CredentialField.zaiAPIKey: "key"])

    XCTAssertThrowsError(try daemon.resolveAccountID(""))
    XCTAssertThrowsError(try daemon.resolveAccountID("  "))
  }

  func testAccountIDPrefixIsCaseInsensitive() throws {
    let daemon = makeDaemon()
    let account = try daemon.addAccount(provider: .zai, credentials: [CredentialField.zaiAPIKey: "key"])

    XCTAssertEqual(try daemon.resolveAccountID(String(account.id.prefix(8)).lowercased()), account.id)
  }

  func testAmbiguousAccountIDPrefixListsCandidates() throws {
    let daemon = try makeDaemon(accounts: [
      ProviderAccount(id: "AB12-ONE", provider: .zai, displayName: "One"),
      ProviderAccount(id: "AB12-TWO", provider: .kimi, displayName: "Two")
    ])

    XCTAssertThrowsError(try daemon.resolveAccountID("ab12")) { error in
      let description = error.localizedDescription
      XCTAssertTrue(description.contains("AB12-ONE (One)") && description.contains("AB12-TWO (Two)"), description)
    }
    XCTAssertEqual(try daemon.resolveAccountID("AB12-TWO"), "AB12-TWO")
  }

  // MARK: - Updating accounts in place

  func testUpdateKeepsIDHistoryAndStyle() async throws {
    let (daemon, account) = try await makeRefreshedAccount()
    let historyBefore = try Data(contentsOf: daemon.paths.historyFileURL)
    let styleBefore = daemon.settings.styleOverride(for: account.id)

    let updated = try daemon.editingSettings {
      try daemon.updateAccount(account.id, displayName: "  Work Zhipu ", credentials: .merging([CredentialField.zhipuAPIKey: "new-key"]))
    }

    XCTAssertEqual(updated.id, account.id)
    XCTAssertEqual(updated.displayName, "Work Zhipu")
    let reloaded = makeDaemon()
    XCTAssertEqual(reloaded.settings.accounts.map(\.id), [account.id])
    XCTAssertEqual(reloaded.settings.accounts.first?.credentials[CredentialField.zhipuAPIKey], "new-key")
    XCTAssertEqual(reloaded.settings.styleOverride(for: account.id), styleBefore)
    XCTAssertEqual(try Data(contentsOf: daemon.paths.historyFileURL), historyBefore)
    XCTAssertEqual(reloaded.snapshot?.providers.first?.title, "Work Zhipu")
  }

  func testVeniceKeyUpdateStartsANewEstimateAndKeepsHistory() async throws {
    let reset = Date().addingTimeInterval(3_600)
    let daemon = makeDaemon(coordinator: QuotaCoordinator(clients: [VeniceBalances(balances: [100], reset: reset)]))
    let account = try daemon.addAccount(provider: .venice, credentials: [CredentialField.veniceAPIKey: "old-venice-key"])
    await daemon.refreshNow()
    XCTAssertEqual(daemon.snapshot?.providers.first?.metrics.first?.estimatedTotal, 100)
    let historyBefore = try Data(contentsOf: daemon.paths.historyFileURL)

    // A rename alone keeps the estimate.
    try daemon.updateAccount(account.id, displayName: "Venice main")
    XCTAssertEqual(makeDaemon().snapshot?.providers.first?.metrics.first?.estimatedTotal, 100)

    try daemon.updateAccount(account.id, credentials: .merging([CredentialField.veniceAPIKey: "new-venice-key"]))

    XCTAssertFalse(makeDaemon().snapshot?.providers.contains { $0.accountID == account.id } ?? true)
    XCTAssertEqual(try Data(contentsOf: daemon.paths.historyFileURL), historyBefore)
    let next = makeDaemon(coordinator: QuotaCoordinator(clients: [VeniceBalances(balances: [25], reset: reset)]))
    await next.refreshNow()
    XCTAssertEqual(next.snapshot?.providers.first?.accountID, account.id)
    XCTAssertEqual(next.snapshot?.providers.first?.metrics.first?.estimatedTotal, 25)
  }

  func testClaudeTokenChangeClearsManagedMetadata() throws {
    let daemon = makeDaemon()
    let account = try daemon.addAccount(provider: .anthropic, credentials: [
      CredentialField.anthropicAccessToken: "sk-ant-oat-old",
      CredentialField.anthropicProfileID: UUID().uuidString,
      CredentialField.anthropicAccountID: "account-uuid",
      CredentialField.anthropicExpiresAt: "1700000000",
      CredentialField.anthropicCredentialSource: ClaudeCodeCredentialSource.managedProfile.rawValue
    ])

    let renamed = try daemon.updateAccount(account.id, displayName: "Personal")
    XCTAssertEqual(renamed.credentials, account.credentials)

    let updated = try daemon.updateAccount(account.id, credentials: .merging([CredentialField.anthropicAccessToken: "sk-ant-oat-new"]))
    XCTAssertEqual(updated.credentials, [CredentialField.anthropicAccessToken: "sk-ant-oat-new"])
    XCTAssertEqual(makeDaemon().settings.accounts.first?.credentials, updated.credentials)
  }

  func testUpdateRejectsInvalidChanges() throws {
    let daemon = makeDaemon()
    let account = try daemon.addAccount(provider: .kimi, credentials: [CredentialField.kimiAPIKey: "k"])
    var managedCredentials = CodexAccountProfile().credentials(identity: CodexAccountIdentity(accountID: "workspace", userID: "member"))
    managedCredentials[CredentialField.openAIAccessToken] = "managed-access"
    let managed = try daemon.addAccount(provider: .openAI, credentials: managedCredentials)
    let saved = try Data(contentsOf: daemon.paths.settingsFileURL)

    XCTAssertThrowsError(try daemon.updateAccount(account.id, credentials: .merging(["kimi.apikey": "typo"])))
    XCTAssertThrowsError(try daemon.updateAccount(account.id, displayName: "   "))
    XCTAssertThrowsError(try daemon.updateAccount("missing", displayName: "Name"))
    XCTAssertThrowsError(try daemon.updateAccount(managed.id, credentials: .merging([CredentialField.openAIAccessToken: "other"])))
    XCTAssertEqual(try Data(contentsOf: daemon.paths.settingsFileURL), saved)

    // A managed account can still be renamed; only its sign-in belongs to Codex.
    XCTAssertEqual(try daemon.updateAccount(managed.id, displayName: "Team").credentials, managedCredentials)
  }

  // MARK: - Reimport

  func testReimportReplacesCredentialsInPlace() throws {
    try plantClaudeLogin(token: "sk-ant-oat-renewed")
    let daemon = makeDaemon()
    let account = try daemon.addAccount(provider: .anthropic, displayName: "Claude Personal", credentials: [
      CredentialField.anthropicAccessToken: "sk-ant-oat-expired",
      CredentialField.anthropicExpiresAt: "1700000000"
    ])

    let result = try daemon.editingSettings { try daemon.reimportAccount(account.id) }

    XCTAssertTrue(result.changed)
    XCTAssertEqual(result.login.stableID, "anthropic:claude-code")
    let reloaded = try XCTUnwrap(makeDaemon().settings.accounts.first)
    XCTAssertEqual(reloaded.id, account.id)
    XCTAssertEqual(reloaded.displayName, "Claude Personal")
    XCTAssertEqual(reloaded.credentials, [CredentialField.anthropicAccessToken: "sk-ant-oat-renewed"])

    XCTAssertFalse(try daemon.editingSettings { try daemon.reimportAccount(account.id) }.changed)
  }

  func testReimportNeedsAChoiceAmongSeveralLogins() throws {
    try plantKimiLogin(directory: ".kimi", token: "kimi-cli-token")
    try plantKimiLogin(directory: ".kimi-code", token: "kimi-code-token")
    let daemon = makeDaemon()
    let kimi = try daemon.addAccount(provider: .kimi, credentials: [CredentialField.kimiAPIKey: "expired"])
    let zai = try daemon.addAccount(provider: .zai, credentials: [CredentialField.zaiAPIKey: "key"])

    XCTAssertThrowsError(try daemon.reimportAccount(kimi.id)) { error in
      let description = error.localizedDescription
      XCTAssertTrue(description.contains("kimi:kimi-cli") && description.contains("kimi:kimi-code"), description)
    }
    XCTAssertThrowsError(try daemon.reimportAccount(kimi.id, from: "kimi:elsewhere"))
    XCTAssertThrowsError(try daemon.reimportAccount(zai.id))
    XCTAssertEqual(makeDaemon().settings.accounts.first?.credentials[CredentialField.kimiAPIKey], "expired")

    try daemon.reimportAccount(kimi.id, from: "kimi:kimi-code")
    XCTAssertEqual(makeDaemon().settings.account(withID: kimi.id)?.credentials[CredentialField.kimiAPIKey], "kimi-code-token")
  }

  // MARK: - Import matching

  func testImportDetectionComparesOnlyPrimarySecrets() throws {
    let daemon = makeDaemon()
    let account = try daemon.addAccount(provider: .kimi, credentials: [
      CredentialField.kimiAPIKey: "old-access", CredentialField.kimiRefreshToken: "same-refresh"
    ])
    let renewed = detectedLogin(.kimi, "kimi:kimi-cli", [
      CredentialField.kimiAPIKey: "new-access", CredentialField.kimiRefreshToken: "same-refresh"
    ])
    let current = detectedLogin(.kimi, "kimi:kimi-cli", [
      CredentialField.kimiAPIKey: "old-access", CredentialField.kimiRefreshToken: "rotated-refresh"
    ])

    XCTAssertFalse(daemon.isDetectedCredentialImported(renewed))
    XCTAssertEqual(daemon.importMatch(for: renewed), .updateCandidates(accountIDs: [account.id]))
    XCTAssertTrue(daemon.isDetectedCredentialImported(current))
    XCTAssertEqual(daemon.importMatch(for: current), .alreadyImported(accountID: account.id))
  }

  func testImportMatchOffersOnlyAccountsNoOtherLoginExplains() throws {
    let daemon = makeDaemon()
    let renewedLogin = detectedLogin(.gitHubCopilot, "github-copilot:cli", [CredentialField.copilotOAuthToken: "renewed"])
    let editorLogin = detectedLogin(.gitHubCopilot, "github-copilot:editor:github.com", [CredentialField.copilotOAuthToken: "editor"])
    XCTAssertEqual(daemon.importMatch(for: renewedLogin), .newAccount)

    let stale = try daemon.addAccount(provider: .gitHubCopilot, credentials: [CredentialField.copilotOAuthToken: "expired"])
    try daemon.addAccount(provider: .gitHubCopilot, credentials: [CredentialField.copilotOAuthToken: "editor"])
    var managedCredentials = CodexAccountProfile().credentials(identity: CodexAccountIdentity(accountID: "workspace", userID: "member"))
    managedCredentials[CredentialField.openAIAccessToken] = "managed-access"
    try daemon.addAccount(provider: .openAI, credentials: managedCredentials)

    XCTAssertEqual(
      daemon.importMatch(for: renewedLogin, among: [renewedLogin, editorLogin]),
      .updateCandidates(accountIDs: [stale.id])
    )
    let codexLogin = detectedLogin(.openAI, "openai:codex", [CredentialField.openAIAccessToken: "global-access"])
    XCTAssertEqual(daemon.importMatch(for: codexLogin), .newAccount)
  }

  // MARK: - Fixtures

  private func makeDaemon(accounts: [ProviderAccount]) throws -> QuotaDaemon {
    let daemon = makeDaemon()
    try SettingsStore(fileURL: daemon.paths.settingsFileURL).save(AppSettings(accounts: accounts))
    daemon.loadConfiguration()
    return daemon
  }

  private func detectedLogin(_ provider: QuotaProvider, _ stableID: String, _ credentials: [String: String]) -> DiscoveredCredential {
    DiscoveredCredential(stableID: stableID, provider: provider, suggestedName: provider.displayName,
                         sourceLabel: "test", credentials: credentials)
  }

  private func plantClaudeLogin(token: String) throws {
    let directory = tempDirectory.appendingPathComponent(".claude", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(#"{"claudeAiOauth":{"accessToken":"\#(token)"}}"#.utf8)
      .write(to: directory.appendingPathComponent(".credentials.json"))
  }

  private func plantKimiLogin(directory name: String, token: String) throws {
    let directory = tempDirectory.appendingPathComponent(name, isDirectory: true).appendingPathComponent("credentials", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(#"{"access_token":"\#(token)"}"#.utf8).write(to: directory.appendingPathComponent("kimi-code.json"))
  }
}

/// Reports a Venice DIEM balance without an allocation, so the daemon estimates one.
private actor VeniceBalances: QuotaProviderClient {
  let provider: QuotaProvider = .venice
  private var balances: [Double]
  private let reset: Date

  init(balances: [Double], reset: Date) {
    self.balances = balances
    self.reset = reset
  }

  func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    let balance = balances.removeFirst()
    return ProviderUsage(
      accountID: configuration.accountID,
      provider: provider,
      title: configuration.displayName,
      metrics: [UsageMetric(id: "daily-diem", label: "Daily DIEM remaining", remainingAmount: balance,
                            usedDisplay: "\(balance) DIEM", resetAt: reset)],
      fetchedAt: now
    )
  }
}

/// Returns a fixed remaining percentage for every account of one provider.
private struct FixedUsageClient: QuotaProviderClient {
  let provider: QuotaProvider
  let remaining: Int

  func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    ProviderUsage(
      accountID: configuration.accountID,
      provider: provider,
      title: configuration.displayName,
      metrics: [UsageMetric(id: "weekly", label: "Weekly limit", remainingPercent: remaining)],
      fetchedAt: now
    )
  }
}
