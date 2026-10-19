import Foundation
import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class MiMoSessionTests: XCTestCase {

  // MARK: - Header initializer: valid cookies

  func testHeaderInitRequiresServiceTokenAndUserID() throws {
    let session = try MiMoSessionCookies(header: "api-platform_serviceToken=abc123; userId=u-001")
    XCTAssertEqual(session.userID, "u-001")
    XCTAssertTrue(session.header.contains("api-platform_serviceToken=abc123"))
    XCTAssertTrue(session.header.contains("userId=u-001"))
  }

  func testHeaderInitAcceptsAllFourApprovedNames() throws {
    let header = "api-platform_serviceToken=tok; api-platform_slh=slh-val; api-platform_ph=ph-val; userId=u-001"
    let session = try MiMoSessionCookies(header: header)
    XCTAssertEqual(session.userID, "u-001")
    let h = session.header
    XCTAssertTrue(h.contains("api-platform_serviceToken=tok"))
    XCTAssertTrue(h.contains("api-platform_slh=slh-val"))
    XCTAssertTrue(h.contains("api-platform_ph=ph-val"))
    XCTAssertTrue(h.contains("userId=u-001"))
  }

  func testHeaderInitStripsUnknownAnalyticsAndSSOCookies() throws {
    let header = "api-platform_serviceToken=tok; userId=u-001; xiaomi_passport=secret; analytics_id=track123; __guid=123"
    let session = try MiMoSessionCookies(header: header)
    let h = session.header
    XCTAssertTrue(h.contains("api-platform_serviceToken=tok"))
    XCTAssertTrue(h.contains("userId=u-001"))
    XCTAssertFalse(h.contains("xiaomi_passport"))
    XCTAssertFalse(h.contains("analytics_id"))
    XCTAssertFalse(h.contains("__guid"))
  }

  func testHeaderInitPreservesEqualsSignsInValues() throws {
    let header = "api-platform_serviceToken=abc=def=ghi; userId=u-001"
    let session = try MiMoSessionCookies(header: header)
    XCTAssertTrue(session.header.contains("api-platform_serviceToken=abc=def=ghi"))
  }

  func testHeaderInitAcceptsCookiePrefix() throws {
    let session = try MiMoSessionCookies(header: "Cookie: api-platform_serviceToken=tok; userId=u-001")
    XCTAssertEqual(session.userID, "u-001")
  }

  func testHeaderInitTrimsWhitespace() throws {
    let session = try MiMoSessionCookies(header: "  api-platform_serviceToken=tok ; userId=u-001  ")
    XCTAssertEqual(session.userID, "u-001")
  }

  // MARK: - Header initializer: rejections

  func testHeaderInitRejectsDuplicateNames() throws {
    XCTAssertThrowsError(try MiMoSessionCookies(header: "api-platform_serviceToken=tok; api-platform_serviceToken=tok2; userId=u-001"))
  }

  func testHeaderInitRejectsControlCharacters() throws {
    XCTAssertThrowsError(try MiMoSessionCookies(header: "api-platform_serviceToken=to\nk; userId=u-001"))
  }

  func testHeaderInitRejectsInjectionCharactersInValues() throws {
    for bad in ["tok;evil", "tok,comma", "tok\"quote", "tok\\backslash"] {
      XCTAssertThrowsError(try MiMoSessionCookies(header: "api-platform_serviceToken=\(bad); userId=u-001"),
                           "Should reject value: \(bad)")
    }
  }

  func testHeaderInitRejectsBlankValues() throws {
    XCTAssertThrowsError(try MiMoSessionCookies(header: "api-platform_serviceToken=; userId=u-001"))
  }

  func testHeaderInitRejectsMissingServiceToken() throws {
    XCTAssertThrowsError(try MiMoSessionCookies(header: "userId=u-001"))
  }

  func testHeaderInitRejectsMissingUserID() throws {
    XCTAssertThrowsError(try MiMoSessionCookies(header: "api-platform_serviceToken=tok"))
  }

  func testHeaderInitRejectsMissingKeys() throws {
    XCTAssertThrowsError(try MiMoSessionCookies(header: "api-platform_serviceToken=tok; =nakedvalue"))
  }

  func testHeaderInitRejectsOversizedHeaders() throws {
    let huge = String(repeating: "x", count: 65_537)
    XCTAssertThrowsError(try MiMoSessionCookies(header: "api-platform_serviceToken=\(huge); userId=u-001"))
  }

  func testHeaderInitRejectsOversizedValues() throws {
    let huge = String(repeating: "x", count: 16_385)
    XCTAssertThrowsError(try MiMoSessionCookies(header: "api-platform_serviceToken=\(huge); userId=u-001"))
  }

  // MARK: - Header output format

  func testHeaderOutputContainsOnlyApprovedNames() throws {
    let session = try MiMoSessionCookies(header: "api-platform_serviceToken=tok; api-platform_slh=slh; api-platform_ph=ph; userId=u-001")
    let parts = session.header.split(separator: ";")
    for part in parts {
      let name = String(part.split(separator: "=", maxSplits: 1).first!).trimmingCharacters(in: .whitespaces)
      XCTAssertTrue(["api-platform_serviceToken", "api-platform_slh", "api-platform_ph", "userId"].contains(name),
                    "Unexpected cookie name in header: \(name)")
    }
  }

  // MARK: - HTTPCookie initializer

  func testCookieInitExcludesExpiredCookies() throws {
    let past = Date(timeIntervalSince1970: 1_700_000_000)
    var props = [HTTPCookiePropertyKey: Any]()
    props[.name] = "api-platform_serviceToken"
    props[.value] = "tok"
    props[.domain] = ".platform.xiaomimimo.com"
    props[.path] = "/api/v1/tokenPlan"
    props[.secure] = "TRUE"
    props[.expires] = past
    guard let expired = HTTPCookie(properties: props) else { XCTFail("Failed to create cookie"); return }
    XCTAssertEqual(expired.expiresDate, past)

    var props2 = [HTTPCookiePropertyKey: String]()
    props2[.name] = "userId"
    props2[.value] = "u-001"
    props2[.domain] = ".xiaomimimo.com"
    props2[.path] = "/"
    props2[.secure] = "TRUE"
    guard let uid = HTTPCookie(properties: props2) else { XCTFail("Failed to create cookie"); return }

    XCTAssertThrowsError(try MiMoSessionCookies(cookies: [expired, uid]))
  }

  func testCookieInitAcceptsCookiesWithoutSecureFlagForHTTPSConsole() throws {
    var props = [HTTPCookiePropertyKey: String]()
    props[.name] = "api-platform_serviceToken"
    props[.value] = "tok"
    props[.domain] = ".platform.xiaomimimo.com"
    props[.path] = "/api/v1/tokenPlan"
    // No .secure = "TRUE"
    let service = try XCTUnwrap(HTTPCookie(properties: props))
    XCTAssertFalse(service.isSecure)

    var props2 = [HTTPCookiePropertyKey: String]()
    props2[.name] = "userId"
    props2[.value] = "u-001"
    props2[.domain] = ".xiaomimimo.com"
    props2[.path] = "/"
    guard let uid = HTTPCookie(properties: props2) else { XCTFail("Failed to create cookie"); return }
    XCTAssertFalse(uid.isSecure)

    let session = try MiMoSessionCookies(cookies: [service, uid])
    XCTAssertEqual(session.header, "api-platform_serviceToken=tok; userId=u-001")
  }

  func testCookieInitCollapsesIdenticalCookiesAtOverlappingScopes() throws {
    let cookies = try [
      browserCookie("api-platform_serviceToken", "same-fixture", path: "/"),
      browserCookie("api-platform_serviceToken", "same-fixture", path: "/api"),
      browserCookie("userId", "same-user", domain: ".xiaomimimo.com"),
      browserCookie("userId", "same-user"),
    ]
    for order in [cookies, cookies.reversed().map { $0 }] {
      let session = try MiMoSessionCookies(cookies: order)
      XCTAssertEqual(session.header, "api-platform_serviceToken=same-fixture; userId=same-user")
    }
  }

  func testCookieInitRejectsConflictingCookiesWithoutExposingTheirValues() throws {
    let cookies = try [
      browserCookie("api-platform_serviceToken", "first-private-fixture", path: "/"),
      browserCookie("api-platform_serviceToken", "second-private-fixture", path: "/api"),
      browserCookie("userId", "private-user-fixture"),
    ]
    XCTAssertThrowsError(try MiMoSessionCookies(cookies: cookies)) { error in
      let failure = error as? ProviderClientError
      XCTAssertEqual(failure?.kind, .auth)
      XCTAssertTrue(failure?.message.contains("conflicting") == true)
      for cookie in cookies { XCTAssertFalse(failure?.message.contains(cookie.value) == true) }
    }
  }

  func testMissingBrowserSessionGivesReconnectGuidance() throws {
    XCTAssertThrowsError(try MiMoSessionCookies(cookies: [browserCookie("userId", "fixture-user")])) { error in
      let failure = error as? ProviderClientError
      XCTAssertEqual(failure?.kind, .auth)
      XCTAssertTrue(failure?.message.contains("session token") == true)
      XCTAssertFalse(failure?.message.contains("Manual") == true)
    }
    XCTAssertThrowsError(try MiMoSessionCookies(cookies: [browserCookie("api-platform_serviceToken", "fixture-token")])) { error in
      let failure = error as? ProviderClientError
      XCTAssertEqual(failure?.kind, .auth)
      XCTAssertTrue(failure?.message.contains("account ID") == true)
    }
  }

  private func browserCookie(_ name: String, _ value: String,
                             domain: String = ".platform.xiaomimimo.com", path: String = "/") throws -> HTTPCookie {
    try XCTUnwrap(HTTPCookie(properties: [
      .name: name, .value: value, .domain: domain, .path: path, .secure: "TRUE",
    ]))
  }

  func testCookieInitExcludesUnapprovedDomains() throws {
    var props = [HTTPCookiePropertyKey: String]()
    props[.name] = "api-platform_serviceToken"
    props[.value] = "tok"
    props[.domain] = ".evil.com"
    props[.path] = "/api/v1/tokenPlan"
    props[.secure] = "TRUE"
    guard let bad = HTTPCookie(properties: props) else { XCTFail("Failed to create cookie"); return }

    var props2 = [HTTPCookiePropertyKey: String]()
    props2[.name] = "userId"
    props2[.value] = "u-001"
    props2[.domain] = ".xiaomimimo.com"
    props2[.path] = "/"
    props2[.secure] = "TRUE"
    guard let uid = HTTPCookie(properties: props2) else { XCTFail("Failed to create cookie"); return }

    XCTAssertThrowsError(try MiMoSessionCookies(cookies: [bad, uid]))
  }

  func testCookieInitRejectsBadPaths() throws {
    var props = [HTTPCookiePropertyKey: String]()
    props[.name] = "api-platform_serviceToken"
    props[.value] = "tok"
    props[.domain] = ".platform.xiaomimimo.com"
    props[.path] = "/console"
    props[.secure] = "TRUE"
    guard let badPath = HTTPCookie(properties: props) else { XCTFail("Failed to create cookie"); return }

    var props2 = [HTTPCookiePropertyKey: String]()
    props2[.name] = "userId"
    props2[.value] = "u-001"
    props2[.domain] = ".xiaomimimo.com"
    props2[.path] = "/"
    props2[.secure] = "TRUE"
    guard let uid = HTTPCookie(properties: props2) else { XCTFail("Failed to create cookie"); return }

    XCTAssertThrowsError(try MiMoSessionCookies(cookies: [badPath, uid]))
  }

  func testCookieInitAcceptsPlatformServiceCookiesAndParentDomainUserID() throws {
    var props = [HTTPCookiePropertyKey: String]()
    props[.name] = "api-platform_serviceToken"
    props[.value] = "tok"
    props[.domain] = ".platform.xiaomimimo.com"
    props[.path] = "/api/v1/tokenPlan"
    props[.secure] = "TRUE"
    guard let svc = HTTPCookie(properties: props) else { XCTFail("Failed to create cookie"); return }

    var props2 = [HTTPCookiePropertyKey: String]()
    props2[.name] = "userId"
    props2[.value] = "u-001"
    props2[.domain] = ".xiaomimimo.com"
    props2[.path] = "/"
    props2[.secure] = "TRUE"
    guard let uid = HTTPCookie(properties: props2) else { XCTFail("Failed to create cookie"); return }

    let session = try MiMoSessionCookies(cookies: [svc, uid])
    XCTAssertEqual(session.userID, "u-001")
  }

  func testCookiePathMustCoverBothQuotaEndpointsAtASlashBoundary() throws {
    let uid = try XCTUnwrap(HTTPCookie(properties: [
      .name: "userId", .value: "fake-user", .domain: ".xiaomimimo.com",
      .path: "/", .secure: "TRUE",
    ]))
    for path in ["/api/v1/tokenPlan/det", "/api/v1/tokenPlan/detail", "/api/v1/token"] {
      let service = try XCTUnwrap(HTTPCookie(properties: [
        .name: "api-platform_serviceToken", .value: "fake-token",
        .domain: ".platform.xiaomimimo.com", .path: path, .secure: "TRUE",
      ]))
      XCTAssertThrowsError(try MiMoSessionCookies(cookies: [service, uid]), path)
    }
  }

  // MARK: - MiMoSignInPolicy navigation

  func testNavigationAllowsAboutBlank() {
    XCTAssertTrue(MiMoSignInPolicy.allowsNavigation(to: URL(string: "about:blank")!))
  }

  func testNavigationAllowsInlineXiaomiSignInFrame() {
    XCTAssertTrue(MiMoSignInPolicy.allowsNavigation(to: URL(string: "about:srcdoc")!))
    XCTAssertFalse(MiMoSignInPolicy.allowsNavigation(to: URL(string: "about:config")!))
  }

  func testNavigationAllowsExactPlatformHost() {
    XCTAssertTrue(MiMoSignInPolicy.allowsNavigation(to: URL(string: "https://platform.xiaomimimo.com/console/plan-manage")!))
    XCTAssertTrue(MiMoSignInPolicy.allowsNavigation(to: URL(string: "https://platform.xiaomimimo.com/api/v1/tokenPlan/detail")!))
  }

  func testNavigationAllowsXiaomiAccountHosts() {
    XCTAssertTrue(MiMoSignInPolicy.allowsNavigation(to: URL(string: "https://account.xiaomi.com/login")!))
    XCTAssertTrue(MiMoSignInPolicy.allowsNavigation(to: URL(string: "https://id.mi.com/verify")!))
    XCTAssertTrue(MiMoSignInPolicy.allowsNavigation(to: URL(string: "https://login.account.xiaomi.com/oauth")!))
    XCTAssertTrue(MiMoSignInPolicy.allowsNavigation(to: URL(string: "https://sso.id.mi.com/callback")!))
  }

  func testNavigationRejectsLookalikeHosts() {
    XCTAssertFalse(MiMoSignInPolicy.allowsNavigation(to: URL(string: "https://platform.xiaomimimo.com.evil.com/")!))
    XCTAssertFalse(MiMoSignInPolicy.allowsNavigation(to: URL(string: "https://evil-platform.xiaomimimo.com/")!))
    XCTAssertFalse(MiMoSignInPolicy.allowsNavigation(to: URL(string: "https://account.xiaomi.com.evil.com/")!))
    XCTAssertFalse(MiMoSignInPolicy.allowsNavigation(to: URL(string: "https://xiaomimimo.com/")!))
  }

  func testNavigationRejectsNonHTTPSSchemes() {
    XCTAssertFalse(MiMoSignInPolicy.allowsNavigation(to: URL(string: "http://platform.xiaomimimo.com/")!))
    XCTAssertFalse(MiMoSignInPolicy.allowsNavigation(to: URL(string: "ftp://platform.xiaomimimo.com/")!))
  }

  func testNavigationRejectsUserInfo() {
    XCTAssertFalse(MiMoSignInPolicy.allowsNavigation(to: URL(string: "https://user:pass@platform.xiaomimimo.com/")!))
  }

  func testNavigationRejectsNonStandardPorts() {
    XCTAssertFalse(MiMoSignInPolicy.allowsNavigation(to: URL(string: "https://platform.xiaomimimo.com:8443/")!))
  }

  func testNavigationAllowsExplicit443Port() {
    XCTAssertTrue(MiMoSignInPolicy.allowsNavigation(to: URL(string: "https://platform.xiaomimimo.com:443/")!))
  }

  // MARK: - RFC 6265 cookie-value regression tests

  // RFC 6265 section 4.1.1 permits bare or outer-quoted cookie-octets:
  // %x21 / %x23-2B / %x2D-3A / %x3C-5B / %x5D-7E.

  // --- Valid bare characters at range boundaries ---

  func testHeaderInitAcceptsParenthesesInValues() throws {
    let session = try MiMoSessionCookies(header: "api-platform_serviceToken=tok(abc); userId=u-001")
    XCTAssertTrue(session.header.contains("api-platform_serviceToken=tok(abc)"))
  }

  func testHeaderInitAcceptsSquareBracketsInValues() throws {
    let session = try MiMoSessionCookies(header: "api-platform_serviceToken=tok[abc]; userId=u-001")
    XCTAssertTrue(session.header.contains("api-platform_serviceToken=tok[abc]"))
  }

  func testHeaderInitAcceptsCurlyBracesInValues() throws {
    let session = try MiMoSessionCookies(header: "api-platform_serviceToken=tok{abc}; userId=u-001")
    XCTAssertTrue(session.header.contains("api-platform_serviceToken=tok{abc}"))
  }

  func testHeaderInitAcceptsAllRfc6265BoundaryCharacters() throws {
    // %x21 (!), %x23 (#), %x2B (+), %x2D (-), %x2E (.), %x2F (/)
    // %x3A (:), %x3C (<), %x3D (=), %x3E (>), %x3F (?), %x40 (@)
    // %x5B ([), %x5D (]), %x5E (^), %x5F (_), %x60 (`)
    // %x7B ({), %x7C (|), %x7D (}), %x7E (~)
    // Plus parentheses %x28, %x29
    // Excluded by RFC 6265: %x22 (") / %x2C (,) / %x3B (;) / %x5C (\)
    let chars = "!#+-./:<=?@[]^_`{|}~()#"
    let session = try MiMoSessionCookies(header: "api-platform_serviceToken=\(chars); userId=u-001")
    XCTAssertTrue(session.header.contains("api-platform_serviceToken=\(chars)"))
  }

  // --- Outer double-quoted values ---

  func testHeaderInitAcceptsOuterDoubleQuotedValues() throws {
    let session = try MiMoSessionCookies(header: "api-platform_serviceToken=\"tok\"; userId=\"u-001\"")
    XCTAssertTrue(session.header.contains("api-platform_serviceToken=\"tok\""))
    XCTAssertTrue(session.header.contains("userId=\"u-001\""))
  }

  func testHeaderInitPreservesOuterDoubleQuotes() throws {
    let session = try MiMoSessionCookies(header: "api-platform_serviceToken=\"value-with-dashes\"; userId=u-001")
    XCTAssertTrue(session.header.contains("api-platform_serviceToken=\"value-with-dashes\""))
  }

  func testHeaderInitRejectsUnmatchedQuote() throws {
    XCTAssertThrowsError(try MiMoSessionCookies(header: "api-platform_serviceToken=\"tok; userId=u-001"))
  }

  func testHeaderInitRejectsInteriorQuote() throws {
    XCTAssertThrowsError(try MiMoSessionCookies(header: "api-platform_serviceToken=to\"k; userId=u-001"))
  }

  func testHeaderInitRejectsTripleQuotes() throws {
    XCTAssertThrowsError(try MiMoSessionCookies(header: "api-platform_serviceToken=\"\"tok\"; userId=u-001"))
  }

  // --- Empty optional cookies (slh, ph) ---

  func testHeaderInitAcceptsEmptyOptionalSlh() throws {
    let session = try MiMoSessionCookies(header: "api-platform_serviceToken=tok; api-platform_slh=; userId=u-001")
    XCTAssertEqual(session.userID, "u-001")
    XCTAssertTrue(session.header.contains("api-platform_serviceToken=tok"))
    XCTAssertTrue(session.header.contains("userId=u-001"))
  }

  func testHeaderInitAcceptsEmptyOptionalPh() throws {
    let session = try MiMoSessionCookies(header: "api-platform_serviceToken=tok; api-platform_ph=; userId=u-001")
    XCTAssertEqual(session.userID, "u-001")
  }

  func testHeaderInitAcceptsBothEmptyOptionals() throws {
    let session = try MiMoSessionCookies(header: "api-platform_serviceToken=tok; api-platform_slh=; api-platform_ph=; userId=u-001")
    XCTAssertEqual(session.userID, "u-001")
  }

  func testHeaderInitAcceptsQuotedEmptyOptionalSlh() throws {
    let session = try MiMoSessionCookies(header: "api-platform_serviceToken=tok; api-platform_slh=\"\"; userId=u-001")
    XCTAssertEqual(session.userID, "u-001")
  }

  func testHeaderInitAcceptsQuotedEmptyOptionalPh() throws {
    let session = try MiMoSessionCookies(header: "api-platform_serviceToken=tok; api-platform_ph=\"\"; userId=u-001")
    XCTAssertEqual(session.userID, "u-001")
  }

  // --- Required cookies must remain non-empty ---

  func testHeaderInitRejectsQuotedEmptyServiceToken() throws {
    XCTAssertThrowsError(try MiMoSessionCookies(header: "api-platform_serviceToken=\"\"; userId=u-001"))
  }

  func testHeaderInitRejectsQuotedEmptyUserID() throws {
    XCTAssertThrowsError(try MiMoSessionCookies(header: "api-platform_serviceToken=tok; userId=\"\""))
  }

  // --- Rejection: RFC 6265 excluded characters ---

  func testHeaderInitRejectsCommaInValues() throws {
    XCTAssertThrowsError(try MiMoSessionCookies(header: "api-platform_serviceToken=tok,evil; userId=u-001"))
  }

  func testHeaderInitRejectsBackslashInValues() throws {
    XCTAssertThrowsError(try MiMoSessionCookies(header: "api-platform_serviceToken=tok\\evil; userId=u-001"))
  }

  func testHeaderInitRejectsSemicolonInjectionInValues() throws {
    XCTAssertThrowsError(try MiMoSessionCookies(header: "api-platform_serviceToken=tok;evil; userId=u-001"))
  }

  func testHeaderInitRejectsDoubleQuoteInBareValue() throws {
    XCTAssertThrowsError(try MiMoSessionCookies(header: "api-platform_serviceToken=tok\"evil; userId=u-001"))
  }

  // --- Rejection: control characters, DEL, CRLF ---

  func testHeaderInitRejectsControlCharacterTab() throws {
    XCTAssertThrowsError(try MiMoSessionCookies(header: "api-platform_serviceToken=to\tk; userId=u-001"))
  }

  func testHeaderInitRejectsControlCharacterNewline() throws {
    XCTAssertThrowsError(try MiMoSessionCookies(header: "api-platform_serviceToken=to\nk; userId=u-001"))
  }

  func testHeaderInitRejectsCRLFInjection() throws {
    XCTAssertThrowsError(try MiMoSessionCookies(header: "api-platform_serviceToken=tok\r\nX-Injected: evil; userId=u-001"))
  }

  func testHeaderInitRejectsDelCharacter() throws {
    XCTAssertThrowsError(try MiMoSessionCookies(header: "api-platform_serviceToken=\u{7F}; userId=u-001"))
  }

  func testHeaderInitRejectsNullByte() throws {
    XCTAssertThrowsError(try MiMoSessionCookies(header: "api-platform_serviceToken=to\u{00}k; userId=u-001"))
  }

  // --- Rejection: whitespace within values ---

  func testHeaderInitRejectsSpaceWithinValue() throws {
    XCTAssertThrowsError(try MiMoSessionCookies(header: "api-platform_serviceToken=to k; userId=u-001"))
  }

  // --- Rejection: non-ASCII ---

  func testHeaderInitRejectsNonAsciiCharacter() throws {
    XCTAssertThrowsError(try MiMoSessionCookies(header: "api-platform_serviceToken=tok\u{00E9}; userId=u-001"))
  }

  func testHeaderInitRejectsEmojiInValues() throws {
    XCTAssertThrowsError(try MiMoSessionCookies(header: "api-platform_serviceToken=tok😀; userId=u-001"))
  }

  // --- Browser-cookie initializer: empty optional cookies ---

  func testCookieInitAcceptsEmptyOptionalSlh() throws {
    let cookies = try [
      browserCookie("api-platform_serviceToken", "tok"),
      browserCookie("api-platform_slh", ""),
      browserCookie("userId", "u-001"),
    ]
    let session = try MiMoSessionCookies(cookies: cookies)
    XCTAssertEqual(session.userID, "u-001")
  }

  func testCookieInitAcceptsEmptyOptionalPh() throws {
    let cookies = try [
      browserCookie("api-platform_serviceToken", "tok"),
      browserCookie("api-platform_ph", ""),
      browserCookie("userId", "u-001"),
    ]
    let session = try MiMoSessionCookies(cookies: cookies)
    XCTAssertEqual(session.userID, "u-001")
  }

  func testCookieInitAcceptsBothEmptyOptionals() throws {
    let cookies = try [
      browserCookie("api-platform_serviceToken", "tok"),
      browserCookie("api-platform_slh", ""),
      browserCookie("api-platform_ph", ""),
      browserCookie("userId", "u-001"),
    ]
    let session = try MiMoSessionCookies(cookies: cookies)
    XCTAssertEqual(session.userID, "u-001")
  }

  // --- Browser-cookie initializer: quoted and parenthesis values ---

  func testCookieInitAcceptsQuotedValue() throws {
    let cookies = try [
      browserCookie("api-platform_serviceToken", "\"tok\""),
      browserCookie("userId", "\"u-001\""),
    ]
    let session = try MiMoSessionCookies(cookies: cookies)
    XCTAssertTrue(session.header.contains("api-platform_serviceToken=\"tok\""))
    XCTAssertTrue(session.header.contains("userId=\"u-001\""))
  }

  func testCookieInitAcceptsParenthesisValue() throws {
    let cookies = try [
      browserCookie("api-platform_serviceToken", "tok(abc)"),
      browserCookie("userId", "u-001"),
    ]
    let session = try MiMoSessionCookies(cookies: cookies)
    XCTAssertTrue(session.header.contains("api-platform_serviceToken=tok(abc)"))
  }

  func testCookieInitAcceptsQuotedParenthesisValue() throws {
    let cookies = try [
      browserCookie("api-platform_serviceToken", "\"tok(abc)\""),
      browserCookie("userId", "u-001"),
    ]
    let session = try MiMoSessionCookies(cookies: cookies)
    XCTAssertTrue(session.header.contains("api-platform_serviceToken=\"tok(abc)\""))
  }

  func testCookieInitAcceptsSquareBracketValue() throws {
    let cookies = try [
      browserCookie("api-platform_serviceToken", "tok[abc]"),
      browserCookie("userId", "u-001"),
    ]
    let session = try MiMoSessionCookies(cookies: cookies)
    XCTAssertTrue(session.header.contains("api-platform_serviceToken=tok[abc]"))
  }

  func testCookieInitAcceptsCurlyBraceValue() throws {
    let cookies = try [
      browserCookie("api-platform_serviceToken", "tok{abc}"),
      browserCookie("userId", "u-001"),
    ]
    let session = try MiMoSessionCookies(cookies: cookies)
    XCTAssertTrue(session.header.contains("api-platform_serviceToken=tok{abc}"))
  }

  func testEmptyOptionalCookieValuesArePreserved() throws {
    let header = "api-platform_serviceToken=tok; api-platform_slh=; api-platform_ph=\"\"; userId=u-001"
    XCTAssertEqual(try MiMoSessionCookies(header: header).header, header)
    let cookies = try [
      browserCookie("api-platform_serviceToken", "tok"),
      browserCookie("api-platform_slh", ""),
      browserCookie("api-platform_ph", "\"\""),
      browserCookie("userId", "u-001"),
    ]
    XCTAssertEqual(try MiMoSessionCookies(cookies: cookies).header, header)
  }

  func testBrowserValuesCannotBeTruncatedByHeaderSerialization() throws {
    for value in ["tok; ignored=x", "\"tok\"; ignored=x", " tok", "tok "] {
      let token = try browserCookie("api-platform_serviceToken", value)
      XCTAssertEqual(token.value, value)
      let user = try browserCookie("userId", "u-001")
      XCTAssertThrowsError(try MiMoSessionCookies(cookies: [token, user]), "Reject raw browser value before joining a header")
    }
  }
}
