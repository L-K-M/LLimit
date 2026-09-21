import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class MimoClientTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private func config(key: String? = "tp-key", baseURL: String? = nil) -> ProviderRuntimeConfiguration {
    var credentials: [String: String] = [:]
    if let key { credentials[CredentialField.mimoAPIKey] = key }
    if let baseURL { credentials[CredentialField.mimoAPIBaseURL] = baseURL }
    return ProviderRuntimeConfiguration(provider: .mimo, isEnabled: true, credentials: credentials)
  }

  // The dashboard's monthUsage shape: per-item used/limit counters plus a
  // used-fraction percent.
  func testParsesMonthUsageItems() async throws {
    let json = #"""
    {
      "code": 0,
      "message": "",
      "data": {
        "monthUsage": {
          "percent": 0.1661,
          "items": [{
            "name": "month_total_token",
            "used": 265741632,
            "limit": 1600000000,
            "percent": 0.1661
          }]
        }
      }
    }
    """#
    let http = MockHTTP()
    http.respond(to: "https://token-plan-sgp.xiaomimimo.com/v1/tokenPlan/usage", status: 200, body: json)
    let client = MimoQuotaClient(httpClient: http)

    let usage = try await client.fetchUsage(configuration: config(), now: now)

    XCTAssertEqual(usage.provider, .mimo)
    XCTAssertEqual(usage.subtitle, "Token Plan")
    let metric = try XCTUnwrap(usage.metrics.first { $0.id == "month-total-token" })
    XCTAssertEqual(metric.label, "Monthly total credits")
    XCTAssertEqual(metric.remainingPercent, 83)
    XCTAssertEqual(metric.usedDisplay, "265.7M")
    XCTAssertEqual(metric.totalDisplay, "1.6B")
    XCTAssertEqual(QuotaWindowKind.classify(metricID: metric.id, label: metric.label), .monthly)
    XCTAssertEqual(usage.maxUsagePercent, 17)
  }

  // A configured base URL pins the account to that cluster — no probing.
  func testConfiguredBaseURLIsTheOnlyEndpointTried() async throws {
    let json = #"{"data":{"monthUsage":{"items":[{"name":"month_total_token","used":1,"limit":100}]}}}"#
    let http = MockHTTP()
    http.respond(to: "https://token-plan-cn.xiaomimimo.com/v1/tokenPlan/usage", status: 200, body: json)
    let client = MimoQuotaClient(httpClient: http)

    let usage = try await client.fetchUsage(
      configuration: config(baseURL: "https://token-plan-cn.xiaomimimo.com/v1/"),
      now: now
    )

    XCTAssertEqual(usage.metrics.count, 1)
    let urls = await http.requestedURLs
    XCTAssertEqual(urls, ["https://token-plan-cn.xiaomimimo.com/v1/tokenPlan/usage"])
  }

  // A key authenticates only against its own cluster: a 401 on one region
  // must not fail the fetch while another region answers.
  func testFallsThroughClustersUntilOneAnswers() async throws {
    let json = #"{"data":{"monthUsage":{"items":[{"name":"month_total_token","used":10,"limit":100}]}}}"#
    let http = MockHTTP()
    http.respond(to: "https://token-plan-sgp.xiaomimimo.com/v1/tokenPlan/usage", status: 401, body: #"{"message":"unauthorized"}"#)
    http.respond(to: "https://token-plan-cn.xiaomimimo.com/v1/tokenPlan/usage", status: 200, body: json)
    let client = MimoQuotaClient(httpClient: http)

    let usage = try await client.fetchUsage(configuration: config(), now: now)

    XCTAssertEqual(usage.metrics.count, 1)
    let urls = await http.requestedURLs
    XCTAssertEqual(Array(urls.prefix(2)), [
      "https://token-plan-sgp.xiaomimimo.com/v1/tokenPlan/usage",
      "https://token-plan-cn.xiaomimimo.com/v1/tokenPlan/usage"
    ])
  }

  // When no usage endpoint yields items the balance endpoint supplies
  // token_balance/token_limit instead.
  func testFallsBackToTokenBalance() async throws {
    let http = MockHTTP()
    http.respond(to: "https://token-plan-sgp.xiaomimimo.com/v1/user/balance", status: 200, body: #"{"data":{"token_balance":800000,"token_limit":1000000,"plan_name":"Pro"}}"#)
    let client = MimoQuotaClient(httpClient: http)

    let usage = try await client.fetchUsage(configuration: config(), now: now)

    XCTAssertEqual(usage.subtitle, "Token Plan · Pro")
    let metric = try XCTUnwrap(usage.metrics.first { $0.id == "monthly-credits" })
    XCTAssertEqual(metric.label, "Monthly credits")
    XCTAssertEqual(metric.remainingPercent, 80)
    XCTAssertEqual(metric.usedDisplay, "200000")
    XCTAssertEqual(metric.totalDisplay, "1.0M")
    XCTAssertEqual(QuotaWindowKind.classify(metricID: metric.id, label: metric.label), .monthly)
  }

  // Numeric fields arrive as strings on some deployments.
  func testToleratesStringNumbers() async throws {
    let json = #"{"data":{"token_balance":"600000","token_limit":"1000000"}}"#
    let http = MockHTTP()
    http.respond(to: "https://token-plan-sgp.xiaomimimo.com/v1/user/balance", status: 200, body: json)
    let client = MimoQuotaClient(httpClient: http)

    let usage = try await client.fetchUsage(configuration: config(), now: now)
    XCTAssertEqual(usage.metrics.first?.remainingPercent, 60)
  }

  // A platform-style non-zero code on HTTP 200 is an error, not data.
  func testNonZeroCodeSkipsToNextCluster() async throws {
    let http = MockHTTP()
    http.respond(to: "https://token-plan-sgp.xiaomimimo.com/v1/tokenPlan/usage", status: 200, body: #"{"code":1001,"message":"bad key"}"#)
    http.respond(to: "https://token-plan-cn.xiaomimimo.com/v1/tokenPlan/usage", status: 200, body: #"{"data":{"monthUsage":{"items":[{"name":"month_total_token","used":5,"limit":10}]}}}"#)
    let client = MimoQuotaClient(httpClient: http)

    let usage = try await client.fetchUsage(configuration: config(), now: now)
    XCTAssertEqual(usage.metrics.count, 1)
  }

  func testAllAuthFailuresThrowAuth() async {
    let http = MockHTTP()
    http.defaultResponse = (401, #"{"message":"unauthorized"}"#)
    let client = MimoQuotaClient(httpClient: http)
    await assertThrows(kind: .auth) { try await client.fetchUsage(configuration: self.config(), now: self.now) }
  }

  func testAllEndpointsFailingThrowsAPIError() async {
    let http = MockHTTP()
    http.defaultResponse = (500, "boom")
    let client = MimoQuotaClient(httpClient: http)
    await assertThrows(kind: .api) { try await client.fetchUsage(configuration: self.config(), now: self.now) }
  }

  func testMissingKeyThrowsNotConfigured() async {
    let client = MimoQuotaClient(httpClient: MockHTTP())
    await assertThrows(kind: .notConfigured) { try await client.fetchUsage(configuration: self.config(key: nil), now: self.now) }
  }

  private func assertThrows(
    kind: QuotaErrorKind,
    _ block: @escaping () async throws -> ProviderUsage,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      _ = try await block()
      XCTFail("Expected error of kind \(kind)", file: file, line: line)
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, kind, file: file, line: line)
    } catch {
      XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
  }
}

/// Routes canned responses by absolute URL and records the request order —
/// the client probes several endpoints per refresh, so which URL got which
/// response is part of the contract.
private final class MockHTTP: HTTPClient, @unchecked Sendable {
  private var responses: [String: (status: Int, body: String)] = [:]
  var defaultResponse: (status: Int, body: String) = (404, #"{}"#)
  private let lock = NSLock()
  private var urls: [String] = []

  var requestedURLs: [String] {
    get async {
      lock.lock()
      defer { lock.unlock() }
      return urls
    }
  }

  func respond(to url: String, status: Int, body: String) {
    lock.lock()
    responses[url] = (status, body)
    lock.unlock()
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let url = request.url!.absoluteString
    lock.lock()
    urls.append(url)
    let (status, body) = responses[url] ?? defaultResponse
    lock.unlock()
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: status,
      httpVersion: "HTTP/1.1",
      headerFields: nil
    )!
    return (body.data(using: .utf8)!, response)
  }
}
