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
