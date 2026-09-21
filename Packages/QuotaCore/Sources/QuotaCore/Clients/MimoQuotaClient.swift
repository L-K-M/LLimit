import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Xiaomi MiMo Token Plan subscription quota.
///
/// Token Plan keys (`tp-…`, issued per regional cluster — cn, sgp, ams) are
/// Bearer credentials on the same regional gateways the coding tools call:
///
///     GET {base}/tokenPlan/usage →
///     {"code": 0, "data": {"monthUsage": {"percent": 0.1661,
///       "items": [{"name": "month_total_token", "used": 265741632,
///                  "limit": 1600000000, "percent": 0.1661}]}}}
///
/// `GET {base}/user/balance` is the older shape — `data.token_balance` /
/// `data.token_limit` (+ `plan`/`plan_name`) — and is tried when no usage
/// endpoint yields items. Both endpoints are undocumented; everything about
/// the payload is tolerated as optional except the quota numbers themselves.
///
/// A key only authenticates against its own cluster, so with no configured
/// `mimo.api_base_url` every regional base is probed in turn — a 401 on one
/// cluster only means the key lives elsewhere. The platform dashboard's
/// cookie-authenticated `platform.xiaomimimo.com/api/v1/tokenPlan/usage` is
/// deliberately not used: dashboard cookies are a second credential type, not
/// the tp- key this provider stores.
public struct MimoQuotaClient: QuotaProviderClient {
  public let provider: QuotaProvider = .mimo

  /// Regional Token Plan gateways, tried in this order when the account does
  /// not pin a base URL.
  public static let defaultBaseURLs = [
    "https://token-plan-sgp.xiaomimimo.com/v1",
    "https://token-plan-cn.xiaomimimo.com/v1",
    "https://token-plan-ams.xiaomimimo.com/v1"
  ]

  private let httpClient: any HTTPClient

  public init(httpClient: any HTTPClient) {
    self.httpClient = httpClient
  }

  public func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    let apiKey = configuration.credentials[CredentialField.mimoAPIKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !apiKey.isEmpty else {
      throw ProviderClientError(kind: .notConfigured, message: "MiMo Token Plan API key is not configured")
    }

    let baseURLs = configuredBaseURL(in: configuration).map { [$0] } ?? Self.defaultBaseURLs

    // First pass: the usage endpoint, which reports the plan period's items.
    var lastError: ProviderClientError?
    var sawAuthFailure = false
    for base in baseURLs {
      do {
        if let usage = try await fetchMonthUsage(base: base, apiKey: apiKey, configuration: configuration, now: now) {
          return usage
        }
      } catch let error as ProviderClientError {
        if error.kind == .auth { sawAuthFailure = true }
        lastError = error
      } catch {
        lastError = ProviderClientError(kind: .network, message: error.localizedDescription)
      }
    }

    // Second pass: the balance endpoint (token_balance / token_limit).
    for base in baseURLs {
      do {
        if let usage = try await fetchTokenBalance(base: base, apiKey: apiKey, configuration: configuration, now: now) {
          return usage
        }
      } catch let error as ProviderClientError {
        if error.kind == .auth { sawAuthFailure = true }
        lastError = error
      } catch {
        lastError = ProviderClientError(kind: .network, message: error.localizedDescription)
      }
    }

    if sawAuthFailure {
      throw ProviderClientError(
        kind: .auth,
        message: "MiMo authorization failed — check that the key is a Token Plan key (tp-…)"
      )
    }
    throw lastError ?? ProviderClientError(
      kind: .decoding,
      message: "MiMo Token Plan returned no quota data"
    )
  }

  // MARK: - Endpoints

  /// Returns nil when the endpoint answered but carried no usage items, so the
  /// balance fallback still gets a chance.
  private func fetchMonthUsage(
    base: String,
    apiKey: String,
    configuration: ProviderRuntimeConfiguration,
    now: Date
  ) async throws -> ProviderUsage? {
    guard let url = URL(string: "\(base)/tokenPlan/usage") else {
      throw ProviderClientError(kind: .api, message: "Invalid MiMo base URL: \(base)")
    }

    let payload = try await getJSON(url: url, apiKey: apiKey)
    guard let items = (payload["data"] as? [String: Any])
      .flatMap({ $0["monthUsage"] as? [String: Any] })
      .flatMap({ $0["items"] as? [[String: Any]] }),
      !items.isEmpty
    else {
      return nil
    }

    let monthUsage = (payload["data"] as? [String: Any])?["monthUsage"] as? [String: Any] ?? [:]
    var metrics: [UsageMetric] = []
    for item in items {
      guard let limit = parseNumeric(item["limit"]), limit > 0 else { continue }
      let name = nonEmptyString(item["name"]) ?? "month_total_token"
      let used = parseNumeric(item["used"])
        ?? parseNumeric(item["remaining"]).map { max(0, limit - $0) }
        ?? 0
      // `percent` is a used fraction (0.1661 = 16.61%), not a remaining share.
      let usedPercent = parseNumeric(item["percent"]).map { $0 * 100.0 }
        ?? (used / limit) * 100.0
      let remainingPercent = percentRemaining(fromUsedPercent: usedPercent)
      let resetAt = resetDate(in: item, fallback: monthUsage, now: now)

      metrics.append(
        UsageMetric(
          id: metricID(for: name),
          label: metricLabel(for: name),
          remainingPercent: remainingPercent,
          usedDisplay: formatCredits(used),
          totalDisplay: formatCredits(limit),
          resetAt: resetAt,
          resetIn: resetAt.map { formatResetCountdown(to: $0, now: now) }
        )
      )
    }

    guard !metrics.isEmpty else { return nil }

    let maxUsagePercent = metrics.map { 100 - ($0.remainingPercent ?? 100) }.max() ?? 0
    return ProviderUsage(
      accountID: configuration.accountID,
      provider: .mimo,
      title: configuration.displayName,
      subtitle: subtitle(plan: planName(in: payload)),
      metrics: metrics,
      maxUsagePercent: maxUsagePercent,
      warning: maxUsagePercent >= 80 ? "High usage" : nil,
      fetchedAt: now
    )
  }

  /// `data.token_balance` / `data.token_limit` — the remaining/total credit
  /// counters the balance endpoint exposes for Token Plan accounts.
  private func fetchTokenBalance(
    base: String,
    apiKey: String,
    configuration: ProviderRuntimeConfiguration,
    now: Date
  ) async throws -> ProviderUsage? {
    guard let url = URL(string: "\(base)/user/balance") else {
      throw ProviderClientError(kind: .api, message: "Invalid MiMo base URL: \(base)")
    }

    let payload = try await getJSON(url: url, apiKey: apiKey)
    guard
      let data = payload["data"] as? [String: Any],
      let limit = parseNumeric(data["token_limit"]), limit > 0
    else {
      return nil
    }

    let remaining = parseNumeric(data["token_balance"]) ?? 0
    let used = max(0, limit - remaining)
    let remainingPercent = percentRemaining(fromUsedPercent: used / limit * 100.0)
    let resetAt = resetDate(in: data, fallback: [:], now: now)

    let metric = UsageMetric(
      id: "monthly-credits",
      label: "Monthly credits",
      remainingPercent: remainingPercent,
      usedDisplay: formatCredits(used),
      totalDisplay: formatCredits(limit),
      resetAt: resetAt,
      resetIn: resetAt.map { formatResetCountdown(to: $0, now: now) }
    )

    let maxUsagePercent = 100 - (remainingPercent ?? 100)
    return ProviderUsage(
      accountID: configuration.accountID,
      provider: .mimo,
      title: configuration.displayName,
      subtitle: subtitle(plan: planName(in: payload)),
      metrics: [metric],
      maxUsagePercent: maxUsagePercent,
      warning: maxUsagePercent >= 80 ? "High usage" : nil,
      fetchedAt: now
    )
  }

  // MARK: - Helpers

  /// One GET against a regional gateway. Platform-style bodies carry
  /// `code`/`message`; a non-zero `code` is an API error even on HTTP 200.
  private func getJSON(url: URL, apiKey: String) async throws -> [String: Any] {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("LLimit/0.1", forHTTPHeaderField: "User-Agent")

    let (data, response) = try await httpClient.data(for: request)
    guard (200..<300).contains(response.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      switch response.statusCode {
      case 401, 403:
        throw ProviderClientError(kind: .auth, message: "MiMo authorization failed (\(response.statusCode))")
      case 429:
        throw ProviderClientError(kind: .rateLimit, message: "MiMo API rate limited: \(body)")
      default:
        throw ProviderClientError(kind: .api, message: "MiMo API error \(response.statusCode): \(body)")
      }
    }

    let payload = try parseJSONObject(from: data)
    if let code = parseNumeric(payload["code"]), code != 0 {
      let message = nonEmptyString(payload["message"]) ?? "code \(formatIntLike(code) ?? "\(code)")"
      throw ProviderClientError(kind: .api, message: "MiMo API error: \(message)")
    }
    return payload
  }

  /// The configured base URL, normalized to the bare `…/v1` root the relative
  /// endpoints append to. Values copied from a tool config may carry the
  /// `/anthropic` suffix or a trailing slash.
  private func configuredBaseURL(in configuration: ProviderRuntimeConfiguration) -> String? {
    guard var base = configuration.credentials[CredentialField.mimoAPIBaseURL]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !base.isEmpty
    else {
      return nil
    }
    while base.hasSuffix("/") { base.removeLast() }
    if base.hasSuffix("/anthropic") {
      base = String(base.dropLast("/anthropic".count)) + "/v1"
    }
    return base
  }

  /// Item name → metric id. The server's names ("month_total_token") already
  /// carry the window cadence, so lowercased words joined by dashes keeps the
  /// id stable and `QuotaWindowKind.classify` readable.
  private func metricID(for name: String) -> String {
    let words = name.lowercased().split { !$0.isLetter && !$0.isNumber }
    return words.isEmpty ? "usage" : words.joined(separator: "-")
  }

  /// Item name → display label. A leading cadence word becomes the adjective
  /// the classifier keys on ("month_total_token" → "Monthly total credits"),
  /// and "token(s)" is renamed to the plan's own unit, Credits.
  private func metricLabel(for name: String) -> String {
    var words = name.lowercased()
      .split { !$0.isLetter && !$0.isNumber }
      .map { $0 == "token" || $0 == "tokens" ? "credits" : String($0) }
    guard !words.isEmpty else { return "Usage" }

    let cadences = [
      "month": "Monthly", "monthly": "Monthly",
      "week": "Weekly", "weekly": "Weekly",
      "day": "Daily", "daily": "Daily",
      "hour": "Hourly", "hourly": "Hourly"
    ]
    if let cadence = cadences[words[0]] {
      words.removeFirst()
      return words.isEmpty ? "\(cadence) quota" : "\(cadence) \(words.joined(separator: " "))"
    }

    let first = words[0]
    let head = first.prefix(1).uppercased() + first.dropFirst()
    return ([head] + words.dropFirst()).joined(separator: " ")
  }

  private func planName(in payload: [String: Any]) -> String? {
    let data = (payload["data"] as? [String: Any]) ?? payload
    for key in ["planName", "plan_name", "plan", "title"] {
      if let name = nonEmptyString(data[key]) { return name }
    }
    return nil
  }

  private func subtitle(plan: String?) -> String {
    plan.map { "Token Plan · \($0)" } ?? "Token Plan"
  }

  /// The subscription period is the plan's own billing cycle, not the calendar
  /// month — no reset is fabricated when the payload names none.
  private func resetDate(in item: [String: Any], fallback: [String: Any], now: Date) -> Date? {
    let keys = ["resetTime", "reset_time", "resetAt", "reset_at", "endTime", "end_time", "expireTime", "expire_at"]
    return firstDateValue(in: item, keys: keys) ?? firstDateValue(in: fallback, keys: keys)
  }

  /// Credit counts run into the billions, so format compactly ("1.6B").
  private func formatCredits(_ value: Double?) -> String? {
    guard let value, value.isFinite else { return nil }
    switch abs(value) {
    case 1_000_000_000...:
      return String(format: "%.1fB", value / 1_000_000_000.0)
    case 1_000_000...:
      return String(format: "%.1fM", value / 1_000_000.0)
    default:
      return formatIntLike(value)
    }
  }
}
