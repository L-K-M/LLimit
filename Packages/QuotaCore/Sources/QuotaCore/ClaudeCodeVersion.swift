import Foundation

/// Best-effort discovery of the installed Claude Code version, used to keep
/// the `claude-code/<version>` User-Agent on the usage endpoint from drifting
/// stale. Probes once per process on a background queue — `current()` never
/// blocks; until the first probe lands it returns nil and the caller falls
/// back to a bundled version string.
public enum ClaudeCodeVersion {
  private static let lock = NSLock()
  private static var probed = false
  private static var scheduled = false
  private static var cached: String?

  /// The installed CLI's version (e.g. "2.0.30"), or nil when no Claude
  /// executable is found, it doesn't answer `--version` in time, or the
  /// one-time background probe hasn't finished yet.
  public static func current() -> String? {
    lock.lock()
    if probed {
      defer { lock.unlock() }
      return cached
    }
    if !scheduled {
      scheduled = true
      DispatchQueue.global().async {
        let version = detect()
        lock.lock()
        cached = version
        probed = true
        lock.unlock()
      }
    }
    lock.unlock()
    return nil
  }

  /// Extracts the first `x.y.z` token (pre-release suffixes like `-rc.1`
  /// allowed) from `claude --version` output, e.g. "2.0.30 (Claude Code)".
  static func parseVersion(from output: String) -> String? {
    output.split(whereSeparator: \.isWhitespace).first { token in
      token.range(of: #"^\d+\.\d+\.\d+([-+][0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil
    }.map(String.init)
  }

  private static func detect() -> String? {
    // Global budget: several slow candidates must not stack 5s timeouts.
    let deadline = Date().addingTimeInterval(5)
    for url in candidateExecutables() where FileManager.default.isExecutableFile(atPath: url.path) {
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0 else { return nil }
      if let version = probe(url, timeout: remaining) { return version }
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

  /// `claude --version` with a kill-switch. Output accumulates through a
  /// readability handler so a spawned grandchild inheriting the pipe can't
  /// keep a blocking read alive past termination.
  private static func probe(_ executable: URL, timeout: TimeInterval) -> String? {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = executable
    process.arguments = ["--version"]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice

    let buffer = NSMutableData()
    let bufferQueue = DispatchQueue(label: "llimit.claude-version")
    pipe.fileHandleForReading.readabilityHandler = { handle in
      bufferQueue.sync { buffer.append(handle.availableData) }
    }

    do {
      try process.run()
    } catch {
      pipe.fileHandleForReading.readabilityHandler = nil
      return nil
    }

    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    // The handler can miss a process that already exited.
    if !process.isRunning { exited.signal() }
    if exited.wait(timeout: .now() + timeout) == .timedOut {
      process.terminate()
      // A hung process may ignore SIGTERM briefly; SIGKILL it if it lingers.
      Thread.sleep(forTimeInterval: 0.2)
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    process.waitUntilExit()
    pipe.fileHandleForReading.readabilityHandler = nil
    try? pipe.fileHandleForReading.close()

    let output = bufferQueue.sync { String(decoding: buffer as Data, as: UTF8.self) }
    guard process.terminationStatus == 0 else { return nil }
    return parseVersion(from: output)
  }
}
