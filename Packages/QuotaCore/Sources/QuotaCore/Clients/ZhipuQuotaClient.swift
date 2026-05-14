import Foundation

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
    guard (payload["success"] as? Bool) == true, Int(parseNumeric(payload["code"]) ?? -1) == 200 else {
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

    if let tokenLimit = limits.first(where: { ($0["type"] as? String) == "TOKENS_LIMIT" }) {
      let percentage = parseNumeric(tokenLimit["percentage"]) ?? 0
      let remaining = percentRemaining(fromUsedPercent: percentage)
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
          id: "tokens",
          label: provider == .zhipu ? "5-hour token limit" : "Token limit",
          remainingPercent: remaining,
          usedDisplay: usedDisplay,
          totalDisplay: totalDisplay,
          resetAt: resetAt,
          resetIn: resetAt.map { formatResetCountdown(to: $0, now: now) }
        )
      )
    }

    if let timeLimit = limits.first(where: { ($0["type"] as? String) == "TIME_LIMIT" }) {
      let percentage = parseNumeric(timeLimit["percentage"]) ?? 0
      let remaining = percentRemaining(fromUsedPercent: percentage)
      maxUsagePercent = max(maxUsagePercent, 100 - remaining)
      let resetAt = parseResetDate(in: timeLimit) ?? providerResetAt ?? startOfNextMonth(from: now)

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
          resetAt: resetAt,
          resetIn: resetAt.map { formatResetCountdown(to: $0, now: now) }
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

  private func parseResetDate(in object: [String: Any]) -> Date? {
    for key in Self.resetDateKeys {
      if let date = parseDateValue(object[key]) {
        return date
      }
    }

    return nil
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
