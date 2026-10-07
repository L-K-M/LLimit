import Foundation

/// User-facing thresholds for quota alerts. Persisted inside `AppSettings` so
/// both platforms share the same "when to warn" policy; delivery itself is
/// platform-specific (UNUserNotificationCenter on macOS, `llimit check` +
/// notify-send on Linux).
public struct QuotaAlertSettings: Codable, Hashable, Sendable {
  public static let warningRange = 5...90
  public static let criticalRange = 1...50

  public var enabled: Bool
  /// Fire "running low" when a metric's remaining percent drops to this.
  public var warningPercent: Int
  /// Fire "almost out" when a metric drops to this. Kept below warningPercent.
  public var criticalPercent: Int
  /// Notify when an account's fetch starts failing (stale data risk).
  public var notifyOnFailure: Bool

  public init(enabled: Bool = false, warningPercent: Int = 25,
              criticalPercent: Int = 10, notifyOnFailure: Bool = true) {
    self.enabled = enabled
    self.warningPercent = min(max(warningPercent, Self.warningRange.lowerBound),
                              Self.warningRange.upperBound)
    self.criticalPercent = min(max(criticalPercent, Self.criticalRange.lowerBound),
                               Self.criticalRange.upperBound)
    // Defense in depth: a critical at/above warning would swallow every
    // warning alert — the evaluator checks critical first.
    if self.criticalPercent >= self.warningPercent {
      self.criticalPercent = max(Self.criticalRange.lowerBound, self.warningPercent - 1)
    }
    self.notifyOnFailure = notifyOnFailure
  }

  private enum CodingKeys: String, CodingKey {
    case enabled, warningPercent, criticalPercent, notifyOnFailure
  }

  /// Route decoding through the validating init so persisted values are
  /// clamped into range and critical stays below warning even if the
  /// settings file was edited by hand.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
      warningPercent: try container.decodeIfPresent(Int.self, forKey: .warningPercent) ?? 25,
      criticalPercent: try container.decodeIfPresent(Int.self, forKey: .criticalPercent) ?? 10,
      notifyOnFailure: try container.decodeIfPresent(Bool.self, forKey: .notifyOnFailure) ?? true)
  }
}

public struct QuotaAlert: Equatable, Sendable {
  public enum Severity: String, Equatable, Sendable {
    case warning, critical, failure
  }

  /// Stable per (account, metric, band) — doubles as the notification
  /// identifier so re-delivery replaces instead of stacking.
  public let dedupKey: String
  public let severity: Severity
  /// Notification title, e.g. "Claude — 5-hour limit".
  public let title: String
  /// Notification body, e.g. "8% remaining — resets in 2h".
  public let body: String

  public init(dedupKey: String, severity: Severity, title: String, body: String) {
    self.dedupKey = dedupKey
    self.severity = severity
    self.title = title
    self.body = body
  }
}

/// Turns each published snapshot into the alerts that should fire *now*.
///
/// `dedupedKeys` is caller-persisted state holding the dedup keys currently
/// suppressed. A metric alerts once per band it enters (critical implies and
/// suppresses warning), and re-arms only when it climbs past the warning
/// threshold plus `rearmHysteresisPercent` — oscillating values can't
/// re-fire every refresh. Failure keys re-arm when that kind disappears.
public enum QuotaAlertEvaluator {
  /// Points above the warning band a suppressed metric must recover before it
  /// can alert again — kills flapping for values oscillating at a threshold.
  static let rearmHysteresisPercent = 5

  public static func alerts(
    in snapshot: QuotaSnapshot,
    settings: QuotaAlertSettings,
    dedupedKeys: inout Set<String>,
    now: Date = Date()
  ) -> [QuotaAlert] {
    guard settings.enabled else {
      dedupedKeys.removeAll()
      return []
    }

    var fired: [QuotaAlert] = []
    var liveMetricKeys: Set<String> = []

    // A suppressed metric stays suppressed until it clears the warning band
    // plus this margin — an oscillating value can't re-fire every refresh.
    let margin = Self.rearmHysteresisPercent

    for usage in snapshot.providers {
      for metric in usage.metrics {
        guard let remaining = metric.remainingPercent else { continue }
        let prefix = "quota:\(usage.accountID):\(metric.id):"
        let warningKey = prefix + QuotaAlert.Severity.warning.rawValue
        let criticalKey = prefix + QuotaAlert.Severity.critical.rawValue

        if remaining <= settings.criticalPercent {
          if !dedupedKeys.contains(criticalKey) {
            fired.append(QuotaAlert(
              dedupKey: criticalKey, severity: .critical,
              title: "\(usage.title) — \(metric.label)",
              body: body(remaining: remaining, metric: metric, now: now)
            ))
          }
          // Critical implies warning — suppress a later warning re-fire.
          dedupedKeys.formUnion([criticalKey, warningKey])
          liveMetricKeys.formUnion([criticalKey, warningKey])
        } else if remaining <= settings.warningPercent + margin {
          // In the band: fire/suppress warning. In the margin above it: no
          // firing, but the metric stays live so suppression isn't re-armed
          // until remaining clears warningPercent + margin.
          if remaining <= settings.warningPercent,
             !dedupedKeys.contains(warningKey) {
            fired.append(QuotaAlert(
              dedupKey: warningKey, severity: .warning,
              title: "\(usage.title) — \(metric.label)",
              body: body(remaining: remaining, metric: metric, now: now)
            ))
          }
          if remaining <= settings.warningPercent {
            dedupedKeys.insert(warningKey)
          }
          liveMetricKeys.formUnion([criticalKey, warningKey])
        }
        // Above warning + margin → neither key is live; the intersect below
        // re-arms the metric so a later dip alerts again.
      }
    }

    let liveFailureKeys: Set<String>
    if settings.notifyOnFailure {
      var keys: Set<String> = []
      for failure in snapshot.failures {
        let key = "failure:\(failure.accountID):\(failure.kind.rawValue)"
        keys.insert(key)
        if !dedupedKeys.contains(key) {
          fired.append(QuotaAlert(
            dedupKey: key, severity: .failure,
            title: "\(failure.provider.displayName) refresh failed",
            body: failure.message
          ))
        }
      }
      liveFailureKeys = keys
    } else {
      liveFailureKeys = []
    }

    // Re-arm anything that recovered, then suppress what fired this cycle.
    dedupedKeys = dedupedKeys.intersection(liveMetricKeys.union(liveFailureKeys))
    for alert in fired { dedupedKeys.insert(alert.dedupKey) }
    return fired
  }

  private static func body(remaining: Int, metric: UsageMetric, now: Date) -> String {
    var text = "\(metric.isPercentageEstimated ? "≈" : "")\(remaining)% remaining"
    if let resetAt = metric.resetAt {
      let countdown = formatResetCountdown(to: resetAt, now: now)
      if !countdown.isEmpty {
        text += " — resets \(countdown)"
      }
    }
    return text
  }
}
