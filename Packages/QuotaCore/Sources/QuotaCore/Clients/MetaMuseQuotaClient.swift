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
      let detail = apiErrorMessage(in: data) ?? String(data: data, encoding: .utf8) ?? ""
      switch response.statusCode {
      case 401, 403:
        throw ProviderClientError(kind: .auth, message: "Meta authorization failed (\(response.statusCode)) — check the API key or run `muse login` again")
      case 429:
        throw ProviderClientError(kind: .rateLimit, message: "Meta API rate limited: \(detail)")
      default:
        throw ProviderClientError(kind: .api, message: "Meta API error \(response.statusCode): \(detail)")
      }
    }

    let body = String(data: data, encoding: .utf8) ?? ""
    let parsed = subscriptionUsageSnapshot(in: body)
    let snapshot = parsed.snapshot

    var metrics: [UsageMetric] = []

    if let window = snapshot?["window"] as? [String: Any],
       let used = parseNumeric(window["used_percent"]) {
      let resetAt = parseDateValue(window["resets_at"])
      metrics.append(
        UsageMetric(
          id: "window",
          label: windowLabel(durationMins: parseNumeric(window["window_duration_mins"]).flatMap(roundedInt)),
          remainingPercent: percentRemaining(fromUsedPercent: used),
          resetAt: resetAt,
          resetIn: resetAt.map { formatResetCountdown(to: $0, now: now) }
        )
      )
    }

    if let weekly = snapshot?["weekly"] as? [String: Any],
       let used = parseNumeric(weekly["used_percent"]) {
      let resetAt = parseDateValue(weekly["resets_at"])
      metrics.append(
        UsageMetric(
          id: "weekly",
          label: "Weekly limit",
          remainingPercent: percentRemaining(fromUsedPercent: used),
          resetAt: resetAt,
          resetIn: resetAt.map { formatResetCountdown(to: $0, now: now) }
        )
      )
    }

    if metrics.isEmpty {
      // A recognizable stream without a snapshot is a pay-as-you-go key;
      // an unrecognizable body means the undocumented frame moved — fail
      // loudly instead of wearing a green placeholder.
      guard parsed.sawRecognizablePayload else {
        // Prefer the API's own explanation — "bad key" beats "format changed".
        let excerpt = String(body.prefix(200))
        let detail = parsed.streamError ?? apiErrorMessage(in: data)
        throw ProviderClientError(
          kind: .api,
          message: detail.map { "Meta API error: \($0) (body: \(excerpt))" }
            ?? "Meta API response contained no recognizable usage payload — stream format may have changed (body: \(excerpt))"
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

  /// Pulls the SubscriptionUsageSnapshot out of an SSE body. The dedicated
  /// `response.subscription_usage` event is checked first; the same snapshot
  /// can also ride inside the `response` object of a terminal event. If the
  /// body isn't SSE at all (server ignored `stream`), it is tried as a plain
  /// JSON response. `sawRecognizablePayload` distinguishes a healthy stream
  /// that simply carries no snapshot (pay-as-you-go) from an undecodable
  /// body, which is a protocol break worth surfacing as an error.
  /// `streamError` carries the message of a stream-level error event so the
  /// thrown failure can headline the API's own explanation.
  private func subscriptionUsageSnapshot(in body: String) -> (
    snapshot: [String: Any]?,
    sawRecognizablePayload: Bool,
    streamError: String?
  ) {
    var sawRecognizablePayload = false

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
      guard !dataLines.isEmpty else { continue }
      let joined = dataLines.joined(separator: "\n")
      guard joined != "[DONE]" else {
        sawRecognizablePayload = true
        continue
      }
      guard
        let object = try? JSONSerialization.jsonObject(with: Data(joined.utf8)) as? [String: Any]
      else { continue }

      // Stream-level errors arrive as HTTP 200 events; they must not read as
      // a healthy pay-as-you-go stream.
      let type = eventName ?? (object["type"] as? String)
      if type == "error" || type == "response.failed" || object["error"] is [String: Any] {
        return (nil, false, streamErrorMessage(in: object) ?? type)
      }
      sawRecognizablePayload = true

      if type == "response.subscription_usage", let snapshot = snapshotDict(in: object) {
        return (snapshot, true, nil)
      }
      if (type == "response.completed" || type == "response.incomplete"),
         let responseObject = object["response"] as? [String: Any],
         let snapshot = snapshotDict(in: responseObject) {
        return (snapshot, true, nil)
      }
    }

    guard
      let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
    else { return (nil, sawRecognizablePayload, nil) }
    if (object["type"] as? String) == "error" || object["error"] is [String: Any] {
      return (nil, false, streamErrorMessage(in: object) ?? object["type"] as? String)
    }
    return (snapshotDict(in: object), true, nil)
  }

  /// Reads the human explanation out of a stream error event or error
  /// envelope: `error.message`, then the flat fields the envelopes use.
  private func streamErrorMessage(in object: [String: Any]) -> String? {
    if let error = object["error"] as? [String: Any], let message = nonEmptyString(error["message"]) {
      return message
    }
    return nonEmptyString(object["message"]) ?? nonEmptyString(object["detail"]) ?? nonEmptyString(object["title"])
  }

  /// The snapshot's nesting varies with where it was carried: the dedicated
  /// event may put it at top level or under `subscription_usage`, and the
  /// terminal event nests it inside `response`.
  private func snapshotDict(in object: [String: Any]) -> [String: Any]? {
    if object["window"] is [String: Any] || object["weekly"] is [String: Any] {
      return object
    }
    for key in ["subscription_usage", "snapshot"] {
      if let nested = object[key] as? [String: Any],
         nested["window"] is [String: Any] || nested["weekly"] is [String: Any] {
        return nested
      }
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
