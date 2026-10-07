import Foundation
import QuotaCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Somewhere a quota event goes. `deliver` runs on the refresh loop and must
/// return promptly.
protocol QuotaEventSink: AnyObject {
  func deliver(_ event: QuotaEvent, now: Date)
}

/// `--notify`: one desktop notification per event through notify-send.
final class DesktopNotificationSink: QuotaEventSink {
  static let command = "notify-send"

  private let executable: URL
  private let runner: ChildProcessRunner
  /// The daemon's environment, which carries the session bus address.
  private let environment: [String: String]

  init(executable: URL, runner: ChildProcessRunner, environment: [String: String]) {
    self.executable = executable
    self.runner = runner
    self.environment = environment
  }

  func deliver(_ event: QuotaEvent, now: Date) {
    runner.run(executable: executable, arguments: Self.arguments(for: event, now: now), environment: environment)
  }

  /// `--` keeps an account name that starts with "-" from being read as an option.
  static func arguments(for event: QuotaEvent, now: Date) -> [String] {
    let urgency = event.severity == .critical ? "critical" : "normal"
    return ["--app-name=LLimit", "--urgency=\(urgency)", "--", event.title, event.body(now: now)]
  }
}

/// `--on-event <cmd>`: runs the user's executable once per event, without a
/// shell and without arguments. The event travels only in `LLIMIT_*`
/// environment variables.
final class EventHookSink: QuotaEventSink {
  static let payloadPrefix = "LLIMIT_"

  private let executable: URL
  private let runner: ChildProcessRunner
  private let inheritedEnvironment: [String: String]

  init(executable: URL, runner: ChildProcessRunner, inheritedEnvironment: [String: String]) {
    self.executable = executable
    self.runner = runner
    self.inheritedEnvironment = inheritedEnvironment
  }

  func deliver(_ event: QuotaEvent, now: Date) {
    let environment = Self.environment(for: event, now: now, inheriting: inheritedEnvironment)
    runner.run(executable: executable, arguments: [], environment: environment)
  }

  /// The hook's environment: the daemon's own (so PATH and the session bus
  /// work) minus any inherited `LLIMIT_*` variable, plus the event. Every value
  /// comes from `QuotaEvent`, which carries no provider error text and no
  /// credentials. Variables that do not apply to an event are left unset.
  static func environment(for event: QuotaEvent, now: Date, inheriting base: [String: String]) -> [String: String] {
    var environment = base.filter { !$0.key.hasPrefix(payloadPrefix) }
    environment["LLIMIT_EVENT"] = event.kind.rawValue
    environment["LLIMIT_SEVERITY"] = event.severity.rawValue
    environment["LLIMIT_ACCOUNT_ID"] = event.accountID
    environment["LLIMIT_ACCOUNT_NAME"] = event.accountName
    environment["LLIMIT_PROVIDER"] = event.provider.rawValue
    environment["LLIMIT_SUMMARY"] = event.title
    environment["LLIMIT_BODY"] = event.body(now: now)
    environment["LLIMIT_METRIC"] = event.metricID
    environment["LLIMIT_METRIC_LABEL"] = event.metricLabel
    environment["LLIMIT_REMAINING"] = event.remainingPercent.map(String.init)
    environment["LLIMIT_ESTIMATED"] = event.isEstimated ? "1" : nil
    environment["LLIMIT_THRESHOLD"] = event.threshold.map(String.init)
    environment["LLIMIT_RESETS_AT"] = event.resetAt.map { ISO8601DateFormatter().string(from: $0) }
    environment["LLIMIT_FAILURE_KIND"] = event.failureKind?.rawValue
    return environment
  }
}

/// Runs short helper processes (notify-send, the user's hook) off the refresh
/// loop. Runs are serialized on a private queue and each is bounded: past the
/// timeout the child's process group gets SIGTERM, then SIGKILL, and the child
/// is always reaped. A hung hook can delay later alerts, never a refresh.
final class ChildProcessRunner: @unchecked Sendable {
  enum Outcome: Equatable {
    case exited(Int32)
    case signaled(Int32)
    case timedOut
    case failedToLaunch
  }

  static let defaultTimeout: TimeInterval = 10
  private static let killGracePeriod: TimeInterval = 2
  private static let pollInterval: useconds_t = 20_000
  /// Descriptors from 3 up to this bound are closed in the child unless already
  /// close-on-exec. The daemon never has more open.
  private static let inheritedDescriptorLimit: Int32 = 1_024

  private let timeout: TimeInterval
  private let log: (String) -> Void
  private let queue = DispatchQueue(label: "llimit.alert-delivery")

  init(timeout: TimeInterval = ChildProcessRunner.defaultTimeout, log: @escaping (String) -> Void) {
    self.timeout = timeout
    self.log = log
  }

  /// Queues a run and returns immediately. `environment` is the child's whole
  /// environment.
  func run(
    executable: URL,
    arguments: [String],
    environment: [String: String],
    completion: ((Outcome) -> Void)? = nil
  ) {
    queue.async { [self] in
      let outcome = runToCompletion(executable: executable, arguments: arguments, environment: environment)
      completion?(outcome)
    }
  }

  /// Blocks until every queued run has finished. For tests.
  func waitUntilIdle() {
    queue.sync {}
  }

  private func runToCompletion(executable: URL, arguments: [String], environment: [String: String]) -> Outcome {
    let name = executable.lastPathComponent
    let pid: pid_t
    do {
      pid = try Self.spawn(executable: executable, arguments: arguments, environment: environment)
    } catch {
      log("[llimitd] Could not start \(name): \(error.localizedDescription)")
      return .failedToLaunch
    }

    if let status = Self.waitForExit(pid, within: timeout) {
      return outcome(of: status, name: name)
    }

    log("[llimitd] \(name) did not finish within \(Int(timeout))s, stopping it")
    // The child leads its own process group, so this also reaches whatever it
    // started. It has not been reaped yet, so the IDs cannot have been reused.
    kill(-pid, SIGTERM)
    if Self.waitForExit(pid, within: Self.killGracePeriod) == nil {
      log("[llimitd] \(name) ignored SIGTERM, killing it")
      kill(-pid, SIGKILL)
      var status: Int32 = 0
      while waitpid(pid, &status, 0) == -1, errno == EINTR {}
    }
    return .timedOut
  }

  private func outcome(of status: Int32, name: String) -> Outcome {
    let signal = status & 0x7f
    guard signal == 0 else {
      log("[llimitd] \(name) was stopped by signal \(signal)")
      return .signaled(signal)
    }

    let code = (status >> 8) & 0xff
    if code != 0 {
      log("[llimitd] \(name) exited with status \(code)")
    }
    return .exited(code)
  }

  /// Polls so the wait can time out. Returns the wait status once the child
  /// has exited and been reaped, or nil while it is still running at the
  /// deadline.
  private static func waitForExit(_ pid: pid_t, within interval: TimeInterval) -> Int32? {
    let deadline = Date().addingTimeInterval(interval)
    var status: Int32 = 0
    while true {
      let result = waitpid(pid, &status, WNOHANG)
      if result == pid {
        return status
      }
      if result == -1, errno != EINTR {
        // Nothing left to reap: report it as exited rather than signal an ID
        // that may now belong to another process.
        return 0
      }
      if Date() >= deadline {
        return nil
      }
      usleep(pollInterval)
    }
  }

  struct SpawnError: LocalizedError {
    var code: Int32
    var errorDescription: String? { String(cString: strerror(code)) }
  }

  /// posix_spawn rather than Foundation's Process: the daemon ignores SIGTERM
  /// and SIGINT so it can shut down through dispatch sources, ignored signals
  /// survive exec, and Process keeps them, leaving a hook (and anything it
  /// starts) deaf to the timeout and to Ctrl-C. Here the child starts with
  /// default signal dispositions, an empty signal mask, its own process group,
  /// stdin on /dev/null, and none of the daemon's other descriptors.
  private static func spawn(executable: URL, arguments: [String], environment: [String: String]) throws -> pid_t {
    #if canImport(Darwin)
    var attributes: posix_spawnattr_t?
    var actions: posix_spawn_file_actions_t?
    #else
    var attributes = posix_spawnattr_t()
    var actions = posix_spawn_file_actions_t()
    #endif
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }

    var defaultSignals = sigset_t()
    sigfillset(&defaultSignals)
    posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
    var blockedSignals = sigset_t()
    sigemptyset(&blockedSignals)
    posix_spawnattr_setsigmask(&attributes, &blockedSignals)
    posix_spawnattr_setpgroup(&attributes, 0)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP))

    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    for descriptor in 3..<inheritedDescriptorLimit {
      let flags = fcntl(descriptor, F_GETFD)
      if flags >= 0, flags & FD_CLOEXEC == 0 {
        posix_spawn_file_actions_addclose(&actions, descriptor)
      }
    }

    var pid = pid_t()
    let result = withCStrings([executable.path] + arguments) { argv in
      withCStrings(environment.map { "\($0.key)=\($0.value)" }) { envp in
        posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
      }
    }
    guard result == 0 else {
      throw SpawnError(code: result)
    }
    return pid
  }

  private static func withCStrings<Value>(
    _ strings: [String],
    _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Value
  ) -> Value {
    let pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) } + [nil]
    defer { pointers.forEach { free($0) } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
  }
}

/// Resolves a command the way exec does without a shell: a value containing
/// "/" is a path, anything else is looked up on PATH.
enum ExecutableLocator {
  static func find(_ command: String, environment: [String: String]) -> URL? {
    if command.contains("/") {
      let url = URL(fileURLWithPath: command)
      return isExecutableFile(url.path) ? url : nil
    }

    let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
    for directory in directories where !directory.isEmpty {
      let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(command)
      if isExecutableFile(candidate.path) {
        return candidate
      }
    }
    return nil
  }

  private static func isExecutableFile(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      && !isDirectory.boolValue
      && FileManager.default.isExecutableFile(atPath: path)
  }
}
