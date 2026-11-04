import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class CommandCodeQuotaClientTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_793_491_200)
  private let key = "user_commandcode-inert-fixture"
  private let whoami = #"{"success":true,"user":{"id":"fixture-user"},"org":null}"#
  private let credits = #"{"credits":{"monthlyCredits":50,"purchasedCredits":5,"freeCredits":2},"windowLimits":{"limited":true,"fiveHour":{"used":3.5,"cap":14,"resetAt":1796083200000},"weekly":{"used":7,"cap":35,"resetAt":0}}}"#
  private let subscription = #"{"success":true,"data":{"status":"active","planId":"unknown-fixture-plan","currentPeriodStart":"2026-11-01T00:00:00Z","currentPeriodEnd":"2026-12-01T00:00:00Z"}}"#

  private func configuration(key: String? = "user_commandcode-inert-fixture", id: String = "commandcode-personal") -> ProviderRuntimeConfiguration {
    ProviderRuntimeConfiguration(accountID: id, provider: .commandCode, displayName: "Personal Command Code", isEnabled: true,
      credentials: key.map { [CredentialField.commandCodeAPIKey: $0] } ?? [:])
  }

  private func stub(whoami: String? = nil, credits: String? = nil, subscription: String? = nil) -> CommandCodeHTTPStub {
    CommandCodeHTTPStub(bodies: ["/alpha/whoami": whoami ?? self.whoami,
      "/alpha/billing/credits": credits ?? self.credits,
      "/alpha/billing/subscriptions": subscription ?? self.subscription])
  }

  func testReadsSeparateQuotaWindowsAndBalancesWithoutInventingMonthlyAllowance() async throws {
    let http = stub()
    let usage = try await CommandCodeQuotaClient(httpClient: http)
      .fetchUsage(configuration: configuration(key: " \(key)\n"), now: now)
    XCTAssertEqual(usage.accountID, "commandcode-personal")
    XCTAssertEqual(usage.provider, .commandCode)
    XCTAssertEqual(usage.title, "Personal Command Code")
    XCTAssertEqual(usage.fetchedAt, now)
    let metrics = Dictionary(uniqueKeysWithValues: usage.metrics.map { ($0.id, $0) })
    let fiveHour = try XCTUnwrap(metrics["five-hour"])
    XCTAssertEqual(fiveHour.remainingPercent, 75)
    XCTAssertEqual(fiveHour.remainingAmount, 10.5)
    XCTAssertEqual(fiveHour.windowSeconds, 18_000)
    XCTAssertEqual(fiveHour.resetAt, Date(timeIntervalSince1970: 1_796_083_200))
    XCTAssertFalse(fiveHour.isUnlimited)
    let weekly = try XCTUnwrap(metrics["weekly"])
    XCTAssertEqual(weekly.remainingPercent, 80)
    XCTAssertEqual(weekly.remainingAmount, 28)
    XCTAssertEqual(weekly.windowSeconds, 604_800)
    XCTAssertNil(weekly.resetAt)
    XCTAssertNil(weekly.resetIn)
    let monthly = try XCTUnwrap(metrics["monthly-credits"])
    XCTAssertEqual(monthly.remainingAmount, 50)
    XCTAssertNil(monthly.remainingPercent)
    XCTAssertNil(monthly.totalDisplay)
    XCTAssertEqual(monthly.resetAt, Date(timeIntervalSince1970: 1_796_083_200))
    XCTAssertEqual(monthly.windowSeconds, 2_592_000)
    for (id, amount) in [("purchased-credits", 5.0), ("free-credits", 2.0)] {
      let metric = try XCTUnwrap(metrics[id])
      XCTAssertEqual(metric.remainingAmount, amount)
      XCTAssertNil(metric.remainingPercent)
      XCTAssertNil(metric.totalDisplay)
      XCTAssertNil(metric.windowSeconds)
      XCTAssertNil(metric.resetAt)
      XCTAssertFalse(metric.isUnlimited)
    }
    XCTAssertEqual(defaultRingMetrics(for: usage).map(\.id), ["five-hour", "weekly"])
    let encoded = String(decoding: try JSONEncoder().encode(usage), as: UTF8.self)
    XCTAssertFalse(encoded.contains("USD"))
    XCTAssertFalse(encoded.contains(key))
  }

  func testUsesOnlyReadOnlyFixedOriginRequestsWithIsolatedCredentials() async throws {
    let http = stub()
    _ = try await CommandCodeQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
    let requests = await http.requests
    XCTAssertEqual(requests.count, 3)
    XCTAssertEqual(Set(requests.compactMap { $0.url?.path }),
      Set(["/alpha/whoami", "/alpha/billing/credits", "/alpha/billing/subscriptions"]))
    for request in requests {
      XCTAssertEqual(request.url?.scheme, "https")
      XCTAssertEqual(request.url?.host, "api.commandcode.ai")
      XCTAssertEqual(request.httpMethod, "GET")
      XCTAssertNil(request.httpBody)
      XCTAssertFalse(request.httpShouldHandleCookies)
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }
    let policies = await http.redirectPolicies
    XCTAssertEqual(policies.count, 3)
    XCTAssertTrue(policies.allSatisfy { $0 == .refuse })
    let identityRequest = try XCTUnwrap(requests.first { $0.url?.path == "/alpha/whoami" })
    XCTAssertEqual(URLComponents(url: identityRequest.url!, resolvingAgainstBaseURL: false)?.queryItems,
      [URLQueryItem(name: "limits", value: "1")])
    for request in requests where request.url?.path != "/alpha/whoami" {
      XCTAssertNil(request.url?.query)
    }
  }

  func testOrganizationContextComesFromAuthenticatedIdentity() async throws {
    let http = stub(whoami: #"{"success":true,"user":null,"org":{"id":"org-fixture","login":"untrusted-display-name"}}"#)
    let usage = try await CommandCodeQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
    let requests = await http.requests
    for request in requests where request.url?.path != "/alpha/whoami" {
      XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
        [URLQueryItem(name: "orgId", value: "org-fixture")])
    }
    let encoded = String(decoding: try JSONEncoder().encode(usage), as: UTF8.self)
    XCTAssertFalse(encoded.contains("org-fixture"))
    XCTAssertFalse(encoded.contains("untrusted-display-name"))
  }

  func testBalanceOnlyAccountsDoNotAppearUnlimitedOrInventQuotaWindows() async throws {
    let http = stub(credits: #"{"credits":{"monthlyCredits":0,"purchasedCredits":5,"freeCredits":2},"windowLimits":{"limited":false}}"#,
                    subscription: #"{"success":true,"data":null}"#)
    let usage = try await CommandCodeQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
    XCTAssertFalse(usage.metrics.contains { ["five-hour", "weekly"].contains($0.id) })
    XCTAssertTrue(defaultRingMetrics(for: usage).isEmpty)
    XCTAssertTrue(usage.metrics.allSatisfy { $0.remainingPercent == nil && !$0.isUnlimited && $0.resetAt == nil && $0.windowSeconds == nil })
    XCTAssertEqual(usage.metrics.first { $0.id == "purchased-credits" }?.remainingAmount, 5)
    XCTAssertEqual(usage.metrics.first { $0.id == "free-credits" }?.remainingAmount, 2)
  }

  func testMonthlyUnknownOrAnnualPeriodDoesNotInventMonthlyResetOrPercent() async throws {
    for value in [#"{"success":true,"data":{"status":"active","planId":"individual-goat"}}"#,
                  #"{"success":true,"data":{"status":"active","planId":"new-plan","currentPeriodStart":"2026-11-01T00:00:00Z","currentPeriodEnd":"2027-11-01T00:00:00Z"}}"#] {
      let usage = try await CommandCodeQuotaClient(httpClient: stub(subscription: value))
        .fetchUsage(configuration: configuration(), now: now)
      let monthly = try XCTUnwrap(usage.metrics.first { $0.id == "monthly-credits" })
      XCTAssertEqual(monthly.remainingAmount, 50)
      XCTAssertNil(monthly.remainingPercent)
      XCTAssertNil(monthly.totalDisplay)
      XCTAssertNil(monthly.resetAt)
      XCTAssertNil(monthly.windowSeconds)
    }
  }

  func testNonrenewingSubscriptionsRetainCreditsWithoutPromisingRefill() async throws {
    for fields in [#""status":"canceled""#, #""status":"past_due""#,
                   #""status":"active","cancelAtPeriodEnd":true"#, #""status":"unknown-status""#] {
      let value = "{\"success\":true,\"data\":{\(fields),\"currentPeriodStart\":\"2026-11-01T00:00:00Z\",\"currentPeriodEnd\":\"2026-12-01T00:00:00Z\"}}"
      let usage = try await CommandCodeQuotaClient(httpClient: stub(subscription: value))
        .fetchUsage(configuration: configuration(), now: now)
      let monthly = try XCTUnwrap(usage.metrics.first { $0.id == "monthly-credits" })
      XCTAssertEqual(monthly.remainingAmount, 50)
      XCTAssertNil(monthly.remainingPercent)
      XCTAssertNil(monthly.totalDisplay)
      XCTAssertNil(monthly.resetAt)
      XCTAssertNil(monthly.resetIn)
      XCTAssertNil(monthly.windowSeconds)
    }
  }

  func testBenchmarkUsesExactCreditDeltaAndRejectsChangedWindowCap() async throws {
    let before = try await CommandCodeQuotaClient(httpClient: stub())
      .fetchUsage(configuration: configuration(), now: now)
    let afterCredits = credits.replacingOccurrences(of: #""used":7,"cap":35"#, with: #""used":7.01,"cap":35"#)
    let after = try await CommandCodeQuotaClient(httpClient: stub(credits: afterCredits))
      .fetchUsage(configuration: configuration(), now: now.addingTimeInterval(1))
    let beforeWeekly = try XCTUnwrap(before.metrics.first { $0.id == "weekly" })
    let afterWeekly = try XCTUnwrap(after.metrics.first { $0.id == "weekly" })
    XCTAssertEqual(beforeWeekly.remainingPercent, 80)
    XCTAssertEqual(afterWeekly.remainingPercent, 80)
    XCTAssertEqual(beforeWeekly.totalAmount, 35)
    XCTAssertEqual(afterWeekly.totalAmount, 35)
    XCTAssertNil(before.metrics.first { $0.id == "monthly-credits" }?.totalAmount)
    let change = try XCTUnwrap(BenchmarkQuotaChange.changes(before: before, after: after).first { $0.metricID == "weekly" })
    XCTAssertEqual(try XCTUnwrap(change.consumedAmount), 0.01, accuracy: 0.0000001)
    XCTAssertNotNil(change.consumedPercentagePoints)
    if let points = change.consumedPercentagePoints {
      XCTAssertEqual(points, 0.01 / 35 * 100, accuracy: 0.0000001)
    }
    XCTAssertNil(change.unavailableReason)

    // A lower remaining amount and lower integer percentage can look like
    // consumption even though the provider changed the complete allowance.
    let changedCredits = credits.replacingOccurrences(of: #""used":7,"cap":35"#, with: #""used":49.01,"cap":70"#)
    let changed = try await CommandCodeQuotaClient(httpClient: stub(credits: changedCredits))
      .fetchUsage(configuration: configuration(), now: now.addingTimeInterval(2))
    let invalid = try XCTUnwrap(BenchmarkQuotaChange.changes(before: before, after: changed).first { $0.metricID == "weekly" })
    XCTAssertNil(invalid.consumedAmount)
    XCTAssertNil(invalid.consumedPercentagePoints)
    XCTAssertTrue(invalid.unavailableReason?.contains("denominator") == true)
  }

  func testZeroAndExceededWindowCapsRemainBoundedWithoutUnlimitedClaims() async throws {
    let http = stub(credits: #"{"credits":{"monthlyCredits":0,"purchasedCredits":0,"freeCredits":0},"windowLimits":{"limited":true,"fiveHour":{"used":3,"cap":0,"resetAt":0},"weekly":{"used":42,"cap":35,"resetAt":0}}}"#)
    let usage = try await CommandCodeQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
    for id in ["five-hour", "weekly"] {
      let metric = try XCTUnwrap(usage.metrics.first { $0.id == id })
      XCTAssertEqual(metric.remainingPercent, 0)
      XCTAssertEqual(metric.remainingAmount, 0)
      XCTAssertFalse(metric.isUnlimited)
    }
    let weekly = try XCTUnwrap(usage.metrics.first { $0.id == "weekly" })
    XCTAssertTrue([weekly.usedDisplay, weekly.detail].compactMap { $0 }.joined().contains("42"))
  }

  func testRejectsInvalidKeysBeforeAnyRequest() async {
    for value in [nil, "", " \n", "fixture key", "fixture\nkey", "fixture\u{0000}key", "clé-fixture"] as [String?] {
      let http = stub()
      await assertFailure(.notConfigured) {
        try await CommandCodeQuotaClient(httpClient: http).fetchUsage(configuration: self.configuration(key: value), now: self.now)
      }
      let requests = await http.requests
      XCTAssertTrue(requests.isEmpty)
    }
  }

  func testInvalidIdentityAndUnsuccessfulEnvelopesFailWithoutPublishingBodies() async {
    for body in ["{}", "not-json", #"{"success":false,"user":{"id":"fixture-user"}}"#,
                 #"{"success":true,"user":null,"org":null}"#, #"{"success":true,"user":{"id":""}}"#] {
      await assertFailure(.api) {
        try await CommandCodeQuotaClient(httpClient: self.stub(whoami: body)).fetchUsage(configuration: self.configuration(), now: self.now)
      }
    }
    for body in ["{}", #"{"success":false,"data":null}"#, #"{"success":true}"#] {
      await assertFailure(.api) {
        try await CommandCodeQuotaClient(httpClient: self.stub(subscription: body)).fetchUsage(configuration: self.configuration(), now: self.now)
      }
    }
  }

  func testMalformedQuotaCountsDoNotTurnIntoAnEmptyOrUnlimitedAccount() async {
    let malformed = ["{}", "null", "not-json", #"{"success":false,"credits":{"monthlyCredits":1,"purchasedCredits":0,"freeCredits":0}}"#,
      #"{"credits":{"monthlyCredits":null,"purchasedCredits":0,"freeCredits":0}}"#,
      #"{"credits":{"monthlyCredits":true,"purchasedCredits":0,"freeCredits":0}}"#,
      #"{"credits":{"monthlyCredits":"10","purchasedCredits":0,"freeCredits":0}}"#,
      #"{"credits":{"monthlyCredits":1e999,"purchasedCredits":0,"freeCredits":0}}"#,
      #"{"credits":{"monthlyCredits":10,"freeCredits":0}}"#,
      #"{"credits":{"monthlyCredits":10,"purchasedCredits":0,"freeCredits":0},"windowLimits":{"limited":true}}"#,
      #"{"credits":{"monthlyCredits":10,"purchasedCredits":0,"freeCredits":0},"windowLimits":{"limited":true,"fiveHour":{"used":-1,"cap":14,"resetAt":0}}}"#,
      #"{"credits":{"monthlyCredits":10,"purchasedCredits":0,"freeCredits":0},"windowLimits":{"limited":true,"weekly":{"used":1,"cap":-2,"resetAt":0}}}"#]
    for body in malformed {
      await assertFailure(.api) {
        try await CommandCodeQuotaClient(httpClient: self.stub(credits: body)).fetchUsage(configuration: self.configuration(), now: self.now)
      }
    }
  }

  func testSanitizesHTTPAndTransportErrorsAndPreservesRateLimitDeadline() async throws {
    for (status, kind) in [(301, QuotaErrorKind.api), (401, .auth), (403, .auth), (429, .rateLimit), (500, .api)] {
      let http = CommandCodeHTTPStub(bodies: [:], status: status, headers: ["Retry-After": "120"], fallbackBody: key)
      do {
        _ = try await CommandCodeQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
        XCTFail("Expected HTTP \(status) failure")
      } catch let error as ProviderClientError {
        XCTAssertEqual(error.kind, kind)
        XCTAssertEqual(error.statusCode, status)
        XCTAssertEqual(error.retryAfter, status == 429 ? 120 : nil)
        XCTAssertFalse(error.message.contains(key))
      }
    }
    await assertFailure(.network) {
      try await CommandCodeQuotaClient(httpClient: CommandCodeFailingHTTP(error: ProviderClientError(kind: .network, message: self.key)))
        .fetchUsage(configuration: self.configuration(), now: self.now)
    }
  }

  func testCancellationRemainsCancellation() async {
    for error in [CancellationError(), URLError(.cancelled)] as [any Error & Sendable] {
      do {
        _ = try await CommandCodeQuotaClient(httpClient: CommandCodeFailingHTTP(error: error))
          .fetchUsage(configuration: configuration(), now: now)
        XCTFail("Expected cancellation")
      } catch is CancellationError {
      } catch {
        XCTFail("Expected cancellation, got \(error)")
      }
    }
  }

  func testResponseMetadataNeverReachesSnapshotDisplayFields() async throws {
    let http = stub(whoami: "{\"success\":true,\"user\":{\"id\":\"fixture-user\",\"name\":\"\(key)\"},\"org\":null}",
                    subscription: "{\"success\":true,\"data\":{\"planId\":\"\(key)\",\"status\":\"\(key)\"}}")
    let usage = try await CommandCodeQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
    let encoded = String(decoding: try JSONEncoder().encode(usage), as: UTF8.self)
    XCTAssertFalse(encoded.contains(key))
  }

  private func assertFailure(_ kind: QuotaErrorKind, operation: () async throws -> ProviderUsage) async {
    do {
      _ = try await operation()
      XCTFail("Expected \(kind)")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, kind)
      XCTAssertFalse(error.message.contains(key))
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }
}

private actor CommandCodeHTTPStub: HTTPClient {
  let bodies: [String: String]
  let status: Int
  let headers: [String: String]
  let fallbackBody: String
  private(set) var requests: [URLRequest] = []
  private(set) var redirectPolicies: [HTTPRedirectPolicy] = []

  init(bodies: [String: String], status: Int = 200, headers: [String: String] = [:], fallbackBody: String = "{}") {
    self.bodies = bodies
    self.status = status
    self.headers = headers
    self.fallbackBody = fallbackBody
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    try await data(for: request, redirects: .follow)
  }

  func data(for request: URLRequest, redirects: HTTPRedirectPolicy) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    redirectPolicies.append(redirects)
    let body = bodies[request.url!.path] ?? fallbackBody
    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
  }
}

private struct CommandCodeFailingHTTP: HTTPClient {
  let error: any Error & Sendable

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw error }
  func data(for request: URLRequest, redirects: HTTPRedirectPolicy) async throws -> (Data, HTTPURLResponse) { throw error }
}
