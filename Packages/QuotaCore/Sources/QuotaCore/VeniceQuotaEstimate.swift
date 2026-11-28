import Foundation

/// Infers a daily DIEM denominator only when Venice does not report an allocation.
/// The snapshot retains the observed amount so restarts do not reset the estimate.
enum VeniceQuotaEstimate {
  static func applying(to usage: ProviderUsage, previous: ProviderUsage?) -> ProviderUsage {
    guard usage.provider == .venice,
          let index = usage.metrics.firstIndex(where: { $0.id == "daily-diem" }) else {
      return usage
    }

    let metric = usage.metrics[index]
    guard metric.remainingPercent == nil else { return usage }
    guard let amount = metric.remainingAmount, amount.isFinite,
          let resetAt = metric.resetAt, resetAt > usage.fetchedAt else { return usage }

    let prior = previous.flatMap { candidate -> ProviderUsage? in
      guard candidate.accountID == usage.accountID, candidate.provider == .venice else { return nil }
      return candidate
    }
    let priorMetric = prior?.metrics.first(where: { $0.id == "daily-diem" })

    // A concurrent or delayed response must not roll an established estimate
    // back — unless the key changed since the prior reading, in which case the
    // estimate belongs to a different credential and must not survive.
    if let prior, priorMetric?.isPercentageEstimated == true,
       priorMetric?.estimateKeyHash == metric.estimateKeyHash,
       usage.fetchedAt <= prior.fetchedAt {
      return prior
    }

    let upperBound: Double
    if let priorMetric, let priorReset = priorMetric.resetAt,
       // The estimate belongs to the API key that produced the prior reading.
       // A replaced key starts a fresh observation instead of measuring a
       // different account's balance against this key's denominator.
       priorMetric.estimateKeyHash == metric.estimateKeyHash,
       // SnapshotStore's ISO-8601 dates retain whole seconds. Compare at that
       // precision so reloading does not turn the same server epoch into a new one.
       floor(priorReset.timeIntervalSince1970) == floor(resetAt.timeIntervalSince1970),
       let priorAmount = priorMetric.remainingAmount, priorAmount.isFinite,
       let priorTotal = priorMetric.estimatedTotal, priorTotal.isFinite, priorTotal > 0,
       amount <= priorAmount || amount <= 0 {
      upperBound = priorTotal
    } else {
      guard amount > 0 else { return usage }
      // Any increase starts a fresh observation, even below an older high-water mark.
      upperBound = amount
    }

    let remaining = Int((min(max(amount, 0), upperBound) / upperBound * 100).rounded())
    var result = usage
    result.metrics[index].remainingPercent = remaining
    result.metrics[index].estimatedTotal = upperBound
    result.metrics[index].detail = "Estimated from an observed upper bound of \(String(format: "%.6g", locale: Locale(identifier: "en_US_POSIX"), upperBound)) DIEM. The first reading may already be partly spent."
    result.maxUsagePercent = max(100 - remaining, result.maxUsagePercent ?? 0)
    if result.warning == nil {
      if amount <= 0 {
        result.warning = VeniceQuotaClient.dailyDIEMExhaustedWarning(metrics: result.metrics)
      } else if remaining <= 20 {
        result.warning = "High estimated DIEM usage"
      }
    }
    return result
  }
}

public extension QuotaSnapshot {
  /// Rebuild a missing daily estimate from an earlier observation of the same
  /// key and server epoch. A cleared baseline should not hide an exhausted ring.
  func restoringVeniceDailyEstimates(from history: [QuotaSnapshot], now: Date) -> QuotaSnapshot {
    var result = self
    for index in result.providers.indices where result.providers[index].provider == .venice {
      let usage = result.providers[index]
      guard let metric = usage.metrics.first(where: { $0.id == "daily-diem" }),
            metric.remainingPercent == nil, let amount = metric.remainingAmount, amount <= 0,
            let keyHash = metric.estimateKeyHash, let reset = metric.resetAt, reset > now else { continue }

      let previous = history.lazy.flatMap(\.providers).filter { prior in
        prior.accountKey == usage.accountKey && prior.fetchedAt < usage.fetchedAt
          && prior.metrics.contains { priorMetric in
            priorMetric.id == metric.id && priorMetric.isPercentageEstimated
              && priorMetric.estimateKeyHash == keyHash && priorMetric.resetAt == reset
          }
      }.max { $0.fetchedAt < $1.fetchedAt }
      guard let previous else { continue }
      result.providers[index] = VeniceQuotaEstimate.applying(to: usage, previous: previous)
    }
    return result
  }
}
