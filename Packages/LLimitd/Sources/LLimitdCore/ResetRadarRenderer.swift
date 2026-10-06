import Foundation
import QuotaCore

/// The "reset radar": a chronological view of every upcoming reset across
/// providers. Rendered from the credential-free snapshot like the rest of
/// `StatusRenderer`, and kept in its own file so the bar contract stays put.
public extension StatusRenderer {
  /// One line per upcoming reset, soonest first.
  static func resetsHumanReadable(
    _ resets: [UpcomingReset],
    now: Date = Date(),
    windowDays: Int = 7
  ) -> String {
    let window = dayCount(windowDays)
    guard !resets.isEmpty else {
      return "No resets in the next \(window)."
    }

    var lines = ["Upcoming resets (next \(window))"]
    for entry in resets {
      let countdown = entry.countdown(at: now)
      let when = countdown == "reset" ? "reset due" : "in \(countdown)"
      var line = "\(when) — \(entry.accountName) · \(entry.metricLabel)"
      if entry.isUnlimited {
        line += " (unlimited)"
      } else if let remaining = entry.remainingPercent {
        line += " (\(remaining)% left)"
      }
      lines.append(line)
    }
    return lines.joined(separator: "\n")
  }

  /// The same radar as JSON for scripts and popups. This is its own contract, so
  /// the `llimit status --json` bar contract is untouched.
  static func resetsJSON(
    _ resets: [UpcomingReset],
    now: Date = Date(),
    windowDays: Int = 7
  ) -> String {
    let object: [String: Any] = [
      "windowDays": max(1, windowDays),
      "resets": resets.map { entry -> [String: Any] in
        var row: [String: Any] = [
          "accountID": entry.accountID,
          "name": entry.accountName,
          "provider": entry.provider.rawValue,
          "metricID": entry.metricID,
          "metricLabel": entry.metricLabel,
          "resetAt": iso8601String(entry.resetAt),
          "resetIn": entry.countdown(at: now),
          "unlimited": entry.isUnlimited
        ]
        if let remaining = entry.remainingPercent {
          row["remainingPercent"] = remaining
        }
        return row
      }
    ]

    guard
      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      let string = String(data: data, encoding: .utf8)
    else {
      return #"{"error":"reset schedule serialization failed"}"#
    }
    return string
  }

  private static func dayCount(_ days: Int) -> String {
    let value = max(1, days)
    return "\(value) day\(value == 1 ? "" : "s")"
  }

  private static func iso8601String(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }
}
