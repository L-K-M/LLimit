import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Tencent Cloud TokenHub "Token Plan" quota via the signed control plane.
///
/// Personal `sk-tp-…`/Coding Plan `sk-sp-…` keys are inference-only — Tencent
/// exposes no usage endpoint for them — so this client calls the documented
/// `tokenhub` API 3.0 actions `DescribeTokenPlanList` + `DescribeTokenPlan`
/// with TC3-HMAC-SHA256 SecretId/SecretKey credentials, then renders each
/// plan's `PackageInfo` the way the official thcli does: total quota across
/// the package, the current month's exclusive-pool usage, and the shared pool.
public struct TencentTokenHubClient: QuotaProviderClient {
  public let provider: QuotaProvider = .tencentTokenHub

  private static let service = "tokenhub"
  private static let version = "2026-03-22"
  private static let defaultEndpoint = "https://tokenhub.intl.tencentcloudapi.com"
  private static let defaultRegion = "ap-singapore"
  private static let listPageSize = 100

  private let httpClient: HTTPClient

  public init(httpClient: HTTPClient = URLSessionHTTPClient()) {
    self.httpClient = httpClient
  }

  public func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    let credentials = try Self.credentials(from: configuration)
    let teamIDs = try await teamIDs(credentials: credentials, timestamp: now)
    // Sequential: accounts hold a handful of plans and each call is one POST.
    var plans: [[String: Any]] = []
    for teamID in teamIDs {
      plans.append(try await describePlan(teamID: teamID, credentials: credentials, timestamp: now))
    }
    var metrics: [UsageMetric] = []
    var stoppedReasons: [String] = []
    for plan in plans {
      let planMetrics = Self.metrics(for: plan, now: now)
      metrics.append(contentsOf: planMetrics)
      let reason = nonEmptyString(plan["StopReason"])
      let stopped = (plan["Status"] as? String)?.lowercased() == "disable"
      if stopped, let reason, reason.uppercased() != "NORMAL" {
        stoppedReasons.append(reason)
      }
    }

    var warning: String?
    if plans.isEmpty || metrics.isEmpty {
      warning = "No Token Plan packages found on this Tencent Cloud account."
    } else if let reason = stoppedReasons.first {
      warning = "Token Plan is stopped (\(reason))."
    }

    return ProviderUsage(
      accountID: configuration.accountID,
      provider: provider,
      title: configuration.displayName,
      subtitle: "Token Plan",
      metrics: metrics,
      warning: warning,
      fetchedAt: now
    )
  }

  // MARK: - credentials

  private struct SignedCredentials {
    let signer: TencentCloudTC3Signer
    let endpoint: URL
  }

  private static func credentials(from configuration: ProviderRuntimeConfiguration) throws -> SignedCredentials {
    let resolved = configuration.credentials.resolvingEnvironmentReferences()
    guard let secretID = resolved[CredentialField.tokenhubSecretID]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !secretID.isEmpty else {
      throw ProviderClientError(kind: .notConfigured,
        message: "Add a Tencent Cloud SecretId — the plan API key (sk-tp-…) cannot query quota.")
    }
    guard let secretKey = resolved[CredentialField.tokenhubSecretKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !secretKey.isEmpty else {
      throw ProviderClientError(kind: .notConfigured, message: "Add a Tencent Cloud SecretKey.")
    }

    let endpointText = resolved[CredentialField.tokenhubEndpoint]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let endpoint: URL
    if let endpointText, !endpointText.isEmpty {
      guard let parsed = URL(string: endpointText), parsed.host != nil, parsed.scheme == "https" else {
        throw ProviderClientError(kind: .notConfigured, message: "TokenHub endpoint must be a valid https:// URL.")
      }
      endpoint = parsed
    } else {
      endpoint = URL(string: defaultEndpoint)!
    }

    let region = resolved[CredentialField.tokenhubRegion]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let sessionToken = resolved[CredentialField.tokenhubSessionToken]?.trimmingCharacters(in: .whitespacesAndNewlines)

    return SignedCredentials(
      signer: TencentCloudTC3Signer(
        secretID: secretID,
        secretKey: secretKey,
        sessionToken: sessionToken?.isEmpty == false ? sessionToken : nil,
        service: service,
        region: region?.isEmpty == false ? region : defaultRegion
      ),
      endpoint: endpoint
    )
  }

  // MARK: - API calls

  private func teamIDs(credentials: SignedCredentials, timestamp: Date) async throws -> [String] {
    let response = try await call(
      action: "DescribeTokenPlanList",
      payload: ["Offset": 0, "Limit": Self.listPageSize],
      credentials: credentials,
      timestamp: timestamp
    )
    guard let plans = response["TokenPlanSet"] as? [[String: Any]] else {
      throw ProviderClientError(kind: .decoding, message: "Unexpected TokenHub plan list response")
    }
    return plans.compactMap { nonEmptyString($0["TeamId"]) }
  }

  private func describePlan(teamID: String, credentials: SignedCredentials, timestamp: Date) async throws -> [String: Any] {
    let response = try await call(
      action: "DescribeTokenPlan",
      payload: ["TeamId": teamID],
      credentials: credentials,
      timestamp: timestamp
    )
    // thcli accepts `Response.Team ?? Response`: newer API builds nest the
    // plan under `Team`, the original SDK documented the fields inline.
    guard let plan = (response["Team"] as? [String: Any]) ?? (response["TeamId"] != nil ? response : nil) else {
      throw ProviderClientError(kind: .decoding, message: "Unexpected TokenHub plan response")
    }
    return plan
  }

  private func call(action: String, payload: [String: Any], credentials: SignedCredentials, timestamp: Date) async throws -> [String: Any] {
    let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    let request = try credentials.signer.signedRequest(
      action: action,
      version: Self.version,
      body: body,
      endpoint: credentials.endpoint,
      timestamp: timestamp
    )

    let (data, response): (Data, HTTPURLResponse)
    do {
      (data, response) = try await httpClient.data(for: request)
    } catch let error as ProviderClientError {
      throw error
    } catch {
      throw ProviderClientError(kind: .network, message: "Could not reach the provider. Check your connection and try again.")
    }

    // Tencent answers API errors with HTTP 200 carrying an `Error` object, so
    // the body is always inspected before the status decides anything.
    let object: [String: Any]
    do {
      object = try parseJSONObject(from: data)
    } catch {
      throw Self.error(forStatusCode: response.statusCode, response: response)
    }
    guard let envelope = object["Response"] as? [String: Any] else {
      throw Self.error(forStatusCode: response.statusCode, response: response)
    }
    if let apiError = envelope["Error"] as? [String: Any] {
      throw Self.error(apiError: apiError, response: response)
    }
    guard (200..<300).contains(response.statusCode) else {
      throw Self.error(forStatusCode: response.statusCode, response: response)
    }
    return envelope
  }

  private static func error(apiError: [String: Any], response: HTTPURLResponse) -> ProviderClientError {
    let code = nonEmptyString(apiError["Code"]) ?? "unknown"
    let kind: QuotaErrorKind
    if code.hasPrefix("AuthFailure") || code.hasPrefix("Unauthorized") || code.hasPrefix("InvalidCredential") {
      kind = .auth
    } else if code.hasPrefix("RequestLimitExceeded") || code.hasPrefix("Throttling") {
      kind = .rateLimit
    } else {
      kind = errorKind(forStatusCode: response.statusCode)
    }
    // The code is a stable enum member; Message could echo request internals.
    return ProviderClientError(kind: kind, message: "Tencent TokenHub returned \(code)",
      statusCode: response.statusCode,
      retryAfter: kind == .rateLimit
        ? parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: Date())
        : nil)
  }

  private static func error(forStatusCode statusCode: Int, response: HTTPURLResponse) -> ProviderClientError {
    ProviderClientError(kind: errorKind(forStatusCode: statusCode),
      message: "Tencent TokenHub request failed (HTTP \(statusCode))",
      statusCode: statusCode,
      retryAfter: parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: Date()))
  }

  // MARK: - metrics

  /// Renders one plan the way `thcli describe plan` does. `Unit` is credits
  /// for enterprise products, tokens otherwise — the same field magnitudes
  /// measure different things across product types.
  static func metrics(for plan: [String: Any], now: Date) -> [UsageMetric] {
    guard let package = plan["PackageInfo"] as? [String: Any] else { return [] }

    let teamID = nonEmptyString(plan["TeamId"]) ?? "plan"
    let name = nonEmptyString(plan["Name"]) ?? teamID
    let unit = (plan["ProductType"] as? String)?.hasPrefix("enterprise") == true ? "credits" : "tokens"
    let summary = plan["TokenSummary"] as? [String: Any]
    let cycleStart = summary.flatMap { firstDateValue(in: $0, keys: ["CycleStartTime"]) }
    let cycleEnd = summary.flatMap { firstDateValue(in: $0, keys: ["CycleEndTime"]) }
    let cycleWindow: Int? = {
      guard let cycleStart, let cycleEnd, cycleEnd > cycleStart else { return nil }
      return roundedInt(cycleEnd.timeIntervalSince(cycleStart))
    }()
    let expire = firstDateValue(in: package, keys: ["ExpireTime"])

    let disabled = (plan["Status"] as? String)?.lowercased() == "disable"
    let stopReason = nonEmptyString(plan["StopReason"])
    let statusNote: String? = {
      guard disabled || (stopReason?.uppercased() != "NORMAL" && stopReason != nil) else { return nil }
      return stopReason.map { "Stopped: \($0)" } ?? "Stopped"
    }()

    var metrics: [UsageMetric] = []

    // Current billing cycle — the ring users watch. Exclusive-pool usage is
    // the cycle's consumption; CycleQuota alone means the pool isn't split.
    let exclusiveTotal = firstNumeric(in: package, keys: ["ExclusiveAllocated"])
    let exclusiveUsed = firstNumeric(in: package, keys: ["ExclusiveUsed"])
    let cycleQuota = firstNumeric(in: package, keys: ["CycleQuota"])
    let currentCycle = firstNumeric(in: package, keys: ["CurrentCycle"]).flatMap(roundedInt)
    let totalCycles = firstNumeric(in: package, keys: ["TotalCycles"]).flatMap(roundedInt)
    var cycleDetail = ["per-cycle \(unit)"]
    if let currentCycle, let totalCycles { cycleDetail.append("cycle \(currentCycle)/\(totalCycles)") }
    if let statusNote { cycleDetail.append(statusNote) }

    if let exclusiveTotal, exclusiveTotal > 0, let exclusiveUsed {
      metrics.append(UsageMetric(
        id: "\(teamID)-cycle",
        label: "\(name) monthly quota",
        remainingPercent: remainingPercent(used: exclusiveUsed, total: exclusiveTotal),
        usedDisplay: formatIntLike(exclusiveUsed).map { "\($0) \(unit)" },
        totalDisplay: "\(formatIntLike(exclusiveTotal) ?? "") \(unit)",
        resetAt: cycleEnd,
        windowSeconds: cycleWindow,
        detail: cycleDetail.joined(separator: " · ")
      ))
    } else if let cycleQuota, cycleQuota > 0 {
      metrics.append(UsageMetric(
        id: "\(teamID)-cycle",
        label: "\(name) monthly quota",
        totalDisplay: "\(formatIntLike(cycleQuota) ?? "") \(unit)",
        resetAt: cycleEnd,
        windowSeconds: cycleWindow,
        detail: cycleDetail.joined(separator: " · ")
      ))
    }

    // Shared pool: top-up balance shared by all plans on the account.
    let sharedTotal = firstNumeric(in: package, keys: ["SharedPool"])
    if let sharedTotal, sharedTotal > 0, let sharedUsed = firstNumeric(in: package, keys: ["SharedUsed"]) {
      metrics.append(UsageMetric(
        id: "\(teamID)-shared",
        label: "\(name) shared pool",
        remainingPercent: remainingPercent(used: sharedUsed, total: sharedTotal),
        usedDisplay: formatIntLike(sharedUsed).map { "\($0) \(unit)" },
        totalDisplay: "\(formatIntLike(sharedTotal) ?? "") \(unit)",
        resetAt: expire,
        detail: statusNote
      ))
    }

    // Whole package: TotalUsed accumulates across every cycle, ExpireTime is
    // the plan's end — a package-level gauge, not a resetting window.
    let total = firstNumeric(in: package, keys: ["TotalQuota"])
    let used = firstNumeric(in: package, keys: ["TotalUsed"])
    if let total, total > 0 {
      var detail = ["whole package"]
      if let totalCycles { detail.append("\(totalCycles) cycles") }
      if let statusNote { detail.append(statusNote) }
      metrics.append(UsageMetric(
        id: "\(teamID)-total",
        label: name,
        remainingPercent: used.flatMap { remainingPercent(used: $0, total: total) },
        usedDisplay: used.flatMap(formatIntLike).map { "\($0) \(unit)" },
        totalDisplay: "\(formatIntLike(total) ?? "") \(unit)",
        resetAt: expire,
        detail: detail.joined(separator: " · ")
      ))
    }
    return metrics
  }

  private static func remainingPercent(used: Double, total: Double) -> Int? {
    guard total > 0, used.isFinite else { return nil }
    return roundedPercent((1.0 - used / total) * 100.0)
  }
}
