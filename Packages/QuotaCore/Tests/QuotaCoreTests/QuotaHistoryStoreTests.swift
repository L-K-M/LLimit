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

  func testRemoveWithoutMatchLeavesArchiveUntouched() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("history.json")

    // Nothing to purge must not create an archive.
    try store.remove(accountIDs: ["absent"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

    // Pretty-printed bytes differ from the store's compact encoding, so any
    // rewrite would show up as changed bytes.
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let original = try encoder.encode([snapshot(at: now, accountIDs: ["keep-me"], failedAccountIDs: ["failed"])])
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try original.write(to: url)

    try store.remove(accountIDs: ["absent"])
    XCTAssertEqual(try Data(contentsOf: url), original)

    // A match in failures alone still counts.
    try store.remove(accountIDs: ["failed"])
    let loaded = try XCTUnwrap(store.load().first)
    XCTAssertTrue(loaded.failures.isEmpty)
    XCTAssertEqual(loaded.providers.map(\.accountID), ["keep-me"])
  }

  func testPublishPathDecodesArchiveOnce() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let decoder = CountingDecoder()
    let localURL = dir.appendingPathComponent("local/history.json")
    let mirrorURL = dir.appendingPathComponent("group/history.json")
    let store = QuotaHistoryStore(fileURL: localURL, decoder: decoder)
    let mirror = QuotaHistoryStore(fileURL: mirrorURL, decoder: decoder)

    // A full archive: 3,000 refreshes 15 minutes apart, the shortest interval.
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let interval: TimeInterval = 15 * 60
    try store.save((1...3_000).map { snapshot(at: now.addingTimeInterval(-Double($0) * interval), accountIDs: ["a", "b"]) })
    // An unreadable widget copy with a private mode, both repaired by the mirror.
    try FileManager.default.createDirectory(at: mirrorURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: mirrorURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mirrorURL.path)
    decoder.archiveDecodes = 0

    // The app's publish: append the refresh, derive the dashboard's recent slice,
    // then mirror the archive into the widget copy.
    let archive = try store.append(snapshot(at: now, accountIDs: ["a", "b"]))
    let recent = QuotaHistoryStore.recent(archive.snapshots, days: 2, now: now)
    try mirror.save(archive)

    XCTAssertEqual(decoder.archiveDecodes, 1)
    XCTAssertEqual(archive.snapshots.count, 3_000)
    XCTAssertEqual(archive.snapshots.first?.generatedAt, now.addingTimeInterval(-2_999 * interval))
    // 48 hours of 15-minute refreshes plus the new one.
    XCTAssertEqual(recent.count, 193)
    XCTAssertEqual(recent.last?.generatedAt, now)

    XCTAssertEqual(try Data(contentsOf: mirrorURL), try Data(contentsOf: localURL))
    let mode = try FileManager.default.attributesOfItem(atPath: mirrorURL.path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(mode?.intValue, 0o644)
  }

  func testAppendReturnsTheArchiveItWrote() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    // Out of order, with one entry past retention and more than the cap.
    let offsets: [Double] = [3, 1, 10, 2, 4, 0.5]
    try store.save(offsets.map { snapshot(at: now.addingTimeInterval(-$0 * 86_400), accountIDs: ["a"]) })

    let archive = try store.append(snapshot(at: now, accountIDs: ["a"]), keepDays: 5, maxEntries: 4)

    XCTAssertEqual(archive.snapshots, try store.load())
    XCTAssertEqual(archive.snapshots.map(\.generatedAt), [2, 1, 0.5, 0].map { now.addingTimeInterval(-$0 * 86_400) })
    XCTAssertEqual(
      QuotaHistoryStore.recent(archive.snapshots, days: 2, now: now),
      try store.loadRecent(days: 2, now: now)
    )
  }

  func testBackdatedAppendIsWrittenOldestFirstAndTrimsTheOldest() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let hoursAgo = { (hours: Double) in now.addingTimeInterval(-hours * 3_600) }
    try store.save([4, 3, 2, 1].map { snapshot(at: hoursAgo($0), accountIDs: ["a"]) })

    // Older than the newest stored entry, as after the clock steps back.
    let archive = try store.append(snapshot(at: hoursAgo(2.5), accountIDs: ["a"]), maxEntries: 4)

    // An unsorted trim would keep 3, 2, 1, 2.5 hours ago.
    let expected = [3, 2.5, 2, 1].map(hoursAgo)
    XCTAssertEqual(archive.snapshots.map(\.generatedAt), expected)
    // `load` returns the file's order without sorting.
    XCTAssertEqual(try store.load().map(\.generatedAt), expected)
  }

  func testAppendReplacesAnUnreadableFileOnlyWhenAsked() throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("history.json")
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let refresh = snapshot(at: now, accountIDs: ["a"])

    let corrupt = Data("not json".utf8)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try corrupt.write(to: url)

    // A primary archive keeps its unreadable file for inspection or repair.
    XCTAssertThrowsError(try store.append(refresh)) { XCTAssertTrue($0 is DecodingError) }
    XCTAssertEqual(try Data(contentsOf: url), corrupt)

    // A derived copy starts over from the refresh.
    let archive = try store.append(refresh, ifUnreadable: .replace)
    XCTAssertEqual(archive.snapshots, [refresh])
    XCTAssertEqual(try store.load(), [refresh])

    // Only decode failures are replaced; an unreadable path still throws.
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    XCTAssertThrowsError(try store.append(refresh, ifUnreadable: .replace)) { XCTAssertFalse($0 is DecodingError) }
  }

  func testRecentHonorsCutoffAndCap() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let hours: [Double] = [5, 49, 1, 30, 47, 0]
    let history = hours.map { snapshot(at: now.addingTimeInterval(-$0 * 3_600), accountIDs: ["a"]) }

    let windowed = QuotaHistoryStore.recent(history, days: 2, now: now)
    XCTAssertEqual(windowed.map(\.generatedAt), [47, 30, 5, 1, 0].map { now.addingTimeInterval(-$0 * 3_600) })

    let capped = QuotaHistoryStore.recent(history, days: 2, now: now, maxEntries: 2)
    XCTAssertEqual(capped.map(\.generatedAt), [1, 0].map { now.addingTimeInterval(-$0 * 3_600) })
  }

  private func snapshot(at date: Date, accountIDs: [String], failedAccountIDs: [String] = []) -> QuotaSnapshot {
    QuotaSnapshot(
      generatedAt: date,
      providers: accountIDs.map { id in
        ProviderUsage(
          accountID: id,
          provider: .anthropic,
          title: "Claude",
          metrics: [UsageMetric(id: "weekly", label: "Weekly limit", remainingPercent: 60)],
          fetchedAt: date
        )
      },
      failures: failedAccountIDs.map { id in
        ProviderFailure(accountID: id, provider: .anthropic, kind: .auth, message: "failed")
      }
    )
  }
}

/// Counts top-level decodes; the store decodes the whole archive in one call.
private final class CountingDecoder: JSONDecoder, @unchecked Sendable {
  var archiveDecodes = 0

  override func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    archiveDecodes += 1
    return try super.decode(type, from: data)
  }
}
