import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

private let ownerOnlyFileMode: mode_t = 0o600

/// Creates private bytes before atomic replacement; chmod after an atomic
/// Foundation write leaves its temporary credential file readable meanwhile.
func writeOwnerOnlyAtomically(_ data: Data, to fileURL: URL) throws {
  let directory = fileURL.deletingLastPathComponent()
  let temporaryURL = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
  let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, ownerOnlyFileMode)
  guard descriptor >= 0 else { throw privateFileError("create", fileURL: fileURL) }

  do {
    guard fchmod(descriptor, ownerOnlyFileMode) == 0 else {
      throw privateFileError("restrict", fileURL: fileURL)
    }
    try writeAll(data, to: descriptor, fileURL: fileURL)
    try synchronize(descriptor, fileURL: fileURL)
  } catch {
    close(descriptor)
    try? FileManager.default.removeItem(at: temporaryURL)
    throw error
  }

  guard close(descriptor) == 0 else {
    let error = privateFileError("close", fileURL: fileURL)
    try? FileManager.default.removeItem(at: temporaryURL)
    throw error
  }
  guard rename(temporaryURL.path, fileURL.path) == 0 else {
    let error = privateFileError("replace", fileURL: fileURL)
    try? FileManager.default.removeItem(at: temporaryURL)
    throw error
  }

  try verifyOwnerOnlyFile(at: fileURL)

  // The bytes have committed. A directory-sync failure cannot undo that
  // replacement, so report it without encouraging a rotating-grant replay.
  let directoryDescriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
  guard directoryDescriptor >= 0 else {
    reportPersistenceIssue("Could not synchronize the directory for \(fileURL.lastPathComponent).")
    return
  }
  defer { close(directoryDescriptor) }
  do { try synchronize(directoryDescriptor, fileURL: directory) }
  catch { reportPersistenceIssue("Could not synchronize the directory for \(fileURL.lastPathComponent).") }
}

private func writeAll(_ data: Data, to descriptor: Int32, fileURL: URL) throws {
  try data.withUnsafeBytes { buffer in
    guard let base = buffer.baseAddress else { return }
    var offset = 0
    while offset < buffer.count {
      let written = write(descriptor, base + offset, buffer.count - offset)
      if written == -1, errno == EINTR { continue }
      guard written > 0 else { throw privateFileError("write", fileURL: fileURL) }
      offset += written
    }
  }
}

private func synchronize(_ descriptor: Int32, fileURL: URL) throws {
  while fsync(descriptor) != 0 {
    if errno == EINTR { continue }
    throw privateFileError("synchronize", fileURL: fileURL)
  }
}

private func verifyOwnerOnlyFile(at fileURL: URL) throws {
  var status = stat()
  guard lstat(fileURL.path, &status) == 0 else { throw privateFileError("verify", fileURL: fileURL) }
  guard status.st_mode & S_IFMT == S_IFREG, status.st_mode & 0o777 == ownerOnlyFileMode else {
    throw CocoaError(.fileWriteNoPermission, userInfo: [
      NSFilePathErrorKey: fileURL.path,
      NSLocalizedDescriptionKey: "\(fileURL.lastPathComponent) is not a regular owner-only file."
    ])
  }
}

private func privateFileError(_ operation: String, fileURL: URL) -> NSError {
  let code = errno
  return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
    NSFilePathErrorKey: fileURL.path,
    NSLocalizedDescriptionKey: "Could not \(operation) \(fileURL.lastPathComponent): \(String(cString: strerror(code)))"
  ])
}
