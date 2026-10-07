import XCTest
@testable import QuotaCore

final class TrendChartTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private let hour: TimeInterval = 3_600

  // MARK: - Series

  func testWindowThatChangesSlotSplitsIntoTwoLines() throws {
    // `primary` was the 5-hour window and now carries the 7-day window.
    let settings = AppSettings(accounts: [account("o1", .openAI)])
    let before = snapshot(at: now.addingTimeInterval(-2 * hour), [usage("o1", .openAI, [
      UsageMetric(id: "primary", label: "5-hour limit", remainingPercent: 40),
      UsageMetric(id: "secondary", label: "7-day limit", remainingPercent: 70)
    ])])
    let after = snapshot(at: now, [usage("o1", .openAI, [
      UsageMetric(id: "primary", label: "7-day limit", remainingPercent: 66)
    ])])

    let content = TrendSeriesBuilder.build(snapshots: [before, after], latest: after, settings: settings)
    let series = try XCTUnwrap(content.accounts.first).series

    XCTAssertEqual(series.map(\.metricID), ["primary", "secondary", "primary"])
    XCTAssertEqual(series.map(\.slot.kind), [.session, .weekly, .weekly])
    XCTAssertEqual(series.map(\.isRetired), [true, true, false])
    XCTAssertEqual(series.map { $0.samples.map(\.remainingPercent) }, [[40], [70], [66]])
    XCTAssertEqual(Set(series.map(\.id)).count, 3)
    XCTAssertNil(content.emptyReason)

    var longTermOnly = settings
    longTermOnly.widgetVisibility.showShortTermLimitsInTrend = false
    let filtered = TrendSeriesBuilder.build(snapshots: [before, after], latest: after, settings: longTermOnly)

    XCTAssertEqual(try XCTUnwrap(filtered.accounts.first).series.map(\.slot.kind), [.weekly, .weekly])
  }

  func testRetiredLongWindowDoesNotHideALiveShortWindow() throws {
    var settings = AppSettings(accounts: [account("z1", .zai)])
    settings.widgetVisibility.showShortTermLimitsInTrend = false
    let before = snapshot(at: now.addingTimeInterval(-hour), [usage("z1", .zai, [
      UsageMetric(id: "tokens", label: "5-hour token limit", remainingPercent: 80),
      UsageMetric(id: "mcp", label: "MCP monthly quota", remainingPercent: 90)
    ])])
    let after = snapshot(at: now, [usage("z1", .zai, [
      UsageMetric(id: "tokens", label: "5-hour token limit", remainingPercent: 70)
    ])])

    let content = TrendSeriesBuilder.build(snapshots: [before, after], latest: after, settings: settings)

    XCTAssertEqual(try XCTUnwrap(content.accounts.first).series.map(\.metricID), ["tokens", "mcp"])
  }

  func testHidingShortTermLimitsKeepsAnAccountWhoseOnlyWindowIsShort() throws {
    // The short-term filter never empties an account, so it cannot be the
    // reason for an empty chart.
    var settings = AppSettings(accounts: [account("z1", .zai)])
    settings.widgetVisibility.showShortTermLimitsInTrend = false
    let latest = snapshot(at: now, [usage("z1", .zai, [
      UsageMetric(id: "tokens", label: "5-hour token limit", remainingPercent: 70)
    ])])

    let content = TrendSeriesBuilder.build(snapshots: [latest], latest: latest, settings: settings)

    XCTAssertNil(content.emptyReason)
    XCTAssertEqual(try XCTUnwrap(content.accounts.first).series.map(\.slot.kind), [.session])
  }

  func testSlotComesFromTheNewestUsage() throws {
    let settings = AppSettings(accounts: [account("g1", .googleAntigravity)])
    let latest = snapshot(at: now, [usage("g1", .googleAntigravity, [
      UsageMetric(id: "gemini-3-pro-high", label: "Gemini 3 Pro", remainingPercent: 50),
      UsageMetric(id: "gemini-3-flash", label: "Gemini 3 Flash", remainingPercent: 60)
    ])])

    let content = TrendSeriesBuilder.build(snapshots: [latest], latest: latest, settings: settings)
    let series = try XCTUnwrap(content.accounts.first).series

    XCTAssertEqual(series.map(\.slot), [LimitSeriesSlot(kind: .other, otherSlot: 0), LimitSeriesSlot(kind: .other, otherSlot: 1)])
    XCTAssertEqual(series.map(\.isRetired), [false, false])
  }

  // MARK: - Empty reasons

  func testEmptyReasonWithoutEnabledAccounts() {
    let disabled = AppSettings(accounts: [account("a1", .anthropic, isEnabled: false)])

    XCTAssertEqual(TrendSeriesBuilder.build(snapshots: [], latest: nil, settings: AppSettings()).emptyReason, .noAccounts)
    XCTAssertEqual(TrendSeriesBuilder.build(snapshots: [], latest: nil, settings: disabled).emptyReason, .noAccounts)
  }

  func testEmptyReasonWhenEveryAccountIsHidden() {
    let settings = AppSettings(
      accounts: [account("a1", .anthropic)],
      widgetVisibility: WidgetVisibilitySettings(trendHiddenAccountIDs: ["a1"])
    )
    let latest = snapshot(at: now, [usage("a1", .anthropic, [UsageMetric(id: "five_hour", label: "5-hour limit", remainingPercent: 50)])])

    XCTAssertEqual(TrendSeriesBuilder.build(snapshots: [latest], latest: latest, settings: settings).emptyReason, .allHidden)
  }

  func testEmptyReasonForUnlimitedOnly() {
    let settings = AppSettings(accounts: [account("c1", .gitHubCopilot)])
    let latest = snapshot(at: now, [usage("c1", .gitHubCopilot, [UsageMetric(id: "chat", label: "Chat", isUnlimited: true)])])

    XCTAssertEqual(TrendSeriesBuilder.build(snapshots: [latest], latest: latest, settings: settings).emptyReason, .onlyUnlimited)
  }

  func testEmptyReasonForBalancesOnly() {
    let settings = AppSettings(accounts: [account("v1", .venice), account("c1", .gitHubCopilot)])
    let latest = snapshot(at: now, [
      usage("v1", .venice, [UsageMetric(id: "usd", label: "USD balance", remainingAmount: 4.25, usedDisplay: "$4.25")]),
      usage("c1", .gitHubCopilot, [UsageMetric(id: "chat", label: "Chat", isUnlimited: true)])
    ])

    XCTAssertEqual(TrendSeriesBuilder.build(snapshots: [latest], latest: latest, settings: settings).emptyReason, .onlyAmounts)
  }

  func testEmptyReasonWhenTheRefreshFailsForEveryShownAccount() {
    let settings = AppSettings(accounts: [account("a1", .anthropic)])
    let latest = QuotaSnapshot(
      generatedAt: now,
      providers: [],
      failures: [ProviderFailure(accountID: "a1", provider: .anthropic, kind: .auth, message: "expired")]
    )

    XCTAssertEqual(TrendSeriesBuilder.build(snapshots: [latest], latest: latest, settings: settings).emptyReason, .refreshFailing)
  }

  func testEmptyReasonBeforeTheFirstRefresh() {
    let settings = AppSettings(accounts: [account("a1", .anthropic), account("o1", .openAI)])
    // A failure for an account the chart hides is not the chart's problem.
    let hiddenFailure = AppSettings(
      accounts: settings.accounts,
      widgetVisibility: WidgetVisibilitySettings(trendHiddenAccountIDs: ["o1"])
    )
    let latest = QuotaSnapshot(
      generatedAt: now,
      providers: [],
      failures: [ProviderFailure(accountID: "o1", provider: .openAI, kind: .auth, message: "expired")]
    )

    XCTAssertEqual(TrendSeriesBuilder.build(snapshots: [], latest: nil, settings: settings).emptyReason, .noHistory)
    XCTAssertEqual(TrendSeriesBuilder.build(snapshots: [latest], latest: latest, settings: hiddenFailure).emptyReason, .noHistory)
  }

  // MARK: - Path segments

  func testDropAndEqualValuesStayInOneConsumptionRun() {
    let samples = [sample(0, 80), sample(1, 70), sample(2, 70)]

    XCTAssertEqual(TrendPathBuilder.segments(for: samples), [TrendPathSegment(kind: .consumption, samples: samples)])
  }

  func testSmallRiseIsJitterNotAReset() {
    let samples = [sample(0, 70), sample(1, 74)]

    XCTAssertEqual(TrendPathBuilder.segments(for: samples), [TrendPathSegment(kind: .consumption, samples: samples)])
  }

  func testRefillHoldsThenRisesAsAResetSegment() {
    let samples = [sample(0, 30), sample(1, 20), sample(2, 100), sample(3, 95)]
    let hold = sample(2, 20)

    XCTAssertEqual(TrendPathBuilder.segments(for: samples), [
      TrendPathSegment(kind: .consumption, samples: [sample(0, 30), sample(1, 20), hold]),
      TrendPathSegment(kind: .reset, samples: [hold, sample(2, 100)]),
      TrendPathSegment(kind: .consumption, samples: [sample(2, 100), sample(3, 95)])
    ])
  }

  // MARK: - Time axis

  func testDaySpanUsesHourTicksAndNamesMidnight() {
    let calendar = newYorkCalendar
    let start = date(2026, 10, 5, 9, 30, calendar)
    let end = date(2026, 10, 6, 9, 30, calendar)

    let ticks = TrendAxisTicks.make(start: start, end: end, calendar: calendar, locale: enUS, maxLabels: 8)

    XCTAssertEqual(ticks.map { normalized($0.label) }, ["12 PM", "3 PM", "6 PM", "9 PM", "Tue", "3 AM", "6 AM", "9 AM"])
    XCTAssertEqual(ticks[4].date, date(2026, 10, 6, 0, 0, calendar))
  }

  func testHourTicksFollowTheRepeatedHourOnTheDSTFallBackDay() {
    let calendar = newYorkCalendar
    let start = date(2026, 10, 31, 12, 0, calendar)
    let end = date(2026, 11, 1, 12, 0, calendar)

    let ticks = TrendAxisTicks.make(start: start, end: end, calendar: calendar, locale: enUS, maxLabels: 9)

    XCTAssertEqual(ticks.map { normalized($0.label) }, ["3 PM", "6 PM", "9 PM", "Sun", "3 AM", "6 AM", "9 AM", "12 PM"])
    // 1 AM happens twice, so midnight to 3 AM is four hours.
    XCTAssertEqual(ticks[4].date.timeIntervalSince(ticks[3].date), 4 * hour)
  }

  func testRepeatedFallBackHourGetsOneTick() {
    let calendar = newYorkCalendar
    let start = date(2026, 10, 31, 23, 30, calendar)
    let end = date(2026, 11, 1, 4, 30, calendar)

    let ticks = TrendAxisTicks.make(start: start, end: end, calendar: calendar, locale: enUS, maxLabels: 8)

    XCTAssertEqual(ticks.map { normalized($0.label) }, ["Sun", "1 AM", "2 AM", "3 AM", "4 AM"])
    // The first 1 AM (daylight time) keeps the tick.
    XCTAssertEqual(ticks[1].date.timeIntervalSince(ticks[0].date), hour)
  }

  func testWeekSpanUsesLocalMidnightsAcrossSpringForward() {
    let calendar = newYorkCalendar
    let start = date(2026, 3, 5, 10, 0, calendar)
    let end = date(2026, 3, 12, 10, 0, calendar)

    let ticks = TrendAxisTicks.make(start: start, end: end, calendar: calendar, locale: enUS, maxLabels: 8)

    XCTAssertEqual(ticks.map(\.label), ["Fri", "Sat", "Sun", "Mon", "Tue", "Wed", "Thu"])
    XCTAssertTrue(ticks.allSatisfy { calendar.component(.hour, from: $0.date) == 0 })
    // March 8 is 23 hours long.
    XCTAssertEqual(ticks[3].date.timeIntervalSince(ticks[2].date), 23 * hour)
  }

  func testMonthSpanUsesDayOfMonthAndNamesTheMonth() {
    let calendar = newYorkCalendar
    let start = date(2026, 9, 15, 12, 0, calendar)
    let end = date(2026, 10, 15, 12, 0, calendar)

    let ticks = TrendAxisTicks.make(start: start, end: end, calendar: calendar, locale: enUS, maxLabels: 8)

    XCTAssertEqual(ticks.map(\.label), ["Sep 16", "21", "26", "Oct 1", "6", "11"])
  }

  func testTicksNeverExceedTheLabelBudget() {
    let calendar = newYorkCalendar
    let end = date(2026, 10, 15, 12, 0, calendar)

    let spans: [Double] = [6, 30, 36, 72, 8 * 24, 14 * 24, 30 * 24]
    for spanHours in spans {
      for maxLabels in 1...4 {
        let start = end.addingTimeInterval(-spanHours * hour)
        let ticks = TrendAxisTicks.make(start: start, end: end, calendar: calendar, locale: enUS, maxLabels: maxLabels)
        XCTAssertLessThanOrEqual(ticks.count, maxLabels, "span \(spanHours)h, budget \(maxLabels)")
        XCTAssertTrue(ticks.allSatisfy { $0.date > start && $0.date <= end })
      }
    }
  }

  func testEndpointsNameTheStartAndNow() {
    let calendar = newYorkCalendar
    let end = date(2026, 10, 6, 18, 0, calendar)

    let short = TrendAxisTicks.endpoints(start: date(2026, 10, 6, 9, 5, calendar), end: end, calendar: calendar, locale: enUS)
    let week = TrendAxisTicks.endpoints(start: date(2026, 9, 30, 18, 0, calendar), end: end, calendar: calendar, locale: enUS)
    let month = TrendAxisTicks.endpoints(start: date(2026, 9, 6, 18, 0, calendar), end: end, calendar: calendar, locale: enUS)

    XCTAssertEqual(short.map { normalized($0.label) }, ["9:05 AM", "now"])
    XCTAssertEqual(week.map(\.label), ["Wed", "now"])
    XCTAssertEqual(month.map(\.label), ["Sep 6", "now"])
    XCTAssertEqual(month.last?.date, end)
  }

  // MARK: - Forecast wording

  func testWarningTimingKeepsTwoUnits() {
    let warning = QuotaDepletionWarning(
      accountID: "a",
      metricID: "m",
      metricLabel: "7-day limit",
      depletionAt: now.addingTimeInterval(28 * hour + 20 * 60),
      resetAt: now.addingTimeInterval(3 * 24 * hour)
    )

    XCTAssertEqual(warning.timing(at: now), "out in ~1d 4h, resets in 3d")
  }

  // MARK: - Fixtures

  private var newYorkCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
  }

  private let enUS = Locale(identifier: "en_US")

  /// Newer ICU data separates "9" and "AM" with a narrow no-break space.
  private func normalized(_ label: String) -> String {
    label.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
  }

  private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ calendar: Calendar) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
  }

  private func sample(_ hours: Double, _ remaining: Double) -> TrendSample {
    TrendSample(date: now.addingTimeInterval(hours * hour), remainingPercent: remaining)
  }

  private func account(_ id: String, _ provider: QuotaProvider, isEnabled: Bool = true) -> ProviderAccount {
    ProviderAccount(id: id, provider: provider, displayName: id, isEnabled: isEnabled, credentials: [:])
  }

  private func usage(_ accountID: String, _ provider: QuotaProvider, _ metrics: [UsageMetric]) -> ProviderUsage {
    ProviderUsage(accountID: accountID, provider: provider, title: accountID, metrics: metrics, fetchedAt: now)
  }

  private func snapshot(at date: Date, _ usages: [ProviderUsage]) -> QuotaSnapshot {
    QuotaSnapshot(generatedAt: date, providers: usages, failures: [])
  }
}
