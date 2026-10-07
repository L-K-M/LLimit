import Foundation

/// What changed about an account's quota between two snapshots. The raw values
/// are the `LLIMIT_EVENT` names hook scripts match on: never rename one.
public enum QuotaEventKind: String, Codable, CaseIterable, Sendable {
  /// Remaining quota fell to or below a configured threshold.
  case threshold
  /// A window that had reached an alert threshold ended and its quota came back.
  case reset
  /// An account started failing in a way that needs the user (sign-in, an
  /// unreadable usage response). Transient network and rate-limit errors do not
  /// count.
  case failure
  /// A previously reported failure cleared: the account refreshed successfully.
  case recovered
  /// A weekly or monthly window is about to reset with most of it unused.
  case expiringUnused
}

public enum QuotaEventSeverity: String, Codable, Sendable {
  case normal
  case critical
}

/// One alert-worthy change. Built only from snapshot data that display surfaces
/// already show (account name, metric label, percentages, reset times, the
/// failure kind), so it never carries provider error text or credentials.
public struct QuotaEvent: Hashable, Sendable {
  public var kind: QuotaEventKind
  public var severity: QuotaEventSeverity
  public var accountID: String
  public var accountName: String
  public var provider: QuotaProvider
  public var metricID: String?
  public var metricLabel: String?
  public var remainingPercent: Int?
  public var isEstimated: Bool = false
  /// The threshold that was crossed, for `threshold` events.
  public var threshold: Int?
  /// When the metric's current window resets, when the provider reports it.
  public var resetAt: Date?
  /// The failure that appeared (`failure`) or cleared (`recovered`).
  public var failureKind: QuotaErrorKind?
}

public struct QuotaEventConfig: Hashable, Sendable {
  public static let defaultThresholds = [20, 5]
  public static let validThresholds = 1...99

  /// Remaining percentages that raise a `threshold` event when quota falls to or
  /// below them, highest first. Also bounds `reset` events: a window has to have
  /// reached the highest threshold for its reset to be worth an alert, otherwise
  /// every routine five-hour turnover would notify.
  public let thresholds: [Int]
  /// How many points remaining must climb above a threshold before it can fire
  /// again in the same window, and the smallest rise that counts as a reset.
  /// Absorbs rounding jitter in providers' used percentages.
  public var hysteresis = 5
  /// Failure kinds that need the user. Network and rate-limit errors are
  /// transient and clear on their own.
  public var failureKinds: Set<QuotaErrorKind> = [.auth, .decoding]
  /// Window kinds whose leftover quota is lost at reset on flat-rate plans.
  public var expiringUnusedKinds: Set<QuotaWindowKind> = [.weekly, .monthly]
  /// How close to its reset a window has to be for `expiringUnused`.
  public var expiringUnusedLeadTime: TimeInterval = 24 * 60 * 60
  /// The remaining percentage at or above which a closing window counts as
  /// mostly unused.
  public var expiringUnusedMinimumRemaining = 50

  /// Values outside `validThresholds` are dropped and duplicates collapse, so
  /// `thresholds` is always sorted highest first. If nothing survives, no
  /// `threshold` or `reset` event is ever produced: callers taking thresholds
  /// from users must reject such input instead (`llimit daemon --thresholds`
  /// does).
  public init(thresholds: [Int] = QuotaEventConfig.defaultThresholds) {
    self.thresholds = Array(Set(thresholds.filter { Self.validThresholds.contains($0) })).sorted(by: >)
  }

  public static let `default` = QuotaEventConfig()
}

/// What the detector has already announced, so each alert fires once instead of
/// every refresh. Persisted between daemon runs. Holds only account IDs, metric
/// IDs, thresholds, reset times and failure kinds: no credentials.
public struct QuotaEventState: Codable, Hashable, Sendable {
  struct ThresholdLatch: Codable, Hashable, Sendable {
    var accountID: String
    var metricID: String
    var threshold: Int
    /// The window the alert fired in. Its end re-arms the threshold.
    var resetAt: Date?
  }

  struct WindowMark: Codable, Hashable, Sendable {
    var accountID: String
    var metricID: String
    var resetAt: Date
  }

  struct ResetMark: Codable, Hashable, Sendable {
    var accountID: String
    var metricID: String
    /// The low window whose end was announced.
    var endedAt: Date
    /// When the window that reset opened ends, if the provider said.
    var nextResetAt: Date?
  }

  struct FailureLatch: Codable, Hashable, Sendable {
    var accountID: String
    var kind: QuotaErrorKind
  }

  var thresholdLatches: [ThresholdLatch] = []
  /// The window change each metric last announced a `reset` for.
  var resetMarks: [ResetMark] = []
  /// The window each metric last announced `expiringUnused` for.
  var expiringUnusedMarks: [WindowMark] = []
  var failureLatches: [FailureLatch] = []

  public init() {}

  private enum CodingKeys: String, CodingKey {
    case thresholdLatches
    case resetMarks
    case expiringUnusedMarks
    case failureLatches
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    thresholdLatches = try container.decodeIfPresent([ThresholdLatch].self, forKey: .thresholdLatches) ?? []
    resetMarks = try container.decodeIfPresent([ResetMark].self, forKey: .resetMarks) ?? []
    expiringUnusedMarks = try container.decodeIfPresent([WindowMark].self, forKey: .expiringUnusedMarks) ?? []
    failureLatches = try container.decodeIfPresent([FailureLatch].self, forKey: .failureLatches) ?? []
  }

  /// Forgets accounts that are no longer in the snapshot (removed or disabled),
  /// so re-adding one starts fresh.
  mutating func keepAccounts(_ accountIDs: Set<String>) {
    thresholdLatches.removeAll { !accountIDs.contains($0.accountID) }
    resetMarks.removeAll { !accountIDs.contains($0.accountID) }
    expiringUnusedMarks.removeAll { !accountIDs.contains($0.accountID) }
    failureLatches.removeAll { !accountIDs.contains($0.accountID) }
  }

  /// Forgets metrics a freshly refreshed account no longer reports.
  mutating func keepMetrics(_ metricIDs: Set<String>, of accountID: String) {
    func isGone(_ entryAccountID: String, _ entryMetricID: String) -> Bool {
      entryAccountID == accountID && !metricIDs.contains(entryMetricID)
    }
    thresholdLatches.removeAll { isGone($0.accountID, $0.metricID) }
    resetMarks.removeAll { isGone($0.accountID, $0.metricID) }
    expiringUnusedMarks.removeAll { isGone($0.accountID, $0.metricID) }
  }
}

public struct QuotaEventDetection: Hashable, Sendable {
  public var events: [QuotaEvent]
  /// The state to persist and pass to the next `detect` call.
  public var state: QuotaEventState
}

/// Turns consecutive snapshots into alert events. Pure: the caller owns the
/// clock, the persisted state and delivery, so the Linux daemon and the macOS
/// app can share the rules.
///
/// Conditions are level-triggered and latched: an alert fires the first time
/// its condition holds (including on the first run, so a token that expired
/// while nothing was watching is still reported once) and not again until the
/// condition clears or the window ends.
public enum QuotaEvents {
  /// Reset times jitter between fetches when a provider reports a relative
  /// "resets in" value. Two reset times this close describe the same window.
  static let windowMatchTolerance: TimeInterval = 60 * 60

  /// `accountNames` (account ID to display name) names accounts that have only
  /// failed so far: a snapshot failure carries no title of its own.
  public static func detect(
    previous: QuotaSnapshot?,
    current: QuotaSnapshot,
    now: Date,
    config: QuotaEventConfig = .default,
    state: QuotaEventState,
    accountNames: [String: String] = [:]
  ) -> QuotaEventDetection {
    var next = state
    let failingIDs = Set(current.failures.map(\.accountID))
    // Like metrics below: an account missing from one snapshot keeps its
    // alerts; absent from both (removed or disabled), it is forgotten.
    let previousAccountIDs = (previous?.providers.map(\.accountID) ?? []) + (previous?.failures.map(\.accountID) ?? [])
    next.keepAccounts(Set(current.providers.map(\.accountID)).union(failingIDs).union(previousAccountIDs))

    var events = detectFailures(in: current, failingIDs: failingIDs, accountNames: accountNames, config: config, state: &next)

    let previousUsage = Dictionary(
      (previous?.providers ?? []).map { ($0.accountID, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    // A failing account's usage is carried over from an earlier refresh, so it
    // says nothing new: its alerts neither fire nor re-arm until it refreshes.
    for usage in current.providers where !failingIDs.contains(usage.accountID) {
      let previousMetrics = Dictionary(
        (previousUsage[usage.accountID]?.metrics ?? []).map { ($0.id, $0) },
        uniquingKeysWith: { first, _ in first }
      )
      // A metric a provider leaves out of one response keeps its alerts, so it
      // does not alert again when it comes back. Absent twice, it is forgotten.
      next.keepMetrics(Set(usage.metrics.map(\.id)).union(previousMetrics.keys), of: usage.accountID)

      for metric in usage.metrics where !metric.isUnlimited {
        guard let remaining = metric.remainingPercent else { continue }
        let reading = Reading(usage: usage, metric: metric, remaining: remaining)

        if let event = detectReset(reading, previous: previousMetrics[metric.id], now: now, config: config, state: &next) {
          events.append(event)
        }
        if let event = detectThreshold(reading, now: now, config: config, state: &next) {
          events.append(event)
        }
        if let event = detectExpiringUnused(reading, now: now, config: config, state: &next) {
          events.append(event)
        }
      }
    }

    return QuotaEventDetection(events: events, state: next)
  }

  private struct Reading {
    var usage: ProviderUsage
    var metric: UsageMetric
    var remaining: Int

    func event(_ kind: QuotaEventKind, severity: QuotaEventSeverity) -> QuotaEvent {
      QuotaEvent(
        kind: kind,
        severity: severity,
        accountID: usage.accountID,
        accountName: usage.title,
        provider: usage.provider,
        metricID: metric.id,
        metricLabel: metric.label,
        remainingPercent: remaining,
        isEstimated: metric.isPercentageEstimated,
        resetAt: metric.resetAt
      )
    }

    func isSame(accountID: String, metricID: String) -> Bool {
      accountID == usage.accountID && metricID == metric.id
    }
  }

  private static func detectFailures(
    in current: QuotaSnapshot,
    failingIDs: Set<String>,
    accountNames: [String: String],
    config: QuotaEventConfig,
    state: inout QuotaEventState
  ) -> [QuotaEvent] {
    var events: [QuotaEvent] = []

    for failure in current.failures where config.failureKinds.contains(failure.kind) {
      if let index = state.failureLatches.firstIndex(where: { $0.accountID == failure.accountID }) {
        // Still down: keep the latest reason, so `recovered` names what cleared.
        state.failureLatches[index].kind = failure.kind
        continue
      }

      state.failureLatches.append(.init(accountID: failure.accountID, kind: failure.kind))
      events.append(QuotaEvent(
        kind: .failure,
        severity: .critical,
        accountID: failure.accountID,
        accountName: accountNames[failure.accountID]
          ?? current.providers.first { $0.accountID == failure.accountID }?.title
          ?? failure.provider.displayName,
        provider: failure.provider,
        failureKind: failure.kind
      ))
    }

    // Only a clean refresh clears a failure. An auth failure that turns into a
    // network error has not been fixed, so its latch stays.
    for usage in current.providers where !failingIDs.contains(usage.accountID) {
      guard let index = state.failureLatches.firstIndex(where: { $0.accountID == usage.accountID }) else { continue }

      let latch = state.failureLatches.remove(at: index)
      events.append(QuotaEvent(
        kind: .recovered,
        severity: .normal,
        accountID: usage.accountID,
        accountName: usage.title,
        provider: usage.provider,
        failureKind: latch.kind
      ))
    }

    return events
  }

  /// Fires when a window that had reached the highest threshold ended and its
  /// quota came back: the previous reading's reset time has passed by the time
  /// of this fetch and remaining rose by at least the hysteresis. Fires once
  /// per ended window, and not again while the window the reset opened is
  /// still running (when the provider reports when it ends), even if a
  /// provider glitch makes it look like it ended.
  private static func detectReset(
    _ reading: Reading,
    previous: UsageMetric?,
    now: Date,
    config: QuotaEventConfig,
    state: inout QuotaEventState
  ) -> QuotaEvent? {
    guard
      let previous,
      !previous.isUnlimited,
      let endedAt = previous.resetAt,
      let previousRemaining = previous.remainingPercent,
      let ceiling = config.thresholds.first,
      previousRemaining <= ceiling,
      reading.usage.fetchedAt >= endedAt,
      reading.remaining >= previousRemaining + config.hysteresis
    else { return nil }

    let alreadyAnnounced = state.resetMarks.contains { mark in
      guard reading.isSame(accountID: mark.accountID, metricID: mark.metricID) else { return false }
      let openedWindowRunning = mark.nextResetAt.map { $0 > now } ?? false
      return openedWindowRunning || isSameWindow(mark.endedAt, endedAt)
    }
    guard !alreadyAnnounced else { return nil }

    state.resetMarks.removeAll { reading.isSame(accountID: $0.accountID, metricID: $0.metricID) }
    state.resetMarks.append(.init(
      accountID: reading.usage.accountID,
      metricID: reading.metric.id,
      endedAt: endedAt,
      nextResetAt: reading.metric.resetAt
    ))
    return reading.event(.reset, severity: .normal)
  }

  /// Fires once for the lowest newly crossed threshold, so a drop straight from
  /// 50% to 3% raises one critical alert rather than two. Every crossed
  /// threshold latches until remaining recovers past it by the hysteresis or
  /// the window it fired in ends.
  private static func detectThreshold(
    _ reading: Reading,
    now: Date,
    config: QuotaEventConfig,
    state: inout QuotaEventState
  ) -> QuotaEvent? {
    state.thresholdLatches.removeAll { latch in
      guard reading.isSame(accountID: latch.accountID, metricID: latch.metricID) else { return false }
      let recovered = reading.remaining > latch.threshold + config.hysteresis
      let windowEnded = latch.resetAt.map { now >= $0 } ?? false
      return recovered || windowEnded
    }

    // A reading whose window already ended describes nothing current.
    if let resetAt = reading.metric.resetAt, resetAt <= now {
      return nil
    }

    let newlyCrossed = config.thresholds.filter { threshold in
      reading.remaining <= threshold && !state.thresholdLatches.contains {
        reading.isSame(accountID: $0.accountID, metricID: $0.metricID) && $0.threshold == threshold
      }
    }
    guard let crossed = newlyCrossed.last else { return nil }

    for threshold in newlyCrossed {
      state.thresholdLatches.append(.init(
        accountID: reading.usage.accountID,
        metricID: reading.metric.id,
        threshold: threshold,
        resetAt: reading.metric.resetAt
      ))
    }

    var event = reading.event(.threshold, severity: crossed == config.thresholds.last ? .critical : .normal)
    event.threshold = crossed
    return event
  }

  /// Fires once per window when a weekly or monthly window is within the lead
  /// time of its reset with at least the minimum still unused. A mark whose
  /// reset is still ahead belongs to the window in progress (a metric has one
  /// at a time), so a provider moving that window's reset does not repeat it.
  private static func detectExpiringUnused(
    _ reading: Reading,
    now: Date,
    config: QuotaEventConfig,
    state: inout QuotaEventState
  ) -> QuotaEvent? {
    let kind = QuotaWindowKind.classify(metricID: reading.metric.id, label: reading.metric.label)
    guard
      config.expiringUnusedKinds.contains(kind),
      let resetAt = reading.metric.resetAt,
      reading.remaining >= config.expiringUnusedMinimumRemaining
    else { return nil }

    let timeLeft = resetAt.timeIntervalSince(now)
    guard timeLeft > 0, timeLeft <= config.expiringUnusedLeadTime else { return nil }

    let alreadyAnnounced = state.expiringUnusedMarks.contains {
      reading.isSame(accountID: $0.accountID, metricID: $0.metricID)
        && ($0.resetAt > now || isSameWindow($0.resetAt, resetAt))
    }
    guard !alreadyAnnounced else { return nil }

    state.expiringUnusedMarks.removeAll { reading.isSame(accountID: $0.accountID, metricID: $0.metricID) }
    state.expiringUnusedMarks.append(.init(accountID: reading.usage.accountID, metricID: reading.metric.id, resetAt: resetAt))
    return reading.event(.expiringUnused, severity: .normal)
  }

  private static func isSameWindow(_ lhs: Date, _ rhs: Date) -> Bool {
    abs(lhs.timeIntervalSince(rhs)) < windowMatchTolerance
  }
}

// MARK: - Notification copy

public extension QuotaEvent {
  /// A one-line headline, e.g. "Claude: Weekly limit mostly unused".
  var title: String {
    let metric = metricLabel ?? metricID ?? "Quota"
    switch kind {
    case .threshold:
      return "\(accountName): \(metric) low"
    case .reset:
      return "\(accountName): \(metric) reset"
    case .failure:
      switch failureKind {
      case .auth:
        return "\(accountName): sign-in needed"
      case .decoding:
        return "\(accountName): usage unreadable"
      default:
        return "\(accountName): refresh failing"
      }
    case .recovered:
      return "\(accountName): refreshing again"
    case .expiringUnused:
      return "\(accountName): \(metric) mostly unused"
    }
  }

  /// The notification text, e.g. "62% unused, resets in 9h." Estimated
  /// percentages keep their "≈" marker and say so.
  func body(now: Date) -> String {
    let percent = remainingPercent.map { "\(isEstimated ? "≈" : "")\($0)%" } ?? "?"
    let estimate = isEstimated ? " (estimated)" : ""
    let resets = resetAt.flatMap { $0 > now ? ", resets in \(formatResetCountdown(to: $0, now: now))" : nil } ?? ""

    switch kind {
    case .threshold:
      return "\(percent) left\(estimate)\(resets)."
    case .reset:
      return "\(percent) left again\(estimate)\(resets)."
    case .failure:
      switch failureKind {
      case .auth:
        return "Authentication failed. Reconnect or replace this account's credentials."
      case .decoding:
        return "The provider's usage response could not be read. The last good data stays visible."
      default:
        return "Refreshing this account failed."
      }
    case .recovered:
      return "Usage is updating again."
    case .expiringUnused:
      return "\(percent) unused\(estimate)\(resets)."
    }
  }
}
