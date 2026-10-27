import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// StepFun "Step Plan" quota from the web dashboard's Connect-RPC endpoint.
///
/// The plan is not reachable with the inference `STEP_API_KEY` — quota lives in
/// the `platform.stepfun.com` (or `.ai`) web session. The credential is the
/// `Oasis-Token` cookie, a `access…refresh` JWT pair whose refresh half carries
/// the `device_id` claim that must mirror the `Oasis-Webid` header, or the
/// server answers "oasis-token is embezzled".
///
/// `QueryStepPlanRateLimit` returns either the grandfathered Coding Plan's
/// rolling five-hour/weekly windows or the credit plan's `plan_credit_rate_limit`
/// monthly subscription pool plus booster credits (classified by payload shape,
/// with `plan_family == 2` only as the ambiguous-payload tie-breaker — CodexBar
/// semantics). `GetStepPlanStatus` supplies the plan name for the subtitle.
public struct StepFunQuotaClient: QuotaProviderClient {
  public let provider: QuotaProvider = .stepfun

  private static let baseHeaders: [String: String] = [
    "oasis-appid": "10300",
    "oasis-platform": "web",
    "oasis-webid": "c8a1002d2c457e758785a9979832217c7c0b884c"
  ]

  private let httpClient: HTTPClient

  public init(httpClient: HTTPClient = URLSessionHTTPClient()) {
    self.httpClient = httpClient
  }

  public func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    let credentials = configuration.credentials.resolvingEnvironmentReferences()
    guard let token = credentials[CredentialField.stepfunOasisToken]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !token.isEmpty else {
      throw ProviderClientError(kind: .notConfigured,
        message: "Paste the Oasis-Token cookie from platform.stepfun.com or platform.stepfun.ai.")
    }
    let site = credentials[CredentialField.stepfunSite]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let host = site == "ai" ? "https://platform.stepfun.ai" : "https://platform.stepfun.com"

    let body = try await call(
      host: host, path: "QueryStepPlanRateLimit", token: token, timestamp: now)
    let planName = (try? await call(host: host, path: "GetStepPlanStatus", token: token, timestamp: now))
      .flatMap { $0["subscription"] as? [String: Any] }
      .flatMap { nonEmptyString($0["name"]) }

    return ProviderUsage(
      accountID: configuration.accountID,
      provider: provider,
      title: configuration.displayName,
      subtitle: planName.map { "Step Plan \($0)" } ?? "Step Plan",
      metrics: Self.metrics(for: body, now: now),
      fetchedAt: now
    )
  }

  // MARK: - HTTP

  private func call(host: String, path: String, token: String, timestamp: Date) async throws -> [String: Any] {
    let webid = Self.webID(forToken: token)
    let url = URL(string: "\(host)/api/step.openapi.devcenter.Dashboard/\(path)")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = Data("{}".utf8)
    request.httpShouldHandleCookies = false
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    for (key, value) in Self.baseHeaders {
      request.setValue(value, forHTTPHeaderField: key)
    }
    request.setValue(webid, forHTTPHeaderField: "oasis-webid")
    // The cookie carries the session; the header form is redundant but matches
    // what the web client sends.
    request.setValue("Oasis-Token=\(token); Oasis-Webid=\(webid)", forHTTPHeaderField: "Cookie")

    let (data, response): (Data, HTTPURLResponse)
    do {
      (data, response) = try await httpClient.data(for: request)
    } catch let error as ProviderClientError {
      throw error
    } catch {
      throw ProviderClientError(kind: .network, message: "Could not reach the provider. Check your connection and try again.")
    }

    guard (200..<300).contains(response.statusCode) else {
      throw ProviderClientError(kind: errorKind(forStatusCode: response.statusCode),
        message: "StepFun request failed (HTTP \(response.statusCode))",
        statusCode: response.statusCode,
        retryAfter: parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: timestamp))
    }

    let object = try parseJSONObject(from: data)
    guard firstNumeric(in: object, keys: ["status"]) == 1 else {
      // `code` is an enum member, `message`/`desc` may echo request internals.
      let code = firstNumeric(in: object, keys: ["code"]).flatMap(roundedInt).map { " (code \($0))" } ?? ""
      let isAuth = (object["message"] as? String)?.lowercased().contains("auth") == true
        || (object["desc"] as? String)?.lowercased().contains("auth") == true
      throw ProviderClientError(kind: isAuth ? .auth : .api,
        message: "StepFun request failed\(code)", statusCode: response.statusCode)
    }
    return object
  }

  // MARK: - Token helpers

  /// The `Oasis-Webid` must equal the `device_id` claim embedded in the token.
  /// Tokens are `access...refresh` pairs; the device id lives in the refresh
  /// half, falling back to the access half and finally the web client's
  /// well-known default device id.
  static func webID(forToken token: String) -> String {
    for half in token.components(separatedBy: "...").reversed() {
      if let webid = jwtDeviceID(half), !webid.isEmpty {
        return webid
      }
    }
    return baseHeaders["oasis-webid"]!
  }

  /// Decodes the JWT payload without verifying it — this token is the user's own
  /// session, read only to recover the device id the server requires.
  private static func jwtDeviceID(_ jwt: String) -> String? {
    let parts = jwt.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var payload = String(parts[1])
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    guard let data = Data(base64Encoded: payload
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return json["device_id"] as? String
  }

  // MARK: - metrics

  static func metrics(for body: [String: Any], now: Date) -> [UsageMetric] {
    let fiveHourReset = firstNumeric(in: body, keys: ["five_hour_usage_reset_time"])
      .flatMap(dateFromEpochTimestamp)
    let weeklyReset = firstNumeric(in: body, keys: ["weekly_usage_reset_time"])
      .flatMap(dateFromEpochTimestamp)
    let hasLiveWindow = (fiveHourReset.map { $0.timeIntervalSince1970 > 0 } ?? false)
      || (weeklyReset.map { $0.timeIntervalSince1970 > 0 } ?? false)
    let credit = body["plan_credit_rate_limit"] as? [String: Any]
    let hasCreditPool = credit != nil && (
      firstNumeric(in: credit!, keys: ["subscription_credit_left_rate"]) != nil
        || firstNumeric(in: credit!, keys: ["topup_credit_left_rate"]) != nil
        || (credit!["credit_buckets"] as? [[String: Any]])?.isEmpty == false)
    let family = firstNumeric(in: body, keys: ["plan_family"])
    let isCreditPlan = !hasLiveWindow && (hasCreditPool || family == 2)

    if isCreditPlan {
      return creditMetrics(credit, now: now)
    }

    var metrics: [UsageMetric] = []
    if let leftRate = firstNumeric(in: body, keys: ["five_hour_usage_left_rate"]) {
      metrics.append(UsageMetric(
        id: "stepfun-five-hour",
        label: "5-hour limit",
        remainingPercent: roundedPercent(leftRate * 100),
        resetAt: fiveHourReset,
        windowSeconds: 300 * 60
      ))
    }
    if let leftRate = firstNumeric(in: body, keys: ["weekly_usage_left_rate"]) {
      metrics.append(UsageMetric(
        id: "stepfun-weekly",
        label: "Weekly limit",
        remainingPercent: roundedPercent(leftRate * 100),
        resetAt: weeklyReset,
        windowSeconds: 10_080 * 60
      ))
    }
    return metrics
  }

  /// Credit plans measure a monthly pool, not rolling windows. When bucket
  /// totals are present they weight the combined remaining fraction exactly;
  /// otherwise the subscription rate stands alone (subscription and top-up
  /// fractions can't be added). Top-up gets its own line when reported.
  private static func creditMetrics(_ credit: [String: Any]?, now: Date) -> [UsageMetric] {
    guard let credit else { return [] }
    let buckets = (credit["credit_buckets"] as? [[String: Any]]) ?? []
    let validBuckets = buckets.compactMap { bucket -> (total: Double, residual: Double)? in
      guard let total = firstNumeric(in: bucket, keys: ["credit_total"]),
            let residual = firstNumeric(in: bucket, keys: ["credit_residual"]),
            total > 0, residual >= 0, residual <= total else { return nil }
      return (total, residual)
    }
    let subscriptionRate = firstNumeric(in: credit, keys: ["subscription_credit_left_rate"])
    let topupRate = firstNumeric(in: credit, keys: ["topup_credit_left_rate"])
    let creditReset = firstNumeric(in: credit, keys: ["subscription_credit_reset_time"])
      .flatMap(dateFromEpochTimestamp)

    let leftRate: Double?
    if buckets.count == validBuckets.count, !validBuckets.isEmpty {
      leftRate = validBuckets.reduce(0) { $0 + $1.residual }
        / validBuckets.reduce(0) { $0 + $1.total }
    } else {
      leftRate = subscriptionRate ?? topupRate
    }

    var metrics: [UsageMetric] = []
    if let leftRate {
      let total = validBuckets.reduce(0) { $0 + $1.total }
      let residual = validBuckets.reduce(0) { $0 + $1.residual }
      metrics.append(UsageMetric(
        id: "stepfun-credit",
        label: "Monthly plan credits",
        remainingPercent: roundedPercent(leftRate * 100),
        remainingAmount: residual > 0 ? residual : nil,
        usedDisplay: total > 0 ? formatTokensMillions(total - residual).map { "\($0) credits" } : nil,
        totalDisplay: total > 0 ? "\(formatTokensMillions(total) ?? "") credits" : nil,
        resetAt: creditReset,
        windowSeconds: nil,
        detail: "monthly allowance"
      ))
    }
    if let topupRate, topupRate > 0 {
      metrics.append(UsageMetric(
        id: "stepfun-topup",
        label: "Booster credits",
        remainingPercent: roundedPercent(topupRate * 100),
        detail: "30-day booster packs"
      ))
    }
    return metrics
  }
}
