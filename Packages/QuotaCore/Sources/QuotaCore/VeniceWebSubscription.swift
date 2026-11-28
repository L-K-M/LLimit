import Foundation

/// The small, credential-free projection of Venice's signed-in session response.
public struct VeniceWebSubscription: Decodable, Sendable {
  public static let metricID = "bundled-credits-web"

  private let availableCredits: Double?
  private let monthlyRefillCredits: Double
  private let nextRefillAt: Double
  private let usedThisCycle: Double

  public func metric(asOf now: Date) throws -> UsageMetric? {
    let available = availableCredits ?? 0
    let total = available + usedThisCycle
    guard available.isFinite, available >= 0, usedThisCycle.isFinite, usedThisCycle >= 0,
          total.isFinite, monthlyRefillCredits.isFinite, monthlyRefillCredits >= 0,
          nextRefillAt.isFinite, nextRefillAt >= 0 else {
      throw ProviderClientError(kind: .decoding, message: "Venice returned invalid subscription data.")
    }
    guard monthlyRefillCredits > 0 else { return nil }

    // Venice reports epoch milliseconds. A zero deadline means none was supplied.
    let epochSeconds = nextRefillAt / 1000
    let refill = (946_684_800..<4_102_444_800).contains(epochSeconds)
      ? Date(timeIntervalSince1970: epochSeconds) : nil
    let paceWindow = refill.flatMap { date -> DateInterval? in
      guard date > now,
            let window = MonthlyQuotaCycle(anchor: date).window(containing: now, allowsPrecedingWindow: true),
            window.end == date else { return nil }
      return window
    }
    // Available credits include the banked balance. The dashboard shows usage
    // against the balance plus what was used this cycle.
    let fraction = total > 0 ? available / total : nil
    return UsageMetric(
      id: Self.metricID, label: "Monthly subscription credits", remainingPercent: fraction.flatMap { roundedPercent($0 * 100) },
      remainingAmount: available, totalAmount: total > 0 ? total : nil,
      usedDisplay: "\(VeniceQuotaClient.amount(available)) credits",
      detail: "Venice web balance, including banked credits.",
      reportedRemainingFraction: fraction, paceWindow: paceWindow, refillAt: refill
    )
  }
}

public extension UsageMetric {
  var isVeniceSubscription: Bool {
    id == "bundled-credits" || id == VeniceWebSubscription.metricID
  }
}

/// The website data store belongs to LLimit. Only its reference and the pinned
/// web user identity are stored in account settings.
public struct VeniceWebProfile: Equatable, Sendable {
  public let id: UUID
  public let userID: String

  public init(id: UUID, userID: String) {
    self.id = id
    self.userID = userID
  }

  public static func profile(from credentials: [String: String]) -> Self? {
    guard let rawID = credentials[CredentialField.veniceWebProfile], let id = UUID(uuidString: rawID),
          let userID = nonEmptyString(credentials[CredentialField.veniceWebUserID]) else { return nil }
    return Self(id: id, userID: userID)
  }
}
