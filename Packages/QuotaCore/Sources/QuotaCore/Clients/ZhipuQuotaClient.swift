import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ZhipuQuotaClient: QuotaProviderClient {
  public let provider: QuotaProvider
  private let endpoint: URL
  private let accountLabel: String
  private let httpClient: any HTTPClient

  public init(
    provider: QuotaProvider,
    endpoint: URL,
    accountLabel: String,
    httpClient: any HTTPClient
  ) {
    self.provider = provider
    self.endpoint = endpoint
    self.accountLabel = accountLabel
    self.httpClient = httpClient
  }

  public func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    let credentialKey = provider == .zai ? CredentialField.zaiAPIKey : CredentialField.zhipuAPIKey
    guard let apiKey = configuration.credentials[credentialKey], !apiKey.isEmpty else {
      throw ProviderClientError(kind: .notConfigured, message: "\(provider.displayName) API key is not configured")
    }

    var request = URLRequest(url: endpoint)
    request.httpMethod = "GET"
    request.setValue(apiKey, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("LLimit/0.1", forHTTPHeaderField: "User-Agent")

    let (data, response) = try await httpClient.data(for: request)
    guard (200..<300).contains(response.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      let kind: QuotaErrorKind = response.statusCode == 401 || response.statusCode == 403 ? .auth : .api
      throw ProviderClientError(kind: kind, message: "\(provider.displayName) API error \(response.statusCode): \(body)")
    }

    let payload = try parseJSONObject(from: data)
    guard
      (payload["success"] as? Bool) == true,
      let responseCode = parseNumeric(payload["code"]),
      responseCode == 200
    else {
      let message = payload["msg"] as? String ?? "Unknown response"
      throw ProviderClientError(kind: .api, message: "\(provider.displayName) API returned non-success payload: \(message)")
    }

    guard
      let dataObject = payload["data"] as? [String: Any],
      let limits = dataObject["limits"] as? [[String: Any]]
    else {
      throw ProviderClientError(kind: .decoding, message: "\(provider.displayName) payload missing limits array")
    }

    let providerResetAt = parseResetDate(in: dataObject)

    var metrics: [UsageMetric] = []
    var maxUsagePercent = 0

    for tokenLimit in limits where (tokenLimit["type"] as? String) == "TOKENS_LIMIT" {
      let window = TokenWindow(entry: tokenLimit)
      // Two entries naming the same window keep the first, as this client
      // always has, so a metric id never appears twice.
      guard !metrics.contains(where: { $0.id == window.metricID }) else { continue }

      guard
        let percentage = parseNumeric(tokenLimit["percentage"]),
        let remaining = percentRemaining(fromUsedPercent: percentage)
      else {
        throw ProviderClientError(kind: .decoding, message: "\(provider.displayName) token limit has an invalid percentage")
      }
      maxUsagePercent = max(maxUsagePercent, 100 - remaining)

      let used = firstNumeric(
        in: tokenLimit,
        keys: ["currentValue", "current_value", "used", "usedValue", "used_value"]
      )
      let total = firstNumeric(
        in: tokenLimit,
        keys: ["usage", "total", "limit", "quota", "max", "entitlement", "totalValue", "total_value"]
      )

      let resolvedUsed: Double?
      let resolvedTotal: Double?
      if let used, let total, total > 0 {
        resolvedUsed = min(max(0, used), total)
        resolvedTotal = total
      } else {
        resolvedUsed = percentage
        resolvedTotal = 100
      }

      let usingMillions = (resolvedTotal ?? 0) >= 1_000_000 || (resolvedUsed ?? 0) >= 1_000_000
      let usedDisplay = usingMillions ? formatTokensMillions(resolvedUsed) : formatIntLike(resolvedUsed)
      let totalDisplay = usingMillions ? formatTokensMillions(resolvedTotal) : formatIntLike(resolvedTotal)

      let resetAt = parseResetDate(in: tokenLimit) ?? providerResetAt

      metrics.append(
        UsageMetric(
          id: window.metricID,
          label: window.label(for: provider),
          remainingPercent: remaining,
          usedDisplay: usedDisplay,
          totalDisplay: totalDisplay,
          resetAt: resetAt,
          resetIn: resetAt.map { formatResetCountdown(to: $0, now: now) }
        )
      )
    }

    if let timeLimit = limits.first(where: { ($0["type"] as? String) == "TIME_LIMIT" }) {
      guard
        let percentage = parseNumeric(timeLimit["percentage"]),
        let remaining = percentRemaining(fromUsedPercent: percentage)
      else {
        throw ProviderClientError(kind: .decoding, message: "\(provider.displayName) time limit has an invalid percentage")
      }
      maxUsagePercent = max(maxUsagePercent, 100 - remaining)
      let reset = resolveTimeLimitReset(in: timeLimit, planResetAt: providerResetAt, now: now)

      let used = firstNumeric(
        in: timeLimit,
        keys: ["currentValue", "current_value", "used", "usedValue", "used_value"]
      )
      let total = firstNumeric(
        in: timeLimit,
        keys: ["usage", "total", "limit", "quota", "max", "entitlement", "totalValue", "total_value"]
      )

      metrics.append(
        UsageMetric(
          id: "mcp",
          label: "MCP monthly quota",
          remainingPercent: remaining,
          usedDisplay: formatIntLike(used),
          totalDisplay: formatIntLike(total),
          resetAt: reset.date,
          resetIn: reset.date.map { formatResetCountdown(to: $0, now: now) },
          detail: reset.origin.explanation
        )
      )
    }

    if metrics.isEmpty {
      metrics.append(
        UsageMetric(
          id: "empty",
          label: "No quota data available",
          resetAt: providerResetAt,
          resetIn: providerResetAt.map { formatResetCountdown(to: $0, now: now) }
        )
      )
    }

    return ProviderUsage(
      accountID: configuration.accountID,
      provider: provider,
      title: configuration.displayName,
      subtitle: accountLabel,
      metrics: metrics,
      maxUsagePercent: maxUsagePercent,
      warning: maxUsagePercent >= 80 ? "High usage" : nil,
      fetchedAt: now
    )
  }

  /// Which window one `TOKENS_LIMIT` entry measures. The GLM Coding Plan sends
  /// one entry per token cap and tells them apart only by `unit` and `number`:
  /// (3, 5) is the 5-hour window and (6, 1) the weekly one, as observed by
  /// third-party monitors (netspeedy/zquota); Z.ai documents neither code.
  /// History and colors key on the metric id, so the 5-hour window keeps the
  /// `tokens` id it has always had.
  private enum TokenWindow {
    /// No numeric `unit`: the single-entry shape this client was written for.
    /// It keeps its original id and per-host label.
    case unannotated
    case fiveHour
    case weekly
    /// A code pair with no known meaning. It gets a neutral id and label,
    /// never a guessed cadence.
    case unrecognized(unit: String, number: String?)

    init(entry: [String: Any]) {
      guard let unitValue = parseNumeric(entry["unit"]), let unit = formatIntLike(unitValue) else {
        self = .unannotated
        return
      }

      let number = parseNumeric(entry["number"])
      switch (unitValue, number) {
      case (3, 5?):
        self = .fiveHour
      case (6, 1?):
        self = .weekly
      default:
        self = .unrecognized(unit: unit, number: formatIntLike(number))
      }
    }

    var metricID: String {
      switch self {
      case .unannotated, .fiveHour:
        return "tokens"
      case .weekly:
        return "tokens-weekly"
      case let .unrecognized(unit, number):
        return "tokens-u\(unit)" + (number.map { "-n\($0)" } ?? "")
      }
    }

    /// Labels `QuotaWindowKind.classify` can parse. The neutral label names no
    /// cadence, so an unknown window classifies as `.other`.
    func label(for provider: QuotaProvider) -> String {
      switch self {
      case .unannotated:
        // Z.ai's single entry never named its duration; `classify` still maps
        // the bare `tokens` id to the session window.
        return provider == .zhipu ? "5-hour token limit" : "Token limit"
      case .fiveHour:
        return "5-hour token limit"
      case .weekly:
        return "Weekly token limit"
      case let .unrecognized(unit, number):
        return "Token limit (unit \(unit)" + (number.map { ", number \($0)" } ?? "") + ")"
      }
    }
  }

  /// Where the MCP quota's reset date came from. The menu dropdown prints the
  /// matching sentence, so a countdown LLimit inferred is never mistaken for
  /// one the provider actually sent.
  private enum TimeLimitResetOrigin {
    /// The `TIME_LIMIT` entry carried its own reset date.
    case reported
    /// The entry carried none, so the plan's renewal date stands in. This is
    /// the common case, and it is why the countdown rarely lands on the 1st.
    case planRenewal
    /// Neither was present, so the date below is LLimit's assumption.
    case assumedCalendarMonth
    /// Neither was present and the calendar could not produce a fallback.
    case unknown

    /// Kept to two short lines: `MetricQuotaRow` truncates the detail text.
    var explanation: String {
      switch self {
      case .reported:
        return "A separate allowance from the token window, with its own reset."
      case .planRenewal:
        return "A separate allowance from the token window. Resets when your plan period renews, not on the 1st."
      case .assumedCalendarMonth:
        return "A separate allowance from the token window. No reset date was reported, so the 1st of next month is assumed."
      case .unknown:
        return "A separate allowance from the token window. The provider reported no reset date."
      }
    }
  }

  private func resolveTimeLimitReset(
    in timeLimit: [String: Any],
    planResetAt: Date?,
    now: Date
  ) -> (date: Date?, origin: TimeLimitResetOrigin) {
    if let reported = parseResetDate(in: timeLimit) {
      return (reported, .reported)
    }

    if let planResetAt {
      return (planResetAt, .planRenewal)
    }

    guard let assumed = startOfNextMonth(from: now) else {
      return (nil, .unknown)
    }
    return (assumed, .assumedCalendarMonth)
  }

  private func parseResetDate(in object: [String: Any]) -> Date? {
    firstDateValue(in: object, keys: Self.resetDateKeys)
  }

  private static let resetDateKeys = [
    "nextResetTime",
    "next_reset_time",
    "nextResetAt",
    "next_reset_at",
    "resetTime",
    "reset_time",
    "resetAt",
    "reset_at",
    "quotaResetDate",
    "quota_reset_date"
  ]
}
