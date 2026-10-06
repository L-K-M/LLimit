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
}
