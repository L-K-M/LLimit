import XCTest
@testable import QuotaCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

final class StoreSafetyTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("llimit-store-safety-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  func testAllStoresReplaceLooseFilesWithOwnerOnlyFiles() throws {
    let settingsURL = directory.appendingPathComponent("settings.json")
    let snapshotURL = directory.appendingPathComponent("snapshot.json")
    let historyURL = directory.appendingPathComponent("history.json")
    let urls = [settingsURL, snapshotURL, historyURL]
    for url in urls {
      XCTAssertTrue(FileManager.default.createFile(
        atPath: url.path, contents: Data("{}".utf8), attributes: [.posixPermissions: 0o644]))
    }

    let snapshot = QuotaSnapshot(generatedAt: Date(), providers: [], failures: [])
    try SettingsStore(fileURL: settingsURL).save(.default)
    try SnapshotStore(fileURL: snapshotURL).save(snapshot)
    try QuotaHistoryStore(fileURL: historyURL).save([snapshot])

    for url in urls {
      XCTAssertEqual(try modeBits(url), 0o600, url.lastPathComponent)
      XCTAssertEqual(try modeBits(url.appendingPathExtension("access.lock")), 0o600)
    }
    XCTAssertEqual(try artifacts().count, urls.count)
  }

  func testCorruptStoresPreserveEachQuarantineAndRecover() throws {
    for name in ["snapshot.json", "history.json"] {
      let url = directory.appendingPathComponent(name)
      let first = Data("first malformed document".utf8)
      let second = Data("second malformed document".utf8)

      try first.write(to: url)
      try assertRecoveredStore(at: url)
      XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

      try second.write(to: url)
      try assertRecoveredStore(at: url)
      let quarantines = try artifacts().filter { $0.lastPathComponent.hasPrefix(name + ".corrupt-") }
      XCTAssertEqual(quarantines.count, 2)
      XCTAssertEqual(Set(try quarantines.map { try Data(contentsOf: $0) }), [first, second])
      for quarantine in quarantines {
        XCTAssertEqual(try modeBits(quarantine), 0o600)
      }
    }
  }

  func testQuarantineRetentionKeepsNewestFiveDocuments() throws {
    let url = directory.appendingPathComponent("history.json")
    for index in 0..<7 {
      try Data("invalid document \(index)".utf8).write(to: url)
      try assertRecoveredStore(at: url)
    }

    let quarantines = try artifacts().filter { $0.lastPathComponent.hasPrefix("history.json.corrupt-") }
    XCTAssertEqual(quarantines.count, 5)
    XCTAssertEqual(Set(try quarantines.map { try String(contentsOf: $0, encoding: .utf8) }),
                   Set((2..<7).map { "invalid document \($0)" }))
  }

  func testReadErrorsNeverQuarantineOrReplaceTheOriginal() throws {
    try XCTSkipIf(geteuid() == 0, "root bypasses file permissions")
    let url = directory.appendingPathComponent("history.json")
    let original = Data("[]".utf8)
    try original.write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }

    let store = QuotaHistoryStore(fileURL: url)
    XCTAssertThrowsError(try store.load())
    XCTAssertThrowsError(try store.append(QuotaSnapshot(generatedAt: Date(), providers: [], failures: [])))
    XCTAssertEqual(try artifacts().map(\.lastPathComponent), ["history.json"])

    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    XCTAssertEqual(try Data(contentsOf: url), original)
  }

  func testNewestQuarantineSurvivesClockSkewWithoutExceedingRetention() throws {
    let url = directory.appendingPathComponent("history.json")
    for index in 0..<5 {
      try Data("old invalid document \(index)".utf8).write(to: url)
      try assertRecoveredStore(at: url)
    }
    for artifact in try artifacts() {
      try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(3_600)], ofItemAtPath: artifact.path)
    }

    let current = Data("new invalid document".utf8)
    try current.write(to: url)
    try assertRecoveredStore(at: url)

    let quarantines = try artifacts()
    XCTAssertEqual(quarantines.count, 5)
    XCTAssertTrue(try quarantines.contains { try Data(contentsOf: $0) == current })
  }

  func testFailedQuarantineDoesNotReportAnEmptyStore() throws {
    try XCTSkipIf(geteuid() == 0, "root bypasses directory permissions")
    let url = directory.appendingPathComponent("snapshot.json")
    let original = Data("malformed".utf8)
    try original.write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

    XCTAssertThrowsError(try SnapshotStore(fileURL: url).load(policy: .recover))
    XCTAssertEqual(try Data(contentsOf: url), original)
    XCTAssertEqual(try artifacts().map(\.lastPathComponent), ["snapshot.json"])
  }

  func testQuarantinePruningLeavesSimilarlyNamedUserFilesUntouched() throws {
    let notes = directory.appendingPathComponent("history.json.corrupt-notes")
    let contents = Data("keep these diagnostic notes".utf8)
    try contents.write(to: notes)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: notes.path)
    let url = directory.appendingPathComponent("history.json")
    for index in 0..<6 {
      try Data("invalid \(index)".utf8).write(to: url)
      try assertRecoveredStore(at: url)
    }

    XCTAssertTrue(FileManager.default.fileExists(atPath: notes.path))
    XCTAssertEqual(try Data(contentsOf: notes), contents)
  }

  func testFailedSaveLeavesExistingCredentialBytesUntouched() throws {
    try XCTSkipIf(geteuid() == 0, "root bypasses directory permissions")
    let url = directory.appendingPathComponent("settings.json")
    let store = SettingsStore(fileURL: url)
    try store.save(.default)
    let original = try Data(contentsOf: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

    XCTAssertThrowsError(try store.save(AppSettings(refreshIntervalMinutes: 60)))
    XCTAssertEqual(try Data(contentsOf: url), original)
    XCTAssertEqual(try modeBits(url), 0o600)
  }

  func testDisplayReadsLeaveCorruptFilesAndPermissionsUntouched() throws {
    let original = Data("malformed display document".utf8)
    for name in ["snapshot.json", "history.json"] {
      let url = directory.appendingPathComponent(name)
      try original.write(to: url)
      let before = try FileManager.default.attributesOfItem(atPath: url.path)

      if name == "snapshot.json" {
        XCTAssertThrowsError(try SnapshotStore(fileURL: url).load())
      } else {
        XCTAssertThrowsError(try QuotaHistoryStore(fileURL: url).load())
      }

      XCTAssertEqual(try Data(contentsOf: url), original)
      let after = try FileManager.default.attributesOfItem(atPath: url.path)
      XCTAssertEqual(before[.posixPermissions] as? NSNumber, after[.posixPermissions] as? NSNumber)
      XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
    }
    XCTAssertEqual(Set(try artifacts().map(\.lastPathComponent)), ["snapshot.json", "history.json"])
  }

  func testCredentialIntermediatesAreOwnerOnlyFromCreation() async throws {
    let settings = AppSettings(accounts: (0..<2_000).map { index in
      ProviderAccount(provider: .openAI, displayName: "Account \(index)", isEnabled: true,
                      credentials: [CredentialField.openAIAccessToken: String(repeating: "a", count: 1_024),
                                    CredentialField.openAIRefreshToken: String(repeating: "b", count: 1_024)])
    })
    let sampler = StoreModeSampler()
    let directory = try XCTUnwrap(self.directory)
    let samplerTask = Task {
      while !Task.isCancelled {
        let urls = (try? FileManager.default.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.lastPathComponent != "settings.json"
          && !url.lastPathComponent.hasSuffix(".access.lock") {
          if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
             let mode = attributes[.posixPermissions] as? NSNumber {
            await sampler.record(mode.intValue & 0o777)
          }
        }
      }
    }
    defer { samplerTask.cancel() }

    try SettingsStore(fileURL: directory.appendingPathComponent("settings.json")).save(settings)
    samplerTask.cancel()
    await samplerTask.value
    let observed = await sampler.observed
    guard !observed.isEmpty else { throw XCTSkip("No intermediate file observed") }
    for mode in observed {
      XCTAssertEqual(mode & ~0o600, 0, "intermediate mode 0o\(String(mode, radix: 8))")
    }
  }

  private func assertRecoveredStore(at url: URL) throws {
    if url.lastPathComponent == "snapshot.json" {
      XCTAssertNil(try SnapshotStore(fileURL: url).load(policy: .recover))
    } else {
      XCTAssertEqual(try QuotaHistoryStore(fileURL: url).load(policy: .recover), [])
    }
  }

  private func artifacts() throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { !$0.lastPathComponent.hasSuffix(".access.lock") }
  }

  private func modeBits(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
  }
}

private actor StoreModeSampler {
  private(set) var observed: Set<Int> = []
  func record(_ mode: Int) { observed.insert(mode) }
}
