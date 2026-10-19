import Foundation

/// A user-supplied reset anchors Junie's fixed 30-day credit period.
public struct JunieCreditCycle: Sendable {
  public static let windowSeconds = 30 * 86_400
  public let anchor: Date

  /// Date-only input means midnight UTC. Date-times require an explicit zone.
  public init?(anchor text: String) {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let datePattern = "[0-9]{4}-[0-9]{2}-[0-9]{2}"
    let timePattern = "(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:\\.[0-9]{1,9})?"
    let zonePattern = "(?:Z|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])"
    guard text.range(of: "\\A\(datePattern)(?:T\(timePattern)\(zonePattern))?\\z", options: .regularExpression) != nil else {
      return nil
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    let day = String(text.prefix(10))
    guard let midnight = formatter.date(from: day), formatter.string(from: midnight) == day else { return nil }

    if text.count == 10 {
      anchor = midnight
    } else {
      guard let date = parseISO8601(text) else { return nil }
      anchor = date
    }
  }

  /// Never refills the balance; only advances an elapsed configured reset.
  public func resetAt(after now: Date) -> Date {
    guard anchor <= now else { return anchor }
    let seconds = TimeInterval(Self.windowSeconds)
    let elapsedPeriods = floor(now.timeIntervalSince(anchor) / seconds)
    return anchor.addingTimeInterval((elapsedPeriods + 1) * seconds)
  }
}
