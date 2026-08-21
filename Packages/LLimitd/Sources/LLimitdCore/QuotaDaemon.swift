import Foundation
import QuotaCore

/// Headless orchestration for the Linux port: the moral equivalent of the macOS app's
/// `AppModel` + `RefreshService`, with no UI framework, no Combine/Observation, no
/// Keychain, no App Group and no WidgetCenter. It owns the settings file (mode 0600,
/// the only place credentials live), the snapshot and history stores under
/// `$XDG_DATA_HOME`, and the refresh loop.
///
/// Behavioral reference: `LLimitApp/AppModel.swift` and
/// `LLimitApp/Services/RefreshService.swift`. The pieces intentionally ported across:
///  - stale-usage merging: a failed account keeps its last-known usage in the snapshot
///    (`QuotaSnapshot.mergingStaleUsage(from:)`), the failure is recorded alongside;
///  - OpenAI/ChatGPT token hygiene: adopt Codex's live on-disk tokens, refresh expired
///    ones, and reactively recover accounts that failed auth this cycle, then re-fetch
///    only those accounts;
///  - Claude token adoption: re-read Claude Code's live local token before refreshing;
///  - account removal purges that account's history and reconciles the snapshot.
///
/// Fetch errors never propagate out of `refreshNow()` — provider APIs are undocumented
/// and unstable, so a failure lands in `statusMessage` and the last good snapshot keeps
/// being served. The daemon must not crash on a fetch error.
public final class QuotaDaemon {
  public private(set) var settings: AppSettings = .default
  public private(set) var snapshot: QuotaSnapshot?
  public private(set) var statusMessage: String = ""
  /// Credentials detected from local AI tools, offered as one-click imports. A
  /// convenience only — imported accounts are fully owned and stored by LLimit.
  public private(set) var detectedCredentials: [DiscoveredCredential] = []
  public private(set) var discoveryDiagnostics: [String] = []

  public let paths: LinuxPaths
  /// Serializes settings read-modify-write cycles against other llimit processes
  /// (see SettingsLock). CLI mutations re-load settings inside this lock so a
  /// concurrent daemon save can no longer silently drop an edit.
  public let settingsLock: SettingsLock
  private let settingsStore: SettingsStore
  private let snapshotStore: SnapshotStore
  private let historyStore: QuotaHistoryStore
  private let coordinator: QuotaCoordinator
  private let makeDiscovery: () -> CredentialDiscovery
  /// Mirrors AppModel: when the settings file can't be decoded, refuse to overwrite
  /// it (it may hold credentials) until the user fixes or removes it.
  private var configurationLoadFailed = false
  /// Log sink so the CLI can route daemon logs; tests capture them.
  private let log: (String) -> Void

  public init(
    paths: LinuxPaths,
    coordinator: QuotaCoordinator = .live(),
    makeDiscovery: @escaping () -> CredentialDiscovery = { CredentialDiscovery() },
    log: @escaping (String) -> Void = { line in
      // Unbuffered: the daemon's stdout is a pipe (journald), where print()
      // would sit in the stdio buffer.
      FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
  ) {
    self.paths = paths
    self.settingsLock = SettingsLock(settingsFileURL: paths.settingsFileURL)
    self.settingsStore = SettingsStore(fileURL: paths.settingsFileURL)
    self.snapshotStore = SnapshotStore(fileURL: paths.snapshotFileURL)
    self.historyStore = QuotaHistoryStore(fileURL: paths.historyFileURL)
    self.coordinator = coordinator
    self.makeDiscovery = makeDiscovery
    self.log = log
  }

  // MARK: - Configuration

  /// Loads settings and the last snapshot from disk. A missing settings file yields
  /// defaults; an unreadable one blocks saving (see `configurationLoadFailed`).
  public func loadConfiguration() {
    do {
      settings = try settingsStore.load()
      configurationLoadFailed = false
    } catch {
      settings = .default
      configurationLoadFailed = true
      statusMessage = "Could not load settings. Using defaults. The existing file will not be overwritten."
    }

    do {
      snapshot = try snapshotStore.load()
      reconcileSnapshotWithCurrentAccounts()
    } catch {
      statusMessage = "Could not load snapshot: \(error.localizedDescription)"
    }
  }

  /// Persists the current settings. The settings file is the ONLY credential-bearing
  /// file; snapshot/history/status output never contain credentials by construction
  /// (the snapshot is built from ProviderUsage/ProviderFailure, which have no
  /// credential fields).
  public func saveConfiguration() throws {
    guard !configurationLoadFailed else {
      throw DaemonError.settingsFileUnreadable
    }
    try settingsStore.save(settings)
  }

  // MARK: - Accounts (the Settings → Accounts surface, as plain mutations)

  @discardableResult
  public func addAccount(
    provider: QuotaProvider,
    displayName: String? = nil,
    credentials: [String: String] = [:]
  ) -> ProviderAccount {
    var mergedCredentials = Dictionary(uniqueKeysWithValues: provider.credentialFields.map { ($0.key, "") })
    for (key, value) in credentials {
      mergedCredentials[key] = value
    }

    let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let account = ProviderAccount(
      provider: provider,
      displayName: (name?.isEmpty == false) ? name : nextDisplayName(for: provider),
      isEnabled: true,
      credentials: mergedCredentials
    )

    settings.accounts.append(account)
    normalizeAndSave()
    return account
  }

  /// Creates a new LLimit-owned account pre-filled with a detected credential.
  @discardableResult
  public func importAccount(from detected: DiscoveredCredential) -> ProviderAccount {
    let name = detected.suggestedName.trimmingCharacters(in: .whitespacesAndNewlines)
    return addAccount(
      provider: detected.provider,
      displayName: name.isEmpty ? nextDisplayName(for: detected.provider) : name,
      credentials: detected.credentials
    )
  }

  public func setAccountEnabled(_ accountID: String, _ enabled: Bool) throws {
    guard let index = settings.accounts.firstIndex(where: { $0.id == accountID }) else {
      throw DaemonError.unknownAccount(accountID)
    }
    settings.accounts[index].isEnabled = enabled
    reconcileSnapshotWithCurrentAccounts()
    normalizeAndSave()
  }

  public func removeAccount(_ accountID: String) throws {
    guard let removed = settings.accounts.first(where: { $0.id == accountID }) else {
      throw DaemonError.unknownAccount(accountID)
    }
    settings.accounts.removeAll { $0.id == accountID }
    settings.providerTileSlots = settings.providerTileSlots.map { $0 == accountID ? "" : $0 }
    reconcileSnapshotWithCurrentAccounts()
    purgeHistory(for: removed)
    normalizeAndSave()
  }

  /// Resolves a full account ID or a unique prefix (so the CLI can take short IDs).
  public func resolveAccountID(_ fragment: String) -> String? {
    if settings.accounts.contains(where: { $0.id == fragment }) {
      return fragment
    }
    let matches = settings.accounts.filter { $0.id.hasPrefix(fragment) }
    return matches.count == 1 ? matches[0].id : nil
  }

  /// True when an existing account already holds the same token for this provider,
  /// so the CLI can say "already imported" instead of offering a duplicate.
  public func isDetectedCredentialImported(_ detected: DiscoveredCredential) -> Bool {
    let tokens = Set(detected.credentials.values.filter { !$0.isEmpty })
    guard !tokens.isEmpty else { return false }
    return settings.accounts.contains { account in
      account.provider == detected.provider
        && !Set(account.credentials.values).isDisjoint(with: tokens)
    }
  }

  // MARK: - Detect & import (convenience)

  /// Scans local AI tools for credentials that could seed a new account. On Linux
  /// there is no Keychain branch — Claude Code writes `~/.claude/.credentials.json`
  /// directly, which `CredentialDiscovery` already reads.
  public func scanForDetectedCredentials() {
    let result = makeDiscovery().discover()
    detectedCredentials = result.credentials
    discoveryDiagnostics = result.diagnostics
  }

  // MARK: - Refresh

  /// One refresh cycle. Never throws: every failure is captured in the snapshot's
  /// `failures` and/or `statusMessage`, and the last good snapshot stays on disk.
  public func refreshNow() async {
    await refreshExpiringChatGPTTokens()
    refreshLiveClaudeTokens()

    let enabledConfigs = runtimeConfigurations().filter { configuration in
      configuration.isEnabled && configuration.provider.hasRequiredCredentials(configuration.credentials)
    }

    guard !enabledConfigs.isEmpty else {
      statusMessage = "No enabled provider accounts with complete credentials configured."
      log("[llimitd] \(statusMessage)")
      return
    }

    // Read the previous snapshot before overwriting it so accounts that fail this
    // cycle keep showing their last-known usage instead of vanishing.
    let previous = (try? snapshotStore.load()) ?? snapshot
    var refreshed = await coordinator.refresh(configurations: enabledConfigs)
      .mergingStaleUsage(from: previous)

    // Reactive recovery: if an enabled OpenAI account failed authentication (a token
    // revoked before its JWT exp, or a Codex rotation that landed mid-cycle), refresh
    // its token and retry — only the accounts we actually recovered, so healthy accounts
    // and the other providers aren't re-polled (Anthropic hard-rate-limits repeat pollers).
    let recoveredIDs = await recoverFailedOpenAITokens(in: refreshed)
    if !recoveredIDs.isEmpty {
      let retryConfigs = runtimeConfigurations().filter { configuration in
        recoveredIDs.contains(configuration.accountID)
          && configuration.isEnabled
          && configuration.provider.hasRequiredCredentials(configuration.credentials)
      }
      if !retryConfigs.isEmpty {
        let retriedIDs = Set(retryConfigs.map(\.accountID))
        let retrySnapshot = await coordinator.refresh(configurations: retryConfigs)
          .mergingStaleUsage(from: refreshed)
        refreshed = refreshed.replacingResults(forAccountIDs: retriedIDs, from: retrySnapshot)
      }
    }

    do {
      try snapshotStore.save(refreshed)
    } catch {
      statusMessage = "Snapshot save failed: \(error.localizedDescription)"
      log("[llimitd] \(statusMessage)")
      return
    }

    do {
      try historyStore.append(refreshed)
    } catch {
      log("[llimitd] History append failed: \(error.localizedDescription)")
    }

    snapshot = refreshed
    statusMessage = "Refreshed \(refreshed.providers.count) account(s), \(refreshed.failures.count) failure(s)"
    log("[llimitd] \(statusMessage)")
  }

  /// The daemon's main loop. Settings are re-loaded each cycle: on Linux account
  /// management is a separate `llimit` process, so the daemon must pick up its edits
  /// (unlike the macOS app, which is the sole writer of its own settings). Each
  /// load → refresh → save cycle runs under the settings lock: the daemon writes
  /// settings during token refresh, and without the lock a concurrent
  /// `llimit accounts …` edit could be overwritten by a stale save.
  public func runRefreshLoop() async {
    await refreshCycle(bootstrap: true)

    while !Task.isCancelled {
      let interval = autoRefreshIntervalNanoseconds()
      do {
        try await Task.sleep(nanoseconds: interval)
      } catch {
        return
      }

      if Task.isCancelled {
        return
      }

      await refreshCycle(bootstrap: false)
    }
  }

  /// One locked load → refresh cycle. On bootstrap a refresh only happens when the
  /// snapshot is missing or older than the configured interval.
  private func refreshCycle(bootstrap: Bool) async {
    do {
      try await settingsLock.withLock {
        loadConfiguration()
        if !bootstrap || shouldRefreshOnBootstrap() {
          await refreshNow()
        }
      }
    } catch {
      statusMessage = "Settings lock failed: \(error.localizedDescription)"
      log("[llimitd] \(statusMessage)")
    }
  }

  // MARK: - Token hygiene (ported from AppModel)

  /// ChatGPT tokens expire hourly, and OpenAI rotates refresh tokens — LLimit's
  /// imported copy dies as soon as the Codex CLI refreshes (and vice-versa). Adopt
  /// Codex's current on-disk token (matched by ChatGPT account id) and refresh
  /// anything still expired, so the two stay in sync instead of fighting the grant.
  private func refreshExpiringChatGPTTokens() async {
    // Only enabled accounts: refreshing a disabled account would keep rotating the
    // shared Codex refresh token and log the user's Codex CLI out.
    let openAIAccountIDs = settings.accounts.filter { $0.provider == .openAI && $0.isEnabled }.map(\.id)
    guard !openAIAccountIDs.isEmpty else { return }

    var didChange = adoptLiveOpenAITokens(forAccountIDs: openAIAccountIDs)

    for accountID in openAIAccountIDs {
      guard let index = settings.accounts.firstIndex(where: { $0.id == accountID }) else { continue }
      let credentials = settings.accounts[index].credentials
      guard let refreshToken = credentials[CredentialField.openAIRefreshToken], !refreshToken.isEmpty else { continue }

      let access = credentials[CredentialField.openAIAccessToken] ?? ""
      if !access.isEmpty, !ChatGPTOAuth.isAccessTokenExpired(access) { continue }

      if await refreshOpenAIAccount(id: accountID, refreshToken: refreshToken) {
        didChange = true
      }
    }

    if didChange {
      try? saveConfiguration()
    }
  }

  /// Adopts the live Codex/OpenCode tokens for the given accounts, matched by ChatGPT
  /// account id. Returns whether any account's credentials changed. Does not save.
  private func adoptLiveOpenAITokens(forAccountIDs accountIDs: [String]) -> Bool {
    let live = makeDiscovery().discover().credentials
      .filter { $0.provider == .openAI }
      .map(\.credentials)
    guard !live.isEmpty else { return false }

    var changed = false
    for accountID in accountIDs {
      guard let index = settings.accounts.firstIndex(where: { $0.id == accountID }) else { continue }
      guard let updated = OpenAICredentialSync.adoption(
        for: settings.accounts[index].credentials,
        among: live,
        expiry: ChatGPTOAuth.accessTokenExpiry
      ) else { continue }
      settings.accounts[index].credentials = updated
      changed = true
    }
    return changed
  }

  /// Exchanges the stored refresh token for a fresh access token (in memory; caller
  /// saves). On failure — typically `invalid_grant` after Codex rotated the grant —
  /// re-reads the live Codex file and adopts its token as a last resort.
  @discardableResult
  private func refreshOpenAIAccount(id accountID: String, refreshToken: String) async -> Bool {
    do {
      let result = try await ChatGPTOAuth.refresh(refreshToken: refreshToken)
      guard let index = settings.accounts.firstIndex(where: { $0.id == accountID }) else { return false }
      settings.accounts[index].credentials[CredentialField.openAIAccessToken] = result.accessToken
      if let newRefresh = result.refreshToken {
        settings.accounts[index].credentials[CredentialField.openAIRefreshToken] = newRefresh
      }
      if let newAccountID = result.accountID {
        settings.accounts[index].credentials[CredentialField.openAIAccountID] = newAccountID
      }
      return true
    } catch {
      log("[llimitd] ChatGPT token refresh failed: \(error.localizedDescription)")
      return adoptLiveOpenAITokens(forAccountIDs: [accountID])
    }
  }

  /// Reactive recovery for a ChatGPT access token revoked server-side before its JWT
  /// `exp`: such an account 401s every cycle while the proactive pass skips it. For
  /// each enabled OpenAI account that failed auth this cycle, first adopt a fresher
  /// live token; only if nothing fresher is on disk do we force a refresh (which
  /// rotates the grant). Returns the ids whose credentials changed, so the caller can
  /// retry exactly those accounts.
  private func recoverFailedOpenAITokens(in snapshot: QuotaSnapshot) async -> Set<String> {
    let failedIDs = snapshot.failures
      .filter { $0.provider == .openAI && $0.kind == .auth }
      .map(\.accountID)
    guard !failedIDs.isEmpty else { return [] }

    var recovered: Set<String> = []
    for accountID in failedIDs {
      guard
        let index = settings.accounts.firstIndex(where: { $0.id == accountID }),
        settings.accounts[index].provider == .openAI,
        settings.accounts[index].isEnabled
      else { continue }

      if adoptLiveOpenAITokens(forAccountIDs: [accountID]) {
        recovered.insert(accountID)
        continue
      }

      let refreshToken = settings.accounts[index].credentials[CredentialField.openAIRefreshToken] ?? ""
      if !refreshToken.isEmpty, await refreshOpenAIAccount(id: accountID, refreshToken: refreshToken) {
        recovered.insert(accountID)
      }
    }

    if !recovered.isEmpty {
      try? saveConfiguration()
    }
    return recovered
  }

  /// Claude Code refreshes its own OAuth token (in `~/.claude/.credentials.json`)
  /// roughly every 8 hours; LLimit's imported copy goes stale and 401s within hours.
  /// Re-read the live local token before refreshing and adopt it for enabled Claude
  /// accounts. Only accounts whose stored token is empty or is itself a Claude Code
  /// OAuth token (`sk-ant-oat…`) are updated, so a hand-entered token is never
  /// clobbered. On Linux there is no Keychain fallback — the file is the source.
  private func refreshLiveClaudeTokens() {
    let claudeAccountIDs = settings.accounts
      .filter { $0.provider == .anthropic && $0.isEnabled }
      .map(\.id)
    guard !claudeAccountIDs.isEmpty else { return }

    guard let liveToken = makeDiscovery().discover().credentials
      .first(where: { $0.provider == .anthropic })?
      .credentials[CredentialField.anthropicAccessToken],
      !liveToken.isEmpty
    else { return }

    var didChange = false
    for accountID in claudeAccountIDs {
      guard let index = settings.accounts.firstIndex(where: { $0.id == accountID }) else { continue }
      let stored = settings.accounts[index].credentials[CredentialField.anthropicAccessToken] ?? ""
      let isClaudeCodeToken = stored.isEmpty || stored.hasPrefix("sk-ant-oat")
      if isClaudeCodeToken, stored != liveToken {
        settings.accounts[index].credentials[CredentialField.anthropicAccessToken] = liveToken
        didChange = true
      }
    }

    if didChange {
      try? saveConfiguration()
    }
  }

  // MARK: - Internals

  private func runtimeConfigurations() -> [ProviderRuntimeConfiguration] {
    settings.accounts.map { account in
      ProviderRuntimeConfiguration(
        accountID: account.id,
        provider: account.provider,
        displayName: account.resolvedDisplayName,
        isEnabled: account.isEnabled,
        credentials: account.credentials
      )
    }
  }

  private func normalizeAndSave() {
    // Rebuild through the AppSettings initializer so account-dependent normalization
    // (providerStyleSettings, tile slots, duplicate IDs) stays in one place.
    settings = AppSettings(
      refreshIntervalMinutes: settings.refreshIntervalMinutes,
      accounts: settings.accounts,
      widgetStyle: settings.widgetStyle,
      widgetBackgroundSettings: settings.widgetBackgroundSettings,
      providerStyleSettings: settings.providerStyleSettings,
      widgetVisibility: settings.widgetVisibility,
      providerTileSlots: settings.providerTileSlots
    )
    do {
      try saveConfiguration()
    } catch {
      statusMessage = "Save failed: \(error.localizedDescription)"
      log("[llimitd] \(statusMessage)")
    }
  }

  private func reconcileSnapshotWithCurrentAccounts() {
    guard let currentSnapshot = snapshot else { return }

    let activeAccounts = settings.accounts.filter { $0.isEnabled && $0.hasRequiredCredentials }
    let reconciled = currentSnapshot.reconciled(with: activeAccounts)
    guard reconciled != currentSnapshot else { return }

    snapshot = reconciled
    do {
      try snapshotStore.save(reconciled)
    } catch {
      log("[llimitd] Snapshot reconciliation save failed: \(error.localizedDescription)")
    }
  }

  private func purgeHistory(for account: ProviderAccount) {
    var accountIDs: Set<String> = [account.id]
    if !settings.accounts.contains(where: { $0.provider == account.provider }) {
      accountIDs.insert(account.provider.rawValue)
    }

    do {
      try historyStore.remove(accountIDs: accountIDs)
    } catch {
      log("[llimitd] History purge failed: \(error.localizedDescription)")
    }
  }

  private func nextDisplayName(for provider: QuotaProvider) -> String {
    let existingNames = Set(
      settings.accounts
        .filter { $0.provider == provider }
        .map { $0.resolvedDisplayName.lowercased() }
    )
    let baseName = provider.displayName
    if !existingNames.contains(baseName.lowercased()) {
      return baseName
    }

    var suffix = 2
    while existingNames.contains("\(baseName) \(suffix)".lowercased()) {
      suffix += 1
    }
    return "\(baseName) \(suffix)"
  }

  private func autoRefreshIntervalNanoseconds() -> UInt64 {
    let clampedMinutes = min(
      max(settings.refreshIntervalMinutes, AppSettings.refreshIntervalRange.lowerBound),
      AppSettings.refreshIntervalRange.upperBound
    )
    return UInt64(clampedMinutes * 60) * 1_000_000_000
  }

  private func shouldRefreshOnBootstrap(now: Date = Date()) -> Bool {
    guard !settings.accounts.isEmpty else {
      return false
    }

    guard let snapshot else {
      return true
    }

    let clampedMinutes = min(
      max(settings.refreshIntervalMinutes, AppSettings.refreshIntervalRange.lowerBound),
      AppSettings.refreshIntervalRange.upperBound
    )
    return now.timeIntervalSince(snapshot.generatedAt) >= TimeInterval(clampedMinutes * 60)
  }
}

public enum DaemonError: LocalizedError, Sendable {
  case unknownAccount(String)
  case settingsFileUnreadable

  public var errorDescription: String? {
    switch self {
    case .unknownAccount(let id):
      return "No account with ID \(id)."
    case .settingsFileUnreadable:
      return "Save blocked because the existing settings file could not be read. Fix or remove the file, then retry."
    }
  }
}
