import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Uses the same read-only personal Token Plan queries as Xiaomi's console.
/// No inference request, API-key creation, or subscription mutation is needed.
public struct MiMoQuotaClient: QuotaProviderClient {
  public let provider: QuotaProvider = .xiaomiMiMo
  private let httpClient: any HTTPClient

  public init(httpClient: any HTTPClient) { self.httpClient = httpClient }

  public func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    let cookies = try MiMoSessionCookies(header: configuration.credentials[CredentialField.mimoSessionCookies] ?? "")
    async let detail = fetch("detail", cookies: cookies)
    async let usage = fetch("usage", cookies: cookies)
    return try await MiMoTokenPlanDecoder.decode(detailData: detail, usageData: usage,
      accountID: configuration.accountID, title: configuration.displayName, now: now)
  }

  private func fetch(_ resource: String, cookies: MiMoSessionCookies) async throws -> Data {
    let url = URL(string: "https://\(MiMoSessionCookies.consoleHost)/api/v1/tokenPlan/\(resource)")!
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    request.setValue(cookies.header, forHTTPHeaderField: "Cookie")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("en", forHTTPHeaderField: "Accept-Language")
    request.setValue("UTC", forHTTPHeaderField: "x-timeZone")
    request.setValue("LLimit/0.1", forHTTPHeaderField: "User-Agent")
    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await httpClient.data(for: request, redirects: .refuse)
    } catch is CancellationError { throw CancellationError() }
    catch let error as URLError where error.code == .cancelled { throw CancellationError() }
    catch { throw ProviderClientError(kind: .network, message: "Could not reach MiMo. Check your connection and try again.") }
    if [301, 302, 303, 307, 308, 401, 403].contains(response.statusCode) {
      throw ProviderClientError(kind: .auth, message: "Your MiMo console session expired or was rejected. Connect MiMo to sign in again.")
    }
    guard (200..<300).contains(response.statusCode) else {
      throw ProviderClientError(kind: response.statusCode == 429 ? .rateLimit : .api,
        message: "MiMo quota request failed (HTTP \(response.statusCode)). Try again later.", statusCode: response.statusCode)
    }
    guard response.url?.scheme == "https", response.url?.host == MiMoSessionCookies.consoleHost,
          response.url?.path == url.path else {
      throw ProviderClientError(kind: .auth, message: "MiMo redirected the quota request. Connect MiMo to sign in again.")
    }
    return data
  }
}
