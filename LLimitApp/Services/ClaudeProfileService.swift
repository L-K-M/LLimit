import Foundation
import CryptoKit
import Security
import QuotaCore

/// Reads only the credential namespace belonging to a single LLimit profile.
/// Claude Code owns the refresh token and writes it; LLimit keeps only an access-token cache.
struct ClaudeProfileService {
  enum ReadMode { case interactive, background }

  struct Login {
    let credentials: ClaudeCodeCredentials
    let identity: ClaudeCodeIdentity
    let renewal: ClaudeCodeRenewalMaterial?
  }

  enum Failure: LocalizedError {
    case cliMissing, unsafeDirectory, notSignedIn, keychainLocked, missingIdentity, renewalUnavailable, settingsUnavailable

    var errorDescription: String? {
      switch self {
      case .cliMissing: return "Claude Code was not found. Install Claude Code, then connect this account again."
      case .unsafeDirectory: return "The Claude profile directory could not be secured. Check its permissions before reconnecting."
      case .notSignedIn: return "This Claude profile is not signed in. Open its terminal to connect."
      case .keychainLocked: return "Allow LLimit to read this Claude profile in Keychain, then reconnect."
      case .missingIdentity: return "Claude Code did not save an account identity. Complete sign-in again in this account’s terminal."
      case .settingsUnavailable: return "Could not save this account securely. Check LLimit’s settings file before trying again."
      case .renewalUnavailable: return "This Claude login cannot be renewed automatically. Reconnect this account."
      }
    }
  }

  private var root: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("LLimit/ClaudeProfiles", isDirectory: true)
  }

  func directory(for profile: ClaudeCodeProfile) -> URL {
    profile.directory(under: root)
  }

  func prepare(_ profile: ClaudeCodeProfile) throws -> URL {
    let directory = directory(for: profile)
    for url in [root, directory, directory.appendingPathComponent("work", isDirectory: true)] {
      try validatePath(url)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true,
            url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else {
        throw Failure.unsafeDirectory
      }
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    return directory
  }

  func executable() throws -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    var candidates = [home.appendingPathComponent(".local/bin/claude"),
                      URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
                      URL(fileURLWithPath: "/usr/local/bin/claude")]
    for path in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") where path.hasPrefix("/") {
      candidates.append(URL(fileURLWithPath: String(path)).appendingPathComponent("claude"))
    }
    guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
      throw Failure.cliMissing
    }
    return executable
  }

  func read(_ profile: ClaudeCodeProfile, mode: ReadMode) throws -> Login {
    let directory = try prepare(profile)
    let data = try credentialData(in: directory, mode: mode)
    guard let credentials = ClaudeCodeProfile.parseCredentials(data) else { throw Failure.notSignedIn }
    let configURL = directory.appendingPathComponent(".claude.json")
    guard let values = try? configURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
          values.isRegularFile == true, values.isSymbolicLink != true,
          let config = try? Data(contentsOf: configURL),
          let identity = ClaudeCodeProfile.parseIdentity(config) else { throw Failure.missingIdentity }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    return Login(credentials: credentials, identity: identity,
                 renewal: ClaudeCodeProfile.parseRenewalMaterial(data))
  }

  /// The namespace matches Claude Code's CLAUDE_CONFIG_DIR-specific Keychain service.
  /// Never enumerate other Claude services: each account must stay in its own profile.
  private func keychainService(for directory: URL) -> String {
    let normalizedPath = directory.path.precomposedStringWithCanonicalMapping
    let digest = SHA256.hash(data: Data(normalizedPath.utf8))
    let suffix = digest.map { String(format: "%02x", $0) }.joined().prefix(8)
    return "Claude Code-credentials-\(suffix)"
  }

  private var keychainAccount: String {
    let candidate = ProcessInfo.processInfo.environment["USER"].flatMap { $0.isEmpty ? nil : $0 } ?? NSUserName()
    // Claude Code rejects the whole value when it contains unsupported characters.
    // Stripping them could address a different user's Keychain item.
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
    guard !candidate.isEmpty, candidate.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
      return "claude-code-user"
    }
    return candidate
  }

  private func credentialData(in directory: URL, mode: ReadMode) throws -> Data {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService(for: directory),
      kSecAttrAccount as String: keychainAccount,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecUseAuthenticationUI as String: mode == .interactive ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecSuccess, let data = result as? Data { return data }
    guard status == errSecItemNotFound else { throw Failure.keychainLocked }
    let fileURL = directory.appendingPathComponent(".credentials.json")
    guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
          values.isRegularFile == true, values.isSymbolicLink != true,
          let data = try? Data(contentsOf: fileURL) else { throw Failure.notSignedIn }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    return data
  }

  func isRefreshLocked(_ profile: ClaudeCodeProfile) -> Bool {
    let directory = directory(for: profile)
    return FileManager.default.fileExists(atPath: directory.appendingPathComponent(".oauth_refresh.lock").path)
      || FileManager.default.fileExists(atPath: directory.path + ".lock")
  }

  private func validatePath(_ url: URL) throws {
    guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else {
      throw Failure.unsafeDirectory
    }
    if let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
      guard values.isDirectory == true, values.isSymbolicLink != true else { throw Failure.unsafeDirectory }
    }
  }

  /// Removes only local state for a removed account. Never invokes logout, which may revoke a grant.
  func remove(_ profile: ClaudeCodeProfile) throws {
    let directory = directory(for: profile)
    try validatePath(root)
    try validatePath(directory)
    guard !isRefreshLocked(profile) else { throw Failure.renewalUnavailable }
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                               kSecAttrService as String: keychainService(for: directory),
                               kSecAttrAccount as String: keychainAccount]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychainLocked }
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
  }
}
