import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Cross-process advisory lock guarding read-modify-write cycles on the settings
/// file. The daemon writes settings during token refresh while a concurrent
/// `llimit accounts …` may be editing; `SettingsStore.save` is atomic, so the file
/// is never corrupted, but without mutual exclusion one writer's edit can be
/// silently lost (both processes loaded the same base, the later save wins).
/// Holding an flock from load through save closes that window.
///
/// The lock lives in a sidecar file (`quota-settings.lock`) rather than on the
/// settings file itself: `SettingsStore.save` writes via atomic rename, so the
/// locked inode would be replaced underneath us and the lock would not actually
/// exclude anyone.
public struct SettingsLock: Sendable {
  public let lockFileURL: URL

  public init(settingsFileURL: URL) {
    self.lockFileURL = settingsFileURL
      .deletingPathExtension()
      .appendingPathExtension("lock")
  }

  /// Runs `body` while holding the exclusive flock. Blocks until any other holder
  /// (another CLI invocation, or the daemon mid-refresh) releases it.
  public func withLock<T>(_ body: () throws -> T) throws -> T {
    let fd = try acquire()
    defer { release(fd) }
    return try body()
  }

  /// Async variant: the lock is held across suspension points. flock is tied to the
  /// open file description, not a thread, so task resumption on a different thread
  /// is safe. Note the daemon deliberately does NOT hold it across network fetches
  /// (see `QuotaDaemon.refreshCycle`) — this exists for short async critical
  /// sections.
  public func withLock<T>(_ body: () async throws -> T) async throws -> T {
    let fd = try acquire()
    defer { release(fd) }
    return try await body()
  }

  /// Non-blocking acquisition, exposed for tests: returns false when another
  /// open file description holds the lock.
  func tryAcquire() throws -> Int32? {
    try openLockFile(blocking: false)
  }

  private func acquire() throws -> Int32 {
    // Blocking flock only fails on error (openLockFile returns nil solely for a
    // non-blocking EWOULDBLOCK), so the nil case here is defensive.
    guard let fd = try openLockFile(blocking: true) else {
      throw SettingsLockError.interrupted
    }
    return fd
  }

  private func openLockFile(blocking: Bool) throws -> Int32? {
    try FileManager.default.createDirectory(
      at: lockFileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let fd = open(lockFileURL.path, O_WRONLY | O_CREAT, 0o600)
    guard fd >= 0 else {
      throw SettingsLockError.openFailed(String(cString: strerror(errno)))
    }
    let operation = blocking ? LOCK_EX : LOCK_EX | LOCK_NB
    guard flock(fd, operation) == 0 else {
      let error = errno
      close(fd)
      if !blocking, error == EWOULDBLOCK {
        return nil
      }
      throw SettingsLockError.flockFailed(String(cString: strerror(error)))
    }
    return fd
  }

  func release(_ fd: Int32) {
    flock(fd, LOCK_UN)
    close(fd)
  }
}

public enum SettingsLockError: LocalizedError, Sendable {
  case openFailed(String)
  case flockFailed(String)
  case interrupted

  public var errorDescription: String? {
    switch self {
    case .openFailed(let detail):
      return "Could not open the settings lock file: \(detail)"
    case .flockFailed(let detail):
      return "Could not lock the settings lock file: \(detail)"
    case .interrupted:
      return "Interrupted while acquiring the settings lock."
    }
  }
}
