import XCTest
@testable import QuotaCore

final class StoreConcurrencyTests: XCTestCase {
  func testRecoveryCannotQuarantineAConcurrentValidReplacement() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.json")
    let corrupt = Data("malformed".utf8)
    try corrupt.write(to: url)
    let decoder = PausingStoreDecoder()
    let recovering = QuotaHistoryStore(fileURL: url, decoder: decoder)
    let replacement = [QuotaSnapshot(generatedAt: Date(timeIntervalSince1970: 1_700_000_000), providers: [], failures: [])]

    let recovery = Task.detached { try recovering.load(policy: .recover) }
    guard decoder.read.wait(timeout: .now() + 5) == .success else {
      decoder.resume.signal()
      return XCTFail("Recovery never read the original bytes")
    }
    let finished = StoreCompletion()
    let writer = Task.detached {
      try QuotaHistoryStore(fileURL: url).save(replacement)
      await finished.mark()
    }
    try await Task.sleep(nanoseconds: 50_000_000)
    let completedEarly = await finished.done
    decoder.resume.signal()
    _ = try await recovery.value
    try await writer.value

    XCTAssertFalse(completedEarly, "A replacement must wait for read/decode/quarantine")
    XCTAssertEqual(try QuotaHistoryStore(fileURL: url).load(), replacement)
    let quarantines = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix("history.json.corrupt-") }
    XCTAssertEqual(quarantines.count, 1)
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(quarantines.first)), corrupt)
  }

  func testConcurrentAppendsKeepBothObservations() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.json")
    try QuotaHistoryStore(fileURL: url).save([])
    let decoder = PausingStoreDecoder()
    let firstStore = QuotaHistoryStore(fileURL: url, decoder: decoder)
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let first = observation(accountID: "first", at: now)
    let second = observation(accountID: "second", at: now.addingTimeInterval(1))

    let firstAppend = Task.detached { try firstStore.append(first) }
    guard decoder.read.wait(timeout: .now() + 5) == .success else {
      decoder.resume.signal()
      return XCTFail("Append never read the archive")
    }
    let secondAppend = Task.detached { try QuotaHistoryStore(fileURL: url).append(second) }
    try await Task.sleep(nanoseconds: 50_000_000)
    decoder.resume.signal()
    try await firstAppend.value
    try await secondAppend.value

    XCTAssertEqual(try QuotaHistoryStore(fileURL: url).load(), [first, second])
  }

  private func observation(accountID: String, at date: Date) -> QuotaSnapshot {
    QuotaSnapshot(generatedAt: date, providers: [
      ProviderUsage(accountID: accountID, provider: .anthropic, title: accountID,
                    metrics: [UsageMetric(id: "five_hour", label: "5-hour limit", remainingPercent: 50)],
                    fetchedAt: date)
    ], failures: [])
  }
}

private actor StoreCompletion {
  private(set) var done = false
  func mark() { done = true }
}

private final class PausingStoreDecoder: JSONDecoder, @unchecked Sendable {
  let read = DispatchSemaphore(value: 0)
  let resume = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var shouldPause = true

  override func decode<T>(_ type: T.Type, from data: Data) throws -> T where T: Decodable {
    lock.lock()
    let pause = shouldPause
    shouldPause = false
    lock.unlock()
    if pause {
      read.signal()
      guard resume.wait(timeout: .now() + 5) == .success else {
        throw CocoaError(.fileReadUnknown)
      }
    }
    return try super.decode(type, from: data)
  }
}
