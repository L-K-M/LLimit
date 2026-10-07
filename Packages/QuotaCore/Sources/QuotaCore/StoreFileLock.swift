import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

private let storeLockMode: mode_t = 0o600

/// Atomic replacement changes inodes. This durable sidecar serializes owner
/// read/decode/recovery and read-modify-write against every replacement.
/// Keep the sidecar: replacing it would split the lock across different inodes.
/// Locks cover local owner operations and release when the descriptor closes.
func withStoreFileLock<T>(at fileURL: URL, _ body: () throws -> T) throws -> T {
  let lockURL = fileURL.appendingPathExtension("access.lock")
  let descriptor = open(lockURL.path, O_WRONLY | O_CREAT | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW, storeLockMode)
  guard descriptor >= 0 else { throw storeLockError(fileURL) }
  defer { close(descriptor) }
  var status = stat()
  guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
    throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: lockURL.path])
  }
  guard fchmod(descriptor, storeLockMode) == 0 else { throw storeLockError(fileURL) }
  while flock(descriptor, LOCK_EX) != 0 {
    if errno == EINTR { continue }
    throw storeLockError(fileURL)
  }
  defer { flock(descriptor, LOCK_UN) }
  return try body()
}

private func storeLockError(_ fileURL: URL) -> NSError {
  NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
    NSFilePathErrorKey: fileURL.path,
    NSLocalizedDescriptionKey: "Could not lock \(fileURL.lastPathComponent)."
  ])
}
