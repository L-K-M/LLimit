import Foundation

public enum BenchmarkQuotaCadence {
  public static func minimumInterval(for provider: QuotaProvider) -> TimeInterval {
    provider == .anthropic ? 180 : 0
  }

  /// Include dashboard observations and failed attempts, not just successful
  /// benchmark reads. Clock skew must never create an unbounded wait.
  public static func delay(provider: QuotaProvider, lastAttempt: Date?, lastObservation: Date?, now: Date = Date()) -> TimeInterval {
    guard let last = [lastAttempt, lastObservation].compactMap({ $0 }).max() else { return 0 }
    return max(0, minimumInterval(for: provider) - now.timeIntervalSince(min(last, now)))
  }
}
