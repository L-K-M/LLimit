import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class StepFunQuotaClientTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private func config(
    token: String? = "oasis-token",
    username: String? = nil,
    password: String? = nil
  ) -> ProviderRuntimeConfiguration {
    var credentials: [String: String] = [:]
    if let token { credentials[CredentialField.stepfunToken] = token }
    if let username { credentials[CredentialField.stepfunUsername] = username }
    if let password { credentials[CredentialField.stepfunPassword] = password }
    return ProviderRuntimeConfiguration(provider: .stepfun, isEnabled: true, credentials: credentials)
  }

  // MARK: - Rate-window plans

  // The documented QueryStepPlanRateLimit shape: fractions remaining,
  // reset epochs as strings or numbers.
  func testParsesRateWindowPlan() async throws {
    let json = #"""
    {
      "status": 1,
      "five_hour_usage_left_rate": 0.99781543,
      "weekly_usage_left_rate": "0.5",
      "five_hour_usage_reset_time": "1777528800",
      "weekly_usage_reset_time": 1778000000
    }
    """#
    let client = StepFunQuotaClient(httpClient: MockHTTP(status: 200, body: json))

    let usage = try await client.fetchUsage(configuration: config(), now: now)

    XCTAssertEqual(usage.provider, .stepfun)
    XCTAssertEqual(usage.subtitle, "Step Plan")

    let session = try XCTUnwrap(usage.metrics.first { $0.id == "window-5-hour" })
    XCTAssertEqual(session.label, "5-hour limit")
    XCTAssertEqual(session.remainingPercent, 100)
    XCTAssertEqual(session.resetAt, Date(timeIntervalSince1970: 1_777_528_800))
    XCTAssertEqual(QuotaWindowKind.classify(metricID: session.id, label: session.label), .session)

    let weekly = try XCTUnwrap(usage.metrics.first { $0.id == "weekly" })
    XCTAssertEqual(weekly.remainingPercent, 50)
    XCTAssertEqual(weekly.resetAt, Date(timeIntervalSince1970: 1_778_000_000))
    XCTAssertEqual(QuotaWindowKind.classify(metricID: weekly.id, label: weekly.label), .weekly)

    XCTAssertEqual(usage.maxUsagePercent, 50)
    XCTAssertNil(usage.warning)
  }

  // Zeroed windows mean "no window configured", not "used up" — a payload
  // with neither windows nor credit must not report a fake exhausted metric.
  func testZeroedWindowsAreNotUsage() async throws {
    let json = #"{"status": 1, "five_hour_usage_left_rate": 0, "weekly_usage_left_rate": 0, "five_hour_usage_reset_time": "0", "weekly_usage_reset_time": "0"}"#
    let client = StepFunQuotaClient(httpClient: MockHTTP(status: 200, body: json))

    let usage = try await client.fetchUsage(configuration: config(), now: now)
    XCTAssertEqual(usage.metrics.map(\.id), ["empty"])
    XCTAssertEqual(usage.maxUsagePercent, 0)
  }

  // MARK: - Credit plans

  func testParsesCreditPlanFromBuckets() async throws {
    let json = #"""
    {
      "status": 1,
      "plan_family": 2,
      "five_hour_usage_left_rate": 0,
      "weekly_usage_left_rate": 0,
      "plan_credit_rate_limit": {
        "subscription_credit_left_rate": "0.9641",
        "subscription_credit_reset_time": "1780185600",
        "credit_buckets": [
          {"credit_total": "400000000", "credit_residual": "385000000", "expire_at": "1780185600", "next_reset_at": "1780185600"},
          {"credit_total": "100000000", "credit_residual": "100000000", "expire_at": "1782000000"}
        ]
      }
    }
    """#
    let client = StepFunQuotaClient(httpClient: MockHTTP(status: 200, body: json))

    let usage = try await client.fetchUsage(configuration: config(), now: now)

    let credit = try XCTUnwrap(usage.metrics.first { $0.id == "credit-monthly" })
    XCTAssertEqual(credit.label, "Monthly credit")
    // 485M residual of 500M total.
    XCTAssertEqual(credit.remainingPercent, 97)
    XCTAssertEqual(credit.usedDisplay, "15.0M")
    XCTAssertEqual(credit.totalDisplay, "500.0M")
    XCTAssertEqual(credit.resetAt, Date(timeIntervalSince1970: 1_780_185_600))
    XCTAssertEqual(QuotaWindowKind.classify(metricID: credit.id, label: credit.label), .monthly)
    XCTAssertNil(usage.metrics.first { $0.id == "window-5-hour" })
  }

  // Without bucket sizes the subscription and top-up rates can't be safely
  // combined — they surface as two metrics instead.
  func testParsesCreditPlanFromRates() async throws {
    let json = #"""
    {
      "status": 1,
      "plan_family": 2,
      "plan_credit_rate_limit": {
        "subscription_credit_left_rate": 0.9641,
        "subscription_credit_reset_time": "1780185600",
        "topup_credit_left_rate": 0.5
      }
    }
    """#
    let client = StepFunQuotaClient(httpClient: MockHTTP(status: 200, body: json))

    let usage = try await client.fetchUsage(configuration: config(), now: now)

    let subscription = try XCTUnwrap(usage.metrics.first { $0.id == "credit-monthly" })
    XCTAssertEqual(subscription.remainingPercent, 96)
    XCTAssertEqual(subscription.resetAt, Date(timeIntervalSince1970: 1_780_185_600))

    let topup = try XCTUnwrap(usage.metrics.first { $0.id == "credit-topup" })
    XCTAssertEqual(topup.label, "Top-up credit")
    XCTAssertEqual(topup.remainingPercent, 50)
  }

  // A live window beats plan_family: a windowed plan must never classify as
  // credit just because the family id is ambiguous.
  func testLiveWindowWinsOverPlanFamily() async throws {
    let json = #"{"status": 1, "plan_family": 2, "five_hour_usage_left_rate": 0.25, "five_hour_usage_reset_time": "1777528800"}"#
    let client = StepFunQuotaClient(httpClient: MockHTTP(status: 200, body: json))

    let usage = try await client.fetchUsage(configuration: config(), now: now)
    let session = try XCTUnwrap(usage.metrics.first { $0.id == "window-5-hour" })
    XCTAssertEqual(session.remainingPercent, 25)
    XCTAssertNil(usage.metrics.first { $0.id == "credit-monthly" })
  }

  // MARK: - Plan name

  func testPlanNameBecomesSubtitle() async throws {
    let mock = RoutingHTTP(routes: [
      ("QueryStepPlanRateLimit", .init(status: 200, body: #"{"status": 1, "five_hour_usage_left_rate": 0.9, "five_hour_usage_reset_time": "1777528800"}"#)),
      ("GetStepPlanStatus", .init(status: 200, body: #"{"status": 1, "subscription": {"name": "Flash Plus"}}"#))
    ])
    let client = StepFunQuotaClient(baseURL: URL(string: "https://stepfun.test")!, httpClient: mock)

    let usage = try await client.fetchUsage(configuration: config(), now: now)
    XCTAssertEqual(usage.subtitle, "Flash Plus")
  }

  func testPlanNameFailureStillReportsUsage() async throws {
    let mock = RoutingHTTP(routes: [
      ("QueryStepPlanRateLimit", .init(status: 200, body: #"{"status": 1, "five_hour_usage_left_rate": 0.9, "five_hour_usage_reset_time": "1777528800"}"#)),
      ("GetStepPlanStatus", .init(status: 500, body: ""))
    ])
    let client = StepFunQuotaClient(baseURL: URL(string: "https://stepfun.test")!, httpClient: mock)

    let usage = try await client.fetchUsage(configuration: config(), now: now)
    XCTAssertEqual(usage.subtitle, "Step Plan")
    XCTAssertEqual(usage.metrics.count, 1)
  }

  // MARK: - Request shape

  func testSendsOasisTokenCookieAndDerivedWebID() async throws {
    let refresh = jwt(payload: ["device_id": "web123"])
    let token = "access-jwt...\(refresh)"
    let mock = RoutingHTTP(routes: [
      ("QueryStepPlanRateLimit", .init(status: 200, body: #"{"status": 1}"#))
    ])
    let client = StepFunQuotaClient(baseURL: URL(string: "https://stepfun.test")!, httpClient: mock)

    _ = try await client.fetchUsage(configuration: config(token: token), now: now)

    let request = try XCTUnwrap(mock.requests.first { $0.url?.absoluteString.contains("QueryStepPlanRateLimit") == true })
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "oasis-webid"), "web123")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Cookie"),
      "Oasis-Token=\(token); Oasis-Webid=web123"
    )
  }

  // MARK: - Login flow

  func testPasswordLoginMintsTokenAndQueries() async throws {
    let anonToken = "anon-access...\(jwt(payload: ["device_id": "anon-dev"]))"
    let signedToken = "signed-access...\(jwt(payload: ["device_id": "signed-dev"]))"
    let mock = RoutingHTTP(routes: [
      ("RegisterDevice", .init(status: 200, body: #"{"accessToken": {"raw": "anon-access"}, "refreshToken": {"raw": "\#(jwt(payload: ["device_id": "anon-dev"]))"}}"#)),
      ("SignInByPassword", .init(status: 200, body: #"{"accessToken": {"raw": "signed-access"}, "refreshToken": {"raw": "\#(jwt(payload: ["device_id": "signed-dev"]))"}}"#)),
      ("QueryStepPlanRateLimit", .init(status: 200, body: #"{"status": 1, "weekly_usage_left_rate": 0.8, "weekly_usage_reset_time": "1778000000"}"#))
    ], homepageHeaders: ["Set-Cookie": "INGRESSCOOKIE=ingress-1; Path=/; HttpOnly"])
    let client = StepFunQuotaClient(baseURL: URL(string: "https://stepfun.test")!, httpClient: mock)

    let usage = try await client.fetchUsage(
      configuration: config(token: nil, username: "13800000000", password: "pw"),
      now: now
    )

    XCTAssertEqual(usage.metrics.first?.id, "weekly")
    XCTAssertEqual(usage.metrics.first?.remainingPercent, 80)

    // The login chain ran in order and the usage query carried the minted token.
    XCTAssertEqual(mock.requests.first?.url?.absoluteString, "https://stepfun.test")
    let paths = mock.requests.compactMap { $0.url?.absoluteString }
    XCTAssertTrue(paths.contains { $0.contains("RegisterDevice") })
    XCTAssertTrue(paths.contains { $0.contains("SignInByPassword") })
    let usageRequest = try XCTUnwrap(mock.requests.last { $0.url?.absoluteString.contains("QueryStepPlanRateLimit") == true })
    XCTAssertEqual(
      usageRequest.value(forHTTPHeaderField: "Cookie"),
      "Oasis-Token=\(signedToken); Oasis-Webid=signed-dev"
    )

    let signIn = try XCTUnwrap(mock.requests.first { $0.url?.absoluteString.contains("SignInByPassword") == true })
    XCTAssertEqual(
      signIn.value(forHTTPHeaderField: "Cookie"),
      "Oasis-Token=\(anonToken); Oasis-Webid=anon-dev; INGRESSCOOKIE=ingress-1"
    )
  }

  func testExpiredStoredTokenFallsBackToPasswordLogin() async throws {
    let mock = RoutingHTTP(routes: [
      ("RegisterDevice", .init(status: 200, body: #"{"accessToken": {"raw": "a"}, "refreshToken": {"raw": "r"}}"#)),
      ("SignInByPassword", .init(status: 200, body: #"{"accessToken": {"raw": "sa"}, "refreshToken": {"raw": "sr"}}"#)),
      ("QueryStepPlanRateLimit", .init(status: 200, body: #"{"status": 0, "message": "token expired"}"#))
    ], homepageHeaders: ["Set-Cookie": "INGRESSCOOKIE=i; Path=/"])
    // First token query fails (status != 1), login succeeds, retry still fails
    // -> surfaces the API error rather than looping.
    let client = StepFunQuotaClient(baseURL: URL(string: "https://stepfun.test")!, httpClient: mock)

    await assertThrows(kind: .api, messageContains: "token expired") {
      try await client.fetchUsage(
        configuration: self.config(username: "u", password: "p"),
        now: self.now
      )
    }
    XCTAssertTrue(mock.requests.contains { $0.url?.absoluteString.contains("SignInByPassword") == true })
  }

  func testMissingCredentialsThrowsNotConfigured() async {
    let client = StepFunQuotaClient(httpClient: MockHTTP(status: 200, body: "{}"))
    await assertThrows(kind: .notConfigured) {
      try await client.fetchUsage(configuration: self.config(token: nil), now: self.now)
    }
  }

  func testMissingCredentialLabelsAcceptEitherSecret() {
    XCTAssertEqual(QuotaProvider.stepfun.missingCredentialLabels(in: [:]), ["Oasis-Token or username plus password"])
    XCTAssertTrue(QuotaProvider.stepfun.missingCredentialLabels(in: [CredentialField.stepfunToken: "t"]).isEmpty)
    XCTAssertTrue(QuotaProvider.stepfun.missingCredentialLabels(in: [
      CredentialField.stepfunUsername: "u",
      CredentialField.stepfunPassword: "p"
    ]).isEmpty)
    // Username alone is not enough.
    XCTAssertEqual(
      QuotaProvider.stepfun.missingCredentialLabels(in: [CredentialField.stepfunUsername: "u"]),
      ["Oasis-Token or username plus password"]
    )
  }

  func testUnauthorizedThrowsAuth() async {
    let client = StepFunQuotaClient(httpClient: MockHTTP(status: 401, body: "unauthorized"))
    await assertThrows(kind: .auth) {
      try await client.fetchUsage(configuration: self.config(), now: self.now)
    }
  }

  func testRateLimitThrowsRateLimit() async {
    let client = StepFunQuotaClient(httpClient: MockHTTP(status: 429, body: "slow down"))
    await assertThrows(kind: .rateLimit) {
      try await client.fetchUsage(configuration: self.config(), now: self.now)
    }
  }

  func testNonSuccessStatusThrowsAPI() async {
    let client = StepFunQuotaClient(httpClient: MockHTTP(status: 200, body: #"{"status": 0, "message": "quota query denied"}"#))
    await assertThrows(kind: .api, messageContains: "quota query denied") {
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

private func jwt(payload: [String: Any]) -> String {
  let data = try! JSONSerialization.data(withJSONObject: payload)
  let segment = data.base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .trimmingCharacters(in: CharacterSet(charactersIn: "="))
  return "eyJhbGciOiJub25lIn0.\(segment).signature"
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

/// Routes requests by URL substring; the bare-base-URL GET carries
/// `homepageHeaders` so the login flow can observe a Set-Cookie.
private final class RoutingHTTP: HTTPClient, @unchecked Sendable {
  struct Stub {
    let status: Int
    let body: String
    var headers: [String: String] = [:]
  }

  private let routes: [(match: String, stub: Stub)]
  private let homepageHeaders: [String: String]
  private let baseURL: String
  private(set) var requests: [URLRequest] = []

  init(routes: [(String, Stub)], homepageHeaders: [String: String] = [:], baseURL: String = "https://stepfun.test") {
    self.routes = routes
    self.homepageHeaders = homepageHeaders
    self.baseURL = baseURL
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    let url = request.url!.absoluteString

    var stub: Stub?
    if url == baseURL || url == "\(baseURL)/" {
      stub = Stub(status: 200, body: "", headers: homepageHeaders)
    } else {
      for route in routes where url.contains(route.match) {
        stub = route.stub
        break
      }
    }

    guard let stub else {
      let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!
      return (Data("no route".utf8), response)
    }
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: stub.status,
      httpVersion: "HTTP/1.1",
      headerFields: stub.headers
    )!
    return (stub.body.data(using: .utf8)!, response)
  }
}
