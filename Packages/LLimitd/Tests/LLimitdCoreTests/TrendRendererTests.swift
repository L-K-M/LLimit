import XCTest
@testable import QuotaCore
@testable import LLimitdCore

final class TrendRendererTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private func snapshot(at date: Date, percent: Int, accountID: String = "acct",
                        title: String = "Claude", label: String = "5-hour limit",
                        amount: Double? = nil) -> QuotaSnapshot {
    QuotaSnapshot(
      generatedAt: date,
      providers: [
        ProviderUsage(
          accountID: accountID, provider: .anthropic, title: title,
          metrics: [UsageMetric(id: "m", label: label,
                                remainingPercent: amount == nil ? percent : nil,
                                remainingAmount: amount)],
          fetchedAt: date
        )
      ],
      failures: []
    )
  }

  func testSparklineForwardFillsAndRendersSlope() {
    let window = now.addingTimeInterval(-86_400)...now
    let samples: [(at: Date, value: Double)] = [
      (at: now.addingTimeInterval(-86_400), value: 90),
      (at: now.addingTimeInterval(-43_200), value: 45),
      (at: now, value: 10),
    ]
    let line = TrendRenderer.sparkline(samples, window: window, width: 8)
    XCTAssertEqual(line.count, 8)
    // Falling values: the left half rides high, the right half low.
    XCTAssertEqual(line.prefix(1), "█")
    XCTAssertEqual(line.suffix(1), "▁")
    XCTAssertTrue(line.contains("▄") || line.contains("▅"))
  }

  func testSparklineLeavesLeadingBucketsBlankBeforeFirstSample() {
    let window = now.addingTimeInterval(-86_400)...now
    let line = TrendRenderer.sparkline([(at: now, value: 50)], window: window, width: 8)
    XCTAssertTrue(line.hasPrefix(" "))
    XCTAssertTrue(line.hasSuffix("▄"))  // flat series draws a mid line
  }

  func testRenderGroupsMetricsUnderAccountTitles() {
    let history = [
      snapshot(at: now.addingTimeInterval(-7_200), percent: 80),
      snapshot(at: now.addingTimeInterval(-3_600), percent: 60),
      snapshot(at: now, percent: 40),
    ]
    let text = TrendRenderer.render(history: history, now: now, days: 1)
    XCTAssertTrue(text.contains("Claude:"))
    XCTAssertTrue(text.contains("5-hour limit"))
    XCTAssertTrue(text.contains("40% left"))
    XCTAssertTrue(text.contains("▁") || text.contains("▂") || text.contains("▃"))
  }

  func testRenderHonorsAccountPrefixAndAmountOnlyMetrics() {
    let history = [
      snapshot(at: now.addingTimeInterval(-7_200), percent: 80, title: "Venice",
               label: "DIEM", amount: 12.0),
      snapshot(at: now, percent: 80, title: "Venice",
               label: "DIEM", amount: 6.0),
      snapshot(at: now, percent: 70, title: "Claude"),
    ]
    let filtered = TrendRenderer.render(history: history, now: now, days: 1,
                                        accountPrefix: "venice")
    XCTAssertTrue(filtered.contains("Venice:"))
    XCTAssertFalse(filtered.contains("Claude:"))
  }

  func testRenderExplainsWhenHistoryIsThin() {
    let text = TrendRenderer.render(history: [snapshot(at: now, percent: 50)], now: now)
    XCTAssertTrue(text.contains("not enough history"))
  }
}
