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

/// How many color-scheme variants exist per identity hue: base, deep, pale.
/// A fourth account wraps back to the base scheme.
public let accountColorVariantCount = 3

/// Accounts in the stable order every color and tile decision keys off:
/// provider, then display name, then id. Shared by the tile auto-order and
/// the account color variants.
public func stableAccountOrder(_ accounts: [ProviderAccount]) -> [ProviderAccount] {
  accounts.sorted { lhs, rhs in
    if lhs.provider.rawValue != rhs.provider.rawValue {
      return lhs.provider.rawValue < rhs.provider.rawValue
    }
    if lhs.resolvedDisplayName != rhs.resolvedDisplayName {
      return lhs.resolvedDisplayName < rhs.resolvedDisplayName
    }
    return lhs.id < rhs.id
  }
}

/// Which variant of every identity hue this account's marks wear (0 = base,
/// 1 = deep, 2 = pale). The tile rings double as the trend chart's legend, so
/// no two accounts may share an exact color scheme. Ranked over ALL accounts —
/// not just enabled ones — so disabling an account never recolors the others,
/// using the same order users see tiles auto-fill in. Legacy sole-account
/// usages identify themselves by the provider's raw value and resolve to that
/// provider's only account.
public func accountColorStep(forAccountID accountID: String, in accounts: [ProviderAccount]) -> Int {
  let ordered = stableAccountOrder(accounts)

  if let index = ordered.firstIndex(where: { $0.id == accountID }) {
    return index % accountColorVariantCount
  }

  if let provider = QuotaProvider(rawValue: accountID) {
    let matches = ordered.enumerated().filter { $0.element.provider == provider }
    if matches.count == 1, let match = matches.first {
      return match.offset % accountColorVariantCount
    }
  }

  return 0
}
