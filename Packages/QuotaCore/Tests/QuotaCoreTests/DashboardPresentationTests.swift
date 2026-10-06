import XCTest
@testable import QuotaCore

final class DashboardPresentationTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)
  private let account = ProviderAccount(id: "google", provider: .googleAntigravity, displayName: "Work")

  func testSettingsChangesReconcileTheSameSnapshotBeforeSummaryAndLimit() {
    let removed = ProviderAccount(id: "removed", provider: .openAI)
    let disabled = ProviderAccount(id: "disabled", provider: .anthropic, isEnabled: false)
    let renamed = ProviderAccount(id: account.id, provider: account.provider, displayName: "Renamed")
    let stored = snapshot(
      [usage(removed, remaining: 1), usage(disabled, remaining: 2), usage(account, remaining: 70)],
      failures: [failure(removed), failure(disabled)]
    )

    let result = presentation(accounts: [disabled, renamed], snapshot: .loaded(stored))

    XCTAssertEqual(result.state, .ready)
    XCTAssertEqual(result.providers.map(\.accountID), [account.id])
    XCTAssertEqual(result.providers.first?.title, "Renamed")
    XCTAssertEqual(result.providers.prefix(1).first?.accountID, account.id)
    XCTAssertTrue(result.overviewSummary.hasPrefix("1 "))
    XCTAssertTrue(result.overviewSummary.contains("lowest 70% left"))
    XCTAssertEqual(result.failureCount, 0)
  }

  func testRenamedTitlesDetermineRiskTiesAfterReconciliation() {
    let second = ProviderAccount(id: "second", provider: .openAI, displayName: "A")
    let renamed = ProviderAccount(id: account.id, provider: account.provider, displayName: "Z")
    let result = presentation(
      accounts: [renamed, second],
      snapshot: .loaded(snapshot([usage(account, remaining: 60), usage(second, remaining: 60)]))
    )

    XCTAssertEqual(result.providers.map(\.title), ["A", "Z"])
    XCTAssertTrue(result.overviewSummary.hasPrefix("2 "))
  }

  func testUnknownGoogleMetricWithAggregateZeroHasNoNumericSummaryOrBar() {
    let unknown = UsageMetric(id: "empty", label: "No quota data available")
    let storedUsage = usage(account, metrics: [unknown], aggregate: 0)
    let result = presentation(accounts: [account], snapshot: .loaded(snapshot([storedUsage])))

    XCTAssertEqual(result.state, .ready)
    XCTAssertEqual(dashboardPrimaryMetric(for: storedUsage), unknown)
    XCTAssertNil(dashboardRemainingPercent(for: storedUsage))
    XCTAssertTrue(dashboardBarMetrics(for: storedUsage).isEmpty)
    XCTAssertFalse(result.overviewSummary.contains("lowest"))
  }

  func testAggregateWithoutAttributableMetricsCannotCreatePercentage() {
    for aggregate in [0, 80, 100] {
      let storedUsage = usage(account, metrics: [], aggregate: aggregate)
      let result = presentation(accounts: [account], snapshot: .loaded(snapshot([storedUsage])))

      XCTAssertNil(dashboardPrimaryMetric(for: storedUsage))
      XCTAssertNil(dashboardRemainingPercent(for: storedUsage))
      XCTAssertTrue(dashboardBarMetrics(for: storedUsage).isEmpty)
      XCTAssertFalse(result.overviewSummary.contains("lowest"))
    }
  }

  func testExplicitUnlimitedIsNotNumericOneHundredPercent() {
    let unlimited = UsageMetric(id: "chat", label: "Chat", isUnlimited: true)
    let storedUsage = usage(account, metrics: [unlimited], aggregate: 0)
    let result = presentation(accounts: [account], snapshot: .loaded(snapshot([storedUsage])))

    XCTAssertEqual(dashboardPrimaryMetric(for: storedUsage), unlimited)
    XCTAssertNil(dashboardRemainingPercent(for: storedUsage))
    XCTAssertTrue(dashboardBarMetrics(for: storedUsage).isEmpty)
    XCTAssertFalse(result.overviewSummary.contains("lowest"))
  }

  func testUnknownLimitIsNotHiddenByAnotherUnlimitedMetric() {
    let unknown = UsageMetric(id: "premium", label: "Premium requests")
    let unlimited = UsageMetric(id: "chat", label: "Chat", isUnlimited: true)
    for metrics in [[unlimited, unknown], [unknown, unlimited]] {
      let storedUsage = usage(account, metrics: metrics, aggregate: 0)
      XCTAssertEqual(dashboardPrimaryMetric(for: storedUsage), unknown)
      XCTAssertNil(dashboardRemainingPercent(for: storedUsage))
    }
  }

  func testHealthyZeroUsedAndExhaustedMetricsKeepTheirRealGeometry() {
    for remaining in [100, 0] {
      let storedUsage = usage(account, remaining: remaining)
      let result = presentation(accounts: [account], snapshot: .loaded(snapshot([storedUsage])))

      XCTAssertEqual(dashboardRemainingPercent(for: storedUsage), remaining)
      XCTAssertEqual(dashboardPrimaryMetric(for: storedUsage)?.remainingPercent, remaining)
      XCTAssertEqual(dashboardBarMetrics(for: storedUsage).map(\.remainingPercent), [remaining])
      XCTAssertTrue(result.overviewSummary.contains("lowest \(remaining)% left"))
    }
  }

  func testMostConstrainedBoundedMetricWinsOverUnlimitedAndAggregate() {
    let metrics = [
      UsageMetric(id: "chat", label: "Chat", isUnlimited: true),
      UsageMetric(id: "weekly", label: "Weekly limit", remainingPercent: 15),
      UsageMetric(id: "daily", label: "Daily limit", remainingPercent: 80)
    ]
    let storedUsage = usage(account, metrics: metrics, aggregate: 0)

    XCTAssertEqual(dashboardPrimaryMetric(for: storedUsage)?.id, "weekly")
    XCTAssertEqual(dashboardRemainingPercent(for: storedUsage), 15)
    XCTAssertEqual(dashboardBarMetrics(for: storedUsage).map(\.id), ["weekly"])
  }

  func testEstimatedSummaryRetainsItsQualifier() {
    let estimated = UsageMetric(id: "daily-diem", label: "Daily DIEM", remainingPercent: 40, estimatedTotal: 10)
    let result = presentation(
      accounts: [account],
      snapshot: .loaded(snapshot([usage(account, metrics: [estimated], aggregate: 0)]))
    )

    XCTAssertTrue(result.overviewSummary.contains("lowest ≈40% left"))
  }

  func testGenuinelyEmptySettingsIgnoreOldSnapshotMembership() {
    let result = presentation(
      accounts: [], snapshot: .loaded(snapshot([usage(account, remaining: 50)], failures: [failure(account)]))
    )

    XCTAssertEqual(result.state, .noAccounts)
    XCTAssertTrue(result.providers.isEmpty)
    XCTAssertEqual(result.failureCount, 0)
  }

  func testDisabledAccountsDoNotTriggerOnboarding() {
    var disabled = account
    disabled.isEnabled = false
    let result = presentation(accounts: [disabled], snapshot: .loaded(snapshot([usage(account, remaining: 50)])))

    XCTAssertEqual(result.state, .noEnabledAccounts)
    XCTAssertTrue(result.providers.isEmpty)
  }

  func testEmptyLoadedSettingsWinOverUnavailableSnapshot() {
    let result = presentation(accounts: [], snapshot: .unavailable)

    XCTAssertEqual(result.state, .noAccounts)
    XCTAssertTrue(result.providers.isEmpty)
    XCTAssertEqual(result.failureCount, 0)
  }

  func testAllDisabledLoadedSettingsWinOverUnavailableSnapshot() {
    var disabled = account
    disabled.isEnabled = false
    let result = presentation(accounts: [disabled], snapshot: .unavailable)

    XCTAssertEqual(result.state, .noEnabledAccounts)
    XCTAssertTrue(result.providers.isEmpty)
    XCTAssertEqual(result.failureCount, 0)
  }

  func testEnabledLoadedSettingsStillRequireReadableSnapshot() {
    let result = presentation(accounts: [account], snapshot: .unavailable)

    XCTAssertEqual(result.state, .storageUnavailable)
    XCTAssertTrue(result.providers.isEmpty)
    XCTAssertEqual(result.failureCount, 0)
  }

  func testConfiguredAccountsWithMissingOrEmptySnapshotAwaitData() {
    for stored: DashboardStoredValue<QuotaSnapshot> in [.missing, .loaded(snapshot([]))] {
      let result = presentation(accounts: [account], snapshot: stored)
      XCTAssertEqual(result.state, .awaitingData)
      XCTAssertEqual(result.failureCount, 0)
    }
  }

  func testFirstRefreshAllFailuresRetainsFailureCountWithoutOnboarding() {
    let second = ProviderAccount(id: "second", provider: .openAI)
    let result = presentation(
      accounts: [account, second],
      snapshot: .loaded(snapshot([], failures: [failure(account), failure(second), failure(second)]))
    )

    XCTAssertEqual(result.state, .allFailed)
    XCTAssertEqual(result.failureCount, 2)
    XCTAssertTrue(result.providers.isEmpty)
  }

  func testNewAccountAwaitsDataAlongsideAnotherAccountsFailure() {
    let second = ProviderAccount(id: "second", provider: .openAI)
    let result = presentation(
      accounts: [account, second], snapshot: .loaded(snapshot([], failures: [failure(account)]))
    )

    XCTAssertEqual(result.state, .awaitingData)
    XCTAssertEqual(result.failureCount, 1)
  }

  func testRetainedLastGoodUsageStillShowsItsCurrentFailure() {
    let result = presentation(
      accounts: [account], snapshot: .loaded(snapshot([usage(account, remaining: 50)], failures: [failure(account)]))
    )

    XCTAssertEqual(result.state, .ready)
    XCTAssertEqual(result.failureCount, 1)
    XCTAssertEqual(result.providers.count, 1)
  }

  func testStorageErrorsNeverBecomeNoAccountsOrAwaitingData() {
    let failedSettings = DashboardPresentation(settings: .unavailable, snapshot: .loaded(snapshot([usage(account, remaining: 50)])))
    let failedSnapshot = presentation(accounts: [account], snapshot: .unavailable)
    let bothFailed = DashboardPresentation(settings: .unavailable, snapshot: .unavailable)

    for result in [failedSettings, failedSnapshot, bothFailed] {
      XCTAssertEqual(result.state, .storageUnavailable)
      XCTAssertTrue(result.providers.isEmpty)
    }
  }

  func testMissingSettingsWithExistingSnapshotCannotAssertNoAccounts() {
    let result = DashboardPresentation(settings: .missing, snapshot: .loaded(snapshot([usage(account, remaining: 50)])))

    XCTAssertEqual(result.state, .storageUnavailable)
    XCTAssertTrue(result.providers.isEmpty)
    XCTAssertEqual(DashboardPresentation(settings: .missing, snapshot: .missing).state, .noAccounts)
  }

  func testLegacyFailureOnlyBelongsToAnUnambiguousCurrentAccount() {
    let legacy = ProviderFailure(provider: account.provider, kind: .network, message: "Fixture failure")
    let sole = presentation(accounts: [account], snapshot: .loaded(snapshot([], failures: [legacy])))
    var disabled = account
    disabled.id = "disabled"
    disabled.isEnabled = false
    let ambiguous = presentation(accounts: [account, disabled], snapshot: .loaded(snapshot([], failures: [legacy])))

    XCTAssertEqual(sole.state, .allFailed)
    XCTAssertEqual(sole.failureCount, 1)
    XCTAssertEqual(ambiguous.state, .awaitingData)
    XCTAssertEqual(ambiguous.failureCount, 0)
  }

  func testMismatchedProviderUsageAndFailuresCannotMatchAnAccountID() {
    let mismatched = ProviderAccount(id: account.id, provider: .openAI)
    let result = presentation(
      accounts: [account],
      snapshot: .loaded(snapshot([usage(mismatched, remaining: 50)], failures: [failure(mismatched)]))
    )

    XCTAssertEqual(result.state, .awaitingData)
    XCTAssertTrue(result.providers.isEmpty)
    XCTAssertEqual(result.failureCount, 0)
  }

  private func presentation(
    accounts: [ProviderAccount], snapshot: DashboardStoredValue<QuotaSnapshot>
  ) -> DashboardPresentation {
    DashboardPresentation(settings: .loaded(AppSettings(accounts: accounts)), snapshot: snapshot)
  }

  private func usage(_ account: ProviderAccount, remaining: Int) -> ProviderUsage {
    usage(account, metrics: [UsageMetric(id: "weekly", label: "Weekly limit", remainingPercent: remaining)], aggregate: 100 - remaining)
  }

  private func usage(_ account: ProviderAccount, metrics: [UsageMetric], aggregate: Int) -> ProviderUsage {
    ProviderUsage(accountID: account.id, provider: account.provider, title: account.resolvedDisplayName,
                  metrics: metrics, maxUsagePercent: aggregate, fetchedAt: now)
  }

  private func snapshot(_ providers: [ProviderUsage], failures: [ProviderFailure] = []) -> QuotaSnapshot {
    QuotaSnapshot(generatedAt: now, providers: providers, failures: failures)
  }

  private func failure(_ account: ProviderAccount) -> ProviderFailure {
    ProviderFailure(accountID: account.id, provider: account.provider, kind: .network, message: "Fixture failure")
  }
}
