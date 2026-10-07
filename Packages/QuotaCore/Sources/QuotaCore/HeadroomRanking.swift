import Foundation

/// Ranks accounts by the quota they have left: which subscription to use next
/// (`llimit pick`, `llimit check`) and which one is the most constrained
/// (`llimit status --worst`). Pure and credential-free: it reads only a snapshot.
///
/// An account's headroom is the lowest remaining percentage across its bounded
/// metrics, or across the metrics of one window kind when the filter names one.
/// That is the same worst-metric rule as the status bar headline: 90% of a
/// session does not help when 3% of the week is left. Metrics without a
/// percentage (balances, counts, placeholders) never count. Unlimited metrics
/// count only when nothing bounded is reported, and then rank above every
/// percentage.
public enum HeadroomRanking {
  /// The age after which the Linux status contract flags an account `stale`.
  public static let defaultMaxAge: TimeInterval = 2 * 3_600

  /// Case order is the ranking: the synthesized `Comparable` orders percentages
  /// by value and puts every percentage below `unlimited`.
  public enum Headroom: Hashable, Comparable, Sendable {
    case percent(Int)
    case unlimited
  }

  /// Which accounts may be ranked at all.
  public enum Eligibility: Hashable, Sendable {
    /// For choosing an account to use now: accounts whose last refresh failed,
    /// or whose data is older than `maxAge`, are excluded.
    case current(maxAge: TimeInterval)
    /// For display surfaces, which mark stale data themselves: every account
    /// that reported quota, including the carried-over usage of a failing one.
    case anyReported
  }

  public struct Filter: Hashable, Sendable {
    /// `nil` means every provider.
    public var providers: Set<QuotaProvider>?
    /// `nil` means every account.
    public var accountIDs: Set<String>?
    /// When set, only metrics of this window kind count toward headroom.
    public var kind: QuotaWindowKind?
    public var eligibility: Eligibility

    public init(
      providers: Set<QuotaProvider>? = nil,
      accountIDs: Set<String>? = nil,
      kind: QuotaWindowKind? = nil,
      eligibility: Eligibility = .current(maxAge: HeadroomRanking.defaultMaxAge)
    ) {
      self.providers = providers
      self.accountIDs = accountIDs
      self.kind = kind
      self.eligibility = eligibility
    }

    func includes(accountID: String, provider: QuotaProvider) -> Bool {
      if let providers, !providers.contains(provider) {
        return false
      }
      if let accountIDs, !accountIDs.contains(accountID) {
        return false
      }
      return true
    }
  }

  public struct Candidate: Hashable, Sendable {
    public let usage: ProviderUsage
    public let headroom: Headroom
    /// The metrics that set `headroom`; several when they tie.
    public let limitingMetrics: [UsageMetric]

    /// Nil when no metric of `kind` (or of any kind, when `kind` is nil)
    /// reports a percentage or unlimited quota.
    public init?(usage: ProviderUsage, kind: QuotaWindowKind?) {
      let considered = usage.metrics.filter { metric in
        guard let kind else { return true }
        return QuotaWindowKind.classify(metricID: metric.id, label: metric.label) == kind
      }

      let bounded = considered.filter { !$0.isUnlimited && $0.remainingPercent != nil }
      if let minimum = bounded.compactMap(\.remainingPercent).min() {
        self.usage = usage
        self.headroom = .percent(minimum)
        self.limitingMetrics = bounded.filter { $0.remainingPercent == minimum }
        return
      }

      let unlimited = considered.filter(\.isUnlimited)
      guard !unlimited.isEmpty else { return nil }
      self.usage = usage
      self.headroom = .unlimited
      self.limitingMetrics = unlimited
    }

    public var accountID: String { usage.accountID }

    /// The limiting metric that holds the headroom down longest: the one with
    /// the latest known reset, since headroom rises only once every limiting
    /// metric has reset. The first one when none reports a reset.
    public var limitingMetric: UsageMetric {
      var latest = limitingMetrics[0]
      for metric in limitingMetrics.dropFirst() {
        guard let reset = metric.resetAt else { continue }
        if latest.resetAt.map({ reset > $0 }) ?? true {
          latest = metric
        }
      }
      return latest
    }

    /// When the headroom can next grow.
    public var resetAt: Date? {
      limitingMetric.resetAt
    }

    /// Whether the headroom rests on an estimated percentage (Venice DIEM).
    public var isEstimated: Bool {
      limitingMetrics.contains(where: \.isPercentageEstimated)
    }
  }

  public enum ExclusionReason: Hashable, Sendable {
    /// The last refresh failed; any usage on record is carried over.
    case failing(QuotaErrorKind)
    /// No metric (of the requested kind) reports a percentage or unlimited quota.
    case noQuotaData
    /// The usage was fetched longer ago than the allowed age.
    case stale(fetchedAt: Date)
  }

  public struct Exclusion: Hashable, Sendable {
    public let accountID: String
    public let provider: QuotaProvider
    public let name: String
    public let reason: ExclusionReason
  }

  public struct Ranking: Hashable, Sendable {
    /// Most headroom first.
    public let candidates: [Candidate]
    /// Accounts the filter matched but the ranking could not use.
    public let exclusions: [Exclusion]

    public var best: Candidate? { candidates.first }
    public var worst: Candidate? { candidates.last }
  }

  /// Usage and failures belong to the same account only when both provider and
  /// account id match. Legacy single-account entries decode with the provider's
  /// raw value as their id, so they pair up the same way.
  private struct AccountKey: Hashable {
    let provider: QuotaProvider
    let accountID: String
  }

  public static func rank(snapshot: QuotaSnapshot, filter: Filter, now: Date) -> Ranking {
    let failures = Dictionary(
      snapshot.failures.map { (AccountKey(provider: $0.provider, accountID: $0.accountID), $0) },
      uniquingKeysWith: { first, _ in first }
    )
    var candidates: [Candidate] = []
    var exclusions: [Exclusion] = []

    for usage in snapshot.providers where filter.includes(accountID: usage.accountID, provider: usage.provider) {
      func exclude(_ reason: ExclusionReason) {
        exclusions.append(
          Exclusion(accountID: usage.accountID, provider: usage.provider, name: usage.title, reason: reason)
        )
      }

      if case .current = filter.eligibility,
         let failure = failures[AccountKey(provider: usage.provider, accountID: usage.accountID)] {
        exclude(.failing(failure.kind))
        continue
      }

      guard let candidate = Candidate(usage: usage, kind: filter.kind) else {
        exclude(.noQuotaData)
        continue
      }

      if case .current(let maxAge) = filter.eligibility, now.timeIntervalSince(usage.fetchedAt) > maxAge {
        exclude(.stale(fetchedAt: usage.fetchedAt))
        continue
      }

      candidates.append(candidate)
    }

    // An account that failed before it ever reported usage exists only as a failure.
    let reported = Set(snapshot.providers.map { AccountKey(provider: $0.provider, accountID: $0.accountID) })
    for failure in snapshot.failures
    where !reported.contains(AccountKey(provider: failure.provider, accountID: failure.accountID))
      && filter.includes(accountID: failure.accountID, provider: failure.provider) {
      exclusions.append(
        Exclusion(
          accountID: failure.accountID,
          provider: failure.provider,
          name: failure.provider.displayName,
          reason: .failing(failure.kind)
        )
      )
    }

    return Ranking(candidates: candidates.sorted(by: ranksAhead), exclusions: exclusions)
  }

  /// Most headroom first. Ties go to the sooner reset: that account's unused
  /// quota is replenished (or forfeited) first, so it is the one to spend now.
  /// A known reset beats an unknown one; the rest is a stable display order.
  private static func ranksAhead(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
    if lhs.headroom != rhs.headroom {
      return lhs.headroom > rhs.headroom
    }

    switch (lhs.resetAt, rhs.resetAt) {
    case let (left?, right?) where left != right:
      return left < right
    case (.some, .none):
      return true
    case (.none, .some):
      return false
    default:
      break
    }

    if lhs.usage.provider != rhs.usage.provider {
      return lhs.usage.provider.rawValue < rhs.usage.provider.rawValue
    }
    if lhs.usage.title != rhs.usage.title {
      return lhs.usage.title < rhs.usage.title
    }
    return lhs.accountID < rhs.accountID
  }
}
