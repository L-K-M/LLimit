import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct LongcatConnection: Sendable {
  public let userID: String
  public let usage: ProviderUsage
}

/// Reads owned console authentication, never an inference API key. Percentage
/// baselines are applied by the coordinator after the live balance is decoded.
public struct LongcatQuotaClient: QuotaProviderClient {
  public let provider: QuotaProvider = .longcat
  private let httpClient: any HTTPClient

  public init(httpClient: any HTTPClient) { self.httpClient = httpClient }

  public func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    guard configuration.credentials[CredentialField.longcatUserID]?.isEmpty == false else {
      throw ProviderClientError(kind: .notConfigured,
        message: "Connect Longcat or replace its session cookies to verify the account before refreshing.")
    }
    return try await verifiedConnection(configuration: configuration, now: now).usage
  }

  public func verifiedManualCredentials(header: String, now: Date = Date()) async throws -> [String: String] {
    let cookies = try LongcatSessionCookies(header: header)
    let configuration = ProviderRuntimeConfiguration(provider: .longcat, displayName: "Longcat", isEnabled: true,
      credentials: [CredentialField.longcatSessionCookies: cookies.header])
    let connection = try await verifiedConnection(configuration: configuration, now: now)
    return [CredentialField.longcatSessionCookies: cookies.header, CredentialField.longcatUserID: connection.userID]
  }

  public func verifiedConnection(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> LongcatConnection {
    let header: String
    if let raw = configuration.credentials[CredentialField.longcatBrowserSession], !raw.isEmpty {
      let browser = try LongcatBrowserSession(serialized: raw)
      guard !browser.isExpired(at: now) else { throw Self.reconnect }
      header = browser.cookieHeader
    } else {
      guard let raw = configuration.credentials[CredentialField.longcatSessionCookies], !raw.isEmpty else {
        throw ProviderClientError(kind: .notConfigured, message: "Connect Longcat or enter its console session cookies.")
      }
      header = try LongcatSessionCookies(header: raw).header
    }

    let user: User = try await request("/api/v1/user-current", header: header, now: now)
    guard user.loginStatus == 1, !user.userID.isEmpty, user.userID.utf8.count <= 256,
          user.userID.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
      throw Self.reconnect
    }
    if let expected = configuration.credentials[CredentialField.longcatUserID], !expected.isEmpty,
       expected != user.userID { throw Self.reconnect }
    // Both identity and authentication belong to the observation. Reconnecting
    // cannot measure a different login against the former account's baseline.
    let keyHash = credentialFingerprint(user.userID + "\n" + header)
    let metrics: [UsageMetric]
    do {
      let summary: Summary = try await request("/api/pay/quota/metering/token-packs/summary",
        post: true, header: header, now: now)
      if summary.currentLot == nil && summary.otherLots.isEmpty {
        metrics = [try await legacyMetric(header: header, keyHash: keyHash, now: now)]
      } else {
        metrics = try summary.metrics(keyHash: keyHash)
      }
    } catch let error as ProviderClientError where error.statusCode == 404 {
      // Older console deployments expose only the legacy aggregate. Auth,
      // transport and decoding failures must retain the last good snapshot.
      metrics = [try await legacyMetric(header: header, keyHash: keyHash, now: now)]
    }
    return LongcatConnection(userID: user.userID,
      usage: ProviderUsage(accountID: configuration.accountID, provider: provider, title: configuration.displayName,
        subtitle: "Longcat tokens", metrics: metrics, fetchedAt: now))
  }

  private func legacyMetric(header: String, keyHash: String, now: Date) async throws -> UsageMetric {
    let legacy: Legacy = try await request("/api/lc-platform/v1/tokenUsage", header: header, now: now)
    let balance = try legacy.balance()
    return Self.metric(id: "token-balance", label: "Tokens remaining", amount: balance, keyHash: keyHash)
  }

  private func request<T: Decodable>(_ path: String, post: Bool = false, header: String, now: Date) async throws -> T {
    let url = URL(string: "https://longcat.chat" + path)!
    var request = URLRequest(url: url)
    request.httpMethod = post ? "POST" : "GET"
    if post {
      request.httpBody = Data("{}".utf8)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    request.httpShouldHandleCookies = false
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue(header, forHTTPHeaderField: "Cookie")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
    request.setValue("https://longcat.chat", forHTTPHeaderField: "Origin")
    request.setValue(LongcatSignInPolicy.startURL.absoluteString, forHTTPHeaderField: "Referer")
    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await httpClient.data(for: request, redirects: .refuse)
    } catch is CancellationError { throw CancellationError() }
    catch let error as URLError where error.code == .cancelled { throw CancellationError() }
    catch {
      throw ProviderClientError(kind: .network, message: "Could not reach Longcat. Check your connection and try again.")
    }
    guard response.url == url else { throw Self.reconnect }
    switch response.statusCode {
    case 200: break
    case 300..<400, 401, 403: throw Self.reconnect
    case 429:
      throw ProviderClientError(kind: .rateLimit, message: "Longcat is rate limiting usage requests. Try again later.",
        statusCode: 429, retryAfter: parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: now))
    default:
      throw ProviderClientError(kind: .api, message: "Longcat usage request failed. Try again later.", statusCode: response.statusCode)
    }
    guard data.count <= 2_000_000 else { throw Self.invalid }
    // Inspect the wrapper before its payload: expired sessions can return null
    // data with HTTP 200 and must be classified as authentication failures.
    let wrapper: Wrapper
    do { wrapper = try JSONDecoder().decode(Wrapper.self, from: data) }
    catch { throw Self.invalid }
    switch wrapper.code {
    case 0, 200: break
    case 401, 403: throw Self.reconnect
    case 429:
      throw ProviderClientError(kind: .rateLimit, message: "Longcat is rate limiting usage requests. Try again later.")
    default: throw ProviderClientError(kind: .api, message: "Longcat could not read usage. Try again later.")
    }
    do { return try JSONDecoder().decode(Envelope<T>.self, from: data).data }
    catch { throw Self.invalid }
  }

  private struct Wrapper: Decodable { let code: Int }
  private struct Envelope<T: Decodable>: Decodable { let data: T }

  private struct User: Decodable {
    let userID: String
    let loginStatus: Int
    enum CodingKeys: String, CodingKey { case userId, loginStatus }
    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      loginStatus = try c.decode(Int.self, forKey: .loginStatus)
      if let id = try? c.decode(String.self, forKey: .userId) { userID = id }
      else { userID = try c.decodeIfPresent(Int64.self, forKey: .userId).map(String.init) ?? "" }
    }
  }

  private struct Count: Decodable {
    let value: Double
    init(from decoder: Decoder) throws {
      let c = try decoder.singleValueContainer()
      if let text = try? c.decode(String.self), let number = Double(text) { value = number }
      else { value = try c.decode(Double.self) }
      guard value.isFinite, value >= 0, value.rounded(.towardZero) == value else { throw invalid }
    }
  }

  private struct Legacy: Decodable {
    struct Usage: Decodable {
      let totalToken: Count
      let availableToken: Count?
      let usedToken: Count?
    }
    let usage: Usage
    init(from decoder: Decoder) throws {
      struct Nested: Decodable { let usage: Usage }
      if let nested = try? Nested(from: decoder) { usage = nested.usage }
      else { usage = try Usage(from: decoder) }
    }
    func balance() throws -> Double {
      if let available = usage.availableToken { return available.value }
      guard let used = usage.usedToken, used.value <= usage.totalToken.value else { throw invalid }
      return usage.totalToken.value - used.value
    }
  }

  private struct Summary: Decodable {
    let currentLot: Lot?
    let otherLots: [Lot]

    func metrics(keyHash: String) throws -> [UsageMetric] {
      let lots = [currentLot].compactMap { $0 } + otherLots
      var seen: Set<String> = []
      var groups: [String: (models: [String], amount: Double)] = [:]
      for lot in lots {
        // A duplicated lot must not double the remaining balance.
        guard seen.insert(lot.lotId).inserted else { throw invalid }
        if let status = lot.status, status.uppercased() != "ACTIVE" { continue }
        let models = try lot.models()
        let key = models.joined(separator: "\n")
        let prior = groups[key]?.amount ?? 0
        let amount = prior + lot.remainingToken.value
        guard amount.isFinite else { throw invalid }
        groups[key] = (models, amount)
      }
      guard !groups.isEmpty else {
        return [metric(id: "token-balance", label: "Tokens remaining", amount: 0, keyHash: keyHash)]
      }
      return groups.keys.sorted().map { key in
        let group = groups[key]!
        let allModels = group.models == ["ALL"]
        return metric(id: allModels ? "token-balance" : "token-balance-" + credentialFingerprint(key),
          label: allModels ? "Tokens remaining" : group.models.joined(separator: ", ") + " tokens remaining",
          amount: group.amount, keyHash: keyHash)
      }
    }
  }

  private struct Lot: Decodable {
    let lotId: String
    let remainingToken: Count
    let modelScope: String?
    let status: String?
    enum CodingKeys: String, CodingKey { case lotId, remainingToken, modelScope, status }
    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      if let id = try? c.decode(String.self, forKey: .lotId) { lotId = id }
      else { lotId = try c.decode(Int64.self, forKey: .lotId).description }
      guard !lotId.isEmpty else { throw invalid }
      remainingToken = try c.decode(Count.self, forKey: .remainingToken)
      modelScope = try c.decodeIfPresent(String.self, forKey: .modelScope)
      status = try c.decodeIfPresent(String.self, forKey: .status)
    }
    func models() throws -> [String] {
      guard let modelScope, !modelScope.isEmpty else { return ["ALL"] }
      guard let scope = try? JSONSerialization.jsonObject(with: Data(modelScope.utf8)) as? [String: Any] else { throw invalid }
      // Match the official console: an absent/empty list is unscoped, and
      // only nonempty model names participate in grouping.
      let models = (scope["models"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
      guard models.allSatisfy({ $0.count <= 150 }) else { throw invalid }
      return models.isEmpty ? ["ALL"] : Array(Set(models)).sorted()
    }
  }

  private static func metric(id: String, label: String, amount: Double, keyHash: String) -> UsageMetric {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 0
    let display = formatter.string(from: NSNumber(value: amount)) ?? String(amount)
    return UsageMetric(id: id, label: label, remainingAmount: amount, estimateKeyHash: keyHash,
      usedDisplay: "\(display) tokens", detail: "Remaining token balance. No reset schedule is reported.")
  }

  private static var reconnect: ProviderClientError {
    ProviderClientError(kind: .auth, message: "Longcat needs you to sign in again. Connect Longcat or replace its console session cookies.")
  }
  private static var invalid: ProviderClientError {
    ProviderClientError(kind: .decoding, message: "Longcat returned incomplete or invalid token data. Try again later.")
  }
}
