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
    let failureMessages = FailureMessagePolicy(configurations: configurations)
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
                message: failureMessages.redacted(error.message)
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
                message: "Could not read usage. Try again later."
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

private struct FailureMessagePolicy: Sendable {
  private static let maximumScalarCount = 512
  private let secrets: [String]

  init(configurations: [ProviderRuntimeConfiguration]) {
    let hiddenSecretKeys: Set<String> = [CredentialField.openAIRefreshToken, CredentialField.kimiRefreshToken]
    let values = configurations.flatMap { configuration in
      let keys = Set(configuration.provider.credentialFields.filter(\.isSecret).map(\.key))
        .union(hiddenSecretKeys)
      return configuration.credentials.compactMap { key, value in
        keys.contains(key) && !value.isEmpty ? value : nil
      }
    }
    secrets = Set(values).sorted { $0.count > $1.count }
  }

  func redacted(_ message: String) -> String {
    // Redact before truncation so a length boundary cannot retain a secret prefix.
    let redacted = secrets.reduce(message) { $0.replacingOccurrences(of: $1, with: "[redacted]") }
    let clean = redacted.components(separatedBy: .controlCharacters)
      .joined(separator: " ")
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
    return String(String.UnicodeScalarView(clean.unicodeScalars.prefix(Self.maximumScalarCount)))
  }
}

private struct RefreshResult: Sendable {
  var accountID: String
  var provider: QuotaProvider
  var usage: ProviderUsage?
  var failure: ProviderFailure?
}
