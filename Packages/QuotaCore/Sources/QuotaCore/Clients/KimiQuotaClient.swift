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
///
/// Metric ids carry the window cadence ("plan-weekly", "window-5-hour") so the
/// widget's trend history stays keyed to the window itself — not the server's
/// array order — and `QuotaWindowKind.classify` keeps the right identity color
/// even when a server-sent label override replaces the parseable default.
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
      switch response.statusCode {
      case 401, 403:
        throw ProviderClientError(kind: .auth, message: "Kimi authorization failed (\(response.statusCode)) — check the API key")
      case 404:
        // The endpoint only exists on the Kimi Code platform; Moonshot open
        // platform keys (api.moonshot.ai/.cn) get a 404 here. A transient
        // routing 404 looks identical, so hint rather than assert.
        throw ProviderClientError(kind: .api, message: "Kimi usage endpoint not found (404) — if this persists, check that the key is a Kimi for Coding key; Moonshot open-platform keys are not accepted")
      case 429:
        let body = String(data: data, encoding: .utf8) ?? ""
        throw ProviderClientError(kind: .rateLimit, message: "Kimi API rate limited: \(body)")
      default:
        let body = String(data: data, encoding: .utf8) ?? ""
        throw ProviderClientError(kind: .api, message: "Kimi API error \(response.statusCode): \(body)")
      }
    }

    let payload = try parseJSONObject(from: data)

    var metrics: [UsageMetric] = []

    if let summary = payload["usage"] as? [String: Any] {
      let label = nonEmptyString(summary["name"]) ?? nonEmptyString(summary["title"]) ?? "Weekly limit"
      if let metric = metric(from: summary, id: "plan-weekly", label: label, now: now) {
        metrics.append(metric)
      }
    }

    if let windows = payload["limits"] as? [[String: Any]] {
      for (index, item) in windows.enumerated() {
        let detail = (item["detail"] as? [String: Any]) ?? item
        let window = (item["window"] as? [String: Any]) ?? [:]
        let descriptor = windowDescriptor(item: item, detail: detail, window: window, index: index)
        if let metric = metric(from: detail, id: descriptor.id, label: descriptor.label, now: now) {
          metrics.append(metric)
        }
      }
    }

    let maxUsagePercent = metrics.map { 100 - ($0.remainingPercent ?? 100) }.max() ?? 0

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

  private func metric(from data: [String: Any], id: String, label: String, now: Date) -> UsageMetric? {
    let limit = parseNumeric(data["limit"])
    var used = parseNumeric(data["used"])
    if used == nil, let limit, let remaining = parseNumeric(data["remaining"]) {
      // remaining can exceed limit (top-up quota, plan changes); don't show
      // a negative usage for it.
      used = max(0, limit - remaining)
    }
    guard used != nil || limit != nil else { return nil }

    var remainingPercent: Int?
    if let limit, limit > 0, let used {
      remainingPercent = percentRemaining(fromUsedPercent: used / limit * 100.0)
    }

    let resetAt = resetDate(in: data, now: now)
    return UsageMetric(
      id: id,
      label: label,
      remainingPercent: remainingPercent,
      usedDisplay: formatIntLike(used),
      totalDisplay: formatIntLike(limit),
      resetAt: resetAt,
      resetIn: resetAt.map { formatResetCountdown(to: $0, now: now) }
    )
  }

  /// The window's stable id (duration-based, immune to `limits[]` reordering)
  /// and display label. Labels follow kimi-cli's rendering but are spelled so
  /// `QuotaWindowKind.classify` can parse the window length ("5-hour limit",
  /// not "5h limit"); server-sent name/title/scope overrides replace the label
  /// only — the id keeps carrying the cadence for classification and history.
  private func windowDescriptor(
    item: [String: Any],
    detail: [String: Any],
    window: [String: Any],
    index: Int
  ) -> (id: String, label: String) {
    var override: String?
    for key in ["name", "title", "scope"] {
      if let label = nonEmptyString(item[key]) ?? nonEmptyString(detail[key]) {
        override = label
        break
      }
    }

    // kimi-cli checks all three locations for the window length (usage.py
    // _limit_label): window first, then the item, then its detail.
    let duration = parseNumeric(window["duration"]) ?? parseNumeric(item["duration"]) ?? parseNumeric(detail["duration"])
    let timeUnit = nonEmptyString(window["timeUnit"]) ?? nonEmptyString(item["timeUnit"]) ?? nonEmptyString(detail["timeUnit"]) ?? ""

    guard
      let duration, duration > 0, let rawCount = roundedInt(duration),
      let unit = windowUnit(count: rawCount, timeUnit: timeUnit)
    else {
      return (id: "limit-\(index)", label: override ?? "Limit #\(index + 1)")
    }

    let cadence = "\(unit.count)-\(unit.name)"
    return (id: "window-\(cadence)", label: override ?? "\(cadence) limit")
  }

  /// Normalizes a protobuf `TIME_UNIT_*` window to a classifier-friendly unit
  /// word, folding whole-hour minute counts (300 minutes → 5 hours) the way
  /// kimi-cli renders them. Unknown units return nil rather than fabricating
  /// a cadence the payload never stated.
  private func windowUnit(count: Int, timeUnit: String) -> (count: Int, name: String)? {
    if timeUnit.contains("MINUTE") {
      if count >= 60, count % 60 == 0 {
        return (count / 60, "hour")
      }
      return (count, "minute")
    }
    if timeUnit.contains("HOUR") {
      return (count, "hour")
    }
    if timeUnit.contains("DAY") {
      return (count, "day")
    }
    if timeUnit.contains("WEEK") {
      return (count, "week")
    }
    if timeUnit.contains("MONTH") {
      return (count, "month")
    }
    return nil
  }

  private func resetDate(in data: [String: Any], now: Date) -> Date? {
    if let date = firstDateValue(in: data, keys: ["reset_at", "resetAt", "reset_time", "resetTime"]) {
      return date
    }

    if let seconds = firstNumeric(in: data, keys: ["reset_in", "resetIn", "ttl"]), seconds > 0 {
      return now.addingTimeInterval(seconds)
    }

    return nil
  }
}
