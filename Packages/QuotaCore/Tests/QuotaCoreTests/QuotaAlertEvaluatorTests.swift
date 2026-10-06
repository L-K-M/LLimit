import XCTest
@testable import QuotaCore

final class QuotaAlertEvaluatorTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private func snapshot(percent: Int, accountID: String = "acct",
                        title: String = "Claude",
                        failures: [ProviderFailure] = []) -> QuotaSnapshot {
    QuotaSnapshot(
      generatedAt: now,
      providers: [
        ProviderUsage(
          accountID: accountID, provider: .anthropic, title: title,
          metrics: [UsageMetric(
            id: "five-hour", label: "5-hour limit", remainingPercent: percent,
            resetAt: now.addingTimeInterval(3_600))],
          fetchedAt: now
        )
      ],
      failures: failures
    )
  }

  func testHealthySnapshotFiresNothing() {
    var dedup: Set<String> = []
    let alerts = QuotaAlertEvaluator.alerts(
      in: snapshot(percent: 80), settings: QuotaAlertSettings(), dedupedKeys: &dedup, now: now)
    XCTAssertTrue(alerts.isEmpty)
    XCTAssertTrue(dedup.isEmpty)
  }

  func testCrossingWarningFiresOnce() {
    var dedup: Set<String> = []
    let settings = QuotaAlertSettings()
    let first = QuotaAlertEvaluator.alerts(
      in: snapshot(percent: 20), settings: settings, dedupedKeys: &dedup, now: now)
    XCTAssertEqual(first.map(\.severity), [.warning])
    XCTAssertTrue(first[0].body.contains("20% remaining"))
    XCTAssertTrue(first[0].body.contains("resets"))

    let second = QuotaAlertEvaluator.alerts(
      in: snapshot(percent: 19), settings: settings, dedupedKeys: &dedup, now: now)
    XCTAssertTrue(second.isEmpty, "staying inside the band must not re-alert")
  }

  func testEscalationToCriticalFiresWithoutRepeatingWarning() {
    var dedup: Set<String> = []
    let settings = QuotaAlertSettings()
    _ = QuotaAlertEvaluator.alerts(
      in: snapshot(percent: 20), settings: settings, dedupedKeys: &dedup, now: now)
    let escalated = QuotaAlertEvaluator.alerts(
      in: snapshot(percent: 5), settings: settings, dedupedKeys: &dedup, now: now)
    XCTAssertEqual(escalated.map(\.severity), [.critical])
  }

  func testCriticalImpliesAndSuppressesWarning() {
    var dedup: Set<String> = []
    let settings = QuotaAlertSettings()
    let first = QuotaAlertEvaluator.alerts(
      in: snapshot(percent: 5), settings: settings, dedupedKeys: &dedup, now: now)
    XCTAssertEqual(first.map(\.severity), [.critical])
    let deescalated = QuotaAlertEvaluator.alerts(
      in: snapshot(percent: 15), settings: settings, dedupedKeys: &dedup, now: now)
    XCTAssertTrue(deescalated.isEmpty, "dropping from critical to warning must not re-alert")
  }

  func testRecoveryRearmsTheMetric() {
    var dedup: Set<String> = []
    let settings = QuotaAlertSettings()
    _ = QuotaAlertEvaluator.alerts(
      in: snapshot(percent: 20), settings: settings, dedupedKeys: &dedup, now: now)
    _ = QuotaAlertEvaluator.alerts(
      in: snapshot(percent: 90), settings: settings, dedupedKeys: &dedup, now: now)
    XCTAssertTrue(dedup.isEmpty, "recovery must clear suppression")
    let secondDip = QuotaAlertEvaluator.alerts(
      in: snapshot(percent: 20), settings: settings, dedupedKeys: &dedup, now: now)
    XCTAssertEqual(secondDip.map(\.severity), [.warning])
  }

  func testFailureFiresOncePerKind() {
    var dedup: Set<String> = []
    let failure = ProviderFailure(provider: .kimi, kind: .auth, message: "bad token")
    let first = QuotaAlertEvaluator.alerts(
      in: snapshot(percent: 80, failures: [failure]),
      settings: QuotaAlertSettings(), dedupedKeys: &dedup, now: now)
    XCTAssertEqual(first.map(\.severity), [.failure])
    XCTAssertEqual(first[0].body, "bad token")

    let repeat_ = QuotaAlertEvaluator.alerts(
      in: snapshot(percent: 80, failures: [failure]),
      settings: QuotaAlertSettings(), dedupedKeys: &dedup, now: now)
    XCTAssertTrue(repeat_.isEmpty)

    // A different failure kind for the same account is a new alert.
    let other = ProviderFailure(provider: .kimi, kind: .network, message: "offline")
    let second = QuotaAlertEvaluator.alerts(
      in: snapshot(percent: 80, failures: [failure, other]),
      settings: QuotaAlertSettings(), dedupedKeys: &dedup, now: now)
    XCTAssertEqual(second.map(\.severity), [.failure])
  }

  func testDisabledClearsSuppressionAndFiresNothing() {
    var dedup: Set<String> = ["quota:acct:m:warning"]
    let off = QuotaAlertSettings(enabled: false)
    let alerts = QuotaAlertEvaluator.alerts(
      in: snapshot(percent: 5), settings: off, dedupedKeys: &dedup, now: now)
    XCTAssertTrue(alerts.isEmpty)
    XCTAssertTrue(dedup.isEmpty)
  }

  func testUnlimitedAndAmountOnlyMetricsNeverAlert() {
    var dedup: Set<String> = []
    let snapshot = QuotaSnapshot(
      generatedAt: now,
      providers: [ProviderUsage(
        accountID: "v", provider: .venice, title: "Venice",
        metrics: [
          UsageMetric(id: "unl", label: "Unlimited", isUnlimited: true),
          UsageMetric(id: "bal", label: "DIEM", remainingAmount: 0.5),
        ],
        fetchedAt: now)],
      failures: [])
    XCTAssertTrue(QuotaAlertEvaluator.alerts(
      in: snapshot, settings: QuotaAlertSettings(), dedupedKeys: &dedup, now: now).isEmpty)
  }

  func testThresholdsClampIntoRange() {
    let settings = QuotaAlertSettings(warningPercent: 500, criticalPercent: -3)
    XCTAssertEqual(settings.warningPercent, QuotaAlertSettings.warningRange.upperBound)
    XCTAssertEqual(settings.criticalPercent, QuotaAlertSettings.criticalRange.lowerBound)
  }
}
