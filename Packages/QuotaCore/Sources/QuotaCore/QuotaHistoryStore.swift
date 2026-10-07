import Foundation

public final class QuotaHistoryStore: @unchecked Sendable {
  private static let secondsPerDay: TimeInterval = 24 * 60 * 60

  /// Reuse the decoded archive and its bytes for views and mirror stores.
  public struct Archive: Sendable {
    public let snapshots: [QuotaSnapshot]
    fileprivate let encoded: Data
  }

  private let fileURL: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public convenience init(fileURL: URL) {
    self.init(fileURL: fileURL, decoder: JSONDecoder())
  }

  convenience init(fileURL: URL, decoder: JSONDecoder) {
    self.init(fileURL: fileURL, encoder: JSONEncoder(), decoder: decoder)
  }

  init(fileURL: URL, encoder: JSONEncoder, decoder: JSONDecoder) {
    self.fileURL = fileURL
    self.encoder = encoder
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

  /// Decodes the archive, then selects recent source/publication activity.
  public func loadRecent(days: Int, maxEntries: Int = 3_000, now: Date = Date()) throws -> [QuotaSnapshot] {
    Self.recent(try load(), days: days, now: now, maxEntries: maxEntries)
  }

  public static func recent(
    _ history: [QuotaSnapshot], days: Int, now: Date, maxEntries: Int = 3_000
  ) -> [QuotaSnapshot] {
    let cutoff = now.addingTimeInterval(-Double(max(1, days)) * Self.secondsPerDay)
    return cappedSnapshots(history.filter { effectiveActivityDate(for: $0) >= cutoff }, maxEntries: maxEntries)
  }

  public func save(_ snapshots: [QuotaSnapshot]) throws {
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try withStoreFileLock(at: fileURL) { try saveLocked(snapshots) }
  }

  private func saveLocked(_ snapshots: [QuotaSnapshot]) throws {
    let normalized = snapshots.sorted { $0.generatedAt < $1.generatedAt }
    try writeOwnerOnlyAtomicallyLocked(encoder.encode(normalized), to: fileURL)
  }

  public func save(_ archive: Archive) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    // Mirrors reuse encoded bytes, but serialize against owner recovery too.
    try withStoreFileLock(at: fileURL) {
      try writeOwnerOnlyAtomicallyLocked(archive.encoded, to: fileURL)
    }
  }

  /// Archives new fetches and changed failure states. Equal fresh values survive.
  @discardableResult
  public func append(
    _ snapshot: QuotaSnapshot,
    keepDays: Int = 45,
    maxEntries: Int = 3_000
  ) throws -> Archive {
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    return try withStoreFileLock(at: fileURL) {
      try appendLocked(snapshot, keepDays: keepDays, maxEntries: maxEntries)
    }
  }

  private func appendLocked(_ snapshot: QuotaSnapshot, keepDays: Int, maxEntries: Int) throws -> Archive {
    let original = try loadLocked(policy: .recover)
    var history = original

    let cutoffDays = max(1, keepDays)
    let activity = max(Self.effectiveActivityDate(for: snapshot), history.map(Self.effectiveActivityDate).max() ?? .distantPast)
    let cutoffDate = activity.addingTimeInterval(-Double(cutoffDays) * Self.secondsPerDay)
    let observations = QuotaObservations.newSuccessfulUsage(in: snapshot, excluding: history)
      .filter { $0.fetchedAt >= cutoffDate }
    let failures = Self.changedFailures(in: snapshot, history: history)

    // Dedupe before pruning: expired copies must never resurrect observations.
    if !observations.isEmpty || !failures.isEmpty {
      history.append(QuotaSnapshot(version: snapshot.version, generatedAt: snapshot.generatedAt,
        providers: observations, failures: failures))
    }

    history = Self.cappedSnapshots(history.filter { Self.effectiveActivityDate(for: $0) >= cutoffDate }, maxEntries: maxEntries)
    let encoded = try encoder.encode(history)
    if history != original { try writeOwnerOnlyAtomicallyLocked(encoded, to: fileURL) }
    return Archive(snapshots: history, encoded: encoded)
  }

  private static func effectiveActivityDate(for snapshot: QuotaSnapshot) -> Date {
    snapshot.providers.reduce(snapshot.generatedAt) { max($0, $1.fetchedAt) }
  }

  private static func cappedSnapshots(_ snapshots: [QuotaSnapshot], maxEntries: Int) -> [QuotaSnapshot] {
    snapshots.sorted { lhs, rhs in
      let left = effectiveActivityDate(for: lhs)
      let right = effectiveActivityDate(for: rhs)
      if left != right { return left < right }
      return lhs.generatedAt < rhs.generatedAt
    }.suffix(max(1, maxEntries)).sorted { $0.generatedAt < $1.generatedAt }
  }

  private struct FailureKey: Hashable {
    let provider: QuotaProvider
    let accountID: String
  }

  private static func changedFailures(in snapshot: QuotaSnapshot, history: [QuotaSnapshot]) -> [ProviderFailure] {
    var states: [FailureKey: ProviderFailure] = [:]
    for entry in history.sorted(by: { effectiveActivityDate(for: $0) < effectiveActivityDate(for: $1) }) {
      for usage in entry.providers {
        states[FailureKey(provider: usage.provider, accountID: usage.accountID)] = nil
      }
      for failure in entry.failures {
        states[FailureKey(provider: failure.provider, accountID: failure.accountID)] = failure
      }
    }

    // Completion order and duplicate failures do not represent state changes.
    return Set(snapshot.failures).filter {
      states[FailureKey(provider: $0.provider, accountID: $0.accountID)] != $0
    }.sorted {
      ($0.provider.rawValue, $0.accountID, $0.kind.rawValue, $0.message)
        < ($1.provider.rawValue, $1.accountID, $1.kind.rawValue, $1.message)
    }
  }

  public func remove(accountIDs: Set<String>) throws {
    guard !accountIDs.isEmpty, FileManager.default.fileExists(atPath: fileURL.path) else { return }
    try withStoreFileLock(at: fileURL) { try removeLocked(accountIDs: accountIDs) }
  }

  private func removeLocked(accountIDs: Set<String>) throws {
    let history = try loadLocked(policy: .recover)
    let filtered = history.map { snapshot in
      QuotaSnapshot(
        version: snapshot.version,
        generatedAt: snapshot.generatedAt,
        providers: snapshot.providers.filter { !accountIDs.contains($0.accountID) },
        failures: snapshot.failures.filter { !accountIDs.contains($0.accountID) }
      )
    }
    guard filtered != history else { return }
    try saveLocked(filtered)
  }
}
