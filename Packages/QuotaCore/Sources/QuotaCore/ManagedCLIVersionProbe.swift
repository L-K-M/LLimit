import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Version-only children have no grant to protect. Authentication runners never
/// enter this boundary, which bounds output and stops a probe at its deadline.
enum ManagedCLIVersionProbe {
  static let outputLimit = 4096
  static let maximumTimeout: TimeInterval = 10

  static func environment(for cli: ManagedCLI, executable: URL, parent: [String: String], home: URL) -> [String: String] {
    var environment = parent.filter { ManagedCLI.sharedEnvironmentKeys.contains($0.key) }
    environment["HOME"] = home.path
    environment["PATH"] = ManagedCLI.searchPath(for: executable, environment: parent)
    environment["VOLTA_HOME"] = ManagedCLI.voltaHome(environment: parent)
    switch cli {
    case .claude:
      environment["CLAUDE_CONFIG_DIR"] = home.path
    case .codex:
      environment["CODEX_HOME"] = home.path
      environment["CODEX_CA_CERTIFICATE"] = parent["CODEX_CA_CERTIFICATE"]
    }
    return environment
  }

  static func output(_ executable: URL, environment: [String: String], directory: URL,
                     timeout: TimeInterval) async -> Result<String, CodexCLIFailure> {
    guard timeout.isFinite, timeout > 0, timeout <= maximumTimeout else { return .failure(.launch) }
    let process = Process()
    let output = Pipe()
    process.executableURL = executable
    process.arguments = ["--version"]
    process.environment = environment
    process.currentDirectoryURL = directory
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let run = VersionRun(process: process, limit: outputLimit)
    process.terminationHandler = { run.exited(reason: $0.terminationReason, status: $0.terminationStatus) }
    output.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty { handle.readabilityHandler = nil }
      run.received(data)
    }
    do { try process.run() } catch {
      output.fileHandleForReading.readabilityHandler = nil
      process.terminationHandler = nil
      return .failure(.launch)
    }
    run.launched()
    try? output.fileHandleForWriting.close()
    let result = await withCheckedContinuation { continuation in
      run.wait(continuation)
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { run.timedOut() }
    }
    output.fileHandleForReading.readabilityHandler = nil
    try? output.fileHandleForReading.close()
    return result
  }
}

/// Exit, EOF, output overflow and the deadline race on Foundation's queues.
/// Serialize transitions and complete the waiter exactly once without a reap wait.
private final class VersionRun: @unchecked Sendable {
  private var process: Process?
  private var group: pid_t?
  private let limit: Int
  private let lock = NSLock()
  private var captured = Data()
  private var reachedEOF = false
  private var exit: (reason: Process.TerminationReason, status: Int32)?
  private var result: Result<String, CodexCLIFailure>?
  private var waiter: CheckedContinuation<Result<String, CodexCLIFailure>, Never>?

  init(process: Process, limit: Int) {
    self.process = process
    self.limit = limit
  }

  func wait(_ continuation: CheckedContinuation<Result<String, CodexCLIFailure>, Never>) {
    lock.lock()
    defer { lock.unlock() }
    guard let result else {
      waiter = continuation
      return
    }
    continuation.resume(returning: result)
  }

  /// Record only a group led by this child; never signal the app's own group.
  func launched() {
    lock.lock()
    defer { lock.unlock() }
    guard let identifier = process?.processIdentifier, getpgid(identifier) == identifier else { return }
    group = identifier
  }

  func received(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    guard result == nil else { return }
    if data.isEmpty {
      reachedEOF = true
    } else if captured.count + data.count > limit {
      return stop(.excessiveOutput)
    } else {
      captured.append(data)
    }
    finishIfExited()
  }

  func exited(reason: Process.TerminationReason, status: Int32) {
    lock.lock()
    defer { lock.unlock() }
    exit = (reason, status)
    finishIfExited()
  }

  func timedOut() {
    lock.lock()
    defer { lock.unlock() }
    stop(.timeout)
  }

  private func finishIfExited() {
    guard result == nil, reachedEOF, let exit else { return }
    switch exit.reason {
    case .uncaughtSignal:
      finish(.failure(.signal(exit.status)))
    case .exit where exit.status != 0:
      finish(.failure(.exit(exit.status)))
    default:
      finish(String(data: captured, encoding: .utf8).map { .success($0) } ?? .failure(.unrecognizedVersion))
    }
  }

  private func stop(_ failure: CodexCLIFailure) {
    guard result == nil else { return }
    // Descendants can hold stdout after the direct child exits. Without a
    // recorded private group, signal only a direct child that is still running.
    if let group {
      _ = killpg(group, SIGKILL)
    } else if exit == nil, let process, process.isRunning {
      _ = kill(process.processIdentifier, SIGKILL)
    }
    finish(.failure(failure))
  }

  private func finish(_ outcome: Result<String, CodexCLIFailure>) {
    guard result == nil else { return }
    result = outcome
    process = nil
    waiter?.resume(returning: outcome)
    waiter = nil
  }
}
