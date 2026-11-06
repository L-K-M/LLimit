import Foundation

/// An allocation of a subscription fee to one complete quota window, assuming
/// its capacity is used. It is not an additional provider charge or a refill.
public struct BenchmarkPriceAllocation: Sendable {
  public let allowanceCost: Double
  public let explanation: String

  public static func subscription(_ price: SubscriptionPricing, metric: UsageMetric,
                                  currency: String, provider: QuotaProvider? = nil) -> BenchmarkPriceAllocation? {
    guard let price = try? price.validated(), price.currency == currency,
          let seconds = windowSeconds(for: metric, provider: provider), seconds.isFinite, seconds > 0,
          !metric.isUnlimited else { return nil }
    let kind = QuotaWindowKind.classify(metricID: metric.id, label: metric.label)
    let isMonthly = kind == .monthly && (Double(28 * 86_400)...Double(31 * 86_400)).contains(seconds)
    let factor = isMonthly ? 1 : seconds / (365.2425 * 86_400) * 12
    let cost = price.monthlyEquivalent * factor
    guard cost.isFinite, cost >= 0 else { return nil }
    let basis = isMonthly
      ? "Account subscription price, using its monthly equivalent for the complete monthly allowance."
      : "Account subscription price, prorated to the reported window using an average calendar year (365.2425 days)."
    return BenchmarkPriceAllocation(allowanceCost: cost,
      explanation: basis + " Assumes all capacity in the selected window can be used. Overlapping windows are not added together.")
  }

  public static func defaultMetricID(in metrics: [UsageMetric], provider: QuotaProvider? = nil) -> String? {
    var chosenID: String?
    var longest: TimeInterval = 0
    for metric in metrics where !metric.isUnlimited && metric.remainingPercent != nil {
      if let duration = windowSeconds(for: metric, provider: provider), duration.isFinite, duration > longest {
        chosenID = metric.id
        longest = duration
      }
    }
    return chosenID
  }

  private static func windowSeconds(for metric: UsageMetric, provider: QuotaProvider?) -> TimeInterval? {
    if let provider { return QuotaPace.windowSeconds(for: metric, provider: provider) }
    return metric.windowSeconds.map(TimeInterval.init)
  }
}
