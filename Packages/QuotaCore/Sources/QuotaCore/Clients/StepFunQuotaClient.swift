import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reads the global Step Plan console without making inference requests.
/// Console sessions are kept separate from StepFun inference API keys.
public struct StepFunQuotaClient: QuotaProviderClient {
  public let provider: QuotaProvider = .stepFun
  private let httpClient: any HTTPClient
  private static let endpoint = URL(string: "https://platform.stepfun.ai/api/step.openapi.devcenter.Dashboard/QueryStepPlanRateLimit")!

  public init(httpClient: any HTTPClient) { self.httpClient = httpClient }

  public func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    let token = configuration.credentials[CredentialField.stepFunSessionToken]?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let explicitWebID = configuration.credentials[CredentialField.stepFunWebID]?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let webID = explicitWebID.isEmpty ? Self.deviceID(from: token) ?? "" : explicitWebID
    guard Self.validHeaderValue(token), Self.validHeaderValue(webID) else {
      throw ProviderClientError(kind: .notConfigured,
        message: "Enter the StepFun console Oasis-Token and its matching Oasis-Webid. API keys are not supported.")
    }

    var request = URLRequest(url: Self.endpoint)
    request.httpMethod = "POST"
    request.httpBody = Data("{}".utf8)
    request.httpShouldHandleCookies = false
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue(token, forHTTPHeaderField: "Oasis-Token")
    request.setValue(webID, forHTTPHeaderField: "Oasis-Webid")
    request.setValue("20700", forHTTPHeaderField: "Oasis-Appid")
    request.setValue("web", forHTTPHeaderField: "Oasis-Platform")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("LLimit/0.1", forHTTPHeaderField: "User-Agent")

    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await httpClient.data(for: request, redirects: .refuse)
    } catch is CancellationError { throw CancellationError() }
    catch let error as URLError where error.code == .cancelled { throw CancellationError() }
    catch {
      throw ProviderClientError(kind: .network, message: "Could not reach StepFun. Check your connection and try again.")
    }
    if (300..<400).contains(response.statusCode) || [401, 403].contains(response.statusCode) {
      throw Self.authenticationFailure
    }
    guard (200..<300).contains(response.statusCode) else {
      throw ProviderClientError(kind: response.statusCode == 429 ? .rateLimit : .api,
        message: "StepFun quota request failed (HTTP \(response.statusCode)). Try again later.",
        statusCode: response.statusCode,
        retryAfter: response.statusCode == 429
          ? parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: now) : nil)
    }
    guard response.url?.scheme == Self.endpoint.scheme, response.url?.host == Self.endpoint.host,
          response.url?.port == Self.endpoint.port, response.url?.path == Self.endpoint.path else {
      throw Self.authenticationFailure
    }
    return try StepFunQuotaDecoder.decode(data, configuration: configuration, now: now)
  }

  private static func validHeaderValue(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 32_768
      && value.utf8.allSatisfy { (33...126).contains($0) }
  }

  private static func deviceID(from token: String) -> String? {
    // This unverified claim supplies only a routing header, never identity or
    // authorization. StepFun validates the token and device binding itself.
    guard token.utf8.count <= 32_768 else { return nil }
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }
    var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    guard let data = Data(base64Encoded: payload),
          let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return claims["device_id"] as? String
  }

  static var authenticationFailure: ProviderClientError {
    ProviderClientError(kind: .auth, message: "Your StepFun console session expired or was rejected. Replace the console token and matching web ID.")
  }
}
