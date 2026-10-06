import XCTest
@testable import QuotaCore

final class ResetScheduleTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private func metric(
    _ id: String,
    _ label: String,
    resetAt: Date?,
    remaining: Int? = 50,
    unlimited: Bool = false
  ) -> UsageMetric {
    UsageMetric(
      id: id,
      label: label,
      remainingPercent: remaining,
      resetAt: resetAt,
      isUnlimited: unlimited
    )
  }

  func testSchedulesOnlyResetsInsideTheWindow() {
    let snapshot = QuotaSnapshot(
      generatedAt: now,
      providers: [
        ProviderUsage(
          accountID: "a",
          provider: .anthropic,
          title: "Claude",
          metrics: [
            metric("past", "Past", resetAt: now.addingTimeInterval(-60)),
            metric("soon", "Soon", resetAt: now.addingTimeInterval(3600)),
            metric("edge", "Edge", resetAt: now.addingTimeInterval(7200)),
            metric("later", "Later", resetAt: now.addingTimeInterval(7201)),
            metric("undated", "Undated", resetAt: nil)
          ],
          fetchedAt: now
        )
      ],
      failures: []
    )

    let resets = snapshot.upcomingResets(now: now, within: 7200)

    // The past and the undated cannot be scheduled; the window is inclusive.
    XCTAssertEqual(resets.map(\.metricID), ["soon", "edge"])
  }

  func testOrdersByResetTimeThenAccountThenMetric() {
    let sameInstant = now.addingTimeInterval(1800)
    let snapshot = QuotaSnapshot(
      generatedAt: now,
      providers: [
        ProviderUsage(
          accountID: "b",
          provider: .openAI,
          title: "OpenAI",
          metrics: [
            metric("weekly", "Weekly limit", resetAt: sameInstant),
            metric("session", "5-hour limit", resetAt: now.addingTimeInterval(600))
          ],
          fetchedAt: now
        ),
        ProviderUsage(
          accountID: "a",
          provider: .anthropic,
          title: "Claude",
          metrics: [metric("weekly", "Weekly limit", resetAt: sameInstant)],
          fetchedAt: now
        )
      ],
      failures: []
    )

    let resets = snapshot.upcomingResets(now: now, within: 86_400)

    // Soonest first; the two equal instants break by account name.
    XCTAssertEqual(resets.map(\.accountName), ["OpenAI", "Claude", "OpenAI"])
    XCTAssertEqual(resets.map(\.metricID), ["session", "weekly", "weekly"])
  }

  func testNonPositiveOrInfiniteWindowSchedulesNothing() {
    let snapshot = QuotaSnapshot(
      generatedAt: now,
      providers: [
        ProviderUsage(
          accountID: "a", provider: .anthropic, title: "Claude",
          metrics: [metric("weekly", "Weekly", resetAt: now.addingTimeInterval(60))],
          fetchedAt: now
        )
      ],
      failures: []
    )

    XCTAssertTrue(snapshot.upcomingResets(now: now, within: 0).isEmpty)
    XCTAssertTrue(snapshot.upcomingResets(now: now, within: -60).isEmpty)
    XCTAssertTrue(snapshot.upcomingResets(now: now, within: .infinity).isEmpty)
  }

  func testEqualKeysAreFullyOrdered() {
    let instant = now.addingTimeInterval(1800)
    // Same title, same metric label, same instant: only the account id can
    // order these, and `sorted` is not stable, so the comparator must be total.
    let snapshot = QuotaSnapshot(
      generatedAt: now,
      providers: [
        ProviderUsage(
          accountID: "zzz", provider: .anthropic, title: "Claude",
          metrics: [metric("weekly", "Weekly limit", resetAt: instant)], fetchedAt: now
        ),
        ProviderUsage(
          accountID: "aaa", provider: .anthropic, title: "Claude",
          metrics: [metric("weekly", "Weekly limit", resetAt: instant)], fetchedAt: now
        )
      ],
      failures: []
    )

    let resets = snapshot.upcomingResets(now: now, within: 86_400)
    XCTAssertEqual(resets.map(\.accountID), ["aaa", "zzz"])
  }

  func testCarriesTheMetricContextForRendering() {
    let resetAt = now.addingTimeInterval(3 * 3600 + 12 * 60)
    let snapshot = QuotaSnapshot(
      generatedAt: now,
      providers: [
        ProviderUsage(
          accountID: "acct-1", provider: .anthropic, title: "Claude",
          metrics: [metric("five_hour", "5-hour limit", resetAt: resetAt, remaining: 62)],
          fetchedAt: now
        )
      ],
      failures: []
    )

    let entry = snapshot.upcomingResets(now: now, within: 86_400).first
    XCTAssertEqual(entry?.accountID, "acct-1")
    XCTAssertEqual(entry?.provider, .anthropic)
    XCTAssertEqual(entry?.metricLabel, "5-hour limit")
    XCTAssertEqual(entry?.remainingPercent, 62)
    XCTAssertEqual(entry?.isUnlimited, false)
    XCTAssertEqual(entry?.countdown(at: now), "3h 12m")
    XCTAssertEqual(entry?.countdown(at: resetAt.addingTimeInterval(1)), "reset")
  }

  func testUnlimitedMetricsWithAResetDateAreStillScheduled() {
    // An unlimited metric has no remainingPercent to rank on, but a real reset
    // the renderer displays with its "(unlimited)" suffix. Pin it so a future
    // filter on remainingPercent == nil cannot drop it silently.
    let snapshot = QuotaSnapshot(
      generatedAt: now,
      providers: [
        ProviderUsage(
          accountID: "a", provider: .anthropic, title: "Claude",
          metrics: [metric(
            "weekly", "Weekly limit",
            resetAt: now.addingTimeInterval(3600), remaining: nil, unlimited: true
          )],
          fetchedAt: now
        )
      ],
      failures: []
    )

    let entry = snapshot.upcomingResets(now: now, within: 86_400).first
    XCTAssertEqual(entry?.metricID, "weekly")
    XCTAssertEqual(entry?.isUnlimited, true)
    XCTAssertNil(entry?.remainingPercent)
  }
}
