import Foundation

public enum SubscriptionBillingPeriod: String, Codable, CaseIterable, Sendable {
  case monthly
  case yearly

  public var displayName: String {
    switch self {
    case .monthly: return "Monthly"
    case .yearly: return "Yearly"
    }
  }
}

/// Account-owned subscription pricing, separate from provider authentication.
/// This describes the bill; converting it into task cost requires an explicit
/// allocation assumption and does not establish a provider's quota duration.
public struct SubscriptionPricing: Codable, Hashable, Sendable {
  public var amount: Double
  public var currency: String
  public var billingPeriod: SubscriptionBillingPeriod

  public init(amount: Double, currency: String = "USD", billingPeriod: SubscriptionBillingPeriod = .monthly) {
    self.amount = amount
    self.currency = currency
    self.billingPeriod = billingPeriod
  }

  @discardableResult
  public func validated() throws -> Self {
    guard amount.isFinite, amount >= 0 else { throw SubscriptionPricingError.invalidAmount }
    guard currency.utf8.count == 3, currency.utf8.allSatisfy({ (65...90).contains($0) }) else {
      throw SubscriptionPricingError.invalidCurrency
    }
    return self
  }

  /// Compare validated subscriptions on the same billing basis. This is not
  /// the amount billed monthly for a yearly subscription or a task-cost rate.
  public var monthlyEquivalent: Double {
    billingPeriod == .yearly ? amount / 12 : amount
  }
}

public enum SubscriptionPricingError: LocalizedError, Equatable {
  case invalidAmount
  case invalidCurrency

  public var errorDescription: String? {
    switch self {
    case .invalidAmount:
      return "Enter a nonnegative finite subscription price."
    case .invalidCurrency:
      return "Enter an uppercase three-letter currency code, such as USD or CHF."
    }
  }
}
