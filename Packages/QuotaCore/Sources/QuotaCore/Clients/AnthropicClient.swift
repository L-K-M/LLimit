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
          message: "Claude authentication failed (\(response.statusCode)). Reconnect this account or import its credentials again.",
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

    for window in Self.usageWindows(in: payload) {
      guard let object = payload[window.key] as? [String: Any] else { continue }
      guard let utilization = parseNumeric(object["utilization"]) else { continue }

      guard let usedPercent = roundedPercent(utilization) else { continue }
      maxUsage = max(maxUsage, usedPercent)

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

    // Extra usage is real data, so it stands in for the no-data placeholder.
    let extraUsage = Self.extraUsageMetric(from: payload)
    if metrics.isEmpty && extraUsage == nil {
      metrics.append(UsageMetric(id: "empty", label: "No usage data available"))
    }

    // Appended after every window, so it never shifts a window's color slot.
    if let extraUsage {
      metrics.append(extraUsage)
    }

    return ProviderUsage(
      accountID: configuration.accountID,
      provider: .anthropic,
      title: configuration.displayName,
      metrics: metrics,
      maxUsagePercent: maxUsage,
      warning: maxUsage >= 80 ? "High usage" : nil,
      fetchedAt: now
    )
  }

  /// The established windows first, in their original order: their ids key
  /// history and colors. Then any other `five_hour_*` / `seven_day_*` window
  /// the endpoint adds (`seven_day_sonnet_max`, ...), sorted by key so the
  /// order is stable. Each label names its cadence, so
  /// `QuotaWindowKind.classify` treats it like the account-wide window of the
  /// same length.
  private static func usageWindows(in payload: [String: Any]) -> [(key: String, label: String)] {
    let knownKeys = Set(knownWindows.map(\.key))
    let additional = payload.keys.sorted().compactMap { key -> (key: String, label: String)? in
      guard !knownKeys.contains(key) else { return nil }
      guard let cadence = windowCadences.first(where: { key.hasPrefix($0.prefix) }) else { return nil }

      let scope = String(key.dropFirst(cadence.prefix.count))
      guard !scope.isEmpty else { return nil }
      return (key, "\(cadence.name) (\(scopeName(scope)))")
    }
    return knownWindows + additional
  }

  private static let knownWindows: [(key: String, label: String)] = [
    ("five_hour", "5-hour limit"),
    ("seven_day", "Weekly limit"),
    ("seven_day_opus", "Weekly (Opus)"),
    ("seven_day_sonnet", "Weekly (Sonnet)")
  ]

  private static let windowCadences: [(prefix: String, name: String)] = [
    ("five_hour_", "5-hour"),
    ("seven_day_", "Weekly")
  ]

  /// `oauth_apps` caps third-party apps, not a model, so it gets a spelled-out
  /// name; model scopes read as words ("sonnet_max" -> "Sonnet Max").
  private static func scopeName(_ scope: String) -> String {
    if scope == "oauth_apps" {
      return "OAuth apps"
    }
    return scope
      .split(separator: "_")
      .map { $0.prefix(1).uppercased() + $0.dropFirst() }
      .joined(separator: " ")
  }

  /// Pay-as-you-go spend beyond the plan windows, as an amount-only metric: no
  /// percentage, reset, or cadence, so it never takes a ring, the primary
  /// color, the headline percentage, or the warning. Keep the label free of
  /// cadence words: a "monthly" label would classify as a window and could
  /// take the primary color. Amounts are minor units of `currency` (cents
  /// for USD).
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
    // Claude reportedly switches extra usage off once the monthly cap is
    // spent, which is exactly when the cap matters, so a reached cap shows
    // even when disabled.
    guard (extra["is_enabled"] as? Bool) == true || isCapReached else { return nil }

    // Responses without `currency` are treated as USD, the only currency the
    // amounts have been observed in.
    let currency = nonEmptyString(extra["currency"])?.uppercased() ?? usDollarCurrencyCode
    let usedDisplay: String
    let totalDisplay: String?
    if currency == usDollarCurrencyCode {
      usedDisplay = dollars(fromCents: used)
      totalDisplay = limit.map(dollars(fromCents:))
    } else {
      // Other currencies differ in minor units and symbol, so show the state
      // rather than an amount that may be off by orders of magnitude.
      usedDisplay = isCapReached ? "Cap reached" : "On"
      totalDisplay = nil
    }

    return UsageMetric(
      id: "extra_usage",
      label: "Extra usage",
      usedDisplay: usedDisplay,
      totalDisplay: totalDisplay,
      detail: isCapReached ? "Monthly spending cap reached." : nil
    )
  }

  private static let usDollarCurrencyCode = "USD"
  private static let centsPerDollar = 100.0

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
