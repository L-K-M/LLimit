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
  /// Why the settings file could not be loaded, or nil when it loaded (a missing
  /// file loads as defaults). While set, the in-memory settings are the empty
  /// fallback, so nothing may be saved over the file (it may hold credentials),
  /// reconciled against it, or refreshed from it.
  public private(set) var settingsLoadError: SettingsLoadError?
  /// The settings error last written to the log. The daemon re-loads every cycle,
  /// and repeating the same line each interval would bury it.
  private var loggedSettingsLoadError: SettingsLoadError?
  private var configurationLoadFailed: Bool { settingsLoadError != nil }
  /// True while `editingSettings` runs its edit; a `SettingsTransaction` is only
  /// usable then.
  fileprivate private(set) var isEditing = false
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

  /// Loads settings and the last snapshot from disk. A missing settings file yields
  /// defaults; an unreadable one sets `settingsLoadError`, which blocks saving and
  /// keeps the snapshot as it is. Never logs: `llimit status --json` loads through
  /// here and its stdout belongs to the bar.
  public func loadConfiguration() {
    do {
      settings = try settingsStore.load()
      settingsBase = settings
      settingsLoadError = nil
      loggedSettingsLoadError = nil
    } catch {
      settings = .default
      let failure = SettingsLoadError(fileURL: paths.settingsFileURL, error: error)
      settingsLoadError = failure
      statusMessage = failure.localizedDescription
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
  ///
  /// Callers must hold the settings lock and have loaded inside it (the CLI
  /// mutation paths do both). The daemon's refresh cycle instead uses
  /// `mergeAndSaveSettings()`, which acquires the lock itself.
  func saveConfiguration() throws {
    if let settingsLoadError {
      throw settingsLoadError
    }
    try settingsStore.save(settings)
    settingsBase = settings
  }

  /// Persists credential changes made during a refresh (token adoption/rotation)
  /// WITHOUT clobbering a concurrent CLI edit. Re-reads the file under the settings
  /// lock and three-way merges: a credential key is overwritten only when the
  /// on-disk value still matches what the daemon loaded — i.e. the CLI didn't touch
  /// that key. Accounts added/removed/enabled by the CLI mid-refresh survive,
  /// because everything except the daemon's own credential deltas comes from disk.
  func mergeAndSaveSettings() throws {
    if let settingsLoadError {
      throw settingsLoadError
    }
    try settingsLock.withLock {
      let onDisk = try settingsStore.load()
      let merged = Self.mergingCredentialChanges(base: settingsBase, current: settings, onto: onDisk)
      try settingsStore.save(merged)
      settings = merged
      settingsBase = merged
    }
  }

  /// The merge behind `mergeAndSaveSettings`, pure for testability: replays the
  /// credential changes between `base` and `current` onto `disk`. A key the CLI
  /// changed concurrently (disk value ≠ base value) keeps the CLI's value — an
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
        let diskIndex = result.accounts.firstIndex(where: { $0.id == currentAccount.id })
      else { continue }

      var credentials = result.accounts[diskIndex].credentials
      for (key, currentValue) in currentAccount.credentials {
        let baseValue = baseAccount.credentials[key]
        guard currentValue != baseValue else { continue } // the daemon changed this key
        if credentials[key] == baseValue {
          credentials[key] = currentValue
        }
      }
      result.accounts[diskIndex].credentials = credentials
    }
    return result
  }

  // MARK: - Accounts (the Settings → Accounts surface, as plain mutations)

  /// Runs one account edit as a transaction: holds the settings lock, re-loads the
  /// file inside it (the daemon may have saved rotated tokens since this process
  /// loaded), and refuses to edit the empty fallback of an unreadable file. Other
  /// modules can reach the mutations below only through the `SettingsTransaction`
  /// passed to `edit`; each one saves before returning and throws when the save
  /// fails.
  ///
  /// Do not nest transactions. The flock is not recursive, so an inner one would
  /// wait for the outer one forever; nesting stops with a precondition failure
  /// instead.
  public func editingSettings<T>(_ edit: (SettingsTransaction) throws -> T) throws -> T {
    precondition(!isEditing, "editingSettings must not be nested")
    return try settingsLock.withLock {
      loadConfiguration()
      if let settingsLoadError {
        throw settingsLoadError
      }

      isEditing = true
      defer { isEditing = false }
      return try edit(SettingsTransaction(daemon: self))
    }
  }

  // The mutations below are internal: callers in other modules go through
  // `SettingsTransaction`, which runs them under the lock. Tests call them
  // directly against settings they loaded themselves.

  @discardableResult
  func addAccount(
    provider: QuotaProvider,
    displayName: String? = nil,
    credentials: [String: String] = [:]
  ) throws -> ProviderAccount {
    let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let account = ProviderAccount(
      provider: provider,
      displayName: (name?.isEmpty == false) ? name : nextDisplayName(for: provider),
      isEnabled: true,
      credentials: Self.blankCredentials(for: provider).merging(credentials) { _, new in new }
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

  /// Changes an account in place, keeping its id, history and style. A new name is
  /// trimmed and must not be blank. When the credentials change, derived state
  /// that belongs to the old login is cleared: managed Claude metadata when the
  /// token changes, and a Venice account's DIEM estimate when the key changes.
  @discardableResult
  func updateAccount(
    _ accountID: String,
    displayName: String? = nil,
    credentials change: CredentialChange = .unchanged
  ) throws -> ProviderAccount {
    guard let index = settings.accounts.firstIndex(where: { $0.id == accountID }) else {
      throw DaemonError.unknownAccount(accountID)
    }

    let previous = settings.accounts[index]
    var updated = previous
    if let displayName {
      let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else {
        throw DaemonError.blankDisplayName
      }
      updated.displayName = name
    }
    updated.credentials = try Self.credentials(of: previous, applying: change)
    guard updated != previous else { return previous }

    if updated.credentials != previous.credentials {
      // Codex owns a managed account's sign-in in its private profile; LLimit
      // must never put another login's tokens into it.
      guard !CodexAccountProfile.isManaged(previous.credentials) else {
        throw DaemonError.managedCredentials(previous.resolvedDisplayName)
      }
      if previous.provider == .venice,
         previous.credentials[CredentialField.veniceAPIKey] != updated.credentials[CredentialField.veniceAPIKey] {
        // The estimate was observed under the old key. Clear it durably before
        // the new key is saved, so a failure cannot pair the two.
        try discardSnapshotEntry(for: accountID)
      }
    }

    settings.accounts[index] = updated
    try normalizeAndSave()
    reconcileSnapshotWithCurrentAccounts()
    return settings.account(withID: accountID) ?? updated
  }

  /// Replaces an account's credentials with the login detected on this machine for
  /// its provider (`llimit accounts reimport`), keeping its id, name, history and
  /// style. `detected` is a scan taken before the transaction, so no files are
  /// read while the lock is held; `stableID` picks one login when it holds
  /// several for the provider. Returns the login used and whether the account
  /// changed.
  func reimportAccount(
    _ accountID: String,
    from stableID: String? = nil,
    among detected: [DiscoveredCredential]
  ) throws -> (login: DiscoveredCredential, changed: Bool) {
    guard let account = settings.account(withID: accountID) else {
      throw DaemonError.unknownAccount(accountID)
    }

    let logins = detected.filter { $0.provider == account.provider }
    let login: DiscoveredCredential
    if let stableID {
      guard let match = logins.first(where: { $0.stableID == stableID }) else {
        throw DaemonError.detectedLoginNotFound(stableID, available: logins.map(\.stableID))
      }
      login = match
    } else {
      guard let only = logins.first else {
        throw DaemonError.noDetectedLogin(account.provider)
      }
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
    // Save first: if it fails the account still exists, so its snapshot entry
    // and history must too.
    try normalizeAndSave()
    reconcileSnapshotWithCurrentAccounts()
    purgeHistory(for: removed)
  }

  /// Resolves a full account ID or a unique prefix, ignoring case (so the CLI can
  /// take short IDs). A blank fragment is rejected: every ID has the empty prefix,
  /// so a quoted unset shell variable would otherwise pick an account.
  public func resolveAccountID(_ fragment: String) throws -> String {
    let wanted = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !wanted.isEmpty else {
      throw DaemonError.blankAccountID
    }
    if settings.accounts.contains(where: { $0.id == wanted }) {
      return wanted
    }

    let matches = settings.accounts.filter { $0.id.lowercased().hasPrefix(wanted.lowercased()) }
    guard matches.count <= 1 else {
      throw DaemonError.ambiguousAccount(wanted, candidates: matches.map { "\($0.id) (\($0.resolvedDisplayName))" })
    }
    guard let match = matches.first else {
      throw DaemonError.unknownAccount(wanted)
    }
    return match.id
  }

  /// True when an existing account already holds this login, so the CLI can say
  /// "already imported" instead of offering a duplicate.
  public func isDetectedCredentialImported(_ detected: DiscoveredCredential) -> Bool {
    account(holding: detected) != nil
  }

  /// Decides whether importing `detected` adds an account or should offer to update
  /// one in place. `scan` is everything the same scan detected: an account that
  /// holds another of those logins is accounted for and is not offered.
  public func importMatch(for detected: DiscoveredCredential, among scan: [DiscoveredCredential] = []) -> ImportMatch {
    if let holder = account(holding: detected) {
      return .alreadyImported(accountID: holder.id)
    }

    let otherLogins = scan.filter { $0.provider == detected.provider && $0.stableID != detected.stableID }
    let candidates = settings.accounts.filter { account in
      account.provider == detected.provider
        && !CodexAccountProfile.isManaged(account.credentials)
        && !otherLogins.contains { Self.sharesPrimarySecret(account.credentials, $0.credentials, provider: account.provider) }
    }
    return candidates.isEmpty ? .newAccount : .updateCandidates(accountIDs: candidates.map(\.id))
  }

  /// The keys `update --set` may change: the provider's form fields, plus hidden
  /// keys the account already stores (an imported refresh token, say) so they can
  /// be replaced or cleared. Any other key is most likely a typo.
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
      // The fallback settings have no accounts; fetching would only report
      // "no accounts configured" and point away from the broken file.
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
    let previous = (try? snapshotStore.load()) ?? snapshot
    var refreshed = await coordinator.refresh(configurations: enabledConfigs, previousSnapshot: previous)
      .mergingStaleUsage(from: previous)

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

  /// Every form field of the provider, empty, so a stored account lists them all.
  private static func blankCredentials(for provider: QuotaProvider) -> [String: String] {
    Dictionary(uniqueKeysWithValues: provider.credentialFields.map { ($0.key, "") })
  }

  private static func credentials(
    of account: ProviderAccount,
    applying change: CredentialChange
  ) throws -> [String: String] {
    switch change {
    case .unchanged:
      return account.credentials

    case .replacing(let values):
      return blankCredentials(for: account.provider).merging(values) { _, new in new }

    case .merging(let values):
      let editable = editableCredentialKeys(of: account)
      if let unknown = values.keys.sorted().first(where: { !editable.contains($0) }) {
        throw DaemonError.unknownCredentialKey(unknown, provider: account.provider)
      }

      var result = account.credentials
      let tokenKey = CredentialField.anthropicAccessToken
      if account.provider == .anthropic, let token = values[tokenKey], token != result[tokenKey] {
        // Managed metadata (profile, verified identity, expiry) describes the
        // old token's login; keeping it would let a later renewal undo the edit.
        result = ClaudeCodeProfile.clearManagedMetadata(from: result)
      }
      return result.merging(values) { _, new in new }
    }
  }

  /// The account of the login's provider that holds its primary secret, if any.
  private func account(holding detected: DiscoveredCredential) -> ProviderAccount? {
    settings.accounts.first { account in
      account.provider == detected.provider
        && Self.sharesPrimarySecret(account.credentials, detected.credentials, provider: detected.provider)
    }
  }

  /// Whether two credential sets hold the same login. Only primary secrets count:
  /// the secret fields of the provider's form (an access token or API key, or
  /// Copilot's OAuth token or PAT). Hidden companions such as refresh tokens and
  /// non-secret fields such as account ids can match across different logins.
  private static func sharesPrimarySecret(_ lhs: [String: String], _ rhs: [String: String], provider: QuotaProvider) -> Bool {
    provider.credentialFields.contains { field in
      guard field.isSecret, let value = lhs[field.key], !value.isEmpty else { return false }
      return rhs[field.key] == value
    }
  }

  /// Drops one account's usage and failure from the saved snapshot. An unreadable
  /// snapshot file falls back to the loaded copy, or to nothing to clear, so it
  /// cannot block a key change; snapshots hold no credentials, so replacing a
  /// corrupt one loses nothing that matters.
  private func discardSnapshotEntry(for accountID: String) throws {
    guard let current = (try? snapshotStore.load()) ?? snapshot else { return }

    let empty = QuotaSnapshot(generatedAt: current.generatedAt, providers: [], failures: [])
    let cleared = current.replacingResults(forAccountIDs: [accountID], from: empty)
    guard cleared != current else { return }

    try snapshotStore.save(cleared)
    snapshot = cleared
  }

  private func reconcileSnapshotWithCurrentAccounts() {
    // Without readable settings the account list is the empty fallback, and
    // reconciling against it would erase every saved result.
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

  /// Logs a settings load failure once per distinct problem; `statusMessage`
  /// always carries the current one.
  private func reportSettingsLoadError(_ error: SettingsLoadError) {
    statusMessage = error.localizedDescription
    guard error != loggedSettingsLoadError else { return }

    loggedSettingsLoadError = error
    log("[llimitd] \(statusMessage)")
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

/// The account edits of one `QuotaDaemon.editingSettings` transaction, the only
/// way other modules can change accounts: each edit runs under the settings lock
/// against a fresh load. Only `editingSettings` creates one, and it is usable only
/// until that call returns. Methods match the daemon's internal mutations.
public struct SettingsTransaction {
  private let daemon: QuotaDaemon

  fileprivate init(daemon: QuotaDaemon) {
    self.daemon = daemon
  }

  /// The daemon, checked to still be inside this transaction: a handle kept
  /// past `editingSettings` would edit without the lock.
  private var editing: QuotaDaemon {
    precondition(daemon.isEditing, "SettingsTransaction used outside editingSettings")
    return daemon
  }

  @discardableResult
  public func addAccount(
    provider: QuotaProvider,
    displayName: String? = nil,
    credentials: [String: String] = [:]
  ) throws -> ProviderAccount {
    try editing.addAccount(provider: provider, displayName: displayName, credentials: credentials)
  }

  @discardableResult
  public func importAccount(from detected: DiscoveredCredential) throws -> ProviderAccount {
    try editing.importAccount(from: detected)
  }

  @discardableResult
  public func updateAccount(
    _ accountID: String,
    displayName: String? = nil,
    credentials change: CredentialChange = .unchanged
  ) throws -> ProviderAccount {
    try editing.updateAccount(accountID, displayName: displayName, credentials: change)
  }

  public func reimportAccount(
    _ accountID: String,
    from stableID: String? = nil,
    among detected: [DiscoveredCredential]
  ) throws -> (login: DiscoveredCredential, changed: Bool) {
    try editing.reimportAccount(accountID, from: stableID, among: detected)
  }

  public func setAccountEnabled(_ accountID: String, _ enabled: Bool) throws {
    try editing.setAccountEnabled(accountID, enabled)
  }

  public func removeAccount(_ accountID: String) throws {
    try editing.removeAccount(accountID)
  }
}

/// How `QuotaDaemon.updateAccount` changes an account's credentials.
public enum CredentialChange: Equatable, Sendable {
  case unchanged
  /// Sets the given keys and keeps every other stored value (`update --set`).
  case merging([String: String])
  /// Replaces every stored value with a detected login (`reimport`), so values
  /// of the old login, such as its refresh token, cannot outlive it.
  case replacing(with: [String: String])
}

/// How a detected login relates to the existing accounts (`QuotaDaemon.importMatch`).
public enum ImportMatch: Equatable, Sendable {
  /// This account already holds the login's primary secret.
  case alreadyImported(accountID: String)
  /// No existing account could take the login, so importing adds one.
  case newAccount
  /// These accounts of the login's provider hold a different login, such as an
  /// expired token of the same Claude account. Importing offers to update one of
  /// them in place instead of adding a duplicate.
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
      return "No account matches \"\(id)\". Run `llimit accounts list` to see account IDs."
    case .blankAccountID:
      return "The account ID is empty."
    case .ambiguousAccount(let fragment, let candidates):
      return "\"\(fragment)\" matches several accounts: \(candidates.joined(separator: ", ")). Type more of the ID."
    case .blankDisplayName:
      return "The account name is empty."
    case .unknownCredentialKey(let key, let provider):
      let keys = provider.credentialFields.map(\.key).joined(separator: ", ")
      return "\"\(key)\" is not a \(provider.displayName) credential. Use one of: \(keys)."
    case .managedCredentials(let name):
      return "\(name) is signed in through its own Codex profile, so its credentials cannot be replaced. Reconnect it in the macOS app, or add a separate account."
    case .noDetectedLogin(let provider):
      return "No \(provider.displayName) login was detected on this machine. Sign in with the provider's tool, or set the credentials with `llimit accounts update`."
    case .detectedLoginNotFound(let stableID, let available):
      let detected = available.isEmpty ? "none" : available.joined(separator: ", ")
      return "No detected login has the ID \(stableID). Detected logins for this provider: \(detected)."
    case .ambiguousDetectedLogin(let provider, let stableIDs):
      return "Several \(provider.displayName) logins were detected: \(stableIDs.joined(separator: ", ")). Choose one with --from <stable-id>."
    }
  }
}
