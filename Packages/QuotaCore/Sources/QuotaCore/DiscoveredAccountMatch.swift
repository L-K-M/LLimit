import Foundation

public extension DiscoveredCredential {
  /// Whether this local login is already represented by an LLimit account.
  func matchesStoredAccount(_ account: ProviderAccount) -> Bool {
    guard account.provider == provider, !CodexAccountProfile.isManaged(account.credentials),
          account.credentials[CredentialField.anthropicCredentialSource] != ClaudeCodeCredentialSource.managedProfile.rawValue,
          ClaudeCodeProfile.profile(from: account.credentials) == nil else { return false }

    func value(_ source: [String: String], _ key: String) -> String {
      source[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    func sameSecret(_ key: String) -> Bool {
      let token = value(credentials, key)
      return !token.isEmpty && !token.isEnvironmentReference && token == value(account.credentials, key)
    }
    func sameContext(_ key: String) -> Bool {
      value(credentials, key) == value(account.credentials, key)
    }

    // Only primary authentication identifies a login. A shared email, allowance,
    // server address, or secondary refresh grant must never mark another login Added.
    switch provider {
    case .anthropic: return sameSecret(CredentialField.anthropicAccessToken)
    case .openAI:
      return sameSecret(CredentialField.openAIAccessToken) && sameContext(CredentialField.openAIAccountID)
    case .googleAntigravity:
      return sameSecret(CredentialField.googleRefreshToken) && sameContext(CredentialField.googleProjectID)
    case .devin:
      func server(_ source: [String: String]) -> String {
        let override = value(source, CredentialField.devinAPIServer)
        return (override.isEmpty ? DevinQuotaClient.defaultServerURL.absoluteString : override)
          .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      }
      return sameSecret(CredentialField.devinAPIKey) && server(credentials) == server(account.credentials)
    case .gitHubCopilot:
      func usesPAT(_ source: [String: String]) -> Bool {
        // Match CopilotClient's routing before validating the selected secret.
        !(source[CredentialField.copilotPATToken] ?? "").isEmpty
          && !(source[CredentialField.copilotUsername] ?? "").isEmpty
      }
      guard usesPAT(credentials) == usesPAT(account.credentials) else { return false }
      if usesPAT(credentials) {
        return sameSecret(CredentialField.copilotPATToken)
          && value(credentials, CredentialField.copilotUsername).caseInsensitiveCompare(
            value(account.credentials, CredentialField.copilotUsername)) == .orderedSame
      }
      return sameSecret(CredentialField.copilotOAuthToken)
    case .zhipu: return sameSecret(CredentialField.zhipuAPIKey)
    case .zai: return sameSecret(CredentialField.zaiAPIKey)
    case .kimi: return sameSecret(CredentialField.kimiAPIKey)
    case .metaMuse: return sameSecret(CredentialField.metaMuseAPIKey)
    case .openCodeGo: return sameSecret(CredentialField.openCodeGoAPIKey)
    case .venice: return sameSecret(CredentialField.veniceAPIKey)
    case .cline: return sameSecret(CredentialField.clineAPIKey)
    case .junie: return sameSecret(CredentialField.junieAPIKey)
    case .minimax: return sameSecret(CredentialField.minimaxAPIKey)
    case .stepFun:
      guard sameSecret(CredentialField.stepFunPlanKey) else { return false }
      let detectedUID = value(credentials, CredentialField.stepFunUserID)
      let savedUID = value(account.credentials, CredentialField.stepFunUserID)
      guard !detectedUID.isEmpty, !savedUID.isEmpty else { return true }
      func userID(_ value: String) -> Int64? {
        guard value.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              let number = Int64(value), number > 0 else { return nil }
        return number
      }
      guard let detectedID = userID(detectedUID), let savedID = userID(savedUID) else { return false }
      return detectedID == savedID
    case .xiaomiMiMo: return false // Browser connections have no local-tool importer.
    }
  }
}
