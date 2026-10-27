import Foundation
import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class StepFunPlanQuotaTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)
  private let key = "fixture-personal-plan-key"
  private func configuration(userID: String? = nil) -> ProviderRuntimeConfiguration {
    var credentials = [CredentialField.stepFunPlanKey: key]
    credentials[CredentialField.stepFunUserID] = userID
    return ProviderRuntimeConfiguration(accountID: "fixture-plan", provider: .stepFun,
      displayName: "StepFun", isEnabled: true, credentials: credentials)
  }
  private var coding: String {
    #"{"schema_version":1,"observed_at_ms":1700000000000,"scope":"personal_account","account":{"id":"123"},"plan":{"state":"known","family":"coding","name":"Pro","subscription":{"id":"7","expires_at_ms":null}},"quota":{"state":"known","allowed":true,"reason":null,"windows":[{"id":"five_hour","limited":true,"used_percent":25,"resets_at_ms":1700000010000},{"id":"weekly","limited":false,"used_percent":null,"resets_at_ms":null}],"credit_buckets":[]}}"#
  }
  private var token: String {
    #"{"schema_version":1,"observed_at_ms":1700000000000,"scope":"personal_account","account":{"id":"123"},"plan":{"state":"known","family":"token","name":null,"subscription":null},"quota":{"state":"known","allowed":true,"reason":null,"windows":[],"credit_buckets":[{"type":"subscription","total":"1000","remaining":"400","used_percent":60,"resets_at_ms":1700000020000,"expires_at_ms":null},{"type":"topup","total":"9007199254740993","remaining":"42","used_percent":99,"resets_at_ms":null,"expires_at_ms":1800000000000}]}}"#
  }

  func testPlanKeyUsesIsolatedGETAndTakesPrecedenceOverConsoleSession() async throws {
    var config = configuration(userID: "123")
    config.credentials[CredentialField.stepFunSessionToken] = "fixture-unused-console-token"
    config.credentials[CredentialField.stepFunWebID] = "fixture-unused-device"
    let http = PlanHTTPStub(body: coding)
    let usage = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: config, now: now)
    let requests = await http.requests, policies = await http.policies
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(policies, [.refuse])
    XCTAssertEqual(request.url?.absoluteString, "https://api.stepfun.ai/step_plan/v1/usage")
    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Oasis-Token"))
    XCTAssertNil(request.httpBody)
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertEqual(usage.accountID, config.accountID)
    let fiveHour = try XCTUnwrap(usage.metrics.first { $0.id == "five-hour" })
    XCTAssertEqual(fiveHour.remainingPercent, 75)
    XCTAssertEqual(fiveHour.resetAt, Date(timeIntervalSince1970: 1_700_000_010))
    XCTAssertEqual(fiveHour.windowSeconds, 18_000)
    let weekly = try XCTUnwrap(usage.metrics.first { $0.id == "weekly" })
    XCTAssertTrue(weekly.isUnlimited)
    XCTAssertNil(weekly.remainingPercent)
  }

  func testTokenCreditsKeepIndependentPercentagesAndExactCounts() async throws {
    let usage = try await StepFunQuotaClient(httpClient: PlanHTTPStub(body: token))
      .fetchUsage(configuration: configuration(), now: now)
    let subscription = try XCTUnwrap(usage.metrics.first { $0.id == "monthly-credits" })
    XCTAssertEqual(subscription.remainingPercent, 40)
    XCTAssertEqual(subscription.usedDisplay, "600 credits")
    XCTAssertEqual(subscription.totalDisplay, "1000 credits")
    XCTAssertEqual(subscription.resetAt, Date(timeIntervalSince1970: 1_700_000_020))
    XCTAssertNil(subscription.windowSeconds)
    let topup = try XCTUnwrap(usage.metrics.first { $0.id == "topup-credits" })
    XCTAssertEqual(topup.remainingPercent, 1)
    XCTAssertEqual(topup.remainingAmount, 42)
    XCTAssertEqual(topup.usedDisplay, "9007199254740951 credits")
    XCTAssertEqual(topup.totalDisplay, "9007199254740993 credits")
    XCTAssertNil(topup.resetAt)
    XCTAssertNil(topup.windowSeconds)
    XCTAssertTrue(topup.detail?.contains("Next top-up expiry") == true)
  }

  func testExpiredTopupsAreOmittedAndNullPercentRemainsUnknown() async throws {
    let body = token.replacingOccurrences(of: "1800000000000", with: "1600000000000")
      .replacingOccurrences(of: "\"used_percent\":60", with: "\"used_percent\":null")
    let usage = try await StepFunQuotaClient(httpClient: PlanHTTPStub(body: body))
      .fetchUsage(configuration: configuration(), now: now)
    XCTAssertEqual(usage.metrics.map(\.id), ["monthly-credits"])
    XCTAssertNil(usage.metrics.first?.remainingPercent)
    XCTAssertEqual(usage.metrics.first?.remainingAmount, 400)
  }

  func testInvalidSchemaAndInconsistentQuotasFailWithoutPublishingPartialMetrics() async throws {
    let invalid = [
      coding.replacingOccurrences(of: "\"schema_version\":1", with: "\"schema_version\":2"),
      coding.replacingOccurrences(of: "personal_account", with: "organization"),
      coding.replacingOccurrences(of: "1700000000000", with: "1800000000000"),
      coding.replacingOccurrences(of: "\"weekly\"", with: "\"five_hour\""),
      coding.replacingOccurrences(of: "\"used_percent\":25", with: "\"used_percent\":101"),
      coding.replacingOccurrences(of: "\"limited\":false", with: "\"limited\":true"),
      token.replacingOccurrences(of: "\"type\":\"topup\"", with: "\"type\":\"unknown\""),
      token.replacingOccurrences(of: "\"remaining\":\"400\"", with: "\"remaining\":\"1001\""),
      token.replacingOccurrences(of: "\"used_percent\":60", with: "\"used_percent\":-1"),
      token.replacingOccurrences(of: "\"total\":\"1000\"", with: "\"total\":\"9223372036854775808\""),
      token.replacingOccurrences(of: "\"state\":\"known\",\"allowed\"", with: "\"state\":\"partial\",\"allowed\""),
      String(repeating: " ", count: 256 * 1024 + 1), key
    ]
    for body in invalid {
      do {
        _ = try await StepFunQuotaClient(httpClient: PlanHTTPStub(body: body))
          .fetchUsage(configuration: configuration(), now: now)
        XCTFail("Accepted invalid quota")
      } catch let error as ProviderClientError {
        XCTAssertEqual(error.kind, .decoding)
        XCTAssertFalse(error.message.contains(key))
      }
    }
  }

  func testDifferentAccountIsRejectedWithoutEchoingIdentity() async throws {
    do {
      _ = try await StepFunQuotaClient(httpClient: PlanHTTPStub(body: coding))
        .fetchUsage(configuration: configuration(userID: "999"), now: now)
      XCTFail("Accepted another account")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .auth)
      XCTAssertFalse(error.message.contains("123"))
      XCTAssertFalse(error.message.contains("999"))
    }
  }

  func testHTTPFailuresAreSanitizedAndRateLimitsPreserveRetryAfter() async throws {
    for (status, kind) in [(302, QuotaErrorKind.auth), (401, .auth), (403, .auth), (429, .rateLimit), (500, .api)] {
      let http = PlanHTTPStub(body: key, status: status)
      do {
        _ = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
        XCTFail("Accepted failed HTTP status")
      } catch let error as ProviderClientError {
        XCTAssertEqual(error.kind, kind)
        XCTAssertFalse(error.message.contains(key))
        XCTAssertEqual(error.retryAfter, status == 429 ? 30 : nil)
      }
    }
  }

  func testCancellationIsPreservedAndNetworkErrorsAreSanitized() async throws {
    for error in [CancellationError() as any Error, URLError(.cancelled)] {
      do {
        _ = try await StepFunQuotaClient(httpClient: PlanFailingHTTP(error: error))
          .fetchUsage(configuration: configuration(), now: now)
        XCTFail("Swallowed cancellation")
      } catch { XCTAssertTrue(error is CancellationError) }
    }
    do {
      _ = try await StepFunQuotaClient(httpClient: PlanFailingHTTP(error: NSError(domain: key, code: 1)))
        .fetchUsage(configuration: configuration(), now: now)
      XCTFail("Accepted network failure")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .network)
      XCTAssertFalse(error.message.contains(key))
    }
  }

  func testPlanKeyIsReadyAndRedactedWhileEmptyAccountsNeedCredentials() throws {
    let account = ProviderAccount(provider: .stepFun, credentials: configuration(userID: "123").credentials)
    XCTAssertTrue(account.hasRequiredCredentials)
    XCTAssertFalse(ProviderAccount(provider: .stepFun).hasRequiredCredentials)
    let redacted = AppSettings(accounts: [account]).redactedCredentials()
    let text = String(decoding: try JSONEncoder().encode(redacted), as: UTF8.self)
    XCTAssertFalse(text.contains(key))
    XCTAssertFalse(text.contains("123"))
  }
}

private actor PlanHTTPStub: HTTPClient {
  let body: String
  let status: Int
  private(set) var requests: [URLRequest] = []
  private(set) var policies: [HTTPRedirectPolicy] = []
  init(body: String, status: Int = 200) { self.body = body; self.status = status }
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
      headerFields: ["Retry-After": "30"])!)
  }
  func data(for request: URLRequest, redirects: HTTPRedirectPolicy) async throws -> (Data, HTTPURLResponse) {
    policies.append(redirects)
    return try await data(for: request)
  }
}
private struct PlanFailingHTTP: HTTPClient {
  let error: any Error
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw error }
  func data(for request: URLRequest, redirects: HTTPRedirectPolicy) async throws -> (Data, HTTPURLResponse) { throw error }
}
