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
      makeDiscovery: { CredentialDiscovery(homeDirectories: [self.tempDirectory]) },
      log: { _ in }
    )
  }

  /// Writes a Claude Code credentials file the daemon will adopt (T0 -> T1).
  private func plantLiveClaudeToken(_ token: String) throws {
    let claudeDir = tempDirectory.appendingPathComponent(".claude", isDirectory: true)
    try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
    try "{\"claudeAiOauth\":{\"accessToken\":\"\(token)\"}}"
      .write(to: claudeDir.appendingPathComponent(".credentials.json"), atomically: true, encoding: .utf8)
  }

  /// A CLI-style edit from a second process: lock, reload, mutate, save.
  private func cliAddKimiAccount(_ name: String) throws {
    let cli = makeDaemon(coordinator: QuotaCoordinator(clients: []))
    try cli.settingsLock.withLock {
      cli.loadConfiguration()
      cli.addAccount(provider: .kimi, displayName: name, credentials: [CredentialField.kimiAPIKey: "k"])
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
    try plantLiveClaudeToken("sk-ant-oat-T1")

    let gate = FetchGate()
    let daemon = makeDaemon(coordinator: QuotaCoordinator(clients: [
      GatedClient(provider: .anthropic, gate: gate)
    ]))
    daemon.addAccount(
      provider: .anthropic,
      credentials: [CredentialField.anthropicAccessToken: "sk-ant-oat-T0"]
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
      midFetch.accounts.first { $0.provider == .anthropic }?.credentials[CredentialField.anthropicAccessToken],
      "sk-ant-oat-T1"
    )

    await gate.release()
    _ = try await edit.value
    _ = await cycle.value

    // After the cycle, both writes must still be there: the merge must not have
    // clobbered the CLI edit, and the CLI edit must not have lost the token.
    let final = try onDiskSettings()
    XCTAssertTrue(final.accounts.contains { $0.provider == .kimi }, "CLI edit was clobbered by the daemon's save")
    XCTAssertEqual(
      final.accounts.first { $0.provider == .anthropic }?.credentials[CredentialField.anthropicAccessToken],
      "sk-ant-oat-T1"
    )
    XCTAssertNotNil(daemon.snapshot)
  }

  // MARK: - The merge itself

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

  func release() async {
    lock.lock()
    isReleased = true
    let continuation = releaseContinuation
    releaseContinuation = nil
    lock.unlock()
    continuation?.resume()
  }
}

private struct GatedClient: QuotaProviderClient {
  let provider: QuotaProvider
  let gate: FetchGate

  func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    gate.fetchEntered()
    await gate.waitUntilReleased()
    return ProviderUsage(
      accountID: configuration.accountID,
      provider: provider,
      title: configuration.displayName,
      metrics: [UsageMetric(id: "weekly", label: "Weekly limit", remainingPercent: 50)],
      fetchedAt: now
    )
  }
}
