import Foundation
import XCTest
@testable import QuotaCore

final class MiMoTokenPlanDecoderTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)
  private var detail: [String: Any] { ["planCode": "lite", "planName": "Lite", "expired": false] }
  private var ordinary: [String: Any] { ["name": "total_token", "used": 20, "limit": 100, "percent": 0.2] }

  private func decode(
    detail: [String: Any]? = nil,
    items: [[String: Any]]? = nil,
    detailCode: Int = 0,
    usageCode: Int = 0
  ) throws -> ProviderUsage {
    try decode(
      detailObject: ["code": detailCode, "data": detail ?? self.detail],
      usageObject: ["code": usageCode, "data": ["usage": ["items": items ?? [ordinary]]]]
    )
  }

  private func decode(detailObject: Any, usageObject: Any) throws -> ProviderUsage {
    try MiMoTokenPlanDecoder.decode(
      detailData: JSONSerialization.data(withJSONObject: detailObject),
      usageData: JSONSerialization.data(withJSONObject: usageObject),
      accountID: "personal-mimo", title: "My MiMo", now: now
    )
  }

  private func assertFailure(_ kind: QuotaErrorKind, file: StaticString = #filePath, line: UInt = #line,
                             _ body: () throws -> ProviderUsage) {
    XCTAssertThrowsError(try body(), file: file, line: line) { error in
      XCTAssertEqual((error as? ProviderClientError)?.kind, kind, file: file, line: line)
    }
  }

  func testUsedFractionProducesRemainingPercentageAndRawCreditCounts() throws {
    let usage = try decode()
    XCTAssertEqual(usage.provider, .xiaomiMiMo)
    XCTAssertEqual(usage.accountID, "personal-mimo")
    XCTAssertEqual(usage.title, "My MiMo")
    XCTAssertEqual(usage.subtitle, "Lite")
    XCTAssertEqual(usage.fetchedAt, now)
    XCTAssertEqual(usage.maxUsagePercent, 20)
    let metric = try XCTUnwrap(usage.metrics.first)
    XCTAssertEqual(metric.id, "plan-total_token")
    XCTAssertEqual(metric.label, "Plan credits")
    XCTAssertEqual(metric.remainingPercent, 80)
    XCTAssertEqual(metric.usageLine, "20 credits / 100 credits")
    XCTAssertNil(metric.remainingAmount)
    XCTAssertNil(metric.estimatedTotal)
    XCTAssertNil(metric.estimateKeyHash)
  }

  func testRemainingPercentageRoundsHalfUp() throws {
    let usage = try decode(items: [["name": "total_token", "percent": 0.125]])
    XCTAssertEqual(usage.metrics.first?.remainingPercent, 88)
  }

  func testMissingPercentFallsBackToReportedCountsWithoutScaling() throws {
    let usage = try decode(items: [["name": "total_token", "used": 1_025_000_000, "limit": 4_100_000_000]])
    XCTAssertEqual(usage.metrics.first?.remainingPercent, 75)
    XCTAssertEqual(usage.metrics.first?.usageLine, "1025000000 credits / 4100000000 credits")
  }

  func testPercentIsAuthoritativeWhenTotalsAreAbsentOrDisagree() throws {
    for item: [String: Any] in [
      ["name": "total_token", "percent": 0.2],
      ["name": "total_token", "used": 90, "limit": 100, "percent": 0.2],
      ["name": "total_token", "used": 0, "limit": 0, "percent": 0.2]
    ] {
      let metric = try XCTUnwrap(decode(items: [item]).metrics.first)
      XCTAssertEqual(metric.remainingPercent, 80)
      XCTAssertNil(metric.usedDisplay)
      XCTAssertNil(metric.totalDisplay)
    }
  }

  func testZeroUsageExhaustionAndOverageStayBounded() throws {
    for (fraction, expected) in [(0.0, 100), (1.0, 0), (1.25, 0), (1e308, 0)] {
      let usage = try decode(items: [["name": "total_token", "percent": fraction]])
      XCTAssertEqual(usage.metrics.first?.remainingPercent, expected)
      XCTAssertEqual(usage.maxUsagePercent, 100 - expected)
    }
    let overage = try decode(items: [["name": "total_token", "used": 125, "limit": 100, "percent": 1.25]])
    XCTAssertEqual(overage.metrics.first?.usageLine, "125 credits / 100 credits")
    XCTAssertEqual(overage.warning, "High usage")
  }

  func testExtremeFiniteCountsCannotOverflowPercentageConversion() throws {
    let usage = try decode(items: [["name": "total_token", "used": 1e308, "limit": 1e-308]])
    XCTAssertEqual(usage.metrics.first?.remainingPercent, 0)
  }

  func testCompensationQuotaRemainsSeparateAndSortsAfterPlan() throws {
    let bonus: [String: Any] = ["name": "compensation_total_token", "used": 5, "limit": 10, "percent": 0.5]
    let usage = try decode(items: [bonus, ordinary])
    XCTAssertEqual(usage.metrics.map(\.id), ["plan-total_token", "plan-compensation_total_token"])
    XCTAssertEqual(usage.metrics.map(\.label), ["Plan credits", "Bonus credits"])
    XCTAssertEqual(usage.metrics.map(\.remainingPercent), [80, 50])
    XCTAssertEqual(usage.metrics.last?.usageLine, "5 credits / 10 credits")
    let withoutBonus = try decode(items: [ordinary, ["name": "compensation_total_token", "limit": 0]])
    XCTAssertEqual(withoutBonus.metrics.count, 1)
  }

  func testDistinctPlanBucketsHaveStableOrderIDsAndLabels() throws {
    let a: [String: Any] = ["name": "alpha", "percent": 0.1]
    let z: [String: Any] = ["name": "zeta", "percent": 0.8]
    let first = try decode(items: [z, a])
    let reversed = try decode(items: [a, z])
    XCTAssertEqual(first.metrics, reversed.metrics)
    XCTAssertEqual(first.metrics.map(\.id), ["plan-alpha", "plan-zeta"])
    XCTAssertEqual(first.metrics.map(\.label), ["Plan credits (alpha)", "Plan credits (zeta)"])
    XCTAssertEqual(first.maxUsagePercent, 80)
  }

  func testAnnualPlanAndExpiryNeverCreateResetOrPace() throws {
    let usage = try decode(detail: [
      "planCode": "lite:year", "planName": "Lite Annual Plan", "expired": false,
      "currentPeriodEnd": "2027-11-01 03:04:05", "nextResetTime": "2026-12-01T00:00:00Z"
    ])
    let metric = try XCTUnwrap(usage.metrics.first)
    XCTAssertEqual(metric.detail, "Plan expires 2027-11-01 03:04:05")
    XCTAssertNil(metric.resetAt)
    XCTAssertNil(metric.resetIn)
    XCTAssertNil(metric.windowSeconds)
    XCTAssertNil(metric.paceEstimate)
    XCTAssertEqual(QuotaWindowKind.classify(metricID: metric.id, label: metric.label), .other)
  }

  func testExpiryTextPreservesReportedTimezoneAndDateOnlyPrecision() throws {
    for expiry in ["2027-11-01", "2027-11-01T03:04:05+08:00", "2027-11-01T03:04:05Z"] {
      let usage = try decode(detail: detail.merging(["currentPeriodEnd": expiry]) { _, new in new })
      XCTAssertEqual(usage.metrics.first?.detail, "Plan expires \(expiry)")
    }
  }

  func testInvalidOrSensitiveExpiryTextIsNotPublished() throws {
    for expiry in ["cookie-fixture-private", "2027-01-01\nCookie: fixture-private", "", String(repeating: "x", count: 300)] {
      let usage = try decode(detail: detail.merging(["currentPeriodEnd": expiry]) { _, new in new })
      XCTAssertNil(usage.metrics.first?.detail)
    }
    XCTAssertEqual(try decode(detail: ["planCode": "lite"]).subtitle, "Token Plan")
  }

  func testMissingBlankOrExpiredPlanFailsExplicitly() {
    for data: [String: Any] in [[:], ["planCode": ""], ["planCode": " \n"], ["planCode": "lite", "expired": true]] {
      assertFailure(.api) { try self.decode(detail: data) }
    }
  }

  func testMissingEmptyOrBonusOnlyZeroQuotaIsNotAFullPlan() {
    for items: [[String: Any]] in [[], [["name": "compensation_total_token", "limit": 0]]] {
      assertFailure(.decoding) { try self.decode(items: items) }
    }
    for payload: [String: Any] in [[:], ["usage": [:]], ["usage": ["items": NSNull()]]] {
      assertFailure(.decoding) {
        try self.decode(detailObject: ["code": 0, "data": self.detail], usageObject: ["code": 0, "data": payload])
      }
    }
  }

  func testDuplicateBlankAndControlCharacterNamesAreRejected() {
    for items: [[String: Any]] in [[ordinary, ordinary], [ordinary, ["name": " total_token ", "percent": 0.2]],
                                 [["name": "", "percent": 0.2]], [["name": "bad\nname", "percent": 0.2]],
                                 [["name": String(repeating: "x", count: 129), "percent": 0.2]]] {
      assertFailure(.decoding) { try self.decode(items: items) }
    }
  }

  func testInvalidNumericTypesAndNegativeBoundsAreRejected() {
    for patch: [String: Any] in [
      ["percent": -0.1], ["used": -1], ["limit": -1],
      ["percent": "0.2"], ["percent": true], ["used": "20"], ["limit": "100"], ["name": 42]
    ] {
      let item = ordinary.merging(patch) { _, new in new }
      assertFailure(.decoding) { try self.decode(items: [item]) }
    }
    assertFailure(.decoding) { try self.decode(items: [["name": "total_token", "used": 0, "limit": 0]]) }
    assertFailure(.decoding) { try self.decode(items: [["name": "total_token"]]) }
  }

  func testNonFiniteJSONNumbersAreRejectedWithoutLeakingPayload() throws {
    let detailData = try JSONSerialization.data(withJSONObject: ["code": 0, "data": detail])
    let usageData = Data(#"{"code":0,"data":{"usage":{"items":[{"name":"total_token","percent":1e999,"apiKey":"private-fixture"}]}}}"#.utf8)
    assertFailure(.decoding) {
      try MiMoTokenPlanDecoder.decode(detailData: detailData, usageData: usageData,
        accountID: "personal-mimo", title: "My MiMo", now: self.now)
    }
  }

  func testOnlyVerifiedSuccessWrappersAreAccepted() throws {
    XCTAssertEqual(try decode(detailCode: 200, usageCode: 200).metrics.first?.remainingPercent, 80)
    for status in [429, 400429] {
      assertFailure(.rateLimit) { try self.decode(detailCode: status) }
      assertFailure(.rateLimit) { try self.decode(usageCode: status) }
    }
    for status in [401, 400, 500, -1] {
      assertFailure(.api) { try self.decode(detailCode: status) }
      assertFailure(.api) { try self.decode(usageCode: status) }
    }
    assertFailure(.decoding) {
      try self.decode(detailObject: self.detail, usageObject: ["code": 0, "data": ["usage": ["items": [self.ordinary]]]])
    }
    assertFailure(.decoding) {
      try self.decode(detailObject: ["code": 0, "data": self.detail], usageObject: ["usage": ["items": [self.ordinary]]])
    }
  }

  func testUnknownAuthenticationFieldsAndServerMessagesNeverReachUsageOrErrors() throws {
    let privateValue = "mimo-decoder-private-fixture"
    let detail = self.detail.merging(["cookie": privateValue, "refreshToken": privateValue]) { _, new in new }
    let usage = try decode(detail: detail, items: [ordinary.merging(["apiKey": privateValue]) { _, new in new }])
    let saved = String(decoding: try JSONEncoder().encode(usage), as: UTF8.self)
    XCTAssertFalse(saved.contains(privateValue))
    XCTAssertFalse(saved.contains("refreshToken"))
    for code in [429, 401, 0] {
      do {
        _ = try decode(detailObject: ["code": code, "message": privateValue], usageObject: [:])
        XCTFail("Invalid envelope was accepted")
      } catch {
        XCTAssertFalse(error.localizedDescription.contains(privateValue))
      }
    }
  }
}
