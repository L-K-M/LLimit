import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class VeniceQuotaClientTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_790_680_000)
  // Deliberately synthetic sentinel used only by the injected HTTP stub.
  private let fixtureKey = "venice-test-fixture"
  private let usageBody = #"""
  {"data":{"accessPermitted":true,"balances":{"DIEM":40,"USD":7.5,"BUNDLED_CREDITS":2},
    "nextEpochBegins":"2026-09-30T00:00:00.000Z"}}
  """#
  private let billingBody = #"""
  {"canConsume":true,"balances":{"diem":40,"usd":7.5},"diemEpochAllocation":100}
  """#

  private func configuration(key: String? = "venice-test-fixture") -> ProviderRuntimeConfiguration {
    ProviderRuntimeConfiguration(
      accountID: "venice-personal", provider: .venice, displayName: "Personal Venice", isEnabled: true,
      credentials: key.map { [CredentialField.veniceAPIKey: $0] } ?? [:]
    )
  }

  func testAdminKeyTracksDailyAllocationAndUnboundedCreditBalances() async throws {
    let http = VeniceHTTPStub(.response(200, usageBody), .response(200, billingBody))
    let usage = try await VeniceQuotaClient(httpClient: http)
      .fetchUsage(configuration: configuration(key: " \(fixtureKey)\n"), now: now)

    XCTAssertEqual(usage.provider, .venice)
    XCTAssertEqual(usage.accountID, "venice-personal")
    XCTAssertEqual(usage.title, "Personal Venice")
    XCTAssertEqual(usage.fetchedAt, now)
    XCTAssertEqual(usage.metrics.map(\.id), ["daily-diem", "usd-balance", "bundled-credits"])
    XCTAssertEqual(usage.metrics.map(\.remainingPercent), [40, nil, nil])
    XCTAssertEqual(usage.metrics.map(\.usedDisplay), ["40 DIEM", "$7.50", "$2.00"])
    XCTAssertTrue(usage.metrics.allSatisfy { $0.totalDisplay == nil })
    XCTAssertEqual(usage.metrics[0].detail, "Account daily allocation: 100 DIEM")
    XCTAssertEqual(usage.metrics[0].resetAt, parseISO8601("2026-09-30T00:00:00Z"))
    XCTAssertEqual(usage.metrics[0].resetIn, formatResetCountdown(to: try XCTUnwrap(usage.metrics[0].resetAt), now: now))
    XCTAssertNil(usage.metrics[1].resetAt)
    XCTAssertNil(usage.metrics[2].resetAt)
    XCTAssertEqual(QuotaWindowKind.classify(metricID: usage.metrics[0].id, label: usage.metrics[0].label), .daily)
    XCTAssertEqual(usage.maxUsagePercent, 60)
    XCTAssertNil(usage.warning)

    let requests = await http.requests
    XCTAssertEqual(requests.map { $0.url?.absoluteString }, [
      "https://api.venice.ai/api/v1/api_keys/rate_limits", "https://api.venice.ai/api/v1/billing/balance"
    ])
    for request in requests {
      XCTAssertEqual(request.httpMethod, "GET")
      XCTAssertNil(request.httpBody)
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(fixtureKey)")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
      XCTAssertFalse(request.httpShouldHandleCookies)
    }
    XCTAssertFalse(String(decoding: try JSONEncoder().encode(usage), as: UTF8.self).contains(fixtureKey))
  }

  func testInferenceKeyReturnsAmountsWithoutInventingPercentages() async throws {
    for deniedStatus in [401, 403] {
      let http = VeniceHTTPStub(.response(200, usageBody), .response(deniedStatus, #"{"error":"Admin API key required"}"#))
      let usage = try await VeniceQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
      XCTAssertEqual(usage.metrics.map(\.usedDisplay), ["40 DIEM", "$7.50", "$2.00"])
      XCTAssertTrue(usage.metrics.allSatisfy { $0.remainingPercent == nil })
      XCTAssertTrue(try XCTUnwrap(usage.metrics[0].detail).contains("admin API key"))
      XCTAssertNotNil(usage.metrics[0].resetAt)
      XCTAssertNil(usage.maxUsagePercent)
      XCTAssertNil(usage.warning)
    }
  }

  func testPercentagePairsBillingBalanceWithBillingAllocation() async throws {
    let billing = billingBody.replacingOccurrences(of: "\"diem\":40", with: "\"diem\":10")
      .replacingOccurrences(of: "\"usd\":7.5", with: "\"usd\":100")
    let usage = try await fetch(billing: billing)
    XCTAssertEqual(usage.metrics[0].remainingPercent, 10)
    XCTAssertEqual(usage.metrics[0].usedDisplay, "10 DIEM")
    XCTAssertEqual(usage.metrics[1].usedDisplay, "$7.50", "Keep the USD balance available to the key")
    XCTAssertEqual(usage.warning, "High DIEM usage")
  }

  func testZeroOrNegativeAllocationLeavesPercentageUnknown() async throws {
    for allocation in ["0", "-10"] {
      let usage = try await fetch(billing: billingBody.replacingOccurrences(of: "\"diemEpochAllocation\":100", with: "\"diemEpochAllocation\":\(allocation)"))
      XCTAssertNil(usage.metrics[0].remainingPercent)
      XCTAssertNil(usage.maxUsagePercent)
      XCTAssertEqual(usage.metrics[0].usedDisplay, "40 DIEM")
      XCTAssertTrue(try XCTUnwrap(usage.metrics[0].detail).contains("unavailable"))
    }
  }

  func testNullBillingBalanceDoesNotUseKeyBalanceAsAllocationNumerator() async throws {
    let usage = try await fetch(billing: billingBody.replacingOccurrences(of: "\"diem\":40", with: "\"diem\":null"))
    XCTAssertEqual(usage.metrics[0].usedDisplay, "40 DIEM")
    XCTAssertNil(usage.metrics[0].remainingPercent)
    XCTAssertNil(usage.maxUsagePercent)
  }

  func testPreservesSignedBalancesAndClampsOnlyPercentageGeometry() async throws {
    let rates = usageBody.replacingOccurrences(of: "\"USD\":7.5", with: "\"USD\":-1.25")
    for (amount, expectedPercent, expectedDisplay) in [("-2.5", 0, "-2.5 DIEM"), ("0", 0, "0 DIEM"), ("150", 100, "150 DIEM")] {
      let billing = billingBody.replacingOccurrences(of: "\"diem\":40", with: "\"diem\":\(amount)")
      let usage = try await fetch(rates: rates, billing: billing)
      XCTAssertEqual(usage.metrics[0].remainingPercent, expectedPercent)
      XCTAssertEqual(usage.metrics[0].usedDisplay, expectedDisplay)
      XCTAssertEqual(usage.metrics[1].usedDisplay, "-$1.25")
      XCTAssertEqual(usage.warning, expectedPercent == 0 ? "Daily DIEM exhausted" : nil)
    }
  }

  func testFiniteExtremeBalancesDoNotOverflowPercentageCalculation() async throws {
    let billing = billingBody.replacingOccurrences(of: "\"diem\":40", with: "\"diem\":1e308")
      .replacingOccurrences(of: "\"diemEpochAllocation\":100", with: "\"diemEpochAllocation\":1e-300")
    let usage = try await fetch(billing: billing)
    XCTAssertEqual(usage.metrics[0].remainingPercent, 100)
    XCTAssertEqual(usage.maxUsagePercent, 0)
  }

  func testSmallPositiveDIEMBalanceIsNotReportedAsExhausted() async throws {
    let billing = billingBody.replacingOccurrences(of: "\"diem\":40", with: "\"diem\":0.4")
    let usage = try await fetch(billing: billing)
    XCTAssertEqual(usage.metrics[0].remainingPercent, 0)
    XCTAssertEqual(usage.metrics[0].usedDisplay, "0.4 DIEM")
    XCTAssertEqual(usage.warning, "High DIEM usage")
  }

  func testSmallNonzeroCreditsAreNotDisplayedAsZero() async throws {
    let rates = usageBody.replacingOccurrences(of: "\"USD\":7.5", with: "\"USD\":0.00000001")
    let billing = billingBody.replacingOccurrences(of: "\"diemEpochAllocation\":100", with: "\"diemEpochAllocation\":1e-300")
    let usage = try await fetch(rates: rates, billing: billing)
    XCTAssertEqual(usage.metrics[0].detail, "Account daily allocation: 1e-300 DIEM")
    XCTAssertEqual(usage.metrics[1].usedDisplay, "$1e-08")
  }

  func testKeySpendingRestrictionDoesNotImplyEmptyBalance() async throws {
    let usage = try await fetch(rates: usageBody.replacingOccurrences(of: "\"accessPermitted\":true", with: "\"accessPermitted\":false"))
    XCTAssertEqual(usage.metrics[0].remainingPercent, 40)
    XCTAssertEqual(usage.metrics[1].usedDisplay, "$7.50")
    XCTAssertEqual(usage.warning, "API key spending unavailable. Check its limits in Venice.")
  }

  func testAccountConsumptionRestrictionIsShown() async throws {
    let usage = try await fetch(billing: billingBody.replacingOccurrences(of: "\"canConsume\":true", with: "\"canConsume\":false"))
    XCTAssertEqual(usage.metrics[0].remainingPercent, 40)
    XCTAssertEqual(usage.warning, "API spending unavailable. Check Venice billing.")
  }

  func testOptionalCurrenciesCanBeAbsent() async throws {
    let rates = #"{"data":{"accessPermitted":true,"balances":{"USD":3.25},"nextEpochBegins":"2026-09-30T00:00:00Z"}}"#
    let billing = #"{"canConsume":true,"balances":{"diem":null,"usd":3.25},"diemEpochAllocation":0}"#
    let usage = try await fetch(rates: rates, billing: billing)
    XCTAssertEqual(usage.metrics.map(\.id), ["usd-balance"])
    XCTAssertEqual(usage.metrics[0].usedDisplay, "$3.25")
    XCTAssertNil(usage.metrics[0].remainingPercent)
    XCTAssertNil(usage.maxUsagePercent)
  }

  func testRejectsMissingAndMalformedAPIKeysBeforeNetworking() async {
    for key in [nil, "", " \n", "fixture key", "fixture\nkey", "fixture\u{0000}key"] as [String?] {
      let http = VeniceHTTPStub(.response(200, usageBody))
      await assertFailure(.notConfigured) {
        try await VeniceQuotaClient(httpClient: http).fetchUsage(configuration: self.configuration(key: key), now: self.now)
      }
      let requests = await http.requests
      XCTAssertTrue(requests.isEmpty)
    }
  }

  func testRequiredUsageEndpointMapsFailuresWithoutExposingBodies() async {
    for (status, kind) in [(401, QuotaErrorKind.auth), (403, .auth), (429, .rateLimit), (500, .api), (302, .api)] {
      let http = VeniceHTTPStub(.response(status, fixtureKey))
      await assertFailure(kind) {
        try await VeniceQuotaClient(httpClient: http).fetchUsage(configuration: self.configuration(), now: self.now)
      }
      let requests = await http.requests
      XCTAssertEqual(requests.count, 1)
    }
  }

  func testTransientBillingFailureFailsRefreshInsteadOfLosingKnownPercentage() async {
    for (status, kind) in [(429, QuotaErrorKind.rateLimit), (500, .api), (302, .api)] {
      let http = VeniceHTTPStub(.response(200, usageBody), .response(status, fixtureKey))
      await assertFailure(kind) {
        try await VeniceQuotaClient(httpClient: http).fetchUsage(configuration: self.configuration(), now: self.now)
      }
    }
  }

  func testRejectsMalformedUsagePayloads() async {
    let invalidBodies = ["{}", "[]", fixtureKey,
      usageBody.replacingOccurrences(of: "\"accessPermitted\":true", with: "\"accessPermitted\":1"),
      usageBody.replacingOccurrences(of: "\"DIEM\":40,\"USD\":7.5,\"BUNDLED_CREDITS\":2", with: ""),
      usageBody.replacingOccurrences(of: "2026-09-30T00:00:00.000Z", with: "2026-09-30"),
      usageBody.replacingOccurrences(of: "2026-09-30T00:00:00.000Z", with: fixtureKey)
    ] + ["true", "\"40\"", "1e1000"].map {
      usageBody.replacingOccurrences(of: "\"DIEM\":40", with: "\"DIEM\":\($0)")
    }
    for body in invalidBodies {
      let http = VeniceHTTPStub(.response(200, body))
      await assertFailure(.decoding) {
        try await VeniceQuotaClient(httpClient: http).fetchUsage(configuration: self.configuration(), now: self.now)
      }
      let requests = await http.requests
      XCTAssertEqual(requests.count, 1)
    }
  }

  func testRejectsMalformedBillingPayloads() async {
    let invalidBodies = ["{}", "[]", fixtureKey,
      billingBody.replacingOccurrences(of: "\"canConsume\":true", with: "\"canConsume\":1")
    ] + ["true", "null", "\"100\"", "1e1000"].map {
      billingBody.replacingOccurrences(of: "\"diemEpochAllocation\":100", with: "\"diemEpochAllocation\":\($0)")
    } + ["true", "\"40\"", "1e1000"].map {
      billingBody.replacingOccurrences(of: "\"diem\":40", with: "\"diem\":\($0)")
    }
    for body in invalidBodies {
      await assertFailure(.decoding) { try await self.fetch(billing: body) }
    }
  }

  func testSanitizesTransportErrorsFromEitherRequest() async {
    for responses: [VeniceHTTPStub.Result] in [[.failure], [.response(200, usageBody), .failure]] {
      let http = VeniceHTTPStub(responses: responses)
      await assertFailure(.network) {
        try await VeniceQuotaClient(httpClient: http).fetchUsage(configuration: self.configuration(), now: self.now)
      }
    }
  }

  func testPreservesCancellation() async {
    let http = VeniceHTTPStub(.cancelled)
    do {
      _ = try await VeniceQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("Expected cancellation, not a provider failure")
    }
  }

  private func fetch(rates: String? = nil, billing: String? = nil) async throws -> ProviderUsage {
    try await VeniceQuotaClient(httpClient: VeniceHTTPStub(.response(200, rates ?? usageBody), .response(200, billing ?? billingBody)))
      .fetchUsage(configuration: configuration(), now: now)
  }

  private func assertFailure(
    _ kind: QuotaErrorKind, file: StaticString = #filePath, line: UInt = #line,
    operation: () async throws -> ProviderUsage
  ) async {
    do {
      _ = try await operation()
      XCTFail("Expected \(kind) error", file: file, line: line)
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, kind, file: file, line: line)
      XCTAssertFalse(error.message.contains(fixtureKey), file: file, line: line)
    } catch {
      XCTFail("Expected a sanitized provider error", file: file, line: line)
    }
  }
}

private actor VeniceHTTPStub: HTTPClient {
  enum Result {
    case response(Int, String)
    case failure
    case cancelled
  }

  private var responses: [Result]
  private(set) var requests: [URLRequest] = []

  init(_ responses: Result...) { self.responses = responses }
  init(responses: [Result]) { self.responses = responses }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    guard !responses.isEmpty else { throw CancellationError() }
    switch responses.removeFirst() {
    case let .response(status, body):
      return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    case .failure:
      throw NSError(domain: "venice-test-fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "venice-test-fixture"])
    case .cancelled:
      throw CancellationError()
    }
  }
}
