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

final class QuotaWeatherExplanationTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func usage(_ name: String, remaining: Int?, estimated: Bool = false) -> ProviderUsage {
    ProviderUsage(accountID: name, provider: .openAI, title: name,
      metrics: [UsageMetric(id: "weekly", label: "Weekly", remainingPercent: remaining,
                            estimatedTotal: estimated ? 100 : nil)], fetchedAt: now)
  }

  private func explain(_ providers: [ProviderUsage] = [], failures: [ProviderFailure] = []) -> QuotaWeatherExplanation {
    QuotaWeather.explanation(for: QuotaSnapshot(generatedAt: now, providers: providers, failures: failures),
                             now: now, staleAfter: 3_600)
  }

  func testThresholdsMatchClassificationAndDescribeWorstWindow() {
    for (remaining, expected) in [(14, QuotaWeather.stormy), (15, .cloudy), (39, .cloudy), (40, .calm)] {
      let result = explain([usage("High", remaining: 99), usage("Low", remaining: remaining)])
      XCTAssertEqual(result.weather, expected)
      XCTAssertTrue(result.reasons.contains { $0.contains("Low") && $0.contains("Weekly") && $0.contains("\(remaining)%") })
      XCTAssertTrue(result.summary.contains("most constrained"))
      XCTAssertTrue(result.summary.contains("not an average"))
      XCTAssertTrue(result.summary.contains("forecast"))
    }
  }

  func testFailureExplainsAccountAndKindWithoutRawDiagnosticsOrCachedHeadroom() {
    var cached = usage("Cached", remaining: 5)
    cached.metrics[0].detail = "private-detail"
    let result = explain([cached], failures: [ProviderFailure(accountID: "a", provider: .anthropic,
      kind: .auth, message: "private-provider-message", title: "Claude Personal")])
    let text = result.accessibilityDescription
    XCTAssertEqual(result.weather, .stormy)
    XCTAssertTrue(text.contains("1 account could not refresh"))
    XCTAssertTrue(text.contains("Claude Personal"))
    XCTAssertTrue(text.lowercased().contains("reconnect"))
    XCTAssertFalse(text.contains("private-provider-message"))
    XCTAssertFalse(text.contains("private-detail"))
    XCTAssertFalse(text.contains("5%"))
  }

  func testEveryFailureKindUsesActionableFixedCopy() {
    for (kind, expected) in [(QuotaErrorKind.auth, "reconnect"), (.network, "connection"),
                             (.rateLimit, "wait"), (.api, "unavailable"), (.decoding, "unavailable"),
                             (.notConfigured, "configure"), (.unknown, "retry")] {
      let result = explain(failures: [ProviderFailure(provider: .openAI, kind: kind, message: "private-response")])
      XCTAssertTrue(result.reasons.joined(separator: " ").lowercased().contains(expected), "\(kind)")
      XCTAssertFalse(result.accessibilityDescription.contains("private-response"))
    }
  }

  func testNilAndEmptyDataExplainMissingReadingsWithoutInferringAccountConfiguration() {
    for result in [QuotaWeather.explanation(for: nil, now: now), explain()] {
      XCTAssertEqual(result.weather, .unknown)
      XCTAssertFalse(result.guidance.isEmpty)
      XCTAssertTrue(result.summary.contains("most constrained"))
      XCTAssertFalse(result.accessibilityDescription.contains("no accounts are configured"))
    }
  }

  func testMissingPercentageNamesTheUnknownWindow() {
    let result = explain([usage("Measured", remaining: 90), usage("Unknown Account", remaining: nil)])
    XCTAssertEqual(result.weather, .unknown)
    XCTAssertTrue(result.reasons.contains { $0.contains("Unknown Account") && $0.contains("Weekly") })
    XCTAssertFalse(result.reasons.contains { $0.contains("90%") })
  }

  func testOldSourceDoesNotClaimAQuotaResetOccurred() {
    var old = usage("Older Account", remaining: 80)
    old.fetchedAt = now.addingTimeInterval(-3_601)
    let result = explain([old])
    XCTAssertEqual(result.weather, .stale)
    XCTAssertTrue(result.reasons.contains { $0.contains("Older Account") && $0.contains("older") })
    XCTAssertFalse(result.reasons.contains { $0.contains("reset") })
    XCTAssertFalse(result.accessibilityDescription.contains("have reset"))
  }

  func testElapsedResetIsExplainedSeparatelyFromOldSource() {
    var elapsed = usage("Reset Account", remaining: 80)
    elapsed.fetchedAt = now.addingTimeInterval(-60)
    elapsed.metrics[0].resetAt = now.addingTimeInterval(-1)
    let result = explain([elapsed])
    XCTAssertEqual(result.weather, .stale)
    XCTAssertTrue(result.reasons.contains { $0.contains("Reset Account") && $0.contains("Weekly") && $0.contains("reset") })
    XCTAssertTrue(result.guidance.lowercased().contains("refresh"))
  }

  func testEstimatedHeadroomDoesNotPromiseAServerAllowanceWillArrive() {
    let result = explain([usage("Estimated Account", remaining: 90, estimated: true)])
    XCTAssertEqual(result.weather, .estimated)
    XCTAssertTrue(result.reasons.contains { $0.contains("Estimated Account") && $0.contains("Weekly") })
    XCTAssertTrue(result.guidance.contains("not a provider-reported total"))
    XCTAssertFalse(result.guidance.contains("will update"))
  }

  func testReasonsHaveDeterministicNamesAndCapWithRemainingCount() {
    let failures = (0..<8).map { index in
      ProviderFailure(accountID: "\(index)", provider: .openAI, kind: .network,
                      message: "private", title: "Account \(index)")
    }
    let forward = explain(failures: failures)
    let reversed = explain(failures: failures.reversed())
    XCTAssertEqual(forward.reasons, reversed.reasons)
    XCTAssertEqual(forward.reasons.count, 5)
    XCTAssertTrue(forward.reasons[0].hasPrefix("Account 0:"))
    XCTAssertTrue(forward.guidance.contains("3 more"))
  }

  func testNamesAreBoundedAndControlsDoNotExpandThePopover() {
    let name = "Account\n" + String(repeating: "x", count: 500)
    let result = explain(failures: [ProviderFailure(provider: .openAI, kind: .network, message: "private", title: name)])
    XCTAssertLessThan(result.reasons[0].count, 250)
    XCTAssertFalse(result.reasons[0].contains("\n"))
  }

  func testLegendIncludesAllStatesAndAccurateThresholds() {
    let legend = explain().legend
    XCTAssertEqual(legend.count, 6)
    for state in ["Calm", "Cloudy", "Stormy", "Unknown", "Stale", "Estimated"] {
      XCTAssertTrue(legend.contains { $0.hasPrefix(state + ":") })
    }
    XCTAssertTrue(legend[0].contains("40%"))
    XCTAssertTrue(legend[1].contains("15%") && legend[1].contains("40%"))
    XCTAssertTrue(legend[2].contains("15%") && legend[2].contains("refresh"))
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
