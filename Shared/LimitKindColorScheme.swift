import SwiftUI
import QuotaCore

/// Resolves quota metrics to their identity colors. Color encodes exactly one
/// thing everywhere in LLimit: WHICH limit a mark belongs to (its reset-window
/// kind). How much is left is carried by geometry (arc length, bar length,
/// line height), and danger states by the reserved status accents — never by
/// repainting an identity hue.
enum LimitKindColorScheme {
  struct SeriesSlot: Hashable {
    let kind: QuotaWindowKind
    let otherSlot: Int
  }

  /// Stable slot per metric within one account: classified kinds map directly;
  /// `.other` metrics take auxiliary slots in metric order, so e.g. Google's
  /// per-model quotas stay distinct and keep their color between refreshes.
  static func slots(for metrics: [UsageMetric]) -> [SeriesSlot] {
    var otherCount = 0
    return metrics.map { metric in
      let kind = QuotaWindowKind.classify(metricID: metric.id, label: metric.label)
      guard kind == .other else {
        return SeriesSlot(kind: kind, otherSlot: 0)
      }
      defer { otherCount += 1 }
      return SeriesSlot(kind: .other, otherSlot: otherCount)
    }
  }

  static func slot(forMetricAt index: Int, in metrics: [UsageMetric]) -> SeriesSlot {
    let allSlots = slots(for: metrics)
    guard index >= 0, index < allSlots.count else {
      return SeriesSlot(kind: .other, otherSlot: 0)
    }
    return allSlots[index]
  }

  static func color(for slot: SeriesSlot, colors: LimitKindColors) -> Color {
    color(hex: colors.hexColor(for: slot.kind, otherSlot: slot.otherSlot)) ?? .white
  }

  /// Identity color for one metric of an account. Unlimited metrics share a
  /// single reserved tint — there is nothing to tell apart about "no limit".
  static func color(forMetricAt index: Int, in metrics: [UsageMetric], colors: LimitKindColors) -> Color {
    if index >= 0, index < metrics.count, metrics[index].isUnlimited {
      return color(hex: colors.unlimitedHexColor) ?? .white
    }
    return color(for: slot(forMetricAt: index, in: metrics), colors: colors)
  }

  /// Account-level accent: the identity color of the account's most
  /// constrained bounded metric, i.e. the limit that currently matters most.
  static func accountAccent(for metrics: [UsageMetric], colors: LimitKindColors) -> Color {
    let bounded = metrics.enumerated().filter { !$0.element.isUnlimited && $0.element.remainingPercent != nil }
    if let worst = bounded.min(by: {
      ($0.element.remainingPercent ?? Int.max) < ($1.element.remainingPercent ?? Int.max)
    }) {
      return color(forMetricAt: worst.offset, in: metrics, colors: colors)
    }

    if metrics.contains(where: \.isUnlimited) {
      return color(hex: colors.unlimitedHexColor) ?? .white
    }

    return Color.white.opacity(0.55)
  }

  /// Chart series sharing a hue (two accounts with a weekly limit, Claude's
  /// two weeklies) get successive brightness steps; callers pair step >= 1
  /// with a dash pattern so the difference never rides on lightness alone.
  static func steppedColor(hex: String?, step: Int) -> Color? {
    guard let base = rgbaComponents(hex: hex) else {
      return nil
    }

    let blended: (red: Double, green: Double, blue: Double, alpha: Double)
    switch step {
    case ..<1:
      blended = base
    case 1:
      blended = blend(base, target: (1, 1, 1), fraction: 0.38)
    case 2:
      blended = blend(base, target: (0.02, 0.03, 0.06), fraction: 0.28)
    default:
      blended = blend(base, target: (1, 1, 1), fraction: 0.62)
    }
    return Color(red: blended.red, green: blended.green, blue: blended.blue, opacity: blended.alpha)
  }

  static func color(hex: String?) -> Color? {
    guard let components = rgbaComponents(hex: hex) else {
      return nil
    }
    return Color(red: components.red, green: components.green, blue: components.blue, opacity: components.alpha)
  }

  // MARK: - Private

  private static func blend(
    _ base: (red: Double, green: Double, blue: Double, alpha: Double),
    target: (red: Double, green: Double, blue: Double),
    fraction: Double
  ) -> (red: Double, green: Double, blue: Double, alpha: Double) {
    let mix = max(0, min(1, fraction))
    return (
      base.red * (1 - mix) + target.red * mix,
      base.green * (1 - mix) + target.green * mix,
      base.blue * (1 - mix) + target.blue * mix,
      base.alpha
    )
  }

  private static func rgbaComponents(hex: String?) -> (red: Double, green: Double, blue: Double, alpha: Double)? {
    guard var raw = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      return nil
    }

    if raw.hasPrefix("#") {
      raw.removeFirst()
    }

    if raw.count == 3 || raw.count == 4 {
      raw = raw.map { "\($0)\($0)" }.joined()
    }

    guard (raw.count == 6 || raw.count == 8), let parsed = UInt64(raw, radix: 16) else {
      return nil
    }

    if raw.count == 6 {
      return (
        Double((parsed >> 16) & 0xFF) / 255.0,
        Double((parsed >> 8) & 0xFF) / 255.0,
        Double(parsed & 0xFF) / 255.0,
        1
      )
    }

    return (
      Double((parsed >> 24) & 0xFF) / 255.0,
      Double((parsed >> 16) & 0xFF) / 255.0,
      Double((parsed >> 8) & 0xFF) / 255.0,
      Double(parsed & 0xFF) / 255.0
    )
  }
}
