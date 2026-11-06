import Foundation
import XCTest
@testable import QuotaCore

final class BenchmarkJudgeInspectionTests: XCTestCase {
  func testMigrationPreservesModelsArgumentsAndPluginPolicy() throws {
    for disabledPlugins in [true] {
      let original = piCommand(disabledPlugins: disabledPlugins)
      let inspector = try XCTUnwrap(BenchmarkJudgeInspection.enablingInspection(in: original))
      XCTAssertEqual(inspector.executable, original.executable)
      XCTAssertTrue(inspector.arguments.contains("selected-provider"))
      XCTAssertTrue(inspector.arguments.contains("selected/model"))
      XCTAssertTrue(inspector.arguments.contains("high"))
      XCTAssertEqual(inspector.arguments.contains("--no-extensions"), disabledPlugins)
      XCTAssertTrue(inspector.arguments.contains("--no-approve"))
      XCTAssertTrue(inspector.arguments.contains("--no-mcp"))
      XCTAssertFalse(inspector.arguments.contains("bash"))
      XCTAssertEqual(BenchmarkJudgeInspection.enablingInspection(in: inspector), inspector)
      XCTAssertTrue(original.arguments.contains("--no-tools"))
    }
    XCTAssertNil(BenchmarkJudgeInspection.enablingInspection(in: piCommand(disabledPlugins: false)),
      "Configured extensions must remain unchanged rather than bypass the inspection guard")
    let claude = BenchmarkCommand(executable: "/fixture/claude", arguments: ["-p", "--output-format", "json", "--tools", "", "--model", "selected-model"], outputFormat: .claudeJSON)
    let inspector = try XCTUnwrap(BenchmarkJudgeInspection.enablingInspection(in: claude))
    XCTAssertTrue(inspector.arguments.contains("selected-model"))
    XCTAssertTrue(inspector.arguments.contains("--restricted"))
    XCTAssertTrue(inspector.arguments.contains("Read,Glob,Grep"))
    XCTAssertTrue(inspector.arguments.contains("dontAsk"))
    XCTAssertTrue(inspector.arguments.contains("--disable-slash-commands"))
    XCTAssertTrue(inspector.arguments.contains(#"{"mcpServers":{}}"#))
    XCTAssertFalse(inspector.arguments.contains("bypassPermissions"))
    XCTAssertEqual(BenchmarkJudgeInspection.enablingInspection(in: inspector), inspector)
  }

  func testCustomCommandsAndConflictingPermissionsAreNotRewritten() {
    for command in [
      BenchmarkCommand(executable: "/fixture/custom", arguments: ["--no-tools"], outputFormat: .piJSON),
      BenchmarkCommand(executable: "/fixture/claude", arguments: ["-p", "--output-format", "json", "--tools", "", "--permission-mode", "bypassPermissions"], outputFormat: .claudeJSON),
      BenchmarkCommand(executable: "/fixture/opencode", arguments: ["run", "--format", "json", "--agent", "custom-agent"], outputFormat: .opencodeJSON),
      BenchmarkCommand(executable: "/fixture/custom", arguments: ["{prompt}"])
    ] {
      XCTAssertNil(BenchmarkJudgeInspection.enablingInspection(in: command))
    }
  }

  func testGeneratedCodexReadOnlyCommandAlreadyInspectsWithoutChangingCustomCommands() {
    let command = BenchmarkCommand(executable: "/fixture/codex", arguments: ["exec", "--json", "--sandbox", "read-only", "-"], outputFormat: .codexJSON)
    XCTAssertEqual(BenchmarkJudgeInspection.enablingInspection(in: command), command)
    var custom = command
    custom.arguments = ["exec", "--json", "--sandbox", "workspace-write", "-"]
    XCTAssertNil(BenchmarkJudgeInspection.enablingInspection(in: custom))
  }

  func testExistingOpenCodeEvidenceAgentStillDeniesToolsAndMigrationIsIndependent() throws {
    let name = BenchmarkHarness.makeJudgeAgentName()
    let command = BenchmarkCommand(executable: "/fixture/opencode", arguments: ["run", "--format", "json", "--pure", "--model", "selected/model", "--agent", name], outputFormat: .opencodeJSON)
    let environment = BenchmarkHarness.environment(for: command)
    let data = try XCTUnwrap(environment["OPENCODE_CONFIG_CONTENT"]?.data(using: .utf8))
    let configuration = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let agents = try XCTUnwrap(configuration["agent"] as? [String: [String: Any]])
    XCTAssertEqual(agents[name]?["permission"] as? [String: String], ["*": "deny"])
    let inspector = try XCTUnwrap(BenchmarkJudgeInspection.enablingInspection(in: command))
    XCTAssertTrue(inspector.arguments.contains("--pure"))
    XCTAssertTrue(inspector.arguments.contains("selected/model"))
    XCTAssertFalse(inspector.arguments.contains(name))
    XCTAssertEqual(BenchmarkJudgeInspection.enablingInspection(in: inspector), inspector)
  }

  func testPiGuardAllowsWorkspaceReadsAndRejectsGitExternalAndSymlinkTargets() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("llimit-inspection-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = root.appendingPathComponent("judge")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
    try "visible result".write(to: workspace.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
    try "outside marker".write(to: root.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: workspace.appendingPathComponent(".git"), withIntermediateDirectories: false)
    try "git marker".write(to: workspace.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("escape"), withDestinationURL: root.appendingPathComponent("outside.txt"))
    let command = try XCTUnwrap(BenchmarkJudgeInspection.enablingInspection(in: piCommand()))
    let prepared = try BenchmarkJudgeInspection.prepare(command: command, directory: workspace)
    XCTAssertThrowsError(try BenchmarkJudgeInspection.validateExecution(command: command, directory: workspace))
    XCTAssertTrue(prepared.arguments.contains("--no-builtin-tools"), "Readers must come from the explicit guard, not unrestricted built-ins")
    XCTAssertTrue(prepared.arguments.contains("--tools"))
    let index = try XCTUnwrap(prepared.arguments.firstIndex(of: "--extension"))
    let guardFile = URL(fileURLWithPath: prepared.arguments[index + 1])
    let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: guardFile.path)[.posixPermissions] as? NSNumber)
    XCTAssertEqual(mode.intValue, 0o600)
    // Replace only the host SDK dependency; the actual guard executes below.
    let portableGuard = root.appendingPathComponent("guard-fixture.mjs")
    let guardSource = try String(contentsOf: guardFile).replacingOccurrences(
      of: "import { createReadOnlyTools } from \"@mariozechner/pi-coding-agent\";",
      with: "const createReadOnlyTools = () => [\"read\", \"grep\", \"find\", \"ls\"].map(name => ({ name }));")
    try guardSource.write(to: portableGuard, atomically: true, encoding: .utf8)
    let fixture = root.appendingPathComponent("check.mjs")
    let guardJSON = String(decoding: try JSONEncoder().encode(portableGuard.absoluteString), as: UTF8.self)
    let script = #"""
      import assert from "node:assert/strict";
      const handlers = {};
      let active = [];
      const registered = [];
      const extension = await import(\#(guardJSON));
      extension.default({ on: (name, callback) => { handlers[name] = callback; }, setActiveTools: (names) => { active = names; }, getActiveTools: () => active, registerTool: tool => { registered.push(tool.name); } });
      assert.deepEqual(active, []);
      assert.deepEqual(registered, ["read", "grep", "find", "ls"]);
      handlers.before_agent_start();
      assert.deepEqual(active, ["read", "grep", "find", "ls"]);
      const call = (toolName, path) => handlers.tool_call({ toolName, input: { path } });
      assert.equal(call("read", "result.txt"), undefined);
      for (const path of ["../outside.txt", "/etc/passwd", "escape", ".git/config", ".git/../result.txt"]) {
        assert.equal(call("read", path).block, true);
      }
      assert.equal(call("bash", ".").block, true);
      assert.equal(call("edit", "result.txt").block, true);
      const search = { toolName: "grep", input: { path: ".", glob: "**" } };
      assert.equal(handlers.tool_call(search), undefined);
      assert.equal(search.input.glob, "!**/.git/**");
      const listed = handlers.tool_result({ toolName: "find", content: [{ type: "text", text: "visible.txt\n.git/config\n.git/" }] });
      assert.equal(listed.content[0].text, "visible.txt");
      """#
    try script.write(to: fixture, atomically: true, encoding: .utf8)
    let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) }
    guard let node else { throw XCTSkip("Node is needed to execute the generated Pi guard fixture") }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: node)
    process.arguments = [fixture.path]
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    try BenchmarkJudgeInspection.validateExecution(command: command, directory: workspace)
    try BenchmarkJudgeInspection.validateExecution(command: prepared, directory: workspace)
    let ready = workspace.appendingPathComponent(".llimit-evidence/inspection-ready")
    try FileManager.default.removeItem(at: ready)
    try FileManager.default.createSymbolicLink(at: ready, withDestinationURL: root.appendingPathComponent("outside.txt"))
    XCTAssertThrowsError(try BenchmarkJudgeInspection.validateExecution(command: command, directory: workspace))
  }

  func testPreparationRejectsSymlinkedEvidenceDirectory() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("llimit-inspection-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".llimit-evidence"), withDestinationURL: root.deletingLastPathComponent())
    let command = try XCTUnwrap(BenchmarkJudgeInspection.enablingInspection(in: piCommand()))
    XCTAssertThrowsError(try BenchmarkJudgeInspection.prepare(command: command, directory: root))
  }

  private func piCommand(disabledPlugins: Bool = true) -> BenchmarkCommand {
    BenchmarkCommand(executable: "/fixture/pi", arguments: ["--mode", "json", "--print", "--no-session", "--offline", "--provider", "selected-provider", "--model", "selected/model", "--thinking", "high", "--no-tools", "--no-skills", "--no-context-files", "--no-prompt-templates"] + (disabledPlugins ? ["--no-extensions"] : []), outputFormat: .piJSON)
  }
}
