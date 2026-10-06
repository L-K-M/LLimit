import XCTest
@testable import QuotaCore

final class HeadroomSelectionTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private func usage(
    _ accountID: String,
    provider: QuotaProvider = .openAI,
    title: String,
    metrics: [UsageMetric],
    maxUsagePercent: Int? = nil
  ) -> ProviderUsage {
    ProviderUsage(
      accountID: accountID,
      provider: provider,
      title: title,
      metrics: metrics,
      maxUsagePercent: maxUsagePercent,
      fetchedAt: now
    )
  }

  func testEffectiveRemainingPercentUsesLowestBoundedMetric() {
    let u = usage("a", title: "A", metrics: [
      UsageMetric(id: "five_hour", label: "5h", remainingPercent: 80),
      UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 25),
      UsageMetric(id: "extra", label: "Extra", isUnlimited: true)
    ])
    XCTAssertEqual(effectiveRemainingPercent(for: u), 25)
  }

  func testEffectiveRemainingPercentUnlimitedOnlyYields100() {
    let u = usage("a", title: "A", metrics: [
      UsageMetric(id: "m", label: "m", isUnlimited: true)
    ])
    XCTAssertEqual(effectiveRemainingPercent(for: u), 100)
  }

  func testEffectiveRemainingPercentFallsBackToMaxUsagePercent() {
    let u = usage("a", title: "A", metrics: [], maxUsagePercent: 30)
    XCTAssertEqual(effectiveRemainingPercent(for: u), 70)
  }

  func testBestHeadroomPicksHighestBoundedRemaining() {
    let low = usage("low", provider: .anthropic, title: "Low", metrics: [
      UsageMetric(id: "m", label: "m", remainingPercent: 20)
    ])
    let high = usage("high", title: "High", metrics: [
      UsageMetric(id: "m", label: "m", remainingPercent: 60),
      UsageMetric(id: "u", label: "u", isUnlimited: true)
    ])
    XCTAssertEqual(bestHeadroomProvider(in: [low, high])?.accountID, "high")
  }

  func testBestHeadroomIgnoresUnlimitedOnlyProviders() {
    let unlimited = usage("u", title: "Unlimited", metrics: [
      UsageMetric(id: "m", label: "m", isUnlimited: true)
    ])
    let bounded = usage("b", title: "Bounded", metrics: [
      UsageMetric(id: "m", label: "m", remainingPercent: 5)
    ])
    // Unlimited metrics report 100% but must never outrank real headroom.
    XCTAssertEqual(bestHeadroomProvider(in: [unlimited, bounded])?.accountID, "b")
    XCTAssertNil(bestHeadroomProvider(in: [unlimited]))
  }

  func testBestHeadroomReturnsNilWhenAllDepleted() {
    let a = usage("a", title: "A", metrics: [
      UsageMetric(id: "m", label: "m", remainingPercent: 0)
    ])
    let b = usage("b", title: "B", metrics: [
      UsageMetric(id: "m", label: "m", remainingPercent: 0)
    ])
    XCTAssertNil(bestHeadroomProvider(in: [a, b]),
                 "A 0% recommendation would claim headroom that does not exist")
  }

  func testBestHeadroomReturnsNilWhenPercentagesUnknown() {
    let a = usage("a", title: "A", metrics: [
      UsageMetric(id: "m", label: "m", remainingAmount: 12.5)
    ])
    XCTAssertNil(bestHeadroomProvider(in: [a]))
  }

  func testBestHeadroomBreaksTiesAlphabetically() {
    let b = usage("b", title: "Beta", metrics: [
      UsageMetric(id: "m", label: "m", remainingPercent: 50)
    ])
    let a = usage("a", title: "Alpha", metrics: [
      UsageMetric(id: "m", label: "m", remainingPercent: 50)
    ])
    XCTAssertEqual(bestHeadroomProvider(in: [b, a])?.title, "Alpha")
  }

  func testBestHeadroomEmptyInputReturnsNil() {
    XCTAssertNil(bestHeadroomProvider(in: []))
  }

  func testEffectiveRemainingPercentClampsOutOfRangeValues() {
    let high = usage("a", title: "A", metrics: [
      UsageMetric(id: "m", label: "m", remainingPercent: 150)
    ])
    let negative = usage("b", title: "B", metrics: [
      UsageMetric(id: "m", label: "m", remainingPercent: -20)
    ])
    let overdrawn = usage("c", title: "C", metrics: [], maxUsagePercent: 150)
    XCTAssertEqual(effectiveRemainingPercent(for: high), 100)
    XCTAssertEqual(effectiveRemainingPercent(for: negative), 0)
    XCTAssertEqual(effectiveRemainingPercent(for: overdrawn), 0)
  }

  func testBestHeadroomRanksByMaxUsagePercentFallback() {
    let explicit = usage("a", title: "A", metrics: [
      UsageMetric(id: "m", label: "m", remainingPercent: 50)
    ])
    let fallback = usage("b", title: "B", metrics: [
      UsageMetric(id: "m", label: "m", remainingAmount: 5.0)
    ], maxUsagePercent: 20)
    XCTAssertEqual(bestHeadroomProvider(in: [explicit, fallback])?.accountID, "b")
  }
}
