import Foundation

/// A known subtotal never implies that attempts with missing measurements were free.
public struct BenchmarkCostCoverage: Sendable {
  public let knownCost: Double?
  public let pricedAttempts: Int
  public let totalAttempts: Int
  public var isComplete: Bool { totalAttempts > 0 && pricedAttempts == totalAttempts && knownCost != nil }

  public init(runs: [BenchmarkRun]) {
    let prices = runs.compactMap(\.estimatedCost).filter { $0.isFinite && $0 >= 0 }
    let sum = prices.reduce(0, +)
    knownCost = !prices.isEmpty && sum.isFinite ? sum : nil
    pricedAttempts = prices.count
    totalAttempts = runs.count
  }

  public static func unavailableReason(for run: BenchmarkRun, candidate: BenchmarkCandidate?,
                                       currency: String? = nil, allowanceAvailable: Bool? = nil) -> String? {
    guard run.estimatedCost == nil else { return nil }
    if let reason = run.costUnavailableReason { return reason }
    guard let candidate, candidate.accountID != nil else { return "No quota account was selected for cost measurement." }
    guard let id = candidate.quotaMetricID else { return "No cost allocation window was selected." }
    let selected = run.quotaChanges.first { $0.metricID == id }
    let otherLabels = run.quotaChanges.filter {
      $0.metricID != id && (($0.consumedPercentagePoints ?? 0) > 0 || ($0.consumedAmount ?? 0) > 0)
    }.map(\.label)
    if let reason = selected?.unavailableReason ?? run.quotaChanges.first(where: { $0.metricID == "unavailable" })?.unavailableReason {
      return reason + (otherLabels.isEmpty ? "" : " Usage was measured in a different window: \(otherLabels.joined(separator: ", ")). Select the window used by this harness for future runs.")
    }
    guard let selected else { return "The selected cost allocation window was missing from the quota readings." }
    guard selected.consumedPercentagePoints != nil else {
      return "A comparable percentage of the selected allowance could not be measured."
    }
    if candidate.allowanceCost == nil && candidate.subscriptionPricing == nil {
      return "No subscription price or full-window cost override was recorded."
    }
    if let price = candidate.subscriptionPricing, let currency, price.currency != currency, candidate.allowanceCost == nil {
      return "The subscription price and benchmark use different currencies; conversion is not automatic."
    }
    if allowanceAvailable == false {
      return "The selected allowance has no known duration. Configure its supported reset schedule or enter a full-window cost override."
    }
    return "The original report does not contain enough comparable usage and allowance data to price this attempt."
  }
}
