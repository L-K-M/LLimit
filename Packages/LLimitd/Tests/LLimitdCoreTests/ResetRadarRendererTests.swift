import XCTest
@testable import QuotaCore
@testable import LLimitdCore

final class ResetRadarRendererTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private func metric(
    _ id: String,
    _ label: String,
    in seconds: TimeInterval,
    remaining: Int? = 62,
    unlimited: Bool = false
  ) -> UsageMetric {
    UsageMetric(
      id: id,
      label: label,
      remainingPercent: remaining,
      resetAt: now.addingTimeInterval(seconds),
      isUnlimited: unlimited
    )
  }

  private func usage(
    _ id: String,
    _ name: String,
    provider: QuotaProvider = .anthropic,
    _ metrics: [UsageMetric]
  ) -> ProviderUsage {
    ProviderUsage(accountID: id, provider: provider, title: name, metrics: metrics, fetchedAt: now)
  }

  private func snapshot(_ providers: [ProviderUsage]) -> QuotaSnapshot {
    QuotaSnapshot(generatedAt: now, providers: providers, failures: [])
  }

  // MARK: - Missing data vs. an empty schedule

  func testMissingSnapshotIsCalledOutRatherThanReportedAsEmpty() {
    let text = StatusRenderer.resetsHumanReadable(snapshot: nil, now: now, windowDays: 7)

    XCTAssertTrue(text.contains("No quota data yet"))
    XCTAssertTrue(text.contains("llimit refresh"))
    XCTAssertFalse(text.contains("No resets in the next"))
  }

  func testMissingSnapshotJSONSaysSoAndOmitsGeneratedAt() throws {
    let json = StatusRenderer.resetsJSON(snapshot: nil, now: now, windowDays: 7)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])

    XCTAssertEqual(object["snapshot"] as? Bool, false)
    XCTAssertNil(object["generatedAt"])
    XCTAssertEqual((object["resets"] as? [Any])?.count, 0)
  }

  func testEmptyScheduleNamesTheWindowAndKeepsSnapshotMetadata() throws {
    // A dated limit outside the window: data exists, nothing is due.
    let far = snapshot([usage("a", "Claude", [metric("weekly", "Weekly limit", in: 40 * 86_400)])])

    XCTAssertEqual(
      StatusRenderer.resetsHumanReadable(snapshot: far, now: now, windowDays: 7),
      "No resets in the next 7 days."
    )
    XCTAssertEqual(
      StatusRenderer.resetsHumanReadable(snapshot: far, now: now, windowDays: 1),
      "No resets in the next 1 day."
    )

    let json = StatusRenderer.resetsJSON(snapshot: far, now: now, windowDays: 7)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    XCTAssertEqual(object["snapshot"] as? Bool, true)
    XCTAssertNotNil(object["generatedAt"])
    XCTAssertEqual((object["resets"] as? [Any])?.count, 0)
  }

  // MARK: - Rendering

  func testHumanReadableListsResetsWithCountdownAndHeadroom() {
    let snap = snapshot([
      usage("claude", "Claude", [metric("five_hour", "5-hour limit", in: 3 * 3600 + 12 * 60)]),
      usage("openai", "OpenAI", provider: .openAI,
            [metric("weekly", "Weekly limit", in: 4 * 86_400 + 2 * 3600, remaining: 41)]),
      usage("zhipu", "Zhipu AI", provider: .zhipu,
            [metric("mcp", "MCP monthly", in: 86_400, remaining: nil, unlimited: true)])
    ])

    let lines = StatusRenderer.resetsHumanReadable(snapshot: snap, now: now, windowDays: 7)
      .split(separator: "\n").map(String.init)

    XCTAssertEqual(lines[0], "Upcoming resets (next 7 days)")
    XCTAssertEqual(lines[1], "in 3h 12m — Claude · 5-hour limit (62% left)")
    // Soonest first: Zhipu's 1-day reset precedes OpenAI's 4-day one.
    XCTAssertEqual(lines[2], "in 1d — Zhipu AI · MCP monthly (unlimited)")
    XCTAssertEqual(lines[3], "in 4d 2h — OpenAI · Weekly limit (41% left)")
  }

  // MARK: - Staleness

  private func staleSnapshot(metricSeconds: TimeInterval) -> QuotaSnapshot {
    QuotaSnapshot(
      generatedAt: now.addingTimeInterval(-3 * 86_400),
      providers: [usage("a", "Claude", [metric("weekly", "Weekly limit", in: metricSeconds)])],
      failures: []
    )
  }

  func testStaleSnapshotIsFlaggedInTheEmptyMessage() {
    // Three days old with nothing due: an all-clear that must not read as fresh.
    XCTAssertEqual(
      StatusRenderer.resetsHumanReadable(snapshot: staleSnapshot(metricSeconds: 40 * 86_400),
                                         now: now, windowDays: 7),
      "No resets in the next 7 days (data from 3d ago)."
    )
  }

  func testStaleSnapshotIsFlaggedInTheHeader() {
    let lines = StatusRenderer.resetsHumanReadable(snapshot: staleSnapshot(metricSeconds: 3600),
                                                   now: now, windowDays: 7)
      .split(separator: "\n").map(String.init)

    XCTAssertEqual(lines[0], "Upcoming resets (next 7 days) (data from 3d ago)")
  }

  func testFreshSnapshotHasNoStalenessHint() {
    let fresh = snapshot([usage("a", "Claude", [metric("weekly", "Weekly limit", in: 3600)])])
    XCTAssertFalse(
      StatusRenderer.resetsHumanReadable(snapshot: fresh, now: now, windowDays: 7)
        .contains("data from")
    )
  }

  func testJSONCarriesEveryFieldAndOmitsMissingPercent() throws {
    let snap = snapshot([
      usage("claude", "Claude", [metric("five_hour", "5-hour limit", in: 3 * 3600 + 12 * 60)]),
      usage("cline", "Cline", provider: .cline,
            [metric("credit", "Credit balance", in: 4 * 86_400, remaining: nil)])
    ])

    let json = StatusRenderer.resetsJSON(snapshot: snap, now: now, windowDays: 7)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])

    XCTAssertEqual(object["windowDays"] as? Int, 7)
    XCTAssertEqual(object["snapshot"] as? Bool, true)
    let rows = try XCTUnwrap(object["resets"] as? [[String: Any]])
    XCTAssertEqual(rows.count, 2)

    XCTAssertEqual(rows[0]["accountID"] as? String, "claude")
    XCTAssertEqual(rows[0]["provider"] as? String, "anthropic")
    XCTAssertEqual(rows[0]["metricLabel"] as? String, "5-hour limit")
    XCTAssertEqual(rows[0]["remainingPercent"] as? Int, 62)
    XCTAssertEqual(rows[0]["resetIn"] as? String, "3h 12m")
    XCTAssertEqual(rows[0]["unlimited"] as? Bool, false)

    let iso = try XCTUnwrap(rows[0]["resetAt"] as? String)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let parsed = try XCTUnwrap(formatter.date(from: iso))
    XCTAssertEqual(
      parsed.timeIntervalSince1970,
      now.addingTimeInterval(3 * 3600 + 12 * 60).timeIntervalSince1970,
      accuracy: 1
    )

    // An amount-only limit has no percentage to report.
    XCTAssertNil(rows[1]["remainingPercent"])
  }
}
