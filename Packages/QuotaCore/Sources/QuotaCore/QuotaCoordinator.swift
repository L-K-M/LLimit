import Foundation

public struct QuotaCoordinator: Sendable {
  private let clientsByProvider: [QuotaProvider: any QuotaProviderClient]

  public init(clients: [any QuotaProviderClient]) {
    self.clientsByProvider = Dictionary(uniqueKeysWithValues: clients.map { ($0.provider, $0) })
  }

  public static func live(httpClient: any HTTPClient = URLSessionHTTPClient()) -> QuotaCoordinator {
    QuotaCoordinator(
      clients: [
        AnthropicClient(httpClient: httpClient),
        OpenAIClient(httpClient: httpClient),
        ZhipuQuotaClient(
          provider: .zhipu,
          endpoint: URL(string: "https://bigmodel.cn/api/monitor/usage/quota/limit")!,
          accountLabel: "Coding Plan",
          httpClient: httpClient
        ),
        ZhipuQuotaClient(
          provider: .zai,
          endpoint: URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!,
          accountLabel: "Z.ai",
          httpClient: httpClient
        ),
        GoogleAntigravityClient(httpClient: httpClient),
        CopilotClient(httpClient: httpClient)
      ]
    )
  }

  public func refresh(configurations: [ProviderRuntimeConfiguration], now: Date = Date()) async -> QuotaSnapshot {
    let targets = configurations
      .filter { $0.isEnabled }
      .filter { clientsByProvider[$0.provider] != nil }

    let results = await withTaskGroup(of: RefreshResult.self) { group in
      for configuration in targets {
        guard let client = clientsByProvider[configuration.provider] else { continue }

        group.addTask {
          do {
            let usage = try await client.fetchUsage(configuration: configuration, now: now)
            return RefreshResult(
              accountID: configuration.accountID,
              provider: configuration.provider,
              usage: usage,
              failure: nil
            )
          } catch let error as ProviderClientError {
            return RefreshResult(
              accountID: configuration.accountID,
              provider: configuration.provider,
              usage: nil,
              failure: ProviderFailure(
                accountID: configuration.accountID,
                provider: configuration.provider,
                kind: error.kind,
                message: error.message
              )
            )
          } catch {
            return RefreshResult(
              accountID: configuration.accountID,
              provider: configuration.provider,
              usage: nil,
              failure: ProviderFailure(
                accountID: configuration.accountID,
                provider: configuration.provider,
                kind: .unknown,
                message: error.localizedDescription
              )
            )
          }
        }
      }

      var collected: [RefreshResult] = []
      for await result in group {
        collected.append(result)
      }
      return collected
    }

    let ordered = results.sorted { lhs, rhs in
      if lhs.provider.rawValue != rhs.provider.rawValue {
        return lhs.provider.rawValue < rhs.provider.rawValue
      }
      return lhs.accountID < rhs.accountID
    }

    let usages = ordered.compactMap(\.usage)
    let failures = ordered.compactMap(\.failure)
    return QuotaSnapshot(generatedAt: now, providers: usages, failures: failures)
  }
}

private struct RefreshResult: Sendable {
  var accountID: String
  var provider: QuotaProvider
  var usage: ProviderUsage?
  var failure: ProviderFailure?
}
