import Foundation

/// Calendar-month resets anchored to the original purchase day and UTC clock.
public struct MonthlyQuotaCycle: Sendable {
  public let anchor: Date

  public init?(anchor text: String) {
    guard let date = parseQuotaResetDate(text) else { return nil }
    anchor = date
  }

  init(anchor: Date) {
    self.anchor = anchor
  }

  public func resetAt(after now: Date) -> Date {
    window(containing: now)?.end ?? anchor
  }

  /// A purchase date starts the first window. A known refill date can also
  /// anchor the active window that ends on that date.
  public func window(containing now: Date, allowsPrecedingWindow: Bool = false) -> DateInterval? {
    guard (now >= anchor || allowsPrecedingWindow), now.timeIntervalSinceReferenceDate.isFinite else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    guard let month = calendar.dateInterval(of: .month, for: now),
          let currentReset = occurrence(in: month.start, calendar: calendar) else { return nil }
    let offset = currentReset > now ? -1 : 0
    guard let startMonth = calendar.date(byAdding: .month, value: offset, to: month.start),
          let endMonth = calendar.date(byAdding: .month, value: offset + 1, to: month.start),
          let start = occurrence(in: startMonth, calendar: calendar),
          let end = occurrence(in: endMonth, calendar: calendar), end > start,
          now >= anchor || end == anchor else { return nil }
    return DateInterval(start: start, end: end)
  }

  private func occurrence(in month: Date, calendar: Calendar) -> Date? {
    guard let days = calendar.range(of: .day, in: .month, for: month) else { return nil }
    // Always derive from the purchase day; adding months to February's clamped
    // date would otherwise permanently turn a 31st-day subscription into a 28th.
    let day = min(calendar.component(.day, from: anchor), days.count)
    guard let midnight = calendar.date(byAdding: .day, value: day - 1, to: month) else { return nil }
    return midnight.addingTimeInterval(anchor.timeIntervalSince(calendar.startOfDay(for: anchor)))
  }
}
