import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// M Plan's read-only quota endpoint. Counter interpretation, status values and
/// weekly boosts follow MiniMax-AI/cli at 38aba5f (types/api.ts, utils/quota.ts,
/// output/quota-table.ts). Explicit remaining percentages are authoritative:
/// different server versions use `usage_count` for used OR remaining counts.
public struct MiniMaxQuotaClient: QuotaProviderClient {
  public let provider: QuotaProvider = .minimax
  private let endpoint: URL
  private let httpClient: any HTTPClient
  private enum Window { case interval, weekly }

  public init(
    endpoint: URL = URL(string: "https://www.minimax.io/v1/token_plan/remains")!,
    httpClient: any HTTPClient
  ) {
    self.endpoint = endpoint
    self.httpClient = httpClient
  }

  public func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    let key = configuration.credentials[CredentialField.minimaxAPIKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !key.isEmpty,
          key.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
      throw ProviderClientError(kind: .notConfigured, message: "Enter your MiniMax M Plan Subscription Key without spaces or control characters.")
    }

    var request = URLRequest(url: endpoint)
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("LLimit/0.1", forHTTPHeaderField: "User-Agent")

    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await httpClient.data(for: request)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch {
      throw ProviderClientError(kind: .network, message: "Could not reach MiniMax. Check your connection and try again.")
    }
    guard (200..<300).contains(response.statusCode) else {
      let kind: QuotaErrorKind = [401, 403].contains(response.statusCode) ? .auth
        : (response.statusCode == 429 ? .rateLimit : .api)
      throw ProviderClientError(kind: kind,
        message: "MiniMax quota request failed (HTTP \(response.statusCode)). Check your M Plan Subscription Key and try again.",
        statusCode: response.statusCode)
    }

    let payload: MiniMaxResponse
    do {
      payload = try JSONDecoder().decode(MiniMaxResponse.self, from: data)
    } catch {
      throw Self.invalidResponse
    }
    if let code = payload.base_resp?.status_code, code != 0 {
      // Never copy status_msg: error bodies can echo credentials or requests.
      throw ProviderClientError(kind: code == 1004 ? .auth : .api,
        message: "MiniMax rejected the quota request (code \(code)). Check that your Subscription Key has an active M Plan.")
    }
    guard let buckets = payload.model_remains, !buckets.isEmpty else { throw Self.invalidResponse }

    var metrics: [UsageMetric] = []
    var seen = Set<String>()
    // Server order may change; preserve metric identities and primary selection.
    let sorted = buckets.sorted {
      if ($0.model_name == "general") != ($1.model_name == "general") { return $0.model_name == "general" }
      return $0.model_name < $1.model_name
    }
    for bucket in sorted {
      let name = bucket.model_name.trimmingCharacters(in: .whitespacesAndNewlines)
      let id = name.lowercased()
      guard !name.isEmpty, name.count <= 128,
            name.rangeOfCharacter(from: .controlCharacters) == nil,
            seen.insert(id).inserted else { throw Self.invalidResponse }
      let label = name == "general" ? "General" : (name == "video" ? "Video" : name)
      if bucket.isUnavailable {
        metrics.append(UsageMetric(id: "\(id)-unavailable", label: label, usedDisplay: "Not included in plan"))
        continue
      }
      metrics.append(try metric(bucket: bucket, window: .interval, id: id, label: label, now: now))
      metrics.append(try metric(bucket: bucket, window: .weekly, id: id, label: label, now: now))
    }
    guard metrics.contains(where: { $0.remainingPercent != nil || $0.isUnlimited }) else {
      throw ProviderClientError(kind: .api, message: "MiniMax reported no quota included in this plan. Check your M Plan subscription.")
    }
    let maxUsage = metrics.compactMap(\.remainingPercent).map { 100 - $0 }.max()
    return ProviderUsage(accountID: configuration.accountID, provider: provider,
      title: configuration.displayName, subtitle: "M Plan", metrics: metrics,
      maxUsagePercent: maxUsage, warning: maxUsage.map { $0 >= 80 } == true ? "High usage" : nil,
      fetchedAt: now)
  }

  private func metric(bucket: MiniMaxBucket, window: Window, id: String, label: String, now: Date) throws -> UsageMetric {
    let weekly = window == .weekly
    let status = weekly ? bucket.current_weekly_status : bucket.current_interval_status
    if let status, ![1, 2, 3].contains(status) { throw Self.invalidResponse }
    let start = weekly ? bucket.weekly_start_time : bucket.start_time
    let end = weekly ? bucket.weekly_end_time : bucket.end_time
    let countdown = weekly ? bucket.weekly_remains_time : bucket.remains_time
    let reset = try resetDate(end: end, countdown: countdown, now: now)
    let duration = try windowSeconds(start: start, end: end)
    let cadence = weekly ? "weekly" : intervalLabel(seconds: duration)
    let metricID = "\(id)-\(weekly ? "weekly" : "interval")"
    if status == 3 {
      return UsageMetric(id: metricID, label: "\(label) \(cadence)", resetAt: reset,
        resetIn: reset.map { formatResetCountdown(to: $0, now: now) }, windowSeconds: duration, isUnlimited: true)
    }

    let percent = weekly ? bucket.current_weekly_remaining_percent : bucket.current_interval_remaining_percent
    let count = weekly ? bucket.current_weekly_usage_count : bucket.current_interval_usage_count
    let total = weekly ? bucket.current_weekly_total_count : bucket.current_interval_total_count
    if let percent, !percent.isFinite || !(0...100).contains(percent) { throw Self.invalidResponse }
    let counts = resolveCounts(count: count, total: total, percent: percent)
    // Older responses include zero-filled weekly fields for a window the
    // server does not report. Preserve the known interval without inventing
    // either exhaustion or unlimited access for that weekly placeholder.
    if status == nil, percent == nil, total == 0, count == 0 {
      return UsageMetric(id: metricID, label: "\(label) \(cadence)", resetAt: reset,
        resetIn: reset.map { formatResetCountdown(to: $0, now: now) }, windowSeconds: duration,
        detail: "Quota not reported")
    }
    guard let basePercent = status == 2 ? 0 : percent ?? counts.map({ $0.remaining / $0.total * 100 }) else { throw Self.invalidResponse }
    let boost = weekly ? (bucket.weekly_boost_permille ?? 1000) / 1000 : 1
    guard boost.isFinite, boost >= 0, (basePercent * boost).isFinite else { throw Self.invalidResponse }
    let displayed = status == 2 ? 0 : basePercent * boost
    // Shared charts and alert thresholds use a bounded percentage. Preserve
    // MiniMax's boosted percentage in text when it exceeds their 100% ceiling.
    let remaining = Int(min(100, max(0, displayed)).rounded())
    let detail = displayed > 100 ? "\(formatIntLike(displayed) ?? "100")% of base quota remaining"
      : (status == 2 ? "Limit reached" : nil)
    return UsageMetric(id: metricID, label: "\(label) \(cadence)", remainingPercent: remaining,
      usedDisplay: counts.flatMap { formatIntLike(status == 2 ? $0.total : $0.total - $0.remaining) },
      totalDisplay: counts.flatMap { formatIntLike($0.total) },
      resetAt: reset, resetIn: reset.map { formatResetCountdown(to: $0, now: now) },
      windowSeconds: duration, detail: detail)
  }

  private func resolveCounts(count: Double?, total: Double?, percent: Double?) -> (remaining: Double, total: Double)? {
    guard let count, let total, count.isFinite, total.isFinite,
          total > 0, count >= 0, count <= total else { return nil }
    guard let percent else { return (count, total) }
    let remainingDistance = abs(count / total * 100 - percent)
    let usedDistance = abs((total - count) / total * 100 - percent)
    guard min(remainingDistance, usedDistance) <= 1 else { return nil }
    return (usedDistance < remainingDistance ? total - count : count, total)
  }

  private func resetDate(end: Double?, countdown: Double?, now: Date) throws -> Date? {
    if let end, end != 0 {
      guard end.isFinite, end > 0, end < 253_402_300_800_000 else { throw Self.invalidResponse }
      return Date(timeIntervalSince1970: end / 1000)
    }
    guard let countdown else { return nil }
    guard countdown.isFinite, countdown >= 0,
          now.timeIntervalSince1970 + countdown / 1000 < 253_402_300_800 else { throw Self.invalidResponse }
    return now.addingTimeInterval(countdown / 1000)
  }

  private func windowSeconds(start: Double?, end: Double?) throws -> Int? {
    guard let start, let end, start > 0, end > 0 else { return nil }
    let seconds = (end - start) / 1000
    guard seconds.isFinite, seconds > 0, let duration = roundedInt(seconds), duration > 0 else { throw Self.invalidResponse }
    return duration
  }

  private func intervalLabel(seconds: Int?) -> String {
    guard let seconds else { return "rolling limit" }
    if seconds % 86_400 == 0 { return "\(seconds / 86_400)-day limit" }
    if seconds % 3_600 == 0 { return "\(seconds / 3_600)-hour limit" }
    return "\(max(1, seconds / 60))-minute limit"
  }

  private static var invalidResponse: ProviderClientError {
    ProviderClientError(kind: .decoding, message: "MiniMax returned incomplete or invalid M Plan quota data. Try again later.")
  }
}

private struct MiniMaxResponse: Decodable {
  struct Status: Decodable { let status_code: Int }
  let base_resp: Status?
  let model_remains: [MiniMaxBucket]?
}

private struct MiniMaxBucket: Decodable {
  let model_name: String
  let start_time: Double?
  let end_time: Double?
  let remains_time: Double?
  let current_interval_total_count: Double?
  let current_interval_usage_count: Double?
  let current_interval_remaining_percent: Double?
  let current_interval_status: Int?
  let current_weekly_total_count: Double?
  let current_weekly_usage_count: Double?
  let current_weekly_remaining_percent: Double?
  let current_weekly_status: Int?
  let weekly_start_time: Double?
  let weekly_end_time: Double?
  let weekly_remains_time: Double?
  let weekly_boost_permille: Double?

  var isUnavailable: Bool {
    current_interval_status == 3 && current_weekly_status == 3
      && current_interval_total_count == 0 && current_weekly_total_count == 0
  }
}
