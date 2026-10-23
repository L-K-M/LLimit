import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Only Xiaomi Account's saved-login pair, never a browser profile or analytics.
/// Stored in owner-only local settings; it is never sent to the quota API.
public struct MiMoBrowserSession: Sendable, Equatable {
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
  public var userID: String { Self.unquoted(records.first { $0.name == "userId" }!.value) }
  var secretValues: [String] { records.flatMap { [$0.value, Self.unquoted($0.value)] } }

  public init(cookies: [HTTPCookie], userID: String, now: Date = Date()) throws {
    let selected = cookies.filter {
      Self.allowed(name: $0.name, domain: $0.domain, path: $0.path)
        && ($0.expiresDate.map { $0 > now } ?? true)
    }.map {
      Cookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path,
             secure: true, httpOnly: $0.isHTTPOnly, expires: $0.expiresDate?.timeIntervalSince1970)
    }
    records = try Self.validated(selected)
    guard self.userID == Self.unquoted(userID) else { throw Self.invalid }
  }

  public init(serialized: String) throws {
    guard serialized.utf8.count <= 65_536, let data = serialized.data(using: .utf8),
          let decoded = try? JSONDecoder().decode([Cookie].self, from: data) else { throw Self.invalid }
    records = try Self.validated(decoded)
  }

  public func encoded() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(records), as: UTF8.self)
  }

  /// Session cookies remain saved between LLimit launches, just as a remembered
  /// browser login does. A server-supplied expiry still takes precedence.
  public func cookies(now: Date = Date()) -> [HTTPCookie] {
    guard records.allSatisfy({ $0.expires.map { $0 > now.timeIntervalSince1970 } ?? true }) else { return [] }
    return records.compactMap { record in
      var properties: [HTTPCookiePropertyKey: Any] = [
        .name: record.name, .value: record.value, .domain: record.domain,
        .path: record.path, .secure: "TRUE"
      ]
      if record.httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
      if let expires = record.expires { properties[.expires] = Date(timeIntervalSince1970: expires) }
      return HTTPCookie(properties: properties)
    }
  }

  public func matches(_ session: MiMoSessionCookies) -> Bool { userID == Self.unquoted(session.userID) }

  private static func validated(_ cookies: [Cookie]) throws -> [Cookie] {
    guard (2...8).contains(cookies.count) else { throw invalid }
    var values: [String: String] = [:]
    var result: [Cookie] = []
    for cookie in cookies {
      guard allowed(name: cookie.name, domain: cookie.domain, path: cookie.path), cookie.secure,
            cookie.expires.map({ $0.isFinite && $0 > 0 }) ?? true,
            MiMoSessionCookies.isValidCookieValue(cookie.value, for: cookie.name),
            !unquoted(cookie.value).isEmpty else { throw invalid }
      if let previous = values[cookie.name], previous != cookie.value { throw invalid }
      values[cookie.name] = cookie.value
      if !result.contains(cookie) { result.append(cookie) }
    }
    guard values["passToken"] != nil, values["userId"] != nil else { throw invalid }
    return result.sorted { ($0.name, $0.domain) < ($1.name, $1.domain) }
  }

  private static func allowed(name: String, domain: String, path: String) -> Bool {
    ["passToken", "userId"].contains(name)
      && ["account.xiaomi.com", ".account.xiaomi.com"].contains(domain.lowercased()) && path == "/"
  }

  private static func unquoted(_ value: String) -> String {
    value.hasPrefix("\"") && value.hasSuffix("\"") ? String(value.dropFirst().dropLast()) : value
  }

  private static var invalid: ProviderClientError {
    ProviderClientError(kind: .auth, message: "The saved Xiaomi login cannot renew this MiMo account. Connect MiMo to sign in again.")
  }
}

public struct MiMoBrowserLogin: Sendable {
  public let console: MiMoSessionCookies
  public let browser: MiMoBrowserSession?

  public init(cookies: [HTTPCookie], now: Date = Date()) throws {
    console = try MiMoSessionCookies(cookies: cookies, now: now)
    browser = try? MiMoBrowserSession(cookies: cookies, userID: console.userID, now: now)
  }

  public func credentials(replacing account: ProviderAccount) throws -> [String: String] {
    var credentials = account.credentialsForImport([CredentialField.mimoSessionCookies: console.header])
    credentials[CredentialField.mimoBrowserSession] = try browser?.encoded()
    return credentials
  }
}
