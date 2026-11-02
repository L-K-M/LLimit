import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An explicitly supplied Cookie header, used only for LongCat's fixed HTTPS APIs.
/// Cookie presence is not proof of authentication; the client verifies the account.
public struct LongcatSessionCookies: Sendable {
  public let header: String
  public let secretValues: [String]

  public init(header: String) throws {
    guard !header.isEmpty, header.utf8.count <= 65_536,
          !header.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
      throw longcatReconnect
    }
    var selected: [String: String] = [:]
    for component in header.split(separator: ";", omittingEmptySubsequences: true) {
      let pair = component.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1,
                                                                          omittingEmptySubsequences: false)
      guard pair.count == 2 else { throw longcatReconnect }
      let name = String(pair[0])
      guard Self.validName(name) else { throw longcatReconnect }
      if Self.isAnalytics(name) { continue }
      let value = String(pair[1])
      guard Self.validValue(value), selected[name] == nil else { throw longcatReconnect }
      selected[name] = value
    }
    guard (1...32).contains(selected.count) else { throw longcatReconnect }
    self.header = selected.keys.sorted().map { "\($0)=\(selected[$0]!)" }.joined(separator: "; ")
    secretValues = selected.values.flatMap { [$0, Self.unquoted($0)] }
  }

  public static func credentialsForStorage(_ credentials: [String: String]) throws -> [String: String] {
    var normalized = credentials
    let raw = credentials[CredentialField.longcatSessionCookies] ?? ""
    if !raw.isEmpty { normalized[CredentialField.longcatSessionCookies] = try Self(header: raw).header }
    if let saved = credentials[CredentialField.longcatBrowserSession], !saved.isEmpty {
      let browser = try LongcatBrowserSession(serialized: saved)
      if !raw.isEmpty, normalized[CredentialField.longcatSessionCookies] != browser.cookieHeader { throw longcatReconnect }
      normalized[CredentialField.longcatSessionCookies] = browser.cookieHeader
    }
    return normalized
  }

  static func validName(_ name: String) -> Bool {
    !name.isEmpty && name.utf8.count <= 256 && name.utf8.allSatisfy {
      (33...126).contains($0) && ![34, 40, 41, 44, 47, 58, 59, 60, 61, 62, 63, 64, 91, 92, 93, 123, 125].contains($0)
    }
  }

  static func validValue(_ value: String) -> Bool {
    let content = unquoted(value)
    return !content.isEmpty && value.utf8.count <= 32_768
      && content.utf8.allSatisfy { (33...126).contains($0) && ![34, 44, 59, 92].contains($0) }
  }

  static func unquoted(_ value: String) -> String {
    value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2
      ? String(value.dropFirst().dropLast()) : value
  }

  static func isAnalytics(_ name: String) -> Bool {
    let name = name.lowercased()
    return ["_ga", "_gid", "_gat", "_lxsdk", "_lxsdk_s", "_lxsdk_cuid", "hm_lpvt", "hm_lvt", "hmacct", "hmaccount"]
      .contains { name == $0 || name.hasPrefix($0 + "_") }
  }
}

/// A private WebKit attempt's API-scoped cookies. LongCat's callback owns the
/// authentication-cookie names, so capture is structural: Secure + HttpOnly at
/// the exact API authority. The official site's UUID cookies are optional context.
/// No Passport-host cookies or browser profiles are imported.
public struct LongcatBrowserSession: Sendable, Equatable {
  public static let host = "longcat.chat"
  private static let maximumSerializedBytes = 100_000
  private struct Cookie: Codable, Sendable, Equatable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let secure: Bool
    let httpOnly: Bool
    let expires: Double?
  }
  private let records: [Cookie]
  public var cookieHeader: String { records.map { "\($0.name)=\($0.value)" }.joined(separator: "; ") }
  public var secretValues: [String] { records.flatMap { [$0.value, LongcatSessionCookies.unquoted($0.value)] } }

  public init(cookies: [HTTPCookie], now: Date = Date()) throws {
    let selected = cookies.filter {
      Self.allowed(name: $0.name, domain: $0.domain, path: $0.path)
        && (Self.isContext($0.name) || ($0.isSecure && $0.isHTTPOnly))
        && ($0.expiresDate.map { $0 > now } ?? true)
    }.map {
      // The official site's JS may set UUID context without Secure. Every
      // saved cookie is nevertheless restricted to LLimit's fixed HTTPS requests.
      Cookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path,
             secure: true, httpOnly: $0.isHTTPOnly, expires: $0.expiresDate?.timeIntervalSince1970)
    }
    records = try Self.validated(selected)
  }

  public init(serialized: String) throws {
    guard serialized.utf8.count <= Self.maximumSerializedBytes, let data = serialized.data(using: .utf8),
          let cookies = try? JSONDecoder().decode([Cookie].self, from: data) else { throw longcatReconnect }
    records = try Self.validated(cookies)
  }

  public func encoded() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(records)
    guard data.count <= Self.maximumSerializedBytes else { throw longcatReconnect }
    return String(decoding: data, as: UTF8.self)
  }

  public func isExpired(at now: Date = Date()) -> Bool {
    records.contains { $0.expires.map { $0 <= now.timeIntervalSince1970 } ?? false }
  }

  public func credentials(userID: String) throws -> [String: String] {
    guard !userID.isEmpty, userID.utf8.count <= 256,
          userID.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
      throw longcatReconnect
    }
    return [CredentialField.longcatSessionCookies: cookieHeader, CredentialField.longcatBrowserSession: try encoded(),
            CredentialField.longcatUserID: userID]
  }

  private static func isContext(_ name: String) -> Bool { ["uuid", "passport_uuid"].contains(name) }

  private static func allowed(name: String, domain: String, path: String) -> Bool {
    // A single header is sent to /api/v1 and /api/pay. More specific paths
    // cannot be widened to both endpoints. Subdomains have a separate authority.
    LongcatSessionCookies.validName(name) && !LongcatSessionCookies.isAnalytics(name)
      && [host, "." + host].contains(domain.lowercased()) && ["/", "/api", "/api/"].contains(path)
  }

  private static func validated(_ cookies: [Cookie]) throws -> [Cookie] {
    guard (1...32).contains(cookies.count), Set(cookies.map(\.name)).count == cookies.count,
          cookies.contains(where: { !isContext($0.name) && $0.httpOnly }),
          cookies.allSatisfy({ allowed(name: $0.name, domain: $0.domain, path: $0.path)
            && $0.secure && (isContext($0.name) || $0.httpOnly)
            && LongcatSessionCookies.validValue($0.value)
            && ($0.expires.map { $0.isFinite && $0 > 0 } ?? true) }) else { throw longcatReconnect }
    return cookies.sorted { $0.name < $1.name }
  }
}

public enum LongcatSignInPolicy {
  public static let startURL = URL(string: "https://longcat.chat/platform/usage")!

  public static func allowsNavigation(to url: URL) -> Bool {
    if url.absoluteString == "about:blank" { return true }
    // Passport's official production Yoda host also serves secondary verification
    // as a top-level /v2/web/general_page flow (its common.js + yoda.seed.js).
    return isSecureOrigin(url) && ["longcat.chat", "passport.meituan.com", "passport.mykeeta.com",
      "verify.meituan.com", "accounts.google.com", "www.facebook.com"].contains(url.host?.lowercased() ?? "")
  }

  public static func allowsSubframeNavigation(to url: URL) -> Bool {
    if allowsNavigation(to: url) || url.absoluteString == "about:srcdoc" { return true }
    // The official Passport overseas page loads Yoda's production challenge here.
    return isSecureOrigin(url) && url.host?.lowercased() == "verify.mykeeta.com"
  }

  private static func isSecureOrigin(_ url: URL) -> Bool {
    url.scheme == "https" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
  }
}

let longcatReconnect = ProviderClientError(kind: .auth,
  message: "LongCat needs you to sign in again. Connect LongCat or replace the platform session cookies.")
