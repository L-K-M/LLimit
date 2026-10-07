import Foundation
import XCTest
@testable import QuotaCore

final class RefreshProvenanceTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  func testNonVeniceKeyReplacementDuringFetchCannotPublishOldUsageOrFailure() async {
    for outcome in [GatedProvenanceClient.Outcome.usage, .authFailure] {
      let account = manual("kimi", .kimi, key: "key-a")
      let client = GatedProvenanceClient(provider: .kimi, outcome: outcome)
      let configuration = account.runtimeConfiguration()
      let ownership = RefreshProvenance(configurations: [configuration])
      let fetch = Task { await QuotaCoordinator(clients: [client]).refresh(configurations: [configuration], now: now) }
      await client.waitUntilEntered()
      var replacement = account
      replacement.credentials[CredentialField.kimiAPIKey] = "key-b"
      await client.release()

      let fetched = await fetch.value
      XCTAssertEqual(fetched.providers.count + fetched.failures.count, 1)
      let validated = ownership.validated(fetched, accounts: [replacement], credentialRevisions: [account.id: UUID()])
      XCTAssertTrue(validated.providers.isEmpty)
      XCTAssertTrue(validated.failures.isEmpty)
    }
  }

  func testNonVeniceCommittedKeyReversionDuringAuthRecoveryCannotPublish() async {
    let account = manual("kimi", .kimi, key: "key-a")
    let configuration = account.runtimeConfiguration()
    let originalRevision = UUID()
    let ownership = RefreshProvenance(configurations: [configuration], credentialRevisions: [account.id: originalRevision])
    let first = await QuotaCoordinator(clients: [ImmediateProvenanceClient(provider: .kimi)])
      .refresh(configurations: [configuration], now: now)
    let recoveryClient = GatedProvenanceClient(provider: .openAI)
    let recovering = manual("openai", .openAI, key: "old-access")
    let recovery = Task { await QuotaCoordinator(clients: [recoveryClient]).refresh(configurations: [recovering.runtimeConfiguration()], now: now) }
    await recoveryClient.waitUntilEntered()
    // Two commits restore the text but cannot restore the original request's ownership.
    var current = account
    current.credentials[CredentialField.kimiAPIKey] = "key-b"
    var replacementRevision = UUID()
    current.credentials[CredentialField.kimiAPIKey] = "key-a"
    replacementRevision = UUID()
    await recoveryClient.release()
    _ = await recovery.value

    XCTAssertEqual(current.credentials, account.credentials)
    let validated = ownership.validated(first, accounts: [current], credentialRevisions: [account.id: replacementRevision])
    XCTAssertTrue(validated.providers.isEmpty)
  }

  func testRemovalDisableAndProviderReplacementDuringFetchAreRejected() async {
    let account = manual("account", .kimi, key: "key-a")
    let configuration = account.runtimeConfiguration()
    let ownership = RefreshProvenance(configurations: [configuration])
    let client = GatedProvenanceClient(provider: .kimi)
    let fetch = Task { await QuotaCoordinator(clients: [client]).refresh(configurations: [configuration], now: now) }
    await client.waitUntilEntered()
    var disabled = account
    disabled.isEnabled = false
    let differentProvider = manual(account.id, .venice, key: "key-a")
    await client.release()
    let fetched = await fetch.value

    for current in [[], [disabled], [differentProvider]] {
      XCTAssertTrue(ownership.validated(fetched, accounts: current, credentialRevisions: [:]).providers.isEmpty)
    }
  }

  func testRetryCapturesRotatedCredentialsAndLeavesHealthySiblingIntact() async {
    let sibling = manual("kimi", .kimi, key: "sibling-key")
    let old = manual("openai", .openAI, key: "old-access")
    let configurations = [sibling.runtimeConfiguration(), old.runtimeConfiguration()]
    var ownership = RefreshProvenance(configurations: configurations)
    let first = await QuotaCoordinator(clients: [ImmediateProvenanceClient(provider: .kimi)])
      .refresh(configurations: configurations, now: now)
    var rotated = old
    rotated.credentials[CredentialField.openAIAccessToken] = "rotated-access"
    let retryConfiguration = rotated.runtimeConfiguration()
    ownership.recordQueries([retryConfiguration], credentialRevisions: [:])
    let client = GatedProvenanceClient(provider: .openAI)
    let retry = Task { await QuotaCoordinator(clients: [client]).refresh(configurations: [retryConfiguration], now: now.addingTimeInterval(1)) }
    await client.waitUntilEntered()
    await client.release()
    let retried = await retry.value
    let merged = first.replacingResults(forAccountIDs: [old.id], from: retried)
    let validated = ownership.validated(merged, accounts: [sibling, rotated], credentialRevisions: [:])

    XCTAssertEqual(validated.providers.first { $0.accountID == old.id }, retried.providers.first)
    XCTAssertEqual(validated.providers.first { $0.accountID == sibling.id }, first.providers.first)
  }

  func testRetryDoesNotBlessAUserEditOrReversionAfterItsCapture() async {
    let account = manual("openai", .openAI, key: "rotated-access")
    let configuration = account.runtimeConfiguration()
    var ownership = RefreshProvenance(configurations: [])
    ownership.recordQueries([configuration], credentialRevisions: [:])
    let client = GatedProvenanceClient(provider: .openAI)
    let retry = Task { await QuotaCoordinator(clients: [client]).refresh(configurations: [configuration], now: now) }
    await client.waitUntilEntered()
    var edited = account
    edited.credentials[CredentialField.openAIAccessToken] = "user-replacement"
    var revision = UUID()
    edited.credentials[CredentialField.openAIAccessToken] = "rotated-access"
    revision = UUID()
    await client.release()
    let result = await retry.value

    XCTAssertEqual(edited.credentials, account.credentials)
    XCTAssertTrue(ownership.validated(result, accounts: [edited], credentialRevisions: [account.id: revision]).providers.isEmpty)
  }

  func testSkippedProfileIsBoundAtSelectionAndKeepsItsOriginalTimestamp() async {
    let old = managedOpenAI("openai", profileID: UUID())
    let sibling = manual("kimi", .kimi, key: "sibling-key")
    let previous = QuotaSnapshot(generatedAt: now.addingTimeInterval(-600), providers: [
      usage(old, at: now.addingTimeInterval(-600))
    ], failures: [ProviderFailure(accountID: old.id, provider: .openAI, kind: .auth, message: "Earlier failure")])
    let ownership = RefreshProvenance(configurations: [sibling.runtimeConfiguration()], carriedConfigurations: [old.runtimeConfiguration()])
    let client = GatedProvenanceClient(provider: .kimi)
    let fetch = Task { await QuotaCoordinator(clients: [client]).refresh(configurations: [sibling.runtimeConfiguration()], now: now) }
    await client.waitUntilEntered()
    let reconnected = managedOpenAI(old.id, profileID: UUID())
    await client.release()
    let fresh = await fetch.value
    let carried = fresh.carryingResults(forSkippedAccountIDs: [old.id], from: previous)
    let unchanged = ownership.validated(carried, accounts: [sibling, old], credentialRevisions: [:])
    XCTAssertEqual(unchanged.providers.first { $0.accountID == old.id }?.fetchedAt, previous.generatedAt)
    XCTAssertEqual(unchanged.failures, previous.failures)

    let replaced = ownership.validated(carried, accounts: [sibling, reconnected], credentialRevisions: [:])
    XCTAssertEqual(replaced.providers, fresh.providers)
    XCTAssertTrue(replaced.failures.isEmpty)
  }

  func testTargetedManagedFetchRejectsChangedProfileAndPreservesSibling() async {
    for provider in [QuotaProvider.anthropic, .openAI] {
      let account = provider == .openAI ? managedOpenAI("managed", profileID: UUID()) : managedClaude("managed", profileID: UUID())
      let sibling = manual("kimi", .kimi, key: "sibling-key")
      let configuration = account.runtimeConfiguration()
      let ownership = RefreshProvenance(configurations: [configuration])
      let client = GatedProvenanceClient(provider: provider)
      let fetch = Task { await QuotaCoordinator(clients: [client]).refresh(configurations: [configuration], now: now) }
      await client.waitUntilEntered()
      let replacement = provider == .openAI ? managedOpenAI(account.id, profileID: UUID()) : managedClaude(account.id, profileID: UUID())
      await client.release()
      let result = await fetch.value
      let filtered = ownership.validated(result, accounts: [replacement, sibling], credentialRevisions: [:])
      XCTAssertTrue(filtered.providers.isEmpty)
      let baseline = QuotaSnapshot(generatedAt: now, providers: [usage(sibling, at: now)], failures: [])
      XCTAssertEqual(baseline.replacingResults(forAccountIDs: [account.id], from: filtered).providers, baseline.providers)
    }
  }

  func testRetryBookkeepingCannotReassignAnUnfetchedSkippedProfile() {
    let skipped = managedOpenAI("openai", profileID: UUID())
    let connected = managedOpenAI(skipped.id, profileID: UUID())
    var ownership = RefreshProvenance(configurations: [], carriedConfigurations: [skipped.runtimeConfiguration()])
    ownership.recordQueries([connected.runtimeConfiguration()], credentialRevisions: [:])
    let old = QuotaSnapshot(generatedAt: now, providers: [usage(skipped, at: now.addingTimeInterval(-60))], failures: [])

    XCTAssertTrue(ownership.validated(old, accounts: [connected], credentialRevisions: [:]).providers.isEmpty)
    XCTAssertFalse(ownership.matchesQuery(connected, credentialRevisions: [:]))
  }

  func testOnlyActualQueryProviderAndAccountResultsArePublished() {
    let account = manual("shared-id", .kimi, key: "key")
    let otherProvider = manual(account.id, .venice, key: "key")
    let unknown = manual("not-queried", .kimi, key: "key")
    let validUsage = usage(account, at: now)
    let result = QuotaSnapshot(generatedAt: now,
      providers: [validUsage, usage(otherProvider, at: now), usage(unknown, at: now)],
      failures: [ProviderFailure(accountID: otherProvider.id, provider: .venice, kind: .auth, message: "Wrong provider")])
    let validated = RefreshProvenance(configurations: [account.runtimeConfiguration()])
      .validated(result, accounts: [account, otherProvider, unknown], credentialRevisions: [:])

    XCTAssertEqual(validated.providers, [validUsage])
    XCTAssertTrue(validated.failures.isEmpty)
  }

  func testCommittedReplacementValidationProtectsSnapshotAndHistoryWrites() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SnapshotStore(fileURL: root.appendingPathComponent("snapshot.json"))
    let history = QuotaHistoryStore(fileURL: root.appendingPathComponent("history.json"))
    let account = manual("kimi", .kimi, key: "key-a")
    let sibling = manual("venice", .venice, key: "sibling-key")
    let configurations = [account.runtimeConfiguration(), sibling.runtimeConfiguration()]
    let ownership = RefreshProvenance(configurations: configurations)
    let client = GatedProvenanceClient(provider: .kimi)
    let fetch = Task { await QuotaCoordinator(clients: [client, ImmediateProvenanceClient(provider: .venice)])
      .refresh(configurations: configurations, now: now) }
    await client.waitUntilEntered()
    var replacement = account
    replacement.credentials[CredentialField.kimiAPIKey] = "key-b"
    await client.release()
    let filtered = ownership.validated(await fetch.value, accounts: [replacement, sibling], credentialRevisions: [account.id: UUID()])
    try store.save(filtered)
    try history.append(filtered)

    XCTAssertEqual(try store.load()?.providers.map(\.accountID), [sibling.id])
    XCTAssertEqual(try history.load().last?.providers.map(\.accountID), [sibling.id])
  }

  private func manual(_ id: String, _ provider: QuotaProvider, key: String) -> ProviderAccount {
    let keyName: String
    switch provider {
    case .kimi: keyName = CredentialField.kimiAPIKey
    case .venice: keyName = CredentialField.veniceAPIKey
    default: keyName = CredentialField.openAIAccessToken
    }
    return ProviderAccount(id: id, provider: provider, credentials: [keyName: key])
  }

  private func managedOpenAI(_ id: String, profileID: UUID) -> ProviderAccount {
    ProviderAccount(id: id, provider: .openAI, credentials: CodexAccountProfile(id: profileID)
      .credentials(identity: CodexAccountIdentity(accountID: "account", userID: "user")))
  }

  private func managedClaude(_ id: String, profileID: UUID) -> ProviderAccount {
    ProviderAccount(id: id, provider: .anthropic, credentials: ClaudeCodeProfile.storedCredentials(
      token: ClaudeCodeCredentials(accessToken: "token", expiresAt: now.addingTimeInterval(3600)),
      identity: ClaudeCodeIdentity(accountID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                   organizationID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!), profileID: profileID))
  }

  private func usage(_ account: ProviderAccount, at date: Date) -> ProviderUsage {
    ProviderUsage(accountID: account.id, provider: account.provider, title: account.resolvedDisplayName,
                  metrics: [UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 73)], fetchedAt: date)
  }
}

private actor GatedProvenanceClient: QuotaProviderClient {
  enum Outcome { case usage, authFailure }
  let provider: QuotaProvider
  private let outcome: Outcome
  private var entered = false
  private var enteredWaiter: CheckedContinuation<Void, Never>?
  private var resultWaiter: CheckedContinuation<Void, Never>?

  init(provider: QuotaProvider, outcome: Outcome = .usage) {
    self.provider = provider
    self.outcome = outcome
  }

  func waitUntilEntered() async {
    if entered { return }
    await withCheckedContinuation { enteredWaiter = $0 }
  }

  func release() {
    resultWaiter?.resume()
    resultWaiter = nil
  }

  func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    await withCheckedContinuation { continuation in
      resultWaiter = continuation
      entered = true
      enteredWaiter?.resume()
      enteredWaiter = nil
    }
    if case .authFailure = outcome { throw ProviderClientError(kind: .auth, message: "Synthetic auth failure") }
    return ProviderUsage(accountID: configuration.accountID, provider: provider, title: configuration.displayName,
                         metrics: [UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 73)], fetchedAt: now)
  }
}

private struct ImmediateProvenanceClient: QuotaProviderClient {
  let provider: QuotaProvider

  func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    ProviderUsage(accountID: configuration.accountID, provider: provider, title: configuration.displayName,
                  metrics: [UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 73)], fetchedAt: now)
  }
}
