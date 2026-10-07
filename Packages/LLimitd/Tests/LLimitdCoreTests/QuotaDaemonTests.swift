import XCTest
@testable import QuotaCore
@testable import LLimitdCore

final class QuotaDaemonTests: XCTestCase {
  private var tempDirectory: URL!
  private var daemon: QuotaDaemon!

  override func setUp() {
    super.setUp()
    tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
      log: { _ in }
    )
    daemon.loadConfiguration()
    return daemon
  }

  // MARK: - Claude account isolation

  func testRefreshKeepsClaudeAccountsSeparateFromGlobalCLILogin() async throws {
    let claudeDirectory = tempDirectory.appendingPathComponent(".claude", isDirectory: true)
    try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
    try Data(#"{"claudeAiOauth":{"accessToken":"sk-ant-oat-global"}}"#.utf8)
      .write(to: claudeDirectory.appendingPathComponent(".credentials.json"))

    let daemon = makeDaemon(coordinator: QuotaCoordinator(clients: [ClaudeAccountClient()]))
    let imported = try daemon.importAccount(from: DiscoveredCredential(
      stableID: "anthropic:previous-login",
      provider: .anthropic,
      suggestedName: "Personal Claude",
      sourceLabel: "Previously imported login",
      credentials: [CredentialField.anthropicAccessToken: "sk-ant-oat-personal"]
    ))
    let manual = try daemon.addAccount(
      provider: .anthropic,
      displayName: "Work Claude",
      credentials: [CredentialField.anthropicAccessToken: "sk-ant-oat-work"]
    )
    let managed = try daemon.addAccount(
      provider: .anthropic,
      displayName: "Profile Claude",
      credentials: [
        CredentialField.anthropicAccessToken: "sk-ant-oat-profile",
        CredentialField.anthropicProfileID: UUID().uuidString,
        CredentialField.anthropicCredentialSource: ClaudeCodeCredentialSource.managedProfile.rawValue
      ]
    )
    let disabled = try daemon.addAccount(
      provider: .anthropic,
      credentials: [CredentialField.anthropicAccessToken: "sk-ant-oat-disabled"]
    )
    try daemon.setAccountEnabled(disabled.id, false)
    let unconfigured = try daemon.addAccount(provider: .anthropic)
    let originalAccounts = daemon.settings.accounts

    await daemon.refreshNow()

    XCTAssertEqual(daemon.settings.accounts, originalAccounts)
    XCTAssertEqual(makeDaemon().settings.accounts, originalAccounts)
    let snapshot = try XCTUnwrap(daemon.snapshot)
    XCTAssertTrue(snapshot.failures.isEmpty)
    XCTAssertEqual(Set(snapshot.providers.map(\.accountID)), [imported.id, manual.id, managed.id])
    XCTAssertEqual(snapshot.providers.first { $0.accountID == imported.id }?.metrics.first?.remainingPercent, 73)
    XCTAssertEqual(snapshot.providers.first { $0.accountID == manual.id }?.metrics.first?.remainingPercent, 41)
    XCTAssertEqual(snapshot.providers.first { $0.accountID == managed.id }?.metrics.first?.remainingPercent, 62)
    XCTAssertFalse(snapshot.providers.contains { $0.accountID == disabled.id || $0.accountID == unconfigured.id })
  }

  // MARK: - OpenAI account isolation

  func testManagedOpenAIAccountsDoNotAdoptGlobalLoginDuringRefreshOrAuthRecovery() async throws {
    let codexDirectory = tempDirectory.appendingPathComponent(".codex", isDirectory: true)
    try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
    let oldAccess = fakeAccessToken(expiresAt: Date().addingTimeInterval(3_600))
    let globalAccess = fakeAccessToken(expiresAt: Date().addingTimeInterval(7_200))
    // No refresh grant is supplied: even a regression must stay fully offline.
    try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": globalAccess, "account_id": "workspace"]])
      .write(to: codexDirectory.appendingPathComponent("auth.json"))
    let client = RecordingOpenAIAuthFailure()
    let daemon = makeDaemon(coordinator: QuotaCoordinator(clients: [client]))
    var managedCredentials = CodexAccountProfile().credentials(identity: CodexAccountIdentity(accountID: "workspace", userID: "member"))
    managedCredentials[CredentialField.openAIAccessToken] = oldAccess
    let managed = try daemon.addAccount(provider: .openAI, credentials: managedCredentials)
    var malformedCredentials = managedCredentials
    malformedCredentials[CredentialField.openAICodexProfileID] = "malformed"
    let malformed = try daemon.addAccount(provider: .openAI, credentials: malformedCredentials)
    let imported = try daemon.addAccount(provider: .openAI, credentials: [
      CredentialField.openAIAccessToken: oldAccess, CredentialField.openAIAccountID: "workspace"
    ])

    await daemon.refreshNow()

    XCTAssertEqual(daemon.settings.accounts.first { $0.id == managed.id }?.credentials, managedCredentials)
    XCTAssertEqual(daemon.settings.accounts.first { $0.id == malformed.id }?.credentials, malformedCredentials)
    XCTAssertEqual(daemon.settings.accounts.first { $0.id == imported.id }?.credentials[CredentialField.openAIAccessToken], globalAccess)
    XCTAssertEqual(makeDaemon().settings.accounts, daemon.settings.accounts)
    let calls = await client.configurations
    XCTAssertEqual(calls.count, 2)
    XCTAssertEqual(calls.first { $0.accountID == managed.id }?.credentials, managedCredentials)
    XCTAssertEqual(Set(daemon.snapshot?.failures.map(\.accountID) ?? []), [managed.id, imported.id])
    XCTAssertTrue(daemon.snapshot?.failures.allSatisfy { $0.kind == .auth } == true)
  }

  private func fakeAccessToken(expiresAt date: Date) -> String {
    let payload = try! JSONSerialization.data(withJSONObject: ["exp": date.timeIntervalSince1970]).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return "header.\(payload).fake-signature"
  }

  // MARK: - Settings mutations (the CLI's accounts surface)

  func testAddAccountPersistsWithMode0600() throws {
    let daemon = makeDaemon()
    let account = try daemon.addAccount(
      provider: .anthropic,
      credentials: [CredentialField.anthropicAccessToken: "sk-ant-oat-secret"]
    )

    XCTAssertTrue(account.isEnabled)
    XCTAssertEqual(daemon.settings.accounts.count, 1)

    let attributes = try FileManager.default.attributesOfItem(atPath: daemon.paths.settingsFileURL.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

    let reloaded = makeDaemon()
    XCTAssertEqual(reloaded.settings.accounts.first?.credentials[CredentialField.anthropicAccessToken], "sk-ant-oat-secret")
  }

  func testAddAccountAssignsUniqueDisplayNames() throws {
    let daemon = makeDaemon()
    let first = try daemon.addAccount(provider: .kimi, credentials: [CredentialField.kimiAPIKey: "k1"])
    let second = try daemon.addAccount(provider: .kimi, credentials: [CredentialField.kimiAPIKey: "k2"])

    XCTAssertEqual(first.resolvedDisplayName, "Kimi")
    XCTAssertEqual(second.resolvedDisplayName, "Kimi 2")
  }

  func testImportAccountCopiesDetectedCredential() throws {
    let daemon = makeDaemon()
    let detected = DiscoveredCredential(
      stableID: "anthropic:claude-code",
      provider: .anthropic,
      suggestedName: "Claude",
      sourceLabel: "Claude Code (~/.claude)",
      credentials: [CredentialField.anthropicAccessToken: "sk-ant-oat-imported"]
    )

    let account = try daemon.importAccount(from: detected)

    XCTAssertEqual(account.provider, .anthropic)
    XCTAssertEqual(account.credentials[CredentialField.anthropicAccessToken], "sk-ant-oat-imported")
    XCTAssertTrue(daemon.isDetectedCredentialImported(detected))
  }

  func testEnableDisableAndRemovePersist() throws {
    let daemon = makeDaemon()
    let account = try daemon.addAccount(
      provider: .zhipu,
      credentials: [CredentialField.zhipuAPIKey: "key"]
    )

    try daemon.setAccountEnabled(account.id, false)
    XCTAssertEqual(makeDaemon().settings.accounts.first?.isEnabled, false)

    try daemon.setAccountEnabled(account.id, true)
    XCTAssertEqual(makeDaemon().settings.accounts.first?.isEnabled, true)

    try daemon.removeAccount(account.id)
    XCTAssertTrue(makeDaemon().settings.accounts.isEmpty)
    XCTAssertThrowsError(try daemon.removeAccount(account.id))
  }

  func testResolveAccountIDAcceptsUniquePrefix() throws {
    let daemon = makeDaemon()
    let account = try daemon.addAccount(provider: .zai, credentials: [CredentialField.zaiAPIKey: "key"])

    XCTAssertEqual(try daemon.resolveAccountID(account.id), account.id)
    XCTAssertEqual(try daemon.resolveAccountID(String(account.id.prefix(8))), account.id)
    XCTAssertThrowsError(try daemon.resolveAccountID("does-not-exist"))
  }

  func testUnreadableSettingsFileBlocksSaving() throws {
    let daemon = makeDaemon()
    try FileManager.default.createDirectory(
      at: daemon.paths.settingsFileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "not json".write(to: daemon.paths.settingsFileURL, atomically: true, encoding: .utf8)

    daemon.loadConfiguration()
    XCTAssertThrowsError(try daemon.saveConfiguration())

    // The corrupt file must be left untouched (it may hold credentials).
    let contents = try String(contentsOf: daemon.paths.settingsFileURL, encoding: .utf8)
    XCTAssertEqual(contents, "not json")
  }

  // MARK: - Refresh behavior

  func testRefreshWritesCredentialFreeSnapshotAndHistory() async throws {
    let token = "sk-ant-oat-super-secret-token"

    let echoingClient = EchoingClient(provider: .anthropic, remaining: 73)
    let daemon = makeDaemon(coordinator: QuotaCoordinator(clients: [echoingClient]))
    let account = try daemon.addAccount(
      provider: .anthropic,
      credentials: [CredentialField.anthropicAccessToken: token]
    )

    await daemon.refreshNow()

    let snapshot = try XCTUnwrap(daemon.snapshot)
    XCTAssertEqual(snapshot.providers.first?.accountID, account.id)
    XCTAssertEqual(snapshot.providers.first?.metrics.first?.remainingPercent, 73)
    XCTAssertTrue(snapshot.failures.isEmpty)

    // The snapshot and history files must not contain the credential anywhere.
    for url in [daemon.paths.snapshotFileURL, daemon.paths.historyFileURL] {
      let data = try Data(contentsOf: url)
      let text = String(decoding: data, as: UTF8.self)
      XCTAssertFalse(text.contains(token), "\(url.lastPathComponent) leaked a credential")
    }

    // History captured the refresh.
    let history = try Data(contentsOf: daemon.paths.historyFileURL)
    XCTAssertFalse(history.isEmpty)

    // Settings still hold the credential (mode 0600).
    let settingsData = try Data(contentsOf: daemon.paths.settingsFileURL)
    XCTAssertTrue(String(decoding: settingsData, as: UTF8.self).contains(token))
  }

  func testRefreshKeepsStaleUsageWhenFetchFails() async throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    let succeeding = EchoingClient(provider: .zhipu, remaining: 64, at: date)
    let daemon = makeDaemon(coordinator: QuotaCoordinator(clients: [succeeding]))
    let account = try daemon.addAccount(provider: .zhipu, credentials: [CredentialField.zhipuAPIKey: "key"])

    await daemon.refreshNow()
    XCTAssertEqual(daemon.snapshot?.providers.count, 1)

    // Next cycle the provider errors: the account must keep its last-known usage
    // AND record the failure, instead of vanishing from the snapshot.
    let failing = EchoingClient(provider: .zhipu, remaining: nil, error: ProviderClientError(kind: .network, message: "boom"))
    let daemon2 = makeDaemon(coordinator: QuotaCoordinator(clients: [failing]))
    await daemon2.refreshNow()

    let snapshot = try XCTUnwrap(daemon2.snapshot)
    XCTAssertEqual(snapshot.providers.count, 1)
    XCTAssertEqual(snapshot.providers.first?.accountID, account.id)
    XCTAssertEqual(snapshot.providers.first?.metrics.first?.remainingPercent, 64)
    XCTAssertEqual(snapshot.failures.count, 1)
    XCTAssertEqual(snapshot.failures.first?.kind, .network)
  }

  func testVeniceDailyEstimateSurvivesRefreshAndRestart() async throws {
    let reset = Date().addingTimeInterval(3_600)
    let client = VeniceBalanceClient(balances: [100, 75], reset: reset)
    let daemon = makeDaemon(coordinator: QuotaCoordinator(clients: [client]))
    let key = "venice-daemon-test-key"
    let account = try daemon.addAccount(provider: .venice, credentials: [CredentialField.veniceAPIKey: key])

    await daemon.refreshNow()
    XCTAssertEqual(daemon.snapshot?.providers.first?.metrics.first?.remainingPercent, 100)
    XCTAssertEqual(daemon.snapshot?.providers.first?.metrics.first?.estimatedTotal, 100)

    await daemon.refreshNow()
    XCTAssertEqual(daemon.snapshot?.providers.first?.metrics.first?.remainingPercent, 75)

    // A new process must recover the observed upper bound from its saved snapshot.
    let nextClient = VeniceBalanceClient(balances: [50, 120, 60], reset: reset)
    let restarted = makeDaemon(coordinator: QuotaCoordinator(clients: [nextClient]))
    XCTAssertEqual(restarted.snapshot?.providers.first?.accountID, account.id)
    await restarted.refreshNow()
    let continued = try XCTUnwrap(restarted.snapshot?.providers.first?.metrics.first)
    XCTAssertEqual(continued.remainingAmount, 50)
    XCTAssertEqual(continued.estimatedTotal, 100)
    XCTAssertEqual(continued.remainingPercent, 50)
    XCTAssertTrue(continued.isPercentageEstimated)

    await restarted.refreshNow()
    XCTAssertEqual(restarted.snapshot?.providers.first?.metrics.first?.estimatedTotal, 120)
    XCTAssertEqual(restarted.snapshot?.providers.first?.metrics.first?.remainingPercent, 100)
    await restarted.refreshNow()
    XCTAssertEqual(restarted.snapshot?.providers.first?.metrics.first?.estimatedTotal, 120)
    XCTAssertEqual(restarted.snapshot?.providers.first?.metrics.first?.remainingPercent, 50)

    let history = try QuotaHistoryStore(fileURL: restarted.paths.historyFileURL).load()
    XCTAssertEqual(history.count, 5)
    XCTAssertEqual(history.last?.providers.first?.metrics.first?.estimatedTotal, 120)
    for url in [restarted.paths.snapshotFileURL, restarted.paths.historyFileURL] {
      let contents = String(decoding: try Data(contentsOf: url), as: UTF8.self)
      XCTAssertFalse(contents.contains(key), "\(url.lastPathComponent) leaked a credential")
    }
  }

  func testReplacingVeniceAccountDoesNotReuseEstimate() async throws {
    let reset = Date().addingTimeInterval(3_600)
    let client = VeniceBalanceClient(balances: [100], reset: reset)
    let daemon = makeDaemon(coordinator: QuotaCoordinator(clients: [client]))
    let original = try daemon.addAccount(provider: .venice, credentials: [CredentialField.veniceAPIKey: "old-venice-test-key"])
    await daemon.refreshNow()
    XCTAssertEqual(daemon.snapshot?.providers.first?.metrics.first?.estimatedTotal, 100)

    // The CLI replaces an API key by removing and adding the account. A new ID
    // must begin a new estimate even when its reset time and provider match.
    try daemon.removeAccount(original.id)
    let replacement = try daemon.addAccount(provider: .venice, credentials: [CredentialField.veniceAPIKey: "new-venice-test-key"])
    let restarted = makeDaemon(coordinator: QuotaCoordinator(clients: [VeniceBalanceClient(balances: [25], reset: reset)]))
    await restarted.refreshNow()

    XCTAssertNotEqual(original.id, replacement.id)
    XCTAssertEqual(restarted.snapshot?.providers.first?.accountID, replacement.id)
    XCTAssertEqual(restarted.snapshot?.providers.first?.metrics.first?.estimatedTotal, 25)
    XCTAssertEqual(restarted.snapshot?.providers.first?.metrics.first?.remainingPercent, 100)
    let history = try QuotaHistoryStore(fileURL: restarted.paths.historyFileURL).load()
    XCTAssertFalse(history.contains { $0.providers.contains { $0.accountID == original.id } })
  }

  func testRefreshWithNoConfiguredAccountsDoesNotCrash() async {
    let daemon = makeDaemon()
    await daemon.refreshNow()
    XCTAssertNil(daemon.snapshot)
    XCTAssertTrue(daemon.statusMessage.contains("No enabled provider accounts"))
  }
}

private actor VeniceBalanceClient: QuotaProviderClient {
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

private actor RecordingOpenAIAuthFailure: QuotaProviderClient {
  let provider: QuotaProvider = .openAI
  private(set) var configurations: [ProviderRuntimeConfiguration] = []

  func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    configurations.append(configuration)
    throw ProviderClientError(kind: .auth, message: "Reconnect OpenAI")
  }
}

private struct ClaudeAccountClient: QuotaProviderClient {
  let provider: QuotaProvider = .anthropic

  func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    let remainingByToken = ["sk-ant-oat-personal": 73, "sk-ant-oat-work": 41, "sk-ant-oat-profile": 62]
    let token = configuration.credentials[CredentialField.anthropicAccessToken] ?? ""
    return ProviderUsage(
      accountID: configuration.accountID,
      provider: provider,
      title: configuration.displayName,
      metrics: [UsageMetric(id: "weekly", label: "Weekly limit", remainingPercent: remainingByToken[token] ?? 0)],
      fetchedAt: now
    )
  }
}

/// Returns usage keyed by the requesting account's id, or throws a scripted error.
private final class EchoingClient: QuotaProviderClient, @unchecked Sendable {
  let provider: QuotaProvider
  let remaining: Int?
  let date: Date
  let error: ProviderClientError?

  init(provider: QuotaProvider, remaining: Int?, at date: Date = Date(timeIntervalSince1970: 1_700_000_000), error: ProviderClientError? = nil) {
    self.provider = provider
    self.remaining = remaining
    self.date = date
    self.error = error
  }

  func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    if let error {
      throw error
    }
    return ProviderUsage(
      accountID: configuration.accountID,
      provider: provider,
      title: configuration.displayName,
      metrics: [UsageMetric(id: "weekly", label: "Weekly limit", remainingPercent: remaining ?? 0)],
      fetchedAt: date
    )
  }
}
