import XCTest
@testable import QuotaCore

final class BenchmarkPriceAllocationTests: XCTestCase {
  func testMistralUsesDocumentedCalendarMonthWithoutReportedDuration() throws {
    let reset = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z"))
    let metric = UsageMetric(id: "api-monthly", label: "Monthly API allowance", remainingPercent: 90, resetAt: reset)
    let price = SubscriptionPricing(amount: 30)
    let allocation = try XCTUnwrap(BenchmarkPriceAllocation.subscription(price, metric: metric, currency: "USD", provider: .mistral))
    XCTAssertEqual(allocation.allowanceCost, 30)
    XCTAssertEqual(BenchmarkPriceAllocation.defaultMetricID(in: [metric], provider: .mistral), "api-monthly")
    XCTAssertNil(BenchmarkPriceAllocation.subscription(price, metric: metric, currency: "USD"))
    XCTAssertNil(BenchmarkPriceAllocation.subscription(price, metric: metric, currency: "USD", provider: .stepFun))
  }

  func testMistralUnknownOrNonCalendarResetDoesNotInventDuration() throws {
    let price = SubscriptionPricing(amount: 30)
    let reset = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-12-15T00:00:00Z"))
    for metric in [UsageMetric(id: "api-monthly", label: "Monthly API allowance", remainingPercent: 90),
                   UsageMetric(id: "api-monthly", label: "Monthly API allowance", remainingPercent: 90, resetAt: reset)] {
      XCTAssertNil(BenchmarkPriceAllocation.subscription(price, metric: metric, currency: "USD", provider: .mistral))
      XCTAssertNil(BenchmarkPriceAllocation.defaultMetricID(in: [metric], provider: .mistral))
    }
  }

  func testMonthlyQuotaUsesMonthlyPriceEvenAcrossDifferentCalendarMonthLengths() throws {
    for days in [28, 29, 30, 31] {
      let metric = UsageMetric(id: "monthly", label: "Monthly credits", remainingPercent: 90, windowSeconds: days * 86_400)
      let allocation = try XCTUnwrap(BenchmarkPriceAllocation.subscription(SubscriptionPricing(amount: 200), metric: metric, currency: "USD"))
      XCTAssertEqual(allocation.allowanceCost, 200)
      XCTAssertTrue(allocation.explanation.contains("monthly equivalent"))
    }
  }

  func testYearlyPriceAndWeeklyCapacityUseDeclaredProration() throws {
    let metric = UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 90, windowSeconds: 7 * 86_400)
    let price = SubscriptionPricing(amount: 1_200, billingPeriod: .yearly)
    let allocation = try XCTUnwrap(BenchmarkPriceAllocation.subscription(price, metric: metric, currency: "USD"))
    XCTAssertEqual(allocation.allowanceCost, 1_200 * 7 / 365.2425, accuracy: 0.0000001)
    XCTAssertTrue(allocation.explanation.contains("365.2425"))
  }

  func testUnknownDurationsAndCurrencyMismatchDoNotInventCosts() {
    let price = SubscriptionPricing(amount: 200, currency: "CHF")
    XCTAssertNil(BenchmarkPriceAllocation.subscription(price, metric: UsageMetric(id: "weekly", label: "Weekly"), currency: "CHF"))
    let metric = UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 50, windowSeconds: 604_800)
    XCTAssertNil(BenchmarkPriceAllocation.subscription(price, metric: metric, currency: "USD"))
    XCTAssertNil(BenchmarkPriceAllocation.subscription(SubscriptionPricing(amount: -.infinity), metric: metric, currency: "USD"))
  }

  func testDefaultUsesLongestMeasuredWindowWithoutAddingOverlappingAllowances() {
    let metrics = [UsageMetric(id: "short", label: "5-hour", remainingPercent: 50, windowSeconds: 18_000),
                   UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 80, windowSeconds: 604_800),
                   UsageMetric(id: "unknown", label: "Monthly"),
                   UsageMetric(id: "unlimited", label: "Monthly", windowSeconds: 2_592_000, isUnlimited: true)]
    XCTAssertEqual(BenchmarkPriceAllocation.defaultMetricID(in: metrics), "weekly")
    XCTAssertNil(BenchmarkPriceAllocation.defaultMetricID(in: [metrics[2], metrics[3]]))
  }

  func testFreePriceAndOverflowRemainValidJSONNumbers() throws {
    let metric = UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 50, windowSeconds: 604_800)
    XCTAssertEqual(BenchmarkPriceAllocation.subscription(SubscriptionPricing(amount: 0), metric: metric, currency: "USD")?.allowanceCost, 0)
    let huge = UsageMetric(id: "long", label: "Long window", remainingPercent: 50, windowSeconds: Int.max)
    XCTAssertNil(BenchmarkPriceAllocation.subscription(SubscriptionPricing(amount: Double.greatestFiniteMagnitude), metric: huge, currency: "USD"))
  }
}
