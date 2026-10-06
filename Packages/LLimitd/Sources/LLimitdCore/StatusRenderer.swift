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
          let qualifier = metric.isPercentageEstimated ? "≈" : ""
          var text = "\(metric.label) \(qualifier)\(remaining)% left"
          if metric.isPercentageEstimated {
            text += " (estimated)"
          }
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
      if let warning = warningText(for: usage) {
        lines.append("\(usage.title): WARNING \(warning)")
      }
    }

    for failure in snapshot.failures.sorted(by: { $0.accountID < $1.accountID }) {
      lines.append("\(failure.provider.displayName): ERROR \(failure.message)")
    }

    return lines.joined(separator: "\n")
  }

  /// Waybar `custom`-module JSON. `percentage` is the lowest remaining percent across
  /// accounts (the number a bar would color on); `class` is `ok`/`warning`/`critical`
  /// from that same minimum, with provider warnings elevating `ok` to `warning`;
  /// `error` when every account failed, `empty` with no data.
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

  /// One limit as a JSON row for popup consumers (the tray). Optional fields are
  /// omitted rather than emitted as null, so a consumer can use plain key lookup
  /// without distinguishing "absent" from "present but null".
  static func metricObject(_ metric: UsageMetric) -> [String: Any] {
    var object: [String: Any] = [
      "id": metric.id,
      "label": metric.label,
      "unlimited": metric.isUnlimited
    ]
    if let remaining = metric.remainingPercent {
      object["remainingPercent"] = remaining
    }
    if metric.isPercentageEstimated {
      object["estimated"] = true
    }
    if let resetIn = metric.resetIn {
      object["resetIn"] = resetIn
    }
    if let usageLine = metric.usageLine {
      object["usageLine"] = usageLine
    }
    if let detail = metric.detail {
      object["detail"] = detail
    }
    return object
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
      var account: [String: Any] = [
        "id": usage.accountID,
        "provider": usage.provider.rawValue,
        "name": usage.title,
        "remainingPercent": remaining as Any,
        "stale": now.timeIntervalSince(usage.fetchedAt) > 2 * 3600,
        // Per-limit breakdown. The headline `remainingPercent` above is only the
        // worst metric; a popup (the tray) needs every limit as its own row.
        // Additive: bars that read only the older keys are unaffected.
        "metrics": usage.metrics.map(metricObject)
      ]
      if let warning = warningText(for: usage) {
        account["warning"] = warning
      }
      if headlineIsEstimated(for: usage) {
        account["estimated"] = true
      }
      accounts.append(account)
    }

    let text: String
    if providers.isEmpty {
      text = "LLimit"
    } else {
      text = providers.map { usage in
        if let remaining = usage.metrics.compactMap(\.remainingPercent).min() {
          let qualifier = headlineIsEstimated(for: usage) ? "≈" : ""
          return "\(usage.title) \(qualifier)\(remaining)%"
        }
        let balances = usage.metrics.compactMap { metric -> String? in
          guard !metric.isUnlimited, let value = metric.usageLine else { return nil }
          return "\(metric.label) \(value)"
        }
        return balances.isEmpty ? usage.title : "\(usage.title) \(balances.joined(separator: " / "))"
      }.joined(separator: " · ")
    }

    var statusClass: StatusClass
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
    if statusClass == .ok, providers.contains(where: { warningText(for: $0) != nil }) {
      statusClass = .warning
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
      if providers.contains(where: {
        $0.metrics.compactMap(\.remainingPercent).min() == minimum && headlineIsEstimated(for: $0)
      }) {
        object["estimated"] = true
      }
    }
    return object
  }

  /// Tightest useful rendering — `Claude:84% GPT:62%` — for shell prompts and
  /// `watch`-style loops. Accounts without a percentage show their usage line.
  public static func compactLine(snapshot: QuotaSnapshot?) -> String {
    guard let snapshot, !snapshot.providers.isEmpty else {
      return "LLimit: no data"
    }
    return snapshot.providers.sorted(by: titleOrder).map { usage in
      if let remaining = usage.metrics.compactMap(\.remainingPercent).min() {
        let qualifier = headlineIsEstimated(for: usage) ? "≈" : ""
        return "\(usage.title):\(qualifier)\(remaining)%"
      }
      let balances = usage.metrics.compactMap { metric -> String? in
        guard !metric.isUnlimited, let value = metric.usageLine else { return nil }
        return "\(metric.label) \(value)"
      }
      return balances.isEmpty ? usage.title : "\(usage.title):\(balances.joined(separator: "/"))"
    }.joined(separator: " ")
  }

  /// Every upcoming reset across accounts, soonest first — answers "what frees
  /// up next?". One row per metric: "in 45m   Claude — 5-hour limit". Metrics
  /// that carry only the `resetIn` display text (no date) sort last — they
  /// can't be ordered reliably.
  public static func resetLines(snapshot: QuotaSnapshot?, now: Date = Date()) -> [String] {
    guard let snapshot else { return [] }
    let rows: [(date: Date, line: String)] = snapshot.providers.flatMap { usage in
      usage.metrics.compactMap { metric -> (Date, String)? in
        guard let countdown = metric.resetCountdown(at: now), countdown != "reset" else {
          return nil
        }
        let sortable = metric.resetAt.map { $0 > now ? $0 : Date.distantFuture } ?? .distantFuture
        return (sortable, "in \(countdown)   \(usage.title) — \(metric.label)")
      }
    }
    return rows.sorted { $0.date < $1.date }.map(\.line)
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

  private static func warningText(for usage: ProviderUsage) -> String? {
    guard let warning = usage.warning?.trimmingCharacters(in: .whitespacesAndNewlines),
          !warning.isEmpty else { return nil }
    return warning
  }

  private static func headlineIsEstimated(for usage: ProviderUsage) -> Bool {
    guard let remaining = usage.metrics.compactMap(\.remainingPercent).min() else { return false }
    return usage.metrics.contains {
      $0.remainingPercent == remaining && $0.isPercentageEstimated
    }
  }
}
