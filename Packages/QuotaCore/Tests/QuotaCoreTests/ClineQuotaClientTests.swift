import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ClineQuotaClientTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_790_680_000)
  // Deliberately synthetic sentinel used only by the injected HTTP stub.
  private let fixtureKey = "cline-test-fixture"
  private static let userID = "usr-01FIXTURE"
  /// Cline reports the credit balance in millionths of a US dollar.
  private let profileBody = #"""
  {"success":true,"data":{"id":"\#(ClineQuotaClientTests.userID)","email":"dev@example.com","displayName":"Dev"}}
  """#
  private let balanceBody = #"""
  {"success":true,"data":{"userId":"\#(ClineQuotaClientTests.userID)","balance":4250000}}
  """#
  private let limitsBody = #"""
  {"success":true,"data":{"limits":[
    {"type":"five_hour","percentUsed":25,"resetsAt":"2026-09-30T02:00:00.000Z"},
    {"type":"weekly","percentUsed":60},
    {"type":"monthly","percentUsed":80,"resetsAt":"2026-10-01T00:00:00.000Z"}]}}
  """#

  private func configuration(key: String? = "cline-test-fixture") -> ProviderRuntimeConfiguration {
    ProviderRuntimeConfiguration(
      accountID: "cline-personal", provider: .cline, displayName: "Personal Cline", isEnabled: true,
      credentials: key.map { [CredentialField.clineAPIKey: $0] } ?? [:]
    )
  }

  func testTracksClinePassWindowsAndCreditBalance() async throws {
    let http = ClineHTTPStub(.response(200, profileBody), .response(200, balanceBody), .response(200, limitsBody))
    let usage = try await ClineQuotaClient(httpClient: http)
      .fetchUsage(configuration: configuration(key: " \(fixtureKey)\n"), now: now)

    XCTAssertEqual(usage.provider, .cline)
    XCTAssertEqual(usage.accountID, "cline-personal")
    XCTAssertEqual(usage.title, "Personal Cline")
    XCTAssertEqual(usage.fetchedAt, now)
    XCTAssertEqual(usage.metrics.map(\.id), ["five_hour", "weekly", "monthly", "credit-balance"])
    XCTAssertEqual(usage.metrics.map(\.remainingPercent), [75, 40, 20, nil])
    XCTAssertEqual(usage.metrics.map(\.usedDisplay), ["25% used", "60% used", "80% used", "$4.25"])
    XCTAssertEqual(usage.metrics[0].resetAt, parseISO8601("2026-09-30T02:00:00Z"))
    XCTAssertEqual(usage.metrics[0].resetIn,
                   formatResetCountdown(to: try XCTUnwrap(usage.metrics[0].resetAt), now: now))
    XCTAssertNil(usage.metrics[1].resetAt, "A window without a reset time still reports its share")
    XCTAssertEqual(usage.metrics[3].remainingAmount, 4.25, "Cline reports the balance in millionths of a dollar")
    XCTAssertTrue(usage.metrics.allSatisfy { $0.totalDisplay == nil })
    XCTAssertEqual(usage.maxUsagePercent, 80)
    XCTAssertEqual(usage.warning, "High ClinePass usage")

    // Window kinds drive the identity colors, so every id has to classify.
    let kinds = usage.metrics.map { QuotaWindowKind.classify(metricID: $0.id, label: $0.label) }
    XCTAssertEqual(kinds, [.session, .weekly, .monthly, .other])

    let requests = await http.requests
    XCTAssertEqual(requests.map { $0.url?.absoluteString }, [
      "https://api.cline.bot/api/v1/users/me",
      "https://api.cline.bot/api/v1/users/usr-01FIXTURE/balance",
      "https://api.cline.bot/api/v1/users/me/plan/usage-limits"
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

  func testBalanceOnlyWhenNoClinePassSubscriptionIsReported() async throws {
    let usage = try await fetch(limits: #"{"success":true,"data":null}"#)
    XCTAssertEqual(usage.metrics.map(\.id), ["credit-balance"])
    XCTAssertEqual(usage.metrics.map(\.usedDisplay), ["$4.25"])
    XCTAssertTrue(usage.metrics.allSatisfy { $0.remainingPercent == nil })
    XCTAssertNil(usage.maxUsagePercent)
    XCTAssertNil(usage.warning)
  }

  func testUsageLimitsAreOptionalWhenTheEndpointIsAbsent() async throws {
    for status in [401, 403, 404] {
      let usage = try await fetch(limits: "{}", limitsStatus: status)
      XCTAssertEqual(usage.metrics.map(\.id), ["credit-balance"], "HTTP \(status) must not fail the refresh")
      XCTAssertEqual(usage.metrics[0].usedDisplay, "$4.25")
      XCTAssertNil(usage.maxUsagePercent)
    }
  }

  func testTransientUsageLimitsFailureFailsRefreshInsteadOfDroppingWindows() async throws {
    // Losing a known window would silently under-report ClinePass usage.
    for (status, kind) in [(429, QuotaErrorKind.rateLimit), (500, .api), (302, .api)] {
      await assertFailure(kind) {
        try await self.fetch(limits: "{}", limitsStatus: status)
      }
    }
  }

  func testAccountsWithoutCreditsKeepReportedWindows() async throws {
    for (balance, expectedDisplay) in [("0", "$0.00"), ("-2500000", "-$2.50")] {
      let usage = try await fetch(balance: #"{"success":true,"data":{"userId":"\#(ClineQuotaClientTests.userID)","balance":\#(balance)}}"#)
      XCTAssertEqual(usage.metrics.map(\.remainingPercent), [75, 40, 20, nil])
      XCTAssertEqual(usage.metrics[3].usedDisplay, expectedDisplay)
      XCTAssertEqual(usage.warning, "High ClinePass usage", "A constrained window explains the state better than an empty balance")
    }
  }

  func testExhaustedCreditsAreWarnedOnlyWhenNoSubscriptionExists() async throws {
    // A ClinePass subscriber who never bought credits is in a normal state;
    // warning there would be permanent noise. Pay-as-you-go only, an empty
    // balance does block work, so it is reported.
    let subscribed = #"""
    {"success":true,"data":{"limits":[{"type":"five_hour","percentUsed":25},
                                      {"type":"weekly","percentUsed":10},{"type":"monthly","percentUsed":10}]}}
    """#
    let usage = try await fetch(balance: #"{"success":true,"data":{"userId":"\#(ClineQuotaClientTests.userID)","balance":0}}"#,
                                limits: subscribed)
    XCTAssertEqual(usage.maxUsagePercent, 25)
    XCTAssertNil(usage.warning)
    XCTAssertEqual(usage.metrics.last?.usedDisplay, "$0.00", "The empty balance still shows as an amount")

    let payAsYouGo = try await fetch(balance: #"{"success":true,"data":{"userId":"\#(ClineQuotaClientTests.userID)","balance":0}}"#,
                                     limits: #"{"success":true,"data":null}"#)
    XCTAssertEqual(payAsYouGo.warning, "No Cline credits left")

    let exhausted = limitsBody.replacingOccurrences(of: "\"percentUsed\":25", with: "\"percentUsed\":100")
    let spent = try await fetch(balance: #"{"success":true,"data":{"userId":"\#(ClineQuotaClientTests.userID)","balance":0}}"#,
                                limits: exhausted)
    XCTAssertEqual(spent.maxUsagePercent, 100)
    XCTAssertEqual(spent.warning, "ClinePass 5-hour limit reached")
  }

  func testOutOfRangeWindowSharesStayInsideBoundedGeometry() async throws {
    // percentUsed:   remaining, maxUsage, usedDisplay
    let cases: [(percentUsed: String, remaining: Int, maxUsage: Int, usedDisplay: String)] = [
      ("-5", 100, 0, "0% used"),
      ("250", 0, 100, "100% used")
    ]
    for testCase in cases {
      let limits = #"{"success":true,"data":{"limits":[{"type":"five_hour","percentUsed":\#(testCase.percentUsed)}]}}"#
      let usage = try await fetch(limits: limits)
      XCTAssertEqual(usage.metrics[0].remainingPercent, testCase.remaining, testCase.percentUsed)
      XCTAssertEqual(usage.metrics[0].usedDisplay, testCase.usedDisplay, testCase.percentUsed)
      XCTAssertEqual(usage.maxUsagePercent, testCase.maxUsage, testCase.percentUsed)
    }
  }

  func testUnrepresentableWindowShareFailsInsteadOfRenderingAPercentage() async throws {
    // A share this large is not a real reading. Rejecting the refresh keeps
    // the last good snapshot rather than claiming the window is fully spent.
    let limits = #"{"success":true,"data":{"limits":[{"type":"five_hour","percentUsed":1e1000}]}}"#
    await assertFailure(.decoding) { try await self.fetch(limits: limits) }
  }

  func testRecognizedWindowsRequireReportedFinitePercentages() async {
    for type in ["five_hour", "weekly", "monthly"] {
      let windows = [#"{"type":"\#(type)"}"#] + ["null", "true", #""25""#, "{}", "[]", "1e1000"].map {
        #"{"type":"\#(type)","percentUsed":\#($0)}"#
      }
      for window in windows {
        let bare = #"{"limits":[\#(window)]}"#
        for body in [bare, #"{"success":true,"data":\#(bare)}"#] {
          await assertFailure(.decoding) { try await self.fetch(limits: body) }
        }
      }
    }
  }

  func testExplicitZeroWindowSharesRemainValidInWrappedAndBarePayloads() async throws {
    let bare = #"{"limits":[{"type":"five_hour","percentUsed":0},{"type":"weekly","percentUsed":0},{"type":"monthly","percentUsed":0}]}"#
    for body in [bare, #"{"success":true,"data":\#(bare)}"#] {
      let usage = try await fetch(limits: body)
      XCTAssertEqual(usage.metrics.map(\.remainingPercent), [100, 100, 100, nil])
      XCTAssertEqual(usage.maxUsagePercent, 0)
      XCTAssertNil(usage.warning)
    }
  }

  func testUnknownWindowTypesSurviveWithServerSuppliedIdentity() async throws {
    let limits = #"""
    {"success":true,"data":{"limits":[{"type":"daily","percentUsed":10,"resetsAt":"2026-09-29T00:00:00Z"},
                                      {"type":"yearly","percentUsed":5}]}}
    """#
    let usage = try await fetch(limits: limits)
    XCTAssertEqual(usage.metrics.map(\.id), ["daily", "yearly", "credit-balance"])
    XCTAssertEqual(usage.metrics.map(\.remainingPercent), [90, 95, nil])
    XCTAssertEqual(QuotaWindowKind.classify(metricID: usage.metrics[0].id, label: usage.metrics[0].label), .daily)
    XCTAssertEqual(QuotaWindowKind.classify(metricID: usage.metrics[1].id, label: usage.metrics[1].label), .other)
    XCTAssertEqual(usage.metrics[1].label, "Yearly remaining")
  }

  func testRejectedWindowTypesDoNotProduceBlankRows() async throws {
    let usage = try await fetch(limits: #"{"success":true,"data":{"limits":[{"percentUsed":50},{"type":"","percentUsed":50}]}}"#)
    XCTAssertEqual(usage.metrics.map(\.id), ["credit-balance"])
  }

  func testDuplicateWindowTypesResolveToTheMostConsumedReading() async throws {
    // The API never repeats a type; where it does, keeping the lower share
    // would under-report usage.
    let limits = #"""
    {"success":true,"data":{"limits":[{"type":"weekly","percentUsed":10},{"type":"weekly","percentUsed":90}]}}
    """#
    let usage = try await fetch(limits: limits)
    XCTAssertEqual(usage.metrics.map(\.id), ["weekly", "credit-balance"])
    XCTAssertEqual(usage.metrics[0].remainingPercent, 10)
    XCTAssertEqual(usage.metrics[0].usedDisplay, "90% used")
  }

  func testWindowOrderFromTheServerDoesNotChangeRingSelection() async throws {
    let reversed = #"""
    {"success":true,"data":{"limits":[{"type":"monthly","percentUsed":80},{"type":"five_hour","percentUsed":25},
                                      {"type":"weekly","percentUsed":60}]}}
    """#
    let usage = try await fetch(limits: reversed)
    XCTAssertEqual(defaultRingMetrics(for: usage).map(\.id), ["five_hour", "weekly"])
  }

  func testBarePayloadsWithoutTheSuccessEnvelopeAreAccepted() async throws {
    let http = ClineHTTPStub(
      .response(200, #"{"id":"\#(ClineQuotaClientTests.userID)","email":"dev@example.com"}"#),
      .response(200, #"{"userId":"\#(ClineQuotaClientTests.userID)","balance":1000000}"#),
      .response(200, #"{"limits":[{"type":"weekly","percentUsed":20}]}"#)
    )
    let usage = try await ClineQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
    XCTAssertEqual(usage.metrics.map(\.id), ["weekly", "credit-balance"])
    XCTAssertEqual(usage.metrics[1].usedDisplay, "$1.00")
  }

  func testSmallBalancesKeepSubCentPrecision() async throws {
    let usage = try await fetch(balance: #"{"success":true,"data":{"userId":"\#(ClineQuotaClientTests.userID)","balance":7}}"#,
                                limits: #"{"success":true,"data":null}"#)
    let credit = try XCTUnwrap(usage.metrics.last)
    XCTAssertEqual(credit.usedDisplay, "$0.000007")
    XCTAssertEqual(credit.remainingAmount, 0.000007)
  }

    func testUserIDsThatCouldReshapeTheBalancePathAreRejected() async throws {
    // The id is one path segment, and appending it must not become a different
    // request than "this account's balance".
    for id in ["usr/../admin", "usr-01/balance", "..", "usr-01?admin=1"] {
      let body = #"{"success":true,"data":{"id":"\#(id)","email":"dev@example.com"}}"#
      let http = ClineHTTPStub(.response(200, body))
      await assertFailure(.decoding) {
        try await ClineQuotaClient(httpClient: http).fetchUsage(configuration: self.configuration(), now: self.now)
      }
      let requests = await http.requests
      XCTAssertEqual(requests.count, 1, "id \(id)")
    }
  }

  func testRejectedMissingAndMalformedAPIKeysBeforeNetworking() async {
    for key in [nil, "", " \n", "fixture key", "fixture\nkey", "fixture\u{0000}key"] as [String?] {
      let http = ClineHTTPStub(.response(200, profileBody))
      await assertFailure(.notConfigured) {
        try await ClineQuotaClient(httpClient: http).fetchUsage(configuration: self.configuration(key: key), now: self.now)
      }
      let requests = await http.requests
      XCTAssertTrue(requests.isEmpty)
    }
  }

  func testProfileAndBalanceFailuresAreReportedWithoutBodies() async {
    for (status, kind) in [(401, QuotaErrorKind.auth), (403, .auth), (429, .rateLimit), (500, .api), (302, .api)] {
      for failing in ["profile", "balance"] {
        let responses: [ClineHTTPStub.Result] = failing == "profile"
          ? [.response(status, fixtureKey), .response(200, balanceBody), .response(200, limitsBody)]
          : [.response(200, profileBody), .response(status, fixtureKey), .response(200, limitsBody)]
        await assertFailure(kind) {
          try await ClineQuotaClient(httpClient: ClineHTTPStub(responses: responses))
            .fetchUsage(configuration: self.configuration(), now: self.now)
        }
      }
    }

    await assertFailure(.decoding) {
      try await self.fetch(balance: self.fixtureKey)
    }
  }

  func testRejectsMalformedProfileAndBalancePayloads() async {
    let invalidProfiles = ["{}", "[]", fixtureKey,
      #"{"success":true,"data":{"id":"  ","email":"dev@example.com"}}"#,
      #"{"success":true,"data":{"id":42}}"#,
      #"{"success":true,"data":null}"#
    ] + ["true", "[]"].map { #"{"success":true,"data":{"id":\#($0)}}"# }
    for body in invalidProfiles {
      let http = ClineHTTPStub(.response(200, body))
      await assertFailure(.decoding) {
        try await ClineQuotaClient(httpClient: http).fetchUsage(configuration: self.configuration(), now: self.now)
      }
      let requests = await http.requests
      XCTAssertEqual(requests.count, 1, "A profile failure must stop before the balance request")
    }

    for value in ["true", "null", "\"4250000\"", "1e1000"] {
      await assertFailure(.decoding) {
        try await self.fetch(balance: #"{"success":true,"data":{"userId":"usr-01FIXTURE","balance":\#(value)}}"#)
      }
    }
  }

  func testEnvelopeFailuresAreReportedWithoutEchoingServerText() async {
    // The server's `error` string reaches the snapshot and `llimit status`, so
    // it is never echoed — a deployment reflecting the Authorization value
    // back would otherwise put the key there.
    let bodies = [
      #"{"success":false,"error":"Invalid token: \(fixtureKey)"}"#,
      #"{"success":false,"error":"Account suspended"}"#,
      #"{"success":false,"data":{"id":"usr-01FIXTURE"}}"#
    ]
    for body in bodies {
      let http = ClineHTTPStub(.response(200, body))
      do {
        _ = try await ClineQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
        XCTFail("Expected an API failure: \(body)")
      } catch let error as ProviderClientError {
        XCTAssertEqual(error.kind, .api, body)
        XCTAssertFalse(error.message.contains(fixtureKey), body)
        XCTAssertFalse(error.message.contains("suspended"), body)
      } catch {
        XCTFail("Expected a sanitized provider error: \(body)")
      }
    }
  }

  func testEnvelopeWithoutADataFieldFailsInsteadOfErasingWindows() async throws {
    // Only an explicit `"data": null` means "no subscription". A missing key is
    // a schema change, and must not silently drop the windows.
    for body in [#"{"success":true}"#, #"{"success":true,"error":"nope"}"#] {
      let http = ClineHTTPStub(.response(200, body))
      await assertFailure(.decoding) {
        try await ClineQuotaClient(httpClient: http).fetchUsage(configuration: self.configuration(), now: self.now)
      }
    }
  }

  func testSanitizesTransportErrorsFromEveryRequest() async {
    let cases: [[ClineHTTPStub.Result]] = [
      [.failure],
      [.response(200, profileBody), .failure],
      [.response(200, profileBody), .response(200, balanceBody), .failure]
    ]
    for responses in cases {
      let http = ClineHTTPStub(responses: responses)
      await assertFailure(.network) {
        try await ClineQuotaClient(httpClient: http).fetchUsage(configuration: self.configuration(), now: self.now)
      }
    }
  }

  func testPreservesCancellation() async {
    let http = ClineHTTPStub(.cancelled)
    do {
      _ = try await ClineQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("Expected cancellation, not a provider failure")
    }
  }

  private func fetch(balance: String? = nil, limits: String? = nil, limitsStatus: Int = 200) async throws -> ProviderUsage {
    try await ClineQuotaClient(httpClient: ClineHTTPStub(
      .response(200, profileBody), .response(200, balance ?? balanceBody), .response(limitsStatus, limits ?? limitsBody)
    )).fetchUsage(configuration: configuration(), now: now)
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

private actor ClineHTTPStub: HTTPClient {
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
      throw NSError(domain: "cline-test-fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "cline-test-fixture"])
    case .cancelled:
      throw CancellationError()
    }
  }
}
