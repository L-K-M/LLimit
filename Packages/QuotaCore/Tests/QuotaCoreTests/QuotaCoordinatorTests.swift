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

  func testPartialCancellationKeepsPreviousUsageAndCompletedAuthFailure() async {
    let signal = RefreshSignal()
    let coordinator = QuotaCoordinator(clients: [
      SignalingClient(provider: .openAI, signal: signal),
      SignalingClient(provider: .zhipu, signal: signal, error: ProviderClientError(kind: .auth, message: "Credential rejected")),
      WaitingClient(provider: .anthropic, signal: signal)
    ])
    let seedTime = Date(timeIntervalSince1970: 1_700_000_000)
    let refreshTime = seedTime.addingTimeInterval(100)
    let seed = QuotaSnapshot(
      generatedAt: seedTime,
      providers: [.openAI, .anthropic, .zhipu].map { sampleUsage(provider: $0, at: seedTime) },
      failures: []
    )
    let task = Task {
      await coordinator.refresh(
        configurations: [.openAI, .anthropic, .zhipu].map { configuration(provider: $0) },
        now: refreshTime,
        previousSnapshot: seed
      )
    }
    await waitForClients(signal, count: 3)
    task.cancel()
    let snapshot = await task.value
    let merged = snapshot.mergingStaleUsage(from: seed)

    XCTAssertEqual(snapshot.generatedAt, refreshTime)
    XCTAssertEqual(snapshot.providers.first { $0.provider == .openAI }?.fetchedAt, refreshTime)
    XCTAssertEqual(snapshot.providers.first { $0.provider == .anthropic }, seed.providers[1],
                   "Cancelled accounts need explicit carry-forward, not a synthetic failure")
    XCTAssertEqual(merged.providers.first { $0.provider == .zhipu }?.fetchedAt, seedTime)
    XCTAssertEqual(snapshot.failures.map(\.kind), [.auth])
    XCTAssertEqual(snapshot.failures.first?.provider, .zhipu)
  }

  func testCancellationWithoutFreshUsageKeepsCompletedAuthFailure() async {
    let signal = RefreshSignal()
    let coordinator = QuotaCoordinator(clients: [
      SignalingClient(provider: .zhipu, signal: signal, error: ProviderClientError(kind: .auth, message: "Credential rejected")),
      WaitingClient(provider: .anthropic, signal: signal)
    ])
    let seedTime = Date(timeIntervalSince1970: 1_700_000_000)
    let seed = QuotaSnapshot(
      generatedAt: seedTime,
      providers: [sampleUsage(provider: .anthropic, at: seedTime)],
      failures: []
    )
    let task = Task {
      await coordinator.refresh(
        configurations: [.anthropic, .zhipu].map { configuration(provider: $0) },
        now: seedTime.addingTimeInterval(100),
        previousSnapshot: seed
      )
    }
    await waitForClients(signal, count: 2)
    task.cancel()
    let snapshot = await task.value

    XCTAssertEqual(snapshot.providers, seed.providers)
    XCTAssertEqual(snapshot.failures.map(\.kind), [.auth],
                   "A completed auth failure must survive cancellation even without fresh usage")
  }

  private func waitForClients(_ signal: RefreshSignal, count: Int) async {
    for _ in 0..<500 {
      if await signal.count == count { return }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Clients did not reach the cancellation boundary")
  }

  private func configuration(provider: QuotaProvider) -> ProviderRuntimeConfiguration {
    ProviderRuntimeConfiguration(provider: provider, isEnabled: true, credentials: [:])
  }

  private func sampleUsage(provider: QuotaProvider, at date: Date) -> ProviderUsage {
    ProviderUsage(
      provider: provider,
      title: provider.displayName,
      metrics: [UsageMetric(id: "primary", label: "primary", remainingPercent: 10)],
      maxUsagePercent: 90,
      fetchedAt: date
    )
  }
}

private actor RefreshSignal {
  private(set) var count = 0
  func mark() { count += 1 }
}

private struct SignalingClient: QuotaProviderClient {
  let provider: QuotaProvider
  let signal: RefreshSignal
  var error: ProviderClientError?

  func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    await signal.mark()
    if let error { throw error }
    return ProviderUsage(
      provider: provider,
      title: provider.displayName,
      metrics: [UsageMetric(id: "primary", label: "primary", remainingPercent: 50)],
      maxUsagePercent: 50,
      fetchedAt: now
    )
  }
}

private struct WaitingClient: QuotaProviderClient {
  let provider: QuotaProvider
  let signal: RefreshSignal

  func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    await signal.mark()
    try await Task.sleep(nanoseconds: 60_000_000_000)
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
