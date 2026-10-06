import XCTest
@testable import QuotaCore

final class QuotaCoordinatorTests: XCTestCase {
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

  func testCoordinatorIgnoresCancelledTasks() async {
    let successClient = MockClient(provider: .openAI, shouldFail: false)
    let cancelledClient = CancelledMockClient(provider: .anthropic)

    let coordinator = QuotaCoordinator(clients: [successClient, cancelledClient])
    let snapshot = await coordinator.refresh(
      configurations: [
        ProviderRuntimeConfiguration(provider: .openAI, isEnabled: true, credentials: [:]),
        ProviderRuntimeConfiguration(provider: .anthropic, isEnabled: true, credentials: [:])
      ],
      now: Date(timeIntervalSince1970: 1_700_000_000)
    )

    XCTAssertEqual(snapshot.providers.count, 1)
    XCTAssertTrue(snapshot.failures.isEmpty, "Cancelled task must not become a recorded failure")
    XCTAssertEqual(snapshot.providers.first?.provider, .openAI)
  }

  func testCancelledRefreshFallsBackToPreviousSnapshot() async {
    // A refresh cancelled before any provider answered keeps the last good
    // snapshot instead of degrading to an empty one.
    let coordinator = QuotaCoordinator(clients: [
      CancellationAwareClient(provider: .openAI)
    ])
    let configurations = [
      ProviderRuntimeConfiguration(provider: .openAI, isEnabled: true, credentials: [:])
    ]
    let seedTime = Date(timeIntervalSince1970: 1_700_000_000)
    let seed = QuotaSnapshot(
      generatedAt: seedTime,
      providers: [Self.sampleUsage(provider: .openAI, percent: 10, at: seedTime)],
      failures: []
    )

    let task = Task {
      await coordinator.refresh(
        configurations: configurations,
        now: seedTime.addingTimeInterval(100),
        previousSnapshot: seed
      )
    }
    task.cancel()
    let snapshot = await task.value

    XCTAssertEqual(snapshot.generatedAt, seedTime,
                   "Cancelled refresh with no fresh results must return the previous snapshot")
    XCTAssertEqual(snapshot.providers.map(\.provider), [.openAI])
  }

  func testCancelledRefreshKeepsResultsThatAlreadyArrived() async {
    // Cancellation after a provider answered must not discard fresh data.
    let flag = CompletionFlag()
    let coordinator = QuotaCoordinator(clients: [
      SignalingClient(provider: .openAI, flag: flag),
      CancellationAwareClient(provider: .anthropic)
    ])
    let configurations = [
      ProviderRuntimeConfiguration(provider: .openAI, isEnabled: true, credentials: [:]),
      ProviderRuntimeConfiguration(provider: .anthropic, isEnabled: true, credentials: [:])
    ]
    let seedTime = Date(timeIntervalSince1970: 1_700_000_000)
    let seed = QuotaSnapshot(
      generatedAt: seedTime,
      providers: [Self.sampleUsage(provider: .openAI, percent: 10, at: seedTime)],
      failures: []
    )
    let refreshTime = seedTime.addingTimeInterval(100)

    let task = Task {
      await coordinator.refresh(
        configurations: configurations,
        now: refreshTime,
        previousSnapshot: seed
      )
    }
    // Generous budget: the fast path exits on the first iteration, so a
    // larger bound only affects loaded CI runners.
    for _ in 0..<5_000 where await !flag.done {
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    let didFinish = await flag.done
    XCTAssertTrue(didFinish, "Fast client should have completed")
    task.cancel()
    let snapshot = await task.value

    XCTAssertEqual(snapshot.generatedAt, refreshTime,
                   "Late cancellation must keep the fresh partial snapshot")
    XCTAssertEqual(snapshot.providers.map(\.provider), [.openAI])
    XCTAssertEqual(snapshot.providers.first?.metrics.first?.remainingPercent, 50,
                   "Fresh result wins over the previous snapshot")
    XCTAssertTrue(snapshot.failures.isEmpty)
  }

  private static func sampleUsage(provider: QuotaProvider, percent: Int, at date: Date) -> ProviderUsage {
    ProviderUsage(
      provider: provider,
      title: provider.displayName,
      metrics: [UsageMetric(id: "primary", label: "primary", remainingPercent: percent)],
      maxUsagePercent: 100 - percent,
      fetchedAt: date
    )
  }
}

private actor CompletionFlag {
  private(set) var done = false
  func mark() { done = true }
}

private struct SignalingClient: QuotaProviderClient {
  let provider: QuotaProvider
  let flag: CompletionFlag

  func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    await flag.mark()
    return ProviderUsage(
      provider: provider,
      title: provider.displayName,
      metrics: [UsageMetric(id: "primary", label: "primary", remainingPercent: 50)],
      maxUsagePercent: 50,
      fetchedAt: now
    )
  }
}

private struct CancellationAwareClient: QuotaProviderClient {
  let provider: QuotaProvider

  func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    for _ in 0..<5_000 {
      try Task.checkCancellation()
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    return ProviderUsage(provider: provider, title: provider.displayName, metrics: [], fetchedAt: now)
  }
}

private struct CancelledMockClient: QuotaProviderClient {
  let provider: QuotaProvider

  func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    throw CancellationError()
  }
}

private struct MockClient: QuotaProviderClient {
  let provider: QuotaProvider
  let shouldFail: Bool

  func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    if shouldFail {
      throw ProviderClientError(kind: .api, message: "Synthetic failure")
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
