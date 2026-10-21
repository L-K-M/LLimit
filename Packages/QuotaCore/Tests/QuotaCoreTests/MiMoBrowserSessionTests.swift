import Foundation
import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class MiMoBrowserSessionTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private func cookie(_ name: String, _ value: String, domain: String = ".account.xiaomi.com",
                      path: String = "/", httpOnly: Bool = true, expires: Date? = nil) throws -> HTTPCookie {
    var properties: [HTTPCookiePropertyKey: Any] = [
      .name: name, .value: value, .domain: domain, .path: path, .secure: "TRUE"
    ]
    if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
    if let expires { properties[.expires] = expires }
    return try XCTUnwrap(HTTPCookie(properties: properties))
  }

  private func pair(userID: String = "42", domain: String = ".account.xiaomi.com",
                    path: String = "/") throws -> [HTTPCookie] {
    try [cookie("passToken", "saved-login-fixture", domain: domain, path: path),
         cookie("userId", userID, domain: domain, path: path)]
  }

  private func record(_ name: String, value: String = "fixture", domain: String = ".account.xiaomi.com") -> [String: Any] {
    ["name": name, "value": value, "domain": domain, "path": "/", "secure": true, "httpOnly": true]
  }

  private func serialized(_ records: [[String: Any]]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: records), as: UTF8.self)
  }

  func testCaptureKeepsOnlyAuthenticationPairAtAllowedRootDomains() throws {
    let noise = try [cookie("_onetrack_cid", "analytics-fixture"), cookie("PassToken", "spoof-fixture"),
      cookie("api-platform_serviceToken", "console-fixture", domain: "platform.xiaomimimo.com"),
      cookie("passToken", "unrelated-fixture", domain: "example.com")]
    for domain in ["account.xiaomi.com", ".account.xiaomi.com"] {
      let session = try MiMoBrowserSession(cookies: pair(domain: domain) + noise, userID: "42", now: now)
      let restored = session.cookies(now: now)
      XCTAssertEqual(Set(restored.map(\.name)), ["passToken", "userId"])
      XCTAssertEqual(restored.first { $0.name == "passToken" }?.value, "saved-login-fixture")
      XCTAssertFalse(try session.encoded().contains("analytics-fixture"))
    }
    for domain in ["platform.xiaomimimo.com", "xiaomi.com", "account.xiaomi.com.evil.test", "id.mi.com"] {
      XCTAssertThrowsError(try MiMoBrowserSession(cookies: pair(domain: domain), userID: "42", now: now))
    }
    XCTAssertThrowsError(try MiMoBrowserSession(cookies: pair(path: "/login"), userID: "42", now: now))
  }

  func testRequiredPairIdentityAndConflictingDuplicates() throws {
    let cookies = try pair()
    for missingPair in [[], Array(cookies.prefix(1)), Array(cookies.suffix(1))] {
      XCTAssertThrowsError(try MiMoBrowserSession(cookies: missingPair, userID: "42", now: now))
    }
    XCTAssertThrowsError(try MiMoBrowserSession(cookies: cookies, userID: "99", now: now))
    XCTAssertThrowsError(try MiMoBrowserSession(cookies: cookies + [cookie("passToken", "conflicting-fixture")], userID: "42", now: now))
    let same = try MiMoBrowserSession(cookies: cookies + [cookie("passToken", "saved-login-fixture", domain: "account.xiaomi.com")], userID: "42", now: now)
    XCTAssertEqual(same.userID, "42")
    let quoted = try MiMoBrowserSession(cookies: pair(userID: "\"42\""), userID: "42", now: now)
    XCTAssertEqual(quoted.userID, "42")
    XCTAssertTrue(quoted.matches(try MiMoSessionCookies(header: "api-platform_serviceToken=console-fixture; userId=42")))
    XCTAssertFalse(quoted.matches(try MiMoSessionCookies(header: "api-platform_serviceToken=console-fixture; userId=99")))
  }

  func testCaptureRejectsUnsafeCookieValue() throws {
    let cookies = try [cookie("passToken", "bad;separator"), cookie("userId", "42")]
    XCTAssertThrowsError(try MiMoBrowserSession(cookies: cookies, userID: "42", now: now))
  }

  func testSerializationRestoresAttributesAndExpiresWholePair() throws {
    let expiry = now.addingTimeInterval(3_600)
    let cookies = try [cookie("passToken", "saved-login-fixture", expires: expiry),
                       cookie("userId", "42", httpOnly: false, expires: expiry.addingTimeInterval(3_600))]
    let original = try MiMoBrowserSession(cookies: cookies, userID: "42", now: now)
    let restored = try MiMoBrowserSession(serialized: original.encoded())
    XCTAssertEqual(restored, original)
    let seeds = restored.cookies(now: now)
    XCTAssertEqual(seeds.count, 2)
    XCTAssertTrue(seeds.allSatisfy(\.isSecure))
    XCTAssertTrue(try XCTUnwrap(seeds.first { $0.name == "passToken" }).isHTTPOnly)
    XCTAssertFalse(try XCTUnwrap(seeds.first { $0.name == "userId" }).isHTTPOnly)
    XCTAssertEqual(try XCTUnwrap(seeds.first { $0.name == "passToken" }?.expiresDate).timeIntervalSince1970, expiry.timeIntervalSince1970, accuracy: 1)
    XCTAssertTrue(restored.cookies(now: expiry).isEmpty)
    XCTAssertThrowsError(try MiMoBrowserSession(cookies: cookies, userID: "42", now: expiry))
    let remembered = try MiMoBrowserSession(cookies: pair(), userID: "42", now: now)
    XCTAssertEqual(try MiMoBrowserSession(serialized: remembered.encoded()).cookies(now: now.addingTimeInterval(10 * 365 * 86_400)).count, 2)
  }

  func testSerializedDecoderRejectsUnsafeOrUnexpectedRecords() throws {
    let valid = [record("passToken"), record("userId", value: "42")]
    for change: [String: Any] in [["name": "analytics"], ["domain": "xiaomi.com"], ["path": "/login"],
      ["secure": false], ["expires": 0], ["expires": -1], ["value": ""], ["value": "\"\""],
      ["value": "bad;separator"], ["value": "bad,value"], ["value": "bad value"],
      ["value": String(repeating: "x", count: 16_385)]] {
      var changed = valid
      changed[0].merge(change) { _, new in new }
      XCTAssertThrowsError(try MiMoBrowserSession(serialized: serialized(changed)))
    }
    XCTAssertThrowsError(try MiMoBrowserSession(serialized: serialized([valid[0]])))
    XCTAssertThrowsError(try MiMoBrowserSession(serialized: serialized(valid + [record("analytics")])))
    XCTAssertThrowsError(try MiMoBrowserSession(serialized: serialized(valid + [record("passToken", value: "different")])))
    let finite = try serialized(valid.map { $0.merging(["expires": 1]) { _, new in new } })
    XCTAssertThrowsError(try MiMoBrowserSession(serialized: finite.replacingOccurrences(of: "\"expires\":1", with: "\"expires\":1e999")))
    XCTAssertThrowsError(try MiMoBrowserSession(serialized: String(repeating: "x", count: 65_537)))
  }

  func testBrowserLoginPreservesPurchaseSettingAndManualLoginRemovesSavedLogin() throws {
    let console = try [cookie("api-platform_serviceToken", "console-fixture", domain: "platform.xiaomimimo.com"),
                       cookie("userId", "42", domain: "platform.xiaomimimo.com")]
    let login = try MiMoBrowserLogin(cookies: console + pair() + [cookie("_onetrack_cid", "analytics-fixture")], now: now)
    let reset = "2026-10-19T20:14:00Z"
    let account = ProviderAccount(provider: .xiaomiMiMo, credentials: [CredentialField.mimoResetAt: reset])
    let credentials = try login.credentials(replacing: account)
    XCTAssertEqual(credentials[CredentialField.mimoResetAt], reset)
    XCTAssertEqual(credentials[CredentialField.mimoSessionCookies], "api-platform_serviceToken=console-fixture; userId=42")
    let saved = try MiMoBrowserSession(serialized: XCTUnwrap(credentials[CredentialField.mimoBrowserSession]))
    XCTAssertEqual(saved.userID, "42")
    XCTAssertFalse(credentials.values.contains { $0.contains("analytics-fixture") })
    let connected = ProviderAccount(provider: .xiaomiMiMo, credentials: credentials)
    let manual = try MiMoBrowserLogin(cookies: console, now: now).credentials(replacing: connected)
    XCTAssertNil(manual[CredentialField.mimoBrowserSession])
    XCTAssertEqual(manual[CredentialField.mimoResetAt], reset)
  }
}
