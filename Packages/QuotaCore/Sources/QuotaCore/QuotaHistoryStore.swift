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

    let data = try Data(contentsOf: fileURL)
    return try decoder.decode([QuotaSnapshot].self, from: data)
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
    try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
  }

  /// Appends a snapshot to the retained history, unless it repeats the newest
  /// entry exactly.
  ///
  /// A refresh that carries the last-known usage after a failure, or that fails
  /// again with the same message, produces a snapshot whose accounts and failures
  /// are byte-identical to the newest stored one — it carries no new information.
  /// Storing it only grows the file (and the widget's per-render decode) and adds
  /// a flat repeated point to the trend. A *successful* refresh always advances
  /// `ProviderUsage.fetchedAt`, so genuine observations are never skipped.
  public func append(
    _ snapshot: QuotaSnapshot,
    keepDays: Int = 45,
    maxEntries: Int = 3_000
  ) throws {
    var history = try load()

    if let newest = history.max(by: { $0.generatedAt < $1.generatedAt }),
       newest.providers == snapshot.providers,
       newest.failures == snapshot.failures {
      return
    }

    history.append(snapshot)

    let cutoffDays = max(1, keepDays)
    let cutoffDate = snapshot.generatedAt.addingTimeInterval(-Double(cutoffDays) * 86_400)
    history = history.filter { $0.generatedAt >= cutoffDate }
    history.sort { $0.generatedAt < $1.generatedAt }

    let limit = max(1, maxEntries)
    if history.count > limit {
      history = Array(history.suffix(limit))
    }

    try save(history)
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
