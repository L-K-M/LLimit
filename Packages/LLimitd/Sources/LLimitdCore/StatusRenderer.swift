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

  /// How old an account's data may get before it is flagged `stale`. The snapshot does
  /// not record the refresh interval, so this is twice the longest interval the settings
  /// allow: a healthy account is never flagged between two normal cycles, and a failing
  /// account is flagged at once through `failed` instead.
  static let staleAfter = 2 * TimeInterval(AppSettings.refreshIntervalRange.upperBound) * 60

  /// Longest error text any surface prints. Provider errors can carry whole HTML pages.
  static let maximumErrorLength = 160
  /// How much raw error text is scanned. The rest of a page cannot reach the output.
  static let maximumScannedErrorLength = 16_384

  /// What `UsageMetric.resetCountdown(at:)` returns for a reset that had already
  /// passed when a metric without `resetAt` was fetched.
  private static let passedResetCountdown = "reset"

  /// Removed from error text, each replaced by a space. Compiled once: every bar poll
  /// renders the snapshot again. The patterns are constants, so `try!` cannot fail.
  private static let errorTextNoise = [
    // Script and style blocks of an HTML error page, with their content. An unclosed
    // block (a page cut short) runs to the end, so no later opening is scanned again.
    #"(?is)<(script|style)\b[^>]*>.*?(?:</\1\s*>|$)"#,
    // Tag-shaped text only, so a comparison such as "a < b" is kept.
    #"</?[A-Za-z!][^<>]*>"#,
    // ANSI CSI sequences (colors, cursor movement) a terminal would obey.
    #"\x{1B}\[[0-?]*[ -/]*[@-~]"#
  ].map { try! NSRegularExpression(pattern: $0) }
  /// A tag split by a cut, such as "<div cla", which no later `>` can close.
  private static let trailingTagFragment = try! NSRegularExpression(pattern: #"<[A-Za-z!/][^<>]*$"#)
  /// Polybar parses "%{…}" in script output as formatting, including click-to-run
  /// "%{A1:command:}" regions; a space makes it plain text.
  private static let polybarTagOpener = "%{"

  /// One account as the status surfaces present it at render time.
  private struct AccountStatus {
    let accountID: String
    let provider: QuotaProvider
    let name: String
    /// Fresh this cycle, or carried from an earlier refresh when `failure` is set.
    let usage: ProviderUsage?
    let failure: ProviderFailure?
    let isStale: Bool

    var isFailed: Bool { failure != nil }
    var isLastKnown: Bool { failure != nil && usage != nil }
    var needsAttention: Bool { isFailed || isStale }
    /// The most-consumed metric, as remaining percent so "100" always means "full quota".
    var headline: Int? { usage?.metrics.compactMap(\.remainingPercent).min() }
  }

  private enum ResetState {
    case upcoming(String)
    case passed
  }

  /// One line per account with its metrics, plus failure lines. Credential-free:
  /// reads only the snapshot.
  public static func humanReadable(snapshot: QuotaSnapshot?, now: Date = Date()) -> String {
    guard let snapshot else {
      return "No quota data yet. Run `llimit refresh` (or start `llimit daemon`)."
    }

    var lines: [String] = []
    lines.append("Updated \(QuotaDisplayText.relativeAge(snapshot.generatedAt, now: now))")

    for status in accountStatuses(in: snapshot, now: now) {
      if let usage = status.usage {
        let metrics = usage.metrics.compactMap { metricLine($0, now: now) }
        let suffix = metrics.isEmpty ? "" : ": " + metrics.joined(separator: " · ")
        lines.append("\(status.name)\(freshnessNote(for: status, now: now))\(suffix)")
        if let warning = warningText(for: usage) {
          lines.append("\(status.name): WARNING \(warning)")
        }
      }
      if let failure = status.failure {
        lines.append("\(status.name): ERROR \(errorText(for: failure))")
      }
    }

    return lines.joined(separator: "\n")
  }

  /// Waybar `custom`-module JSON. `percentage` is the lowest remaining percent across
  /// accounts, last-known values of failing accounts included. `class` is
  /// `ok`/`warning`/`critical` from the lowest value among accounts refreshed this
  /// cycle; provider warnings and failed or stale accounts raise `ok` to `warning`.
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
  /// without distinguishing "absent" from "present but null". `resetIn` is counted
  /// down from `resetAt` at render time and omitted once the reset has passed.
  static func metricObject(_ metric: UsageMetric, now: Date) -> [String: Any] {
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
    if case .upcoming(let countdown)? = resetState(of: metric, now: now) {
      object["resetIn"] = countdown
    }
    if let resetAt = metric.resetAt {
      object["resetAt"] = iso8601(resetAt)
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
        "accounts": [Any](),
        "failures": [Any]()
      ]
    }

    let statuses = accountStatuses(in: snapshot, now: now)
    let text = statuses.isEmpty ? "LLimit" : statuses.map(textSegment).joined(separator: " · ")

    var tooltipLines = ["Updated \(QuotaDisplayText.relativeAge(snapshot.generatedAt, now: now))"]
    tooltipLines.append(humanReadable(snapshot: snapshot, now: now)
      .split(separator: "\n")
      .dropFirst()
      .joined(separator: "\n"))

    var object: [String: Any] = [
      "text": text,
      "tooltip": tooltipLines.joined(separator: "\n"),
      "class": statusClass(for: statuses).rawValue,
      "accounts": statuses.map { accountObject($0, now: now) },
      // Names and classifies every failing account for bars that only need a count or
      // a list; the sanitized message stays on the account entry.
      "failures": statuses.compactMap(failureSummary)
    ]
    if let minimum = statuses.compactMap(\.headline).min() {
      object["percentage"] = minimum
      if statuses.contains(where: {
        $0.headline == minimum && $0.usage.map(headlineIsEstimated(for:)) == true
      }) {
        object["estimated"] = true
      }
    }
    return object
  }

  /// Reduces provider error text to one plain line that is safe on every surface: a bar
  /// may parse it as markup (waybar's default) and a terminal obeys escape sequences.
  static func sanitizedErrorText(_ message: String) -> String {
    let scanned = message.prefix(maximumScannedErrorLength)
    var text = String(scanned)
    if scanned.endIndex != message.endIndex {
      text = droppingTrailingTagFragment(text)
    }
    for pattern in errorTextNoise {
      let range = NSRange(text.startIndex..., in: text)
      text = pattern.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
    }
    text = text.replacingOccurrences(of: polybarTagOpener, with: "% {")

    let separators = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
    let oneLine = text.components(separatedBy: separators)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    guard oneLine.count > maximumErrorLength else { return oneLine }

    let kept = droppingTrailingTagFragment(String(oneLine.prefix(maximumErrorLength - 1)))
    return kept.trimmingCharacters(in: .whitespaces) + "…"
  }

  /// Applied only after a cut: at the end of uncut text, "<x" is the provider's own text.
  private static func droppingTrailingTagFragment(_ text: String) -> String {
    let range = NSRange(text.startIndex..., in: text)
    return trailingTagFragment.stringByReplacingMatches(in: text, range: range, withTemplate: "")
  }

  /// Every account in the snapshot, ordered by provider and name: those with usage
  /// (fresh, or carried from an earlier refresh) and those that failed without any.
  private static func accountStatuses(in snapshot: QuotaSnapshot, now: Date) -> [AccountStatus] {
    let failuresByID = Dictionary(
      snapshot.failures.map { ($0.accountID, $0) },
      uniquingKeysWith: { first, _ in first }
    )

    var statuses = snapshot.providers.map { usage -> AccountStatus in
      let failure = failuresByID[usage.accountID]
      // A carried window can reset between two daemon cycles, or after the daemon stopped.
      let shown = failure == nil ? usage : usage.clearingElapsedWindows(at: now)
      return AccountStatus(
        accountID: usage.accountID,
        provider: usage.provider,
        name: usage.title,
        usage: shown,
        failure: failure,
        isStale: now.timeIntervalSince(usage.fetchedAt) > staleAfter
      )
    }

    var listedIDs = Set(statuses.map(\.accountID))
    for failure in snapshot.failures where !listedIDs.contains(failure.accountID) {
      listedIDs.insert(failure.accountID)
      statuses.append(AccountStatus(
        accountID: failure.accountID,
        provider: failure.provider,
        name: failureName(failure),
        usage: nil,
        failure: failure,
        isStale: false
      ))
    }

    return statuses.sorted { lhs, rhs in
      if lhs.provider.rawValue != rhs.provider.rawValue {
        return lhs.provider.rawValue < rhs.provider.rawValue
      }
      if lhs.name != rhs.name {
        return lhs.name < rhs.name
      }
      return lhs.accountID < rhs.accountID
    }
  }

  /// Names an account that has no usage to take a title from. Older snapshots record
  /// no failure title; the id prefix still tells two accounts of one provider apart.
  private static func failureName(_ failure: ProviderFailure) -> String {
    if let title = failure.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
      return title
    }

    let provider = failure.provider.displayName
    guard failure.accountID != failure.provider.rawValue else { return provider }
    return "\(provider) (\(failure.accountID.prefix(8)))"
  }

  private static func statusClass(for statuses: [AccountStatus]) -> StatusClass {
    guard !statuses.isEmpty else { return .empty }
    if statuses.allSatisfy(\.isFailed) { return .error }

    // Only current numbers can make the class critical: a failed or stale account's
    // numbers are last known, so it raises the class to warning at most.
    let minimum = statuses.filter { !$0.needsAttention }.compactMap(\.headline).min()
    let byQuota = minimum.map(quotaClass(remainingPercent:)) ?? .ok
    guard byQuota == .ok else { return byQuota }

    let needsAttention = statuses.contains { status in
      status.needsAttention || status.usage.flatMap(warningText(for:)) != nil
    }
    return needsAttention ? .warning : .ok
  }

  private static func quotaClass(remainingPercent: Int) -> StatusClass {
    switch remainingPercent {
    case ..<15:
      return .critical
    case ..<40:
      return .warning
    default:
      return .ok
    }
  }

  /// One `text` segment. A trailing "!" marks an account whose numbers are not current.
  private static func textSegment(_ status: AccountStatus) -> String {
    let marker = status.needsAttention ? "!" : ""
    guard let usage = status.usage else { return status.name + marker }

    if let remaining = status.headline {
      let qualifier = headlineIsEstimated(for: usage) ? "≈" : ""
      return "\(status.name) \(qualifier)\(remaining)%\(marker)"
    }
    let balances = usage.metrics.compactMap { metric -> String? in
      guard !metric.isUnlimited, let value = metric.usageLine else { return nil }
      return "\(metric.label) \(value)"
    }
    let segment = balances.isEmpty ? status.name : "\(status.name) \(balances.joined(separator: " / "))"
    return segment + marker
  }

  private static func accountObject(_ status: AccountStatus, now: Date) -> [String: Any] {
    var account: [String: Any] = [
      "id": status.accountID,
      "provider": status.provider.rawValue,
      "name": status.name,
      "remainingPercent": status.headline as Any,
      "stale": status.isStale,
      // `failed`: the latest refresh of this account failed. `lastKnown`: the usage
      // shown is carried from an earlier successful refresh at `fetchedAt`.
      "failed": status.isFailed,
      "lastKnown": status.isLastKnown,
      // Per-limit breakdown. The headline `remainingPercent` above is only the
      // worst metric; a popup (the tray) needs every limit as its own row.
      // Additive: bars that read only the older keys are unaffected.
      "metrics": (status.usage?.metrics ?? []).map { metricObject($0, now: now) }
    ]
    if let usage = status.usage {
      account["fetchedAt"] = iso8601(usage.fetchedAt)
      if let warning = warningText(for: usage) {
        account["warning"] = warning
      }
      if headlineIsEstimated(for: usage) {
        account["estimated"] = true
      }
    }
    if let failure = status.failure {
      account["errorKind"] = failure.kind.rawValue
      account["error"] = errorText(for: failure)
    }
    return account
  }

  private static func failureSummary(_ status: AccountStatus) -> [String: Any]? {
    guard let failure = status.failure else { return nil }
    return [
      "id": status.accountID,
      "provider": status.provider.rawValue,
      "name": status.name,
      "errorKind": failure.kind.rawValue
    ]
  }

  private static func metricLine(_ metric: UsageMetric, now: Date) -> String? {
    if let remaining = metric.remainingPercent {
      let qualifier = metric.isPercentageEstimated ? "≈" : ""
      var text = "\(metric.label) \(qualifier)\(remaining)% left"
      if metric.isPercentageEstimated {
        text += " (estimated)"
      }
      switch resetState(of: metric, now: now) {
      case .upcoming(let countdown)?:
        text += " (resets in \(countdown))"
      case .passed?:
        text += " (reset due)"
      case nil:
        break
      }
      return text
    }
    if metric.isUnlimited {
      return "\(metric.label) unlimited"
    }
    if let usageLine = metric.usageLine {
      return "\(metric.label) \(usageLine)"
    }
    if case .passed? = resetState(of: metric, now: now) {
      return "\(metric.label) reset since the last successful refresh"
    }
    return nil
  }

  /// Annotates an account line whose numbers are not from the latest cycle.
  private static func freshnessNote(for status: AccountStatus, now: Date) -> String {
    guard let usage = status.usage else { return "" }

    let age = QuotaDisplayText.relativeAge(usage.fetchedAt, now: now)
    if status.isLastKnown {
      return " (last known, \(age))"
    }
    return status.isStale ? " (stale, \(age))" : ""
  }

  /// Counted at render time: the fetch-time `resetIn` text would be frozen.
  private static func resetState(of metric: UsageMetric, now: Date) -> ResetState? {
    guard let countdown = metric.resetCountdown(at: now) else { return nil }
    if let resetAt = metric.resetAt {
      return resetAt <= now ? .passed : .upcoming(countdown)
    }
    // Without `resetAt` only the fetch-time text is known.
    return countdown == passedResetCountdown ? .passed : .upcoming(countdown)
  }

  private static func errorText(for failure: ProviderFailure) -> String {
    let text = sanitizedErrorText(failure.message)
    return text.isEmpty ? "Refresh failed (\(failure.kind.rawValue))" : text
  }

  private static func iso8601(_ date: Date) -> String {
    date.formatted(.iso8601)
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
