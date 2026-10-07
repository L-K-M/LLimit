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
      in: snapshot(percent: 80), settings: QuotaAlertSettings(enabled: true), dedupedKeys: &dedup, now: now)
    XCTAssertTrue(alerts.isEmpty)
    XCTAssertTrue(dedup.isEmpty)
  }

  func testCrossingWarningFiresOnce() {
    var dedup: Set<String> = []
    let settings = QuotaAlertSettings(enabled: true)
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
    let settings = QuotaAlertSettings(enabled: true)
    _ = QuotaAlertEvaluator.alerts(
      in: snapshot(percent: 20), settings: settings, dedupedKeys: &dedup, now: now)
    let escalated = QuotaAlertEvaluator.alerts(
      in: snapshot(percent: 5), settings: settings, dedupedKeys: &dedup, now: now)
    XCTAssertEqual(escalated.map(\.severity), [.critical])
  }

  func testCriticalImpliesAndSuppressesWarning() {
    var dedup: Set<String> = []
    let settings = QuotaAlertSettings(enabled: true)
    let first = QuotaAlertEvaluator.alerts(
      in: snapshot(percent: 5), settings: settings, dedupedKeys: &dedup, now: now)
    XCTAssertEqual(first.map(\.severity), [.critical])
    let deescalated = QuotaAlertEvaluator.alerts(
      in: snapshot(percent: 15), settings: settings, dedupedKeys: &dedup, now: now)
    XCTAssertTrue(deescalated.isEmpty, "dropping from critical to warning must not re-alert")
  }

  func testRecoveryRearmsTheMetric() {
    var dedup: Set<String> = []
    let settings = QuotaAlertSettings(enabled: true)
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
      settings: QuotaAlertSettings(enabled: true), dedupedKeys: &dedup, now: now)
    XCTAssertEqual(first.map(\.severity), [.failure])
    XCTAssertEqual(first[0].body, "bad token")

    let repeat_ = QuotaAlertEvaluator.alerts(
      in: snapshot(percent: 80, failures: [failure]),
      settings: QuotaAlertSettings(enabled: true), dedupedKeys: &dedup, now: now)
    XCTAssertTrue(repeat_.isEmpty)

    // A different failure kind for the same account is a new alert.
    let other = ProviderFailure(provider: .kimi, kind: .network, message: "offline")
    let second = QuotaAlertEvaluator.alerts(
      in: snapshot(percent: 80, failures: [failure, other]),
      settings: QuotaAlertSettings(enabled: true), dedupedKeys: &dedup, now: now)
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
      in: snapshot, settings: QuotaAlertSettings(enabled: true), dedupedKeys: &dedup, now: now).isEmpty)
  }

  func testThresholdsClampIntoRange() {
    let settings = QuotaAlertSettings(warningPercent: 500, criticalPercent: -3)
    XCTAssertEqual(settings.warningPercent, QuotaAlertSettings.warningRange.upperBound)
    XCTAssertEqual(settings.criticalPercent, QuotaAlertSettings.criticalRange.lowerBound)
  }

  func testDefaultsToDisabled() {
    // Alerts are opt-in — existing users shouldn't be surprised by banners
    // appearing after an update.
    XCTAssertFalse(QuotaAlertSettings().enabled)
  }

  func testDecodeRestoresClampAndOrdering() throws {
    // A hand-edited or version-skewed settings file bypasses init clamps
    // with synthesized Codable — decode must re-validate.
    let json = #"{"enabled":true,"warningPercent":10,"criticalPercent":80,"notifyOnFailure":false}"#
    let decoded = try JSONDecoder().decode(QuotaAlertSettings.self, from: Data(json.utf8))
    XCTAssertTrue(decoded.enabled)
    XCTAssertEqual(decoded.warningPercent, 10)
    XCTAssertLessThan(decoded.criticalPercent, decoded.warningPercent)
    XCTAssertFalse(decoded.notifyOnFailure)
    // Missing keys fall back to defaults (alerts stay opt-in).
    let empty = try JSONDecoder().decode(QuotaAlertSettings.self, from: Data(#"{}"#.utf8))
    XCTAssertFalse(empty.enabled)
  }

  func testCriticalCanNeverMeetOrExceedWarning() {
    // A decoded/constructed config with inverted bands would silently swallow
    // every warning alert — the initializer restores the invariant.
    let inverted = QuotaAlertSettings(enabled: true, warningPercent: 10, criticalPercent: 40)
    XCTAssertLessThan(inverted.criticalPercent, inverted.warningPercent)
    XCTAssertEqual(inverted.warningPercent, 10)
    XCTAssertEqual(inverted.criticalPercent, 9)
  }

  func testHysteresisKeepsSuppressionThroughThresholdFlapping() {
    var dedup: Set<String> = []
    let settings = QuotaAlertSettings(enabled: true, warningPercent: 25, criticalPercent: 10)
    // Enter the band → fires once.
    XCTAssertEqual(QuotaAlertEvaluator.alerts(
      in: snapshot(percent: 24), settings: settings, dedupedKeys: &dedup, now: now
    ).map(\.severity), [.warning])
    // Oscillate inside the 5pt re-arm margin (25…30) → never re-fires.
    for percent in [26, 24, 27, 25, 29] {
      XCTAssertTrue(QuotaAlertEvaluator.alerts(
        in: snapshot(percent: percent), settings: settings, dedupedKeys: &dedup, now: now
      ).isEmpty, "percent \(percent) should not re-fire inside the hysteresis margin")
    }
    // Clear warning + margin (30) → re-arms.
    XCTAssertTrue(QuotaAlertEvaluator.alerts(
      in: snapshot(percent: 31), settings: settings, dedupedKeys: &dedup, now: now).isEmpty)
    XCTAssertTrue(dedup.isEmpty)
    // Next dip alerts again.
    XCTAssertEqual(QuotaAlertEvaluator.alerts(
      in: snapshot(percent: 24), settings: settings, dedupedKeys: &dedup, now: now
    ).map(\.severity), [.warning])
  }
}
