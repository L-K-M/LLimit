import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reads API credit balances without making a paid inference request. Any
/// Venice API key can read balances; an admin key also supplies the daily DIEM
/// allocation needed for a percentage. USD and bundled credits have no quota.
public struct VeniceQuotaClient: QuotaProviderClient {
  public let provider: QuotaProvider = .venice
  private let usageEndpoint: URL
  private let billingEndpoint: URL
  private let httpClient: any HTTPClient

  public init(
    usageEndpoint: URL = URL(string: "https://api.venice.ai/api/v1/api_keys/rate_limits")!,
    billingEndpoint: URL = URL(string: "https://api.venice.ai/api/v1/billing/balance")!,
    httpClient: any HTTPClient
  ) {
    self.usageEndpoint = usageEndpoint
    self.billingEndpoint = billingEndpoint
    self.httpClient = httpClient
  }

  public func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    let apiKey = configuration.credentials[CredentialField.veniceAPIKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !apiKey.isEmpty else {
      throw ProviderClientError(kind: .notConfigured, message: "Venice API key is not configured.")
    }
    guard apiKey.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
      throw ProviderClientError(kind: .notConfigured, message: "Enter a Venice API key without spaces or control characters.")
    }

    let (usageData, usageResponse) = try await request(usageEndpoint, apiKey: apiKey)
    try checkStatus(usageResponse.statusCode)
    let usage: VeniceRateLimitData = try decode(VeniceRateLimitResponse.self, from: usageData).data
    guard !usage.balances.values.isEmpty, usage.balances.values.allSatisfy(\.isFinite),
          usage.nextEpochBegins.contains("T"),
          let resetAt = parseISO8601(usage.nextEpochBegins) else {
      throw Self.invalidResponse
    }

    let (billingData, billingResponse) = try await request(billingEndpoint, apiKey: apiKey)
    let billing: VeniceBillingBalance?
    if [401, 403].contains(billingResponse.statusCode) {
      // Inference keys cannot read the allocation. A transient failure on an
      // otherwise authorized request instead fails the refresh so the app keeps
      // its last good percentage rather than replacing it with unknown data.
      billing = nil
    } else {
      try checkStatus(billingResponse.statusCode)
      let decoded = try decode(VeniceBillingBalance.self, from: billingData)
      guard decoded.diemEpochAllocation.isFinite,
            [decoded.balances.diem, decoded.balances.usd].compactMap({ $0 }).allSatisfy(\.isFinite) else {
        throw Self.invalidResponse
      }
      billing = decoded
    }

    var metrics: [UsageMetric] = []
    var remainingPercent: Int?
    if let diem = billing?.balances.diem ?? usage.balances.DIEM {
      let detail: String
      if let billing, let balance = billing.balances.diem, billing.diemEpochAllocation > 0 {
        // Use the numerator and denominator from the same response. Clamp before
        // division to avoid overflow and preserve signed/over-allocation amounts
        // separately from the bounded geometry.
        let boundedBalance = min(billing.diemEpochAllocation, max(0, balance))
        remainingPercent = roundedPercent((boundedBalance / billing.diemEpochAllocation) * 100)
        detail = "Account daily allocation: \(Self.amount(billing.diemEpochAllocation)) DIEM"
      } else if billing == nil {
        detail = "Available to this API key. An admin API key is needed to show the account's daily allocation and percentage."
      } else {
        detail = "Daily allocation is unavailable; showing the remaining balance."
      }
      metrics.append(UsageMetric(
        id: "daily-diem", label: "Daily DIEM remaining", remainingPercent: remainingPercent,
        usedDisplay: "\(Self.amount(diem)) DIEM", resetAt: resetAt,
        resetIn: formatResetCountdown(to: resetAt, now: now), detail: detail
      ))
    }
    if let usd = usage.balances.USD {
      metrics.append(UsageMetric(id: "usd-balance", label: "USD balance", usedDisplay: Self.dollars(usd), detail: "Available to this API key."))
    }
    if let bundled = usage.balances.BUNDLED_CREDITS {
      metrics.append(UsageMetric(id: "bundled-credits", label: "Bundled credits balance", usedDisplay: Self.dollars(bundled), detail: "Available to this API key."))
    }
    guard !metrics.isEmpty else { throw Self.invalidResponse }

    let maxUsagePercent = remainingPercent.map { 100 - $0 }
    let warning: String?
    if !usage.accessPermitted {
      warning = "API key spending unavailable. Check its limits in Venice."
    } else if billing?.canConsume == false {
      warning = "API spending unavailable. Check Venice billing."
    } else if maxUsagePercent == 100, let diem = billing?.balances.diem, diem <= 0 {
      warning = "Daily DIEM exhausted"
    } else if let maxUsagePercent, maxUsagePercent >= 80 {
      warning = "High DIEM usage"
    } else {
      warning = nil
    }
    return ProviderUsage(
      accountID: configuration.accountID, provider: provider, title: configuration.displayName,
      subtitle: "Venice API credits", metrics: metrics, maxUsagePercent: maxUsagePercent,
      warning: warning, fetchedAt: now
    )
  }

  private func request(_ endpoint: URL, apiKey: String) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("LLimit/0.1", forHTTPHeaderField: "User-Agent")
    do {
      return try await httpClient.data(for: request)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw ProviderClientError(kind: .network, message: "Could not reach Venice. Check your connection and try again.")
    }
  }

  private func checkStatus(_ status: Int) throws {
    guard !(200..<300).contains(status) else { return }
    switch status {
    case 401, 403:
      throw ProviderClientError(kind: .auth, message: "Venice authorization failed. Check the API key.")
    case 429:
      throw ProviderClientError(kind: .rateLimit, message: "Venice is rate limiting usage requests. Try again later.")
    default:
      throw ProviderClientError(kind: .api, message: "Venice usage request failed (HTTP \(status)). Try again later.")
    }
  }

  private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do { return try JSONDecoder().decode(type, from: data) }
    catch { throw Self.invalidResponse }
  }

  private static func amount(_ value: Double, minimumFractionDigits: Int = 0) -> String {
    if value != 0, abs(value) < 0.000001 {
      return String(format: "%.6g", locale: Locale(identifier: "en_US_POSIX"), value).lowercased()
    }
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.minimumFractionDigits = minimumFractionDigits
    formatter.maximumFractionDigits = 6
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
  }

  private static func dollars(_ value: Double) -> String {
    "\(value < 0 ? "-" : "")$\(amount(abs(value), minimumFractionDigits: 2))"
  }

  private static var invalidResponse: ProviderClientError {
    ProviderClientError(kind: .decoding, message: "Venice returned incomplete or invalid balance data. Try again later.")
  }
}

private struct VeniceRateLimitResponse: Decodable {
  let data: VeniceRateLimitData
}

private struct VeniceRateLimitData: Decodable {
  struct Balances: Decodable {
    let DIEM: Double?
    let USD: Double?
    let BUNDLED_CREDITS: Double?

    var values: [Double] { [DIEM, USD, BUNDLED_CREDITS].compactMap { $0 } }
  }

  let accessPermitted: Bool
  let balances: Balances
  let nextEpochBegins: String
}

private struct VeniceBillingBalance: Decodable {
  struct Balances: Decodable {
    let diem: Double?
    let usd: Double?
  }

  let canConsume: Bool
  let balances: Balances
  let diemEpochAllocation: Double
}
