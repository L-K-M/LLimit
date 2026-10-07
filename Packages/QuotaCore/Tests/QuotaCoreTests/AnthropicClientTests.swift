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

  func testUserAgentUsesInstalledVersionOrNoCLIFallback() async throws {
    for version: String? in ["2.1.0-rc.1", nil] {
      let http = RecordingAnthropicHTTP()
      let client = AnthropicClient(httpClient: http, claudeVersion: { version })
      _ = try await client.fetchUsage(configuration: config(), now: now)
      let request = await http.request

      XCTAssertEqual(request?.value(forHTTPHeaderField: "User-Agent"), "claude-code/\(version ?? "1.0.110")")
      XCTAssertEqual(request?.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
    }
  }

  func testRateLimitUsesBoundedSafeWaitGuidance() async {
    for (header, delay) in [("120", 120.0), ("Tue, 14 Nov 2023 22:18:20 GMT", 300.0),
                            ("99999999999999999999", 86_400.0)] {
      let client = AnthropicClient(httpClient: MockHTTP(status: 429, body: "secret response", headers: ["Retry-After": header]))
      do {
        _ = try await client.fetchUsage(configuration: config(), now: now)
        XCTFail("Expected rate limit")
      } catch let error as ProviderClientError {
        XCTAssertEqual(error.kind, .rateLimit)
        XCTAssertEqual(error.retryAfter, delay)
        XCTAssertTrue(error.message.contains("Next attempt"))
        XCTAssertFalse(error.message.contains("secret response"))
      } catch { XCTFail("Unexpected error: \(error)") }
    }
  }

  func testAllReportedMalformedWindowsFailWithoutExposingBodies() async {
    for json in [#"{"five_hour":{"foo":1},"seven_day":{"bar":2}}"#,
                 #"{"five_hour":42,"seven_day":"secret response"}"#,
                 #"{"seven_day_sonnet":{"utilization":"n/a"}}"#,
                 #"{"five_hour":{"utilization":"n/a"},"extra_usage":{"is_enabled":true,"used_credits":1234}}"#] {
      await assertThrows(kind: .decoding) { try await self.fetch(json) }
    }
  }

  func testFullModelWindowsAreStableAndPartialDriftKeepsReadableQuota() async throws {
    let json = #"{"five_hour":{"utilization":5},"seven_day":{"utilization":20},"seven_day_opus":null,"seven_day_sonnet":{"utilization":94,"resets_at":"2026-06-20T00:00:00Z"},"seven_day_haiku":{"utilization":40},"five_hour_sonnet":{"utilization":85},"seven_day_oauth_apps":{"utilization":12},"seven_day_sonnet_max":{"utilization":30},"seven_day_cowork":{"utilization":null},"seven_day_notes":"not a window"}"#
    let usage = try await fetch(json)
    XCTAssertEqual(usage.metrics.map(\.id), ["five_hour", "seven_day", "seven_day_sonnet", "five_hour_sonnet", "seven_day_haiku", "seven_day_oauth_apps", "seven_day_sonnet_max"])
    XCTAssertEqual(usage.metrics.map { QuotaWindowKind.classify(metricID: $0.id, label: $0.label) }, [.session, .weekly, .weekly, .session, .weekly, .weekly, .weekly])
    XCTAssertEqual(usage.metrics.first { $0.id == "seven_day_sonnet" }?.remainingPercent, 6)
    XCTAssertNotNil(usage.metrics.first { $0.id == "seven_day_sonnet" }?.resetAt)
    XCTAssertEqual(usage.metrics.first { $0.id == "seven_day_oauth_apps" }?.label, "Weekly (OAuth apps)")
    XCTAssertEqual(usage.metrics.first { $0.id == "seven_day_sonnet_max" }?.label, "Weekly (Sonnet Max)")
    XCTAssertEqual(usage.maxUsagePercent, 94)
    XCTAssertEqual(usage.warning, "High usage")
    XCTAssertEqual(defaultRingMetrics(for: usage).map(\.id), ["five_hour", "seven_day"])

    let partial = try await fetch(#"{"five_hour":{"foo":1},"seven_day":{"utilization":50}}"#)
    XCTAssertEqual(partial.metrics.map(\.id), ["seven_day"])
    XCTAssertEqual(partial.metrics.first?.remainingPercent, 50)
  }

  func testNullWindowsAndAmountOnlyUsageHaveNoAggregateQuota() async throws {
    let absent = try await fetch(#"{"five_hour":null,"seven_day":{"utilization":null,"resets_at":null}}"#)
    XCTAssertEqual(absent.metrics.map(\.id), ["empty"])
    XCTAssertNil(absent.maxUsagePercent)
    XCTAssertNil(absent.warning)

    let extra = try await fetch(#"{"five_hour":null,"extra_usage":{"is_enabled":true,"used_credits":1234,"monthly_limit":100000}}"#)
    XCTAssertEqual(extra.metrics.map(\.id), ["extra_usage"])
    XCTAssertEqual(extra.metrics.first?.usageLine, "$12.34 / $1000.00")
    XCTAssertNil(extra.metrics.first?.remainingPercent)
    XCTAssertNil(extra.metrics.first?.resetAt)
    XCTAssertNil(extra.maxUsagePercent)
    XCTAssertNil(extra.subtitle)
    XCTAssertTrue(defaultRingMetrics(for: extra).isEmpty)
    XCTAssertNil(primaryLimitSlot(for: extra.metrics))
  }

  func testExtraUsagePreservesQuotaSelectionAndCurrencyRules() async throws {
    let windows = #""five_hour":{"utilization":40},"seven_day":{"utilization":75}"#
    let baseline = try await fetch("{\(windows)}")
    for (fields, display, detail) in [
      (#""is_enabled":true,"used_credits":27140,"monthly_limit":50000,"currency":"USD""#, "$271.40 / $500.00", nil),
      (#""is_enabled":true,"used_credits":5,"monthly_limit":null,"currency":"usd""#, "$0.05", nil),
      (#""is_enabled":false,"used_credits":5012,"monthly_limit":5000"#, "$50.12 / $50.00", "Monthly spending cap reached."),
      (#""used_credits":5000,"monthly_limit":5000"#, "$50.00 / $50.00", "Monthly spending cap reached."),
      (#""is_enabled":true,"used_credits":1234,"currency":"EUR""#, "On", nil),
      (#""is_enabled":false,"used_credits":5000,"monthly_limit":5000,"currency":"JPY""#, "Cap reached", "Monthly spending cap reached.")
    ] as [(String, String, String?)] {
      let usage = try await fetch("{\(windows),\"extra_usage\":{\(fields)}}")
      let extra = try XCTUnwrap(usage.metrics.last)
      XCTAssertEqual(extra.id, "extra_usage")
      XCTAssertEqual(extra.usageLine, display)
      XCTAssertEqual(extra.detail, detail)
      XCTAssertNil(extra.remainingPercent)
      XCTAssertEqual(QuotaWindowKind.classify(metricID: extra.id, label: extra.label), .other)
      XCTAssertEqual(defaultRingMetrics(for: usage), defaultRingMetrics(for: baseline))
      XCTAssertEqual(primaryLimitSlot(for: usage.metrics), primaryLimitSlot(for: baseline.metrics))
      XCTAssertEqual(Array(limitSeriesSlots(for: usage.metrics).dropLast()), limitSeriesSlots(for: baseline.metrics))
      XCTAssertEqual(usage.maxUsagePercent, baseline.maxUsagePercent)
    }
    for fields in [#""is_enabled":false,"used_credits":1234,"monthly_limit":100000"#,
                   #""is_enabled":true,"used_credits":0"#, #""used_credits":1234,"monthly_limit":100000"#] {
      let usage = try await fetch("{\"extra_usage\":{\(fields)}}")
      XCTAssertEqual(usage.metrics.map(\.id), ["empty"])
    }
  }

  private func fetch(_ json: String) async throws -> ProviderUsage {
    try await AnthropicClient(httpClient: MockHTTP(status: 200, body: json)).fetchUsage(configuration: config(), now: now)
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

private actor RecordingAnthropicHTTP: HTTPClient {
  private(set) var request: URLRequest?

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    self.request = request
    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    return (Data("{}".utf8), response)
  }
}

private struct MockHTTP: HTTPClient {
  let status: Int
  let body: String
  var headers: [String: String] = [:]

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: status,
      httpVersion: "HTTP/1.1",
      headerFields: headers
    )!
    return (body.data(using: .utf8)!, response)
  }
}
