import Foundation
import QuotaCore
import Security

/// The ordinary tool logins only; LLimit's private managed profiles are never scanned.
struct LocalCredentialScanner: Sendable {
  enum KeychainInteraction: Sendable { case withoutPrompts, allowPrompts }
  struct KeychainCredential: Sendable {
    let token: String?
    let diagnostic: String
  }

  private let discoverFiles: @Sendable () -> CredentialDiscoveryResult
  private let readKeychain: @Sendable (KeychainInteraction) -> KeychainCredential

  init(discoverFiles: @escaping @Sendable () -> CredentialDiscoveryResult = { CredentialDiscovery().discover() },
       readKeychain: @escaping @Sendable (KeychainInteraction) -> KeychainCredential = { LocalCredentialScanner.readDefaultClaudeKeychain(interaction: $0) }) {
    self.discoverFiles = discoverFiles
    self.readKeychain = readKeychain
  }

  func discover(for provider: QuotaProvider? = nil, interaction: KeychainInteraction = .withoutPrompts) -> CredentialDiscoveryResult {
    var result = discoverFiles()
    if (provider == nil || provider == .anthropic),
       !result.credentials.contains(where: { $0.provider == .anthropic }) {
      // The default CLI item uses the legacy Keychain. Its access dialogs do
      // not honor LAContext.interactionNotAllowed, so automatic scans must not
      // attempt the read. An explicit Scan Again may request that permission.
      guard interaction == .allowPrompts else {
        result.diagnostics.append("Claude Code Keychain: choose Scan Again to check the default login and allow access if requested.")
        return result
      }
      let keychain = readKeychain(interaction)
      result.diagnostics.append("Claude Code Keychain: \(keychain.diagnostic)")
      if let token = keychain.token {
        result.credentials.append(DiscoveredCredential(stableID: "anthropic:keychain", provider: .anthropic,
          suggestedName: "Claude", sourceLabel: "Claude Code (macOS Keychain)",
          credentials: [CredentialField.anthropicAccessToken: token]))
      }
    }
    return result
  }

  static func claudeKeychainQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "Claude Code-credentials",
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]
  }

  private static func readDefaultClaudeKeychain(interaction: KeychainInteraction) -> KeychainCredential {
    guard interaction == .allowPrompts else {
      return KeychainCredential(token: nil, diagnostic: "choose Scan Again to check the default Claude Code login")
    }
    var data: CFTypeRef?
    let status = SecItemCopyMatching(claudeKeychainQuery() as CFDictionary, &data)
    if status == errSecSuccess, let payload = data as? Data, let token = claudeToken(from: payload) {
      return KeychainCredential(token: token, diagnostic: "found the default Claude Code login")
    }
    if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
      return KeychainCredential(token: nil,
        diagnostic: "the default Claude Code login needs Keychain permission. Choose Scan Again to allow access, or use Connect Claude.")
    }
    return KeychainCredential(token: nil,
      diagnostic: "no readable default Claude Code login. Use Connect Claude to sign in to a separate account.")
  }

  static func claudeToken(from data: Data) -> String? {
    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      let oauth = (object["claudeAiOauth"] as? [String: Any]) ?? object
      let token = ((oauth["accessToken"] as? String) ?? (oauth["access_token"] as? String))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return token?.isEmpty == false ? token : nil
    }
    guard let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          token.count > 20, !token.contains(where: \.isWhitespace),
          !token.hasPrefix("{"), !token.hasPrefix("[") else { return nil }
    return token
  }
}
