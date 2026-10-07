import XCTest
@testable import QuotaCore

final class QuotaHistoryStoreTests: XCTestCase {
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

  func testAppendDeduplicatesConsecutiveEquivalentSnapshots() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let t1 = Date(timeIntervalSince1970: 1_700_000_000)
    let s1 = QuotaSnapshot(
      generatedAt: t1,
      providers: [
        ProviderUsage(
          accountID: "test-acct",
          provider: .anthropic,
          title: "Claude",
          metrics: [UsageMetric(id: "five_hour", label: "5-hour limit", remainingPercent: 80)],
          fetchedAt: t1
        )
      ],
      failures: []
    )

    try store.append(s1)
    XCTAssertEqual(try store.load().count, 1)

    // Append identical usage with a later timestamp: should be skipped
    let t2 = t1.addingTimeInterval(300)
    let s2 = QuotaSnapshot(
      generatedAt: t2,
      providers: [
        ProviderUsage(
          accountID: "test-acct",
          provider: .anthropic,
          title: "Claude",
          metrics: [UsageMetric(id: "five_hour", label: "5-hour limit", remainingPercent: 80)],
          fetchedAt: t2
        )
      ],
      failures: []
    )
    try store.append(s2)
    XCTAssertEqual(try store.load().count, 1, "Duplicate snapshot must not be appended")

    // Append changed usage: should be appended
    let t3 = t2.addingTimeInterval(300)
    let s3 = QuotaSnapshot(
      generatedAt: t3,
      providers: [
        ProviderUsage(
          accountID: "test-acct",
          provider: .anthropic,
          title: "Claude",
          metrics: [UsageMetric(id: "five_hour", label: "5-hour limit", remainingPercent: 75)],
          fetchedAt: t3
        )
      ],
      failures: []
    )
    try store.append(s3)
    XCTAssertEqual(try store.load().count, 2, "Changed snapshot must be appended")
  }

  func testLoadRecoversFromCorruptFile() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let historyURL = dir.appendingPathComponent("history.json")
    let corruptData = Data("{\"not a valid json[".utf8)
    try corruptData.write(to: historyURL)

    let loaded = try store.load()
    XCTAssertTrue(loaded.isEmpty, "Corrupted archive should load as empty instead of throwing")

    var leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    XCTAssertTrue(leftovers.contains { $0.hasPrefix("history.corrupt-") },
                  "Corrupt file should be quarantined under a .corrupt- name")
    XCTAssertFalse(FileManager.default.fileExists(atPath: historyURL.path))

    // Verify next append succeeds
    let snapshot = QuotaSnapshot(generatedAt: Date(), providers: [], failures: [])
    try store.append(snapshot)
    XCTAssertEqual(try store.load().count, 1)

    // A second corruption must produce a distinct quarantine name.
    try corruptData.write(to: historyURL)
    XCTAssertTrue(try store.load().isEmpty)
    leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    XCTAssertEqual(leftovers.filter { $0.hasPrefix("history.corrupt-") }.count, 2)
  }

  func testDeduplicatedAppendStillPrunesExpiredEntries() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let metric = UsageMetric(id: "five_hour", label: "5-hour limit", remainingPercent: 80)
    let usage = ProviderUsage(
      accountID: "test-acct", provider: .anthropic, title: "Claude",
      metrics: [metric], fetchedAt: now
    )

    let expired = QuotaSnapshot(
      generatedAt: now.addingTimeInterval(-50 * 86_400), providers: [usage], failures: []
    )
    let fresh = QuotaSnapshot(generatedAt: now, providers: [usage], failures: [])
    try store.save([expired, fresh])

    // Appending an equivalent snapshot must not append, but must still drop the
    // entry that aged past keepDays.
    let duplicate = QuotaSnapshot(
      generatedAt: now.addingTimeInterval(300), providers: [usage], failures: []
    )
    try store.append(duplicate, keepDays: 45)

    let loaded = try store.load()
    XCTAssertEqual(loaded.count, 1)
    XCTAssertEqual(loaded.first?.generatedAt, now)
  }

  func testTitleOrLabelChangeBreaksDedupe() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let usage = ProviderUsage(
      accountID: "a", provider: .anthropic, title: "Claude",
      metrics: [UsageMetric(id: "five_hour", label: "5-hour", remainingPercent: 80)],
      fetchedAt: now
    )
    try store.append(QuotaSnapshot(generatedAt: now, providers: [usage], failures: []))

    // Same numbers, different display names: a rename must be recorded.
    let renamed = ProviderUsage(
      accountID: "a", provider: .anthropic, title: "Claude Work",
      metrics: [UsageMetric(id: "five_hour", label: "Session limit", remainingPercent: 80)],
      fetchedAt: now.addingTimeInterval(300)
    )
    try store.append(QuotaSnapshot(
      generatedAt: now.addingTimeInterval(300), providers: [renamed], failures: []
    ))

    XCTAssertEqual(try store.load().count, 2,
                   "Title/label changes are real history, not duplicates")
  }

  func testQuarantineKeepsOnlyNewestCorruptFiles() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let historyURL = dir.appendingPathComponent("history.json")
    let corruptData = Data("{\"bad[".utf8)

    for _ in 0..<8 {
      try corruptData.write(to: historyURL)
      XCTAssertTrue(try store.load().isEmpty)
    }

    let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
      .filter { $0.hasPrefix("history.corrupt-") }
    XCTAssertEqual(leftovers.count, 5,
                   "Quarantine must be bounded; oldest corrupt files are dropped")
  }

  func testStoragePermissionsAre0600() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    try store.save([QuotaSnapshot(generatedAt: Date(), providers: [], failures: [])])
    let historyURL = dir.appendingPathComponent("history.json")
    let attrs = try FileManager.default.attributesOfItem(atPath: historyURL.path)
    let perms = attrs[.posixPermissions] as? Int
    XCTAssertEqual(perms, 0o600, "History file permissions must be 0600")
  }

  func testUnreadableHistoryIsQuarantinedNotOverwritten() throws {
    let (store, dir) = makeStore()
    defer {
      // Restore readability so cleanup succeeds.
      let url = dir.appendingPathComponent("history.json")
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      try? FileManager.default.removeItem(at: dir)
    }

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    try store.save([QuotaSnapshot(generatedAt: now, providers: [], failures: [])])
    let historyURL = dir.appendingPathComponent("history.json")

    // Make the file unreadable (skipped implicitly when running as root,
    // where chmod 000 still permits reads).
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: historyURL.path)

    let loaded = try store.load()
    XCTAssertTrue(loaded.isEmpty)

    let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    XCTAssertTrue(leftovers.contains { $0.hasPrefix("history.corrupt-") },
                  "Unreadable history must be quarantined, not silently swallowed")
    XCTAssertFalse(FileManager.default.fileExists(atPath: historyURL.path))
  }

  func testDedupeIsInsensitiveToProviderAndMetricOrder() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let usageA = ProviderUsage(
      accountID: "a", provider: .anthropic, title: "Claude",
      metrics: [
        UsageMetric(id: "five_hour", label: "5-hour", remainingPercent: 80),
        UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 60)
      ],
      fetchedAt: now
    )
    let usageB = ProviderUsage(
      accountID: "b", provider: .openAI, title: "OpenAI",
      metrics: [UsageMetric(id: "monthly", label: "Monthly", remainingPercent: 50)],
      fetchedAt: now
    )
    try store.append(QuotaSnapshot(
      generatedAt: now, providers: [usageA, usageB], failures: []
    ))

    // Same data, reversed provider and metric order: still a duplicate.
    let reorderedA = ProviderUsage(
      accountID: "a", provider: .anthropic, title: "Claude",
      metrics: [usageA.metrics[1], usageA.metrics[0]],
      fetchedAt: now.addingTimeInterval(300)
    )
    try store.append(QuotaSnapshot(
      generatedAt: now.addingTimeInterval(300), providers: [usageB, reorderedA], failures: []
    ))

    XCTAssertEqual(try store.load().count, 1,
                   "Reordered but identical usage must still deduplicate")
  }

  func testSaveSweepsStaleStagingTemps() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // Simulate a temp file abandoned by a crashed writer an hour ago.
    let stale = dir.appendingPathComponent(".history.json.\(UUID().uuidString).tmp")
    try Data("stale".utf8).write(to: stale)
    let old = Date().addingTimeInterval(-7_200)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: stale.path)
    // A fresh temp must survive the sweep (concurrent writer mid-save).
    let fresh = dir.appendingPathComponent(".history.json.\(UUID().uuidString).tmp")
    try Data("fresh".utf8).write(to: fresh)

    try store.save([QuotaSnapshot(generatedAt: Date(), providers: [], failures: [])])

    let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    XCTAssertFalse(entries.contains(stale.lastPathComponent),
                   "Hour-old staging temp must be swept")
    XCTAssertTrue(entries.contains(fresh.lastPathComponent),
                  "Fresh staging temp belongs to a live writer; keep it")
  }
}
