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
  /// Bounds one `--version` answer; a chatty executable is not a version.
  static let outputLimit = ManagedCLIVersionProbe.outputLimit
  private static let probeBudget: TimeInterval = 5

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
      Task.detached(priority: .utility) {
        cache(await detect())
      }
    }
    lock.unlock()
    return nil
  }

  private static func cache(_ version: String?) {
    lock.lock()
    defer { lock.unlock() }
    cached = version
    probed = true
  }

  /// Extracts the first `x.y.z` token (pre-release suffixes like `-rc.1`
  /// allowed) from `claude --version` output, e.g. "2.0.30 (Claude Code)".
  static func parseVersion(from output: String) -> String? {
    output.split(whereSeparator: \.isWhitespace).first { token in
      token.range(of: #"^\d+\.\d+\.\d+([-+][0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil
    }.map(String.init)
  }

  private static func detect() async -> String? {
    // Global budget: several slow candidates must not stack 5s timeouts.
    let deadline = Date().addingTimeInterval(probeBudget)
    let environment = ProcessInfo.processInfo.environment
    for url in ManagedCLI.claude.candidates(environment: environment)
    where FileManager.default.isExecutableFile(atPath: url.path) {
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0 else { return nil }
      if let version = await probe(url, timeout: remaining, parentEnvironment: environment) { return version }
    }
    return nil
  }

  static func probe(_ executable: URL, timeout: TimeInterval, parentEnvironment: [String: String]) async -> String? {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("llimit-claude-version-" + UUID().uuidString)
    do {
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    } catch { return nil }
    defer { try? FileManager.default.removeItem(at: home) }
    let environment = ManagedCLIVersionProbe.environment(for: .claude, executable: executable, parent: parentEnvironment, home: home)
    guard case .success(let output) = await ManagedCLIVersionProbe.output(
      executable, environment: environment, directory: home, timeout: timeout) else { return nil }
    return parseVersion(from: output)
  }
}
