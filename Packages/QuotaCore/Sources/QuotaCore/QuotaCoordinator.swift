import Foundation

public struct QuotaCoordinator: Sendable {
  private let clientsByProvider: [QuotaProvider: any QuotaProviderClient]

  public init(clients: [any QuotaProviderClient]) {
    self.clientsByProvider = Dictionary(uniqueKeysWithValues: clients.map { ($0.provider, $0) })
  }

  public static func live(httpClient: any HTTPClient = URLSessionHTTPClient(),
                          managedOpenAI: (any ManagedOpenAIUsageSource)? = nil) -> QuotaCoordinator {
    QuotaCoordinator(
      clients: [
        AnthropicClient(httpClient: httpClient),
        OpenAIClient(httpClient: httpClient, managedSource: managedOpenAI),
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
        KimiQuotaClient(httpClient: httpClient),
        GoogleAntigravityClient(httpClient: httpClient),
        CopilotClient(httpClient: httpClient),
        DevinQuotaClient(httpClient: httpClient),
        MetaMuseQuotaClient(httpClient: httpClient),
        OpenCodeGoQuotaClient(httpClient: httpClient),
        VeniceQuotaClient(httpClient: httpClient),
        ClineQuotaClient(httpClient: httpClient)
      ]
    )
  }

  public func refresh(configurations: [ProviderRuntimeConfiguration], now: Date = Date(),
                      previousSnapshot: QuotaSnapshot? = nil) async -> QuotaSnapshot {
    let targets = configurations
      .filter { $0.isEnabled }
      .filter { clientsByProvider[$0.provider] != nil }

    // Honor the server's Retry-After: polling a rate-limited account before
    // its retry time only hardens the limit (Anthropic's endpoint is the
    // documented worst case). The failure carries forward unchanged so the
    // cooldown and its retryAt survive consecutive cycles, and callers
    // backfill last-known usage via mergingStaleUsage, which keys off the
    // failure's presence. Accounts no longer being polled (removed or
    // disabled since the previous snapshot) must not drag their cooldown
    // failure into every future snapshot.
    let configuredAccountIDs = Set(targets.map(\.accountID))
    let cooldownFailures = (previousSnapshot?.failures ?? [])
      .filter { $0.kind == .rateLimit && ($0.retryAt ?? .distantPast) > now }
      .filter { configuredAccountIDs.contains($0.accountID) }
    let cooledAccountIDs = Set(cooldownFailures.map(\.accountID))
    let fetchTargets = targets.filter { !cooledAccountIDs.contains($0.accountID) }

    let results = await withTaskGroup(of: RefreshResult.self) { group in
      for configuration in fetchTargets {
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
                message: error.message,
                retryAt: error.retryAfter.map { now.addingTimeInterval($0) }
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

      var collected = cooldownFailures.map { failure in
        RefreshResult(
          accountID: failure.accountID,
          provider: failure.provider,
          usage: nil,
          failure: failure
        )
      }
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

    let previousByID = Dictionary(
      (previousSnapshot?.providers ?? []).filter { $0.provider == .venice }.map { ($0.accountID, $0) },
      uniquingKeysWith: { $0.fetchedAt >= $1.fetchedAt ? $0 : $1 }
    )
    let usages = ordered.compactMap(\.usage).map {
      VeniceQuotaEstimate.applying(to: $0, previous: previousByID[$0.accountID])
    }
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
