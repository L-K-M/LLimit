import XCTest
@testable import QuotaCore

final class TrendChartTests: XCTestCase {
  private let base = Date(timeIntervalSince1970: 1_700_000_000)
  private var settings: AppSettings { AppSettings(accounts: [ProviderAccount(id: "a", provider: .openAI)]) }

  private func snapshot(fetch: Date, label: String = "7-day limit", failed: Bool = false) -> QuotaSnapshot {
    QuotaSnapshot(generatedAt: base.addingTimeInterval(3_600), providers: [
      ProviderUsage(accountID: "a", provider: .openAI, title: "Account",
        metrics: [UsageMetric(id: "primary", label: label, remainingPercent: 60)], fetchedAt: fetch)
    ], failures: failed ? [ProviderFailure(accountID: "a", provider: .openAI, kind: .network, message: "offline")] : [])
  }

  func testChartUsesDistinctSourceFetchesAndNeverPublicationOrFailedCarries() throws {
    let first = snapshot(fetch: base)
    let second = snapshot(fetch: base.addingTimeInterval(900))
    let failed = snapshot(fetch: base.addingTimeInterval(900), failed: true)
    let content = TrendSeriesBuilder.build(snapshots: [second, first, second, failed], latest: failed, settings: settings)
    let line = try XCTUnwrap(content.accounts.first?.series.first)
    XCTAssertEqual(line.samples.map(\.date), [base, base.addingTimeInterval(900)])
  }

  func testFailureOnlyCarryDoesNotInventHistory() {
    let failed = snapshot(fetch: base, failed: true)
    let content = TrendSeriesBuilder.build(snapshots: [failed], latest: failed, settings: settings)
    XCTAssertEqual(content.emptyReason, .refreshFailing)
  }

  func testKindChangesProduceStableDistinctRetiredAndLiveLines() throws {
    let before = snapshot(fetch: base, label: "5-hour limit")
    let after = snapshot(fetch: base.addingTimeInterval(900))
    let content = TrendSeriesBuilder.build(snapshots: [before, after], latest: after, settings: settings)
    let lines = try XCTUnwrap(content.accounts.first).series
    XCTAssertEqual(lines.map(\.slot.kind), [.session, .weekly])
    XCTAssertEqual(lines.map(\.isRetired), [true, false])
    XCTAssertEqual(Set(lines.map(\.id)).count, 2)
  }

  func testFailedLatestCannotRetireOrReviveMetricKinds() throws {
    let before = snapshot(fetch: base, label: "5-hour limit")
    let current = snapshot(fetch: base.addingTimeInterval(900))
    let failed = snapshot(fetch: base.addingTimeInterval(1_800), label: "5-hour limit", failed: true)
    let content = TrendSeriesBuilder.build(snapshots: [before, current, failed], latest: failed, settings: settings)
    XCTAssertEqual(try XCTUnwrap(content.accounts.first).series.map(\.isRetired), [true, false])
  }

  func testReportedOldAndFailedLinesAreStaleRatherThanRetired() throws {
    let source = snapshot(fetch: base)
    for latest in [source, snapshot(fetch: base, failed: true)] {
      let content = TrendSeriesBuilder.build(snapshots: [source, latest], latest: latest,
        settings: settings, now: base.addingTimeInterval(3_600))
      let line = try XCTUnwrap(content.accounts.first?.series.first)
      XCTAssertTrue(line.isStale)
      XCTAssertFalse(line.isRetired)
    }
  }

  func testEmptyReasonsAndShortTermFilteringUseCurrentLimits() throws {
    XCTAssertEqual(TrendSeriesBuilder.build(snapshots: [], latest: nil, settings: AppSettings()).emptyReason, .noAccounts)
    var hidden = settings
    hidden.widgetVisibility.trendHiddenAccountIDs = ["a"]
    XCTAssertEqual(TrendSeriesBuilder.build(snapshots: [], latest: nil, settings: hidden).emptyReason, .allHidden)
    var source = snapshot(fetch: base)
    source.providers[0].metrics = [UsageMetric(id: "chat", label: "Chat", isUnlimited: true)]
    XCTAssertEqual(TrendSeriesBuilder.build(snapshots: [source], latest: source, settings: settings).emptyReason, .onlyUnlimited)
    source.providers[0].metrics = [UsageMetric(id: "usd", label: "USD", remainingAmount: 4)]
    XCTAssertEqual(TrendSeriesBuilder.build(snapshots: [source], latest: source, settings: settings).emptyReason, .onlyAmounts)
    var longTerm = settings
    longTerm.widgetVisibility.showShortTermLimitsInTrend = false
    let before = snapshot(fetch: base)
    let after = snapshot(fetch: base.addingTimeInterval(900), label: "5-hour limit")
    let content = TrendSeriesBuilder.build(snapshots: [before, after], latest: after, settings: longTerm)
    XCTAssertEqual(try XCTUnwrap(content.accounts.first).series.map(\.slot.kind), [.weekly, .session])
  }

  func testResetsHoldThenSnapAndSmallResetUsesServerBoundary() {
    let reset = base.addingTimeInterval(900)
    let before = TrendSample(date: base, remainingPercent: 98, resetAt: reset)
    let after = TrendSample(date: reset, remainingPercent: 100, resetAt: reset.addingTimeInterval(900))
    let segments = TrendPathBuilder.segments(for: [before, after])
    XCTAssertEqual(segments.map(\.kind), [.consumption, .reset, .consumption])
    XCTAssertEqual(segments[0].samples.last?.remainingPercent, 98)
    XCTAssertEqual(segments[1].samples.map(\.remainingPercent), [98, 100])
    let jitter = TrendSample(date: reset, remainingPercent: 100)
    XCTAssertEqual(TrendPathBuilder.segments(for: [TrendSample(date: base, remainingPercent: 98), jitter]).count, 1)
  }

  func testTimeAxesRespectDSTLabelBudgetsAndRecentEnd() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
    let locale = Locale(identifier: "en_US")
    let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 23, minute: 30)))
    let end = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 4, minute: 30)))
    let repeated = TrendAxisTicks.make(start: start, end: end, calendar: calendar, locale: locale, maxLabels: 8)
    XCTAssertEqual(repeated.count, 5)
    XCTAssertEqual(repeated[1].date.timeIntervalSince(repeated[0].date), 3_600)
    for days in [7, 14, 30] {
      for budget in 1...8 {
        let ticks = TrendAxisTicks.make(start: end.addingTimeInterval(-Double(days) * 86_400),
          end: end, calendar: calendar, locale: locale, maxLabels: budget)
        XCTAssertLessThanOrEqual(ticks.count, budget)
        XCTAssertEqual(ticks.last?.date, calendar.startOfDay(for: end))
      }
    }
    XCTAssertEqual(TrendAxisTicks.endpoints(start: start, end: end, calendar: calendar, locale: locale).last?.label, "now")
  }

  func testDownsamplePreservesBothSidesOfReset() {
    let samples = (0..<300).map { index in
      TrendSample(date: base.addingTimeInterval(Double(index) * 900), remainingPercent: index < 173 ? 60 : 100)
    }
    let reduced = TrendPathBuilder.downsample(samples, maxCount: 20)
    XCTAssertTrue(reduced.contains(samples[172]))
    XCTAssertTrue(reduced.contains(samples[173]))
    XCTAssertEqual(reduced.first, samples.first)
    XCTAssertEqual(reduced.last, samples.last)
  }
}
