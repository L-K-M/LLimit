import Foundation

public final class QuotaHistoryStore: @unchecked Sendable {
  private static let secondsPerDay: TimeInterval = 24 * 60 * 60
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

  /// Loads recent snapshot/source activity, capped to the newest `maxEntries`.
  /// Returns entries in `generatedAt` order.
  /// The widget uses this so a large history file can't exhaust the extension's memory
  /// budget while rendering the (at most 30-day) trend chart.
  public func loadRecent(days: Int, maxEntries: Int = 3_000, now: Date = Date()) throws -> [QuotaSnapshot] {
    let cutoff = now.addingTimeInterval(-Double(max(1, days)) * Self.secondsPerDay)
    let recent = try load()
      .filter { Self.effectiveActivityDate(for: $0) >= cutoff }

    return Self.cappedSnapshots(recent, maxEntries: maxEntries)
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

  /// Archives sparse new observations and failure events, not full current state.
  public func append(
    _ snapshot: QuotaSnapshot,
    keepDays: Int = 45,
    maxEntries: Int = 3_000
  ) throws {
    var history = try load()
    let cutoffDays = max(1, keepDays)
    let cutoffDate = Self.effectiveActivityDate(for: snapshot)
      .addingTimeInterval(-Double(cutoffDays) * Self.secondsPerDay)
    let observations = QuotaObservations.newSuccessfulUsage(in: snapshot, excluding: history)
      .filter { $0.fetchedAt >= cutoffDate }

    // Record new readings and failure events, not carried or untouched usages.
    // Dedupe before pruning so retention cannot resurrect an archived reading.
    if !observations.isEmpty || !snapshot.failures.isEmpty {
      var entry = snapshot
      entry.providers = observations
      history.append(entry)
    }

    history = history.filter { Self.effectiveActivityDate(for: $0) >= cutoffDate }
    try save(Self.cappedSnapshots(history, maxEntries: maxEntries))
  }

  private static func effectiveActivityDate(for snapshot: QuotaSnapshot) -> Date {
    // A targeted retry can fetch after its containing snapshot was generated.
    snapshot.providers.reduce(snapshot.generatedAt) { max($0, $1.fetchedAt) }
  }

  private static func cappedSnapshots(_ snapshots: [QuotaSnapshot], maxEntries: Int) -> [QuotaSnapshot] {
    let ranked = snapshots.map { (snapshot: $0, activity: effectiveActivityDate(for: $0)) }
      .sorted { lhs, rhs in
        if lhs.activity != rhs.activity { return lhs.activity < rhs.activity }
        return lhs.snapshot.generatedAt < rhs.snapshot.generatedAt
      }

    // Select by activity without changing the archive's publication ordering.
    return ranked.suffix(max(1, maxEntries)).map(\.snapshot)
      .sorted { $0.generatedAt < $1.generatedAt }
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
