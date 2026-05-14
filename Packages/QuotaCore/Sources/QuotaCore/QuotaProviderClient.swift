import Foundation

public protocol QuotaProviderClient: Sendable {
  var provider: QuotaProvider { get }
  func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage
}
