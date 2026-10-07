import Foundation
import QuotaCore

/// One expansion per account, using the renderer's shared account view and class.
public enum StatusTemplate {
  public enum Placeholder: String, CaseIterable, Sendable {
    case id, name, provider, remaining, metric, kind, reset, age, stale
    case statusClass = "class"
  }
  public static let defaultSeparator = " · "
  public static let pickDefault = "{id}\t{name}"

  public static func render(
    _ template: String, snapshot: QuotaSnapshot?, kind: QuotaWindowKind?, separator: String, now: Date
  ) -> String {
    guard let snapshot else { return "" }
    return StatusRenderer.accountStatuses(in: snapshot, now: now).map { row in
      let candidate = row.candidate(kind: kind)
      let metric = candidate?.limitingMetric
      return expand(template) { name in
        guard let placeholder = Placeholder(rawValue: name) else { return nil }
        let value: String
        switch placeholder {
        case .id: value = row.key.accountID
        case .name: value = row.name
        case .provider: value = row.key.provider.rawValue
        case .remaining: value = remainingText(candidate)
        case .metric: value = metric?.label ?? ""
        case .kind: value = metric.map { QuotaWindowKind.classify(metricID: $0.id, label: $0.label).rawValue } ?? ""
        case .reset: value = metric?.resetCountdown(at: now) ?? ""
        case .statusClass: value = StatusRenderer.statusClass(for: row, kind: kind).rawValue
        case .age: value = row.usage.map { StatusRenderer.relativeAge($0.fetchedAt, now: now) } ?? ""
        case .stale: value = row.isStale ? "stale" : ""
        }
        return StatusRenderer.singleLine(value)
      }
    }.joined(separator: separator)
  }

  public static func render(
    _ template: String, accountKey: QuotaAccountKey, in snapshot: QuotaSnapshot, kind: QuotaWindowKind?, now: Date
  ) -> String {
    render(template, snapshot: StatusCommand.restricted(snapshot, to: [accountKey]), kind: kind, separator: "", now: now)
  }

  static func remainingText(_ candidate: HeadroomRanking.Candidate?) -> String {
    switch candidate?.headroom {
    case .percent(let percent)?: return "\(candidate?.isEstimated == true ? "≈" : "")\(percent)%"
    case .unlimited?: return "unlimited"
    case nil: return "n/a"
    }
  }

  /// Unknown placeholders and unmatched braces remain literal.
  static func expand(_ template: String, value: (String) -> String?) -> String {
    var output = ""
    var rest = template[...]
    while let open = rest.firstIndex(of: "{") {
      output += rest[..<open]
      let start = rest.index(after: open)
      guard let close = rest[start...].firstIndex(of: "}"), let replacement = value(String(rest[start..<close])) else {
        output += "{"
        rest = rest[start...]
        continue
      }
      output += replacement
      rest = rest[rest.index(after: close)...]
    }
    return output + rest
  }
}
