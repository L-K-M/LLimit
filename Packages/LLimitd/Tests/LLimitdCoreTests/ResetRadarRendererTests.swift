import XCTest
@testable import QuotaCore
@testable import LLimitdCore

final class ResetRadarRendererTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)
  private func object(_ snapshot: QuotaSnapshot?, days: Int = 7) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(StatusRenderer.resetsJSON(snapshot: snapshot, now: now, windowDays: days).utf8)) as? [String: Any])
  }

  func testMissingSnapshotAndEmptyScheduleHaveDistinctMetadata() throws {
    XCTAssertTrue(StatusRenderer.resetsHumanReadable(snapshot: nil, now: now).contains("No quota data yet"))
    let missing = try object(nil)
    XCTAssertEqual(missing["snapshot"] as? Bool, false)
    XCTAssertNil(missing["generatedAt"])
    let empty = QuotaSnapshot(generatedAt: now, providers: [], failures: [])
    XCTAssertEqual(StatusRenderer.resetsHumanReadable(snapshot: empty, now: now, windowDays: 1), "No resets in the next 1 day.")
    XCTAssertEqual(try object(empty)["snapshot"] as? Bool, true)
    XCTAssertNotNil(try object(empty)["generatedAt"])
    let old = QuotaSnapshot(generatedAt: now.addingTimeInterval(-3 * 86_400), providers: [], failures: [])
    XCTAssertEqual(StatusRenderer.resetsHumanReadable(snapshot: old, now: now), "No resets in the next 7 days (data from 3d ago).")
  }

  func testRadarMetadataAndAdditiveStatusResetsUseSameDetector() throws {
    let usage = ProviderUsage(accountID: "v", provider: .venice, title: "Venice", metrics: [UsageMetric(
      id: "daily-diem", label: "Daily DIEM", remainingAmount: 4.25, usedDisplay: "4.25 DIEM", resetAt: now.addingTimeInterval(5_400)
    )], fetchedAt: now)
    let snapshot = QuotaSnapshot(generatedAt: now, providers: [usage], failures: [])
    let rows = try XCTUnwrap(try object(snapshot)["resets"] as? [[String: Any]])
    XCTAssertEqual(rows[0]["window"] as? String, "daily")
    XCTAssertEqual(rows[0]["remainingAmount"] as? Double, 4.25)
    XCTAssertNil(rows[0]["remainingPercent"])
    XCTAssertEqual(rows[0]["resetSeconds"] as? Int, 5_400)
    XCTAssertEqual(rows[0]["resetIn"] as? String, "1h 30m")
    let status = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(StatusRenderer.waybarJSON(snapshot: snapshot, now: now).utf8)) as? [String: Any])
    XCTAssertEqual((status["resets"] as? [[String: Any]])?.count, rows.count)
    XCTAssertTrue(StatusRenderer.resetsHumanReadable(snapshot: snapshot, now: now).contains("(4.25 DIEM)"))
  }

  func testFailureCountsCollapseDuplicatesButNotProviders() throws {
    let snapshot = QuotaSnapshot(generatedAt: now, providers: [], failures: [
      .init(accountID: "shared", provider: .anthropic, kind: .auth, message: "expired"),
      .init(accountID: "shared", provider: .anthropic, kind: .network, message: "offline"),
      .init(accountID: "shared", provider: .openAI, kind: .auth, message: "expired")
    ])
    XCTAssertEqual(try object(snapshot)["failureCount"] as? Int, 2)
    XCTAssertTrue(StatusRenderer.resetsHumanReadable(snapshot: snapshot, now: now).contains("2 accounts failed to refresh"))
  }

  func testHorizonParserDistinguishesTrueOverflowFromLargeInt64() throws {
    XCTAssertEqual(try ResetsOptions.parse([]).days, 7)
    XCTAssertEqual(try ResetsOptions.parse(["--json", "--days", "90"]).days, 90)
    // 5e18 fits Int64. Only longer digit strings exercise the overflow path.
    XCTAssertNotNil(Int("+5000000000000000000"))
    XCTAssertNil(Int("+50000000000000000000"))
    for raw in ["0", "91", "-1", "+5000000000000000000", "99999999999999999999", "-99999999999999999999"] {
      XCTAssertThrowsError(try ResetsOptions.parse(["--days", raw])) { XCTAssertEqual(($0 as? CommandLineError)?.message, "--days must be between 1 and 90") }
    }
    for args in [["--days"], ["--days", "1.5"], ["--bogus"]] { XCTAssertThrowsError(try ResetsOptions.parse(args)) }
  }
}
