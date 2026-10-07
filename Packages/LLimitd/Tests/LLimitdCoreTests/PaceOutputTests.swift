import XCTest
import QuotaCore
@testable import LLimitdCore

final class PaceOutputTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func pacedSnapshot() throws -> QuotaSnapshot {
    let history = (0...4).map { index in
      let date = now.addingTimeInterval(Double(index - 4) * 1_800)
      return QuotaSnapshot(generatedAt: date, providers: [ProviderUsage(accountID: "a", provider: .anthropic,
        title: "Claude", metrics: [UsageMetric(id: "five_hour", label: "5-hour limit",
          remainingPercent: 100 - index * 15, resetAt: now.addingTimeInterval(3 * 3_600))], fetchedAt: date)], failures: [])
    }
    return try XCTUnwrap(history.last).applyingPaceEstimates(from: history, now: now, refreshInterval: 1_800)
  }

  func testHumanAndJSONExposeSharedPaceAndRate() throws {
    let snapshot = try pacedSnapshot()
    XCTAssertTrue(StatusRenderer.humanReadable(snapshot: snapshot, now: now).contains("runs out"))
    let object = StatusRenderer.waybarObject(snapshot: snapshot, now: now)
    let accounts = try XCTUnwrap(object["accounts"] as? [[String: Any]])
    let metric = try XCTUnwrap((accounts[0]["metrics"] as? [[String: Any]])?.first)
    XCTAssertEqual(metric["paceTrend"] as? String, "runsOut")
    XCTAssertEqual(metric["burnRatePerHour"] as? Double, 30)
    XCTAssertNotNil(metric["exhaustionAt"])
  }

  func testStoredPaceExpiresAndFailureSuppressesOutput() throws {
    var snapshot = try pacedSnapshot()
    XCTAssertFalse(StatusRenderer.humanReadable(snapshot: snapshot, now: now.addingTimeInterval(7_200)).contains("runs out"))
    snapshot.failures = [.init(accountID: "a", provider: .anthropic, kind: .network, message: "offline")]
    XCTAssertFalse(StatusRenderer.humanReadable(snapshot: snapshot, now: now).contains("runs out"))
    let object = StatusRenderer.waybarObject(snapshot: snapshot, now: now)
    let accounts = try XCTUnwrap(object["accounts"] as? [[String: Any]])
    let metric = try XCTUnwrap((accounts[0]["metrics"] as? [[String: Any]])?.first)
    XCTAssertNil(metric["pace"])
  }
}
