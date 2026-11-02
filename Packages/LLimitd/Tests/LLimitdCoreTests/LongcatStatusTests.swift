import XCTest
@testable import QuotaCore
@testable import LLimitdCore

final class LongcatStatusTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_793_232_000)

  private func snapshot(amount: Double, percentage: Int? = nil, baseline: Double? = nil) -> QuotaSnapshot {
    QuotaSnapshot(generatedAt: now, providers: [ProviderUsage(
      accountID: "longcat-personal", provider: .longcat, title: "Longcat",
      metrics: [UsageMetric(id: "token-balance", label: "Tokens remaining", remainingPercent: percentage,
        remainingAmount: amount, estimatedTotal: baseline, usedDisplay: "\(Int(amount)) tokens")],
      fetchedAt: now)], failures: [])
  }

  private func object(_ snapshot: QuotaSnapshot) throws -> [String: Any] {
    let json = StatusRenderer.waybarJSON(snapshot: snapshot, now: now)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
  }

  func testEstimatedTokenBalanceAppearsInBarsAndHumanStatusWithoutReset() throws {
    let snapshot = snapshot(amount: 250_000, percentage: 25, baseline: 1_000_000)
    let object = try object(snapshot)
    XCTAssertEqual(object["text"] as? String, "Longcat ≈25%")
    XCTAssertEqual(object["percentage"] as? Int, 25)
    XCTAssertEqual(object["estimated"] as? Bool, true)
    let account = try XCTUnwrap((object["accounts"] as? [[String: Any]])?.first)
    XCTAssertEqual(account["provider"] as? String, "longcat")
    let metric = try XCTUnwrap((account["metrics"] as? [[String: Any]])?.first)
    XCTAssertEqual(metric["estimated"] as? Bool, true)
    XCTAssertEqual(metric["remainingAmount"] as? Double, 250_000)
    XCTAssertEqual(metric["window"] as? String, "other")
    XCTAssertNil(metric["resetAt"])
    XCTAssertNil(metric["resetIn"])
    XCTAssertNil(metric["pace"])
    let human = StatusRenderer.humanReadable(snapshot: snapshot, now: now)
    XCTAssertTrue(human.contains("Tokens remaining ≈25% left (estimated)"))
    XCTAssertFalse(human.contains("resets"))
  }

  func testInitialZeroShowsTokenAmountWithoutInventingPercentage() throws {
    let snapshot = snapshot(amount: 0)
    let object = try object(snapshot)
    XCTAssertEqual(object["text"] as? String, "Longcat Tokens remaining 0 tokens")
    XCTAssertNil(object["percentage"])
    XCTAssertNil(object["estimated"])
    let account = try XCTUnwrap((object["accounts"] as? [[String: Any]])?.first)
    let metric = try XCTUnwrap((account["metrics"] as? [[String: Any]])?.first)
    XCTAssertEqual(metric["remainingAmount"] as? Double, 0)
    XCTAssertNil(metric["remainingPercent"])
    XCTAssertTrue(StatusRenderer.humanReadable(snapshot: snapshot, now: now)
      .contains("Tokens remaining 0 tokens"))
  }

  func testExhaustedObservedBalanceKeepsEstimatedZeroPercentage() throws {
    let object = try object(snapshot(amount: 0, percentage: 0, baseline: 1_000_000))
    XCTAssertEqual(object["text"] as? String, "Longcat ≈0%")
    XCTAssertEqual(object["percentage"] as? Int, 0)
    XCTAssertEqual(object["estimated"] as? Bool, true)
    XCTAssertEqual(object["class"] as? String, "critical")
  }
}
