import Foundation

public final class QuotaHistoryStore: @unchecked Sendable {
  private let fileURL: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(fileURL: URL) {
    self.fileURL = fileURL
    self.encoder = JSONEncoder()
    self.decoder = JSONDecoder()
    encoder.dateEncodingStrategy = .iso8601
    decoder.dateDecodingStrategy = .iso8601
    // Compact (not pretty-printed): the widget extension reads this file on every
    // timeline refresh under a tight memory budget, so keep it as small as possible.
    encoder.outputFormatting = []
  }

  public func load() throws -> [QuotaSnapshot] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return []
    }

    do {
      let data = try Data(contentsOf: fileURL)
      return try decoder.decode([QuotaSnapshot].self, from: data)
    } catch {
      let timestamp = Int(Date().timeIntervalSince1970)
      let corruptURL = fileURL.deletingPathExtension()
        .appendingPathExtension("corrupt-\(timestamp).json")
      try? FileManager.default.moveItem(at: fileURL, to: corruptURL)
      return []
    }
  }

  /// Loads only the snapshots within the last `days`, capped to the newest `maxEntries`.
  /// The widget uses this so a large history file can't exhaust the extension's memory
  /// budget while rendering the (at most 30-day) trend chart.
  public func loadRecent(days: Int, maxEntries: Int = 3_000, now: Date = Date()) throws -> [QuotaSnapshot] {
    let cutoff = now.addingTimeInterval(-Double(max(1, days)) * 86_400)
    let recent = try load()
      .filter { $0.generatedAt >= cutoff }
      .sorted { $0.generatedAt < $1.generatedAt }

    if recent.count > max(1, maxEntries) {
      return Array(recent.suffix(max(1, maxEntries)))
    }
    return recent
  }

  public func save(_ snapshots: [QuotaSnapshot]) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let normalized = snapshots.sorted { $0.generatedAt < $1.generatedAt }
    let data = try encoder.encode(normalized)
    try data.write(to: fileURL, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }

  public func append(
    _ snapshot: QuotaSnapshot,
    keepDays: Int = 45,
    maxEntries: Int = 3_000
  ) throws {
    var history = try load()

    let cutoffDays = max(1, keepDays)
    let cutoffDate = snapshot.generatedAt.addingTimeInterval(-Double(cutoffDays) * 86_400)

    if let newest = history.max(by: { $0.generatedAt < $1.generatedAt }),
       newest.generatedAt >= cutoffDate,
       Self.hasEquivalentUsage(newest, snapshot) {
      return
    }

    history.append(snapshot)
    history = history.filter { $0.generatedAt >= cutoffDate }
    history.sort { $0.generatedAt < $1.generatedAt }

    let limit = max(1, maxEntries)
    if history.count > limit {
      history = Array(history.suffix(limit))
    }

    try save(history)
  }

  static func hasEquivalentUsage(_ lhs: QuotaSnapshot, _ rhs: QuotaSnapshot) -> Bool {
    guard lhs.failures == rhs.failures else { return false }
    guard lhs.providers.count == rhs.providers.count else { return false }

    for (p1, p2) in zip(lhs.providers, rhs.providers) {
      guard p1.accountID == p2.accountID,
            p1.provider == p2.provider,
            p1.warning == p2.warning,
            p1.maxUsagePercent == p2.maxUsagePercent,
            p1.metrics.count == p2.metrics.count
      else { return false }

      for (m1, m2) in zip(p1.metrics, p2.metrics) {
        guard m1.id == m2.id,
              m1.remainingPercent == m2.remainingPercent,
              m1.remainingAmount == m2.remainingAmount,
              m1.usedDisplay == m2.usedDisplay,
              m1.totalDisplay == m2.totalDisplay,
              m1.isUnlimited == m2.isUnlimited,
              m1.resetAt == m2.resetAt
        else { return false }
      }
    }
    return true
  }

  public func remove(accountIDs: Set<String>) throws {
    guard !accountIDs.isEmpty else { return }

    let filtered = try load().map { snapshot in
      QuotaSnapshot(
        version: snapshot.version,
        generatedAt: snapshot.generatedAt,
        providers: snapshot.providers.filter { !accountIDs.contains($0.accountID) },
        failures: snapshot.failures.filter { !accountIDs.contains($0.accountID) }
      )
    }
    try save(filtered)
  }
}
