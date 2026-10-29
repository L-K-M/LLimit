import Foundation
import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class MistralBrowserSessionTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_793_232_000)

  private func cookie(_ name: String = "ory_session_test", _ value: String = "owned-session-fixture",
                      domain: String = ".mistral.ai", path: String = "/", secure: Bool = true,
                      httpOnly: Bool = true, expires: Date? = nil) throws -> HTTPCookie {
    var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
    if secure { properties[.secure] = "TRUE" }
    if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
    if let expires { properties[.expires] = expires }
    return try XCTUnwrap(HTTPCookie(properties: properties))
  }

  private func record(_ name: String = "ory_session_test", value: String = "owned-session-fixture") -> [String: Any] {
    ["name": name, "value": value, "domain": ".mistral.ai", "path": "/", "secure": true, "httpOnly": true]
  }

  private func encoded(_ records: [[String: Any]]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys]), as: UTF8.self)
  }

  func testCapturesOnlyAuthenticationAtAllowedSecureAdminScopes() throws {
    let noise = try [cookie("_ga", "analytics-fixture"), cookie("ory_session_bad", "unrelated-fixture", domain: "example.com"),
      cookie("ory_session_auth", "auth-host-fixture", domain: "auth.mistral.ai"),
      cookie("ory_session_console", "console-host-fixture", domain: "console.mistral.ai")]
    for domain in ["admin.mistral.ai", ".admin.mistral.ai", ".mistral.ai"] {
      let session = try MistralBrowserSession(cookies: [cookie(domain: domain),
        cookie("csrftoken", "csrf-fixture", domain: domain, httpOnly: false)] + noise, now: now)
      let header = session.cookieHeader
      XCTAssertTrue(header.contains("ory_session_test=owned-session-fixture"))
      XCTAssertTrue(header.contains("csrftoken=csrf-fixture"))
      XCTAssertEqual(Set(session.secretValues), ["owned-session-fixture", "csrf-fixture"])
      for excluded in ["analytics-fixture", "unrelated-fixture", "auth-host-fixture", "console-host-fixture"] {
        XCTAssertFalse(try session.encoded().contains(excluded))
      }
    }
  }

  func testRejectsMissingSessionUnsafeScopesAndInsecureAuthentication() throws {
    XCTAssertThrowsError(try MistralBrowserSession(cookies: [], now: now))
    XCTAssertThrowsError(try MistralBrowserSession(cookies: [cookie("csrftoken", "csrf-fixture")], now: now))
    for domain in ["mistral.ai", "admin.mistral.ai.evil.test", "console.mistral.ai", "auth.mistral.ai", "example.com"] {
      XCTAssertThrowsError(try MistralBrowserSession(cookies: [cookie(domain: domain)], now: now))
    }
    XCTAssertThrowsError(try MistralBrowserSession(cookies: [cookie(path: "/subscription")], now: now))
    XCTAssertThrowsError(try MistralBrowserSession(cookies: [cookie(secure: false)], now: now))
    XCTAssertThrowsError(try MistralBrowserSession(cookies: [cookie(httpOnly: false)], now: now))
    XCTAssertThrowsError(try MistralBrowserSession(cookies: [cookie("ory_session_", "fixture")], now: now))
    let legacy = try MistralBrowserSession(cookies: [cookie("ory_kratos_session", "legacy-session-fixture")], now: now)
    XCTAssertEqual(legacy.cookieHeader, "ory_kratos_session=legacy-session-fixture")
  }

  func testAmbiguousCookiesAndHeaderSeparatorsAreRejected() throws {
    XCTAssertThrowsError(try MistralBrowserSession(cookies: [cookie(),
      cookie("ory_session_test", "other-session-fixture", domain: "admin.mistral.ai")], now: now))
    for value in ["bad;separator", "bad,value", "bad value", "bad\\value", "bad\"value", ""] {
      XCTAssertThrowsError(try MistralBrowserSession(cookies: [cookie("ory_session_test", value)], now: now))
    }
  }

  func testRoundTripRetainsExpiryAndRejectsExpiredCapture() throws {
    let expiry = now.addingTimeInterval(3_600)
    let session = try MistralBrowserSession(cookies: [cookie(expires: expiry)], now: now)
    let restored = try MistralBrowserSession(serialized: session.encoded())
    XCTAssertEqual(restored, session)
    XCTAssertEqual(restored.cookieHeader, session.cookieHeader)
    XCTAssertFalse(restored.isExpired(at: now))
    XCTAssertTrue(restored.isExpired(at: expiry))
    XCTAssertThrowsError(try MistralBrowserSession(cookies: [cookie(expires: expiry)], now: expiry))
    let remembered = try MistralBrowserSession(cookies: [cookie()], now: now)
    XCTAssertFalse(remembered.isExpired(at: now.addingTimeInterval(365 * 86_400)))
  }

  func testSerializedSessionCannotWidenCookieScope() throws {
    for change: [String: Any] in [["name": "_ga"], ["name": "ory_session_"], ["domain": "auth.mistral.ai"],
      ["domain": ".evil.test"], ["path": "/subscription"], ["secure": false], ["httpOnly": false],
      ["expires": 0], ["expires": -1], ["value": ""], ["value": "bad;separator"],
      ["value": String(repeating: "x", count: 32_769)]] {
      let changed = record().merging(change) { _, new in new }
      XCTAssertThrowsError(try MistralBrowserSession(serialized: encoded([changed])))
    }
    XCTAssertThrowsError(try MistralBrowserSession(serialized: encoded([record(), record(value: "other-fixture")])))
    XCTAssertThrowsError(try MistralBrowserSession(serialized: encoded([record(), record("_ga")])))
    XCTAssertThrowsError(try MistralBrowserSession(serialized: String(repeating: "x", count: 100_001)))
    let finite = try encoded([record().merging(["expires": 1]) { _, new in new }])
    XCTAssertThrowsError(try MistralBrowserSession(serialized: finite.replacingOccurrences(of: "\"expires\":1", with: "\"expires\":1e999")))
  }

  func testManualCookiesStripAnalyticsAndRejectHeaderInjection() throws {
    let header = "ory_session_test=owned-session-fixture; csrftoken=csrf-fixture; _ga=analytics-fixture"
    let manual = try MistralSessionCookies(header: header)
    XCTAssertTrue(manual.header.contains("ory_session_test=owned-session-fixture"))
    XCTAssertTrue(manual.header.contains("csrftoken=csrf-fixture"))
    XCTAssertFalse(manual.header.contains("analytics-fixture"))
    XCTAssertEqual(Set(manual.secretValues), ["owned-session-fixture", "csrf-fixture"])
    for invalid in ["", " ", "csrftoken=csrf-fixture", "ory_session_=empty-suffix",
      "ory_session_test=first; ory_session_test=second", "ory_session_test=fixture\r\nX-Injected: test",
      "ory_session_test=bad,value", "ory_session_test=bad value", "ory_session_test=bad\\value"] {
      XCTAssertThrowsError(try MistralSessionCookies(header: invalid))
    }
  }

  func testQuotedAuthenticationCookieRetainsItsWireValueAndRedactsUnquotedValue() throws {
    let value = "\"owned-quoted-session-fixture\""
    let browser = try MistralBrowserSession(cookies: [cookie("ory_session_test", value)], now: now)
    XCTAssertEqual(browser.cookieHeader, "ory_session_test=" + value)
    XCTAssertTrue(browser.secretValues.contains("owned-quoted-session-fixture"))
    XCTAssertEqual(try MistralSessionCookies(header: browser.cookieHeader).header, browser.cookieHeader)
  }

  func testCredentialsBindVerifiedIdentityAndSharedSettingsStripEverySecret() throws {
    let browser = try MistralBrowserSession(cookies: [cookie(), cookie("csrftoken", "csrf-fixture", httpOnly: false)], now: now)
    let credentials = try browser.credentials(userID: "verified-user-fixture", organizationID: "verified-org-fixture")
    XCTAssertEqual(credentials[CredentialField.mistralSessionCookies], browser.cookieHeader)
    XCTAssertEqual(credentials[CredentialField.mistralUserID], "verified-user-fixture")
    XCTAssertEqual(credentials[CredentialField.mistralOrganizationID], "verified-org-fixture")
    let saved = try MistralBrowserSession(serialized: XCTUnwrap(credentials[CredentialField.mistralBrowserSession]))
    XCTAssertEqual(saved, browser)
    let settings = AppSettings(accounts: [ProviderAccount(provider: .mistral, credentials: credentials)])
    XCTAssertTrue(settings.redactedCredentials().accounts.allSatisfy { $0.credentials.isEmpty })
  }

  func testCoordinatorRedactsIndividualSavedCookieValues() async throws {
    let browser = try MistralBrowserSession(cookies: [cookie(), cookie("csrftoken", "csrf-fixture", httpOnly: false)], now: now)
    let credentials = try browser.credentials(userID: "verified-user-fixture", organizationID: "verified-org-fixture")
    let config = ProviderRuntimeConfiguration(accountID: "mistral-personal", provider: .mistral,
      displayName: "Mistral", isEnabled: true, credentials: credentials)
    let snapshot = await QuotaCoordinator(clients: [MistralLeakingTestClient()]).refresh(configurations: [config], now: now)
    let failure = try XCTUnwrap(snapshot.failures.first)
    XCTAssertFalse(failure.message.contains("owned-session-fixture"))
    XCTAssertFalse(failure.message.contains("csrf-fixture"))
    XCTAssertTrue(failure.message.contains("[redacted]"))
  }

  func testSubscriptionRedirectReturnsOnlyExactSecureStudioOrigin() throws {
    let startURL = MistralSignInPolicy.startURL
    for raw in ["https://console.mistral.ai/", "https://console.mistral.ai/code",
      "https://console.mistral.ai:443/?from=login", "https://CONSOLE.MISTRAL.AI/"] {
      let url = try XCTUnwrap(URL(string: raw), raw)
      XCTAssertEqual(MistralSignInPolicy.subscriptionRedirect(after: url), startURL, raw)
    }
    for raw in ["https://admin.mistral.ai/subscription",
      "https://auth.mistral.ai/self-service/login/browser",
      "https://v2.auth.mistral.ai/login",
      "https://accounts.google.com/",
      "https://appleid.apple.com/",
      "https://login.microsoftonline.com/",
      "https://login.live.com/",
      "about:blank",
      "http://console.mistral.ai/",
      "https://console.mistral.ai.evil.test/",
      "https://console.mistral.ai@evil.test/",
      "https://user:password@console.mistral.ai/",
      "https://console.mistral.ai:8443/",
      "https://evil.test/",
      "file:///tmp/login.html"] {
      let url = try XCTUnwrap(URL(string: raw), raw)
      XCTAssertNil(MistralSignInPolicy.subscriptionRedirect(after: url), raw)
    }
  }

  #if os(macOS)
  func testApexDomainCookieParsingAndHostOnlyRejection() throws {
    for domain in ["mistral.ai", ".mistral.ai"] {
      let cookies = HTTPCookie.cookies(withResponseHeaderFields: [
        "Set-Cookie": "ory_session_fixture=domain-fixture; Domain=\(domain); Path=/; Secure; HttpOnly"
      ], for: MistralSignInPolicy.startURL)
      XCTAssertEqual(cookies.count, 1)
      XCTAssertEqual(try XCTUnwrap(cookies.first).domain, ".mistral.ai")
      let session = try MistralBrowserSession(cookies: cookies, now: now)
      XCTAssertEqual(session.cookieHeader, "ory_session_fixture=domain-fixture")
    }
    let apexURL = try XCTUnwrap(URL(string: "https://mistral.ai/"))
    let hostOnly = HTTPCookie.cookies(withResponseHeaderFields: [
      "Set-Cookie": "ory_session_fixture=hostonly-fixture; Path=/; Secure; HttpOnly"
    ], for: apexURL)
    XCTAssertEqual(hostOnly.count, 1)
    XCTAssertEqual(try XCTUnwrap(hostOnly.first).domain, "mistral.ai")
    XCTAssertThrowsError(try MistralBrowserSession(cookies: hostOnly, now: now))
  }
  #endif

  func testEncodedSessionRoundTripsLargeSerializedRecordsWithinSizeBound() throws {
    let fixtures = (0..<3).map { record("ory_session_fixture_\($0)", value: String(repeating: "x", count: 20_000)) }
    let input = try encoded(fixtures)
    XCTAssertLessThan(input.utf8.count, 100_000)
    let session = try MistralBrowserSession(serialized: input)
    let serialized = try session.encoded()
    XCTAssertLessThan(serialized.utf8.count, 100_000)
    XCTAssertEqual(try MistralBrowserSession(serialized: serialized), session)
  }

  func testEncodedSessionRejectsSlashEscapingBeyondSizeBound() throws {
    let fixtures = (0..<3).map { record("ory_session_fixture_\($0)", value: String(repeating: "/", count: 20_000)) }
    let data = try JSONSerialization.data(withJSONObject: fixtures, options: [.sortedKeys, .withoutEscapingSlashes])
    XCTAssertLessThan(data.count, 100_000)
    let session = try MistralBrowserSession(serialized: String(decoding: data, as: UTF8.self))
    XCTAssertThrowsError(try session.encoded(), "JSONEncoder slash escaping must not produce an unrestorable saved session")
  }

  func testSignInPolicyAllowsKnownAuthHostsAndBlocksLookalikes() throws {
    for url in ["https://admin.mistral.ai/subscription", "https://auth.mistral.ai/self-service/login/browser",
      "https://v2.auth.mistral.ai/login", "https://accounts.google.com/", "https://appleid.apple.com/",
      "https://login.microsoftonline.com/", "https://login.live.com/"] {
      XCTAssertTrue(MistralSignInPolicy.allowsNavigation(to: try XCTUnwrap(URL(string: url))))
    }
    for url in ["http://admin.mistral.ai/subscription", "https://admin.mistral.ai.evil.test/",
      "https://admin.mistral.ai@evil.test/", "https://user:password@admin.mistral.ai/",
      "https://admin.mistral.ai:8443/", "file:///tmp/login.html", "https://evil.test/"] {
      XCTAssertFalse(MistralSignInPolicy.allowsNavigation(to: try XCTUnwrap(URL(string: url))))
    }
    let captcha = try XCTUnwrap(URL(string: "https://challenges.cloudflare.com/turnstile/"))
    XCTAssertFalse(MistralSignInPolicy.allowsNavigation(to: captcha))
    XCTAssertTrue(MistralSignInPolicy.allowsSubframeNavigation(to: captcha))
  }
}

private struct MistralLeakingTestClient: QuotaProviderClient {
  let provider: QuotaProvider = .mistral
  func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    throw ProviderClientError(kind: .api, message: "Echo owned-session-fixture and csrf-fixture")
  }
}
