import Foundation
import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class StepFunResetDateTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_792_497_600)
  private let token = "fixture-token"
  private let webID = "fixture-device"
  private let consoleBody = #"{"status":"CODE_OK","plan_family":2,"plan_credit_rate_limit":{"subscription_credit_left_rate":0.75,"credit_buckets":[{"type":2,"credit_total":100,"credit_residual":50,"expire_at":"1900000000"}]}}"#
  private let consoleBodyWithReset = #"{"status":"CODE_OK","plan_family":2,"plan_credit_rate_limit":{"subscription_credit_left_rate":0.75,"subscription_credit_reset_time":"1900000000","credit_buckets":[{"type":2,"credit_total":100,"credit_residual":50,"expire_at":"1900000000"}]}}"#
  private let legacyBody = #"{"status":"CODE_OK","five_hour_usage_left_rate":0.5,"weekly_usage_left_rate":0.6}"#

  private var planBody: String {
    #"{"schema_version":1,"observed_at_ms":1792497600000,"scope":"personal_account","account":{"id":"123"},"plan":{"state":"known","family":"token","name":null,"subscription":null},"quota":{"state":"known","allowed":true,"reason":null,"windows":[],"credit_buckets":[{"type":"subscription","total":"100","remaining":"75","used_percent":25,"resets_at_ms":null,"expires_at_ms":null},{"type":"topup","total":"100","remaining":"50","used_percent":50,"resets_at_ms":null,"expires_at_ms":1900000000000}]}}"#
  }

  private func consoleConfig(reset: String?) -> ProviderRuntimeConfiguration {
    var creds: [String: String] = [CredentialField.stepFunSessionToken: token, CredentialField.stepFunWebID: webID]
    if let reset { creds[CredentialField.stepFunResetAt] = reset }
    return ProviderRuntimeConfiguration(accountID: "sf", provider: .stepFun, displayName: "StepFun", isEnabled: true, credentials: creds)
  }
  private func planConfig(reset: String?) -> ProviderRuntimeConfiguration {
    var creds: [String: String] = [CredentialField.stepFunPlanKey: "sk-plan-fixture"]
    if let reset { creds[CredentialField.stepFunResetAt] = reset }
    return ProviderRuntimeConfiguration(accountID: "sf", provider: .stepFun, displayName: "StepFun", isEnabled: true, credentials: creds)
  }

  // Past anchor: monthly-credits gets reset, windowSeconds, label, pace; top-up never gets it; redirects refused
  func testPastAnchorMonthlyReset() async throws {
    // Verify now == 2026-10-20T12:00:00Z
    XCTAssertEqual(ISO8601DateFormatter().date(from: "2026-10-20T12:00:00Z"), now)
    let http = StepFunResetStub(body: consoleBody)
    let usage = try await StepFunQuotaClient(httpClient: http)
      .fetchUsage(configuration: consoleConfig(reset: "2026-10-01"), now: now)
    let policies = await http.redirectPolicies
    XCTAssertEqual(policies.first, HTTPRedirectPolicy.refuse)
    let m = try XCTUnwrap(usage.metrics.first { $0.id == "monthly-credits" })
    XCTAssertEqual(m.resetAt, ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))
    XCTAssertEqual(m.resetIn, formatResetCountdown(to: ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z")!, now: now))
    XCTAssertEqual(m.windowSeconds, 31 * 86_400)
    XCTAssertEqual(m.label, "Monthly plan credits")
    XCTAssertEqual(m.remainingPercent, 75)
    XCTAssertTrue(m.detail?.contains("configured monthly reset") == true)
    XCTAssertNotNil(QuotaPace(metric: m, provider: .stepFun, fetchedAt: now, now: now))
    let topup = try XCTUnwrap(usage.metrics.first { $0.id == "topup-credits" })
    XCTAssertNil(topup.resetAt)
    XCTAssertNil(topup.windowSeconds)
  }

  // Future anchor: countdown only, no windowSeconds
  func testFutureAnchorCountdown() async throws {
    let expected = ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z")!
    for text in ["2026-11-01", "2026-11-01T00:00:00Z", "2026-11-01T02:30:00+02:30"] {
      let usage = try await StepFunQuotaClient(httpClient: StepFunResetStub(body: consoleBody))
        .fetchUsage(configuration: consoleConfig(reset: text), now: now)
      let m = try XCTUnwrap(usage.metrics.first { $0.id == "monthly-credits" })
      XCTAssertEqual(m.resetAt, expected)
      XCTAssertNil(m.windowSeconds)
      XCTAssertNil(QuotaPace(metric: m, provider: .stepFun, fetchedAt: now, now: now))
    }
  }

  // Server resetAt preserved; manual date does not invent windowSeconds
  func testServerResetPreserved() async throws {
    let planWithReset = planBody.replacingOccurrences(of: "\"resets_at_ms\":null", with: "\"resets_at_ms\":1900000000000")
    for (config, body) in [(consoleConfig(reset: "2026-10-01"), consoleBodyWithReset),
                           (planConfig(reset: "2026-10-01"), planWithReset)] {
      let usage = try await StepFunQuotaClient(httpClient: StepFunResetStub(body: body))
        .fetchUsage(configuration: config, now: now)
      let m = try XCTUnwrap(usage.metrics.first { $0.id == "monthly-credits" })
      XCTAssertEqual(m.resetAt, Date(timeIntervalSince1970: 1_900_000_000))
      XCTAssertNil(m.windowSeconds)
      XCTAssertEqual(m.remainingPercent, 75)
      XCTAssertFalse(m.detail?.contains("configured monthly reset") == true)
    }
  }

  // Legacy five-hour/weekly never get manual reset
  func testLegacyMetricsUnchanged() async throws {
    let usage = try await StepFunQuotaClient(httpClient: StepFunResetStub(body: legacyBody))
      .fetchUsage(configuration: consoleConfig(reset: "2026-10-01"), now: now)
    let fh = try XCTUnwrap(usage.metrics.first { $0.id == "five-hour" })
    let wk = try XCTUnwrap(usage.metrics.first { $0.id == "weekly" })
    XCTAssertNil(fh.resetAt)
    XCTAssertNil(wk.resetAt)
    XCTAssertEqual(wk.windowSeconds, 604_800)
  }

  // Short month: original day restored after Feb
  func testShortMonthDayRestored() async throws {
    for (current, reset, days) in [("2026-02-15", "2026-02-28", 28), ("2026-03-15", "2026-03-31", 31)] {
      let currentDate = try XCTUnwrap(parseQuotaResetDate(current))
      let usage = try await StepFunQuotaClient(httpClient: StepFunResetStub(body: consoleBody))
        .fetchUsage(configuration: consoleConfig(reset: "2026-01-31"), now: currentDate)
      let metric = try XCTUnwrap(usage.metrics.first { $0.id == "monthly-credits" })
      XCTAssertEqual(metric.resetAt, parseQuotaResetDate(reset))
      XCTAssertEqual(metric.windowSeconds, days * 86_400)
    }
  }

  // Plan key mode also supports reset date
  func testPlanKeyModeReset() async throws {
    let usage = try await StepFunQuotaClient(httpClient: StepFunResetStub(body: planBody))
      .fetchUsage(configuration: planConfig(reset: "2026-10-01"), now: now)
    let m = try XCTUnwrap(usage.metrics.first { $0.id == "monthly-credits" })
    XCTAssertEqual(m.resetAt, ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))
    XCTAssertEqual(m.remainingPercent, 75)
    XCTAssertTrue(m.detail?.contains("configured monthly reset") == true)
  }

  // Blank/missing: no reset; invalid dates fail before HTTP
  func testBlankAndInvalidReset() async throws {
    for text: String? in [nil, "", " \n"] {
      let usage = try await StepFunQuotaClient(httpClient: StepFunResetStub(body: consoleBody))
        .fetchUsage(configuration: consoleConfig(reset: text), now: now)
      let m = try XCTUnwrap(usage.metrics.first { $0.id == "monthly-credits" })
      XCTAssertNil(m.resetAt)
      XCTAssertNil(m.windowSeconds)
    }
    for bad in ["invalid-date", "2026-02-29", "2026-11-01T00:00:00"] {
      let http = StepFunResetStub()
      do {
        _ = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: consoleConfig(reset: bad), now: now)
        XCTFail("Expected failure")
      } catch let e as ProviderClientError {
        XCTAssertEqual(e.kind, .notConfigured)
        XCTAssertFalse(e.message.contains(bad))
      } catch { XCTFail("\(error)") }
      let reqs = await http.requests
      XCTAssertTrue(reqs.isEmpty)
    }
  }

  // Field optional/nonsecret; credentialsForImport retains config unless explicit blank
  func testFieldPropertiesAndImportRetention() throws {
    let field = try XCTUnwrap(QuotaProvider.stepFun.credentialFields.first { $0.key == CredentialField.stepFunResetAt })
    XCTAssertFalse(field.isSecret)
    XCTAssertFalse(field.isRequired)
    let account = ProviderAccount(provider: .stepFun, credentials: consoleConfig(reset: "2026-11-01").credentials)
    XCTAssertEqual(account.credentialsForImport([CredentialField.stepFunSessionToken: "new"])[CredentialField.stepFunResetAt], "2026-11-01")
    var cleared = [CredentialField.stepFunSessionToken: "new"]
    cleared[CredentialField.stepFunResetAt] = ""
    XCTAssertEqual(account.credentialsForImport(cleared), cleared)
  }

  func testConfiguredMonthlyPaceUsesServerResetAndPurchaseStart() async throws {
    let fetched = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-26T14:57:00Z"))
    let serverReset = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-12-24T15:08:47Z"))
    let purchase = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-24T14:34:00Z"))
    let seconds = Int(serverReset.timeIntervalSince1970)
    let console = consoleBody.replacingOccurrences(of: "\"subscription_credit_left_rate\":0.75", with: "\"subscription_credit_left_rate\":0.75,\"subscription_credit_reset_time\":\(seconds)")
    let plan = planBody.replacingOccurrences(of: "\"resets_at_ms\":null", with: "\"resets_at_ms\":\(seconds * 1000)")
    for (var config, body) in [(consoleConfig(reset: "2026-11-24T14:34:00Z"), console),
                               (planConfig(reset: "2026-11-24T14:34:00Z"), plan)] {
      config.credentials[CredentialField.stepFunPaceWindow] = "monthly"
      let usage = try await StepFunQuotaClient(httpClient: StepFunResetStub(body: body)).fetchUsage(configuration: config, now: fetched)
      let metric = try XCTUnwrap(usage.metrics.first { $0.id == "monthly-credits" })
      XCTAssertEqual(metric.resetAt, serverReset)
      XCTAssertEqual(metric.windowSeconds, Int(serverReset.timeIntervalSince(purchase)))
      let pace = try XCTUnwrap(QuotaPace(metric: metric, provider: .stepFun, fetchedAt: fetched, now: fetched))
      XCTAssertEqual(pace.elapsedFraction, fetched.timeIntervalSince(purchase) / serverReset.timeIntervalSince(purchase), accuracy: 0.00001)
      let topup = try XCTUnwrap(usage.metrics.first { $0.id == "topup-credits" })
      XCTAssertNil(topup.windowSeconds)
      XCTAssertNil(topup.resetAt)
    }
  }

  func testSelectedWeeklyAndMonthlyPeriodsAndInvalidSetting() async throws {
    let end = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-23T12:00:00Z"))
    let body = consoleBody.replacingOccurrences(of: "\"subscription_credit_left_rate\":0.75", with: "\"subscription_credit_left_rate\":0.75,\"subscription_credit_reset_time\":\(Int(end.timeIntervalSince1970))")
    var config = consoleConfig(reset: nil)
    config.credentials[CredentialField.stepFunPaceWindow] = "weekly"
    let weekly = try await StepFunQuotaClient(httpClient: StepFunResetStub(body: body)).fetchUsage(configuration: config, now: now)
    let weekMetric = try XCTUnwrap(weekly.metrics.first { $0.id == "monthly-credits" })
    XCTAssertEqual(weekMetric.windowSeconds, 7 * 86_400)
    XCTAssertNotNil(QuotaPace(metric: weekMetric, provider: .stepFun, fetchedAt: now, now: now))

    config.credentials[CredentialField.stepFunPaceWindow] = "monthly"
    let monthly = try await StepFunQuotaClient(httpClient: StepFunResetStub(body: body)).fetchUsage(configuration: config, now: now)
    let monthMetric = try XCTUnwrap(monthly.metrics.first { $0.id == "monthly-credits" })
    XCTAssertEqual(monthMetric.windowSeconds, 30 * 86_400)
    XCTAssertEqual(monthMetric.resetAt, end)

    config.credentials[CredentialField.stepFunPaceWindow] = "invalid"
    let http = StepFunResetStub(body: body)
    do {
      _ = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: config, now: now)
      XCTFail("Expected invalid period to be rejected")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .notConfigured)
    }
    let requests = await http.requests
    XCTAssertTrue(requests.isEmpty)

    let field = try XCTUnwrap(QuotaProvider.stepFun.credentialFields.first { $0.key == CredentialField.stepFunPaceWindow })
    XCTAssertFalse(field.isSecret)
    let account = ProviderAccount(provider: .stepFun, credentials: [CredentialField.stepFunPaceWindow: "monthly"])
    XCTAssertEqual(account.credentialsForImport([CredentialField.stepFunPlanKey: "new"])[CredentialField.stepFunPaceWindow], "monthly")
  }

  func testMonthlyPaceUsesClampedPurchaseAnchorAndHonorsFutureAnchor() async throws {
    let fetched = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-02-15T12:00:00Z"))
    let end = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-02-28T12:00:00Z"))
    let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-31T12:00:00Z"))
    let body = consoleBody.replacingOccurrences(of: "\"subscription_credit_left_rate\":0.75", with: "\"subscription_credit_left_rate\":0.75,\"subscription_credit_reset_time\":\(Int(end.timeIntervalSince1970))")
    var config = consoleConfig(reset: "2027-01-31T12:00:00Z")
    config.credentials[CredentialField.stepFunPaceWindow] = "monthly"
    let client = StepFunQuotaClient(httpClient: StepFunResetStub(body: body))
    let usage = try await client.fetchUsage(configuration: config, now: fetched)
    let metric = try XCTUnwrap(usage.metrics.first { $0.id == "monthly-credits" })
    XCTAssertEqual(metric.windowSeconds, Int(end.timeIntervalSince(start)))
    XCTAssertNotNil(QuotaPace(metric: metric, provider: .stepFun, fetchedAt: fetched, now: fetched))

    config.credentials[CredentialField.stepFunResetAt] = "2027-02-20T12:00:00Z"
    let future = try await client.fetchUsage(configuration: config, now: fetched)
    let futureMetric = try XCTUnwrap(future.metrics.first { $0.id == "monthly-credits" })
    XCTAssertEqual(futureMetric.resetAt, end)
    XCTAssertNil(futureMetric.windowSeconds)
    XCTAssertNil(QuotaPace(metric: futureMetric, provider: .stepFun, fetchedAt: fetched, now: fetched))
  }

}

private actor StepFunResetStub: HTTPClient {
  private let body: String
  private(set) var requests: [URLRequest] = []
  private(set) var redirectPolicies: [HTTPRedirectPolicy] = []
  init(body: String = #"{"status":"CODE_OK","plan_family":2,"plan_credit_rate_limit":{"subscription_credit_left_rate":0.75}}"#) { self.body = body }
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
  }
  func data(for request: URLRequest, redirects: HTTPRedirectPolicy) async throws -> (Data, HTTPURLResponse) {
    redirectPolicies.append(redirects)
    precondition(redirects == .refuse, "StepFun must refuse redirects")
    return try await data(for: request)
  }
}
