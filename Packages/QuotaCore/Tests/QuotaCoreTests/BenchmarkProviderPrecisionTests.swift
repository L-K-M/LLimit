import Foundation
import XCTest
@testable import QuotaCore

final class BenchmarkProviderPrecisionTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private func mimo(used: Double? = nil, limit: Double? = nil, percent: Double?) throws -> ProviderUsage {
    var item: [String: Any] = ["name": "credits"]
    item["used"] = used
    item["limit"] = limit
    item["percent"] = percent
    return try MiMoTokenPlanDecoder.decode(
      detailData: JSONSerialization.data(withJSONObject: ["code": 0, "data": ["planCode": "lite"]]),
      usageData: JSONSerialization.data(withJSONObject: ["code": 0, "data": ["usage": ["items": [item]]]]),
      accountID: "mimo", title: "MiMo", now: now)
  }

  private func stepFun(residual: Int? = nil, fraction: Double) throws -> ProviderUsage {
    var credits: [String: Any] = ["subscription_credit_left_rate": fraction]
    if let residual {
      credits["credit_buckets"] = [["type": 1, "credit_total": 10_000, "credit_residual": residual]]
    }
    let data = try JSONSerialization.data(withJSONObject: ["status": 1, "plan_family": 2,
      "plan_credit_rate_limit": credits])
    return try StepFunQuotaDecoder.decode(data,
      configuration: ProviderRuntimeConfiguration(accountID: "stepfun", provider: .stepFun, isEnabled: true, credentials: [:]),
      now: now)
  }

  func testMiMoSubpercentConsumptionSurvivesWholePercentRounding() throws {
    let before = try mimo(used: 1_000, limit: 10_000, percent: 0.1)
    var after = try mimo(used: 1_001, limit: 10_000, percent: 0.1001)
    after.fetchedAt = now.addingTimeInterval(1)
    XCTAssertEqual(before.metrics[0].remainingPercent, 90)
    XCTAssertEqual(after.metrics[0].remainingPercent, 90)
    XCTAssertEqual(after.metrics[0].remainingAmount, 8_999)
    XCTAssertEqual(after.metrics[0].totalAmount, 10_000)
    let change = BenchmarkQuotaChange.changes(before: before, after: after)[0]
    XCTAssertEqual(change.consumedAmount, 1)
    XCTAssertEqual(try XCTUnwrap(change.consumedPercentagePoints), 0.01, accuracy: 0.000000001)
  }

  func testMiMoProviderFractionWinsOverNearbyCountDifference() throws {
    let metric = try XCTUnwrap(mimo(used: 2_050, limit: 10_000, percent: 0.2).metrics.first)
    XCTAssertEqual(metric.remainingAmount, 7_950)
    XCTAssertEqual(metric.totalAmount, 10_000)
    XCTAssertEqual(metric.remainingFraction, 0.8)
  }

  func testMiMoMissingOrConflictingCountsDoNotReplaceReportedFraction() throws {
    for usage in [try mimo(percent: 0.2), try mimo(used: 9_000, limit: 10_000, percent: 0.2)] {
      let metric = try XCTUnwrap(usage.metrics.first)
      XCTAssertNil(metric.remainingAmount)
      XCTAssertNil(metric.totalAmount)
      XCTAssertEqual(metric.remainingFraction, 0.8)
    }
  }

  func testMiMoCountsFallbackAndOverageRemainBounded() throws {
    let fallback = try XCTUnwrap(mimo(used: 1_000, limit: 10_000, percent: nil).metrics.first)
    XCTAssertNil(fallback.reportedRemainingFraction)
    XCTAssertEqual(fallback.remainingAmount, 9_000)
    XCTAssertEqual(fallback.totalAmount, 10_000)
    XCTAssertEqual(fallback.remainingFraction, 0.9)
    let overage = try XCTUnwrap(mimo(used: 12_000, limit: 10_000, percent: 1.2).metrics.first)
    XCTAssertEqual(overage.remainingAmount, 0)
    XCTAssertEqual(overage.totalAmount, 10_000)
    XCTAssertEqual(overage.remainingFraction, 0)
  }

  func testStepFunSubpercentConsumptionSurvivesWholePercentRounding() throws {
    let before = try stepFun(residual: 8_000, fraction: 0.8)
    var after = try stepFun(residual: 7_999, fraction: 0.7999)
    after.fetchedAt = now.addingTimeInterval(1)
    XCTAssertEqual(before.metrics[0].remainingPercent, 80)
    XCTAssertEqual(after.metrics[0].remainingPercent, 80)
    XCTAssertEqual(after.metrics[0].remainingAmount, 7_999)
    XCTAssertEqual(after.metrics[0].totalAmount, 10_000)
    let change = BenchmarkQuotaChange.changes(before: before, after: after)[0]
    XCTAssertEqual(change.consumedAmount, 1)
    XCTAssertEqual(try XCTUnwrap(change.consumedPercentagePoints), 0.01, accuracy: 0.000000001)
  }

  func testStepFunProviderFractionWinsOverNearbyCountDifference() throws {
    let metric = try XCTUnwrap(stepFun(residual: 7_950, fraction: 0.8).metrics.first)
    XCTAssertEqual(metric.remainingAmount, 7_950)
    XCTAssertEqual(metric.totalAmount, 10_000)
    XCTAssertEqual(metric.remainingFraction, 0.8)
  }

  func testStepFunMissingOrConflictingCountsDoNotReplaceReportedFraction() throws {
    for usage in [try stepFun(fraction: 0.5), try stepFun(residual: 9_000, fraction: 0.5)] {
      let metric = try XCTUnwrap(usage.metrics.first)
      XCTAssertNil(metric.remainingAmount)
      XCTAssertNil(metric.totalAmount)
      XCTAssertEqual(metric.remainingFraction, 0.5)
    }
  }
}
