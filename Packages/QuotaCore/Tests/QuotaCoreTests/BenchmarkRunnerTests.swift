import Foundation
import XCTest
@testable import QuotaCore

final class BenchmarkRunnerTests: XCTestCase {
  private let acceptedVerdict = #"{"accepted":true,"score":8.5,"explanation":"The supplied patch satisfies the task and acceptance evidence."}"#

  func testCodexJudgeUsesFinalResponseAfterCommentary() {
    let judge = UUID()
    let output = #"""
    {"type":"item.completed","item":{"type":"agent_message","text":"I will inspect the supplied changes."}}
    {"type":"item.completed","item":{"type":"agent_message","text":"{\"accepted\":true,\"score\":8,\"explanation\":\"The change meets the requirements.\"}"}}
    {"type":"turn.completed","usage":{"input_tokens":100,"output_tokens":20}}
    """#
    let decoded = BenchmarkOutput.decode(output, format: .codexJSON)
    XCTAssertTrue(decoded.succeeded)
    XCTAssertFalse(decoded.text.contains("I will inspect"))
    XCTAssertTrue(BenchmarkOutput.evaluation(decoded.text, judgeID: judge).isValid)
  }

  func testJudgeScoreIsParsedBeforeShortSecretRedaction() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let verdict = #"{"accepted":true,"score":10,"explanation":"Requirement 1 passed."}"#
    let judges = ["First", "Second"].map {
      BenchmarkJudge(name: $0, command: shellCommand("cat >/dev/null; printf '%s\\n' \(shellQuote(verdict))"))
    }
    let configuration = ProviderRuntimeConfiguration(provider: .junie, isEnabled: true,
      credentials: [CredentialField.junieAPIKey: "1"])
    let report = try await BenchmarkRunner().run(
      plan: makePlan(fixture: fixture, candidates: [candidate(script: "printf done")], judges: judges),
      directory: fixture.reports, redactor: BenchmarkRedactor(configurations: [configuration]),
      quotaReader: { _ in throw BenchmarkError.unavailableAccount })
    let run = try XCTUnwrap(report.runs.first)
    XCTAssertEqual(run.isAccepted, true)
    XCTAssertEqual(run.evaluations.map(\.score), [10, 10])
    XCTAssertTrue(run.evaluations.allSatisfy { $0.explanation == "Requirement [redacted] passed." })
  }

  func testJudgeExplanationRedactsBeforeTruncation() throws {
    let secret = "private-token-straddling-the-length-boundary"
    let explanation = String(repeating: "a", count: 11_995) + secret
    let json: [String: Any] = ["accepted": true, "score": 10, "explanation": explanation]
    let text = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
    let configuration = ProviderRuntimeConfiguration(provider: .junie, isEnabled: true,
      credentials: [CredentialField.junieAPIKey: secret])
    let result = BenchmarkOutput.evaluation(text, judgeID: UUID(), redactor: BenchmarkRedactor(configurations: [configuration]))
    XCTAssertTrue(result.isValid)
    XCTAssertEqual(result.explanation.count, 12_000)
    XCTAssertFalse(result.explanation.contains("priva"))
    XCTAssertTrue(result.explanation.hasSuffix("[reda"))
  }

  func testRepeatedTrialsUsePinnedCommitAndMeasureBeforeIndependentBlindJudging() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let events = fixture.root.appendingPathComponent("events.txt")
    let promptCapture = fixture.root.appendingPathComponent("judge-prompts.txt")
    let quota = QuotaFixture(events: events)
    let first = candidate(name: "PRIVATE_CANDIDATE_ALPHA", script: """
      test "$(cat source.txt)" = baseline || exit 41
      printf '%s\\n' changed > source.txt
      printf '%s\\n' generated > generated.txt
      printf '%s\\n' 'Task completed.'
      """, account: "alpha")
    let second = candidate(name: "PRIVATE_CANDIDATE_BETA", script: """
      test "$(cat source.txt)" = baseline || exit 42
      printf '%s\\n' changed > source.txt
      printf '%s\\n' generated > generated.txt
      printf '%s\\n' 'Task completed.'
      """, account: "beta")
    let judges = judgePair(capture: promptCapture, events: events)
    let plan = makePlan(fixture: fixture, candidates: [first, second], judges: judges, repetitions: 2)
    let report = try await BenchmarkRunner().run(plan: plan, directory: fixture.reports, quotaReader: { id in
      try await quota.read(id)
    })

    XCTAssertEqual(report.runs.count, 4)
    XCTAssertEqual(Set(report.runs.map(\.repetition)), [1, 2])
    XCTAssertTrue(report.runs.allSatisfy { $0.outcome == .completed && $0.isAccepted == true })
    for run in report.runs {
      XCTAssertTrue(run.patch.contains("-baseline"))
      XCTAssertTrue(run.patch.contains("+changed"))
      XCTAssertTrue(run.patch.contains("generated.txt"))
      XCTAssertTrue(run.patch.contains("+generated"))
      XCTAssertEqual(Set(run.evaluations.map(\.judgeID)), Set(judges.map(\.id)))
      XCTAssertEqual(run.estimatedCost, 0.4)
      XCTAssertEqual(run.quotaChanges.first?.consumedPercentagePoints, 2)
    }
    XCTAssertEqual(try String(contentsOf: fixture.repository.appendingPathComponent("source.txt")), "baseline\n")
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.repository.appendingPathComponent("generated.txt").path))
    XCTAssertEqual(try fixture.git(["status", "--porcelain"]), "")
    let counts = await quota.counts()
    XCTAssertEqual(counts, ["alpha": 4, "beta": 4])
    let eventLines = try String(contentsOf: events).split(separator: "\n").map(String.init)
    XCTAssertEqual(eventLines.count, 16)
    XCTAssertTrue(eventLines.prefix(8).allSatisfy { $0.hasPrefix("quota:") })
    XCTAssertTrue(eventLines.suffix(8).allSatisfy { $0.hasPrefix("judge:") })
    let prompts = try String(contentsOf: promptCapture)
    XCTAssertFalse(prompts.contains("PRIVATE_CANDIDATE_ALPHA"))
    XCTAssertFalse(prompts.contains("PRIVATE_CANDIDATE_BETA"))
    XCTAssertFalse(prompts.contains("allowanceCost"))
    XCTAssertFalse(prompts.contains("estimatedCost"))
    XCTAssertFalse(prompts.contains("alpha"))
    XCTAssertFalse(prompts.contains("beta"))
    XCTAssertTrue(prompts.contains("generated.txt"))
    XCTAssertTrue(prompts.contains(plan.rubric))
    XCTAssertTrue(prompts.contains("untrusted evidence"))
    XCTAssertNotNil(report.finishedAt)
    XCTAssertGreaterThan(report.judgeDurationSeconds, 0)
    let stored = try XCTUnwrap(BenchmarkReportStore(directory: fixture.reports).load(id: report.id))
    XCTAssertEqual(stored.runs.map(\.output), report.runs.map(\.output))
    XCTAssertEqual(stored.runs.map(\.patch), report.runs.map(\.patch))
    XCTAssertEqual(stored.runs.map(\.outcome), report.runs.map(\.outcome))
  }

  func testFailedExecutionStillConsumesQuotaAndIncreasesCostPerAcceptedTask() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let marker = shellQuote(fixture.root.appendingPathComponent("first-trial-did-run").path)
    let agent = candidate(name: "Retry-prone setup", script: """
      if ! test -f \(marker); then
        : > \(marker)
        printf '%s\\n' 'Attempt could not complete.'
        exit 7
      fi
      printf '%s\\n' 'Task completed.'
      """, account: "account")
    let quota = QuotaFixture()
    let report = try await BenchmarkRunner().run(
      plan: makePlan(fixture: fixture, candidates: [agent], repetitions: 2), directory: fixture.reports,
      quotaReader: { id in try await quota.read(id) })

    XCTAssertEqual(report.runs.map(\.outcome), [.failed, .completed])
    XCTAssertTrue(report.runs[0].evaluations.isEmpty)
    XCTAssertEqual(report.runs[0].isAccepted, false)
    XCTAssertEqual(report.runs[1].isAccepted, true)
    XCTAssertEqual(report.runs.map(\.estimatedCost), [0.4, 0.4])
    let summary = try XCTUnwrap(report.summaries.first)
    XCTAssertEqual(summary.attempts, 2)
    XCTAssertEqual(summary.acceptedCount, 1)
    XCTAssertEqual(try XCTUnwrap(summary.estimatedTotalCost), 0.8, accuracy: 0.000001)
    XCTAssertEqual(try XCTUnwrap(summary.estimatedCostPerAcceptedTask), 0.8, accuracy: 0.000001)
    let counts = await quota.counts()
    XCTAssertEqual(counts["account"], 4)
  }

  func testAcceptanceFailureOverridesBothPositiveJudges() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    var plan = makePlan(fixture: fixture, candidates: [candidate(script: "printf '%s\\n' done")])
    plan.acceptanceCommand = "printf '%s\\n' 'Required behavior is missing'; exit 12"
    let report = try await BenchmarkRunner().run(plan: plan, directory: fixture.reports, quotaReader: { _ in
      throw BenchmarkError.unavailableAccount
    })

    let run = try XCTUnwrap(report.runs.first)
    XCTAssertEqual(run.outcome, .completed)
    XCTAssertEqual(run.acceptancePassed, false)
    XCTAssertTrue(run.output.contains("Required behavior is missing"))
    XCTAssertEqual(run.evaluations.count, 2)
    XCTAssertTrue(run.evaluations.allSatisfy { $0.accepted == true })
    XCTAssertEqual(run.isAccepted, false)
    XCTAssertEqual(report.summaries.first?.acceptedCount, 0)
  }

  func testMalformedJudgeVerdictLeavesAcceptanceUnresolved() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let judges = [
      BenchmarkJudge(name: "Valid judge", command: shellCommand("printf '%s\\n' \(shellQuote(acceptedVerdict))")),
      BenchmarkJudge(name: "Invalid judge", command: shellCommand("printf '%s\\n' 'looks good to me'"))
    ]
    let plan = makePlan(fixture: fixture, candidates: [candidate(script: "printf '%s\\n' done")], judges: judges)
    let report = try await BenchmarkRunner().run(plan: plan, directory: fixture.reports, quotaReader: { _ in
      throw BenchmarkError.unavailableAccount
    })

    let run = try XCTUnwrap(report.runs.first)
    XCTAssertEqual(run.outcome, .completed)
    XCTAssertEqual(run.evaluations.filter(\.isValid).count, 1)
    XCTAssertEqual(run.evaluations.filter { $0.error != nil }.count, 1)
    XCTAssertNil(run.isAccepted)
    XCTAssertEqual(report.summaries.first?.acceptedCount, 0)
  }

  func testCancellationAfterFirstTrialPreservesPartialReportWithoutJudging() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let plan = makePlan(fixture: fixture, candidates: [candidate(script: "printf '%s\\n' done")], repetitions: 3)
    let work = Task {
      try await BenchmarkRunner().run(plan: plan, directory: fixture.reports, quotaReader: { _ in
        throw BenchmarkError.unavailableAccount
      }, update: { report, message in
        if message == "Trial recorded", report.runs.count == 1 {
          withUnsafeCurrentTask { $0?.cancel() }
        }
      })
    }
    let report = try await work.value
    XCTAssertEqual(report.runs.count, 1)
    XCTAssertEqual(report.runs.first?.outcome, .completed)
    XCTAssertTrue(report.runs.first?.evaluations.isEmpty == true)
    XCTAssertTrue(report.warnings.contains { $0.lowercased().contains("cancelled") })
    XCTAssertNotNil(report.finishedAt)
    let stored = try XCTUnwrap(BenchmarkReportStore(directory: fixture.reports).load(id: report.id))
    XCTAssertEqual(stored.runs.count, 1)
    XCTAssertEqual(stored.warnings, report.warnings)
  }

  func testCodexParserKeepsMessagesAndUsageButDiscardsToolTraces() throws {
    let output = #"""
    {"type":"thread.started","thread_id":"thread"}
    {"type":"item.completed","item":{"type":"command_execution","aggregated_output":"private-tool-diagnostic"}}
    malformed diagnostic line
    {"type":"item.completed","item":{"type":"agent_message","text":"Finished work."}}
    {"type":"turn.completed","usage":{"input_tokens":120,"cached_input_tokens":90,"output_tokens":25}}
    """#
    let decoded = BenchmarkOutput.decode(output, format: .codexJSON)
    XCTAssertTrue(decoded.succeeded)
    XCTAssertEqual(decoded.text, "Finished work.")
    XCTAssertFalse(decoded.text.contains("private-tool-diagnostic"))
    XCTAssertEqual(decoded.tokenUsage, BenchmarkTokenUsage(inputTokens: 120, cachedInputTokens: 90, outputTokens: 25))
    XCTAssertFalse(BenchmarkOutput.decode(output + "\n" + #"{"type":"turn.failed","error":{"message":"failed"}}"#, format: .codexJSON).succeeded)
    XCTAssertFalse(BenchmarkOutput.decode(#"{"type":"turn.completed"}"#, format: .codexJSON).succeeded)
    XCTAssertFalse(BenchmarkOutput.decode("not JSON", format: .codexJSON).succeeded)
  }

  func testClaudeParserRecognizesUsageErrorAndMalformedResults() {
    let output = #"{"type":"result","is_error":false,"result":"Completed.","usage":{"input_tokens":50,"cache_read_input_tokens":20,"output_tokens":9}}"#
    let decoded = BenchmarkOutput.decode(output, format: .claudeJSON)
    XCTAssertTrue(decoded.succeeded)
    XCTAssertEqual(decoded.text, "Completed.")
    XCTAssertEqual(decoded.tokenUsage, BenchmarkTokenUsage(inputTokens: 50, cachedInputTokens: 20, outputTokens: 9))
    XCTAssertFalse(BenchmarkOutput.decode(output.replacingOccurrences(of: #""is_error":false"#, with: #""is_error":true"#), format: .claudeJSON).succeeded)
    for malformed in ["not JSON", "[]", #"{"type":"result","is_error":false}"#, #"{"result":"text"}"#] {
      XCTAssertFalse(BenchmarkOutput.decode(malformed, format: .claudeJSON).succeeded)
    }
  }

  func testJudgeParserRequiresBooleanBoundedScoreAndExplanation() {
    let judge = UUID()
    let valid = BenchmarkOutput.evaluation("```json\n\(acceptedVerdict)\n```", judgeID: judge)
    XCTAssertTrue(valid.isValid)
    XCTAssertEqual(valid.judgeID, judge)
    XCTAssertEqual(valid.score, 8.5)
    for invalid in [
      #"{"accepted":true,"score":11,"explanation":"Outside score range"}"#,
      #"{"accepted":"yes","score":8,"explanation":"Wrong type"}"#,
      #"{"accepted":true,"score":8,"explanation":"  "}"#,
      #"{"accepted":true,"explanation":"No score"}"#,
      acceptedVerdict + "\nUnexpected trailing commentary"
    ] {
      let evaluation = BenchmarkOutput.evaluation(invalid, judgeID: judge)
      XCTAssertFalse(evaluation.isValid)
      XCTAssertNil(evaluation.accepted)
      XCTAssertNotNil(evaluation.error)
    }
  }

  func testRedactionRemovesCookieValuesWithoutReplacingPublicCookieMetadata() throws {
    let serialized = #"[{"name":"passToken","value":"saved-login-secret-8731","domain":"account.xiaomi.com","path":"/","secure":true,"httpOnly":true},{"name":"userId","value":"user-private-4926","domain":"account.xiaomi.com","path":"/","secure":true,"httpOnly":true}]"#
    let configurations = [
      ProviderRuntimeConfiguration(accountID: "mimo", provider: .xiaomiMiMo, isEnabled: true,
        credentials: [CredentialField.mimoBrowserSession: serialized,
                      CredentialField.mimoSessionCookies: "api-platform_serviceToken=console-secret-1984; userId=user-private-4926"]),
      ProviderRuntimeConfiguration(accountID: "mistral", provider: .mistral, isEnabled: true,
        credentials: [CredentialField.mistralSessionCookies: "ory_kratos_session=\"quoted-secret-6274\""])
    ]
    let redactor = BenchmarkRedactor(configurations: configurations)
    let publicText = "Read /tmp/project/source.swift for passToken at account.xiaomi.com and userId."
    XCTAssertEqual(redactor.redact(publicText), publicText)
    let secrets = ["saved-login-secret-8731", "user-private-4926", "console-secret-1984", "quoted-secret-6274"]
    let safe = redactor.redact(publicText + "\n" + serialized + "\n" + secrets.joined(separator: " "))
    for secret in secrets { XCTAssertFalse(safe.contains(secret)) }
    XCTAssertTrue(safe.contains("[redacted]"))
    XCTAssertTrue(safe.contains("account.xiaomi.com"))
    XCTAssertTrue(safe.contains("/tmp/project/source.swift"))
    XCTAssertTrue(safe.contains("passToken"))
    var plan = BenchmarkPlan(taskPrompt: publicText, rubric: "Do the required work.", repositoryPath: "/tmp/project",
      candidates: [candidate(script: "printf done")], judges: judgePair())
    plan.candidates[0].name = "Public / benchmark"
    let report = BenchmarkReport(baselineCommit: String(repeating: "a", count: 40), plan: plan,
      runs: [BenchmarkRun(candidateID: plan.candidates[0].id, repetition: 1,
                          output: "saved-login-secret-8731 at /tmp/project/source.swift")])
    let redacted = try redactor.redact(report)
    XCTAssertEqual(redacted.plan.repositoryPath, "/tmp/project")
    XCTAssertEqual(redacted.plan.candidates[0].name, "Public / benchmark")
    XCTAssertEqual(redacted.runs[0].output, "[redacted] at /tmp/project/source.swift")
  }

  func testJudgeEvidenceRedactsSecretsBeforeJSONEscaping() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let secret = "token/\"with\\escaped"
    let configuration = ProviderRuntimeConfiguration(provider: .junie, isEnabled: true,
      credentials: [CredentialField.junieAPIKey: secret])
    let captures = [fixture.root.appendingPathComponent("first-judge-prompt.txt"),
                    fixture.root.appendingPathComponent("second-judge-prompt.txt")]
    let judges = captures.enumerated().map { index, capture in
      BenchmarkJudge(name: "Judge \(index)", command: shellCommand(
        "cat > \(shellQuote(capture.path))\nprintf '%s\\n' \(shellQuote(acceptedVerdict))"))
    }
    let agent = candidate(script: "printf '%s\\n' \(shellQuote("Secret was " + secret))")
    let plan = makePlan(fixture: fixture, candidates: [agent], judges: judges)
    let report = try await BenchmarkRunner().run(plan: plan, directory: fixture.reports,
      redactor: BenchmarkRedactor(configurations: [configuration]), quotaReader: { _ in
        throw BenchmarkError.unavailableAccount
      })
    XCTAssertEqual(report.runs.first?.isAccepted, true)
    for capture in captures {
      let prompt = try String(contentsOf: capture)
      let evidenceText = try XCTUnwrap(prompt.components(separatedBy: "Evidence:\n").last)
      let evidence = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(evidenceText.utf8)) as? [String: String])
      XCTAssertEqual(evidence["output"], "Secret was [redacted]\n")
      XCTAssertFalse(prompt.contains(secret))
      XCTAssertFalse(evidence.values.contains { $0.contains(secret) })
    }
  }

  func testShortSecretRedactionPreservesStructuralReportValues() throws {
    let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let firstJudge = UUID(uuidString: "11111111-1111-4111-8111-111111111112")!
    let secondJudge = UUID(uuidString: "11111111-1111-4111-8111-111111111113")!
    let command = BenchmarkCommand(executable: "/tmp/agent1", arguments: ["{prompt}"], outputFormat: .codexJSON)
    let plan = BenchmarkPlan(taskPrompt: "Task 1", rubric: "Criterion 1", repositoryPath: "/tmp/repo1",
      currency: "USD", candidates: [BenchmarkCandidate(id: id, name: "Agent 1", command: command)],
      judges: [BenchmarkJudge(id: firstJudge, name: "Judge 1", command: command),
               BenchmarkJudge(id: secondJudge, name: "Judge 2", command: command)])
    let report = BenchmarkReport(id: id, baselineCommit: String(repeating: "1", count: 40), plan: plan,
      runs: [BenchmarkRun(id: id, candidateID: id, repetition: 1, outcome: .completed,
        output: "Credential 1 was present.", evaluations: [BenchmarkEvaluation(judgeID: firstJudge, accepted: true,
          score: 8, explanation: "Requirement 1 passed.")])])
    let configuration = ProviderRuntimeConfiguration(provider: .junie, isEnabled: true,
      credentials: [CredentialField.junieAPIKey: "1"])
    let safe = try BenchmarkRedactor(configurations: [configuration]).redact(report)
    XCTAssertEqual(safe.id, id)
    XCTAssertEqual(safe.plan.candidates[0].id, id)
    XCTAssertEqual(safe.plan.judges.map(\.id), [firstJudge, secondJudge])
    XCTAssertEqual(safe.runs[0].id, id)
    XCTAssertEqual(safe.runs[0].candidateID, id)
    XCTAssertEqual(safe.runs[0].evaluations[0].judgeID, firstJudge)
    XCTAssertEqual(safe.runs[0].outcome, .completed)
    XCTAssertEqual(safe.plan.candidates[0].command.outputFormat, .codexJSON)
    XCTAssertEqual(safe.plan.currency, "USD")
    XCTAssertEqual(safe.baselineCommit, String(repeating: "1", count: 40))
    XCTAssertFalse(safe.runs[0].output.contains("1"))
    XCTAssertTrue(safe.runs[0].output.contains("[redacted]"))
  }

  func testTruncatedCandidateOutputCannotBecomeSuccessfulExecution() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let script = "dd if=/dev/zero bs=1024 count=2050 2>/dev/null | tr '\\000' x"
    let plan = makePlan(fixture: fixture, candidates: [candidate(script: script)])
    let report = try await BenchmarkRunner().run(plan: plan, directory: fixture.reports, quotaReader: { _ in
      throw BenchmarkError.unavailableAccount
    })
    let run = try XCTUnwrap(report.runs.first)
    XCTAssertEqual(run.outcome, .failed)
    XCTAssertTrue(run.evaluations.isEmpty)
    XCTAssertEqual(run.isAccepted, false)
  }

  func testTruncatedJudgeOutputCannotBecomeValidVerdict() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let oversizedVerdict = "printf '%s\\n' \(shellQuote(acceptedVerdict)); dd if=/dev/zero bs=1024 count=2050 2>/dev/null | tr '\\000' ' '"
    let judges = [BenchmarkJudge(name: "Oversized judge", command: shellCommand(oversizedVerdict)),
                  BenchmarkJudge(name: "Normal judge", command: shellCommand("cat >/dev/null; printf '%s\\n' \(shellQuote(acceptedVerdict))"))]
    let plan = makePlan(fixture: fixture, candidates: [candidate(script: "printf '%s\\n' done")], judges: judges)
    let report = try await BenchmarkRunner().run(plan: plan, directory: fixture.reports, quotaReader: { _ in
      throw BenchmarkError.unavailableAccount
    })
    let run = try XCTUnwrap(report.runs.first)
    XCTAssertEqual(run.outcome, .completed)
    XCTAssertEqual(run.evaluations.filter(\.isValid).count, 1)
    XCTAssertNil(run.isAccepted)
    XCTAssertEqual(report.summaries.first?.acceptedCount, 0)
  }

  private func candidate(name: String = "Fixture agent", script: String, account: String? = nil) -> BenchmarkCandidate {
    BenchmarkCandidate(name: name, command: shellCommand(script), accountID: account,
                       quotaMetricID: account == nil ? nil : "weekly", allowanceCost: account == nil ? nil : 20)
  }

  private func shellCommand(_ script: String) -> BenchmarkCommand {
    BenchmarkCommand(executable: "/bin/sh", arguments: ["-c", script])
  }

  private func judgePair(capture: URL? = nil, events: URL? = nil) -> [BenchmarkJudge] {
    ["First", "Second"].map { name in
      var script = capture.map { "cat >> \(shellQuote($0.path))\n" } ?? "cat > /dev/null\n"
      if let events { script += "printf '%s\\n' \(shellQuote("judge:" + name)) >> \(shellQuote(events.path))\n" }
      script += "printf '%s\\n' \(shellQuote(acceptedVerdict))"
      return BenchmarkJudge(name: name + " judge", command: shellCommand(script))
    }
  }

  private func makePlan(fixture: Fixture, candidates: [BenchmarkCandidate], judges: [BenchmarkJudge]? = nil,
                        repetitions: Int = 1) -> BenchmarkPlan {
    BenchmarkPlan(taskPrompt: "Implement the requested behavior using the baseline source.",
                  rubric: "Complete the change and preserve the baseline requirements.",
                  repositoryPath: fixture.repository.path, repetitions: repetitions, timeoutSeconds: 20,
                  candidates: candidates, judges: judges ?? judgePair())
  }

  private func shellQuote(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}

private actor QuotaFixture {
  private var reads: [String: Int] = [:]
  private let events: URL?

  init(events: URL? = nil) { self.events = events }

  func read(_ id: String) throws -> ProviderUsage {
    let index = (reads[id] ?? 0) + 1
    reads[id] = index
    if let events {
      if !FileManager.default.fileExists(atPath: events.path) { _ = FileManager.default.createFile(atPath: events.path, contents: nil) }
      let file = try FileHandle(forWritingTo: events)
      defer { try? file.close() }
      try file.seekToEnd()
      try file.write(contentsOf: Data("quota:\(id)\n".utf8))
    }
    let remaining = Double(100 - 2 * index)
    return ProviderUsage(accountID: id, provider: .openAI, title: "Fixture account",
      metrics: [UsageMetric(id: "weekly", label: "Weekly", remainingPercent: Int(remaining),
                            remainingAmount: remaining, totalAmount: 100)],
      fetchedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)))
  }

  func counts() -> [String: Int] { reads }
}

private struct Fixture {
  let root: URL
  var repository: URL { root.appendingPathComponent("source", isDirectory: true) }
  var reports: URL { root.appendingPathComponent("reports", isDirectory: true) }

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("llimit-benchmark-fixture-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    _ = try git(["-c", "init.templateDir=", "init", "--quiet"])
    try "baseline\n".write(to: repository.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
    _ = try git(["add", "source.txt"])
    _ = try git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--quiet", "-m", "Baseline"])
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  @discardableResult
  func git(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-c", "core.hooksPath=/dev/null"] + arguments
    process.currentDirectoryURL = repository
    process.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
    let output = Pipe()
    let errors = Pipe()
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let error = errors.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
      throw NSError(domain: "BenchmarkFixture", code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: String(decoding: error, as: UTF8.self)])
    }
    return String(decoding: data, as: UTF8.self)
  }
}
