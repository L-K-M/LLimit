import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Reads and deletes Claude Code's macOS Keychain items through `/usr/bin/security`.
///
/// Claude Code writes its login only with that tool, so the item trusts it alone.
/// Each token renewal rewrites the item, after which an in-process Security
/// framework read asks for the login keychain password again, even after
/// "Always Allow". The same tool needs no grant:
///
///     Claude Code ── security add-generic-password -U ──▶ ┌─────────────────────┐
///                                                         │ login keychain item │
///     LLimit ─────── security find-generic-password -w ─▶ │ trusts: security    │
///                                                         └─────────────────────┘
public struct ClaudeCodeKeychain: Sendable {
  public enum Failure: Error, Equatable, Sendable {
    /// The tool failed, was denied, or did not answer in time, e.g. on a locked keychain.
    case unavailable
  }

  /// `security` exits with the low byte of its OSStatus; errSecItemNotFound (-25300) is 44.
  static let itemNotFoundStatus: Int32 = 44
  /// Claude Code logins are a few kilobytes. Anything this large is not one.
  static let outputLimit = 1 << 20
  /// Once the tool has exited, only end-of-file remains to read.
  private static let drainGrace: TimeInterval = 1

  private let tool: URL

  public init() {
    self.init(tool: URL(fileURLWithPath: "/usr/bin/security"))
  }

  init(tool: URL) {
    self.tool = tool
  }

  /// The item's data, or nil when no such item exists.
  public func password(service: String, account: String, timeout: TimeInterval) -> Result<Data?, Failure> {
    switch run(["find-generic-password", "-a", account, "-s", service, "-w"], timeout: timeout) {
    case .exited(0, let output):
      // `-w` prints the password followed by a newline.
      return .success(output.last == UInt8(ascii: "\n") ? output.dropLast() : output)
    case .exited(Self.itemNotFoundStatus, _):
      return .success(nil)
    default:
      return .failure(.unavailable)
    }
  }

  /// Deleting a missing item succeeds: either way, none remains.
  public func deletePassword(service: String, account: String, timeout: TimeInterval) -> Result<Void, Failure> {
    switch run(["delete-generic-password", "-a", account, "-s", service], timeout: timeout) {
    case .exited(0, _), .exited(Self.itemNotFoundStatus, _):
      return .success(())
    default:
      return .failure(.unavailable)
    }
  }

  private enum Outcome {
    case exited(status: Int32, output: Data)
    case failed
  }

  /// Blocks the caller until the tool exits or the deadline passes, then stops it.
  /// No grant is at stake, so a child that misses its deadline is killed.
  private func run(_ arguments: [String], timeout: TimeInterval) -> Outcome {
    guard timeout.isFinite, timeout > 0 else { return .failed }
    let process = Process()
    let output = Pipe()
    process.executableURL = tool
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do { try process.run() } catch { return .failed }
    try? output.fileHandleForWriting.close()

    // Drain while waiting: output larger than the pipe buffer would block the child.
    let drain = OutputDrain()
    let drained = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      drain.read(output.fileHandleForReading, limit: Self.outputLimit) { Self.stop(process) }
      drained.signal()
    }

    guard exited.wait(timeout: .now() + timeout) == .success else {
      Self.stop(process)
      return .failed
    }

    // An answer just before the deadline still counts: the drain gets its own grace.
    guard drained.wait(timeout: .now() + Self.drainGrace) == .success,
          process.terminationReason == .exit, let data = drain.data else { return .failed }
    return .exited(status: process.terminationStatus, output: data)
  }

  /// `security` never forks, so its own pid is all there is to stop.
  private static func stop(_ process: Process) {
    guard process.isRunning else { return }
    _ = kill(process.processIdentifier, SIGKILL)
  }
}

/// Written only on the draining queue before it signals, and read only after.
private final class OutputDrain: @unchecked Sendable {
  private static let chunkSize = 64 * 1024
  private(set) var data: Data?

  /// Leaves `data` nil on a read error or once output exceeds `limit`.
  func read(_ handle: FileHandle, limit: Int, onOverflow: () -> Void) {
    var collected = Data()
    do {
      while let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty {
        collected.append(chunk)
        guard collected.count <= limit else { return onOverflow() }
      }
    } catch {
      return
    }
    data = collected
  }
}
