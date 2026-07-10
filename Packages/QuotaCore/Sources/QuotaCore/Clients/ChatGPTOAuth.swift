import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Refreshes a ChatGPT/Codex OAuth access token using the refresh token written by
/// the Codex CLI (and OpenCode) into `~/.codex/auth.json`.
///
/// ChatGPT access tokens expire roughly hourly, so an imported token goes stale fast.
/// LLimit stores the refresh token and exchanges it for a fresh access token before
/// querying usage, persisting the (rotated) refresh token so it keeps working without
/// depending on Codex being installed or run.
///
/// Client id + token endpoint are the public Codex CLI values (also reused by OpenCode).
public enum ChatGPTOAuth {
  static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
  static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!

  public struct RefreshResult: Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let accountID: String?
  }

  public static func refresh(
    refreshToken: String,
    httpClient: any HTTPClient = URLSessionHTTPClient()
  ) async throws -> RefreshResult {
    var request = URLRequest(url: tokenURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "client_id": clientID,
      "grant_type": "refresh_token",
      "refresh_token": refreshToken,
      "scope": "openid profile email"
    ])

    let (data, response) = try await httpClient.data(for: request)
    guard (200..<300).contains(response.statusCode) else {
      let body = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let kind: QuotaErrorKind = (response.statusCode == 400 || response.statusCode == 401) ? .auth : .api
      throw ProviderClientError(
        kind: kind,
        message: "ChatGPT token refresh failed \(response.statusCode)\(body.isEmpty ? "" : ": \(body)")",
        statusCode: response.statusCode
      )
    }

    let payload = try parseJSONObject(from: data)
    guard let access = payload["access_token"] as? String, !access.isEmpty else {
      throw ProviderClientError(kind: .decoding, message: "ChatGPT token refresh response missing access_token")
    }

    let newRefresh = (payload["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let accountID = accountID(fromJWT: access) ?? (payload["account_id"] as? String)
    return RefreshResult(accessToken: access, refreshToken: newRefresh, accountID: accountID)
  }

  /// True when the token is missing an `exp`, or expires within `leeway` of `now`.
  public static func isAccessTokenExpired(_ token: String, now: Date = Date(), leeway: TimeInterval = 300) -> Bool {
    guard let exp = accessTokenExpiry(token) else {
      return true
    }
    return now.addingTimeInterval(leeway) >= exp
  }

  /// The `exp` (expiry) instant of a ChatGPT access-token JWT, or nil if it can't be
  /// decoded. Used to compare the freshness of two tokens for the same account.
  public static func accessTokenExpiry(_ token: String) -> Date? {
    guard
      let payload = jwtPayload(token),
      let exp = (payload["exp"] as? NSNumber)?.doubleValue
    else {
      return nil
    }
    return Date(timeIntervalSince1970: exp)
  }

  static func accountID(fromJWT jwt: String) -> String? {
    guard
      let payload = jwtPayload(jwt),
      let auth = payload["https://api.openai.com/auth"] as? [String: Any],
      let id = auth["chatgpt_account_id"] as? String,
      !id.isEmpty
    else {
      return nil
    }
    return id
  }

  private static func jwtPayload(_ jwt: String) -> [String: Any]? {
    let parts = jwt.split(separator: ".")
    guard parts.count == 3 else { return nil }

    var encoded = String(parts[1])
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = encoded.count % 4
    if remainder != 0 {
      encoded += String(repeating: "=", count: 4 - remainder)
    }

    guard let data = Data(base64Encoded: encoded) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }
}
