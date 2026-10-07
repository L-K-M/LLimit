import Foundation
import QuotaCore

// Options and evaluation for the snapshot-only commands: `llimit status`,
// `llimit check` and `llimit pick`. They resolve accounts against the snapshot,
// never the settings file, so status bars and scripts polling them never open
// the credential store, and their output is credential-free by construction.

/// A command-line mistake, reported with a usage message.
public struct CommandLineError: LocalizedError, Equatable, Sendable {
  public let message: String

  public init(_ message: String) {
    self.message = message
  }

  public var errorDescription: String? { message }
}

// MARK: - Account targets

/// Resolves a command-line account reference against the snapshot: an exact
/// account id, then a provider id (every account of that provider), then a
/// unique account-id prefix, matching the `llimit accounts` shorthand.
public enum AccountTarget {
  public enum Resolution: Equatable, Sendable {
    /// Empty for a provider with no account in the snapshot.
    case matched(Set<String>)
    case ambiguous([String])
    case unknown
  }

  public static func resolve(_ target: String, in snapshot: QuotaSnapshot?) -> Resolution {
    let accounts = (snapshot?.providers.map { ($0.accountID, $0.provider) } ?? [])
      + (snapshot?.failures.map { ($0.accountID, $0.provider) } ?? [])

    if accounts.contains(where: { $0.0 == target }) {
      return .matched([target])
    }
    if let provider = QuotaProvider(rawValue: target) {
      return .matched(Set(accounts.filter { $0.1 == provider }.map(\.0)))
    }

    let prefixed = Set(accounts.map(\.0).filter { $0.hasPrefix(target) })
    switch prefixed.count {
    case 0:
      return .unknown
    case 1:
      return .matched(prefixed)
    default:
      return .ambiguous(prefixed.sorted())
    }
  }
}

// MARK: - status

public struct StatusOptions: Equatable, Sendable {
  public enum Output: Equatable, Sendable {
    case human
    case json
    case template(String)
  }

  public enum Selection: Equatable, Sendable {
    case all
    /// Only the account with the least headroom.
    case worst
  }

  public static let defaultWatchInterval: TimeInterval = 60

  public var output: Output = .human
  /// `--account` values; empty selects every account.
  public var accountTargets: [String] = []
  public var selection: Selection = .all
  /// Window kind for `{remaining}` and `--worst`; nil considers every limit.
  public var kind: QuotaWindowKind?
  public var separator = StatusTemplate.defaultSeparator
  /// Seconds between renders; nil renders once.
  public var watchInterval: TimeInterval?

  public init() {}

  public static func parse(_ args: [String]) throws -> StatusOptions {
    var options = StatusOptions()
    var wantsJSON = false
    var template: String?
    var separator: String?

    var index = 0
    while index < args.count {
      let arg = args[index]
      switch arg {
      case "--json":
        wantsJSON = true
      case "--format":
        template = try CommandLineValues.template(after: arg, in: args, at: &index)
      case "--account":
        options.accountTargets.append(try CommandLineValues.value(after: arg, in: args, at: &index))
      case "--worst":
        options.selection = .worst
      case "--kind":
        options.kind = try CommandLineValues.kind(try CommandLineValues.value(after: arg, in: args, at: &index))
      case "--separator":
        separator = try CommandLineValues.value(after: arg, in: args, at: &index)
      case "--watch":
        // The interval is optional; status takes no positional arguments, so a
        // following non-option argument can only be it.
        options.watchInterval = defaultWatchInterval
        if index + 1 < args.count, !args[index + 1].hasPrefix("-") {
          index += 1
          guard let seconds = CommandLineValues.duration(args[index]), seconds >= 1 else {
            throw CommandLineError("--watch expects an interval of at least 1 second (got \"\(args[index])\")")
          }
          options.watchInterval = seconds
        }
      default:
        throw CommandLineError("unknown status option: \(arg)")
      }
      index += 1
    }

    if wantsJSON && template != nil {
      throw CommandLineError("--json and --format cannot be combined")
    }
    if separator != nil && template == nil {
      throw CommandLineError("--separator needs --format")
    }
    if options.kind != nil && template == nil && options.selection != .worst {
      throw CommandLineError("--kind needs --format or --worst")
    }

    if let template {
      options.output = .template(template)
    } else if wantsJSON {
      options.output = .json
    }
    if let separator {
      options.separator = separator
    }
    return options
  }
}

public enum StatusCommand {
  public struct Rendering: Equatable, Sendable {
    public let text: String
    /// `--account` values that match nothing in the snapshot (for example an
    /// account that has not been refreshed yet, or a provider without
    /// accounts). They select nothing.
    public let unmatchedTargets: [String]
  }

  /// Without `--account` or `--worst` the snapshot reaches the renderers
  /// unchanged, so the default and `--json` output are exactly those of
  /// `StatusRenderer`. Throws for an ambiguous `--account` prefix.
  public static func render(_ options: StatusOptions, snapshot: QuotaSnapshot?, now: Date) throws -> Rendering {
    var selected = snapshot
    var unmatched: [String] = []

    if let snapshot, !options.accountTargets.isEmpty {
      var accountIDs: Set<String> = []
      for target in options.accountTargets {
        switch AccountTarget.resolve(target, in: snapshot) {
        case .matched(let ids) where ids.isEmpty:
          unmatched.append(target)
        case .matched(let ids):
          accountIDs.formUnion(ids)
        case .ambiguous(let ids):
          throw CommandLineError("\"\(target)\" matches several accounts: \(ids.joined(separator: ", "))")
        case .unknown:
          unmatched.append(target)
        }
      }
      selected = restricted(snapshot, to: accountIDs)
    }

    if options.selection == .worst, let current = selected {
      let ranking = HeadroomRanking.rank(
        snapshot: current,
        filter: HeadroomRanking.Filter(kind: options.kind, eligibility: .anyReported),
        now: now
      )
      selected = restricted(current, to: Set(ranking.worst.map { [$0.accountID] } ?? []))
    }

    let text: String
    switch options.output {
    case .human:
      text = StatusRenderer.humanReadable(snapshot: selected, now: now)
    case .json:
      text = StatusRenderer.waybarJSON(snapshot: selected, now: now)
    case .template(let template):
      text = StatusTemplate.render(template, snapshot: selected, kind: options.kind, separator: options.separator, now: now)
    }
    return Rendering(text: text, unmatchedTargets: unmatched)
  }

  /// The snapshot narrowed to some accounts; its timestamp is kept.
  static func restricted(_ snapshot: QuotaSnapshot, to accountIDs: Set<String>) -> QuotaSnapshot {
    QuotaSnapshot(
      version: snapshot.version,
      generatedAt: snapshot.generatedAt,
      providers: snapshot.providers.filter { accountIDs.contains($0.accountID) },
      failures: snapshot.failures.filter { accountIDs.contains($0.accountID) }
    )
  }
}

// MARK: - check and pick

/// Exit statuses of `llimit check` and `llimit pick`. Scripts branch on them, so
/// they are a contract: never renumber.
public enum QuotaCheckStatus: Int32, Sendable {
  case ok = 0
  case belowMinimum = 1
  case staleOrFailing = 2
  case noData = 3
  /// `EX_USAGE` from sysexits.h, so a typo is never read as a quota answer.
  case usage = 64
}

/// What `check` and `pick` require of an account.
public struct HeadroomCriteria: Equatable, Sendable {
  /// The default 1 means "not exhausted".
  public static let defaultMinimum = 1

  /// Lowest acceptable remaining percentage; unlimited quota always passes.
  public var minimum = HeadroomCriteria.defaultMinimum
  /// Older data counts as stale.
  public var maxAge = HeadroomRanking.defaultMaxAge
  /// Rank on this window kind only; nil uses every limit.
  public var kind: QuotaWindowKind?

  public init() {}

  /// Consumes one shared option at `index`. Returns false for any other argument.
  mutating func parseOption(_ args: [String], at index: inout Int) throws -> Bool {
    let arg = args[index]
    switch arg {
    case "--min":
      let text = try CommandLineValues.value(after: arg, in: args, at: &index)
      guard let percent = Int(text), (0...100).contains(percent) else {
        throw CommandLineError("--min expects a percentage from 0 to 100 (got \"\(text)\")")
      }
      minimum = percent
    case "--max-age":
      let text = try CommandLineValues.value(after: arg, in: args, at: &index)
      guard let seconds = CommandLineValues.duration(text) else {
        throw CommandLineError("--max-age expects a duration such as 90s, 30m, 2h or 1d (got \"\(text)\")")
      }
      maxAge = seconds
    case "--kind":
      kind = try CommandLineValues.kind(try CommandLineValues.value(after: arg, in: args, at: &index))
    default:
      return false
    }
    return true
  }
}

public struct CheckOptions: Equatable, Sendable {
  /// An account id, unique id prefix, or provider id.
  public var target: String
  public var criteria = HeadroomCriteria()

  public init(target: String) {
    self.target = target
  }

  public static func parse(_ args: [String]) throws -> CheckOptions {
    var target: String?
    var criteria = HeadroomCriteria()

    var index = 0
    while index < args.count {
      let arg = args[index]
      if try criteria.parseOption(args, at: &index) {
        index += 1
        continue
      }
      guard !arg.hasPrefix("-") else {
        throw CommandLineError("unknown check option: \(arg)")
      }
      guard target == nil else {
        throw CommandLineError("check takes one account or provider (got \"\(target ?? "")\" and \"\(arg)\")")
      }
      target = arg
      index += 1
    }

    guard let target else {
      throw CommandLineError("check needs an account id or provider")
    }
    var options = CheckOptions(target: target)
    options.criteria = criteria
    return options
  }
}

public struct PickOptions: Equatable, Sendable {
  /// nil considers every provider.
  public var providers: Set<QuotaProvider>?
  public var criteria = HeadroomCriteria()
  public var template = StatusTemplate.pickDefault

  public init() {}

  public static func parse(_ args: [String]) throws -> PickOptions {
    var options = PickOptions()

    var index = 0
    while index < args.count {
      let arg = args[index]
      if try options.criteria.parseOption(args, at: &index) {
        index += 1
        continue
      }
      switch arg {
      case "--provider":
        let list = try CommandLineValues.value(after: arg, in: args, at: &index)
        let ids = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !ids.isEmpty else {
          throw CommandLineError("--provider needs at least one provider id")
        }
        for id in ids {
          guard let provider = QuotaProvider(rawValue: id) else {
            throw CommandLineError("unknown provider \"\(id)\"; use one of: \(QuotaProvider.allCases.map(\.rawValue).joined(separator: ", "))")
          }
          options.providers = (options.providers ?? []).union([provider])
        }
      case "--format":
        options.template = try CommandLineValues.template(after: arg, in: args, at: &index)
      default:
        throw CommandLineError("unknown pick option: \(arg)")
      }
      index += 1
    }
    return options
  }
}

public struct QuotaVerdict: Equatable, Sendable {
  public let status: QuotaCheckStatus
  /// The account with the most headroom among the eligible ones, if any.
  public let candidate: HeadroomRanking.Candidate?
  /// One credential-free line explaining `status`.
  public let message: String
}

public enum QuotaCheck {
  private static let noSnapshotReason = "no snapshot yet; run `llimit refresh` or start the daemon"

  public static func check(_ options: CheckOptions, snapshot: QuotaSnapshot?, now: Date) -> QuotaVerdict {
    switch AccountTarget.resolve(options.target, in: snapshot) {
    case .matched(let accountIDs):
      return evaluate(
        snapshot: snapshot,
        filter: HeadroomRanking.Filter(accountIDs: accountIDs),
        criteria: options.criteria,
        subject: options.target,
        now: now
      )
    case .ambiguous(let ids):
      return QuotaVerdict(
        status: .usage,
        candidate: nil,
        message: "\"\(options.target)\" matches several accounts: \(ids.joined(separator: ", "))"
      )
    case .unknown:
      let reason = snapshot == nil
        ? noSnapshotReason
        : "no account or provider matches \"\(options.target)\" in the snapshot"
      return QuotaVerdict(status: .noData, candidate: nil, message: "no data: \(reason)")
    }
  }

  public static func pick(_ options: PickOptions, snapshot: QuotaSnapshot?, now: Date) -> QuotaVerdict {
    let subject = options.providers.map { $0.map(\.rawValue).sorted().joined(separator: ", ") } ?? "any account"
    return evaluate(
      snapshot: snapshot,
      filter: HeadroomRanking.Filter(providers: options.providers),
      criteria: options.criteria,
      subject: subject,
      now: now
    )
  }

  /// The best eligible account decides between ok and below minimum. Without
  /// one, a stale or failing match means refreshing may help (2); otherwise
  /// nothing reports quota at all (3).
  private static func evaluate(
    snapshot: QuotaSnapshot?,
    filter: HeadroomRanking.Filter,
    criteria: HeadroomCriteria,
    subject: String,
    now: Date
  ) -> QuotaVerdict {
    guard let snapshot else {
      return QuotaVerdict(status: .noData, candidate: nil, message: "no data: \(noSnapshotReason)")
    }

    var filter = filter
    filter.kind = criteria.kind
    filter.eligibility = .current(maxAge: criteria.maxAge)
    let ranking = HeadroomRanking.rank(snapshot: snapshot, filter: filter, now: now)

    if let best = ranking.best {
      if meets(best.headroom, minimum: criteria.minimum) {
        return QuotaVerdict(status: .ok, candidate: best, message: "ok: \(describe(best))")
      }
      return QuotaVerdict(
        status: .belowMinimum,
        candidate: best,
        message: "below minimum: \(describe(best)); minimum is \(criteria.minimum)%"
      )
    }

    let unusable = ranking.exclusions.compactMap { describe($0, now: now) }
    if !unusable.isEmpty {
      return QuotaVerdict(
        status: .staleOrFailing,
        candidate: nil,
        message: "stale or failing: \(unusable.joined(separator: "; "))"
      )
    }

    let window = criteria.kind.map { " for the \($0.rawValue) window" } ?? ""
    return QuotaVerdict(status: .noData, candidate: nil, message: "no data: no quota reported\(window) by \(subject)")
  }

  private static func meets(_ headroom: HeadroomRanking.Headroom, minimum: Int) -> Bool {
    switch headroom {
    case .unlimited:
      return true
    case .percent(let percent):
      return percent >= minimum
    }
  }

  private static func describe(_ candidate: HeadroomRanking.Candidate) -> String {
    let account = "\(candidate.usage.title) (\(candidate.usage.provider.rawValue))"
    let remaining = StatusTemplate.remainingText(candidate)
    let amount = candidate.headroom == .unlimited ? "unlimited quota" : "\(remaining) left"
    return "\(account) has \(amount) (\(candidate.limitingMetric.label))"
  }

  /// Nil for accounts without quota data: they explain exit 3, not exit 2.
  private static func describe(_ exclusion: HeadroomRanking.Exclusion, now: Date) -> String? {
    let account = "\(exclusion.name) (\(exclusion.provider.rawValue))"
    switch exclusion.reason {
    case .failing(let kind):
      return "\(account) failed to refresh (\(kind.rawValue))"
    case .stale(let fetchedAt):
      return "\(account) was last updated \(StatusRenderer.relativeAge(fetchedAt, now: now))"
    case .noQuotaData:
      return nil
    }
  }
}

// MARK: - Values

enum CommandLineValues {
  static func value(after option: String, in args: [String], at index: inout Int) throws -> String {
    guard index + 1 < args.count else {
      throw CommandLineError("\(option) needs a value")
    }
    index += 1
    return args[index]
  }

  /// An empty template would print blank lines that look like success.
  static func template(after option: String, in args: [String], at index: inout Int) throws -> String {
    let template = try value(after: option, in: args, at: &index)
    guard !template.isEmpty else {
      throw CommandLineError("\(option) needs a non-empty template")
    }
    return template
  }

  static func kind(_ text: String) throws -> QuotaWindowKind {
    guard let kind = QuotaWindowKind(rawValue: text) else {
      throw CommandLineError("unknown window kind \"\(text)\"; use one of: \(QuotaWindowKind.allCases.map(\.rawValue).joined(separator: ", "))")
    }
    return kind
  }

  private static let durationUnits: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3_600, "d": 86_400]

  /// `90`, `90s`, `30m`, `2h` or `1d`; a bare number is seconds. Nil unless positive.
  static func duration(_ text: String) -> TimeInterval? {
    var number = Substring(text)
    var scale: TimeInterval = 1
    if let last = text.last, let unit = durationUnits[last] {
      number = number.dropLast()
      scale = unit
    }
    guard let value = Double(number), value.isFinite, value > 0 else { return nil }
    return value * scale
  }
}
