import Foundation

/// Decodes the result of the official app-server's account/rateLimits/read
/// method. No credentials are needed or copied into the resulting usage data.
public struct CodexRateLimits: Sendable {
  private let buckets: [(id: String, snapshot: Snapshot)]

  public init(data: Data) throws {
    do {
      let response = try JSONDecoder().decode(Response.self, from: data)
      if let snapshots = response.rateLimitsByLimitId {
        buckets = snapshots.keys.sorted { lhs, rhs in
          if lhs == "codex" { return rhs != "codex" }
          if rhs == "codex" { return false }
          return lhs < rhs
        }.map { (id: $0, snapshot: snapshots[$0]!) }
      } else if let snapshot = response.rateLimits {
        buckets = [(id: nonEmptyString(snapshot.limitId) ?? "codex", snapshot: snapshot)]
      } else {
        throw CodexRateLimitsError.invalidResponse
      }
      for bucket in buckets {
        guard !bucket.id.isEmpty else { throw CodexRateLimitsError.invalidResponse }
        try bucket.snapshot.validate()
      }
    } catch {
      // Decoding errors can quote parts of their input. Keep failures fixed and
      // credential-free even if an unexpected RPC response reaches this parser.
      throw CodexRateLimitsError.invalidResponse
    }
  }

  public func usage(configuration: ProviderRuntimeConfiguration, now: Date) -> ProviderUsage {
    var metrics: [UsageMetric] = []
    for bucket in buckets {
      for (windowID, window) in [("primary", bucket.snapshot.primary), ("secondary", bucket.snapshot.secondary)] {
        guard let window else { continue }
        let id = bucket.id == "codex" ? windowID : "bucket.\(bucket.id).\(windowID)"
        let cadence = Self.windowName(minutes: window.windowDurationMins, fallback: windowID)
        let label = bucket.id == "codex" ? cadence : "\(cadence) (\(bucket.id))"
        let resetAt = window.resetsAt.map { Date(timeIntervalSince1970: $0) }
        metrics.append(UsageMetric(
          id: id, label: label,
          remainingPercent: window.usedPercent.flatMap(percentRemaining(fromUsedPercent:)),
          resetAt: resetAt,
          resetIn: resetAt.map { formatResetCountdown(to: $0, now: now) },
          windowSeconds: window.windowDurationMins.flatMap { reportedWindowSeconds(count: $0, unitSeconds: 60) },
          detail: nonEmptyString(bucket.snapshot.limitName)))
      }
    }
    if metrics.isEmpty {
      metrics = [UsageMetric(id: "empty", label: "No rate limit data", detail: "Codex returned no active windows")]
    }
    let maxUsage = metrics.compactMap(\.remainingPercent).map { 100 - $0 }.max()
    let reached = buckets.contains { $0.snapshot.rateLimitReachedType != nil }
      || metrics.contains { $0.remainingPercent == 0 }
    return ProviderUsage(
      accountID: configuration.accountID, provider: .openAI, title: configuration.displayName,
      subtitle: buckets.compactMap { nonEmptyString($0.snapshot.planType) }.first,
      metrics: metrics, maxUsagePercent: maxUsage,
      warning: reached ? "Rate limit reached" : nil, fetchedAt: now)
  }

  private static func windowName(minutes: Int?, fallback: String) -> String {
    guard let minutes else { return "\(fallback.capitalized) limit" }
    if minutes.isMultiple(of: 1_440) { return "\(minutes / 1_440)-day limit" }
    if minutes.isMultiple(of: 60) { return "\(minutes / 60)-hour limit" }
    return "\(minutes)-minute limit"
  }

  private struct Response: Decodable {
    let rateLimits: Snapshot?
    let rateLimitsByLimitId: [String: Snapshot]?

    private enum CodingKeys: String, CodingKey {
      case rateLimits
      case rateLimitsByLimitId
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      rateLimitsByLimitId = try container.decodeIfPresent([String: Snapshot].self, forKey: .rateLimitsByLimitId)
      // The map is authoritative. An unused legacy view must not override or
      // prevent displaying the current multi-bucket response.
      rateLimits = rateLimitsByLimitId == nil
        ? try container.decodeIfPresent(Snapshot.self, forKey: .rateLimits) : nil
    }
  }

  private struct Snapshot: Decodable, Sendable {
    let limitId: String?
    let limitName: String?
    let primary: Window?
    let secondary: Window?
    let planType: String?
    let rateLimitReachedType: String?

    func validate() throws {
      try primary?.validate()
      try secondary?.validate()
    }
  }

  private struct Window: Decodable, Sendable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    let resetsAt: Double?

    func validate() throws {
      if let usedPercent, !usedPercent.isFinite { throw CodexRateLimitsError.invalidResponse }
      if let windowDurationMins, windowDurationMins <= 0 { throw CodexRateLimitsError.invalidResponse }
      if let resetsAt, !resetsAt.isFinite || resetsAt < 0 || resetsAt.rounded() != resetsAt {
        throw CodexRateLimitsError.invalidResponse
      }
    }
  }
}

public enum CodexRateLimitsError: LocalizedError, Equatable {
  case invalidResponse

  public var errorDescription: String? { "Codex returned an invalid rate limit response." }
}
