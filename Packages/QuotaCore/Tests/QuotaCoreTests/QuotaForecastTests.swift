import XCTest
@testable import QuotaCore

final class QuotaForecastTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private let hour: TimeInterval = 3_600
  private let interval: TimeInterval = 30 * 60

  private func snapshot(_ hours: Double, _ remaining: Int, id: String = "a", reset: Date? = nil) -> QuotaSnapshot {
    let date = now.addingTimeInterval(hours * hour)
    return QuotaSnapshot(generatedAt: now, providers: [ProviderUsage(accountID: id, provider: .anthropic, title: id,
      metrics: [UsageMetric(id: "five_hour", label: "5-hour limit", remainingPercent: remaining,
        resetAt: reset ?? now.addingTimeInterval(3 * hour))], fetchedAt: date)], failures: [])
  }

  private func estimate(_ history: [QuotaSnapshot], latest: QuotaSnapshot? = nil, at date: Date? = nil) -> PaceEstimate? {
    QuotaForecast.measurements(history: history, latest: latest ?? history.last,
      now: date ?? now, refreshInterval: interval)[.init(accountID: "a", metricID: "five_hour")]
  }

  private var draining: [QuotaSnapshot] {
    [(-2.0, 100), (-1.5, 90), (-1.0, 80), (-0.5, 70), (0.0, 60)].map { snapshot($0.0, $0.1) }
  }

  func testPaceAndWarningsShareRateAndFetchAnchoredETA() throws {
    let history = draining
    var latest = try XCTUnwrap(history.last)
    latest.providers[0].metrics[0].resetAt = now.addingTimeInterval(2.5 * hour)
    // Use a stable reset on every reading, then age the final source by 30m.
    let sources = history.map { original -> QuotaSnapshot in
      var copy = original
      copy.providers[0].fetchedAt = original.providers[0].fetchedAt.addingTimeInterval(-0.5 * hour)
      copy.providers[0].metrics[0].resetAt = now.addingTimeInterval(2.5 * hour)
      return copy
    }
    latest = try XCTUnwrap(sources.last)
    let paced = latest.applyingPaceEstimates(from: sources, now: now, refreshInterval: interval)
    let pace = try XCTUnwrap(paced.providers[0].metrics[0].paceEstimate)
    XCTAssertEqual(pace.burnRatePerHour, 20, accuracy: 0.001)
    // 60% lasts 3h from the fetch, exactly until reset: no warning.
    XCTAssertEqual(pace.trend, .onTrack)
    XCTAssertEqual(pace.projectedPercentAtReset, 0)
    let warnings = QuotaForecast.depletionWarnings(for: [.init(accountID: "a", metricID: "five_hour")],
      history: sources, latest: latest, now: now, refreshInterval: interval)
    XCTAssertTrue(warnings.isEmpty)
  }

  func testSustainedDrainWarnsAndCarriesAdditivePaceFields() throws {
    let sources = draining.enumerated().map { index, original -> QuotaSnapshot in
      var copy = original
      copy.providers[0].metrics[0].remainingPercent = 100 - index * 15
      return copy
    }
    let pace = try XCTUnwrap(estimate(sources))
    XCTAssertEqual(pace.trend, .runsOut)
    XCTAssertEqual(pace.burnRatePerHour, 30, accuracy: 0.001)
    XCTAssertEqual(try XCTUnwrap(pace.exhaustionAt).timeIntervalSince(now), 40.0 / 30 * hour, accuracy: 1)
    let warnings = QuotaForecast.depletionWarnings(for: [.init(accountID: "a", metricID: "five_hour")],
      history: sources, latest: sources.last, now: now, refreshInterval: interval)
    XCTAssertEqual(warnings.first?.depletionAt, pace.exhaustionAt)
  }

  func testSampleSpanFreshnessFailureAndFutureGatesClearCarriedEstimates() throws {
    XCTAssertNil(estimate(Array(draining.suffix(3))))
    XCTAssertNil(estimate([snapshot(-0.75, 90), snapshot(-0.5, 80), snapshot(-0.25, 70), snapshot(0, 60)]))
    XCTAssertNil(estimate(draining, at: now.addingTimeInterval(2 * hour)))
    var failed = try XCTUnwrap(draining.last)
    failed.failures = [.init(accountID: "a", provider: .anthropic, kind: .network, message: "offline")]
    failed.providers[0].metrics[0].paceEstimate = estimate(draining)
    XCTAssertNil(failed.applyingPaceEstimates(from: draining, now: now).providers[0].metrics[0].paceEstimate)
    var future = failed
    future.failures = []
    future.providers[0].fetchedAt = now.addingTimeInterval(1)
    XCTAssertNil(estimate(draining, latest: future))
  }

  func testRepeatedFetchCopiesCannotSatisfySampleGate() {
    let copies = Array(repeating: snapshot(-1, 90), count: 20) + [snapshot(0, 40)]
    XCTAssertNil(estimate(copies))
  }

  func testObservationGapRequiresNewEvidence() {
    let reset = now.addingTimeInterval(hour)
    let history = [(-3.0, 100), (-2.5, 90), (-2.0, 80), (-1.5, 70), (0.0, 30)]
      .map { snapshot($0.0, $0.1, reset: reset) }
    XCTAssertNil(estimate(history))
  }

  func testTopUpWithSameResetIsNotAWindowBoundary() throws {
    let reset = now.addingTimeInterval(2 * hour)
    let history = [(-3.0, 60), (-2.25, 40), (-1.5, 85), (-0.75, 82), (0.0, 80)]
      .map { snapshot($0.0, $0.1, reset: reset) }
    XCTAssertEqual(try XCTUnwrap(estimate(history)).trend, .steady)
  }

  func testSmallJumpResetAndKindChangeDiscardPreviousWindow() {
    var history = draining
    for index in history.indices.dropLast() {
      history[index].providers[0].metrics[0].remainingPercent = 99
      history[index].providers[0].metrics[0].resetAt = now.addingTimeInterval(-0.25 * hour)
    }
    history[history.count - 1].providers[0].metrics[0].remainingPercent = 100
    XCTAssertNil(estimate(history))
    history = draining
    for index in history.indices.dropLast() {
      history[index].providers[0].metrics[0].label = "7-day limit"
    }
    XCTAssertNil(estimate(history))
  }

  func testAccountsRemainIsolatedAndRetiredMetricHasNoEstimate() throws {
    let other = draining.map { original -> QuotaSnapshot in
      var copy = original
      copy.providers[0].accountID = "other"
      return copy
    }
    XCTAssertNil(estimate(other, latest: draining.last))
    var latest = try XCTUnwrap(draining.last)
    latest.providers[0].metrics = []
    XCTAssertNil(estimate(draining, latest: latest))
  }

  func testLabelNeverInventsDurationAndReportedDurationWins() throws {
    var history = draining
    for index in history.indices {
      history[index].providers[0].provider = .openAI
    }
    XCTAssertNil(estimate(history))
    for index in history.indices {
      history[index].providers[0].metrics[0].windowSeconds = 5 * 3_600
    }
    XCTAssertNotNil(estimate(history))
    // A 30-day guessed month would pass; reported 90 days requires 9 days.
    for index in history.indices {
      history[index].providers[0].metrics[0].windowSeconds = 90 * 86_400
      history[index].providers[0].metrics[0].label = "Monthly limit"
    }
    XCTAssertNil(estimate(history))
  }

  func testOldMetricPayloadDecodesWithoutPace() throws {
    let decoder = JSONDecoder()
    let metric = try decoder.decode(UsageMetric.self,
      from: Data(#"{"id":"weekly","label":"Weekly","remainingPercent":60,"isUnlimited":false}"#.utf8))
    XCTAssertNil(metric.paceEstimate)
  }

  private func week(_ remaining: (Double) -> Double) -> [QuotaSnapshot] {
    stride(from: -6 * 24.0, through: 0, by: 0.5).map { offset in
      var source = snapshot(offset, Int(remaining(offset).rounded()), reset: now.addingTimeInterval(24 * hour))
      source.providers[0].metrics[0] = UsageMetric(id: "five_hour", label: "7-day limit",
        remainingPercent: Int(remaining(offset).rounded()), resetAt: now.addingTimeInterval(24 * hour), windowSeconds: 7 * 86_400)
      return source
    }
  }

  func testHealthyWeekBurstDoesNotBecomeADepletionWarning() throws {
    let history = week { offset in
      offset < -3 ? 100 - 40 * (offset + 144) / 141 : 60 - 10 * (offset + 3) / 3
    }
    XCTAssertEqual(try XCTUnwrap(estimate(history)).trend, .onTrack)
  }

  func testLateLowQuotaSurgeUsesRecentRateAtSlowCadence() throws {
    let history = week { offset in
      offset < -3 ? 100 - 70 * (offset + 144) / 141 : 30 - 10 * (offset + 3) / 3
    }
    XCTAssertEqual(try XCTUnwrap(estimate(history)).trend, .runsOut)
    let hourly = history.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
    let results = QuotaForecast.measurements(history: hourly, latest: hourly.last, now: now, refreshInterval: hour)
    XCTAssertEqual(results[.init(accountID: "a", metricID: "five_hour")]?.trend, .runsOut)
  }

  func testRecentFetchesDuringFailuresAreNotEvidence() {
    let history = draining.enumerated().map { index, original -> QuotaSnapshot in
      guard index != 0 && index != 4 else { return original }
      var failed = original
      failed.failures = [.init(accountID: "a", provider: .anthropic, kind: .network, message: "offline")]
      return failed
    }
    XCTAssertNil(estimate(history))
  }

  func testChangedReportedDurationCannotBorrowSameKindEvidence() {
    var history = draining
    for index in history.indices {
      history[index].providers[0].provider = .openAI
      history[index].providers[0].metrics[0].resetAt = now.addingTimeInterval(2 * hour)
      history[index].providers[0].metrics[0].windowSeconds = index == history.count - 1 ? 4 * 3_600 : 5 * 3_600
    }
    XCTAssertNil(estimate(history))
  }
}
