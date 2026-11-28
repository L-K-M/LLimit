import Foundation
import QuotaCore

struct VeniceWebQuotaClient: QuotaProviderClient {
  let provider: QuotaProvider = .venice
  private let api = VeniceQuotaClient(httpClient: URLSessionHTTPClient())

  func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    guard let profile = VeniceWebProfile.profile(from: configuration.credentials) else {
      return try await api.fetchUsage(configuration: configuration, now: now)
    }

    let hasAPIKey = configuration.credentials[CredentialField.veniceAPIKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    async let apiReading = apiUsage(configuration: configuration, now: now, hasAPIKey: hasAPIKey)
    let webReading: Result<UsageMetric?, Error>
    do {
      let reading = try await Self.read(profile)
      webReading = .success(try reading.subscription?.metric(asOf: now))
    } catch let failure as VeniceWebBrowser.Failure {
      webReading = .failure(failure.refreshError)
    } catch {
      webReading = .failure(error)
    }
    let keyed = await apiReading
    try Task.checkCancellation()

    switch webReading {
    case .success(let metric?):
      var usage = (try? keyed.get()) ?? ProviderUsage(accountID: configuration.accountID, provider: .venice,
        title: configuration.displayName, metrics: [], fetchedAt: now)
      if let index = usage.metrics.firstIndex(where: \.isVeniceSubscription) {
        usage.metrics[index] = metric
      } else {
        let index = usage.metrics.firstIndex { $0.id != "daily-diem" } ?? usage.metrics.endIndex
        usage.metrics.insert(metric, at: index)
      }
      usage.maxUsagePercent = usage.metrics.compactMap(\.remainingPercent).min().map { 100 - $0 }
      if case .failure = keyed {
        usage.warning = "Venice API key balances could not be refreshed."
      }
      return usage
    case .success(nil):
      if let usage = try keyed.get() { return usage }
      throw ProviderClientError(kind: .api, message: "Venice has no active subscription credit allowance.")
    case .failure(let error):
      if var usage = try? keyed.get() {
        let message = (error as? ProviderClientError)?.message ?? "Venice’s web dashboard is unavailable."
        usage.warning = [usage.warning, message].compactMap { $0 }.joined(separator: " ")
        return usage
      }
      throw error
    }
  }

  private func apiUsage(configuration: ProviderRuntimeConfiguration, now: Date,
                        hasAPIKey: Bool) async -> Result<ProviderUsage?, Error> {
    guard hasAPIKey else { return .success(nil) }
    do { return .success(try await api.fetchUsage(configuration: configuration, now: now)) }
    catch { return .failure(error) }
  }

  @MainActor
  private static func read(_ profile: VeniceWebProfile) async throws -> VeniceWebBrowser.Reading {
    let browser = VeniceWebBrowser(profileID: profile.id, interactive: false)
    defer { browser.stop() }
    let reading = try await browser.read()
    guard reading.userID == profile.userID else { throw VeniceWebBrowser.Failure.wrongAccount }
    return reading
  }
}
