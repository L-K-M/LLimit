import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public struct BenchmarkProcessResult: Sendable {
  public let status: Int32
  public let stdout: String
  public let stderr: String
  public let timedOut: Bool
}

/// A bounded, noninteractive command. Each child owns a process group; stopping
/// a trial stops its ordinary descendants before another trial can start.
public actor BenchmarkProcess {
  public static let outputLimit = 2 * 1_024 * 1_024
  private static let inputLimit = 4 * 1_024 * 1_024

  public init() {}

  public func run(
    executable: URL, arguments: [String], directory: URL, input: String? = nil,
    timeout: Double, environment: [String: String]? = nil
  ) async throws -> BenchmarkProcessResult {
    try Task.checkCancellation()
    guard executable.isFileURL, executable.path.hasPrefix("/"),
          directory.isFileURL, timeout.isFinite, timeout > 0, timeout <= BenchmarkPlan.maximumTimeoutSeconds,
          (input?.utf8.count ?? 0) <= Self.inputLimit,
          !arguments.contains(where: { $0.utf8.contains(0) }),
          !executable.path.utf8.contains(0), !directory.path.utf8.contains(0) else {
      throw BenchmarkProcessError.invalidInput
    }
    let inherited = environment ?? Self.defaultEnvironment()
    guard inherited.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=")
      && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) }) else {
      throw BenchmarkProcessError.invalidInput
    }
    let cancellation = BenchmarkCancellation()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            let result = try Self.execute(
              executable: executable, arguments: arguments, directory: directory,
              input: input, timeout: timeout, environment: inherited, cancellation: cancellation)
            continuation.resume(returning: result)
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    } onCancel: {
      cancellation.cancel()
    }
  }

  /// CLI authentication remains owned by that CLI. Provider keys, profile
  /// overrides, dynamic-loader hooks and shell startup hooks are not inherited.
  public static func defaultEnvironment(parent: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
    let allowed: Set<String> = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "PATH", "TERM"]
    return parent.filter {
      allowed.contains($0.key) || $0.key.hasPrefix("LC_") || ManagedCLI.sharedEnvironmentKeys.contains($0.key)
    }
  }

  private static func execute(
    executable: URL, arguments: [String], directory: URL, input: String?, timeout: Double,
    environment: [String: String], cancellation: BenchmarkCancellation
  ) throws -> BenchmarkProcessResult {
    if cancellation.isCancelled { throw CancellationError() }
    let launch = try BenchmarkProcessLaunch(directory: directory, input: input)
    let pid = try launch.spawn(executable: executable, arguments: arguments, environment: environment)
    launch.closeChildDescriptors()
    var stdout = Data()
    var stderr = Data()
    var truncated = false
    let started = DispatchTime.now().uptimeNanoseconds
    var timedOut = false
    var cancelled = false
    var exited = false
    while true {
      launch.drain(stdout: &stdout, stderr: &stderr, truncated: &truncated)
      cancelled = cancellation.isCancelled
      timedOut = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000 >= timeout
      // WNOWAIT reserves the child's PID until process-group cleanup is done.
      // Signalling a group after reaping its leader risks an unrelated reused ID.
      var info = siginfo_t()
      let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
      if result == 0, info.si_signo != 0 { exited = true }
      if result == -1, errno != EINTR {
        // Do not signal a child which an external SIGCHLD handler reaped.
        throw BenchmarkProcessError.waitFailed
      }
      if exited || timedOut || cancelled { break }
      usleep(10_000)
    }

    // Even a successfully exited shell may have left background children.
    // The unreaped leader keeps the group ID reserved throughout cleanup.
    kill(-pid, SIGTERM)
    if !exited { kill(pid, SIGTERM) }
    let grace = DispatchTime.now().uptimeNanoseconds
    while Double(DispatchTime.now().uptimeNanoseconds - grace) / 1_000_000_000 < 0.15 {
      launch.drain(stdout: &stdout, stderr: &stderr, truncated: &truncated)
      usleep(10_000)
    }
    kill(-pid, SIGKILL)
    if !exited { kill(pid, SIGKILL) }
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 {
      if errno != EINTR { throw BenchmarkProcessError.waitFailed }
    }
    launch.drain(stdout: &stdout, stderr: &stderr, truncated: &truncated)
    if cancelled { throw CancellationError() }
    let signal = status & 0x7f
    let code = signal == 0 ? (status >> 8) & 0xff : 128 + signal
    let suffix = truncated ? "\n[Output truncated at 2 MiB.]" : ""
    return BenchmarkProcessResult(
      status: code, stdout: String(decoding: stdout, as: UTF8.self),
      stderr: String(decoding: stderr, as: UTF8.self) + suffix, timedOut: timedOut && !exited)
  }
}

public enum BenchmarkProcessError: LocalizedError {
  case invalidInput
  case launchFailed
  case waitFailed

  public var errorDescription: String? {
    switch self {
    case .invalidInput: return "The command, working directory, input, or timeout is invalid."
    case .launchFailed: return "Could not start the command. Check the executable and its permissions."
    case .waitFailed: return "Could not determine whether the command finished."
    }
  }
}

private final class BenchmarkCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
}

// Both the supported macOS and Linux libc versions provide this extension.
// A declaration here also covers Swift libc modules omitting GNU extensions.
#if canImport(Darwin)
@_silgen_name("posix_spawn_file_actions_addchdir_np")
private func benchmarkSpawnChdir(_ actions: UnsafeMutablePointer<posix_spawn_file_actions_t?>, _ path: UnsafePointer<CChar>) -> Int32
#else
@_silgen_name("posix_spawn_file_actions_addchdir_np")
private func benchmarkSpawnChdir(_ actions: UnsafeMutablePointer<posix_spawn_file_actions_t>, _ path: UnsafePointer<CChar>) -> Int32
#endif

private final class BenchmarkProcessLaunch {
  #if canImport(Darwin)
  private var attributes: posix_spawnattr_t?
  private var actions: posix_spawn_file_actions_t?
  #else
  private var attributes = posix_spawnattr_t()
  private var actions = posix_spawn_file_actions_t()
  #endif
  private var attributesInitialized = false
  private var actionsInitialized = false
  private var output: [Int32] = [-1, -1]
  private var errors: [Int32] = [-1, -1]
  private var inputDescriptor: Int32 = -1

  init(directory: URL, input: String?) throws {
    do {
      try check(pipe(&output))
      try check(pipe(&errors))
      for descriptor in output + errors {
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) != -1 else { throw BenchmarkProcessError.launchFailed }
      }
      for descriptor in [output[0], errors[0]] {
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else { throw BenchmarkProcessError.launchFailed }
      }
      if let input {
        var name = Array(FileManager.default.temporaryDirectory.appendingPathComponent("llimit-benchmark-XXXXXX").path.utf8CString)
        inputDescriptor = mkstemp(&name)
        guard inputDescriptor >= 0 else { throw BenchmarkProcessError.launchFailed }
        name.withUnsafeBufferPointer { _ = unlink($0.baseAddress!) }
        guard fcntl(inputDescriptor, F_SETFD, FD_CLOEXEC) != -1 else { throw BenchmarkProcessError.launchFailed }
        try Data(input.utf8).withUnsafeBytes { bytes in
          var offset = 0
          while offset < bytes.count {
            let count = write(inputDescriptor, bytes.baseAddress! + offset, bytes.count - offset)
            if count == -1, errno == EINTR { continue }
            guard count > 0 else { throw BenchmarkProcessError.launchFailed }
            offset += count
          }
        }
        guard lseek(inputDescriptor, 0, SEEK_SET) == 0 else { throw BenchmarkProcessError.launchFailed }
      } else {
        inputDescriptor = open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard inputDescriptor >= 0 else { throw BenchmarkProcessError.launchFailed }
      }
      try check(posix_spawnattr_init(&attributes))
      attributesInitialized = true
      try check(posix_spawn_file_actions_init(&actions))
      actionsInitialized = true
      var defaults = sigset_t()
      sigfillset(&defaults)
      try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
      var mask = sigset_t()
      sigemptyset(&mask)
      try check(posix_spawnattr_setsigmask(&attributes, &mask))
      try check(posix_spawnattr_setpgroup(&attributes, 0))
      var flags = Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP)
      #if canImport(Darwin)
      flags |= Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
      #endif
      try check(posix_spawnattr_setflags(&attributes, flags))
      try check(posix_spawn_file_actions_adddup2(&actions, inputDescriptor, STDIN_FILENO))
      try check(posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO))
      try check(posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO))
      try directory.path.withCString { try check(benchmarkSpawnChdir(&actions, $0)) }
      #if !canImport(Darwin)
      for descriptor: Int32 in 3..<1_024 {
        let descriptorFlags = fcntl(descriptor, F_GETFD)
        if descriptorFlags >= 0, descriptorFlags & FD_CLOEXEC == 0 {
          try check(posix_spawn_file_actions_addclose(&actions, descriptor))
        }
      }
      #endif
    } catch {
      cleanup()
      throw BenchmarkProcessError.launchFailed
    }
  }

  deinit { cleanup() }

  func spawn(executable: URL, arguments: [String], environment: [String: String]) throws -> pid_t {
    var pid = pid_t()
    let result = Self.withCStrings([executable.path] + arguments) { argv in
      Self.withCStrings(environment.map { "\($0.key)=\($0.value)" }) { envp in
        posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
      }
    }
    try check(result)
    return pid
  }

  func closeChildDescriptors() {
    for descriptor in [output[1], errors[1], inputDescriptor] where descriptor >= 0 { close(descriptor) }
    output[1] = -1
    errors[1] = -1
    inputDescriptor = -1
  }

  func drain(stdout: inout Data, stderr: inout Data, truncated: inout Bool) {
    drain(descriptor: output[0], into: &stdout, otherCount: stderr.count, truncated: &truncated)
    drain(descriptor: errors[0], into: &stderr, otherCount: stdout.count, truncated: &truncated)
  }

  private func drain(descriptor: Int32, into data: inout Data, otherCount: Int, truncated: inout Bool) {
    var bytes = [UInt8](repeating: 0, count: 16_384)
    // Bound each drain so an indefinitely noisy process cannot starve timeout
    // and cancellation checks while the pipe remains continuously readable.
    for _ in 0..<64 {
      let count = read(descriptor, &bytes, bytes.count)
      if count == -1, errno == EINTR { continue }
      guard count > 0 else { return }
      let retained = min(count, max(0, BenchmarkProcess.outputLimit - data.count - otherCount))
      if retained > 0 { data.append(contentsOf: bytes.prefix(retained)) }
      if retained < count { truncated = true }
    }
  }

  private func cleanup() {
    for descriptor in output + errors + [inputDescriptor] where descriptor >= 0 { close(descriptor) }
    output = [-1, -1]
    errors = [-1, -1]
    inputDescriptor = -1
    if actionsInitialized { posix_spawn_file_actions_destroy(&actions); actionsInitialized = false }
    if attributesInitialized { posix_spawnattr_destroy(&attributes); attributesInitialized = false }
  }

  private func check(_ result: Int32) throws {
    guard result == 0 else { throw BenchmarkProcessError.launchFailed }
  }

  private static func withCStrings<Value>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Value) -> Value {
    let pointers = strings.map { strdup($0) } + [nil]
    defer { pointers.forEach { free($0) } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
  }
}
