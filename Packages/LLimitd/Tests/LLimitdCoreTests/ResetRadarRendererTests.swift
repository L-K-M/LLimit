import XCTest
@testable import QuotaCore
@testable import LLimitdCore

final class ResetRadarRendererTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private func reset(
    account: String,
    metric: String,
    in seconds: TimeInterval,
    remaining: Int? = 62,
    unlimited: Bool = false,
    provider: QuotaProvider = .anthropic
  ) -> UpcomingReset {
    UpcomingReset(
      accountID: account,
      accountName: account,
      provider: provider,
      metricID: metric,
      metricLabel: metric,
      resetAt: now.addingTimeInterval(seconds),
      remainingPercent: remaining,
      isUnlimited: unlimited
    )
  }

  func testEmptyRadarNamesTheWindow() {
    XCTAssertEqual(
      StatusRenderer.resetsHumanReadable([], now: now, windowDays: 7),
      "No resets in the next 7 days."
    )
    XCTAssertEqual(
      StatusRenderer.resetsHumanReadable([], now: now, windowDays: 1),
      "No resets in the next 1 day."
    )
  }

  func testHumanReadableListsResetsWithCountdownAndHeadroom() {
    let resets = [
      reset(account: "Claude", metric: "5-hour limit", in: 3 * 3600 + 12 * 60),
      reset(account: "OpenAI", metric: "Weekly limit", in: 4 * 86_400 + 2 * 3600, remaining: 41),
      reset(account: "Zhipu AI", metric: "MCP monthly", in: 86_400, remaining: nil, unlimited: true)
    ]

    let text = StatusRenderer.resetsHumanReadable(resets, now: now, windowDays: 7)
    let lines = text.split(separator: "\n").map(String.init)

    XCTAssertEqual(lines[0], "Upcoming resets (next 7 days)")
    XCTAssertEqual(lines[1], "in 3h 12m — Claude · 5-hour limit (62% left)")
    XCTAssertEqual(lines[2], "in 4d 2h — OpenAI · Weekly limit (41% left)")
    XCTAssertEqual(lines[3], "in 1d — Zhipu AI · MCP monthly (unlimited)")
  }

  func testJSONCarriesEveryFieldAndOmitsMissingPercent() throws {
    let resets = [
      reset(account: "Claude", metric: "5-hour limit", in: 3 * 3600 + 12 * 60),
      reset(account: "Cline", metric: "Credit balance", in: 3600, remaining: nil)
    ]

    let json = StatusRenderer.resetsJSON(resets, now: now, windowDays: 7)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])

    XCTAssertEqual(object["windowDays"] as? Int, 7)
    let rows = try XCTUnwrap(object["resets"] as? [[String: Any]])
    XCTAssertEqual(rows.count, 2)

    XCTAssertEqual(rows[0]["accountID"] as? String, "Claude")
    XCTAssertEqual(rows[0]["provider"] as? String, "anthropic")
    XCTAssertEqual(rows[0]["metricLabel"] as? String, "5-hour limit")
    XCTAssertEqual(rows[0]["remainingPercent"] as? Int, 62)
    XCTAssertEqual(rows[0]["resetIn"] as? String, "3h 12m")
    XCTAssertEqual(rows[0]["unlimited"] as? Bool, false)

    let iso = try XCTUnwrap(rows[0]["resetAt"] as? String)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let parsed = try XCTUnwrap(formatter.date(from: iso))
    XCTAssertEqual(parsed.timeIntervalSince1970, now.addingTimeInterval(3 * 3600 + 12 * 60).timeIntervalSince1970, accuracy: 1)

    // An amount-only limit has no percentage to report.
    XCTAssertNil(rows[1]["remainingPercent"])
  }

  func testJSONEmptyRadarIsStillWellFormed() throws {
    let json = StatusRenderer.resetsJSON([], now: now, windowDays: 3)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])

    XCTAssertEqual(object["windowDays"] as? Int, 3)
    XCTAssertEqual((object["resets"] as? [Any])?.count, 0)
  }
}
