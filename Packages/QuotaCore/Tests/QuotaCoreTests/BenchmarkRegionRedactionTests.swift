import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import QuotaCore

final class BenchmarkRegionRedactionTests: XCTestCase {
  private let header = "long_cat_region_key=2; owned_session_fixture=long-auth-secret-fixture"
  private let source = "Phase 2 / LongCat 2.5\ncase 2: return 42;\n@@ -20,2 +20,2 @@"

  private func redactor(_ credentials: [String: String], provider: QuotaProvider = .longcat) -> BenchmarkRedactor {
    BenchmarkRedactor(configurations: [ProviderRuntimeConfiguration(provider: provider, isEnabled: true, credentials: credentials)])
  }

  private func browser() throws -> String {
    let cookies = try [("long_cat_region_key", "2"), ("owned_session_fixture", "long-auth-secret-fixture")].map { name, value in
      try XCTUnwrap(HTTPCookie(properties: [.name: name, .value: value, .domain: "longcat.ai", .path: "/",
        .secure: "TRUE", HTTPCookiePropertyKey("HttpOnly"): "TRUE"]))
    }
    return try LongcatBrowserSession(cookies: cookies).encoded()
  }

  func testHeaderRegionDoesNotCorruptCodeAndRanges() {
    let safe = redactor([CredentialField.longcatSessionCookies: header])
    XCTAssertEqual(safe.redact(source), source)
    XCTAssertFalse(safe.redact(header).contains("long-auth-secret-fixture"))
    XCTAssertEqual(safe.redact(header), "[redacted]")
    XCTAssertNotEqual(safe.redact("long_cat_region_key=2"), "long_cat_region_key=2")
  }

  func testBrowserRegionDoesNotCorruptCodeAndRanges() throws {
    let serialized = try browser()
    let safe = redactor([CredentialField.longcatBrowserSession: serialized])
    XCTAssertEqual(safe.redact(source), source)
    XCTAssertEqual(safe.redact(serialized), "[redacted]")
    XCTAssertFalse(safe.redact("owned_session_fixture=long-auth-secret-fixture").contains("long-auth-secret-fixture"))
  }

  func testIndependentShortAuthenticationSecretsRemainProtected() {
    for credentials in [
      [CredentialField.longcatSessionCookies: "long_cat_region_key=2; owned_session_fixture=2"],
      [CredentialField.longcatSessionCookies: header, CredentialField.junieAPIKey: "2"]
    ] {
      let longcat = ProviderRuntimeConfiguration(provider: .longcat, isEnabled: true, credentials: credentials)
      let junie = ProviderRuntimeConfiguration(provider: .junie, isEnabled: true, credentials: credentials)
      let safe = BenchmarkRedactor(configurations: [longcat, junie])
      XCTAssertFalse(safe.redact("case 2: return 42;").contains("2"))
    }
  }

  func testRoutingExceptionIsExactAndTyped() throws {
    for value in ["LONG_CAT_REGION_KEY=2", "unknown_region=2", "long_cat_region_key=3", "long_cat_region_key=2; malformed"] {
      let safe = redactor([CredentialField.longcatSessionCookies: value])
      XCTAssertNotEqual(safe.redact("2 / 3"), "2 / 3")
    }
    let malformed = #"[{"name":"long_cat_region_key","value":"2"}]"#
    let safe = redactor([CredentialField.longcatBrowserSession: malformed])
    XCTAssertNotEqual(safe.redact("Phase 2"), "Phase 2")
  }
}
