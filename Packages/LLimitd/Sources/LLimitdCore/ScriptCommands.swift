import Foundation
import QuotaCore

public struct CommandLineError: LocalizedError, Equatable, Sendable {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}

/// Resolve against the credential-free snapshot using provider + account identity.
public enum AccountTarget {
  public enum Resolution: Equatable, Sendable {
    case matched(Set<QuotaAccountKey>)
    case ambiguous([String])
    case unknown
  }

  public static func resolve(_ target: String, in snapshot: QuotaSnapshot?) -> Resolution {
    let wanted = target.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !wanted.isEmpty else { return .unknown }
    let keys = Set((snapshot?.providers.map(\.accountKey) ?? []) + (snapshot?.failures.map(\.accountKey) ?? []))
    let exact = keys.filter { $0.accountID.lowercased() == wanted.lowercased() }
    if !exact.isEmpty { return .matched(exact) }
    if let provider = QuotaProvider(rawValue: wanted.lowercased()) { return .matched(keys.filter { $0.provider == provider }) }
    let matches = keys.filter { $0.accountID.lowercased().hasPrefix(wanted.lowercased()) }
    let ids = Set(matches.map(\.accountID))
    if ids.count > 1 { return .ambiguous(ids.sorted()) }
    return matches.isEmpty ? .unknown : .matched(matches)
  }
}

public struct StatusOptions: Equatable, Sendable {
  public enum Output: Equatable, Sendable { case human, json, compact, template(String) }
  public enum Selection: Equatable, Sendable { case all, worst }
  public static let defaultWatchInterval: TimeInterval = 60
  public static let watchIntervalRange: ClosedRange<TimeInterval> = 1...86_400

  public var output: Output = .human
  public var accountTargets: [String] = []
  public var selection: Selection = .all
  public var kind: QuotaWindowKind?
  public var separator = StatusTemplate.defaultSeparator
  public var watchInterval: TimeInterval?
  public init() {}

  public static func parse(_ args: [String]) throws -> StatusOptions {
    var options = StatusOptions()
    var output: Output?
    var separator: String?
    var index = 0
    func setOutput(_ new: Output) throws {
      if let output, output != new { throw CommandLineError("--json, --compact and --format cannot be combined") }
      output = new
    }
    while index < args.count {
      let arg = args[index]
      switch arg {
      case "--json": try setOutput(.json)
      case "--compact": try setOutput(.compact)
      case "--format": try setOutput(.template(CommandLineValues.template(after: arg, in: args, at: &index)))
      case "--account":
        let target = try CommandLineValues.value(after: arg, in: args, at: &index)
        guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CommandLineError("--account needs a nonblank target") }
        options.accountTargets.append(target)
      case "--worst": options.selection = .worst
      case "--kind": options.kind = try CommandLineValues.kind(CommandLineValues.value(after: arg, in: args, at: &index))
      case "--separator": separator = try CommandLineValues.value(after: arg, in: args, at: &index)
      case "--watch":
        options.watchInterval = defaultWatchInterval
        if index + 1 < args.count, !args[index + 1].hasPrefix("-") {
          index += 1
          options.watchInterval = try watchDuration(args[index])
        }
      default:
        guard arg.hasPrefix("--watch=") else { throw CommandLineError("unknown status option: \(arg)") }
        options.watchInterval = try watchDuration(String(arg.dropFirst("--watch=".count)))
      }
      index += 1
    }
    options.output = output ?? .human
    let hasTemplate: Bool
    if case .template = options.output { hasTemplate = true } else { hasTemplate = false }
    if separator != nil && !hasTemplate { throw CommandLineError("--separator needs --format") }
    if options.kind != nil && !hasTemplate && options.selection != .worst { throw CommandLineError("--kind needs --format or --worst") }
    if let separator { options.separator = separator }
    return options
  }

  private static func watchDuration(_ text: String) throws -> TimeInterval {
    guard let seconds = CommandLineValues.duration(text), watchIntervalRange.contains(seconds) else {
      throw CommandLineError("--watch expects a duration between 1s and 1d")
    }
    return seconds
  }
}

public enum StatusCommand {
  public struct Rendering: Equatable, Sendable {
    public let text: String
    public let unmatchedTargets: [String]
  }

  public static func render(_ options: StatusOptions, snapshot: QuotaSnapshot?, now: Date) throws -> Rendering {
    var selected = snapshot
    var unmatched: [String] = []
    if !options.accountTargets.isEmpty {
      var keys: Set<QuotaAccountKey> = []
      for target in options.accountTargets {
        switch AccountTarget.resolve(target, in: snapshot) {
        case .matched(let matches) where matches.isEmpty: unmatched.append(target)
        case .matched(let matches): keys.formUnion(matches)
        case .ambiguous(let ids): throw CommandLineError("\"\(target)\" matches several accounts: \(ids.joined(separator: ", "))")
        case .unknown: unmatched.append(target)
        }
      }
      selected = snapshot.map { restricted($0, to: keys) }
    }
    if options.selection == .worst, let current = selected {
      let ranking = HeadroomRanking.rank(snapshot: current, filter: .init(kind: options.kind, eligibility: .anyReported), now: now)
      selected = restricted(current, to: Set(ranking.worst.map { [$0.accountKey] } ?? []))
    }
    let text: String
    switch options.output {
    case .human: text = StatusRenderer.humanReadable(snapshot: selected, now: now)
    case .json: text = StatusRenderer.waybarJSON(snapshot: selected, now: now)
    case .compact: text = StatusRenderer.compactLine(snapshot: selected, now: now)
    case .template(let template): text = StatusTemplate.render(template, snapshot: selected, kind: options.kind, separator: options.separator, now: now)
    }
    return Rendering(text: text, unmatchedTargets: unmatched)
  }

  static func restricted(_ snapshot: QuotaSnapshot, to keys: Set<QuotaAccountKey>) -> QuotaSnapshot {
    var selected = snapshot
    selected.providers.removeAll { !keys.contains($0.accountKey) }
    selected.failures.removeAll { !keys.contains($0.accountKey) }
    return selected
  }
}

/// Stable scripting contract shared by targeted and whole-snapshot checks.
public enum QuotaCheckStatus: Int32, Sendable {
  case ok = 0
  case belowMinimum = 1
  case staleOrFailing = 2
  case noData = 3
  case usage = 64
}

public struct HeadroomCriteria: Equatable, Sendable {
  public static let defaultMinimum = 1
  public var minimum = defaultMinimum
  public var maxAge: TimeInterval?
  public var kind: QuotaWindowKind?
  public init() {}

  mutating func parseOption(_ args: [String], at index: inout Int) throws -> Bool {
    let arg = args[index]
    switch arg {
    case "--min":
      let text = try CommandLineValues.value(after: arg, in: args, at: &index)
      guard let percent = Int(text), (0...100).contains(percent) else { throw CommandLineError("--min expects a percentage from 0 to 100") }
      minimum = percent
    case "--max-age":
      let text = try CommandLineValues.value(after: arg, in: args, at: &index)
      guard let seconds = CommandLineValues.duration(text) else { throw CommandLineError("--max-age expects a positive duration such as 30m or 2h") }
      maxAge = seconds
    case "--kind": kind = try CommandLineValues.kind(CommandLineValues.value(after: arg, in: args, at: &index))
    default: return false
    }
    return true
  }
}

public struct CheckOptions: Equatable, Sendable {
  /// Nil checks every account; a provider target checks its best current account.
  public var target: String?
  public var criteria = HeadroomCriteria()
  public init(target: String? = nil) { self.target = target }

  public static func parse(_ args: [String]) throws -> CheckOptions {
    var options = CheckOptions()
    var index = 0
    while index < args.count {
      let arg = args[index]
      if try options.criteria.parseOption(args, at: &index) { index += 1; continue }
      guard !arg.hasPrefix("-") else { throw CommandLineError("unknown check option: \(arg)") }
      guard options.target == nil else { throw CommandLineError("check takes at most one account or provider") }
      guard !arg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CommandLineError("check target is blank") }
      options.target = arg
      index += 1
    }
    return options
  }
}

public struct PickOptions: Equatable, Sendable {
  public var providers: Set<QuotaProvider>?
  public var criteria = HeadroomCriteria()
  public var template = StatusTemplate.pickDefault
  public init() {}

  public static func parse(_ args: [String]) throws -> PickOptions {
    var options = PickOptions()
    var index = 0
    while index < args.count {
      let arg = args[index]
      if try options.criteria.parseOption(args, at: &index) { index += 1; continue }
      switch arg {
      case "--provider":
        let list = try CommandLineValues.value(after: arg, in: args, at: &index)
        let ids = list.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        for id in ids {
          guard let provider = QuotaProvider(rawValue: id) else { throw CommandLineError("unknown provider \"\(id)\"") }
          options.providers = (options.providers ?? []).union([provider])
        }
      case "--format": options.template = try CommandLineValues.template(after: arg, in: args, at: &index)
      default: throw CommandLineError("unknown pick option: \(arg)")
      }
      index += 1
    }
    return options
  }
}

public struct QuotaVerdict: Equatable, Sendable {
  public let status: QuotaCheckStatus
  public let candidate: HeadroomRanking.Candidate?
  public let message: String
}

public enum QuotaCheck {
  private static let noSnapshotReason = "no snapshot yet; run `llimit refresh` or start the daemon"

  public static func check(_ options: CheckOptions, snapshot: QuotaSnapshot?, now: Date) -> QuotaVerdict {
    guard let target = options.target else { return checkAll(options.criteria, snapshot: snapshot, now: now) }
    switch AccountTarget.resolve(target, in: snapshot) {
    case .matched(let keys):
      return evaluate(snapshot: snapshot, filter: .init(accountKeys: keys), criteria: options.criteria, subject: target, now: now)
    case .ambiguous(let ids):
      return QuotaVerdict(status: .usage, candidate: nil, message: "\"\(target)\" matches several accounts: \(ids.joined(separator: ", "))")
    case .unknown:
      return QuotaVerdict(status: .noData, candidate: nil,
                          message: "no data: " + (snapshot == nil ? noSnapshotReason : "no account or provider matches \"\(target)\" in the snapshot"))
    }
  }

  public static func pick(_ options: PickOptions, snapshot: QuotaSnapshot?, now: Date) -> QuotaVerdict {
    let subject = options.providers.map { $0.map(\.rawValue).sorted().joined(separator: ", ") } ?? "any account"
    return evaluate(snapshot: snapshot, filter: .init(providers: options.providers), criteria: options.criteria, subject: subject, now: now)
  }

  private static func ranking(_ snapshot: QuotaSnapshot, filter: HeadroomRanking.Filter, criteria: HeadroomCriteria, now: Date) -> HeadroomRanking.Ranking {
    var filter = filter
    filter.kind = criteria.kind
    filter.eligibility = .current(maxAge: criteria.maxAge)
    return HeadroomRanking.rank(snapshot: snapshot, filter: filter, now: now)
  }

  private static func evaluate(snapshot: QuotaSnapshot?, filter: HeadroomRanking.Filter, criteria: HeadroomCriteria, subject: String, now: Date) -> QuotaVerdict {
    guard let snapshot else { return QuotaVerdict(status: .noData, candidate: nil, message: "no data: \(noSnapshotReason)") }
    let ranking = ranking(snapshot, filter: filter, criteria: criteria, now: now)
    if let best = ranking.best {
      let status: QuotaCheckStatus = meets(best.headroom, minimum: criteria.minimum) ? .ok : .belowMinimum
      let prefix = status == .ok ? "ok" : "below minimum"
      let suffix = status == .ok ? "" : "; minimum is \(criteria.minimum)%"
      return QuotaVerdict(status: status, candidate: best, message: "\(prefix): \(describe(best))\(suffix)")
    }
    let unusable = ranking.exclusions.compactMap { describe($0, now: now) }
    if !unusable.isEmpty { return QuotaVerdict(status: .staleOrFailing, candidate: nil, message: "stale or failing: \(unusable.joined(separator: "; "))") }
    let window = criteria.kind.map { " for the \($0.rawValue) window" } ?? ""
    return QuotaVerdict(status: .noData, candidate: nil, message: "no data: no quota reported\(window) by \(subject)")
  }

  /// Whole-snapshot priority: stale/failing (2), missing quota (3), low (1), ok (0).
  /// A healthy account must not mask another account's problem.
  private static func checkAll(_ criteria: HeadroomCriteria, snapshot: QuotaSnapshot?, now: Date) -> QuotaVerdict {
    guard let snapshot else { return QuotaVerdict(status: .noData, candidate: nil, message: "no data: \(noSnapshotReason)") }
    let ranking = ranking(snapshot, filter: .init(), criteria: criteria, now: now)
    let unusable = ranking.exclusions.compactMap { describe($0, now: now) }
    let missing = ranking.exclusions.filter { $0.reason == .noQuotaData }.map { "no data: \(StatusRenderer.singleLine($0.name)) (\($0.provider.rawValue)) reports no quota" }
    let low = ranking.candidates.filter { !meets($0.headroom, minimum: criteria.minimum) }
    let issues = unusable.map { "stale or failing: \($0)" } + missing + low.map { "below minimum: \(describe($0)); minimum is \(criteria.minimum)%" }
    let status: QuotaCheckStatus = !unusable.isEmpty ? .staleOrFailing : !missing.isEmpty ? .noData : !low.isEmpty ? .belowMinimum : .ok
    if ranking.candidates.isEmpty && ranking.exclusions.isEmpty {
      return QuotaVerdict(status: .noData, candidate: nil, message: "no data: no accounts in the snapshot")
    }
    return QuotaVerdict(status: status, candidate: nil, message: issues.isEmpty ? "ok: every account meets the minimum" : issues.joined(separator: "\n"))
  }

  private static func meets(_ headroom: HeadroomRanking.Headroom, minimum: Int) -> Bool {
    if case .percent(let percent) = headroom { return percent >= minimum }
    return true
  }

  private static func describe(_ candidate: HeadroomRanking.Candidate) -> String {
    let remaining = StatusTemplate.remainingText(candidate)
    let amount = candidate.headroom == .unlimited ? "unlimited quota" : "\(remaining) left"
    return "\(StatusRenderer.singleLine(candidate.usage.title)) (\(candidate.usage.provider.rawValue)) has \(amount) (\(StatusRenderer.singleLine(candidate.limitingMetric.label)))"
  }

  private static func describe(_ exclusion: HeadroomRanking.Exclusion, now: Date) -> String? {
    let account = "\(StatusRenderer.singleLine(exclusion.name)) (\(exclusion.provider.rawValue))"
    switch exclusion.reason {
    case .failing(let kind): return "\(account) failed to refresh (\(kind.rawValue))"
    case .stale(let at): return "\(account) was last updated \(StatusRenderer.relativeAge(at, now: now))"
    case .noQuotaData: return nil
    }
  }
}

enum CommandLineValues {
  static func value(after option: String, in args: [String], at index: inout Int) throws -> String {
    guard index + 1 < args.count else { throw CommandLineError("\(option) needs a value") }
    index += 1
    return args[index]
  }

  static func template(after option: String, in args: [String], at index: inout Int) throws -> String {
    let value = try value(after: option, in: args, at: &index)
    guard value.contains(where: { !$0.isWhitespace }) else { throw CommandLineError("\(option) needs a nonblank template") }
    return value
  }

  static func kind(_ text: String) throws -> QuotaWindowKind {
    guard let kind = QuotaWindowKind(rawValue: text) else { throw CommandLineError("unknown window kind \"\(text)\"") }
    return kind
  }

  private static let durationUnits: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3_600, "d": 86_400]
  static func duration(_ text: String) -> TimeInterval? {
    var number = Substring(text)
    var scale: TimeInterval = 1
    if let last = text.last, let unit = durationUnits[last] { number = number.dropLast(); scale = unit }
    guard let value = Double(number), value.isFinite, value > 0 else { return nil }
    let seconds = value * scale
    return seconds.isFinite ? seconds : nil
  }
}
