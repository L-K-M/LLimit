import Foundation

/// Each observed increase starts a new 100% baseline, even below an older peak.
/// The credential-bound baseline lives in the snapshot so it survives restarts.
enum LongcatQuotaEstimate {
  static func applying(to usage: ProviderUsage, previous: ProviderUsage?) -> ProviderUsage {
    guard usage.provider == .longcat else { return usage }
    let prior = previous.flatMap { candidate -> ProviderUsage? in
      candidate.provider == .longcat && candidate.accountID == usage.accountID ? candidate : nil
    }
    // SnapshotStore retains whole seconds; a poll in that same second can
    // still be newer. Strictly older responses retain the original timestamp.
    if let prior, usage.fetchedAt < prior.fetchedAt,
       let key = usage.metrics.first?.estimateKeyHash,
       prior.metrics.contains(where: { $0.estimateKeyHash == key }) { return prior }
    var result = usage
    result.metrics = usage.metrics.map { metric in
      guard metric.remainingPercent == nil,
            let amount = metric.remainingAmount, amount.isFinite, amount >= 0,
            let key = metric.estimateKeyHash, !key.isEmpty else { return metric }
      let old = prior?.metrics.first { $0.id == metric.id && $0.estimateKeyHash == key }
      let total: Double
      if let old, let oldAmount = old.remainingAmount, oldAmount.isFinite,
         amount <= oldAmount, let oldTotal = old.estimatedTotal,
         oldTotal.isFinite, oldTotal > 0 {
        total = oldTotal
      } else {
        // Initial zero has no denominator. Keep the amount visible until a
        // positive reading supplies a baseline rather than inventing an allowance.
        guard amount > 0 else { return metric }
        total = amount
      }
      var estimated = metric
      estimated.estimatedTotal = total
      estimated.remainingPercent = Int((min(amount / total, 1) * 100).rounded())
      let baseline = String(format: "%.6g", locale: Locale(identifier: "en_US_POSIX"), total)
      let explanation = "Estimated from a token baseline of \(baseline). Every observed increase sets a new 100% baseline."
      estimated.detail = [metric.detail, explanation].compactMap { $0 }.joined(separator: " · ")
      return estimated
    }
    result.maxUsagePercent = result.metrics.compactMap(\.remainingPercent).map { 100 - $0 }.max()
    return result
  }
}
