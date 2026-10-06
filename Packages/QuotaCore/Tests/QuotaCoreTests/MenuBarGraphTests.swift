import XCTest
@testable import QuotaCore

final class MenuBarGraphTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private let staleAfter: TimeInterval = 3_600

  private let accounts = [
    ProviderAccount(id: "zai", provider: .zai, displayName: "Team"),
    ProviderAccount(id: "claude", provider: .anthropic, displayName: "Personal"),
    ProviderAccount(id: "openai", provider: .openAI, displayName: "Work", isEnabled: false),
    ProviderAccount(id: "openai-second", provider: .openAI, displayName: "Second")
  ]

  // MARK: - Projection and ordering

  func testBarsMatchUsageProjectionInSettingsOrder() {
    let usages = [
      usage(accounts[3], remaining: 70),
      usage(accounts[2], remaining: 10),
      usage(accounts[1], remaining: 40),
      usage(accounts[0], remaining: 90)
    ]
    let result = bars(providers: usages)

    let projected = orderedUsageForAccounts(usages, accounts: accounts)
    XCTAssertEqual(result.map(\.accountID), projected.map(\.accountID))
    XCTAssertEqual(result.compactMap(\.usage), projected)
    XCTAssertEqual(result.map(\.title), ["Team", "Personal", "Second"])

    let moved = reorderedAccounts(accounts, fromOffsets: IndexSet(integer: 3), toOffset: 0)
    XCTAssertEqual(
      MenuBarGraph.bars(snapshot: snapshot(providers: usages), accounts: moved, now: now, staleAfter: staleAfter)
        .map(\.accountID),
      ["openai-second", "zai", "claude"]
    )
  }

  func testDisabledAndUnreportedAccountsDrawNoBar() {
    let result = bars(
      providers: [usage(accounts[1], remaining: 40)],
      failures: [failure(accounts[2], kind: .auth)]
    )
    XCTAssertEqual(result.map(\.accountID), ["claude"])
    XCTAssertTrue(bars(providers: []).isEmpty)
    XCTAssertTrue(MenuBarGraph.bars(snapshot: nil, accounts: accounts, now: now, staleAfter: staleAfter).isEmpty)
  }

  // MARK: - Failures and staleness

  func testCarriedFailureKeepsLastKnownLevelButIsFailing() {
    let result = bars(
      providers: [usage(accounts[1], remaining: 42)],
      failures: [failure(accounts[1], kind: .auth)]
    )
    XCTAssertEqual(result.count, 1)
    XCTAssertEqual(result[0].freshness, .failing(.auth))
    XCTAssertEqual(result[0].level, .remaining(percent: 42, isEstimated: false))
    XCTAssertEqual(
      MenuBarGraph.tooltip(for: result),
      "LLimit: 1 account, 1 failing\nPersonal: authentication failed, last known 42% remaining"
    )
  }

  func testFailureWithoutUsageGetsItsOwnBarInSettingsOrder() {
    let result = bars(
      providers: [usage(accounts[0], remaining: 90), usage(accounts[3], remaining: 70)],
      failures: [failure(accounts[1], kind: .network)]
    )
    XCTAssertEqual(result.map(\.accountID), ["zai", "claude", "openai-second"])
    XCTAssertEqual(result[1].level, .unavailable)
    XCTAssertEqual(result[1].freshness, .failing(.network))
    XCTAssertNil(result[1].usage)
    XCTAssertNil(MenuBarGraph.barHeight(for: result[1].level, fullHeight: 16))
  }

  func testEveryAccountFailingStillDrawsOneBarPerEnabledAccount() {
    let result = bars(failures: accounts.map { failure($0, kind: .api) })
    XCTAssertEqual(result.map(\.accountID), ["zai", "claude", "openai-second"])
    XCTAssertTrue(result.allSatisfy { $0.freshness == .failing(.api) && $0.level == .unavailable })
    XCTAssertEqual(
      MenuBarGraph.accessibilityLabel(for: result),
      "LLimit: 3 accounts, 3 failing. Team: provider error, no quota data. "
        + "Personal: provider error, no quota data. Second: provider error, no quota data."
    )
  }

  func testOldUsageWithoutFailureIsStale() {
    let fresh = usage(accounts[0], remaining: 90, fetchedAt: now.addingTimeInterval(-staleAfter))
    let old = usage(accounts[1], remaining: 40, fetchedAt: now.addingTimeInterval(-staleAfter - 1))
    let result = bars(providers: [fresh, old])
    XCTAssertEqual(result.map(\.freshness), [.current, .stale])
    XCTAssertEqual(result[1].level, .remaining(percent: 40, isEstimated: false))
  }

  func testWindowResetSinceFetchMarksUsageStale() {
    var reset = usage(accounts[0], remaining: 5)
    reset.metrics[0].resetAt = now
    var pending = usage(accounts[1], remaining: 5)
    pending.metrics[0].resetAt = now.addingTimeInterval(60)
    XCTAssertEqual(bars(providers: [reset, pending]).map(\.freshness), [.stale, .current])
  }

  func testLegacyProviderKeyedFailureBelongsOnlyToSoleAccount() {
    let sole = ProviderAccount(id: "personal", provider: .anthropic)
    let legacy = ProviderFailure(provider: .anthropic, kind: .auth, message: "expired")
    let soleBars = MenuBarGraph.bars(
      snapshot: snapshot(failures: [legacy]), accounts: [sole], now: now, staleAfter: staleAfter
    )
    XCTAssertEqual(soleBars.map(\.accountID), ["personal"])
    XCTAssertEqual(soleBars.first?.freshness, .failing(.auth))

    let second = ProviderAccount(id: "team", provider: .anthropic, isEnabled: false)
    XCTAssertTrue(
      MenuBarGraph.bars(
        snapshot: snapshot(failures: [legacy]), accounts: [sole, second], now: now, staleAfter: staleAfter
      ).isEmpty
    )
  }

  func testStaleIntervalMatchesProviderTileRule() {
    XCTAssertEqual(MenuBarGraph.staleInterval(refreshIntervalMinutes: 15), 3_600)
    XCTAssertEqual(MenuBarGraph.staleInterval(refreshIntervalMinutes: 30), 3_600)
    XCTAssertEqual(MenuBarGraph.staleInterval(refreshIntervalMinutes: 60), 7_200)
    XCTAssertEqual(MenuBarGraph.staleInterval(refreshIntervalMinutes: 180), 21_600)
    XCTAssertEqual(MenuBarGraph.staleInterval(refreshIntervalMinutes: 1), 3_600)
    XCTAssertEqual(MenuBarGraph.staleInterval(refreshIntervalMinutes: 999), 21_600)
  }

  // MARK: - Level

  func testLevelUsesMostConstrainedBoundedWindowThenFallbacks() {
    var mixed = usage(accounts[0], remaining: 80)
    mixed.metrics.append(UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 12, estimatedTotal: 50))
    mixed.metrics.append(UsageMetric(id: "bonus", label: "Bonus", isUnlimited: true))

    let unlimited = ProviderUsage(
      accountID: "claude", provider: .anthropic, title: "Personal",
      metrics: [UsageMetric(id: "all", label: "All", isUnlimited: true)], fetchedAt: now
    )
    let usedOnly = ProviderUsage(
      accountID: "openai-second", provider: .openAI, title: "Second",
      metrics: [], maxUsagePercent: 130, fetchedAt: now
    )

    XCTAssertEqual(
      bars(providers: [mixed, unlimited, usedOnly]).map(\.level),
      [.remaining(percent: 12, isEstimated: true), .unlimited, .remaining(percent: 0, isEstimated: false)]
    )
  }

  func testBarHeightSeparatesLowPercentagesAndKeepsZeroEmpty() {
    func height(_ percent: Int) -> Double? {
      MenuBarGraph.barHeight(for: .remaining(percent: percent, isEstimated: false), fullHeight: 16)
    }

    XCTAssertEqual(height(0), 0)
    XCTAssertEqual(height(-5), 0)
    XCTAssertEqual(height(100), 16)
    XCTAssertEqual(height(150), 16)
    XCTAssertEqual(MenuBarGraph.barHeight(for: .unlimited, fullHeight: 16), 16)
    XCTAssertNil(MenuBarGraph.barHeight(for: .amountOnly, fullHeight: 16))
    XCTAssertNil(MenuBarGraph.barHeight(for: .unavailable, fullHeight: 16))

    // The old 2 pt floor drew every value up to 12% identically.
    let heights = (0...100).compactMap(height)
    XCTAssertEqual(heights.count, 101)
    for (lower, higher) in zip(heights, heights.dropFirst()) {
      XCTAssertLessThan(lower, higher)
    }
    XCTAssertGreaterThanOrEqual(height(1) ?? 0, 1)
    XCTAssertGreaterThan((height(12) ?? 0) - (height(1) ?? 0), 1)
  }

  // MARK: - Summary

  func testSummaryNamesEveryAccountWithStateAndCounts() {
    var estimated = usage(accounts[0], remaining: 30)
    estimated.metrics[0].estimatedTotal = 20
    let balance = ProviderUsage(
      accountID: "openai-second", provider: .openAI, title: "Second",
      metrics: [UsageMetric(id: "usd", label: "USD", usedDisplay: "$4.25")],
      fetchedAt: now.addingTimeInterval(-2 * staleAfter)
    )
    let result = bars(
      providers: [estimated, usage(accounts[1], remaining: 0), balance],
      failures: [failure(accounts[1], kind: .rateLimit)]
    )

    XCTAssertEqual(
      MenuBarGraph.tooltip(for: result),
      """
      LLimit: 3 accounts, 1 failing, 1 stale
      Team: estimated 30% remaining
      Personal: rate limited, last known 0% remaining
      Second: USD $4.25, data is stale
      """
    )
    XCTAssertEqual(MenuBarGraph.tooltip(for: []), "LLimit: no quota data")
    XCTAssertEqual(MenuBarGraph.accessibilityLabel(for: []), "LLimit: no quota data.")
  }

  // MARK: - Fixtures

  private func bars(providers: [ProviderUsage] = [], failures: [ProviderFailure] = []) -> [MenuBarGraph.Bar] {
    MenuBarGraph.bars(
      snapshot: snapshot(providers: providers, failures: failures),
      accounts: accounts,
      now: now,
      staleAfter: staleAfter
    )
  }

  private func snapshot(providers: [ProviderUsage] = [], failures: [ProviderFailure] = []) -> QuotaSnapshot {
    QuotaSnapshot(generatedAt: now, providers: providers, failures: failures)
  }

  private func usage(_ account: ProviderAccount, remaining: Int, fetchedAt: Date? = nil) -> ProviderUsage {
    ProviderUsage(
      accountID: account.id,
      provider: account.provider,
      title: account.resolvedDisplayName,
      metrics: [UsageMetric(id: "five-hour", label: "5-hour", remainingPercent: remaining)],
      fetchedAt: fetchedAt ?? now
    )
  }

  private func failure(_ account: ProviderAccount, kind: QuotaErrorKind) -> ProviderFailure {
    ProviderFailure(accountID: account.id, provider: account.provider, kind: kind, message: "failed")
  }
}
