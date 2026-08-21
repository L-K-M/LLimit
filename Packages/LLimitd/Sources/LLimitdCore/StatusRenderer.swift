import Foundation
import QuotaCore

/// Renders a stored `QuotaSnapshot` for the terminal and for status bars.
///
/// The `--json` output is the waybar/polybar contract (Phase 2 wires a bar module to
/// it). Top-level keys follow waybar's `custom` module convention — `text`,
/// `tooltip`, `class`, `percentage` — plus an `accounts` array for richer consumers.
/// It is built exclusively from the snapshot file, which never contains credentials,
/// so this output is safe to hand to any bar or script.
public enum StatusRenderer {
  public enum StatusClass: String, Sendable {
    case ok
    case warning
    case critical
    case error
    case empty
  }

  /// One line per account with its metrics, plus failure lines. Credential-free:
  /// reads only the snapshot.
  public static func humanReadable(snapshot: QuotaSnapshot?, now: Date = Date()) -> String {
    guard let snapshot else {
      return "No quota data yet. Run `llimit refresh` (or start `llimit daemon`)."
    }

    var lines: [String] = []
    lines.append("Updated \(relativeAge(snapshot.generatedAt, now: now))")

    for usage in snapshot.providers.sorted(by: titleOrder) {
      let metrics = usage.metrics.compactMap { metric -> String? in
        if let remaining = metric.remainingPercent {
          var text = "\(metric.label) \(remaining)% left"
          if let reset = metric.resetIn {
            text += " (resets in \(reset))"
          }
          return text
        }
        if metric.isUnlimited {
          return "\(metric.label) unlimited"
        }
        return metric.usageLine.map { "\(metric.label) \($0)" }
      }
      let suffix = metrics.isEmpty ? "" : ": " + metrics.joined(separator: " · ")
      lines.append("\(usage.title)\(suffix)")
    }

    for failure in snapshot.failures.sorted(by: { $0.accountID < $1.accountID }) {
      lines.append("\(failure.provider.displayName): ERROR \(failure.message)")
    }

    return lines.joined(separator: "\n")
  }

  /// Waybar `custom`-module JSON. `percentage` is the lowest remaining percent across
  /// accounts (the number a bar would color on); `class` is `ok`/`warning`/`critical`
  /// from that same minimum, `error` when every account failed, `empty` with no data.
  public static func waybarJSON(snapshot: QuotaSnapshot?, now: Date = Date()) -> String {
    let object = waybarObject(snapshot: snapshot, now: now)
    guard
      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      let string = String(data: data, encoding: .utf8)
    else {
      return #"{"class":"error","text":"LLimit: status serialization failed"}"#
    }
    return string
  }

  static func waybarObject(snapshot: QuotaSnapshot?, now: Date) -> [String: Any] {
    guard let snapshot else {
      return [
        "text": "LLimit: no data",
        "tooltip": "No quota snapshot yet. Run `llimit refresh`.",
        "class": StatusClass.empty.rawValue,
        "accounts": [Any]()
      ]
    }

    let providers = snapshot.providers.sorted(by: titleOrder)
    var accounts: [[String: Any]] = []
    var remainingPercents: [Int] = []

    for usage in providers {
      // An account's headline number is its most-consumed metric, expressed as
      // remaining percent so "100" always means "full quota".
      let remaining = usage.metrics.compactMap(\.remainingPercent).min()
      if let remaining {
        remainingPercents.append(remaining)
      }
      accounts.append([
        "id": usage.accountID,
        "provider": usage.provider.rawValue,
        "name": usage.title,
        "remainingPercent": remaining as Any,
        "stale": now.timeIntervalSince(usage.fetchedAt) > 2 * 3600
      ])
    }

    let text: String
    if providers.isEmpty {
      text = "LLimit"
    } else {
      text = providers.map { usage in
        if let remaining = usage.metrics.compactMap(\.remainingPercent).min() {
          return "\(usage.title) \(remaining)%"
        }
        return usage.title
      }.joined(separator: " · ")
    }

    let statusClass: StatusClass
    if providers.isEmpty && !snapshot.failures.isEmpty {
      statusClass = .error
    } else if providers.isEmpty {
      statusClass = .empty
    } else if let minimum = remainingPercents.min() {
      switch minimum {
      case ..<15:
        statusClass = .critical
      case ..<40:
        statusClass = .warning
      default:
        statusClass = .ok
      }
    } else {
      statusClass = .ok
    }

    var tooltipLines = ["Updated \(relativeAge(snapshot.generatedAt, now: now))"]
    tooltipLines.append(humanReadable(snapshot: snapshot, now: now)
      .split(separator: "\n")
      .dropFirst()
      .joined(separator: "\n"))

    var object: [String: Any] = [
      "text": text,
      "tooltip": tooltipLines.joined(separator: "\n"),
      "class": statusClass.rawValue,
      "accounts": accounts
    ]
    if let minimum = remainingPercents.min() {
      object["percentage"] = minimum
    }
    return object
  }

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

  private static let titleOrder: (ProviderUsage, ProviderUsage) -> Bool = { lhs, rhs in
    if lhs.provider.rawValue != rhs.provider.rawValue {
      return lhs.provider.rawValue < rhs.provider.rawValue
    }
    return lhs.title < rhs.title
  }
}
