import XCTest
@testable import QuotaCore

// PR #51 horizon/ordering proof, with PR #61 amount and window metadata.
final class ResetScheduleTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)
  private func usage(_ id: String, provider: QuotaProvider = .anthropic, metrics: [UsageMetric]) -> ProviderUsage {
    ProviderUsage(accountID: id, provider: provider, title: "Same", metrics: metrics, fetchedAt: now)
  }

  func testSchedulesOnlyFiniteFutureResetsInsideInclusiveHorizon() {
    let metrics = [-60.0, 0, 60, 120, 121].map { seconds in
      UsageMetric(id: "\(seconds)", label: "Weekly", resetAt: now.addingTimeInterval(seconds))
    } + [UsageMetric(id: "undated", label: "Weekly")]
    let snapshot = QuotaSnapshot(generatedAt: now, providers: [usage("a", metrics: metrics)], failures: [])
    XCTAssertEqual(snapshot.upcomingResets(now: now, within: 120).map(\.metricID), ["60.0", "120.0"])
    for horizon in [0.0, -1, .infinity, .nan] { XCTAssertTrue(snapshot.upcomingResets(now: now, within: horizon).isEmpty) }
  }

  func testEqualTimesHaveTotalOrderingIncludingProviderAndMetricID() {
    let metrics = ["z", "a"].map { UsageMetric(id: $0, label: "Weekly", resetAt: now.addingTimeInterval(60)) }
    let snapshot = QuotaSnapshot(generatedAt: now, providers: [usage("shared", provider: .openAI, metrics: metrics), usage("shared", metrics: metrics)], failures: [])
    let resets = snapshot.upcomingResets(now: now, within: 120)
    XCTAssertEqual(resets.map(\.provider), [.anthropic, .anthropic, .openAI, .openAI])
    XCTAssertEqual(resets.map(\.metricID), ["a", "z", "a", "z"])
  }

  func testFailuresAreOmittedByCompoundIdentityAndContextIsKept() throws {
    let metric = UsageMetric(id: "daily-diem", label: "Daily DIEM", remainingPercent: 64, remainingAmount: 6.4,
                             estimatedTotal: 10, usedDisplay: "6.40 DIEM", resetAt: now.addingTimeInterval(60))
    let snapshot = QuotaSnapshot(generatedAt: now, providers: [usage("shared", metrics: [metric]), usage("shared", provider: .venice, metrics: [metric])], failures: [
      ProviderFailure(accountID: "shared", provider: .anthropic, kind: .auth, message: "expired")
    ])
    let reset = try XCTUnwrap(snapshot.upcomingResets(now: now, within: 120).first)
    XCTAssertEqual(reset.provider, .venice)
    XCTAssertEqual(reset.windowKind, .daily)
    XCTAssertEqual(reset.remainingAmount, 6.4)
    XCTAssertEqual(reset.usageLine, "6.40 DIEM")
    XCTAssertTrue(reset.isEstimated)
    XCTAssertEqual(reset.countdown(at: now), "1m")
    XCTAssertEqual(reset.countdown(at: reset.resetAt), "reset")
  }
}
