import Foundation
import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class StepFunBrowserClientTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)
  private let quota = Data(#"{"status":"CODE_OK","plan_family":2,"plan_credit_rate_limit":{"subscription_credit_left_rate":0.75}}"#.utf8)

  private func jwt(_ claims: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
    let payload = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return "h.\(payload).s"
  }

  private func session(expires: Date? = nil) throws -> StepFunBrowserSession {
    // The official compound cookie binds its device through the refresh JWT.
    // Access tokens deliberately have no device_id claim in this fixture.
    let access = try jwt(["mode": 2, "oasis_id": "123", "exp": 1_700_003_600])
    let refresh = try jwt(["app_id": 20700, "oasis_id": "123", "device_id": "owned-device", "exp": 1_700_086_400])
    let cookies = try [("Oasis-Token", "\(access)...\(refresh)"), ("Oasis-Webid", "owned-device")].map { name, value in
      var properties: [HTTPCookiePropertyKey: Any] = [
        .name: name, .value: value, .domain: "platform.stepfun.ai", .path: "/", .secure: "TRUE",
        HTTPCookiePropertyKey("HttpOnly"): "TRUE"
      ]
      if let expires { properties[.expires] = expires }
      return try XCTUnwrap(HTTPCookie(properties: properties))
    }
    return try StepFunBrowserSession(cookies: cookies, now: now)
  }

  private func configuration(_ session: StepFunBrowserSession) throws -> ProviderRuntimeConfiguration {
    ProviderRuntimeConfiguration(accountID: "owned-stepfun", provider: .stepFun, displayName: "StepFun",
      isEnabled: true, credentials: try session.credentials(verifiedUserID: "123"))
  }

  func testBrowserQuotaAndIdentityUseOnlyTheOwnedCookieProtocol() async throws {
    let browser = try session()
    for identity in [#"{"status":"CODE_OK","uid":"123"}"#, #"{"status":1,"uid":123}"#] {
      let http = StepFunBrowserClientHTTP(quota: quota, identity: Data(identity.utf8))
      let client = StepFunQuotaClient(httpClient: http)
      let configuration = try configuration(browser)
      let usage = try await client.fetchUsage(configuration: configuration, now: now)
      XCTAssertEqual(usage.metrics.first?.remainingPercent, 75)
      let quotaRequests = await http.requests
      XCTAssertEqual(quotaRequests.count, 1)
      XCTAssertEqual(quotaRequests.first?.url?.absoluteString,
        "https://platform.stepfun.ai/api/step.openapi.devcenter.Dashboard/QueryStepPlanRateLimit")

      let uid = try await client.verifyIdentity(configuration: configuration, now: now)
      XCTAssertEqual(uid, "123")
      let requests = await http.requests
      XCTAssertEqual(requests.count, 2)
      XCTAssertEqual(requests.last?.url?.absoluteString,
        "https://platform.stepfun.ai/api/step.openapi.devcenter.Dashboard/UserInfo")
      for request in requests {
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.httpBody, Data("{}".utf8))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), browser.cookieHeader)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Oasis-Webid"), "owned-device")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Oasis-Appid"), "20700")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Oasis-Platform"), "web")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Connect-Protocol-Version"), "1")
        XCTAssertNil(request.value(forHTTPHeaderField: "Oasis-Token"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(request.httpShouldHandleCookies)
      }
      let policies = await http.policies
      XCTAssertEqual(policies, [.refuse, .refuse])
      let serialized = String(decoding: try JSONEncoder().encode(usage), as: UTF8.self)
      for secret in browser.secretValues { XCTAssertFalse(serialized.contains(secret)) }
    }
  }

  func testInvalidIdentityResponsesCannotAuthorizeAnAccountOrLeakPayloads() async throws {
    let browser = try session()
    let credentials = try configuration(browser)
    let invalidObjects: [[String: Any]] = [
      ["status": true, "uid": "123"], ["status": false, "uid": "123"],
      ["status": "CODE_INTERNAL_ERROR", "uid": "123"], ["status": "1", "uid": "123"],
      ["status": "CODE_OK", "uid": true], ["status": "CODE_OK", "uid": 0],
      ["status": "CODE_OK", "uid": -1], ["status": "CODE_OK", "uid": 1.5],
      ["status": "CODE_OK", "uid": ""], ["status": "CODE_OK", "uid": "not-a-uid"],
      ["status": "CODE_OK", "uid": "123\n"], ["status": "CODE_OK", "uid": "9223372036854775808"],
      ["status": "CODE_OK"], ["uid": "123"]
    ]
    var invalidBodies = try invalidObjects.map { object -> Data in
      var echoed = object
      echoed["message"] = "upstream-identity-body \(browser.cookieHeader)"
      return try JSONSerialization.data(withJSONObject: echoed)
    }
    invalidBodies += [Data("invalid-json \(browser.cookieHeader)".utf8), Data("[]".utf8)]
    for body in invalidBodies {
      let http = StepFunBrowserClientHTTP(quota: quota, identity: body)
      do {
        _ = try await StepFunQuotaClient(httpClient: http).verifyIdentity(configuration: credentials, now: now)
        XCTFail("Expected identity rejection")
      } catch let error as ProviderClientError {
        XCTAssertEqual(error.kind, .auth)
        XCTAssertFalse(error.message.contains("upstream-identity-body"))
        XCTAssertFalse(error.message.contains("invalid-json"))
        for secret in browser.secretValues { XCTAssertFalse(error.message.contains(secret)) }
      }
    }
  }

  func testBrowserFieldMismatchAndCookieExpiryFailBeforeAnyHTTPRequest() async throws {
    let original = try configuration(session())
    var wrongToken = original
    wrongToken.credentials[CredentialField.stepFunSessionToken] = "unrelated-access-token"
    var wrongDevice = original
    wrongDevice.credentials[CredentialField.stepFunWebID] = "unrelated-device"
    let expired = try configuration(session(expires: now.addingTimeInterval(600)))
    for (configuration, date) in [(wrongToken, now), (wrongDevice, now), (expired, now.addingTimeInterval(600)),
                                 (original, now.addingTimeInterval(3600))] {
      let http = StepFunBrowserClientHTTP(quota: quota, identity: Data(#"{"status":1,"uid":"123"}"#.utf8))
      let client = StepFunQuotaClient(httpClient: http)
      do {
        _ = try await client.fetchUsage(configuration: configuration, now: date)
        XCTFail("Expected browser credential rejection")
      } catch let error as ProviderClientError { XCTAssertEqual(error.kind, .auth) }
      do {
        _ = try await client.verifyIdentity(configuration: configuration, now: date)
        XCTFail("Expected browser identity request rejection")
      } catch let error as ProviderClientError { XCTAssertEqual(error.kind, .auth) }
      let requests = await http.requests
      XCTAssertTrue(requests.isEmpty)
    }
  }

  func testManualCompoundTokenDerivesDeviceOnlyFromRefreshHalf() async throws {
    let browser = try session()
    let token = try XCTUnwrap(browser.cookieHeader.components(separatedBy: "; ").first)
      .replacingOccurrences(of: "Oasis-Token=", with: "")
    let manual = ProviderRuntimeConfiguration(accountID: "manual-stepfun", provider: .stepFun,
      displayName: "StepFun", isEnabled: true, credentials: [CredentialField.stepFunSessionToken: token])
    let http = StepFunBrowserClientHTTP(quota: quota, identity: Data())
    let usage = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: manual, now: now)
    XCTAssertEqual(usage.metrics.first?.remainingPercent, 75)
    let requests = await http.requests
    XCTAssertEqual(requests.count, 1)
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Oasis-Webid"), "owned-device")
    XCTAssertNil(request.value(forHTTPHeaderField: "Oasis-Token"))
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), browser.cookieHeader)
    XCTAssertFalse(request.httpShouldHandleCookies)
    let policies = await http.policies
    XCTAssertEqual(policies, [.refuse])
  }
}

private actor StepFunBrowserClientHTTP: HTTPClient {
  private let quota: Data
  private let identity: Data
  private(set) var requests: [URLRequest] = []
  private(set) var policies: [HTTPRedirectPolicy] = []

  init(quota: Data, identity: Data) {
    self.quota = quota
    self.identity = identity
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    let payload = request.url?.lastPathComponent == "UserInfo" ? identity : quota
    return (payload, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }

  func data(for request: URLRequest, redirects: HTTPRedirectPolicy) async throws -> (Data, HTTPURLResponse) {
    policies.append(redirects)
    return try await data(for: request)
  }
}
