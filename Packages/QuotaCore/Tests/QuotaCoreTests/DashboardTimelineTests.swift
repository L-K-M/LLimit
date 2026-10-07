import XCTest
@testable import QuotaCore

final class DashboardTimelineTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private let account = ProviderAccount(id: "a", provider: .openAI)

  func testSchedulesStalenessEvenBeyondTheRequestedReload() {
    let snapshot = fixture(fetchedAt: now, generatedAt: now)
    let dates = DashboardTimeline.entryDates(snapshot: snapshot, accounts: [account], now: now, refreshIntervalMinutes: 15)
    XCTAssertEqual(dates, [now, now.addingTimeInterval(3_601)])
    XCTAssertTrue(QuotaFreshness.isStale(fetchedAt: now, in: snapshot, now: dates.last!, maxAge: 3_600))
  }

  func testStaleDataAndEmptyBoardKeepSingleEntry() {
    let old = now.addingTimeInterval(-7_200)
    XCTAssertEqual(DashboardTimeline.entryDates(snapshot: fixture(fetchedAt: old, generatedAt: old),
      accounts: [account], now: now, refreshIntervalMinutes: 30), [now])
    XCTAssertEqual(DashboardTimeline.entryDates(snapshot: fixture(fetchedAt: now, generatedAt: now),
      accounts: [], now: now, refreshIntervalMinutes: 30), [now])
    XCTAssertEqual(DashboardTimeline.entryDates(snapshot: nil, accounts: [account], now: now, refreshIntervalMinutes: 30), [now])
  }

  func testStaleSourceDoesNotAddAnUnchangedHeaderTransition() {
    let snapshot = fixture(fetchedAt: now.addingTimeInterval(-7_200), generatedAt: now)
    XCTAssertEqual(DashboardTimeline.entryDates(snapshot: snapshot, accounts: [account], now: now,
      refreshIntervalMinutes: 30), [now])
  }

  func testEachSourceTransitionIsScheduledAndDisabledDataIgnored() {
    var snapshot = fixture(fetchedAt: now.addingTimeInterval(-600), generatedAt: now)
    var other = account
    other.id = "b"
    var usage = snapshot.providers[0]
    usage.accountID = other.id
    usage.fetchedAt = now.addingTimeInterval(-1_200)
    snapshot.providers.append(usage)
    let dates = DashboardTimeline.entryDates(snapshot: snapshot, accounts: [account, other], now: now,
                                              refreshIntervalMinutes: 60)
    XCTAssertEqual(dates, [now, now.addingTimeInterval(6_001), now.addingTimeInterval(6_601)])
    other.isEnabled = false
    XCTAssertEqual(DashboardTimeline.entryDates(snapshot: snapshot, accounts: [account, other], now: now,
      refreshIntervalMinutes: 60), [now, now.addingTimeInterval(6_601)])
  }

  func testResetBoundaryMarksOldWindowWithoutInventingARefill() throws {
    var snapshot = fixture(fetchedAt: now, generatedAt: now)
    snapshot.providers[0].metrics[0].resetAt = now.addingTimeInterval(120)
    let dates = DashboardTimeline.entryDates(snapshot: snapshot, accounts: [account], now: now, refreshIntervalMinutes: 30)
    XCTAssertEqual(dates, [now, now.addingTimeInterval(120)])
    let transition = try XCTUnwrap(dates.dropFirst().first)
    let bars = MenuBarGraph.bars(snapshot: snapshot, accounts: [account], now: transition, staleAfter: 3_600)
    XCTAssertEqual(bars.first?.freshness, .stale)
    XCTAssertEqual(bars.first?.level, .remaining(percent: 80, isEstimated: false))
  }

  private func fixture(fetchedAt: Date, generatedAt: Date) -> QuotaSnapshot {
    QuotaSnapshot(generatedAt: generatedAt, providers: [ProviderUsage(accountID: account.id, provider: account.provider,
      title: "Old name", metrics: [UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 80)], fetchedAt: fetchedAt)], failures: [])
  }
}
