import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class QuotaPaceTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)
  private let fiveHours = 5 * 3_600
  private let week = 7 * 86_400

  private func metric(
    id: String = "primary",
    remaining: Int? = 50,
    resetIn seconds: TimeInterval? = 3_600,
    windowSeconds: Int? = 5 * 3_600,
    isUnlimited: Bool = false
  ) -> UsageMetric {
    UsageMetric(
      id: id, label: "Limit", remainingPercent: remaining,
      resetAt: seconds.map { now.addingTimeInterval($0) },
      windowSeconds: windowSeconds, isUnlimited: isUnlimited
    )
  }

  private func pace(_ metric: UsageMetric, provider: QuotaProvider = .openAI) -> QuotaPace? {
    QuotaPace(metric: metric, provider: provider, fetchedAt: now, now: now)
  }

  // MARK: - Position in the window

  func testWindowStartPutsEvenPaceAtFullQuota() throws {
    let start = try XCTUnwrap(pace(metric(remaining: 90, resetIn: TimeInterval(fiveHours))))

    XCTAssertEqual(start.elapsedFraction, 0)
    XCTAssertEqual(start.evenPaceRemainingFraction, 1)
    XCTAssertEqual(start.delta, 10)
    XCTAssertEqual(start.phrase, "10% ahead of pace")
  }

  func testMiddleOfWeeklyWindowComparesUsedWithElapsed() throws {
    let halfway = TimeInterval(week / 2)
    let even = try XCTUnwrap(pace(metric(remaining: 50, resetIn: halfway, windowSeconds: week)))
    let ahead = try XCTUnwrap(pace(metric(remaining: 38, resetIn: halfway, windowSeconds: week)))
    let behind = try XCTUnwrap(pace(metric(remaining: 58, resetIn: halfway, windowSeconds: week)))

    XCTAssertEqual(even.elapsedFraction, 0.5, accuracy: 1e-9)
    XCTAssertEqual(even.evenPaceRemainingFraction, 0.5, accuracy: 1e-9)
    XCTAssertEqual(even.delta, 0, accuracy: 1e-9)
    XCTAssertEqual(even.phrase, "on pace")
    XCTAssertEqual(ahead.phrase, "12% ahead of pace")
    XCTAssertEqual(behind.phrase, "8% behind pace")
  }

  // "40% left" on day 2 and day 6 of a weekly window are opposite stories.
  func testSameRemainingShareReadsDifferentlyAcrossTheWeek() throws {
    let dayTwo = try XCTUnwrap(pace(metric(remaining: 40, resetIn: 5 * 86_400, windowSeconds: week)))
    let daySix = try XCTUnwrap(pace(metric(remaining: 40, resetIn: 1 * 86_400, windowSeconds: week)))

    XCTAssertGreaterThan(dayTwo.delta, 0)
    XCTAssertLessThan(daySix.delta, 0)
    XCTAssertEqual(dayTwo.phrase, "31% ahead of pace")
    XCTAssertEqual(daySix.phrase, "26% behind pace")
  }

  func testWindowEndExpectsTheQuotaSpent() throws {
    let end = try XCTUnwrap(pace(metric(remaining: 0, resetIn: 60)))

    XCTAssertEqual(end.elapsedFraction, 1 - 60.0 / Double(fiveHours), accuracy: 1e-9)
    XCTAssertLessThan(end.evenPaceRemainingFraction, 0.01)
    XCTAssertEqual(end.phrase, "on pace")
  }

  func testDeadBandKeepsSmallDeviationsOnPace() throws {
    let halfway = TimeInterval(fiveHours / 2)

    XCTAssertEqual(pace(metric(remaining: 48, resetIn: halfway))?.phrase, "on pace")
    XCTAssertEqual(pace(metric(remaining: 52, resetIn: halfway))?.phrase, "on pace")
    XCTAssertEqual(pace(metric(remaining: 47, resetIn: halfway))?.phrase, "3% ahead of pace")
    XCTAssertEqual(pace(metric(remaining: 53, resetIn: halfway))?.phrase, "3% behind pace")
  }

  // MARK: - Missing and out-of-range data

  func testMissingDataHasNoPace() {
    XCTAssertNil(pace(metric(remaining: nil)), "No share to compare")
    XCTAssertNil(pace(metric(resetIn: nil)), "No reset to pace to")
    XCTAssertNil(pace(metric(windowSeconds: nil)), "No reported or documented length")
    XCTAssertNil(pace(metric(isUnlimited: true)), "Unlimited windows cannot run out")
    XCTAssertNil(pace(metric(windowSeconds: 0)))
    XCTAssertNil(pace(metric(windowSeconds: -60)))
  }

  func testResetAtOrBeforeTheReadingHasNoPace() {
    XCTAssertNil(pace(metric(resetIn: 0)))
    XCTAssertNil(pace(metric(resetIn: -60)))
  }

  // The reading stays valid until its window resets; afterwards its used
  // share describes a window that already ended.
  func testWindowThatResetSinceTheReadingHasNoPace() throws {
    let reading = metric(remaining: 50, resetIn: 600)

    let beforeReset = try XCTUnwrap(QuotaPace(metric: reading, provider: .openAI, fetchedAt: now, now: now.addingTimeInterval(300)))
    XCTAssertNil(QuotaPace(metric: reading, provider: .openAI, fetchedAt: now, now: now.addingTimeInterval(600)))
    XCTAssertNil(QuotaPace(metric: reading, provider: .openAI, fetchedAt: now, now: now.addingTimeInterval(900)))

    // Elapsed time is measured at the reading, not at display time.
    XCTAssertEqual(beforeReset, pace(reading))
  }

  func testResetFurtherThanTheWindowContradictsItsLength() {
    XCTAssertNil(pace(metric(resetIn: TimeInterval(fiveHours) * 1.5)))
    XCTAssertNil(pace(metric(resetIn: TimeInterval(fiveHours) * 1.06)))
  }

  // MARK: - Clamping

  func testSlightOvershootFromSkewClampsToWindowStart() throws {
    let skewed = try XCTUnwrap(pace(metric(remaining: 100, resetIn: TimeInterval(fiveHours) + 120)))

    XCTAssertEqual(skewed.elapsedFraction, 0)
    XCTAssertEqual(skewed.delta, 0)
  }

  func testOutOfRangeSharesClampToTheDrawnGeometry() throws {
    let halfway = TimeInterval(fiveHours / 2)
    let overdrawn = try XCTUnwrap(pace(metric(remaining: -20, resetIn: halfway)))
    let topUp = try XCTUnwrap(pace(metric(remaining: 130, resetIn: halfway)))

    XCTAssertEqual(overdrawn.delta, 50, accuracy: 1e-9)
    XCTAssertEqual(topUp.delta, -50, accuracy: 1e-9)
  }

  // MARK: - Window lengths

  func testReportedLengthWinsOverADocumentedID() throws {
    let reported = metric(id: "five_hour", windowSeconds: 3_600)

    XCTAssertEqual(QuotaPace.windowSeconds(for: reported, provider: .anthropic), 3_600)
  }

  func testInvalidReportedLengthDoesNotFallBackToTheID() {
    XCTAssertNil(QuotaPace.windowSeconds(for: metric(id: "five_hour", windowSeconds: 0), provider: .anthropic))
  }

  func testDocumentedAnthropicIDsFixTheirLength() {
    let lengths = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "five_hour_opus", "extra_usage", "sevenday"]
      .map { QuotaPace.windowSeconds(for: metric(id: $0, windowSeconds: nil), provider: .anthropic) }

    XCTAssertEqual(lengths, [18_000, 604_800, 604_800, 604_800, 18_000, nil, nil])
  }

  func testDocumentedClineIDsFixTheirLengthExceptMonthly() {
    let lengths = ["five_hour", "weekly", "monthly", "credit-balance"]
      .map { QuotaPace.windowSeconds(for: metric(id: $0, windowSeconds: nil), provider: .cline) }

    XCTAssertEqual(lengths, [18_000, 604_800, nil, nil])
  }

  // Ids are only documented per provider; the same spelling elsewhere, or a
  // rolling window, states no length.
  func testIDsWithoutADocumentedLengthHaveNone() {
    let undocumented: [(QuotaProvider, String)] = [
      (.metaMuse, "weekly"),
      (.openCodeGo, "session-rolling"),
      (.openCodeGo, "weekly"),
      (.openCodeGo, "monthly"),
      (.gitHubCopilot, "premium"),
      (.devin, "five_hour")
    ]

    for (provider, id) in undocumented {
      XCTAssertNil(QuotaPace.windowSeconds(for: metric(id: id, windowSeconds: nil), provider: provider), "\(provider) \(id)")
    }
  }

  func testReportedWindowSecondsRejectsNonPositiveAndOverflowingCounts() {
    XCTAssertEqual(reportedWindowSeconds(count: 300, unitSeconds: 60), 18_000)
    XCTAssertNil(reportedWindowSeconds(count: 0, unitSeconds: 60))
    XCTAssertNil(reportedWindowSeconds(count: -5, unitSeconds: 60))
    XCTAssertNil(reportedWindowSeconds(count: Int.max, unitSeconds: 60))
  }

  // MARK: - Snapshot compatibility

  func testSnapshotsWrittenBeforeWindowSecondsStillDecode() throws {
    let json = #"{"id":"primary","label":"5-hour limit","remainingPercent":40,"isUnlimited":false}"#

    let decoded = try JSONDecoder().decode(UsageMetric.self, from: Data(json.utf8))

    XCTAssertNil(decoded.windowSeconds)
    XCTAssertEqual(decoded.remainingPercent, 40)
  }

  func testWindowSecondsRoundTrips() throws {
    let original = metric(windowSeconds: 18_000)

    let decoded = try JSONDecoder().decode(UsageMetric.self, from: JSONEncoder().encode(original))

    XCTAssertEqual(decoded, original)
    XCTAssertEqual(decoded.windowSeconds, 18_000)
  }

  // MARK: - Client population

  // Anthropic reports no lengths; its documented keys must keep matching the
  // ids the client emits.
  func testAnthropicWindowsGetLengthsFromTheirKeys() async throws {
    let json = #"""
    {
      "five_hour": {"utilization": 40, "resets_at": "2026-06-14T20:00:00Z"},
      "seven_day": {"utilization": 75, "resets_at": "2026-06-20T00:00:00Z"},
      "seven_day_opus": {"utilization": 92, "resets_at": "2026-06-20T00:00:00Z"}
    }
    """#
    let client = AnthropicClient(httpClient: PaceFixtureHTTP(body: json))
    let configuration = ProviderRuntimeConfiguration(
      provider: .anthropic, isEnabled: true, credentials: [CredentialField.anthropicAccessToken: "sk-claude"]
    )

    let usage = try await client.fetchUsage(configuration: configuration, now: now)

    XCTAssertEqual(usage.metrics.map(\.id), ["five_hour", "seven_day", "seven_day_opus"])
    XCTAssertEqual(usage.metrics.map(\.windowSeconds), [nil, nil, nil])
    XCTAssertEqual(usage.metrics.map { QuotaPace.windowSeconds(for: $0, provider: .anthropic) }, [18_000, 604_800, 604_800])
  }
}

private struct PaceFixtureHTTP: HTTPClient {
  let body: String

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
