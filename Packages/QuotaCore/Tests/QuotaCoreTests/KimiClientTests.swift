import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class KimiClientTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private func config(key: String? = "sk-kimi") -> ProviderRuntimeConfiguration {
    ProviderRuntimeConfiguration(
      provider: .kimi,
      isEnabled: true,
      credentials: key.map { [CredentialField.kimiAPIKey: $0] } ?? [:]
    )
  }

  // The documented /usages shape: protobuf-JSON int64s as strings, nanosecond
  // fractional seconds in resetTime, weekly summary + 5-hour rolling window.
  func testParsesWeeklySummaryAndFiveHourWindow() async throws {
    let json = #"""
    {
      "usage": {
        "limit": "2048",
        "used": "214",
        "remaining": "1834",
        "resetTime": "2026-01-09T15:23:13.716839300Z"
      },
      "limits": [
        {
          "window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
          "detail": {"limit": "200", "used": "139", "remaining": "61", "resetTime": "2026-01-06T13:33:02.717479433Z"}
        }
      ]
    }
    """#
    let client = KimiQuotaClient(httpClient: MockHTTP(status: 200, body: json))

    let usage = try await client.fetchUsage(configuration: config(), now: now)

    XCTAssertEqual(usage.provider, .kimi)
    XCTAssertEqual(usage.subtitle, "Kimi for Coding")
    XCTAssertEqual(usage.metrics.count, 2)

    let plan = usage.metrics.first { $0.id == "plan" }
    XCTAssertEqual(plan?.label, "Weekly limit")
    XCTAssertEqual(plan?.remainingPercent, 90)
    XCTAssertEqual(plan?.usedDisplay, "214")
    XCTAssertEqual(plan?.totalDisplay, "2048")
    XCTAssertNotNil(plan?.resetAt, "nanosecond-precision resetTime must parse")

    let window = usage.metrics.first { $0.id == "limit-0" }
    XCTAssertEqual(window?.label, "5-hour limit")
    XCTAssertEqual(window?.remainingPercent, 31)
    XCTAssertEqual(window?.usedDisplay, "139")
    XCTAssertEqual(window?.totalDisplay, "200")
    XCTAssertNotNil(window?.resetAt)

    XCTAssertEqual(usage.maxUsagePercent, 69)
    XCTAssertNil(usage.warning)
  }

  func testWindowLabelClassifiesAsSessionAndPlanAsWeekly() async throws {
    let json = #"""
    {
      "usage": {"limit": "1024", "used": "10"},
      "limits": [{"window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"}, "detail": {"limit": "200", "used": "1"}}]
    }
    """#
    let client = KimiQuotaClient(httpClient: MockHTTP(status: 200, body: json))
    let usage = try await client.fetchUsage(configuration: config(), now: now)

    let plan = try XCTUnwrap(usage.metrics.first { $0.id == "plan" })
    XCTAssertEqual(QuotaWindowKind.classify(metricID: plan.id, label: plan.label), .weekly)

    let window = try XCTUnwrap(usage.metrics.first { $0.id == "limit-0" })
    XCTAssertEqual(QuotaWindowKind.classify(metricID: window.id, label: window.label), .session)
  }

  func testComputesUsedFromRemainingWhenUsedMissing() async throws {
    let json = #"{"usage": {"limit": "2048", "remaining": "512"}}"#
    let client = KimiQuotaClient(httpClient: MockHTTP(status: 200, body: json))

    let usage = try await client.fetchUsage(configuration: config(), now: now)
    let plan = try XCTUnwrap(usage.metrics.first { $0.id == "plan" })
    XCTAssertEqual(plan.usedDisplay, "1536")
    XCTAssertEqual(plan.remainingPercent, 25)
    XCTAssertEqual(usage.maxUsagePercent, 75)
  }

  func testAcceptsNumericFieldsAndRelativeResetSeconds() async throws {
    let json = #"""
    {
      "limits": [{"detail": {"limit": 100, "used": 90, "resetIn": 1800}, "window": {"duration": 5, "timeUnit": "TIME_UNIT_HOUR"}}]
    }
    """#
    let client = KimiQuotaClient(httpClient: MockHTTP(status: 200, body: json))

    let usage = try await client.fetchUsage(configuration: config(), now: now)
    let window = try XCTUnwrap(usage.metrics.first { $0.id == "limit-0" })
    XCTAssertEqual(window.label, "5-hour limit")
    XCTAssertEqual(window.remainingPercent, 10)
    XCTAssertEqual(window.resetAt, now.addingTimeInterval(1800))
    XCTAssertEqual(usage.warning, "High usage")
  }

  func testHonorsExplicitNameOverDurationLabel() async throws {
    let json = #"""
    {
      "limits": [{"name": "Concurrent requests", "detail": {"limit": "30", "used": "3"}}]
    }
    """#
    let client = KimiQuotaClient(httpClient: MockHTTP(status: 200, body: json))

    let usage = try await client.fetchUsage(configuration: config(), now: now)
    XCTAssertEqual(usage.metrics.first?.label, "Concurrent requests")
  }

  func testFallsBackToDetailWhenNoDetailKey() async throws {
    let json = #"{"limits": [{"limit": "10", "used": "4", "duration": 1, "timeUnit": "TIME_UNIT_DAY"}]}"#
    let client = KimiQuotaClient(httpClient: MockHTTP(status: 200, body: json))

    let usage = try await client.fetchUsage(configuration: config(), now: now)
    let metric = try XCTUnwrap(usage.metrics.first { $0.id == "limit-0" })
    XCTAssertEqual(metric.label, "1-day limit")
    XCTAssertEqual(metric.remainingPercent, 60)
  }

  func testEmptyPayloadYieldsPlaceholderMetric() async throws {
    let client = KimiQuotaClient(httpClient: MockHTTP(status: 200, body: "{}"))

    let usage = try await client.fetchUsage(configuration: config(), now: now)
    XCTAssertEqual(usage.metrics.map(\.id), ["empty"])
    XCTAssertEqual(usage.maxUsagePercent, 0)
  }

  func testMissingKeyThrowsNotConfigured() async {
    let client = KimiQuotaClient(httpClient: MockHTTP(status: 200, body: "{}"))
    await assertThrows(kind: .notConfigured) { try await client.fetchUsage(configuration: self.config(key: nil), now: self.now) }
  }

  func testUnauthorizedThrowsAuth() async {
    let client = KimiQuotaClient(httpClient: MockHTTP(status: 401, body: #"{"code":"unauthenticated"}"#))
    await assertThrows(kind: .auth) { try await client.fetchUsage(configuration: self.config(), now: self.now) }
  }

  func testNotFoundThrowsAPIWithCodingPlanHint() async {
    let client = KimiQuotaClient(httpClient: MockHTTP(status: 404, body: ""))

    do {
      _ = try await client.fetchUsage(configuration: config(), now: now)
      XCTFail("Expected error")
    } catch let error as ProviderClientError {
      // Assert on the message so the "wrong platform key" hint isn't lost.
      XCTAssertEqual(error.kind, .api)
      XCTAssertTrue(error.message.contains("Kimi for Coding"))
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testRateLimitThrowsRateLimit() async {
    let client = KimiQuotaClient(httpClient: MockHTTP(status: 429, body: "slow down"))
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
