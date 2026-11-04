import Foundation
import XCTest
@testable import QuotaCore

final class BenchmarkDraftStoreTests: XCTestCase {
  private var root: URL!
  private var fileURL: URL { root.appendingPathComponent("benchmark-draft.json") }
  private var store: BenchmarkDraftStore { BenchmarkDraftStore(fileURL: fileURL) }

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("llimit-draft-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDownWithError() throws {
    if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
  }

  private func incompletePlan() -> BenchmarkPlan {
    BenchmarkPlan(taskPrompt: "Private unfinished task with a literal 2.", rubric: "", repositoryPath: "",
      candidates: [BenchmarkCandidate(name: "MiMo 2.6", command: BenchmarkCommand(executable: "", arguments: ["--model", "mimo-v2.6"]))],
      judges: [])
  }

  func testIncompleteSetupRoundTripsWithoutValidationOrRedaction() throws {
    let plan = incompletePlan()
    XCTAssertThrowsError(try plan.validated())
    try store.save(plan)
    XCTAssertEqual(try store.load(), plan)
    let encoded = String(decoding: try Data(contentsOf: fileURL), as: UTF8.self)
    XCTAssertTrue(encoded.contains("MiMo 2.6"))
    XCTAssertFalse(encoded.contains("[redacted]"))
  }

  func testSavesPrivatePermissionsAndRestrictsExistingParent() throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o755])
    try store.save(incompletePlan())
    XCTAssertEqual(try permissions(root), 0o700)
    XCTAssertEqual(try permissions(fileURL), 0o600)
  }

  func testAtomicUpdateAndEncodingFailurePreserveLastCommittedDraft() throws {
    var plan = incompletePlan()
    try store.save(plan)
    plan.taskPrompt = "Updated task"
    try store.save(plan)
    XCTAssertEqual(try store.load(), plan)
    let committed = try Data(contentsOf: fileURL)
    plan.timeoutSeconds = .nan
    XCTAssertThrowsError(try store.save(plan))
    XCTAssertEqual(try Data(contentsOf: fileURL), committed)
    XCTAssertEqual(try permissions(fileURL), 0o600)
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".tmp") })
  }

  func testOnlyMissingFileIsAnAbsentDraft() throws {
    XCTAssertNil(try store.load())
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true)
    XCTAssertThrowsError(try store.load())
  }

  func testMalformedDraftIsReportedAndLeftUntouched() throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let malformed = Data("unfinished invalid JSON".utf8)
    try malformed.write(to: fileURL)
    XCTAssertThrowsError(try store.load())
    XCTAssertEqual(try Data(contentsOf: fileURL), malformed)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [fileURL.lastPathComponent])
  }

  func testDraftIsSeparateFromReportHistory() throws {
    let plan = incompletePlan()
    try store.save(plan)
    let reports = BenchmarkReportStore(directory: root.appendingPathComponent("Benchmarks", isDirectory: true))
    XCTAssertTrue(try reports.list().isEmpty)
    XCTAssertEqual(try store.load(), plan)
  }

  private func permissions(_ url: URL) throws -> Int? {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
  }
}
