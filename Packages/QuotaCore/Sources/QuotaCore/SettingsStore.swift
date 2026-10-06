import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public final class SettingsStore: @unchecked Sendable {
  private let fileURL: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(fileURL: URL) {
    self.fileURL = fileURL
    self.encoder = JSONEncoder()
    self.decoder = JSONDecoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  }

  public func load() throws -> AppSettings {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return .default
    }

    let data = try Data(contentsOf: fileURL)
    return try decoder.decode(AppSettings.self, from: data)
  }

  public func save(_ settings: AppSettings) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let data = try encoder.encode(settings)
    try Self.writeSecured(data, to: fileURL)
  }

  /// Atomic replacement with the credential file owner-only from its first
  /// byte. `Data.write(options: .atomic)` would create the intermediate file
  /// under the process umask (typically 0644) and only tighten permissions
  /// after the rename — leaving OAuth refresh tokens and API keys
  /// group/world-readable for the write's duration, and permanently if that
  /// chmod failed silently. Instead: create the intermediate with mode 0600,
  /// flush it, rename over the target, and verify the result.
  private static func writeSecured(_ data: Data, to fileURL: URL) throws {
    let directory = fileURL.deletingLastPathComponent()
    let temporaryURL = directory
      .appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")

    let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard descriptor >= 0 else {
      throw SettingsStoreError.writeFailed(String(cString: strerror(errno)))
    }

    // Pin the mode on the descriptor: open()'s mode argument can be altered
    // by the process umask on some platforms/filesystems.
    guard fchmod(descriptor, 0o600) == 0 else {
      let reason = String(cString: strerror(errno))
      close(descriptor)
      try? FileManager.default.removeItem(at: temporaryURL)
      throw SettingsStoreError.writeFailed(reason)
    }

    do {
      try writeAll(data, to: descriptor)
      guard fsync(descriptor) == 0 else {
        throw SettingsStoreError.writeFailed(String(cString: strerror(errno)))
      }
    } catch {
      close(descriptor)
      try? FileManager.default.removeItem(at: temporaryURL)
      throw error
    }
    close(descriptor)

    // Capture the failure reason before any cleanup syscall can clobber
    // errno.
    guard rename(temporaryURL.path, fileURL.path) == 0 else {
      let reason = String(cString: strerror(errno))
      try? FileManager.default.removeItem(at: temporaryURL)
      throw SettingsStoreError.writeFailed(reason)
    }

    // Make the replacement durable: without a directory fsync a crash can
    // lose the rename and resurrect the previous (rotated-out) credential
    // file. Best effort — failing here does not undo a correct rename.
    let directoryDescriptor = open(directory.path, O_RDONLY)
    if directoryDescriptor >= 0 {
      fsync(directoryDescriptor)
      close(directoryDescriptor)
    }

    try verifySecured(fileURL)
  }

  private static func writeAll(_ data: Data, to descriptor: Int32) throws {
    guard !data.isEmpty else { return }

    try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
      guard let base = buffer.baseAddress else { return }
      var offset = 0
      while offset < buffer.count {
        let written = write(descriptor, base + offset, buffer.count - offset)
        // A signal can interrupt write() before any byte lands; retry.
        if written == -1, errno == EINTR {
          continue
        }
        guard written > 0 else {
          throw SettingsStoreError.writeFailed(String(cString: strerror(errno)))
        }
        offset += written
      }
    }
  }

  /// Fail closed: if the replacement did not land as a regular file with
  /// owner-only permissions, report the save as failed instead of leaving a
  /// silently loosened credential store behind.
  private static func verifySecured(_ fileURL: URL) throws {
    var status = stat()
    guard stat(fileURL.path, &status) == 0 else {
      throw SettingsStoreError.verificationFailed("could not stat the replaced file")
    }

    guard (status.st_mode & S_IFMT) == S_IFREG else {
      throw SettingsStoreError.verificationFailed("replaced item is not a regular file")
    }

    guard status.st_mode & 0o777 == 0o600 else {
      throw SettingsStoreError.verificationFailed(
        "replaced file has mode 0o\(String(status.st_mode & 0o777, radix: 8)), expected 0600"
      )
    }
  }
}

public enum SettingsStoreError: Error, CustomStringConvertible {
  case writeFailed(String)
  case verificationFailed(String)

  public var description: String {
    switch self {
    case .writeFailed(let detail):
      return "Could not write the settings file: \(detail)"
    case .verificationFailed(let detail):
      return "Settings file verification failed: \(detail)"
    }
  }
}
