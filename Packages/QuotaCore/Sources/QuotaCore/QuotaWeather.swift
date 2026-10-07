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
