import Foundation
import XCTest
@testable import QuotaCore

/// Runs `ClaudeCodeKeychain` against a fake `security` tool, never a real keychain.
final class ClaudeCodeKeychainTests: XCTestCase {
  private let service = "Claude Code-credentials-1a2b3c4d"
  private let account = "jane.doe"
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: root)
    super.tearDown()
  }

  func testReadsTheItemByAccountAndServiceWithoutItsLineEnd() throws {
    let keychain = try tool(#"""
      [ "$#" -eq 6 ] && [ "$1" = find-generic-password ] && [ "$2" = -a ] && [ "$3" = jane.doe ] \
        && [ "$4" = -s ] && [ "$5" = 'Claude Code-credentials-1a2b3c4d' ] && [ "$6" = -w ] || exit 9
      printf '{"claudeAiOauth":{"accessToken":"token"}}\n'
      """#)

    let result = keychain.password(service: service, account: account, timeout: 5)

    XCTAssertEqual(try result.get(), Data(#"{"claudeAiOauth":{"accessToken":"token"}}"#.utf8))
  }

  func testKeepsOutputWithoutALineEndIntact() throws {
    let keychain = try tool("printf 'token'")

    XCTAssertEqual(try keychain.password(service: service, account: account, timeout: 5).get(), Data("token".utf8))
  }

  func testDrainsOutputLargerThanThePipeBuffer() throws {
    let size = 256 * 1024
    let keychain = try tool("head -c \(size) /dev/zero")

    XCTAssertEqual(try keychain.password(service: service, account: account, timeout: 5).get()?.count, size)
  }

  func testMissingItemIsNotAFailure() throws {
    let keychain = try tool("exit \(ClaudeCodeKeychain.itemNotFoundStatus)")

    XCTAssertEqual(keychain.password(service: service, account: account, timeout: 5), .success(nil))
  }

  func testLockedOrDeniedKeychainIsUnavailable() throws {
    // errSecInteractionNotAllowed, errSecAuthFailed, userCanceledErr, and a generic failure.
    for status in [36, 51, 128, 1] {
      let keychain = try tool("printf 'partial'; exit \(status)")

      XCTAssertEqual(keychain.password(service: service, account: account, timeout: 5), .failure(.unavailable),
                     "Exit status \(status)")
    }
  }

  func testStopsAToolThatDoesNotAnswerInTime() throws {
    let pidFile = root.appendingPathComponent("pid")
    let keychain = try tool("echo $$ > '\(pidFile.path)'; exec sleep 30")
    let started = Date()

    XCTAssertEqual(keychain.password(service: service, account: account, timeout: 0.3), .failure(.unavailable))
    XCTAssertLessThan(Date().timeIntervalSince(started), 2)

    // The child is reaped shortly after the kill; until then it is a zombie.
    let pid = try XCTUnwrap(pid_t(String(decoding: Data(contentsOf: pidFile), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)))
    let deadline = Date().addingTimeInterval(2)
    while kill(pid, 0) == 0, Date() < deadline { usleep(10_000) }
    XCTAssertEqual(kill(pid, 0), -1, "The tool outlived its deadline")
  }

  func testRejectsOversizedOutput() throws {
    let keychain = try tool("head -c \(ClaudeCodeKeychain.outputLimit + 1) /dev/zero")

    XCTAssertEqual(keychain.password(service: service, account: account, timeout: 5), .failure(.unavailable))
  }

  func testMissingToolIsUnavailable() {
    let keychain = ClaudeCodeKeychain(tool: root.appendingPathComponent("missing"))

    XCTAssertEqual(keychain.password(service: service, account: account, timeout: 5), .failure(.unavailable))
    XCTAssertEqual(keychain.deletePassword(service: service, account: account, timeout: 5).failure, .unavailable)
  }

  func testInvalidTimeoutNeverLaunchesTheTool() throws {
    let marker = root.appendingPathComponent("launched")
    let keychain = try tool("touch '\(marker.path)'")

    for timeout in [0, -1, .infinity, .nan] as [TimeInterval] {
      XCTAssertEqual(keychain.password(service: service, account: account, timeout: timeout), .failure(.unavailable))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  func testDeletesTheItemByAccountAndService() throws {
    let keychain = try tool(#"""
      [ "$#" -eq 5 ] && [ "$1" = delete-generic-password ] && [ "$2" = -a ] && [ "$3" = jane.doe ] \
        && [ "$4" = -s ] && [ "$5" = 'Claude Code-credentials-1a2b3c4d' ] || exit 9
      """#)

    XCTAssertNil(keychain.deletePassword(service: service, account: account, timeout: 5).failure)
  }

  func testDeletingAMissingItemSucceeds() throws {
    let keychain = try tool("exit \(ClaudeCodeKeychain.itemNotFoundStatus)")

    XCTAssertNil(keychain.deletePassword(service: service, account: account, timeout: 5).failure)
  }

  func testFailedDeleteIsUnavailable() throws {
    let keychain = try tool("exit 36")

    XCTAssertEqual(keychain.deletePassword(service: service, account: account, timeout: 5).failure, .unavailable)
  }

  private func tool(_ body: String) throws -> ClaudeCodeKeychain {
    let executable = root.appendingPathComponent("security")
    try ("#!/bin/sh\n" + body + "\n").write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return ClaudeCodeKeychain(tool: executable)
  }
}

private extension Result {
  var failure: Failure? {
    guard case .failure(let failure) = self else { return nil }
    return failure
  }
}
