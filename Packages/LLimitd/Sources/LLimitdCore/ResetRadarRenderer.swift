import Foundation
import QuotaCore

/// The "reset radar": a chronological view of every upcoming reset across
/// providers. Rendered from the credential-free snapshot like the rest of
/// `StatusRenderer`, and kept in its own file so the bar contract stays put.
public extension StatusRenderer {
  /// One line per upcoming reset, soonest first.
  ///
  /// A missing snapshot is called out rather than reported as an empty schedule:
  /// "no data yet" and "nothing resets this week" must not read the same.
  static func resetsHumanReadable(
    snapshot: QuotaSnapshot?,
    now: Date = Date(),
    windowDays: Int = 7
  ) -> String {
    guard let snapshot else {
      return "No quota data yet. Run `llimit refresh` (or start `llimit daemon`)."
    }

    let window = dayCount(windowDays)
    let resets = snapshot.upcomingResets(now: now, within: windowInterval(windowDays))
    // A snapshot that stopped refreshing days ago renders as a clean all-clear
    // otherwise; say how old the data is.
    let stale = stalenessHint(snapshot: snapshot, now: now)
    guard !resets.isEmpty else {
      return "No resets in the next \(window)\(stale)."
    }

    var lines = ["Upcoming resets (next \(window))\(stale)"]
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
  ///
  /// `snapshot` (and `generatedAt` when present) let a consumer tell "no data
  /// yet" from "nothing scheduled".
  static func resetsJSON(
    snapshot: QuotaSnapshot?,
    now: Date = Date(),
    windowDays: Int = 7
  ) -> String {
    var object: [String: Any] = [
      "windowDays": max(1, windowDays),
      "snapshot": snapshot != nil
    ]

    if let snapshot {
      object["generatedAt"] = iso8601String(snapshot.generatedAt)
      object["resets"] = snapshot
        .upcomingResets(now: now, within: windowInterval(windowDays))
        .map { entry -> [String: Any] in
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
    } else {
      object["resets"] = [Any]()
    }

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

  /// " (data from 3d 4h ago)" once the snapshot is more than a day old, so an
  /// all-clear from stale data does not read like a fresh one.
  private static func stalenessHint(snapshot: QuotaSnapshot, now: Date) -> String {
    let age = now.timeIntervalSince(snapshot.generatedAt)
    guard age.isFinite, age > 86_400 else { return "" }
    let seconds = Int(min(age, Double(Int.max)))
    return " (data from \(formatShortDuration(seconds: seconds)) ago)"
  }

  private static func windowInterval(_ days: Int) -> TimeInterval {
    TimeInterval(max(1, days)) * 86_400
  }

  /// Matches `StatusRenderer.iso8601String`: a fresh formatter per call, because
  /// a shared one is a process-global mutable object (not thread-safe in
  /// swift-corelibs-foundation) and `ISO8601FormatStyle` does not exist there.
  private static func iso8601String(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }
}
