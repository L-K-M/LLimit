import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reads Cline usage with read-only account endpoints: no inference request is
/// made, so a probe costs nothing.
///
/// Cline bills two separate ways and both are reported:
///  - ClinePass, a subscription whose cost is capped in rolling windows (five
///    hours, a week, a month). The API reports the share already used, which
///    becomes an exact remaining percentage.
///  - Cline credits, a prepaid pay-as-you-go balance. There is no reported
///    total and no reset, so it is an amount only and never a percentage.
public struct ClineQuotaClient: QuotaProviderClient {
  public let provider: QuotaProvider = .cline
  private let api: ClineAPI

  public init(baseURL: URL = URL(string: "https://api.cline.bot")!, httpClient: any HTTPClient) {
    self.api = ClineAPI(baseURL: baseURL, httpClient: httpClient)
  }

  public func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    let apiKey = configuration.credentials[CredentialField.clineAPIKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !apiKey.isEmpty else {
      throw ProviderClientError(kind: .notConfigured, message: "Cline API key is not configured.")
    }
    guard apiKey.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
      throw ProviderClientError(kind: .notConfigured, message: "Enter a Cline API key without spaces or control characters.")
    }

    // The profile call doubles as the API key check and yields the user id the
    // balance endpoint needs, so a key that cannot read the account fails here
    // rather than on a URL built from a guessed id.
    let profile = try await api.profile(apiKey: apiKey)
    let balance = try await api.balance(apiKey: apiKey, userID: profile.id)
    // Windows only exist for a subscription. An account without ClinePass
    // reports none, and an older deployment may not serve the endpoint.
    let windows = Self.deduplicated(try await api.usageLimits(apiKey: apiKey) ?? [])

    var metrics = windows.map { Self.windowMetric($0, now: now) }
    metrics.append(Self.creditMetric(balance))

    let maxUsagePercent = windows.map(\.usedPercent).max()
    let warning: String?
    if let exhausted = windows.first(where: \.isExhausted) {
      warning = "ClinePass \(Self.windowName(exhausted.type)) limit reached"
    } else if let maxUsagePercent, maxUsagePercent >= Self.highUsagePercent {
      warning = "High ClinePass usage"
    } else if windows.isEmpty, balance <= 0 {
      // Only an account without a subscription depends on prepaid credits, so
      // only there does an empty balance block work. Warning a ClinePass
      // subscriber who never bought credits would be a permanent false alarm.
      warning = "No Cline credits left"
    } else {
      warning = nil
    }

    return ProviderUsage(
      accountID: configuration.accountID, provider: provider, title: configuration.displayName,
      subtitle: "ClinePass and credits", metrics: metrics, maxUsagePercent: maxUsagePercent,
      warning: warning, fetchedAt: now
    )
  }

  private static let highUsagePercent = 80

  /// Cline stores money as integer millionths of a US dollar, so a raw
  /// `4250000` is $4.25.
  private static let creditsPerDollar = 1_000_000.0

  /// The API repeats a type only in malformed responses, so one type must not
  /// produce two rows for the ring to choose between. Where two readings
  /// disagree the more consumed one wins, because picking the other would
  /// under-report usage.
  private static func deduplicated(_ windows: [ClineUsageWindow]) -> [ClineUsageWindow] {
    var indexByType: [String: Int] = [:]
    var result: [ClineUsageWindow] = []

    for window in windows {
      guard !window.type.isEmpty else { continue }

      guard let index = indexByType[window.type] else {
        indexByType[window.type] = result.count
        result.append(window)
        continue
      }
      if window.usedPercent > result[index].usedPercent { result[index] = window }
    }

    return result
  }

  private static func windowMetric(_ window: ClineUsageWindow, now: Date) -> UsageMetric {
    let resetAt = parseISO8601(window.resetsAt)

    return UsageMetric(
      id: window.type, label: "\(windowName(window.type)) remaining",
      remainingPercent: clampPercent(100 - window.usedPercent), usedDisplay: "\(window.usedPercent)% used",
      resetAt: resetAt, resetIn: resetAt.map { formatResetCountdown(to: $0, now: now) },
      detail: "ClinePass subscription window."
    )
  }

  private static func creditMetric(_ balance: Double) -> UsageMetric {
    let amount = balance / creditsPerDollar

    return UsageMetric(
      id: "credit-balance", label: "Credit balance", remainingAmount: amount,
      usedDisplay: dollars(amount),
      detail: "Prepaid Cline credits. Cline reports no total or reset for them."
    )
  }

  /// How a window is named in prose, in both metric labels and warnings.
  private static func windowName(_ type: String) -> String {
    switch type {
    case "five_hour": return "5-hour"
    case "weekly": return "weekly"
    case "monthly": return "monthly"
    default:
      let words = type.replacingOccurrences(of: "_", with: " ")
      return words.prefix(1).uppercased() + words.dropFirst()
    }
  }

  /// A credit balance is an amount, so it keeps a sign: an overdrawn account
  /// must not read as a positive balance of the same magnitude.
  private static func dollars(_ value: Double) -> String {
    let prefix = value < 0 ? "-$" : "$"
    let magnitude = abs(value)

    // A balance small enough to round to $0.00 still has to read as nonzero.
    if magnitude > 0, magnitude < 0.000001 {
      return prefix + String(format: "%.6g", locale: Locale(identifier: "en_US_POSIX"), magnitude).lowercased()
    }

    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 6

    return prefix + (formatter.string(from: NSNumber(value: magnitude)) ?? String(magnitude))
  }
}

/// Transport and wire shapes for the Cline account API. The API is
/// undocumented and unstable, so every failure is translated into a sanitized
/// `ProviderClientError`: no response body, and never the key, reaches a
/// display surface.
private struct ClineAPI {
  let baseURL: URL
  let httpClient: any HTTPClient

  func profile(apiKey: String) async throws -> ClineProfile {
    guard let profile = try await payload(ClineProfile.self, path: ["api", "v1", "users", "me"], apiKey: apiKey) else {
      throw Self.invalidResponse
    }
    let id = profile.id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.isPathSegment(id) else { throw Self.invalidResponse }

    return ClineProfile(id: id)
  }

  /// The user id becomes one path segment of the balance URL, and
  /// `appendingPathComponent` leaves `/` intact, so an id carrying a separator
  /// or a `..` would reshape the request instead of addressing the account.
  /// Only the shape Cline actually issues is accepted.
  private static func isPathSegment(_ id: String) -> Bool {
    !id.isEmpty && !id.contains("/") && !id.contains("..") && !id.contains("?")
      && id.rangeOfCharacter(from: .controlCharacters) == nil
  }

  func balance(apiKey: String, userID: String) async throws -> Double {
    guard let balance = try await payload(
      ClineBalance.self, path: ["api", "v1", "users", userID, "balance"], apiKey: apiKey
    )?.balance, balance.isFinite else { throw Self.invalidResponse }

    return balance
  }

  /// Returns nil when the account has no ClinePass subscription, or when the
  /// deployment does not serve the endpoint. Any other failure throws: dropping
  /// a window the user previously saw would silently under-report usage, so the
  /// refresh fails and the last good snapshot survives.
  func usageLimits(apiKey: String) async throws -> [ClineUsageWindow]? {
    let response = try await request(["api", "v1", "users", "me", "plan", "usage-limits"], apiKey: apiKey)

    switch response.statusCode {
    case 401, 403, 404:
      return nil
    case 200..<300:
      return try Self.payload(try decode(ClineEnvelope<ClineUsageLimits>.self, from: response.data))?.limits
    default:
      throw Self.error(for: response.statusCode)
    }
  }

  private func payload<T: Decodable>(_ type: T.Type, path: [String], apiKey: String) async throws -> T? {
    let response = try await request(path, apiKey: apiKey)
    guard (200..<300).contains(response.statusCode) else { throw Self.error(for: response.statusCode) }

    return try Self.payload(try decode(ClineEnvelope<T>.self, from: response.data))
  }

  /// The envelope's payload, or nil when the account simply has none.
  ///
  /// A rejected call reports fixed text only. The server's own `error` string
  /// is not echoed: it lands in `ProviderFailure`, which is written to the
  /// snapshot and rendered by `llimit status`, and a deployment that reflects
  /// the submitted `Authorization` value back would put the key there.
  private static func payload<T>(_ envelope: ClineEnvelope<T>) throws -> T? {
    guard !envelope.rejected else {
      throw ProviderClientError(kind: .api, message: "Cline rejected the usage request. Try again later.")
    }
    return envelope.value
  }

  private func request(_ path: [String], apiKey: String) async throws -> (data: Data, statusCode: Int) {
    var request = URLRequest(url: path.reduce(baseURL) { $0.appendingPathComponent($1) })
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("LLimit/0.1", forHTTPHeaderField: "User-Agent")

    do {
      let (data, response) = try await httpClient.data(for: request)
      return (data, response.statusCode)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw ProviderClientError(kind: .network, message: "Could not reach Cline. Check your connection and try again.")
    }
  }

  private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do { return try JSONDecoder().decode(type, from: data) }
    catch { throw Self.invalidResponse }
  }

  private static func error(for status: Int) -> ProviderClientError {
    switch status {
    case 401, 403:
      return ProviderClientError(kind: .auth, message: "Cline authorization failed. Check the API key.")
    case 429:
      return ProviderClientError(kind: .rateLimit, message: "Cline is rate limiting usage requests. Try again later.")
    default:
      return ProviderClientError(kind: .api, message: "Cline usage request failed (HTTP \(status)). Try again later.")
    }
  }

  private static var invalidResponse: ProviderClientError {
    ProviderClientError(kind: .decoding, message: "Cline returned incomplete or invalid usage data. Try again later.")
  }
}

/// Cline answers with `{success, error, data}`, but an older or on-premise
/// deployment can return the bare object. Unwrap `data` only when the envelope
/// marker is present, and carry `success: false` out as a typed failure.
private struct ClineEnvelope<Value: Decodable>: Decodable {
  let value: Value?
  /// Whether the server reported the call itself as failed, independent of any
  /// message it attached.
  let rejected: Bool

  private enum CodingKeys: String, CodingKey {
    case success, error, data
  }

  init(from decoder: Decoder) throws {
    guard let container = try? decoder.container(keyedBy: CodingKeys.self),
          let success = try? container.decodeIfPresent(Bool.self, forKey: .success) else {
      value = try Value(from: decoder)
      rejected = false
      return
    }

    guard success else {
      value = nil
      rejected = true
      return
    }

    // Only an explicit `"data": null` means "the account has none". A payload
    // that fails to decode, or a missing key, must propagate: a schema change
    // would otherwise silently erase the windows the user already sees instead
    // of surfacing as a refresh failure.
    guard container.contains(.data) else {
      throw DecodingError.dataCorrupted(.init(
        codingPath: container.codingPath, debugDescription: "Envelope has no data field"
      ))
    }
    value = try container.decodeIfPresent(Value.self, forKey: .data)
    rejected = false
  }
}

private struct ClineProfile: Decodable {
  let id: String
}

private struct ClineBalance: Decodable {
  let balance: Double
}

private struct ClineUsageLimits: Decodable {
  let limits: [ClineUsageWindow]
}

/// One ClinePass window. `percentUsed` is the share already spent; `resetsAt`
/// is absent for windows the API does not date.
private struct ClineUsageWindow: Decodable {
  let type: String
  let percentUsed: Double
  let resetsAt: String?

  private enum CodingKeys: String, CodingKey {
    case type, percentUsed, resetsAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    type = (try container.decodeIfPresent(String.self, forKey: .type) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    let percentUsed = try container.decodeIfPresent(Double.self, forKey: .percentUsed) ?? 0
    // Foundation differs on whether a share like `1e1000` throws or decodes as
    // infinity, so reject it here to keep one behavior on every platform. A
    // share is never legitimately unbounded.
    guard percentUsed.isFinite else {
      throw DecodingError.dataCorrupted(.init(
        codingPath: container.codingPath + [CodingKeys.percentUsed],
        debugDescription: "Window share is not a finite percentage"
      ))
    }
    self.percentUsed = percentUsed
    resetsAt = try container.decodeIfPresent(String.self, forKey: .resetsAt)
  }

  /// The share as a whole percentage inside 0...100. The API reports a
  /// percentage rather than an amount, so anything outside that range is
  /// clamped into the bounded geometry the surfaces draw.
  var usedPercent: Int {
    Int(min(100, max(0, percentUsed)).rounded())
  }

  var isExhausted: Bool { usedPercent >= 100 }
}