import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reads the same account balance as Junie CLI's `/stats` command. The API
/// supplies neither an allowance total nor a reset, so this is an amount only.
public struct JunieQuotaClient: QuotaProviderClient {
  public let provider: QuotaProvider = .junie
  private let endpoint: URL
  private let httpClient: any HTTPClient

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

    return ProviderUsage(
      accountID: configuration.accountID, provider: provider, title: configuration.displayName,
      subtitle: "JetBrains AI",
      metrics: [UsageMetric(
        id: "credit-balance", label: "Credit balance", remainingAmount: balance,
        usedDisplay: Self.displayBalance(balance, isUSD: isUSD),
        detail: "JetBrains AI balance shared with Junie. No allowance total or reset is reported."
      )],
      warning: balance <= 0 ? "No JetBrains AI credits left" : nil,
      fetchedAt: now
    )
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
