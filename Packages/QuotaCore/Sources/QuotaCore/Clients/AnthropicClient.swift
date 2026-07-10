import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reads Claude (Anthropic) subscription usage via the OAuth usage endpoint that
/// powers Claude Code's `/usage` command.
///
/// The endpoint is aggressively rate limited and *requires* a `claude-code/<version>`
/// User-Agent. LLimit only polls on the user-configured refresh interval (>= 15 min),
/// which stays well inside the documented safe polling window.
public struct AnthropicClient: QuotaProviderClient {
  public let provider: QuotaProvider = .anthropic
  private let httpClient: any HTTPClient

  private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
  // Must look like Claude Code or the endpoint drops us into a hostile rate-limit bucket.
  private static let userAgent = "claude-code/1.0.110"
  private static let oauthBetaHeader = "oauth-2025-04-20"

  public init(httpClient: any HTTPClient) {
    self.httpClient = httpClient
  }

  public func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    guard
      let accessToken = configuration.credentials[CredentialField.anthropicAccessToken],
      !accessToken.isEmpty
    else {
      throw ProviderClientError(kind: .notConfigured, message: "Claude OAuth token is not configured")
    }

    var request = URLRequest(url: Self.usageURL)
    request.httpMethod = "GET"
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue(Self.oauthBetaHeader, forHTTPHeaderField: "anthropic-beta")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

    let (data, response) = try await httpClient.data(for: request)
    guard (200..<300).contains(response.statusCode) else {
      let body = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if response.statusCode == 401 || response.statusCode == 403 {
        throw ProviderClientError(
          kind: .auth,
          message: "Claude authentication failed (\(response.statusCode)). Sign in again with Claude Code.",
          statusCode: response.statusCode
        )
      }
      if response.statusCode == 429 {
        throw ProviderClientError(
          kind: .rateLimit,
          message: "Claude usage endpoint is rate limited. It will recover on the next refresh.",
          statusCode: response.statusCode
        )
      }
      let suffix = body.isEmpty ? "" : ": \(body)"
      throw ProviderClientError(kind: .api, message: "Claude usage API error \(response.statusCode)\(suffix)", statusCode: response.statusCode)
    }

    let payload = try parseJSONObject(from: data)

    var metrics: [UsageMetric] = []
    var maxUsage = 0

    let windows: [(key: String, id: String, label: String)] = [
      ("five_hour", "five_hour", "5-hour limit"),
      ("seven_day", "seven_day", "Weekly limit"),
      ("seven_day_opus", "seven_day_opus", "Weekly (Opus)")
    ]

    for window in windows {
      guard let object = payload[window.key] as? [String: Any] else { continue }
      guard let utilization = parseNumeric(object["utilization"]) else { continue }

      guard let usedPercent = roundedPercent(utilization) else { continue }
      maxUsage = max(maxUsage, usedPercent)

      let resetAt = parseDateValue(object["resets_at"])

      metrics.append(
        UsageMetric(
          id: window.id,
          label: window.label,
          remainingPercent: clampPercent(100 - usedPercent),
          resetAt: resetAt,
          resetIn: resetAt.map { formatResetCountdown(to: $0, now: now) }
        )
      )
    }

    if metrics.isEmpty {
      metrics.append(UsageMetric(id: "empty", label: "No usage data available"))
    }

    return ProviderUsage(
      accountID: configuration.accountID,
      provider: .anthropic,
      title: configuration.displayName,
      subtitle: subtitle(from: payload),
      metrics: metrics,
      maxUsagePercent: maxUsage,
      warning: maxUsage >= 80 ? "High usage" : nil,
      fetchedAt: now
    )
  }

  private func subtitle(from payload: [String: Any]) -> String? {
    guard
      let extra = payload["extra_usage"] as? [String: Any],
      (extra["is_enabled"] as? Bool) == true,
      let used = parseNumeric(extra["used_credits"]),
      used > 0
    else {
      return nil
    }

    if let limit = parseNumeric(extra["monthly_limit"]), limit > 0 {
      return "Extra: $\(formatIntLike(used) ?? "0") / $\(formatIntLike(limit) ?? "0")"
    }
    return "Extra usage on"
  }
}
