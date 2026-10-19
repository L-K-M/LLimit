import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reads the same account balance as Junie CLI's `/stats` command. The API
/// supplies no total or reset. Percentages use an account-configured allowance
/// or the personal AI Ultimate default. Reset dates are optional account settings.
public struct JunieQuotaClient: QuotaProviderClient {
  public let provider: QuotaProvider = .junie
  private let endpoint: URL
  private let httpClient: any HTTPClient
  private static let personalUltimateAllowance = 35.0

  public init(
    endpoint: URL = URL(string: "https://ingrazzio-cloud-prod.labs.jb.gg/auth/test")!,
    httpClient: any HTTPClient
  ) {
    self.endpoint = endpoint
    self.httpClient = httpClient
  }

  public func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    let apiKey = configuration.credentials[CredentialField.junieAPIKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !apiKey.isEmpty,
          apiKey.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
      throw ProviderClientError(kind: .notConfigured, message: "Enter a Junie API key without spaces or control characters.")
    }
    let configuredAllowance = try Self.configuredAllowance(in: configuration.credentials)
    let cycle = try Self.configuredCycle(in: configuration.credentials)
    let resetAt = cycle?.resetAt(after: now)

    var request = URLRequest(url: endpoint)
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("false", forHTTPHeaderField: "X-Accept-EAP-License")
    request.setValue("true", forHTTPHeaderField: "X-Accept-Release-License")
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
      throw ProviderClientError(kind: .network, message: "Could not reach Junie. Check your connection and try again.")
    }

    guard (200..<300).contains(response.statusCode) else {
      let kind = errorKind(forStatusCode: response.statusCode)
      let message: String
      switch kind {
      case .auth:
        message = "Junie authorization failed. Replace the API key or import a fresh login."
      case .rateLimit:
        message = "Junie is rate limiting balance requests. Try again later."
      default:
        message = "Junie balance request failed (HTTP \(response.statusCode)). Try again later."
      }
      throw ProviderClientError(
        kind: kind, message: message, statusCode: response.statusCode,
        retryAfter: kind == .rateLimit ? parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: now) : nil
      )
    }

    let account: JunieBalance
    do {
      account = try JSONDecoder().decode(JunieBalance.self, from: data)
    } catch {
      throw Self.invalidResponse
    }
    guard account.active != false, account.licenseType != "NONE" else {
      throw ProviderClientError(kind: .auth, message: "Junie account is inactive. Check your JetBrains AI subscription and API key.")
    }
    // Junie itself suppresses the balance for GZL licenses. Its raw number
    // does not establish a usable allowance or unlimited access.
    guard account.licenseType != "GZL" else {
      throw ProviderClientError(kind: .api, message: "This JetBrains AI license does not report a credit balance.")
    }
    guard let rawBalance = account.balanceLeft, rawBalance.isFinite else { throw Self.invalidResponse }
    // Junie formats USD directly; every other balance unit is stored in
    // hundred-thousandths of a credit. Do not mix the two scales.
    let isUSD = account.balanceUnit == "USD"
    let balance = isUSD ? rawBalance : rawBalance / 100_000
    // A license code does not distinguish personal and organization quotas.
    // Use the personal Ultimate default transparently, with an explicit
    // override for organization accounts and an opt-out for balance-only use.
    let allowance = configuredAllowance ?? (account.licenseType == "AIPU" ? Self.personalUltimateAllowance : 0)
    let remainingPercent = allowance > 0
      ? roundedPercent(min(max(balance, 0), allowance) / allowance * 100) : nil
    let detail: String
    let resetDetail = resetAt == nil ? "Reset date not reported."
      : "Uses your configured reset, repeating every 30 days."
    if allowance > 0 {
      let basis = configuredAllowance == nil ? "personal AI Ultimate default" : "configured allowance"
      detail = "Based on \(Self.displayBalance(allowance, isUSD: false)) per 30 days (\(basis)). Top-ups may be included. \(resetDetail)"
    } else {
      detail = "JetBrains AI balance shared with Junie. Set a 30-day AI credit allowance to show percentages. \(resetDetail)"
    }

    let warning: String?
    if balance <= 0 {
      warning = "No JetBrains AI balance left"
    } else if allowance > 0, balance / allowance <= 0.2 {
      warning = "Low JetBrains AI balance"
    } else {
      warning = nil
    }

    return ProviderUsage(
      accountID: configuration.accountID, provider: provider, title: configuration.displayName,
      subtitle: "JetBrains AI",
      metrics: [UsageMetric(
        id: "credit-balance", label: allowance > 0 ? "30-day AI credits" : "Credit balance",
        remainingPercent: remainingPercent, remainingAmount: balance,
        usedDisplay: Self.displayBalance(balance, isUSD: isUSD),
        totalDisplay: allowance > 0 ? Self.displayBalance(allowance, isUSD: isUSD) : nil,
        resetAt: resetAt,
        resetIn: resetAt.map { formatResetCountdown(to: $0, now: now) },
        windowSeconds: allowance > 0 && resetAt != nil ? JunieCreditCycle.windowSeconds : nil,
        detail: detail
      )],
      maxUsagePercent: remainingPercent.map { 100 - $0 },
      warning: warning,
      fetchedAt: now
    )
  }

  private static func configuredCycle(in credentials: [String: String]) throws -> JunieCreditCycle? {
    guard let text = nonEmptyString(credentials[CredentialField.junieResetAt]) else { return nil }
    guard let cycle = JunieCreditCycle(anchor: text) else {
      throw ProviderClientError(kind: .notConfigured, message: "Enter a valid reset date as YYYY-MM-DD or an ISO 8601 date-time with a timezone, or leave it empty if unknown.")
    }
    return cycle
  }

  private static func configuredAllowance(in credentials: [String: String]) throws -> Double? {
    guard let text = nonEmptyString(credentials[CredentialField.junieCreditAllowance]) else { return nil }
    guard let value = JunieCreditAllowance.parse(text) else {
      throw ProviderClientError(kind: .notConfigured, message: "Enter a nonnegative number of AI credits for the 30-day allowance, or 0 to show only the balance.")
    }
    return value
  }

  private static func displayBalance(_ balance: Double, isUSD: Bool) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.maximumFractionDigits = 6
    let amount: String
    if balance != 0, abs(balance) < 0.000001 {
      amount = String(format: "%.6g", locale: Locale(identifier: "en_US_POSIX"), balance).lowercased()
    } else {
      amount = formatter.string(from: NSNumber(value: balance)) ?? String(balance)
    }
    // Only recognized wire units reach display surfaces; arbitrary response
    // strings might contain reflected authentication material.
    return "\(amount) \(isUSD ? "USD" : "credits")"
  }

  private static var invalidResponse: ProviderClientError {
    ProviderClientError(kind: .api, message: "Junie did not report a valid balance. Check your JetBrains AI account or try again later.")
  }
}

private struct JunieBalance: Decodable {
  let active: Bool?
  let balanceLeft: Double?
  let balanceUnit: String?
  let licenseType: String?
}
