import Foundation

/// A user-supplied reset anchors Junie's fixed 30-day credit period.
public struct JunieCreditCycle: Sendable {
  public static let windowSeconds = 30 * 86_400
  public let anchor: Date

  /// Date-only input means midnight UTC. Date-times require an explicit zone.
  public init?(anchor text: String) {
    guard let date = parseQuotaResetDate(text) else { return nil }
    anchor = date
  }

  /// Never refills the balance; only advances an elapsed configured reset.
  public func resetAt(after now: Date) -> Date {
    guard anchor <= now else { return anchor }
    let seconds = TimeInterval(Self.windowSeconds)
    let elapsedPeriods = floor(now.timeIntervalSince(anchor) / seconds)
    return anchor.addingTimeInterval((elapsedPeriods + 1) * seconds)
  }
}
