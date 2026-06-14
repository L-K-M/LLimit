import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class AnthropicClientTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private func config(token: String? = "sk-claude") -> ProviderRuntimeConfiguration {
    ProviderRuntimeConfiguration(
      provider: .anthropic,
      isEnabled: true,
      credentials: token.map { [CredentialField.anthropicAccessToken: $0] } ?? [:]
    )
  }

  func testParsesUsageWindows() async throws {
    let json = #"""
    {
      "five_hour": {"utilization": 40, "resets_at": "2026-06-14T20:00:00Z"},
      "seven_day": {"utilization": 75, "resets_at": "2026-06-20T00:00:00Z"},
      "seven_day_opus": null,
      "extra_usage": {"is_enabled": false, "monthly_limit": null, "used_credits": null}
    }
    """#
    let client = AnthropicClient(httpClient: MockHTTP(status: 200, body: json))

    let usage = try await client.fetchUsage(configuration: config(), now: now)

    XCTAssertEqual(usage.provider, .anthropic)
    XCTAssertEqual(usage.metrics.count, 2)
    XCTAssertEqual(usage.metrics.first { $0.id == "five_hour" }?.remainingPercent, 60)
    XCTAssertEqual(usage.metrics.first { $0.id == "seven_day" }?.remainingPercent, 25)
    XCTAssertEqual(usage.maxUsagePercent, 75)
    XCTAssertNil(usage.warning)
    XCTAssertNotNil(usage.metrics.first { $0.id == "five_hour" }?.resetAt)
  }

  func testIncludesOpusWindowAndHighUsageWarning() async throws {
    let json = #"""
    {
      "five_hour": {"utilization": 10, "resets_at": "2026-06-14T20:00:00Z"},
      "seven_day": {"utilization": 50, "resets_at": "2026-06-20T00:00:00Z"},
      "seven_day_opus": {"utilization": 92, "resets_at": "2026-06-20T00:00:00Z"}
    }
    """#
    let client = AnthropicClient(httpClient: MockHTTP(status: 200, body: json))

    let usage = try await client.fetchUsage(configuration: config(), now: now)
    XCTAssertEqual(usage.metrics.count, 3)
    XCTAssertEqual(usage.metrics.first { $0.id == "seven_day_opus" }?.remainingPercent, 8)
    XCTAssertEqual(usage.maxUsagePercent, 92)
    XCTAssertEqual(usage.warning, "High usage")
  }

  func testMissingTokenThrowsNotConfigured() async {
    let client = AnthropicClient(httpClient: MockHTTP(status: 200, body: "{}"))
    await assertThrows(kind: .notConfigured) { try await client.fetchUsage(configuration: self.config(token: nil), now: self.now) }
  }

  func testUnauthorizedThrowsAuth() async {
    let client = AnthropicClient(httpClient: MockHTTP(status: 401, body: #"{"error":"unauthorized"}"#))
    await assertThrows(kind: .auth) { try await client.fetchUsage(configuration: self.config(), now: self.now) }
  }

  func testRateLimitThrowsRateLimit() async {
    let client = AnthropicClient(httpClient: MockHTTP(status: 429, body: "rate limited"))
    await assertThrows(kind: .rateLimit) { try await client.fetchUsage(configuration: self.config(), now: self.now) }
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
