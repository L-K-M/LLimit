import Foundation
import XCTest
@testable import QuotaCore

final class BenchmarkEvidenceHandoffTests: XCTestCase {
  func testAcceptancePreflightUsesCommittedDisposableCopyAndReportsFailure() async throws {
    let fixture = try EvidenceFixture()
    defer { fixture.remove() }
    try "uncommitted input".write(to: fixture.repository.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
    let result = try await BenchmarkAcceptanceCheck().check(repository: fixture.repository,
      command: "test \"$(cat source.txt)\" = baseline && printf verified-baseline && touch generated.txt && exit 7", timeout: 10)
    XCTAssertFalse(result.passed)
    XCTAssertEqual(result.exitCode, 7)
    XCTAssertTrue(result.output.contains("verified-baseline"))
    XCTAssertEqual(try String(contentsOf: fixture.repository.appendingPathComponent("source.txt")), "uncommitted input")
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.repository.appendingPathComponent("generated.txt").path))
  }

  func testAcceptancePreflightRecordsPassAndRedactsOutput() async throws {
    let fixture = try EvidenceFixture()
    defer { fixture.remove() }
    let secret = "acceptance-test-private-key"
    let configuration = ProviderRuntimeConfiguration(provider: .junie, isEnabled: true,
      credentials: [CredentialField.junieAPIKey: secret])
    let result = try await BenchmarkAcceptanceCheck().check(repository: fixture.repository,
      command: "printf '\(secret)'; exit 0", timeout: 10, redactor: BenchmarkRedactor(configurations: [configuration]))
    XCTAssertTrue(result.passed)
    XCTAssertFalse(result.output.contains(secret))
    XCTAssertTrue(result.output.contains("[redacted]"))
  }

  func testJudgeReceivesCandidateFilesAndSameExecutionRules() async throws {
    let fixture = try EvidenceFixture()
    defer { fixture.remove() }
    let prompt = fixture.root.appendingPathComponent("judge-prompt.txt")
    let judge = """
      cat > '\(prompt.path)'
      if test "$(cat solution.txt 2>/dev/null)" = verified-change; then
        printf '%s' '{"accepted":true,"score":8,"explanation":"Verified candidate file"}'
      else
        printf '%s' '{"accepted":false,"score":0,"explanation":"Candidate file missing"}'
      fi
      """
    let report = try await BenchmarkRunner().run(plan: fixture.plan(
      agent: "cat >/dev/null; printf verified-change > solution.txt; printf Done", judge: judge),
      directory: fixture.reports, quotaReader: { _ in throw BenchmarkError.unavailableAccount })
    XCTAssertEqual(report.runs.first?.isAccepted, true)
    let evidence = try String(contentsOf: prompt)
    XCTAssertTrue(evidence.contains("Do not penalize"))
    XCTAssertTrue(evidence.contains("push"))
  }

  func testBranchWorkSurvivesReturningToBaselineBeforeJudging() async throws {
    let fixture = try EvidenceFixture()
    defer { fixture.remove() }
    let prompt = fixture.root.appendingPathComponent("judge-prompt.txt")
    let agent = """
      set -e
      cat >/dev/null
      baseline=$(git rev-parse HEAD)
      git -c core.hooksPath=/dev/null checkout -b completed-work >/dev/null 2>&1
      printf verified-branch-change > solution.txt
      git -c core.hooksPath=/dev/null add solution.txt
      git -c core.hooksPath=/dev/null -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm Result
      git -c core.hooksPath=/dev/null checkout --detach "$baseline" >/dev/null 2>&1
      printf Done
      """
    let judge = """
      cat > '\(prompt.path)'
      evidence=$(cat '\(prompt.path)')
      if printf '%s' "$evidence" | /usr/bin/grep -q verified-branch-change; then
        printf '%s' '{"accepted":true,"score":8,"explanation":"Branch artifact supplied"}'
      else
        printf '%s' '{"accepted":false,"score":0,"explanation":"Branch artifact missing"}'
      fi
      """
    let report = try await BenchmarkRunner().run(plan: fixture.plan(agent: agent, judge: judge),
      directory: fixture.reports, quotaReader: { _ in throw BenchmarkError.unavailableAccount })
    let run = try XCTUnwrap(report.runs.first)
    XCTAssertEqual(run.outcome, .completed)
    XCTAssertEqual(run.patch, "")
    XCTAssertTrue(run.evidence?.additionalArtifacts.contains { $0.patch.contains("verified-branch-change") } == true)
    XCTAssertEqual(run.isAccepted, true)
    let judgePrompt = try String(contentsOf: prompt)
    XCTAssertTrue(judgePrompt.contains("the baseline with no primary file changes"))
    XCTAssertFalse(judgePrompt.contains("the primary candidate changes applied to the baseline"))
  }

  func testReevaluationPreservesOriginalAndNeverRunsCandidatesAgain() async throws {
    let fixture = try EvidenceFixture()
    defer { fixture.remove() }
    let marker = fixture.root.appendingPathComponent("candidate-ran")
    let plan = fixture.plan(agent: "cat >/dev/null; touch '\(marker.path)'; printf candidate > solution.txt; printf Done",
      judge: "cat >/dev/null; printf '%s' '{\"accepted\":true,\"score\":8,\"explanation\":\"Original assessment\"}'")
    let runner = BenchmarkRunner()
    var original = try await runner.run(plan: plan, directory: fixture.reports,
      quotaReader: { _ in throw BenchmarkError.unavailableAccount })
    original.runs[0].durationSeconds = 12.5
    original.runs[0].estimatedCost = 0.75
    try BenchmarkReportStore(directory: fixture.reports).save(original)
    try FileManager.default.removeItem(at: marker)
    // The pinned baseline must remain usable after the source project moves.
    try FileManager.default.moveItem(at: fixture.repository, to: fixture.root.appendingPathComponent("moved-source"))
    let judges = original.plan.judges.map {
      BenchmarkJudge(id: $0.id, name: $0.name, command: BenchmarkCommand(executable: "/bin/sh", arguments: ["-c",
        "cat >/dev/null; printf '%s' '{\"accepted\":true,\"score\":9,\"explanation\":\"New assessment\"}'"]))
    }
    let refreshed = try await runner.reevaluate(report: original, directory: fixture.reports, judges: judges)
    XCTAssertNotEqual(refreshed.id, original.id)
    XCTAssertEqual(refreshed.reevaluationOf, original.id)
    XCTAssertEqual(refreshed.artifactReportID, original.id)
    XCTAssertEqual(refreshed.executionProtocol, original.executionProtocol)
    XCTAssertEqual(refreshed.runs[0].id, original.runs[0].id)
    XCTAssertEqual(refreshed.runs[0].durationSeconds, 12.5)
    XCTAssertEqual(refreshed.runs[0].estimatedCost, 0.75)
    XCTAssertEqual(refreshed.runs[0].patch, original.runs[0].patch)
    XCTAssertEqual(refreshed.runs[0].evaluations.map(\.score), [9, 9])
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    let saved = try XCTUnwrap(BenchmarkReportStore(directory: fixture.reports).load(id: original.id))
    XCTAssertEqual(saved.runs[0].evaluations.map(\.score), [8, 8])
    XCTAssertEqual(try BenchmarkReportStore(directory: fixture.reports).list().count, 2)
  }

  func testBranchOnlyResultDoesNotFailAcceptanceAgainstUnchangedBaseline() async throws {
    let fixture = try EvidenceFixture()
    defer { fixture.remove() }
    let agent = """
      set -e
      cat >/dev/null
      baseline=$(git rev-parse HEAD)
      git -c core.hooksPath=/dev/null checkout -b result >/dev/null 2>&1
      printf candidate > solution.txt
      git -c core.hooksPath=/dev/null add solution.txt
      git -c core.hooksPath=/dev/null -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm Result
      git -c core.hooksPath=/dev/null checkout --detach "$baseline" >/dev/null 2>&1
      printf Done
      """
    var plan = fixture.plan(agent: agent,
      judge: "cat >/dev/null; printf '%s' '{\"accepted\":true,\"score\":8,\"explanation\":\"Branch change supplied\"}'")
    plan.acceptanceCommand = "test -f solution.txt"
    let report = try await BenchmarkRunner().run(plan: plan, directory: fixture.reports,
      quotaReader: { _ in throw BenchmarkError.unavailableAccount })
    let run = try XCTUnwrap(report.runs.first)
    XCTAssertEqual(run.outcome, .completed)
    XCTAssertNil(run.acceptancePassed)
    XCTAssertNotNil(run.acceptanceUnavailableReason)
    XCTAssertNil(run.isAccepted)
  }

  func testNewRunRecordsExecutionProtocolAndPromptsContainHandoffInstructions() async throws {
    let fixture = try EvidenceFixture()
    defer { fixture.remove() }
    let candidatePrompt = fixture.root.appendingPathComponent("candidate-prompt.txt")
    let judgePrompt = fixture.root.appendingPathComponent("judge-prompt.txt")
    let agent = """
      cat > '\(candidatePrompt.path)'
      printf verified-change > solution.txt
      printf Done
      """
    let judge = """
      cat > '\(judgePrompt.path)'
      printf '%s' '{"accepted":true,"score":8,"explanation":"Verified"}'
      """
    var plan = fixture.plan(agent: agent, judge: judge)
    plan.acceptanceCommand = "test -f solution.txt"
    let report = try await BenchmarkRunner().run(plan: plan,
      directory: fixture.reports, quotaReader: { _ in throw BenchmarkError.unavailableAccount })
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let json = try JSONSerialization.jsonObject(with: encoder.encode(report), options: []) as? [String: Any]
    XCTAssertEqual(json?["executionProtocol"] as? String, "preservedArtifactsV1")
    let cPrompt = try String(contentsOf: candidatePrompt)
    let jPrompt = try String(contentsOf: judgePrompt)
    XCTAssertTrue(cPrompt.contains("LLIMIT_BENCHMARK_RESULT.md"),
      "Candidate prompt should contain LLIMIT_BENCHMARK_RESULT.md instruction")
    XCTAssertTrue(jPrompt.contains("LLIMIT_BENCHMARK_RESULT.md"),
      "Judge prompt should contain LLIMIT_BENCHMARK_RESULT.md instruction")
    XCTAssertTrue(jPrompt.contains("the primary candidate changes applied to the baseline"))
    XCTAssertTrue(cPrompt.contains("test -f solution.txt"))
    XCTAssertTrue(jPrompt.contains("test -f solution.txt"))
  }

  func testLegacyReevaluationNeverGivesCurrentExecutionRulesToOldCandidates() async throws {
    let fixture = try EvidenceFixture()
    defer { fixture.remove() }
    let agent = """
      cat >/dev/null
      printf verified-change > solution.txt
      printf Done
      """
    let judge = """
      cat >/dev/null
      printf '%s' '{"accepted":true,"score":8,"explanation":"Original"}'
      """
    let runner = BenchmarkRunner()
    var original = try await runner.run(plan: fixture.plan(agent: agent, judge: judge),
      directory: fixture.reports, quotaReader: { _ in throw BenchmarkError.unavailableAccount })
    original.runs[0].durationSeconds = 5.0
    original.runs[0].estimatedCost = 0.1
    // Recovered evidence is present, but cannot identify the original rules.
    let store = BenchmarkReportStore(directory: fixture.reports)
    try store.save(original)
    let fileURL = fixture.reports.appendingPathComponent(original.id.uuidString.lowercased()).appendingPathExtension("json")
    var jsonDict = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
    jsonDict.removeValue(forKey: "executionProtocol")
    let data = try JSONSerialization.data(withJSONObject: jsonDict, options: [.sortedKeys])
    try data.write(to: fileURL, options: .atomic)
    let legacy = try XCTUnwrap(store.load(id: original.id))
    XCTAssertNil(legacy.executionProtocol)
    XCTAssertNotNil(legacy.runs[0].evidence)
    let judgeStdin1 = fixture.root.appendingPathComponent("judge-stdin-1.txt")
    let judgeStdin2 = fixture.root.appendingPathComponent("judge-stdin-2.txt")
    let reevalJudges = original.plan.judges.map {
      BenchmarkJudge(id: $0.id, name: $0.name, command: BenchmarkCommand(executable: "/bin/sh", arguments: ["-c",
        "cat > '\(judgeStdin1.path)'; printf '%s' '{\"accepted\":true,\"score\":9,\"explanation\":\"Reeval 1\"}'"]))
    }
    let refreshed1 = try await runner.reevaluate(report: legacy, directory: fixture.reports, judges: reevalJudges)
    let saved = try XCTUnwrap(store.load(id: refreshed1.id))
    let reevalJudges2 = refreshed1.plan.judges.map {
      BenchmarkJudge(id: $0.id, name: $0.name, command: BenchmarkCommand(executable: "/bin/sh", arguments: ["-c",
        "cat > '\(judgeStdin2.path)'; printf '%s' '{\"accepted\":true,\"score\":9,\"explanation\":\"Reeval 2\"}'"]))
    }
    let refreshed2 = try await runner.reevaluate(report: saved, directory: fixture.reports, judges: reevalJudges2)
    for url in [judgeStdin1, judgeStdin2] {
      let prompt = try String(contentsOf: url)
      XCTAssertFalse(prompt.contains("Before finishing, write LLIMIT_BENCHMARK_RESULT.md"))
      XCTAssertFalse(prompt.contains("Benchmark execution rules given to the agent:"))
      XCTAssertTrue(prompt.contains("The original benchmark execution rules were not recorded"))
      XCTAssertTrue(prompt.contains("complete snapshots relative to the benchmark baseline"))
      XCTAssertTrue(prompt.contains("Repeated changes may be inherited from a shared ancestor"))
    }
    for refreshed in [refreshed1, refreshed2] {
      let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(refreshed)) as? [String: Any])
      XCTAssertNil(json["executionProtocol"])
      XCTAssertEqual(refreshed.runs[0].id, original.runs[0].id)
      XCTAssertEqual(refreshed.runs[0].durationSeconds, 5.0)
      XCTAssertEqual(refreshed.runs[0].estimatedCost, 0.1)
    }
  }

  func testLegacyWorkspaceMatchingRefusesAmbiguousOrEscapingDirectories() throws {
    let fixture = try EvidenceFixture()
    defer { fixture.remove() }
    var run = BenchmarkRun(candidateID: UUID(), repetition: 1, startedAt: Date().addingTimeInterval(-10))
    var report = BenchmarkReport(baselineCommit: String(repeating: "a", count: 40), plan: fixture.plan(agent: "", judge: ""), runs: [run])
    report.finishedAt = Date().addingTimeInterval(10)
    let root = fixture.reports.appendingPathComponent(report.id.uuidString)
    let first = root.appendingPathComponent("trial-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    if try first.resourceValues(forKeys: [.creationDateKey]).creationDate != nil {
      XCTAssertEqual(try BenchmarkEvidenceLocator.workspace(for: run, in: report, directory: fixture.reports)?.path, first.path)
      try FileManager.default.createDirectory(at: root.appendingPathComponent("trial-\(UUID().uuidString)"), withIntermediateDirectories: false)
      XCTAssertNil(try BenchmarkEvidenceLocator.workspace(for: run, in: report, directory: fixture.reports))
    }
    run.evidence = BenchmarkEvidence(workspaceName: "../source")
    XCTAssertNil(try BenchmarkEvidenceLocator.workspace(for: run, in: report, directory: fixture.reports))
  }

  func testNewEvidenceTextIsRedactedWithoutCorruptingArtifactReferences() throws {
    let plan = BenchmarkPlan(taskPrompt: "Task", rubric: "Rubric", repositoryPath: "/tmp", candidates: [], judges: [])
    let name = "trial-11111111-1111-1111-1111-111111111111"
    let evidence = BenchmarkEvidence(workspaceName: name, additionalArtifacts: [
      BenchmarkEvidenceArtifact(kind: .localBranch, name: "private branch 1", patch: "+credential=1")
    ], warnings: ["private warning 1"], captureComplete: false)
    let run = BenchmarkRun(candidateID: UUID(), repetition: 1, patch: "+credential=1", evidence: evidence,
      acceptanceUnavailableReason: "private reason 1", costUnavailableReason: "private cost 1")
    let source = UUID()
    let report = BenchmarkReport(baselineCommit: String(repeating: "a", count: 40), plan: plan, runs: [run],
      reevaluationOf: source, artifactReportID: source, executionProtocol: .preservedArtifactsV1)
    let configuration = ProviderRuntimeConfiguration(provider: .junie, isEnabled: true,
      credentials: [CredentialField.junieAPIKey: "1"])
    let safe = try BenchmarkRedactor(configurations: [configuration]).redact(report)
    XCTAssertEqual(safe.runs[0].patch, "+credential=[redacted]")
    XCTAssertEqual(safe.runs[0].evidence?.additionalArtifacts[0].patch, "+credential=[redacted]")
    XCTAssertEqual(safe.runs[0].evidence?.additionalArtifacts[0].name, "private branch [redacted]")
    XCTAssertEqual(safe.runs[0].evidence?.warnings, ["private warning [redacted]"])
    XCTAssertEqual(safe.runs[0].acceptanceUnavailableReason, "private reason [redacted]")
    XCTAssertEqual(safe.runs[0].costUnavailableReason, "private cost [redacted]")
    XCTAssertEqual(safe.runs[0].evidence?.workspaceName, name)
    XCTAssertEqual(safe.artifactReportID, source)
    XCTAssertEqual(safe.reevaluationOf, source)
    XCTAssertEqual(safe.executionProtocol, .preservedArtifactsV1)
  }
}

private struct EvidenceFixture {
  let root: URL
  var repository: URL { root.appendingPathComponent("source") }
  var reports: URL { root.appendingPathComponent("reports") }

  init() throws {
    root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("llimit-evidence-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    try "baseline".write(to: repository.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
    for arguments in [["init", "-q"], ["add", "."],
      ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "Baseline"]] {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      process.arguments = ["-c", "core.hooksPath=/dev/null"] + arguments
      process.currentDirectoryURL = repository
      process.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { throw BenchmarkWorkspaceError.gitFailed }
    }
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  func plan(agent: String, judge: String) -> BenchmarkPlan {
    let command = BenchmarkCommand(executable: "/bin/sh", arguments: ["-c", judge])
    return BenchmarkPlan(taskPrompt: "Complete the local change and publish a PR.", rubric: "Verify the supplied implementation.",
      repositoryPath: repository.path, repetitions: 1, timeoutSeconds: 20,
      candidates: [BenchmarkCandidate(name: "Fixture", command: BenchmarkCommand(executable: "/bin/sh", arguments: ["-c", agent]))],
      judges: [BenchmarkJudge(name: "First", command: command), BenchmarkJudge(name: "Second", command: command)])
  }
}
