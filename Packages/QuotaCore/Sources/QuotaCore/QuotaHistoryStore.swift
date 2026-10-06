import Foundation

public final class QuotaHistoryStore: @unchecked Sendable {
  /// Entry cap shared by retention and recent reads. Default arguments of public
  /// functions may only reference public or `@usableFromInline` declarations.
  @usableFromInline static let defaultMaxEntries = 3_000

  private let fileURL: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public convenience init(fileURL: URL) {
    self.init(fileURL: fileURL, decoder: JSONDecoder())
  }

  /// Tests inject a decoder subclass to count full-archive decodes.
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

  public func load() throws -> [QuotaSnapshot] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return []
    }

    let data = try Data(contentsOf: fileURL)
    return try decoder.decode([QuotaSnapshot].self, from: data)
  }

  /// Loads only the snapshots within the last `days`, capped to the newest `maxEntries`.
  /// The widget uses this so a large history file can't exhaust the extension's memory
  /// budget while rendering the (at most 30-day) trend chart. The whole archive is
  /// still decoded first; callers already holding it should use `recent` instead.
  public func loadRecent(days: Int, maxEntries: Int = defaultMaxEntries, now: Date = Date()) throws -> [QuotaSnapshot] {
    Self.recent(try load(), days: days, now: now, maxEntries: maxEntries)
  }

  /// The snapshots within the last `days`, sorted oldest first and capped to the
  /// newest `maxEntries`.
  public static func recent(
    _ history: [QuotaSnapshot],
    days: Int,
    now: Date,
    maxEntries: Int = defaultMaxEntries
  ) -> [QuotaSnapshot] {
    let cutoff = now.addingTimeInterval(-Double(max(1, days)) * 86_400)
    let recent = history
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

  /// Returns the trimmed archive it wrote, so callers can derive views from it
  /// without decoding the file again.
  @discardableResult
  public func append(
    _ snapshot: QuotaSnapshot,
    keepDays: Int = 45,
    maxEntries: Int = defaultMaxEntries
  ) throws -> [QuotaSnapshot] {
    var history = try load()
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
    return history
  }

  /// Rewrites the archive only when some entry belongs to `accountIDs`.
  public func remove(accountIDs: Set<String>) throws {
    guard !accountIDs.isEmpty else { return }

    let history = try load()
    let matches = history.contains { snapshot in
      snapshot.providers.contains { accountIDs.contains($0.accountID) }
        || snapshot.failures.contains { accountIDs.contains($0.accountID) }
    }
    guard matches else { return }

    let filtered = history.map { snapshot in
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
