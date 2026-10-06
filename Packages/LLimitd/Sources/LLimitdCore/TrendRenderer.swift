import Foundation
import QuotaCore

/// `llimit trend` — per-account sparklines built from the local history file.
/// Values forward-fill because quota is stepwise: a reading persists until the
/// next observation replaces it. Percent metrics render 0–100; amount-only
/// metrics (balances) render normalized to their own observed range.
public enum TrendRenderer {
  private static let blocks: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

  /// `width` time-buckets over the history window; the last sample in each
  /// bucket wins and empty buckets inherit the previous value (step data).
  /// Leading buckets before the first sample stay blank. `scale` pins the
  /// value range (percent series pass 0...100 so height reads as level);
  /// without it the series normalizes to its own observed min/max.
  public static func sparkline(_ samples: [(at: Date, value: Double)],
                               window: ClosedRange<Date>, width: Int = 24,
                               scale: ClosedRange<Double>? = nil) -> String {
    guard width > 0, !samples.isEmpty else { return "" }
    let span = max(1, window.upperBound.timeIntervalSince(window.lowerBound))
    var buckets = [Double?](repeating: nil, count: width)
    for sample in samples where sample.at >= window.lowerBound && sample.at <= window.upperBound {
      let offset = sample.at.timeIntervalSince(window.lowerBound) / span
      let index = min(width - 1, max(0, Int((offset * Double(width)).rounded(.down))))
      buckets[index] = sample.value
    }
    let observed = buckets.compactMap { $0 }
    guard !observed.isEmpty else { return "" }
    let low = scale?.lowerBound ?? observed.min()!
    let high = scale?.upperBound ?? observed.max()!
    let range = high - low

    var output = ""
    var carried: Double?
    for bucket in buckets {
      if let value = bucket { carried = value }
      guard let value = carried else {
        output.append(" ")
        continue
      }
      // A flat unscaled series draws a mid-height line rather than a floor row.
      let level = range == 0 ? 3 : Int((value - low) / range * 7).clamped(to: 0...7)
      output.append(blocks[level])
    }
    return output
  }

  /// One block of lines per account with at least two observations:
  /// `  5-hour limit  ▁▃▅█  42% left`.
  public static func render(history: [QuotaSnapshot], now: Date = Date(),
                            days: Int = 7, width: Int = 24,
                            accountPrefix: String? = nil) -> String {
    let cutoff = now.addingTimeInterval(-Double(max(1, days)) * 86_400)
    let window = cutoff...now
    let sorted = history.filter { $0.generatedAt >= cutoff }
      .sorted { $0.generatedAt < $1.generatedAt }

    // Identity is (account, metric) only — titles/labels are display data and
    // can change mid-history on an upstream rename without splitting a series.
    struct Series: Hashable {
      let accountID: String, metricID: String
    }
    var order: [Series] = []
    var samples: [Series: [(at: Date, value: Double)]] = [:]
    var displayTitle: [Series: String] = [:]
    var displayLabel: [Series: String] = [:]
    var isPercent: [Series: Bool] = [:]
    var latestValue: [Series: String] = [:]

    for snapshot in sorted {
      for usage in snapshot.providers {
        if let prefix = accountPrefix,
           !usage.accountID.hasPrefix(prefix),
           !usage.title.localizedCaseInsensitiveContains(prefix) {
          continue
        }
        for metric in usage.metrics where !metric.isUnlimited {
          guard let value = metric.remainingPercent.map(Double.init) ?? metric.remainingAmount else { continue }
          let key = Series(accountID: usage.accountID, metricID: metric.id)
          if !order.contains(key) { order.append(key) }
          samples[key, default: []].append((at: snapshot.generatedAt, value: value))
          displayTitle[key] = usage.title
          displayLabel[key] = metric.label
          isPercent[key] = metric.remainingPercent != nil
          if let percent = metric.remainingPercent {
            latestValue[key] = "\(percent)% left"
          } else if let amount = metric.remainingAmount {
            latestValue[key] = metric.usageLine ?? "\(amount)"
          }
        }
      }
    }

    var lines = ["LLimit trend — last \(days)d"]
    var currentAccount = ""
    var anySeries = false
    for key in order.sorted(by: {
      (displayTitle[$0] ?? "", displayLabel[$0] ?? "") <
        (displayTitle[$1] ?? "", displayLabel[$1] ?? "")
    }) {
      guard let series = samples[key], series.count >= 2 else { continue }
      anySeries = true
      let title = displayTitle[key] ?? key.accountID
      if title != currentAccount {
        currentAccount = title
        lines.append("\(title):")
      }
      let line = sparkline(series, window: window, width: width,
                           scale: isPercent[key] == true ? 0...100 : nil)
      lines.append("  \((displayLabel[key] ?? key.metricID).padding(toLength: 22, withPad: " ", startingAt: 0)) \(line)  \(latestValue[key] ?? "")")
    }
    if !anySeries {
      lines.append("  not enough history yet — the daemon records a point each refresh")
    }
    return lines.joined(separator: "\n")
  }
}

private extension Int {
  func clamped(to range: ClosedRange<Int>) -> Int {
    Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
  }
}
