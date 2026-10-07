import XCTest
@testable import QuotaCore

final class QuotaAlertSettingsTests: XCTestCase {
  func testThresholdsClampIntoRangeAndRemainOrdered() {
    let clamped = QuotaAlertSettings(warningPercent: 500, criticalPercent: -3)
    XCTAssertEqual(clamped.warningPercent, QuotaAlertSettings.warningRange.upperBound)
    XCTAssertEqual(clamped.criticalPercent, QuotaAlertSettings.criticalRange.lowerBound)
    let inverted = QuotaAlertSettings(enabled: true, warningPercent: 10, criticalPercent: 40)
    XCTAssertEqual(inverted.warningPercent, 10)
    XCTAssertEqual(inverted.criticalPercent, 9)
  }

  func testDefaultsAreOptInAndUseTheSharedPolicy() throws {
    XCTAssertFalse(QuotaAlertSettings().enabled)
    XCTAssertEqual(QuotaAlertSettings().eventConfig, QuotaEventConfig.default)
    let empty = try JSONDecoder().decode(QuotaAlertSettings.self, from: Data("{}".utf8))
    XCTAssertEqual(empty, QuotaAlertSettings())
    let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
    XCTAssertEqual(legacy.alertSettings, QuotaAlertSettings())
  }

  func testExistingConfiguredSettingsRoundTripWithoutChangingBands() throws {
    let json = #"{"alertSettings":{"enabled":true,"warningPercent":25,"criticalPercent":10,"notifyOnFailure":false}}"#
    let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    XCTAssertEqual(settings.alertSettings, QuotaAlertSettings(enabled: true, warningPercent: 25,
                                                           criticalPercent: 10, notifyOnFailure: false))
    XCTAssertEqual(settings.alertSettings.eventConfig.thresholds, [25, 10])
    XCTAssertTrue(settings.alertSettings.eventConfig.failureKinds.isEmpty)
    let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    XCTAssertEqual(restored, settings)
  }

  func testDecodeRestoresClampAndOrdering() throws {
    let json = #"{"enabled":true,"warningPercent":10,"criticalPercent":80,"notifyOnFailure":false}"#
    let decoded = try JSONDecoder().decode(QuotaAlertSettings.self, from: Data(json.utf8))
    XCTAssertTrue(decoded.enabled)
    XCTAssertEqual(decoded.warningPercent, 10)
    XCTAssertEqual(decoded.criticalPercent, 9)
    XCTAssertFalse(decoded.notifyOnFailure)
  }

  func testEditingEitherBandMaintainsOrderingAtBounds() {
    var settings = QuotaAlertSettings(enabled: true)
    settings.setThreshold(50, for: .critical)
    XCTAssertEqual(settings.warningPercent, 51)
    settings.setThreshold(5, for: .warning)
    XCTAssertEqual(settings.criticalPercent, 4)
    settings.setThreshold(-1, for: .warning)
    XCTAssertEqual(settings.warningPercent, 5)
    settings.setThreshold(500, for: .critical)
    XCTAssertEqual(settings.criticalPercent, 50)
    XCTAssertEqual(settings.warningPercent, 51)
  }
}
