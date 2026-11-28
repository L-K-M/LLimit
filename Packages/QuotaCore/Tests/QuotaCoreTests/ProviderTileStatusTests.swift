import XCTest
@testable import QuotaCore

final class ProviderTileStatusTests: XCTestCase {
  func testOnlyAccountProblemsRequireRepair() {
    XCTAssertEqual(QuotaAccountRepair(needsSetup: false, failureKind: .auth), .reconnect)
    XCTAssertEqual(QuotaAccountRepair(needsSetup: false, failureKind: .notConfigured), .finishSetup)
    XCTAssertEqual(QuotaAccountRepair(needsSetup: true, failureKind: nil), .finishSetup)
    XCTAssertEqual(QuotaAccountRepair(needsSetup: true, failureKind: .auth), .finishSetup)

    for failure: QuotaErrorKind? in [nil, .network, .rateLimit, .api, .decoding, .unknown] {
      XCTAssertNil(QuotaAccountRepair(needsSetup: false, failureKind: failure))
    }
  }

  func testFreshnessDeadlineUsesFirstDisplayedWindowBoundaryOrAccountAge() {
    let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let reset = UsageMetric(id: "reset", label: "Reset", resetAt: fetchedAt.addingTimeInterval(70))
    let expiry = UsageMetric(id: "expiry", label: "Expiry", expiresAt: fetchedAt.addingTimeInterval(40))
    let window = DateInterval(start: fetchedAt.addingTimeInterval(-900), end: fetchedAt.addingTimeInterval(55))
    let refill = UsageMetric(id: "refill", label: "Refill", paceWindow: window)

    XCTAssertEqual(QuotaFreshness.deadline(fetchedAt: fetchedAt, refreshIntervalMinutes: 30,
      metrics: [reset, expiry, refill]), expiry.expiresAt)
    XCTAssertEqual(QuotaFreshness.deadline(fetchedAt: fetchedAt, refreshIntervalMinutes: 30,
      metrics: [reset, refill]), window.end)
    XCTAssertEqual(QuotaFreshness.deadline(fetchedAt: fetchedAt, refreshIntervalMinutes: 30,
      metrics: [reset]), reset.resetAt)
    XCTAssertEqual(QuotaFreshness.deadline(fetchedAt: fetchedAt, refreshIntervalMinutes: 90,
      metrics: []), fetchedAt.addingTimeInterval(10_800))
  }

  func testWidgetSetupMetadataIsRedactedAndSurvivesRoundTrip() throws {
    let incomplete = ProviderAccount(id: "incomplete", provider: .mistral)
    let ready = ProviderAccount(id: "ready", provider: .mistral,
      credentials: [CredentialField.mistralSessionCookies: "test-secret"])
    let disabled = ProviderAccount(id: "disabled", provider: .mistral, isEnabled: false)
    let recoverable = ProviderAccount(id: "recoverable", provider: .openAI,
      credentials: [CredentialField.openAIAccountID: "test-account"])
    let settings = AppSettings(accounts: [incomplete, ready, disabled, recoverable])
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    XCTAssertTrue(settings.widgetAccountIDsNeedingSetup.isEmpty)
    XCTAssertTrue(try decoder.decode(AppSettings.self, from: Data("{}".utf8)).widgetAccountIDsNeedingSetup.isEmpty)
    let shared = settings.redactedCredentials()
    let data = try encoder.encode(shared)
    XCTAssertEqual(try decoder.decode(AppSettings.self, from: data), shared)
    XCTAssertEqual(shared.widgetAccountIDsNeedingSetup, ["incomplete"])
    XCTAssertEqual(shared.redactedCredentials(), shared)
    XCTAssertTrue(shared.accounts.allSatisfy { $0.credentials.isEmpty })
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("test-secret"))
  }
}
