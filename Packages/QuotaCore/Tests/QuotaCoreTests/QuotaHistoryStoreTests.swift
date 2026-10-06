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

  private let fixedReset = Date(timeIntervalSince1970: 1_800_000_000)

  private func snapshot(at now: Date, percent: Int, fetchedAt: Date? = nil, resetIn: String? = nil) -> QuotaSnapshot {
    QuotaSnapshot(
      generatedAt: now,
      providers: [
        ProviderUsage(
          accountID: "acct",
          provider: .anthropic,
          title: "Claude",
          metrics: [
            UsageMetric(id: "session", label: "Session", remainingPercent: percent,
                        resetAt: fixedReset, resetIn: resetIn)
          ],
          maxUsagePercent: 100 - percent,
          fetchedAt: fetchedAt ?? now
        )
      ],
      failures: []
    )
  }

  func testAppendSkipsUnchangedSnapshots() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    try store.append(snapshot(at: now, percent: 70))
    // Timestamps and the derived countdown text move every cycle; content does not.
    try store.append(snapshot(at: now.addingTimeInterval(900), percent: 70,
                              fetchedAt: now.addingTimeInterval(900), resetIn: "in 2h 45m"))
    try store.append(snapshot(at: now.addingTimeInterval(1_800), percent: 70,
                              fetchedAt: now.addingTimeInterval(1_800), resetIn: "in 2h 30m"))
    XCTAssertEqual(try store.load().count, 1)

    // A real change records a new point — and dedup resumes from there.
    try store.append(snapshot(at: now.addingTimeInterval(2_700), percent: 60,
                              fetchedAt: now.addingTimeInterval(2_700)))
    try store.append(snapshot(at: now.addingTimeInterval(3_600), percent: 60,
                              fetchedAt: now.addingTimeInterval(3_600), resetIn: "in 2h"))
    XCTAssertEqual(try store.load().count, 2)
    XCTAssertEqual(try store.load().last?.generatedAt, now.addingTimeInterval(2_700))
  }
}
