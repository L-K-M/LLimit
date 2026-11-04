import XCTest
@testable import QuotaCore

final class BenchmarkTimeoutTests: XCTestCase {

  // MARK: - Plan validation

  private func plan(timeout: Double = 600) -> BenchmarkPlan {
    BenchmarkPlan(
      taskPrompt: "Fix the bug.",
      rubric: "Pass tests.",
      repositoryPath: "/tmp/repo",
      timeoutSeconds: timeout,
      candidates: [BenchmarkCandidate(name: "A", command: BenchmarkCommand(executable: "/bin/echo"))],
      judges: [
        BenchmarkJudge(name: "J1", command: BenchmarkCommand(executable: "/bin/echo")),
        BenchmarkJudge(name: "J2", command: BenchmarkCommand(executable: "/bin/echo"))
      ]
    )
  }

  func testMaximumTimeoutConstant() throws {
    XCTAssertEqual(BenchmarkPlan.maximumTimeoutSeconds, 86_400)
  }

  func testValidationAcceptsThreeHours() throws {
    let p = plan(timeout: 10_800)
    XCTAssertNoThrow(try p.validated())
  }

  func testValidationAcceptsFullDay() throws {
    let p = plan(timeout: 86_400)
    XCTAssertNoThrow(try p.validated())
  }

  func testValidationRejectsZero() throws {
    let p = plan(timeout: 0)
    XCTAssertThrowsError(try p.validated())
  }

  func testValidationRejectsAboveMaximum() throws {
    let p = plan(timeout: 86_401)
    XCTAssertThrowsError(try p.validated())
  }

  func testValidationRejectsNaN() throws {
    let p = plan(timeout: .nan)
    XCTAssertThrowsError(try p.validated())
  }

  func testValidationRejectsInfinity() throws {
    let p = plan(timeout: .infinity)
    XCTAssertThrowsError(try p.validated())
  }

  func testValidationMessageMentionsRange() throws {
    let p = plan(timeout: 86_401)
    do {
      _ = try p.validated()
      XCTFail("Expected error")
    } catch let error as BenchmarkValidationError {
      let message = error.errorDescription ?? ""
      XCTAssertTrue(message.contains("1") && message.contains("86,400"),
                    "Validation message should mention 1 to 86,400 seconds: \(message)")
    }
  }

  // MARK: - Process run guard

  private var directory: URL!

  override func setUp() {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("llimit-benchmark-timeout-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: directory)
  }

  func testProcessRunAcceptsThreeHours() async throws {
    let process = BenchmarkProcess()
    let result = try await process.run(
      executable: URL(fileURLWithPath: "/usr/bin/true"),
      arguments: [],
      directory: directory,
      timeout: 10_800
    )
    XCTAssertEqual(result.status, 0)
  }

  func testProcessRunRejectsAboveMaximum() async throws {
    let process = BenchmarkProcess()
    do {
      _ = try await process.run(
        executable: URL(fileURLWithPath: "/usr/bin/true"),
        arguments: [],
        directory: directory,
        timeout: 86_401
      )
      XCTFail("Expected error for timeout above maximum")
    } catch BenchmarkProcessError.invalidInput {
      // Expected
    }
  }

  func testProcessRunTrueWithHighTimeoutReturnsImmediately() async throws {
    let process = BenchmarkProcess()
    let start = Date()
    let result = try await process.run(
      executable: URL(fileURLWithPath: "/usr/bin/true"),
      arguments: [],
      directory: directory,
      timeout: 10_800
    )
    let elapsed = -start.timeIntervalSinceNow
    XCTAssertEqual(result.status, 0)
    XCTAssertLessThan(elapsed, 5, "Running /usr/bin/true should return immediately")
  }
}
