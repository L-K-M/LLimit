import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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

  func testRefreshWithNoTargetsUsesTheCurrentTimestamp() async {
    let previousTime = Date(timeIntervalSince1970: 1_700_000_000)
    let now = previousTime.addingTimeInterval(600)
    let previous = QuotaSnapshot(generatedAt: previousTime, providers: [sampleUsage(provider: .openAI, at: previousTime)],
                                 failures: [ProviderFailure(provider: .openAI, kind: .auth, message: "Rejected")])
    let coordinator = QuotaCoordinator(clients: [MockClient(provider: .openAI, shouldFail: false)])
    for configurations in [[], [ProviderRuntimeConfiguration(provider: .openAI, isEnabled: false, credentials: [:])],
                           [ProviderRuntimeConfiguration(provider: .kimi, isEnabled: true, credentials: [:])]] {
      let snapshot = await coordinator.refresh(configurations: configurations, now: now, previousSnapshot: previous)
      XCTAssertEqual(snapshot.generatedAt, now)
      XCTAssertTrue(snapshot.providers.isEmpty)
      XCTAssertTrue(snapshot.failures.isEmpty)
    }
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

  func testCooldownIsScopedToEnabledAccountAndProvider() async {
    let client = RecordingClient(provider: .anthropic)
    let other = RecordingClient(provider: .openAI)
    let coordinator = QuotaCoordinator(clients: [client, other])
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let priorUsage = sampleUsage(provider: .anthropic, at: now.addingTimeInterval(-600))
    let limited = ProviderFailure(accountID: "anthropic", provider: .anthropic, kind: .rateLimit,
                                  message: "limited", retryAt: now.addingTimeInterval(600))
    let previous = QuotaSnapshot(generatedAt: now.addingTimeInterval(-600), providers: [priorUsage], failures: [
      limited,
      ProviderFailure(accountID: "removed", provider: .anthropic, kind: .rateLimit, message: "limited", retryAt: now.addingTimeInterval(600)),
      ProviderFailure(accountID: "disabled", provider: .anthropic, kind: .rateLimit, message: "limited", retryAt: now.addingTimeInterval(600)),
      ProviderFailure(accountID: "shared-id", provider: .anthropic, kind: .rateLimit, message: "limited", retryAt: now.addingTimeInterval(600)),
      ProviderFailure(accountID: "auth", provider: .anthropic, kind: .auth, message: "rejected", retryAt: now.addingTimeInterval(600))
    ])
    let configurations = [
      configuration(provider: .anthropic),
      ProviderRuntimeConfiguration(accountID: "auth", provider: .anthropic, isEnabled: true, credentials: [:]),
      ProviderRuntimeConfiguration(accountID: "healthy", provider: .anthropic, isEnabled: true, credentials: [:]),
      ProviderRuntimeConfiguration(accountID: "disabled", provider: .anthropic, isEnabled: false, credentials: [:]),
      ProviderRuntimeConfiguration(accountID: "shared-id", provider: .openAI, isEnabled: true, credentials: [:])
    ]
    let snapshot = await coordinator.refresh(configurations: configurations, now: now, previousSnapshot: previous)
    let fetched = await client.fetchedAccountIDs
    let otherFetched = await other.fetchedAccountIDs
    XCTAssertEqual(Set(fetched), ["auth", "healthy"])
    XCTAssertEqual(otherFetched, ["shared-id"])
    XCTAssertEqual(snapshot.failures, [limited])
    XCTAssertEqual(snapshot.mergingStaleUsage(from: previous).providers.first { $0.accountID == "anthropic" }, priorUsage)

    _ = await coordinator.refresh(configurations: [configuration(provider: .anthropic)], now: now.addingTimeInterval(600), previousSnapshot: snapshot)
    let afterExpiry = await client.fetchedAccountIDs
    XCTAssertTrue(afterExpiry.contains("anthropic"))
  }

  func testRateLimitDeadlineIsBoundedAtClientAndSnapshotBoundaries() async {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    for delay in [90.0, 1e20, Double.infinity, -30] {
      let client = SignalingClient(provider: .zhipu, signal: RefreshSignal(),
                                   error: ProviderClientError(kind: .rateLimit, message: "limited", retryAfter: delay))
      let snapshot = await QuotaCoordinator(clients: [client]).refresh(configurations: [configuration(provider: .zhipu)], now: now)
      let expected = delay.isFinite && delay > 0 ? now.addingTimeInterval(min(delay, 86_400)) : nil
      XCTAssertEqual(snapshot.failures.first?.retryAt, expected)
    }

    let client = RecordingClient(provider: .anthropic)
    let previous = QuotaSnapshot(generatedAt: now, providers: [], failures: [
      ProviderFailure(provider: .anthropic, kind: .rateLimit, message: "limited", retryAt: .distantFuture)
    ])
    let coordinator = QuotaCoordinator(clients: [client])
    let capped = await coordinator.refresh(configurations: [configuration(provider: .anthropic)], now: now, previousSnapshot: previous)
    XCTAssertEqual(capped.failures.first?.retryAt, now.addingTimeInterval(86_400))
    _ = await coordinator.refresh(configurations: [configuration(provider: .anthropic)], now: now.addingTimeInterval(86_400), previousSnapshot: capped)
    let fetched = await client.fetchedAccountIDs
    XCTAssertEqual(fetched, ["anthropic"])

    let futureSnapshot = QuotaSnapshot(generatedAt: now.addingTimeInterval(7 * 86_400), providers: [], failures: previous.failures)
    let futureCapped = await coordinator.refresh(configurations: [configuration(provider: .anthropic)], now: now, previousSnapshot: futureSnapshot)
    XCTAssertEqual(futureCapped.failures.first?.retryAt, now.addingTimeInterval(86_400),
                   "A future snapshot timestamp must not extend the cooldown cap")
  }

  func testCancelledOnlyRefreshKeepsTimestampAndActiveScope() async {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let coordinator = QuotaCoordinator(clients: [CancelledClient(provider: .anthropic)])
    let previous = QuotaSnapshot(generatedAt: now, providers: [.anthropic, .openAI].map { sampleUsage(provider: $0, at: now) }, failures: [])
    let snapshot = await coordinator.refresh(configurations: [configuration(provider: .anthropic)], now: now.addingTimeInterval(60), previousSnapshot: previous)
    XCTAssertEqual(snapshot.generatedAt, now)
    XCTAssertEqual(snapshot.providers.map(\.provider), [.anthropic])
    XCTAssertTrue(snapshot.failures.isEmpty)

    let first = await coordinator.refresh(configurations: [configuration(provider: .anthropic)], now: now)
    XCTAssertTrue(first.providers.isEmpty)
    XCTAssertTrue(first.failures.isEmpty)
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

extension QuotaCoordinatorTests {
  func testMalformedClinePercentagesKeepLastGoodUsageWhenMerged() async throws {
    for window in [#"{"type":"weekly"}"#, #"{"type":"weekly","percentUsed":null}"#] {
      try await assertMalformedSubscriptionKeepsLastGoodUsage(
        provider: .cline, kind: .decoding,
        http: SubscriptionFixtureHTTP(clineLimits: #"{"success":true,"data":{"limits":[\#(window)]}}"#)
      )
    }
  }

  func testMalformedMuseResponsesKeepLastGoodUsageWhenMerged() async throws {
    for body in [
      "event: response.subscription_usage\ndata: {\"weekly\":{}}\n\n",
      "event: response.subscription_usage\ndata: {\"window\":{\"used_percent\":10},\"weekly\":{}}\n\n",
      SubscriptionFixtureHTTP().museBody + "event: response.subscription_usage\ndata: {\"weekly\":{}}\n\n",
      #"{"type":"response.completed","response":{"id":"fixture","subscription_usage":{"weekly":{}}}}"#
    ] {
      try await assertMalformedSubscriptionKeepsLastGoodUsage(
        provider: .metaMuse, kind: .decoding, http: SubscriptionFixtureHTTP(museBody: body)
      )
    }
    try await assertMalformedSubscriptionKeepsLastGoodUsage(
      provider: .metaMuse, kind: .api, http: SubscriptionFixtureHTTP(museBody: "{}")
    )
  }

  func testMuseStreamErrorAfterSubscriptionSnapshotKeepsLastGoodUsage() async throws {
    let snapshot = "event: response.subscription_usage\ndata: {\"weekly\":{\"used_percent\":10}}\n\n"
    for terminal in [
      "event: error\ndata: {\"type\":\"error\",\"message\":\"terminal-fixture\"}\n\n",
      "event: response.failed\ndata: {\"type\":\"response.failed\",\"response\":{\"id\":\"fixture\",\"error\":{\"message\":\"terminal-fixture\"}}}\n\n"
    ] {
      try await assertMalformedSubscriptionKeepsLastGoodUsage(
        provider: .metaMuse, kind: .api, http: SubscriptionFixtureHTTP(museBody: snapshot + terminal)
      )
    }
  }

  func testSubscriptionFixtureRejectsUnexpectedRoutes() async {
    let routes = [
      ("POST", "https://fixture.invalid/v1/responses"),
      ("POST", "https://api.meta.ai/v1/unexpected"),
      ("GET", "https://fixture.invalid/api/v1/users/me/plan/usage-limits"),
      ("GET", "https://api.cline.bot/unexpected/balance"),
      ("GET", "https://api.cline.bot/api/v1/users/usr-OTHER/balance"),
      ("GET", "https://api.cline.bot/api/v1/unexpected"),
      ("GET", "https://api.meta.ai/v1/responses"),
      ("POST", "https://api.cline.bot/api/v1/users/me"),
      ("GET", "http://api.cline.bot/api/v1/users/me"),
      ("GET", "https://api.cline.bot/api/v1/users/me?unexpected=1")
    ]
    for (method, url) in routes {
      var request = URLRequest(url: URL(string: url)!)
      request.httpMethod = method
      do {
        _ = try await SubscriptionFixtureHTTP().data(for: request)
        XCTFail("Unexpected fixture route accepted: \(method) \(url)")
      } catch let error as URLError {
        XCTAssertEqual(error.code, .unsupportedURL, "\(method) \(url)")
      } catch {
        XCTFail("Unexpected fixture error: \(error)")
      }
    }
  }

  func testSubscriptionFixtureRejectsMissingURL() async {
    var request = URLRequest(url: URL(string: "https://fixture.invalid")!)
    request.url = nil
    XCTAssertNil(request.url)
    do {
      _ = try await SubscriptionFixtureHTTP().data(for: request)
      XCTFail("Expected a bad URL error")
    } catch let error as URLError {
      XCTAssertEqual(error.code, .badURL)
    } catch {
      XCTFail("Unexpected fixture error: \(error)")
    }
  }

  private func assertMalformedSubscriptionKeepsLastGoodUsage(
    provider: QuotaProvider, kind: QuotaErrorKind, http: SubscriptionFixtureHTTP,
    file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    let configurations = [
      ProviderRuntimeConfiguration(accountID: "cline-fixture", provider: .cline, displayName: "Cline", isEnabled: true,
                                   credentials: [CredentialField.clineAPIKey: "cline-test-fixture"]),
      ProviderRuntimeConfiguration(accountID: "muse-fixture", provider: .metaMuse, displayName: "Muse", isEnabled: true,
                                   credentials: [CredentialField.metaMuseAPIKey: "muse-test-fixture"])
    ]
    let previousTime = Date(timeIntervalSince1970: 1_790_000_000)
    let refreshTime = previousTime.addingTimeInterval(900)
    let previous = await QuotaCoordinator.live(httpClient: SubscriptionFixtureHTTP())
      .refresh(configurations: configurations, now: previousTime)
    XCTAssertTrue(previous.failures.isEmpty, file: file, line: line)
    let lastGood = try XCTUnwrap(previous.providers.first { $0.provider == provider }, file: file, line: line)
    let fresh = await QuotaCoordinator.live(httpClient: http)
      .refresh(configurations: configurations, now: refreshTime, previousSnapshot: previous)

    XCTAssertEqual(fresh.failures.map(\.accountID), [lastGood.accountID], file: file, line: line)
    XCTAssertEqual(fresh.failures.map(\.provider), [provider], file: file, line: line)
    XCTAssertEqual(fresh.failures.map(\.kind), [kind], file: file, line: line)
    XCTAssertFalse(fresh.providers.contains { $0.provider == provider }, file: file, line: line)
    XCTAssertEqual(fresh.providers.count, 1, file: file, line: line)
    XCTAssertEqual(fresh.providers.first?.fetchedAt, refreshTime, file: file, line: line)

    let merged = fresh.mergingStaleUsage(from: previous)
    XCTAssertEqual(merged.providers.first { $0.provider == provider }, lastGood, file: file, line: line)
    XCTAssertEqual(merged.providers.count, 2, file: file, line: line)
    XCTAssertEqual(merged.failures, fresh.failures, file: file, line: line)
    XCTAssertEqual(merged.generatedAt, refreshTime, file: file, line: line)
  }
}

// All responses are local fixtures, including those used by the live coordinator's clients.
private struct SubscriptionFixtureHTTP: HTTPClient {
  private static let successStatus = 200

  var clineLimits = #"{"success":true,"data":{"limits":[{"type":"weekly","percentUsed":60}]}}"#
  var museBody = "event: response.subscription_usage\ndata: {\"weekly\":{\"used_percent\":70}}\n\n"

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    guard let url = request.url else { throw URLError(.badURL) }

    // Exact routes expose request drift instead of returning unrelated payloads.
    let body: String
    switch (request.httpMethod, url.absoluteString) {
    case ("POST", "https://api.meta.ai/v1/responses"):
      body = museBody
    case ("GET", "https://api.cline.bot/api/v1/users/me/plan/usage-limits"):
      body = clineLimits
    case ("GET", "https://api.cline.bot/api/v1/users/usr-FIXTURE/balance"):
      body = #"{"success":true,"data":{"balance":4250000}}"#
    case ("GET", "https://api.cline.bot/api/v1/users/me"):
      body = #"{"success":true,"data":{"id":"usr-FIXTURE"}}"#
    default:
      throw URLError(.unsupportedURL)
    }

    return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: Self.successStatus, httpVersion: nil, headerFields: nil)!)
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

private actor RecordingClient: QuotaProviderClient {
  let provider: QuotaProvider
  private(set) var fetchedAccountIDs: [String] = []

  init(provider: QuotaProvider) { self.provider = provider }

  func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    fetchedAccountIDs.append(configuration.accountID)
    return ProviderUsage(accountID: configuration.accountID, provider: provider, title: configuration.displayName,
                         metrics: [], fetchedAt: now)
  }
}

private struct CancelledClient: QuotaProviderClient {
  let provider: QuotaProvider

  func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    throw CancellationError()
  }
}
