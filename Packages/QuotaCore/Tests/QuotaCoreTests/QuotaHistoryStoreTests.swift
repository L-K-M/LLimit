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
    let corruptData = Data("{\"not a valid json[".utf8)
    try corruptData.write(to: dir.appendingPathComponent("history.json"))

    let loaded = try store.load()
    XCTAssertTrue(loaded.isEmpty, "Corrupted archive should load as empty instead of throwing")

    // Verify next append succeeds
    let snapshot = QuotaSnapshot(generatedAt: Date(), providers: [], failures: [])
    try store.append(snapshot)
    XCTAssertEqual(try store.load().count, 1)
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
}
