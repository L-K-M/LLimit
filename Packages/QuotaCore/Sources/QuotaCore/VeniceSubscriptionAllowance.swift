import Foundation

public enum VeniceSubscriptionAllowance {
  public static let invalidMessage = "Enter a positive USD credit allowance, or leave it blank."

  public static func parse(_ text: String?) throws -> Double? {
    guard let text = nonEmptyString(text) else { return nil }
    guard let value = Double(text), value.isFinite, value > 0 else {
      throw ProviderClientError(kind: .notConfigured, message: invalidMessage)
    }
    return value
  }

  public static func parseRefillDate(_ text: String?) throws -> Date? {
    try configuredQuotaResetDate(text)
  }

  static func applying(_ allowance: Double?, refillAt: Date? = nil, to usage: ProviderUsage) -> ProviderUsage {
    guard usage.provider == .venice,
          let index = usage.metrics.firstIndex(where: { $0.id == "bundled-credits" }),
          let balance = usage.metrics[index].remainingAmount, balance.isFinite else { return usage }

    var result = usage
    if let allowance, allowance.isFinite, allowance > 0 {
      let fraction = min(allowance, max(0, balance)) / allowance
      result.metrics[index].remainingPercent = roundedPercent(fraction * 100)
      result.metrics[index].totalAmount = allowance
      result.metrics[index].totalDisplay = VeniceQuotaClient.dollars(allowance)
      result.metrics[index].detail = "Based on your configured USD credit allowance. Banked credits may exceed it."
      // The scheduled refill is a reference for pace. Banked balances remain
      // valid across the refill and must not be cleared as expired windows.
      result.metrics[index].paceWindow = refillAt.flatMap {
        MonthlyQuotaCycle(anchor: $0).window(containing: usage.fetchedAt, allowsPrecedingWindow: true)
      }
    } else {
      guard result.metrics[index].totalAmount != nil else { return usage }
      result.metrics[index].remainingPercent = nil
      result.metrics[index].totalAmount = nil
      result.metrics[index].totalDisplay = nil
      result.metrics[index].paceWindow = nil
      result.metrics[index].detail = "Monthly plan credits. Some plans carry unused credits into later months."
    }
    result.maxUsagePercent = result.metrics.compactMap(\.remainingPercent).min().map { 100 - $0 }
    return result
  }
}

public extension QuotaSnapshot {
  /// Apply the latest display preference to saved balances without re-fetching
  /// or changing the observation time. Pass locally owned accounts.
  func applyingVeniceSubscriptionAllowances(from accounts: [ProviderAccount]) -> QuotaSnapshot {
    var result = self
    for index in result.providers.indices where result.providers[index].provider == .venice {
      let usage = result.providers[index]
      guard let account = accounts.first(where: { $0.id == usage.accountID && $0.provider == .venice }) else { continue }
      let allowance = try? VeniceSubscriptionAllowance.parse(account.credentials[CredentialField.veniceCreditAllowance])
      let refillAt = try? VeniceSubscriptionAllowance.parseRefillDate(account.credentials[CredentialField.veniceRefillAt])
      result.providers[index] = VeniceSubscriptionAllowance.applying(allowance, refillAt: refillAt, to: usage)
    }
    return result
  }
}
