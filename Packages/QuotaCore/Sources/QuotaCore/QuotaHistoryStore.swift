import Foundation

public final class QuotaHistoryStore: @unchecked Sendable {
  private let fileURL: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public convenience init(fileURL: URL) {
    self.init(fileURL: fileURL, decoder: JSONDecoder())
  }

  init(fileURL: URL, decoder: JSONDecoder) {
    self.fileURL = fileURL
    self.encoder = JSONEncoder()
    self.decoder = decoder
    encoder.dateEncodingStrategy = .iso8601
    decoder.dateDecodingStrategy = .iso8601
    // Compact (not pretty-printed): the widget extension reads this file on every
    // timeline refresh under a tight memory budget, so keep it as small as possible.
    encoder.outputFormatting = []
  }

  public func load(policy: StoreReadPolicy = .preserve) throws -> [QuotaSnapshot] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    if case .recover = policy {
      return try withStoreFileLock(at: fileURL) { try loadLocked(policy: policy) }
    }
    return try loadLocked(policy: policy)
  }

  private func loadLocked(policy: StoreReadPolicy) throws -> [QuotaSnapshot] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return []
    }

    let data = try Data(contentsOf: fileURL)
    do {
      return try decoder.decode([QuotaSnapshot].self, from: data)
    } catch {
      guard case .recover = policy else { throw error }
      guard quarantineCorruptFile(at: fileURL) else { throw error }
      reportPersistenceIssue("Quarantined undecodable \(fileURL.lastPathComponent).")
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

    try withStoreFileLock(at: fileURL) { try saveLocked(snapshots) }
  }

  private func saveLocked(_ snapshots: [QuotaSnapshot]) throws {
    let normalized = snapshots.sorted { $0.generatedAt < $1.generatedAt }
    let data = try encoder.encode(normalized)
    try writeOwnerOnlyAtomicallyLocked(data, to: fileURL)
  }

  public func append(
    _ snapshot: QuotaSnapshot,
    keepDays: Int = 45,
    maxEntries: Int = 3_000
  ) throws {
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try withStoreFileLock(at: fileURL) {
      try appendLocked(snapshot, keepDays: keepDays, maxEntries: maxEntries)
    }
  }

  private func appendLocked(_ snapshot: QuotaSnapshot, keepDays: Int, maxEntries: Int) throws {
    var history = try loadLocked(policy: .recover)
    history.append(snapshot)

    let cutoffDays = max(1, keepDays)
    let cutoffDate = snapshot.generatedAt.addingTimeInterval(-Double(cutoffDays) * 86_400)
    history = history.filter { $0.generatedAt >= cutoffDate }
    history.sort { $0.generatedAt < $1.generatedAt }

    let limit = max(1, maxEntries)
    if history.count > limit {
      history = Array(history.suffix(limit))
    }

    try saveLocked(history)
  }

  public func remove(accountIDs: Set<String>) throws {
    guard !accountIDs.isEmpty, FileManager.default.fileExists(atPath: fileURL.path) else { return }
    try withStoreFileLock(at: fileURL) { try removeLocked(accountIDs: accountIDs) }
  }

  private func removeLocked(accountIDs: Set<String>) throws {
    let filtered = try loadLocked(policy: .recover).map { snapshot in
      QuotaSnapshot(
        version: snapshot.version,
        generatedAt: snapshot.generatedAt,
        providers: snapshot.providers.filter { !accountIDs.contains($0.accountID) },
        failures: snapshot.failures.filter { !accountIDs.contains($0.accountID) }
      )
    }
    try saveLocked(filtered)
  }
}
