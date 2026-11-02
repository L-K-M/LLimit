import Foundation
import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class LongcatBrowserSessionTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_793_232_000)

  func testInternationalLoginDoesNotNavigateToChineseConsole() throws {
    XCTAssertEqual(LongcatSignInPolicy.startURL.absoluteString, "https://longcat.ai/platform/usage")
    XCTAssertTrue(LongcatSignInPolicy.allowsNavigation(to: try XCTUnwrap(URL(string: "https://longcat.ai/platform/usage"))))
    for raw in ["https://longcat.chat/platform/usage", "https://passport.meituan.com/useraccount/login"] {
      XCTAssertFalse(LongcatSignInPolicy.allowsNavigation(to: try XCTUnwrap(URL(string: raw))))
    }
  }

  private func cookie(_ name: String = "owned_session_fixture", _ value: String = "owned-secret-fixture",
                      domain: String = "longcat.ai", path: String = "/", secure: Bool = true,
                      httpOnly: Bool = true, expires: Date? = nil) throws -> HTTPCookie {
    var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
    if secure { properties[.secure] = "TRUE" }
    if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
    if let expires { properties[.expires] = expires }
    return try XCTUnwrap(HTTPCookie(properties: properties))
  }

  private func record(_ name: String = "owned_session_fixture", value: String = "owned-secret-fixture") -> [String: Any] {
    ["name": name, "value": value, "domain": "longcat.ai", "path": "/", "secure": true, "httpOnly": true]
  }

  private func encoded(_ records: [[String: Any]]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys]), as: UTF8.self)
  }

  func testCaptureKeepsOnlySecureHTTPOnlyLongcatAPICookiesAndOfficialContext() throws {
    let noise = try [cookie("_ga", "analytics-fixture"), cookie("_lxsdk_s", "analytics-session-fixture"),
      cookie("sso", "passport-secret-fixture", domain: "passport.meituan.com"),
      cookie("sso", "overseas-secret-fixture", domain: "passport.mykeeta.com"),
      cookie("china_session", "china-secret-fixture", domain: ".longcat.chat"),
      cookie("unrelated", "other-secret-fixture", domain: "www.longcat.ai"),
      cookie("preference", "theme-fixture", httpOnly: false),
      cookie("insecure", "insecure-secret-fixture", secure: false),
      cookie("endpoint_only", "narrow-secret-fixture", path: "/api/v1")]
    for domain in ["longcat.ai", ".longcat.ai"] {
      for path in ["/", "/api", "/api/"] {
        let browser = try LongcatBrowserSession(cookies: [cookie(domain: domain, path: path),
          cookie("passport_uuid", "browser-id-fixture", domain: domain, path: path, secure: false, httpOnly: false)] + noise, now: now)
        XCTAssertEqual(browser.cookieHeader, "owned_session_fixture=owned-secret-fixture; passport_uuid=browser-id-fixture")
        XCTAssertEqual(Set(browser.secretValues), ["owned-secret-fixture", "browser-id-fixture"])
        let serialized = try browser.encoded()
        for value in ["analytics-fixture", "analytics-session-fixture", "passport-secret-fixture", "overseas-secret-fixture",
          "other-secret-fixture", "theme-fixture", "insecure-secret-fixture", "narrow-secret-fixture", "china-secret-fixture"] {
          XCTAssertFalse(serialized.contains(value))
        }
        XCTAssertTrue(serialized.contains("\"secure\":true"))
      }
    }
  }

  func testCaptureRequiresSessionCandidateAndRejectsAmbiguousHeaderScopes() throws {
    XCTAssertThrowsError(try LongcatBrowserSession(cookies: [], now: now))
    XCTAssertThrowsError(try LongcatBrowserSession(cookies: [cookie("uuid", "context-only-fixture", httpOnly: false)], now: now))
    XCTAssertThrowsError(try LongcatBrowserSession(cookies: [cookie(httpOnly: false)], now: now))
    XCTAssertThrowsError(try LongcatBrowserSession(cookies: [cookie(secure: false)], now: now))
    XCTAssertThrowsError(try LongcatBrowserSession(cookies: [cookie("_ga", "analytics-only-fixture")], now: now))
    for domain in ["longcat.ai.evil.test", ".ai", "www.longcat.ai", "api.longcat.ai", "passport.mykeeta.com",
      "longcat.chat", ".longcat.chat"] {
      XCTAssertThrowsError(try LongcatBrowserSession(cookies: [cookie(domain: domain)], now: now), domain)
    }
    for path in ["/platform", "/api/v1", "/api/pay", "/ap", "/api-other"] {
      XCTAssertThrowsError(try LongcatBrowserSession(cookies: [cookie(path: path)], now: now), path)
    }
    XCTAssertThrowsError(try LongcatBrowserSession(cookies: [cookie(),
      cookie("owned_session_fixture", "second-secret-fixture", domain: ".longcat.ai")], now: now))
    XCTAssertThrowsError(try LongcatBrowserSession(cookies: [cookie(),
      cookie("owned_session_fixture", "second-secret-fixture", path: "/api")], now: now))
  }

  func testManualHeaderValidatesGenericNamesPreservesWireValuesAndStripsAnalytics() throws {
    let supplied = "another-auth=second-fixture; _ga=analytics-fixture; owned_session_fixture=\"quoted-secret-fixture\"; uuid=id-fixture; _lxsdk_s=tracker-fixture"
    let manual = try LongcatSessionCookies(header: supplied)
    XCTAssertEqual(manual.header, "another-auth=second-fixture; owned_session_fixture=\"quoted-secret-fixture\"; uuid=id-fixture")
    XCTAssertEqual(Set(manual.secretValues), ["second-fixture", "\"quoted-secret-fixture\"", "quoted-secret-fixture", "id-fixture"])
    for invalid in ["", " ", "_ga=only-analytics", "broken", "=empty-name", "bad name=value", "bad/name=value",
      "owned_session_fixture=first; owned_session_fixture=second", "session=bad,value", "session=bad value",
      "session=bad\\value", "session=bad\"value", "session=", "session=fixture\r\nX-Injected: yes"] {
      XCTAssertThrowsError(try LongcatSessionCookies(header: invalid), invalid)
    }
    XCTAssertThrowsError(try LongcatSessionCookies(header: "session=" + String(repeating: "x", count: 32_769)))
    XCTAssertThrowsError(try LongcatSessionCookies(header: String(repeating: "x", count: 65_537)))
  }

  func testBrowserSessionRetainsExpiryAndRejectsExpiredCapture() throws {
    let expiry = now.addingTimeInterval(3_600)
    let browser = try LongcatBrowserSession(cookies: [cookie(expires: expiry)], now: now)
    let restored = try LongcatBrowserSession(serialized: browser.encoded())
    XCTAssertEqual(restored, browser)
    XCTAssertFalse(restored.isExpired(at: now))
    XCTAssertTrue(restored.isExpired(at: expiry))
    XCTAssertThrowsError(try LongcatBrowserSession(cookies: [cookie(expires: expiry)], now: expiry))
    let transient = try LongcatBrowserSession(cookies: [cookie()], now: now)
    XCTAssertFalse(transient.isExpired(at: now.addingTimeInterval(365 * 86_400)))
  }

  func testSerializedSessionCannotWidenScopeOrDropAuthenticationProperties() throws {
    for change: [String: Any] in [["name": "_ga"], ["name": "bad name"], ["domain": ".evil.test"],
      ["domain": "passport.meituan.com"], ["path": "/platform"], ["path": "/api/v1"],
      ["secure": false], ["httpOnly": false], ["expires": 0], ["expires": -1],
      ["value": ""], ["value": "bad;separator"], ["value": "bad,value"],
      ["value": String(repeating: "x", count: 32_769)]] {
      let changed = record().merging(change) { _, new in new }
      XCTAssertThrowsError(try LongcatBrowserSession(serialized: encoded([changed])))
    }
    XCTAssertThrowsError(try LongcatBrowserSession(serialized: encoded([record("uuid")])))
    XCTAssertThrowsError(try LongcatBrowserSession(serialized: encoded([record(), record(value: "duplicate-fixture")])))
    XCTAssertThrowsError(try LongcatBrowserSession(serialized: encoded([record(), record("_gid")])))
    XCTAssertThrowsError(try LongcatBrowserSession(serialized: "[]"))
    XCTAssertThrowsError(try LongcatBrowserSession(serialized: String(repeating: "x", count: 100_001)))
    let finite = try encoded([record().merging(["expires": 1]) { _, new in new }])
    XCTAssertThrowsError(try LongcatBrowserSession(serialized: finite.replacingOccurrences(of: "\"expires\":1", with: "\"expires\":1e999")))
  }

  func testCredentialsNormalizeManualHeaderRequireBrowserAgreementAndRedactSettings() throws {
    let browser = try LongcatBrowserSession(cookies: [cookie(), cookie("uuid", "context-fixture", httpOnly: false)], now: now)
    let credentials = try browser.credentials(userID: "verified-user-fixture")
    XCTAssertEqual(credentials[CredentialField.longcatSessionCookies], browser.cookieHeader)
    XCTAssertEqual(credentials[CredentialField.longcatUserID], "verified-user-fixture")
    XCTAssertEqual(credentials[CredentialField.longcatSessionOrigin], "https://longcat.ai")
    XCTAssertEqual(try LongcatBrowserSession(serialized: XCTUnwrap(credentials[CredentialField.longcatBrowserSession])), browser)
    XCTAssertEqual(try LongcatSessionCookies.credentialsForStorage(credentials), credentials)
    XCTAssertEqual(try LongcatSessionCookies.credentialsForStorage([CredentialField.longcatSessionCookies: ""]),
      [CredentialField.longcatSessionCookies: ""])
    XCTAssertEqual(try LongcatSessionCookies.credentialsForStorage([CredentialField.longcatSessionCookies: "session=fixture; _ga=tracker"]),
      [CredentialField.longcatSessionCookies: "session=fixture"])
    XCTAssertThrowsError(try LongcatSessionCookies.credentialsForStorage(credentials.merging(
      [CredentialField.longcatSessionCookies: "other_session=different-fixture"]) { _, new in new }))
    XCTAssertThrowsError(try browser.credentials(userID: ""))
    XCTAssertThrowsError(try browser.credentials(userID: "bad\nidentity"))
    let legacy = try LongcatSessionCookies.credentialsForStorage([
      CredentialField.longcatSessionCookies: "session=legacy-fixture", CredentialField.longcatUserID: "123"])
    XCTAssertNil(legacy[CredentialField.longcatSessionOrigin], "Normalization cannot authorize forwarding an old raw header")
    XCTAssertThrowsError(try LongcatSessionCookies.credentialsForStorage([
      CredentialField.longcatSessionCookies: "session=legacy-fixture", CredentialField.longcatSessionOrigin: "https://longcat.chat"]))
    let settings = AppSettings(accounts: [ProviderAccount(provider: .longcat, credentials: credentials)])
    let shared = String(decoding: try JSONEncoder().encode(settings.redactedCredentials()), as: UTF8.self)
    for secret in browser.secretValues { XCTAssertFalse(shared.contains(secret)) }
  }

  func testSignInPolicyLimitsMainFramesToKnownHTTPSAuthorities() throws {
    XCTAssertEqual(LongcatSignInPolicy.startURL.absoluteString, "https://longcat.ai/platform/usage")
    for raw in ["https://longcat.ai/platform/usage",
      "https://passport.mykeeta.com/pc/login", "https://accounts.google.com/", "https://www.facebook.com/",
      "https://LONGCAT.AI:443/platform/usage", "about:blank"] {
      XCTAssertTrue(LongcatSignInPolicy.allowsNavigation(to: try XCTUnwrap(URL(string: raw))), raw)
    }
    for raw in ["http://longcat.ai/", "https://longcat.ai.evil.test/", "https://longcat.ai@evil.test/",
      "https://user:password@longcat.ai/", "https://longcat.ai:8443/", "https://evil.test/",
      "https://passport.mykeeta.com.evil.test/", "file:///tmp/login.html", "javascript:alert(1)",
      "https://verify.meituan.com.evil.test/", "https://verify.meituan.net/", "http://verify.meituan.com/",
      "https://www.longcat.ai/", "https://longcat.chat/platform/usage",
      "https://passport.meituan.com/useraccount/login"] {
      XCTAssertFalse(LongcatSignInPolicy.allowsNavigation(to: try XCTUnwrap(URL(string: raw))), raw)
      XCTAssertFalse(LongcatSignInPolicy.allowsSubframeNavigation(to: try XCTUnwrap(URL(string: raw))), raw)
    }
    let srcdoc = try XCTUnwrap(URL(string: "about:srcdoc"))
    XCTAssertFalse(LongcatSignInPolicy.allowsNavigation(to: srcdoc))
    XCTAssertTrue(LongcatSignInPolicy.allowsSubframeNavigation(to: srcdoc))
    let challenge = try XCTUnwrap(URL(string: "https://verify.mykeeta.com/challenge"))
    XCTAssertFalse(LongcatSignInPolicy.allowsNavigation(to: challenge))
    XCTAssertTrue(LongcatSignInPolicy.allowsSubframeNavigation(to: challenge))
    let domesticChallenge = try XCTUnwrap(URL(string: "https://verify.meituan.com/challenge"))
    XCTAssertFalse(LongcatSignInPolicy.allowsNavigation(to: domesticChallenge))
    XCTAssertFalse(LongcatSignInPolicy.allowsSubframeNavigation(to: domesticChallenge))
  }
}
