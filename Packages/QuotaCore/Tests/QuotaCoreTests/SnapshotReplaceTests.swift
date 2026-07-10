import XCTest
@testable import QuotaCore

final class SnapshotReplaceTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

  private func usage(_ accountID: String, provider: QuotaProvider, remaining: Int) -> ProviderUsage {
    ProviderUsage(
      accountID: accountID,
      provider: provider,
      title: provider.displayName,
      metrics: [UsageMetric(id: "m", label: "limit", remainingPercent: remaining)],
      maxUsagePercent: 100 - remaining,
      fetchedAt: t0
    )
  }

  private func failure(_ accountID: String, provider: QuotaProvider) -> ProviderFailure {
    ProviderFailure(accountID: accountID, provider: provider, kind: .auth, message: "boom")
  }

  func testSplicesRetriedAccountAndLeavesOthersUntouched() {
    // Full snapshot: Z.ai OK, OpenAI failed.
    let base = QuotaSnapshot(
      generatedAt: t0,
      providers: [usage("zai-1", provider: .zai, remaining: 80)],
      failures: [failure("openai-1", provider: .openAI)]
    )
    // OpenAI-only retry that now succeeds.
    let retry = QuotaSnapshot(
      generatedAt: t0,
      providers: [usage("openai-1", provider: .openAI, remaining: 55)],
      failures: []
    )

    let result = base.replacingResults(forAccountIDs: ["openai-1"], from: retry)

    // Z.ai untouched; OpenAI failure replaced by fresh usage.
    XCTAssertEqual(Set(result.providers.map(\.accountID)), ["zai-1", "openai-1"])
    XCTAssertTrue(result.failures.isEmpty)
    XCTAssertEqual(result.providers.first { $0.accountID == "openai-1" }?.metrics.first?.remainingPercent, 55)
  }

  func testStillFailingRetryReplacesOnlyItsOwnEntries() {
    let base = QuotaSnapshot(
      generatedAt: t0,
      providers: [usage("zai-1", provider: .zai, remaining: 80), usage("openai-1", provider: .openAI, remaining: 40)],
      failures: []
    )
    // Retry still fails but carries stale usage (as mergingStaleUsage would produce).
    let retry = QuotaSnapshot(
      generatedAt: t0,
      providers: [usage("openai-1", provider: .openAI, remaining: 40)],
      failures: [failure("openai-1", provider: .openAI)]
    )

    let result = base.replacingResults(forAccountIDs: ["openai-1"], from: retry)

    XCTAssertEqual(result.providers.filter { $0.accountID == "zai-1" }.count, 1)
    XCTAssertEqual(result.failures.map(\.accountID), ["openai-1"])
    // Stale OpenAI usage retained alongside the failure.
    XCTAssertEqual(result.providers.filter { $0.accountID == "openai-1" }.count, 1)
  }

  func testEmptyAccountIDsIsNoOp() {
    let base = QuotaSnapshot(
      generatedAt: t0,
      providers: [usage("zai-1", provider: .zai, remaining: 80)],
      failures: []
    )
    let result = base.replacingResults(forAccountIDs: [], from: QuotaSnapshot(generatedAt: t0, providers: [], failures: []))
    XCTAssertEqual(result, base)
  }
}
