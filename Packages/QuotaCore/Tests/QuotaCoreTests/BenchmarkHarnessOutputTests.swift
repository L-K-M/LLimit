import Foundation
import XCTest
@testable import QuotaCore

final class BenchmarkHarnessOutputTests: XCTestCase {
  func testPiUsesFinalAssistantAndCountsEachReportedCallOnce() throws {
    let planning = piMessage("Planning only", reason: "toolUse", input: 5, output: 2, cached: 3)
    var final = piMessage("Finished work.", input: 7, output: 4, cached: 6)
    final["content"] = [["type": "thinking", "thinking": "private-thinking"],
                        ["type": "text", "text": "Finished work."]]
    let end: [String: Any] = ["type": "agent_end", "messages": [planning,
      ["role": "toolResult", "content": [["type": "text", "text": "private-tool-output"]]], final]]
    let output = try lines([
      ["type": "session", "id": "session"],
      ["type": "agent_start"],
      ["type": "message_end", "message": planning],
      ["type": "message_end", "message": final], end, end
    ])
    let decoded = BenchmarkOutput.decode(output, format: .piJSON)
    XCTAssertTrue(decoded.succeeded)
    XCTAssertEqual(decoded.text, "Finished work.")
    XCTAssertFalse(decoded.text.contains("private-"))
    XCTAssertEqual(decoded.tokenUsage, BenchmarkTokenUsage(inputTokens: 12, cachedInputTokens: 9, outputTokens: 6))
  }

  func testPiRequiresCompletedAgentAndFinalStopReason() throws {
    for reason in ["error", "aborted", "length", "toolUse"] {
      let output = try lines([["type": "agent_end", "messages": [piMessage("Not complete", reason: reason)]]])
      XCTAssertFalse(BenchmarkOutput.decode(output, format: .piJSON).succeeded, reason)
    }
    for events: [[String: Any]] in [
      [["type": "session", "id": "session"]],
      [["type": "message_end", "message": piMessage("Not terminal")]],
      [["type": "agent_end", "messages": []]],
      [["type": "agent_end", "messages": [piMessage("Done")]], ["type": "agent_start"]]
    ] {
      XCTAssertFalse(BenchmarkOutput.decode(try lines(events), format: .piJSON).succeeded)
    }
  }

  func testPiRejectsMalformedRecordsAndMissingFinalText() throws {
    let valid = try lines([["type": "agent_end", "messages": [piMessage("Done")]]])
    XCTAssertFalse(BenchmarkOutput.decode("not-json\n" + valid, format: .piJSON).succeeded)
    XCTAssertFalse(BenchmarkOutput.decode("{}\n" + valid, format: .piJSON).succeeded)
    XCTAssertFalse(BenchmarkOutput.decode(try lines([["type": "agent_end", "messages": "invalid"]]), format: .piJSON).succeeded)
    var final = piMessage("unused")
    final["content"] = [["type": "thinking", "thinking": "private-thinking"]]
    XCTAssertFalse(BenchmarkOutput.decode(try lines([["type": "agent_end", "messages": [final]]]), format: .piJSON).succeeded)
  }

  func testOpenCodeUsesFinalMessageAndDeduplicatesUsageAndTextParts() throws {
    let firstFinish = finish("m1", id: "finish1", reason: "tool-calls", input: 5, output: 2, cached: 3)
    let lastFinish = finish("m2", id: "finish2", input: 7, output: 4, cached: 6)
    let finalText = text("m2", id: "text2", value: "Finished work.")
    let output = try lines([
      start("m1", id: "start1"), text("m1", id: "text1", value: "Planning only"),
      ["type": "tool_use", "part": ["id": "tool1", "messageID": "m1", "state": ["output": "private-tool-output"]]],
      firstFinish, start("m2", id: "start2"),
      ["type": "reasoning", "part": ["id": "thinking", "messageID": "m2", "text": "private-thinking"]],
      finalText, text("m2", id: "text3", value: "Tests passed."), lastFinish,
      firstFinish, lastFinish, finalText
    ])
    let decoded = BenchmarkOutput.decode(output, format: .opencodeJSON)
    XCTAssertTrue(decoded.succeeded)
    XCTAssertEqual(decoded.text, "Finished work.\nTests passed.")
    XCTAssertFalse(decoded.text.contains("private-"))
    XCTAssertEqual(decoded.tokenUsage, BenchmarkTokenUsage(inputTokens: 12, cachedInputTokens: 9, outputTokens: 6))
  }

  func testOpenCodeRequiresFinalStopAndNoLaterUnfinishedStep() throws {
    let complete = [start("m1", id: "start1"), text("m1", id: "text1", value: "Done"), finish("m1", id: "finish1")]
    for later in [start("m2", id: "start2"), start("m1", id: "start2"),
                  ["type": "tool_use", "part": ["id": "tool2", "messageID": "m1"]]] {
      XCTAssertFalse(BenchmarkOutput.decode(try lines(complete + [later]), format: .opencodeJSON).succeeded)
    }
    for reason in ["tool-calls", "length", "error", "unknown"] {
      let output = try lines([text("m1", id: "t", value: "Not complete"), finish("m1", id: "f", reason: reason)])
      XCTAssertFalse(BenchmarkOutput.decode(output, format: .opencodeJSON).succeeded, reason)
    }
    XCTAssertFalse(BenchmarkOutput.decode(try lines([text("m1", id: "t", value: "No terminal event")]), format: .opencodeJSON).succeeded)
  }

  func testOpenCodeUsesOnlyFinalStepTextWhenAMessageHasSeveralSteps() throws {
    let output = try lines([
      start("m1", id: "start1"), text("m1", id: "planning", value: "Planning only"),
      finish("m1", id: "finish1", reason: "tool-calls", input: 5, output: 2, cached: 3),
      start("m1", id: "start2"), text("m1", id: "answer", value: "Final answer"),
      finish("m1", id: "finish2", input: 7, output: 4, cached: 6)
    ])
    let decoded = BenchmarkOutput.decode(output, format: .opencodeJSON)
    XCTAssertTrue(decoded.succeeded)
    XCTAssertEqual(decoded.text, "Final answer")
    XCTAssertEqual(decoded.tokenUsage, BenchmarkTokenUsage(inputTokens: 12, cachedInputTokens: 9, outputTokens: 6))
  }

  func testOpenCodeErrorFailsWithoutExposingDiagnostics() throws {
    let output = try lines([
      text("m1", id: "text1", value: "Done"), finish("m1", id: "finish1"),
      ["type": "error", "error": ["message": "private-auth-diagnostic"]]
    ])
    let decoded = BenchmarkOutput.decode(output, format: .opencodeJSON)
    XCTAssertFalse(decoded.succeeded)
    XCTAssertFalse(decoded.text.contains("private-auth-diagnostic"))
    XCTAssertNil(decoded.tokenUsage)
  }

  func testOpenCodeAllowsTextAfterItsFinishButRejectsMalformedParts() throws {
    let output = try lines([finish("m1", id: "finish1"), text("m1", id: "text1", value: "Done")])
    XCTAssertTrue(BenchmarkOutput.decode(output, format: .opencodeJSON).succeeded)
    XCTAssertFalse(BenchmarkOutput.decode("broken\n" + output, format: .opencodeJSON).succeeded)
    XCTAssertFalse(BenchmarkOutput.decode(try lines([["type": "text", "part": ["text": "missing identity"]], finish("m1", id: "finish1")]), format: .opencodeJSON).succeeded)
    XCTAssertFalse(BenchmarkOutput.decode(try lines([finish("m1", id: "finish1")]), format: .opencodeJSON).succeeded)
  }

  func testOpenCodeDeduplicatesFinishWithoutPartIDAndDoesNotAddReasoningTokens() throws {
    var finished = finish("m1", id: "unused", input: 9, output: 4, cached: 2)
    var part = try XCTUnwrap(finished["part"] as? [String: Any])
    part["id"] = nil
    finished["part"] = part
    let decoded = BenchmarkOutput.decode(try lines([text("m1", id: "text1", value: "Done"), finished, finished]), format: .opencodeJSON)
    XCTAssertTrue(decoded.succeeded)
    XCTAssertEqual(decoded.tokenUsage, BenchmarkTokenUsage(inputTokens: 9, cachedInputTokens: 2, outputTokens: 4))
  }

  func testNativeUsageCountsAreBoundedAndCannotOverflow() throws {
    var message = piMessage("Done")
    message["usage"] = ["input": 1e300, "output": -20, "cacheRead": 1e300]
    let pi = BenchmarkOutput.decode(try lines([["type": "agent_end", "messages": [message, message]]]), format: .piJSON)
    XCTAssertEqual(pi.tokenUsage, BenchmarkTokenUsage(inputTokens: 1_000_000_000_000, cachedInputTokens: 1_000_000_000_000, outputTokens: 0))
    let giant: [String: Any] = ["type": "step_finish", "part": ["messageID": "m1", "id": "finish1", "reason": "stop",
      "tokens": ["input": 1e300, "output": -20, "cache": ["read": 1e300, "write": 10]]]]
    let openCode = BenchmarkOutput.decode(try lines([text("m1", id: "text1", value: "Done"), giant]), format: .opencodeJSON)
    XCTAssertEqual(openCode.tokenUsage, pi.tokenUsage)
  }

  func testNativeFramingUsesLFAndAcceptsCRLFWithoutSplittingTextUnicodeSeparators() throws {
    let expected = "Line A\u{2028}Line B"
    let fixtures: [(BenchmarkOutputFormat, [[String: Any]])] = [
      (.piJSON, [["type": "agent_start"], ["type": "agent_end", "messages": [piMessage(expected)]]]),
      (.opencodeJSON, [text("m1", id: "text1", value: expected), finish("m1", id: "finish1")])
    ]
    for (format, events) in fixtures {
      let output = try lines(events).replacingOccurrences(of: "\\u2028", with: "\u{2028}")
        .replacingOccurrences(of: "\n", with: "\r\n")
      let decoded = BenchmarkOutput.decode(output, format: format)
      XCTAssertTrue(decoded.succeeded)
      XCTAssertEqual(decoded.text, expected)
    }
  }

  func testOpenCodeRecoverySelectsOnlyOneSafeSessionFromStructuredEvents() throws {
    let valid: [String: Any] = ["type": "text", "sessionID": "ses_A-b_123",
      "part": ["id": "text1", "messageID": "m1", "sessionID": "ses_A-b_123", "text": "Incomplete stream"]]
    XCTAssertEqual(BenchmarkOutput.openCodeSessionForRecovery(try lines([valid, valid])), "ses_A-b_123")
    XCTAssertNil(BenchmarkOutput.openCodeSessionForRecovery(""))
    XCTAssertNil(BenchmarkOutput.openCodeSessionForRecovery("broken\n" + (try lines([valid]))))
    XCTAssertNil(BenchmarkOutput.openCodeSessionForRecovery("{}\n" + (try lines([valid]))))
    XCTAssertNil(BenchmarkOutput.openCodeSessionForRecovery(try lines([valid, ["type": "error", "sessionID": "ses_A-b_123"]])))
    XCTAssertNil(BenchmarkOutput.openCodeSessionForRecovery(try lines([valid, ["type": "text", "sessionID": "ses_other"]])))
    XCTAssertNil(BenchmarkOutput.openCodeSessionForRecovery(try lines([["type": "text", "sessionID": "ses_A", "part": ["sessionID": "ses_B"]]])))
    for invalid in ["latest", "ses_", "ses_private/path", "ses_secret\nargument", "ses_é", "ses_" + String(repeating: "a", count: 125)] {
      XCTAssertNil(BenchmarkOutput.openCodeSessionForRecovery(try lines([["type": "text", "sessionID": invalid]])), invalid)
    }
  }

  func testOpenCodeExportRecoversOnlyFinalTextAndUniqueAssistantUsage() throws {
    let planning = exportMessage("planning", role: "assistant", finish: "tool-calls", input: 5, output: 2, cached: 3,
      parts: [["id": "plan", "type": "text", "text": "Planning only"]])
    let final = exportMessage("answer", input: 7, output: 4, cached: 6, parts: [
      ["id": "thinking", "type": "reasoning", "text": "private-thinking"],
      ["id": "tool", "type": "tool", "state": ["status": "completed", "output": "private-tool-output"]],
      ["id": "ignored", "type": "text", "text": "private-ignored", "ignored": true],
      ["id": "synthetic", "type": "text", "text": "private-synthetic", "synthetic": true],
      ["id": "text1", "type": "text", "text": "Finished work."],
      ["id": "text1", "type": "text", "text": "Finished work."]
    ])
    let text = try export([exportMessage("request", role: "user"), planning, final, planning])
    let recovered = BenchmarkOutput.decodeOpenCodeExport(text, expectedSessionID: "ses_fixture")
    XCTAssertTrue(recovered.succeeded)
    XCTAssertEqual(recovered.text, "Finished work.")
    XCTAssertFalse(recovered.text.contains("private-"))
    XCTAssertEqual(recovered.tokenUsage, BenchmarkTokenUsage(inputTokens: 12, cachedInputTokens: 9, outputTokens: 6))
    XCTAssertFalse(BenchmarkOutput.decodeOpenCodeExport(text, expectedSessionID: "ses_unrelated").succeeded)
  }

  func testOpenCodeExportRejectsUnfinishedLaterMessagesAndErrors() throws {
    let final = exportMessage("answer", parts: [["id": "t", "type": "text", "text": "Done"]])
    for later in [exportMessage("later-user", role: "user"), exportMessage("later-assistant", finish: "tool-calls")] {
      XCTAssertFalse(BenchmarkOutput.decodeOpenCodeExport(try export([final, later])).succeeded)
    }
    for reason in ["length", "tool-calls", "error", ""] {
      XCTAssertFalse(BenchmarkOutput.decodeOpenCodeExport(try export([exportMessage("answer", finish: reason)])).succeeded)
    }
    var errored = final
    var info = try XCTUnwrap(errored["info"] as? [String: Any])
    info["error"] = ["message": "private-auth-error"]
    errored["info"] = info
    let result = BenchmarkOutput.decodeOpenCodeExport(try export([errored]))
    XCTAssertFalse(result.succeeded)
    XCTAssertEqual(result.text, "")
    XCTAssertNil(result.tokenUsage)
  }

  func testOpenCodeExportValidatesSessionAndOptionalCompletionTimestamp() throws {
    let final = exportMessage("answer", parts: [["id": "t", "type": "text", "text": "Done"]])
    XCTAssertFalse(BenchmarkOutput.decodeOpenCodeExport(try export([exportMessage("answer", sessionID: "ses_other")])).succeeded)
    var crossedPart = final
    crossedPart["parts"] = [["id": "t", "type": "text", "text": "Unrelated", "sessionID": "ses_other"]]
    XCTAssertFalse(BenchmarkOutput.decodeOpenCodeExport(try export([crossedPart])).succeeded)
    for value: Any in [0, -1, true, "not-a-timestamp", NSNull()] {
      var invalid = final
      var info = try XCTUnwrap(invalid["info"] as? [String: Any])
      info["time"] = ["completed": value]
      invalid["info"] = info
      XCTAssertFalse(BenchmarkOutput.decodeOpenCodeExport(try export([invalid])).succeeded)
    }
    var omitted = final
    var info = try XCTUnwrap(omitted["info"] as? [String: Any])
    info["time"] = nil
    omitted["info"] = info
    XCTAssertTrue(BenchmarkOutput.decodeOpenCodeExport(try export([omitted])).succeeded)
    XCTAssertFalse(BenchmarkOutput.decodeOpenCodeExport("not JSON").succeeded)
  }

  func testOpenCodeExportDiscardsEarlierStepTextAndRejectsNonAnswerParts() throws {
    let final = exportMessage("answer", parts: [
      ["id": "step1", "type": "step-start"], ["id": "plan", "type": "text", "text": "Planning only"],
      ["id": "step2", "type": "step-start"], ["id": "final", "type": "text", "text": "Done"]
    ])
    XCTAssertEqual(BenchmarkOutput.decodeOpenCodeExport(try export([final])).text, "Done")
    for parts: [[String: Any]] in [[], [["id": "s", "type": "text", "text": "Hidden", "synthetic": true]],
      [["id": "tool", "type": "tool", "state": ["status": "running"]], ["id": "t", "type": "text", "text": "Not finished"]]] {
      XCTAssertFalse(BenchmarkOutput.decodeOpenCodeExport(try export([exportMessage("answer", parts: parts)])).succeeded)
    }
    var summary = final
    var info = try XCTUnwrap(summary["info"] as? [String: Any])
    info["summary"] = true
    summary["info"] = info
    XCTAssertFalse(BenchmarkOutput.decodeOpenCodeExport(try export([summary])).succeeded)
  }

  private func exportMessage(_ id: String, role: String = "assistant", finish: String = "stop", sessionID: String = "ses_fixture",
                             input: Int = 1, output: Int = 1, cached: Int = 0, parts: [[String: Any]] = []) -> [String: Any] {
    ["info": ["id": id, "sessionID": sessionID, "role": role, "finish": finish,
      "time": ["created": 1_800_000_000_000, "completed": 1_800_000_000_001],
      "tokens": ["input": input, "output": output, "reasoning": 100, "cache": ["read": cached, "write": 90]],
      "path": ["cwd": "private-path", "root": "private-path"]], "parts": parts]
  }

  private func export(_ messages: [[String: Any]]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: [
      "info": ["id": "ses_fixture", "title": "private-session-title", "directory": "private-path"], "messages": messages
    ], options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
  }

  private func piMessage(_ text: String, reason: String = "stop", input: Int = 1, output: Int = 1, cached: Int = 0) -> [String: Any] {
    ["role": "assistant", "content": [["type": "text", "text": text]], "stopReason": reason,
     "usage": ["input": input, "output": output, "cacheRead": cached, "cacheWrite": 90]]
  }

  private func start(_ message: String, id: String) -> [String: Any] {
    ["type": "step_start", "part": ["messageID": message, "id": id]]
  }

  private func text(_ message: String, id: String, value: String) -> [String: Any] {
    ["type": "text", "part": ["messageID": message, "id": id, "text": value]]
  }

  private func finish(_ message: String, id: String, reason: String = "stop", input: Int = 1, output: Int = 1, cached: Int = 0) -> [String: Any] {
    ["type": "step_finish", "part": ["messageID": message, "id": id, "reason": reason,
      "tokens": ["input": input, "output": output, "reasoning": 100, "cache": ["read": cached, "write": 90]]]]
  }

  private func lines(_ events: [[String: Any]]) throws -> String {
    try events.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }.joined(separator: "\n")
  }
}
