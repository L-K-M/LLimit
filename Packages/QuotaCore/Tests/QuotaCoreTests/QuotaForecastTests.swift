import XCTest
@testable import QuotaCore

final class QuotaForecastTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private let minute: TimeInterval = 60
  private let hour: TimeInterval = 3_600
  private let day: TimeInterval = 86_400
  private static let refreshInterval: TimeInterval = 30 * 60
  private var refreshInterval: TimeInterval { Self.refreshInterval }
  private let weekly = (id: "secondary", label: "7-day limit")

  // MARK: - Regressions from the trend widget's old forecast

  func testRetiredMetricGivesNoWarning() {
    // `secondary` drained to 58% two days ago and then left the response;
    // the live weekly window now reads 66% under `primary`.
    let resetAt = now.addingTimeInterval(5 * day)
    let retired = timeline(from: now.addingTimeInterval(-2.5 * day), to: now.addingTimeInterval(-2 * day)) { date in
      let progress = date.timeIntervalSince(self.now.addingTimeInterval(-2.5 * self.day)) / (0.5 * self.day)
      return [self.usage("lukas", at: date, metrics: [
        self.metric(self.weekly.id, self.weekly.label, remaining: 80 - 22 * progress, resetAt: resetAt)
      ])]
    }
    let live = timeline(from: now.addingTimeInterval(-2 * day + refreshInterval), to: now) { date in
      [self.usage("lukas", at: date, metrics: [self.metric("primary", "7-day limit", remaining: 66, resetAt: resetAt)])]
    }
    let history = retired + live

    let warnings = warnings(for: [("lukas", "primary"), ("lukas", weekly.id)], history: history)

    XCTAssertEqual(warnings, [])
  }

  func testStaleLatestSampleGivesNoWarning() {
    // Sustained overpace, but LLimit stopped refreshing three days ago.
    let resetAt = now.addingTimeInterval(2 * day)
    let windowStart = now.addingTimeInterval(-5 * day)
    let history = timeline(from: windowStart, to: now.addingTimeInterval(-3 * day)) { date in
      let elapsedDays = date.timeIntervalSince(windowStart) / self.day
      return [self.usage("acct", at: date, metrics: [
        self.metric(self.weekly.id, self.weekly.label, remaining: 100 - 25 * elapsedDays, resetAt: resetAt)
      ])]
    }

    XCTAssertEqual(warnings(for: [("acct", weekly.id)], history: history), [])
  }

  func testCurrentFailureGivesNoWarning() {
    var history = overpacedWeek(account: "acct", usedPercentPerDay: 21)
    let last = history.removeLast()
    // The latest cycle failed and carried the previous usage forward.
    history.append(QuotaSnapshot(
      generatedAt: last.generatedAt,
      providers: last.providers,
      failures: [ProviderFailure(accountID: "acct", provider: .openAI, kind: .network, message: "offline")]
    ))

    XCTAssertEqual(warnings(for: [("acct", weekly.id)], history: history), [])
  }

  func testShortBurstInsideHealthyWeekGivesNoWarning() {
    // 39 points over four days, then 6 points in the last five hours.
    let windowStart = now.addingTimeInterval(-4 * day)
    let burstStart = now.addingTimeInterval(-5 * hour)
    let resetAt = now.addingTimeInterval(3 * day)
    let history = timeline(from: windowStart, to: now) { date in
      let remaining: Double
      if date <= burstStart {
        remaining = 100 - 39 * date.timeIntervalSince(windowStart) / burstStart.timeIntervalSince(windowStart)
      } else {
        remaining = 61 - 6 * date.timeIntervalSince(burstStart) / (5 * self.hour)
      }
      return [self.usage("acct", at: date, metrics: [
        self.metric(self.weekly.id, self.weekly.label, remaining: remaining, resetAt: resetAt)
      ])]
    }

    XCTAssertEqual(warnings(for: [("acct", weekly.id)], history: history), [])
  }

  func testSustainedOverpaceWarnsWithDepletionAndReset() throws {
    // 42 points in two days of a seven-day window: 58% left lasts about 2.76 days.
    let history = overpacedWeek(account: "acct", usedPercentPerDay: 21)

    let warning = try XCTUnwrap(warnings(for: [("acct", weekly.id)], history: history).first)

    XCTAssertEqual(warning.accountID, "acct")
    XCTAssertEqual(warning.metricID, weekly.id)
    XCTAssertEqual(warning.metricLabel, weekly.label)
    XCTAssertEqual(warning.resetAt, now.addingTimeInterval(5 * day))
    XCTAssertEqual(warning.depletionAt.timeIntervalSince(now), 58.0 / 21.0 * day, accuracy: hour)
  }

  func testJustAfterResetGivesNoWarning() {
    // A daily window refilled two hours ago and has been used hard since.
    // Two hours is too little of a day to extrapolate from.
    let resetMoment = now.addingTimeInterval(-2 * hour)
    let previousStart = now.addingTimeInterval(-26 * hour)
    let quarterHour = 15 * minute
    let previous = timeline(from: previousStart, to: resetMoment.addingTimeInterval(-quarterHour), every: quarterHour) { date in
      let progress = date.timeIntervalSince(previousStart) / (24 * self.hour)
      return [self.usage("acct", at: date, metrics: [
        self.metric("quota-daily", "Daily quota", remaining: 100 - 95 * progress, resetAt: resetMoment)
      ])]
    }
    let current = timeline(from: resetMoment, to: now, every: quarterHour) { date in
      let progress = date.timeIntervalSince(resetMoment) / (2 * self.hour)
      return [self.usage("acct", at: date, metrics: [
        self.metric("quota-daily", "Daily quota", remaining: 100 - 45 * progress, resetAt: resetMoment.addingTimeInterval(self.day))
      ])]
    }

    let warnings = QuotaForecast.depletionWarnings(
      for: [QuotaForecast.SeriesKey(accountID: "acct", metricID: "quota-daily")],
      history: previous + current,
      latest: current.last,
      now: now,
      refreshInterval: quarterHour
    )

    XCTAssertEqual(warnings, [])
  }

  func testWarningsAreOrderedByEarliestDepletion() {
    let slow = overpacedWeek(account: "slow", usedPercentPerDay: 21)
    let fast = overpacedWeek(account: "fast", usedPercentPerDay: 35)
    let history = zip(slow, fast).map { slowSnapshot, fastSnapshot in
      QuotaSnapshot(
        generatedAt: slowSnapshot.generatedAt,
        providers: slowSnapshot.providers + fastSnapshot.providers,
        failures: []
      )
    }

    let warnings = warnings(for: [("slow", weekly.id), ("fast", weekly.id)], history: history)

    XCTAssertEqual(warnings.map(\.accountID), ["fast", "slow"])
  }

  func testDepletionAlreadyInThePastGivesNoWarning() {
    // The last fetch (50 minutes ago, still fresh) read 1%, and that 1%
    // was projected to last about half an hour.
    let lastFetch = now.addingTimeInterval(-50 * minute)
    let windowStart = lastFetch.addingTimeInterval(-2 * day)
    let history = timeline(from: windowStart, to: lastFetch) { date in
      let elapsedDays = date.timeIntervalSince(windowStart) / self.day
      return [self.usage("acct", at: date, metrics: [
        self.metric(self.weekly.id, self.weekly.label, remaining: 100 - 49.5 * elapsedDays, resetAt: self.now.addingTimeInterval(5 * self.day))
      ])]
    }

    XCTAssertEqual(warnings(for: [("acct", weekly.id)], history: history), [])
  }

  func testResetMustComeFromTheLatestSnapshot() {
    var history = overpacedWeek(account: "acct", usedPercentPerDay: 21)
    let last = history.removeLast()
    let withoutReset = last.providers.map { usage -> ProviderUsage in
      var usage = usage
      usage.metrics = usage.metrics.map { metric in
        var metric = metric
        metric.resetAt = nil
        return metric
      }
      return usage
    }
    history.append(QuotaSnapshot(generatedAt: last.generatedAt, providers: withoutReset, failures: []))

    XCTAssertEqual(warnings(for: [("acct", weekly.id)], history: history), [])
  }

  func testTooFewRawSamplesGiveNoWarning() {
    let resetAt = now.addingTimeInterval(5 * day)
    let history = [(-2.0, 100.0), (-1.0, 79.0), (0.0, 58.0)].map { offsetDays, remaining in
      let date = now.addingTimeInterval(offsetDays * day)
      return snapshot(at: date, [usage("acct", at: date, metrics: [
        metric(weekly.id, weekly.label, remaining: remaining, resetAt: resetAt)
      ])])
    }

    XCTAssertEqual(warnings(for: [("acct", weekly.id)], history: history), [])
  }

  func testWindowWithoutAKnownCadenceGetsNoForecast() {
    // Per-model quotas name no window, so no minimum span can be judged.
    let history = overpacedWeek(account: "acct", usedPercentPerDay: 21, metricID: "gemini-3-pro-high", label: "Gemini 3 Pro")

    let warnings = QuotaForecast.depletionWarnings(
      for: [QuotaForecast.SeriesKey(accountID: "acct", metricID: "gemini-3-pro-high")],
      history: history,
      latest: history.last,
      now: now,
      refreshInterval: refreshInterval
    )

    XCTAssertEqual(warnings, [])
  }

  func testNonPositiveRefreshIntervalStillAcceptsRecentData() {
    // Fetched ten minutes ago: fresh for any refresh interval LLimit allows.
    var history = overpacedWeek(account: "acct", usedPercentPerDay: 21)
    let last = history.removeLast()
    let tenMinutesAgo = now.addingTimeInterval(-10 * minute)
    history.append(QuotaSnapshot(
      generatedAt: last.generatedAt,
      providers: last.providers.map { usage in
        var usage = usage
        usage.fetchedAt = tenMinutesAgo
        return usage
      },
      failures: []
    ))

    for interval in [0, -60] as [TimeInterval] {
      let warnings = QuotaForecast.depletionWarnings(
        for: [QuotaForecast.SeriesKey(accountID: "acct", metricID: weekly.id)],
        history: history,
        latest: history.last,
        now: now,
        refreshInterval: interval
      )
      XCTAssertEqual(warnings.map(\.accountID), ["acct"], "refresh interval \(interval)")
    }
  }

  func testLateSurgeAtLowRemainingWarns() throws {
    // Six quiet days left 30%, then the last three hours burned 10 more.
    // The window average (about 13% a day) would last past tomorrow's
    // reset; the recent pace empties the window within hours.
    let windowStart = now.addingTimeInterval(-6 * day)
    let surgeStart = now.addingTimeInterval(-3 * hour)
    let resetAt = now.addingTimeInterval(day)
    let history = timeline(from: windowStart, to: now) { date in
      let remaining: Double
      if date <= surgeStart {
        remaining = 100 - 70 * date.timeIntervalSince(windowStart) / surgeStart.timeIntervalSince(windowStart)
      } else {
        remaining = 30 - 10 * date.timeIntervalSince(surgeStart) / (3 * self.hour)
      }
      return [self.usage("acct", at: date, metrics: [
        self.metric(self.weekly.id, self.weekly.label, remaining: remaining, resetAt: resetAt)
      ])]
    }

    let warning = try XCTUnwrap(warnings(for: [("acct", weekly.id)], history: history).first)

    XCTAssertLessThan(warning.depletionAt.timeIntervalSince(now), 12 * hour)
  }

  func testLateSurgeAboveTheLowThresholdStaysSilent() {
    // The same surge with half the window left is a burst, not a crisis.
    let windowStart = now.addingTimeInterval(-6 * day)
    let surgeStart = now.addingTimeInterval(-3 * hour)
    let history = timeline(from: windowStart, to: now) { date in
      let remaining: Double
      if date <= surgeStart {
        remaining = 100 - 40 * date.timeIntervalSince(windowStart) / surgeStart.timeIntervalSince(windowStart)
      } else {
        remaining = 60 - 10 * date.timeIntervalSince(surgeStart) / (3 * self.hour)
      }
      return [self.usage("acct", at: date, metrics: [
        self.metric(self.weekly.id, self.weekly.label, remaining: remaining, resetAt: self.now.addingTimeInterval(self.day))
      ])]
    }

    XCTAssertEqual(warnings(for: [("acct", weekly.id)], history: history), [])
  }

  func testChartLineKeyMatchesForecastForBlankMetricID() throws {
    // A blank id falls back to the label on both sides.
    let history = overpacedWeek(account: "acct", usedPercentPerDay: 21, metricID: " ", label: "7-day limit")
    let settings = AppSettings(accounts: [ProviderAccount(id: "acct", provider: .openAI)])
    let content = TrendSeriesBuilder.build(snapshots: history, latest: history.last, settings: settings)
    let line = try XCTUnwrap(content.accounts.first?.series.first)

    let warnings = QuotaForecast.depletionWarnings(
      for: [QuotaForecast.SeriesKey(accountID: line.accountID, metricID: line.metricID)],
      history: history,
      latest: history.last,
      now: now,
      refreshInterval: refreshInterval
    )

    XCTAssertEqual(line.metricID, "7-day limit")
    XCTAssertEqual(warnings.map(\.metricID), ["7-day limit"])
  }

  // MARK: - Fixtures

  /// A seven-day window that reset two days ago and has been used steadily since.
  private func overpacedWeek(
    account: String,
    usedPercentPerDay: Double,
    metricID: String = "secondary",
    label: String = "7-day limit"
  ) -> [QuotaSnapshot] {
    let windowStart = now.addingTimeInterval(-2 * day)
    let resetAt = now.addingTimeInterval(5 * day)
    return timeline(from: windowStart, to: now) { date in
      let elapsedDays = date.timeIntervalSince(windowStart) / self.day
      return [self.usage(account, at: date, metrics: [
        self.metric(metricID, label, remaining: 100 - usedPercentPerDay * elapsedDays, resetAt: resetAt)
      ])]
    }
  }

  private func warnings(for keys: [(String, String)], history: [QuotaSnapshot]) -> [QuotaDepletionWarning] {
    QuotaForecast.depletionWarnings(
      for: keys.map { QuotaForecast.SeriesKey(accountID: $0.0, metricID: $0.1) },
      history: history,
      latest: history.last,
      now: now,
      refreshInterval: refreshInterval
    )
  }

  private func timeline(
    from start: Date,
    to end: Date,
    every step: TimeInterval = QuotaForecastTests.refreshInterval,
    _ usages: (Date) -> [ProviderUsage]
  ) -> [QuotaSnapshot] {
    stride(from: start.timeIntervalSince1970, through: end.timeIntervalSince1970, by: step).map { seconds in
      let date = Date(timeIntervalSince1970: seconds)
      return snapshot(at: date, usages(date))
    }
  }

  private func snapshot(at date: Date, _ usages: [ProviderUsage]) -> QuotaSnapshot {
    QuotaSnapshot(generatedAt: date, providers: usages, failures: [])
  }

  private func usage(_ accountID: String, at date: Date, metrics: [UsageMetric]) -> ProviderUsage {
    ProviderUsage(accountID: accountID, provider: .openAI, title: accountID, metrics: metrics, fetchedAt: date)
  }

  /// `remainingPercent` is an Int, so linear fixtures drop in whole-percent
  /// steps. Keep slope-derived assertions coarse (`accuracy: hour`, wide
  /// margins around now and the reset): a tight failure here is rounding.
  private func metric(_ id: String, _ label: String, remaining: Double, resetAt: Date?) -> UsageMetric {
    UsageMetric(id: id, label: label, remainingPercent: Int(remaining.rounded()), resetAt: resetAt)
  }
}
