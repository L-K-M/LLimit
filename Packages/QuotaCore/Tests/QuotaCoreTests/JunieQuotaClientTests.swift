import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class JunieQuotaClientTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_792_368_000)
  private let key = "perm-junie-fixture"

  private func configuration(key: String? = "perm-junie-fixture", id: String = "junie-personal") -> ProviderRuntimeConfiguration {
    ProviderRuntimeConfiguration(
      accountID: id, provider: .junie, displayName: "Personal Junie", isEnabled: true,
      credentials: key.map { [CredentialField.junieAPIKey: $0] } ?? [:]
    )
  }

  func testReadsCreditBalanceUsingJunieScaleWithoutInventingQuota() async throws {
    let http = JunieHTTPStub(body: #"{"active":true,"balanceLeft":1250000,"balanceUnit":"AI_CREDITS","licenseType":"ULTIMATE"}"#)
    let usage = try await JunieQuotaClient(httpClient: http).fetchUsage(configuration: configuration(key: " \(key)\n"), now: now)

    XCTAssertEqual(usage.accountID, "junie-personal")
    XCTAssertEqual(usage.provider, .junie)
    XCTAssertEqual(usage.title, "Personal Junie")
    XCTAssertEqual(usage.fetchedAt, now)
    let metric = try XCTUnwrap(usage.metrics.first)
    XCTAssertEqual(metric.id, "credit-balance")
    XCTAssertEqual(metric.remainingAmount, 12.5)
    XCTAssertEqual(metric.usedDisplay, "12.5 credits")
    XCTAssertNil(metric.remainingPercent)
    XCTAssertNil(metric.totalDisplay)
    XCTAssertNil(metric.resetAt)
    XCTAssertNil(usage.maxUsagePercent)
    XCTAssertNil(usage.warning)
    XCTAssertTrue(defaultRingMetrics(for: usage).isEmpty)

    let requests = await http.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(request.url?.absoluteString, "https://ingrazzio-cloud-prod.labs.jb.gg/auth/test")
    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertNil(request.httpBody)
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Accept-EAP-License"), "false")
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Accept-Release-License"), "true")
  }

  func testUSDUsesUnscaledBalanceAndMissingUnitUsesCreditScale() async throws {
    for (unit, expected, display) in [(#""USD""#, 12.5, "12.5 USD"), ("null", 0.000125, "0.000125 credits")] {
      let http = JunieHTTPStub(body: "{\"balanceLeft\":12.5,\"balanceUnit\":\(unit)}")
      let usage = try await JunieQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
      XCTAssertEqual(usage.metrics.first?.remainingAmount, expected)
      XCTAssertEqual(usage.metrics.first?.usedDisplay, display)
    }
  }

  func testSignedAndTinyBalancesRemainAccurate() async throws {
    for (balance, display, warning) in [
      ("0", "0 credits", true), ("-250000", "-2.5 credits", true),
      ("0.001", "1e-08 credits", false), ("0.1", "0.000001 credits", false)
    ] {
      let usage = try await JunieQuotaClient(httpClient: JunieHTTPStub(body: "{\"balanceLeft\":\(balance)}"))
        .fetchUsage(configuration: configuration(), now: now)
      XCTAssertEqual(usage.metrics.first?.usedDisplay, display)
      XCTAssertEqual(usage.warning != nil, warning)
    }
  }

  func testRejectsMissingAndMalformedKeysBeforeNetworking() async {
    for candidate in [nil, "", " \n", "fixture key", "fixture\nkey", "fixture\u{0000}key"] as [String?] {
      let http = JunieHTTPStub(body: #"{"balanceLeft":1}"#)
      await assertFailure(.notConfigured) {
        try await JunieQuotaClient(httpClient: http).fetchUsage(configuration: self.configuration(key: candidate), now: self.now)
      }
      let requests = await http.requests
      XCTAssertTrue(requests.isEmpty)
    }
  }

  func testRejectsMalformedBalancesAndInactiveAccounts() async {
    for body in ["{}", "null", "not json", #"{"balanceLeft":null}"#, #"{"balanceLeft":true}"#,
                 #"{"balanceLeft":"12.5"}"#, #"{"balanceLeft":1e999}"#] {
      await assertFailure(.api) {
        try await JunieQuotaClient(httpClient: JunieHTTPStub(body: body)).fetchUsage(configuration: self.configuration(), now: self.now)
      }
    }
    await assertFailure(.auth) {
      try await JunieQuotaClient(httpClient: JunieHTTPStub(body: #"{"active":false,"balanceLeft":100000}"#))
        .fetchUsage(configuration: self.configuration(), now: self.now)
    }
  }

  func testDoesNotPublishGZLLicenseBalanceAsAUsableAllowance() async {
    await assertFailure(.api) {
      try await JunieQuotaClient(httpClient: JunieHTTPStub(body: #"{"licenseType":"GZL","balanceLeft":999999999}"#))
        .fetchUsage(configuration: self.configuration(), now: self.now)
    }
  }

  func testRejectsNoLicenseEvenWhenActiveIsMissingOrTrue() async {
    for active in ["null", "true"] {
      await assertFailure(.auth) {
        try await JunieQuotaClient(httpClient: JunieHTTPStub(body: "{\"licenseType\":\"NONE\",\"active\":\(active),\"balanceLeft\":100000}"))
          .fetchUsage(configuration: self.configuration(), now: self.now)
      }
    }
  }

  func testSanitizesServerAndTransportErrorsAndRespectsRetryAfter() async throws {
    for (status, kind) in [(401, QuotaErrorKind.auth), (403, .auth), (429, .rateLimit), (500, .api)] {
      let http = JunieHTTPStub(status: status, body: key, headers: ["Retry-After": "120"])
      do {
        _ = try await JunieQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
        XCTFail("Expected HTTP failure")
      } catch let error as ProviderClientError {
        XCTAssertEqual(error.kind, kind)
        XCTAssertEqual(error.statusCode, status)
        XCTAssertEqual(error.retryAfter, status == 429 ? 120 : nil)
        XCTAssertFalse(error.message.contains(key))
      }
    }
    await assertFailure(.network) {
      try await JunieQuotaClient(httpClient: JunieFailingHTTP(error: ProviderClientError(kind: .network, message: self.key)))
        .fetchUsage(configuration: self.configuration(), now: self.now)
    }
  }

  func testCancellationRemainsCancellation() async {
    for error in [CancellationError(), URLError(.cancelled)] as [any Error & Sendable] {
      do {
        _ = try await JunieQuotaClient(httpClient: JunieFailingHTTP(error: error))
          .fetchUsage(configuration: configuration(), now: now)
        XCTFail("Expected cancellation")
      } catch is CancellationError {
      } catch {
        XCTFail("Expected cancellation, got \(error)")
      }
    }
  }

  func testCoordinatorSeparatesAccountsAndDoesNotPublishResponseSecrets() async throws {
    let http = JunieHTTPStub(body: "{\"balanceLeft\":750000,\"balanceUnit\":\"\(key)\",\"username\":\"\(key)\",\"licenseType\":\"\(key)\"}")
    let accounts = [configuration(), configuration(key: "perm-other-fixture", id: "junie-work")]
    let snapshot = await QuotaCoordinator.live(httpClient: http).refresh(configurations: accounts, now: now)
    XCTAssertTrue(snapshot.failures.isEmpty)
    XCTAssertEqual(snapshot.providers.map(\.accountID), ["junie-personal", "junie-work"])
    XCTAssertEqual(snapshot.providers.map { $0.metrics.first?.remainingAmount }, [7.5, 7.5])
    let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
    XCTAssertFalse(json.contains(key))
    XCTAssertFalse(json.contains("perm-other-fixture"))
    XCTAssertTrue(QuotaProvider.junie.hasRequiredCredentials([CredentialField.junieAPIKey: key]))
    XCTAssertTrue(AppSettings(accounts: [ProviderAccount(provider: .junie, credentials: [CredentialField.junieAPIKey: key])])
      .redactedCredentials().accounts.allSatisfy { $0.credentials.isEmpty })
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

private actor JunieHTTPStub: HTTPClient {
  let status: Int
  let body: String
  let headers: [String: String]
  private(set) var requests: [URLRequest] = []

  init(status: Int = 200, body: String, headers: [String: String] = [:]) {
    self.status = status
    self.body = body
    self.headers = headers
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
  }
}

private struct JunieFailingHTTP: HTTPClient {
  let error: any Error & Sendable

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    throw error
  }
}
