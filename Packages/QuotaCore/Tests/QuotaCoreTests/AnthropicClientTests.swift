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

  // Regression test: windows whose utilization cannot be parsed were skipped,
  // and an all-unparsable response produced "No usage data available" with
  // maxUsagePercent 0 — a confidently healthy account during schema drift.
  func testAllUnparsableWindowsFailAsDecoding() async {
    let json = #"""
    {
      "five_hour": {"foo": 1},
      "seven_day": {"bar": 2}
    }
    """#
    let client = AnthropicClient(httpClient: MockHTTP(status: 200, body: json))
    await assertThrows(kind: .decoding) { try await client.fetchUsage(configuration: self.config(), now: self.now) }
  }

  // Non-dictionary window values count as drift too: the keys exist but the
  // shape changed, which is the same "confidently healthy" hazard.
  func testNonDictionaryWindowsFailAsDecoding() async {
    let json = #"""
    {
      "five_hour": 42,
      "seven_day": "soon"
    }
    """#
    let client = AnthropicClient(httpClient: MockHTTP(status: 200, body: json))
    await assertThrows(kind: .decoding) { try await client.fetchUsage(configuration: self.config(), now: self.now) }
  }

  // A single unparsable window alongside parsable ones degrades gracefully:
  // keep the readable windows rather than failing the whole account.
  func testPartiallyUnparsableWindowsKeepReadableMetrics() async throws {
    let json = #"""
    {
      "five_hour": {"foo": 1},
      "seven_day": {"utilization": 50, "resets_at": "2026-06-20T00:00:00Z"}
    }
    """#
    let client = AnthropicClient(httpClient: MockHTTP(status: 200, body: json))

    let usage = try await client.fetchUsage(configuration: config(), now: now)

    XCTAssertEqual(usage.metrics.count, 1)
    XCTAssertEqual(usage.metrics.first?.id, "seven_day")
    XCTAssertEqual(usage.metrics.first?.remainingPercent, 50)
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
