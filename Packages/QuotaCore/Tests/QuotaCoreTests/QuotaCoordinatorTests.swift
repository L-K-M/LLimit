import XCTest
@testable import QuotaCore

final class QuotaCoordinatorTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  func testCoordinatorAggregatesSuccessAndFailure() async {
    let successClient = MockClient(provider: .openAI, shouldFail: false)
    let failureClient = MockClient(provider: .zhipu, shouldFail: true)

    let coordinator = QuotaCoordinator(clients: [successClient, failureClient])
    let snapshot = await coordinator.refresh(
      configurations: [
        ProviderRuntimeConfiguration(provider: .openAI, isEnabled: true, credentials: [:]),
        ProviderRuntimeConfiguration(provider: .zhipu, isEnabled: true, credentials: [:])
      ],
      now: Date(timeIntervalSince1970: 1_700_000_000)
    )

    XCTAssertEqual(snapshot.providers.count, 1)
    XCTAssertEqual(snapshot.failures.count, 1)
    XCTAssertEqual(snapshot.providers.first?.provider, .openAI)
    XCTAssertEqual(snapshot.providers.first?.accountID, QuotaProvider.openAI.rawValue)
    XCTAssertEqual(snapshot.failures.first?.provider, .zhipu)
  }

  func testClientRetryAfterBecomesFailureRetryAt() async {
    let client = MockClient(provider: .zhipu, error: ProviderClientError(kind: .rateLimit, message: "limited", retryAfter: 90))
    let coordinator = QuotaCoordinator(clients: [client])

    let snapshot = await coordinator.refresh(
      configurations: [ProviderRuntimeConfiguration(provider: .zhipu, isEnabled: true, credentials: [:])],
      now: now
    )

    let retryAt = try? XCTUnwrap(snapshot.failures.first?.retryAt)
    XCTAssertEqual(retryAt?.timeIntervalSince(now) ?? 0, 90, accuracy: 0.001)
  }

  // The server said when it would accept the next request: repolling a
  // rate-limited account before that time just hardens the limit.
  func testCooldownSkipsRateLimitedAccountUntilRetryAt() async {
    let cooledClient = RecordingClient(provider: .anthropic)
    let healthyClient = RecordingClient(provider: .openAI)
    let coordinator = QuotaCoordinator(clients: [cooledClient, healthyClient])

    let previous = QuotaSnapshot(
      generatedAt: now.addingTimeInterval(-600),
      providers: [
        ProviderUsage(
          provider: .anthropic,
          title: "Claude",
          metrics: [UsageMetric(id: "five_hour", label: "5-hour limit", remainingPercent: 40)],
          maxUsagePercent: 60,
          fetchedAt: now.addingTimeInterval(-600)
        )
      ],
      failures: [
        ProviderFailure(
          provider: .anthropic,
          kind: .rateLimit,
          message: "rate limited",
          retryAt: now.addingTimeInterval(600)
        )
      ]
    )

    let snapshot = await coordinator.refresh(
      configurations: [
        ProviderRuntimeConfiguration(provider: .anthropic, isEnabled: true, credentials: [:]),
        ProviderRuntimeConfiguration(provider: .openAI, isEnabled: true, credentials: [:])
      ],
      now: now,
      previousSnapshot: previous
    )

    let fetched = await cooledClient.fetchedAccountIDs
    XCTAssertTrue(fetched.isEmpty, "an account inside its Retry-After window must not be polled")
    let healthyFetched = await healthyClient.fetchedAccountIDs
    XCTAssertEqual(healthyFetched, [QuotaProvider.openAI.rawValue])

    // The failure carries forward with its retry time; the stale usage is the
    // caller's job (mergingStaleUsage), keyed off the failure's presence.
    XCTAssertEqual(snapshot.failures.first?.kind, .rateLimit)
    XCTAssertEqual(snapshot.failures.first?.retryAt, now.addingTimeInterval(600))
    XCTAssertFalse(snapshot.providers.contains { $0.provider == .anthropic })
  }

  func testExpiredCooldownRefetches() async {
    let cooledClient = RecordingClient(provider: .anthropic)
    let coordinator = QuotaCoordinator(clients: [cooledClient])
    let previous = QuotaSnapshot(
      generatedAt: now.addingTimeInterval(-1_800),
      providers: [],
      failures: [
        ProviderFailure(provider: .anthropic, kind: .rateLimit, message: "rate limited", retryAt: now.addingTimeInterval(-60))
      ]
    )

    _ = await coordinator.refresh(
      configurations: [ProviderRuntimeConfiguration(provider: .anthropic, isEnabled: true, credentials: [:])],
      now: now,
      previousSnapshot: previous
    )

    let fetched = await cooledClient.fetchedAccountIDs
    XCTAssertEqual(fetched, [QuotaProvider.anthropic.rawValue], "a past retryAt must not block the next poll")
  }

  func testNonRateLimitFailuresNeverEnterCooldown() async {
    let client = RecordingClient(provider: .anthropic)
    let coordinator = QuotaCoordinator(clients: [client])
    let previous = QuotaSnapshot(
      generatedAt: now.addingTimeInterval(-600),
      providers: [],
      failures: [
        ProviderFailure(provider: .anthropic, kind: .auth, message: "bad token", retryAt: now.addingTimeInterval(600))
      ]
    )

    _ = await coordinator.refresh(
      configurations: [ProviderRuntimeConfiguration(provider: .anthropic, isEnabled: true, credentials: [:])],
      now: now,
      previousSnapshot: previous
    )

    let fetched = await client.fetchedAccountIDs
    XCTAssertEqual(fetched, [QuotaProvider.anthropic.rawValue])
  }
}

private struct MockClient: QuotaProviderClient {
  let provider: QuotaProvider
  let shouldFail: Bool
  var error: ProviderClientError?

  init(provider: QuotaProvider, shouldFail: Bool) {
    self.init(provider: provider, error: shouldFail ? ProviderClientError(kind: .api, message: "Synthetic failure") : nil)
  }

  init(provider: QuotaProvider, error: ProviderClientError?) {
    self.provider = provider
    self.shouldFail = error != nil
    self.error = error
  }

  func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    if let error {
      throw error
    }

    return ProviderUsage(
      provider: provider,
      title: provider.displayName,
      metrics: [UsageMetric(id: "primary", label: "primary", remainingPercent: 50)],
      maxUsagePercent: 50,
      fetchedAt: now
    )
  }
}

/// Records every fetched accountID so cooldown tests can prove an account
/// was skipped rather than merely failed.
private actor RecordingClient: QuotaProviderClient {
  let provider: QuotaProvider
  private(set) var fetchedAccountIDs: [String] = []

  init(provider: QuotaProvider) {
    self.provider = provider
  }

  func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    fetchedAccountIDs.append(configuration.accountID)
    return ProviderUsage(
      provider: provider,
      title: provider.displayName,
      metrics: [UsageMetric(id: "primary", label: "primary", remainingPercent: 50)],
      maxUsagePercent: 50,
      fetchedAt: now
    )
  }
}
