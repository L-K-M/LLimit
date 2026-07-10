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
