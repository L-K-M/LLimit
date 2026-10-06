import Foundation

/// Best-effort discovery of the installed Claude Code version, used to keep
/// the `claude-code/<version>` User-Agent on the usage endpoint from drifting
/// stale. Probes once per process and caches; a missing CLI is not an error —
/// the caller falls back to a bundled version string.
public enum ClaudeCodeVersion {
  private static let lock = NSLock()
  private static var probed = false
  private static var cached: String?

  /// The installed CLI's version (e.g. "2.0.30"), or nil when no Claude
  /// executable is found or it doesn't answer `--version` in time.
  public static func current() -> String? {
    lock.lock()
    defer { lock.unlock() }
    if !probed {
      probed = true
      cached = detect()
    }
    return cached
  }

  /// Extracts the first `x.y.z` token from `claude --version` output, e.g.
  /// "2.0.30 (Claude Code)".
  static func parseVersion(from output: String) -> String? {
    output.split(whereSeparator: { $0 == " " || $0 == "\n" }).first { token in
      token.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil
    }.map(String.init)
  }

  private static func detect() -> String? {
    for url in candidateExecutables() where FileManager.default.isExecutableFile(atPath: url.path) {
      if let version = probe(url) { return version }
    }
    return nil
  }

  /// Same lookup order as the app's ClaudeProfileService: known install
  /// locations first, then PATH.
  private static func candidateExecutables() -> [URL] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    var candidates = [home.appendingPathComponent(".local/bin/claude"),
                      home.appendingPathComponent(".claude/local/claude"),
                      URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
                      URL(fileURLWithPath: "/usr/local/bin/claude")]
    for path in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
    where path.hasPrefix("/") {
      candidates.append(URL(fileURLWithPath: String(path)).appendingPathComponent("claude"))
    }
    return candidates
  }

  /// `claude --version` with a short kill-switch: a hung CLI must not stall
  /// the refresh. Output is a single line — well under the pipe buffer.
  private static func probe(_ executable: URL) -> String? {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = executable
    process.arguments = ["--version"]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice

    do {
      try process.run()
    } catch {
      return nil
    }

    DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
      if process.isRunning { process.terminate() }
    }
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return parseVersion(from: output)
  }
}
