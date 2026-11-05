import Foundation
import XCTest
@testable import QuotaCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

final class BenchmarkProcessTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("llimit-benchmark-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: directory)
  }

  private func shell(_ script: String, input: String? = nil, timeout: Double = 5) async throws -> BenchmarkProcessResult {
    try await BenchmarkProcess().run(
      executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
      directory: directory, input: input, timeout: timeout)
  }

  func testCapturesStdinSeparateStreamsAndExitStatus() async throws {
    let result = try await shell("cat; printf 'problem' >&2; exit 7", input: "task\n")
    XCTAssertEqual(result.stdout, "task\n")
    XCTAssertEqual(result.stderr, "problem")
    XCTAssertEqual(result.status, 7)
    XCTAssertFalse(result.timedOut)
  }

  func testAppliesWorkingDirectoryWithoutChangingHostDirectory() async throws {
    let previous = FileManager.default.currentDirectoryPath
    let result = try await shell("pwd")
    let reported = URL(fileURLWithPath: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    XCTAssertEqual(reported.resolvingSymlinksInPath().path, directory.resolvingSymlinksInPath().path)
    XCTAssertEqual(FileManager.default.currentDirectoryPath, previous)
  }

  // Full stdout exceeding pipe capacity is preserved; stderr is bounded as a diagnostic preview.
  func testLargeStdoutExceedingPipeCapacityIsPreserved() async throws {
    // Generate 3 MiB on stdout, 3 MiB on stderr.
    let size = 3 * 1_024 * 1_024
    let result = try await shell("""
      dd if=/dev/zero bs=1024 count=\(size / 1024) 2>/dev/null | tr '\\0' A
      dd if=/dev/zero bs=1024 count=\(size / 1024) 2>/dev/null | tr '\\0' E >&2
      """, timeout: 15)
    XCTAssertEqual(result.status, 0)
    XCTAssertFalse(result.timedOut)
    // Stdout must be fully preserved regardless of volume.
    XCTAssertEqual(result.stdout.utf8.count, size,
      "Full stdout must be preserved even when it exceeds pipe capacity")
    // Stderr is bounded as a diagnostic preview.
    XCTAssertLessThanOrEqual(result.stderr.utf8.count, 65_536,
      "Stderr should be bounded to a diagnostic preview")
    XCTAssertTrue(result.stderrTruncated)
  }

  // Regression: full plain-text output exceeding 2 MiB must be preserved.
  func testLargePlainTextOutputIsPreserved() async throws {
    let size = 2 * 1_024 * 1_024 + 512 * 1_024
    let result = try await shell("dd if=/dev/zero bs=1024 count=\(size / 1024) 2>/dev/null | tr '\\0' A", timeout: 15)
    XCTAssertEqual(result.status, 0)
    XCTAssertFalse(result.timedOut)
    XCTAssertEqual(result.stdout.utf8.count, size,
      "Full output must be preserved without loss")
  }

  // Regression: valid JSON followed by >2 MiB of whitespace must remain parseable.
  func testJsonPrefixWithLargeTrailingWhitespaceIsPreserved() async throws {
    let json = #"{"status":"ok"}"#
    let padding = 2 * 1_024 * 1_024 + 256 * 1_024
    let result = try await shell("""
      printf '%s' '\(json)'
      dd if=/dev/zero bs=1024 count=\(padding / 1024) 2>/dev/null | tr '\\0' ' '
      """, timeout: 15)
    XCTAssertEqual(result.status, 0)
    XCTAssertFalse(result.timedOut)
    XCTAssertTrue(result.stdout.hasPrefix(json),
      "The JSON prefix must remain intact after large trailing content")
  }

  // Regression: >2 MiB of stderr must not cause a small valid stdout to be lost.
  func testLargeStderrDoesNotInvalidateSmallStdout() async throws {
    let stderrSize = 2 * 1_024 * 1_024 + 512 * 1_024
    let result = try await shell("""
      printf 'small-output\n'
      dd if=/dev/zero bs=1024 count=\(stderrSize / 1024) 2>/dev/null | tr '\\0' E >&2
      """, timeout: 15)
    XCTAssertEqual(result.status, 0)
    XCTAssertFalse(result.timedOut)
    XCTAssertEqual(result.stdout, "small-output\n",
      "Small stdout must not be truncated when stderr is large")
    XCTAssertTrue(result.stderrTruncated)
  }

  // Regression: >4 MiB stdin must reach the child process intact.
  func testLargeStdinReachesChildIntact() async throws {
    let size = 4 * 1_024 * 1_024 + 512 * 1_024
    let input = String(repeating: "X", count: size)
    // Write stdin to a temp file, then verify size and content.
    let tmp = directory.appendingPathComponent("stdin-tmp")
    let result = try await shell("""
      cat > \(tmp.lastPathComponent)
      wc -c < \(tmp.lastPathComponent) >&2
      cat \(tmp.lastPathComponent)
      """, input: input, timeout: 15)
    XCTAssertEqual(result.status, 0)
    XCTAssertFalse(result.timedOut)
    let reportedCount = Int(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    XCTAssertEqual(reportedCount, size,
      "Child must receive the full >4 MiB stdin")
    XCTAssertEqual(result.stdout.utf8.count, size,
      "Child must echo back the full >4 MiB stdin")
  }

  func testTimeoutStopsDescendantsIncludingIgnoredTermination() async throws {
    let result = try await shell("trap '' TERM; (trap '' TERM; sleep 20) & echo $!; wait", timeout: 0.15)
    XCTAssertTrue(result.timedOut)
    XCTAssertNotEqual(result.status, 0)
    let child = try XCTUnwrap(Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
    // A killed orphan can briefly remain a zombie until init reaps it; it
    // must never remain runnable or execute a delayed side effect.
    XCTAssertFalse(isRunning(child))
  }

  func testTimeoutRemainsResponsiveWhileOutputIsContinuous() async throws {
    let result = try await shell("while :; do printf 'continuously producing output\\n'; done", timeout: 0.15)
    XCTAssertTrue(result.timedOut)
    XCTAssertNotEqual(result.status, 0)
    XCTAssertFalse(result.stdout.isEmpty)
  }

  func testNormalParentExitAlsoStopsBackgroundDescendants() async throws {
    let marker = directory.appendingPathComponent("escaped")
    let result = try await shell("(sleep 1; touch escaped) & echo $!")
    XCTAssertEqual(result.status, 0)
    let child = try XCTUnwrap(Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
    XCTAssertFalse(isRunning(child))
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  func testCancellationStopsChildAndThrows() async throws {
    let marker = directory.appendingPathComponent("pid")
    let runner = BenchmarkProcess()
    let task = Task {
      try await runner.run(
        executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo $$ > pid; sleep 20"],
        directory: directory, timeout: 30)
    }
    for _ in 0..<100 {
      if FileManager.default.fileExists(atPath: marker.path) { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let pid = try XCTUnwrap(Int32(String(contentsOf: marker).trimmingCharacters(in: .whitespacesAndNewlines)))
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Cancellation must not produce a completed result")
    } catch is CancellationError {}
    XCTAssertFalse(isRunning(pid))
  }

  func testLaunchFailureAndInvalidInputAreExplicit() async throws {
    do {
      _ = try await BenchmarkProcess().run(
        executable: directory.appendingPathComponent("missing"), arguments: [], directory: directory, timeout: 1)
      XCTFail("A missing executable must fail")
    } catch BenchmarkProcessError.launchFailed {}
    do {
      _ = try await shell("exit 0", timeout: .infinity)
      XCTFail("An unbounded timeout must fail")
    } catch BenchmarkProcessError.invalidInput {}
  }

  func testDefaultEnvironmentDoesNotPassProviderCredentialsOrHooks() {
    let environment = BenchmarkProcess.defaultEnvironment(parent: [
      "HOME": "/home/test", "PATH": "/bin", "LANG": "C", "HTTPS_PROXY": "http://localhost",
      "ANTHROPIC_API_KEY": "secret", "OPENAI_API_KEY": "secret", "CODEX_HOME": "/managed",
      "BASH_ENV": "/hook", "NODE_OPTIONS": "--require=/hook", "DYLD_INSERT_LIBRARIES": "/hook"
    ])
    XCTAssertEqual(environment["HOME"], "/home/test")
    XCTAssertEqual(environment["HTTPS_PROXY"], "http://localhost")
    XCTAssertEqual(environment.count, 4)
  }

  func testWorkspacePinsCommittedContentAndIncludesNewFilesInPatch() async throws {
    let source = directory.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let process = BenchmarkProcess()
    try await git(["init"], at: source, process: process)
    let file = source.appendingPathComponent("task.txt")
    try "baseline".write(to: file, atomically: true, encoding: .utf8)
    try await git(["add", "."], at: source, process: process)
    try await git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "Baseline"], at: source, process: process)
    let commit = try await BenchmarkWorkspace.commit(repository: source, process: process)
    try "dirty original".write(to: file, atomically: true, encoding: .utf8)
    let destination = directory.appendingPathComponent("trial")
    try await BenchmarkWorkspace.create(repository: source, commit: commit, destination: destination, process: process)
    XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("task.txt")), "baseline")
    let remotes = try await process.run(
      executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: ["remote"], directory: destination, timeout: 10)
    XCTAssertEqual(remotes.stdout, "", "A trial must not retain a push route into the source checkout")
    try "new output".write(to: destination.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
    let patch = try await BenchmarkWorkspace.patch(directory: destination, process: process)
    XCTAssertTrue(patch.contains("new.txt"))
    XCTAssertTrue(patch.contains("+new output"))
    XCTAssertEqual(try String(contentsOf: file), "dirty original")
  }

  func testWorkspacePatchIncludesChangesCommittedByCandidate() async throws {
    let source = directory.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let process = BenchmarkProcess()
    try await git(["init"], at: source, process: process)
    try "before\n".write(to: source.appendingPathComponent("task.txt"), atomically: true, encoding: .utf8)
    try await git(["add", "."], at: source, process: process)
    try await git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "Baseline"], at: source, process: process)
    let commit = try await BenchmarkWorkspace.commit(repository: source, process: process)
    let destination = directory.appendingPathComponent("trial")
    try await BenchmarkWorkspace.create(repository: source, commit: commit, destination: destination, process: process)
    try "after\n".write(to: destination.appendingPathComponent("task.txt"), atomically: true, encoding: .utf8)
    try await git(["add", "."], at: destination, process: process)
    try await git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "Candidate result"], at: destination, process: process)
    let patch = try await BenchmarkWorkspace.patch(directory: destination, baselineCommit: commit, process: process)
    XCTAssertTrue(patch.contains("-before"))
    XCTAssertTrue(patch.contains("+after"))
    XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("task.txt")), "before\n")
  }

  func testWorkspaceRejectsSymlinksOutsideCheckout() async throws {
    let source = directory.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let process = BenchmarkProcess()
    try await git(["init"], at: source, process: process)
    try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("escape").path, withDestinationPath: "/tmp")
    try await git(["add", "."], at: source, process: process)
    try await git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "Symlink"], at: source, process: process)
    let commit = try await BenchmarkWorkspace.commit(repository: source, process: process)
    let destination = directory.appendingPathComponent("trial")
    do {
      try await BenchmarkWorkspace.create(repository: source, commit: commit, destination: destination, process: process)
      XCTFail("An escaping symlink must fail before the agent runs")
    } catch BenchmarkWorkspaceError.unsafePath {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
  }

  private func git(_ arguments: [String], at directory: URL, process: BenchmarkProcess) async throws {
    var environment = BenchmarkProcess.defaultEnvironment()
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    let result = try await process.run(
      executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: arguments,
      directory: directory, timeout: 10, environment: environment)
    XCTAssertEqual(result.status, 0, result.stderr)
  }

  private func isRunning(_ pid: Int32) -> Bool {
    // ps exposes zombie status on both supported platforms without accessing
    // /proc (which is absent on macOS).
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-o", "stat=", "-p", String(pid)]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return kill(pid, 0) == 0 }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let state = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return !state.isEmpty && !state.hasPrefix("Z")
  }
}
