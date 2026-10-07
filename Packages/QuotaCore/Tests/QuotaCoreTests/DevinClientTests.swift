import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class DevinClientTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private func config(
    key: String? = "devin-session-key",
    server: String? = nil
  ) -> ProviderRuntimeConfiguration {
    var credentials: [String: String] = [:]
    if let key { credentials[CredentialField.devinAPIKey] = key }
    if let server { credentials[CredentialField.devinAPIServer] = server }
    return ProviderRuntimeConfiguration(
      provider: .devin,
      isEnabled: true,
      credentials: credentials
    )
  }

  // The shape observed live from GetUserStatus: quota percents as numbers,
  // reset epochs as strings, -1 meaning "not credit-billed".
  func testParsesDailyAndWeeklyQuotas() async throws {
    let json = #"""
    {
      "userStatus": {
        "name": "devin.ai",
        "email": "devin@example.com",
        "planStatus": {
          "planInfo": {
            "planName": "Pro",
            "billingStrategy": "BILLING_STRATEGY_QUOTA",
            "devinInfo": {"accountDisplayName": "My Team"}
          },
          "planStart": "2026-09-13T19:56:36Z",
          "planEnd": "2026-10-13T19:56:36Z",
          "availablePromptCredits": -1,
          "dailyQuotaRemainingPercent": 42,
          "weeklyQuotaRemainingPercent": 87,
          "dailyQuotaResetAtUnix": "1789372800",
          "weeklyQuotaResetAtUnix": "1789891200"
        }
      }
    }
    """#
    let client = DevinQuotaClient(httpClient: MockHTTP(status: 200, body: json))

    let usage = try await client.fetchUsage(configuration: config(), now: now)

    XCTAssertEqual(usage.provider, .devin)
    XCTAssertEqual(usage.subtitle, "Pro plan · My Team")
    XCTAssertEqual(usage.metrics.map(\.id), ["quota-daily", "quota-weekly"])

    let daily = try XCTUnwrap(usage.metrics.first { $0.id == "quota-daily" })
    XCTAssertEqual(daily.label, "Daily quota")
    XCTAssertEqual(daily.remainingPercent, 42)
    XCTAssertEqual(daily.resetAt, Date(timeIntervalSince1970: 1_789_372_800))
    XCTAssertEqual(QuotaWindowKind.classify(metricID: daily.id, label: daily.label), .daily)

    let weekly = try XCTUnwrap(usage.metrics.first { $0.id == "quota-weekly" })
    XCTAssertEqual(weekly.remainingPercent, 87)
    XCTAssertEqual(QuotaWindowKind.classify(metricID: weekly.id, label: weekly.label), .weekly)

    XCTAssertEqual(usage.maxUsagePercent, 58)
    XCTAssertNil(usage.warning)
  }

  // Protobuf-JSON renders int64 fields as strings; percents must still parse.
  func testAcceptsStringPercentFields() async throws {
    let json = #"""
    {"userStatus": {"planStatus": {"dailyQuotaRemainingPercent": "35", "weeklyQuotaRemainingPercent": "90"}}}
    """#
    let client = DevinQuotaClient(httpClient: MockHTTP(status: 200, body: json))

    let usage = try await client.fetchUsage(configuration: config(), now: now)

    XCTAssertEqual(usage.metrics.first { $0.id == "quota-daily" }?.remainingPercent, 35)
    XCTAssertEqual(usage.metrics.first { $0.id == "quota-weekly" }?.remainingPercent, 90)
  }

  func testDailyQuotaKeepsPrimaryColorWhenExtraBalanceIsPresent() async throws {
    let json = #"""
    {"userStatus": {"planStatus": {"dailyQuotaRemainingPercent": 42, "usageBalance": 15}}}
    """#
    let client = DevinQuotaClient(httpClient: MockHTTP(status: 200, body: json))

    let usage = try await client.fetchUsage(configuration: config(), now: now)

    XCTAssertEqual(usage.metrics.map(\.id), ["quota-daily", "balance"])
    XCTAssertEqual(defaultRingMetrics(for: usage).map(\.id), ["quota-daily"])
    XCTAssertEqual(primaryLimitSlot(for: usage.metrics), LimitSeriesSlot(kind: .daily))
  }

  func testShowsPromptCreditsOnlyOnCreditBilledPlans() async throws {
    let json = #"""
    {"userStatus": {"planStatus": {
      "planInfo": {"planName": "Core", "billingStrategy": "BILLING_STRATEGY_CREDITS"},
      "availablePromptCredits": 350.5,
      "planEnd": "2026-10-13T19:56:36Z"
    }}}
    """#
    let client = DevinQuotaClient(httpClient: MockHTTP(status: 200, body: json))

    let usage = try await client.fetchUsage(configuration: config(), now: now)

    let credits = try XCTUnwrap(usage.metrics.first { $0.id == "credits" })
    XCTAssertEqual(credits.usedDisplay, "350.5")
    XCTAssertNotNil(credits.resetAt)
    // No percent fields -> no quota metrics.
    XCTAssertNil(usage.metrics.first { $0.id == "quota-daily" })
  }

  func testSurfacesUsageActionLabelWhenQuotaExhausted() async throws {
    let json = #"""
    {"userStatus": {"planStatus": {
      "planInfo": {"devinInfo": {"requestUsageAction": {"label": "Ask your account admin to raise it"}}},
      "dailyQuotaRemainingPercent": 0
    }}}
    """#
    let client = DevinQuotaClient(httpClient: MockHTTP(status: 200, body: json))

    let usage = try await client.fetchUsage(configuration: config(), now: now)

    XCTAssertEqual(usage.maxUsagePercent, 100)
    XCTAssertEqual(usage.warning, "Ask your account admin to raise it")
  }

  func testTopLevelPlanInfoOverridesNestedCreditAndHideRules() async throws {
    let credit = try await fetch(#"{"planInfo":{"planName":"Core","billingStrategy":"BILLING_STRATEGY_CREDITS","hideDailyQuota":true,"devinInfo":{"accountDisplayName":"Current team"}},"userStatus":{"planStatus":{"planInfo":{"planName":"Old","billingStrategy":"BILLING_STRATEGY_QUOTA"},"dailyQuotaResetAtUnix":"1789372800"}}}"#)
    XCTAssertEqual(credit.subtitle, "Core plan · Current team")
    XCTAssertEqual(credit.metrics.map(\.id), ["credits"])
    XCTAssertEqual(credit.metrics.first?.usedDisplay, "0")

    let quota = try await fetch(#"{"planInfo":{"planName":"Pro","billingStrategy":"BILLING_STRATEGY_QUOTA","hideDailyQuota":true,"devinInfo":{"requestUsageAction":{"label":"Ask your current admin"}}},"userStatus":{"planStatus":{"planInfo":{"billingStrategy":"BILLING_STRATEGY_CREDITS","hideWeeklyQuota":true},"dailyQuotaRemainingPercent":42,"weeklyQuotaResetAtUnix":"1789891200"}}}"#)
    XCTAssertEqual(quota.metrics.map(\.id), ["quota-weekly"])
    XCTAssertEqual(quota.metrics.first?.remainingPercent, 0)
    XCTAssertEqual(quota.maxUsagePercent, 100)
    XCTAssertEqual(quota.warning, "Ask your current admin")
  }

  func testImplicitProtoZerosAndNestedPlanCompatibility() async throws {
    let exhausted = try await fetch(#"{"userStatus":{"planStatus":{"planInfo":{"planName":"Pro","billingStrategy":"BILLING_STRATEGY_QUOTA"},"dailyQuotaResetAtUnix":"1789372800","weeklyQuotaRemainingPercent":87,"weeklyQuotaResetAtUnix":"1789891200","availablePromptCredits":-1}}}"#)
    XCTAssertEqual(exhausted.metrics.map(\.id), ["quota-daily", "quota-weekly"])
    XCTAssertEqual(exhausted.metrics.map(\.remainingPercent), [0, 87])
    XCTAssertEqual(exhausted.metrics.first?.resetAt, Date(timeIntervalSince1970: 1_789_372_800))
    XCTAssertEqual(exhausted.warning, "Quota exhausted")

    let nullAndZero = try await fetch(#"{"userStatus":{"planStatus":{"dailyQuotaRemainingPercent":null,"dailyQuotaResetAtUnix":"1789372800","weeklyQuotaResetAtUnix":"0"}}}"#)
    XCTAssertEqual(nullAndZero.metrics.map(\.id), ["empty"])

    let hidden = try await fetch(#"{"userStatus":{"planStatus":{"planInfo":{"hideWeeklyQuota":true},"dailyQuotaRemainingPercent":70,"weeklyQuotaResetAtUnix":"1789891200"}}}"#)
    XCTAssertEqual(hidden.metrics.map(\.id), ["quota-daily"])
    XCTAssertNil(hidden.warning)

    let credits = try await fetch(#"{"userStatus":{"planStatus":{"planInfo":{"billingStrategy":"BILLING_STRATEGY_CREDITS"},"dailyQuotaResetAtUnix":"1789372800","planEnd":"2026-10-13T19:56:36Z"}}}"#)
    XCTAssertEqual(credits.metrics.map(\.id), ["credits"])
    XCTAssertEqual(credits.metrics.first?.usedDisplay, "0")
    XCTAssertNotNil(credits.metrics.first?.resetAt)
  }

  func testOverageMicrosTakePrecedenceAndKeepRoundedSign() async throws {
    for (micros, display) in [("4250000", "$4.25"), ("-1500000", "-$1.50"), ("-4000", "$0.00")] {
      let usage = try await fetch(#"{"userStatus":{"planStatus":{"dailyQuotaRemainingPercent":42,"overageBalanceMicros":"\#(micros)","usageBalance":15}}}"#)
      let balance = try XCTUnwrap(usage.metrics.first { $0.id == "balance" })
      XCTAssertEqual(balance.usedDisplay, display)
      XCTAssertNil(balance.remainingPercent)
      XCTAssertEqual(defaultRingMetrics(for: usage).map(\.id), ["quota-daily"])
      XCTAssertEqual(usage.maxUsagePercent, 58)
    }
  }

  private func fetch(_ json: String) async throws -> ProviderUsage {
    try await DevinQuotaClient(httpClient: MockHTTP(status: 200, body: json)).fetchUsage(configuration: config(), now: now)
  }

  func testEmptyPayloadYieldsPlaceholderMetric() async throws {
    let client = DevinQuotaClient(httpClient: MockHTTP(status: 200, body: "{}"))

    let usage = try await client.fetchUsage(configuration: config(), now: now)

    XCTAssertEqual(usage.metrics.map(\.id), ["empty"])
    XCTAssertEqual(usage.maxUsagePercent, 0)
  }

  func testSendsKeyInMetadataAndBearerHeader() async throws {
    let mock = CapturingHTTP(status: 200, body: "{}")
    let client = DevinQuotaClient(httpClient: mock)

    _ = try await client.fetchUsage(configuration: config(), now: now)

    let request = try XCTUnwrap(mock.lastRequest)
    XCTAssertEqual(
      request.url?.absoluteString,
      "https://server.codeium.com/exa.seat_management_pb.SeatManagementService/GetUserStatus"
    )
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer devin-session-key")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Connect-Protocol-Version"), "1")

    let body = try XCTUnwrap(request.httpBody)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let metadata = try XCTUnwrap(json["metadata"] as? [String: Any])
    XCTAssertEqual(metadata["api_key"] as? String, "devin-session-key")
  }

  func testAccountServerOverrideChangesEndpoint() async throws {
    let mock = CapturingHTTP(status: 200, body: "{}")
    let client = DevinQuotaClient(httpClient: mock)

    _ = try await client.fetchUsage(
      configuration: config(server: "https://devin.internal.example.com"),
      now: now
    )

    XCTAssertEqual(
      mock.lastRequest?.url?.absoluteString,
      "https://devin.internal.example.com/exa.seat_management_pb.SeatManagementService/GetUserStatus"
    )
  }

  func testInvalidServerOverrideThrowsNotConfigured() async {
    let client = DevinQuotaClient(httpClient: MockHTTP(status: 200, body: "{}"))
    await assertThrows(kind: .notConfigured) {
      try await client.fetchUsage(configuration: self.config(server: "not a url"), now: self.now)
    }
  }

  func testMissingKeyThrowsNotConfigured() async {
    let client = DevinQuotaClient(httpClient: MockHTTP(status: 200, body: "{}"))
    await assertThrows(kind: .notConfigured) {
      try await client.fetchUsage(configuration: self.config(key: nil), now: self.now)
    }
  }

  func testUnauthorizedThrowsAuth() async {
    let client = DevinQuotaClient(httpClient: MockHTTP(status: 401, body: #"{"code":"unauthenticated"}"#))
    await assertThrows(kind: .auth) {
      try await client.fetchUsage(configuration: self.config(), now: self.now)
    }
  }

  func testRateLimitThrowsRateLimit() async {
    let client = DevinQuotaClient(httpClient: MockHTTP(status: 429, body: "slow down"))
    await assertThrows(kind: .rateLimit) {
      try await client.fetchUsage(configuration: self.config(), now: self.now)
    }
  }

  func testConnectErrorThrowsAPI() async {
    let client = DevinQuotaClient(httpClient: MockHTTP(status: 400, body: #"{"code":"invalid_argument","message":"bad request"}"#))
    await assertThrows(kind: .api, messageContains: "HTTP 400") {
      try await client.fetchUsage(configuration: self.config(), now: self.now)
    }
  }

  private func assertThrows(
    kind: QuotaErrorKind,
    messageContains: String? = nil,
    _ block: @escaping () async throws -> ProviderUsage,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      _ = try await block()
      XCTFail("Expected error of kind \(kind)", file: file, line: line)
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, kind, file: file, line: line)
      if let messageContains {
        XCTAssertTrue(
          error.message.contains(messageContains),
          "Expected message containing \"\(messageContains)\", got: \(error.message)",
          file: file,
          line: line
        )
      }
    } catch {
      XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
  }
}

private struct MockHTTP: HTTPClient {
  let status: Int
  let body: String

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: status,
      httpVersion: "HTTP/1.1",
      headerFields: nil
    )!
    return (body.data(using: .utf8)!, response)
  }
}

private final class CapturingHTTP: HTTPClient, @unchecked Sendable {
  let status: Int
  let body: String
  private(set) var lastRequest: URLRequest?

  init(status: Int, body: String) {
    self.status = status
    self.body = body
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    lastRequest = request
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: status,
      httpVersion: "HTTP/1.1",
      headerFields: nil
    )!
    return (body.data(using: .utf8)!, response)
  }
}
