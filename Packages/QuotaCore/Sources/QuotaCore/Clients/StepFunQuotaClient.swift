import Foundation
import CoreFoundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reads global personal Step Plan quota without making inference requests.
/// Step Code's Plan key and the console session use separate endpoints.
public struct StepFunQuotaClient: QuotaProviderClient {
  public let provider: QuotaProvider = .stepFun
  private let httpClient: any HTTPClient

  public init(httpClient: any HTTPClient) { self.httpClient = httpClient }

  public func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    let key = configuration.credentials[CredentialField.stepFunPlanKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !key.isEmpty {
      guard Self.validHeaderValue(key) else {
        throw ProviderClientError(kind: .notConfigured, message: "Import a valid global personal Step Plan key from Step Code.")
      }
      let endpoint = URL(string: "https://api.stepfun.ai/step_plan/v1/usage")!
      var request = URLRequest(url: endpoint)
      request.httpMethod = "GET"
      request.httpShouldHandleCookies = false
      request.cachePolicy = .reloadIgnoringLocalCacheData
      request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      let data = try await send(request, endpoint: endpoint, now: now, authenticationFailure: Self.planAuthenticationFailure)
      guard data.count <= 256 * 1_024 else {
        throw ProviderClientError(kind: .decoding, message: "StepFun returned an oversized personal Plan usage response. Try again later.")
      }
      return try StepFunPlanQuotaDecoder.decode(data, configuration: configuration, now: now)
    }
    let data = try await fetch("QueryStepPlanRateLimit", configuration: configuration, now: now)
    return try StepFunQuotaDecoder.decode(data, configuration: configuration, now: now)
  }

  public func verifyIdentity(configuration: ProviderRuntimeConfiguration, now: Date = Date()) async throws -> String {
    let data = try await fetch("UserInfo", configuration: configuration, now: now)
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          Self.isOKStatus(object["status"]),
          let uid = object["uid"] else { throw Self.invalidIdentity }
    let id: String
    if let text = uid as? String { id = text }
    else if let number = uid as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { id = number.stringValue }
    else { throw Self.invalidIdentity }
    guard !id.isEmpty, id.utf8.count <= 20, id.utf8.allSatisfy({ (48...57).contains($0) }),
          let number = UInt64(id), number > 0, number <= UInt64(Int64.max) else { throw Self.invalidIdentity }
    return id
  }

  private func fetch(_ procedure: String, configuration: ProviderRuntimeConfiguration, now: Date) async throws -> Data {
    let endpoint = URL(string: "https://platform.stepfun.ai/api/step.openapi.devcenter.Dashboard/\(procedure)")!
    let token = configuration.credentials[CredentialField.stepFunSessionToken]?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let explicitWebID = configuration.credentials[CredentialField.stepFunWebID]?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let webID = explicitWebID.isEmpty ? Self.deviceID(from: token) ?? "" : explicitWebID
    guard Self.validHeaderValue(token), Self.validHeaderValue(webID) else {
      throw ProviderClientError(kind: .notConfigured,
        message: "Import a personal Step Plan key, or enter the StepFun console Oasis-Token and its matching Oasis-Webid.")
    }

    let browser: StepFunBrowserSession?
    if let raw = configuration.credentials[CredentialField.stepFunBrowserSession] {
      let saved = try StepFunBrowserSession(serialized: raw)
      guard saved.accessToken == token, saved.webID == webID,
            !saved.isExpired(at: now), !saved.isAccessExpired(at: now) else {
        throw Self.authenticationFailure
      }
      browser = saved
    } else if token.contains("...") {
      let manual = try StepFunBrowserSession(compoundToken: token, webID: webID)
      guard !manual.isExpired(at: now), !manual.isAccessExpired(at: now) else { throw Self.authenticationFailure }
      browser = manual
    } else { browser = nil }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.httpBody = Data("{}".utf8)
    request.httpShouldHandleCookies = false
    request.cachePolicy = .reloadIgnoringLocalCacheData
    if let browser {
      // Match the console's own HttpOnly authentication cookie. This is only
      // LLimit's isolated login, never a normal browser or shared cookie jar.
      request.setValue(browser.cookieHeader, forHTTPHeaderField: "Cookie")
    } else {
      request.setValue(token, forHTTPHeaderField: "Oasis-Token")
    }
    request.setValue(webID, forHTTPHeaderField: "Oasis-Webid")
    request.setValue("20700", forHTTPHeaderField: "Oasis-Appid")
    request.setValue("web", forHTTPHeaderField: "Oasis-Platform")
    request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("LLimit/0.1", forHTTPHeaderField: "User-Agent")

    return try await send(request, endpoint: endpoint, now: now, authenticationFailure: Self.authenticationFailure)
  }

  private func send(_ request: URLRequest, endpoint: URL, now: Date,
                    authenticationFailure: ProviderClientError) async throws -> Data {
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
      throw authenticationFailure
    }
    guard (200..<300).contains(response.statusCode) else {
      throw ProviderClientError(kind: response.statusCode == 429 ? .rateLimit : .api,
        message: "StepFun quota request failed (HTTP \(response.statusCode)). Try again later.",
        statusCode: response.statusCode,
        retryAfter: response.statusCode == 429
          ? parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: now) : nil)
    }
    guard response.url?.scheme == endpoint.scheme, response.url?.host == endpoint.host,
          response.url?.port == endpoint.port, response.url?.path == endpoint.path else {
      throw authenticationFailure
    }
    return data
  }

  private static func validHeaderValue(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 32_768
      && value.utf8.allSatisfy { (33...126).contains($0) }
  }

  private static func deviceID(from token: String) -> String? {
    // This unverified claim supplies only a routing header, never identity or
    // authorization. StepFun validates the token and device binding itself.
    guard token.utf8.count <= 32_768 else { return nil }
    let compound = token.components(separatedBy: "...")
    let jwt = compound.count == 2 ? compound[1] : token
    let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }
    var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    guard let data = Data(base64Encoded: payload),
          let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return claims["device_id"] as? String
  }

  static var authenticationFailure: ProviderClientError {
    ProviderClientError(kind: .auth, message: "Your StepFun session expired or was rejected. Connect StepFun to sign in again, or replace manual credentials on Linux.")
  }
  private static var planAuthenticationFailure: ProviderClientError {
    ProviderClientError(kind: .auth, message: "Your StepFun Plan key was rejected. Reimport your Step Code login or reconnect StepFun.")
  }
  private static var invalidIdentity: ProviderClientError {
    ProviderClientError(kind: .auth, message: "StepFun could not verify this account. Connect StepFun to sign in again.")
  }
  private static func isOKStatus(_ value: Any?) -> Bool {
    if let name = value as? String { return name == "CODE_OK" }
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
    return number.doubleValue == 1
  }
}
