import XCTest
@testable import QuotaCore
@testable import LLimitdCore

/// Tests for the daemon/CLI concurrency contract: the daemon must not hold the
/// settings lock across a network fetch, and its token-refresh saves must merge
/// instead of overwriting a CLI edit that landed mid-cycle.
final class SettingsConcurrencyTests: XCTestCase {
  private var tempDirectory: URL!
  private var paths: LinuxPaths!

  override func setUp() {
    super.setUp()
    tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    paths = LinuxPaths(
      configHome: tempDirectory.appendingPathComponent("config", isDirectory: true),
      dataHome: tempDirectory.appendingPathComponent("data", isDirectory: true)
    )
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: tempDirectory)
    super.tearDown()
  }

  private func makeDaemon(coordinator: QuotaCoordinator) -> QuotaDaemon {
    QuotaDaemon(
      paths: paths,
      coordinator: coordinator,
      makeDiscovery: { CredentialDiscovery(homeDirectories: [self.tempDirectory], environment: [:]) },
      log: { _ in }
    )
  }

  /// Writes a newer Codex token with the same verified account identity.
  private func plantLiveOpenAIToken(_ token: String) throws {
    let codexDirectory = tempDirectory.appendingPathComponent(".codex", isDirectory: true)
    try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: [
      "tokens": ["access_token": token, "account_id": "account-under-test"]
    ])
    try data.write(to: codexDirectory.appendingPathComponent("auth.json"), options: .atomic)
  }

  private func openAIToken(expiresAt: Int) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: ["exp": expiresAt])
    let payload = data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return "e30.\(payload).test-signature"
  }

  /// A CLI-style edit from a second process: lock, reload, mutate, save.
  private func cliAddKimiAccount(_ name: String) throws {
    let cli = makeDaemon(coordinator: QuotaCoordinator(clients: []))
    try cli.settingsLock.withLock {
      cli.loadConfiguration()
      try cli.addAccount(provider: .kimi, displayName: name, credentials: [CredentialField.kimiAPIKey: "k"])
    }
  }

  private func onDiskSettings() throws -> AppSettings {
    let data = try Data(contentsOf: paths.settingsFileURL)
    return try JSONDecoder().decode(AppSettings.self, from: data)
  }

  // MARK: - Interleaving: CLI edit lands while the daemon is mid-fetch

  /// The daemon cycle must hold the settings lock only around the settings load,
  /// never across the fetch. A CLI edit during an in-flight fetch must complete
  /// immediately AND survive the daemon's token-adoption save.
  func testCLIEditDuringInFlightFetchIsNeitherBlockedNorClobbered() async throws {
    let originalToken = try openAIToken(expiresAt: 4_070_908_800)
    let renewedToken = try openAIToken(expiresAt: 4_102_444_800)
    try plantLiveOpenAIToken(renewedToken)

    let gate = FetchGate()
    let daemon = makeDaemon(coordinator: QuotaCoordinator(clients: [
      GatedClient(provider: .openAI, gate: gate)
    ]))
    try daemon.addAccount(
      provider: .openAI,
      credentials: [
        CredentialField.openAIAccessToken: originalToken,
        CredentialField.openAIAccountID: "account-under-test"
      ]
    )

    let cycle = Task { await daemon.refreshCycle(bootstrap: false) }

    // Wait until the fetch is actually in flight (settings load + token adoption
    // + pre-fetch merge-save have all happened by now).
    await gate.waitUntilEntered()

    // The CLI edit must complete while the fetch is still blocked. With the old
    // whole-cycle lock this blocks until the fetch finishes — which never happens
    // until the gate is released below, so this poll times out and fails.
    let editCompletion = CompletionFlag()
    let edit = Task {
      try cliAddKimiAccount("Kimi CLI")
      editCompletion.mark()
    }
    var completed = false
    for _ in 0 ..< 40 where !completed {
      try? await Task.sleep(nanoseconds: 50_000_000)
      completed = editCompletion.isMarked
    }
    XCTAssertTrue(completed, "CLI edit was still blocked 2s into an in-flight fetch — the lock spans the network call")

    // While the fetch is in flight, the CLI account and the adopted token must
    // both already be on disk.
    let midFetch = try onDiskSettings()
    XCTAssertTrue(midFetch.accounts.contains { $0.provider == .kimi }, "CLI account missing mid-fetch")
    XCTAssertEqual(
      midFetch.accounts.first { $0.provider == .openAI }?.credentials[CredentialField.openAIAccessToken],
      renewedToken
    )

    gate.release()
    _ = try await edit.value
    _ = await cycle.value

    // After the cycle, both writes must still be there: the merge must not have
    // clobbered the CLI edit, and the CLI edit must not have lost the token.
    let final = try onDiskSettings()
    XCTAssertTrue(final.accounts.contains { $0.provider == .kimi }, "CLI edit was clobbered by the daemon's save")
    XCTAssertEqual(
      final.accounts.first { $0.provider == .openAI }?.credentials[CredentialField.openAIAccessToken],
      renewedToken
    )
    XCTAssertNotNil(daemon.snapshot)
  }

  // MARK: - The merge itself

  func testOldCredentialSuccessIsNotRepublishedAfterUpdate() async throws {
    try await assertObsoleteFetchRejected(.replaceCredentials)
  }

  func testOldCredentialFailureDoesNotCarryUsageAfterUpdate() async throws {
    try await assertObsoleteFetchRejected(.replaceCredentials, outcome: .failure)
  }

  func testInFlightResultDoesNotResurrectRemovedAccount() async throws {
    try await assertObsoleteFetchRejected(.remove)
  }

  func testInFlightResultDoesNotResurrectDisabledAccount() async throws {
    try await assertObsoleteFetchRejected(.disable)
  }

  func testCancelledOldAuthResultDoesNotReviveUpdatedAccount() async throws {
    try await assertObsoleteFetchRejected(.replaceCredentials, outcome: .failure, completion: .cancelled)
  }

  func testCancelledEmptyFirstRefreshDoesNotCreateDisplayStores() async throws {
    let daemon = makeDaemon(coordinator: QuotaCoordinator(clients: []))
    daemon.loadConfiguration()
    _ = try daemon.editingSettings { try $0.addAccount(provider: .zhipu, credentials: [CredentialField.zhipuAPIKey: "test-key"]) }
    let cycle = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      await daemon.refreshNow()
    }
    await cycle.value

    XCTAssertNil(daemon.snapshot)
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.snapshotFileURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.historyFileURL.path))
  }

  func testCancellationDoesNotDropCompletedAuthFailure() async throws {
    let gate = FetchGate()
    let daemon = makeDaemon(coordinator: QuotaCoordinator(clients: [
      GatedClient(provider: .zhipu, gate: gate, outcome: .failure)
    ]))
    daemon.loadConfiguration()
    let account = try daemon.editingSettings { try $0.addAccount(provider: .zhipu, credentials: [CredentialField.zhipuAPIKey: "test-key"]) }
    let cycle = Task { await daemon.refreshNow() }
    await gate.waitUntilEntered()
    cycle.cancel()
    gate.release()
    await cycle.value

    let snapshot = try XCTUnwrap(SnapshotStore(fileURL: paths.snapshotFileURL).load(policy: .preserve))
    XCTAssertTrue(snapshot.providers.isEmpty)
    XCTAssertEqual(snapshot.failures.map(\.accountID), [account.id])
    XCTAssertEqual(snapshot.failures.first?.kind, .auth)
    XCTAssertEqual(try QuotaHistoryStore(fileURL: paths.historyFileURL).load(policy: .preserve).last?.failures, snapshot.failures)
  }

  func testCredentialEditDuringAuthRecoveryCannotReviveHistory() async throws {
    let replaced = ProviderAccount(id: "replaced", provider: .kimi,
      credentials: [CredentialField.kimiAPIKey: "old-test-key"])
    let failing = ProviderAccount(id: "failing", provider: .openAI, credentials: [
      CredentialField.openAIAccessToken: try openAIToken(expiresAt: 4_070_908_800),
      CredentialField.openAIAccountID: "account-under-test"
    ])
    try SettingsStore(fileURL: paths.settingsFileURL).save(AppSettings(accounts: [replaced, failing]))

    let gate = FetchGate()
    gate.release()
    var discoveries = 0
    let daemon = QuotaDaemon(paths: paths, coordinator: QuotaCoordinator(clients: [
      CurrentKimiClient(), GatedClient(provider: .openAI, gate: gate, outcome: .failure)
    ]), makeDiscovery: {
      discoveries += 1
      if discoveries == 2 {
        // The first discovery is pre-fetch adoption. This edit lands during
        // auth recovery, after the initial result validation has already run.
        let cli = self.makeDaemon(coordinator: QuotaCoordinator(clients: []))
        do {
          _ = try cli.editingSettings { transaction in
            try transaction.updateAccount(replaced.id,
              credentials: .merging([CredentialField.kimiAPIKey: "replacement-test-key"]))
          }
        } catch {
          XCTFail("Concurrent credential edit failed: \(error)")
        }
      }
      return CredentialDiscovery(homeDirectories: [self.tempDirectory], environment: [:])
    }, log: { _ in })
    daemon.loadConfiguration()
    await daemon.refreshNow()

    XCTAssertEqual(discoveries, 2)
    XCTAssertEqual(try onDiskSettings().accounts.first { $0.id == replaced.id }?
      .credentials[CredentialField.kimiAPIKey], "replacement-test-key")
    let snapshot = try XCTUnwrap(SnapshotStore(fileURL: paths.snapshotFileURL).load())
    XCTAssertFalse(snapshot.providers.contains { $0.accountID == replaced.id })
    XCTAssertEqual(snapshot.failures.map(\.accountID), [failing.id])
    let history = try QuotaHistoryStore(fileURL: paths.historyFileURL).load()
    XCTAssertFalse(history.contains { $0.providers.contains { $0.accountID == replaced.id } },
      "History publication must use the same final credential validation as the snapshot")
  }

  private enum ConcurrentEdit {
    case replaceCredentials
    case remove
    case disable
  }

  private enum FetchCompletion {
    case normal
    case cancelled
  }

  private func assertObsoleteFetchRejected(
    _ change: ConcurrentEdit,
    outcome: GatedClient.Outcome = .success,
    completion: FetchCompletion = .normal
  ) async throws {
    let gate = FetchGate()
    let daemon = makeDaemon(coordinator: QuotaCoordinator(clients: [
      GatedClient(provider: .zhipu, gate: gate, outcome: outcome),
      CurrentKimiClient()
    ]))
    daemon.loadConfiguration()
    let obsolete = try daemon.addAccount(provider: .zhipu, credentials: [CredentialField.zhipuAPIKey: "old-test-key"])
    let current = try daemon.addAccount(provider: .kimi, credentials: [CredentialField.kimiAPIKey: "test-key"])
    let previous = QuotaSnapshot(generatedAt: Date(), providers: [ProviderUsage(
      accountID: obsolete.id, provider: .zhipu, title: obsolete.resolvedDisplayName,
      metrics: [UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 70)], fetchedAt: Date()
    )], failures: [])
    try SnapshotStore(fileURL: paths.snapshotFileURL).save(previous)
    try QuotaHistoryStore(fileURL: paths.historyFileURL).append(previous)

    let cycle = Task { await daemon.refreshCycle(bootstrap: false) }
    await gate.waitUntilEntered()

    // The second writer must finish while the provider is still waiting.
    let editCompletion = CompletionFlag()
    let edit = Task {
      let cli = makeDaemon(coordinator: QuotaCoordinator(clients: []))
      try cli.editingSettings { transaction in
        switch change {
        case .replaceCredentials:
          try transaction.updateAccount(obsolete.id, credentials: .merging([CredentialField.zhipuAPIKey: "new-test-key"]))
        case .remove:
          try transaction.removeAccount(obsolete.id)
        case .disable:
          try transaction.setAccountEnabled(obsolete.id, false)
        }
      }
      editCompletion.mark()
    }
    for _ in 0..<40 where !editCompletion.isMarked {
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertTrue(editCompletion.isMarked, "Settings lock spans the provider fetch")
    if completion == .cancelled { cycle.cancel() }
    gate.release()
    try await edit.value
    await cycle.value

    let saved = try XCTUnwrap(SnapshotStore(fileURL: paths.snapshotFileURL).load())
    XCTAssertEqual(saved.providers.map(\.accountID), [current.id])
    XCTAssertFalse(saved.failures.contains { $0.accountID == obsolete.id })
    XCTAssertEqual(daemon.snapshot?.providers.map(\.accountID), saved.providers.map(\.accountID))
    XCTAssertEqual(daemon.snapshot?.failures, saved.failures)
    let history = try QuotaHistoryStore(fileURL: paths.historyFileURL).load()
    XCTAssertFalse(history.last?.providers.contains { $0.accountID == obsolete.id } ?? true)
    if case .remove = change {
      XCTAssertFalse(history.contains { $0.providers.contains { $0.accountID == obsolete.id } })
    }
  }

  private func settingsWithAccounts(_ accounts: [ProviderAccount]) -> AppSettings {
    AppSettings(accounts: accounts)
  }

  private func account(_ provider: QuotaProvider, token: String, enabled: Bool = true) -> ProviderAccount {
    ProviderAccount(
      provider: provider,
      displayName: provider.displayName,
      isEnabled: enabled,
      credentials: provider.credentialFields.reduce(into: [:]) { $0[$1.key] = "" }
        .merging([CredentialField.anthropicAccessToken: token]) { _, new in new }
    )
  }

  func testMergeReplaysDaemonCredentialChangesOntoCLIEdits() {
    let base = settingsWithAccounts([account(.anthropic, token: "T0")])
    let id = base.accounts[0].id

    // Daemon adopted a new token; CLI added an account and disabled the old one.
    var current = base
    current.accounts[0].credentials[CredentialField.anthropicAccessToken] = "T1"
    var disk = base
    disk.accounts[0].isEnabled = false
    disk.accounts.append(account(.kimi, token: "k"))

    let merged = QuotaDaemon.mergingCredentialChanges(base: base, current: current, onto: disk)

    let mergedA = merged.accounts.first { $0.id == id }!
    XCTAssertEqual(mergedA.credentials[CredentialField.anthropicAccessToken], "T1", "daemon token update lost")
    XCTAssertFalse(mergedA.isEnabled, "CLI enable-toggle clobbered")
    XCTAssertTrue(merged.accounts.contains { $0.provider == .kimi }, "CLI-added account clobbered")
  }

  func testMergeKeepsCLIValueWhenBothSidesChangedTheSameKey() {
    let base = settingsWithAccounts([account(.anthropic, token: "T0")])
    let id = base.accounts[0].id

    var current = base
    current.accounts[0].credentials[CredentialField.anthropicAccessToken] = "T1"
    var disk = base
    disk.accounts[0].credentials[CredentialField.anthropicAccessToken] = "T-cli"

    let merged = QuotaDaemon.mergingCredentialChanges(base: base, current: current, onto: disk)

    // The explicit edit wins over the automatic one; the next cycle re-adopts.
    XCTAssertEqual(
      merged.accounts.first { $0.id == id }?.credentials[CredentialField.anthropicAccessToken],
      "T-cli"
    )
  }

  func testMergeIgnoresAccountsTheCLIRemoved() {
    let base = settingsWithAccounts([account(.anthropic, token: "T0")])
    let id = base.accounts[0].id

    var current = base
    current.accounts[0].credentials[CredentialField.anthropicAccessToken] = "T1"
    let disk = settingsWithAccounts([]) // CLI removed the account mid-refresh

    let merged = QuotaDaemon.mergingCredentialChanges(base: base, current: current, onto: disk)

    XCTAssertFalse(merged.accounts.contains { $0.id == id }, "merge resurrected a removed account")
  }

  func testCredentialMergeDoesNotSpliceRotatedGrantIntoReplacedLogin() {
    let original = ProviderAccount(id: "account", provider: .openAI, credentials: [
      CredentialField.openAIAccessToken: "old-access", CredentialField.openAIRefreshToken: "old-refresh"
    ])
    let base = AppSettings(accounts: [original])
    var current = base
    current.accounts[0].credentials[CredentialField.openAIAccessToken] = "rotated-access"
    current.accounts[0].credentials[CredentialField.openAIRefreshToken] = "rotated-refresh"
    var disk = base
    disk.accounts[0].credentials[CredentialField.openAIAccessToken] = "explicit-replacement"

    let merged = QuotaDaemon.mergingCredentialChanges(base: base, current: current, onto: disk)

    XCTAssertEqual(merged.accounts[0].credentials, disk.accounts[0].credentials)
  }
}

// MARK: - Gated fetch fixtures

private final class CompletionFlag: @unchecked Sendable {
  private var marked = false
  private let lock = NSLock()

  func mark() {
    lock.lock()
    marked = true
    lock.unlock()
  }

  var isMarked: Bool {
    lock.lock()
    defer { lock.unlock() }
    return marked
  }
}

/// A one-shot gate: `waitUntilEntered` returns once the client is inside the
/// fetch; the fetch returns only after `release`.
private final class FetchGate: @unchecked Sendable {
  private var enteredContinuation: CheckedContinuation<Void, Never>?
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  private var hasEntered = false
  private var isReleased = false
  private let lock = NSLock()

  func fetchEntered() {
    lock.lock()
    hasEntered = true
    let continuation = enteredContinuation
    enteredContinuation = nil
    lock.unlock()
    continuation?.resume()
  }

  func waitUntilEntered() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if hasEntered {
        lock.unlock()
        continuation.resume()
      } else {
        enteredContinuation = continuation
        lock.unlock()
      }
    }
  }

  func waitUntilReleased() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if isReleased {
        lock.unlock()
        continuation.resume()
      } else {
        releaseContinuation = continuation
        lock.unlock()
      }
    }
  }

  func release() {
    lock.lock()
    isReleased = true
    let continuation = releaseContinuation
    releaseContinuation = nil
    lock.unlock()
    continuation?.resume()
  }
}

private struct GatedClient: QuotaProviderClient {
  enum Outcome {
    case success
    case failure
  }

  let provider: QuotaProvider
  let gate: FetchGate
  var outcome: Outcome = .success

  func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    gate.fetchEntered()
    await gate.waitUntilReleased()
    if outcome == .failure {
      throw ProviderClientError(kind: .auth, message: "old-test-key rejected")
    }
    return ProviderUsage(
      accountID: configuration.accountID,
      provider: provider,
      title: configuration.displayName,
      metrics: [UsageMetric(id: "weekly", label: "Weekly limit", remainingPercent: 50)],
      fetchedAt: now
    )
  }
}

private struct CurrentKimiClient: QuotaProviderClient {
  let provider: QuotaProvider = .kimi

  func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    ProviderUsage(accountID: configuration.accountID, provider: provider, title: configuration.displayName,
                  metrics: [UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 80)], fetchedAt: now)
  }
}
