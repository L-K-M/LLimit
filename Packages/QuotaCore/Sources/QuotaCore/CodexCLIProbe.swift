import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Older Codex releases can treat an unknown subcommand as an agent prompt.
/// Probe only --version, without any real home/config or authentication context.
enum CodexCLIProbe {
  static func firstSupported(_ candidates: [URL], environment: [String: String], timeout: TimeInterval = 2) async throws -> URL {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("llimit-codex-version-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: temporary) }
    let environment = ["HOME": temporary.path, "CODEX_HOME": temporary.path, "PATH": environment["PATH"] ?? "/usr/bin:/bin"]
    var seen = Set<String>()
    for candidate in candidates where seen.insert(candidate.path).inserted && FileManager.default.isExecutableFile(atPath: candidate.path) {
      guard !Task.isCancelled else { throw CodexConnectionError.cancelled }
      let output = await Task.detached(priority: .utility) {
        Self.versionOutput(candidate, environment: environment, directory: temporary, timeout: timeout)
      }.value
      if let output, isSupported(output) { return candidate }
    }
    throw CodexConnectionError.cliUnavailable
  }

  static func isSupported(_ output: String) -> Bool {
    let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0] == "codex-cli" else { return false }
    let components = parts[1].split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 3 else { return false }
    let version = components.compactMap { value -> Int? in
      guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
      return Int(value)
    }
    guard version.count == 3 else { return false }
    return !version.lexicographicallyPrecedes([0, 144, 4])
  }

  private static func versionOutput(_ executable: URL, environment: [String: String], directory: URL, timeout: TimeInterval) -> String? {
    guard timeout.isFinite, timeout > 0, timeout <= 10 else { return nil }
    let process = Process()
    let output = Pipe()
    process.executableURL = executable
    process.arguments = ["--version"]
    process.environment = environment
    process.currentDirectoryURL = directory
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    try? output.fileHandleForWriting.close()
    defer { try? output.fileHandleForReading.close() }
    let descriptor = output.fileHandleForReading.fileDescriptor
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
      if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
      return nil
    }
    let deadline = Date().addingTimeInterval(timeout)
    var bytes = [UInt8](repeating: 0, count: 1024)
    var captured = Data()
    var reachedEOF = false
    while Date() < deadline {
      let count = read(descriptor, &bytes, bytes.count)
      if count > 0 {
        guard captured.count + count <= 4096 else {
          if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
          return nil
        }
        captured.append(contentsOf: bytes.prefix(count))
      } else if count == 0 {
        reachedEOF = true
      } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        return nil
      }
      if !process.isRunning && reachedEOF {
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return String(data: captured, encoding: .utf8)
      }
      usleep(10_000)
    }
    // A version-only process has no grant to protect and must not outlive its
    // deadline. Authentication app-server processes are never killed this way.
    if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
    return nil
  }
}
