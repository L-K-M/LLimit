import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The read-only billing calls used by Command Code's `/usage` view. Credits
/// are usage units whose dollar value can vary by model, not cash balances.
public struct CommandCodeQuotaClient: QuotaProviderClient {
  public let provider: QuotaProvider = .commandCode
  private let httpClient: any HTTPClient
  private let baseURL: URL

  public init(baseURL: URL = URL(string: "https://api.commandcode.ai")!, httpClient: any HTTPClient) {
    self.baseURL = baseURL
    self.httpClient = httpClient
  }

  public func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    let key = configuration.credentials[CredentialField.commandCodeAPIKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !key.isEmpty, key.utf8.count <= 32_768,
          key.utf8.allSatisfy({ (0x21...0x7e).contains($0) }),
          !key.hasPrefix("$"), !key.hasPrefix("{env:"), !key.hasPrefix("!") else {
      throw ProviderClientError(kind: .notConfigured,
        message: "Enter a Command Code API key without spaces or control characters, or import a saved CLI login.")
    }

    let who: CommandCodeIdentity = try await get("/alpha/whoami", query: [URLQueryItem(name: "limits", value: "1")], key: key, now: now)
    guard who.success != false,
          Self.validID(who.user?.id) || Self.validID(who.org?.id),
          who.org == nil || Self.validID(who.org?.id) else { throw Self.invalidResponse }
    // Use only the organization resolved by this key's authenticated identity.
    // A Studio URL slug is not an authorization or organization identifier.
    let query = who.org?.id.map { [URLQueryItem(name: "orgId", value: $0)] } ?? []
    let balance: CommandCodeCredits = try await get("/alpha/billing/credits", query: query, key: key, now: now)
    let subscription: CommandCodeSubscriptionEnvelope = try await get("/alpha/billing/subscriptions", query: query, key: key, now: now)
    guard balance.success != false, subscription.success != false else { throw Self.invalidResponse }
    let credits = balance.credits
    guard [credits.monthlyCredits, credits.purchasedCredits, credits.freeCredits].allSatisfy(\.isFinite) else {
      throw Self.invalidResponse
    }

    var metrics: [UsageMetric] = []
    if let windows = balance.windowLimits, windows.limited {
      guard windows.fiveHour != nil || windows.weekly != nil else { throw Self.invalidResponse }
      if let window = windows.fiveHour {
        metrics.append(try Self.windowMetric(window, id: "five-hour", label: "5-hour plan credits", seconds: 18_000, now: now))
      }
      if let window = windows.weekly {
        metrics.append(try Self.windowMetric(window, id: "weekly", label: "Weekly plan credits", seconds: 604_800, now: now))
      }
    }
    let percentages = metrics.compactMap(\.remainingPercent)
    let monthly = max(0, credits.monthlyCredits)
    let purchased = max(0, credits.purchasedCredits)
    let free = max(0, credits.freeCredits)
    var monthlyMetric = Self.balanceMetric(id: "monthly-credits", label: "Monthly plan credits", amount: monthly,
      detail: "Included subscription credits. Their usage value depends on the model; the API does not report a total allowance.")
    // A monthly subscription period supplies a known refill cycle. Do not
    // mistake a yearly billing period or a plan price for monthly quota.
    if let period = subscription.data,
       ["active", "trialing"].contains(period.status ?? ""), period.cancelAtPeriodEnd != true,
       let startText = period.currentPeriodStart, let endText = period.currentPeriodEnd,
       let start = parseISO8601(startText), let end = parseISO8601(endText),
       (28 * 86_400...31 * 86_400).contains(end.timeIntervalSince(start)) {
      monthlyMetric.resetAt = end
      monthlyMetric.resetIn = formatResetCountdown(to: end, now: now)
      if start <= now { monthlyMetric.windowSeconds = Int(end.timeIntervalSince(start).rounded()) }
    }
    metrics.append(monthlyMetric)
    metrics.append(Self.balanceMetric(id: "purchased-credits", label: "Purchased credits", amount: purchased,
      detail: "Extra credits are separate from the subscription's rolling limits. No total or reset is reported."))
    metrics.append(Self.balanceMetric(id: "free-credits", label: "Free credits", amount: free,
      detail: "Free credits are separate from the included monthly allowance. No total or reset is reported."))

    let warning: String?
    if let exhausted = metrics.first(where: { $0.remainingPercent == 0 }) {
      warning = "Command Code \(exhausted.id == "five-hour" ? "5-hour" : "weekly") plan limit reached"
    } else if monthly == 0, purchased == 0, free == 0 {
      warning = "No Command Code credits left"
    } else if percentages.min().map({ $0 <= 20 }) == true {
      warning = "High Command Code plan usage"
    } else { warning = nil }

    return ProviderUsage(accountID: configuration.accountID, provider: provider, title: configuration.displayName,
      subtitle: "Subscription and credits", metrics: metrics, maxUsagePercent: percentages.min().map { 100 - $0 },
      warning: warning, fetchedAt: now)
  }

  private static func validID(_ value: String?) -> Bool {
    guard let value, !value.isEmpty, value.utf8.count <= 256 else { return false }
    return value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
  }

  private static func windowMetric(_ window: CommandCodeWindow, id: String, label: String, seconds: Int, now: Date) throws -> UsageMetric {
    guard window.used.isFinite, window.used >= 0, window.cap.isFinite, window.cap >= 0,
          window.resetAt.isFinite, window.resetAt >= 0, window.resetAt < 253_402_300_800_000 else {
      throw invalidResponse
    }
    let remaining = max(0, window.cap - window.used)
    let percent = window.cap > 0 ? roundedPercent((1 - min(1, window.used / window.cap)) * 100) : 0
    // The official CLI compares resetAt directly with Date.now(): milliseconds.
    // Zero denotes an unopened window, not an epoch-date reset.
    let reset = window.resetAt > 0 ? Date(timeIntervalSince1970: window.resetAt / 1_000) : nil
    return UsageMetric(id: id, label: label, remainingPercent: percent, remainingAmount: remaining, totalAmount: window.cap,
      usedDisplay: "\(formatCredits(window.used)) used", totalDisplay: formatCredits(window.cap),
      resetAt: reset, resetIn: reset.map { formatResetCountdown(to: $0, now: now) }, windowSeconds: seconds,
      detail: "Paces included subscription credits only. Purchased extra credits are not throttled by this window.")
  }

  private static func balanceMetric(id: String, label: String, amount: Double, detail: String) -> UsageMetric {
    UsageMetric(id: id, label: label, remainingAmount: amount, usedDisplay: "\(formatCredits(amount)) left", detail: detail)
  }

  private static func formatCredits(_ value: Double) -> String {
    if value > 0, value < 0.000001 {
      return String(format: "%.6g credits", locale: Locale(identifier: "en_US_POSIX"), value)
    }
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.maximumFractionDigits = 6
    return "\(formatter.string(from: NSNumber(value: value)) ?? String(value)) credits"
  }

  private func get<T: Decodable>(_ path: String, query: [URLQueryItem], key: String, now: Date) async throws -> T {
    guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
      throw Self.invalidResponse
    }
    if !query.isEmpty { components.queryItems = query }
    guard let url = components.url else { throw Self.invalidResponse }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("LLimit/0.1", forHTTPHeaderField: "User-Agent")
    let data: Data
    let response: HTTPURLResponse
    do { (data, response) = try await httpClient.data(for: request, redirects: .refuse) }
    catch is CancellationError { throw CancellationError() }
    catch let error as URLError where error.code == .cancelled { throw CancellationError() }
    catch {
      throw ProviderClientError(kind: .network, message: "Could not reach Command Code. Check your connection and try again.")
    }
    guard response.statusCode == 200 else {
      let kind = errorKind(forStatusCode: response.statusCode)
      let message: String
      switch kind {
      case .auth: message = "Command Code authorization failed. Replace the API key or import a fresh CLI login."
      case .rateLimit: message = "Command Code is rate limiting quota requests. Try again later."
      default: message = "Command Code quota request failed (HTTP \(response.statusCode)). Try again later."
      }
      throw ProviderClientError(kind: kind, message: message, statusCode: response.statusCode,
        retryAfter: kind == .rateLimit ? parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: now) : nil)
    }
    do { return try JSONDecoder().decode(T.self, from: data) }
    catch { throw Self.invalidResponse }
  }

  private static var invalidResponse: ProviderClientError {
    ProviderClientError(kind: .api, message: "Command Code did not report valid quota data. Try again later.")
  }
}

private struct CommandCodeIdentity: Decodable {
  let success: Bool?
  let user: Entity?
  let org: Entity?
  struct Entity: Decodable { let id: String? }
}

private struct CommandCodeCredits: Decodable {
  let success: Bool?
  let credits: Balance
  let windowLimits: Windows?
  struct Balance: Decodable {
    let monthlyCredits: Double
    let purchasedCredits: Double
    let freeCredits: Double
  }
  struct Windows: Decodable {
    let limited: Bool
    let fiveHour: CommandCodeWindow?
    let weekly: CommandCodeWindow?
  }
}

private struct CommandCodeWindow: Decodable {
  let used: Double
  let cap: Double
  let resetAt: Double
}

private struct CommandCodeSubscriptionEnvelope: Decodable {
  let success: Bool?
  let data: Subscription?
  struct Subscription: Decodable {
    let status: String?
    let cancelAtPeriodEnd: Bool?
    let currentPeriodStart: String?
    let currentPeriodEnd: String?
  }
  private enum CodingKeys: String, CodingKey { case success, data }
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard container.contains(.data) else {
      throw DecodingError.keyNotFound(CodingKeys.data, .init(codingPath: decoder.codingPath, debugDescription: "Missing subscription data"))
    }
    success = try container.decodeIfPresent(Bool.self, forKey: .success)
    data = try container.decodeIfPresent(Subscription.self, forKey: .data)
  }
}
