import XCTest
@testable import QuotaCore

final class QuotaEventsTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
  private let hour: TimeInterval = 3_600
  private let day: TimeInterval = 86_400

  /// Feeds snapshots through the detector the way the daemon does: the state
  /// and the previous snapshot carry from one refresh to the next.
  private struct Run {
    var config = QuotaEventConfig.default
    var state = QuotaEventState()
    var previous: QuotaSnapshot?

    mutating func step(_ current: QuotaSnapshot, now: Date) -> [QuotaEvent] {
      let detection = QuotaEvents.detect(previous: previous, current: current, now: now, config: config, state: state)
      state = detection.state
      previous = current
      return detection.events
    }
  }

  private func metric(
    _ id: String = "five_hour",
    label: String = "5-hour limit",
    remaining: Int?,
    resetAt: Date? = nil,
    unlimited: Bool = false,
    estimatedTotal: Double? = nil
  ) -> UsageMetric {
    UsageMetric(
      id: id,
      label: label,
      remainingPercent: remaining,
      estimatedTotal: estimatedTotal,
      resetAt: resetAt,
      isUnlimited: unlimited
    )
  }

  private func usage(
    account accountID: String = "acct-1",
    title: String = "Claude Work",
    provider: QuotaProvider = .anthropic,
    _ metrics: [UsageMetric],
    at fetchedAt: Date
  ) -> ProviderUsage {
    ProviderUsage(accountID: accountID, provider: provider, title: title, metrics: metrics, fetchedAt: fetchedAt)
  }

  private func snapshot(_ providers: [ProviderUsage], failures: [ProviderFailure] = [], at date: Date) -> QuotaSnapshot {
    QuotaSnapshot(generatedAt: date, providers: providers, failures: failures)
  }

  /// One account with one metric, fetched at `date`.
  private func reading(_ remaining: Int?, resetAt: Date? = nil, at date: Date, id: String = "five_hour", label: String = "5-hour limit") -> QuotaSnapshot {
    snapshot([usage([metric(id, label: label, remaining: remaining, resetAt: resetAt)], at: date)], at: date)
  }

  // MARK: - Thresholds

  func testCrossingBelowThresholdFiresOncePerCrossing() {
    var run = Run()
    let reset = t0.addingTimeInterval(4 * hour)

    XCTAssertTrue(run.step(reading(50, resetAt: reset, at: t0), now: t0).isEmpty)

    let crossed = run.step(reading(18, resetAt: reset, at: t0 + 900), now: t0 + 900)
    XCTAssertEqual(crossed.map(\.kind), [.threshold])
    XCTAssertEqual(crossed.first?.threshold, 20)
    XCTAssertEqual(crossed.first?.severity, .normal)
    XCTAssertEqual(crossed.first?.remainingPercent, 18)
    XCTAssertEqual(crossed.first?.resetAt, reset)
    XCTAssertEqual(crossed.first?.accountName, "Claude Work")
    XCTAssertEqual(crossed.first?.metricID, "five_hour")

    XCTAssertTrue(run.step(reading(15, resetAt: reset, at: t0 + 1_800), now: t0 + 1_800).isEmpty)
    XCTAssertTrue(run.step(reading(12, resetAt: reset, at: t0 + 2_700), now: t0 + 2_700).isEmpty)

    let critical = run.step(reading(4, resetAt: reset, at: t0 + 3_600), now: t0 + 3_600)
    XCTAssertEqual(critical.map(\.threshold), [5])
    XCTAssertEqual(critical.first?.severity, .critical)
    XCTAssertTrue(run.step(reading(1, resetAt: reset, at: t0 + 4_500), now: t0 + 4_500).isEmpty)
  }

  func testDropPastEveryThresholdFiresOneCriticalEvent() {
    var run = Run()
    _ = run.step(reading(50, at: t0), now: t0)

    let events = run.step(reading(3, at: t0 + 900), now: t0 + 900)

    XCTAssertEqual(events.map(\.kind), [.threshold])
    XCTAssertEqual(events.first?.threshold, 5)
    XCTAssertEqual(events.first?.severity, .critical)
    // 18 is within the 20% threshold's hysteresis, so that latch holds; it
    // is past 5% + 5, so a second dip to the critical level alerts again.
    XCTAssertTrue(run.step(reading(18, at: t0 + 1_800), now: t0 + 1_800).isEmpty)
    XCTAssertEqual(run.step(reading(3, at: t0 + 2_700), now: t0 + 2_700).map(\.threshold), [5])
  }

  func testRemainingExactlyAtThresholdCounts() {
    var run = Run()
    XCTAssertEqual(run.step(reading(20, at: t0), now: t0).map(\.threshold), [20])
  }

  func testFirstRunAlreadyBelowThresholdFiresOnce() {
    var run = Run()
    XCTAssertEqual(run.step(reading(9, at: t0), now: t0).map(\.threshold), [20])
    XCTAssertTrue(run.step(reading(9, at: t0 + 900), now: t0 + 900).isEmpty)
  }

  func testThresholdRearmsOnlyAfterRecoveringPastHysteresis() {
    var run = Run()
    XCTAssertEqual(run.step(reading(18, at: t0), now: t0).count, 1)

    // 24 is within the 5-point hysteresis of 20: rounding jitter, not recovery.
    XCTAssertTrue(run.step(reading(24, at: t0 + 900), now: t0 + 900).isEmpty)
    XCTAssertTrue(run.step(reading(19, at: t0 + 1_800), now: t0 + 1_800).isEmpty)

    // Exactly threshold + hysteresis is not yet a recovery: it must be exceeded.
    XCTAssertTrue(run.step(reading(25, at: t0 + 2_000), now: t0 + 2_000).isEmpty)
    XCTAssertTrue(run.step(reading(19, at: t0 + 2_200), now: t0 + 2_200).isEmpty)

    XCTAssertTrue(run.step(reading(26, at: t0 + 2_700), now: t0 + 2_700).isEmpty)
    XCTAssertEqual(run.step(reading(19, at: t0 + 3_600), now: t0 + 3_600).map(\.threshold), [20])
  }

  func testWindowEndRearmsThresholdForRollingWindows() {
    var run = Run()
    let firstReset = t0.addingTimeInterval(hour)
    XCTAssertEqual(run.step(reading(10, resetAt: firstReset, at: t0), now: t0).count, 1)

    // Reset jitter inside the same window does not re-fire.
    let jittered = firstReset.addingTimeInterval(20)
    XCTAssertTrue(run.step(reading(9, resetAt: jittered, at: t0 + 900), now: t0 + 900).isEmpty)

    // After the window it fired in has ended, a still-low rolling window alerts again.
    let later = firstReset.addingTimeInterval(60)
    let events = run.step(reading(10, resetAt: later.addingTimeInterval(hour), at: later), now: later)
    XCTAssertEqual(events.map(\.threshold), [20])
  }

  func testReadingOfAnEndedWindowDoesNotFire() {
    var run = Run()
    XCTAssertTrue(run.step(reading(3, resetAt: t0 - 60, at: t0), now: t0).isEmpty)
  }

  func testUnlimitedAndAmountOnlyMetricsNeverAlert() {
    var run = Run()
    let current = snapshot([usage([
      // Would be a threshold and an expiringUnused alert if it were a quota.
      metric("plan", label: "Weekly plan", remaining: 0, resetAt: t0 + 2 * hour, unlimited: true),
      metric("plan-left", label: "Weekly plan", remaining: 90, resetAt: t0 + 2 * hour, unlimited: true),
      metric("usd", label: "Monthly USD balance", remaining: nil, resetAt: t0 + hour),
      // A live control, so the silence above is meaningful.
      metric("control", label: "5-hour limit", remaining: 10, resetAt: t0 + hour)
    ], at: t0)], at: t0)

    XCTAssertEqual(run.step(current, now: t0).map(\.metricID), ["control"])
  }

  func testEstimatedPercentagesAreMarked() {
    var run = Run()
    let current = snapshot([usage(
      title: "Venice",
      provider: .venice,
      [metric("daily-diem", label: "Daily DIEM remaining", remaining: 12, resetAt: t0 + 3 * hour, estimatedTotal: 100)],
      at: t0
    )], at: t0)

    let event = run.step(current, now: t0).first
    XCTAssertEqual(event?.isEstimated, true)
    XCTAssertEqual(event?.body(now: t0), "≈12% left (estimated), resets in 3h.")
  }

  func testCustomThresholds() {
    var run = Run(config: QuotaEventConfig(thresholds: [50, 10]))
    XCTAssertEqual(run.step(reading(45, at: t0), now: t0).map(\.threshold), [50])
    let critical = run.step(reading(10, at: t0 + 900), now: t0 + 900)
    XCTAssertEqual(critical.map(\.threshold), [10])
    XCTAssertEqual(critical.first?.severity, .critical)
  }

  func testConfigNormalizesThresholds() {
    XCTAssertEqual(QuotaEventConfig(thresholds: [5, 20, 20, 0, 100, -3]).thresholds, [20, 5])
    XCTAssertEqual(QuotaEventConfig.default.thresholds, [20, 5])
    XCTAssertEqual(QuotaEventConfig(thresholds: [150]).thresholds, [])
  }

  func testUnsortedThresholdsStillAlertForTheLowest() {
    var run = Run(config: QuotaEventConfig(thresholds: [5, 20]))
    let events = run.step(reading(3, at: t0), now: t0)
    XCTAssertEqual(events.map(\.threshold), [5])
    XCTAssertEqual(events.first?.severity, .critical)
  }

  func testAccountsAndMetricsAreTrackedIndependently() {
    var run = Run()
    let reset = t0 + 4 * hour
    let first = snapshot([
      usage(account: "a", title: "A", [metric(remaining: 18, resetAt: reset), metric("seven_day", label: "7-day limit", remaining: 60)], at: t0),
      usage(account: "b", title: "B", [metric(remaining: 18, resetAt: reset)], at: t0)
    ], at: t0)

    let events = run.step(first, now: t0)
    XCTAssertEqual(events.map(\.accountID).sorted(), ["a", "b"])

    let second = snapshot([
      usage(account: "a", title: "A", [metric(remaining: 17, resetAt: reset), metric("seven_day", label: "7-day limit", remaining: 15)], at: t0 + 900),
      usage(account: "b", title: "B", [metric(remaining: 16, resetAt: reset)], at: t0 + 900)
    ], at: t0 + 900)
    let more = run.step(second, now: t0 + 900)
    XCTAssertEqual(more.map(\.accountID), ["a"])
    XCTAssertEqual(more.map(\.metricID), ["seven_day"])
  }

  func testCarriedUsageOfFailingAccountNeitherFiresNorRearms() {
    var run = Run()
    let reset = t0 + hour
    XCTAssertEqual(run.step(reading(18, resetAt: reset, at: t0), now: t0).count, 1)

    // The fetch fails; the snapshot carries the old usage (even with its window
    // over) plus the failure. Nothing about the quota is known to have changed.
    let failing = snapshot(
      [usage([metric(remaining: 3, resetAt: reset)], at: t0)],
      failures: [ProviderFailure(accountID: "acct-1", provider: .anthropic, kind: .network, message: "offline")],
      at: t0 + 2 * hour
    )
    XCTAssertTrue(run.step(failing, now: t0 + 2 * hour).isEmpty)
    XCTAssertEqual(run.state.thresholdLatches.count, 1)
  }

  func testCarriedUsageInAnOpenWindowIsNotANewCrossing() {
    var run = Run()
    let reset = t0 + 3 * hour
    XCTAssertEqual(run.step(reading(18, resetAt: reset, at: t0), now: t0).count, 1)

    // The window is still open, so only the failure keeps this quiet.
    let failing = snapshot(
      [usage([metric(remaining: 3, resetAt: reset)], at: t0)],
      failures: [ProviderFailure(accountID: "acct-1", provider: .anthropic, kind: .network, message: "offline")],
      at: t0 + hour
    )
    XCTAssertTrue(run.step(failing, now: t0 + hour).isEmpty)
  }

  func testMetricMissingForOneRefreshKeepsItsLatch() {
    var run = Run()
    XCTAssertEqual(run.step(reading(10, at: t0, id: "m"), now: t0).count, 1)

    // The provider omits the metric once, then reports it again, still low.
    XCTAssertTrue(run.step(reading(80, at: t0 + 900, id: "other"), now: t0 + 900).isEmpty)
    XCTAssertTrue(run.step(reading(10, at: t0 + 1_800, id: "m"), now: t0 + 1_800).isEmpty)
  }

  func testMetricMissingForTwoRefreshesIsForgotten() {
    var run = Run()
    _ = run.step(reading(10, at: t0, id: "old"), now: t0)
    _ = run.step(reading(80, at: t0 + 900, id: "new"), now: t0 + 900)
    _ = run.step(reading(80, at: t0 + 1_800, id: "new"), now: t0 + 1_800)
    XCTAssertTrue(run.state.thresholdLatches.isEmpty)
    XCTAssertEqual(run.step(reading(10, at: t0 + 2_700, id: "old"), now: t0 + 2_700).count, 1)
  }

  // MARK: - Resets

  func testResetAfterLowWindowFires() {
    var run = Run()
    let firstReset = t0 + hour
    _ = run.step(reading(3, resetAt: firstReset, at: t0), now: t0)

    let afterReset = firstReset + 120
    let nextReset = afterReset + 5 * hour
    let events = run.step(reading(100, resetAt: nextReset, at: afterReset), now: afterReset)

    XCTAssertEqual(events.map(\.kind), [.reset])
    XCTAssertEqual(events.first?.remainingPercent, 100)
    XCTAssertEqual(events.first?.resetAt, nextReset)
    XCTAssertEqual(events.first?.severity, .normal)

    // The thresholds re-armed: the next low reading alerts again.
    let low = afterReset + hour
    XCTAssertEqual(run.step(reading(15, resetAt: nextReset, at: low), now: low).map(\.kind), [.threshold])
  }

  func testRoutineResetOfLightlyUsedWindowIsSilent() {
    var run = Run()
    let firstReset = t0 + hour
    _ = run.step(reading(60, resetAt: firstReset, at: t0), now: t0)

    let afterReset = firstReset + 60
    XCTAssertTrue(run.step(reading(100, resetAt: afterReset + 5 * hour, at: afterReset), now: afterReset).isEmpty)
  }

  func testRiseBeforeResetTimeIsNotAReset() {
    var run = Run()
    let reset = t0 + 2 * hour
    _ = run.step(reading(10, resetAt: reset, at: t0), now: t0)

    // A provider correction inside the window.
    let events = run.step(reading(40, resetAt: reset, at: t0 + 900), now: t0 + 900)
    XCTAssertFalse(events.contains { $0.kind == .reset })
  }

  func testResetNeedsARiseBeyondJitter() {
    var run = Run()
    let reset = t0 + hour
    _ = run.step(reading(10, resetAt: reset, at: t0), now: t0)

    let after = reset + 60
    let events = run.step(reading(12, resetAt: after + hour, at: after), now: after)
    XCTAssertFalse(events.contains { $0.kind == .reset })
  }

  func testResetIsNotRepeatedWithinTheWindowItOpened() {
    var run = Run()
    let firstReset = t0 + hour
    _ = run.step(reading(3, resetAt: firstReset, at: t0), now: t0)
    let afterReset = firstReset + 60
    let nextReset = afterReset + 5 * hour
    XCTAssertEqual(run.step(reading(100, resetAt: nextReset, at: afterReset), now: afterReset).map(\.kind), [.reset])

    // A provider glitch two hours later: one low reading whose window "ends" a
    // minute later, then the real numbers again. The window the reset opened
    // is still running, so this is not a second reset.
    let glitch = afterReset + 2 * hour
    _ = run.step(reading(10, resetAt: glitch + 60, at: glitch), now: glitch)
    let recovered = glitch + 900
    let events = run.step(reading(100, resetAt: nextReset, at: recovered), now: recovered)
    XCTAssertFalse(events.contains { $0.kind == .reset })
  }

  func testEachLowWindowAnnouncesItsOwnReset() {
    var run = Run()
    let firstReset = t0 + hour
    _ = run.step(reading(3, resetAt: firstReset, at: t0), now: t0)
    let second = firstReset + 60
    let nextReset = second + 5 * hour
    XCTAssertEqual(run.step(reading(100, resetAt: nextReset, at: second), now: second).map(\.kind), [.reset])

    let low = nextReset - hour
    _ = run.step(reading(4, resetAt: nextReset, at: low), now: low)
    let third = nextReset + 60
    XCTAssertEqual(run.step(reading(100, resetAt: third + 5 * hour, at: third), now: third).map(\.kind), [.reset])
  }

  func testResetIsAnnouncedOnceWhenThePreviousSnapshotRepeats() {
    // A failed snapshot save means the daemon compares against the same
    // previous snapshot again; the persisted mark keeps the reset single.
    let previous = reading(3, resetAt: t0 + hour, at: t0)
    let after = t0 + hour + 60
    let current = reading(100, resetAt: after + 5 * hour, at: after)

    let first = QuotaEvents.detect(previous: previous, current: current, now: after, state: QuotaEventState())
    XCTAssertEqual(first.events.map(\.kind), [.reset])

    let again = QuotaEvents.detect(previous: previous, current: current, now: after + 900, state: first.state)
    XCTAssertTrue(again.events.isEmpty)
  }

  // MARK: - Failures

  func testAuthFailureAlertsOnceAndRecovers() {
    var run = Run()
    _ = run.step(reading(80, at: t0), now: t0)

    let failure = ProviderFailure(accountID: "acct-1", provider: .anthropic, kind: .auth, message: "401 token sk-ant-secret rejected")
    let failing = snapshot([usage([metric(remaining: 80)], at: t0)], failures: [failure], at: t0 + 900)

    let events = run.step(failing, now: t0 + 900)
    XCTAssertEqual(events.map(\.kind), [.failure])
    XCTAssertEqual(events.first?.failureKind, .auth)
    XCTAssertEqual(events.first?.severity, .critical)
    XCTAssertEqual(events.first?.accountName, "Claude Work")
    XCTAssertNil(events.first?.metricID)
    // The provider's message never reaches the event or its copy.
    let text = "\(events)" + (events.first.map { $0.title + $0.body(now: t0) } ?? "")
    XCTAssertFalse(text.contains("sk-ant-secret"))

    XCTAssertTrue(run.step(failing, now: t0 + 1_800).isEmpty)

    let recovered = run.step(reading(79, at: t0 + 2_700), now: t0 + 2_700)
    XCTAssertEqual(recovered.map(\.kind), [.recovered])
    XCTAssertEqual(recovered.first?.failureKind, .auth)
    XCTAssertTrue(run.step(reading(78, at: t0 + 3_600), now: t0 + 3_600).isEmpty)
  }

  func testDecodingFailureAlerts() {
    var run = Run()
    let failing = snapshot([], failures: [ProviderFailure(accountID: "acct-1", provider: .kimi, kind: .decoding, message: "bad json")], at: t0)

    let events = run.step(failing, now: t0)
    XCTAssertEqual(events.map(\.failureKind), [.decoding])
    // No usage to borrow a name from: the provider name stands in.
    XCTAssertEqual(events.first?.accountName, "Kimi")
  }

  func testFailureUsesTheConfiguredAccountName() {
    let failing = snapshot([], failures: [ProviderFailure(accountID: "acct-1", provider: .kimi, kind: .auth, message: "x")], at: t0)

    let detection = QuotaEvents.detect(previous: nil, current: failing, now: t0, state: QuotaEventState(), accountNames: ["acct-1": "Kimi Work"])

    XCTAssertEqual(detection.events.first?.accountName, "Kimi Work")
  }

  func testTransientFailuresDoNotAlert() {
    for kind in [QuotaErrorKind.network, .rateLimit, .api, .unknown] {
      var run = Run()
      let failing = snapshot([], failures: [ProviderFailure(accountID: "acct-1", provider: .openAI, kind: kind, message: "x")], at: t0)
      XCTAssertTrue(run.step(failing, now: t0).isEmpty, "\(kind)")
    }
  }

  func testAuthFailureTurningIntoNetworkErrorIsNotARecovery() {
    var run = Run()
    let auth = snapshot([], failures: [ProviderFailure(accountID: "acct-1", provider: .openAI, kind: .auth, message: "x")], at: t0)
    let network = snapshot([], failures: [ProviderFailure(accountID: "acct-1", provider: .openAI, kind: .network, message: "x")], at: t0 + 900)

    XCTAssertEqual(run.step(auth, now: t0).count, 1)
    XCTAssertTrue(run.step(network, now: t0 + 900).isEmpty)
    XCTAssertTrue(run.step(auth, now: t0 + 1_800).isEmpty)
    XCTAssertEqual(run.step(reading(90, at: t0 + 2_700), now: t0 + 2_700).map(\.kind), [.recovered])
  }

  func testAccountMissingForOneRefreshKeepsItsAlerts() {
    var run = Run()
    let failing = snapshot([], failures: [ProviderFailure(accountID: "acct-1", provider: .openAI, kind: .auth, message: "x")], at: t0)
    XCTAssertEqual(run.step(failing, now: t0).count, 1)

    let other = snapshot([usage(account: "acct-2", [metric(remaining: 90)], at: t0 + 900)], at: t0 + 900)
    XCTAssertTrue(run.step(other, now: t0 + 900).isEmpty)
    XCTAssertTrue(run.step(failing, now: t0 + 1_800).isEmpty)
  }

  func testRemovedAccountIsForgottenWithoutARecovery() {
    var run = Run()
    let failing = snapshot([], failures: [ProviderFailure(accountID: "acct-1", provider: .openAI, kind: .auth, message: "x")], at: t0)
    XCTAssertEqual(run.step(failing, now: t0).count, 1)

    // Absent from two snapshots in a row (the daemon also drops disabled and
    // removed accounts from the saved snapshot): forgotten, silently.
    let other = snapshot([usage(account: "acct-2", [metric(remaining: 90)], at: t0 + 900)], at: t0 + 900)
    XCTAssertTrue(run.step(other, now: t0 + 900).isEmpty)
    XCTAssertTrue(run.step(other, now: t0 + 1_800).isEmpty)
    XCTAssertEqual(run.state, QuotaEventState())

    // Re-enabled while still broken: it alerts again.
    let reenabled = snapshot([], failures: failing.failures, at: t0 + 2_700)
    XCTAssertEqual(run.step(reenabled, now: t0 + 2_700).map(\.kind), [.failure])
  }

  func testFailureLatchFollowsTheLatestKind() {
    var run = Run()
    let auth = snapshot([], failures: [ProviderFailure(accountID: "acct-1", provider: .kimi, kind: .auth, message: "x")], at: t0)
    let decoding = snapshot([], failures: [ProviderFailure(accountID: "acct-1", provider: .kimi, kind: .decoding, message: "x")], at: t0 + 900)

    XCTAssertEqual(run.step(auth, now: t0).map(\.failureKind), [.auth])
    XCTAssertTrue(run.step(decoding, now: t0 + 900).isEmpty)

    let recovered = run.step(reading(90, at: t0 + 1_800), now: t0 + 1_800)
    XCTAssertEqual(recovered.map(\.kind), [.recovered])
    XCTAssertEqual(recovered.first?.failureKind, .decoding)
  }

  // MARK: - Use it or lose it

  func testExpiringUnusedFiresOncePerWindow() {
    var run = Run()
    let weeklyReset = t0 + 9 * hour
    let weekly = { (remaining: Int, reset: Date, at: Date) in
      self.reading(remaining, resetAt: reset, at: at, id: "seven_day", label: "7-day limit")
    }

    // More than a day out: nothing yet.
    XCTAssertTrue(run.step(weekly(70, weeklyReset, t0 - day), now: t0 - day).isEmpty)

    let events = run.step(weekly(62, weeklyReset, t0), now: t0)
    XCTAssertEqual(events.map(\.kind), [.expiringUnused])
    XCTAssertEqual(events.first?.title, "Claude Work: 7-day limit mostly unused")
    XCTAssertEqual(events.first?.body(now: t0), "62% unused, resets in 9h.")

    // Same window, reset time jittering by seconds: no repeat.
    XCTAssertTrue(run.step(weekly(61, weeklyReset + 3, t0 + hour), now: t0 + hour).isEmpty)

    // Next week's window gets its own nudge.
    let nextReset = weeklyReset + 7 * day
    XCTAssertTrue(run.step(weekly(100, nextReset, weeklyReset + 60), now: weeklyReset + 60).isEmpty)
    let nextNudge = nextReset - 12 * hour
    XCTAssertEqual(run.step(weekly(80, nextReset, nextNudge), now: nextNudge).map(\.kind), [.expiringUnused])
  }

  func testExpiringUnusedIgnoresAResetShiftWithinTheOngoingWindow() {
    var run = Run()
    let reset = t0 + 9 * hour
    let first = run.step(reading(62, resetAt: reset, at: t0, id: "seven_day", label: "7-day limit"), now: t0)
    XCTAssertEqual(first.map(\.kind), [.expiringUnused])

    // The provider moves the same window's reset by three hours, beyond the jitter tolerance.
    let later = t0 + hour
    XCTAssertTrue(run.step(reading(60, resetAt: reset + 3 * hour, at: later, id: "seven_day", label: "7-day limit"), now: later).isEmpty)
  }

  func testExpiringUnusedFiltersByKindAndThresholds() {
    func events(id: String, label: String, remaining: Int, resetIn: TimeInterval) -> [QuotaEventKind] {
      var run = Run()
      return run.step(reading(remaining, resetAt: t0 + resetIn, at: t0, id: id, label: label), now: t0).map(\.kind)
    }

    XCTAssertEqual(events(id: "seven_day", label: "7-day limit", remaining: 50, resetIn: 24 * hour), [.expiringUnused])
    XCTAssertEqual(events(id: "monthly", label: "Monthly limit", remaining: 90, resetIn: hour), [.expiringUnused])
    XCTAssertEqual(events(id: "premium", label: "Premium requests", remaining: 75, resetIn: 2 * hour), [.expiringUnused])
    XCTAssertEqual(events(id: "seven_day", label: "7-day limit", remaining: 49, resetIn: hour), [])
    XCTAssertEqual(events(id: "seven_day", label: "7-day limit", remaining: 90, resetIn: 24 * hour + 60), [])
    XCTAssertEqual(events(id: "five_hour", label: "5-hour limit", remaining: 90, resetIn: hour), [])
    XCTAssertEqual(events(id: "daily", label: "Daily limit", remaining: 90, resetIn: hour), [])
  }

  func testExpiringUnusedHonorsConfig() {
    var config = QuotaEventConfig.default
    config.expiringUnusedLeadTime = 2 * day
    config.expiringUnusedMinimumRemaining = 30
    var run = Run(config: config)

    let events = run.step(reading(35, resetAt: t0 + 40 * hour, at: t0, id: "seven_day", label: "7-day limit"), now: t0)
    XCTAssertEqual(events.map(\.kind), [.expiringUnused])
  }

  // MARK: - Persistence

  func testRepeatedSourceCannotRearmWhenOnlyTheClockPassedReset() {
    let current = reading(10, resetAt: t0 + hour, at: t0)
    let first = QuotaEvents.detect(previous: nil, current: current, now: t0, state: QuotaEventState())
    let later = QuotaEvents.detect(previous: current, current: current, now: t0 + 2 * hour, state: first.state)

    XCTAssertTrue(later.events.isEmpty)
    XCTAssertEqual(later.state, first.state, "a timer is not a fresh observation of a new window")
  }

  func testStaleSourceCannotAlertOrClearFailure() {
    let stale = snapshot([usage([metric(remaining: 3)], at: t0)], at: t0 + 900)
    let initial = QuotaEvents.detect(previous: nil, current: stale, now: t0 + 900, state: QuotaEventState())
    XCTAssertTrue(initial.events.isEmpty)

    let failing = snapshot([], failures: [ProviderFailure(
      accountID: "acct-1", provider: .anthropic, kind: .auth, message: "private response")], at: t0)
    let failure = QuotaEvents.detect(previous: nil, current: failing, now: t0, state: QuotaEventState())
    let later = QuotaEvents.detect(previous: failing, current: stale, now: t0 + 900, state: failure.state)
    XCTAssertTrue(later.events.isEmpty)
    XCTAssertEqual(later.state, failure.state)
  }

  func testExpiredMetricWithCorrectedPercentIsNotAnObservedReset() {
    var run = Run()
    let endedAt = t0 + hour
    _ = run.step(reading(3, resetAt: endedAt, at: t0), now: t0)
    let later = endedAt + 60
    XCTAssertTrue(run.step(reading(100, resetAt: endedAt, at: later), now: later).isEmpty)
  }

  func testOlderSnapshotCannotIntroduceAFailure() {
    let previous = reading(80, at: t0 + 900)
    let older = snapshot([], failures: [ProviderFailure(
      accountID: "acct-1", provider: .anthropic, kind: .auth, message: "old response")], at: t0)
    let detection = QuotaEvents.detect(previous: previous, current: older, now: t0 + 900, state: QuotaEventState())
    XCTAssertTrue(detection.events.isEmpty)
    XCTAssertEqual(detection.state, QuotaEventState())
  }

  func testDedupeSurvivesAStateRoundTrip() throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let reset = t0.addingTimeInterval(9 * hour + 0.75)
    let current = snapshot([
      usage([metric(remaining: 4, resetAt: t0 + 0.5 + hour), metric("seven_day", label: "7-day limit", remaining: 80, resetAt: reset)], at: t0)
    ], failures: [], at: t0)
    let failing = snapshot([], failures: [ProviderFailure(accountID: "acct-2", provider: .openAI, kind: .auth, message: "x")], at: t0)
    let combined = snapshot(current.providers, failures: failing.failures, at: t0)

    let first = QuotaEvents.detect(previous: nil, current: combined, now: t0, state: QuotaEventState())
    XCTAssertEqual(Set(first.events.map(\.kind)), Set<QuotaEventKind>([.threshold, .expiringUnused, .failure]))

    // A daemon restart: the state comes back from JSON with whole-second dates.
    let restored = try decoder.decode(QuotaEventState.self, from: encoder.encode(first.state))
    XCTAssertNotEqual(restored, first.state, "the round trip should drop sub-second precision")
    let second = QuotaEvents.detect(previous: combined, current: combined, now: t0 + 900, state: restored)
    XCTAssertTrue(second.events.isEmpty)
  }

  func testUnknownOrMissingStateKeysDecodeAsEmpty() throws {
    let state = try JSONDecoder().decode(QuotaEventState.self, from: Data(#"{"future":1}"#.utf8))
    XCTAssertEqual(state, QuotaEventState())
  }

  func testStateEntriesTolerateMissingOptionalAndUnknownKeys() throws {
    // Synthesized Codable already decodes optionals with decodeIfPresent and
    // ignores keys it does not know, so entries stay readable across versions.
    let json = #"{"thresholdLatches":[{"accountID":"a","metricID":"m","threshold":20,"addedLater":true}],"#
      + #""resetMarks":[{"accountID":"a","metricID":"m","endedAt":0}]}"#
    let state = try JSONDecoder().decode(QuotaEventState.self, from: Data(json.utf8))

    XCTAssertEqual(state.thresholdLatches, [.init(accountID: "a", metricID: "m", threshold: 20, resetAt: nil)])
    XCTAssertEqual(state.resetMarks.first?.nextResetAt, nil)
  }

  // MARK: - Copy

  func testCopyNamesTheAccountMetricAndReset() {
    var event = QuotaEvent(
      kind: .threshold,
      severity: .critical,
      accountID: "a",
      accountName: "Claude Work",
      provider: .anthropic,
      metricID: "five_hour",
      metricLabel: "5-hour limit",
      remainingPercent: 4,
      threshold: 5,
      resetAt: t0 + 2 * hour + 600
    )
    XCTAssertEqual(event.title, "Claude Work: 5-hour limit low")
    XCTAssertEqual(event.body(now: t0), "4% left, resets in 2h 10m.")
    // A reset time that has passed by delivery is left out rather than shown as "resets in reset".
    XCTAssertEqual(event.body(now: t0 + 3 * hour), "4% left.")

    event.kind = .reset
    event.remainingPercent = 100
    XCTAssertEqual(event.title, "Claude Work: 5-hour limit reset")
    XCTAssertEqual(event.body(now: t0), "100% left again, resets in 2h 10m.")

    let failure = QuotaEvent(kind: .failure, severity: .critical, accountID: "a", accountName: "ChatGPT", provider: .openAI, failureKind: .auth)
    XCTAssertEqual(failure.title, "ChatGPT: sign-in needed")
    XCTAssertEqual(failure.body(now: t0), "Authentication failed. Reconnect or replace this account's credentials.")

    var recovered = failure
    recovered.kind = .recovered
    XCTAssertEqual(recovered.title, "ChatGPT: refreshing again")
    XCTAssertEqual(recovered.body(now: t0), "Usage is updating again.")
  }
}
