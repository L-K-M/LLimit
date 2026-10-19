import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// LLimit-owned console credentials. Inference keys returned by MiMo Code do
/// not provide this web session. Never collect Xiaomi SSO or analytics cookies.
public struct MiMoSessionCookies: Sendable, Equatable {
  public static let consoleHost = "platform.xiaomimimo.com"
  private static let names = ["api-platform_serviceToken", "api-platform_slh", "api-platform_ph", "userId"]
  private let values: [String: String]

  public var header: String { Self.names.compactMap { name in values[name].map { "\(name)=\($0)" } }.joined(separator: "; ") }
  public var userID: String { values["userId"]! }

  public init(header: String) throws {
    var raw = header.trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.lowercased().hasPrefix("cookie:") { raw = String(raw.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
    guard raw.utf8.count <= 65_536, raw.rangeOfCharacter(from: .controlCharacters) == nil else { throw Self.invalid }
    var result: [String: String] = [:]
    for pair in raw.split(separator: ";", omittingEmptySubsequences: true) {
      guard let equals = pair.firstIndex(of: "=") else { throw Self.invalid }
      let name = pair[..<equals].trimmingCharacters(in: .whitespaces)
      guard Self.names.contains(name) else { continue }
      let value = pair[pair.index(after: equals)...].trimmingCharacters(in: .whitespaces)
      guard result[name] == nil, Self.isValidCookieValue(value, for: name) else { throw Self.invalid }
      result[name] = value
    }
    guard result["api-platform_serviceToken"] != nil, result["userId"] != nil else { throw Self.invalid }
    values = result
  }

  /// Accept only the platform cookies from the new, isolated login store.
  public init(cookies: [HTTPCookie], now: Date = Date()) throws {
    let selected = cookies.filter { cookie in
      // Secure restricts a cookie to HTTPS; it is not required for a cookie
      // to be valid on HTTPS. Capture and quota requests both enforce HTTPS.
      guard Self.names.contains(cookie.name),
            cookie.expiresDate.map({ $0 > now }) ?? true,
            ["/api/v1/tokenPlan/detail", "/api/v1/tokenPlan/usage"].allSatisfy({ path in
              path == cookie.path || path.hasPrefix(cookie.path.hasSuffix("/") ? cookie.path : cookie.path + "/")
            }) else { return false }
      let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
      if domain == Self.consoleHost { return true }
      return cookie.name == "userId" && domain == "xiaomimimo.com"
    }
    var selectedValues: [String: String] = [:]
    for cookie in selected {
      // Validate before serialization so a separator cannot split a browser
      // value into a different header, or trimming change its contents.
      guard Self.isValidCookieValue(cookie.value, for: cookie.name) else {
        throw Self.invalidConsoleSession
      }
      // WebKit can retain the same cookie at overlapping domain/path scopes.
      // Identical values are unambiguous; never guess between different logins.
      if let previous = selectedValues[cookie.name], previous != cookie.value {
        throw ProviderClientError(kind: .auth, message: "MiMo returned conflicting login cookies. Cancel and sign in again.")
      }
      selectedValues[cookie.name] = cookie.value
    }
    guard selectedValues["api-platform_serviceToken"] != nil else {
      throw ProviderClientError(kind: .auth, message: "MiMo did not provide a console session token. Cancel and sign in again.")
    }
    guard selectedValues["userId"] != nil else {
      throw ProviderClientError(kind: .auth, message: "MiMo did not provide an account ID cookie. Cancel and sign in again.")
    }
    let header = Self.names.compactMap { name in selectedValues[name].map { "\(name)=\($0)" } }.joined(separator: "; ")
    do {
      try self.init(header: header)
    } catch {
      throw Self.invalidConsoleSession
    }
  }

  private static func isValidCookieValue(_ value: String, for name: String) -> Bool {
    guard value.utf8.count <= 16_384 else { return false }
    var content = value[...]
    // RFC 6265 permits one outer pair of quotes. Keep those bytes in the
    // stored header because MiMo's console uses quoted session cookies.
    if content.first == "\"" || content.last == "\"" {
      guard content.count >= 2, content.first == "\"", content.last == "\"" else { return false }
      content = content.dropFirst().dropLast()
    }
    if name == "api-platform_serviceToken" || name == "userId" {
      guard !content.isEmpty else { return false }
    }
    return content.unicodeScalars.allSatisfy { scalar in
      switch scalar.value {
      case 0x21, 0x23...0x2B, 0x2D...0x3A, 0x3C...0x5B, 0x5D...0x7E: return true
      default: return false
      }
    }
  }

  private static var invalidConsoleSession: ProviderClientError {
    ProviderClientError(kind: .auth, message: "MiMo returned an invalid console session. Cancel and sign in again.")
  }

  public static func credentialsForStorage(_ credentials: [String: String]) throws -> [String: String] {
    guard !credentials.isEmpty else { return [:] }
    let value = credentials[CredentialField.mimoSessionCookies] ?? ""
    if value.isEnvironmentReference { return [CredentialField.mimoSessionCookies: value] }
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return [CredentialField.mimoSessionCookies: ""]
    }
    return [CredentialField.mimoSessionCookies: try Self(header: value).header]
  }

  public static func hasChangedIdentity(from previous: String?, to updated: String?) -> Bool {
    guard previous != updated else { return false }
    let previousID = try? Self(header: previous ?? "").userID
    let updatedID = try? Self(header: updated ?? "").userID
    guard let previousID, let updatedID else { return true }
    return previousID != updatedID
  }

  private static var invalid: ProviderClientError {
    ProviderClientError(kind: .notConfigured, message: "Connect MiMo to sign in to the API Platform. Manual console cookies must include api-platform_serviceToken and userId.")
  }
}

public enum MiMoSignInPolicy {
  public static let startURL = URL(string: "https://platform.xiaomimimo.com/console/plan-manage")!

  public static func allowsNavigation(to url: URL) -> Bool {
    // Xiaomi's sign-in page embeds an inline document. These local documents
    // inherit the containing page's origin and cannot supply a console login.
    if ["about:blank", "about:srcdoc"].contains(url.absoluteString) { return true }
    guard url.scheme == "https", url.user == nil, url.password == nil,
          url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
    if host == MiMoSessionCookies.consoleHost { return true }
    // The platform's public genLoginUrl redirects to account.xiaomi.com.
    // id.mi.com hosts Xiaomi's related account verification flows.
    return ["account.xiaomi.com", "id.mi.com"].contains { host == $0 || host.hasSuffix(".\($0)") }
  }
}
