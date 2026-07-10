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
