import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reads the Go subscription windows without making an inference request.
/// The server owns rolling-window length and subscription-anniversary resets;
/// neither is derived from the current clock or a hardcoded plan duration.
public struct OpenCodeGoQuotaClient: QuotaProviderClient {
  public let provider: QuotaProvider = .openCodeGo
  private let endpoint: URL
  private let httpClient: any HTTPClient

  public init(
    endpoint: URL = URL(string: "https://opencode.ai/zen/go/v1/usage")!,
    httpClient: any HTTPClient
  ) {
    self.endpoint = endpoint
    self.httpClient = httpClient
  }

  public func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    let apiKey = configuration.credentials[CredentialField.openCodeGoAPIKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !apiKey.isEmpty else {
      throw ProviderClientError(kind: .notConfigured, message: "OpenCode Go API key is not configured.")
    }
    guard apiKey.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
      throw ProviderClientError(kind: .notConfigured, message: "Enter an OpenCode Go API key without spaces or control characters.")
    }

    var request = URLRequest(url: endpoint)
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("LLimit/0.1", forHTTPHeaderField: "User-Agent")

    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await httpClient.data(for: request)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // Transport errors can include request details. Never persist them in
      // the snapshot's provider failure or expose them on display surfaces.
      throw ProviderClientError(kind: .network, message: "Could not reach OpenCode Go. Check your connection and try again.")
    }
    guard (200..<300).contains(response.statusCode) else {
      switch response.statusCode {
      case 401:
        throw ProviderClientError(kind: .auth, message: "OpenCode Go authorization failed. Check the API key.")
      case 403:
        throw ProviderClientError(kind: .auth, message: "OpenCode Go requires an active subscription for this API key's user.")
      case 429:
        throw ProviderClientError(kind: .rateLimit, message: "OpenCode Go is rate limiting usage requests. Try again later.")
      default:
        throw ProviderClientError(kind: .api, message: "OpenCode Go usage request failed (HTTP \(response.statusCode)). Try again later.")
      }
    }

    let windows: GoUsageWindows
    do {
      windows = try JSONDecoder().decode(GoUsageResponse.self, from: data).usage
    } catch {
      throw Self.invalidResponse
    }
    let metrics = try [
      metric(from: windows.rolling, id: "session-rolling", label: "Rolling limit", now: now),
      metric(from: windows.weekly, id: "weekly", label: "Weekly limit", now: now),
      metric(from: windows.monthly, id: "monthly", label: "Monthly limit", now: now)
    ]
    // A rate-limited window is exhausted regardless of the reported percent.
    let maxUsage = [windows.rolling, windows.weekly, windows.monthly]
      .map { $0.status == .rateLimited ? 100 : $0.percent }.max() ?? 0
    let limited = [windows.rolling, windows.weekly, windows.monthly].contains { $0.status == .rateLimited }

    return ProviderUsage(
      accountID: configuration.accountID,
      provider: provider,
      title: configuration.displayName,
      subtitle: "OpenCode Go",
      metrics: metrics,
      maxUsagePercent: maxUsage,
      warning: limited ? "Limit reached" : (maxUsage >= 80 ? "High usage" : nil),
      fetchedAt: now
    )
  }

  private func metric(from window: GoUsageWindow, id: String, label: String, now: Date) throws -> UsageMetric {
    guard (0...100).contains(window.percent),
          window.resetsAt.contains("T"),
          let resetAt = parseISO8601(window.resetsAt) else {
      throw Self.invalidResponse
    }
    // rate-limited means exhausted even if percent reads below 100 — the
    // endpoint proxies migrated keys, so trust the status over the number
    // instead of failing the whole fetch on the mismatch.
    let limited = window.status == .rateLimited
    return UsageMetric(
      id: id,
      label: label,
      remainingPercent: limited ? 0 : 100 - window.percent,
      usedDisplay: "\(window.percent)%",
      resetAt: resetAt,
      resetIn: formatResetCountdown(to: resetAt, now: now),
      detail: limited ? "Limit reached" : nil
    )
  }

  private static var invalidResponse: ProviderClientError {
    ProviderClientError(kind: .decoding, message: "OpenCode Go returned incomplete or invalid usage data. Try again later.")
  }
}

private struct GoUsageResponse: Decodable {
  let usage: GoUsageWindows
}

private struct GoUsageWindows: Decodable {
  let rolling: GoUsageWindow
  let weekly: GoUsageWindow
  let monthly: GoUsageWindow
}

private struct GoUsageWindow: Decodable {
  enum Status: String, Decodable {
    case ok
    case rateLimited = "rate-limited"
  }

  let status: Status
  let percent: Int
  let resetsAt: String
}
