import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Devin (Cognition) subscription quota.
///
/// `POST {server}/exa.seat_management_pb.SeatManagementService/GetUserStatus`
/// — the Connect-RPC call the Devin CLI's `/usage` command renders. The CLI
/// shares the Windsurf/Codeium backend, so the default server is
/// `server.codeium.com` and the session key `devin auth login` writes to
/// `credentials.toml` is still called `windsurf_api_key`. The key authenticates
/// as the proto `metadata.api_key`; a Bearer header is sent alongside it.
///
/// The response is protobuf-JSON under `userStatus.planStatus`:
///
///     {"dailyQuotaRemainingPercent": 42, "weeklyQuotaRemainingPercent": 87,
///      "dailyQuotaResetAtUnix": "1789372800", "weeklyQuotaResetAtUnix": "1789891200",
///      "availablePromptCredits": -1, "planStart": "…", "planEnd": "…",
///      "planInfo": {"planName": "Pro", "billingStrategy": "BILLING_STRATEGY_QUOTA"}}
///
/// int64s may arrive as strings and epoch resets as either form — parseNumeric/
/// parseDateValue cover both. `availablePromptCredits` is -1 on quota-billed
/// plans (the daily/weekly percents carry the signal) and a real count on
/// credit-billed ones.
public struct DevinQuotaClient: QuotaProviderClient {
  public let provider: QuotaProvider = .devin
  public static let defaultServerURL = URL(string: "https://server.codeium.com")!
  private static let servicePath = "exa.seat_management_pb.SeatManagementService/GetUserStatus"

  private let defaultEndpoint: URL
  private let httpClient: any HTTPClient

  public init(serverURL: URL = DevinQuotaClient.defaultServerURL, httpClient: any HTTPClient) {
    self.defaultEndpoint = serverURL.appending(path: Self.servicePath)
    self.httpClient = httpClient
  }

  public func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    let apiKey = configuration.credentials[CredentialField.devinAPIKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !apiKey.isEmpty else {
      throw ProviderClientError(kind: .notConfigured, message: "Devin API key is not configured")
    }

    // The per-account server URL (imported from credentials.toml) overrides the
    // default endpoint so enterprise/self-hosted logins keep working.
    let endpoint: URL
    let serverOverride = configuration.credentials[CredentialField.devinAPIServer]?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if serverOverride.isEmpty {
      endpoint = defaultEndpoint
    } else if let serverURL = URL(string: serverOverride), serverURL.host != nil {
      endpoint = serverURL.appending(path: Self.servicePath)
    } else {
      throw ProviderClientError(kind: .notConfigured, message: "Devin API server \"\(serverOverride)\" is not a valid URL")
    }

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("LLimit/0.1", forHTTPHeaderField: "User-Agent")
    // The backend parses ide/extension versions as strict semver — a two-part
    // version like "0.1" returns a 500 — and rejects requests that omit them.
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "metadata": [
        "api_key": apiKey,
        "ide_name": "llimit",
        "ide_version": "1.0.0",
        "extension_name": "llimit",
        "extension_version": "1.0.0"
      ]
    ])

    let (data, response) = try await httpClient.data(for: request)
    guard (200..<300).contains(response.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      switch response.statusCode {
      case 401, 403:
        throw ProviderClientError(kind: .auth, message: "Devin authorization failed (\(response.statusCode)) — check the API key or re-run `devin auth login`")
      case 429:
        throw ProviderClientError(kind: .rateLimit, message: "Devin API rate limited: \(body)")
      default:
        throw ProviderClientError(kind: .api, message: "Devin API error \(response.statusCode): \(body)")
      }
    }

    let payload = try parseJSONObject(from: data)
    let userStatus = (payload["userStatus"] as? [String: Any]) ?? [:]
    let planStatus = (userStatus["planStatus"] as? [String: Any]) ?? [:]
    let planInfo = (planStatus["planInfo"] as? [String: Any]) ?? [:]
    let devinInfo = (planInfo["devinInfo"] as? [String: Any]) ?? [:]

    var metrics: [UsageMetric] = []

    func quotaWindow(id: String, label: String, percentKey: String, resetKey: String) {
      guard let percent = parseNumeric(planStatus[percentKey]) else { return }
      let resetAt = parseDateValue(planStatus[resetKey])
      metrics.append(
        UsageMetric(
          id: id,
          label: label,
          remainingPercent: roundedPercent(percent),
          resetAt: resetAt,
          resetIn: resetAt.map { formatResetCountdown(to: $0, now: now) }
        )
      )
    }

    quotaWindow(id: "quota-daily", label: "Daily quota", percentKey: "dailyQuotaRemainingPercent", resetKey: "dailyQuotaResetAtUnix")
    quotaWindow(id: "quota-weekly", label: "Weekly quota", percentKey: "weeklyQuotaRemainingPercent", resetKey: "weeklyQuotaResetAtUnix")

    // Credit-billed plans report a real count; quota-billed ones send -1.
    if let credits = parseNumeric(planStatus["availablePromptCredits"]), credits >= 0 {
      let resetAt = parseDateValue(planStatus["planEnd"])
      metrics.append(
        UsageMetric(
          id: "credits",
          label: "Prompt credits remaining",
          usedDisplay: formatIntLike(credits),
          resetAt: resetAt,
          resetIn: resetAt.map { formatResetCountdown(to: $0, now: now) }
        )
      )
    }

    // Overage balance, when the account carries one (the CLI shows it as the
    // "extra usage balance" line). The key spelling is not documented, so
    // probe the plausible spots in both planStatus and userStatus.
    let balanceKeys = ["usageBalance", "extraUsageBalance", "usage_balance", "extra_usage_balance", "flexCredits"]
    if let balance = firstNumeric(in: planStatus, keys: balanceKeys) ?? firstNumeric(in: userStatus, keys: balanceKeys) {
      metrics.append(
        UsageMetric(id: "balance", label: "Extra usage balance", usedDisplay: formatIntLike(balance))
      )
    }

    if metrics.isEmpty {
      metrics.append(UsageMetric(id: "empty", label: "No quota data available"))
    }

    let maxUsagePercent = metrics.compactMap(\.remainingPercent).map { 100 - $0 }.max() ?? 0

    let actionLabel = nonEmptyString(
      ((devinInfo["requestUsageAction"] as? [String: Any])?["label"])
    )
    let warning: String?
    if maxUsagePercent >= 100 {
      warning = actionLabel ?? "Quota exhausted"
    } else {
      warning = maxUsagePercent >= 80 ? "High usage" : nil
    }

    let subtitle = [
      nonEmptyString(planInfo["planName"]).map { "\($0) plan" },
      nonEmptyString(devinInfo["accountDisplayName"])
    ].compactMap { $0 }.joined(separator: " · ")

    return ProviderUsage(
      accountID: configuration.accountID,
      provider: .devin,
      title: configuration.displayName,
      subtitle: subtitle.isEmpty ? nil : subtitle,
      metrics: metrics,
      maxUsagePercent: maxUsagePercent,
      warning: warning,
      fetchedAt: now
    )
  }
}
