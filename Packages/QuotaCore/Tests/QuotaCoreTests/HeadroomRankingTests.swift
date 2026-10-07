import XCTest
@testable import QuotaCore

// Scenarios retained from PR #108, with compound identity and shared freshness.
final class HeadroomRankingTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)
  private func usage(_ id: String, provider: QuotaProvider = .anthropic, age: TimeInterval = 300, _ metrics: [UsageMetric]) -> ProviderUsage {
    ProviderUsage(accountID: id, provider: provider, title: id, metrics: metrics, fetchedAt: now.addingTimeInterval(-age))
  }
  private func metric(_ id: String, _ percent: Int?, reset: TimeInterval? = nil, unlimited: Bool = false) -> UsageMetric {
    UsageMetric(id: id, label: id, remainingPercent: percent, resetAt: reset.map { now.addingTimeInterval($0) }, isUnlimited: unlimited)
  }
  private func rank(_ usages: [ProviderUsage], failures: [ProviderFailure] = [], filter: HeadroomRanking.Filter = .init()) -> HeadroomRanking.Ranking {
    HeadroomRanking.rank(snapshot: .init(generatedAt: now, providers: usages, failures: failures), filter: filter, now: now)
  }

  func testHeadroomIsLowestBoundedMetricAndKindFiltersIt() {
    let accounts = [usage("deep", [metric("session", 90), metric("weekly", 12)]), usage("even", [metric("session", 40), metric("weekly", 50)])]
    XCTAssertEqual(rank(accounts).candidates.map(\.accountID), ["even", "deep"])
    XCTAssertEqual(rank(accounts, filter: .init(kind: .session)).best?.accountID, "deep")
    XCTAssertEqual(rank(accounts).worst?.limitingMetrics.map(\.id), ["weekly"])
  }

  func testTiesUseLatestLimitingWindowThenSoonestAccountReset() {
    let both = usage("both", [metric("session", 30, reset: 3_600), metric("weekly", 30, reset: 6 * 86_400)])
    let sooner = usage("sooner", [metric("weekly", 30, reset: 3 * 86_400)])
    let unknown = usage("unknown", [metric("weekly", 30)])
    let ranking = rank([both, unknown, sooner])
    XCTAssertEqual(ranking.candidates.map(\.accountID), ["sooner", "both", "unknown"])
    XCTAssertEqual(ranking.candidates[1].resetAt, now.addingTimeInterval(6 * 86_400))
  }

  func testUnlimitedDoesNotHideBoundedLimitsAndAmountsDoNotRank() {
    let result = rank([
      usage("full", [metric("weekly", 100)]),
      usage("unlimited", [metric("plan", nil, unlimited: true)]),
      usage("mixed", [metric("chat", nil, unlimited: true), metric("weekly", 20)]),
      usage("credits", [UsageMetric(id: "credits", label: "Credits", usedDisplay: "$4.25")])
    ])
    XCTAssertEqual(result.candidates.map(\.accountID), ["unlimited", "full", "mixed"])
    XCTAssertEqual(result.exclusions.first?.reason, .noQuotaData)
  }

  func testFailurePriorityAndIdentityCurrentAndReportedEligibility() {
    let accounts = [usage("shared", [metric("weekly", 90)]), usage("shared", provider: .openAI, [metric("weekly", 40)]), usage("old", age: 10_800, [metric("weekly", 99)])]
    let failures = [ProviderFailure(accountID: "shared", provider: .anthropic, kind: .network, message: "offline"),
                    ProviderFailure(accountID: "shared", provider: .anthropic, kind: .auth, message: "expired")]
    let current = rank(accounts, failures: failures)
    XCTAssertEqual(current.candidates.map(\.usage.provider), [.openAI])
    XCTAssertEqual(current.exclusions.first(where: { $0.accountID == "shared" })?.reason, .failing(.auth))
    XCTAssertEqual(rank(accounts, failures: failures, filter: .init(eligibility: .anyReported)).candidates.count, 3)
    let key = QuotaAccountKey(provider: .openAI, accountID: "shared")
    XCTAssertEqual(rank(accounts, failures: failures, filter: .init(accountKeys: [key])).candidates.map(\.accountKey), [key])
    XCTAssertTrue(rank(accounts, filter: .init(accountKeys: [])).candidates.isEmpty)
  }

  func testStaleBoundaryAndDeterministicOrder() {
    let accounts = [usage("b", age: 600, [metric("weekly", 50)]), usage("a", age: 600, [metric("weekly", 50)])]
    XCTAssertEqual(rank(accounts, filter: .init(eligibility: .current(maxAge: 600))).candidates.map(\.accountID), ["a", "b"])
    XCTAssertTrue(rank(accounts, filter: .init(eligibility: .current(maxAge: 599))).candidates.isEmpty)
  }
}
