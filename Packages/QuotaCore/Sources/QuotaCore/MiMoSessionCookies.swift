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
      guard result[name] == nil, !value.isEmpty, value.utf8.count <= 16_384,
            value.unicodeScalars.allSatisfy({ scalar in
              (0x21...0x7E).contains(scalar.value) && !"\"(),;\\".unicodeScalars.contains(scalar)
            }) else { throw Self.invalid }
      result[name] = value
    }
    guard result["api-platform_serviceToken"] != nil, result["userId"] != nil else { throw Self.invalid }
    values = result
  }

  /// Accept only the platform cookies from the new, isolated login store.
  public init(cookies: [HTTPCookie], now: Date = Date()) throws {
    let selected = cookies.filter { cookie in
      guard Self.names.contains(cookie.name), cookie.isSecure,
            cookie.expiresDate.map({ $0 > now }) ?? true,
            ["/api/v1/tokenPlan/detail", "/api/v1/tokenPlan/usage"].allSatisfy({ path in
              path == cookie.path || path.hasPrefix(cookie.path.hasSuffix("/") ? cookie.path : cookie.path + "/")
            }) else { return false }
      let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
      if domain == Self.consoleHost { return true }
      return cookie.name == "userId" && domain == "xiaomimimo.com"
    }
    try self.init(header: selected.map { "\($0.name)=\($0.value)" }.joined(separator: "; "))
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
