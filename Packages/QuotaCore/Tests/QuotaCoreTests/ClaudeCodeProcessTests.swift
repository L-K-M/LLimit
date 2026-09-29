import Foundation
import XCTest
@testable import QuotaCore

final class ClaudeCodeProcessTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: directory)
  }

  func testEnvironmentKeepsSystemContextAndStripsInheritedAuthentication() {
    let parent = [
      "HOME": "/Users/example", "USER": "example", "LOGNAME": "example",
      "PATH": "/usr/bin:/bin", "TMPDIR": "/tmp/example", "LANG": "en_US.UTF-8",
      "LC_ALL": "C", "TERM": "xterm-256color", "ANTHROPIC_API_KEY": "wrong-account",
      "ANTHROPIC_BASE_URL": "https://example.invalid", "CLAUDE_CONFIG_DIR": "/another/profile",
      "CLAUDE_CODE_OAUTH_TOKEN": "wrong-access-token",
      "CLAUDE_CODE_OAUTH_REFRESH_TOKEN": "wrong-refresh-token",
      "CLAUDE_CODE_OAUTH_SCOPES": "wrong-scope", "BASH_ENV": "/tmp/untrusted-hook",
      "NODE_OPTIONS": "--require=/tmp/untrusted-hook", "DYLD_INSERT_LIBRARIES": "/tmp/untrusted.dylib"
    ]
    let profile = directory.appendingPathComponent("private-profile")

    let environment = ClaudeCodeProcess.environment(parent: parent, profileDirectory: profile)

    XCTAssertEqual(environment, [
      "HOME": "/Users/example", "USER": "example", "LOGNAME": "example",
      "PATH": "/usr/bin:/bin", "TMPDIR": "/tmp/example", "LANG": "en_US.UTF-8",
      "LC_ALL": "C", "TERM": "xterm-256color", "CLAUDE_CONFIG_DIR": profile.path,
      "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
    ])
  }

  func testEnvironmentUsesOnlyExplicitRenewalMaterial() {
    let environment = ClaudeCodeProcess.environment(
      parent: ["CLAUDE_CODE_OAUTH_REFRESH_TOKEN": "unrelated-login", "HOME": "/home/example"],
      profileDirectory: directory,
      renewal: ClaudeCodeRenewalMaterial(refreshToken: "selected-profile-refresh", scopes: ["user:profile", "user:inference"])
    )

    XCTAssertEqual(environment["CLAUDE_CODE_OAUTH_REFRESH_TOKEN"], "selected-profile-refresh")
    XCTAssertEqual(environment["CLAUDE_CODE_OAUTH_SCOPES"], "user:profile user:inference")
    XCTAssertNil(environment["CLAUDE_CODE_OAUTH_TOKEN"])
  }

  func testArgumentsStayLiteralAndAllStandardStreamsUseNullDevice() async throws {
    let executable = try fixture("""
      printf '%s\\n' "$@" > arguments.txt
      [ -c /dev/stdin ] && [ -c /dev/stdout ] && [ -c /dev/stderr ] || exit 31
      printf 'discarded stdout'
      printf 'discarded stderr' >&2
      exit 7
      """)
    let arguments = ["literal with spaces", "$(touch expanded)", "`touch backticks`", "; touch separated", "'quotes'"]
    let runner = ClaudeCodeProcess()

    let result = try await runner.run(
      executable: executable,
      arguments: arguments,
      environment: ["PATH": "/usr/bin:/bin"],
      workingDirectory: directory,
      timeout: 5
    )

    XCTAssertEqual(result, .completed(status: 7))
    let written = try String(contentsOf: directory.appendingPathComponent("arguments.txt"), encoding: .utf8)
    XCTAssertEqual(written, arguments.joined(separator: "\n") + "\n")
    for name in ["expanded", "backticks", "separated"] {
      XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
    }
  }

  func testTimeoutKeepsChildAliveAndTracksEventualExit() async throws {
    let executable = try fixture("""
      sleep 0.2
      printf completed > completed.txt
      exit 23
      """)
    let runner = ClaudeCodeProcess()

    let result = try await runner.run(
      executable: executable,
      arguments: [],
      environment: ["PATH": "/usr/bin:/bin"],
      workingDirectory: directory,
      timeout: 0.01
    )

    guard case .running(let id) = result else {
      return XCTFail("The wait should time out while the child continues its work")
    }
    let completion = try await waitForExit(runner, id: id)
    XCTAssertEqual(completion, .completed(status: 23))
    XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("completed.txt"), encoding: .utf8), "completed")
    let consumed = await runner.status(id: id)
    XCTAssertNil(consumed)
  }

  func testCancellationAfterLaunchDoesNotInterruptChild() async throws {
    let executable = try fixture("""
      printf started > started.txt
      sleep 0.2
      printf completed > completed.txt
      """)
    let runner = ClaudeCodeProcess()
    let workingDirectory = directory!
    let operation = Task {
      try await runner.run(
        executable: executable,
        arguments: [],
        environment: ["PATH": "/usr/bin:/bin"],
        workingDirectory: workingDirectory,
        timeout: 5
      )
    }
    let deadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("started.txt").path), Date() < deadline {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("started.txt").path))
    operation.cancel()

    let result = try await operation.value

    XCTAssertEqual(result, .completed(status: 0))
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("completed.txt").path))
  }

  func testSpawnFailureThrowsWithoutPretendingCommandCompleted() async {
    let runner = ClaudeCodeProcess()
    do {
      _ = try await runner.run(
        executable: directory.appendingPathComponent("missing-claude"),
        arguments: [],
        environment: [:],
        workingDirectory: directory,
        timeout: 5
      )
      XCTFail("Missing executable should fail to start")
    } catch {
      guard let failure = error as? ClaudeCodeProcess.StartFailure else {
        return XCTFail("A launch failure must prove that no child started")
      }
      XCTAssertFalse(failure.underlyingError is CancellationError)
    }
  }

  private func fixture(_ body: String) throws -> URL {
    let executable = directory.appendingPathComponent("fixture-cli")
    try ("#!/bin/sh\n" + body + "\n").write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return executable
  }

  private func waitForExit(_ runner: ClaudeCodeProcess, id: UUID) async throws -> ClaudeCodeProcess.Result? {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      let status = await runner.status(id: id)
      if status != .running(id: id) { return status }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Fixture CLI did not exit")
    return nil
  }
}
