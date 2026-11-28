import Foundation
import XCTest
@testable import QuotaCore

final class VeniceWebSubscriptionTests: XCTestCase {
  private let refill = Date(timeIntervalSince1970: 1_800_000_000)
  private var now: Date { refill.addingTimeInterval(-864_000) }

  func testRolloverUsesBalancePlusCurrentCycleSpending() throws {
    let metric = try XCTUnwrap(parse("""
      {"availableCredits":9000,"monthlyRefillCredits":7500,"usedThisCycle":3000,
       "tierCap":15000,"nextRefillAt":1800000000000}
      """).metric(asOf: now))
    XCTAssertEqual(metric.remainingPercent, 75)
    XCTAssertEqual(metric.remainingFraction, 0.75)
    XCTAssertEqual(metric.remainingAmount, 9_000)
    XCTAssertEqual(metric.totalAmount, 12_000)
    XCTAssertEqual(metric.refillAt, refill)
    XCTAssertEqual(metric.paceWindow?.end, refill)
    XCTAssertNil(metric.resetAt)
    XCTAssertNil(metric.expiresAt)
    XCTAssertFalse(metric.isPercentageEstimated)

    let usage = ProviderUsage(accountID: "venice_test", provider: .venice, title: "Venice",
      metrics: [metric, UsageMetric(id: "daily-diem", label: "Daily DIEM", remainingPercent: 40)], fetchedAt: now)
    let account = ProviderAccount(id: usage.accountID, provider: .venice, credentials: [
      CredentialField.veniceCreditAllowance: "75",
      CredentialField.veniceRefillAt: "2027-01-01",
      CredentialField.veniceWebProfile: UUID().uuidString,
      CredentialField.veniceWebUserID: "test-identity"
    ])
    let snapshot = QuotaSnapshot(generatedAt: now, providers: [usage], failures: [])
      .applyingVeniceSubscriptionAllowances(from: [account])
    XCTAssertEqual(snapshot.providers, [usage])
    XCTAssertEqual(defaultRingMetrics(for: usage).map(\.id), ["daily-diem", VeniceWebSubscription.metricID])
    XCTAssertTrue(account.redactedCredentials().credentials.isEmpty)
    XCTAssertEqual(usage.clearingElapsedWindows(at: refill).metrics.first, metric)
    XCTAssertEqual(try JSONDecoder().decode(UsageMetric.self, from: JSONEncoder().encode(metric)), metric)
  }

  func testZeroBalanceAndUnreportedRefill() throws {
    let metric = try XCTUnwrap(parse("""
      {"availableCredits":0,"monthlyRefillCredits":7500,"usedThisCycle":7500,"nextRefillAt":0}
      """).metric(asOf: now))
    XCTAssertEqual(metric.remainingPercent, 0)
    XCTAssertNil(metric.refillAt)
    XCTAssertNil(metric.paceWindow)
  }

  func testNoPlanOrNoPercentageBasis() throws {
    XCTAssertNil(try parse("""
      {"monthlyRefillCredits":0,"usedThisCycle":0,"nextRefillAt":0}
      """).metric(asOf: now))
    let metric = try XCTUnwrap(parse("""
      {"availableCredits":0,"monthlyRefillCredits":7500,"usedThisCycle":0,"nextRefillAt":1800000000000}
      """).metric(asOf: now))
    XCTAssertNil(metric.remainingPercent)
    XCTAssertEqual(metric.refillAt, refill)
  }

  func testInvalidValuesFailClosed() throws {
    XCTAssertThrowsError(try parse("""
      {"availableCredits":30,"monthlyRefillCredits":7500,"usedThisCycle":-1,"nextRefillAt":1800000000000}
      """).metric(asOf: now))
    XCTAssertThrowsError(try parse("""
      {"availableCredits":true,"monthlyRefillCredits":7500,"usedThisCycle":0,"nextRefillAt":1800000000000}
      """))
  }

  private func parse(_ json: String) throws -> VeniceWebSubscription {
    try JSONDecoder().decode(VeniceWebSubscription.self, from: Data(json.utf8))
  }
}
