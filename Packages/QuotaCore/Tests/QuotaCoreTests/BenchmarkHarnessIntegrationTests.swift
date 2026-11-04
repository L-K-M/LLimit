import Foundation
import XCTest
@testable import QuotaCore

final class BenchmarkHarnessIntegrationTests: XCTestCase {
  func testOpenCodeRecoversOnlyItsOwnCompletedReceiptAndKeepsFinalPublicOutput() async throws {
    let fixture = try HarnessFixture()
    defer { fixture.remove() }
    let sessionID = "ses_fixture_recovery"
    let stream = try jsonLine([
      "type": "text", "sessionID": sessionID,
      "part": ["id": "prt_stream", "messageID": "msg_final", "sessionID": sessionID,
               "type": "text", "text": "Provisional stream text."]
    ])
    let finalText = "Task completed from the saved receipt."
    let receipt = try completionReceipt(sessionID: sessionID, text: finalText)
    let marker = fixture.root.appendingPathComponent("export-calls")
    let executable = try fakeOpenCode(fixture: fixture, stream: stream, receipt: receipt,
                                     exportMarker: marker)
    let report = try await run(fixture: fixture, executable: executable)
    let trial = try XCTUnwrap(report.runs.first)

    XCTAssertEqual(trial.outcome, .completed)
    XCTAssertEqual(trial.output, finalText)
    XCTAssertEqual(trial.tokenUsage, BenchmarkTokenUsage(inputTokens: 112, cachedInputTokens: 32, outputTokens: 22))
    XCTAssertEqual(trial.evaluations.count, 2)
    XCTAssertTrue(trial.evaluations.allSatisfy { $0.isValid && $0.accepted == true })
    XCTAssertEqual(trial.isAccepted, true)
    XCTAssertEqual(try String(contentsOf: marker), "export \(sessionID) --pure\n")
    let stored = try XCTUnwrap(BenchmarkReportStore(directory: fixture.reports).load(id: report.id))
    XCTAssertEqual(stored.runs.first?.output, finalText)
    let serialized = String(decoding: try JSONEncoder().encode(stored), as: UTF8.self)
    for discarded in ["private-tool-secret", "private-reasoning", "ignored-text", "synthetic-text", "Provisional stream", "Earlier commentary"] {
      XCTAssertFalse(serialized.contains(discarded), "Discarded native trace was persisted: \(discarded)")
    }
  }

  func testOpenCodeAmbiguousSessionsErrorsAndFailedProcessNeverExportOrReachJudges() async throws {
    let sessionID = "ses_fixture_recovery"
    let textEvent: [String: Any] = [
      "type": "text", "sessionID": sessionID,
      "part": ["id": "prt_stream", "messageID": "msg_final", "sessionID": sessionID,
               "type": "text", "text": "Incomplete result."]
    ]
    let first = try jsonLine(textEvent)
    let other = try jsonLine([
      "type": "text", "sessionID": "ses_unrelated",
      "part": ["id": "prt_other", "messageID": "msg_other", "sessionID": "ses_unrelated",
               "type": "text", "text": "Unrelated session."]
    ])
    let error = try jsonLine(["type": "error", "sessionID": sessionID,
                              "error": ["message": "private-tool-secret"]])
    for (name, stream, status) in [("ambiguous", first + other, 0), ("error", first + error, 0),
                                    ("failed-process", first, 7)] {
      let fixture = try HarnessFixture()
      defer { fixture.remove() }
      let marker = fixture.root.appendingPathComponent("export-calls")
      let judgesMarker = fixture.root.appendingPathComponent("judge-calls")
      let executable = try fakeOpenCode(fixture: fixture, stream: stream,
        receipt: completionReceipt(sessionID: sessionID, text: "Must not be recovered."),
        exportMarker: marker, status: status)
      let report = try await run(fixture: fixture, executable: executable, judgesMarker: judgesMarker)
      let trial = try XCTUnwrap(report.runs.first)
      XCTAssertEqual(trial.outcome, .failed, name)
      XCTAssertEqual(trial.isAccepted, false, name)
      XCTAssertTrue(trial.evaluations.isEmpty, name)
      XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), name)
      XCTAssertFalse(FileManager.default.fileExists(atPath: judgesMarker.path), name)
      XCTAssertFalse(trial.output.contains("private-tool-secret"), name)
    }
  }

  func testOpenCodeDiscoveryReadsCommittedProjectSettingsInCleanTemporaryClone() async throws {
    let fixture = try HarnessFixture()
    defer { fixture.remove() }
    let configuration = fixture.repository.appendingPathComponent("opencode.json")
    let committed = #"{"fixtureModel":"fixture/committed-model"}"#
    try committed.write(to: configuration, atomically: true, encoding: .utf8)
    _ = try fixture.git(["add", "opencode.json"])
    _ = try fixture.git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                         "commit", "--quiet", "-m", "Project model configuration"])
    let dirty = #"{"fixtureModel":"fixture/dirty-model"}"#
    try dirty.write(to: configuration, atomically: true, encoding: .utf8)
    let untracked = fixture.repository.appendingPathComponent("untracked-private.txt")
    try "source-only data".write(to: untracked, atomically: true, encoding: .utf8)
    let originalStatus = try fixture.git(["status", "--porcelain"])
    let marker = fixture.root.appendingPathComponent("discovery-directory")
    let executable = try fixture.executable("""
      test "$#" = 2 && test "$1" = models && test "$2" = --pure || exit 40
      test "$OPENCODE_DISABLE_MODELS_FETCH" = 1 && test "$OPENCODE_DISABLE_AUTOUPDATE" = 1 || exit 41
      test "$(cat opencode.json)" = \(shellQuote(committed)) || exit 42
      test -z "$(/usr/bin/git status --porcelain)" || exit 43
      test ! -e untracked-private.txt || exit 44
      pwd > \(shellQuote(marker.path))
      printf '%s\\n' fixture/committed-model
      """)

    let models = try await BenchmarkHarnessDiscovery().models(for: .opencode, executable: executable,
      repository: fixture.repository, plugins: .disabled)

    XCTAssertEqual(models, [BenchmarkHarnessModel(harness: .opencode, provider: "fixture",
      modelID: "committed-model", displayName: "committed-model", pluginPolicy: .disabled)])
    let clone = URL(fileURLWithPath: try String(contentsOf: marker).trimmingCharacters(in: .whitespacesAndNewlines))
    XCTAssertNotEqual(clone, fixture.repository)
    XCTAssertTrue(clone.deletingLastPathComponent().lastPathComponent.hasPrefix("llimit-models-"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: clone.deletingLastPathComponent().path))
    XCTAssertEqual(try String(contentsOf: configuration), dirty)
    XCTAssertEqual(try String(contentsOf: untracked), "source-only data")
    XCTAssertEqual(try fixture.git(["status", "--porcelain"]), originalStatus)
  }

  private func fakeOpenCode(fixture: HarnessFixture, stream: String, receipt: String,
                            exportMarker: URL, status: Int = 0) throws -> URL {
    try fixture.executable("""
      case "$1" in
        run)
          cat >/dev/null
          printf '%s' \(shellQuote(stream))
          exit \(status)
          ;;
        export)
          test "$#" = 3 && test "$2" = ses_fixture_recovery && test "$3" = --pure || exit 45
          printf '%s %s %s\\n' "$1" "$2" "$3" >> \(shellQuote(exportMarker.path))
          printf '%s\\n' \(shellQuote(receipt))
          ;;
        *) exit 46 ;;
      esac
      """)
  }

  private func run(fixture: HarnessFixture, executable: URL, judgesMarker: URL? = nil) async throws -> BenchmarkReport {
    let command = BenchmarkHarnessModel(harness: .opencode, provider: "fixture", modelID: "offline",
      displayName: "Offline fixture").command(executable: executable.path, judge: false)
    let verdict = #"{"accepted":true,"score":9,"explanation":"The supplied fixture result meets the task."}"#
    let judges = ["First", "Second"].map { name in
      var script = "cat >/dev/null\n"
      if let judgesMarker { script += "printf '%s\\n' \(shellQuote(name)) >> \(shellQuote(judgesMarker.path))\n" }
      script += "printf '%s\\n' \(shellQuote(verdict))"
      return BenchmarkJudge(name: name, command: BenchmarkCommand(executable: "/bin/sh", arguments: ["-c", script]))
    }
    let plan = BenchmarkPlan(taskPrompt: "Complete the offline fixture task.", rubric: "Return the required fixture result.",
      repositoryPath: fixture.repository.path, repetitions: 1, timeoutSeconds: 5,
      candidates: [BenchmarkCandidate(name: "OpenCode fixture", command: command)], judges: judges)
    return try await BenchmarkRunner().run(plan: plan, directory: fixture.reports,
      quotaReader: { _ in throw BenchmarkError.unavailableAccount })
  }

  private func completionReceipt(sessionID: String, text: String) throws -> String {
    func assistant(id: String, created: Int, input: Int, cached: Int, output: Int, finish: String) -> [String: Any] {
      ["id": id, "sessionID": sessionID, "role": "assistant", "parentID": "msg_user",
       "time": ["created": created, "completed": created + 1], "finish": finish,
       "modelID": "offline", "providerID": "fixture", "mode": "build", "agent": "build",
       "path": ["cwd": "/fixture", "root": "/fixture"], "cost": 0,
       "tokens": ["input": input, "output": output, "reasoning": 99, "cache": ["read": cached, "write": 7]]]
    }
    func part(id: String, message: String, type: String, values: [String: Any]) -> [String: Any] {
      ["id": id, "sessionID": sessionID, "messageID": message, "type": type].merging(values) { _, new in new }
    }
    let messages: [[String: Any]] = [
      ["info": ["id": "msg_user", "sessionID": sessionID, "role": "user", "time": ["created": 1],
                "agent": "build", "model": ["modelID": "offline", "providerID": "fixture"]], "parts": []],
      ["info": assistant(id: "msg_tools", created: 2, input: 11, cached: 3, output: 5, finish: "tool-calls"),
       "parts": [part(id: "prt_old", message: "msg_tools", type: "text", values: ["text": "Earlier commentary"]),
                 part(id: "prt_tool", message: "msg_tools", type: "tool", values: ["tool": "bash", "callID": "call_fixture",
                   "state": ["status": "completed", "input": ["command": "fixture"], "output": "private-tool-secret",
                             "title": "Fixture tool", "metadata": [:], "time": ["start": 2, "end": 3]]])]],
      ["info": assistant(id: "msg_final", created: 4, input: 101, cached: 29, output: 17, finish: "stop"),
       "parts": [part(id: "prt_reasoning", message: "msg_final", type: "reasoning", values: ["text": "private-reasoning"]),
                 part(id: "prt_ignored", message: "msg_final", type: "text", values: ["text": "ignored-text", "ignored": true]),
                 part(id: "prt_synthetic", message: "msg_final", type: "text", values: ["text": "synthetic-text", "synthetic": true]),
                 part(id: "prt_final", message: "msg_final", type: "text", values: ["text": text, "time": ["start": 4, "end": 5]])]]
    ]
    return try jsonLine(["info": ["id": sessionID], "messages": messages])
  }

  private func jsonLine(_ value: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) + "\n"
  }

  private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}

private struct HarnessFixture {
  let root: URL
  var repository: URL { root.appendingPathComponent("repository", isDirectory: true) }
  var reports: URL { root.appendingPathComponent("reports", isDirectory: true) }

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("llimit-harness-fixture-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    _ = try git(["-c", "init.templateDir=", "init", "--quiet"])
    try "baseline\n".write(to: repository.appendingPathComponent("fixture.txt"), atomically: true, encoding: .utf8)
    _ = try git(["add", "fixture.txt"])
    _ = try git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--quiet", "-m", "Baseline"])
  }

  func executable(_ script: String) throws -> URL {
    let executable = root.appendingPathComponent("fake-opencode")
    try ("#!/bin/sh\nset -eu\n" + script + "\n").write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return executable
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
    let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
      throw NSError(domain: "BenchmarkHarnessFixture", code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: String(decoding: diagnostics, as: UTF8.self)])
    }
    return String(decoding: data, as: UTF8.self)
  }
}
