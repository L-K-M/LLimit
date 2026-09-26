import Foundation

/// Runs an official Claude Code authentication command without capturing its output.
/// The CLI remains the sole owner of refresh-token rotation and profile storage.
public actor ClaudeCodeProcess {
  public enum Result: Equatable, Sendable {
    case completed(status: Int32)
    /// The child may still be rotating its grant. Do not retry with the same token.
    case running(id: UUID)
  }

  public enum RunError: Error {
    case invalidTimeout
  }

  private struct RunningOperation {
    let process: Process
    var waiter: CheckedContinuation<Result, Never>?
    var timeout: Task<Void, Never>?
  }

  private enum Operation {
    case running(RunningOperation)
    case completed(Int32)
  }

  private var operations: [UUID: Operation] = [:]

  public init() {}

  /// Builds an isolated CLI environment without inheriting provider credentials,
  /// endpoint overrides, startup hooks or another Claude configuration directory.
  /// HOME stays the user's real home so the CLI can access the login Keychain.
  public static func environment(
    parent: [String: String],
    profileDirectory: URL,
    renewal: ClaudeCodeRenewalMaterial? = nil
  ) -> [String: String] {
    let allowedKeys: Set<String> = ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "TERM"]
    var environment = parent.filter { allowedKeys.contains($0.key) || $0.key.hasPrefix("LC_") }
    environment["CLAUDE_CONFIG_DIR"] = profileDirectory.standardizedFileURL.path
    environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
    if let renewal {
      environment["CLAUDE_CODE_OAUTH_REFRESH_TOKEN"] = renewal.refreshToken
      environment["CLAUDE_CODE_OAUTH_SCOPES"] = renewal.scopes.joined(separator: " ")
    }
    return environment
  }

  /// Starts the executable directly, with no shell and all standard streams sent
  /// to the null device. The caller must persist its renewal-in-progress marker
  /// before invoking this method, because the app may exit while the CLI is running.
  ///
  /// Cancellation before launch throws. After launch it never kills the child:
  /// interrupting a rotating grant could lose the only usable replacement token.
  /// The wait is bounded by timeout; a running result stays tracked until exit.
  public func run(
    executable: URL,
    arguments: [String],
    environment: [String: String],
    workingDirectory: URL,
    timeout: TimeInterval
  ) async throws -> Result {
    try Task.checkCancellation()
    guard timeout.isFinite, timeout >= 0, timeout <= 3_600 else {
      throw RunError.invalidTimeout
    }

    let id = UUID()
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    process.currentDirectoryURL = workingDirectory
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.terminationHandler = { process in
      let status = process.terminationStatus
      Task { await self.finished(id: id, status: status) }
    }
    operations[id] = .running(RunningOperation(process: process))

    do {
      try process.run()
    } catch {
      operations.removeValue(forKey: id)
      process.terminationHandler = nil
      throw error
    }

    return await withCheckedContinuation { continuation in
      guard case .running(var operation) = operations[id] else {
        // A termination callback can arrive before the waiter is installed.
        if case .completed(let status) = operations.removeValue(forKey: id) {
          continuation.resume(returning: .completed(status: status))
        } else {
          preconditionFailure("The launched Claude Code operation must be tracked")
        }
        return
      }
      operation.waiter = continuation
      operation.timeout = Task {
        do {
          try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        } catch {
          return
        }
        self.stopWaiting(id: id)
      }
      operations[id] = .running(operation)
    }
  }

  /// Checks a child returned by `run` as still running. A completed status is
  /// consumed once, releasing the record; nil means the ID is no longer tracked.
  public func status(id: UUID) -> Result? {
    switch operations[id] {
    case .running:
      return .running(id: id)
    case .completed(let status):
      operations.removeValue(forKey: id)
      return .completed(status: status)
    case nil:
      return nil
    }
  }

  private func stopWaiting(id: UUID) {
    guard case .running(var operation) = operations[id], let waiter = operation.waiter else { return }
    operation.waiter = nil
    operation.timeout = nil
    operations[id] = .running(operation)
    waiter.resume(returning: .running(id: id))
  }

  private func finished(id: UUID, status: Int32) {
    guard case .running(let operation) = operations[id] else { return }
    operation.timeout?.cancel()
    operation.process.terminationHandler = nil
    if let waiter = operation.waiter {
      operations.removeValue(forKey: id)
      waiter.resume(returning: .completed(status: status))
    } else {
      operations[id] = .completed(status)
    }
  }
}
