import XCTest
@testable import QuotaCore

final class PaceEstimatorTests: XCTestCase {
  private let base = Date(timeIntervalSince1970: 1_700_000_000)

  private func estimate(
    _ series: [(hours: Double, percent: Double)],
    hoursToReset: Double = 4
  ) -> PaceEstimate? {
    PaceEstimator.estimate(
      points: series.map { (base.addingTimeInterval($0.hours * -3_600), $0.percent) },
      now: base,
      resetAt: base.addingTimeInterval(hoursToReset * 3_600),
      maxLookback: 8 * 3_600
    )
  }

  func testNeedsAtLeastTwoSamples() {
    XCTAssertNil(estimate([(1, 80)]))
    XCTAssertNil(estimate([]))
  }

  func testRejectsTooShortASpan() {
    // Two points only five minutes apart — too noisy to project.
    XCTAssertNil(estimate([(10.0 / 60.0, 90), (0, 89)]))
  }

  func testSteadyWhenNotDraining() {
    let estimate = estimate([(2, 90), (1, 90), (0, 90)])
    XCTAssertEqual(estimate?.trend, .steady)
    XCTAssertEqual(estimate?.projectedPercentAtReset, 90)
  }

  func testOnTrackProjectsRemainingAtReset() {
    // 10%/h drain over the last 2h, 4h left -> 40% more consumed -> 40% left.
    let estimate = estimate([(2, 100), (1, 90), (0, 80)], hoursToReset: 4)
    XCTAssertEqual(estimate?.trend, .onTrack)
    XCTAssertEqual(estimate?.burnRatePerHour ?? 0, 10, accuracy: 0.01)
    XCTAssertEqual(estimate?.projectedPercentAtReset, 40)
    XCTAssertNil(estimate?.exhaustionAt)
    XCTAssertEqual(estimate?.summary, "≈40% at reset")
  }

  func testRunsOutWhenDrainBeatsReset() {
    // 20%/h drain, 80% left, reset in 5h -> empty in 4h.
    let estimate = estimate([(2, 100), (0, 60)], hoursToReset: 5)
    XCTAssertEqual(estimate?.trend, .runsOut)
    let expectedEmpty = base.addingTimeInterval(3 * 3_600) // 60% / 20%/h = 3h
    XCTAssertEqual(estimate?.exhaustionAt?.timeIntervalSince1970 ?? 0,
                   expectedEmpty.timeIntervalSince1970, accuracy: 1)
    XCTAssertTrue(estimate?.summary.contains("runs out") ?? false)
  }

  func testResetBoundaryDropsPreviousWindow() {
    // Earlier window sits at low percent; a reset jumps back to 95. Without
    // boundary detection the pre-reset points would fake a huge drain.
    let estimate = estimate([(4, 30), (3, 20), (2, 95), (1, 90), (0, 85)])
    XCTAssertEqual(estimate?.trend, .onTrack)
    // Slope comes only from the post-reset segment: 95 -> 85 over 2h = 5%/h.
    XCTAssertEqual(estimate?.burnRatePerHour ?? 0, 5, accuracy: 0.01)
  }

  func testSummaryFormatsExhaustion() {
    let estimate = estimate([(2, 100), (0, 60)], hoursToReset: 5)
    XCTAssertEqual(estimate?.summary, "runs out in ~3h")
  }

  func testExhaustionAnchoredAtLastSampleNotNow() {
    // Newest sample is 30 minutes old; the projection must anchor at the
    // sample's own timestamp, same baseline as the measured rate.
    let estimate = estimate([(2, 100), (0.5, 60)], hoursToReset: 5)
    XCTAssertEqual(estimate?.trend, .runsOut)
    // rate = 40/1.5 ≈ 26.67%/h; 60% remaining -> ~2.25h after the last sample
    // (base - 0.5h + 2.25h = base + 1.75h), not base + 2.25h.
    let expected = base.addingTimeInterval(1.75 * 3_600)
    XCTAssertEqual(estimate?.exhaustionAt?.timeIntervalSince1970 ?? 0,
                   expected.timeIntervalSince1970, accuracy: 1)
  }

  // MARK: - snapshot integration

  private func snapshot(
    at date: Date,
    percent: Int,
    resetAt: Date,
    accountID: String = "acct"
  ) -> QuotaSnapshot {
    QuotaSnapshot(
      generatedAt: date,
      providers: [
        ProviderUsage(
          accountID: accountID,
          provider: .anthropic,
          title: "Claude",
          metrics: [
            UsageMetric(
              id: "five_hour",
              label: "5-hour limit",
              remainingPercent: percent,
              resetAt: resetAt
            )
          ],
          fetchedAt: date
        )
      ],
      failures: []
    )
  }

  func testApplyingPaceEstimatesFillsMetric() {
    let resetAt = base.addingTimeInterval(4 * 3_600)
    let history = [
      snapshot(at: base.addingTimeInterval(-2 * 3_600), percent: 100, resetAt: resetAt),
      snapshot(at: base.addingTimeInterval(-1 * 3_600), percent: 90, resetAt: resetAt),
    ]
    let current = snapshot(at: base, percent: 80, resetAt: resetAt)

    let paced = current.applyingPaceEstimates(from: history, now: base)
    let estimate = paced.providers[0].metrics[0].paceEstimate
    XCTAssertEqual(estimate?.trend, .onTrack)
    XCTAssertEqual(estimate?.projectedPercentAtReset, 40)
  }

  func testApplyingPaceEstimatesSkipsMetricsWithoutWindow() {
    // No resetAt -> not projectable.
    let resetAt = base.addingTimeInterval(4 * 3_600)
    let history = [
      snapshot(at: base.addingTimeInterval(-2 * 3_600), percent: 100, resetAt: resetAt)
    ]
    var metric = UsageMetric(id: "five_hour", label: "5-hour limit", remainingPercent: 80)
    metric.resetAt = nil
    let current = QuotaSnapshot(
      generatedAt: base,
      providers: [
        ProviderUsage(
          accountID: "acct", provider: .anthropic, title: "Claude",
          metrics: [metric], fetchedAt: base
        )
      ],
      failures: []
    )
    let paced = current.applyingPaceEstimates(from: history, now: base)
    XCTAssertNil(paced.providers[0].metrics[0].paceEstimate)
  }

  func testApplyingPaceEstimatesTopUpWithinWindowIsNotAReset() {
    // 60 -> 40 -> 85 -> 80, all stamped with the same resetAt: the +45 jump is
    // a top-up, not a window boundary, so all samples stay in the rate slope
    // (net drain ≈ -6.7%/h -> steady). Jump-only detection would keep just the
    // last two points and report a draining 5%/h onTrack.
    let resetAt = base.addingTimeInterval(4 * 3_600)
    let history = [
      snapshot(at: base.addingTimeInterval(-3 * 3_600), percent: 60, resetAt: resetAt),
      snapshot(at: base.addingTimeInterval(-2 * 3_600), percent: 40, resetAt: resetAt),
      snapshot(at: base.addingTimeInterval(-1 * 3_600), percent: 85, resetAt: resetAt),
    ]
    let current = snapshot(at: base, percent: 80, resetAt: resetAt)

    let paced = current.applyingPaceEstimates(from: history, now: base)
    XCTAssertEqual(paced.providers[0].metrics[0].paceEstimate?.trend, .steady)
  }

  func testApplyingPaceEstimatesDropsSmallJumpAcrossReset() {
    // Previous window was barely used: a 98 -> 100 reset is under the 4pt jump
    // threshold. The old resetAt stamps identify it as another window anyway,
    // leaving too few same-window points to estimate.
    let newReset = base.addingTimeInterval(4 * 3_600)
    let oldReset = base.addingTimeInterval(-20 * 3_600)
    let history = [
      snapshot(at: base.addingTimeInterval(-2 * 3_600), percent: 99, resetAt: oldReset),
      snapshot(at: base.addingTimeInterval(-1 * 3_600), percent: 98, resetAt: oldReset),
    ]
    let current = snapshot(at: base, percent: 100, resetAt: newReset)

    let paced = current.applyingPaceEstimates(from: history, now: base)
    XCTAssertNil(paced.providers[0].metrics[0].paceEstimate)
  }

  func testApplyingPaceEstimatesIsolatesAccounts() {
    // A second account's history must not leak into the first's estimate.
    let resetAt = base.addingTimeInterval(4 * 3_600)
    let otherHistory = [
      snapshot(at: base.addingTimeInterval(-2 * 3_600), percent: 5, resetAt: resetAt, accountID: "other")
    ]
    let current = snapshot(at: base, percent: 80, resetAt: resetAt, accountID: "acct")
    let paced = current.applyingPaceEstimates(from: otherHistory, now: base)
    XCTAssertNil(paced.providers[0].metrics[0].paceEstimate)
  }
}
