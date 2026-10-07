import XCTest
@testable import QuotaCore

final class SnapshotMergeTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

  private func usage(_ accountID: String, provider: QuotaProvider, remaining: Int, at: Date) -> ProviderUsage {
    ProviderUsage(
      accountID: accountID,
      provider: provider,
      title: provider.displayName,
      metrics: [UsageMetric(id: "m", label: "limit", remainingPercent: remaining)],
      maxUsagePercent: 100 - remaining,
      fetchedAt: at
    )
  }

  private func failure(_ accountID: String, provider: QuotaProvider) -> ProviderFailure {
    ProviderFailure(accountID: accountID, provider: provider, kind: .auth, message: "boom")
  }

  func testCarriesForwardLastGoodUsageForFailedAccount() {
    let previous = QuotaSnapshot(
      generatedAt: t0,
      providers: [usage("claude-1", provider: .anthropic, remaining: 60, at: t0)],
      failures: []
    )
    let fresh = QuotaSnapshot(
      generatedAt: t0.addingTimeInterval(900),
      providers: [usage("zai-1", provider: .zai, remaining: 80, at: t0.addingTimeInterval(900))],
      failures: [failure("claude-1", provider: .anthropic)]
    )

    let merged = fresh.mergingStaleUsage(from: previous)

    // Fresh Z.ai stays, stale Claude usage is carried back in, and the failure is preserved.
    XCTAssertEqual(Set(merged.providers.map(\.accountID)), ["zai-1", "claude-1"])
    XCTAssertEqual(merged.failures.map(\.accountID), ["claude-1"])
    let carried = merged.providers.first { $0.accountID == "claude-1" }
    XCTAssertEqual(carried?.metrics.first?.remainingPercent, 60)
    XCTAssertEqual(carried?.fetchedAt, t0) // original (stale) timestamp preserved
    XCTAssertEqual(merged.generatedAt, fresh.generatedAt)
  }

  func testDoesNotShadowAFreshSuccessWithStaleData() {
    let previous = QuotaSnapshot(
      generatedAt: t0,
      providers: [usage("claude-1", provider: .anthropic, remaining: 10, at: t0)],
      failures: []
    )
    // Same account succeeds this cycle — the fresh value must win.
    let fresh = QuotaSnapshot(
      generatedAt: t0.addingTimeInterval(900),
      providers: [usage("claude-1", provider: .anthropic, remaining: 95, at: t0.addingTimeInterval(900))],
      failures: []
    )

    let merged = fresh.mergingStaleUsage(from: previous)
    XCTAssertEqual(merged.providers.count, 1)
    XCTAssertEqual(merged.providers.first?.metrics.first?.remainingPercent, 95)
  }

  func testNoPreviousReturnsSelfUnchanged() {
    let fresh = QuotaSnapshot(
      generatedAt: t0,
      providers: [],
      failures: [failure("claude-1", provider: .anthropic)]
    )
    XCTAssertEqual(fresh.mergingStaleUsage(from: nil), fresh)
  }

  func testFailureWithoutPriorUsageIsNotFabricated() {
    let previous = QuotaSnapshot(generatedAt: t0, providers: [], failures: [])
    let fresh = QuotaSnapshot(
      generatedAt: t0.addingTimeInterval(900),
      providers: [],
      failures: [failure("copilot-1", provider: .gitHubCopilot)]
    )
    let merged = fresh.mergingStaleUsage(from: previous)
    XCTAssertTrue(merged.providers.isEmpty)
  }

  func testCarriedWindowPastItsResetLosesItsPreResetReading() throws {
    let elapsedReset = t0.addingTimeInterval(600)
    let futureReset = t0.addingTimeInterval(86_400)
    let previous = QuotaSnapshot(
      generatedAt: t0,
      providers: [ProviderUsage(
        accountID: "claude-1", provider: .anthropic, title: "Claude",
        metrics: [
          UsageMetric(id: "five-hour", label: "5-hour limit", remainingPercent: 8, remainingAmount: 8,
                      estimatedTotal: 100, usedDisplay: "92% used", totalDisplay: "100%",
                      resetAt: elapsedReset, resetIn: "10m"),
          UsageMetric(id: "weekly", label: "Weekly limit", remainingPercent: 60, usedDisplay: "40% used",
                      resetAt: futureReset, resetIn: "1d")
        ],
        maxUsagePercent: 92, fetchedAt: t0
      )],
      failures: []
    )
    let fresh = QuotaSnapshot(
      generatedAt: t0.addingTimeInterval(900),
      providers: [],
      failures: [failure("claude-1", provider: .anthropic)]
    )

    let carried = try XCTUnwrap(fresh.mergingStaleUsage(from: previous).providers.first)

    // The 5-hour window reset after the last success, so its 8% is known to be wrong.
    let elapsed = carried.metrics[0]
    XCTAssertNil(elapsed.remainingPercent)
    XCTAssertNil(elapsed.remainingAmount)
    XCTAssertNil(elapsed.estimatedTotal)
    XCTAssertNil(elapsed.usedDisplay)
    XCTAssertNil(elapsed.resetIn)
    XCTAssertEqual(elapsed.resetAt, elapsedReset)
    XCTAssertEqual(elapsed.totalDisplay, "100%")
    XCTAssertEqual(elapsed.detail, "Window reset since the last successful refresh")
    // A window that has not reset yet keeps its last-known reading.
    XCTAssertEqual(carried.metrics[1], previous.providers[0].metrics[1])
    XCTAssertEqual(carried.maxUsagePercent, 40)
    XCTAssertEqual(carried.fetchedAt, t0)
  }

  func testCarriedUsageWithEveryWindowElapsedHasNoMaxUsage() throws {
    var previousUsage = usage("claude-1", provider: .anthropic, remaining: 8, at: t0)
    previousUsage.metrics[0].resetAt = t0.addingTimeInterval(900)
    let previous = QuotaSnapshot(generatedAt: t0, providers: [previousUsage], failures: [])
    // A reset exactly at the refresh time has already happened.
    let fresh = QuotaSnapshot(
      generatedAt: t0.addingTimeInterval(900),
      providers: [],
      failures: [failure("claude-1", provider: .anthropic)]
    )

    let carried = try XCTUnwrap(fresh.mergingStaleUsage(from: previous).providers.first)

    XCTAssertNil(carried.metrics[0].remainingPercent)
    XCTAssertNil(carried.maxUsagePercent)
  }

  func testCarriedReadingTakenAfterItsResetIsKept() throws {
    // The provider reported a reset time at or before the fetch (clock skew, or a fetch
    // just after a rollover): the reading already describes the current window.
    var previousUsage = usage("claude-1", provider: .anthropic, remaining: 8, at: t0)
    previousUsage.metrics[0].resetAt = t0
    let previous = QuotaSnapshot(generatedAt: t0, providers: [previousUsage], failures: [])
    let fresh = QuotaSnapshot(
      generatedAt: t0.addingTimeInterval(900),
      providers: [],
      failures: [failure("claude-1", provider: .anthropic)]
    )

    XCTAssertEqual(fresh.mergingStaleUsage(from: previous).providers, [previousUsage])
  }

  func testCarriedUnlimitedAndResetlessMetricsAreNeverCleared() throws {
    let unlimited = UsageMetric(id: "unlimited", label: "Unlimited", resetAt: t0.addingTimeInterval(60),
                                isUnlimited: true)
    let resetless = UsageMetric(id: "no-reset", label: "No reset", remainingPercent: 40, usedDisplay: "60%")
    var previousUsage = usage("claude-1", provider: .anthropic, remaining: 8, at: t0)
    previousUsage.metrics = [unlimited, resetless]
    let previous = QuotaSnapshot(generatedAt: t0, providers: [previousUsage], failures: [])
    let fresh = QuotaSnapshot(
      generatedAt: t0.addingTimeInterval(900),
      providers: [],
      failures: [failure("claude-1", provider: .anthropic)]
    )

    XCTAssertEqual(fresh.mergingStaleUsage(from: previous).providers, [previousUsage])
  }

  func testFreshUsageIsNotClearedByTheCarryRule() {
    var freshUsage = usage("claude-1", provider: .anthropic, remaining: 8, at: t0.addingTimeInterval(900))
    freshUsage.metrics[0].resetAt = t0
    let previous = QuotaSnapshot(generatedAt: t0, providers: [], failures: [])
    let fresh = QuotaSnapshot(
      generatedAt: t0.addingTimeInterval(900),
      providers: [freshUsage],
      failures: [failure("zai-1", provider: .zai)]
    )

    XCTAssertEqual(fresh.mergingStaleUsage(from: previous).providers, [freshUsage])
  }

  func testReconcileRemovesInactiveAccountsAndUpdatesNames() {
    let current = QuotaSnapshot(
      generatedAt: t0,
      providers: [
        usage("claude-1", provider: .anthropic, remaining: 60, at: t0),
        usage("openai-1", provider: .openAI, remaining: 70, at: t0)
      ],
      failures: [failure("openai-1", provider: .openAI)]
    )
    let activeAccounts = [
      ProviderAccount(id: "claude-1", provider: .anthropic, displayName: "Work Claude")
    ]

    let reconciled = current.reconciled(with: activeAccounts)

    XCTAssertEqual(reconciled.generatedAt, t0)
    XCTAssertEqual(reconciled.providers.map(\.accountID), ["claude-1"])
    XCTAssertEqual(reconciled.providers.first?.title, "Work Claude")
    XCTAssertTrue(reconciled.failures.isEmpty)
  }

  func testReconcileRenamesFailures() {
    let current = QuotaSnapshot(
      generatedAt: t0,
      providers: [],
      failures: [ProviderFailure(accountID: "claude-1", provider: .anthropic, kind: .auth,
                                 message: "boom", title: "Old name")]
    )
    let account = ProviderAccount(id: "claude-1", provider: .anthropic, displayName: "Work Claude")

    XCTAssertEqual(current.reconciled(with: [account]).failures.first?.title, "Work Claude")
  }

  func testFailureTitleIsOptionalWhenDecoding() throws {
    let legacy = Data(#"{"accountID":"a","provider":"kimi","kind":"auth","message":"m"}"#.utf8)
    XCTAssertNil(try JSONDecoder().decode(ProviderFailure.self, from: legacy).title)

    let titled = ProviderFailure(accountID: "a", provider: .kimi, kind: .auth, message: "m", title: "Kimi Work")
    let decoded = try JSONDecoder().decode(ProviderFailure.self, from: JSONEncoder().encode(titled))
    XCTAssertEqual(decoded, titled)
  }

  func testReconcileMapsLegacyProviderKeyForSoleAccount() {
    let current = QuotaSnapshot(
      generatedAt: t0,
      providers: [usage(QuotaProvider.openAI.rawValue, provider: .openAI, remaining: 70, at: t0)],
      failures: []
    )
    let account = ProviderAccount(id: "openai-1", provider: .openAI, displayName: "Personal")

    let reconciled = current.reconciled(with: [account])

    XCTAssertEqual(reconciled.providers.first?.accountID, "openai-1")
    XCTAssertEqual(reconciled.providers.first?.title, "Personal")
  }
}
