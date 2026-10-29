import XCTest
@testable import QuotaCore

final class MonthlyRefillCycleTests: XCTestCase {
  func testMistralAndCopilotUseActualCalendarMonthLengths() throws {
    let cycles = [
      ("2026-10-01T00:00:00Z", "2026-11-01T00:00:00Z", 31),
      ("2026-02-01T00:00:00Z", "2026-03-01T00:00:00Z", 28),
      ("2028-02-01T00:00:00Z", "2028-03-01T00:00:00Z", 29),
      ("2026-12-01T00:00:00Z", "2027-01-01T00:00:00Z", 31)
    ]
    for (startText, endText, days) in cycles {
      let start = try date(startText)
      let end = try date(endText)
      let midpoint = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
      for (provider, ids) in [(QuotaProvider.mistral, ["api-monthly", "vibe-monthly"]),
                              (.gitHubCopilot, ["premium", "chat", "completions"])] {
        for id in ids {
          let metric = UsageMetric(id: id, label: "Allowance", remainingPercent: 50, resetAt: end)
          XCTAssertEqual(QuotaPace.windowSeconds(for: metric, provider: provider), Double(days * 86_400))
          let pace = try XCTUnwrap(QuotaPace(metric: metric, provider: provider, fetchedAt: midpoint, now: midpoint))
          XCTAssertEqual(pace.elapsedFraction, 0.5, accuracy: 0.000001)
          XCTAssertEqual(pace.phrase, "on pace")
        }
      }
    }
  }

  func testCalendarMonthMappingsRejectUnconfirmedBoundariesAndUnknownIDs() throws {
    for provider in [QuotaProvider.mistral, .gitHubCopilot] {
      let id = provider == .mistral ? "api-monthly" : "premium"
      for end in ["2026-11-02T00:00:00Z", "2026-11-01T12:00:00Z", "2026-11-01T00:00:01Z"] {
        let metric = UsageMetric(id: id, label: "Monthly", remainingPercent: 50, resetAt: try date(end))
        XCTAssertNil(QuotaPace.windowSeconds(for: metric, provider: provider))
      }
      let unknown = UsageMetric(id: "monthly-unknown", label: "Monthly", remainingPercent: 50,
                                resetAt: try date("2026-11-01T00:00:00Z"))
      XCTAssertNil(QuotaPace.windowSeconds(for: unknown, provider: provider))
    }
  }

  func testZaiAndZhipuTokenCyclesHaveDocumentedLengths() throws {
    let reset = try date("2026-10-30T12:00:00Z")
    for provider in [QuotaProvider.zai, .zhipu] {
      for (id, seconds) in [("tokens", 18_000), ("tokens-weekly", 604_800)] {
        let metric = UsageMetric(id: id, label: "Allowance", remainingPercent: 50, resetAt: reset)
        let midpoint = reset.addingTimeInterval(-Double(seconds) / 2)
        let pace = try XCTUnwrap(QuotaPace(metric: metric, provider: provider, fetchedAt: midpoint, now: midpoint))
        XCTAssertEqual(pace.elapsedFraction, 0.5)
      }
      let unknown = UsageMetric(id: "tokens-u5-n1", label: "Monthly", remainingPercent: 50, resetAt: reset)
      XCTAssertNil(QuotaPace.windowSeconds(for: unknown, provider: provider))
    }
  }

  func testOpenCodeAnniversaryKeepsUTCClockAndShortMonthClamping() throws {
    for (startText, endText) in [
      ("2026-10-12T11:51:17Z", "2026-11-12T11:51:17Z"),
      ("2026-02-28T11:51:17Z", "2026-03-31T11:51:17Z"),
      ("2028-02-29T11:51:17Z", "2028-03-30T11:51:17Z")
    ] {
      let start = try date(startText)
      let end = try date(endText)
      let metric = UsageMetric(id: "monthly", label: "Allowance", remainingPercent: 50, resetAt: end)
      XCTAssertEqual(QuotaPace.windowSeconds(for: metric, provider: .openCodeGo), end.timeIntervalSince(start))
      let midpoint = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
      let pace = try XCTUnwrap(QuotaPace(metric: metric, provider: .openCodeGo, fetchedAt: midpoint, now: midpoint))
      XCTAssertEqual(pace.elapsedFraction, 0.5, accuracy: 0.000001)
    }
    // February's 28th could be an original 28th, 29th, 30th or 31st.
    // The reset alone cannot establish which previous January day to use.
    for end in ["2026-02-28T11:51:17Z", "2028-02-29T11:51:17Z", "2026-04-30T11:51:17Z"] {
      let metric = UsageMetric(id: "monthly", label: "Monthly", remainingPercent: 50, resetAt: try date(end))
      XCTAssertNil(QuotaPace.windowSeconds(for: metric, provider: .openCodeGo))
    }
  }

  func testExplicitDurationsWinAndMonthlyPaceExpires() throws {
    let reset = try date("2026-11-01T00:00:00Z")
    let fetchedAt = reset.addingTimeInterval(-3_600)
    var metric = UsageMetric(id: "api-monthly", label: "Allowance", remainingPercent: 50,
                             resetAt: reset, windowSeconds: 7_200)
    XCTAssertEqual(QuotaPace(metric: metric, provider: .mistral, fetchedAt: fetchedAt, now: fetchedAt)?.elapsedFraction, 0.5)
    XCTAssertNil(QuotaPace(metric: metric, provider: .mistral, fetchedAt: fetchedAt, now: reset))
    metric.windowSeconds = 0
    XCTAssertNil(QuotaPace.windowSeconds(for: metric, provider: .mistral))
    metric.windowSeconds = nil
    metric.resetAt = nil
    XCTAssertNil(QuotaPace.windowSeconds(for: metric, provider: .mistral))
  }

  func testDocumentedMonthSupportsSharedForecastWithEnoughHistory() throws {
    let now = try date("2026-10-20T12:00:00Z")
    let reset = try date("2026-11-01T00:00:00Z")
    // Four days of readings satisfy the monthly forecast's observation gate.
    let history = (0...32).map { index in
      let fetchedAt = now.addingTimeInterval(Double(index - 32) * 10_800)
      return QuotaSnapshot(generatedAt: fetchedAt, providers: [ProviderUsage(
        accountID: "fixture", provider: .mistral, title: "Mistral",
        metrics: [UsageMetric(id: "api-monthly", label: "Monthly API allowance",
          remainingPercent: 100 - index, resetAt: reset)], fetchedAt: fetchedAt)], failures: [])
    }
    let latest = try XCTUnwrap(history.last)
    let key = QuotaForecast.SeriesKey(accountID: "fixture", metricID: "api-monthly")
    let estimate = try XCTUnwrap(QuotaForecast.measurements(history: history, latest: latest,
      now: now, refreshInterval: 10_800)[key])
    XCTAssertEqual(estimate.burnRatePerHour, 1.0 / 3, accuracy: 0.000001)
    XCTAssertEqual(estimate.trend, .runsOut)
    XCTAssertTrue(QuotaForecast.measurements(history: history, latest: latest,
      now: reset, refreshInterval: 10_800).isEmpty)
  }

  private func date(_ text: String) throws -> Date {
    try XCTUnwrap(ISO8601DateFormatter().date(from: text))
  }
}
