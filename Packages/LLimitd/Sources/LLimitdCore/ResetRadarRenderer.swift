import Foundation
import QuotaCore

public extension StatusRenderer {
  static func resetsHumanReadable(snapshot: QuotaSnapshot?, now: Date = Date(), windowDays: Int = ResetsOptions.defaultDays) -> String {
    guard let snapshot else { return "No quota data yet. Run `llimit refresh` (or start `llimit daemon`)." }
    let days = max(ResetsOptions.supportedDays.lowerBound, min(ResetsOptions.supportedDays.upperBound, windowDays))
    let resets = snapshot.upcomingResets(now: now, within: TimeInterval(days) * 86_400)
    let window = "\(days) day\(days == 1 ? "" : "s")"
    let stale = QuotaFreshness.isStale(fetchedAt: snapshot.generatedAt, in: snapshot, now: now)
      ? " (data from \(formatShortDuration(seconds: boundedSeconds(now.timeIntervalSince(snapshot.generatedAt)))) ago)" : ""
    var lines = [resets.isEmpty ? "No resets in the next \(window)\(stale)." : "Upcoming resets (next \(window))\(stale)"]
    for reset in resets {
      let reading: String
      if reset.isUnlimited { reading = "unlimited" }
      else if let remaining = reset.remainingPercent { reading = "\(reset.isEstimated ? "≈" : "")\(remaining)% left" }
      else { reading = reset.usageLine ?? reset.remainingAmount.map { String($0) } ?? "" }
      lines.append("in \(reset.countdown(at: now)) — \(singleLine(reset.accountName)) · \(singleLine(reset.metricLabel))"
        + (reading.isEmpty ? "" : " (\(singleLine(reading)))"))
    }
    let failures = snapshot.preferredFailures.count
    if failures > 0 { lines.append("\(failures) account\(failures == 1 ? "" : "s") failed to refresh; their resets may be missing.") }
    return lines.joined(separator: "\n")
  }

  static func resetsJSON(snapshot: QuotaSnapshot?, now: Date = Date(), windowDays: Int = ResetsOptions.defaultDays) -> String {
    let days = max(ResetsOptions.supportedDays.lowerBound, min(ResetsOptions.supportedDays.upperBound, windowDays))
    var object: [String: Any] = ["windowDays": days, "snapshot": snapshot != nil, "resets": [Any]()]
    if let snapshot {
      object["generatedAt"] = iso8601String(snapshot.generatedAt)
      object["failureCount"] = snapshot.preferredFailures.count
      object["stale"] = QuotaFreshness.isStale(fetchedAt: snapshot.generatedAt, in: snapshot, now: now)
      object["resets"] = resetObjects(snapshot.upcomingResets(now: now, within: TimeInterval(days) * 86_400), now: now)
    }
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
      return #"{"error":"reset schedule serialization failed"}"#
    }
    return String(decoding: data, as: UTF8.self)
  }
}

extension StatusRenderer {
  static func resetObjects(_ resets: [UpcomingReset], now: Date) -> [[String: Any]] {
    resets.map { reset in
      var row: [String: Any] = [
        "accountID": reset.accountID, "name": reset.accountName, "provider": reset.provider.rawValue,
        "metricID": reset.metricID, "metricLabel": reset.metricLabel, "window": reset.windowKind.rawValue,
        "resetAt": iso8601String(reset.resetAt), "resetIn": reset.countdown(at: now),
        "resetSeconds": boundedSeconds(reset.resetAt.timeIntervalSince(now)), "unlimited": reset.isUnlimited
      ]
      if let percent = reset.remainingPercent { row["remainingPercent"] = percent }
      if let amount = reset.remainingAmount, amount.isFinite { row["remainingAmount"] = amount }
      if let usage = reset.usageLine { row["usageLine"] = usage }
      if reset.isEstimated { row["estimated"] = true }
      return row
    }
  }
}
