import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// StepFun (阶跃星辰) Step Plan quota, read from the web dashboard's own API.
///
/// There is no usage endpoint for the Step API key (`api.stepfun.com`
/// `/step_plan/v1` is billing-only); the only place subscription quota is
/// reported is the console backend, authenticated by an `Oasis-Token` cookie:
///
///     POST https://platform.stepfun.com/api/step.openapi.devcenter.Dashboard/QueryStepPlanRateLimit
///     Cookie: Oasis-Token=<access...refresh>; Oasis-Webid=<device_id>
///
/// The account can carry a pasted `Oasis-Token`, or username + password, which
/// mint a fresh token through the passport flow the console itself uses:
/// `GET platform.stepfun.com` (INGRESSCOOKIE) → `RegisterDevice` →
/// `SignInByPassword`. A pasted token that stops working is retried once
/// through the password login when both are stored.
///
/// `Oasis-Webid` must equal the token's `device_id` claim or the server
/// rejects the session as embezzled; it lives in the refresh half of the
/// "access...refresh" pair, so the JWT payload is decoded without verifying
/// (same trust model as CredentialDiscovery's JWT reads).
///
/// Two billing shapes come back in one payload (CodexBar's docs/stepfun.md is
/// the reference): legacy Coding Plans carry rolling windows in
/// `five_hour_usage_left_rate` / `weekly_usage_left_rate` (fractions
/// remaining, reset epochs as strings), while current Credit plans
/// (`plan_family` 2) report a monthly pool under `plan_credit_rate_limit`
/// (`subscription_credit_left_rate`, `credit_buckets[]` with string int64s)
/// and zeroed window fields — 0 there means "no window configured", never
/// "used up". `GetStepPlanStatus` adds the plan name as the subtitle; its
/// failure is tolerated.
public struct StepFunQuotaClient: QuotaProviderClient {
  public let provider: QuotaProvider = .stepfun
  private let baseURL: URL
  private let httpClient: any HTTPClient

  /// Sent while a token carries no readable `device_id` — the login flow
  /// always gets a real one back, so this only covers bare pasted JWTs.
  private static let fallbackWebID = "1f6a9c4d2e8b3075f1a6c9d4e2b83075f1a6c9d4"
  private static let appID = "10300"

  public init(
    baseURL: URL = URL(string: "https://platform.stepfun.com")!,
    httpClient: any HTTPClient
  ) {
    self.baseURL = baseURL
    self.httpClient = httpClient
  }

  public func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    let token = trimmed(configuration.credentials[CredentialField.stepfunToken])
    let username = trimmed(configuration.credentials[CredentialField.stepfunUsername])
    let password = trimmed(configuration.credentials[CredentialField.stepfunPassword])
    let canLogin = !username.isEmpty && !password.isEmpty

    if token.isEmpty && !canLogin {
      throw ProviderClientError(kind: .notConfigured, message: "StepFun needs an Oasis-Token or a username plus password")
    }

    if !token.isEmpty {
      do {
        return try await queryUsage(token: token, configuration: configuration, now: now)
      } catch let error as ProviderClientError {
        // A pasted token expires; when the password login is also stored it
        // mints a fresh one rather than failing the account outright.
        guard canLogin, error.kind == .auth || error.kind == .api else { throw error }
      }
    }

    let sessionToken = try await login(username: username, password: password)
    return try await queryUsage(token: sessionToken, configuration: configuration, now: now)
  }

  // MARK: - Usage + plan status

  private func queryUsage(token: String, configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    let request = dashboardRequest(path: "QueryStepPlanRateLimit", token: token)
    let (data, response) = try await httpClient.data(for: request)
    try requireSuccess(response: response, data: data)

    let payload = try parseJSONObject(from: data)
    guard parseNumeric(payload["status"]) == 1 else {
      let detail = nonEmptyString(payload["message"]) ?? nonEmptyString(payload["desc"])
        ?? parseNumeric(payload["code"]).map { "code \($0)" } ?? "unknown"
      throw ProviderClientError(kind: .api, message: "StepFun API error: \(detail)")
    }

    var metrics = isCreditPlan(payload) ? creditMetrics(in: payload, now: now) : windowMetrics(in: payload, now: now)
    if metrics.isEmpty {
      metrics.append(UsageMetric(id: "empty", label: "No quota data available"))
    }
    let maxUsagePercent = metrics.map { 100 - ($0.remainingPercent ?? 100) }.max() ?? 0

    let planName = try? await queryPlanName(token: token)

    return ProviderUsage(
      accountID: configuration.accountID,
      provider: .stepfun,
      title: configuration.displayName,
      subtitle: planName ?? "Step Plan",
      metrics: metrics,
      maxUsagePercent: maxUsagePercent,
      warning: maxUsagePercent >= 80 ? "High usage" : nil,
      fetchedAt: now
    )
  }

  private func queryPlanName(token: String) async throws -> String? {
    let request = dashboardRequest(path: "GetStepPlanStatus", token: token)
    let (data, response) = try await httpClient.data(for: request)
    guard (200..<300).contains(response.statusCode) else { return nil }

    guard
      let payload = try? parseJSONObject(from: data),
      let subscription = payload["subscription"] as? [String: Any]
    else { return nil }
    return nonEmptyString(subscription["name"])
  }

  /// Rolling-window plans (legacy Coding Plan): fractions left in the 5-hour
  /// and weekly windows. A window is only real when it carries a reset time —
  /// credit plans report `left_rate: 0` with `reset_time: 0`, and treating
  /// that as a live window would read "no window configured" as "used up".
  private func windowMetrics(in payload: [String: Any], now: Date) -> [UsageMetric] {
    var metrics: [UsageMetric] = []

    if let resetAt = positiveEpochDate(payload["five_hour_usage_reset_time"]) {
      metrics.append(
        UsageMetric(
          id: "window-5-hour",
          label: "5-hour limit",
          remainingPercent: parseNumeric(payload["five_hour_usage_left_rate"]).flatMap { roundedPercent($0 * 100) },
          resetAt: resetAt,
          resetIn: formatResetCountdown(to: resetAt, now: now)
        )
      )
    }

    if let resetAt = positiveEpochDate(payload["weekly_usage_reset_time"]) {
      metrics.append(
        UsageMetric(
          id: "weekly",
          label: "Weekly limit",
          remainingPercent: parseNumeric(payload["weekly_usage_left_rate"]).flatMap { roundedPercent($0 * 100) },
          resetAt: resetAt,
          resetIn: formatResetCountdown(to: resetAt, now: now)
        )
      )
    }

    return metrics
  }

  /// Credit plans (the current Step Plan): one monthly pool. `credit_buckets`
  /// carry absolute balances (subscription month-pool plus top-up packs), so
  /// their sums weight the combined remaining fraction correctly; without
  /// them the subscription rate stands in, with a separate top-up metric when
  /// the account also holds a top-up balance.
  private func creditMetrics(in payload: [String: Any], now: Date) -> [UsageMetric] {
    guard let credit = payload["plan_credit_rate_limit"] as? [String: Any] else { return [] }

    var metrics: [UsageMetric] = []
    let resetAt = positiveEpochDate(credit["subscription_credit_reset_time"])
      ?? firstBucketReset(in: credit)

    if let buckets = credit["credit_buckets"] as? [[String: Any]], !buckets.isEmpty {
      let balances = buckets.compactMap { bucket -> (total: Double, residual: Double)? in
        guard
          let total = parseNumeric(bucket["credit_total"]),
          let residual = parseNumeric(bucket["credit_residual"]),
          total > 0, residual >= 0, residual <= total
        else { return nil }
        return (total, residual)
      }

      if balances.count == buckets.count {
        let total = balances.reduce(0.0) { $0 + $1.total }
        let residual = balances.reduce(0.0) { $0 + $1.residual }
        metrics.append(
          UsageMetric(
            id: "credit-monthly",
            label: "Monthly credit",
            remainingPercent: roundedPercent(residual / total * 100),
            usedDisplay: formatTokensMillions(total - residual),
            totalDisplay: formatTokensMillions(total),
            resetAt: resetAt,
            resetIn: resetAt.map { formatResetCountdown(to: $0, now: now) }
          )
        )
      }
    }

    if metrics.isEmpty {
      if let rate = parseNumeric(credit["subscription_credit_left_rate"]) {
        metrics.append(
          UsageMetric(
            id: "credit-monthly",
            label: "Monthly credit",
            remainingPercent: roundedPercent(rate * 100),
            resetAt: resetAt,
            resetIn: resetAt.map { formatResetCountdown(to: $0, now: now) }
          )
        )
      }
      if let rate = parseNumeric(credit["topup_credit_left_rate"]) {
        metrics.append(
          UsageMetric(
            id: "credit-topup",
            label: "Top-up credit",
            remainingPercent: roundedPercent(rate * 100)
          )
        )
      }
    }

    return metrics
  }

  /// Shape over flag: a live window (any reset time > 0) means a rolling-window
  /// plan regardless of `plan_family`; only a windowless payload carrying a
  /// credit pool — or the bare family id — classifies as credit-based.
  private func isCreditPlan(_ payload: [String: Any]) -> Bool {
    if positiveEpochDate(payload["five_hour_usage_reset_time"]) != nil
      || positiveEpochDate(payload["weekly_usage_reset_time"]) != nil {
      return false
    }

    if let credit = payload["plan_credit_rate_limit"] as? [String: Any],
       parseNumeric(credit["subscription_credit_left_rate"]) != nil
        || parseNumeric(credit["topup_credit_left_rate"]) != nil
        || !(credit["credit_buckets"] as? [[String: Any]] ?? []).isEmpty {
      return true
    }

    return parseNumeric(payload["plan_family"]) == 2
  }

  private func firstBucketReset(in credit: [String: Any]) -> Date? {
    guard let buckets = credit["credit_buckets"] as? [[String: Any]] else { return nil }
    return buckets.lazy.compactMap { positiveEpochDate($0["next_reset_at"]) }.min()
  }

  /// Reset epochs arrive as strings ("1777528800") or numbers; 0 is the API's
  /// "no window" sentinel, and both epoch seconds and milliseconds occur.
  private func positiveEpochDate(_ value: Any?) -> Date? {
    guard let epoch = parseNumeric(value), epoch > 0 else { return nil }
    return dateFromEpochTimestamp(epoch)
  }

  // MARK: - Login

  /// The console's own sign-in: an ingress session cookie, an anonymous
  /// device registration, then the password exchange — each step's cookies
  /// ride the next request. Returns the combined "access...refresh" token the
  /// dashboard cookie holds.
  private func login(username: String, password: String) async throws -> String {
    let ingressCookie = try await fetchIngressCookie()
    let anonymousToken = try await registerDevice(ingressCookie: ingressCookie)
    return try await signInByPassword(
      username: username,
      password: password,
      ingressCookie: ingressCookie,
      anonymousToken: anonymousToken
    )
  }

  private func fetchIngressCookie() async throws -> String {
    var request = URLRequest(url: baseURL)
    request.httpMethod = "GET"
    applyBaseHeaders(to: &request)

    let (_, response) = try await httpClient.data(for: request)
    guard (200..<400).contains(response.statusCode) else {
      throw ProviderClientError(kind: .api, message: "StepFun platform unreachable (\(response.statusCode))")
    }

    guard let cookie = ingressCookieValue(from: response) else {
      throw ProviderClientError(kind: .api, message: "StepFun login failed: no INGRESSCOOKIE in platform response")
    }
    return cookie
  }

  private func registerDevice(ingressCookie: String) async throws -> String {
    var request = passportRequest(path: "RegisterDevice")
    request.setValue("INGRESSCOOKIE=\(ingressCookie)", forHTTPHeaderField: "Cookie")

    let (data, response) = try await httpClient.data(for: request)
    try requireSuccess(response: response, data: data)

    let payload = try parseJSONObject(from: data)
    guard let token = combinedToken(in: payload) else {
      throw ProviderClientError(kind: .api, message: "StepFun device registration returned no token")
    }
    return token
  }

  private func signInByPassword(
    username: String,
    password: String,
    ingressCookie: String,
    anonymousToken: String
  ) async throws -> String {
    var request = passportRequest(path: "SignInByPassword")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "username": username,
      "password": password
    ])
    let webID = webID(forToken: anonymousToken)
    request.setValue(webID, forHTTPHeaderField: "oasis-webid")
    request.setValue(
      "Oasis-Token=\(anonymousToken); Oasis-Webid=\(webID); INGRESSCOOKIE=\(ingressCookie)",
      forHTTPHeaderField: "Cookie"
    )

    let (data, response) = try await httpClient.data(for: request)
    if response.statusCode == 401 || response.statusCode == 403 {
      throw ProviderClientError(kind: .auth, message: "StepFun login failed (\(response.statusCode)) — check username and password")
    }
    try requireSuccess(response: response, data: data)

    let payload = try parseJSONObject(from: data)
    guard let token = combinedToken(in: payload) else {
      let detail = nonEmptyString(payload["message"]) ?? nonEmptyString(payload["desc"]) ?? "no token returned"
      throw ProviderClientError(kind: .auth, message: "StepFun login failed: \(detail)")
    }
    return token
  }

  /// `accessToken`/`refreshToken` arrive as `{ "raw": "<jwt>" }` objects;
  /// snake_case spellings are accepted in case the proto-JSON layer changes.
  private func combinedToken(in payload: [String: Any]) -> String? {
    func rawToken(_ key: String, _ snakeKey: String) -> String? {
      let container = (payload[key] as? [String: Any]) ?? (payload[snakeKey] as? [String: Any])
      return nonEmptyString(container?["raw"])
    }

    guard let access = rawToken("accessToken", "access_token") else { return nil }
    guard let refresh = rawToken("refreshToken", "refresh_token") else { return access }
    return "\(access)...\(refresh)"
  }

  // MARK: - Request plumbing

  private func dashboardRequest(path: String, token: String) -> URLRequest {
    var request = URLRequest(url: baseURL.appendingPathComponent("api/step.openapi.devcenter.Dashboard/\(path)"))
    request.httpMethod = "POST"
    request.httpBody = Data("{}".utf8)
    applyBaseHeaders(to: &request)
    let webID = webID(forToken: token)
    request.setValue(webID, forHTTPHeaderField: "oasis-webid")
    request.setValue("Oasis-Token=\(token); Oasis-Webid=\(webID)", forHTTPHeaderField: "Cookie")
    return request
  }

  private func passportRequest(path: String) -> URLRequest {
    var request = URLRequest(url: baseURL.appendingPathComponent("passport/proto.api.passport.v1.PassportService/\(path)"))
    request.httpMethod = "POST"
    request.httpBody = Data("{}".utf8)
    applyBaseHeaders(to: &request)
    return request
  }

  /// The headers the console backend expects — including a browser
  /// User-Agent, without which the ingress can refuse the request.
  private func applyBaseHeaders(to request: inout URLRequest) {
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(Self.appID, forHTTPHeaderField: "oasis-appid")
    request.setValue("web", forHTTPHeaderField: "oasis-platform")
    request.setValue(Self.fallbackWebID, forHTTPHeaderField: "oasis-webid")
    request.setValue(
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36",
      forHTTPHeaderField: "User-Agent"
    )
  }

  private func requireSuccess(response: HTTPURLResponse, data: Data) throws {
    guard !(200..<300).contains(response.statusCode) else { return }
    let body = String(data: data, encoding: .utf8) ?? ""
    switch response.statusCode {
    case 401, 403:
      throw ProviderClientError(kind: .auth, message: "StepFun authorization failed (\(response.statusCode)) — the Oasis-Token may have expired")
    case 429:
      throw ProviderClientError(kind: .rateLimit, message: "StepFun API rate limited: \(body)")
    default:
      throw ProviderClientError(kind: .api, message: "StepFun API error \(response.statusCode): \(body)")
    }
  }

  /// Reads INGRESSCOOKIE out of the homepage's Set-Cookie headers. Header
  /// joins vary by platform, so the value stops at the first `;` or `,` —
  /// neither can appear inside a cookie value.
  private func ingressCookieValue(from response: HTTPURLResponse) -> String? {
    for (key, value) in response.allHeaderFields {
      guard
        (key as? String)?.lowercased() == "set-cookie",
        let header = value as? String,
        let start = header.range(of: "INGRESSCOOKIE=")
      else { continue }

      let tail = header[start.upperBound...]
      let end = tail.firstIndex(where: { $0 == ";" || $0 == "," }) ?? tail.endIndex
      let cookie = tail[..<end].trimmingCharacters(in: .whitespaces)
      if !cookie.isEmpty { return cookie }
    }
    return nil
  }

  /// The `Oasis-Webid` the server cross-checks against the token. The
  /// `device_id` claim lives in the refresh half of an "access...refresh"
  /// pair, so halves are scanned refresh-first; a bare token without the
  /// claim gets the placeholder (which only the login flow's tokens never
  /// need).
  private func webID(forToken token: String) -> String {
    for half in token.components(separatedBy: "...").reversed() {
      if let deviceID = deviceIDClaim(in: half), !deviceID.isEmpty {
        return deviceID
      }
    }
    return Self.fallbackWebID
  }

  private func deviceIDClaim(in jwt: String) -> String? {
    let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count >= 2 else { return nil }

    var payload = String(parts[1])
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = payload.count % 4
    if remainder != 0 {
      payload += String(repeating: "=", count: 4 - remainder)
    }

    guard
      let data = Data(base64Encoded: payload),
      let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return claims["device_id"] as? String
  }

  private func trimmed(_ value: String?) -> String {
    value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }
}
