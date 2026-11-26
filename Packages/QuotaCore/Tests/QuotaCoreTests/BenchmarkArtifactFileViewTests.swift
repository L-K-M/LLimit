import Foundation
import XCTest
@testable import QuotaCore

/// Regression tests for the artifact file-view feature in prepareJudge.
/// Each test creates its own temporary repository and fixture; no shared
/// state across tests.  The tests exercise the expected API contract so
/// they fail deterministically before the production implementation lands.
final class BenchmarkArtifactFileViewTests: XCTestCase {
  private var root: URL!
  private var repo: URL!
  private var process: BenchmarkProcess!

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("llimit-artifact-view-\(UUID().uuidString)", isDirectory: true)
    repo = root.appendingPathComponent("repo", isDirectory: true)
    process = BenchmarkProcess()
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try await git(["init", "--quiet"], at: repo)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: root)
  }

  func testRunnerCapturesRedactsAndHandsBranchFilesToBothJudges() async throws {
    try "baseline\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    _ = try await commit(repo)
    let secret = "long-auth-secret-fixture"
    let candidate = """
      set -eu
      cat >/dev/null
      baseline=$(git rev-parse HEAD)
      git -c core.hooksPath=/dev/null checkout -b result-branch >/dev/null 2>&1
      mkdir src
      printf '%s\\n' 'int solve() => 42;' '// token=\(secret)' > src/solution2.dart
      git -c core.hooksPath=/dev/null add src/solution2.dart
      git -c core.hooksPath=/dev/null -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm Result
      git -c core.hooksPath=/dev/null checkout --detach "$baseline" >/dev/null 2>&1
      printf '%s\\n' 'Saved solution2.dart on result-branch; expected answer 42.' > LLIMIT_BENCHMARK_RESULT.md
      printf 'Completed the branch result.'
      """
    let judge = """
      set -eu
      prompt=$(cat)
      view=$(awk -F'"' '/"filesDirectory"/ {print $4; exit}' .llimit-evidence/manifest.json)
      test "$view" = artifact-1
      file=".llimit-evidence/$view/src/solution2.dart"
      grep -Fq 'int solve() => 42;' "$file"
      grep -Fq '[redacted]' "$file"
      if grep -Fq '\(secret)' "$file"; then exit 9; fi
      if printf '%s' "$prompt" | grep -Fq '\(secret)'; then exit 10; fi
      test ! -e src/solution2.dart
      printf '%s' '{"accepted":true,"score":9,"explanation":"Read complete branch file: answer 42, authentication secret absent."}'
      """
    let judgeCommand = BenchmarkCommand(executable: "/bin/sh", arguments: ["-c", judge])
    let plan = BenchmarkPlan(taskPrompt: "Implement answer 42 in solution2.dart and preserve the result branch.",
      rubric: "The complete changed file provides answer 42.", repositoryPath: repo.path,
      repetitions: 1, timeoutSeconds: 20,
      candidates: [BenchmarkCandidate(name: "Fixture", command: BenchmarkCommand(executable: "/bin/sh", arguments: ["-c", candidate]))],
      judges: [BenchmarkJudge(name: "First", command: judgeCommand), BenchmarkJudge(name: "Second", command: judgeCommand)])
    let redactor = BenchmarkRedactor(configurations: [ProviderRuntimeConfiguration(provider: .longcat,
      isEnabled: true, credentials: [CredentialField.longcatSessionCookies:
        "owned_session_fixture=\(secret);long_cat_region_key=2"])])
    let report = try await BenchmarkRunner().run(plan: plan, directory: root.appendingPathComponent("reports"),
      redactor: redactor, quotaReader: { _ in throw BenchmarkError.unavailableAccount })
    let run = try XCTUnwrap(report.runs.first)
    XCTAssertEqual(run.outcome, .completed)
    XCTAssertEqual(run.isAccepted, true)
    XCTAssertEqual(run.evaluations.count, 2)
    XCTAssertTrue(run.evaluations.allSatisfy { $0.isValid && ($0.evidenceWarnings ?? []).isEmpty })
    let artifact = try XCTUnwrap(run.evidence?.additionalArtifacts.first)
    XCTAssertTrue(artifact.patch.contains("src/solution2.dart"))
    XCTAssertTrue(artifact.patch.contains("return 42") || artifact.patch.contains("=> 42"))
    XCTAssertFalse(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains(secret))
    XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("src/solution2.dart").path))
  }

  // MARK: - Test 1: Valid patch – modify, add, delete

  func test_validArtifact_materializesChangedFiles() async throws {
    // Build baseline: src/value.txt, src/new.txt (absent), src/obsolete.txt,
    // src/baseline-only.txt
    let src = repo.appendingPathComponent("src", isDirectory: true)
    try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    try "original value\n".write(to: src.appendingPathComponent("value.txt"), atomically: true, encoding: .utf8)
    try "obsolete content\n".write(to: src.appendingPathComponent("obsolete.txt"), atomically: true, encoding: .utf8)
    try "baseline only\n".write(to: src.appendingPathComponent("baseline-only.txt"), atomically: true, encoding: .utf8)
    let baseline = try await commit(repo)

    // Create a branch with the desired changes, then generate a full diff.
    try await git(["checkout", "-b", "artifact-branch"], at: repo)
    try "modified value\n".write(to: src.appendingPathComponent("value.txt"), atomically: true, encoding: .utf8)
    try "brand new file\n".write(to: src.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(at: src.appendingPathComponent("obsolete.txt"))
    _ = try await commit(repo)
    let patch = try await git(["diff", "--binary", "--no-color",
      "--src-prefix=a/", "--dst-prefix=b/", "--unified=3",
      baseline, "HEAD", "--", "."], at: repo)
    // Return to baseline
    try await git(["checkout", "--detach", baseline], at: repo)

    let artifact = BenchmarkEvidenceArtifact(
      kind: .localBranch, name: "artifact-branch", patch: patch)

    let judge = root.appendingPathComponent("judge", isDirectory: true)
    try await BenchmarkWorkspace.prepareJudge(
      repository: repo, baselineCommit: baseline, destination: judge,
      patch: "", additionalArtifacts: [artifact], process: process)

    let evidence = judge.appendingPathComponent(".llimit-evidence", isDirectory: true)

    // Patch file retained
    XCTAssertTrue(FileManager.default.fileExists(atPath: evidence.appendingPathComponent("artifact-1.patch").path))

    // Manifest – additionalArtifacts row
    let manifest = try loadManifest(evidence)
    let artifacts = try XCTUnwrap(manifest["additionalArtifacts"] as? [[String: Any]])
    XCTAssertEqual(artifacts.count, 1)
    let row = artifacts[0]
    // filesDirectory points to artifact-1
    XCTAssertEqual(row["filesDirectory"] as? String, "artifact-1")
    // deletedPaths contains obsolete.txt
    let deletedPaths = row["deletedPaths"] as? [String] ?? []
    XCTAssertTrue(deletedPaths.contains("src/obsolete.txt"),
      "deletedPaths must record src/obsolete.txt")

    // Materialized files
    let artifactDir = evidence.appendingPathComponent("artifact-1", isDirectory: true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: artifactDir.path),
      "artifact-1/ directory must exist for a valid artifact")

    // Modified file has new bytes
    let modified = try String(contentsOf: artifactDir.appendingPathComponent("src/value.txt"))
    XCTAssertEqual(modified, "modified value\n",
      "Modified file must carry the patched bytes")

    // New file exists
    let added = try String(contentsOf: artifactDir.appendingPathComponent("src/new.txt"))
    XCTAssertEqual(added, "brand new file\n",
      "Added file must be materialized")

    // Deleted file must NOT exist in the artifact directory
    XCTAssertFalse(FileManager.default.fileExists(atPath: artifactDir.appendingPathComponent("src/obsolete.txt").path),
      "Deleted file must not appear in the artifact directory")

    // Unchanged baseline-only.txt must NOT be duplicated
    XCTAssertFalse(FileManager.default.fileExists(atPath: artifactDir.appendingPathComponent("src/baseline-only.txt").path),
      "Unchanged baseline-only.txt must not be duplicated in the artifact view")

    // Root checkout stays at baseline
    let rootValue = try String(contentsOf: judge.appendingPathComponent("src/value.txt"))
    XCTAssertEqual(rootValue, "original value\n",
      "Root checkout must remain at baseline bytes")
  }

  // MARK: - Test 2: Two independent artifacts modifying the same file

  func test_twoArtifacts_independentValues() async throws {
    let src = repo.appendingPathComponent("src", isDirectory: true)
    try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    try "shared baseline\n".write(to: src.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
    let baseline = try await commit(repo)

    // First branch
    try await git(["checkout", "-b", "first"], at: repo)
    try "first-result\n".write(to: src.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
    _ = try await commit(repo)
    let patch1 = try await git(["diff", "--binary", "--no-color",
      "--src-prefix=a/", "--dst-prefix=b/", "--unified=3",
      baseline, "HEAD", "--", "."], at: repo)

    // Second branch
    try await git(["checkout", "-b", "second", baseline], at: repo)
    try "second-result\n".write(to: src.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
    _ = try await commit(repo)
    let patch2 = try await git(["diff", "--binary", "--no-color",
      "--src-prefix=a/", "--dst-prefix=b/", "--unified=3",
      baseline, "HEAD", "--", "."], at: repo)

    try await git(["checkout", "--detach", baseline], at: repo)

    let artifacts = [
      BenchmarkEvidenceArtifact(kind: .localBranch, name: "first", patch: patch1),
      BenchmarkEvidenceArtifact(kind: .localBranch, name: "second", patch: patch2),
    ]

    let judge = root.appendingPathComponent("judge", isDirectory: true)
    try await BenchmarkWorkspace.prepareJudge(
      repository: repo, baselineCommit: baseline, destination: judge,
      patch: "", additionalArtifacts: artifacts, process: process)

    let evidence = judge.appendingPathComponent(".llimit-evidence", isDirectory: true)

    let a1 = try String(contentsOf: evidence.appendingPathComponent("artifact-1/src/shared.txt"))
    let a2 = try String(contentsOf: evidence.appendingPathComponent("artifact-2/src/shared.txt"))
    XCTAssertEqual(a1, "first-result\n", "artifact-1 must carry first-result")
    XCTAssertEqual(a2, "second-result\n", "artifact-2 must carry second-result")

    // Primary checkout untouched
    let rootVal = try String(contentsOf: judge.appendingPathComponent("src/shared.txt"))
    XCTAssertEqual(rootVal, "shared baseline\n",
      "Neither artifact should contaminate the primary checkout")
    let staged = try await git(["diff", "--cached", "--name-only"], at: judge)
    XCTAssertTrue(staged.isEmpty)
    let temporaryIndexes = try FileManager.default.contentsOfDirectory(atPath: evidence.path)
      .filter { $0.hasPrefix(".artifact-index-") }
    XCTAssertTrue(temporaryIndexes.isEmpty)
  }

  func testBaselineContextSeparatesPrimaryNewChangedAndDeletedFilesFromBranches() async throws {
    try "original shared\n".write(to: repo.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
    try "original removed\n".write(to: repo.appendingPathComponent("removed.txt"), atomically: true, encoding: .utf8)
    try "unchanged\n".write(to: repo.appendingPathComponent("unchanged.txt"), atomically: true, encoding: .utf8)
    let baseline = try await commit(repo)
    try "primary result\n".write(to: repo.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
    try "primary only\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(at: repo.appendingPathComponent("removed.txt"))
    _ = try await commit(repo)
    let primary = try await git(["diff", "--binary", baseline, "HEAD", "--"], at: repo)
    try await git(["checkout", "--detach", baseline], at: repo)
    try "branch result\n".write(to: repo.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
    _ = try await commit(repo)
    let branch = try await git(["diff", "--binary", baseline, "HEAD", "--"], at: repo)
    try await git(["checkout", "--detach", baseline], at: repo)
    let judge = root.appendingPathComponent("judge")
    let warnings = try await BenchmarkWorkspace.prepareJudge(repository: repo, baselineCommit: baseline,
      destination: judge, patch: primary,
      additionalArtifacts: [BenchmarkEvidenceArtifact(kind: .localBranch, name: "branch", patch: branch)], process: process)
    XCTAssertTrue(warnings.isEmpty)
    let evidence = judge.appendingPathComponent(".llimit-evidence")
    let manifest = try loadManifest(evidence)
    XCTAssertEqual(manifest["primaryChangedPaths"] as? [String], ["new.txt", "removed.txt", "shared.txt"])
    XCTAssertEqual(manifest["baselineFilesDirectory"] as? String, "baseline")
    XCTAssertEqual(try String(contentsOf: evidence.appendingPathComponent("baseline/shared.txt")), "original shared\n")
    XCTAssertEqual(try String(contentsOf: evidence.appendingPathComponent("baseline/removed.txt")), "original removed\n")
    XCTAssertFalse(FileManager.default.fileExists(atPath: evidence.appendingPathComponent("baseline/new.txt").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: evidence.appendingPathComponent("baseline/unchanged.txt").path))
    XCTAssertEqual(try String(contentsOf: judge.appendingPathComponent("shared.txt")), "primary result\n")
    XCTAssertEqual(try String(contentsOf: judge.appendingPathComponent("new.txt")), "primary only\n")
    XCTAssertEqual(try String(contentsOf: evidence.appendingPathComponent("artifact-1/shared.txt")), "branch result\n")
  }

  // MARK: - Test 3: Git binary patch – exact bytes

  func test_binaryPatch_exactBytes() async throws {
    // Create a binary file, then generate a diff via intent-to-add.
    let binaryData = Data([0, 1, 2, 255, 0, 9])
    try "*.bin text eol=crlf\n".write(to: repo.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
    let binPath = repo.appendingPathComponent("data.bin")
    try binaryData.write(to: binPath)
    try await git(["add", "--", "data.bin"], at: repo)
    let baseline = try await commit(repo)

    // Modify the binary file to produce a diff.
    let modifiedData = Data([0, 1, 2, 255, 0, 9, 42, 10])
    try modifiedData.write(to: binPath)
    try await git(["add", "--intent-to-add", "--", "data.bin"], at: repo)
    let patch = try await git(["diff", "--binary", "--no-color",
      "--src-prefix=a/", "--dst-prefix=b/", "--unified=3",
      baseline, "--", "data.bin"], at: repo)

    // Reset to baseline
    try await git(["checkout", "--", "data.bin"], at: repo)

    let artifact = BenchmarkEvidenceArtifact(
      kind: .localBranch, name: "binary-change", patch: patch)

    let judge = root.appendingPathComponent("judge", isDirectory: true)
    try await BenchmarkWorkspace.prepareJudge(
      repository: repo, baselineCommit: baseline, destination: judge,
      patch: "", additionalArtifacts: [artifact], process: process)

    let evidence = judge.appendingPathComponent(".llimit-evidence", isDirectory: true)
    let materialized = try Data(contentsOf: evidence.appendingPathComponent("artifact-1/data.bin"))
    XCTAssertEqual(materialized, modifiedData,
      "Binary artifact must materialize exact bytes")
  }

  // MARK: - Test 4: Malformed patch – warning, no filesDirectory; second valid still works

  func test_malformedArtifact_warningAndNoDirectory() async throws {
    let src = repo.appendingPathComponent("src", isDirectory: true)
    try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    try "text\n".write(to: src.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    let baseline = try await commit(repo)

    // Build a valid second artifact
    try await git(["checkout", "-b", "valid-branch"], at: repo)
    try "changed\n".write(to: src.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    _ = try await commit(repo)
    let validPatch = try await git(["diff", "--binary", "--no-color",
      "--src-prefix=a/", "--dst-prefix=b/", "--unified=3",
      baseline, "HEAD", "--", "."], at: repo)
    try await git(["checkout", "--detach", baseline], at: repo)

    let artifacts = [
      BenchmarkEvidenceArtifact(
        kind: .localBranch, name: "bad", patch: "this is not a valid git diff at all"),
      BenchmarkEvidenceArtifact(
        kind: .localBranch, name: "valid-branch", patch: validPatch),
    ]

    let judge = root.appendingPathComponent("judge", isDirectory: true)
    try await BenchmarkWorkspace.prepareJudge(
      repository: repo, baselineCommit: baseline, destination: judge,
      patch: "", additionalArtifacts: artifacts, process: process)

    let evidence = judge.appendingPathComponent(".llimit-evidence", isDirectory: true)

    // Manifest checks
    let manifest = try loadManifest(evidence)
    let rows = try XCTUnwrap(manifest["additionalArtifacts"] as? [[String: Any]])
    XCTAssertEqual(rows.count, 2)

    // First (malformed) – has warning, no filesDirectory, patch retained
    let badRow = rows[0]
    XCTAssertNotNil(badRow["warning"] as? String,
      "Malformed artifact must have a warning in the manifest")
    XCTAssertNil(badRow["filesDirectory"] as? String,
      "Malformed artifact must not have filesDirectory")
    XCTAssertEqual(badRow["patchFile"] as? String, "artifact-1.patch")
    XCTAssertTrue(FileManager.default.fileExists(atPath: evidence.appendingPathComponent("artifact-1.patch").path))
    // No artifact-1/ directory
    XCTAssertFalse(FileManager.default.fileExists(atPath: evidence.appendingPathComponent("artifact-1").path),
      "Malformed artifact must not leave behind an artifact-1/ directory")

    // Second (valid) – materializes normally
    let goodRow = rows[1]
    XCTAssertEqual(goodRow["filesDirectory"] as? String, "artifact-2")
    XCTAssertNil(goodRow["warning"] as? String)
    let goodFile = try String(contentsOf: evidence.appendingPathComponent("artifact-2/src/file.txt"))
    XCTAssertEqual(goodFile, "changed\n",
      "Valid second artifact must still materialize correctly")
  }

  // MARK: - Test 5: Symlink pointing outside artifact view – rejected

  func test_symlinkEscaping_rejected() async throws {
    let src = repo.appendingPathComponent("src", isDirectory: true)
    try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    try "content\n".write(to: src.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    let baseline = try await commit(repo)

    // Create a sentinel file outside the judge area.
    let sentinel = root.appendingPathComponent("sentinel.txt")
    try "untouched\n".write(to: sentinel, atomically: true, encoding: .utf8)

    // Craft a patch that adds a symlink pointing outside the artifact view.
    // We use a synthetic patch because git diff --no-index is unreliable for
    // symlinks across platforms.
    let outsideTarget = sentinel.path
    let symlinkPatch = """
diff --git a/src/escape-link b/src/escape-link
new file mode 120000
--- /dev/null
+++ b/src/escape-link
@@ -0,0 +1 @@
+\(outsideTarget)

"""

    let artifact = BenchmarkEvidenceArtifact(
      kind: .localBranch, name: "symlink-escape", patch: symlinkPatch)

    let judge = root.appendingPathComponent("judge", isDirectory: true)
    try await BenchmarkWorkspace.prepareJudge(
      repository: repo, baselineCommit: baseline, destination: judge,
      patch: "", additionalArtifacts: [artifact], process: process)

    let evidence = judge.appendingPathComponent(".llimit-evidence", isDirectory: true)

    let manifest = try loadManifest(evidence)
    let rows = try XCTUnwrap(manifest["additionalArtifacts"] as? [[String: Any]])
    let row = rows[0]
    XCTAssertNotNil(row["warning"] as? String,
      "Escaping symlink artifact must produce a warning")
    XCTAssertNil(row["filesDirectory"] as? String,
      "Escaping symlink artifact must not have filesDirectory")

    // Sentinel untouched
    let sentinelContent = try String(contentsOf: sentinel)
    XCTAssertEqual(sentinelContent, "untouched\n",
      "Outside sentinel must remain untouched")

    // No readable escaping symlink in any artifact directory
    XCTAssertFalse(FileManager.default.fileExists(atPath: evidence.appendingPathComponent("artifact-1").path),
      "No artifact directory should exist for a rejected symlink artifact")
  }

  // MARK: - Test 6: Malicious patch paths – .git/config, ../outside, mode160000

  func test_maliciousPaths_rejectedIndependently() async throws {
    let src = repo.appendingPathComponent("src", isDirectory: true)
    try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    try "safe\n".write(to: src.appendingPathComponent("safe.txt"), atomically: true, encoding: .utf8)
    let baseline = try await commit(repo)

    // Sentinel files that must not be written.
    let outsideFile = root.appendingPathComponent("outside.txt")
    let sourceFile = repo.appendingPathComponent("injected.txt")

    // Three independent malicious patches.
    let gitConfigPatch = """
diff --git a/.git/config b/.git/config
new file mode 100644
--- /dev/null
+++ b/.git/config
@@ -0,0 +1,3 @@
+[remote "malicious"]
+ url = https://evil.example.com
+ fetch = +refs/heads/*:refs/remotes/malicious/*

"""

    let outsidePathPatch = """
diff --git a/../outside.txt b/../outside.txt
new file mode 100644
--- /dev/null
+++ b/../outside.txt
@@ -0,0 +1 @@
+escaped content

"""

    let submodulePatch = """
diff --git a/submod b/submod
new file mode 160000
--- /dev/null
+++ b/submod
@@ -0,0 +1 @@
+Subproject commit \(baseline)

"""

    let artifacts = [
      BenchmarkEvidenceArtifact(kind: .localBranch, name: "git-config", patch: gitConfigPatch),
      BenchmarkEvidenceArtifact(kind: .localBranch, name: "outside-path", patch: outsidePathPatch),
      BenchmarkEvidenceArtifact(kind: .localBranch, name: "submodule", patch: submodulePatch),
    ]

    let judge = root.appendingPathComponent("judge", isDirectory: true)
    try await BenchmarkWorkspace.prepareJudge(
      repository: repo, baselineCommit: baseline, destination: judge,
      patch: "", additionalArtifacts: artifacts, process: process)

    let evidence = judge.appendingPathComponent(".llimit-evidence", isDirectory: true)
    let manifest = try loadManifest(evidence)
    let rows = try XCTUnwrap(manifest["additionalArtifacts"] as? [[String: Any]])
    XCTAssertEqual(rows.count, 3)

    // Each must have a warning and no filesDirectory
    for (i, row) in rows.enumerated() {
      XCTAssertNotNil(row["warning"] as? String,
        "Artifact \(i + 1) must have a warning")
      XCTAssertNil(row["filesDirectory"] as? String,
        "Artifact \(i + 1) must not have filesDirectory")
    }

    // No outside writes
    XCTAssertFalse(FileManager.default.fileExists(atPath: outsideFile.path),
      "../outside.txt must not be created")
    XCTAssertFalse(FileManager.default.fileExists(atPath: sourceFile.path),
      "Source repo must not be written to")

    // .git/config in judge must be the original (from clone), not the patched one
    let gitConfig = judge.appendingPathComponent(".git/config")
    if FileManager.default.fileExists(atPath: gitConfig.path) {
      let configContent = try String(contentsOf: gitConfig)
      XCTAssertFalse(configContent.contains("malicious"),
        ".git/config must not contain the injected remote")
    }
  }

  // MARK: - Helpers

  @discardableResult
  private func git(_ arguments: [String], at directory: URL) async throws -> String {
    var environment = BenchmarkProcess.defaultEnvironment()
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    environment["GIT_TERMINAL_PROMPT"] = "0"
    let result = try await process.run(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: arguments, directory: directory, timeout: 15, environment: environment)
    XCTAssertEqual(result.status, 0, "git \(arguments.joined(separator: " ")) failed: \(result.stderr)")
    return result.stdout
  }

  @discardableResult
  private func commit(_ directory: URL) async throws -> String {
    try await git(["add", "--all"], at: directory)
    try await git(["-c", "user.name=Artifact Test", "-c", "user.email=test@llimit.invalid",
      "commit", "--quiet", "-m", "Fixture"], at: directory)
    let head = try await git(["rev-parse", "--verify", "HEAD^{commit}"], at: directory)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return head
  }

  private func loadManifest(_ evidence: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: evidence.appendingPathComponent("manifest.json"))
    guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      XCTFail("manifest.json must be a valid JSON object")
      throw NSError(domain: "BenchmarkArtifactFileViewTests", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Invalid manifest.json"])
    }
    return manifest
  }
}
