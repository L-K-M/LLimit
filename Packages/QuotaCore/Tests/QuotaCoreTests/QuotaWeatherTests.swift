import XCTest
@testable import QuotaCore

final class QuotaWeatherTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private let fresh: TimeInterval = 3_600

  private func snapshot(
    providers: [ProviderUsage] = [],
    failures: [ProviderFailure] = [],
    generatedAt: Date? = nil
  ) -> QuotaSnapshot {
    QuotaSnapshot(
      generatedAt: generatedAt ?? now,
      providers: providers,
      failures: failures
    )
  }

  private func usage(_ id: String, remaining: Int?, estimated: Bool = false) -> ProviderUsage {
    ProviderUsage(
      accountID: id,
      provider: .openAI,
      title: id,
      metrics: [
        UsageMetric(
          id: "m",
          label: "m",
          remainingPercent: remaining,
          estimatedTotal: estimated ? 100 : nil
        )
      ],
      fetchedAt: now
    )
  }

  func testNilSnapshotIsUnknown() {
    XCTAssertEqual(QuotaWeather.forSnapshot(nil, now: now, staleAfter: fresh), .unknown)
  }

  func testEmptyProvidersIsUnknown() {
    XCTAssertEqual(QuotaWeather.forSnapshot(snapshot(), now: now, staleAfter: fresh), .unknown)
  }

  func testFailuresAreStormy() {
    let s = snapshot(
      providers: [usage("a", remaining: 90)],
      failures: [ProviderFailure(accountID: "b", provider: .anthropic, kind: .auth, message: "x")]
    )
    XCTAssertEqual(QuotaWeather.forSnapshot(s, now: now, staleAfter: fresh), .stormy)
  }

  func testUnknownWhenNoBoundedPercentages() {
    let u = ProviderUsage(
      accountID: "a", provider: .openAI, title: "a",
      metrics: [UsageMetric(id: "m", label: "m", remainingAmount: 12.5)],
      fetchedAt: now
    )
    XCTAssertEqual(
      QuotaWeather.forSnapshot(snapshot(providers: [u]), now: now, staleAfter: fresh),
      .unknown
    )
  }

  func testStaleIsSeparateFromHealthy() {
    let old = snapshot(providers: [usage("a", remaining: 90)], generatedAt: now.addingTimeInterval(-7_200))
    XCTAssertEqual(QuotaWeather.forSnapshot(old, now: now, staleAfter: fresh), .stale)
  }

  func testEstimatedIsSeparateFromHealthy() {
    // The old keypath `\.$0.isPercentageEstimated` did not compile; the
    // corrected predicate must detect estimates without grading them stormy.
    let s = snapshot(providers: [usage("a", remaining: 90, estimated: true)])
    XCTAssertEqual(QuotaWeather.forSnapshot(s, now: now, staleAfter: fresh), .estimated)
  }

  func testHealthyThresholds() {
    XCTAssertEqual(
      QuotaWeather.forSnapshot(snapshot(providers: [usage("a", remaining: 90)]), now: now, staleAfter: fresh),
      .calm
    )
    XCTAssertEqual(
      QuotaWeather.forSnapshot(snapshot(providers: [usage("a", remaining: 30)]), now: now, staleAfter: fresh),
      .cloudy
    )
    XCTAssertEqual(
      QuotaWeather.forSnapshot(snapshot(providers: [usage("a", remaining: 10)]), now: now, staleAfter: fresh),
      .stormy
    )
  }

  func testFreshAttemptWithOldSourceIsStale() {
    var old = usage("a", remaining: 90)
    old.fetchedAt = now.addingTimeInterval(-fresh - 1)
    XCTAssertEqual(QuotaWeather.forSnapshot(snapshot(providers: [old]), now: now, staleAfter: fresh), .stale)
  }

  func testUnknownWindowIsNotHealthyBecauseAnotherWindowReports() {
    var mixed = usage("a", remaining: 90)
    mixed.metrics.append(UsageMetric(id: "weekly", label: "Weekly"))
    XCTAssertEqual(QuotaWeather.forSnapshot(snapshot(providers: [mixed]), now: now, staleAfter: fresh), .unknown)
  }
}

final class DashboardBestAccountTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private let staleAfter: TimeInterval = 3_600

  private func account(_ id: String, enabled: Bool = true) -> ProviderAccount {
    ProviderAccount(id: id, provider: .openAI, displayName: id, isEnabled: enabled)
  }

  private func usage(_ id: String, remaining: Int?, estimated: Bool = false) -> ProviderUsage {
    ProviderUsage(
      accountID: id,
      provider: .openAI,
      title: id,
      metrics: [
        UsageMetric(
          id: "m",
          label: "m",
          remainingPercent: remaining,
          estimatedTotal: estimated ? 100 : nil
        )
      ],
      fetchedAt: now
    )
  }

  func testPicksHighestBoundedRemaining() {
    let accounts = [account("low"), account("high")]
    let s = QuotaSnapshot(
      generatedAt: now,
      providers: [usage("low", remaining: 20), usage("high", remaining: 60)],
      failures: []
    )
    XCTAssertEqual(
      DashboardBestAccount.best(snapshot: s, accounts: accounts, now: now, staleAfter: staleAfter)?.accountID,
      "high"
    )
  }

  func testIgnoresUnlimitedOnlyDisabledFailingAndDepleted() {
    let accounts = [account("u"), account("b"), account("off", enabled: false), account("zero")]
    let unlimited = ProviderUsage(
      accountID: "u", provider: .openAI, title: "u",
      metrics: [UsageMetric(id: "m", label: "m", isUnlimited: true)],
      fetchedAt: now
    )
    let s = QuotaSnapshot(
      generatedAt: now,
      providers: [unlimited, usage("b", remaining: 5), usage("zero", remaining: 0)],
      failures: [ProviderFailure(accountID: "b", provider: .openAI, kind: .auth, message: "x")]
    )
    // "b" fails so it is excluded; "u" is unlimited-only; "zero" is depleted.
    XCTAssertNil(DashboardBestAccount.best(snapshot: s, accounts: accounts, now: now, staleAfter: staleAfter))
  }

  func testReturnsNilWhenUnknown() {
    let accounts = [account("a")]
    let u = ProviderUsage(
      accountID: "a", provider: .openAI, title: "a",
      metrics: [UsageMetric(id: "m", label: "m", remainingAmount: 5)],
      fetchedAt: now
    )
    let s = QuotaSnapshot(generatedAt: now, providers: [u], failures: [])
    XCTAssertNil(DashboardBestAccount.best(snapshot: s, accounts: accounts, now: now, staleAfter: staleAfter))
  }

  func testUsesCurrentNameAndRejectsAmbiguousLegacyData() {
    let current = account("a")
    var legacy = usage(QuotaProvider.openAI.rawValue, remaining: 80)
    legacy.title = "Obsolete name"
    let s = QuotaSnapshot(generatedAt: now, providers: [legacy], failures: [])
    XCTAssertEqual(DashboardBestAccount.best(snapshot: s, accounts: [current], now: now,
                                            staleAfter: staleAfter)?.usage.title, "a")
    XCTAssertNil(DashboardBestAccount.best(snapshot: s, accounts: [current, account("b")], now: now,
                                           staleAfter: staleAfter))
  }

  func testDoesNotNominateAWindowThatResetSinceFetch() {
    var pending = usage("a", remaining: 80)
    pending.fetchedAt = now.addingTimeInterval(-60)
    pending.metrics[0].resetAt = now
    let s = QuotaSnapshot(generatedAt: now, providers: [pending], failures: [])
    XCTAssertNil(DashboardBestAccount.best(snapshot: s, accounts: [account("a")], now: now,
                                           staleAfter: staleAfter))
  }

  func testUnknownBoundedWindowCannotWinOnAnotherWindowsHeadroom() {
    var mixed = usage("a", remaining: 90)
    mixed.metrics.append(UsageMetric(id: "weekly", label: "Weekly"))
    let s = QuotaSnapshot(generatedAt: now, providers: [mixed], failures: [])
    XCTAssertNil(DashboardBestAccount.best(snapshot: s, accounts: [account("a")], now: now,
                                           staleAfter: staleAfter))
  }

  func testDisabledAndStaleLeadersYieldToCurrentAccount() {
    var stale = usage("stale", remaining: 99)
    stale.fetchedAt = now.addingTimeInterval(-staleAfter - 1)
    let s = QuotaSnapshot(generatedAt: now, providers: [usage("off", remaining: 100), stale, usage("a", remaining: 40)], failures: [])
    XCTAssertEqual(DashboardBestAccount.best(snapshot: s, accounts: [account("off", enabled: false), account("stale"), account("a")],
      now: now, staleAfter: staleAfter)?.accountID, "a")
  }
}
