import Foundation

/// Dashboard header weather, pure and credential-free so Linux tests cover it.
///
/// Weather-only: it summarizes headroom, failures, and data quality. It never
/// touches palettes or drawing. Unknown, stale, and estimated data are
/// separate states from healthy levels, so a dead refresh loop or a Venice
/// estimate never renders as healthy.
public enum QuotaWeather: String, Equatable, Sendable {
  private static let stormyThreshold = 15
  private static let cloudyThreshold = 40
  case calm = "Calm"
  case cloudy = "Cloudy"
  case stormy = "Stormy"
  case unknown = "Unknown"
  case stale = "Stale"
  case estimated = "Estimated"

  public var iconName: String {
    switch self {
    case .calm:
      return "sun.max.fill"
    case .cloudy:
      return "cloud.fill"
    case .stormy:
      return "cloud.bolt.fill"
    case .unknown:
      return "questionmark.circle.fill"
    case .stale:
      return "clock.arrow.circlepath"
    case .estimated:
      return "cloud.fill"
    }
  }

  /// Weather for a snapshot at `now`. `staleAfter` follows the shared stale
  /// interval (two refresh intervals, never sooner than an hour).
  public static func forSnapshot(
    _ snapshot: QuotaSnapshot?,
    now: Date,
    staleAfter: TimeInterval? = nil
  ) -> QuotaWeather {
    guard let snapshot else { return .unknown }
    if !snapshot.failures.isEmpty { return .stormy }
    guard !snapshot.providers.isEmpty else { return .unknown }

    let bounded = snapshot.providers.flatMap { usage in
      usage.metrics.filter { !$0.isUnlimited }.compactMap(\.remainingPercent)
    }
    guard !bounded.isEmpty else { return .unknown }

    if QuotaFreshness.isStale(fetchedAt: snapshot.generatedAt, in: snapshot, now: now, maxAge: staleAfter)
      || snapshot.providers.contains(where: {
        QuotaFreshness.isStale(fetchedAt: $0.fetchedAt, in: snapshot, now: now, maxAge: staleAfter)
          || hasElapsedWindow($0, now: now)
      }) {
      return .stale
    }

    if snapshot.providers.contains(where: hasUnknownWindow) { return .unknown }

    // Estimated percentages (for example Venice DIEM) are data quality, not
    // headroom: surface them instead of grading them as healthy or stormy.
    let hasEstimated = snapshot.providers.contains { usage in
      usage.metrics.contains { !$0.isUnlimited && $0.isPercentageEstimated && $0.remainingPercent != nil }
    }
    if hasEstimated { return .estimated }

    let minRemaining = bounded.min() ?? 100
    if minRemaining < stormyThreshold { return .stormy }
    if minRemaining < cloudyThreshold { return .cloudy }
    return .calm
  }
}

private func hasElapsedWindow(_ usage: ProviderUsage, now: Date) -> Bool {
  usage.metrics.contains {
    guard !$0.isUnlimited, $0.remainingPercent != nil, let reset = $0.resetAt else { return false }
    return reset > usage.fetchedAt && reset <= now
  }
}

private func hasUnknownWindow(_ usage: ProviderUsage) -> Bool {
  usage.metrics.contains {
    !$0.isUnlimited && $0.remainingPercent == nil
      && (QuotaWindowKind.classify(metricID: $0.id, label: $0.label) != .other || $0.resetAt != nil)
  }
}

/// Public display copy only. Provider diagnostics never enter this explanation.
public struct QuotaWeatherExplanation: Equatable, Sendable {
  public let weather: QuotaWeather
  public let summary: String
  public let reasons: [String]
  public let guidance: String
  public let legend: [String]

  public var accessibilityDescription: String {
    (["Quota weather: \(weather.rawValue).", summary] + reasons + [guidance]).joined(separator: " ")
  }
}

extension QuotaWeather {
  public static func explanation(
    for snapshot: QuotaSnapshot?, now: Date, staleAfter: TimeInterval? = nil
  ) -> QuotaWeatherExplanation {
    let weather = forSnapshot(snapshot, now: now, staleAfter: staleAfter)
    let usages = (snapshot?.providers ?? []).sorted {
      ($0.title, $0.provider.rawValue, $0.accountID) < ($1.title, $1.provider.rawValue, $1.accountID)
    }
    let windows = usages.flatMap { usage in
      usage.metrics.filter { !$0.isUnlimited && $0.remainingPercent != nil }.map { metric in
        (name: displayName(usage.title, fallback: usage.provider.displayName),
         label: displayName(metric.label, fallback: "Quota window"),
         remaining: metric.remainingPercent!, estimated: metric.isPercentageEstimated,
         key: usage.provider.rawValue + usage.accountID + metric.id)
      }
    }.sorted {
      if $0.remaining != $1.remaining { return $0.remaining < $1.remaining }
      return ($0.name, $0.label, $0.key) < ($1.name, $1.label, $1.key)
    }
    var stateSummary: String
    var reasons: [String] = []
    var guidance: String

    switch weather {
    case .stormy where snapshot?.failures.isEmpty == false:
      let failures = snapshot?.failures ?? []
      stateSummary = QuotaDisplayText.countPhrase(failures.count, singular: "account could not refresh.", plural: "accounts could not refresh.")
      reasons = failures.map { failure -> (name: String, key: String, reason: String) in
        let usageName = usages.first { $0.accountID == failure.accountID && $0.provider == failure.provider }?.title
        let name = displayName(failure.title ?? usageName ?? "", fallback: failure.provider.displayName)
        return (name, failure.provider.rawValue + failure.accountID + failure.kind.rawValue,
                "\(name): \(failureGuidance(failure.kind))")
      }.sorted { ($0.name, $0.key) < ($1.name, $1.key) }.map(\.reason)
      guidance = "Open Accounts to resolve the affected connections. Retained quota readings may be out of date."
    case .stormy, .cloudy, .calm:
      switch weather {
      case .stormy: stateSummary = "At least one quota window has less than \(stormyThreshold)% remaining."
      case .cloudy: stateSummary = "The lowest quota window has at least \(stormyThreshold)% but less than \(cloudyThreshold)% remaining."
      default: stateSummary = "All reported percentage windows have at least \(cloudyThreshold)% remaining."
      }
      let limit = weather == .stormy ? stormyThreshold : cloudyThreshold
      let relevant = weather == .calm ? windows.filter { $0.remaining == windows.first?.remaining } : windows.filter { $0.remaining < limit }
      reasons = relevant.map { "\($0.name), \($0.label): \($0.remaining)% remaining." }
      guidance = weather == .calm ? "No quota or refresh warning is currently reported." : "Use an account with more headroom, or check when the affected window resets."
    case .stale:
      stateSummary = "Some quota readings are no longer current."
      if let snapshot {
        if QuotaFreshness.isStale(fetchedAt: snapshot.generatedAt, in: snapshot, now: now, maxAge: staleAfter) {
          reasons.append("The last quota refresh is older than the freshness limit.")
        }
        for usage in usages {
          let name = displayName(usage.title, fallback: usage.provider.displayName)
          if QuotaFreshness.isStale(fetchedAt: usage.fetchedAt, in: snapshot, now: now, maxAge: staleAfter) {
            reasons.append("\(name): the quota reading is older than the freshness limit.")
          }
          for metric in usage.metrics.sorted(by: { $0.id < $1.id }) where !metric.isUnlimited && metric.remainingPercent != nil {
            if let reset = metric.resetAt, reset > usage.fetchedAt, reset <= now {
              reasons.append("\(name), \(displayName(metric.label, fallback: "Quota window")): a reported reset passed since this reading.")
            }
          }
        }
      }
      guidance = "Refresh quota to obtain current readings. A passed reset does not confirm a refill until the provider reports it."
    case .estimated:
      stateSummary = "Some remaining percentages use an estimated allowance."
      reasons = windows.filter(\.estimated).map { "\($0.name), \($0.label): \($0.remaining)% remaining, estimated." }
      guidance = "Treat these percentages as approximate. The allowance is based on an observed balance, not a provider-reported total."
    case .unknown:
      stateSummary = "There is not enough comparable percentage data to assess headroom."
      for usage in usages {
        for metric in usage.metrics.sorted(by: { $0.id < $1.id }) where !metric.isUnlimited && metric.remainingPercent == nil {
          reasons.append("\(displayName(usage.title, fallback: usage.provider.displayName)), \(displayName(metric.label, fallback: "Quota window")): no remaining percentage was reported.")
        }
      }
      if reasons.isEmpty { reasons = [usages.isEmpty ? "No quota readings are available yet." : "Only unlimited or amount-only quota was reported."] }
      guidance = "Refresh quota. If readings remain unavailable, check Accounts for connections that need attention."
    }
    if reasons.count > 5 { guidance = "\(reasons.count - 5) more details are not shown. " + guidance }
    let meaning = "Quota weather summarizes the most constrained measured quota window and account refresh/data health; it is not an average or a forecast."
    return QuotaWeatherExplanation(weather: weather, summary: stateSummary + " " + meaning,
      reasons: Array(reasons.prefix(5)), guidance: guidance, legend: [
        "Calm: all measured windows have at least \(cloudyThreshold)% remaining.",
        "Cloudy: the lowest window has at least \(stormyThreshold)% but less than \(cloudyThreshold)% remaining.",
        "Stormy: below \(stormyThreshold)% remaining, or an account refresh issue.",
        "Unknown: a quota window has no comparable percentage data.",
        "Stale: quota data is too old, or a reported reset has passed.",
        "Estimated: a percentage uses an observed balance instead of a reported allowance."
      ])
  }

  private static func displayName(_ text: String, fallback: String) -> String {
    let clean = text.components(separatedBy: .controlCharacters).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    return clean.isEmpty ? fallback : String(clean.prefix(100))
  }

  private static func failureGuidance(_ kind: QuotaErrorKind) -> String {
    switch kind {
    case .auth: return "sign-in needs attention; reconnect this account."
    case .network: return "the provider could not be reached; check your connection and retry."
    case .rateLimit: return "the usage check was rate limited; wait before retrying."
    case .api, .decoding: return "the provider's quota response is unavailable; retry later."
    case .notConfigured: return "configure the missing account credentials."
    case .unknown: return "the quota check failed; retry or check the account connection."
    }
  }
}

/// Best account to burn, via the shared `HeadroomRanking` (no duplicate ranking).
///
/// Bounded-quota eligibility only: unknown, unlimited-only, failing, stale,
/// disabled, and depleted (0%) accounts are never nominated. Ties go to the
/// sooner reset via `HeadroomRanking`'s own ordering.
public enum DashboardBestAccount {
  public static func best(
    snapshot: QuotaSnapshot?,
    accounts: [ProviderAccount],
    now: Date,
    staleAfter: TimeInterval
  ) -> HeadroomRanking.Candidate? {
    guard let snapshot else { return nil }
    let enabledKeys = Set(accounts.filter(\.isEnabled).map {
      QuotaAccountKey(provider: $0.provider, accountID: $0.id)
    })
    guard !enabledKeys.isEmpty else { return nil }

    // Project legacy identity and current names before invoking the one ranking.
    var current = snapshot
    current.providers = orderedUsageForAccounts(snapshot.providers, accounts: accounts)
      .filter { !hasElapsedWindow($0, now: now) && !hasUnknownWindow($0) }
    current.failures = orderedFailuresForAccounts(snapshot.failures, accounts: accounts)

    let ranking = HeadroomRanking.rank(
      snapshot: current,
      filter: HeadroomRanking.Filter(
        accountKeys: enabledKeys,
        eligibility: .current(maxAge: staleAfter)
      ),
      now: now
    )

    // Bounded headroom only: unlimited never outranks real quota, unknown is
    // excluded by the ranking, and an all-depleted board hides the trophy
    // rather than nominating an empty account.
    let bounded = ranking.candidates.filter {
      if case .percent(let value) = $0.headroom, value > 0 { return true }
      return false
    }
    return bounded.first
  }
}
