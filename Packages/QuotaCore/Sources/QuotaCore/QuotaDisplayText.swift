import Foundation

/// Wording shared by the macOS dashboard and `llimit status`, so ages and
/// counts read the same on every surface.
public enum QuotaDisplayText {
  /// Age of `date` at `now`, at minute granularity: "just now", "12 min ago",
  /// "3 h ago", "2 d ago". A date after `now` reads "just now": the dashboard
  /// clock ticks once a minute, so a fresh fetch can be newer than its "now".
  public static func relativeAge(_ date: Date, now: Date) -> String {
    let seconds = Int(now.timeIntervalSince(date))
    if seconds < 60 {
      return "just now"
    }
    let minutes = seconds / 60
    if minutes < 60 {
      return "\(minutes) min ago"
    }
    let hours = minutes / 60
    if hours < 48 {
      return "\(hours) h ago"
    }
    return "\(hours / 24) d ago"
  }

  /// "1 account", "0 accounts", "2 accounts".
  public static func countPhrase(_ count: Int, singular: String, plural: String) -> String {
    "\(count) \(count == 1 ? singular : plural)"
  }

  /// Provider and subtitle shown under an account's name, without repeats.
  ///
  /// Default account names equal the provider name, and some clients report
  /// the provider name as their subtitle, which produced "Z.ai · Z.ai". A part
  /// is dropped when it is blank or matches the account name or an earlier
  /// part, ignoring case and surrounding whitespace.
  public static func accountDetailParts(providerName: String, accountName: String, subtitle: String?) -> [String] {
    var seen: Set<String> = [comparisonKey(accountName)]
    var parts: [String] = []

    for candidate in [providerName, subtitle ?? ""] {
      let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, seen.insert(comparisonKey(trimmed)).inserted else { continue }
      parts.append(trimmed)
    }
    return parts
  }

  private static func comparisonKey(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}
