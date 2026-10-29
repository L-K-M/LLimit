import Foundation
import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class MistralQuotaClientTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_793_232_000)
  private let userID = "11111111-1111-4111-8111-111111111111"
  private let organizationID = "22222222-2222-4222-8222-222222222222"
  private let sessionHeader = "ory_session_test=owned-session-fixture; csrftoken=csrf-fixture"
  private let reset = "2026-11-01T00:00:00Z"

  private func configuration(savedIdentity: Bool = true) -> ProviderRuntimeConfiguration {
    var credentials = [CredentialField.mistralSessionCookies: sessionHeader]
    if savedIdentity {
      credentials[CredentialField.mistralUserID] = userID
      credentials[CredentialField.mistralOrganizationID] = organizationID
    }
    return ProviderRuntimeConfiguration(accountID: "mistral-personal", provider: .mistral,
      displayName: "Personal Mistral", isEnabled: true, credentials: credentials)
  }

  private func bucket(percent: Any = 4.3921594, total: Any = 10, resetAt: Any? = nil) -> [String: Any] {
    ["usage_percentage": percent, "initial_budget": total, "currency": "USD", "reset_at": resetAt ?? reset]
  }

  private func budget(api: [String: Any]? = nil, vibe: [String: Any]? = nil) -> [String: Any] {
    var result = bucket()
    result["api_budget"] = api ?? bucket()
    result["vibe_budget"] = vibe ?? bucket(percent: 0)
    return result
  }

  /// Synthetic React Flight data matching the official subscription page's
  /// identity reference and budget props. It contains no captured user data.
  private func page(budget: [String: Any]? = nil, user: String? = nil, organization: String? = nil,
                    reference: String = "$9:props:children:props:user", includeIdentity: Bool = true,
                    splitFrames: Bool = false, extraProps: [String: Any] = [:], textRecord: String? = nil,
                    additionalBudget: [String: Any]? = nil) throws -> String {
    let identity: [String: Any] = ["uuid": user ?? userID,
      "organization": ["uuid": organization ?? organizationID]]
    let identityRecord: [Any] = ["$", "$Lx", NSNull(),
      ["children": ["$", "$Ly", NSNull(), ["user": identity]]]]
    var props: [String: Any] = ["user": reference, "subscriptions": [], "billingInfo": [:],
      "budget": budget ?? self.budget()]
    props.merge(extraProps) { _, new in new }
    let quotaRecord: [Any] = ["$", "$Lz", NSNull(),
      ["children": [NSNull(), ["$", "$La", NSNull(), props]]]]
    func json(_ value: Any) throws -> String {
      String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
    var stream = includeIdentity ? try "9:\(json(identityRecord))\n" : ""
    stream += try "26:\(json(quotaRecord))\n"
    if let additionalBudget {
      var otherProps = props
      otherProps["budget"] = additionalBudget
      stream += try "27:\(json(["$", "$La", NSNull(), otherProps]))\n"
    }
    if let textRecord {
      stream = "f:T\(String(textRecord.utf8.count, radix: 16)),\(textRecord)" + stream
    }
    let chunks: [String]
    if splitFrames {
      // Deliberately split inside the identity reference, not at record boundaries.
      let middle = stream.range(of: reference).map { stream.index($0.lowerBound, offsetBy: 8) }
        ?? stream.index(stream.startIndex, offsetBy: stream.count / 2)
      chunks = [String(stream[..<middle]), String(stream[middle...])]
    } else { chunks = [stream] }
    return try "<html><body>" + chunks.map {
      "<script>self.__next_f.push(\(try json([1, $0])))</script>"
    }.joined() + "</body></html>"
  }

  func testVerifiedConnectionReadsIdentityAndSeparateMonthlyAllowances() async throws {
    let http = MistralHTTPStub(body: try page())
    let connection = try await MistralQuotaClient(httpClient: http)
      .verifiedConnection(configuration: configuration(savedIdentity: false), now: now)
    XCTAssertEqual(connection.userID, userID)
    XCTAssertEqual(connection.organizationID, organizationID)
    let usage = connection.usage
    XCTAssertEqual(usage.provider, .mistral)
    XCTAssertEqual(usage.accountID, "mistral-personal")
    XCTAssertEqual(usage.title, "Personal Mistral")
    XCTAssertEqual(usage.fetchedAt, now)
    XCTAssertEqual(Set(usage.metrics.map(\.id)), ["vibe-monthly", "api-monthly"])
    XCTAssertEqual(usage.metrics.count, 2, "The aggregate parent budget is not an extra allowance")
    XCTAssertEqual(usage.metrics.first { $0.id == "vibe-monthly" }?.remainingPercent, 100)
    XCTAssertEqual(usage.metrics.first { $0.id == "api-monthly" }?.remainingPercent, 96)
    let expectedReset = try XCTUnwrap(ISO8601DateFormatter().date(from: reset))
    for metric in usage.metrics {
      XCTAssertEqual(metric.resetAt, expectedReset)
      XCTAssertNotNil(metric.resetIn)
      XCTAssertNil(metric.windowSeconds, "A monthly label does not prove the window's start")
      XCTAssertNil(metric.estimatedTotal)
    }
  }

  func testVerifiedManualCredentialsReturnsOnlyCanonicalAuthenticationAndBoundIdentity() async throws {
    let http = MistralHTTPStub(body: try page())
    let credentials = try await MistralQuotaClient(httpClient: http).verifiedManualCredentials(
      header: sessionHeader + "; _ga=analytics-fixture", now: now)
    XCTAssertEqual(credentials[CredentialField.mistralSessionCookies],
      "csrftoken=csrf-fixture; ory_session_test=owned-session-fixture")
    XCTAssertEqual(credentials[CredentialField.mistralUserID], userID)
    XCTAssertEqual(credentials[CredentialField.mistralOrganizationID], organizationID)
    XCTAssertNil(credentials[CredentialField.mistralBrowserSession])
    XCTAssertFalse(credentials.values.contains { $0.contains("analytics-fixture") })
    let requests = await http.requests
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Cookie"), credentials[CredentialField.mistralSessionCookies])
  }

  func testRefreshRequiresBothPreviouslyVerifiedIdentitiesBeforeMakingRequests() async throws {
    let http = MistralHTTPStub(body: try page())
    for key in [CredentialField.mistralUserID, CredentialField.mistralOrganizationID] {
      for value in [nil, ""] as [String?] {
        var config = configuration()
        config.credentials[key] = value
        do {
          _ = try await MistralQuotaClient(httpClient: http).fetchUsage(configuration: config, now: now)
          XCTFail("Expected unverified identity to prevent refresh")
        } catch let error as ProviderClientError {
          XCTAssertEqual(error.kind, .notConfigured)
        }
      }
    }
    let requests = await http.requests
    XCTAssertTrue(requests.isEmpty)
  }

  func testRequestsOnlyFixedSubscriptionPageWithIsolatedTransport() async throws {
    let http = MistralHTTPStub(body: try page())
    var config = configuration()
    config.credentials[CredentialField.mistralSessionCookies] = sessionHeader + "; _ga=analytics-fixture"
    _ = try await MistralQuotaClient(httpClient: http).fetchUsage(configuration: config, now: now)
    let requests = await http.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(request.url?.absoluteString, "https://admin.mistral.ai/subscription")
    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertNil(request.httpBody)
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    let header = try XCTUnwrap(request.value(forHTTPHeaderField: "Cookie"))
    XCTAssertTrue(header.contains("ory_session_test=owned-session-fixture"))
    XCTAssertTrue(header.contains("csrftoken=csrf-fixture"))
    XCTAssertFalse(header.contains("analytics-fixture"))
    let policies = await http.redirectPolicies
    XCTAssertEqual(policies, [.refuse])
  }

  func testReassemblesFramesAndIgnoresEscapedFakeBudgetsInStrings() async throws {
    let decoy = #"a quoted \"budget\":{\"api_budget\":{\"usage_percentage\":99}} and } { braces"#
    let http = MistralHTTPStub(body: try page(splitFrames: true, extraProps: ["message": decoy]))
    let usage = try await MistralQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
    XCTAssertEqual(usage.metrics.count, 2)
    XCTAssertEqual(usage.metrics.first { $0.id == "api-monthly" }?.remainingPercent, 96)
  }

  func testLengthPrefixedFlightTextCannotImpersonateSubscriptionProps() async throws {
    let fakeProps: [String: Any] = ["user": ["uuid": userID, "organization": ["uuid": organizationID]],
      "subscriptions": [], "billingInfo": [:], "budget": budget(api: bucket(percent: 99))]
    let fakeJSON = String(decoding: try JSONSerialization.data(withJSONObject: fakeProps), as: UTF8.self)
    let text = "This text contains a fake record with unicode: é 😀\n38:\(fakeJSON)\n"
    let http = MistralHTTPStub(body: try page(textRecord: text))
    let usage = try await MistralQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
    XCTAssertEqual(usage.metrics.count, 2)
    XCTAssertEqual(usage.metrics.first { $0.id == "api-monthly" }?.remainingPercent, 96)
  }

  func testConflictingAuthoritativeBudgetPropsAreRejected() async throws {
    let http = MistralHTTPStub(body: try page(additionalBudget: budget(api: bucket(percent: 99))))
    await assertFailure(http, expected: .decoding)
  }

  func testMissingIdentityAndBrokenUserReferenceFailClosed() async throws {
    for body in [try page(includeIdentity: false), try page(reference: "$9:props:children:props:missing"),
                 try page(reference: "$88:props:user")] {
      await assertFailure(MistralHTTPStub(body: body))
    }
  }

  func testSavedUserAndOrganizationMustBothMatch() async throws {
    for body in [try page(user: "33333333-3333-4333-8333-333333333333"),
                 try page(organization: "44444444-4444-4444-8444-444444444444")] {
      await assertFailure(MistralHTTPStub(body: body), expected: .auth)
    }
  }

  func testPartialOrMalformedAllowancesDoNotSilentlyDropASibling() async throws {
    var noAPI = budget()
    noAPI.removeValue(forKey: "api_budget")
    var noVibe = budget()
    noVibe.removeValue(forKey: "vibe_budget")
    for value in [noAPI, noVibe, budget(api: bucket(percent: -1)),
                  budget(vibe: bucket(percent: true)), budget(api: bucket(percent: "4.3921594")),
                  budget(api: bucket(total: "not-an-amount"))] {
      await assertFailure(MistralHTTPStub(body: try page(budget: value)), expected: .decoding)
    }
  }

  func testMissingAndNullPercentageStayUnavailableForReportedBuckets() async throws {
    var absent = bucket()
    absent.removeValue(forKey: "usage_percentage")
    for api in [absent, bucket(percent: NSNull()), bucket(percent: 0, total: 0)] {
      let http = MistralHTTPStub(body: try page(budget: budget(api: api)))
      let usage = try await MistralQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
      let metric = try XCTUnwrap(usage.metrics.first { $0.id == "api-monthly" })
      XCTAssertNil(metric.remainingPercent)
      XCTAssertFalse(metric.isUnlimited)
      XCTAssertEqual(usage.metrics.first { $0.id == "vibe-monthly" }?.remainingPercent, 100)
    }
  }

  func testUsageAboveAllowanceClampsGeometryAndKeepsReportedDetail() async throws {
    let http = MistralHTTPStub(body: try page(budget: budget(api: bucket(percent: 125))))
    let usage = try await MistralQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
    let metric = try XCTUnwrap(usage.metrics.first { $0.id == "api-monthly" })
    XCTAssertEqual(metric.remainingPercent, 0)
    let detail = [metric.detail, metric.usedDisplay].compactMap { $0 }.joined(separator: " ")
    XCTAssertTrue(detail.contains("125"), "The server's overage percentage must remain inspectable")
  }

  func testNoServerResetDoesNotInventBillingSchedule() async throws {
    let http = MistralHTTPStub(body: try page(budget: budget(api: bucket(resetAt: NSNull()),
      vibe: bucket(percent: 0, resetAt: NSNull()))))
    let usage = try await MistralQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
    XCTAssertTrue(usage.metrics.allSatisfy { $0.resetAt == nil && $0.resetIn == nil && $0.windowSeconds == nil })
  }

  func testAuthStatusesAndRateLimitNeverEchoResponseBody() async throws {
    let secret = "private-response-fixture owned-session-fixture csrf-fixture"
    for status in [301, 302, 303, 307, 308, 401, 403] {
      await assertFailure(MistralHTTPStub(body: secret, status: status), expected: .auth)
    }
    let http = MistralHTTPStub(body: secret, status: 429, headers: ["Retry-After": "120"])
    do {
      _ = try await MistralQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
      XCTFail("Expected rate limit")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .rateLimit)
      XCTAssertEqual(error.statusCode, 429)
      XCTAssertEqual(error.retryAfter, 120)
      XCTAssertFalse(error.message.contains("private-response-fixture"))
      XCTAssertFalse(error.message.contains("owned-session-fixture"))
    }
    await assertFailure(MistralHTTPStub(body: secret, status: 500), expected: .api)
  }

  func testUnexpectedResponseOriginAndOversizedBodyFailClosed() async throws {
    await assertFailure(MistralHTTPStub(body: try page(), responseURL: URL(string: "https://auth.mistral.ai/login")!))
    await assertFailure(MistralHTTPStub(body: String(repeating: "x", count: 8 * 1_024 * 1_024)), expected: .decoding)
  }

  func testMissingCredentialsDoesNotMakeRequests() async throws {
    let http = MistralHTTPStub(body: try page())
    var config = configuration()
    config.credentials = [:]
    do {
      _ = try await MistralQuotaClient(httpClient: http).fetchUsage(configuration: config, now: now)
      XCTFail("Expected missing credentials")
    } catch let error as ProviderClientError { XCTAssertEqual(error.kind, .notConfigured) }
    let requests = await http.requests
    XCTAssertTrue(requests.isEmpty)
  }

  func testExpiredSavedSessionDoesNotMakeRequests() async throws {
    let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: "ory_session_test", .value: "owned-session-fixture",
      .domain: ".mistral.ai", .path: "/", .secure: "TRUE", HTTPCookiePropertyKey("HttpOnly"): "TRUE",
      .expires: now.addingTimeInterval(60)]))
    let browser = try MistralBrowserSession(cookies: [cookie], now: now)
    var config = configuration()
    config.credentials = try browser.credentials(userID: userID, organizationID: organizationID)
    let http = MistralHTTPStub(body: try page())
    do {
      _ = try await MistralQuotaClient(httpClient: http).fetchUsage(configuration: config, now: now.addingTimeInterval(60))
      XCTFail("Expected expired session")
    } catch let error as ProviderClientError { XCTAssertEqual(error.kind, .auth) }
    let requests = await http.requests
    XCTAssertTrue(requests.isEmpty)
  }

  func testLiveCoordinatorRegistersMistralAndSharedSettingsStayCredentialFree() async throws {
    let http = MistralHTTPStub(body: try page())
    let snapshot = await QuotaCoordinator.live(httpClient: http).refresh(configurations: [configuration()], now: now)
    XCTAssertTrue(snapshot.failures.isEmpty)
    XCTAssertEqual(snapshot.providers.first?.provider, .mistral)
    let settings = AppSettings(accounts: [ProviderAccount(provider: .mistral, credentials: configuration().credentials)])
    XCTAssertTrue(settings.redactedCredentials().accounts.allSatisfy { $0.credentials.isEmpty })
  }

  private func assertFailure(_ http: MistralHTTPStub, expected: QuotaErrorKind? = nil,
                             file: StaticString = #filePath, line: UInt = #line) async {
    do {
      _ = try await MistralQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
      XCTFail("Expected invalid Mistral response to fail", file: file, line: line)
    } catch let error as ProviderClientError {
      if let expected { XCTAssertEqual(error.kind, expected, file: file, line: line) }
      XCTAssertFalse(error.message.contains("owned-session-fixture"), file: file, line: line)
      XCTAssertFalse(error.message.contains("csrf-fixture"), file: file, line: line)
      XCTAssertFalse(error.message.contains("private-response-fixture"), file: file, line: line)
    } catch { XCTFail("Unexpected error type", file: file, line: line) }
  }
}

private actor MistralHTTPStub: HTTPClient {
  let body: String
  let status: Int
  let headers: [String: String]
  let responseURL: URL?
  private(set) var requests: [URLRequest] = []
  private(set) var redirectPolicies: [HTTPRedirectPolicy] = []

  init(body: String, status: Int = 200, headers: [String: String] = [:], responseURL: URL? = nil) {
    self.body = body
    self.status = status
    self.headers = headers
    self.responseURL = responseURL
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    let response = HTTPURLResponse(url: responseURL ?? request.url!, statusCode: status,
      httpVersion: "HTTP/1.1", headerFields: headers)!
    return (Data(body.utf8), response)
  }

  func data(for request: URLRequest, redirects: HTTPRedirectPolicy) async throws -> (Data, HTTPURLResponse) {
    redirectPolicies.append(redirects)
    return try await data(for: request)
  }
}
