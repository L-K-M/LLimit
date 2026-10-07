import Foundation
import XCTest
@testable import QuotaCore

final class ClaudeCodeVersionTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: root)
    super.tearDown()
  }

  func testVersionProbeHasNoProviderCredentialsOrRealProfile() async throws {
    let executable = try fixture(#"""
      [ "$1" = '--version' ] && [ "$#" -eq 1 ] || exit 7
      [ "$HOME" != '/ordinary-home' ] && [ "$CLAUDE_CONFIG_DIR" = "$HOME" ] || exit 8
      [ -z "${ANTHROPIC_API_KEY+x}" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN+x}" ] && [ -z "${BASH_ENV+x}" ] || exit 9
      [ "$VOLTA_HOME" = '/ordinary-home/.volta' ] || exit 10
      [ "$HTTPS_PROXY" = 'http://proxy.invalid:8080' ] || exit 11
      printf '2.1.0-rc.1 (Claude Code)\n'
      """#)
    let version = await ClaudeCodeVersion.probe(executable, timeout: 2, parentEnvironment: [
      "HOME": "/ordinary-home", "CLAUDE_CONFIG_DIR": "/ordinary-profile", "PATH": "/usr/bin:/bin",
      "ANTHROPIC_API_KEY": "wrong-account", "CLAUDE_CODE_OAUTH_TOKEN": "wrong-token", "BASH_ENV": "/startup-hook",
      "HTTPS_PROXY": "http://proxy.invalid:8080"
    ])

    XCTAssertEqual(version, "2.1.0-rc.1")
  }

  func testVersionDeadlineStopsDescendants() async throws {
    let marker = root.appendingPathComponent("survived")
    let executable = try fixture(#"( sleep 1; printf survived > "$(dirname "$0")/survived" ) & wait"#)
    let started = Date()
    let version = await ClaudeCodeVersion.probe(executable, timeout: 0.2, parentEnvironment: ["PATH": "/usr/bin:/bin"])

    XCTAssertNil(version)
    XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    try await Task.sleep(for: .milliseconds(1300))
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "A version descendant outlived its deadline")
  }

  func testExcessOutputNeverBecomesAVersion() async throws {
    let executable = try fixture("printf '2.1.0 (Claude Code)\\n'; yes | head -c \(ClaudeCodeVersion.outputLimit + 1)")
    let version = await ClaudeCodeVersion.probe(executable, timeout: 0.5, parentEnvironment: ["PATH": "/usr/bin:/bin"])

    XCTAssertNil(version)
  }

  func testNpmVersionShimFindsItsInterpreterBesideTheExecutable() async throws {
    let interpreter = root.appendingPathComponent("fakenode")
    try "#!/bin/sh\nexec /bin/sh \"$@\"\n".write(to: interpreter, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: interpreter.path)
    let executable = root.appendingPathComponent("claude")
    try "#!/usr/bin/env fakenode\nprintf '2.1.0 (Claude Code)\\n'\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

    let version = await ClaudeCodeVersion.probe(executable, timeout: 2, parentEnvironment: ["PATH": "/usr/bin:/bin"])
    XCTAssertEqual(version, "2.1.0")
  }

  private func fixture(_ body: String) throws -> URL {
    let executable = root.appendingPathComponent("claude")
    try ("#!/bin/sh\n" + body + "\n").write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return executable
  }
}
