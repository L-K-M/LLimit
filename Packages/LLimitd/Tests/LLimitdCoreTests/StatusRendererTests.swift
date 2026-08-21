import XCTest
@testable import QuotaCore
@testable import LLimitdCore

final class StatusRendererTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private func snapshot(remaining: [Int], failures: [ProviderFailure] = []) -> QuotaSnapshot {
    QuotaSnapshot(
      generatedAt: now.addingTimeInterval(-300),
      providers: remaining.enumerated().map { index, percent in
        ProviderUsage(
          accountID: "account-\(index)",
          provider: .anthropic,
          title: "Claude \(index + 1)",
          metrics: [UsageMetric(id: "five-hour", label: "5-hour limit", remainingPercent: percent)],
          fetchedAt: now.addingTimeInterval(-300)
        )
      },
      failures: failures
    )
  }

  private func decodedWaybar(_ snapshot: QuotaSnapshot?) throws -> [String: Any] {
    let json = StatusRenderer.waybarJSON(snapshot: snapshot, now: now)
    let data = try XCTUnwrap(json.data(using: .utf8))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  func testWaybarJSONHasWaybarContractKeys() throws {
    let object = try decodedWaybar(snapshot(remaining: [73, 41]))

    XCTAssertEqual(object["text"] as? String, "Claude 1 73% · Claude 2 41%")
    XCTAssertEqual(object["class"] as? String, "ok")
    XCTAssertEqual(object["percentage"] as? Int, 41)
    XCTAssertNotNil(object["tooltip"])
    XCTAssertEqual((object["accounts"] as? [[String: Any]])?.count, 2)
  }

  // MARK: - Per-metric rows (consumed by the tray popup)

  func testAccountsCarryEveryMetricAsItsOwnRow() throws {
    let usage = ProviderUsage(
      accountID: "acct",
      provider: .anthropic,
      title: "Claude",
      metrics: [
        UsageMetric(id: "session", label: "Session", remainingPercent: 62, resetIn: "3h 12m"),
        UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 8, resetIn: "4d 2h")
      ],
      fetchedAt: now
    )
    let object = try decodedWaybar(
      QuotaSnapshot(generatedAt: now, providers: [usage], failures: [])
    )

    let account = try XCTUnwrap((object["accounts"] as? [[String: Any]])?.first)
    let metrics = try XCTUnwrap(account["metrics"] as? [[String: Any]])
    XCTAssertEqual(metrics.count, 2)
    XCTAssertEqual(metrics[0]["label"] as? String, "Session")
    XCTAssertEqual(metrics[0]["remainingPercent"] as? Int, 62)
    XCTAssertEqual(metrics[0]["resetIn"] as? String, "3h 12m")
    XCTAssertEqual(metrics[1]["label"] as? String, "Weekly")
    XCTAssertEqual(metrics[1]["remainingPercent"] as? Int, 8)
    // The headline stays the worst metric, so existing bars are unchanged.
    XCTAssertEqual(account["remainingPercent"] as? Int, 8)
  }

  func testUnlimitedMetricIsFlaggedAndOmitsRemainingPercent() throws {
    let usage = ProviderUsage(
      accountID: "acct",
      provider: .zhipu,
      title: "Zhipu AI",
      metrics: [UsageMetric(id: "plan", label: "Plan", isUnlimited: true)],
      fetchedAt: now
    )
    let object = try decodedWaybar(
      QuotaSnapshot(generatedAt: now, providers: [usage], failures: [])
    )

    let account = try XCTUnwrap((object["accounts"] as? [[String: Any]])?.first)
    let metric = try XCTUnwrap((account["metrics"] as? [[String: Any]])?.first)
    XCTAssertEqual(metric["unlimited"] as? Bool, true)
    // Absent, not null: the tray uses plain key lookup.
    XCTAssertNil(metric["remainingPercent"])
    XCTAssertNil(metric["resetIn"])
    XCTAssertEqual(metric["usageLine"] as? String, "Unlimited")
  }

  func testMetricsAreEmittedForEveryAccount() throws {
    let object = try decodedWaybar(snapshot(remaining: [73, 41]))
    let accounts = try XCTUnwrap(object["accounts"] as? [[String: Any]])
    for account in accounts {
      XCTAssertEqual((account["metrics"] as? [[String: Any]])?.count, 1)
    }
  }

  func testWaybarClassFollowsLowestRemainingPercent() throws {
    XCTAssertEqual(try decodedWaybar(snapshot(remaining: [80]))["class"] as? String, "ok")
    XCTAssertEqual(try decodedWaybar(snapshot(remaining: [25]))["class"] as? String, "warning")
    XCTAssertEqual(try decodedWaybar(snapshot(remaining: [5]))["class"] as? String, "critical")
  }

  func testWaybarWithoutSnapshotIsEmpty() throws {
    let object = try decodedWaybar(nil)
    XCTAssertEqual(object["class"] as? String, "empty")
  }

  func testWaybarWithOnlyFailuresIsError() throws {
    let failed = QuotaSnapshot(
      generatedAt: now,
      providers: [],
      failures: [ProviderFailure(provider: .kimi, kind: .auth, message: "token expired")]
    )
    let object = try decodedWaybar(failed)
    XCTAssertEqual(object["class"] as? String, "error")
  }

  func testWaybarJSONIsValidAndCredentialFree() throws {
    let json = StatusRenderer.waybarJSON(snapshot: snapshot(remaining: [50]), now: now)
    XCTAssertFalse(json.contains("access_token"))
    XCTAssertFalse(json.contains("api_key"))
  }

  func testHumanReadableListsAccountsAndFailures() {
    let text = StatusRenderer.humanReadable(
      snapshot: snapshot(
        remaining: [73],
        failures: [ProviderFailure(provider: .kimi, kind: .rateLimit, message: "slow down")]
      ),
      now: now
    )

    XCTAssertTrue(text.contains("5 min ago"))
    XCTAssertTrue(text.contains("Claude 1: 5-hour limit 73% left"))
    XCTAssertTrue(text.contains("Kimi: ERROR slow down"))
  }

  func testHumanReadableWithoutSnapshotExplainsNextStep() {
    XCTAssertTrue(StatusRenderer.humanReadable(snapshot: nil, now: now).contains("llimit refresh"))
  }
}
