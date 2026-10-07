import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Local namespaces owned by Codex. LLimit persists only their identity, never
/// copies their OAuth tokens. An exclusive operation record survives crashes.
public struct CodexProfileStore: Sendable {
  public let root: URL

  public init(root: URL) { self.root = root.standardizedFileURL }

  public func directory(for profile: CodexAccountProfile) -> URL {
    root.appendingPathComponent(profile.id.uuidString.lowercased(), isDirectory: true)
  }

  public func prepare(_ profile: CodexAccountProfile) throws -> URL {
    try prepareDirectory(root)
    let directory = directory(for: profile)
    try prepareDirectory(directory)
    try prepareDirectory(directory.appendingPathComponent("work", isDirectory: true))
    return directory
  }

  public func identity(_ profile: CodexAccountProfile) throws -> CodexAccountIdentity {
    let directory = directory(for: profile)
    try validateDirectory(root)
    try validateDirectory(directory)
    let file = directory.appendingPathComponent("auth.json")
    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
          let size = values.fileSize, size <= 1_048_576 else { throw CodexConnectionError.invalidProfile }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    return try CodexAccountProfile.parseIdentity(Data(contentsOf: file))
  }

  /// Acquire before launching a process, not just before sending a refresh.
  /// Codex may renew while loading auth. A stale marker requires a fresh login;
  /// absence of a PID or elapsed time cannot prove a token rotation finished.
  public func acquire(_ profile: CodexAccountProfile) throws {
    try prepareDirectory(root)
    try prepareDirectory(operationsDirectory)
    try synchronizeDirectory(root)
    let descriptor = open(operationRecord(profile).path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      if errno == EEXIST { throw CodexConnectionError.unfinishedOperation }
      throw CodexConnectionError.storage
    }
    defer { _ = close(descriptor) }
    guard fsync(descriptor) == 0 else { throw CodexConnectionError.storage }
    try synchronizeDirectory(operationsDirectory)
  }

  /// Only the owner of this operation may call this, after observing child exit.
  public func release(_ profile: CodexAccountProfile) throws {
    try validateDirectory(root)
    try validateDirectory(operationsDirectory)
    try FileManager.default.removeItem(at: operationRecord(profile))
    try synchronizeDirectory(operationsDirectory)
  }

  public func hasPendingOperation(_ profile: CodexAccountProfile) -> Bool {
    (try? operationRecord(profile).resourceValues(forKeys: [.isRegularFileKey])) != nil
  }

  /// Returns false for an uncertain/live operation; its entire namespace stays
  /// in place for recovery. Acquiring the marker also serializes local deletion.
  public func remove(_ profile: CodexAccountProfile) throws -> Bool {
    do { try acquire(profile) }
    catch CodexConnectionError.unfinishedOperation { return false }
    do {
      try validateDirectory(root)
      let directory = directory(for: profile)
      try validateDirectory(directory)
      if FileManager.default.fileExists(atPath: directory.path) {
        try FileManager.default.removeItem(at: directory)
      }
      try release(profile)
      return true
    } catch {
      // Keep the marker after a partial failure. Never guess whether credentials
      // remain or another process can safely enter a partially removed profile.
      throw CodexConnectionError.storage
    }
  }

  private var operationsDirectory: URL { root.appendingPathComponent("Operations", isDirectory: true) }
  private func operationRecord(_ profile: CodexAccountProfile) -> URL {
    operationsDirectory.appendingPathComponent(profile.id.uuidString.lowercased() + ".pending")
  }

  private func prepareDirectory(_ url: URL) throws {
    try validateDirectory(url)
    if !FileManager.default.fileExists(atPath: url.path) {
      do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
      } catch {
        guard FileManager.default.fileExists(atPath: url.path) else { throw CodexConnectionError.storage }
      }
    }
    try validateDirectory(url)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  }

  private func synchronizeDirectory(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard descriptor >= 0 else { throw CodexConnectionError.storage }
    defer { _ = close(descriptor) }
    guard fsync(descriptor) == 0 else { throw CodexConnectionError.storage }
  }

  private func validateDirectory(_ url: URL) throws {
    guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else {
      throw CodexConnectionError.storage
    }
    if let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
      guard values.isDirectory == true, values.isSymbolicLink != true else { throw CodexConnectionError.storage }
    }
  }
}

public enum CodexConnectionError: Error, LocalizedError, Sendable {
  case cliUnavailable, invalidProfile, unfinishedOperation, storage, signInFailed, cancelled, incompatibleCLI

  public var errorDescription: String? {
    switch self {
    case .cliUnavailable: return "Install Codex CLI 0.144.4 or later to connect this OpenAI account."
    case .invalidProfile: return "This OpenAI login could not be verified. Reconnect the account."
    case .unfinishedOperation: return "A previous Codex operation has not finished safely. Reconnect this account if it does not recover."
    case .storage: return "Could not save this OpenAI connection. Check LLimit’s storage permissions."
    case .signInFailed: return "OpenAI sign-in did not finish. Connect this account to try again."
    case .cancelled: return "OpenAI sign-in was canceled."
    case .incompatibleCLI: return "Codex could not complete this request. Try again or reconnect the account."
    }
  }
}
