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

  func testRemovingWebQuotaKeepsDailyEstimate() throws {
    let web = try XCTUnwrap(parse("""
      {"availableCredits":9000,"monthlyRefillCredits":7500,"usedThisCycle":3000,"nextRefillAt":1800000000000}
      """).metric(asOf: now))
    let daily = UsageMetric(id: "daily-diem", label: "Daily DIEM", remainingPercent: 80,
      remainingAmount: 16, estimatedTotal: 20)
    let account = ProviderUsage(accountID: "venice_test", provider: .venice, title: "Venice",
      metrics: [daily, web], maxUsagePercent: 25, fetchedAt: now)
    var other = account
    other.accountID = "venice_other"
    let snapshot = QuotaSnapshot(generatedAt: now, providers: [account, other], failures: [])
    let updated = snapshot.removingMetric(VeniceWebSubscription.metricID, forAccountID: account.accountID)

    XCTAssertEqual(updated.providers[0].metrics, [daily])
    XCTAssertEqual(updated.providers[0].maxUsagePercent, 20)
    XCTAssertEqual(updated.providers[1], other)
  }

  func testRestoreLostDailyEstimateFromSameKeyAndEpoch() throws {
    let reset = now.addingTimeInterval(3_600)
    let current = UsageMetric(id: "daily-diem", label: "Daily DIEM", remainingAmount: 0,
      estimateKeyHash: "same-key", resetAt: reset)
    var prior = current
    prior.estimatedTotal = 50
    prior.remainingPercent = 0
    let priorUsage = ProviderUsage(accountID: "venice_test", provider: .venice, title: "Venice",
      metrics: [prior], fetchedAt: now.addingTimeInterval(-60))
    let web = try XCTUnwrap(parse("""
      {"availableCredits":9000,"monthlyRefillCredits":7500,"usedThisCycle":3000,"nextRefillAt":1800000000000}
      """).metric(asOf: now))
    var usage = priorUsage
    usage.metrics = [current, web]
    usage.fetchedAt = now
    let snapshot = QuotaSnapshot(generatedAt: now, providers: [usage], failures: [])
    let priorSnapshot = QuotaSnapshot(generatedAt: priorUsage.fetchedAt, providers: [priorUsage], failures: [])
    let restored = snapshot.restoringVeniceDailyEstimates(from: [priorSnapshot], now: now)
    XCTAssertEqual(restored.providers[0].metrics[0].estimatedTotal, 50)
    XCTAssertEqual(restored.providers[0].metrics[0].remainingPercent, 0)
    XCTAssertEqual(restored.providers[0].metrics[1], web)
    XCTAssertEqual(restored.providers[0].fetchedAt, now)
    XCTAssertEqual(snapshot.restoringVeniceDailyEstimates(from: [priorSnapshot], now: reset), snapshot)

    var wrongKey = priorSnapshot
    wrongKey.providers[0].metrics[0].estimateKeyHash = "different-key"
    XCTAssertEqual(snapshot.restoringVeniceDailyEstimates(from: [wrongKey], now: now), snapshot)
    var wrongEpoch = priorSnapshot
    wrongEpoch.providers[0].metrics[0].resetAt = reset.addingTimeInterval(-86_400)
    XCTAssertEqual(snapshot.restoringVeniceDailyEstimates(from: [wrongEpoch], now: now), snapshot)
  }

  private func parse(_ json: String) throws -> VeniceWebSubscription {
    try JSONDecoder().decode(VeniceWebSubscription.self, from: Data(json.utf8))
  }
}
