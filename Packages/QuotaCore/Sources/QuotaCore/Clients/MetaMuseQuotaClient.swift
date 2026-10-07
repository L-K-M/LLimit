import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Meta Muse (Muse Code) subscription quota.
///
/// Muse Code has no standalone usage endpoint — `POST /muse-code/key` is the
/// login-time key mint and the only other place the snapshot appears — so the
/// subscription numbers the CLI's `/usage` panel renders arrive inside the
/// model stream itself: every `/v1/responses` SSE stream carries a
/// `response.subscription_usage` event with the account's snapshot:
///
///     {"window": {"used_percent": 12.5, "window_duration_mins": 300,
///                 "resets_at": "2026-09-15T02:00:00Z"},
///      "weekly": {"used_percent": 34.0, "resets_at": "2026-09-21T00:00:00Z"}}
///
/// One minimal streaming call therefore doubles as the quota read. It is not
/// free — it counts as one request plus a handful of tokens against the
/// account's quota — which is why the probe uses the cheap contributor-tier
/// model and caps output. `used_percent` is used-not-remaining; it is
/// inverted. Accounts without a subscription (pay-as-you-go keys) get no such
/// event and report a placeholder metric.
///
/// `x-api-version` and the `muse-build` user agent mirror the CLI's own calls:
/// the frame is an undocumented surface, so the request speaks the protocol
/// exactly as Muse Code 1.2.x does.
public struct MetaMuseQuotaClient: QuotaProviderClient {
  public let provider: QuotaProvider = .metaMuse
  public static let defaultEndpoint = URL(string: "https://api.meta.ai/v1/responses")!
  /// The catalog-default contributor-tier model: the cheapest probe the API
  /// accepts. Contributor tier means Meta may train on the "ping" content.
  private static let probeModel = "muse-spark-1.3-contributor"

  private enum EventType: String {
    case subscriptionUsage = "response.subscription_usage"
    case completed = "response.completed"
    case incomplete = "response.incomplete"
    case failed = "response.failed"
    case error
  }

  private struct SubscriptionSnapshot {
    let window: (fields: [String: Any], usedPercent: Double)?
    let weekly: (fields: [String: Any], usedPercent: Double)?
  }

  private let endpoint: URL
  private let httpClient: any HTTPClient

  public init(endpoint: URL = MetaMuseQuotaClient.defaultEndpoint, httpClient: any HTTPClient) {
    self.endpoint = endpoint
    self.httpClient = httpClient
  }

  public func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    let apiKey = configuration.credentials[CredentialField.metaMuseAPIKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !apiKey.isEmpty else {
      throw ProviderClientError(kind: .notConfigured, message: "Meta API key is not configured")
    }

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("1.0.0", forHTTPHeaderField: "x-api-version")
    request.setValue("muse-build/1.2.1", forHTTPHeaderField: "User-Agent")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "model": Self.probeModel,
      "input": "ping",
      "stream": true,
      "store": false,
      "max_output_tokens": 16,
      "reasoning": ["effort": "minimal"]
    ])

    let (data, response) = try await httpClient.data(for: request)
    guard (200..<300).contains(response.statusCode) else {
      switch response.statusCode {
      case 401, 403:
        throw ProviderClientError(kind: .auth, message: "Meta authorization failed (\(response.statusCode)) — check the API key or run `muse login` again")
      case 429:
        throw ProviderClientError(kind: .rateLimit, message: "Meta API is rate limiting requests. Try again later.", statusCode: response.statusCode)
      default:
        throw ProviderClientError(kind: .api, message: "Meta API unavailable (HTTP \(response.statusCode)). Try again later.", statusCode: response.statusCode)
      }
    }

    let body = String(data: data, encoding: .utf8) ?? ""
    let parsed = try subscriptionUsageSnapshot(in: body)
    let snapshot = parsed.snapshot

    var metrics: [UsageMetric] = []

    if let window = snapshot?.window {
      let resetAt = parseDateValue(window.fields["resets_at"])
      let durationMins = parseNumeric(window.fields["window_duration_mins"]).flatMap(roundedInt)
      metrics.append(
        UsageMetric(
          id: "window",
          label: windowLabel(durationMins: durationMins),
          remainingPercent: percentRemaining(fromUsedPercent: window.usedPercent),
          resetAt: resetAt,
          resetIn: resetAt.map { formatResetCountdown(to: $0, now: now) },
          windowSeconds: durationMins.flatMap { reportedWindowSeconds(count: $0, unitSeconds: 60) }
        )
      )
    }

    if let weekly = snapshot?.weekly {
      let resetAt = parseDateValue(weekly.fields["resets_at"])
      metrics.append(
        UsageMetric(
          id: "weekly",
          label: "Weekly limit",
          remainingPercent: percentRemaining(fromUsedPercent: weekly.usedPercent),
          resetAt: resetAt,
          resetIn: resetAt.map { formatResetCountdown(to: $0, now: now) }
        )
      )
    }

    if metrics.isEmpty {
      // A present snapshot must report a window. Only a completed response
      // without a snapshot establishes a pay-as-you-go result.
      guard parsed.sawCompletedResponse else {
        // Failed streams can contain credentials or generated text; publish only recovery advice.
        let detail = parsed.streamError ?? apiErrorMessage(in: data)
        throw ProviderClientError(
          kind: .api,
          message: detail == nil
            ? "Meta API response contained no recognizable usage payload. Try again later."
            : "Meta API request failed. Check the API key or try again later."
        )
      }
      metrics.append(UsageMetric(id: "empty", label: "Pay-as-you-go — no subscription quota"))
    }

    let maxUsagePercent = metrics.compactMap(\.remainingPercent).map { 100 - $0 }.max() ?? 0
    let warning: String? = maxUsagePercent >= 100 ? "Quota exhausted" : (maxUsagePercent >= 80 ? "High usage" : nil)

    return ProviderUsage(
      accountID: configuration.accountID,
      provider: .metaMuse,
      title: configuration.displayName,
      subtitle: nil,
      metrics: metrics,
      maxUsagePercent: maxUsagePercent,
      warning: warning,
      fetchedAt: now
    )
  }

  /// "300-minute" windows report their length in minutes; a label that spells
  /// the duration out is what `QuotaWindowKind.classify` reads, so emit the
  /// same "N-hour"/"N-minute" phrasing other providers use.
  private func windowLabel(durationMins: Int?) -> String {
    guard let mins = durationMins, mins > 0 else { return "Session window" }
    if mins % 60 == 0 { return "\(mins / 60)-hour limit" }
    return "\(mins)-minute limit"
  }

  private func subscriptionWindow(in snapshot: [String: Any]?, key: String) throws -> (
    fields: [String: Any], usedPercent: Double
  )? {
    guard let value = snapshot?[key] else { return nil }
    guard let fields = value as? [String: Any] else { throw invalidSubscriptionSnapshot }

    // Numeric strings are supported, but a partial parse such as "1e1000"
    // must not turn an invalid percentage into a small finite reading.
    let usedPercent: Double?
    if let string = fields["used_percent"] as? String {
      usedPercent = Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
    } else {
      usedPercent = parseNumeric(fields["used_percent"])
    }
    guard let usedPercent, usedPercent.isFinite else { throw invalidSubscriptionSnapshot }

    return (fields, usedPercent)
  }

  private func decodeSubscriptionSnapshot(_ fields: [String: Any]) throws -> SubscriptionSnapshot {
    let window = try subscriptionWindow(in: fields, key: "window")
    let weekly = try subscriptionWindow(in: fields, key: "weekly")
    guard window != nil || weekly != nil else { throw invalidSubscriptionSnapshot }

    return SubscriptionSnapshot(window: window, weekly: weekly)
  }

  private var invalidSubscriptionSnapshot: ProviderClientError {
    ProviderClientError(kind: .decoding, message: "Meta returned incomplete or invalid subscription usage data")
  }

  /// Pulls the SubscriptionUsageSnapshot out of an SSE body. The dedicated
  /// `response.subscription_usage` event is checked first; the same snapshot
  /// can also ride inside the `response` object of a terminal event. If the
  /// body isn't SSE at all (server ignored `stream`), it is tried as a plain
  /// JSON response. `sawCompletedResponse` distinguishes a completed response
  /// without a subscription snapshot from an unrecognized or unfinished body.
  /// A dedicated subscription event or snapshot field is never absence.
  /// `streamError` identifies a failed stream; its raw explanation stays transient.
  private func subscriptionUsageSnapshot(in body: String) throws -> (
    snapshot: SubscriptionSnapshot?,
    sawCompletedResponse: Bool,
    streamError: String?
  ) {
    var snapshot: SubscriptionSnapshot?
    var sawCompletedResponse = false

    // SSE permits CRLF line endings; normalize or multi-event bodies stay one
    // unsplittable block and their concatenated data: lines fail JSON parsing.
    for block in body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n") {
      var eventName: String?
      var dataLines: [String] = []
      for line in block.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("event:") {
          eventName = trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces)
        } else if trimmed.hasPrefix("data:") {
          dataLines.append(String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        }
      }
      guard !dataLines.isEmpty else {
        if eventName == EventType.subscriptionUsage.rawValue { throw invalidSubscriptionSnapshot }
        continue
      }
      let joined = dataLines.joined(separator: "\n")
      guard joined != "[DONE]" else {
        if eventName == EventType.subscriptionUsage.rawValue { throw invalidSubscriptionSnapshot }
        continue
      }
      guard
        let object = try? JSONSerialization.jsonObject(with: Data(joined.utf8)) as? [String: Any]
      else {
        if eventName == EventType.subscriptionUsage.rawValue { throw invalidSubscriptionSnapshot }
        continue
      }

      // Terminal errors fail the refresh even after a valid quota snapshot;
      // the caller's stale merge preserves the last-good usage.
      let rawType = eventName ?? (object["type"] as? String)
      let type = rawType.flatMap(EventType.init(rawValue:))
      if type == .error || type == .failed || object["error"] is [String: Any] {
        return (nil, false, streamErrorMessage(in: object) ?? rawType)
      }

      // Keep the first reading, but validate later snapshots before success.
      if type == .subscriptionUsage {
        let candidate = try decodeSubscriptionSnapshot(try snapshotDict(in: object) ?? object)
        snapshot = snapshot ?? candidate
        continue
      }
      if (type == .completed || type == .incomplete),
         let responseObject = object["response"] as? [String: Any] {
        if let fields = try snapshotDict(in: responseObject) {
          let candidate = try decodeSubscriptionSnapshot(fields)
          snapshot = snapshot ?? candidate
        }
      }
      if isCompletedResponse(object, type: rawType) {
        sawCompletedResponse = true
      }
    }

    guard
      let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
    else { return (snapshot, sawCompletedResponse, nil) }
    let rawType = object["type"] as? String
    let type = rawType.flatMap(EventType.init(rawValue:))
    if type == .error || type == .failed || object["error"] is [String: Any] {
      return (nil, false, streamErrorMessage(in: object) ?? object["type"] as? String)
    }
    if let fields = try snapshotDict(in: object) {
      return (try decodeSubscriptionSnapshot(fields), false, nil)
    }
    if let responseObject = object["response"] as? [String: Any],
       let fields = try snapshotDict(in: responseObject) {
      return (try decodeSubscriptionSnapshot(fields), false, nil)
    }
    if type == .subscriptionUsage { throw invalidSubscriptionSnapshot }

    return (snapshot, sawCompletedResponse || isCompletedResponse(object, type: rawType), nil)
  }

  private func isCompletedResponse(_ object: [String: Any], type: String?) -> Bool {
    let response: [String: Any]
    if type == EventType.completed.rawValue, let nested = object["response"] as? [String: Any] {
      response = nested
    } else if type == nil, object["status"] as? String == "completed" {
      response = object
    } else {
      return false
    }
    guard nonEmptyString(response["id"]) != nil else { return false }

    return response["status"] == nil || response["status"] as? String == "completed"
  }

  /// Reads the human explanation out of a stream error event or error
  /// envelope: `error.message`, the `response.error.message` a
  /// `response.failed` event nests it under, then flat fields.
  private func streamErrorMessage(in object: [String: Any]) -> String? {
    if let error = object["error"] as? [String: Any], let message = nonEmptyString(error["message"]) {
      return message
    }
    if let response = object["response"] as? [String: Any],
       let error = response["error"] as? [String: Any],
       let message = nonEmptyString(error["message"]) {
      return message
    }
    return nonEmptyString(object["message"]) ?? nonEmptyString(object["detail"]) ?? nonEmptyString(object["title"])
  }

  /// The snapshot's nesting varies with where it was carried: the dedicated
  /// event may put it at top level or under `subscription_usage`, and the
  /// terminal event nests it inside `response`.
  private func snapshotDict(in object: [String: Any]) throws -> [String: Any]? {
    if object["window"] != nil || object["weekly"] != nil {
      return object
    }
    for key in ["subscription_usage", "snapshot"] {
      guard let value = object[key] else { continue }
      guard let nested = value as? [String: Any] else { throw invalidSubscriptionSnapshot }
      return nested
    }
    return nil
  }

  /// Errors come back in either envelope: the Model API's OpenAI-style
  /// `error.message` or the muse-code service's problem+json `detail`/`title`.
  private func apiErrorMessage(in data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    if let error = object["error"] as? [String: Any], let message = nonEmptyString(error["message"]) {
      return message
    }
    return nonEmptyString(object["detail"]) ?? nonEmptyString(object["title"]) ?? nonEmptyString(object["message"])
  }
}
