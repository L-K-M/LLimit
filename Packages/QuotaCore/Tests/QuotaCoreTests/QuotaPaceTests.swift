import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class QuotaPaceTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)
  private let fiveHours = 5 * 3_600
  private let week = 7 * 86_400

  func testPaceComparesConsumptionAtTheReading() throws {
    let start = try XCTUnwrap(pace(metric(remaining: 90, resetIn: TimeInterval(fiveHours))))
    XCTAssertEqual(start.elapsedFraction, 0)
    XCTAssertEqual(start.evenPaceRemainingFraction, 1)
    XCTAssertEqual(start.phrase, "10% over pace")

    for (remaining, phrase) in [(50, "on pace"), (38, "12% over pace"), (58, "8% under pace"),
                               (48, "on pace"), (47, "3% over pace"), (53, "3% under pace")] {
      let reading = try XCTUnwrap(pace(metric(remaining: remaining, resetIn: TimeInterval(week / 2), windowSeconds: week)))
      XCTAssertEqual(reading.elapsedFraction, 0.5)
      XCTAssertEqual(reading.evenPaceRemainingFraction, 0.5)
      XCTAssertEqual(reading.phrase, phrase)
    }
    XCTAssertEqual(pace(metric(remaining: 40, resetIn: 5 * 86_400, windowSeconds: week))?.phrase, "31% over pace")
    XCTAssertEqual(pace(metric(remaining: 40, resetIn: 86_400, windowSeconds: week))?.phrase, "26% under pace")
  }

  func testPaceDoesNotDriftWithDisplayTimeAndExpiresAtReset() {
    let reading = metric(resetIn: 600)
    XCTAssertEqual(QuotaPace(metric: reading, provider: .openAI, fetchedAt: now, now: now.addingTimeInterval(300)), pace(reading))
    XCTAssertNil(QuotaPace(metric: reading, provider: .openAI, fetchedAt: now, now: now.addingTimeInterval(600)))
  }

  func testMissingOrContradictoryDataHasNoPace() {
    for reading in [metric(remaining: nil), metric(resetIn: nil), metric(windowSeconds: nil),
                    metric(windowSeconds: 0), metric(windowSeconds: -60), metric(isUnlimited: true),
                    metric(resetIn: 0), metric(resetIn: -60), metric(resetIn: TimeInterval(fiveHours) * 1.06)] {
      XCTAssertNil(pace(reading))
    }
    XCTAssertEqual(pace(metric(remaining: 100, resetIn: TimeInterval(fiveHours) + 120))?.elapsedFraction, 0)
  }

  func testSharesClampToTheDrawnGeometry() {
    XCTAssertEqual(pace(metric(remaining: -20, resetIn: TimeInterval(fiveHours / 2)))?.delta, 50)
    XCTAssertEqual(pace(metric(remaining: 130, resetIn: TimeInterval(fiveHours / 2)))?.delta, -50)
  }

  func testOnlyReportedDurationsAndDocumentedIDsSupplyLengths() {
    let anthropic = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "five_hour_opus", "extra_usage", "sevenday"]
    XCTAssertEqual(anthropic.map { length(id: $0, provider: .anthropic) }, [18_000, 604_800, 604_800, 604_800, 18_000, nil, nil])
    XCTAssertEqual(["five_hour", "weekly", "monthly", "credit-balance"].map { length(id: $0, provider: .cline) }, [18_000, 604_800, nil, nil])
    for (provider, id) in [(QuotaProvider.metaMuse, "weekly"), (.openCodeGo, "session-rolling"), (.openCodeGo, "weekly"),
                           (.openCodeGo, "monthly"), (.gitHubCopilot, "premium"), (.devin, "five_hour")] {
      XCTAssertNil(length(id: id, provider: provider))
    }
    XCTAssertEqual(QuotaPace.windowSeconds(for: metric(id: "five_hour", windowSeconds: 3_600), provider: .anthropic), 3_600)
    XCTAssertNil(QuotaPace.windowSeconds(for: metric(id: "five_hour", windowSeconds: 0), provider: .anthropic))
  }

  func testReportedDurationsRejectNonPositiveAndOverflowingCounts() {
    XCTAssertEqual(reportedWindowSeconds(count: 300, unitSeconds: 60), 18_000)
    XCTAssertNil(reportedWindowSeconds(count: 0, unitSeconds: 60))
    XCTAssertNil(reportedWindowSeconds(count: -5, unitSeconds: 60))
    XCTAssertNil(reportedWindowSeconds(count: Int.max, unitSeconds: 60))
    XCTAssertNil(reportedWindowSeconds(count: 5, unitSeconds: 0))
  }

  func testSnapshotCompatibilityAndDurationRoundTrip() throws {
    let legacy = #"{"id":"primary","label":"5-hour limit","remainingPercent":40,"isUnlimited":false}"#
    XCTAssertNil(try JSONDecoder().decode(UsageMetric.self, from: Data(legacy.utf8)).windowSeconds)
    let original = metric(windowSeconds: fiveHours)
    XCTAssertEqual(try JSONDecoder().decode(UsageMetric.self, from: JSONEncoder().encode(original)), original)
  }

  func testClientDurationsStayReportedAndUncertainWindowsStayUnknown() async throws {
    let kimiBody = #"{"usage":{"limit":"2048","used":"214"},"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"200","used":"139"}},{"window":{"duration":1,"timeUnit":"TIME_UNIT_MONTH"},"detail":{"limit":"100","used":"5"}},{"window":{"duration":9e18,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"1","used":"0"}}]}"#
    let kimi = try await KimiQuotaClient(httpClient: PaceFixtureHTTP(body: kimiBody)).fetchUsage(configuration: ProviderRuntimeConfiguration(
      provider: .kimi, isEnabled: true, credentials: [CredentialField.kimiAPIKey: "fixture-key"]
    ), now: now)
    XCTAssertEqual(kimi.metrics.map(\.windowSeconds), [nil, 18_000, nil, nil])

    let museBody = "event: response.subscription_usage\ndata: " + #"{"type":"response.subscription_usage","window":{"used_percent":40,"window_duration_mins":300},"weekly":{"used_percent":60}}"# + "\n\n"
    let muse = try await MetaMuseQuotaClient(httpClient: PaceFixtureHTTP(body: museBody)).fetchUsage(configuration: ProviderRuntimeConfiguration(
      provider: .metaMuse, isEnabled: true, credentials: [CredentialField.metaMuseAPIKey: "fixture-key"]
    ), now: now)
    XCTAssertEqual(muse.metrics.map(\.windowSeconds), [18_000, nil])
  }

  private func metric(id: String = "primary", remaining: Int? = 50, resetIn: TimeInterval? = 3_600,
                      windowSeconds: Int? = 5 * 3_600, isUnlimited: Bool = false) -> UsageMetric {
    UsageMetric(id: id, label: "Limit", remainingPercent: remaining, resetAt: resetIn.map { now.addingTimeInterval($0) },
                windowSeconds: windowSeconds, isUnlimited: isUnlimited)
  }

  private func pace(_ metric: UsageMetric) -> QuotaPace? {
    QuotaPace(metric: metric, provider: .openAI, fetchedAt: now, now: now)
  }

  private func length(id: String, provider: QuotaProvider) -> TimeInterval? {
    QuotaPace.windowSeconds(for: metric(id: id, windowSeconds: nil), provider: provider)
  }
}

private struct PaceFixtureHTTP: HTTPClient {
  let body: String

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
