import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GoogleAntigravityClient: QuotaProviderClient {
  public let provider: QuotaProvider = .googleAntigravity
  private let httpClient: any HTTPClient

  private static let tokenRefreshURL = URL(string: "https://oauth2.googleapis.com/token")!
  private static let modelsURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels")!
  private static let userAgent = "antigravity/1.11.9 windows/amd64"

  // OAuth credentials used by antigravity auth flow.
  private static let clientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
  private static let clientSecret = "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"

  private let modelSpecs: [(key: String, altKey: String?, label: String)] = [
    ("gemini-3-pro-high", "gemini-3-pro-low", "G3 Pro"),
    ("gemini-3-pro-image", nil, "G3 Image"),
    ("gemini-3-flash", nil, "G3 Flash"),
    ("claude-opus-4-5-thinking", "claude-opus-4-5", "Claude")
  ]

  public init(httpClient: any HTTPClient) {
    self.httpClient = httpClient
  }

  public func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    guard let refreshToken = configuration.credentials[CredentialField.googleRefreshToken], !refreshToken.isEmpty else {
      throw ProviderClientError(kind: .notConfigured, message: "Google refresh token is not configured")
    }

    guard let projectID = configuration.credentials[CredentialField.googleProjectID], !projectID.isEmpty else {
      throw ProviderClientError(kind: .notConfigured, message: "Google project ID is not configured")
    }

    let email = configuration.credentials[CredentialField.googleEmail]

    let accessToken = try await refreshAccessToken(refreshToken: refreshToken)
    let modelsPayload = try await fetchAvailableModels(accessToken: accessToken, projectID: projectID)

    guard let modelsObject = modelsPayload["models"] as? [String: Any] else {
      throw ProviderClientError(kind: .decoding, message: "Google response missing models object")
    }

    var metrics: [UsageMetric] = []
    var maxUsage = 0

    for spec in modelSpecs {
      var modelInfo = modelsObject[spec.key] as? [String: Any]
      if modelInfo == nil, let altKey = spec.altKey {
        modelInfo = modelsObject[altKey] as? [String: Any]
      }

      guard let modelInfo else { continue }

      let quotaInfo = modelInfo["quotaInfo"] as? [String: Any]
      let remainingFraction = parseNumeric(quotaInfo?["remainingFraction"]) ?? 0
      guard let remainingPercent = roundedPercent(remainingFraction * 100) else { continue }
      let usagePercent = 100 - remainingPercent
      maxUsage = max(maxUsage, usagePercent)

      let resetDate = parseISO8601(quotaInfo?["resetTime"] as? String)

      metrics.append(
        UsageMetric(
          id: spec.key,
          label: spec.label,
          remainingPercent: remainingPercent,
          resetAt: resetDate,
          resetIn: resetDate.map { formatResetCountdown(to: $0, now: now) }
        )
      )
    }

    if metrics.isEmpty {
      metrics.append(UsageMetric(id: "empty", label: "No quota data available"))
    }

    return ProviderUsage(
      accountID: configuration.accountID,
      provider: .googleAntigravity,
      title: configuration.displayName,
      subtitle: email,
      metrics: metrics,
      maxUsagePercent: maxUsage,
      warning: maxUsage >= 80 ? "High usage" : nil,
      fetchedAt: now
    )
  }

  private func refreshAccessToken(refreshToken: String) async throws -> String {
    var request = URLRequest(url: Self.tokenRefreshURL)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

    var bodyComponents = URLComponents()
    bodyComponents.queryItems = [
      URLQueryItem(name: "client_id", value: Self.clientID),
      URLQueryItem(name: "client_secret", value: Self.clientSecret),
      URLQueryItem(name: "refresh_token", value: refreshToken),
      URLQueryItem(name: "grant_type", value: "refresh_token")
    ]

    request.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)

    let (data, response) = try await httpClient.data(for: request)
    guard (200..<300).contains(response.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      let kind: QuotaErrorKind = response.statusCode == 400 || response.statusCode == 401 ? .auth : .api
      throw ProviderClientError(kind: kind, message: "Google token refresh failed \(response.statusCode): \(body)")
    }

    guard
      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let token = payload["access_token"] as? String,
      !token.isEmpty
    else {
      throw ProviderClientError(kind: .decoding, message: "Google token refresh payload missing access_token")
    }

    return token
  }

  private func fetchAvailableModels(accessToken: String, projectID: String) async throws -> [String: Any] {
    var request = URLRequest(url: Self.modelsURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["project": projectID])

    let (data, response) = try await httpClient.data(for: request)
    guard (200..<300).contains(response.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      let kind: QuotaErrorKind = response.statusCode == 401 || response.statusCode == 403 ? .auth : .api
      throw ProviderClientError(kind: kind, message: "Google quota API failed \(response.statusCode): \(body)")
    }

    return try parseJSONObject(from: data)
  }
}
