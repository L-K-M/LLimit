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
///  - Claude accounts use their saved credentials; the current CLI login must never
///    replace another account's token;
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
  /// Called after each refresh saves its snapshot, with the snapshot it
  /// replaced. Runs on the refresh loop, so it must return promptly (the alert
  /// monitor hands its child processes to a background queue).
  public var onSnapshotSaved: ((_ previous: QuotaSnapshot?, _ current: QuotaSnapshot) -> Void)?

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
  public private(set) var settingsLoadError: SettingsLoadError?
  private var loggedSettingsLoadError: SettingsLoadError?
  private var configurationLoadFailed: Bool { settingsLoadError != nil }
  fileprivate private(set) var editingID: UUID?
  /// The settings as they were on disk when last loaded (or last merged). The basis
  /// for the three-way merge in `mergeAndSaveSettings()`: during a refresh the
  /// daemon only ever changes `credentials` of existing accounts, and the merge
  /// replays exactly those changes onto a freshly read file.
  private var settingsBase: AppSettings = .default
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

  public enum ConfigurationAccess {
    case inspect
    case owner
  }

  /// Loads settings and the last snapshot from disk. A missing settings file yields
  /// defaults; an unreadable one blocks saving (see `configurationLoadFailed`).
  public func loadConfiguration(access: ConfigurationAccess = .owner) {
    do {
      settings = try settingsStore.load()
      settingsBase = settings
      settingsLoadError = nil
      loggedSettingsLoadError = nil
    } catch {
      settings = .default
      settingsLoadError = SettingsLoadError(fileURL: paths.settingsFileURL, error: error)
      statusMessage = settingsLoadError?.localizedDescription ?? "Could not load settings"
    }

    do {
      let policy: StoreReadPolicy = access == .owner ? .recover : .preserve
      snapshot = try snapshotStore.load(policy: policy)
      if access == .owner { reconcileSnapshotWithCurrentAccounts() }
    } catch {
      statusMessage = "Could not load snapshot: \(error.localizedDescription)"
    }
  }

  /// Persists the current settings. The settings file is the ONLY credential-bearing
  /// file; snapshot/history/status output never contain credentials by construction
  /// (the snapshot is built from ProviderUsage/ProviderFailure, which have no
  /// credential fields).
  ///
  /// Callers must hold the settings lock and have loaded inside it (the CLI
  /// mutation paths do both). The daemon's refresh cycle instead uses
  /// `mergeAndSaveSettings()`, which acquires the lock itself.
  func saveConfiguration() throws {
    if let settingsLoadError { throw settingsLoadError }
    try settingsStore.save(settings)
    settingsBase = settings
  }

  /// Persists credential changes made during a refresh (token adoption/rotation)
  /// WITHOUT clobbering a concurrent CLI edit. Re-reads the file under the settings
  /// lock and three-way merges: the credential set is replaced only when it still
  /// matches what the daemon loaded. Tokens from two logins must never be spliced.
  /// Accounts added/removed/enabled by the CLI mid-refresh survive,
  /// because everything except the daemon's own credential deltas comes from disk.
  func mergeAndSaveSettings() throws {
    if let settingsLoadError { throw settingsLoadError }
    try settingsLock.withLock {
      let onDisk = try settingsStore.load()
      let merged = Self.mergingCredentialChanges(base: settingsBase, current: settings, onto: onDisk)
      try settingsStore.save(merged)
      settings = merged
      settingsBase = merged
    }
  }

  /// The merge behind `mergeAndSaveSettings`, pure for testability: replays the
  /// credential changes between `base` and `current` onto `disk`. A login the CLI
  /// changed concurrently keeps the CLI's complete credential set: an
  /// explicit edit beats an automatic token refresh; the next cycle re-reads live
  /// tokens anyway. Accounts the CLI removed stay removed; accounts it added are
  /// untouched (the daemon never adds accounts during a refresh).
  static func mergingCredentialChanges(base: AppSettings, current: AppSettings, onto disk: AppSettings) -> AppSettings {
    var result = disk
    let baseByID = Dictionary(base.accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for currentAccount in current.accounts {
      guard
        let baseAccount = baseByID[currentAccount.id],
        baseAccount.credentials != currentAccount.credentials,
        let diskIndex = result.accounts.firstIndex(where: { $0.id == currentAccount.id }),
        result.accounts[diskIndex].provider == currentAccount.provider,
        result.accounts[diskIndex].credentials == baseAccount.credentials
      else { continue }

      result.accounts[diskIndex].credentials = currentAccount.credentials
    }
    return result
  }

  // MARK: - Accounts (the Settings → Accounts surface, as plain mutations)

  /// Account edits reload under the lock and save before returning. Prompts and
  /// discovery run before entering this boundary, so they cannot stall a refresh.
  public func editingSettings<T>(_ edit: (SettingsTransaction) throws -> T) throws -> T {
    precondition(editingID == nil, "editingSettings must not be nested")
    return try settingsLock.withLock {
      loadConfiguration()
      if let settingsLoadError { throw settingsLoadError }
      let id = UUID()
      editingID = id
      defer { editingID = nil }
      do {
        return try edit(SettingsTransaction(daemon: self, id: id))
      } catch {
        // Keep memory aligned with the last durable edit after a failed save.
        settings = settingsBase
        throw error
      }
    }
  }

  @discardableResult
  func addAccount(
    provider: QuotaProvider,
    displayName: String? = nil,
    credentials: [String: String] = [:]
  ) throws -> ProviderAccount {
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
    try normalizeAndSave()
    return account
  }

  /// Creates a new LLimit-owned account pre-filled with a detected credential.
  @discardableResult
  func importAccount(from detected: DiscoveredCredential) throws -> ProviderAccount {
    let name = detected.suggestedName.trimmingCharacters(in: .whitespacesAndNewlines)
    return try addAccount(
      provider: detected.provider,
      displayName: name.isEmpty ? nextDisplayName(for: detected.provider) : name,
      credentials: detected.credentials
    )
  }

  /// Keep identity, style and history while replacing the login or display name.
  @discardableResult
  func updateAccount(
    _ accountID: String, displayName: String? = nil, credentials change: CredentialChange = .unchanged
  ) throws -> ProviderAccount {
    guard let index = settings.accounts.firstIndex(where: { $0.id == accountID }) else {
      throw DaemonError.unknownAccount(accountID)
    }
    let previous = settings.accounts[index]
    var updated = previous
    if let displayName {
      let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { throw DaemonError.blankDisplayName }
      updated.displayName = name
    }
    updated.credentials = try Self.credentials(of: previous, applying: change)
    guard updated != previous else { return previous }

    if updated.credentials != previous.credentials {
      guard !CodexAccountProfile.isManaged(previous.credentials) else {
        throw DaemonError.managedCredentials(previous.resolvedDisplayName)
      }
      // Old usage belongs to the old login, including Venice's estimated allowance.
      // Clear before saving the new login so a failed snapshot save cannot pair them.
      try discardSnapshotEntry(for: accountID)
    }
    settings.accounts[index] = updated
    try normalizeAndSave()
    reconcileSnapshotWithCurrentAccounts()
    return settings.account(withID: accountID) ?? updated
  }

  func reimportAccount(
    _ accountID: String, from stableID: String? = nil, among detected: [DiscoveredCredential]
  ) throws -> (login: DiscoveredCredential, changed: Bool) {
    guard let account = settings.account(withID: accountID) else { throw DaemonError.unknownAccount(accountID) }
    let logins = detected.filter { $0.provider == account.provider }
    let login: DiscoveredCredential
    if let stableID {
      guard let match = logins.first(where: { $0.stableID == stableID }) else {
        throw DaemonError.detectedLoginNotFound(stableID, available: logins.map(\.stableID))
      }
      login = match
    } else {
      guard let only = logins.first else { throw DaemonError.noDetectedLogin(account.provider) }
      guard logins.count == 1 else {
        throw DaemonError.ambiguousDetectedLogin(account.provider, stableIDs: logins.map(\.stableID))
      }
      login = only
    }
    let updated = try updateAccount(accountID, credentials: .replacing(with: login.credentials))
    return (login, updated != account)
  }

  func setAccountEnabled(_ accountID: String, _ enabled: Bool) throws {
    guard let index = settings.accounts.firstIndex(where: { $0.id == accountID }) else {
      throw DaemonError.unknownAccount(accountID)
    }
    settings.accounts[index].isEnabled = enabled
    try normalizeAndSave()
    reconcileSnapshotWithCurrentAccounts()
  }

  func removeAccount(_ accountID: String) throws {
    guard let removed = settings.accounts.first(where: { $0.id == accountID }) else {
      throw DaemonError.unknownAccount(accountID)
    }
    settings.accounts.removeAll { $0.id == accountID }
    settings.providerTileSlots = settings.providerTileSlots.map { $0 == accountID ? "" : $0 }
    try normalizeAndSave()
    reconcileSnapshotWithCurrentAccounts()
    purgeHistory(for: removed)
  }

  /// Resolves a full account ID or a unique prefix (so the CLI can take short IDs).
  public func resolveAccountID(_ fragment: String) throws -> String {
    let wanted = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !wanted.isEmpty else { throw DaemonError.blankAccountID }
    if settings.accounts.contains(where: { $0.id == wanted }) {
      return wanted
    }
    let matches = settings.accounts.filter { $0.id.lowercased().hasPrefix(wanted.lowercased()) }
    guard matches.count <= 1 else {
      throw DaemonError.ambiguousAccount(wanted, candidates: matches.map { "\($0.id) (\($0.resolvedDisplayName))" })
    }
    guard let match = matches.first else { throw DaemonError.unknownAccount(wanted) }
    return match.id
  }

  /// True when an existing account already holds the same token for this provider,
  /// so the CLI can say "already imported" instead of offering a duplicate.
  public func isDetectedCredentialImported(_ detected: DiscoveredCredential) -> Bool {
    account(holding: detected) != nil
  }

  public func importMatch(for detected: DiscoveredCredential, among scan: [DiscoveredCredential] = []) -> ImportMatch {
    if let holder = account(holding: detected) { return .alreadyImported(accountID: holder.id) }
    let otherLogins = scan.filter { $0.provider == detected.provider && $0.stableID != detected.stableID }
    let candidates = settings.accounts.filter { account in
      account.provider == detected.provider && !CodexAccountProfile.isManaged(account.credentials)
        && !otherLogins.contains { Self.sharesPrimarySecret(account.credentials, $0.credentials, provider: account.provider) }
    }
    return candidates.isEmpty ? .newAccount : .updateCandidates(accountIDs: candidates.map(\.id))
  }

  public static func editableCredentialKeys(of account: ProviderAccount) -> Set<String> {
    Set(account.provider.credentialFields.map(\.key)).union(account.credentials.keys)
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
  ///
  /// Locking: callers must have loaded settings first (`refreshCycle` does, under
  /// the lock). The cycle itself runs UNLOCKED so a fetch never blocks a CLI edit;
  /// settings writes (token adoption/rotation) go through `mergeAndSaveSettings()`,
  /// which re-reads the file under the lock and merges instead of overwriting.
  public func refreshNow() async {
    if let settingsLoadError {
      reportSettingsLoadError(settingsLoadError)
      return
    }
    let openAITokensChanged = await refreshExpiringChatGPTTokens()
    if openAITokensChanged {
      // Persist promptly: OpenAI rotates refresh tokens, so the stored grant is
      // dead the moment a refresh succeeds — losing this save can orphan the
      // account on machines without a live Codex file to re-adopt from.
      do {
        try mergeAndSaveSettings()
      } catch {
        log("[llimitd] Settings save failed: \(error.localizedDescription)")
      }
    }

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
    let previous = (try? snapshotStore.load(policy: .recover)) ?? snapshot
    var fetchedConfigurations = enabledConfigs
    var refreshed = await coordinator.refresh(configurations: enabledConfigs, previousSnapshot: previous)
      .mergingStaleUsage(from: previous)
    if Task.isCancelled && refreshed.providers.isEmpty && refreshed.failures.isEmpty { return }

    // Validate before reactive recovery too: an old auth failure must not renew
    // a login the user replaced while the request was in flight.
    do {
      refreshed = try settingsLock.withLock {
        let latest = try loadLatestSettings()
        let validated = validatedResults(refreshed, configurations: fetchedConfigurations, settings: latest)
        settings = latest
        settingsBase = latest
        return validated
      }
    } catch {
      log("[llimitd] Refresh validation failed: \(error.localizedDescription)")
      return
    }

    // Reactive recovery: if an enabled OpenAI account failed authentication (a token
    // revoked before its JWT exp, or a Codex rotation that landed mid-cycle), refresh
    // its token and retry — only the accounts we actually recovered, so healthy accounts
    // and the other providers aren't re-polled (Anthropic hard-rate-limits repeat pollers).
    let recoveredIDs = await recoverFailedOpenAITokens(in: refreshed)
    if !recoveredIDs.isEmpty {
      do {
        try mergeAndSaveSettings()
      } catch {
        log("[llimitd] Settings save failed: \(error.localizedDescription)")
      }
      let retryConfigs = runtimeConfigurations().filter { configuration in
        recoveredIDs.contains(configuration.accountID)
          && configuration.isEnabled
          && configuration.provider.hasRequiredCredentials(configuration.credentials)
      }
      if !retryConfigs.isEmpty {
        let retriedIDs = Set(retryConfigs.map(\.accountID))
        let retrySnapshot = await coordinator.refresh(configurations: retryConfigs, previousSnapshot: refreshed)
          .mergingStaleUsage(from: refreshed)
        refreshed = refreshed.replacingResults(forAccountIDs: retriedIDs, from: retrySnapshot)
        fetchedConfigurations.removeAll { retriedIDs.contains($0.accountID) }
        fetchedConfigurations += retryConfigs
      }
    }

    do {
      // The lock covers validation and publication, never the network fetch.
      // Otherwise an edit between validation and save could resurrect old data.
      try settingsLock.withLock {
        let latest = try loadLatestSettings()
        refreshed = validatedResults(refreshed, configurations: fetchedConfigurations, settings: latest)
        refreshed.refreshIntervalMinutes = latest.refreshIntervalMinutes

        // Archive only finally validated observations, then reuse that evidence
        // for pace. An earlier append could revive a login replaced during recovery.
        let archive: QuotaHistoryStore.Archive?
        do {
          archive = try historyStore.append(refreshed)
        } catch {
          log("[llimitd] History append failed: \(error.localizedDescription)")
          archive = nil
        }
        refreshed = refreshed.applyingPaceEstimates(from: archive?.snapshots ?? [],
          accounts: latest.accounts, now: Date(), refreshInterval: TimeInterval(latest.refreshIntervalMinutes * 60))
        try snapshotStore.save(refreshed)
        settings = latest
        settingsBase = latest
      }
    } catch {
      statusMessage = "Snapshot save failed: \(error.localizedDescription)"
      log("[llimitd] \(statusMessage)")
      return
    }

    snapshot = refreshed
    onSnapshotSaved?(previous, refreshed)
    statusMessage = "Refreshed \(refreshed.providers.count) account(s), \(refreshed.failures.count) failure(s)"
    log("[llimitd] \(statusMessage)")
  }

  /// The daemon's main loop. Settings are re-loaded each cycle: on Linux account
  /// management is a separate `llimit` process, so the daemon must pick up its edits
  /// (unlike the macOS app, which is the sole writer of its own settings). Only the
  /// load holds the settings lock; the fetch runs unlocked and settings writes
  /// merge under the lock (see `mergeAndSaveSettings()`), so neither the daemon nor
  /// a CLI edit can block or overwrite the other.
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

  /// One load → refresh cycle. Only the load holds the settings lock: the daemon
  /// writes settings during token refresh, and holding the lock across the network
  /// fetch would stall a concurrent `llimit accounts …` for the whole cycle.
  /// Settings writes inside the refresh go through `mergeAndSaveSettings()`.
  func refreshCycle(bootstrap: Bool) async {
    do {
      try settingsLock.withLock {
        loadConfiguration()
      }
    } catch {
      statusMessage = "Settings lock failed: \(error.localizedDescription)"
      log("[llimitd] \(statusMessage)")
      return
    }

    if let settingsLoadError {
      reportSettingsLoadError(settingsLoadError)
      return
    }

    if bootstrap && !shouldRefreshOnBootstrap() {
      return
    }

    await refreshNow()
  }

  // MARK: - Token hygiene (ported from AppModel)

  /// ChatGPT tokens expire hourly, and OpenAI rotates refresh tokens — LLimit's
  /// imported copy dies as soon as the Codex CLI refreshes (and vice-versa). Adopt
  /// Codex's current on-disk token (matched by ChatGPT account id) and refresh
  /// anything still expired, so the two stay in sync instead of fighting the grant.
  /// Returns whether any credentials changed (in memory; the caller saves via
  /// `mergeAndSaveSettings()`).
  private func refreshExpiringChatGPTTokens() async -> Bool {
    // Only enabled accounts: refreshing a disabled account would keep rotating the
    // shared Codex refresh token and log the user's Codex CLI out.
    let openAIAccountIDs = settings.accounts.filter { $0.provider == .openAI && $0.isEnabled && !CodexAccountProfile.isManaged($0.credentials) }.map(\.id)
    guard !openAIAccountIDs.isEmpty else { return false }

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

    return didChange
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
    guard let previous = settings.accounts.first(where: { $0.id == accountID })?.credentials,
          !CodexAccountProfile.isManaged(previous) else { return false }
    do {
      let result = try await ChatGPTOAuth.refresh(refreshToken: refreshToken)
      guard let index = settings.accounts.firstIndex(where: { $0.id == accountID }),
            settings.accounts[index].credentials == previous else { return false }
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
  /// retry exactly those accounts (and save via `mergeAndSaveSettings()`).
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
        settings.accounts[index].isEnabled,
        !CodexAccountProfile.isManaged(settings.accounts[index].credentials)
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

    return recovered
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

  private func normalizeAndSave() throws {
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
    try saveConfiguration()
  }

  private func loadLatestSettings() throws -> AppSettings {
    do { return try settingsStore.load() }
    catch { throw SettingsLoadError(fileURL: paths.settingsFileURL, error: error) }
  }

  private func validatedResults(
    _ result: QuotaSnapshot, configurations: [ProviderRuntimeConfiguration], settings latest: AppSettings
  ) -> QuotaSnapshot {
    let valid = latest.accounts.filter { account in
      account.isEnabled && account.hasRequiredCredentials && configurations.contains {
        $0.accountID == account.id && $0.provider == account.provider && $0.credentials == account.credentials
      }
    }
    return result.reconciled(with: valid)
  }

  private static func credentials(of account: ProviderAccount, applying change: CredentialChange) throws -> [String: String] {
    switch change {
    case .unchanged: return account.credentials
    case .replacing(let values):
      let blank = Dictionary(uniqueKeysWithValues: account.provider.credentialFields.map { ($0.key, "") })
      return blank.merging(values) { _, new in new }
    case .merging(let values):
      let editable = editableCredentialKeys(of: account)
      if let unknown = values.keys.sorted().first(where: { !editable.contains($0) }) {
        throw DaemonError.unknownCredentialKey(unknown, provider: account.provider)
      }
      var result = account.credentials
      let tokenKey = CredentialField.anthropicAccessToken
      if account.provider == .anthropic, let token = values[tokenKey], token != result[tokenKey] {
        result = ClaudeCodeProfile.clearManagedMetadata(from: result)
      }
      return result.merging(values) { _, new in new }
    }
  }

  private func account(holding detected: DiscoveredCredential) -> ProviderAccount? {
    settings.accounts.first {
      $0.provider == detected.provider && !CodexAccountProfile.isManaged($0.credentials)
        && Self.sharesPrimarySecret($0.credentials, detected.credentials, provider: detected.provider)
    }
  }

  private static func sharesPrimarySecret(_ lhs: [String: String], _ rhs: [String: String], provider: QuotaProvider) -> Bool {
    provider.credentialFields.contains { field in
      guard field.isSecret, let value = lhs[field.key], !value.isEmpty else { return false }
      return rhs[field.key] == value
    }
  }

  private func discardSnapshotEntry(for accountID: String) throws {
    guard var current = (try? snapshotStore.load()) ?? snapshot else { return }
    current.providers.removeAll { $0.accountID == accountID }
    current.failures.removeAll { $0.accountID == accountID }
    try snapshotStore.save(current)
    snapshot = current
  }

  private func reconcileSnapshotWithCurrentAccounts() {
    guard !configurationLoadFailed, let currentSnapshot = snapshot else { return }

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

  private func reportSettingsLoadError(_ error: SettingsLoadError) {
    statusMessage = error.localizedDescription
    guard error != loggedSettingsLoadError else { return }
    loggedSettingsLoadError = error
    log("[llimitd] \(statusMessage)")
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

/// A handle is valid only for the particular transaction that created it.
public struct SettingsTransaction {
  private let daemon: QuotaDaemon
  private let id: UUID

  fileprivate init(daemon: QuotaDaemon, id: UUID) {
    self.daemon = daemon
    self.id = id
  }

  private var editing: QuotaDaemon {
    precondition(daemon.editingID == id, "SettingsTransaction used outside its transaction")
    return daemon
  }

  @discardableResult
  public func addAccount(provider: QuotaProvider, displayName: String? = nil, credentials: [String: String] = [:]) throws -> ProviderAccount {
    try editing.addAccount(provider: provider, displayName: displayName, credentials: credentials)
  }

  @discardableResult
  public func importAccount(from detected: DiscoveredCredential) throws -> ProviderAccount {
    try editing.importAccount(from: detected)
  }

  @discardableResult
  public func updateAccount(_ accountID: String, displayName: String? = nil, credentials: CredentialChange = .unchanged) throws -> ProviderAccount {
    try editing.updateAccount(accountID, displayName: displayName, credentials: credentials)
  }

  public func reimportAccount(_ accountID: String, from stableID: String? = nil, among detected: [DiscoveredCredential]) throws -> (login: DiscoveredCredential, changed: Bool) {
    try editing.reimportAccount(accountID, from: stableID, among: detected)
  }

  public func setAccountEnabled(_ accountID: String, _ enabled: Bool) throws {
    try editing.setAccountEnabled(accountID, enabled)
  }

  public func removeAccount(_ accountID: String) throws {
    try editing.removeAccount(accountID)
  }
}

public enum CredentialChange: Equatable, Sendable {
  case unchanged
  case merging([String: String])
  case replacing(with: [String: String])
}

public enum ImportMatch: Equatable, Sendable {
  case alreadyImported(accountID: String)
  case newAccount
  case updateCandidates(accountIDs: [String])
}

public enum DaemonError: LocalizedError, Equatable, Sendable {
  case unknownAccount(String)
  case blankAccountID
  case ambiguousAccount(String, candidates: [String])
  case blankDisplayName
  case unknownCredentialKey(String, provider: QuotaProvider)
  case managedCredentials(String)
  case noDetectedLogin(QuotaProvider)
  case detectedLoginNotFound(String, available: [String])
  case ambiguousDetectedLogin(QuotaProvider, stableIDs: [String])

  public var errorDescription: String? {
    switch self {
    case .unknownAccount(let id):
      return "No account matches \"\(id)\". Run `llimit accounts list` to see IDs."
    case .blankAccountID: return "The account ID is empty."
    case .ambiguousAccount(let fragment, let candidates):
      return "\"\(fragment)\" matches several accounts: \(candidates.joined(separator: ", ")). Type more of the ID."
    case .blankDisplayName: return "The account name is empty."
    case .unknownCredentialKey(let key, let provider):
      return "\"\(key)\" is not a \(provider.displayName) credential. Use: \(provider.credentialFields.map(\.key).joined(separator: ", "))."
    case .managedCredentials(let name):
      return "\(name) uses its own Codex profile. Reconnect it in the macOS app or add a separate account."
    case .noDetectedLogin(let provider): return "No \(provider.displayName) login detected. Sign in or use `llimit accounts update`."
    case .detectedLoginNotFound(let stableID, let available):
      return "No detected login has ID \(stableID). Available: \(available.joined(separator: ", "))."
    case .ambiguousDetectedLogin(let provider, let stableIDs):
      return "Several \(provider.displayName) logins detected: \(stableIDs.joined(separator: ", ")). Choose --from <stable-id>."
    }
  }
}
