import Foundation

public enum BenchmarkJudgeInspectionError: Error, LocalizedError {
  case unavailable

  public var errorDescription: String? {
    "File inspection could not be enabled. Update Pi to a compatible version and retry; no judge verdict was recorded."
  }
}

/// Converts LLimit's evidence-only presets into file inspectors. Test commands
/// remain separately controlled by the benchmark's acceptance command.
public enum BenchmarkJudgeInspection {
  private static let piTools = "read,grep,find,ls"
  private static let claudeTools = "Read,Glob,Grep"

  public static func enablingInspection(in command: BenchmarkCommand) -> BenchmarkCommand? {
    var copy = command
    switch command.outputFormat {
    case .piJSON:
      guard containsPair("--mode", "json", in: command.arguments), command.arguments.contains("--print"),
            command.arguments.contains("--no-session"), command.arguments.contains("--offline"),
            command.arguments.contains("--no-extensions"),
            ["--no-skills", "--no-context-files", "--no-prompt-templates"].allSatisfy(command.arguments.contains),
            !command.arguments.contains(where: { ["--extension", "-e", "--exclude-tools", "-xt", "--no-builtin-tools", "-nbt"].contains($0)
              || ["--tools=", "--extension=", "--exclude-tools=", "-t=", "-e="].contains(where: $0.hasPrefix) }) else { return nil }
      if isPiInspector(command) { return command }
      guard command.arguments.filter({ $0 == "--no-tools" }).count == 1,
            !command.arguments.contains("--tools"), !command.arguments.contains("-t") else { return nil }
      copy.arguments.removeAll { $0 == "--no-tools" }
      copy.arguments += ["--tools", piTools, "--no-mcp", "--no-approve"]
    case .claudeJSON:
      guard command.arguments.contains("-p"), containsPair("--output-format", "json", in: command.arguments) else { return nil }
      if isClaudeInspector(command) { return command }
      guard containsPair("--tools", "", in: command.arguments), command.arguments.filter({ $0 == "--tools" }).count == 1,
            !command.arguments.contains(where: { ["--permission-mode", "--allowedTools", "--allowed-tools", "--disallowedTools", "--disallowed-tools", "--add-dir", "--settings", "--mcp-config", "--plugin-dir", "--restricted"].contains($0) }) else { return nil }
      let index = copy.arguments.firstIndex(of: "--tools")!
      copy.arguments.removeSubrange(index...index + 1)
      copy.arguments += ["--restricted", "--tools", claudeTools, "--allowedTools", claudeTools,
        "--permission-mode", "dontAsk", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
        "--disable-slash-commands"]
    case .opencodeJSON:
      guard command.arguments.first == "run", containsPair("--format", "json", in: command.arguments),
            let index = command.arguments.firstIndex(of: "--agent"), index + 1 < command.arguments.count,
            command.arguments.filter({ $0 == "--agent" }).count == 1 else { return nil }
      let name = command.arguments[index + 1]
      if BenchmarkHarness.isInspectionAgentName(name) { return command }
      guard BenchmarkHarness.isEvidenceAgentName(name) else { return nil }
      copy.arguments[index + 1] = BenchmarkHarness.makeInspectionAgentName()
    case .codexJSON:
      guard command.arguments == ["exec", "--json", "--sandbox", "read-only", "-"] else { return nil }
      return command
    default: return nil
    }
    return copy
  }

  /// Pi's built-in readers accept arbitrary paths. The explicit extension
  /// confines tool calls to this disposable workspace, without granting shell
  /// or edit tools. Built-ins stay disabled until the guard registers readers.
  public static func prepare(command: BenchmarkCommand, directory: URL) throws -> BenchmarkCommand {
    guard isPiInspector(command) else { return command }
    let root = directory.standardizedFileURL.resolvingSymlinksInPath()
    guard root == directory.standardizedFileURL,
          try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
      throw BenchmarkWorkspaceError.unsafePath
    }
    let evidence = root.appendingPathComponent(".llimit-evidence", isDirectory: true)
    if FileManager.default.fileExists(atPath: evidence.path) {
      let values = try evidence.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else { throw BenchmarkWorkspaceError.unsafePath }
    } else {
      try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    }
    let guardFile = evidence.appendingPathComponent("inspection-guard.js")
    let readyFile = evidence.appendingPathComponent("inspection-ready")
    guard !FileManager.default.fileExists(atPath: guardFile.path),
          (try? FileManager.default.destinationOfSymbolicLink(atPath: guardFile.path)) == nil,
          !FileManager.default.fileExists(atPath: readyFile.path),
          (try? FileManager.default.destinationOfSymbolicLink(atPath: readyFile.path)) == nil else {
      throw BenchmarkWorkspaceError.unsafePath
    }
    let rootJSON = String(decoding: try JSONEncoder().encode(root.path), as: UTF8.self)
    let script = #"""
    import { realpathSync, writeFileSync } from "node:fs";
    import { isAbsolute, relative, resolve } from "node:path";
    import { createReadOnlyTools } from "@mariozechner/pi-coding-agent";
    const root = realpathSync(\#(rootJSON));
    const tools = ["read", "grep", "find", "ls"];
    const denied = () => ({ block: true, reason: "Judge inspection is limited to files in its disposable workspace; Git metadata, external paths and other tools are unavailable." });
    export default function (pi) {
      let activated = false;
      for (const tool of createReadOnlyTools(root)) pi.registerTool(tool);
      pi.on("tool_call", (event) => {
        try {
          if (!tools.includes(event.toolName) || !event.input || typeof event.input !== "object") return denied();
          const supplied = event.input.path ?? (event.toolName === "read" ? null : ".");
          if (typeof supplied !== "string" || !supplied || supplied.split(/[\\/]/).some(part => part.toLowerCase() === ".git")) return denied();
          const target = realpathSync(resolve(root, supplied));
          const child = relative(root, target);
          if (isAbsolute(child) || child === ".." || child.startsWith("../") || child.split(/[\\/]/).some(part => part.toLowerCase() === ".git")) return denied();
          event.input.path = target;
          // Recursive searches must never expose Git objects or configuration.
          // The enforced exclusion takes precedence over a caller's glob filter.
          if (event.toolName === "grep") event.input.glob = "!**/.git/**";
          return undefined;
        } catch { return denied(); }
      });
      pi.on("tool_result", (event) => {
        if (!["find", "ls"].includes(event.toolName)) return undefined;
        const content = event.content.map(item => item.type !== "text" ? item : {
          ...item,
          text: item.text.split("\n").filter(line => !/(^|[\\/])\.git([\\/]|$)/i.test(line)).join("\n") || "No visible files found"
        });
        return { content, details: undefined };
      });
      // Activate only after the guard exists. --no-builtin-tools remains fail-closed
      // when an older CLI cannot load this extension or run this hook.
      pi.on("before_agent_start", () => {
        pi.setActiveTools(tools);
        const active = pi.getActiveTools();
        if (active.length !== tools.length || tools.some(name => !active.includes(name))) throw new Error("LLimit inspection tools could not be enabled");
        if (!activated) {
          writeFileSync(resolve(root, ".llimit-evidence/inspection-ready"), "llimit-inspection-v1\n", { mode: 0o600, flag: "wx" });
          activated = true;
        }
      });
    }
    """#
    try writeOwnerOnlyAtomically(Data(script.utf8), to: guardFile)
    var prepared = command
    prepared.arguments += ["--no-builtin-tools", "--extension", guardFile.path]
    return prepared
  }

  /// Missing or failed extensions must not silently become evidence-only
  /// judgments while the UI promises file inspection.
  public static func validateExecution(command: BenchmarkCommand, directory: URL) throws {
    let guardFile = directory.appendingPathComponent(".llimit-evidence/inspection-guard.js")
    let preparedPi = command.outputFormat == .piJSON && command.arguments.contains("--no-builtin-tools")
      && containsPair("--extension", guardFile.path, in: command.arguments)
    guard isPiInspector(command) || preparedPi else { return }
    do {
      let evidence = directory.appendingPathComponent(".llimit-evidence")
      let folder = try evidence.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard folder.isDirectory == true, folder.isSymbolicLink != true else { throw BenchmarkJudgeInspectionError.unavailable }
      let ready = evidence.appendingPathComponent("inspection-ready")
      let values = try ready.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == 21,
            (try FileManager.default.attributesOfItem(atPath: ready.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600,
            try Data(contentsOf: ready) == Data("llimit-inspection-v1\n".utf8) else {
        throw BenchmarkJudgeInspectionError.unavailable
      }
    } catch { throw BenchmarkJudgeInspectionError.unavailable }
  }

  private static func isPiInspector(_ command: BenchmarkCommand) -> Bool {
    command.outputFormat == .piJSON && containsPair("--tools", piTools, in: command.arguments)
      && command.arguments.filter({ $0 == "--tools" }).count == 1
      && ["--no-extensions", "--no-mcp", "--no-approve", "--no-skills", "--no-context-files", "--no-prompt-templates"].allSatisfy(command.arguments.contains)
      && !command.arguments.contains("--no-tools") && !command.arguments.contains("--extension")
  }

  private static func isClaudeInspector(_ command: BenchmarkCommand) -> Bool {
    command.arguments.contains("--restricted") && containsPair("--tools", claudeTools, in: command.arguments)
      && containsPair("--allowedTools", claudeTools, in: command.arguments)
      && containsPair("--permission-mode", "dontAsk", in: command.arguments)
      && containsPair("--mcp-config", #"{"mcpServers":{}}"#, in: command.arguments)
      && command.arguments.contains("--strict-mcp-config")
      && command.arguments.contains("--disable-slash-commands")
      && ["--tools", "--allowedTools", "--permission-mode", "--mcp-config"].allSatisfy { key in command.arguments.filter { $0 == key }.count == 1 }
      && !command.arguments.contains(where: { ["--allowed-tools", "--disallowedTools", "--disallowed-tools", "--add-dir", "--settings", "--plugin-dir"].contains($0) })
  }

  private static func containsPair(_ key: String, _ value: String, in arguments: [String]) -> Bool {
    arguments.indices.dropLast().contains { arguments[$0] == key && arguments[$0 + 1] == value }
  }
}
