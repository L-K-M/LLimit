import Foundation
import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class MiMoResetDateTests: XCTestCase {
  private let resetKey = "mimo.reset_at"
  private let now = ISO8601DateFormatter().date(from: "2026-10-20T12:00:00Z")!
  private let header = "api-platform_serviceToken=reset-fixture; userId=42"

  func testConfiguredDateAppliesOnlyToPlanCreditsWithoutInventingWindow() async throws {
    let expected = ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z")!
    for text in ["2026-11-01", "2026-11-01T00:00:00Z", "2026-11-01T02:30:00+02:30", " 2026-11-01 \n"] {
      let usage = try await fetch(reset: text)
      let plan = try XCTUnwrap(usage.metrics.first { $0.id == "plan-total_token" })
      XCTAssertEqual(plan.resetAt, expected)
      XCTAssertEqual(plan.resetIn, formatResetCountdown(to: expected, now: now))
      XCTAssertEqual(plan.remainingPercent, 75)
      XCTAssertNil(plan.windowSeconds)
      XCTAssertNil(QuotaPace(metric: plan, provider: .xiaomiMiMo, fetchedAt: now, now: now))
      XCTAssertTrue(plan.detail?.contains("configured reset") == true)
      XCTAssertTrue(plan.detail?.contains("Plan expires 2026-12-31") == true)
      let bonus = try XCTUnwrap(usage.metrics.first { $0.id == "plan-compensation_total_token" })
      XCTAssertNil(bonus.resetAt)
      XCTAssertNil(bonus.resetIn)
    }
    let fractional = try await fetch(reset: "2026-11-01T00:00:00.125Z")
    XCTAssertEqual(try XCTUnwrap(fractional.metrics.first?.resetAt).timeIntervalSince(expected), 0.125, accuracy: 0.001)
  }

  func testBlankAndMissingDatesKeepResetUnknown() async throws {
    for text: String? in [nil, "", " \n"] {
      let usage = try await fetch(reset: text)
      XCTAssertTrue(usage.metrics.allSatisfy { $0.resetAt == nil && $0.resetIn == nil && $0.windowSeconds == nil })
      XCTAssertEqual(usage.metrics.first?.detail, "Plan expires 2026-12-31")
    }
  }

  func testElapsedDateDoesNotAdvanceOrRefillQuota() async throws {
    for text in ["2026-10-01", "2026-10-20T12:00:00Z"] {
      let usage = try await fetch(reset: text)
      let plan = try XCTUnwrap(usage.metrics.first)
      XCTAssertNil(plan.resetAt)
      XCTAssertNil(plan.resetIn)
      XCTAssertNil(plan.windowSeconds)
      XCTAssertEqual(plan.remainingPercent, 75)
      XCTAssertTrue(plan.detail?.contains("reset date has passed") == true)
    }
  }

  func testInvalidDateFailsBeforeNetworkingWithoutReflectingInput() async {
    for text in ["invalid-reset-fixture", "2026-02-29", "2026-11-01T00:00:00", "2026-11-01T25:00:00Z", "2026-11-01T00:00:00+24:00", "0000-01-01"] {
      let http = MiMoResetHTTP()
      do {
        _ = try await MiMoQuotaClient(httpClient: http).fetchUsage(configuration: configuration(reset: text), now: now)
        XCTFail("Expected invalid manual date to fail")
      } catch let error as ProviderClientError {
        XCTAssertEqual(error.kind, .notConfigured)
        XCTAssertFalse(error.message.contains(text))
      } catch {
        XCTFail("Unexpected error: \(error)")
      }
      let requests = await http.requests
      XCTAssertTrue(requests.isEmpty)
    }
  }

  func testDatePersistsAlongsideCanonicalCookiesAndPendingAccounts() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
    for cookies: String? in [nil, "", header, "env:MIMO_COOKIES"] {
      var credentials = [resetKey: "2026-11-01"]
      credentials[CredentialField.mimoSessionCookies] = cookies
      let account = ProviderAccount(provider: .xiaomiMiMo, credentials: credentials)
      try store.save(AppSettings(accounts: [account]))
      XCTAssertEqual(try store.load().accounts.first?.credentials, credentials)
      let redacted = AppSettings(accounts: [account]).redactedCredentials()
      XCTAssertEqual(redacted.accounts.first?.credentials, [:])
    }
  }

  func testReconnectKeepsAccountOwnedDateAndExplicitReplacementCanClearIt() {
    let account = ProviderAccount(provider: .xiaomiMiMo, credentials: configuration(reset: "2026-11-01").credentials)
    let replacement = [CredentialField.mimoSessionCookies: "api-platform_serviceToken=new-fixture; userId=42"]
    XCTAssertEqual(account.credentialsForImport(replacement)[resetKey], "2026-11-01")
    var cleared = replacement
    cleared[resetKey] = ""
    XCTAssertEqual(account.credentialsForImport(cleared), cleared)
  }

  func testInvalidStoredDateCannotReplaceDurableSettings() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("settings.json")
    let store = SettingsStore(fileURL: file)
    var account = ProviderAccount(provider: .xiaomiMiMo, credentials: configuration(reset: "2026-11-01").credentials)
    try store.save(AppSettings(accounts: [account]))
    let before = try Data(contentsOf: file)
    account.credentials[resetKey] = "invalid-reset-fixture"
    XCTAssertThrowsError(try store.save(AppSettings(accounts: [account])))
    XCTAssertEqual(try Data(contentsOf: file), before)
  }

  func testDateFieldIsOptionalAndNonsecret() throws {
    let field = try XCTUnwrap(QuotaProvider.xiaomiMiMo.credentialFields.first { $0.key == resetKey })
    XCTAssertFalse(field.isRequired)
    XCTAssertFalse(field.isSecret)
    XCTAssertTrue(ProviderAccount(provider: .xiaomiMiMo, credentials: [CredentialField.mimoSessionCookies: header]).hasRequiredCredentials)
  }

  private func configuration(reset: String?) -> ProviderRuntimeConfiguration {
    var credentials = [CredentialField.mimoSessionCookies: header]
    credentials[resetKey] = reset
    return ProviderRuntimeConfiguration(accountID: "mimo", provider: .xiaomiMiMo, displayName: "MiMo", isEnabled: true, credentials: credentials)
  }

  private func fetch(reset: String?) async throws -> ProviderUsage {
    try await MiMoQuotaClient(httpClient: MiMoResetHTTP()).fetchUsage(configuration: configuration(reset: reset), now: now)
  }
}

private actor MiMoResetHTTP: HTTPClient {
  private(set) var requests: [URLRequest] = []

  func data(for request: URLRequest, redirects: HTTPRedirectPolicy) async throws -> (Data, HTTPURLResponse) {
    try await data(for: request)
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    let body = request.url?.lastPathComponent == "detail"
      ? #"{"code":0,"data":{"planCode":"max","currentPeriodEnd":"2026-12-31"}}"#
      : #"{"code":0,"data":{"usage":{"items":[{"name":"total_token","used":25,"limit":100,"percent":0.25},{"name":"compensation_total_token","used":1,"limit":10,"percent":0.1}]}}}"#
    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
