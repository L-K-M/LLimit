import Foundation

/// macOS preferences for the shared event policy. Keep encoded keys compatible
/// with existing settings; platform delivery remains opt-in.
public struct QuotaAlertSettings: Codable, Hashable, Sendable {
  public static let warningRange = 5...90
  public static let criticalRange = 1...50

  public var enabled: Bool
  public var warningPercent: Int
  public var criticalPercent: Int
  public var notifyOnFailure: Bool

  public init(enabled: Bool = false, warningPercent: Int = QuotaEventConfig.defaultThresholds[0],
              criticalPercent: Int = QuotaEventConfig.defaultThresholds[1], notifyOnFailure: Bool = true) {
    self.enabled = enabled
    self.warningPercent = min(max(warningPercent, Self.warningRange.lowerBound), Self.warningRange.upperBound)
    self.criticalPercent = min(max(criticalPercent, Self.criticalRange.lowerBound), Self.criticalRange.upperBound)
    if self.criticalPercent >= self.warningPercent {
      self.criticalPercent = self.warningPercent - 1
    }
    self.notifyOnFailure = notifyOnFailure
  }

  public enum ThresholdBand: Sendable { case warning, critical }

  /// Preserve the edited band, moving its counterpart when needed.
  public mutating func setThreshold(_ percent: Int, for band: ThresholdBand) {
    switch band {
    case .warning:
      warningPercent = min(max(percent, Self.warningRange.lowerBound), Self.warningRange.upperBound)
      criticalPercent = min(criticalPercent, warningPercent - 1)
    case .critical:
      criticalPercent = min(max(percent, Self.criticalRange.lowerBound), Self.criticalRange.upperBound)
      warningPercent = max(warningPercent, criticalPercent + 1)
    }
    self = Self(enabled: enabled, warningPercent: warningPercent,
                criticalPercent: criticalPercent, notifyOnFailure: notifyOnFailure)
  }

  public var eventConfig: QuotaEventConfig {
    let validated = Self(enabled: enabled, warningPercent: warningPercent,
                         criticalPercent: criticalPercent, notifyOnFailure: notifyOnFailure)
    var config = QuotaEventConfig(thresholds: [validated.warningPercent, validated.criticalPercent])
    if !notifyOnFailure { config.failureKinds = [] }
    return config
  }

  private enum CodingKeys: String, CodingKey {
    case enabled, warningPercent, criticalPercent, notifyOnFailure
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
      warningPercent: try container.decodeIfPresent(Int.self, forKey: .warningPercent) ?? QuotaEventConfig.defaultThresholds[0],
      criticalPercent: try container.decodeIfPresent(Int.self, forKey: .criticalPercent) ?? QuotaEventConfig.defaultThresholds[1],
      notifyOnFailure: try container.decodeIfPresent(Bool.self, forKey: .notifyOnFailure) ?? true)
  }
}
