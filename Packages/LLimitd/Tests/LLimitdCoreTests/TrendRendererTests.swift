import XCTest
import QuotaCore
@testable import LLimitdCore

final class TrendRendererTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func snapshot(_ offset: TimeInterval, remaining: Int? = 50, amount: Double? = nil, failed: Bool = false) -> QuotaSnapshot {
    QuotaSnapshot(generatedAt: now, providers: [ProviderUsage(accountID: "a", provider: .anthropic, title: "Personal",
      metrics: [UsageMetric(id: "weekly", label: "Weekly", remainingPercent: remaining, remainingAmount: amount)],
      fetchedAt: now.addingTimeInterval(offset))], failures: failed
        ? [ProviderFailure(accountID: "a", provider: .anthropic, kind: .network, message: "offline")] : [])
  }

  func testTrendUsesFetchTimesAndDoesNotCountCopiesFailuresOrOutOfWindowCarries() {
    let copied = Array(repeating: snapshot(-3_600), count: 5)
    XCTAssertTrue(TrendRenderer.render(history: copied, now: now).contains("Not enough history"))
    XCTAssertTrue(TrendRenderer.render(history: [snapshot(-3_600, failed: true), snapshot(0)], now: now).contains("Not enough history"))
    XCTAssertTrue(TrendRenderer.render(history: [snapshot(-8 * 86_400), snapshot(0)], now: now).contains("Not enough history"))
  }

  func testPercentUsesAbsoluteScaleAndAmountsAreLabeledNormalized() {
    let history = [snapshot(-86_400, remaining: 45), snapshot(0, remaining: 50)]
    XCTAssertTrue(TrendRenderer.render(history: history, now: now, days: 1, width: 2).contains("▄▄"))
    let amounts = [snapshot(-86_400, remaining: nil, amount: 4), snapshot(0, remaining: nil, amount: 5)]
    let output = TrendRenderer.render(history: amounts, now: now, days: 1, width: 2)
    XCTAssertTrue(output.contains("▁█"))
    XCTAssertTrue(output.contains("amount, normalized to observed range"))
  }

  func testForwardFillLeavesLeadingBlanksAndDoesNotChangeEvidenceCount() {
    let window = now.addingTimeInterval(-4 * 3_600)...now
    let samples = [(at: now, value: 0.0), (at: now.addingTimeInterval(-2 * 3_600), value: 100.0)]
    XCTAssertEqual(TrendRenderer.sparkline(samples, window: window, width: 4, scale: 0...100), "  █▁")
  }

  func testAccountFilterAndAmountPercentChangesDoNotMixUnits() {
    let history = [snapshot(-3_600, remaining: 50), snapshot(-1_800, remaining: nil, amount: 4), snapshot(0, remaining: 40)]
    let output = TrendRenderer.render(history: history, now: now)
    XCTAssertFalse(output.contains("normalized"))
    XCTAssertTrue(TrendRenderer.render(history: history, now: now, accountPrefix: "Work").contains("Not enough history"))
    XCTAssertTrue(TrendRenderer.render(history: history, now: now, accountPrefix: "Pers").contains("Personal:"))
  }
}
