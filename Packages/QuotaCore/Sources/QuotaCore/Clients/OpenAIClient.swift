import Foundation

public struct OpenAIClient: QuotaProviderClient {
  public let provider: QuotaProvider = .openAI
  private let httpClient: any HTTPClient

  public init(httpClient: any HTTPClient) {
    self.httpClient = httpClient
  }

  public func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    guard let accessToken = configuration.credentials[CredentialField.openAIAccessToken], !accessToken.isEmpty else {
      throw ProviderClientError(kind: .notConfigured, message: "OpenAI access token is not configured")
    }

    var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
    request.httpMethod = "GET"
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("LLimit/0.1", forHTTPHeaderField: "User-Agent")

    if let accountID = configuration.credentials[CredentialField.openAIAccountID], !accountID.isEmpty {
      request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
    }

    let (data, response) = try await httpClient.data(for: request)
    guard (200..<300).contains(response.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
      let kind: QuotaErrorKind = response.statusCode == 401 || response.statusCode == 403 ? .auth : .api
      if kind == .auth {
        throw ProviderClientError(
          kind: kind,
          message: "OpenAI authentication failed (\(response.statusCode)). Use a valid ChatGPT web access token, not a platform API key.",
          statusCode: response.statusCode
        )
      }

      let bodySuffix = trimmedBody.isEmpty ? "" : ": \(trimmedBody)"
      throw ProviderClientError(
        kind: kind,
        message: "OpenAI API error \(response.statusCode)\(bodySuffix)",
        statusCode: response.statusCode
      )
    }

    let payload: OpenAIUsageResponse
    do {
      payload = try JSONDecoder().decode(OpenAIUsageResponse.self, from: data)
    } catch {
      throw ProviderClientError(kind: .decoding, message: "OpenAI response decoding failed: \(error.localizedDescription)")
    }

    var metrics: [UsageMetric] = []

    if let primary = payload.rate_limit?.primary_window {
      metrics.append(makeMetric(id: "primary", window: primary, now: now))
    }

    if let secondary = payload.rate_limit?.secondary_window {
      metrics.append(makeMetric(id: "secondary", window: secondary, now: now))
    }

    if metrics.isEmpty {
      metrics.append(
        UsageMetric(
          id: "empty",
          label: "No rate limit data",
          detail: "OpenAI returned no active windows"
        )
      )
    }

    let maxUsage = metrics
      .compactMap(\.remainingPercent)
      .map { 100 - $0 }
      .max()

    return ProviderUsage(
      accountID: configuration.accountID,
      provider: .openAI,
      title: configuration.displayName,
      subtitle: payload.plan_type,
      metrics: metrics,
      maxUsagePercent: maxUsage,
      warning: payload.rate_limit?.limit_reached == true ? "Rate limit reached" : nil,
      fetchedAt: now
    )
  }

  private func makeMetric(id: String, window: RateLimitWindow, now: Date) -> UsageMetric {
    let remainingPercent = percentRemaining(fromUsedPercent: window.used_percent)
    let resetSeconds = max(0, window.reset_after_seconds)
    let resetAt = now.addingTimeInterval(Double(resetSeconds))

    return UsageMetric(
      id: id,
      label: formatWindowName(seconds: window.limit_window_seconds),
      remainingPercent: remainingPercent,
      resetAt: resetAt,
      resetIn: formatShortDuration(seconds: resetSeconds)
    )
  }

  private func formatWindowName(seconds: Int) -> String {
    let days = Int((Double(seconds) / 86_400.0).rounded())
    if days >= 1 {
      return "\(days)-day limit"
    }

    let hours = max(1, Int((Double(seconds) / 3_600.0).rounded()))
    return "\(hours)-hour limit"
  }
}

private struct OpenAIUsageResponse: Decodable {
  let plan_type: String
  let rate_limit: RateLimitContainer?
}

private struct RateLimitContainer: Decodable {
  let limit_reached: Bool
  let primary_window: RateLimitWindow?
  let secondary_window: RateLimitWindow?
}

private struct RateLimitWindow: Decodable {
  let used_percent: Double
  let limit_window_seconds: Int
  let reset_after_seconds: Int
}
