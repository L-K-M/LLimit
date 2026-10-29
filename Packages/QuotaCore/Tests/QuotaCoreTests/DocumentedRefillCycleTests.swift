import XCTest
@testable import QuotaCore

final class DocumentedRefillCycleTests: XCTestCase {
  private let resetAt = Date(timeIntervalSince1970: 1_793_361_600)
  private let cycles: [(QuotaProvider, String, TimeInterval)] = [
    (.venice, "daily-diem", 86_400),
    (.devin, "quota-daily", 86_400),
    (.devin, "quota-weekly", 604_800),
    (.metaMuse, "weekly", 604_800),
    (.openCodeGo, "weekly", 604_800)
  ]

  func testDocumentedDailyAndWeeklyRefillCycles() throws {
    for (provider, id, duration) in cycles {
      let halfway = resetAt.addingTimeInterval(-duration / 2)
      let metric = UsageMetric(id: id, label: "Allowance", remainingPercent: 50, resetAt: resetAt)
      let pace = try XCTUnwrap(QuotaPace(metric: metric, provider: provider, fetchedAt: halfway, now: halfway), id)
      XCTAssertEqual(pace.elapsedFraction, 0.5, id)
      XCTAssertEqual(pace.evenPaceRemainingFraction, 0.5, id)
      XCTAssertEqual(pace.phrase, "on pace", id)
    }
  }

  func testLabelsAndUnrelatedIDsCannotInventCycles() {
    for (provider, _, _) in cycles {
      let unknown = UsageMetric(id: "unknown", label: "Weekly plan quota resets daily",
                                remainingPercent: 50, resetAt: resetAt)
      XCTAssertNil(QuotaPace.windowSeconds(for: unknown, provider: provider))
    }
  }

  func testExplicitDurationWinsAndZeroDisablesFallback() throws {
    var metric = UsageMetric(id: "daily-diem", label: "Allowance", remainingPercent: 50,
                             resetAt: resetAt, windowSeconds: 43_200)
    let halfway = resetAt.addingTimeInterval(-21_600)
    let pace = try XCTUnwrap(QuotaPace(metric: metric, provider: .venice, fetchedAt: halfway, now: halfway))
    XCTAssertEqual(pace.elapsedFraction, 0.5)
    metric.windowSeconds = 0
    XCTAssertNil(QuotaPace.windowSeconds(for: metric, provider: .venice))
  }

  func testExpiredAndContradictoryCyclesHaveNoMarker() {
    for (provider, id, duration) in cycles {
      let metric = UsageMetric(id: id, label: "Allowance", remainingPercent: 50, resetAt: resetAt)
      let fetchedAt = resetAt.addingTimeInterval(-duration / 2)
      XCTAssertNil(QuotaPace(metric: metric, provider: provider, fetchedAt: fetchedAt, now: resetAt))
      XCTAssertNil(QuotaPace(metric: metric, provider: provider, fetchedAt: fetchedAt, now: resetAt.addingTimeInterval(1)))
      let beforeCycle = resetAt.addingTimeInterval(-duration * 1.1)
      XCTAssertNil(QuotaPace(metric: metric, provider: provider, fetchedAt: beforeCycle, now: beforeCycle))
    }
  }
}
