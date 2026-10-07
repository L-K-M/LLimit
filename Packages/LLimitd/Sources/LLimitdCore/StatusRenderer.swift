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

  static let maximumErrorLength = 160
  static let maximumScannedErrorLength = 16_384
  private static let criticalBelowPercent = 15
  private static let warningBelowPercent = 40
  private static let errorTextNoise = [
    #"(?is)<(script|style)\b[^>]*>.*?(?:</\1\s*>|$)"#,
    #"</?[A-Za-z!][^<>]*>"#,
    #"\x{1B}\[[0-?]*[ -/]*[@-~]"#
  ].map { try! NSRegularExpression(pattern: $0) }
  private static let trailingTagFragment = try! NSRegularExpression(pattern: #"<[A-Za-z!/][^<>]*$"#)

  /// One shared account view for JSON, human, compact and template rendering.
  struct AccountStatus {
    let key: QuotaAccountKey
    let name: String
    let usage: ProviderUsage?
    let failure: ProviderFailure?
    let isStale: Bool
    var isFailed: Bool { failure != nil }
    var needsAttention: Bool { isFailed || isStale }
    var isLastKnown: Bool { needsAttention && usage != nil }
    var headline: Int? { candidate(kind: nil).flatMap { candidate in
      if case .percent(let percent) = candidate.headroom { return percent }
      return nil
    } }
    func candidate(kind: QuotaWindowKind?) -> HeadroomRanking.Candidate? {
      usage.flatMap { HeadroomRanking.Candidate(usage: $0, kind: kind) }
    }
  }

  /// One line per account with its metrics, plus failure lines. Credential-free:
  /// reads only the snapshot.
  public static func humanReadable(snapshot: QuotaSnapshot?, now: Date = Date()) -> String {
    guard let snapshot else {
      return "No quota data yet. Run `llimit refresh` (or start `llimit daemon`)."
    }

    var lines: [String] = []
    lines.append("Updated \(relativeAge(snapshot.generatedAt, now: now))")

    for status in accountStatuses(in: snapshot, now: now) {
      if let usage = status.usage {
        let metrics = usage.metrics.compactMap { metricLine($0, now: now, includePace: !status.isFailed) }
        let suffix = metrics.isEmpty ? "" : ": " + metrics.joined(separator: " · ")
        let age = relativeAge(usage.fetchedAt, now: now)
        let note = status.isFailed ? " (last known, \(age))" : status.isStale ? " (stale, \(age))" : ""
        lines.append("\(status.name)\(note)\(suffix)")
        if let warning = warningText(for: usage) { lines.append("\(status.name): WARNING \(warning)") }
      }
      if let failure = status.failure { lines.append("\(status.name): ERROR \(errorText(for: failure))") }
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
  static func metricObject(_ metric: UsageMetric, now: Date = Date()) -> [String: Any] {
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
    if let resetIn = metric.resetCountdown(at: now), resetIn != "reset", !metric.isUnlimited {
      object["resetIn"] = resetIn
    }
    if let resetAt = metric.resetAt {
      object["resetAt"] = iso8601String(resetAt)
      object["resetSeconds"] = boundedSeconds(resetAt.timeIntervalSince(now))
    }
    object["window"] = QuotaWindowKind.classify(metricID: metric.id, label: metric.label).rawValue
    if let amount = metric.remainingAmount, amount.isFinite { object["remainingAmount"] = amount }
    if let usageLine = metric.usageLine {
      object["usageLine"] = usageLine
    }
    if let detail = metric.detail {
      object["detail"] = detail
    }
    if let pace = metric.paceEstimate, pace.isValid(at: now) {
      object["pace"] = pace.displayText(at: now)
      object["paceTrend"] = pace.trend.rawValue
      object["burnRatePerHour"] = pace.burnRatePerHour
      object["projectedPercentAtReset"] = pace.projectedPercentAtReset
      if let exhaustionAt = pace.exhaustionAt {
        object["exhaustionAt"] = ISO8601DateFormatter().string(from: exhaustionAt)
      }
    }
    return object
  }

  static func waybarObject(snapshot: QuotaSnapshot?, now: Date) -> [String: Any] {
    guard let snapshot else {
      return [
        "text": "LLimit: no data",
        "tooltip": "No quota snapshot yet. Run `llimit refresh`.",
        "class": StatusClass.empty.rawValue,
        "accounts": [Any](),
        "failures": [Any](),
        "resets": [Any]()
      ]
    }

    let statuses = accountStatuses(in: snapshot, now: now)
    var accounts: [[String: Any]] = []
    var remainingPercents: [Int] = []

    for status in statuses {
      let displayMetrics = (status.usage?.metrics ?? []).map { metric -> UsageMetric in
        var copy = metric
        if status.isFailed { copy.paceEstimate = nil }
        return copy
      }
      // An account's headline number is its most-consumed metric, expressed as
      // remaining percent so "100" always means "full quota".
      let remaining = status.headline
      if let remaining {
        remainingPercents.append(remaining)
      }
      var account: [String: Any] = [
        "id": status.key.accountID,
        "provider": status.key.provider.rawValue,
        "name": status.name,
        "remainingPercent": remaining as Any,
        "stale": status.isStale,
        "failed": status.isFailed,
        "lastKnown": status.isLastKnown,
        // Per-limit breakdown. The headline `remainingPercent` above is only the
        // worst metric; a popup (the tray) needs every limit as its own row.
        // Additive: bars that read only the older keys are unaffected.
        "metrics": displayMetrics.map { metricObject($0, now: now) }
      ]
      if let usage = status.usage {
        account["fetchedAt"] = iso8601String(usage.fetchedAt)
        if let warning = warningText(for: usage) { account["warning"] = warning }
        if headlineIsEstimated(for: usage) { account["estimated"] = true }
      }
      if let failure = status.failure {
        account["error"] = errorText(for: failure)
        account["errorKind"] = failure.kind.rawValue
      }
      accounts.append(account)
    }

    let text: String
    if statuses.isEmpty {
      text = "LLimit: no accounts"
    } else {
      text = statuses.map { textSegment($0, separator: " ") }.joined(separator: " · ")
    }

    var statusClass: StatusClass
    if !statuses.isEmpty && statuses.allSatisfy(\.isFailed) {
      statusClass = .error
    } else if statuses.isEmpty {
      statusClass = .empty
    } else {
      let classes = statuses.map { self.statusClass(for: $0, kind: nil) }
      statusClass = classes.contains(.critical) ? .critical
        : classes.contains(.warning) || classes.contains(.error) ? .warning
        : classes.contains(.ok) ? .ok : .empty
    }

    var tooltipLines = ["Updated \(relativeAge(snapshot.generatedAt, now: now))"]
    let detail = humanReadable(snapshot: snapshot, now: now)
      .split(separator: "\n")
      .dropFirst()
      .joined(separator: "\n")
    if !detail.isEmpty { tooltipLines.append(detail) }

    var object: [String: Any] = [
      "text": text,
      "tooltip": tooltipLines.joined(separator: "\n"),
      "class": statusClass.rawValue,
      "accounts": accounts,
      "failures": statuses.compactMap { status -> [String: Any]? in
        guard let failure = status.failure else { return nil }
        return ["id": status.key.accountID, "provider": status.key.provider.rawValue,
                "name": status.name, "errorKind": failure.kind.rawValue]
      },
      "resets": resetObjects(snapshot.upcomingResets(now: now, within: ResetsOptions.defaultHorizon), now: now)
    ]
    if let minimum = remainingPercents.min() {
      object["percentage"] = minimum
      if statuses.contains(where: {
        $0.headline == minimum && $0.usage.map(headlineIsEstimated(for:)) == true
      }) {
        object["estimated"] = true
      }
    }
    return object
  }

  public static func relativeAge(_ date: Date, now: Date) -> String {
    QuotaDisplayText.relativeAge(date, now: now)
  }

  static func accountStatuses(in snapshot: QuotaSnapshot, now: Date) -> [AccountStatus] {
    let failures = snapshot.preferredFailures
    var seen: Set<QuotaAccountKey> = []
    var statuses: [AccountStatus] = []
    for usage in snapshot.providers {
      guard seen.insert(usage.accountKey).inserted else { continue }
      let failure = failures[usage.accountKey]
      statuses.append(AccountStatus(
        key: usage.accountKey, name: singleLine(usage.title),
        usage: failure == nil ? usage : usage.clearingElapsedWindows(at: now), failure: failure,
        isStale: QuotaFreshness.isStale(fetchedAt: usage.fetchedAt, in: snapshot, now: now)
      ))
    }
    for failure in failures.values where !seen.contains(failure.accountKey) {
      let title = failure.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let fallback = failure.accountID == failure.provider.rawValue ? failure.provider.displayName
        : "\(failure.provider.displayName) (\(failure.accountID.prefix(8)))"
      statuses.append(AccountStatus(key: failure.accountKey, name: singleLine(title.isEmpty ? fallback : title),
                                    usage: nil, failure: failure, isStale: false))
    }
    return statuses.sorted {
      if $0.key.provider != $1.key.provider { return $0.key.provider.rawValue < $1.key.provider.rawValue }
      if $0.name != $1.name { return $0.name < $1.name }
      return $0.key.accountID < $1.key.accountID
    }
  }

  /// Classification is shared with templates, including failure and stale priority.
  static func statusClass(for status: AccountStatus, kind: QuotaWindowKind?) -> StatusClass {
    if status.isFailed { return .error }
    if status.isStale { return .warning }
    let candidate = status.candidate(kind: kind)
    let byQuota: StatusClass
    if case .percent(let percent)? = candidate?.headroom { byQuota = quotaClass(percent) }
    else { byQuota = status.usage == nil ? .empty : .ok }
    guard byQuota == .ok else { return byQuota }
    return status.usage.flatMap(warningText(for:)) == nil ? .ok : .warning
  }

  private static func quotaClass(_ remaining: Int) -> StatusClass {
    if remaining < criticalBelowPercent { return .critical }
    if remaining < warningBelowPercent { return .warning }
    return .ok
  }

  public static func compactLine(snapshot: QuotaSnapshot?, now: Date = Date()) -> String {
    guard let snapshot else { return "LLimit: no data" }
    let statuses = accountStatuses(in: snapshot, now: now)
    guard !statuses.isEmpty else { return "LLimit: no accounts" }
    return statuses.map { textSegment($0, separator: ":") }.joined(separator: " ")
  }

  public static func accountQuotaSummary(for key: QuotaAccountKey, snapshot: QuotaSnapshot?, now: Date = Date()) -> String {
    guard let snapshot, let status = accountStatuses(in: snapshot, now: now).first(where: { $0.key == key }) else { return "no data yet" }
    let reading = status.usage.map { usage in
      if let candidate = status.candidate(kind: nil) { return StatusTemplate.remainingText(candidate) + (candidate.headroom == .unlimited ? "" : " left") }
      return usage.metrics.compactMap(amountText).first ?? "no quota data"
    }
    if let failure = status.failure {
      return "refresh failed (\(failure.kind.rawValue))" + (reading.map { "; last known \($0)" } ?? "")
    }
    return (reading ?? "no data yet") + (status.isStale ? " (stale)" : "")
  }

  private static func textSegment(_ status: AccountStatus, separator: String) -> String {
    let marker = status.needsAttention ? "!" : ""
    guard let usage = status.usage else { return status.name + marker }
    if let candidate = status.candidate(kind: nil) {
      return status.name + separator + StatusTemplate.remainingText(candidate) + marker
    }
    let balances = usage.metrics.compactMap { metric -> String? in
      guard !metric.isUnlimited, let value = amountText(metric) else { return nil }
      return "\(singleLine(metric.label)) \(value)"
    }
    return status.name + (balances.isEmpty ? "" : separator + balances.joined(separator: " / ")) + marker
  }

  static func amountText(_ metric: UsageMetric) -> String? {
    if let line = metric.usageLine { return singleLine(line) }
    guard let amount = metric.remainingAmount, amount.isFinite else { return nil }
    return String(amount)
  }

  private static func metricLine(_ metric: UsageMetric, now: Date, includePace: Bool) -> String? {
    let label = singleLine(metric.label)
    if metric.isUnlimited { return "\(label) unlimited" }
    var text: String
    if let remaining = metric.remainingPercent {
      text = "\(label) \(metric.isPercentageEstimated ? "≈" : "")\(remaining)% left"
      if metric.isPercentageEstimated { text += " (estimated)" }
    } else if let line = amountText(metric) { text = "\(label) \(line)" }
    else if metric.resetCountdown(at: now) == "reset" { return "\(label) reset since the last successful refresh" }
    else { return nil }
    if let reset = metric.resetCountdown(at: now) {
      text += reset == "reset" ? " (reset due)" : " (resets in \(reset))"
    }
    if includePace, let pace = metric.paceEstimate, pace.trend == .runsOut, pace.isValid(at: now) {
      text += " · \(pace.displayText(at: now))"
    }
    return text
  }

  static func singleLine(_ value: String) -> String {
    value.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
      .filter { !$0.isEmpty }.joined(separator: " ")
  }

  static func sanitizedErrorText(_ message: String) -> String {
    // Bound scalars: one grapheme can contain arbitrarily many combining marks.
    let scanned = message.unicodeScalars.prefix(maximumScannedErrorLength)
    var text = String(String.UnicodeScalarView(scanned))
    if scanned.endIndex != message.unicodeScalars.endIndex { text = droppingTrailingTagFragment(text) }
    for pattern in errorTextNoise {
      text = pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
    }
    text = singleLine(text.replacingOccurrences(of: "%{", with: "% {"))
    guard text.unicodeScalars.count > maximumErrorLength else { return text }
    let kept = String(String.UnicodeScalarView(text.unicodeScalars.prefix(maximumErrorLength - 1)))
    return droppingTrailingTagFragment(kept).trimmingCharacters(in: .whitespaces) + "…"
  }

  private static func droppingTrailingTagFragment(_ text: String) -> String {
    trailingTagFragment.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
  }

  private static func errorText(for failure: ProviderFailure) -> String {
    let text = sanitizedErrorText(failure.message)
    return text.isEmpty ? "Refresh failed (\(failure.kind.rawValue))" : text
  }

  static func boundedSeconds(_ interval: TimeInterval) -> Int {
    guard interval.isFinite, interval > 0 else { return 0 }
    guard interval < Double(Int.max) else { return Int.max }
    return Int(interval.rounded(.down))
  }

  static func iso8601String(_ date: Date) -> String {
    // Corelibs formatters are mutable; never share one between threads.
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
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
