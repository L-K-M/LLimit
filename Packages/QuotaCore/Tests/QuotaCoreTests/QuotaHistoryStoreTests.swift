import XCTest
@testable import QuotaCore

final class QuotaHistoryStoreTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

  private func makeStore() -> (QuotaHistoryStore, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let url = dir.appendingPathComponent("history.json")
    return (QuotaHistoryStore(fileURL: url), dir)
  }

  private func usage(_ accountID: String, at date: Date, remaining: Int = 60) -> ProviderUsage {
    ProviderUsage(
      accountID: accountID,
      provider: .anthropic,
      title: "Claude",
      metrics: [UsageMetric(id: "weekly", label: "Weekly", remainingPercent: remaining)],
      fetchedAt: date
    )
  }

  private func failure(_ accountID: String) -> ProviderFailure {
    ProviderFailure(accountID: accountID, provider: .anthropic, kind: .network, message: "Unavailable")
  }

  func testAppendSuccessThenFailuresRecordsOnlySuccessfulUsage() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let success = QuotaSnapshot(generatedAt: t0, providers: [usage("a", at: t0)], failures: [])
    try store.append(success)

    for offset in [900.0, 1_800.0] {
      let failed = QuotaSnapshot(
        generatedAt: t0.addingTimeInterval(offset), providers: [], failures: [failure("a")]
      ).mergingStaleUsage(from: success)
      try store.append(failed)
    }

    let history = try store.load()
    XCTAssertEqual(history.count, 3)
    XCTAssertEqual(history.flatMap(\.providers), success.providers)
    XCTAssertEqual(history.dropFirst().flatMap(\.failures), [failure("a"), failure("a")])
    XCTAssertTrue(history.dropFirst().allSatisfy { $0.providers.isEmpty })
    XCTAssertEqual(success.providers.first?.metrics.first?.remainingPercent, 60)
  }

  func testAppendFirstFailedSnapshotDoesNotRecordCarriedUsage() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let merged = QuotaSnapshot(
      generatedAt: t0.addingTimeInterval(900),
      providers: [usage("a", at: t0)],
      failures: [failure("a")]
    )
    try store.append(merged)

    let saved = try XCTUnwrap(store.load().first)
    XCTAssertTrue(saved.providers.isEmpty)
    XCTAssertEqual(saved.failures, merged.failures)
    // History filtering must not alter last-known current values.
    XCTAssertEqual(merged.providers.first?.metrics.first?.remainingPercent, 60)
  }

  func testAppendTargetedRefreshDoesNotDuplicateUntouchedSibling() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let initial = QuotaSnapshot(
      generatedAt: t0, providers: [usage("a", at: t0), usage("b", at: t0)], failures: []
    )
    let retry = QuotaSnapshot(
      generatedAt: t0.addingTimeInterval(900),
      providers: [usage("a", at: t0.addingTimeInterval(900), remaining: 50)], failures: []
    )
    let targeted = initial.replacingResults(forAccountIDs: ["a"], from: retry)
    try store.append(initial)
    try store.append(targeted)

    let history = try store.load()
    XCTAssertEqual(history.count, 2)
    XCTAssertEqual(history.last?.providers.map(\.accountID), ["a"])
    XCTAssertEqual(history.flatMap(\.providers).filter { $0.accountID == "b" }.count, 1)
    XCTAssertEqual(history.flatMap(\.providers).filter { $0.accountID == "a" }.count, 2)
    XCTAssertEqual(targeted.providers.count, 2)
  }

  func testAppendKeepsEqualValuedReadingsAtDistinctFetchSeconds() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    for offset in [0.9, 1.1, 900.0] {
      try store.append(QuotaSnapshot(
        generatedAt: t0.addingTimeInterval(1_000),
        providers: [usage("a", at: t0.addingTimeInterval(offset))], failures: []
      ))
    }

    let readings = try store.load().flatMap(\.providers)
    XCTAssertEqual(readings.map(\.fetchedAt), [t0, t0.addingTimeInterval(1), t0.addingTimeInterval(900)])
    XCTAssertEqual(readings.compactMap { $0.metrics.first?.remainingPercent }, [60, 60, 60])
  }

  func testAppendDeduplicatesPersistedAndInMemoryFetchTimes() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let fetchedAt = t0.addingTimeInterval(0.75)
    let initial = QuotaSnapshot(generatedAt: fetchedAt, providers: [usage("a", at: fetchedAt)], failures: [])
    try store.append(initial)
    XCTAssertEqual(try store.load().first?.providers.first?.fetchedAt, t0)

    try store.append(QuotaSnapshot(
      generatedAt: t0.addingTimeInterval(900), providers: initial.providers, failures: []
    ))

    let history = try store.load()
    XCTAssertEqual(history.count, 1)
    XCTAssertEqual(history.flatMap(\.providers).count, 1)
  }

  func testAppendDeduplicatesWithinSnapshotByProviderAccountAndFetchSecond() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let original = usage("a", at: t0)
    var otherProvider = original
    otherProvider.provider = .openAI
    try store.append(QuotaSnapshot(
      generatedAt: t0,
      providers: [original, original, usage("b", at: t0), otherProvider], failures: []
    ))

    let readings = try store.load().flatMap(\.providers)
    XCTAssertEqual(readings.count, 3)
    XCTAssertEqual(Set(readings), Set([original, usage("b", at: t0), otherProvider]))
  }

  func testAppendPreservesExistingArchiveAndArrayFormat() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let success = QuotaSnapshot(version: 7, generatedAt: t0, providers: [usage("a", at: t0)], failures: [])
    let archivedCarry = QuotaSnapshot(
      version: 7, generatedAt: t0.addingTimeInterval(60),
      providers: success.providers, failures: [failure("a")]
    )
    let archive = [success, archivedCarry]
    try store.save(archive)
    try store.append(QuotaSnapshot(
      version: 8, generatedAt: t0.addingTimeInterval(900),
      providers: [usage("a", at: t0.addingTimeInterval(900), remaining: 50)], failures: []
    ))

    let history = try store.load()
    XCTAssertEqual(Array(history.prefix(2)), archive)
    XCTAssertEqual(history.last?.version, 8)
    let data = try Data(contentsOf: dir.appendingPathComponent("history.json"))
    XCTAssertTrue(try JSONSerialization.jsonObject(with: data) is [Any])
  }

  func testAppendNoNewUsageStillPrunesRetention() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let old = QuotaSnapshot(generatedAt: t0.addingTimeInterval(-2 * 86_400), providers: [], failures: [])
    let current = QuotaSnapshot(generatedAt: t0, providers: [usage("a", at: t0)], failures: [])
    try store.save([old, current])
    try store.append(current, keepDays: 1)
    XCTAssertEqual(try store.load(), [current])
  }

  func testAppendDedupePrecedesEntryLimitAndDoesNotResurrectOldUsage() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let oldUsage = usage("a", at: t0.addingTimeInterval(-2 * 86_400))
    let old = QuotaSnapshot(generatedAt: oldUsage.fetchedAt, providers: [oldUsage], failures: [])
    let current = QuotaSnapshot(generatedAt: t0, providers: [usage("b", at: t0)], failures: [])
    try store.save([old, current])

    let refreshed = QuotaSnapshot(
      generatedAt: t0.addingTimeInterval(900),
      providers: [oldUsage, usage("b", at: t0.addingTimeInterval(900))], failures: []
    )
    try store.append(refreshed, keepDays: 1, maxEntries: 1)
    let saved = try XCTUnwrap(store.load().first)
    XCTAssertEqual(saved.providers.map(\.accountID), ["b"])

    // Even after retention removes the original, an expired carry is not new data.
    try store.append(refreshed, keepDays: 1, maxEntries: 1)
    XCTAssertEqual(try store.load(), [saved])
  }

  func testLoadRecentIncludesSourceFetchInsideWindowAfterEarlierSnapshotGeneration() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let cutoff = t0.addingTimeInterval(-86_400)
    let targeted = QuotaSnapshot(
      generatedAt: cutoff.addingTimeInterval(-60),
      providers: [usage("a", at: cutoff.addingTimeInterval(60))], failures: []
    )
    try store.save([targeted])

    XCTAssertEqual(try store.loadRecent(days: 1, now: t0), [targeted])
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
}
