import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Older Codex releases can treat an unknown subcommand as an agent prompt.
/// Probe only --version, without any real home/config or authentication context.
enum CodexCLIProbe {
  /// Compared by SemVer precedence, so a prerelease of a later version passes
  /// and a prerelease of this version does not.
  static let minimumVersion = CodexCLIVersion(major: 0, minor: 144, patch: 4)
  static let outputLimit = 4096
  private static let maximumTimeout: TimeInterval = 10

  /// Returns the first candidate that reports a supported version. Otherwise
  /// throws the first candidate's problem: the preferred install is the one to
  /// repair, and its path tells the user which install LLimit tried.
  static func firstSupported(_ candidates: [URL], environment: [String: String], timeout: TimeInterval = 2) async throws -> URL {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("llimit-codex-version-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: temporary) }
    var firstProblem: CodexConnectionError?
    var seen = Set<String>()
    for candidate in candidates where seen.insert(candidate.path).inserted && FileManager.default.isExecutableFile(atPath: candidate.path) {
      guard !Task.isCancelled else { throw CodexConnectionError.cancelled }
      let probeEnvironment = Self.environment(for: candidate, parent: environment, home: temporary)
      guard let problem = await problem(with: candidate, environment: probeEnvironment, directory: temporary, timeout: timeout) else {
        return candidate
      }
      firstProblem = firstProblem ?? problem
    }
    throw firstProblem ?? CodexConnectionError.cliNotFound
  }

  /// The probe sees no real home, Codex configuration or credential. Volta's
  /// shims still need the user's Volta directory, which defaults under HOME.
  static func environment(for candidate: URL, parent: [String: String], home: URL) -> [String: String] {
    var environment = ["HOME": home.path, "CODEX_HOME": home.path,
                       "PATH": ManagedCLI.searchPath(for: candidate, environment: parent)]
    if let volta = ManagedCLI.voltaHome(environment: parent) { environment["VOLTA_HOME"] = volta }
    return environment
  }

  /// Nil when the candidate is a supported Codex CLI; otherwise why it is not.
  private static func problem(with candidate: URL, environment: [String: String], directory: URL,
                              timeout: TimeInterval) async -> CodexConnectionError? {
    let output: String
    switch await versionOutput(candidate, environment: environment, directory: directory, timeout: timeout) {
    case .success(let value): output = value
    case .failure(let failure): return .cliFailed(path: candidate.path, failure)
    }
    guard let version = CodexCLIVersion(versionOutput: output) else {
      return .cliFailed(path: candidate.path, .unrecognizedVersion)
    }
    guard version < minimumVersion else { return nil }
    return .cliTooOld(path: candidate.path, version: version.description)
  }

  /// Waits through termination and end-of-output callbacks, so no thread is
  /// blocked while the child runs.
  private static func versionOutput(_ executable: URL, environment: [String: String], directory: URL,
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
      // End of output stays readable; stop the handler so it does not spin.
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

/// One version probe, completed exactly once: by exit plus end of output, by
/// excess output, or by its deadline. Foundation and Dispatch deliver the
/// callbacks on their own queues, so the lock serializes every transition.
private final class VersionRun: @unchecked Sendable {
  /// Released on completion, which breaks the cycle through its termination handler.
  private var process: Process?
  /// The child's own process group, when Foundation started it as a leader.
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

  /// Records the process group before the child can exit and be reaped.
  /// Foundation starts the child as a group leader on Linux and macOS today.
  /// If it does not, or the child was already reaped, `group` stays nil and
  /// `stop` can kill only the direct child.
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

  /// Output is complete only once the pipe reaches its end after exit.
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

  /// Ends a probe that did not finish by itself. A version-only process has no
  /// grant to protect, so neither it nor anything it started may outlive the
  /// deadline. Authentication app-server processes are never killed this way.
  private func stop(_ failure: CodexCLIFailure) {
    guard result == nil else { return }
    // Descendants holding the output pipe keep the group alive after the child
    // exits. Without a recorded group, only a still-running child is killed.
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

/// A `codex-cli X.Y.Z[-prerelease][+build]` version, ordered by SemVer
/// precedence: a prerelease precedes its release, and build metadata is ignored.
struct CodexCLIVersion: Comparable, CustomStringConvertible, Sendable {
  let major: Int
  let minor: Int
  let patch: Int
  /// Empty for a release.
  let prerelease: [String]

  init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
    self.major = major
    self.minor = minor
    self.patch = patch
    self.prerelease = prerelease
  }

  /// Accepts only the single line `codex --version` prints.
  init?(versionOutput: String) {
    let parts = versionOutput.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0] == "codex-cli" else { return nil }
    var text = parts[1]
    if let plus = text.firstIndex(of: "+") {
      guard Self.identifiers(text[text.index(after: plus)...]) != nil else { return nil }
      text = text[..<plus]
    }
    var prerelease: [String] = []
    if let dash = text.firstIndex(of: "-") {
      guard let identifiers = Self.identifiers(text[text.index(after: dash)...]) else { return nil }
      prerelease = identifiers
      text = text[..<dash]
    }
    let components = text.split(separator: ".", omittingEmptySubsequences: false)
    let core = components.compactMap { value -> Int? in
      guard Self.isNumeric(value) else { return nil }
      return Int(value)
    }
    guard components.count == 3, core.count == 3 else { return nil }
    self.init(major: core[0], minor: core[1], patch: core[2], prerelease: prerelease)
  }

  var description: String {
    let release = "\(major).\(minor).\(patch)"
    return prerelease.isEmpty ? release : release + "-" + prerelease.joined(separator: ".")
  }

  static func < (lhs: Self, rhs: Self) -> Bool {
    if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
      return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
    // A release has higher precedence than any of its prereleases.
    if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty }
    for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
      return identifierPrecedes(left, right)
    }
    return lhs.prerelease.count < rhs.prerelease.count
  }

  /// Numeric identifiers compare numerically and precede alphanumeric ones,
  /// which compare in ASCII order.
  private static func identifierPrecedes(_ lhs: String, _ rhs: String) -> Bool {
    switch (isNumeric(Substring(lhs)), isNumeric(Substring(rhs))) {
    case (true, true): return (lhs.count, lhs) < (rhs.count, rhs)
    case (true, false): return true
    case (false, true): return false
    case (false, false): return Array(lhs.utf8).lexicographicallyPrecedes(rhs.utf8)
    }
  }

  /// Dot-separated, non-empty `[0-9A-Za-z-]` identifiers, or nil.
  private static func identifiers(_ text: Substring) -> [String]? {
    let identifiers = text.split(separator: ".", omittingEmptySubsequences: false)
    let valid = identifiers.allSatisfy { identifier in
      !identifier.isEmpty && identifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
    return valid ? identifiers.map(String.init) : nil
  }

  private static func isNumeric(_ value: Substring) -> Bool {
    !value.isEmpty && value.allSatisfy { $0.isASCII && $0.isNumber }
  }
}
