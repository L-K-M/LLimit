import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CopilotClient: QuotaProviderClient {
  public let provider: QuotaProvider = .gitHubCopilot
  private let httpClient: any HTTPClient

  private static let apiBaseURL = URL(string: "https://api.github.com")!
  private static let copilotVersion = "0.35.0"
  private static let editorVersion = "vscode/1.107.0"
  private static let pluginVersion = "copilot-chat/\(copilotVersion)"
  private static let userAgent = "GitHubCopilotChat/\(copilotVersion)"

  private static let tierLimits: [CopilotTier: Int] = [
    .free: 50,
    .pro: 300,
    .proPlus: 1500,
    .business: 300,
    .enterprise: 1000
  ]

  private static let quotaUnavailableMessage =
    "Copilot quota API unavailable with current OAuth token. Configure a PAT plus username, or a working OAuth token."

  public init(httpClient: any HTTPClient) {
    self.httpClient = httpClient
  }

  public func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    let pat = configuration.credentials[CredentialField.copilotPATToken] ?? ""
    let username = configuration.credentials[CredentialField.copilotUsername] ?? ""
    let tierRaw = configuration.credentials[CredentialField.copilotTier] ?? ""

    if
      !pat.isEmpty,
      !username.isEmpty
    {
      return try await fetchFromPublicBillingAPI(
        configuration: configuration,
        patToken: pat,
        username: username,
        tier: parseTier(tierRaw),
        now: now
      )
    }

    let oauth = configuration.credentials[CredentialField.copilotOAuthToken] ?? ""
    guard !oauth.isEmpty else {
      throw ProviderClientError(
        kind: .notConfigured,
        message: "Copilot PAT credentials or OAuth token are not configured"
      )
    }

    return try await fetchFromInternalAPI(configuration: configuration, oauthToken: oauth, now: now)
  }

  private func fetchFromPublicBillingAPI(
    configuration: ProviderRuntimeConfiguration,
    patToken: String,
    username: String,
    tier: CopilotTier?,
    now: Date
  ) async throws -> ProviderUsage {
    var request = URLRequest(
      url: Self.apiBaseURL.appending(path: "users/\(username)/settings/billing/premium_request/usage")
    )
    request.httpMethod = "GET"
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(patToken)", forHTTPHeaderField: "Authorization")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

    let (data, response) = try await httpClient.data(for: request)
    guard (200..<300).contains(response.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      let kind: QuotaErrorKind = response.statusCode == 401 || response.statusCode == 403 ? .auth : .api
      throw ProviderClientError(kind: kind, message: "Copilot billing API failed \(response.statusCode): \(body)")
    }

    let payload: BillingUsageResponse
    do {
      payload = try JSONDecoder().decode(BillingUsageResponse.self, from: data)
    } catch {
      throw ProviderClientError(kind: .decoding, message: "Copilot billing payload decoding failed: \(error.localizedDescription)")
    }

    let premiumItems = payload.usageItems.filter {
      $0.sku == "Copilot Premium Request" || $0.sku.localizedCaseInsensitiveContains("Premium")
    }

    let totalUsed = premiumItems.reduce(0) { $0 + $1.grossQuantity }
    let inferredLimit = premiumItems.compactMap(\.limit).max()
    let limit = tier.flatMap { Self.tierLimits[$0] } ?? inferredLimit

    let remainingPercent: Int?
    let totalDisplay: String?

    if let limit, limit > 0 {
      let remaining = max(0, limit - totalUsed)
      remainingPercent = clampPercent(Int((Double(remaining) / Double(limit) * 100.0).rounded()))
      totalDisplay = String(limit)
    } else {
      remainingPercent = nil
      totalDisplay = nil
    }

    let resetAt = payload.timePeriod.month.flatMap { monthEndDate(year: payload.timePeriod.year, month: $0) }
      ?? startOfNextMonth(from: now)
    let metric = UsageMetric(
      id: "premium",
      label: "Premium requests",
      remainingPercent: remainingPercent,
      usedDisplay: String(totalUsed),
      totalDisplay: totalDisplay,
      resetAt: resetAt,
      resetIn: resetAt.map { formatResetCountdown(to: $0, now: now) }
    )

    let maxUsage = remainingPercent.map { 100 - $0 }
    return ProviderUsage(
      accountID: configuration.accountID,
      provider: .gitHubCopilot,
      title: configuration.displayName,
      subtitle: {
        if let tier {
          return "@\(payload.user) (\(tier.rawValue))"
        }
        return "@\(payload.user)"
      }(),
      metrics: [metric],
      maxUsagePercent: maxUsage,
      warning: (maxUsage ?? 0) >= 80 ? "High usage" : nil,
      fetchedAt: now
    )
  }

  private func fetchFromInternalAPI(
    configuration: ProviderRuntimeConfiguration,
    oauthToken: String,
    now: Date
  ) async throws -> ProviderUsage {
    if let payload = try await fetchInternalUser(token: oauthToken, mode: .legacyToken) {
      return buildUsage(from: payload, configuration: configuration, now: now)
    }

    if let payload = try await fetchInternalUser(token: oauthToken, mode: .bearer) {
      return buildUsage(from: payload, configuration: configuration, now: now)
    }

    if let sessionToken = try await exchangeForSessionToken(oauthToken: oauthToken) {
      if let payload = try await fetchInternalUser(token: sessionToken, mode: .bearer) {
        return buildUsage(from: payload, configuration: configuration, now: now)
      }
    }

    throw ProviderClientError(kind: .auth, message: Self.quotaUnavailableMessage)
  }

  private func buildUsage(
    from payload: InternalUsageResponse,
    configuration: ProviderRuntimeConfiguration,
    now: Date
  ) -> ProviderUsage {

    var metrics: [UsageMetric] = []
    let resetAt = parseDateValue(payload.quotaResetDate) ?? startOfNextMonth(from: now)
    let resetIn = resetAt.map { formatResetCountdown(to: $0, now: now) }

    if let premium = payload.quotaSnapshots.premiumInteractions {
      metrics.append(metric(from: premium, label: "Premium", id: "premium", resetAt: resetAt, resetIn: resetIn))
    }

    if let chat = payload.quotaSnapshots.chat, !chat.unlimited {
      metrics.append(metric(from: chat, label: "Chat", id: "chat", resetAt: resetAt, resetIn: resetIn))
    }

    if let completions = payload.quotaSnapshots.completions, !completions.unlimited {
      metrics.append(metric(from: completions, label: "Completions", id: "completions", resetAt: resetAt, resetIn: resetIn))
    }

    if metrics.isEmpty {
      metrics.append(
        UsageMetric(
          id: "empty",
          label: "No quota data available",
          resetAt: resetAt,
          resetIn: resetIn
        )
      )
    }

    let maxUsage = metrics
      .compactMap(\.remainingPercent)
      .map { 100 - $0 }
      .max()

    return ProviderUsage(
      accountID: configuration.accountID,
      provider: .gitHubCopilot,
      title: configuration.displayName,
      subtitle: payload.copilotPlan,
      metrics: metrics,
      maxUsagePercent: maxUsage,
      warning: (maxUsage ?? 0) >= 80 ? "High usage" : nil,
      fetchedAt: now
    )
  }

  private func fetchInternalUser(token: String, mode: AuthorizationMode) async throws -> InternalUsageResponse? {
    var request = URLRequest(url: Self.apiBaseURL.appending(path: "copilot_internal/user"))
    request.httpMethod = "GET"
    request.allHTTPHeaderFields = buildCopilotHeaders(token: token, mode: mode)

    let (data, response) = try await httpClient.data(for: request)
    guard (200..<300).contains(response.statusCode) else {
      if response.statusCode == 429 {
        let body = String(data: data, encoding: .utf8) ?? ""
        throw ProviderClientError(kind: .rateLimit, message: "Copilot quota API rate limited: \(body)")
      }
      if [401, 403, 404].contains(response.statusCode) {
        return nil
      }
      return nil
    }

    do {
      return try JSONDecoder().decode(InternalUsageResponse.self, from: data)
    } catch {
      throw ProviderClientError(kind: .decoding, message: "Copilot internal payload decoding failed: \(error.localizedDescription)")
    }
  }

  private func metric(
    from quota: InternalQuotaDetail,
    label: String,
    id: String,
    resetAt: Date?,
    resetIn: String?
  ) -> UsageMetric {
    if quota.unlimited {
      return UsageMetric(
        id: id,
        label: label,
        resetAt: resetAt,
        resetIn: resetIn,
        isUnlimited: true
      )
    }

    let remainingPercent = clampPercent(Int(quota.percentRemaining.rounded()))
    let used = max(0, quota.entitlement - quota.remaining)

    return UsageMetric(
      id: id,
      label: label,
      remainingPercent: remainingPercent,
      usedDisplay: String(used),
      totalDisplay: String(quota.entitlement),
      resetAt: resetAt,
      resetIn: resetIn
    )
  }

  private func exchangeForSessionToken(oauthToken: String) async throws -> String? {
    let paths = ["copilot_internal/v2/token", "copilot_internal/token"]

    for path in paths {
      var request = URLRequest(url: Self.apiBaseURL.appending(path: path))
      request.httpMethod = "GET"
      request.allHTTPHeaderFields = buildCopilotHeaders(token: oauthToken, mode: .bearer)

      let (data, response) = try await httpClient.data(for: request)
      guard (200..<300).contains(response.statusCode) else {
        if response.statusCode == 429 {
          let body = String(data: data, encoding: .utf8) ?? ""
          throw ProviderClientError(kind: .rateLimit, message: "Copilot token exchange rate limited: \(body)")
        }
        continue
      }

      let payload: SessionTokenResponse
      do {
        payload = try JSONDecoder().decode(SessionTokenResponse.self, from: data)
      } catch {
        continue
      }

      if !payload.token.isEmpty {
        return payload.token
      }
    }

    return nil
  }

  private func parseTier(_ raw: String) -> CopilotTier? {
    let normalized = raw
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: " ", with: "")

    switch normalized {
    case "free":
      return .free
    case "pro":
      return .pro
    case "pro+", "proplus":
      return .proPlus
    case "business":
      return .business
    case "enterprise":
      return .enterprise
    default:
      return nil
    }
  }

  private func buildCopilotHeaders(token: String, mode: AuthorizationMode) -> [String: String] {
    let authorization: String
    switch mode {
    case .bearer:
      authorization = "Bearer \(token)"
    case .legacyToken:
      authorization = "token \(token)"
    }

    return [
      "Accept": "application/json",
      "Authorization": authorization,
      "User-Agent": Self.userAgent,
      "Editor-Version": Self.editorVersion,
      "Editor-Plugin-Version": Self.pluginVersion,
      "Copilot-Integration-Id": "vscode-chat"
    ]
  }
}

private enum AuthorizationMode {
  case bearer
  case legacyToken
}

private enum CopilotTier: String, Codable {
  case free
  case pro
  case proPlus = "pro+"
  case business
  case enterprise
}

private struct BillingUsageResponse: Decodable {
  struct TimePeriod: Decodable {
    let year: Int
    let month: Int?
  }

  struct UsageItem: Decodable {
    let product: String
    let sku: String
    let model: String?
    let unitType: String
    let grossQuantity: Int
    let netQuantity: Int
    let limit: Int?
  }

  let timePeriod: TimePeriod
  let user: String
  let usageItems: [UsageItem]
}

private struct SessionTokenResponse: Decodable {
  let token: String
  let expiresAt: Int?
  let refreshIn: Int?

  enum CodingKeys: String, CodingKey {
    case token
    case expiresAt = "expires_at"
    case refreshIn = "refresh_in"
  }
}

private struct InternalUsageResponse: Decodable {
  let copilotPlan: String
  let quotaResetDate: String
  let quotaSnapshots: InternalQuotaSnapshots

  enum CodingKeys: String, CodingKey {
    case copilotPlan = "copilot_plan"
    case quotaResetDate = "quota_reset_date"
    case quotaSnapshots = "quota_snapshots"
  }
}

private struct InternalQuotaSnapshots: Decodable {
  let chat: InternalQuotaDetail?
  let completions: InternalQuotaDetail?
  let premiumInteractions: InternalQuotaDetail?

  enum CodingKeys: String, CodingKey {
    case chat
    case completions
    case premiumInteractions = "premium_interactions"
  }
}

private struct InternalQuotaDetail: Decodable {
  let entitlement: Int
  let overageCount: Int
  let overagePermitted: Bool
  let percentRemaining: Double
  let quotaID: String
  let quotaRemaining: Int
  let remaining: Int
  let unlimited: Bool

  enum CodingKeys: String, CodingKey {
    case entitlement
    case overageCount = "overage_count"
    case overagePermitted = "overage_permitted"
    case percentRemaining = "percent_remaining"
    case quotaID = "quota_id"
    case quotaRemaining = "quota_remaining"
    case remaining
    case unlimited
  }
}
