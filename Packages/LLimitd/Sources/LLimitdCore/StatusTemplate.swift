import Foundation
import QuotaCore

/// `llimit status --format <template>`: one template expansion per account, joined
/// by a separator, for tmux, starship, shell prompts and scripts that want a short
/// line without parsing JSON. Like the `--json` contract it is built only from the
/// snapshot, so the output never contains credentials.
///
/// An account's figures come from its limiting metric as `HeadroomRanking` defines
/// it: the least remaining percentage (of one window kind, when given). Accounts
/// keep the human-readable order; accounts that failed before ever reporting usage
/// follow. An unknown `{placeholder}` is left as written.
public enum StatusTemplate {
  public enum Placeholder: String, CaseIterable, Sendable {
    /// Account id.
    case id
    /// Account name.
    case name
    /// Provider id, e.g. `anthropic`.
    case provider
    /// `42%`, `≈42%` when estimated, `unlimited`, or `n/a` without a percentage.
    case remaining
    /// Label of the limit behind `{remaining}`, e.g. `7-day limit`.
    case metric
    /// That limit's window kind: `session`, `daily`, `weekly`, `monthly`, `other`.
    case kind
    /// Time until that limit resets, e.g. `3h 12m`; empty when unknown.
    case reset
    /// `ok`, `warning` or `critical` by remaining quota, `error` when the last
    /// refresh failed, `empty` without a percentage.
    case statusClass = "class"
    /// Age of the account's data, e.g. `4 min ago`; empty when it never reported.
    case age
    /// `stale` when the data is older than two hours, otherwise empty.
    case stale
  }

  public static let defaultSeparator = " · "
  /// `llimit pick`'s default line: account id, a tab, account name.
  public static let pickDefault = "{id}\t{name}"

  /// The `--json` contract's class cutoffs, so a template's `{class}` and the
  /// bar modules agree on when an account turns warning or critical.
  private static let criticalBelowPercent = 15
  private static let warningBelowPercent = 40

  public static func render(
    _ template: String,
    snapshot: QuotaSnapshot?,
    kind: QuotaWindowKind?,
    separator: String,
    now: Date
  ) -> String {
    guard let snapshot else { return "" }
    return rows(in: snapshot, kind: kind)
      .map { row in
        expand(template) { name in
          Placeholder(rawValue: name).map { singleLine(value(of: $0, for: row, now: now)) }
        }
      }
      .joined(separator: separator)
  }

  /// One account's line, e.g. the account `llimit pick` chose.
  public static func render(
    _ template: String,
    accountID: String,
    in snapshot: QuotaSnapshot,
    kind: QuotaWindowKind?,
    now: Date
  ) -> String {
    render(
      template,
      snapshot: StatusCommand.restricted(snapshot, to: [accountID]),
      kind: kind,
      separator: "",
      now: now
    )
  }

  /// `42%`, `≈42%` or `unlimited`; shared with `llimit check` messages.
  static func remainingText(_ candidate: HeadroomRanking.Candidate?) -> String {
    switch candidate?.headroom {
    case .percent(let percent)?:
      return "\(candidate?.isEstimated == true ? "≈" : "")\(percent)%"
    case .unlimited?:
      return "unlimited"
    case nil:
      return "n/a"
    }
  }

  // MARK: - Rows

  private struct Row {
    let accountID: String
    let provider: QuotaProvider
    let name: String
    let usage: ProviderUsage?
    let isFailing: Bool
    let candidate: HeadroomRanking.Candidate?
  }

  private static func rows(in snapshot: QuotaSnapshot, kind: QuotaWindowKind?) -> [Row] {
    let failingIDs = Set(snapshot.failures.map(\.accountID))
    let reportedIDs = Set(snapshot.providers.map(\.accountID))

    let reported = snapshot.providers.sorted(by: displayOrder).map { usage in
      Row(
        accountID: usage.accountID,
        provider: usage.provider,
        name: usage.title,
        usage: usage,
        isFailing: failingIDs.contains(usage.accountID),
        candidate: HeadroomRanking.Candidate(usage: usage, kind: kind)
      )
    }
    let failedOnly = snapshot.failures
      .filter { !reportedIDs.contains($0.accountID) }
      .sorted { $0.accountID < $1.accountID }
      .map { failure in
        Row(
          accountID: failure.accountID,
          provider: failure.provider,
          name: failure.provider.displayName,
          usage: nil,
          isFailing: true,
          candidate: nil
        )
      }
    return reported + failedOnly
  }

  /// The human-readable status order: provider id, then account name.
  private static func displayOrder(_ lhs: ProviderUsage, _ rhs: ProviderUsage) -> Bool {
    if lhs.provider != rhs.provider {
      return lhs.provider.rawValue < rhs.provider.rawValue
    }
    if lhs.title != rhs.title {
      return lhs.title < rhs.title
    }
    return lhs.accountID < rhs.accountID
  }

  // MARK: - Placeholders

  private static func value(of placeholder: Placeholder, for row: Row, now: Date) -> String {
    let metric = row.candidate?.limitingMetric

    switch placeholder {
    case .id:
      return row.accountID
    case .name:
      return row.name
    case .provider:
      return row.provider.rawValue
    case .remaining:
      return remainingText(row.candidate)
    case .metric:
      return metric?.label ?? ""
    case .kind:
      return metric.map { QuotaWindowKind.classify(metricID: $0.id, label: $0.label).rawValue } ?? ""
    case .reset:
      return metric?.resetCountdown(at: now) ?? ""
    case .statusClass:
      return statusClass(for: row).rawValue
    case .age:
      return row.usage.map { StatusRenderer.relativeAge($0.fetchedAt, now: now) } ?? ""
    case .stale:
      guard let usage = row.usage, now.timeIntervalSince(usage.fetchedAt) > HeadroomRanking.defaultMaxAge else {
        return ""
      }
      return "stale"
    }
  }

  private static func statusClass(for row: Row) -> StatusRenderer.StatusClass {
    if row.isFailing {
      return .error
    }
    guard let candidate = row.candidate else {
      return .empty
    }

    if case .percent(let percent) = candidate.headroom {
      if percent < criticalBelowPercent {
        return .critical
      }
      if percent < warningBelowPercent {
        return .warning
      }
    }

    // Like the contract, a provider warning ("Rate limit reached") lifts ok to warning.
    let warning = row.usage?.warning?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return warning.isEmpty ? .ok : .warning
  }

  /// Keeps one account on one line and tab-separated output intact, whatever an
  /// account name contains.
  private static func singleLine(_ value: String) -> String {
    String(value.map { $0.isNewline || $0 == "\t" ? " " : $0 })
  }

  /// Replaces each `{name}` that `value` resolves; everything else, including
  /// unknown names and unpaired braces, stays literal.
  static func expand(_ template: String, value: (String) -> String?) -> String {
    var output = ""
    var rest = template[...]

    while let open = rest.firstIndex(of: "{") {
      output += rest[..<open]
      let nameStart = rest.index(after: open)
      guard
        let close = rest[nameStart...].firstIndex(of: "}"),
        let replacement = value(String(rest[nameStart..<close]))
      else {
        output += "{"
        rest = rest[nameStart...]
        continue
      }
      output += replacement
      rest = rest[rest.index(after: close)...]
    }

    output += rest
    return output
  }
}
