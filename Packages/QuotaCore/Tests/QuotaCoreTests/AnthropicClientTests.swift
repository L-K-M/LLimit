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

  func testSonnetWeeklyWindowFeedsUsageAndWarning() async throws {
    let json = #"""
    {
      "five_hour": {"utilization": 10, "resets_at": "2026-06-14T20:00:00Z"},
      "seven_day": {"utilization": 60, "resets_at": "2026-06-20T00:00:00Z"},
      "seven_day_opus": null,
      "seven_day_sonnet": {"utilization": 94, "resets_at": "2026-06-20T00:00:00Z"}
    }
    """#

    let usage = try await fetch(json)

    XCTAssertEqual(usage.metrics.map(\.id), ["five_hour", "seven_day", "seven_day_sonnet"])
    let sonnet = try XCTUnwrap(usage.metrics.first { $0.id == "seven_day_sonnet" })
    XCTAssertEqual(sonnet.label, "Weekly (Sonnet)")
    XCTAssertEqual(sonnet.remainingPercent, 6)
    XCTAssertNotNil(sonnet.resetAt)
    XCTAssertEqual(QuotaWindowKind.classify(metricID: sonnet.id, label: sonnet.label), .weekly)
    XCTAssertEqual(usage.maxUsagePercent, 94)
    XCTAssertEqual(usage.warning, "High usage")
    // The tile rings keep the 5-hour + weekly pair.
    XCTAssertEqual(defaultRingMetrics(for: usage).map(\.id), ["five_hour", "seven_day"])
  }

  func testUnknownModelWindowsKeepTheirCadenceAndNullWindowsAreSkipped() async throws {
    let json = #"""
    {
      "five_hour": {"utilization": 5, "resets_at": "2026-06-14T20:00:00Z"},
      "seven_day": {"utilization": 20, "resets_at": "2026-06-20T00:00:00Z"},
      "seven_day_sonnet_max": {"utilization": 30, "resets_at": "2026-06-20T00:00:00Z"},
      "seven_day_haiku": {"utilization": 40, "resets_at": "2026-06-20T00:00:00Z"},
      "five_hour_sonnet": {"utilization": 85, "resets_at": "2026-06-14T20:00:00Z"},
      "seven_day_oauth_apps": null,
      "seven_day_cowork": {"utilization": null, "resets_at": null},
      "seven_day_notes": "not a window"
    }
    """#

    let usage = try await fetch(json)

    XCTAssertEqual(
      usage.metrics.map(\.id),
      ["five_hour", "seven_day", "five_hour_sonnet", "seven_day_haiku", "seven_day_sonnet_max"]
    )
    let labels = Dictionary(uniqueKeysWithValues: usage.metrics.map { ($0.id, $0.label) })
    XCTAssertEqual(labels["five_hour_sonnet"], "5-hour (Sonnet)")
    XCTAssertEqual(labels["seven_day_haiku"], "Weekly (Haiku)")
    XCTAssertEqual(labels["seven_day_sonnet_max"], "Weekly (Sonnet Max)")

    let kinds = usage.metrics.map { QuotaWindowKind.classify(metricID: $0.id, label: $0.label) }
    XCTAssertEqual(kinds, [.session, .weekly, .session, .weekly, .weekly])
    XCTAssertEqual(usage.metrics.first { $0.id == "seven_day_haiku" }?.remainingPercent, 60)
    XCTAssertEqual(usage.maxUsagePercent, 85)
    XCTAssertEqual(usage.warning, "High usage")
    XCTAssertEqual(defaultRingMetrics(for: usage).map(\.id), ["five_hour", "seven_day"])
  }

  func testOAuthAppsWindowGetsANonModelLabel() async throws {
    let json = #"""
    {
      "seven_day": {"utilization": 20, "resets_at": "2026-06-20T00:00:00Z"},
      "seven_day_oauth_apps": {"utilization": 12, "resets_at": "2026-06-20T00:00:00Z"}
    }
    """#

    let usage = try await fetch(json)

    let apps = try XCTUnwrap(usage.metrics.first { $0.id == "seven_day_oauth_apps" })
    XCTAssertEqual(apps.label, "Weekly (OAuth apps)")
    XCTAssertEqual(QuotaWindowKind.classify(metricID: apps.id, label: apps.label), .weekly)
  }

  func testExtraUsageIsCentsAndStaysOutOfQuotaSelection() async throws {
    let windows = #"""
      "five_hour": {"utilization": 40, "resets_at": "2026-06-14T20:00:00Z"},
      "seven_day": {"utilization": 75, "resets_at": "2026-06-20T00:00:00Z"}
    """#
    let withExtra = try await fetch(#"""
    {
    \#(windows),
      "extra_usage": {"is_enabled": true, "monthly_limit": 100000, "used_credits": 1234, "utilization": 1.234}
    }
    """#)
    let withoutExtra = try await fetch("{\(windows)}")

    let extra = try XCTUnwrap(withExtra.metrics.first { $0.id == "extra_usage" })
    XCTAssertEqual(extra.label, "Extra usage")
    XCTAssertEqual(extra.usageLine, "$12.34 / $1000.00")
    XCTAssertNil(extra.remainingPercent)
    XCTAssertNil(extra.resetAt)
    XCTAssertFalse(extra.isUnlimited)
    // The amount replaces the old subtitle, which repeated it in the card header.
    XCTAssertNil(withExtra.subtitle)

    // Appended last and unclassified, so it never moves a window's color slot,
    // the rings, the primary color, the headline percentage, or the warning.
    XCTAssertEqual(withExtra.metrics.last?.id, "extra_usage")
    XCTAssertEqual(QuotaWindowKind.classify(metricID: extra.id, label: extra.label), .other)
    XCTAssertEqual(Array(limitSeriesSlots(for: withExtra.metrics).dropLast()), limitSeriesSlots(for: withoutExtra.metrics))
    XCTAssertEqual(primaryLimitSlot(for: withExtra.metrics), primaryLimitSlot(for: withoutExtra.metrics))
    XCTAssertEqual(defaultRingMetrics(for: withExtra), defaultRingMetrics(for: withoutExtra))
    XCTAssertEqual(withExtra.maxUsagePercent, withoutExtra.maxUsagePercent)
    XCTAssertEqual(withExtra.warning, withoutExtra.warning)
  }

  func testExtraUsageFormatsGatewayExampleAndSpendWithoutCap() async throws {
    let capped = try await extraUsage(#"{"is_enabled": true, "monthly_limit": 50000, "used_credits": 27140, "currency": "USD"}"#)
    XCTAssertEqual(capped?.usageLine, "$271.40 / $500.00")
    XCTAssertNil(capped?.detail)

    let lowercaseCurrency = try await extraUsage(#"{"is_enabled": true, "monthly_limit": 50000, "used_credits": 5, "currency": "usd"}"#)
    XCTAssertEqual(lowercaseCurrency?.usageLine, "$0.05 / $500.00")

    let uncapped = try await extraUsage(#"{"is_enabled": true, "monthly_limit": null, "used_credits": 1234}"#)
    XCTAssertEqual(uncapped?.usageLine, "$12.34")
  }

  func testExtraUsageIsHiddenWhenOffOrUnspent() async throws {
    let disabled = try await extraUsage(#"{"is_enabled": false, "monthly_limit": 100000, "used_credits": 1234}"#)
    XCTAssertNil(disabled)

    let unspent = try await extraUsage(#"{"is_enabled": true, "monthly_limit": 100000, "used_credits": 0.0}"#)
    XCTAssertNil(unspent)
  }

  func testExtraUsageReportsReachedCapEvenAfterClaudeDisablesIt() async throws {
    // Claude reportedly switches extra usage off once the monthly cap is
    // spent, which is exactly when the cap matters most.
    let disabledAtCap = try await extraUsage(#"{"is_enabled": false, "monthly_limit": 5000, "used_credits": 5000}"#)
    XCTAssertEqual(disabledAtCap?.usageLine, "$50.00 / $50.00")
    XCTAssertEqual(disabledAtCap?.detail, "Monthly spending cap reached.")

    let enabledAtCap = try await extraUsage(#"{"is_enabled": true, "monthly_limit": 5000, "used_credits": 5012}"#)
    XCTAssertEqual(enabledAtCap?.usageLine, "$50.12 / $50.00")
    XCTAssertEqual(enabledAtCap?.detail, "Monthly spending cap reached.")
  }

  func testExtraUsageInOtherCurrencyFallsBackToText() async throws {
    let enabled = try await extraUsage(#"{"is_enabled": true, "monthly_limit": 100000, "used_credits": 1234, "currency": "EUR"}"#)
    XCTAssertEqual(enabled?.usageLine, "On")
    XCTAssertNil(enabled?.remainingPercent)

    let atCap = try await extraUsage(#"{"is_enabled": false, "monthly_limit": 5000, "used_credits": 5000, "currency": "JPY"}"#)
    XCTAssertEqual(atCap?.usageLine, "Cap reached")
    XCTAssertEqual(atCap?.detail, "Monthly spending cap reached.")
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

  private func fetch(_ json: String) async throws -> ProviderUsage {
    let client = AnthropicClient(httpClient: MockHTTP(status: 200, body: json))
    return try await client.fetchUsage(configuration: config(), now: now)
  }

  private func extraUsage(_ extraUsageJSON: String) async throws -> UsageMetric? {
    let usage = try await fetch(#"""
    {
      "seven_day": {"utilization": 50, "resets_at": "2026-06-20T00:00:00Z"},
      "extra_usage": \#(extraUsageJSON)
    }
    """#)
    return usage.metrics.first { $0.id == "extra_usage" }
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
