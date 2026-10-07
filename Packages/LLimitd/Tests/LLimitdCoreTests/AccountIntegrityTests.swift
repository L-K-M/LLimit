import XCTest
@testable import QuotaCore
@testable import LLimitdCore

// Retained account-edit scenarios from PR #104.
final class AccountIntegrityTests: XCTestCase {
  private var directory: URL!
  private var paths: LinuxPaths!
  private var logs: [String] = []

  override func setUp() {
    super.setUp()
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    paths = LinuxPaths(configHome: directory.appendingPathComponent("config"), dataHome: directory.appendingPathComponent("data"))
    logs = []
  }
  override func tearDown() {
    try? FileManager.default.removeItem(at: directory)
    super.tearDown()
  }
  private func daemon() -> QuotaDaemon {
    let daemon = QuotaDaemon(paths: paths, coordinator: .init(clients: []),
                             makeDiscovery: { CredentialDiscovery(homeDirectories: [self.directory], environment: [:]) },
                             log: { self.logs.append($0) })
    daemon.loadConfiguration()
    return daemon
  }
  private func add(_ provider: QuotaProvider = .kimi) throws -> (QuotaDaemon, ProviderAccount) {
    let daemon = daemon()
    let account = try daemon.editingSettings { try $0.addAccount(provider: provider, credentials: [provider.credentialFields[0].key: "test-key"]) }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = QuotaSnapshot(generatedAt: now, providers: [ProviderUsage(accountID: account.id, provider: provider,
      title: account.resolvedDisplayName, metrics: [UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 64)], fetchedAt: now)], failures: [])
    try SnapshotStore(fileURL: paths.snapshotFileURL).save(snapshot)
    try QuotaHistoryStore(fileURL: paths.historyFileURL).save([snapshot])
    daemon.loadConfiguration()
    return (daemon, account)
  }

  func testUnreadableSettingsKeepSnapshotBlockEditsAndLogOnce() async throws {
    let (_, account) = try add()
    let before = try Data(contentsOf: paths.snapshotFileURL)
    let corrupt = #"{"accounts":[{"id":"a","provider":"retired-provider","credentials":{"kimi.api_key":"secret-sentinel"}}]}"#
    try Data(corrupt.utf8).write(to: paths.settingsFileURL)
    let reader = daemon()
    XCTAssertEqual(reader.snapshot?.providers.first?.accountID, account.id)
    var edited = false
    XCTAssertThrowsError(try reader.editingSettings { _ in edited = true })
    XCTAssertFalse(edited)
    await reader.refreshCycle(bootstrap: true)
    await reader.refreshCycle(bootstrap: false)
    XCTAssertEqual(logs.count, 1)
    XCTAssertTrue(logs[0].contains("accounts[0].provider"))
    XCTAssertFalse(logs[0].contains("secret-sentinel"))
    XCTAssertFalse(logs[0].contains("retired-provider"))
    XCTAssertEqual(try Data(contentsOf: paths.snapshotFileURL), before)
    XCTAssertEqual(try String(contentsOf: paths.settingsFileURL, encoding: .utf8), corrupt)
  }

  func testFailedRemoveKeepsSnapshotAndHistory() throws {
    let (daemon, account) = try add()
    let snapshot = try Data(contentsOf: paths.snapshotFileURL)
    let history = try Data(contentsOf: paths.historyFileURL)
    try FileManager.default.removeItem(at: paths.settingsFileURL)
    try FileManager.default.createDirectory(at: paths.settingsFileURL, withIntermediateDirectories: true)
    try Data("occupied".utf8).write(to: paths.settingsFileURL.appendingPathComponent("occupied"))
    XCTAssertThrowsError(try daemon.removeAccount(account.id))
    XCTAssertThrowsError(try daemon.addAccount(provider: .venice))
    XCTAssertEqual(try Data(contentsOf: paths.snapshotFileURL), snapshot)
    XCTAssertEqual(try Data(contentsOf: paths.historyFileURL), history)
  }

  func testTransactionReloadsAndAccountResolutionIsExplicit() throws {
    let stale = daemon()
    let (_, account) = try add()
    try stale.editingSettings { transaction in
      XCTAssertEqual(try stale.resolveAccountID(String(account.id.prefix(8)).lowercased()), account.id)
      XCTAssertThrowsError(try stale.resolveAccountID("  "))
      try transaction.addAccount(provider: .zai)
    }
    XCTAssertEqual(daemon().settings.accounts.map(\.provider), [.kimi, .zai])
    try SettingsStore(fileURL: paths.settingsFileURL).save(.init(accounts: [
      ProviderAccount(id: "AB12-one", provider: .kimi), ProviderAccount(id: "AB12-two", provider: .zai)
    ]))
    let resolver = daemon()
    XCTAssertThrowsError(try resolver.resolveAccountID("ab12")) { error in
      XCTAssertTrue(error.localizedDescription.contains("AB12-one"))
      XCTAssertTrue(error.localizedDescription.contains("AB12-two"))
    }
  }

  func testRenameAndCredentialUpdatePreserveIDStyleAndHistory() throws {
    let (daemon, account) = try add()
    let history = try Data(contentsOf: paths.historyFileURL)
    let style = daemon.settings.styleOverride(for: account.id)
    let renamed = try daemon.editingSettings { try $0.updateAccount(account.id, displayName: "  Work ") }
    XCTAssertEqual(renamed.id, account.id)
    XCTAssertEqual(renamed.displayName, "Work")
    XCTAssertEqual(self.daemon().snapshot?.providers.first?.title, "Work")
    let updated = try daemon.editingSettings { try $0.updateAccount(account.id, credentials: .merging([CredentialField.kimiAPIKey: "replacement"])) }
    XCTAssertEqual(updated.id, account.id)
    XCTAssertEqual(self.daemon().settings.styleOverride(for: account.id), style)
    XCTAssertEqual(try Data(contentsOf: paths.historyFileURL), history)
    XCTAssertTrue(self.daemon().snapshot?.providers.isEmpty == true)
  }

  func testClaudeTokenChangeClearsManagedMetadataAndInvalidEditsFail() throws {
    let daemon = daemon()
    let claude = try daemon.editingSettings { try $0.addAccount(provider: .anthropic, credentials: [
      CredentialField.anthropicAccessToken: "test-old", CredentialField.anthropicProfileID: UUID().uuidString,
      CredentialField.anthropicAccountID: "account", CredentialField.anthropicCredentialSource: ClaudeCodeCredentialSource.managedProfile.rawValue
    ]) }
    let updated = try daemon.editingSettings { try $0.updateAccount(claude.id, credentials: .merging([CredentialField.anthropicAccessToken: "test-new"])) }
    XCTAssertEqual(updated.credentials, [CredentialField.anthropicAccessToken: "test-new"])
    let saved = try Data(contentsOf: paths.settingsFileURL)
    XCTAssertThrowsError(try daemon.editingSettings { try $0.updateAccount(claude.id, displayName: "   ") })
    XCTAssertThrowsError(try daemon.editingSettings { try $0.updateAccount(claude.id, credentials: .merging(["typo": "test"])) })
    XCTAssertEqual(try Data(contentsOf: paths.settingsFileURL), saved)
    let managed = try daemon.editingSettings { try $0.addAccount(provider: .openAI, credentials: CodexAccountProfile().credentials(identity: .init(accountID: "workspace", userID: "member"))) }
    XCTAssertThrowsError(try daemon.editingSettings { try $0.updateAccount(managed.id, credentials: .merging([CredentialField.openAIAccessToken: "test-token"])) })
    XCTAssertEqual(try daemon.editingSettings { try $0.updateAccount(managed.id, displayName: "Team") }.credentials, managed.credentials)
  }

  func testReimportReplacesHiddenCredentialsAndNeedsExplicitLoginChoice() throws {
    let (daemon, account) = try add()
    let logins = ["cli", "editor"].map { source in
      DiscoveredCredential(stableID: "kimi:\(source)", provider: .kimi, suggestedName: "Kimi", sourceLabel: source,
                           credentials: [CredentialField.kimiAPIKey: "test-\(source)"])
    }
    XCTAssertThrowsError(try daemon.editingSettings { try $0.reimportAccount(account.id, among: logins) })
    let result = try daemon.editingSettings { try $0.reimportAccount(account.id, from: "kimi:editor", among: logins) }
    XCTAssertTrue(result.changed)
    XCTAssertEqual(self.daemon().settings.accounts.first?.id, account.id)
    XCTAssertEqual(self.daemon().settings.accounts.first?.credentials[CredentialField.kimiAPIKey], "test-editor")
    XCTAssertFalse(try daemon.editingSettings { try $0.reimportAccount(account.id, from: "kimi:editor", among: logins) }.changed)
  }

  func testImportMatchesPrimarySecretNotSharedRefreshToken() throws {
    let daemon = daemon()
    let account = try daemon.editingSettings { try $0.addAccount(provider: .kimi, credentials: [CredentialField.kimiAPIKey: "old", CredentialField.kimiRefreshToken: "same"]) }
    let login = DiscoveredCredential(stableID: "kimi:cli", provider: .kimi, suggestedName: "Kimi", sourceLabel: "test",
                                    credentials: [CredentialField.kimiAPIKey: "new", CredentialField.kimiRefreshToken: "same"])
    XCTAssertFalse(daemon.isDetectedCredentialImported(login))
    XCTAssertEqual(daemon.importMatch(for: login), .updateCandidates(accountIDs: [account.id]))
  }
}
