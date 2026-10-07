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

    // Cooldowns belong to an enabled account and provider, not just an id.
    // Bound persisted deadlines from their original cycle, never from each poll.
    let cooldownFailures = (previousSnapshot?.failures ?? []).compactMap { failure -> ProviderFailure? in
      guard failure.kind == .rateLimit,
            targets.contains(where: { $0.accountID == failure.accountID && $0.provider == failure.provider }),
            let retryAt = failure.retryAt,
            retryAt.timeIntervalSince1970.isFinite,
            let previousSnapshot else { return nil }
      let cooldownStart = min(previousSnapshot.generatedAt, now)
      let deadline = min(retryAt, cooldownStart.addingTimeInterval(RetryAfterPolicy.maximumDelay))
      guard deadline > now else { return nil }
      var bounded = failure
      bounded.retryAt = deadline
      return bounded
    }
    let fetchTargets = targets.filter { configuration in
      !cooldownFailures.contains { $0.accountID == configuration.accountID && $0.provider == configuration.provider }
    }

    let results = await withTaskGroup(of: RefreshResult.self) { group in
      for configuration in fetchTargets {
        guard let client = clientsByProvider[configuration.provider] else { continue }

        group.addTask {
          do {
            try Task.checkCancellation()
            let usage = try await client.fetchUsage(configuration: configuration, now: now)
            return RefreshResult(
              accountID: configuration.accountID,
              provider: configuration.provider,
              outcome: .usage(usage)
            )
          } catch is CancellationError {
            return RefreshResult(accountID: configuration.accountID, provider: configuration.provider, outcome: .cancelled)
          } catch let error as URLError where error.code == .cancelled {
            return RefreshResult(accountID: configuration.accountID, provider: configuration.provider, outcome: .cancelled)
          } catch let error as ProviderClientError {
            return RefreshResult(
              accountID: configuration.accountID,
              provider: configuration.provider,
              outcome: .failure(ProviderFailure(
                accountID: configuration.accountID,
                provider: configuration.provider,
                kind: error.kind,
                message: failureMessages.redacted(error.message),
                retryAt: error.kind == .rateLimit
                  ? RetryAfterPolicy.boundedDelay(error.retryAfter).map { now.addingTimeInterval($0) } : nil
              ))
            )
          } catch {
            return RefreshResult(
              accountID: configuration.accountID,
              provider: configuration.provider,
              outcome: .failure(ProviderFailure(
                accountID: configuration.accountID,
                provider: configuration.provider,
                kind: .unknown,
                message: "Could not read usage. Try again later."
              ))
            )
          }
        }
      }

      var collected = cooldownFailures.map {
        RefreshResult(accountID: $0.accountID, provider: $0.provider, outcome: .failure($0))
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
    var usages = ordered.compactMap(\.usage).map {
      VeniceQuotaEstimate.applying(to: $0, previous: previousByID[$0.accountID])
    }
    var failures = ordered.compactMap(\.failure)

    // Cancellation has no failure to drive mergingStaleUsage. Carry only the
    // cancelled targets, with their original timestamps and existing errors.
    for result in ordered where result.isCancelled {
      if let previous = previousSnapshot?.providers.filter({
        $0.accountID == result.accountID && $0.provider == result.provider
      }).max(by: { $0.fetchedAt < $1.fetchedAt }) {
        usages.append(previous)
      }
      failures += (previousSnapshot?.failures ?? []).filter {
        $0.accountID == result.accountID && $0.provider == result.provider
      }
    }

    let generatedAt = ordered.allSatisfy(\.isCancelled) ? previousSnapshot?.generatedAt ?? now : now
    return QuotaSnapshot(generatedAt: generatedAt, providers: usages, failures: failures)
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
  enum Outcome: Sendable {
    case usage(ProviderUsage)
    case failure(ProviderFailure)
    case cancelled
  }

  let accountID: String
  let provider: QuotaProvider
  let outcome: Outcome

  var usage: ProviderUsage? {
    guard case let .usage(usage) = outcome else { return nil }
    return usage
  }

  var failure: ProviderFailure? {
    guard case let .failure(failure) = outcome else { return nil }
    return failure
  }

  var isCancelled: Bool {
    if case .cancelled = outcome { return true }
    return false
  }
}
