import Foundation

/// Snapshot-only account selection for check/pick and the most constrained display.
public enum HeadroomRanking {
  public static let defaultMaxAge = QuotaFreshness.legacyMaxAge

  public enum Headroom: Hashable, Comparable, Sendable {
    case percent(Int)
    case unlimited
  }

  public enum Eligibility: Hashable, Sendable {
    /// Nil uses the shared snapshot cadence policy; an explicit age overrides it.
    case current(maxAge: TimeInterval?)
    case anyReported
  }

  public struct Filter: Hashable, Sendable {
    public var providers: Set<QuotaProvider>?
    public var accountKeys: Set<QuotaAccountKey>?
    public var kind: QuotaWindowKind?
    public var eligibility: Eligibility

    public init(providers: Set<QuotaProvider>? = nil, accountKeys: Set<QuotaAccountKey>? = nil,
                kind: QuotaWindowKind? = nil, eligibility: Eligibility = .current(maxAge: nil)) {
      self.providers = providers
      self.accountKeys = accountKeys
      self.kind = kind
      self.eligibility = eligibility
    }

    fileprivate func includes(_ key: QuotaAccountKey) -> Bool {
      if let providers, !providers.contains(key.provider) { return false }
      if let accountKeys, !accountKeys.contains(key) { return false }
      return true
    }
  }

  public struct Candidate: Hashable, Sendable {
    public let usage: ProviderUsage
    public let headroom: Headroom
    public let limitingMetrics: [UsageMetric]

    public init?(usage: ProviderUsage, kind: QuotaWindowKind?) {
      let considered = usage.metrics.filter {
        kind == nil || QuotaWindowKind.classify(metricID: $0.id, label: $0.label) == kind
      }
      let bounded = considered.filter { !$0.isUnlimited && $0.remainingPercent != nil }
      if let minimum = bounded.compactMap(\.remainingPercent).min() {
        self.usage = usage
        headroom = .percent(minimum)
        limitingMetrics = bounded.filter { $0.remainingPercent == minimum }
        return
      }
      let unlimited = considered.filter(\.isUnlimited)
      guard !unlimited.isEmpty else { return nil }
      self.usage = usage
      headroom = .unlimited
      limitingMetrics = unlimited
    }

    public var accountID: String { usage.accountID }
    public var accountKey: QuotaAccountKey { usage.accountKey }

    /// Headroom rises only after every equally limiting window resets.
    public var limitingMetric: UsageMetric {
      limitingMetrics.dropFirst().reduce(limitingMetrics[0]) { latest, metric in
        guard let reset = metric.resetAt else { return latest }
        return (latest.resetAt.map { reset > $0 } ?? true) ? metric : latest
      }
    }

    public var resetAt: Date? { limitingMetric.resetAt }
    public var isEstimated: Bool { limitingMetrics.contains(where: \.isPercentageEstimated) }
  }

  public enum ExclusionReason: Hashable, Sendable {
    case failing(QuotaErrorKind)
    case noQuotaData
    case stale(fetchedAt: Date)
  }

  public struct Exclusion: Hashable, Sendable {
    public let accountKey: QuotaAccountKey
    public let name: String
    public let reason: ExclusionReason
    public var accountID: String { accountKey.accountID }
    public var provider: QuotaProvider { accountKey.provider }
  }

  public struct Ranking: Hashable, Sendable {
    public let candidates: [Candidate]
    public let exclusions: [Exclusion]
    public var best: Candidate? { candidates.first }
    public var worst: Candidate? { candidates.last }
  }

  public static func rank(snapshot: QuotaSnapshot, filter: Filter, now: Date) -> Ranking {
    let failures = snapshot.preferredFailures
    var candidates: [Candidate] = []
    var exclusions: [Exclusion] = []
    var seen: Set<QuotaAccountKey> = []

    for usage in snapshot.providers where filter.includes(usage.accountKey) {
      guard seen.insert(usage.accountKey).inserted else { continue }
      let failure = failures[usage.accountKey]
      func exclude(_ reason: ExclusionReason) {
        exclusions.append(Exclusion(accountKey: usage.accountKey, name: usage.title, reason: reason))
      }
      if case .current = filter.eligibility, let failure {
        exclude(.failing(failure.kind))
        continue
      }
      if case .current(let maxAge) = filter.eligibility,
         QuotaFreshness.isStale(fetchedAt: usage.fetchedAt, in: snapshot, now: now, maxAge: maxAge) {
        exclude(.stale(fetchedAt: usage.fetchedAt))
        continue
      }
      let shown = failure == nil ? usage : usage.clearingElapsedWindows(at: now)
      guard let candidate = Candidate(usage: shown, kind: filter.kind) else {
        exclude(.noQuotaData)
        continue
      }
      candidates.append(candidate)
    }

    for failure in failures.values where filter.includes(failure.accountKey) && !seen.contains(failure.accountKey) {
      let title = failure.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      exclusions.append(Exclusion(accountKey: failure.accountKey,
                                  name: title.isEmpty ? failure.provider.displayName : title,
                                  reason: .failing(failure.kind)))
    }
    return Ranking(candidates: candidates.sorted(by: ranksAhead), exclusions: exclusions.sorted {
      if $0.provider != $1.provider { return $0.provider.rawValue < $1.provider.rawValue }
      if $0.name != $1.name { return $0.name < $1.name }
      return $0.accountID < $1.accountID
    })
  }

  private static func ranksAhead(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
    if lhs.headroom != rhs.headroom { return lhs.headroom > rhs.headroom }
    switch (lhs.resetAt, rhs.resetAt) {
    case let (left?, right?) where left != right: return left < right
    case (.some, .none): return true
    case (.none, .some): return false
    default: break
    }
    if lhs.usage.provider != rhs.usage.provider { return lhs.usage.provider.rawValue < rhs.usage.provider.rawValue }
    if lhs.usage.title != rhs.usage.title { return lhs.usage.title < rhs.usage.title }
    return lhs.accountID < rhs.accountID
  }
}
