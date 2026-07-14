import Foundation

public func defaultRingMetrics(for usage: ProviderUsage) -> [UsageMetric] {
  let candidates = usage.metrics.filter { $0.remainingPercent != nil || $0.isUnlimited }
  guard !candidates.isEmpty else { return [] }

  let preferredIDs: [String]
  switch usage.provider {
  case .anthropic:
    preferredIDs = ["five_hour", "seven_day"]
  case .openAI:
    preferredIDs = ["primary", "secondary"]
  case .zhipu, .zai:
    preferredIDs = ["tokens", "mcp"]
  case .gitHubCopilot:
    preferredIDs = ["premium", "chat", "completions"]
  case .googleAntigravity:
    preferredIDs = ["gemini-3-pro-high", "gemini-3-flash", "gemini-3-pro-image"]
  }

  var selected: [UsageMetric] = []
  for metricID in preferredIDs {
    guard let metric = candidates.first(where: { $0.id == metricID }) else { continue }
    selected.append(metric)
    if selected.count == 2 { return selected }
  }

  for metric in candidates where !selected.contains(where: { $0.id == metric.id }) {
    selected.append(metric)
    if selected.count == 2 { break }
  }
  return selected
}

/// The identity-color slot of one metric: its window kind, plus which
/// auxiliary color an `.other` metric takes.
public struct LimitSeriesSlot: Hashable, Sendable {
  public let kind: QuotaWindowKind
  public let otherSlot: Int

  public init(kind: QuotaWindowKind, otherSlot: Int = 0) {
    self.kind = kind
    self.otherSlot = otherSlot
  }
}

/// Stable color slots for an account's metrics: classified kinds map directly;
/// `.other` metrics take auxiliary slots in metric order so e.g. Google's
/// per-model quotas stay distinct and keep their color between refreshes.
/// Unlimited metrics render with the reserved unlimited tint and therefore do
/// not consume an auxiliary slot. Callers must pass the account's FULL metric
/// list (never a filtered subset) so every surface agrees on the assignment.
public func limitSeriesSlots(for metrics: [UsageMetric]) -> [LimitSeriesSlot] {
  var otherCount = 0
  return metrics.map { metric in
    let kind = QuotaWindowKind.classify(metricID: metric.id, label: metric.label)
    guard kind == .other, !metric.isUnlimited else {
      return LimitSeriesSlot(kind: kind)
    }
    defer { otherCount += 1 }
    return LimitSeriesSlot(kind: .other, otherSlot: otherCount)
  }
}

public extension LimitKindColors {
  func hexColor(for slot: LimitSeriesSlot) -> String {
    hexColor(for: slot.kind, otherSlot: slot.otherSlot)
  }
}
