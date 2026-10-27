import Foundation
import CoreFoundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The two authentication cookies from LLimit's own temporary StepFun browser.
/// No ordinary browser data, SSO cookies, or analytics are adopted.
public struct StepFunBrowserSession: Sendable, Equatable {
  public static let consoleHost = "platform.stepfun.ai"
  private struct Cookie: Codable, Sendable, Equatable {
    let name: String
    let value: String
    let expires: Double?
  }
  private let records: [Cookie]
  public let accessToken: String
  private let refreshToken: String
  public let webID: String
  public let subject: String
  public var secretValues: [String] { records.map(\.value) + [accessToken, refreshToken, webID] }
  public var cookieHeader: String { records.map { "\($0.name)=\($0.value)" }.joined(separator: "; ") }
  public func needsRenewal(at now: Date = Date()) -> Bool {
    (Self.expiry(of: accessToken) ?? .distantPast) <= now.addingTimeInterval(300)
  }
  public func isAccessExpired(at now: Date = Date()) -> Bool {
    (Self.expiry(of: accessToken) ?? .distantPast) <= now
  }
  public func isExpired(at now: Date = Date()) -> Bool {
    records.contains { $0.expires.map { $0 <= now.timeIntervalSince1970 } == true }
      || (Self.expiry(of: refreshToken) ?? .distantPast) <= now
  }

  public init(cookies: [HTTPCookie], now: Date = Date()) throws {
    let selected = cookies.filter {
      ["Oasis-Token", "Oasis-Webid"].contains($0.name)
        && $0.domain.lowercased() == Self.consoleHost && $0.path == "/"
        && $0.isHTTPOnly
        && ($0.expiresDate.map { $0 > now } ?? true)
    }.map { Cookie(name: $0.name, value: $0.value, expires: $0.expiresDate?.timeIntervalSince1970) }
    try self.init(records: selected)
  }

  public init(serialized: String) throws {
    guard serialized.utf8.count <= 100_000, let data = serialized.data(using: .utf8),
          let records = try? JSONDecoder().decode([Cookie].self, from: data) else { throw Self.reconnect }
    try self.init(records: records)
  }

  public init(compoundToken: String, webID: String) throws {
    try self.init(records: [Cookie(name: "Oasis-Token", value: compoundToken, expires: nil),
                           Cookie(name: "Oasis-Webid", value: webID, expires: nil)])
  }

  private init(records: [Cookie]) throws {
    guard records.count == 2, Set(records.map(\.name)) == ["Oasis-Token", "Oasis-Webid"],
          records.allSatisfy({ $0.expires.map { $0.isFinite && $0 > 0 } ?? true }),
          let compound = records.first(where: { $0.name == "Oasis-Token" })?.value,
          let webID = records.first(where: { $0.name == "Oasis-Webid" })?.value,
          Self.headerValue(webID) else { throw Self.reconnect }
    let pair = compound.components(separatedBy: "...")
    guard pair.count == 2,
          let access = Self.claims(pair[0]), let refresh = Self.claims(pair[1]),
          Self.identifier(access["mode"]) == "2",
          let subject = Self.identifier(access["oasis_id"]),
          Self.identifier(refresh["oasis_id"]) == subject,
          Self.identifier(refresh["app_id"]) == "20700",
          refresh["device_id"] as? String == webID else { throw Self.reconnect }
    self.records = records.sorted { $0.name < $1.name }
    accessToken = pair[0]
    refreshToken = pair[1]
    self.webID = webID
    self.subject = subject
  }

  public func encoded() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(records), as: UTF8.self)
  }

  public func credentials(verifiedUserID: String) throws -> [String: String] {
    [CredentialField.stepFunSessionToken: accessToken, CredentialField.stepFunWebID: webID,
     CredentialField.stepFunBrowserSession: try encoded(), CredentialField.stepFunUserID: verifiedUserID]
  }

  /// Passport can return HTTP 200 with an anonymous session when a grant has
  /// expired. Never adopt it, switch identities, or erase the saved login on a
  /// transient failure. The caller verifies the server's UserInfo UID as well.
  public func renewed(httpClient: any HTTPClient, now: Date = Date()) async throws -> StepFunBrowserSession {
    guard !isExpired(at: now) else { throw Self.reconnect }
    let url = URL(string: "https://\(Self.consoleHost)/passport/proto.api.passport.v1.PassportService/RefreshToken")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = Data("{}".utf8)
    request.httpShouldHandleCookies = false
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
    request.setValue(webID, forHTTPHeaderField: "Oasis-Webid")
    request.setValue("20700", forHTTPHeaderField: "Oasis-Appid")
    request.setValue("web", forHTTPHeaderField: "Oasis-Platform")
    request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let data: Data
    let response: HTTPURLResponse
    do { (data, response) = try await httpClient.data(for: request, redirects: .refuse) }
    catch is CancellationError { throw CancellationError() }
    catch let error as URLError where error.code == .cancelled { throw CancellationError() }
    catch { throw Self.transient }
    guard (200..<300).contains(response.statusCode), response.url == url else { throw Self.transient }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    guard let payload = try? decoder.decode(RefreshResponse.self, from: data) else { throw Self.transient }
    guard let mode = payload.accessToken.mode else { throw Self.transient }
    guard mode.isSignedIn else { throw Self.reconnect }
    let access = payload.accessToken.raw
    let refresh = payload.refreshToken?.raw ?? refreshToken
    let expiry = records.first { $0.name == "Oasis-Token" }?.expires
    let session = try StepFunBrowserSession(records: [
      Cookie(name: "Oasis-Token", value: "\(access)...\(refresh)", expires: expiry),
      Cookie(name: "Oasis-Webid", value: webID, expires: records.first { $0.name == "Oasis-Webid" }?.expires)
    ])
    guard session.subject == subject, session.webID == webID, !session.isAccessExpired(at: now) else { throw Self.reconnect }
    return session
  }

  private static func headerValue(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 32_768 && value.utf8.allSatisfy { (33...126).contains($0) }
      && !value.contains(";") && !value.contains(",")
  }

  private static func claims(_ token: String) -> [String: Any]? {
    guard headerValue(token), token.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
      || (48...57).contains($0) || [45, 46, 95].contains($0) }) else { return nil }
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
    var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    guard let data = Data(base64Encoded: payload) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  private static func expiry(of token: String) -> Date? {
    guard let value = claims(token)?["exp"], let text = identifier(value), let seconds = Double(text),
          seconds <= 253_402_300_799 else { return nil }
    return Date(timeIntervalSince1970: seconds)
  }

  private static func identifier(_ value: Any?) -> String? {
    if let value = value as? String, !value.isEmpty, value.utf8.count <= 64,
       value.utf8.allSatisfy({ (48...57).contains($0) }) { return value }
    if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
       value.doubleValue.isFinite, value.doubleValue > 0,
       value.doubleValue < Double(Int64.max), value.doubleValue.rounded(.down) == value.doubleValue {
      return value.stringValue
    }
    return nil
  }

  private struct RefreshResponse: Decodable {
    struct Token: Decodable { let raw: String; let mode: Mode? }
    struct Mode: Decodable {
      let isSignedIn: Bool
      init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) { isSignedIn = number == 2 }
        else { isSignedIn = ["SIGN_IN", "MODE_SIGN_IN"].contains(try container.decode(String.self)) }
      }
    }
    let accessToken: Token
    let refreshToken: Token?
  }

  private static var reconnect: ProviderClientError {
    ProviderClientError(kind: .auth, message: "StepFun needs you to sign in again. Connect StepFun to renew this account’s login.")
  }
  private static var transient: ProviderClientError {
    ProviderClientError(kind: .network, message: "Could not renew the StepFun session. Check your connection and try again.")
  }
}

public enum StepFunSignInPolicy {
  public static let startURL = URL(string: "https://platform.stepfun.ai/plan-subscribe")!
  public static func allowsNavigation(to url: URL) -> Bool {
    if url.absoluteString == "about:blank" { return true }
    return url.scheme == "https" && url.user == nil && url.password == nil
      && (url.port == nil || url.port == 443)
      && ["platform.stepfun.ai", "account.stepfun.ai", "accounts.google.com", "appleid.apple.com"].contains(url.host?.lowercased() ?? "")
  }

  public static func allowsSubframeNavigation(to url: URL) -> Bool {
    if allowsNavigation(to: url) || url.absoluteString == "about:srcdoc" { return true }
    // StepFun's email/SMS sign-in uses Tencent's CAPTCHA. Challenge frames
    // may load here, but they cannot become the account connection origin.
    return url.scheme == "https" && url.user == nil && url.password == nil
      && (url.port == nil || url.port == 443)
      && ["turing.captcha.qcloud.com", "ca.turing.captcha.qcloud.com", "turing.captcha.gtimg.com",
          "global.turing.captcha.gtimg.com"].contains(url.host?.lowercased() ?? "")
  }
}
