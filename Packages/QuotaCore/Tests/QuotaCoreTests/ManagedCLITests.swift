import Foundation
import XCTest
@testable import QuotaCore

final class ManagedCLITests: XCTestCase {
  func testCandidatesKeepEachCLIsPreviousOrderThenAddVersionManagers() {
    let environment = ["HOME": "/Users/example", "PATH": "/usr/bin:relative:/opt/custom/bin:/usr/bin"]
    let versionManagers = [
      "/Users/example/.volta/bin", "/Users/example/.npm-global/bin",
      "/Users/example/.local/share/fnm/aliases/default/bin", "/Users/example/.fnm/aliases/default/bin",
      "/Users/example/Library/Application Support/fnm/aliases/default/bin"
    ]

    // Earlier releases searched these fixed locations and then PATH, so new
    // locations come last and cannot change which install an upgrade picks.
    XCTAssertEqual(ManagedCLI.codex.candidates(environment: environment).map(\.path),
                   (["/opt/homebrew/bin", "/usr/local/bin", "/Users/example/.local/bin", "/usr/bin", "/opt/custom/bin"]
                    + versionManagers).map { $0 + "/codex" })
    XCTAssertEqual(ManagedCLI.claude.candidates(environment: environment).map(\.path),
                   (["/Users/example/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/opt/custom/bin"]
                    + versionManagers).map { $0 + "/claude" })
  }

  func testCandidatesUseRelocatedVoltaHome() {
    let paths = ManagedCLI.claude.candidates(environment: ["HOME": "/Users/example", "VOLTA_HOME": "/tools/volta"]).map(\.path)

    XCTAssertTrue(paths.contains("/tools/volta/bin/claude"))
    XCTAssertFalse(paths.contains("/Users/example/.volta/bin/claude"))
    let probe = CodexCLIProbe.environment(for: URL(fileURLWithPath: "/tools/volta/bin/codex"),
                                          parent: ["HOME": "/Users/example", "VOLTA_HOME": "/tools/volta"],
                                          home: URL(fileURLWithPath: "/private-probe-home"))
    XCTAssertEqual(probe["VOLTA_HOME"], "/tools/volta")
    XCTAssertEqual(probe["HOME"], "/private-probe-home")
    let claude = ClaudeCodeProcess.environment(parent: ["VOLTA_HOME": "/tools/volta"],
                                               profileDirectory: URL(fileURLWithPath: "/profile"),
                                               executable: URL(fileURLWithPath: "/tools/volta/bin/claude"))
    XCTAssertEqual(claude["VOLTA_HOME"], "/tools/volta")
    let codex = CodexAccountService.environment(parent: ["VOLTA_HOME": "/tools/volta"],
                                                directory: URL(fileURLWithPath: "/profile"),
                                                executable: URL(fileURLWithPath: "/tools/volta/bin/codex"))
    XCTAssertEqual(codex["VOLTA_HOME"], "/tools/volta")
  }

  func testNvmCandidatesPreferDefaultAliasThenNewestVersions() throws {
    let root = try nvmTree(versions: ["v9.11.2", "v18.20.4", "v20.11.1", "v22.3.0", "notes"], aliases: ["default": "20"])
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = ManagedCLI.codex.candidates(environment: ["NVM_DIR": root.path]).map(\.path)

    let nvm = paths.filter { $0.hasPrefix(root.path) }
    XCTAssertEqual(nvm, ["v20.11.1", "v22.3.0", "v18.20.4", "v9.11.2"].map { root.path + "/versions/node/" + $0 + "/bin/codex" })
    let firstNvm = try XCTUnwrap(paths.firstIndex { $0.hasPrefix(root.path) })
    XCTAssertEqual(Array(paths[firstNvm...]), nvm, "nvm locations come after every earlier search location")
  }

  func testNvmDefaultAliasFollowsLtsAliasChain() throws {
    let root = try nvmTree(versions: ["v18.20.4", "v22.3.0"],
                           aliases: ["default": "lts/*", "lts/*": "lts/hydrogen", "lts/hydrogen": "v18.20.4"])
    defer { try? FileManager.default.removeItem(at: root) }

    let first = ManagedCLI.claude.candidates(environment: ["NVM_DIR": root.path]).first { $0.path.hasPrefix(root.path) }

    XCTAssertEqual(first?.path, root.path + "/versions/node/v18.20.4/bin/claude")
  }

  func testEmptyOrCyclicNvmDefaultAliasPrefersNewestVersion() throws {
    let newest = "/versions/node/v22.3.0/bin/codex"
    for aliases in [["default": ""], ["default": "lts/a", "lts/a": "lts/b", "lts/b": "lts/a"]] {
      let root = try nvmTree(versions: ["v18.20.4", "v22.3.0"], aliases: aliases)
      defer { try? FileManager.default.removeItem(at: root) }

      let first = ManagedCLI.codex.candidates(environment: ["NVM_DIR": root.path]).first { $0.path.hasPrefix(root.path) }

      XCTAssertEqual(first?.path, root.path + newest, "\(aliases)")
    }
  }

  func testNodeVersionOrderIgnoresAliasesThatMatchNothing() {
    let installed = ["v8.0.0", "v10.1.0", "v10.12.0", "v22.0.0"]

    XCTAssertEqual(ManagedCLI.orderedNodeVersions(installed, defaultAlias: nil), ["v22.0.0", "v10.12.0", "v10.1.0", "v8.0.0"])
    XCTAssertEqual(ManagedCLI.orderedNodeVersions(installed, defaultAlias: "10"), ["v10.12.0", "v22.0.0", "v10.1.0", "v8.0.0"])
    XCTAssertEqual(ManagedCLI.orderedNodeVersions(installed, defaultAlias: "v10.1.0"), ["v10.1.0", "v22.0.0", "v10.12.0", "v8.0.0"])
    for alias in ["16", "node", "stable", "system", "lts/iron", "10.1.0.1", ""] {
      XCTAssertEqual(ManagedCLI.orderedNodeVersions(installed, defaultAlias: alias), ["v22.0.0", "v10.12.0", "v10.1.0", "v8.0.0"], alias)
    }
  }

  func testCandidatesHonorFnmLocationOverridesAndSkipHomeWhenUnknown() {
    let paths = ManagedCLI.codex.candidates(environment: [
      "FNM_DIR": "/data/fnm", "XDG_DATA_HOME": "/data/xdg", "PATH": "/usr/bin"
    ]).map(\.path)

    XCTAssertEqual(paths, [
      "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/usr/bin/codex", "/data/fnm/aliases/default/bin/codex",
      "/data/xdg/fnm/aliases/default/bin/codex"
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

  /// A fake `$NVM_DIR` with empty version directories and alias files.
  private func nvmTree(versions: [String], aliases: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    for version in versions {
      try FileManager.default.createDirectory(at: root.appendingPathComponent("versions/node/" + version + "/bin"),
                                              withIntermediateDirectories: true)
    }
    for (name, target) in aliases {
      let file = root.appendingPathComponent("alias/" + name)
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try (target + "\n").write(to: file, atomically: true, encoding: .utf8)
    }
    return root
  }
}
