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
      makeDiscovery: { CredentialDiscovery(homeDirectories: [self.tempDirectory]) },
      log: { _ in }
    )
    daemon.loadConfiguration()
    return daemon
  }

  // MARK: - Settings mutations (the CLI's accounts surface)

  func testAddAccountPersistsWithMode0600() throws {
    let daemon = makeDaemon()
    let account = daemon.addAccount(
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

  func testAddAccountAssignsUniqueDisplayNames() {
    let daemon = makeDaemon()
    let first = daemon.addAccount(provider: .kimi, credentials: [CredentialField.kimiAPIKey: "k1"])
    let second = daemon.addAccount(provider: .kimi, credentials: [CredentialField.kimiAPIKey: "k2"])

    XCTAssertEqual(first.resolvedDisplayName, "Kimi")
    XCTAssertEqual(second.resolvedDisplayName, "Kimi 2")
  }

  func testImportAccountCopiesDetectedCredential() {
    let daemon = makeDaemon()
    let detected = DiscoveredCredential(
      stableID: "anthropic:claude-code",
      provider: .anthropic,
      suggestedName: "Claude",
      sourceLabel: "Claude Code (~/.claude)",
      credentials: [CredentialField.anthropicAccessToken: "sk-ant-oat-imported"]
    )

    let account = daemon.importAccount(from: detected)

    XCTAssertEqual(account.provider, .anthropic)
    XCTAssertEqual(account.credentials[CredentialField.anthropicAccessToken], "sk-ant-oat-imported")
    XCTAssertTrue(daemon.isDetectedCredentialImported(detected))
  }

  func testEnableDisableAndRemovePersist() throws {
    let daemon = makeDaemon()
    let account = daemon.addAccount(
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

  func testResolveAccountIDAcceptsUniquePrefix() {
    let daemon = makeDaemon()
    let account = daemon.addAccount(provider: .zai, credentials: [CredentialField.zaiAPIKey: "key"])

    XCTAssertEqual(daemon.resolveAccountID(account.id), account.id)
    XCTAssertEqual(daemon.resolveAccountID(String(account.id.prefix(8))), account.id)
    XCTAssertNil(daemon.resolveAccountID("does-not-exist"))
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
    let account = daemon.addAccount(
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
    let account = daemon.addAccount(provider: .zhipu, credentials: [CredentialField.zhipuAPIKey: "key"])

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

  func testRefreshWithNoConfiguredAccountsDoesNotCrash() async {
    let daemon = makeDaemon()
    await daemon.refreshNow()
    XCTAssertNil(daemon.snapshot)
    XCTAssertTrue(daemon.statusMessage.contains("No enabled provider accounts"))
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
