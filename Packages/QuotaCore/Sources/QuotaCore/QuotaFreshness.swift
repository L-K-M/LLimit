import Foundation

/// Shared snapshot age policy. Display commands never need credential-bearing settings.
public enum QuotaFreshness {
  public static let minimumMaxAge: TimeInterval = 60 * 60
  public static let legacyMaxAge: TimeInterval = 2 * 60 * 60
  private static let toleratedIntervals = 2

  public static func maxAge(refreshIntervalMinutes: Int?) -> TimeInterval {
    guard let minutes = refreshIntervalMinutes, minutes > 0 else { return legacyMaxAge }
    let range = AppSettings.refreshIntervalRange
    let clamped = min(range.upperBound, max(range.lowerBound, minutes))
    return max(minimumMaxAge, TimeInterval(clamped * toleratedIntervals * 60))
  }

  public static func isStale(
    fetchedAt: Date, in snapshot: QuotaSnapshot, now: Date, maxAge override: TimeInterval? = nil
  ) -> Bool {
    let age = now.timeIntervalSince(fetchedAt)
    return !age.isFinite || age > (override ?? maxAge(refreshIntervalMinutes: snapshot.refreshIntervalMinutes))
  }
}
