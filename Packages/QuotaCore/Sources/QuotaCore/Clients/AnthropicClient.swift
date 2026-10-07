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
  private let claudeVersion: @Sendable () -> String?

  private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
  // Must look like Claude Code or the endpoint drops us into a hostile
  // rate-limit bucket. Track the installed CLI's version so the UA doesn't
  // drift stale as Claude Code updates; the constant is the no-CLI fallback.
  private static let fallbackVersion = "1.0.110"
  // Computed per request: ClaudeCodeVersion.current() probes in the
  // background and returns nil until it lands, so the first requests after
  // launch use the fallback and later ones pick up the real version.
  private var userAgent: String {
    "claude-code/\(claudeVersion() ?? Self.fallbackVersion)"
  }
  private static let oauthBetaHeader = "oauth-2025-04-20"

  public init(httpClient: any HTTPClient) {
    self.init(httpClient: httpClient, claudeVersion: { ClaudeCodeVersion.current() })
  }

  init(httpClient: any HTTPClient, claudeVersion: @escaping @Sendable () -> String?) {
    self.httpClient = httpClient
    self.claudeVersion = claudeVersion
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
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

    let (data, response) = try await httpClient.data(for: request)
    guard (200..<300).contains(response.statusCode) else {
      if response.statusCode == 401 || response.statusCode == 403 {
        throw ProviderClientError(
          kind: .auth,
          message: "Claude authentication failed (\(response.statusCode)). Reconnect this account or import its credentials again.",
          statusCode: response.statusCode
        )
      }
      if response.statusCode == 429 {
        let retryAfter = parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: now)
        let guidance = retryAfter.map {
          "Next attempt in about \(formatShortDuration(seconds: Int($0.rounded(.up))))."
        } ?? "Try again on the next refresh."
        throw ProviderClientError(
          kind: .rateLimit,
          message: "Claude usage endpoint is rate limited. \(guidance)",
          statusCode: response.statusCode,
          retryAfter: retryAfter
        )
      }
      throw ProviderClientError(kind: .api, message: "Claude usage API failed (HTTP \(response.statusCode)). Try again later.", statusCode: response.statusCode)
    }

    let payload = try parseJSONObject(from: data)

    var metrics: [UsageMetric] = []
    var maxUsage: Int?
    var unreadableWindows = 0

    for window in Self.usageWindows(in: payload) {
      // Null means an unavailable window, not schema drift.
      guard let rawWindow = payload[window.key], !(rawWindow is NSNull) else { continue }
      guard let object = rawWindow as? [String: Any] else {
        unreadableWindows += 1
        continue
      }
      if object["utilization"] is NSNull { continue }
      guard let utilization = parseNumeric(object["utilization"]),
            let usedPercent = roundedPercent(utilization) else {
        unreadableWindows += 1
        continue
      }
      maxUsage = max(maxUsage ?? 0, usedPercent)

      let resetAt = parseDateValue(object["resets_at"])

      metrics.append(
        UsageMetric(
          id: window.key,
          label: window.label,
          remainingPercent: clampPercent(100 - usedPercent),
          resetAt: resetAt,
          resetIn: resetAt.map { formatResetCountdown(to: $0, now: now) }
        )
      )
    }

    // All unreadable windows are a failed refresh; readable windows survive
    // partial drift. Spend alone cannot hide the loss of bounded quota.
    if metrics.isEmpty, unreadableWindows > 0 {
      throw ProviderClientError(kind: .decoding, message: "Claude usage response had no readable quota windows. Try again later.")
    }

    let extraUsage = Self.extraUsageMetric(from: payload)
    if metrics.isEmpty, extraUsage == nil {
      metrics.append(UsageMetric(id: "empty", label: "No usage data available"))
    }
    if let extraUsage { metrics.append(extraUsage) }

    return ProviderUsage(
      accountID: configuration.accountID,
      provider: .anthropic,
      title: configuration.displayName,
      metrics: metrics,
      maxUsagePercent: maxUsage,
      warning: (maxUsage ?? 0) >= 80 ? "High usage" : nil,
      fetchedAt: now
    )
  }

  // Established windows retain their order and ids for history and colors.
  private static let knownWindows: [(key: String, label: String)] = [
    ("five_hour", "5-hour limit"),
    ("seven_day", "Weekly limit"),
    ("seven_day_opus", "Weekly (Opus)"),
    ("seven_day_sonnet", "Weekly (Sonnet)")
  ]
  private static let windowCadences: [(prefix: String, name: String)] = [
    ("five_hour_", "5-hour"), ("seven_day_", "Weekly")
  ]

  private static func usageWindows(in payload: [String: Any]) -> [(key: String, label: String)] {
    let knownKeys = Set(knownWindows.map(\.key))
    let additional = payload.keys.sorted().compactMap { key -> (key: String, label: String)? in
      guard !knownKeys.contains(key),
            let cadence = windowCadences.first(where: { key.hasPrefix($0.prefix) }) else { return nil }
      let scope = String(key.dropFirst(cadence.prefix.count))
      guard !scope.isEmpty else { return nil }
      return (key, "\(cadence.name) (\(scopeName(scope)))")
    }
    return knownWindows + additional
  }

  private static func scopeName(_ scope: String) -> String {
    if scope == "oauth_apps" { return "OAuth apps" }
    return scope.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
  }

  private static let usDollarCurrencyCode = "USD"
  private static let centsPerDollar = 100.0

  /// Amount-only spend stays outside rings, quota warnings, and primary colors.
  private static func extraUsageMetric(from payload: [String: Any]) -> UsageMetric? {
    guard
      let extra = payload["extra_usage"] as? [String: Any],
      let used = parseNumeric(extra["used_credits"]),
      used > 0
    else {
      return nil
    }

    let limit = parseNumeric(extra["monthly_limit"]).flatMap { $0 > 0 ? $0 : nil }
    let isCapReached = limit.map { used >= $0 } ?? false
    // Claude can disable extra usage at the cap; keep that spend visible.
    guard (extra["is_enabled"] as? Bool) == true || isCapReached else { return nil }

    let currency = nonEmptyString(extra["currency"])?.uppercased() ?? usDollarCurrencyCode
    let usedDisplay = currency == usDollarCurrencyCode ? dollars(fromCents: used) : (isCapReached ? "Cap reached" : "On")
    let totalDisplay = currency == usDollarCurrencyCode ? limit.map(dollars(fromCents:)) : nil
    return UsageMetric(id: "extra_usage", label: "Extra usage", usedDisplay: usedDisplay, totalDisplay: totalDisplay,
                       detail: isCapReached ? "Monthly spending cap reached." : nil)
  }

  private static func dollars(fromCents cents: Double) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    let amount = cents / centsPerDollar
    return "$" + (formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f", amount))
  }
}
