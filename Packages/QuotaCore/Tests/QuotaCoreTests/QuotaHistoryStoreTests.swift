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

  // MARK: - No-op appends

  private func makeSnapshot(
    at date: Date,
    fetchedAt: Date,
    failures: [ProviderFailure] = []
  ) -> QuotaSnapshot {
    QuotaSnapshot(
      generatedAt: date,
      providers: [
        ProviderUsage(
          accountID: "a",
          provider: .anthropic,
          title: "Claude",
          metrics: [UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 50)],
          fetchedAt: fetchedAt
        )
      ],
      failures: failures
    )
  }

  func testAppendSkipsASnapshotThatRepeatsTheNewestEntry() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    try store.append(makeSnapshot(at: now, fetchedAt: now))
    // A carried-stale refresh: newer aggregate stamp, identical account content.
    try store.append(makeSnapshot(at: now.addingTimeInterval(1800), fetchedAt: now))

    let loaded = try store.load()
    XCTAssertEqual(loaded.count, 1)
    XCTAssertEqual(loaded.first?.generatedAt, now)
  }

  func testAppendSkipsARepeatedFailureWithNoNewContent() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let failure = ProviderFailure(accountID: "a", provider: .anthropic, kind: .auth, message: "expired")
    try store.append(makeSnapshot(at: now, fetchedAt: now, failures: [failure]))
    try store.append(makeSnapshot(at: now.addingTimeInterval(1800), fetchedAt: now, failures: [failure]))

    XCTAssertEqual(try store.load().count, 1)

    // A genuinely different failure is still recorded.
    let other = ProviderFailure(accountID: "a", provider: .anthropic, kind: .rateLimit, message: "slow down")
    try store.append(makeSnapshot(at: now.addingTimeInterval(3600), fetchedAt: now, failures: [other]))
    XCTAssertEqual(try store.load().count, 2)
  }

  func testAppendKeepsAFreshObservationEvenWhenTheValuesMatch() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    try store.append(makeSnapshot(at: now, fetchedAt: now))
    // Same percentages, but a real fetch: `fetchedAt` moved, so it is new data.
    try store.append(makeSnapshot(at: now.addingTimeInterval(1800), fetchedAt: now.addingTimeInterval(1800)))

    XCTAssertEqual(try store.load().count, 2)
  }
}
