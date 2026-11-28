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
    XCTAssertEqual(usage.metrics.map(\.id), ["daily-diem", "bundled-credits", "usd-balance"])
    XCTAssertEqual(usage.metrics.map(\.remainingPercent), [40, nil, nil])
    XCTAssertEqual(usage.metrics.map(\.usedDisplay), ["40 DIEM", "$2.00", "$7.50"])
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

  func testDailyDIEMMetricIsStampedWithKeyFingerprint() async throws {
    let http = VeniceHTTPStub(.response(200, usageBody), .response(200, billingBody))
    let usage = try await VeniceQuotaClient(httpClient: http)
      .fetchUsage(configuration: configuration(), now: now)
    let metric = try XCTUnwrap(usage.metrics.first)
    XCTAssertEqual(metric.estimateKeyHash, credentialFingerprint(fixtureKey))
    XCTAssertNotEqual(metric.estimateKeyHash, credentialFingerprint("other-key"))
    XCTAssertNil(usage.metrics[1].estimateKeyHash)
    // The stamp is a change-detection fingerprint: stable, and never the key.
    XCTAssertEqual(credentialFingerprint(fixtureKey), credentialFingerprint(fixtureKey))
    XCTAssertFalse(metric.estimateKeyHash?.contains(fixtureKey) ?? true)
  }

  func testInferenceKeyReturnsAmountsWithoutInventingPercentages() async throws {
    for deniedStatus in [401, 403] {
      let http = VeniceHTTPStub(.response(200, usageBody), .response(deniedStatus, #"{"error":"Admin API key required"}"#))
      let usage = try await VeniceQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
      XCTAssertEqual(usage.metrics.map(\.usedDisplay), ["40 DIEM", "$2.00", "$7.50"])
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
    XCTAssertEqual(usage.metrics.first { $0.id == "usd-balance" }?.usedDisplay, "$7.50", "Keep the USD balance available to the key")
    XCTAssertEqual(usage.warning, "High DIEM usage")
  }

  func testSubscriptionAndEarnedCreditsCanComeFromAdminBilling() async throws {
    let rates = #"{"data":{"accessPermitted":true,"balances":{"DIEM":0,"USD":7.5},"nextEpochBegins":"2026-09-30T00:00:00Z"}}"#
    let billing = #"{"canConsume":true,"balances":{"diem":0,"usd":20,"bundledCredits":42.5,"earnedCredits":3},"diemEpochAllocation":100}"#
    let usage = try await fetch(rates: rates, billing: billing)

    XCTAssertEqual(usage.metrics.map(\.id), ["daily-diem", "bundled-credits", "earned-credits", "usd-balance"])
    XCTAssertEqual(usage.metrics.map(\.usedDisplay), ["0 DIEM", "$42.50", "$3.00", "$7.50"])
    let subscription = try XCTUnwrap(usage.metrics.first { $0.id == "bundled-credits" })
    XCTAssertEqual(subscription.label, "Subscription credits")
    XCTAssertEqual(subscription.remainingAmount, 42.5)
    XCTAssertNil(subscription.remainingPercent)
    XCTAssertNil(subscription.totalAmount)
    XCTAssertNil(subscription.resetAt)
    XCTAssertEqual(usage.warning, "Daily DIEM exhausted. Subscription credits remain.")
  }

  func testConfiguredSubscriptionAllowanceAddsAnIndependentRing() async throws {
    let rates = usageBody
      .replacingOccurrences(of: "\"DIEM\":40", with: "\"DIEM\":0")
      .replacingOccurrences(of: "\"BUNDLED_CREDITS\":2", with: "\"BUNDLED_CREDITS\":54.412741")
    let billing = billingBody.replacingOccurrences(of: "\"diem\":40", with: "\"diem\":0")
    let http = VeniceHTTPStub(.response(200, rates), .response(200, billing))
    let account = ProviderAccount(id: "venice", provider: .venice, credentials: [
      CredentialField.veniceAPIKey: fixtureKey, CredentialField.veniceCreditAllowance: "75"
    ])
    let runtime = account.runtimeConfiguration(environment: [:])
    XCTAssertEqual(runtime.credentials, [CredentialField.veniceAPIKey: fixtureKey])
    var edited = account
    edited.credentials[CredentialField.veniceCreditAllowance] = "100"
    XCTAssertTrue(runtime.matchesCurrentAccount(edited, environment: [:]))
    XCTAssertEqual(account.credentialsForImport([CredentialField.veniceAPIKey: "new"])[CredentialField.veniceCreditAllowance], "75")
    let usage = try await VeniceQuotaClient(httpClient: http).fetchUsage(configuration: runtime, now: now)
    let rings = defaultRingMetrics(for: usage)
    XCTAssertEqual(rings.map(\.id), ["daily-diem", "bundled-credits"])
    XCTAssertEqual(rings.map(\.remainingPercent), [0, 73])
    XCTAssertEqual(rings[1].remainingAmount, 54.412741)
    XCTAssertEqual(rings[1].totalAmount, 75)
    XCTAssertEqual(try XCTUnwrap(rings[1].remainingFraction), 54.412741 / 75, accuracy: 0.000001)
    XCTAssertNil(rings[1].resetAt)
    XCTAssertNotNil(rings[0].resetAt)
    XCTAssertTrue(account.redactedCredentials().credentials.isEmpty)
  }

  func testRecalculatingCachedSubscriptionPreservesDIEMAndBankedDollars() async throws {
    let usage = try await fetch()
    let snapshot = QuotaSnapshot(generatedAt: now, providers: [usage], failures: [])
    var account = ProviderAccount(id: usage.accountID, provider: .venice, credentials: [
      CredentialField.veniceAPIKey: fixtureKey, CredentialField.veniceCreditAllowance: "1"
    ])
    let refreshed = snapshot.applyingVeniceSubscriptionAllowances(from: [account])
    let updated = try XCTUnwrap(refreshed.providers.first)
    XCTAssertEqual(updated.metrics[0], usage.metrics[0])
    XCTAssertEqual(updated.fetchedAt, usage.fetchedAt)
    XCTAssertEqual(updated.metrics[1].remainingPercent, 100)
    XCTAssertEqual(updated.metrics[1].usageLine, "$2.00 / $1.00")
    XCTAssertEqual(updated.metrics[1].remainingAmount, 2)
    account.credentials[CredentialField.veniceCreditAllowance] = ""
    XCTAssertEqual(refreshed.applyingVeniceSubscriptionAllowances(from: [account]), snapshot)
    XCTAssertNil(try VeniceSubscriptionAllowance.parse(" "))
    for invalid in ["-5", "0", "nan", "inf", "$75"] {
      XCTAssertThrowsError(try VeniceSubscriptionAllowance.parse(invalid))
    }
  }

  func testConfiguredRefillProvidesPaceAcrossARealCalendarMonth() async throws {
    var usage = try await fetch()
    let fetchedAt = try XCTUnwrap(parseISO8601("2026-12-13T00:36:00Z"))
    let start = try XCTUnwrap(parseISO8601("2026-11-28T00:36:00Z"))
    let end = try XCTUnwrap(parseISO8601("2026-12-28T00:36:00Z"))
    usage.fetchedAt = fetchedAt
    let original = QuotaSnapshot(generatedAt: fetchedAt, providers: [usage], failures: [])
    var account = ProviderAccount(id: usage.accountID, provider: .venice, credentials: [
      CredentialField.veniceAPIKey: fixtureKey, CredentialField.veniceCreditAllowance: "1",
      CredentialField.veniceRefillAt: "2026-12-28T01:36:00+01:00"
    ])
    XCTAssertEqual(account.runtimeConfiguration(environment: [:]).veniceRefillAt, end)
    XCTAssertNil(account.runtimeConfiguration(environment: [:]).credentials[CredentialField.veniceRefillAt])
    let scaled = original.applyingVeniceSubscriptionAllowances(from: [account])
    let subscription = scaled.providers[0].metrics[1]
    XCTAssertEqual(subscription.paceWindow, DateInterval(start: start, end: end))
    XCTAssertEqual(scaled.providers[0].metrics[0], usage.metrics[0])
    XCTAssertNil(subscription.resetAt)
    XCTAssertEqual(subscription.remainingAmount, 2, "Keep the banked credit amount")
    let pace = try XCTUnwrap(QuotaPace(metric: subscription, provider: .venice, fetchedAt: fetchedAt, now: fetchedAt))
    XCTAssertEqual(pace.evenPaceRemainingFraction, 0.5, accuracy: 0.0001)
    XCTAssertNil(QuotaPace(metric: subscription, provider: .venice, fetchedAt: fetchedAt, now: end))
    let elapsed = scaled.providers[0].clearingElapsedWindows(at: end)
    XCTAssertEqual(elapsed.metrics[1].remainingAmount, 2)
    account.credentials[CredentialField.veniceRefillAt] = ""
    let withoutDate = scaled.applyingVeniceSubscriptionAllowances(from: [account])
    XCTAssertNil(withoutDate.providers[0].metrics[1].paceWindow)
    XCTAssertEqual(withoutDate.providers[0].metrics[1].remainingPercent, 100)
  }

  func testKeySubscriptionBalanceTakesPrecedenceIncludingZero() async throws {
    let rates = usageBody.replacingOccurrences(of: "\"BUNDLED_CREDITS\":2", with: "\"BUNDLED_CREDITS\":0")
    let billing = #"{"canConsume":true,"balances":{"diem":40,"usd":7.5,"bundledCredits":50,"earnedCredits":null},"diemEpochAllocation":100}"#
    let usage = try await fetch(rates: rates, billing: billing)

    XCTAssertEqual(usage.metrics.first { $0.id == "bundled-credits" }?.usedDisplay, "$0.00")
    XCTAssertFalse(usage.metrics.contains { $0.id == "earned-credits" })
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
      XCTAssertEqual(usage.metrics.first { $0.id == "usd-balance" }?.usedDisplay, "-$1.25")
      XCTAssertEqual(usage.warning, expectedPercent == 0 ? "Daily DIEM exhausted. Subscription credits remain." : nil)
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
    XCTAssertEqual(usage.metrics.first { $0.id == "usd-balance" }?.usedDisplay, "$1e-08")
  }

  func testKeySpendingRestrictionDoesNotImplyEmptyBalance() async throws {
    let usage = try await fetch(rates: usageBody.replacingOccurrences(of: "\"accessPermitted\":true", with: "\"accessPermitted\":false"))
    XCTAssertEqual(usage.metrics[0].remainingPercent, 40)
    XCTAssertEqual(usage.metrics.first { $0.id == "usd-balance" }?.usedDisplay, "$7.50")
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
