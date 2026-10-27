import Foundation
import Security
import QuotaCore

/// Offline discovery orchestration. Both I/O closures are replaced in every scan;
/// no user credential file, real Keychain item, or authentication UI is accessed.
@main
struct LocalCredentialScannerTests {
  private static let fixtureToken = "offline-claude-access-fixture-value"

  @MainActor static func main() throws {
    testAutomaticScanNeverReadsKeychain()
    testExplicitScanCanRequestKeychainPermission()
    testFileClaudeLoginSkipsKeychain()
    testOtherProviderAutofillSkipsKeychain()
    testUnavailableKeychainPreservesFileResults()
    testKeychainLoginIsAppendedWithItsOwnIdentity()
    try testJSONPayloadParsing()
    testRawPayloadParsing()
    testDiscoveryRunsOffTheMainThread()
    print("Local credential scanner offline policy, parsing, and background checks passed")
  }

  private static func testAutomaticScanNeverReadsKeychain() {
    let login = credential(provider: .kimi, key: CredentialField.kimiAPIKey, value: "offline-automatic-file-fixture")
    let scanner = LocalCredentialScanner(
      discoverFiles: { CredentialDiscoveryResult(credentials: [login], diagnostics: ["automatic file fixture"]) },
      readKeychain: { _ in preconditionFailure("Automatic discovery must not access the legacy Keychain") })
    for provider: QuotaProvider? in [nil, .anthropic] {
      let result = scanner.discover(for: provider)
      precondition(result.credentials == [login], "File-only discovery must retain other supported logins")
      precondition(result.diagnostics.first == "automatic file fixture")
      precondition(result.diagnostics.contains { $0.contains("Scan Again") },
                   "Automatic discovery must explain how to include permission-gated logins")
    }
  }

  private static func testExplicitScanCanRequestKeychainPermission() {
    let recorded = InteractionRecorder()
    let scanner = LocalCredentialScanner(
      discoverFiles: { CredentialDiscoveryResult(credentials: [], diagnostics: []) },
      readKeychain: { interaction in
        recorded.append(interaction)
        return .init(token: nil, diagnostic: "interactive fixture")
      })
    _ = scanner.discover(interaction: .allowPrompts)
    precondition(recorded.values == [.allowPrompts])
    let query = LocalCredentialScanner.claudeKeychainQuery()
    precondition(query[kSecUseAuthenticationContext as String] == nil,
                 "An explicit scan may use the normal system permission flow")
    precondition(query[kSecAttrService as String] as? String == "Claude Code-credentials",
                 "Only the ordinary Claude Code login may be queried")
    precondition(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
    precondition(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String,
                 "Discovery must not enumerate private managed profiles")
    precondition(query[kSecReturnData as String] as? Bool == true)
    precondition(query[kSecAttrAccount as String] == nil)
  }

  private static func testFileClaudeLoginSkipsKeychain() {
    let login = credential(provider: .anthropic, key: CredentialField.anthropicAccessToken, value: fixtureToken)
    let scanner = LocalCredentialScanner(
      discoverFiles: { CredentialDiscoveryResult(credentials: [login], diagnostics: ["file fixture"]) },
      readKeychain: { _ in preconditionFailure("A usable file login must not trigger a Keychain query") })
    let result = scanner.discover(interaction: .allowPrompts)
    precondition(result.credentials == [login])
    precondition(result.diagnostics == ["file fixture"])
  }

  private static func testOtherProviderAutofillSkipsKeychain() {
    let login = credential(provider: .openAI, key: CredentialField.openAIAccessToken, value: "offline-codex-fixture")
    let scanner = LocalCredentialScanner(
      discoverFiles: { CredentialDiscoveryResult(credentials: [login], diagnostics: ["codex file fixture"]) },
      readKeychain: { _ in preconditionFailure("Another provider's autofill must not request Claude Keychain access") })
    let result = scanner.discover(for: .openAI, interaction: .allowPrompts)
    precondition(result.credentials == [login])
    precondition(result.diagnostics == ["codex file fixture"])
  }

  private static func testUnavailableKeychainPreservesFileResults() {
    let login = credential(provider: .kimi, key: CredentialField.kimiAPIKey, value: "offline-kimi-fixture")
    let scanner = LocalCredentialScanner(
      discoverFiles: { CredentialDiscoveryResult(credentials: [login], diagnostics: ["kimi file fixture"]) },
      readKeychain: { _ in .init(token: nil, diagnostic: "permission required fixture") })
    let result = scanner.discover(interaction: .allowPrompts)
    precondition(result.credentials == [login], "A blocked Keychain read must not discard other discoveries")
    precondition(result.diagnostics == ["kimi file fixture", "Claude Code Keychain: permission required fixture"])
  }

  private static func testKeychainLoginIsAppendedWithItsOwnIdentity() {
    let login = credential(provider: .cline, key: CredentialField.clineAPIKey, value: "offline-cline-fixture")
    let scanner = LocalCredentialScanner(
      discoverFiles: { CredentialDiscoveryResult(credentials: [login], diagnostics: ["cline file fixture"]) },
      readKeychain: { _ in .init(token: fixtureToken, diagnostic: "found default fixture") })
    let result = scanner.discover(for: .anthropic, interaction: .allowPrompts)
    precondition(result.credentials.count == 2 && result.credentials.first == login)
    let added = result.credentials[1]
    precondition(added.stableID == "anthropic:keychain" && added.provider == .anthropic)
    precondition(added.credentials == [CredentialField.anthropicAccessToken: fixtureToken])
    precondition(added.sourceLabel == "Claude Code (macOS Keychain)")
    precondition(result.diagnostics == ["cline file fixture", "Claude Code Keychain: found default fixture"])
    precondition(!result.diagnostics.joined().contains(fixtureToken), "Diagnostics must not expose the credential")
  }

  private static func testJSONPayloadParsing() throws {
    let payloads: [[String: Any]] = [
      ["claudeAiOauth": ["accessToken": " \n\(fixtureToken)\t "]],
      ["claudeAiOauth": ["access_token": fixtureToken]],
      ["accessToken": fixtureToken],
      ["access_token": "  \(fixtureToken)\n"]
    ]
    for payload in payloads {
      let data = try JSONSerialization.data(withJSONObject: payload)
      precondition(LocalCredentialScanner.claudeToken(from: data) == fixtureToken)
    }
    for payload: [String: Any] in [[:], ["accessToken": " \n\t "], ["claudeAiOauth": ["accessToken": ""]]] {
      let data = try JSONSerialization.data(withJSONObject: payload)
      precondition(LocalCredentialScanner.claudeToken(from: data) == nil)
    }
  }

  private static func testRawPayloadParsing() {
    precondition(LocalCredentialScanner.claudeToken(from: Data(" \n\(fixtureToken)\n ".utf8)) == fixtureToken)
    for invalid in ["", " \n\t ", "short", "offline raw fixture with spaces", "{malformed-json-with-a-long-fixture-value",
                    "[\"offline-array-is-not-a-credential-fixture\"]"] {
      precondition(LocalCredentialScanner.claudeToken(from: Data(invalid.utf8)) == nil,
                   "Malformed or implausible raw payloads must not become credentials")
    }
    precondition(LocalCredentialScanner.claudeToken(from: Data([0xFF, 0xFE])) == nil)
  }

  @MainActor private static func testDiscoveryRunsOffTheMainThread() {
    precondition(Thread.isMainThread, "The regression must start from the app's main-thread actor")
    let fileLogin = credential(provider: .kimi, key: CredentialField.kimiAPIKey, value: "offline-background-file-fixture")
    let scanner = LocalCredentialScanner(
      discoverFiles: {
        precondition(!Thread.isMainThread, "File discovery must not block the main thread")
        return CredentialDiscoveryResult(credentials: [fileLogin], diagnostics: ["background file fixture"])
      },
      readKeychain: { interaction in
        precondition(!Thread.isMainThread, "An explicit Keychain scan must not block the main thread")
        precondition(interaction == .allowPrompts)
        return .init(token: fixtureToken, diagnostic: "background keychain fixture")
      })
    let completion = ScanCompletion()
    let task = Task { @MainActor in
      precondition(Thread.isMainThread, "Invoke discovery from the same main-thread actor as the app")
      completion.result = await scanner.discoverInBackground(interaction: .allowPrompts)
      precondition(Thread.isMainThread, "Results must return to their caller's actor")
    }
    defer { task.cancel() }
    // A synchronous main keeps macOS's main thread alive while its run loop
    // services MainActor jobs, avoiding command-line async-main thread changes.
    let deadline = Date().addingTimeInterval(15)
    while completion.result == nil && Date() < deadline {
      _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    guard let result = completion.result else { preconditionFailure("Background discovery did not complete") }
    precondition(result.credentials.count == 2 && result.credentials.first == fileLogin)
    precondition(result.credentials.last?.credentials[CredentialField.anthropicAccessToken] == fixtureToken)
    precondition(result.diagnostics == ["background file fixture", "Claude Code Keychain: background keychain fixture"])
  }

  private static func credential(provider: QuotaProvider, key: String, value: String) -> DiscoveredCredential {
    DiscoveredCredential(stableID: "offline:\(provider.rawValue)", provider: provider,
      suggestedName: provider.displayName, sourceLabel: "offline fixture", credentials: [key: value])
  }
}

@MainActor private final class ScanCompletion {
  var result: CredentialDiscoveryResult?
}

private final class InteractionRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [LocalCredentialScanner.KeychainInteraction] = []
  var values: [LocalCredentialScanner.KeychainInteraction] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }
  func append(_ value: LocalCredentialScanner.KeychainInteraction) {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(value)
  }
}
