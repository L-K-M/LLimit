import Foundation

/// A credential auto-detected from a locally-installed AI CLI / tool.
///
/// LLimit never asks the user to paste tokens: it reads the same on-disk
/// credentials that tools like Claude Code, Codex, GitHub Copilot and OpenCode
/// already wrote when the user logged in.
public struct DiscoveredCredential: Sendable, Hashable, Identifiable, Codable {
  public var id: String { stableID }
  /// Deterministic identity so user preferences (enabled / custom name) survive a rescan.
  public var stableID: String
  public var provider: QuotaProvider
  public var suggestedName: String
  /// Human-readable origin, e.g. "Claude Code (~/.claude)".
  public var sourceLabel: String
  public var credentials: [String: String]

  public init(
    stableID: String,
    provider: QuotaProvider,
    suggestedName: String,
    sourceLabel: String,
    credentials: [String: String]
  ) {
    self.stableID = stableID
    self.provider = provider
    self.suggestedName = suggestedName
    self.sourceLabel = sourceLabel
    self.credentials = credentials
  }
}

public struct CredentialDiscoveryResult: Sendable {
  public var credentials: [DiscoveredCredential]
  public var diagnostics: [String]

  public init(credentials: [DiscoveredCredential], diagnostics: [String]) {
    self.credentials = credentials
    self.diagnostics = diagnostics
  }
}

/// Scans well-known local config locations and returns usable provider credentials.
///
/// Pure Foundation and fully injectable (home directories + file manager) so it can
/// be unit tested against fixture directories. Keychain access (Claude Code on macOS)
/// is layered on top by the host app via ``merging(_:)``.
public struct CredentialDiscovery: Sendable {
  private let homeDirectories: [URL]
  private let fileManager: FileManager

  public init(
    homeDirectories: [URL]? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) {
    self.fileManager = fileManager
    if let homeDirectories, !homeDirectories.isEmpty {
      self.homeDirectories = homeDirectories
    } else {
      self.homeDirectories = CredentialDiscovery.defaultHomeDirectories(environment: environment, fileManager: fileManager)
    }
  }

  public func discover() -> CredentialDiscoveryResult {
    var candidates: [DiscoveredCredential] = []
    var diagnostics: [String] = []

    for home in homeDirectories {
      candidates += scanClaudeCode(home: home, diagnostics: &diagnostics)
      candidates += scanCodex(home: home, diagnostics: &diagnostics)
      candidates += scanCopilotEditor(home: home, diagnostics: &diagnostics)
      candidates += scanKimi(home: home, diagnostics: &diagnostics)
      candidates += scanAntigravity(home: home, diagnostics: &diagnostics)
      candidates += scanOpenCode(home: home, diagnostics: &diagnostics)
    }

    return CredentialDiscoveryResult(credentials: dedupe(candidates), diagnostics: diagnostics)
  }

  // MARK: - Sources

  private func scanClaudeCode(home: URL, diagnostics: inout [String]) -> [DiscoveredCredential] {
    let url = path(home, ".claude", ".credentials.json")
    guard let object = readJSON(at: url, label: "Claude Code", diagnostics: &diagnostics) else { return [] }

    // Format is either { "claudeAiOauth": { "accessToken": ... } } or a flat object.
    let oauth = (object["claudeAiOauth"] as? [String: Any]) ?? object
    guard let token = nonEmptyString(oauth["accessToken"] ?? oauth["access_token"]) else {
      diagnostics.append("Claude Code: file found but no access token")
      return []
    }

    diagnostics.append("Claude Code: found OAuth token (\(shortPath(url)))")
    return [
      DiscoveredCredential(
        stableID: "anthropic:claude-code",
        provider: .anthropic,
        suggestedName: "Claude",
        sourceLabel: "Claude Code (~/.claude)",
        credentials: [CredentialField.anthropicAccessToken: token]
      )
    ]
  }

  private func scanCodex(home: URL, diagnostics: inout [String]) -> [DiscoveredCredential] {
    let url = path(home, ".codex", "auth.json")
    guard let object = readJSON(at: url, label: "Codex", diagnostics: &diagnostics) else { return [] }

    let tokens = (object["tokens"] as? [String: Any]) ?? object
    guard let access = nonEmptyString(tokens["access_token"]) else {
      diagnostics.append("Codex: file found but no ChatGPT access token")
      return []
    }

    var credentials = [CredentialField.openAIAccessToken: access]
    if let accountID = nonEmptyString(tokens["account_id"]) ?? extractOpenAIAccountID(from: access) {
      credentials[CredentialField.openAIAccountID] = accountID
    }
    if let refresh = nonEmptyString(tokens["refresh_token"]) {
      credentials[CredentialField.openAIRefreshToken] = refresh
    }

    diagnostics.append("Codex: found ChatGPT token (\(shortPath(url)))")
    return [
      DiscoveredCredential(
        stableID: "openai:codex",
        provider: .openAI,
        suggestedName: "OpenAI (Codex)",
        sourceLabel: "Codex CLI (~/.codex)",
        credentials: credentials
      )
    ]
  }

  private func scanCopilotEditor(home: URL, diagnostics: inout [String]) -> [DiscoveredCredential] {
    var results: [DiscoveredCredential] = []

    // VS Code / Neovim Copilot store OAuth tokens here.
    for fileName in ["apps.json", "hosts.json"] {
      let url = path(home, ".config", "github-copilot", fileName)
      guard let object = readJSON(at: url, label: "GitHub Copilot", diagnostics: &diagnostics) else { continue }

      for (hostKey, value) in object {
        guard
          let entry = value as? [String: Any],
          let token = nonEmptyString(entry["oauth_token"])
        else { continue }

        let user = nonEmptyString(entry["user"])
        results.append(
          DiscoveredCredential(
            stableID: "github-copilot:editor:\(hostKey)",
            provider: .gitHubCopilot,
            suggestedName: user.map { "Copilot (@\($0))" } ?? "GitHub Copilot",
            sourceLabel: "GitHub Copilot (~/.config/github-copilot/\(fileName))",
            credentials: copilotCredentials(oauth: token, username: user)
          )
        )
      }
      if !results.isEmpty {
        diagnostics.append("GitHub Copilot: found OAuth token (\(shortPath(url)))")
      }
    }

    // GitHub Copilot CLI plaintext fallback.
    let cliURL = path(home, ".copilot", "config.json")
    if let object = readJSON(at: cliURL, label: "GitHub Copilot CLI", diagnostics: &diagnostics) {
      if let token = nonEmptyString(object["oauth_token"]) ?? nonEmptyString(object["github_token"]) ?? nonEmptyString(object["token"]) {
        results.append(
          DiscoveredCredential(
            stableID: "github-copilot:cli",
            provider: .gitHubCopilot,
            suggestedName: "GitHub Copilot",
            sourceLabel: "GitHub Copilot CLI (~/.copilot)",
            credentials: copilotCredentials(oauth: token, username: nil)
          )
        )
        diagnostics.append("GitHub Copilot CLI: found token (\(shortPath(cliURL)))")
      }
    }

    return results
  }

  private func scanKimi(home: URL, diagnostics: inout [String]) -> [DiscoveredCredential] {
    // The Kimi CLI (~/.kimi) and its standalone successor Kimi Code
    // (~/.kimi-code) both store the OAuth login at
    // credentials/kimi-code.json; the access token doubles as the Bearer key
    // for the coding-plan usage endpoint.
    let sources: [(stableID: String, url: URL, label: String)] = [
      ("kimi:kimi-cli", path(home, ".kimi", "credentials", "kimi-code.json"), "Kimi CLI (~/.kimi)"),
      ("kimi:kimi-code", path(home, ".kimi-code", "credentials", "kimi-code.json"), "Kimi Code (~/.kimi-code)")
    ]

    var results: [DiscoveredCredential] = []
    for source in sources {
      guard let object = readJSON(at: source.url, label: "Kimi", diagnostics: &diagnostics) else { continue }
      guard let token = nonEmptyString(object["access_token"]) else {
        diagnostics.append("Kimi: file found but no access token (\(shortPath(source.url)))")
        continue
      }

      // kimi-cli writes expires_at as epoch seconds (0.0 when unknown);
      // parseDateValue also tolerates string/millisecond variants.
      if let expiresAt = parseDateValue(object["expires_at"]),
         expiresAt.timeIntervalSince1970 > 0,
         expiresAt < Date() {
        diagnostics.append("Kimi: token expired (\(shortPath(source.url))) — run the Kimi CLI to refresh it, or paste an API key from kimi.com/code/console")
        continue
      }

      var credentials = [CredentialField.kimiAPIKey: token]
      // No refresh flow exists yet, but keeping the refresh token means a
      // future one can renew this account without a re-import.
      if let refresh = nonEmptyString(object["refresh_token"]) {
        credentials[CredentialField.kimiRefreshToken] = refresh
      }

      results.append(
        DiscoveredCredential(
          stableID: source.stableID,
          provider: .kimi,
          suggestedName: "Kimi",
          sourceLabel: source.label,
          credentials: credentials
        )
      )
      diagnostics.append("Kimi: found OAuth token (\(shortPath(source.url)))")
    }

    return results
  }

  /// Antigravity (Google's IDE) and its CLI keep the Google login under `~/.gemini`.
  ///
  /// The store has moved between Antigravity releases and each component spells
  /// the keys differently, so probe every location known to have held it and
  /// accept both snake_case and camelCase. Only the refresh token is imported:
  /// ``GoogleAntigravityClient`` exchanges it for an access token on every fetch,
  /// so a stale access token in these files does not matter and is not checked.
  ///
  /// Sources are probed in a fixed order, newest Antigravity layout first — file
  /// mtimes are never consulted — and the first store holding a refresh token wins
  /// whole. Credentials are never mixed across stores: two of these files can
  /// belong to two different Google accounts, and pairing one account's token with
  /// another's project id would silently report the wrong quota.
  ///
  /// The email is the one exception, and it is only ever a label. When the winning
  /// store names no account, it falls back to the Gemini CLI's `oauth_creds.json`,
  /// which can in principle hold a different Google login, so that borrowing is
  /// called out in the diagnostics. The quota fetch is unaffected: the token and
  /// the project id still come from a single store.
  ///
  /// The project id is therefore optional. Some stores omit it, and such a login
  /// is still worth importing: the account arrives pre-filled and both UIs report
  /// the project id as the one missing credential to supply.
  private func scanAntigravity(home: URL, diagnostics: inout [String]) -> [DiscoveredCredential] {
    let sources: [(url: URL, label: String)] = [
      (path(home, ".gemini", "antigravity", "session.json"), "Antigravity (~/.gemini/antigravity)"),
      (path(home, ".gemini", "antigravity-cli", "antigravity-oauth-token"), "Antigravity CLI (~/.gemini/antigravity-cli)"),
      (path(home, ".gemini", "antigravity-cli", "antigravity-auth-token"), "Antigravity CLI (~/.gemini/antigravity-cli)"),
      (path(home, ".gemini", "jetski-standalone-oauth-token"), "Antigravity (~/.gemini)")
    ]

    var tokenless: [String] = []

    for source in sources {
      guard let object = readJSON(at: source.url, label: "Antigravity", diagnostics: &diagnostics) else { continue }
      let fields = antigravityFields(in: object)

      guard let refreshToken = fields.refreshToken else {
        tokenless.append(shortPath(source.url))
        continue
      }

      // Older installs record the signed-in identity in the Gemini CLI's own
      // credential file rather than beside the Antigravity token.
      var email = fields.email
      if email == nil,
         let credentialsFile = readJSON(at: path(home, ".gemini", "oauth_creds.json"), label: "Gemini", diagnostics: &diagnostics) {
        email = antigravityFields(in: credentialsFile).email
        if email != nil {
          diagnostics.append("Antigravity: account name taken from the Gemini CLI login (~/.gemini/oauth_creds.json) — check that it is the same Google account")
        }
      }

      var credentials = [CredentialField.googleRefreshToken: refreshToken]
      if let projectID = fields.projectID { credentials[CredentialField.googleProjectID] = projectID }
      if let email { credentials[CredentialField.googleEmail] = email }

      diagnostics.append(
        fields.projectID == nil
          ? "Antigravity: found login without a project id (\(shortPath(source.url))) — add the project id after importing"
          : "Antigravity: found login (\(shortPath(source.url)))"
      )

      return [
        DiscoveredCredential(
          stableID: "google-antigravity:antigravity:\(email ?? shortPath(source.url))",
          provider: .googleAntigravity,
          suggestedName: email.map { "Google Antigravity (\($0))" } ?? "Google Antigravity",
          sourceLabel: source.label,
          credentials: credentials
        )
      ]
    }

    if !tokenless.isEmpty {
      diagnostics.append("Antigravity: no refresh token in \(tokenless.joined(separator: ", ")) — sign in again in Antigravity")
    }

    return []
  }

  private func scanOpenCode(home: URL, diagnostics: inout [String]) -> [DiscoveredCredential] {
    var results: [DiscoveredCredential] = []

    let authURLs = [
      path(home, ".local", "share", "opencode", "auth.json"),
      path(home, ".config", "opencode", "auth.json")
    ]

    for url in authURLs {
      guard let object = readJSON(at: url, label: "OpenCode", diagnostics: &diagnostics) else { continue }

      if let openai = object["openai"] as? [String: Any],
         (openai["type"] as? String) == "oauth",
         let access = nonEmptyString(openai["access"]) {
        var credentials = [CredentialField.openAIAccessToken: access]
        if let accountID = extractOpenAIAccountID(from: access) {
          credentials[CredentialField.openAIAccountID] = accountID
        }
        if let refresh = nonEmptyString(openai["refresh"]) {
          credentials[CredentialField.openAIRefreshToken] = refresh
        }
        results.append(make("openai:opencode", .openAI, "OpenAI (OpenCode)", url, credentials))
      }

      if let anthropic = object["anthropic"] as? [String: Any],
         (anthropic["type"] as? String) == "oauth",
         let access = nonEmptyString(anthropic["access"]) {
        results.append(make("anthropic:opencode", .anthropic, "Claude (OpenCode)", url, [CredentialField.anthropicAccessToken: access]))
      }

      if let key = apiKey(in: object, provider: "zhipuai-coding-plan") {
        results.append(make("zhipu:opencode", .zhipu, "Zhipu AI", url, [CredentialField.zhipuAPIKey: key]))
      }

      if let key = apiKey(in: object, provider: "zai-coding-plan") {
        results.append(make("zai:opencode", .zai, "Z.ai", url, [CredentialField.zaiAPIKey: key]))
      }

      if let key = apiKey(in: object, provider: "kimi-for-coding") {
        results.append(make("kimi:opencode", .kimi, "Kimi", url, [CredentialField.kimiAPIKey: key]))
      }

      if let copilot = object["github-copilot"] as? [String: Any],
         (copilot["type"] as? String) == "oauth",
         let oauth = nonEmptyString(copilot["refresh"]) ?? nonEmptyString(copilot["access"]) {
        results.append(make("github-copilot:opencode", .gitHubCopilot, "GitHub Copilot", url, copilotCredentials(oauth: oauth, username: nil)))
      }

      if !results.isEmpty {
        diagnostics.append("OpenCode: found credentials (\(shortPath(url)))")
      }
    }

    // Google Antigravity accounts (separate file, beside auth.json in whichever
    // OpenCode root this install uses).
    for antigravityURL in [
      path(home, ".local", "share", "opencode", "antigravity-accounts.json"),
      path(home, ".config", "opencode", "antigravity-accounts.json")
    ] {
      guard
        let object = readJSON(at: antigravityURL, label: "Antigravity", diagnostics: &diagnostics),
        let accounts = object["accounts"] as? [[String: Any]]
      else { continue }

      let usable = accounts
        .sorted { ((($0["lastUsed"] as? NSNumber)?.doubleValue) ?? 0) > ((($1["lastUsed"] as? NSNumber)?.doubleValue) ?? 0) }
        .first { account in
          nonEmptyString(account["refreshToken"]) != nil &&
          (nonEmptyString(account["projectId"]) ?? nonEmptyString(account["managedProjectId"])) != nil
        }

      if let best = usable {
        let refresh = nonEmptyString(best["refreshToken"]) ?? ""
        let project = nonEmptyString(best["projectId"]) ?? nonEmptyString(best["managedProjectId"]) ?? ""
        let email = nonEmptyString(best["email"])
        var credentials = [
          CredentialField.googleRefreshToken: refresh,
          CredentialField.googleProjectID: project
        ]
        if let email { credentials[CredentialField.googleEmail] = email }

        results.append(
          DiscoveredCredential(
            stableID: "google-antigravity:opencode:\(email ?? project)",
            provider: .googleAntigravity,
            suggestedName: email.map { "Google Antigravity (\($0))" } ?? "Google Antigravity",
            sourceLabel: "OpenCode (\(shortPath(antigravityURL)))",
            credentials: credentials
          )
        )
        diagnostics.append("Antigravity: found account (\(shortPath(antigravityURL)))")
      }
    }

    // Copilot PAT quota token (separate file).
    let copilotPATURL = path(home, ".config", "opencode", "copilot-quota-token.json")
    if let object = readJSON(at: copilotPATURL, label: "Copilot PAT", diagnostics: &diagnostics),
       let token = nonEmptyString(object["token"]),
       let username = nonEmptyString(object["username"]) {
      var credentials = [
        CredentialField.copilotPATToken: token,
        CredentialField.copilotUsername: username
      ]
      if let tier = nonEmptyString(object["tier"]) {
        credentials[CredentialField.copilotTier] = tier
      }
      results.append(
        DiscoveredCredential(
          stableID: "github-copilot:opencode-pat",
          provider: .gitHubCopilot,
          suggestedName: "Copilot (@\(username))",
          sourceLabel: "Copilot PAT (~/.config/opencode)",
          credentials: credentials
        )
      )
      diagnostics.append("Copilot PAT: found (\(shortPath(copilotPATURL)))")
    }

    return results
  }

  // MARK: - Helpers

  private func make(
    _ stableID: String,
    _ provider: QuotaProvider,
    _ name: String,
    _ url: URL,
    _ credentials: [String: String]
  ) -> DiscoveredCredential {
    DiscoveredCredential(
      stableID: stableID,
      provider: provider,
      suggestedName: name,
      sourceLabel: "OpenCode (\(shortPath(url)))",
      credentials: credentials
    )
  }

  /// Pulls the Google login out of one Antigravity credential file.
  ///
  /// Every field is optional: these files are undocumented, and which keys are
  /// present depends on the version of the component that wrote them.
  private func antigravityFields(in object: [String: Any]) -> (refreshToken: String?, projectID: String?, email: String?) {
    let nested = ["tokens", "token", "credentials", "session", "oauth", "account"]
      .compactMap { object[$0] as? [String: Any] }
    let containers = [object] + nested

    let email = firstValue(["email", "userEmail", "user_email"], in: containers)
      ?? firstValue(["id_token", "idToken"], in: containers)
        .flatMap { decodeJWTPayload($0) }
        .flatMap { nonEmptyString($0["email"]) }

    return (
      refreshToken: firstValue(["refresh_token", "refreshToken"], in: containers),
      projectID: firstValue(["projectId", "project_id", "managedProjectId", "managed_project_id", "project"], in: containers),
      email: email
    )
  }

  /// First non-empty string found by trying every key against every container.
  private func firstValue(_ keys: [String], in containers: [[String: Any]]) -> String? {
    for container in containers {
      for key in keys {
        if let value = nonEmptyString(container[key]) { return value }
      }
    }
    return nil
  }

  private func copilotCredentials(oauth: String, username: String?) -> [String: String] {
    var credentials = [CredentialField.copilotOAuthToken: oauth]
    if let username { credentials[CredentialField.copilotUsername] = username }
    return credentials
  }

  private func apiKey(in object: [String: Any], provider: String) -> String? {
    guard
      let entry = object[provider] as? [String: Any],
      (entry["type"] as? String) == "api"
    else { return nil }
    return nonEmptyString(entry["key"])
  }

  /// Keeps the first occurrence of each provider+token pair so the same login surfaced
  /// by two tools doesn't show up twice.
  private func dedupe(_ candidates: [DiscoveredCredential]) -> [DiscoveredCredential] {
    var seenStableIDs: Set<String> = []
    var seenFingerprints: Set<String> = []
    var output: [DiscoveredCredential] = []

    for candidate in candidates {
      if seenStableIDs.contains(candidate.stableID) { continue }
      let fingerprint = "\(candidate.provider.rawValue)|\(candidate.credentials.values.sorted().joined(separator: "|"))"
      if seenFingerprints.contains(fingerprint) { continue }
      seenStableIDs.insert(candidate.stableID)
      seenFingerprints.insert(fingerprint)
      output.append(candidate)
    }

    return output.sorted { lhs, rhs in
      if lhs.provider != rhs.provider {
        return lhs.provider.displayName < rhs.provider.displayName
      }
      return lhs.stableID < rhs.stableID
    }
  }

  private func readJSON(at url: URL, label: String, diagnostics: inout [String]) -> [String: Any]? {
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    do {
      let data = try Data(contentsOf: url)
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        diagnostics.append("\(label): \(shortPath(url)) is not a JSON object")
        return nil
      }
      return object
    } catch {
      diagnostics.append("\(label): could not read \(shortPath(url)) (\(error.localizedDescription))")
      return nil
    }
  }

  private func path(_ base: URL, _ components: String...) -> URL {
    components.reduce(base) { $0.appendingPathComponent($1) }
  }

  private func shortPath(_ url: URL) -> String {
    let path = url.path
    for home in homeDirectories where path.hasPrefix(home.path) {
      return "~" + path.dropFirst(home.path.count)
    }
    return path
  }

  private func extractOpenAIAccountID(from jwt: String) -> String? {
    guard
      let payload = decodeJWTPayload(jwt),
      let auth = payload["https://api.openai.com/auth"] as? [String: Any]
    else {
      return nil
    }
    return nonEmptyString(auth["chatgpt_account_id"])
  }

  /// Decodes a JWT's claims without verifying it: these tokens come from the
  /// user's own login, and the claims are read only to label the account.
  private func decodeJWTPayload(_ jwt: String) -> [String: Any]? {
    let parts = jwt.split(separator: ".")
    guard parts.count == 3 else { return nil }

    var payload = String(parts[1])
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = payload.count % 4
    if remainder != 0 {
      payload += String(repeating: "=", count: 4 - remainder)
    }

    guard let data = Data(base64Encoded: payload) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  private static func defaultHomeDirectories(environment: [String: String], fileManager: FileManager) -> [URL] {
    var homes: [URL] = [fileManager.homeDirectoryForCurrentUser]
    if let envHome = environment["HOME"], !envHome.isEmpty {
      homes.append(URL(fileURLWithPath: envHome, isDirectory: true))
    }

    var seen: Set<String> = []
    return homes.filter { seen.insert($0.standardizedFileURL.path).inserted }
  }
}
