import XCTest
@testable import QuotaCore

final class QuotaHistoryStoreTests: XCTestCase {
  private let base = Date(timeIntervalSince1970: 1_700_000_000)

  private func reading(_ id: String, at date: Date, remaining: Int = 60) -> ProviderUsage {
    ProviderUsage(accountID: id, provider: .anthropic, title: id,
      metrics: [UsageMetric(id: "weekly", label: "Weekly", remainingPercent: remaining)], fetchedAt: date)
  }

  private func failure(_ id: String, message: String = "offline") -> ProviderFailure {
    ProviderFailure(accountID: id, provider: .anthropic, kind: .network, message: message)
  }

  private func makeStore() -> (QuotaHistoryStore, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let url = dir.appendingPathComponent("history.json")
    return (QuotaHistoryStore(fileURL: url), dir)
  }

  func testLoadRecentDropsSnapshotsOutsideWindow() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshots = (0..<10).map { day in
      QuotaSnapshot(generatedAt: now.addingTimeInterval(-Double(day) * 86_400), providers: [], failures: [])
    }
    try store.save(snapshots)

    let recent = try store.loadRecent(days: 3, now: now)
    // Window is (now - 3 days ... now]; day offsets 0,1,2,3 fall inside.
    XCTAssertEqual(recent.count, 4)
    XCTAssertTrue(recent.allSatisfy { $0.generatedAt >= now.addingTimeInterval(-3 * 86_400) })
    // Returned sorted ascending.
    XCTAssertEqual(recent, recent.sorted { $0.generatedAt < $1.generatedAt })
  }

  func testLoadRecentCapsToMaxEntries() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshots = (0..<100).map { i in
      QuotaSnapshot(generatedAt: now.addingTimeInterval(-Double(i) * 60), providers: [], failures: [])
    }
    try store.save(snapshots)

    let recent = try store.loadRecent(days: 30, maxEntries: 10, now: now)
    XCTAssertEqual(recent.count, 10)
    // Keeps the newest entries.
    XCTAssertEqual(recent.last?.generatedAt, now)
  }

  func testRemovePurgesOnlySelectedAccount() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = QuotaSnapshot(
      generatedAt: now,
      providers: [
        ProviderUsage(
          accountID: "remove-me",
          provider: .anthropic,
          title: "Claude",
          metrics: [],
          fetchedAt: now
        ),
        ProviderUsage(
          accountID: "keep-me",
          provider: .openAI,
          title: "OpenAI",
          metrics: [],
          fetchedAt: now
        )
      ],
      failures: [
        ProviderFailure(accountID: "remove-me", provider: .anthropic, kind: .auth, message: "failed")
      ]
    )
    try store.save([snapshot])

    try store.remove(accountIDs: ["remove-me"])

    let loaded = try XCTUnwrap(store.load().first)
    XCTAssertEqual(loaded.providers.map(\.accountID), ["keep-me"])
    XCTAssertTrue(loaded.failures.isEmpty)
  }

  func testFailedCarriesAndRepeatedFailureStatesAreNotNewSamples() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let success = QuotaSnapshot(generatedAt: base, providers: [reading("a", at: base)], failures: [])
    try store.append(success)
    for offset in [900.0, 1_800.0] {
      try store.append(QuotaSnapshot(generatedAt: base.addingTimeInterval(offset),
        providers: success.providers, failures: [failure("a")]))
    }
    let history = try store.load()
    XCTAssertEqual(history.count, 2)
    XCTAssertEqual(history.flatMap(\.providers), success.providers)
    XCTAssertEqual(history.flatMap(\.failures), [failure("a")])
  }

  func testFirstFailedSnapshotNeverArchivesCarriedUsage() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    try store.append(QuotaSnapshot(generatedAt: base,
      providers: [reading("a", at: base)], failures: [failure("a")]))
    XCTAssertTrue(try XCTUnwrap(store.load().first).providers.isEmpty)
  }

  func testTargetedRetryArchivesOnlyNewFetchesAndKeepsFreshEqualValues() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let initial = QuotaSnapshot(generatedAt: base,
      providers: [reading("a", at: base), reading("b", at: base)], failures: [])
    try store.append(initial)
    let retry = QuotaSnapshot(generatedAt: base.addingTimeInterval(900),
      providers: [reading("a", at: base.addingTimeInterval(900))], failures: [])
    try store.append(initial.replacingResults(forAccountIDs: ["a"], from: retry))
    let history = try store.load()
    XCTAssertEqual(history.count, 2)
    XCTAssertEqual(history.last?.providers.map(\.accountID), ["a"])
    XCTAssertEqual(history.flatMap(\.providers).filter { $0.accountID == "a" }.count, 2)
  }

  func testSameFetchSecondDeduplicatesAcrossReloadsAndWithinSnapshot() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let first = reading("a", at: base.addingTimeInterval(0.2))
    try store.append(QuotaSnapshot(generatedAt: base, providers: [first, first], failures: []))
    try store.append(QuotaSnapshot(generatedAt: base.addingTimeInterval(900),
      providers: [reading("a", at: base.addingTimeInterval(0.8))], failures: []))
    try store.append(QuotaSnapshot(generatedAt: base.addingTimeInterval(900),
      providers: [reading("a", at: base.addingTimeInterval(1.1))], failures: []))
    XCTAssertEqual(try store.load().flatMap(\.providers).map(\.fetchedAt), [base, base.addingTimeInterval(1)])
  }

  func testFailureNormalizationPreservesChangesAndRecovery() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let failures = [failure("a"), failure("b")]
    try store.append(QuotaSnapshot(generatedAt: base, providers: [], failures: failures))
    try store.append(QuotaSnapshot(generatedAt: base.addingTimeInterval(60), providers: [], failures: failures.reversed()))
    try store.append(QuotaSnapshot(generatedAt: base.addingTimeInterval(120), providers: [], failures: [failure("a", message: "auth")] ))
    try store.append(QuotaSnapshot(generatedAt: base.addingTimeInterval(180),
      providers: [reading("a", at: base.addingTimeInterval(180))], failures: [failure("b")]))
    try store.append(QuotaSnapshot(generatedAt: base.addingTimeInterval(240), providers: [], failures: [failure("a")]))
    let history = try store.load()
    XCTAssertEqual(history.count, 4)
    XCTAssertEqual(history.flatMap(\.failures).count, 4)
    XCTAssertEqual(history.last?.failures, [failure("a")])
  }

  func testChangingFailureDeadlineAndTitleDoesNotEvictObservationsOrRewriteArchive() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("history.json")
    let success = QuotaSnapshot(generatedAt: base, providers: [reading("healthy", at: base)], failures: [])
    try store.append(success, maxEntries: 2)

    let failedAt = base.addingTimeInterval(900)
    var limited = ProviderFailure(accountID: "limited", provider: .anthropic, kind: .rateLimit,
      message: "Try again later", retryAt: failedAt.addingTimeInterval(900))
    limited.title = "Original name"
    let failureSnapshot = QuotaSnapshot(generatedAt: failedAt, providers: [], failures: [limited])
    try store.append(failureSnapshot, maxEntries: 2)
    let original = try Data(contentsOf: url)

    for cycle in 1...10 {
      let date = failedAt.addingTimeInterval(Double(cycle) * 900)
      limited.retryAt = date.addingTimeInterval(900)
      limited.title = "Renamed account"
      let archive = try store.append(QuotaSnapshot(generatedAt: date, providers: [], failures: [limited]), maxEntries: 2)

      XCTAssertEqual(archive.snapshots, [success, failureSnapshot])
      XCTAssertEqual(try Data(contentsOf: url), original)
    }

    limited.kind = .auth
    let changed = QuotaSnapshot(generatedAt: failedAt.addingTimeInterval(11 * 900), providers: [], failures: [limited])
    let archive = try store.append(changed, maxEntries: 3)
    XCTAssertEqual(archive.snapshots, [success, failureSnapshot, changed])
    XCTAssertEqual(archive.snapshots.last?.failures, [limited])
  }

  func testDuplicateStillPrunesRetentionAndCannotResurrectExpiredCarry() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let oldDate = base.addingTimeInterval(-2 * 86_400)
    let old = QuotaSnapshot(generatedAt: oldDate, providers: [reading("a", at: oldDate)], failures: [])
    let current = QuotaSnapshot(generatedAt: base, providers: [reading("b", at: base)], failures: [])
    try store.save([old, current])
    let carried = QuotaSnapshot(generatedAt: base, providers: old.providers + current.providers, failures: [])
    try store.append(carried, keepDays: 1)
    try store.append(carried, keepDays: 1)
    XCTAssertEqual(try store.load(), [current])
  }

  func testRecentAndRetentionRankSourceActivityInsteadOfPublication() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let retry = QuotaSnapshot(generatedAt: base.addingTimeInterval(-2 * 86_400),
      providers: [reading("a", at: base)], failures: [])
    let older = QuotaSnapshot(generatedAt: base.addingTimeInterval(-60),
      providers: [reading("b", at: base.addingTimeInterval(-60))], failures: [])
    try store.save([retry, older])
    XCTAssertEqual(try store.loadRecent(days: 1, maxEntries: 1, now: base), [retry])
    try store.append(retry, keepDays: 1, maxEntries: 1)
    XCTAssertEqual(try store.load(), [retry])
  }

  func testNoMatchRemovalDoesNotCreateArchive() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    try store.remove(accountIDs: ["absent"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("history.json").path))
  }

  func testPublishDecodesAndEncodesOnceAndMirrorsIdenticalBytes() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let decoder = HistoryCountingDecoder()
    let encoder = HistoryCountingEncoder()
    let localURL = dir.appendingPathComponent("local.json")
    let mirrorURL = dir.appendingPathComponent("mirror.json")
    let store = QuotaHistoryStore(fileURL: localURL, encoder: encoder, decoder: decoder)
    let mirror = QuotaHistoryStore(fileURL: mirrorURL, encoder: encoder, decoder: decoder)
    try store.save((1...3_000).map { offset in
      let date = base.addingTimeInterval(-Double(offset) * 900)
      return QuotaSnapshot(generatedAt: date, providers: [reading("a", at: date)], failures: [])
    })
    try Data("corrupt mirror".utf8).write(to: mirrorURL)
    encoder.encodes = 0
    decoder.decodes = 0

    let archive = try store.append(QuotaSnapshot(generatedAt: base, providers: [reading("a", at: base)], failures: []))
    let recent = QuotaHistoryStore.recent(archive.snapshots, days: 2, now: base)
    try mirror.save(archive)
    XCTAssertEqual(decoder.decodes, 1)
    XCTAssertEqual(encoder.encodes, 1)
    XCTAssertEqual(archive.snapshots.count, 3_000)
    XCTAssertEqual(recent.count, 193)
    XCTAssertEqual(try Data(contentsOf: localURL), try Data(contentsOf: mirrorURL))
    for url in [localURL, mirrorURL] {
      let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
      XCTAssertEqual(mode?.intValue, 0o600)
    }
  }

  func testLegacyArchiveSurvivesAppendAndNoMatchRemovePreservesBytes() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("history.json")
    let original = QuotaSnapshot(version: 7, generatedAt: base,
      providers: [reading("a", at: base)], failures: [failure("a")])
    try store.save([original])
    let bytes = try Data(contentsOf: url)
    try store.remove(accountIDs: ["absent"])
    XCTAssertEqual(try Data(contentsOf: url), bytes)
    let date = base.addingTimeInterval(900)
    let archive = try store.append(QuotaSnapshot(generatedAt: date, providers: [reading("a", at: date)], failures: []))
    XCTAssertEqual(archive.snapshots.first, original)
    XCTAssertTrue(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) is [Any])
  }

  func testSparseAppendAndMirrorPreserveSnapshotCadence() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let first = QuotaSnapshot(version: 7, generatedAt: base,
      providers: [reading("a", at: base), reading("b", at: base)], failures: [], refreshIntervalMinutes: 30)
    try store.append(first)

    let fetchedAt = base.addingTimeInterval(900)
    let refreshed = QuotaSnapshot(version: 8, generatedAt: fetchedAt,
      providers: [reading("a", at: fetchedAt), first.providers[1]], failures: [], refreshIntervalMinutes: 60)
    let archive = try store.append(refreshed)
    var expected = refreshed
    expected.providers = [refreshed.providers[0]]

    XCTAssertEqual(archive.snapshots, [first, expected])
    XCTAssertEqual(try store.load(), [first, expected])
    let mirror = QuotaHistoryStore(fileURL: dir.appendingPathComponent("mirror.json"))
    try mirror.save(archive)
    XCTAssertEqual(try mirror.load(), [first, expected])
  }

  func testRemovalPreservesCadenceOnEveryEntry() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let original = [30, 60].enumerated().map { index, cadence in
      let date = base.addingTimeInterval(Double(index) * 900)
      return QuotaSnapshot(version: 7 + index, generatedAt: date,
        providers: [reading("remove", at: date), reading("keep", at: date)],
        failures: [failure("remove")], refreshIntervalMinutes: cadence)
    }
    try store.save(original)
    try store.remove(accountIDs: ["remove"])
    let expected = original.map { snapshot -> QuotaSnapshot in
      var copy = snapshot
      copy.providers = [snapshot.providers[1]]
      copy.failures = []
      return copy
    }
    XCTAssertEqual(try store.load(), expected)
  }
}

private final class HistoryCountingDecoder: JSONDecoder, @unchecked Sendable {
  var decodes = 0
  override func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    decodes += 1
    return try super.decode(type, from: data)
  }
}

private final class HistoryCountingEncoder: JSONEncoder, @unchecked Sendable {
  var encodes = 0
  override func encode<T: Encodable>(_ value: T) throws -> Data {
    encodes += 1
    return try super.encode(value)
  }
}
