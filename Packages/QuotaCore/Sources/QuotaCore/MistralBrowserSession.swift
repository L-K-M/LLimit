import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Authentication owned by LLimit, sent only to the fixed Admin subscription page.
public struct MistralSessionCookies: Sendable {
  public let header: String
  public let secretValues: [String]

  public init(header: String) throws {
    guard !header.isEmpty, header.utf8.count <= 65_536,
          !header.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
      throw mistralReconnect
    }
    var selected: [String: String] = [:]
    for component in header.split(separator: ";", omittingEmptySubsequences: true) {
      let pair = component.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1,
                                                                          omittingEmptySubsequences: false)
      guard pair.count == 2 else { throw mistralReconnect }
      let name = String(pair[0])
      guard Self.allowedName(name) else { continue }
      let value = String(pair[1])
      guard Self.validValue(value), selected[name] == nil else { throw mistralReconnect }
      selected[name] = value
    }
    guard selected.keys.contains(where: Self.isSessionName), selected.count <= 8 else { throw mistralReconnect }
    self.header = selected.keys.sorted().map { "\($0)=\(selected[$0]!)" }.joined(separator: "; ")
    secretValues = selected.values.flatMap { [$0, Self.unquoted($0)] }
  }

  public static func credentialsForStorage(_ credentials: [String: String]) throws -> [String: String] {
    var normalized = credentials
    let raw = credentials[CredentialField.mistralSessionCookies] ?? ""
    if !raw.isEmpty { normalized[CredentialField.mistralSessionCookies] = try Self(header: raw).header }
    if let saved = credentials[CredentialField.mistralBrowserSession], !saved.isEmpty {
      let browser = try MistralBrowserSession(serialized: saved)
      if !raw.isEmpty, normalized[CredentialField.mistralSessionCookies] != browser.cookieHeader { throw mistralReconnect }
      normalized[CredentialField.mistralSessionCookies] = browser.cookieHeader
    }
    return normalized
  }

  static func isSessionName(_ name: String) -> Bool {
    if name == "ory_kratos_session" { return true }
    guard name.hasPrefix("ory_session_"), name.count > "ory_session_".count, name.utf8.count <= 128 else { return false }
    return name.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0)
      || (48...57).contains($0) || $0 == 45 || $0 == 95 }
  }

  static func allowedName(_ name: String) -> Bool { isSessionName(name) || name == "csrftoken" }
  static func validValue(_ value: String) -> Bool {
    let content = unquoted(value)
    return !content.isEmpty && value.utf8.count <= 32_768
      && content.utf8.allSatisfy { (33...126).contains($0) && ![34, 44, 59, 92].contains($0) }
  }
  static func unquoted(_ value: String) -> String {
    value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2
      ? String(value.dropFirst().dropLast()) : value
  }
}

public struct MistralBrowserSession: Sendable, Equatable {
  public static let adminHost = "admin.mistral.ai"
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
  public var secretValues: [String] { records.flatMap { [$0.value, MistralSessionCookies.unquoted($0.value)] } }

  public init(cookies: [HTTPCookie], now: Date = Date()) throws {
    let selected = cookies.filter {
      Self.allowed(name: $0.name, domain: $0.domain, path: $0.path)
        && $0.isSecure && (!MistralSessionCookies.isSessionName($0.name) || $0.isHTTPOnly)
        && ($0.expiresDate.map { $0 > now } ?? true)
    }.map {
      Cookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path,
             secure: $0.isSecure, httpOnly: $0.isHTTPOnly, expires: $0.expiresDate?.timeIntervalSince1970)
    }
    records = try Self.validated(selected)
  }

  public init(serialized: String) throws {
    guard serialized.utf8.count <= 100_000, let data = serialized.data(using: .utf8),
          let cookies = try? JSONDecoder().decode([Cookie].self, from: data) else { throw mistralReconnect }
    records = try Self.validated(cookies)
  }

  public func encoded() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(records), as: UTF8.self)
  }

  public func isExpired(at now: Date = Date()) -> Bool {
    records.contains { $0.expires.map { $0 <= now.timeIntervalSince1970 } ?? false }
  }

  public func credentials(userID: String, organizationID: String) throws -> [String: String] {
    [CredentialField.mistralSessionCookies: cookieHeader, CredentialField.mistralBrowserSession: try encoded(),
     CredentialField.mistralUserID: userID, CredentialField.mistralOrganizationID: organizationID]
  }

  private static func allowed(name: String, domain: String, path: String) -> Bool {
    MistralSessionCookies.allowedName(name) && path == "/"
      && [adminHost, "." + adminHost, ".mistral.ai"].contains(domain.lowercased())
  }

  private static func validated(_ cookies: [Cookie]) throws -> [Cookie] {
    guard (1...8).contains(cookies.count), Set(cookies.map(\.name)).count == cookies.count,
          cookies.contains(where: { MistralSessionCookies.isSessionName($0.name) }),
          cookies.allSatisfy({ allowed(name: $0.name, domain: $0.domain, path: $0.path)
            && $0.secure && (!MistralSessionCookies.isSessionName($0.name) || $0.httpOnly)
            && MistralSessionCookies.validValue($0.value)
            && ($0.expires.map { $0.isFinite && $0 > 0 } ?? true) }) else { throw mistralReconnect }
    return cookies.sorted { $0.name < $1.name }
  }
}

public enum MistralSignInPolicy {
  public static let startURL = URL(string: "https://admin.mistral.ai/subscription")!
  public static func allowsNavigation(to url: URL) -> Bool {
    if url.absoluteString == "about:blank" { return true }
    return url.scheme == "https" && url.user == nil && url.password == nil
      && (url.port == nil || url.port == 443)
      && ["admin.mistral.ai", "console.mistral.ai", "auth.mistral.ai", "v2.auth.mistral.ai",
          "accounts.google.com", "appleid.apple.com", "login.microsoftonline.com", "login.live.com"]
        .contains(url.host?.lowercased() ?? "")
  }

  public static func allowsSubframeNavigation(to url: URL) -> Bool {
    if allowsNavigation(to: url) || url.absoluteString == "about:srcdoc" { return true }
    return url.scheme == "https" && url.user == nil && url.password == nil
      && (url.port == nil || url.port == 443)
      && ["challenges.cloudflare.com", "www.google.com", "www.recaptcha.net"]
        .contains(url.host?.lowercased() ?? "")
  }
}

let mistralReconnect = ProviderClientError(kind: .auth,
  message: "Mistral needs you to sign in again. Connect Mistral or replace the Admin session cookies.")
