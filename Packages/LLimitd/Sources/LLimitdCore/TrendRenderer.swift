import Foundation
import QuotaCore

/// Forward fill is decorative; only source fetches count as observations.
public enum TrendRenderer {
  private static let blocks: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
  private enum ValueKind: String, Hashable { case percent, amount }
  private struct Series: Hashable {
    let provider: QuotaProvider
    let accountID: String
    let metricID: String
    let kind: QuotaWindowKind
    let valueKind: ValueKind
  }

  public static func sparkline(
    _ samples: [(at: Date, value: Double)], window: ClosedRange<Date>,
    width: Int = 24, scale: ClosedRange<Double>? = nil
  ) -> String {
    guard width > 0, !samples.isEmpty else { return "" }
    let span = max(1, window.upperBound.timeIntervalSince(window.lowerBound))
    let observed = samples.filter { window.contains($0.at) && $0.value.isFinite }
    var buckets = [Double?](repeating: nil, count: width)
    for sample in observed.sorted(by: { $0.at < $1.at }) {
      let offset = sample.at.timeIntervalSince(window.lowerBound) / span
      let index = min(width - 1, max(0, Int((offset * Double(width)).rounded(.down))))
      buckets[index] = sample.value
    }
    let values = observed.map(\.value)
    guard let minimum = values.min(), let maximum = values.max() else { return "" }
    let low = scale?.lowerBound ?? minimum
    let high = scale?.upperBound ?? maximum
    var output = ""
    var carried: Double?
    for bucket in buckets {
      if let bucket { carried = bucket }
      guard let value = carried else { output.append(" "); continue }
      // Halving first avoids overflow between finite signed amounts.
      let relative = high == low ? 0.5 : (high - low).isFinite
        ? (value - low) / (high - low)
        : (value / 2 - low / 2) / (high / 2 - low / 2)
      let fraction = min(1, max(0, relative))
      output.append(blocks[Int(fraction * Double(blocks.count - 1))])
    }
    return output
  }

  public static func render(
    history: [QuotaSnapshot], now: Date = Date(), days: Int = 7,
    width: Int = 24, accountPrefix: String? = nil
  ) -> String {
    let days = max(1, days)
    let window = now.addingTimeInterval(-Double(days) * 86_400)...now
    var samples: [Series: [(at: Date, value: Double)]] = [:]
    var titles: [Series: String] = [:]
    var labels: [Series: String] = [:]
    var values: [Series: String] = [:]

    for usage in QuotaObservations.extract(from: history, window: window) {
      if let prefix = accountPrefix, !usage.accountID.hasPrefix(prefix),
         !usage.title.localizedCaseInsensitiveContains(prefix) { continue }
      for metric in usage.metrics where !metric.isUnlimited {
        guard let value = metric.remainingPercent.map(Double.init) ?? metric.remainingAmount, value.isFinite else { continue }
        let key = Series(provider: usage.provider, accountID: usage.accountID,
          metricID: metric.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? metric.label : metric.id,
          kind: QuotaWindowKind.classify(metricID: metric.id, label: metric.label),
          valueKind: metric.remainingPercent != nil ? .percent : .amount)
        samples[key, default: []].append((at: usage.fetchedAt, value: value))
        titles[key] = usage.title
        labels[key] = metric.label
        values[key] = metric.remainingPercent.map { "\($0)% left" } ?? metric.usageLine ?? String(value)
      }
    }

    var lines = ["LLimit trend: last \(days)d"]
    var currentAccount: String?
    for key in samples.keys.sorted(by: {
      (titles[$0] ?? "", $0.accountID, labels[$0] ?? "", $0.valueKind.rawValue)
        < (titles[$1] ?? "", $1.accountID, labels[$1] ?? "", $1.valueKind.rawValue)
    }) {
      guard let series = samples[key], series.count >= 2 else { continue }
      if currentAccount != key.accountID {
        currentAccount = key.accountID
        lines.append("\(titles[key] ?? key.accountID):")
      }
      let line = sparkline(series, window: window, width: width, scale: key.valueKind == .percent ? 0...100 : nil)
      let normalization = key.valueKind == .amount ? " (amount, normalized to observed range)" : ""
      lines.append("  \(labels[key] ?? key.metricID)  \(line)  \(values[key] ?? "")\(normalization)")
    }
    if lines.count == 1 { lines.append("  Not enough history yet. Two successful fetches are required.") }
    return lines.joined(separator: "\n")
  }
}
