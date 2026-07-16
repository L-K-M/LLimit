import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Kimi for Coding (kimi.com/code) subscription quota.
///
/// `GET https://api.kimi.com/coding/v1/usages` with `Authorization: Bearer <key>`,
/// where the key is either an API key from the Kimi Code console or the Kimi
/// CLI's OAuth access token. The response is protobuf-JSON — int64 fields
/// (`limit`, `used`, `remaining`) arrive as strings, and `resetTime` is RFC3339
/// with up to nanosecond fractional seconds:
///
///     {"usage":  {"limit": "2048", "used": "214", "remaining": "1834",
///                 "resetTime": "2026-01-09T15:23:13.716839300Z"},
///      "limits": [{"window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
///                  "detail": {"limit": "200", "used": "139", "remaining": "61",
///                             "resetTime": "2026-01-06T13:33:02.717479433Z"}}]}
///
/// `usage` is the plan quota (the CLI labels it "Weekly limit"); each `limits`
/// entry is a rolling rate window (300 minutes = the 5-hour window). Parsing
/// mirrors the tolerances of kimi-cli's `/usage` command (ui/shell/usage.py):
/// `used` OR `remaining`, alternate reset keys, relative reset seconds, and
/// `name`/`title`/`scope` label overrides.
public struct KimiQuotaClient: QuotaProviderClient {
  public let provider: QuotaProvider = .kimi
  private let endpoint: URL
  private let httpClient: any HTTPClient

  public init(
    endpoint: URL = URL(string: "https://api.kimi.com/coding/v1/usages")!,
    httpClient: any HTTPClient
  ) {
    self.endpoint = endpoint
    self.httpClient = httpClient
  }

  public func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    let apiKey = configuration.credentials[CredentialField.kimiAPIKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !apiKey.isEmpty else {
      throw ProviderClientError(kind: .notConfigured, message: "Kimi API key is not configured")
    }

    var request = URLRequest(url: endpoint)
    request.httpMethod = "GET"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("LLimit/0.1", forHTTPHeaderField: "User-Agent")

    let (data, response) = try await httpClient.data(for: request)
    guard (200..<300).contains(response.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      switch response.statusCode {
      case 401, 403:
        throw ProviderClientError(kind: .auth, message: "Kimi authorization failed (\(response.statusCode)) — check the API key")
      case 404:
        // The endpoint only exists on the Kimi Code platform; Moonshot open
        // platform keys (api.moonshot.ai/.cn) get a 404 here.
        throw ProviderClientError(kind: .api, message: "Kimi usage endpoint not available — use a Kimi for Coding key, not a Moonshot open-platform key")
      case 429:
        throw ProviderClientError(kind: .rateLimit, message: "Kimi API rate limited: \(body)")
      default:
        throw ProviderClientError(kind: .api, message: "Kimi API error \(response.statusCode): \(body)")
      }
    }

    let payload = try parseJSONObject(from: data)

    var metrics: [UsageMetric] = []
    var maxUsagePercent = 0

    if let summary = payload["usage"] as? [String: Any],
       let parsed = metric(from: summary, id: "plan", fallbackLabel: "Weekly limit", now: now) {
      metrics.append(parsed.metric)
      maxUsagePercent = max(maxUsagePercent, parsed.usedPercent)
    }

    if let windows = payload["limits"] as? [[String: Any]] {
      for (index, item) in windows.enumerated() {
        let detail = (item["detail"] as? [String: Any]) ?? item
        let window = (item["window"] as? [String: Any]) ?? [:]
        let label = windowLabel(item: item, detail: detail, window: window, index: index)
        guard let parsed = metric(from: detail, id: "limit-\(index)", fallbackLabel: label, now: now) else {
          continue
        }
        metrics.append(parsed.metric)
        maxUsagePercent = max(maxUsagePercent, parsed.usedPercent)
      }
    }

    if metrics.isEmpty {
      metrics.append(UsageMetric(id: "empty", label: "No quota data available"))
    }

    return ProviderUsage(
      accountID: configuration.accountID,
      provider: .kimi,
      title: configuration.displayName,
      subtitle: "Kimi for Coding",
      metrics: metrics,
      maxUsagePercent: maxUsagePercent,
      warning: maxUsagePercent >= 80 ? "High usage" : nil,
      fetchedAt: now
    )
  }

  private func metric(
    from data: [String: Any],
    id: String,
    fallbackLabel: String,
    now: Date
  ) -> (metric: UsageMetric, usedPercent: Int)? {
    let limit = parseNumeric(data["limit"])
    var used = parseNumeric(data["used"])
    if used == nil, let limit, let remaining = parseNumeric(data["remaining"]) {
      used = limit - remaining
    }
    guard used != nil || limit != nil else { return nil }

    let label = nonEmptyLabel(data["name"]) ?? nonEmptyLabel(data["title"]) ?? fallbackLabel

    var remainingPercent: Int?
    var usedPercent = 0
    if let limit, limit > 0, let used {
      let percent = clampPercent(roundedPercent(100.0 - used / limit * 100.0) ?? 0)
      remainingPercent = percent
      usedPercent = 100 - percent
    }

    let resetAt = resetDate(in: data, now: now)
    let metric = UsageMetric(
      id: id,
      label: label,
      remainingPercent: remainingPercent,
      usedDisplay: formatIntLike(used),
      totalDisplay: formatIntLike(limit),
      resetAt: resetAt,
      resetIn: resetAt.map { formatResetCountdown(to: $0, now: now) }
    )
    return (metric, usedPercent)
  }

  /// Labels follow kimi-cli's rendering, spelled so `QuotaWindowKind.classify`
  /// can parse the window length ("5-hour limit", not "5h limit").
  private func windowLabel(
    item: [String: Any],
    detail: [String: Any],
    window: [String: Any],
    index: Int
  ) -> String {
    for key in ["name", "title", "scope"] {
      if let label = nonEmptyLabel(item[key]) ?? nonEmptyLabel(detail[key]) {
        return label
      }
    }

    let duration = parseNumeric(window["duration"]) ?? parseNumeric(item["duration"]) ?? parseNumeric(detail["duration"])
    let timeUnit = ((window["timeUnit"] ?? item["timeUnit"] ?? detail["timeUnit"]) as? String) ?? ""

    if let duration, duration > 0, let count = roundedInt(duration) {
      if timeUnit.contains("MINUTE") {
        if count >= 60, count % 60 == 0 {
          return "\(count / 60)-hour limit"
        }
        return "\(count)-minute limit"
      }
      if timeUnit.contains("HOUR") {
        return "\(count)-hour limit"
      }
      if timeUnit.contains("DAY") {
        return "\(count)-day limit"
      }
      return "\(count)-second limit"
    }

    return "Limit #\(index + 1)"
  }

  private func resetDate(in data: [String: Any], now: Date) -> Date? {
    for key in ["reset_at", "resetAt", "reset_time", "resetTime"] {
      if let date = parseDateValue(data[key]) {
        return date
      }
    }

    for key in ["reset_in", "resetIn", "ttl"] {
      if let seconds = parseNumeric(data[key]), seconds > 0 {
        return now.addingTimeInterval(seconds)
      }
    }

    return nil
  }

  private func nonEmptyLabel(_ value: Any?) -> String? {
    guard let string = value as? String else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
