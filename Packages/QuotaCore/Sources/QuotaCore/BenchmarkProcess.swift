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
  public let stderrTruncated: Bool
  public let decodedOutput: BenchmarkOutput?
  public let recoverySessionID: String?
}

public enum BenchmarkProcessCapture: Sendable {
  case text
  case harness(BenchmarkOutputFormat)
  case openCodeExport(sessionID: String)
}

/// A noninteractive command. Each child owns a process group; stopping
/// a trial stops its ordinary descendants before another trial can start.
public actor BenchmarkProcess {
  private static let diagnosticLimit = 65_536

  public init() {}

  public func run(
    executable: URL, arguments: [String], directory: URL, input: String? = nil,
    timeout: Double, environment: [String: String]? = nil,
    capture: BenchmarkProcessCapture = .text
  ) async throws -> BenchmarkProcessResult {
    try Task.checkCancellation()
    guard executable.isFileURL, executable.path.hasPrefix("/"),
          directory.isFileURL, timeout.isFinite, timeout > 0, timeout <= BenchmarkPlan.maximumTimeoutSeconds,
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
              input: input, timeout: timeout, environment: inherited, cancellation: cancellation, capture: capture)
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
    environment: [String: String], cancellation: BenchmarkCancellation, capture: BenchmarkProcessCapture
  ) throws -> BenchmarkProcessResult {
    if cancellation.isCancelled { throw CancellationError() }
    let stdout = try BenchmarkCaptureFile()
    let launch = try BenchmarkProcessLaunch(directory: directory, input: input)
    let pid = try launch.spawn(executable: executable, arguments: arguments, environment: environment)
    launch.closeChildDescriptors()
    var stderr = Data()
    var stderrTruncated = false
    var captureFailed = false
    let started = DispatchTime.now().uptimeNanoseconds
    var timedOut = false
    var cancelled = false
    var exited = false
    while true {
      launch.drain(stdout: stdout, stderr: &stderr, diagnosticLimit: diagnosticLimit,
                   stderrTruncated: &stderrTruncated, captureFailed: &captureFailed)
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
      if exited || timedOut || cancelled || captureFailed { break }
      usleep(10_000)
    }

    // Even a successfully exited shell may have left background children.
    // The unreaped leader keeps the group ID reserved throughout cleanup.
    kill(-pid, SIGTERM)
    if !exited { kill(pid, SIGTERM) }
    let grace = DispatchTime.now().uptimeNanoseconds
    while Double(DispatchTime.now().uptimeNanoseconds - grace) / 1_000_000_000 < 0.15 {
      launch.drain(stdout: stdout, stderr: &stderr, diagnosticLimit: diagnosticLimit,
                   stderrTruncated: &stderrTruncated, captureFailed: &captureFailed)
      usleep(10_000)
    }
    kill(-pid, SIGKILL)
    if !exited { kill(pid, SIGKILL) }
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 {
      if errno != EINTR { throw BenchmarkProcessError.waitFailed }
    }
    launch.drain(stdout: stdout, stderr: &stderr, diagnosticLimit: diagnosticLimit,
                 stderrTruncated: &stderrTruncated, captureFailed: &captureFailed)
    if cancelled { throw CancellationError() }
    if captureFailed { throw BenchmarkProcessError.captureFailed }
    let signal = status & 0x7f
    let code = signal == 0 ? (status >> 8) & 0xff : 128 + signal
    if cancellation.isCancelled { throw CancellationError() }
    let data = try stdout.contents()
    let text: String
    let decoded: BenchmarkOutput?
    var recoverySessionID: String?
    switch capture {
    case .text:
      text = String(decoding: data, as: UTF8.self)
      decoded = nil
    case .harness(let format):
      decoded = BenchmarkOutput.decode(data, format: format, shouldCancel: { cancellation.isCancelled })
      text = format == .text ? decoded!.text : ""
      if format == .opencodeJSON, decoded?.succeeded != true {
        recoverySessionID = BenchmarkOutput.openCodeSessionForRecovery(data, shouldCancel: { cancellation.isCancelled })
      }
    case .openCodeExport(let sessionID):
      decoded = BenchmarkOutput.decodeOpenCodeExport(data, expectedSessionID: sessionID, shouldCancel: { cancellation.isCancelled })
      text = ""
    }
    if cancellation.isCancelled { throw CancellationError() }
    return BenchmarkProcessResult(
      status: code, stdout: text, stderr: String(decoding: stderr, as: UTF8.self),
      timedOut: timedOut && !exited, stderrTruncated: stderrTruncated,
      decodedOutput: decoded, recoverySessionID: recoverySessionID)
  }
}

public enum BenchmarkProcessError: LocalizedError {
  case invalidInput
  case launchFailed
  case waitFailed
  case captureFailed

  public var errorDescription: String? {
    switch self {
    case .invalidInput: return "The command, working directory, input, or timeout is invalid."
    case .launchFailed: return "Could not start the command. Check the executable and its permissions."
    case .waitFailed: return "Could not determine whether the command finished."
    case .captureFailed: return "Could not capture the complete command output. Check available disk space and try again."
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

/// Raw traces can contain secrets. Unlink the owner-only file before launching
/// the child, so neither normal completion nor an app crash leaves a transcript.
private final class BenchmarkCaptureFile {
  private let descriptor: Int32

  init() throws {
    var name = Array(FileManager.default.temporaryDirectory.appendingPathComponent("llimit-capture-XXXXXX").path.utf8CString)
    let file = mkstemp(&name)
    guard file >= 0 else { throw BenchmarkProcessError.captureFailed }
    let unlinked = name.withUnsafeBufferPointer { unlink($0.baseAddress!) == 0 }
    guard unlinked, fchmod(file, 0o600) == 0, fcntl(file, F_SETFD, FD_CLOEXEC) != -1 else {
      close(file)
      if !unlinked { name.withUnsafeBufferPointer { _ = unlink($0.baseAddress!) } }
      throw BenchmarkProcessError.captureFailed
    }
    descriptor = file
  }

  deinit { close(descriptor) }

  func append(_ bytes: UnsafeRawBufferPointer) throws {
    var offset = 0
    while offset < bytes.count {
      let count = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
      if count == -1, errno == EINTR { continue }
      guard count > 0 else { throw BenchmarkProcessError.captureFailed }
      offset += count
    }
  }

  func contents() throws -> Data {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_size >= 0,
          UInt64(metadata.st_size) <= UInt64(Int.max) else { throw BenchmarkProcessError.captureFailed }
    let size = Int(metadata.st_size)
    guard size > 0 else { return Data() }
    guard let pointer = mmap(nil, size, PROT_READ, MAP_PRIVATE, descriptor, 0), pointer != MAP_FAILED else {
      throw BenchmarkProcessError.captureFailed
    }
    // The file is immutable after all child pipes have been drained. Mapping it
    // lets the selective reader skip arbitrarily large traces without copying
    // them into Swift strings or JSON object graphs.
    return Data(bytesNoCopy: pointer, count: size, deallocator: .custom { address, length in munmap(address, length) })
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

  func drain(stdout: BenchmarkCaptureFile, stderr: inout Data, diagnosticLimit: Int,
             stderrTruncated: inout Bool, captureFailed: inout Bool) {
    drain(descriptor: output[0], captureFailed: &captureFailed) { bytes in try stdout.append(bytes) }
    drain(descriptor: errors[0], captureFailed: &captureFailed) { bytes in
      let retained = min(bytes.count, max(0, diagnosticLimit - stderr.count))
      stderr.append(contentsOf: bytes.prefix(retained))
      if retained < bytes.count { stderrTruncated = true }
    }
  }

  private func drain(descriptor: Int32, captureFailed: inout Bool,
                     consume: (UnsafeRawBufferPointer) throws -> Void) {
    var bytes = [UInt8](repeating: 0, count: 16_384)
    // Bound each drain so an indefinitely noisy process cannot starve timeout
    // and cancellation checks while the pipe remains continuously readable.
    for _ in 0..<64 {
      let count = read(descriptor, &bytes, bytes.count)
      if count == -1, errno == EINTR { continue }
      if count == -1, errno != EAGAIN, errno != EWOULDBLOCK { captureFailed = true }
      guard count > 0 else { return }
      do { try bytes.withUnsafeBytes { try consume(UnsafeRawBufferPointer(rebasing: $0[..<count])) } }
      catch { captureFailed = true; return }
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
