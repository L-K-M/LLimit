import XCTest
@testable import QuotaCore

final class CarriedWindowRegressionTests: XCTestCase {
  func testCarriedElapsedWindowDropsReadingButKeepsFutureWindow() throws {
    let fetched = Date(timeIntervalSince1970: 1_700_000_000)
    let old = ProviderUsage(accountID: "work", provider: .anthropic, title: "Work", metrics: [
      UsageMetric(id: "session", label: "Session", remainingPercent: 8, remainingAmount: 8,
                  estimatedTotal: 100, usedDisplay: "92%", resetAt: fetched.addingTimeInterval(600)),
      UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 60, resetAt: fetched.addingTimeInterval(86_400))
    ], maxUsagePercent: 92, fetchedAt: fetched)
    let previous = QuotaSnapshot(generatedAt: fetched, providers: [old], failures: [])
    let failed = QuotaSnapshot(generatedAt: fetched.addingTimeInterval(900), providers: [], failures: [
      ProviderFailure(accountID: "work", provider: .anthropic, kind: .auth, message: "expired")
    ])
    let carried = try XCTUnwrap(failed.mergingStaleUsage(from: previous).providers.first)
    XCTAssertNil(carried.metrics[0].remainingPercent)
    XCTAssertNil(carried.metrics[0].remainingAmount)
    XCTAssertNil(carried.metrics[0].estimatedTotal)
    XCTAssertNil(carried.metrics[0].usedDisplay)
    XCTAssertEqual(carried.metrics[0].resetAt, old.metrics[0].resetAt)
    XCTAssertEqual(carried.metrics[1], old.metrics[1])
    XCTAssertEqual(carried.maxUsagePercent, 40)
  }

  func testFailureCannotCarryAnotherProvidersSameAccountID() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let previous = QuotaSnapshot(generatedAt: now, providers: [ProviderUsage(
      accountID: "shared", provider: .openAI, title: "OpenAI", metrics: [], fetchedAt: now
    )], failures: [])
    let failed = QuotaSnapshot(generatedAt: now, providers: [], failures: [
      ProviderFailure(accountID: "shared", provider: .anthropic, kind: .network, message: "offline")
    ])
    XCTAssertTrue(failed.mergingStaleUsage(from: previous).providers.isEmpty)
  }
}
