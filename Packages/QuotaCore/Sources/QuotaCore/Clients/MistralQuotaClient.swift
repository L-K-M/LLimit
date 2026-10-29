import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct MistralConnection: Sendable {
  public let userID: String
  public let organizationID: String
  public let organizationName: String?
  public let usage: ProviderUsage
}

/// Read-only allowances from the official Admin subscription page. Vibe API
/// keys and its account/read RPC identify a plan but cannot read these budgets.
public struct MistralQuotaClient: QuotaProviderClient {
  public let provider: QuotaProvider = .mistral
  private let httpClient: any HTTPClient

  public init(httpClient: any HTTPClient) { self.httpClient = httpClient }

  public func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    guard configuration.credentials[CredentialField.mistralUserID]?.isEmpty == false,
          configuration.credentials[CredentialField.mistralOrganizationID]?.isEmpty == false else {
      throw ProviderClientError(kind: .notConfigured,
        message: "Reconnect Mistral to verify the account and organization before refreshing usage.")
    }
    return try await verifiedConnection(configuration: configuration, now: now).usage
  }

  /// CLI prompts and validation happen before acquiring the settings lock. The
  /// returned identity pins future refreshes to this session's organization.
  public func verifiedManualCredentials(header: String, now: Date = Date()) async throws -> [String: String] {
    let session = try MistralSessionCookies(header: header)
    let credentials = [CredentialField.mistralSessionCookies: session.header]
    let configuration = ProviderRuntimeConfiguration(provider: .mistral, displayName: "Mistral",
      isEnabled: true, credentials: credentials)
    let connection = try await verifiedConnection(configuration: configuration, now: now)
    return credentials.merging([CredentialField.mistralUserID: connection.userID,
      CredentialField.mistralOrganizationID: connection.organizationID]) { _, new in new }
  }

  public func verifiedConnection(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> MistralConnection {
    let header: String
    if let raw = configuration.credentials[CredentialField.mistralBrowserSession], !raw.isEmpty {
      let session = try MistralBrowserSession(serialized: raw)
      guard !session.isExpired(at: now) else { throw mistralReconnect }
      header = session.cookieHeader
    } else {
      guard let raw = configuration.credentials[CredentialField.mistralSessionCookies], !raw.isEmpty else {
        throw ProviderClientError(kind: .notConfigured, message: "Connect Mistral or enter your Admin session cookies.")
      }
      header = try MistralSessionCookies(header: raw).header
    }
    let url = MistralSignInPolicy.startURL
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue(header, forHTTPHeaderField: "Cookie")
    request.setValue("text/html", forHTTPHeaderField: "Accept")
    let (data, response) = try await httpClient.data(for: request, redirects: .refuse)
    guard response.url == url else { throw mistralReconnect }
    guard response.statusCode == 200 else {
      switch response.statusCode {
      case 300..<400, 401, 403: throw mistralReconnect
      case 429:
        throw ProviderClientError(kind: .rateLimit, message: "Mistral is rate limiting subscription requests. Try again later.",
                                  statusCode: 429, retryAfter: parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: now))
      default:
        throw ProviderClientError(kind: .api, message: "Mistral subscription request failed. Try again later.",
                                  statusCode: response.statusCode)
      }
    }
    guard data.count <= 5_000_000, let html = String(data: data, encoding: .utf8) else { throw MistralSubscription.invalid }
    let subscription = try MistralSubscription(html: html)
    for (key, actual) in [(CredentialField.mistralUserID, subscription.userID),
                          (CredentialField.mistralOrganizationID, subscription.organizationID)] {
      if let expected = configuration.credentials[key], !expected.isEmpty, expected != actual { throw mistralReconnect }
    }
    let metrics = [metric(subscription.vibe, id: "vibe-monthly", label: "Monthly Vibe Code", now: now),
                   metric(subscription.api, id: "api-monthly", label: "Monthly API allowance", now: now)]
    let maxUsage = metrics.compactMap(\.remainingPercent).map { 100 - $0 }.max()
    let usage = ProviderUsage(accountID: configuration.accountID, provider: provider, title: configuration.displayName,
      subtitle: subscription.organizationName ?? "Mistral monthly allowances", metrics: metrics,
      maxUsagePercent: maxUsage, warning: maxUsage.map { $0 >= 100 ? "Allowance reached" : ($0 >= 80 ? "High usage" : nil) } ?? nil,
      fetchedAt: now)
    return MistralConnection(userID: subscription.userID, organizationID: subscription.organizationID,
                             organizationName: subscription.organizationName, usage: usage)
  }

  private func metric(_ budget: MistralSubscription.Budget, id: String, label: String, now: Date) -> UsageMetric {
    let percent = budget.usedPercent.flatMap { percentRemaining(fromUsedPercent: $0) }
    let allowance = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), budget.allowance)
    var details = ["\(budget.currency) \(allowance) included"]
    if let used = budget.usedPercent {
      details.insert(String(format: "%.1f%% used", locale: Locale(identifier: "en_US_POSIX"), used), at: 0)
    } else { details.insert("Usage unavailable", at: 0) }
    return UsageMetric(id: id, label: label, remainingPercent: percent,
      resetAt: budget.resetAt, resetIn: budget.resetAt.map { formatResetCountdown(to: $0, now: now) },
      detail: details.joined(separator: " · "))
  }
}
