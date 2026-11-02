import Foundation
import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class LongcatQuotaTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_793_600_000)
  private let header = "owned_session_fixture=longcat-secret-fixture"

  private func configuration(id: String = "longcat-personal", header: String? = nil, user: String = "123") -> ProviderRuntimeConfiguration {
    ProviderRuntimeConfiguration(accountID: id, provider: .longcat, displayName: "Personal Longcat", isEnabled: true,
      credentials: [CredentialField.longcatSessionCookies: header ?? self.header, CredentialField.longcatUserID: user])
  }

  private func snapshot(_ amount: Double, previous: QuotaSnapshot? = nil, offset: Double = 0,
                        configuration: ProviderRuntimeConfiguration? = nil) async -> QuotaSnapshot {
    await QuotaCoordinator.live(httpClient: LongcatHTTP(amount: amount)).refresh(
      configurations: [configuration ?? self.configuration()], now: now.addingTimeInterval(offset), previousSnapshot: previous)
  }

  func testAnyIncreaseBecomesOneHundredEvenBelowOldPeak() async throws {
    let first = await snapshot(1_000)
    let spent = await snapshot(400, previous: first, offset: 1)
    let partialRefill = await snapshot(600, previous: spent, offset: 2)
    let spentAgain = await snapshot(300, previous: partialRefill, offset: 3)
    let unchanged = await snapshot(300, previous: spentAgain, offset: 4)
    let exhausted = await snapshot(0, previous: unchanged, offset: 5)
    XCTAssertEqual([first, spent, partialRefill, spentAgain, unchanged, exhausted].map {
      $0.providers.first?.metrics.first?.remainingPercent
    }, [100, 40, 100, 50, 50, 0])
    XCTAssertEqual(partialRefill.providers.first?.metrics.first?.estimatedTotal, 600)
    XCTAssertEqual(exhausted.providers.first?.metrics.first?.estimatedTotal, 600)
    let metric = try XCTUnwrap(spentAgain.providers.first?.metrics.first)
    XCTAssertTrue(metric.isPercentageEstimated)
    XCTAssertNil(metric.resetAt)
    XCTAssertNil(metric.windowSeconds)
    XCTAssertEqual(QuotaWindowKind.classify(metricID: metric.id, label: metric.label), .other)
    XCTAssertEqual(defaultRingMetrics(for: spentAgain.providers[0]).map(\.id), ["token-balance"])
    XCTAssertEqual(spentAgain.providers.first?.maxUsagePercent, 50)
  }

  func testBaselineSurvivesSnapshotStoreRestartAndFailedRefresh() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SnapshotStore(fileURL: directory.appendingPathComponent("snapshot.json"))
    let first = await snapshot(1_000)
    try store.save(first)
    let reloaded = try XCTUnwrap(store.load())
    let spent = await snapshot(250, previous: reloaded, offset: 1)
    XCTAssertEqual(spent.providers.first?.metrics.first?.remainingPercent, 25)
    let failure = await QuotaCoordinator.live(httpClient: LongcatHTTP(amount: 0, status: 503)).refresh(
      configurations: [configuration()], now: now.addingTimeInterval(2), previousSnapshot: spent)
    let retained = failure.mergingStaleUsage(from: spent)
    XCTAssertEqual(retained.providers.first?.metrics.first?.estimatedTotal, 1_000)
    XCTAssertEqual(retained.providers.first?.fetchedAt, spent.providers.first?.fetchedAt)
    let recovered = await snapshot(200, previous: retained, offset: 3)
    XCTAssertEqual(recovered.providers.first?.metrics.first?.remainingPercent, 20)
    let encoded = String(decoding: try JSONEncoder().encode(recovered), as: UTF8.self)
    XCTAssertFalse(encoded.contains("longcat-secret-fixture"))
    XCTAssertFalse(encoded.contains("owned_session_fixture"))
  }

  func testDifferentAccountsAndCredentialsStartSeparateBaselines() async throws {
    let first = await snapshot(1_000)
    let otherAccount = await snapshot(250, previous: first, offset: 1, configuration: configuration(id: "work"))
    let replaced = await snapshot(250, previous: first, offset: 1,
      configuration: configuration(header: "owned_session_fixture=replacement-fixture"))
    XCTAssertEqual(otherAccount.providers.first?.metrics.first?.remainingPercent, 100)
    XCTAssertEqual(replaced.providers.first?.metrics.first?.remainingPercent, 100)
    XCTAssertEqual(replaced.providers.first?.metrics.first?.estimatedTotal, 250)
  }

  func testPreviousBalancesStaySeparateWhenProvidersShareAnAccountID() async {
    let config = configuration(id: "shared-id")
    var previous = await snapshot(1_000, configuration: config)
    previous.providers.append(ProviderUsage(accountID: "shared-id", provider: .venice, title: "Venice",
      metrics: [UsageMetric(id: "daily-diem", label: "Daily DIEM remaining", remainingPercent: 50,
        remainingAmount: 5, estimatedTotal: 10)],
      fetchedAt: now.addingTimeInterval(1)))
    let next = await snapshot(500, previous: previous, offset: 2, configuration: config)
    XCTAssertEqual(next.providers.first?.metrics.first?.remainingPercent, 50)
    XCTAssertEqual(next.providers.first?.metrics.first?.estimatedTotal, 1_000)
  }

  func testInitialZeroWaitsForPositiveBaseline() async {
    let zero = await snapshot(0)
    XCTAssertEqual(zero.providers.first?.metrics.first?.remainingAmount, 0)
    XCTAssertNil(zero.providers.first?.metrics.first?.remainingPercent)
    XCTAssertNil(zero.providers.first?.metrics.first?.estimatedTotal)
    let refilled = await snapshot(500, previous: zero, offset: 1)
    XCTAssertEqual(refilled.providers.first?.metrics.first?.remainingPercent, 100)
  }

  func testOlderResponseCannotReplaceBaseline() async {
    let first = await snapshot(1_000)
    let spent = await snapshot(400, previous: first, offset: 2)
    let delayed = await snapshot(600, previous: spent, offset: 1)
    XCTAssertEqual(delayed.providers.first?.metrics.first?.remainingPercent, 40)
    XCTAssertEqual(delayed.providers.first?.metrics.first?.estimatedTotal, 1_000)
    XCTAssertEqual(delayed.providers.first?.metrics.first?.remainingAmount, 400)
  }

  func testClientRequestContractAndManualValidation() async throws {
    let http = LongcatHTTP(amount: 42)
    let saved = try await LongcatQuotaClient(httpClient: http).verifiedManualCredentials(
      header: header + "; _ga=analytics-fixture", now: now)
    XCTAssertEqual(saved[CredentialField.longcatSessionCookies], header)
    XCTAssertEqual(saved[CredentialField.longcatUserID], "123")
    XCTAssertEqual(saved.count, 2)
    let requests = await http.requests
    XCTAssertEqual(requests.map { $0.url?.path }, ["/api/v1/user-current", "/api/pay/quota/metering/token-packs/summary"])
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
    XCTAssertEqual(requests.last?.httpBody, Data("{}".utf8))
    XCTAssertTrue(requests.allSatisfy { !$0.httpShouldHandleCookies && $0.cachePolicy == .reloadIgnoringLocalCacheData })
    XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == header })
    XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
  }

  func testAnonymousOrWrongIdentityIsRejectedBeforeQuotaRequest() async throws {
    for user in [#"{"loginStatus":0,"userId":null}"#, #"{"loginStatus":1,"userId":"456"}"#] {
      let http = LongcatHTTP(amount: 42, user: user)
      do {
        _ = try await LongcatQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
        XCTFail("Must reject unverified identity")
      } catch let error as ProviderClientError { XCTAssertEqual(error.kind, .auth) }
      let count = await http.requests.count
      XCTAssertEqual(count, 1)
    }
  }

  func testSummaryScopesRemainSeparateAndLotOrderDoesNotChangeMetricIDs() async throws {
    let scope = #"{\"models\":[\"Longcat-2.5\"]}"#
    let current = #"{"lotId":"one","status":"ACTIVE","remainingToken":"100","modelScope":"\#(scope)"}"#
    let other = #"{"lotId":"two","status":"ACTIVE","remainingToken":50,"modelScope":"\#(scope)"},{"lotId":"all","remainingToken":25}"#
    let body = #"{"code":0,"data":{"currentLot":\#(current),"otherLots":[\#(other)]}}"#
    let usage = try await LongcatQuotaClient(httpClient: LongcatHTTP(amount: 0, summary: body))
      .fetchUsage(configuration: configuration(), now: now)
    XCTAssertEqual(usage.metrics.count, 2)
    XCTAssertEqual(usage.metrics.first { $0.id == "token-balance" }?.remainingAmount, 25)
    XCTAssertEqual(usage.metrics.first { $0.id != "token-balance" }?.remainingAmount, 150)
    XCTAssertTrue(usage.metrics.allSatisfy { $0.remainingPercent == nil && $0.estimatedTotal == nil })
  }

  func testMissingOrEmptyModelListsMeanAllModels() async throws {
    for scope in ["{}", #"{\"models\":[]}"#] {
      let body = #"{"code":0,"data":{"currentLot":{"lotId":"unscoped","remainingToken":50,"modelScope":"\#(scope)"},"otherLots":[]}}"#
      let usage = try await LongcatQuotaClient(httpClient: LongcatHTTP(amount: 0, summary: body))
        .fetchUsage(configuration: configuration(), now: now)
      XCTAssertEqual(usage.metrics.first?.id, "token-balance")
      XCTAssertEqual(usage.metrics.first?.remainingAmount, 50)
    }
  }

  func testMalformedQuotaCannotPublishFabricatedZero() async throws {
    for data in [
      #"{"currentLot":{"lotId":"a","remainingToken":true},"otherLots":[]}"#,
      #"{"currentLot":{"lotId":"a","remainingToken":-1},"otherLots":[]}"#,
      #"{"currentLot":{"lotId":"a","remainingToken":"NaN"},"otherLots":[]}"#,
      #"{"currentLot":{"lotId":"a","remainingToken":3}}"#,
      #"{"currentLot":{"lotId":"a","remainingToken":3},"otherLots":[{"lotId":"a","remainingToken":3}]}"#
    ] {
      let http = LongcatHTTP(amount: 0, summary: #"{"code":0,"data":\#(data)}"#)
      do {
        _ = try await LongcatQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
        XCTFail("Invalid counts must fail")
      } catch let error as ProviderClientError { XCTAssertEqual(error.kind, .decoding) }
    }
  }

  func testLegacyFallbackOnlyForAbsentSummaryAndKeepsAvailableTokens() async throws {
    for missing in [false, true] {
      let http = LongcatHTTP(amount: 80, summary: #"{"code":0,"data":{"currentLot":null,"otherLots":[]}}"#,
        summaryStatus: missing ? 404 : 200)
      let usage = try await LongcatQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
      XCTAssertEqual(usage.metrics.first?.remainingAmount, 80)
      let paths = await http.requests.map { $0.url!.path }
      XCTAssertEqual(paths.last, "/api/lc-platform/v1/tokenUsage")
    }
  }

  func testMissingLegacyEndpointIsRequestedOnlyOnceAfterEmptySummary() async {
    let http = LongcatHTTP(amount: 0, summary: #"{"code":0,"data":{"currentLot":null,"otherLots":[]}}"#,
      legacyStatus: 404)
    do {
      _ = try await LongcatQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
      XCTFail("An unavailable legacy endpoint must fail the refresh")
    } catch let error as ProviderClientError { XCTAssertEqual(error.statusCode, 404) }
    catch { XCTFail("Unexpected error") }
    let paths = await http.requests.map { $0.url!.path }
    XCTAssertEqual(paths.filter { $0 == "/api/lc-platform/v1/tokenUsage" }.count, 1)
  }

  func testAuthRateLimitsAndAPIFailuresDoNotLeakResponseTextOrFallback() async throws {
    for (status, code, expected) in [(200, 401, QuotaErrorKind.auth), (200, 429, .rateLimit), (429, 0, .rateLimit),
                                    (302, 0, .auth), (503, 0, .api)] {
      let http = LongcatHTTP(amount: 0,
        summary: #"{"code":\#(code),"msg":"longcat-secret-fixture","data":null}"#, summaryStatus: status)
      do {
        _ = try await LongcatQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
        XCTFail("Must fail closed")
      } catch let error as ProviderClientError {
        XCTAssertEqual(error.kind, expected)
        XCTAssertFalse(error.message.contains("longcat-secret-fixture"))
      }
      let count = await http.requests.count
      XCTAssertEqual(count, 2)
    }
  }

  func testFailurePolicyRedactsIndividualCookieValues() async throws {
    let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: "owned_session_fixture", .value: "browser-secret-fixture",
      .domain: "longcat.chat", .path: "/", .secure: "TRUE", HTTPCookiePropertyKey("HttpOnly"): "TRUE"]))
    let browser = try LongcatBrowserSession(cookies: [cookie], now: now)
    let browserConfig = ProviderRuntimeConfiguration(accountID: "browser", provider: .longcat,
      displayName: "Longcat", isEnabled: true, credentials: try browser.credentials(userID: "123"))
    let manualConfig = configuration(header: #"owned_session_fixture="quoted-secret-fixture"; other=second-secret-fixture"#)
    let message = #"browser-secret-fixture "quoted-secret-fixture" quoted-secret-fixture second-secret-fixture"#
    let result = await QuotaCoordinator(clients: [LongcatFailureClient(message: message)]).refresh(
      configurations: [browserConfig, manualConfig], now: now)
    XCTAssertEqual(result.failures.count, 2)
    let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    for secret in ["browser-secret-fixture", "quoted-secret-fixture", "second-secret-fixture"] {
      XCTAssertFalse(json.contains(secret))
    }
    XCTAssertTrue(result.failures.allSatisfy { $0.message.contains("[redacted]") })
  }
}

private struct LongcatFailureClient: QuotaProviderClient {
  let provider: QuotaProvider = .longcat
  let message: String
  func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    throw ProviderClientError(kind: .auth, message: message)
  }
}

private actor LongcatHTTP: HTTPClient {
  let amount: Double
  let user: String
  let summary: String?
  let status: Int
  let summaryStatus: Int
  let legacyStatus: Int
  private(set) var requests: [URLRequest] = []
  init(amount: Double, user: String = #"{"loginStatus":1,"userId":"123","token":"never-publish-fixture"}"#,
       summary: String? = nil, status: Int = 200, summaryStatus: Int = 200, legacyStatus: Int = 200) {
    self.amount = amount; self.user = user; self.summary = summary; self.status = status; self.summaryStatus = summaryStatus
    self.legacyStatus = legacyStatus
  }
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    XCTFail("Session transport must refuse redirects")
    throw URLError(.badURL)
  }
  func data(for request: URLRequest, redirects: HTTPRedirectPolicy) async throws -> (Data, HTTPURLResponse) {
    XCTAssertEqual(redirects, .refuse)
    requests.append(request)
    let body: String
    let httpStatus: Int
    switch request.url!.path {
    case "/api/v1/user-current": body = #"{"code":0,"data":\#(user)}"#; httpStatus = status
    case "/api/pay/quota/metering/token-packs/summary":
      body = summary ?? #"{"code":0,"data":{"currentLot":{"lotId":"fixture-lot","status":"ACTIVE","remainingToken":\#(amount)},"otherLots":[]}}"#
      httpStatus = summaryStatus
    case "/api/lc-platform/v1/tokenUsage":
      body = #"{"code":0,"data":{"usage":{"totalToken":1000,"availableToken":\#(amount),"usedToken":1}}}"#
      httpStatus = legacyStatus
    default: throw URLError(.badURL)
    }
    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: httpStatus,
      httpVersion: nil, headerFields: ["Retry-After": "60"])!)
  }
}
