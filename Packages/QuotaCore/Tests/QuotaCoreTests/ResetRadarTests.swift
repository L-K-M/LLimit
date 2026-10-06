import XCTest
@testable import QuotaCore

final class ResetRadarTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  func testUpcomingResetsSortedChronologically() {
    let usage1 = ProviderUsage(
      accountID: "claude-work",
      provider: .anthropic,
      title: "Claude Work",
      metrics: [
        UsageMetric(
          id: "five_hour",
          label: "5-hour limit",
          remainingPercent: 40,
          resetAt: now.addingTimeInterval(3_600) // 1 hour
        ),
        UsageMetric(
          id: "seven_day",
          label: "Weekly limit",
          remainingPercent: 75,
          resetAt: now.addingTimeInterval(86_400 * 3) // 3 days
        )
      ],
      fetchedAt: now
    )

    let usage2 = ProviderUsage(
      accountID: "openai-main",
      provider: .openAI,
      title: "OpenAI Main",
      metrics: [
        UsageMetric(
          id: "primary",
          label: "Primary window",
          remainingPercent: 20,
          resetAt: now.addingTimeInterval(1_800) // 30 minutes
        )
      ],
      fetchedAt: now
    )

    let snapshot = QuotaSnapshot(generatedAt: now, providers: [usage1, usage2], failures: [])
    let resets = ResetRadar.upcomingResets(from: snapshot, now: now)

    XCTAssertEqual(resets.count, 3)
    // First should be OpenAI Primary (30m)
    XCTAssertEqual(resets[0].accountID, "openai-main")
    XCTAssertEqual(resets[0].metricID, "primary")
    XCTAssertEqual(resets[0].secondsUntilReset, 1_800, accuracy: 1.0)
    XCTAssertEqual(resets[0].countdown, "30m")

    // Second should be Claude 5-hour (1h)
    XCTAssertEqual(resets[1].accountID, "claude-work")
    XCTAssertEqual(resets[1].metricID, "five_hour")
    XCTAssertEqual(resets[1].secondsUntilReset, 3_600, accuracy: 1.0)
    XCTAssertEqual(resets[1].countdown, "1h")

    // Third should be Claude Weekly (3d)
    XCTAssertEqual(resets[2].accountID, "claude-work")
    XCTAssertEqual(resets[2].metricID, "seven_day")
    XCTAssertEqual(resets[2].countdown, "3d")
  }

  func testIgnoresPastResetsAndMissingDates() {
    let usage = ProviderUsage(
      accountID: "copilot",
      provider: .gitHubCopilot,
      title: "Copilot",
      metrics: [
        UsageMetric(id: "past", label: "Past", resetAt: now.addingTimeInterval(-100)),
        UsageMetric(id: "nodate", label: "No Date", remainingPercent: 90)
      ],
      fetchedAt: now
    )

    let snapshot = QuotaSnapshot(generatedAt: now, providers: [usage], failures: [])
    let resets = ResetRadar.upcomingResets(from: snapshot, now: now)
    XCTAssertTrue(resets.isEmpty)
  }

  func testNilSnapshotReturnsEmptyList() {
    let resets = ResetRadar.upcomingResets(from: nil, now: now)
    XCTAssertTrue(resets.isEmpty)
  }

  func testZeroMaxCountYieldsEmptyArray() {
    let usage = ProviderUsage(
      accountID: "claude-work",
      provider: .anthropic,
      title: "Claude Work",
      metrics: [
        UsageMetric(id: "five_hour", label: "5-hour limit", resetAt: now.addingTimeInterval(3_600))
      ],
      fetchedAt: now
    )
    let snapshot = QuotaSnapshot(generatedAt: now, providers: [usage], failures: [])
    let resets = ResetRadar.upcomingResets(from: snapshot, now: now, maxCount: 0)
    XCTAssertTrue(resets.isEmpty)
  }

  func testStrictWeakOrderingWithCloseResetTimes() {
    let u1 = ProviderUsage(
      accountID: "zulu",
      provider: .anthropic,
      title: "Zulu",
      metrics: [UsageMetric(id: "m", label: "m", resetAt: now.addingTimeInterval(10))],
      fetchedAt: now
    )
    let u2 = ProviderUsage(
      accountID: "mike",
      provider: .openAI,
      title: "Mike",
      metrics: [UsageMetric(id: "m", label: "m", resetAt: now.addingTimeInterval(11))],
      fetchedAt: now
    )
    let u3 = ProviderUsage(
      accountID: "alpha",
      provider: .devin,
      title: "Alpha",
      metrics: [UsageMetric(id: "m", label: "m", resetAt: now.addingTimeInterval(12))],
      fetchedAt: now
    )
    let snapshot = QuotaSnapshot(generatedAt: now, providers: [u1, u2, u3], failures: [])
    let resets = ResetRadar.upcomingResets(from: snapshot, now: now)
    XCTAssertEqual(resets.map(\.accountName), ["Zulu", "Mike", "Alpha"])
  }
}
