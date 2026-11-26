import Foundation
import XCTest
@testable import QuotaCore

final class BenchmarkWorkspaceEvidenceTests: XCTestCase {
  private var directory: URL!
  private var source: URL!
  private var trial: URL!
  private var baseline: String!
  private var process: BenchmarkProcess!

  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("llimit-evidence-tests-\(UUID().uuidString)", isDirectory: true)
    source = directory.appendingPathComponent("source", isDirectory: true)
    trial = directory.appendingPathComponent("trial", isDirectory: true)
    process = BenchmarkProcess()
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try await git(["init", "--quiet"], at: source)
    try "baseline\n".write(to: source.appendingPathComponent("task.txt"), atomically: true, encoding: .utf8)
    try await commitFiles(at: source)
    baseline = try await BenchmarkWorkspace.commit(repository: source, process: process)
    try await BenchmarkWorkspace.create(repository: source, commit: baseline, destination: trial, process: process)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: directory)
  }

  func testCapturesBranchWorkAfterReturningToBaseline() async throws {
    try await git(["checkout", "-b", "candidate-result"], at: trial)
    try "branch result\n".write(to: trial.appendingPathComponent("task.txt"), atomically: true, encoding: .utf8)
    try await commitFiles(at: trial)
    try await git(["checkout", "--detach", baseline], at: trial)
    let evidence = try await BenchmarkWorkspace.captureEvidence(directory: trial, baselineCommit: baseline, process: process)
    XCTAssertEqual(evidence.patch, "")
    let artifact = try XCTUnwrap(evidence.additionalArtifacts.first)
    XCTAssertEqual(artifact.kind, .localBranch)
    XCTAssertEqual(artifact.name, "candidate-result")
    XCTAssertTrue(artifact.patch.contains("+branch result"), "Completed branch work must remain available after HEAD returns to baseline")
    XCTAssertTrue(evidence.warnings.isEmpty)
    XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("task.txt")), "baseline\n")
  }

  func testIgnoredDependencySymlinksDoNotHideCandidateChanges() async throws {
    let ignored = trial.appendingPathComponent("ignored-deps")
    try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: false)
    try "ignored-deps/\n".write(to: trial.appendingPathComponent(".git/info/exclude"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: ignored.appendingPathComponent("sdk"), withDestinationURL: source)
    try "candidate result\n".write(to: trial.appendingPathComponent("task.txt"), atomically: true, encoding: .utf8)
    let captured = try await BenchmarkWorkspace.captureEvidence(directory: trial, baselineCommit: baseline, process: process)
    XCTAssertTrue(captured.patch.contains("+candidate result"))
    XCTAssertFalse(captured.patch.contains("ignored-deps"))
  }

  func testCapturesDirtyRegisteredExternalWorktree() async throws {
    let worktree = directory.appendingPathComponent("external-trial", isDirectory: true)
    try await git(["worktree", "add", "-b", "external-result", worktree.path, baseline], at: trial)
    try "worktree result\n".write(to: worktree.appendingPathComponent("task.txt"), atomically: true, encoding: .utf8)
    let evidence = try await BenchmarkWorkspace.captureEvidence(directory: trial, baselineCommit: baseline, process: process)
    XCTAssertEqual(evidence.patch, "")
    let artifact = try XCTUnwrap(evidence.additionalArtifacts.first)
    XCTAssertEqual(artifact.kind, .linkedWorktree)
    XCTAssertTrue(artifact.patch.contains("+worktree result"), "Registered linked worktree changes must remain available for judging")
    XCTAssertTrue(evidence.warnings.isEmpty)
    XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("task.txt")), "baseline\n")
  }

  func testDeduplicatesIdenticalRootBranchAndWorktreePatches() async throws {
    try await git(["checkout", "-b", "candidate-result"], at: trial)
    try "same result\n".write(to: trial.appendingPathComponent("task.txt"), atomically: true, encoding: .utf8)
    try await commitFiles(at: trial)
    try await git(["branch", "duplicate-result"], at: trial)
    let worktree = directory.appendingPathComponent("duplicate-worktree")
    try await git(["worktree", "add", worktree.path, "duplicate-result"], at: trial)
    let evidence = try await BenchmarkWorkspace.captureEvidence(directory: trial, baselineCommit: baseline, process: process)
    XCTAssertTrue(evidence.patch.contains("+same result"))
    XCTAssertTrue(evidence.additionalArtifacts.isEmpty)
    XCTAssertTrue(evidence.warnings.isEmpty)
  }

  func testSkipsMissingAndReusedForeignWorktreeDirectories() async throws {
    let missing = directory.appendingPathComponent("missing-worktree")
    let reused = directory.appendingPathComponent("reused-worktree")
    try await git(["worktree", "add", "-b", "missing-result", missing.path, baseline], at: trial)
    try await git(["worktree", "add", "-b", "reused-result", reused.path, baseline], at: trial)
    try FileManager.default.removeItem(at: missing)
    try FileManager.default.removeItem(at: reused)
    try FileManager.default.createDirectory(at: reused, withIntermediateDirectories: false)
    try await git(["init", "--quiet"], at: reused)
    try "foreign private file\n".write(to: reused.appendingPathComponent("foreign.txt"), atomically: true, encoding: .utf8)
    let evidence = try await BenchmarkWorkspace.captureEvidence(directory: trial, baselineCommit: baseline, process: process)
    XCTAssertTrue(evidence.additionalArtifacts.isEmpty)
    XCTAssertTrue(evidence.warnings.contains { $0.contains("missing-worktree") })
    XCTAssertTrue(evidence.warnings.contains { $0.contains("reused-worktree") })
    let foreignStatus = try await git(["status", "--porcelain"], at: reused)
    XCTAssertTrue(foreignStatus.contains("?? foreign.txt"), "Foreign files must not even be added to an index")
  }

  func testSkipsBranchThatDoesNotDescendFromBaseline() async throws {
    try await git(["checkout", "--orphan", "unrelated"], at: trial)
    try "unrelated\n".write(to: trial.appendingPathComponent("task.txt"), atomically: true, encoding: .utf8)
    try await commitFiles(at: trial)
    try await git(["checkout", "--detach", baseline], at: trial)
    let evidence = try await BenchmarkWorkspace.captureEvidence(directory: trial, baselineCommit: baseline, process: process)
    XCTAssertTrue(evidence.additionalArtifacts.isEmpty)
    XCTAssertTrue(evidence.warnings.contains { $0.contains("unrelated") })
  }

  func testCaptureNeverExecutesConfiguredCleanOrProcessFilters() async throws {
    let cleanMarker = trial.appendingPathComponent("clean-filter-ran")
    let processMarker = trial.appendingPathComponent("process-filter-ran")
    try "*.txt filter=malicious\n".write(to: trial.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
    try "changed\n".write(to: trial.appendingPathComponent("task.txt"), atomically: true, encoding: .utf8)
    try await git(["config", "filter.malicious.clean", "touch clean-filter-ran; cat"], at: trial)
    try await git(["config", "filter.malicious.smudge", "touch clean-filter-ran; cat"], at: trial)
    try await git(["config", "filter.malicious.process", "touch process-filter-ran; exit 1"], at: trial)
    try await git(["config", "filter.malicious.required", "true"], at: trial)
    let evidence = try await BenchmarkWorkspace.captureEvidence(directory: trial, baselineCommit: baseline, process: process)
    XCTAssertTrue(evidence.patch.contains("+changed"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: cleanMarker.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: processMarker.path))
  }

  func testRejectsEscapingSymlinksBeforeCapturingFiles() async throws {
    try FileManager.default.createSymbolicLink(at: trial.appendingPathComponent("escape"), withDestinationURL: source)
    do {
      _ = try await BenchmarkWorkspace.captureEvidence(directory: trial, baselineCommit: baseline, process: process)
      XCTFail("Escaping links must fail before evidence capture")
    } catch BenchmarkWorkspaceError.unsafePath {}
  }

  func testIncludesOnlyReservedHandoffWhenIgnoredWithoutCommittingIt() async throws {
    let sourceExcludes = source.appendingPathComponent(".git/info/exclude")
    let originalSourceExcludes = try String(contentsOf: sourceExcludes)
    let handoffName = "LLIMIT_BENCHMARK_RESULT.md"
    let researchName = "LLIMIT_RESEARCH.md"
    try "*.md\nprivate-build/\n".write(to: trial.appendingPathComponent(".git/info/exclude"), atomically: true, encoding: .utf8)
    try "Full research handoff\n".write(to: trial.appendingPathComponent(handoffName), atomically: true, encoding: .utf8)
    try "Complete reserved research findings\n".write(to: trial.appendingPathComponent(researchName), atomically: true, encoding: .utf8)
    try "Ignored private notes\n".write(to: trial.appendingPathComponent("private-notes.md"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: trial.appendingPathComponent("private-build"), withIntermediateDirectories: false)
    try "Ignored credential-like data\n".write(to: trial.appendingPathComponent("private-build/private.txt"), atomically: true, encoding: .utf8)
    let evidence = try await BenchmarkWorkspace.captureEvidence(directory: trial, baselineCommit: baseline, process: process)
    XCTAssertTrue(evidence.patch.contains(handoffName))
    XCTAssertTrue(evidence.patch.contains("+Full research handoff"))
    XCTAssertTrue(evidence.patch.contains(researchName))
    XCTAssertTrue(evidence.patch.contains("+Complete reserved research findings"))
    XCTAssertFalse(evidence.patch.contains("Ignored private notes"))
    XCTAssertFalse(evidence.patch.contains("Ignored credential-like data"))
    let head = try await git(["rev-parse", "HEAD"], at: trial).trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertEqual(head, baseline)
    let staged = try await git(["diff", "--cached", "--name-only"], at: trial)
    XCTAssertEqual(staged, "", "Intent-to-add must not stage the handoff's contents")
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent(handoffName).path))
    XCTAssertEqual(try String(contentsOf: sourceExcludes), originalSourceExcludes)
  }

  func testIgnoredReservedResearchMustBeARegularFile() async throws {
    try "*.md\n".write(to: trial.appendingPathComponent(".git/info/exclude"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: trial.appendingPathComponent("LLIMIT_RESEARCH.md"),
      withDestinationURL: trial.appendingPathComponent("task.txt"))
    do {
      _ = try await BenchmarkWorkspace.captureEvidence(directory: trial, baselineCommit: baseline, process: process)
      XCTFail("The reserved research output must not follow a symbolic link")
    } catch BenchmarkWorkspaceError.invalidEvidence {}
  }

  func testMaterializesPrimaryPatchAndPrivateAdditionalEvidenceForJudge() async throws {
    try "candidate result\n".write(to: trial.appendingPathComponent("task.txt"), atomically: true, encoding: .utf8)
    // Candidate-local presentation preferences must not turn frozen evidence
    // into colored, prefix-free, or context-free text which cannot be applied.
    try await git(["config", "color.ui", "always"], at: trial)
    try await git(["config", "diff.noprefix", "true"], at: trial)
    try await git(["config", "diff.context", "0"], at: trial)
    let evidence = try await BenchmarkWorkspace.captureEvidence(directory: trial, baselineCommit: baseline, process: process)
    let judge = directory.appendingPathComponent("judge")
    let artifact = BenchmarkEvidenceArtifact(kind: .localBranch, name: "alternate", patch: "alternate patch bytes\n")
    try await BenchmarkWorkspace.prepareJudge(repository: source, baselineCommit: baseline, destination: judge,
      patch: evidence.patch, additionalArtifacts: [artifact], process: process)
    XCTAssertEqual(try String(contentsOf: judge.appendingPathComponent("task.txt")), "candidate result\n")
    XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("task.txt")), "baseline\n")
    let sidecars = judge.appendingPathComponent(".llimit-evidence")
    let directoryMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: sidecars.path)[.posixPermissions] as? NSNumber)
    XCTAssertEqual(directoryMode.intValue & 0o777, 0o700)
    for file in try FileManager.default.contentsOfDirectory(at: sidecars, includingPropertiesForKeys: nil) {
      let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
      let isDirectory = try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
      XCTAssertEqual(mode.intValue & 0o777, isDirectory ? 0o700 : 0o600, file.lastPathComponent)
    }
    XCTAssertEqual(try String(contentsOf: sidecars.appendingPathComponent("artifact-1.patch")), artifact.patch)
    let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sidecars.appendingPathComponent("manifest.json"))) as? [String: Any])
    XCTAssertEqual(manifest["baselineCommit"] as? String, baseline)
    let judgeBaseline = try await git(["rev-parse", "HEAD"], at: judge).trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertEqual(judgeBaseline, baseline)
  }

  func testRejectsUnapplicableJudgePatchWithFixedError() async throws {
    let judge = directory.appendingPathComponent("judge")
    do {
      try await BenchmarkWorkspace.prepareJudge(repository: source, baselineCommit: baseline, destination: judge,
        patch: "malformed patch with private payload", additionalArtifacts: [], process: process)
      XCTFail("Unapplicable evidence must fail")
    } catch BenchmarkWorkspaceError.invalidEvidence {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: judge.path))
    XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("task.txt")), "baseline\n")
  }

  func testJudgePatchCannotWriteOutsideItsCheckout() async throws {
    let judge = directory.appendingPathComponent("judge")
    let patch = """
    diff --git a/../outside.txt b/../outside.txt
    new file mode 100644
    --- /dev/null
    +++ b/../outside.txt
    @@ -0,0 +1 @@
    +outside payload

    """
    do {
      try await BenchmarkWorkspace.prepareJudge(repository: source, baselineCommit: baseline, destination: judge,
        patch: patch, additionalArtifacts: [], process: process)
      XCTFail("A patch must not write outside its judge checkout")
    } catch BenchmarkWorkspaceError.invalidEvidence {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("outside.txt").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: judge.path))
  }

  @discardableResult
  private func git(_ arguments: [String], at directory: URL) async throws -> String {
    var environment = BenchmarkProcess.defaultEnvironment()
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    let result = try await process.run(executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: arguments,
      directory: directory, timeout: 15, environment: environment)
    XCTAssertEqual(result.status, 0, result.stderr)
    return result.stdout
  }

  private func commitFiles(at directory: URL) async throws {
    try await git(["add", "--all"], at: directory)
    try await git(["-c", "user.name=Evidence Test", "-c", "user.email=evidence@example.invalid", "commit", "--quiet", "-m", "Fixture"], at: directory)
  }
}
