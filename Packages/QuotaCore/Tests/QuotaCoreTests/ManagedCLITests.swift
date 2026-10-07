import Foundation
import XCTest
@testable import QuotaCore

final class ManagedCLITests: XCTestCase {
  func testCandidatesKeepEachCLIsPreferredOrderThenVersionManagersThenPath() {
    let environment = ["HOME": "/Users/example", "PATH": "/usr/bin:relative:/opt/custom/bin:/usr/bin"]
    let versionManagers = [
      "/Users/example/.volta/bin", "/Users/example/.npm-global/bin",
      "/Users/example/.local/share/fnm/aliases/default/bin", "/Users/example/.fnm/aliases/default/bin",
      "/Users/example/Library/Application Support/fnm/aliases/default/bin"
    ]

    XCTAssertEqual(ManagedCLI.codex.candidates(environment: environment).map(\.path),
                   (["/opt/homebrew/bin", "/usr/local/bin", "/Users/example/.local/bin"] + versionManagers
                    + ["/usr/bin", "/opt/custom/bin"]).map { $0 + "/codex" })
    XCTAssertEqual(ManagedCLI.claude.candidates(environment: environment).map(\.path),
                   (["/Users/example/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"] + versionManagers
                    + ["/usr/bin", "/opt/custom/bin"]).map { $0 + "/claude" })
  }

  func testCandidatesHonorFnmLocationOverridesAndSkipHomeWhenUnknown() {
    let paths = ManagedCLI.codex.candidates(environment: [
      "FNM_DIR": "/data/fnm", "XDG_DATA_HOME": "/data/xdg", "PATH": "/usr/bin"
    ]).map(\.path)

    XCTAssertEqual(paths, [
      "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/data/fnm/aliases/default/bin/codex",
      "/data/xdg/fnm/aliases/default/bin/codex", "/usr/bin/codex"
    ])
    XCTAssertFalse(ManagedCLI.codex.candidates(environment: ["HOME": "relative", "XDG_DATA_HOME": "relative"])
      .contains { $0.path.contains("relative") })
  }

  func testSearchPathDropsRelativeAndUnrepresentableDirectories() {
    let executable = URL(fileURLWithPath: "/opt/odd:dir/bin/codex")

    let path = ManagedCLI.searchPath(for: executable, environment: ["PATH": ":.:bin:/usr/local/bin:/custom/bin"])

    XCTAssertEqual(path, "/opt/homebrew/bin:/usr/local/bin:/custom/bin:/usr/bin:/bin:/usr/sbin:/sbin")
  }

  func testFingerprintFollowsSymlinkAndChangesWithSizeOrModificationTime() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("codex.js")
    try "first".write(to: target, atomically: true, encoding: .utf8)
    let link = directory.appendingPathComponent("codex")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "codex.js")

    let original = try XCTUnwrap(ManagedCLIFingerprint(executable: link))
    XCTAssertEqual(original.path, target.resolvingSymlinksInPath().path)
    XCTAssertEqual(original.size, 5)
    XCTAssertEqual(ManagedCLIFingerprint(executable: link), original)

    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: target.path)
    let touched = try XCTUnwrap(ManagedCLIFingerprint(executable: link))
    XCTAssertNotEqual(touched, original)

    try "second".write(to: target, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: target.path)
    XCTAssertNotEqual(ManagedCLIFingerprint(executable: link), touched)

    try FileManager.default.removeItem(at: target)
    XCTAssertNil(ManagedCLIFingerprint(executable: link))
  }
}
