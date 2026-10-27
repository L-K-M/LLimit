import Foundation
import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class StepFunBrowserSessionTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private func jwt(_ claims: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
    let payload = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return "h.\(payload).s"
  }

  private func access(subject: String = "123", mode: Int = 2, expires: Double = 1_700_003_600) throws -> String {
    try jwt(["mode": mode, "oasis_id": subject, "exp": expires])
  }

  private func refresh(subject: String = "123", device: String = "device", app: Int = 20700,
                       expires: Double = 1_700_086_400) throws -> String {
    try jwt(["app_id": app, "device_id": device, "oasis_id": subject, "exp": expires])
  }

  private func cookie(_ name: String, _ value: String, domain: String = "platform.stepfun.ai",
                      path: String = "/", expires: Date? = nil) throws -> HTTPCookie {
    var properties: [HTTPCookiePropertyKey: Any] = [
      .name: name, .value: value, .domain: domain, .path: path, .secure: "TRUE",
      HTTPCookiePropertyKey("HttpOnly"): "TRUE"
    ]
    if let expires { properties[.expires] = expires }
    return try XCTUnwrap(HTTPCookie(properties: properties))
  }

  private func cookies(access rawAccess: String? = nil, refresh rawRefresh: String? = nil,
                       webID: String = "device", domain: String = "platform.stepfun.ai",
                       path: String = "/", expires: Date? = nil) throws -> [HTTPCookie] {
    let token = "\(try rawAccess ?? access())...\(try rawRefresh ?? refresh())"
    return try [cookie("Oasis-Token", token, domain: domain, path: path, expires: expires),
                cookie("Oasis-Webid", webID, domain: domain, path: path, expires: expires)]
  }

  private func session() throws -> StepFunBrowserSession {
    try StepFunBrowserSession(cookies: cookies(), now: now)
  }

  private func response(access rawAccess: String? = nil, refresh rawRefresh: String? = nil,
                        mode: Any = 2, snakeCase: Bool = false) throws -> Data {
    var body: [String: Any] = [
      snakeCase ? "access_token" : "accessToken": [
        "raw": try rawAccess ?? access(expires: 1_700_007_200), "mode": mode, "duration": 7200
      ]
    ]
    if let rawRefresh { body[snakeCase ? "refresh_token" : "refreshToken"] = ["raw": rawRefresh] }
    return try JSONSerialization.data(withJSONObject: body)
  }

  func testCaptureKeepsOnlyExactConsoleAuthenticationCookies() throws {
    let noise = try [
      cookie("analytics", "analytics-fixture"), cookie("SSO", "sso-fixture", domain: "account.stepfun.ai"),
      cookie("Oasis-Token", "foreign-token", domain: "example.com"),
      cookie("Oasis-Webid", "nested-device", path: "/login")
    ]
    let captured = try StepFunBrowserSession(cookies: cookies() + noise, now: now)
    XCTAssertEqual(captured.accessToken, try access())
    XCTAssertEqual(captured.webID, "device")
    XCTAssertEqual(captured.subject, "123")
    XCTAssertEqual(captured.cookieHeader, "Oasis-Token=\(try access())...\(try refresh()); Oasis-Webid=device")
    let encoded = try captured.encoded()
    for excluded in ["analytics-fixture", "sso-fixture", "foreign-token", "nested-device"] {
      XCTAssertFalse(encoded.contains(excluded))
    }
    for domain in [".platform.stepfun.ai", "stepfun.ai", "account.stepfun.ai", "platform.stepfun.ai.evil.test"] {
      XCTAssertThrowsError(try StepFunBrowserSession(cookies: cookies(domain: domain), now: now))
    }
    XCTAssertThrowsError(try StepFunBrowserSession(cookies: cookies(path: "/login"), now: now))
  }

  func testEncodingRoundTripAndCredentialsPreservePrivateLogin() throws {
    let original = try session()
    let restored = try StepFunBrowserSession(serialized: original.encoded())
    XCTAssertEqual(restored, original)
    let credentials = try restored.credentials(verifiedUserID: "verified-uid")
    XCTAssertEqual(credentials[CredentialField.stepFunSessionToken], try access())
    XCTAssertEqual(credentials[CredentialField.stepFunWebID], "device")
    XCTAssertEqual(credentials[CredentialField.stepFunUserID], "verified-uid")
    XCTAssertEqual(try StepFunBrowserSession(serialized: XCTUnwrap(credentials[CredentialField.stepFunBrowserSession])), original)
    for value in [try access(), try refresh(), "device", "\(try access())...\(try refresh())"] {
      XCTAssertTrue(original.secretValues.contains(value))
    }
  }

  func testCaptureRejectsMissingDuplicateMalformedAndUnsafeCookies() throws {
    let pair = try cookies()
    for incomplete in [[], Array(pair.prefix(1)), Array(pair.suffix(1)), pair + pair] {
      XCTAssertThrowsError(try StepFunBrowserSession(cookies: incomplete, now: now))
    }
    XCTAssertThrowsError(try StepFunBrowserSession(cookies: cookies() + [cookie("Oasis-Webid", "other")], now: now))
    XCTAssertThrowsError(try StepFunBrowserSession(cookies: cookies(expires: now), now: now))
    for value in ["bad;cookie", "bad,header", "bad\u{0001}header", "bad header"] {
      let records: [[String: Any]] = [
        ["name": "Oasis-Token", "value": "\(try access())...\(try refresh())"],
        ["name": "Oasis-Webid", "value": value]
      ]
      let raw = String(decoding: try JSONSerialization.data(withJSONObject: records), as: UTF8.self)
      XCTAssertThrowsError(try StepFunBrowserSession(serialized: raw))
    }
    for invalid in ["{}", "[]", "not-json", String(repeating: "x", count: 100_001)] {
      XCTAssertThrowsError(try StepFunBrowserSession(serialized: invalid))
    }
  }

  func testCaptureRejectsAnonymousForeignAppAndMismatchedIdentity() throws {
    let invalidPairs = try [
      cookies(access: access(mode: 1)),
      cookies(access: access(subject: "456")),
      cookies(refresh: refresh(subject: "456")),
      cookies(refresh: refresh(app: 10300)),
      cookies(refresh: refresh(device: "other-device")),
      cookies(webID: "other-device"),
      cookies(access: "malformed-token"),
      cookies(refresh: "malformed-token")
    ]
    for pair in invalidPairs {
      XCTAssertThrowsError(try StepFunBrowserSession(cookies: pair, now: now)) { error in
        XCTAssertEqual((error as? ProviderClientError)?.kind, .auth)
      }
    }
  }

  func testRenewalUsesJWTExpiryAndExpiredPrivateLoginCannotSendRequest() async throws {
    let original = try session()
    XCTAssertFalse(original.needsRenewal(at: now))
    XCTAssertTrue(original.needsRenewal(at: now.addingTimeInterval(3600)))
    // An expired access token can renew while the refresh grant stays valid.
    XCTAssertFalse(original.isExpired(at: now.addingTimeInterval(3600)))

    let cookieExpiry = now.addingTimeInterval(600)
    let cookieBound = try StepFunBrowserSession(cookies: cookies(expires: cookieExpiry), now: now)
    let grantBound = try StepFunBrowserSession(cookies: cookies(refresh: refresh(expires: 1_700_000_600)), now: now)
    for session in [cookieBound, grantBound] {
      let restored = try StepFunBrowserSession(serialized: session.encoded())
      XCTAssertFalse(restored.isExpired(at: now))
      XCTAssertTrue(restored.isExpired(at: cookieExpiry))
      let http = StepFunBrowserHTTP(data: try response())
      do {
        _ = try await restored.renewed(httpClient: http, now: cookieExpiry)
        XCTFail("Expected expired login rejection")
      } catch let error as ProviderClientError {
        XCTAssertEqual(error.kind, .auth)
      }
      let requests = await http.requests
      XCTAssertTrue(requests.isEmpty)
    }
  }

  func testRenewalUsesOnlyPassportProtocolAndPrivateCookiePair() async throws {
    let original = try session()
    let nextAccess = try access(expires: 1_700_007_200)
    let nextRefresh = try refresh(expires: 1_700_172_800)
    let http = StepFunBrowserHTTP(data: try response(access: nextAccess, refresh: nextRefresh))
    let renewed = try await original.renewed(httpClient: http, now: now)

    XCTAssertEqual(renewed.accessToken, nextAccess)
    XCTAssertEqual(renewed.subject, original.subject)
    XCTAssertTrue(renewed.secretValues.contains(nextRefresh))
    XCTAssertFalse(renewed.secretValues.contains(try refresh()))
    let requests = await http.requests
    XCTAssertEqual(requests.count, 1)
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.url?.absoluteString, "https://platform.stepfun.ai/passport/proto.api.passport.v1.PassportService/RefreshToken")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.httpBody, Data("{}".utf8))
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), original.cookieHeader)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Oasis-Webid"), "device")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Oasis-Appid"), "20700")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Oasis-Platform"), "web")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Connect-Protocol-Version"), "1")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    XCTAssertFalse(request.httpShouldHandleCookies)
    let policies = await http.policies
    XCTAssertEqual(policies, [.refuse])
  }

  func testRenewalAcceptsSnakeCaseAndRetainsRefreshWhenOmitted() async throws {
    for snakeCase in [false, true] {
      let http = StepFunBrowserHTTP(data: try response(mode: "SIGN_IN", snakeCase: snakeCase))
      let renewed = try await session().renewed(httpClient: http, now: now)
      XCTAssertEqual(renewed.accessToken, try access(expires: 1_700_007_200))
      XCTAssertTrue(renewed.secretValues.contains(try refresh()))
      XCTAssertEqual(renewed.subject, "123")
    }
    do {
      _ = try await session().renewed(httpClient: StepFunBrowserHTTP(data: response(mode: NSNull())), now: now)
      XCTFail("Missing mode must be a transient failure")
    } catch let error as ProviderClientError { XCTAssertEqual(error.kind, .network) }
  }

  func testAnonymousHTTP200RenewalCannotReplaceSignedInSession() async throws {
    for mode: Any in [1, "ANONYMOUS"] {
      let http = StepFunBrowserHTTP(data: try response(access: access(mode: 1), mode: mode))
      do {
        _ = try await session().renewed(httpClient: http, now: now)
        XCTFail("Expected anonymous renewal rejection")
      } catch let error as ProviderClientError {
        XCTAssertEqual(error.kind, .auth)
        XCTAssertFalse(error.message.contains(try access(mode: 1)))
      }
    }
  }

  func testRenewalRejectsChangedSubjectDeviceAndApp() async throws {
    let replacements = try [
      response(access: access(subject: "456"), refresh: refresh(subject: "456")),
      response(refresh: refresh(device: "other-device")),
      response(refresh: refresh(app: 10300)),
      response(access: access(subject: "456"))
    ]
    for body in replacements {
      do {
        _ = try await session().renewed(httpClient: StepFunBrowserHTTP(data: body), now: now)
        XCTFail("Expected identity-bound renewal rejection")
      } catch let error as ProviderClientError {
        XCTAssertEqual(error.kind, .auth)
      }
    }
  }

  func testRenewalFailuresKeepTransportAndResponseDetailsPrivate() async throws {
    let secret = try refresh()
    for status in [200, 302, 401, 429, 500] {
      let http = StepFunBrowserHTTP(data: Data("upstream-body-\(secret)".utf8), status: status)
      do {
        _ = try await session().renewed(httpClient: http, now: now)
        XCTFail("Expected renewal failure")
      } catch let error as ProviderClientError {
        XCTAssertFalse(error.message.contains(secret))
        XCTAssertFalse(error.message.contains("upstream-body"))
      }
    }
    do {
      _ = try await session().renewed(httpClient: StepFunBrowserHTTP(error: URLError(.badServerResponse,
        userInfo: [NSLocalizedDescriptionKey: secret])), now: now)
      XCTFail("Expected transport failure")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .network)
      XCTAssertFalse(error.message.contains(secret))
    }
    for error in [CancellationError() as any Error & Sendable, URLError(.cancelled)] {
      do {
        _ = try await session().renewed(httpClient: StepFunBrowserHTTP(error: error), now: now)
        XCTFail("Expected cancellation")
      } catch is CancellationError { }
      catch { XCTFail("Expected cancellation, got \(error)") }
    }
  }

  func testFailurePolicyRedactsHiddenSessionAndIndividualTokenValues() async throws {
    let original = try session()
    let encoded = try original.encoded()
    let configuration = ProviderRuntimeConfiguration(accountID: "browser-account", provider: .stepFun,
      displayName: "StepFun", isEnabled: true,
      credentials: [CredentialField.stepFunBrowserSession: encoded, CredentialField.stepFunUserID: "verified-uid"])
    for secret in [encoded] + original.secretValues {
      let coordinator = QuotaCoordinator(clients: [StepFunEchoFailure(message: "echoed=\(secret)")])
      let snapshot = await coordinator.refresh(configurations: [configuration], now: now)
      let failure = try XCTUnwrap(snapshot.failures.first)
      XCTAssertFalse(failure.message.contains(secret))
      XCTAssertTrue(failure.message.contains("[redacted]"))
      XCTAssertFalse(String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self).contains(secret))
    }
    let account = ProviderAccount(provider: .stepFun, credentials: try original.credentials(verifiedUserID: "verified-uid"))
    let shared = AppSettings(accounts: [account]).redactedCredentials()
    XCTAssertEqual(shared.accounts.first?.credentials, [:])
    let compound = try XCTUnwrap(original.cookieHeader.components(separatedBy: "; ").first)
      .replacingOccurrences(of: "Oasis-Token=", with: "")
    let manual = ProviderRuntimeConfiguration(provider: .stepFun, isEnabled: true,
      credentials: [CredentialField.stepFunSessionToken: compound])
    for secret in compound.components(separatedBy: "...") {
      let snapshot = await QuotaCoordinator(clients: [StepFunEchoFailure(message: "echoed=\(secret)")])
        .refresh(configurations: [manual], now: now)
      XCTAssertFalse(try XCTUnwrap(snapshot.failures.first).message.contains(secret))
    }
  }

  func testSignInNavigationRejectsForeignInsecureAndSpoofedOrigins() throws {
    XCTAssertEqual(StepFunSignInPolicy.startURL.absoluteString, "https://platform.stepfun.ai/plan-subscribe")
    for url in ["about:blank", "https://platform.stepfun.ai/plan-subscribe", "https://account.stepfun.ai/login",
                "https://accounts.google.com/signin", "https://appleid.apple.com/auth/authorize"] {
      XCTAssertTrue(StepFunSignInPolicy.allowsNavigation(to: try XCTUnwrap(URL(string: url))))
    }
    for url in ["http://platform.stepfun.ai", "https://platform.stepfun.ai.evil.test", "https://evil.test",
                "https://user:password@platform.stepfun.ai", "https://platform.stepfun.ai:8443/login",
                "file:///tmp/login.html", "javascript:alert(1)"] {
      XCTAssertFalse(StepFunSignInPolicy.allowsNavigation(to: try XCTUnwrap(URL(string: url))))
      XCTAssertFalse(StepFunSignInPolicy.allowsSubframeNavigation(to: try XCTUnwrap(URL(string: url))))
    }
    let captcha = try XCTUnwrap(URL(string: "https://ca.turing.captcha.qcloud.com/challenge"))
    XCTAssertTrue(StepFunSignInPolicy.allowsSubframeNavigation(to: captcha))
    XCTAssertFalse(StepFunSignInPolicy.allowsNavigation(to: captcha))
  }
}

private actor StepFunBrowserHTTP: HTTPClient {
  private let payload: Data
  private let status: Int
  private let error: (any Error & Sendable)?
  private(set) var requests: [URLRequest] = []
  private(set) var policies: [HTTPRedirectPolicy] = []

  init(data: Data = Data(), status: Int = 200, error: (any Error & Sendable)? = nil) {
    payload = data
    self.status = status
    self.error = error
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    if let error { throw error }
    return (payload, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }

  func data(for request: URLRequest, redirects: HTTPRedirectPolicy) async throws -> (Data, HTTPURLResponse) {
    policies.append(redirects)
    return try await data(for: request)
  }
}

private struct StepFunEchoFailure: QuotaProviderClient {
  let provider: QuotaProvider = .stepFun
  let message: String
  func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    throw ProviderClientError(kind: .api, message: message)
  }
}
