import Foundation
import SwiftUI
import AppKit
import WidgetKit
import ServiceManagement
import QuotaCore
#if canImport(Security)
import Security
#endif

struct ProviderAccountStatus: Identifiable, Hashable {
  let accountID: String
  let provider: QuotaProvider
  let available: Bool
  let enabled: Bool
  let detail: String

  var id: String { accountID }
}

@MainActor
final class AppModel: ObservableObject {
  @Published var refreshIntervalMinutes: Int = 30
  @Published var widgetStyle: WidgetStyleSettings = .default
  @Published var widgetBackgroundSettings: WidgetBackgroundSettings = .default
  @Published var widgetVisibility: WidgetVisibilitySettings = .default
  @Published var providerAccounts: [ProviderAccount] = []
  @Published var providerStyleSettings: [String: ProviderStyleSettings] = [:]
  /// Account ID per provider-tile widget slot; "" = automatic (Nth enabled account).
  @Published var providerTileSlots: [String] = []
  @Published var accountStatuses: [ProviderAccountStatus] = []
  @Published var snapshot: QuotaSnapshot?
  /// Recent slice of the local refresh history backing the dashboard sparklines.
  /// Two days is enough for the 24h spark window while keeping the read cheap
  /// against the 45-day history file.
  @Published private(set) var recentHistory: [QuotaSnapshot] = []
  @Published var statusMessage: String = ""
  @Published var isRefreshing = false
  @Published var launchAtLogin = false
  /// Credentials detected on this Mac from local AI tools, offered as one-click imports.
  /// This is a convenience only — imported accounts are fully owned and stored by LLimit.
  @Published var detectedCredentials: [DiscoveredCredential] = []
  /// Human-readable log of the last detection scan, shown in Settings to explain what
  /// was (or wasn't) found — including the macOS Keychain result for Claude.
  @Published var discoveryDiagnostics: [String] = []

  @Published var claudeTerminalSession: ClaudeTerminalSession?
  @Published private(set) var claudeAccountMessages: [String: String] = [:]
  @Published private var claudeRenewals: [String: UUID] = [:]
  private var claudeSessions: [String: ClaudeTerminalSession] = [:]
  private var claudeLoginProfiles: [String: ClaudeCodeProfile] = [:]
  private var claudeCredentialFailures: Set<String> = []
  private var claudeUsageReceipts: [String: ClaudeCodeUsageReceipt] = [:]
  private let claudeProfiles = ClaudeProfileService()
  private let claudeProcess = ClaudeCodeProcess()

  private let settingsStore: SettingsStore
  private let snapshotStore: SnapshotStore
  private let historyStore: QuotaHistoryStore
  private let refreshService: RefreshService
  private var cachedAppGroupSettingsStore: SettingsStore?
  private var cachedAppGroupSnapshotStore: SnapshotStore?
  private var cachedAppGroupHistoryStore: QuotaHistoryStore?
  private var autoRefreshTask: Task<Void, Never>?
  private var widgetReloadTask: Task<Void, Never>?
  private var hasBootstrapped = false
  private var configurationLoadFailed = false

  init() {
    let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let baseDirectory = appSupportDirectory.appendingPathComponent("LLimit", isDirectory: true)
    let urls: (settings: URL, snapshot: URL, history: URL) = (
      baseDirectory.appendingPathComponent(SharedConstants.settingsFileName),
      baseDirectory.appendingPathComponent(SharedConstants.snapshotFileName),
      baseDirectory.appendingPathComponent(SharedConstants.historyFileName)
    )

    let settingsStore = SettingsStore(fileURL: urls.settings)
    let snapshotStore = SnapshotStore(fileURL: urls.snapshot)
    let historyStore = QuotaHistoryStore(fileURL: urls.history)

    self.settingsStore = settingsStore
    self.snapshotStore = snapshotStore
    self.historyStore = historyStore
    self.refreshService = RefreshService(
      coordinator: QuotaCoordinator.live(),
      snapshotStore: snapshotStore
    )
    self.launchAtLogin = SMAppService.mainApp.status == .enabled

    Task { @MainActor [weak self] in
      await self?.bootstrap()
    }
  }

  func bootstrap() async {
    guard !hasBootstrapped else { return }
    hasBootstrapped = true

    await loadConfiguration()

    do {
      snapshot = try loadSnapshotFromPreferredStore()
      reconcileSnapshotWithCurrentAccounts()
    } catch {
      statusMessage = "Could not load snapshot: \(error.localizedDescription)"
    }

    reloadRecentHistory()
    reloadAccountStatuses()
    restartAutoRefreshLoop()

    if shouldRefreshOnBootstrap() {
      await refreshNow()
    }
  }

  func loadConfiguration() async {
    let settings: AppSettings
    do {
      settings = try loadSettingsFromPreferredStore()
      configurationLoadFailed = false
    } catch {
      settings = .default
      configurationLoadFailed = true
      statusMessage = "Could not load settings. Using defaults. The existing file will not be overwritten."
    }

    refreshIntervalMinutes = settings.refreshIntervalMinutes
    widgetStyle = settings.widgetStyle
    widgetBackgroundSettings = settings.widgetBackgroundSettings
    widgetVisibility = settings.widgetVisibility
    providerAccounts = settings.accounts
    providerTileSlots = settings.providerTileSlots
    providerStyleSettings = Dictionary(
      uniqueKeysWithValues: providerAccounts.map { account in
        (account.id, settings.styleOverride(for: account.id))
      }
    )
    reloadAccountStatuses()
  }

  func saveConfiguration(showSuccessMessage: Bool = false) {
    guard !configurationLoadFailed else {
      statusMessage = "Save blocked because the existing settings file could not be read. Fix or back up the file, then relaunch LLimit."
      return
    }

    do {
      let settings = currentSettings()

      try settingsStore.save(settings)
      let widgetSyncReady = syncSettingsToWidgetStore(settings.redactedCredentials())
      if widgetSyncReady {
        reloadWidgetTimelines()
      }
      if !widgetSyncReady {
        statusMessage = "Settings saved locally. Widget sync unavailable."
      } else if showSuccessMessage {
        statusMessage = "Configuration saved"
      }
    } catch {
      statusMessage = "Save failed: \(error.localizedDescription)"
    }
  }

  func refreshNow() async {
    guard !isRefreshing else {
      return
    }

    isRefreshing = true
    defer { isRefreshing = false }

    await refreshExpiringChatGPTTokens()
    let claudeFailures = await prepareClaudeAccounts()
    reloadAccountStatuses()

    let enabledConfigs = runtimeConfigurations().filter { configuration in
      configuration.isEnabled && configuration.provider.hasRequiredCredentials(configuration.credentials)
        && !claudeFailures.contains(where: { $0.accountID == configuration.accountID })
    }

    guard !enabledConfigs.isEmpty || !claudeFailures.isEmpty else {
      statusMessage = "No enabled provider accounts with complete credentials configured."
      return
    }

    do {
      var refreshed = try await refreshService.refresh(configurations: enabledConfigs, credentialFailures: claudeFailures)
      recordClaudeUsage(in: refreshed, configurations: enabledConfigs)

      // Reactive recovery: if an enabled OpenAI account failed authentication (a token
      // revoked before its JWT exp, or a Codex rotation that landed mid-cycle), refresh
      // its token and retry — only the accounts we actually recovered, so healthy accounts
      // and the other providers aren't re-polled (Anthropic hard-rate-limits repeat pollers).
      var recoveredIDs = await recoverFailedOpenAITokens(in: refreshed)
      let blockedClaudeIDs = Set(claudeFailures.map(\.accountID))
      for failure in refreshed.failures where failure.provider == .anthropic && failure.kind == .auth
        && !blockedClaudeIDs.contains(failure.accountID) {
        if await prepareClaudeAccount(id: failure.accountID, force: true) == nil,
           let account = account(withID: failure.accountID),
           ClaudeCodeProfile.profile(from: account.credentials) != nil {
          recoveredIDs.insert(failure.accountID)
        }
      }
      if !recoveredIDs.isEmpty {
        let retryConfigs = runtimeConfigurations().filter { configuration in
          recoveredIDs.contains(configuration.accountID)
            && configuration.isEnabled
            && configuration.provider.hasRequiredCredentials(configuration.credentials)
        }
        if !retryConfigs.isEmpty {
          let retriedIDs = Set(retryConfigs.map(\.accountID))
          // Merge stale-on-failure against the current snapshot so a still-failing retry
          // keeps the last-known usage, then splice only these accounts' results back in.
          let retrySnapshot = await refreshService.fetch(configurations: retryConfigs)
            .mergingStaleUsage(from: refreshed)
          recordClaudeUsage(in: retrySnapshot, configurations: retryConfigs)
          refreshed = refreshed.replacingResults(forAccountIDs: retriedIDs, from: retrySnapshot)
          try? refreshService.save(refreshed)
        }
      }

      publishSnapshot(refreshed)
    } catch {
      statusMessage = "Refresh failed: \(error.localizedDescription)"
    }
  }

  private func publishSnapshot(_ refreshed: QuotaSnapshot) {
    do {
      try historyStore.append(refreshed)
    } catch {
      print("[LLimit] Local history append failed: \(error.localizedDescription)")
    }
    reloadRecentHistory()

    let widgetSyncReady = syncSnapshotToWidgetStore(refreshed)
    let historySyncReady = syncHistoryToWidgetStore(refreshed)

    if widgetSyncReady || historySyncReady {
      reloadWidgetTimelines()
    }

    snapshot = refreshed

    if widgetSyncReady && historySyncReady {
      statusMessage = "Refreshed \(refreshed.providers.count) account(s), \(refreshed.failures.count) failure(s)"
    } else {
      statusMessage = "Refreshed \(refreshed.providers.count) account(s), \(refreshed.failures.count) failure(s). Widget sync partially unavailable."
    }
  }

  /// Bind each successful result to the profile actually queried. A timestamp
  /// alone cannot distinguish an old imported login from its replacement.
  private func recordClaudeUsage(in result: QuotaSnapshot, configurations: [ProviderRuntimeConfiguration]) {
    for configuration in configurations where configuration.provider == .anthropic {
      let id = configuration.accountID
      guard !result.failures.contains(where: { $0.accountID == id }),
            let usage = result.providers.first(where: { $0.accountID == id }),
            let profile = ClaudeCodeProfile.profile(from: configuration.credentials) else {
        claudeUsageReceipts[id] = nil
        continue
      }
      claudeUsageReceipts[id] = ClaudeCodeUsageReceipt(profileID: profile.id, fetchedAt: usage.fetchedAt)
    }
  }

  /// A completed login needs fresh usage. Reuse a concurrent cycle's successful
  /// result only if it queried this new profile after login completed.
  private func refreshClaudeAccountAfterCurrentCycle(_ id: String, requestedAt: Date) async {
    while isRefreshing {
      do { try await Task.sleep(for: .seconds(1)) }
      catch { return }
    }
    guard !Task.isCancelled else { return }
    guard let account = account(withID: id), account.isEnabled,
          let profile = ClaudeCodeProfile.profile(from: account.credentials) else { return }
    if snapshot?.failures.contains(where: { $0.accountID == id }) == false,
       claudeUsageReceipts[id]?.satisfies(profileID: profile.id, since: requestedAt) == true {
      return
    }
    isRefreshing = true
    defer { isRefreshing = false }
    let failure = await prepareClaudeAccount(id: id)
    var partial: QuotaSnapshot
    if let failure {
      partial = QuotaSnapshot(generatedAt: Date(), providers: [], failures: [failure])
    } else {
      let configurations = runtimeConfigurations().filter { $0.accountID == id && $0.isEnabled }
      partial = await refreshService.fetch(configurations: configurations)
      recordClaudeUsage(in: partial, configurations: configurations)
    }
    partial = partial.mergingStaleUsage(from: snapshot)
    var refreshed = snapshot?.replacingResults(forAccountIDs: [id], from: partial) ?? partial
    refreshed.generatedAt = partial.generatedAt
    var saveFailed = false
    do { try refreshService.save(refreshed) }
    catch { saveFailed = true }
    publishSnapshot(refreshed)
    if saveFailed { statusMessage = "The Claude refresh result could not be saved locally. Check LLimit’s storage permissions." }
  }

  func reloadAccountStatuses() {
    accountStatuses = providerAccounts.map { account in
      let missing = account.missingCredentialLabels
      let failed = claudeCredentialFailures.contains(account.id)
      let pending = account.credentials[CredentialField.anthropicRenewalPending] != nil
      let needsRenewal = ClaudeCodeProfile.profile(from: account.credentials) != nil
        && ClaudeCodeProfile.readiness(for: ClaudeCodeProfile.credentials(from: account.credentials)) != .ready
      let detail: String
      if failed, let message = claudeAccountMessages[account.id] {
        detail = message
      } else if pending {
        detail = "Renewal needs verification. Reconnect if it does not finish."
      } else if needsRenewal {
        detail = "Credentials need renewal. Refresh this account."
      } else if missing.isEmpty {
        detail = account.isEnabled ? "Ready" : "Disabled"
      } else {
        detail = "Missing: \(missing.joined(separator: ", "))"
      }

      return ProviderAccountStatus(
        accountID: account.id,
        provider: account.provider,
        available: missing.isEmpty && !failed && !pending && !needsRenewal,
        enabled: account.isEnabled,
        detail: detail
      )
    }
  }

  @discardableResult
  func addProviderAccount(provider: QuotaProvider) -> ProviderAccount {
    let account = ProviderAccount(
      provider: provider,
      displayName: nextDisplayName(for: provider),
      isEnabled: true,
      credentials: emptyCredentials(for: provider)
    )

    providerAccounts.append(account)
    providerStyleSettings[account.id] = ProviderStyleSettings.defaultValue(
      for: account.id,
      provider: provider,
      fallbackStyle: widgetStyle
    )
    reloadAccountStatuses()
    saveConfiguration(showSuccessMessage: true)
    return account
  }

  func removeProviderAccount(accountID: String) {
    guard !isRefreshing, !claudeAccountIsBusy(accountID) else { return }
    let removedAccount = providerAccounts.first { $0.id == accountID }
    if let removedAccount, ClaudeCodeProfile.isRemovalBlocked(for: removedAccount.credentials) {
      // A renewal from an earlier app instance may still be rotating this grant.
      // Its auth-login command does not hold the CLI's automatic-refresh locks.
      claudeAccountMessages[accountID] = "Renewal is not verified yet. Refresh to check it, or reconnect before removing this account."
      reloadAccountStatuses()
      return
    }
    if let profile = removedAccount.flatMap({ ClaudeCodeProfile.profile(from: $0.credentials) }) {
      do { try claudeProfiles.remove(profile) }
      catch {
        claudeAccountMessages[accountID] = "Could not remove this Claude profile. Close its terminal and unlock Keychain, then try again."
        reloadAccountStatuses()
        return
      }
    }
    claudeSessions[accountID] = nil
    claudeAccountMessages[accountID] = nil
    claudeCredentialFailures.remove(accountID)
    claudeUsageReceipts[accountID] = nil
    providerAccounts.removeAll { $0.id == accountID }
    providerStyleSettings.removeValue(forKey: accountID)
    // Deleting the account is an explicit choice, so its tile slots fall back to
    // automatic (visibly badged on the tile) instead of a dead "reassign" state.
    providerTileSlots = providerTileSlots.map { $0 == accountID ? "" : $0 }
    reconcileSnapshotWithCurrentAccounts()
    purgeHistory(for: removedAccount)
    reloadAccountStatuses()
    saveConfiguration(showSuccessMessage: true)
  }

  // MARK: - Detect & import (convenience)

  /// Scans local AI tools for credentials you could import into a new LLimit account.
  /// Optional convenience so you don't have to hunt for tokens — nothing here is a
  /// runtime dependency; imported accounts are copied into LLimit and stored locally.
  func scanForDetectedCredentials() {
    var result = CredentialDiscovery().discover()

    #if canImport(Security)
    if !result.credentials.contains(where: { $0.provider == .anthropic }) {
      let keychain = Self.readClaudeKeychainToken()
      result.diagnostics.append("Claude Code Keychain: \(keychain.diagnostic)")
      if let token = keychain.token {
        result.credentials.append(
          DiscoveredCredential(
            stableID: "anthropic:keychain",
            provider: .anthropic,
            suggestedName: "Claude",
            sourceLabel: "Claude Code (macOS Keychain)",
            credentials: [CredentialField.anthropicAccessToken: token]
          )
        )
      }
    }
    #endif

    detectedCredentials = result.credentials
    discoveryDiagnostics = result.diagnostics
  }

  /// Fills an existing account's credentials from a login detected on this Mac (the
  /// per-account "Auto-fill" action). Running this on demand also triggers the macOS
  /// Keychain prompt for Claude, which a background scan can't surface clearly.
  @discardableResult
  func autofillCredentials(forAccountID accountID: String) -> Bool {
    guard let index = providerAccounts.firstIndex(where: { $0.id == accountID }) else { return false }
    let provider = providerAccounts[index].provider

    scanForDetectedCredentials()

    guard let match = detectedCredentials.first(where: { $0.provider == provider }) else {
      statusMessage = "No \(provider.displayName) login detected on this Mac. Sign in to a supported tool, or paste the credentials manually."
      return false
    }

    providerAccounts[index].credentials = match.credentials
    claudeAccountMessages[accountID] = nil
    claudeCredentialFailures.remove(accountID)
    reloadAccountStatuses()
    saveConfiguration()
    statusMessage = "Filled “\(providerAccounts[index].resolvedDisplayName)” from \(match.sourceLabel)."
    return true
  }

  /// Creates a new LLimit-owned account pre-filled with a detected credential.
  @discardableResult
  func importAccount(from detected: DiscoveredCredential) -> ProviderAccount {
    let name = detected.suggestedName.trimmingCharacters(in: .whitespacesAndNewlines)
    let account = ProviderAccount(
      provider: detected.provider,
      displayName: name.isEmpty ? nextDisplayName(for: detected.provider) : name,
      isEnabled: true,
      credentials: detected.credentials
    )

    providerAccounts.append(account)
    providerStyleSettings[account.id] = ProviderStyleSettings.defaultValue(
      for: account.id,
      provider: detected.provider,
      fallbackStyle: widgetStyle
    )
    reloadAccountStatuses()
    saveConfiguration(showSuccessMessage: true)
    return account
  }

  /// True when an existing account already holds the same token for this provider,
  /// so we can show "Added" instead of offering a duplicate import.
  func isDetectedCredentialImported(_ detected: DiscoveredCredential) -> Bool {
    let tokens = Set(detected.credentials.values.filter { !$0.isEmpty })
    guard !tokens.isEmpty else { return false }
    return providerAccounts.contains { account in
      account.provider == detected.provider
        && !Set(account.credentials.values).isDisjoint(with: tokens)
    }
  }

  #if canImport(Security)
  private static func readClaudeKeychainToken() -> (token: String?, diagnostic: String) {
    // Import only the ordinary CLI login. Enumerating every service containing
    // "claude" would expose a private managed profile as an unrelated import.
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "Claude Code-credentials",
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var data: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &data)
    if status == errSecSuccess, let payload = data as? Data, let token = claudeToken(fromKeychainData: payload) {
      return (token, "found the default Claude Code login")
    }
    if status == errSecInteractionNotAllowed {
      return (nil, "the default Claude Code login needs Keychain permission. Allow access, then scan again.")
    }
    return (nil, "no readable default Claude Code login. Use Connect Claude to sign in to a separate account.")
  }

  /// Claude Code stores JSON (`{ "claudeAiOauth": { "accessToken": ... } }`), but be
  /// lenient: accept a flat object or a raw token string too.
  private static func claudeToken(fromKeychainData data: Data) -> String? {
    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      let oauth = (object["claudeAiOauth"] as? [String: Any]) ?? object
      let token = ((oauth["accessToken"] as? String) ?? (oauth["access_token"] as? String))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return (token?.isEmpty == false) ? token : nil
    }

    let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let raw, raw.count > 20, !raw.contains(" ") {
      return raw
    }
    return nil
  }
  #endif

  /// Prepares ChatGPT/Codex access tokens before a refresh: adopts the live tokens Codex
  /// maintains on disk, then refreshes anything still missing/expired. ChatGPT tokens
  /// expire hourly, so without this an imported OpenAI account 401s after ~an hour.
  ///
  /// OpenAI uses *rotating* refresh tokens — each refresh invalidates the previous one for
  /// sibling clients — so LLimit's one-time imported copy dies as soon as the Codex CLI
  /// refreshes (and vice-versa). Re-reading `~/.codex/auth.json` (matched by ChatGPT
  /// account id) and adopting Codex's current token keeps the two in sync instead of
  /// fighting over the grant.
  private func refreshExpiringChatGPTTokens() async {
    // Only enabled accounts: refreshing a disabled account would keep rotating the shared
    // Codex refresh token and log the user's Codex CLI out of an account they turned off.
    let openAIAccountIDs = providerAccounts.filter { $0.provider == .openAI && $0.isEnabled }.map(\.id)
    guard !openAIAccountIDs.isEmpty else { return }

    var didChange = false

    // 1. Adopt the freshest local Codex/OpenCode tokens first (Codex may have rotated).
    if adoptLiveOpenAITokens(forAccountIDs: openAIAccountIDs) {
      didChange = true
    }

    // 2. Refresh anything still missing or near expiry using the (possibly just-adopted)
    //    refresh token.
    for accountID in openAIAccountIDs {
      guard let index = providerAccounts.firstIndex(where: { $0.id == accountID }) else { continue }
      let credentials = providerAccounts[index].credentials
      guard let refreshToken = credentials[CredentialField.openAIRefreshToken], !refreshToken.isEmpty else { continue }

      let access = credentials[CredentialField.openAIAccessToken] ?? ""
      if !access.isEmpty, !ChatGPTOAuth.isAccessTokenExpired(access) { continue }

      if await refreshOpenAIAccount(id: accountID, refreshToken: refreshToken) {
        didChange = true
      }
    }

    if didChange {
      saveConfiguration()
    }
  }

  /// Adopts the live Codex/OpenCode tokens for the given accounts, matched by ChatGPT
  /// account id. Returns whether any account's credentials changed. Does not save.
  private func adoptLiveOpenAITokens(forAccountIDs accountIDs: [String]) -> Bool {
    let live = CredentialDiscovery().discover().credentials
      .filter { $0.provider == .openAI }
      .map(\.credentials)
    guard !live.isEmpty else { return false }

    var changed = false
    for accountID in accountIDs {
      guard let index = providerAccounts.firstIndex(where: { $0.id == accountID }) else { continue }
      guard let updated = OpenAICredentialSync.adoption(
        for: providerAccounts[index].credentials,
        among: live,
        expiry: ChatGPTOAuth.accessTokenExpiry
      ) else { continue }
      providerAccounts[index].credentials = updated
      changed = true
    }
    return changed
  }

  /// Exchanges the stored refresh token for a fresh access token and persists the rotated
  /// tokens (in memory; caller saves). On failure — typically `invalid_grant` after Codex
  /// rotated the grant out from under us — re-reads the live Codex file and adopts its
  /// token as a last resort. Returns whether the account's credentials changed.
  @discardableResult
  private func refreshOpenAIAccount(id accountID: String, refreshToken: String) async -> Bool {
    do {
      let result = try await ChatGPTOAuth.refresh(refreshToken: refreshToken)
      // Re-resolve the index across the await — the account list may have changed.
      guard let index = providerAccounts.firstIndex(where: { $0.id == accountID }) else { return false }
      providerAccounts[index].credentials[CredentialField.openAIAccessToken] = result.accessToken
      if let newRefresh = result.refreshToken {
        providerAccounts[index].credentials[CredentialField.openAIRefreshToken] = newRefresh
      }
      if let newAccountID = result.accountID {
        providerAccounts[index].credentials[CredentialField.openAIAccountID] = newAccountID
      }
      return true
    } catch {
      print("[LLimit] ChatGPT token refresh failed: \(error.localizedDescription)")
      // Codex may have rotated the grant; re-read the live file and adopt if it changed.
      return adoptLiveOpenAITokens(forAccountIDs: [accountID])
    }
  }

  /// Reactive recovery for a ChatGPT access token that was revoked server-side before its
  /// JWT `exp` (logout, password change, refresh-token-family revocation): the proactive
  /// pass skips a not-yet-expired token, so such an account 401s every cycle. For each
  /// enabled OpenAI account that failed auth this cycle, first adopt a fresher live token;
  /// only if nothing fresher is on disk do we force a refresh (which rotates the grant).
  /// Returns the set of account ids whose credentials changed, so the caller can retry
  /// exactly those accounts.
  private func recoverFailedOpenAITokens(in snapshot: QuotaSnapshot) async -> Set<String> {
    let failedIDs = snapshot.failures
      .filter { $0.provider == .openAI && $0.kind == .auth }
      .map(\.accountID)
    guard !failedIDs.isEmpty else { return [] }

    var recovered: Set<String> = []
    for accountID in failedIDs {
      guard
        let index = providerAccounts.firstIndex(where: { $0.id == accountID }),
        providerAccounts[index].provider == .openAI,
        providerAccounts[index].isEnabled
      else { continue }

      // Prefer adopting Codex's own fresher token — that recovers the account without
      // rotating the shared grant (which would log the Codex CLI out).
      if adoptLiveOpenAITokens(forAccountIDs: [accountID]) {
        recovered.insert(accountID)
        continue
      }

      // Nothing fresher on disk: the stored token is genuinely bad, so force a refresh.
      let refreshToken = providerAccounts[index].credentials[CredentialField.openAIRefreshToken] ?? ""
      if !refreshToken.isEmpty, await refreshOpenAIAccount(id: accountID, refreshToken: refreshToken) {
        recovered.insert(accountID)
      }
    }

    if !recovered.isEmpty {
      saveConfiguration()
    }
    return recovered
  }

  // MARK: - Independent Claude Code profiles

  func claudeLoginIsOpen(_ accountID: String) -> Bool {
    guard let session = claudeSessions[accountID] else { return false }
    if case .exited = session.state { return false }
    return true
  }

  func claudeAccountIsBusy(_ accountID: String) -> Bool {
    if claudeRenewals[accountID] != nil { return true }
    guard let session = claudeSessions[accountID] else { return false }
    if case .exited = session.state { return false }
    return true
  }

  func dismissClaudeTerminal() {
    if let session = claudeTerminalSession, case .exited = session.state {
      claudeSessions = claudeSessions.filter { $0.value.id != session.id }
    }
    claudeTerminalSession = nil
  }

  func connectClaudeAccount(_ accountID: String) {
    if let session = claudeSessions[accountID] {
      if case .exited = session.state {} else {
        claudeTerminalSession = session
        return
      }
    }
    guard !isRefreshing, !claudeAccountIsBusy(accountID),
          let account = account(withID: accountID), account.provider == .anthropic else { return }
    do {
      let executable = try claudeProfiles.executable()
      // Stage each login independently. Cancellation or signing into the wrong
      // account must leave an existing working connection untouched. This also
      // avoids racing a renewal left behind by an earlier app instance.
      let profile = ClaudeCodeProfile()
      let directory = try claudeProfiles.prepare(profile)
      let session = ClaudeTerminalSession(
        executable: executable, arguments: ["auth", "login", "--claudeai"],
        environment: ClaudeCodeProcess.environment(parent: ProcessInfo.processInfo.environment,
                                                    profileDirectory: directory),
        workingDirectory: directory.appendingPathComponent("work", isDirectory: true))
      session.onExit = { [weak self] status in
        self?.completeClaudeLogin(accountID: accountID, profile: profile, status: status)
      }
      claudeLoginProfiles[accountID] = profile
      claudeSessions[accountID] = session
      claudeAccountMessages[accountID] = "Finish signing in in this account’s terminal."
      claudeTerminalSession = session
      reloadAccountStatuses()
    } catch {
      claudeAccountMessages[accountID] = claudeErrorMessage(error)
      reloadAccountStatuses()
    }
  }

  private func completeClaudeLogin(accountID: String, profile: ClaudeCodeProfile, status: Int32?) {
    guard let account = account(withID: accountID), claudeLoginProfiles[accountID] == profile else { return }
    claudeLoginProfiles[accountID] = nil
    guard status == 0 else {
      try? claudeProfiles.remove(profile)
      claudeAccountMessages[accountID] = account.provider.hasRequiredCredentials(account.credentials)
        ? "Sign-in did not finish. Your previous connection is unchanged."
        : "Sign-in did not finish. Connect this account to try again."
      reloadAccountStatuses()
      return
    }
    do {
      let login = try claudeProfiles.read(profile, mode: .interactive)
      let otherIdentities = providerAccounts.filter { $0.id != accountID && $0.provider == .anthropic }
        .compactMap { ClaudeCodeProfile.identity(from: $0.credentials) }
      let credentials = try ClaudeCodeProfile.loginCredentials(
        for: account.credentials, credentials: login.credentials, identity: login.identity,
        profileID: profile.id, existingIdentities: otherIdentities)
      try persistClaudeCredentials(credentials, accountID: accountID)
      if let previous = ClaudeCodeProfile.profile(from: account.credentials) {
        // A persisted pending marker can belong to a still-running orphan child.
        // Keep that old namespace intact; it is never reused by the new login.
        if account.credentials[CredentialField.anthropicRenewalPending] == nil {
          try? claudeProfiles.remove(previous)
        }
      }
      claudeCredentialFailures.remove(accountID)
      claudeAccountMessages[accountID] = "Connected. Credentials renew automatically."
      reloadAccountStatuses()
      let completedAt = Date()
      Task { await refreshClaudeAccountAfterCurrentCycle(accountID, requestedAt: completedAt) }
    } catch {
      try? claudeProfiles.remove(profile)
      claudeAccountMessages[accountID] = claudeErrorMessage(error)
      reloadAccountStatuses()
    }
  }

  /// Saving the pending marker must succeed before the CLI can rotate a grant.
  /// On a crash or ambiguous exit, a later run may adopt a newly saved token, but
  /// it must never replay the old refresh token automatically.
  private func persistClaudeCredentials(_ credentials: [String: String], accountID: String,
                                       expectedProfile: ClaudeCodeProfile? = nil) throws {
    guard !configurationLoadFailed,
          let index = providerAccounts.firstIndex(where: { $0.id == accountID }) else {
      throw ClaudeProfileService.Failure.settingsUnavailable
    }
    if let expectedProfile,
       ClaudeCodeProfile.profile(from: providerAccounts[index].credentials) != expectedProfile {
      throw ClaudeProfileService.Failure.settingsUnavailable
    }
    let previous = providerAccounts[index].credentials
    providerAccounts[index].credentials = credentials
    do { try settingsStore.save(currentSettings()) }
    catch {
      providerAccounts[index].credentials = previous
      throw ClaudeProfileService.Failure.settingsUnavailable
    }
    if syncSettingsToWidgetStore(currentSettings().redactedCredentials()) { reloadWidgetTimelines() }
    reloadAccountStatuses()
  }

  private func prepareClaudeAccounts() async -> [ProviderFailure] {
    let ids = providerAccounts.filter {
      $0.provider == .anthropic && $0.isEnabled && ClaudeCodeProfile.profile(from: $0.credentials) != nil
    }.map(\.id)
    var failures: [ProviderFailure] = []
    for id in ids {
      if let failure = await prepareClaudeAccount(id: id) { failures.append(failure) }
    }
    return failures
  }

  private func prepareClaudeAccount(id: String, force: Bool = false) async -> ProviderFailure? {
    guard let account = account(withID: id), account.isEnabled,
          let profile = ClaudeCodeProfile.profile(from: account.credentials) else { return nil }
    do {
      if let operation = claudeRenewals[id] {
        if case .running = await claudeProcess.status(id: operation) {
          throw ClaudeCodeRenewalError.inProgress
        }
        claudeRenewals[id] = nil
      }
      guard !claudeAccountIsBusy(id), !claudeProfiles.isRefreshLocked(profile) else {
        throw ClaudeCodeRenewalError.inProgress
      }
      _ = try await ClaudeCodeRenewal.prepare(
        stored: account.credentials, force: force,
        read: { [claudeProfiles] in
          let login = try claudeProfiles.read(profile, mode: .background)
          return ClaudeCodeLogin(credentials: login.credentials, identity: login.identity, renewal: login.renewal)
        },
        persist: { [weak self] credentials in
          guard let self else { throw ClaudeProfileService.Failure.settingsUnavailable }
          try await self.persistClaudeCredentials(credentials, accountID: id, expectedProfile: profile)
        },
        renew: { [weak self] material in
          guard let self else { throw ClaudeProfileService.Failure.settingsUnavailable }
          return try await self.renewClaudeAccount(id: id, profile: profile, material: material)
        })
      claudeAccountMessages[id] = nil
      claudeCredentialFailures.remove(id)
      reloadAccountStatuses()
      return nil
    } catch {
      let message = claudeErrorMessage(error)
      claudeCredentialFailures.insert(id)
      claudeAccountMessages[id] = message
      reloadAccountStatuses()
      return ProviderFailure(accountID: id, provider: .anthropic, kind: .auth, message: message)
    }
  }

  private func renewClaudeAccount(id: String, profile: ClaudeCodeProfile,
                                 material: ClaudeCodeRenewalMaterial) async throws -> Bool {
    let directory = try claudeProfiles.prepare(profile)
    let result = try await claudeProcess.run(
      executable: claudeProfiles.executable(), arguments: ["auth", "login", "--claudeai"],
      environment: ClaudeCodeProcess.environment(parent: ProcessInfo.processInfo.environment,
                                                  profileDirectory: directory, renewal: material),
      workingDirectory: directory.appendingPathComponent("work", isDirectory: true), timeout: 45)
    switch result {
    case .completed(let status):
      guard status == 0 else { throw ClaudeCodeRenewalError.renewalIncomplete }
      return true
    case .running(let operation):
      claudeRenewals[id] = operation
      // Keep observing a slow child without killing it or replaying its grant.
      Task { [weak self, claudeProcess] in
        while case .running = await claudeProcess.status(id: operation) {
          try? await Task.sleep(for: .seconds(2))
        }
        guard let self, self.claudeRenewals[id] == operation else { return }
        self.claudeRenewals[id] = nil
        while self.isRefreshing { try? await Task.sleep(for: .seconds(1)) }
        // A concurrent manual refresh may already have adopted and fetched it.
        guard self.account(withID: id)?.credentials[CredentialField.anthropicRenewalPending] != nil else { return }
        await self.refreshClaudeAccountAfterCurrentCycle(id, requestedAt: Date())
      }
      return false
    }
  }

  private func claudeErrorMessage(_ error: Error) -> String {
    // Process and filesystem errors can embed paths or command details. Only
    // domain errors with fixed copy are allowed on snapshots and widgets.
    if let error = error as? ClaudeProfileService.Failure { return error.localizedDescription }
    if let error = error as? ClaudeCodeRenewalError { return error.localizedDescription }
    if let error = error as? ClaudeCodeLoginError { return error.localizedDescription }
    return "Could not connect this Claude account. Reconnect it to try again."
  }

  func account(withID accountID: String) -> ProviderAccount? {
    providerAccounts.first(where: { $0.id == accountID })
  }

  func status(for accountID: String) -> ProviderAccountStatus? {
    accountStatuses.first(where: { $0.accountID == accountID })
  }

  func isAccountAvailable(_ accountID: String) -> Bool {
    status(for: accountID)?.available ?? false
  }

  func accountDisplayNameBinding(for accountID: String) -> Binding<String> {
    Binding(
      get: { self.account(withID: accountID)?.displayName ?? "" },
      set: { newValue in
        self.updateAccount(accountID: accountID) { account in
          account.displayName = newValue
        }
      }
    )
  }

  func accountEnabledBinding(for accountID: String) -> Binding<Bool> {
    Binding(
      get: { self.account(withID: accountID)?.isEnabled ?? false },
      set: { newValue in
        self.updateAccount(accountID: accountID) { account in
          account.isEnabled = newValue
        }
      }
    )
  }

  func credentialBinding(for accountID: String, fieldKey: String) -> Binding<String> {
    Binding(
      get: { self.account(withID: accountID)?.credentials[fieldKey] ?? "" },
      set: { newValue in
        self.claudeAccountMessages[accountID] = nil
        self.claudeCredentialFailures.remove(accountID)
        self.updateAccount(accountID: accountID) { account in
          if account.provider == .anthropic && fieldKey == CredentialField.anthropicAccessToken {
            account.credentials = ClaudeCodeProfile.clearManagedMetadata(from: account.credentials)
          }
          account.credentials[fieldKey] = newValue
        }
      }
    )
  }

  func launchAtLoginBinding() -> Binding<Bool> {
    Binding(
      get: { self.launchAtLogin },
      set: { newValue in
        self.setLaunchAtLogin(newValue)
      }
    )
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      statusMessage = "Login item update failed: \(error.localizedDescription)"
    }
    launchAtLogin = SMAppService.mainApp.status == .enabled
  }

  func refreshIntervalBinding() -> Binding<Int> {
    Binding(
      get: { self.refreshIntervalMinutes },
      set: { newValue in
        self.refreshIntervalMinutes = min(
          max(newValue, AppSettings.refreshIntervalRange.lowerBound),
          AppSettings.refreshIntervalRange.upperBound
        )
        self.saveConfiguration()
        self.restartAutoRefreshLoop()
      }
    )
  }

  func providerTileSlotBinding(for index: Int) -> Binding<String> {
    Binding(
      get: {
        guard self.providerTileSlots.indices.contains(index) else { return "" }
        return self.providerTileSlots[index]
      },
      set: { newValue in
        var slots = self.providerTileSlots
        while slots.count < AppSettings.providerTileSlotCount {
          slots.append("")
        }
        guard slots.indices.contains(index) else { return }
        slots[index] = newValue
        self.providerTileSlots = slots
        // saveConfiguration syncs settings to the App Group store and reloads
        // widget timelines, which is how the tiles pick up the new assignment.
        self.saveConfiguration()
      }
    )
  }

  func widgetVisibilityBinding(
    for keyPath: WritableKeyPath<WidgetVisibilitySettings, Bool>
  ) -> Binding<Bool> {
    Binding(
      get: { self.widgetVisibility[keyPath: keyPath] },
      set: { newValue in
        self.widgetVisibility[keyPath: keyPath] = newValue
        self.saveConfiguration()
      }
    )
  }

  func widgetVisibilityIntBinding(
    for keyPath: WritableKeyPath<WidgetVisibilitySettings, Int>,
    range: ClosedRange<Int>
  ) -> Binding<Int> {
    Binding(
      get: { self.widgetVisibility[keyPath: keyPath] },
      set: { newValue in
        let clamped = min(max(newValue, range.lowerBound), range.upperBound)
        self.widgetVisibility[keyPath: keyPath] = clamped
        self.saveConfiguration()
      }
    )
  }

  var stylePresets: [WidgetStylePreset] {
    WidgetStylePreset.all
  }

  var customStylePresetID: String {
    WidgetStylePreset.customID
  }

  func widgetStylePresetBinding() -> Binding<String> {
    Binding(
      get: { WidgetStylePreset.id(for: self.widgetStyle) },
      set: { newValue in
        guard let preset = WidgetStylePreset.preset(withID: newValue) else {
          return
        }

        // Presets theme the background and menu bar status colors only; the
        // user's limit identity colors are not part of any preset and survive.
        var style = preset.style
        style.limitKindColors = self.widgetStyle.limitKindColors
        self.widgetStyle = style
        self.saveConfiguration()
      }
    )
  }

  func providerStylePresetBinding(for accountID: String) -> Binding<String> {
    Binding(
      get: { WidgetStylePreset.id(for: self.providerStyle(for: accountID).style) },
      set: { newValue in
        guard let preset = WidgetStylePreset.preset(withID: newValue) else {
          return
        }

        self.updateProviderStyle(for: accountID) { style in
          style.useCustomStyle = true
          style.style = preset.style
        }
      }
    )
  }

  func widgetBackgroundColorBinding() -> Binding<Color> {
    Binding(
      get: { Self.color(fromHex: self.widgetStyle.backgroundHexColor) },
      set: { newValue in
        self.widgetStyle.backgroundHexColor = Self.hexColor(from: newValue, allowTransparency: true)
        self.widgetStyle.useTransparentBackground = false
        self.saveConfiguration()
      }
    )
  }

  func widgetTransparentBackgroundBinding() -> Binding<Bool> {
    Binding(
      get: { self.widgetStyle.useTransparentBackground },
      set: { newValue in
        self.widgetStyle.useTransparentBackground = newValue
        self.saveConfiguration()
      }
    )
  }

  enum WidgetBackgroundTarget {
    case dashboard
    case trend
  }

  func widgetBackgroundOverride(for target: WidgetBackgroundTarget) -> WidgetBackgroundOverride {
    switch target {
    case .dashboard:
      return widgetBackgroundSettings.dashboard
    case .trend:
      return widgetBackgroundSettings.trend
    }
  }

  func widgetBackgroundOverrideBinding(for target: WidgetBackgroundTarget) -> Binding<Bool> {
    Binding(
      get: { self.widgetBackgroundOverride(for: target).useCustomBackground },
      set: { newValue in
        self.updateWidgetBackgroundOverride(for: target) { override in
          override.useCustomBackground = newValue
        }
      }
    )
  }

  func widgetBackgroundColorBinding(for target: WidgetBackgroundTarget) -> Binding<Color> {
    Binding(
      get: {
        let override = self.widgetBackgroundOverride(for: target)
        let resolvedHex = override.backgroundHexColor ?? self.widgetStyle.backgroundHexColor
        return Self.color(fromHex: resolvedHex)
      },
      set: { newValue in
        self.updateWidgetBackgroundOverride(for: target) { override in
          override.useCustomBackground = true
          override.backgroundHexColor = Self.hexColor(from: newValue, allowTransparency: true)
          override.useTransparentBackground = false
        }
      }
    )
  }

  func widgetTransparentBackgroundBinding(for target: WidgetBackgroundTarget) -> Binding<Bool> {
    Binding(
      get: { self.widgetBackgroundOverride(for: target).useTransparentBackground },
      set: { newValue in
        self.updateWidgetBackgroundOverride(for: target) { override in
          override.useCustomBackground = true
          override.useTransparentBackground = newValue
        }
      }
    )
  }

  func limitKindColorBinding(for kind: QuotaWindowKind, otherSlot: Int = 0) -> Binding<Color> {
    Binding(
      get: {
        Self.color(fromHex: self.widgetStyle.limitKindColors.hexColor(for: kind, otherSlot: otherSlot))
      },
      set: { newValue in
        guard let hex = Self.hexColor(from: newValue, allowTransparency: false) else {
          return
        }

        self.widgetStyle.limitKindColors.setHexColor(hex, for: kind, otherSlot: otherSlot)
        self.saveConfiguration()
      }
    )
  }

  func limitKindUnlimitedColorBinding() -> Binding<Color> {
    Binding(
      get: {
        Self.color(fromHex: self.widgetStyle.limitKindColors.unlimitedHexColor)
      },
      set: { newValue in
        guard let hex = Self.hexColor(from: newValue, allowTransparency: false) else {
          return
        }

        self.widgetStyle.limitKindColors.unlimitedHexColor = hex
        self.saveConfiguration()
      }
    )
  }

  func resetLimitKindColors() {
    widgetStyle.limitKindColors = .default
    saveConfiguration()
  }

  func providerStyle(for accountID: String) -> ProviderStyleSettings {
    providerStyleSettings[accountID]
      ?? ProviderStyleSettings.defaultValue(
        for: accountID,
        provider: account(withID: accountID)?.provider,
        fallbackStyle: widgetStyle
      )
  }

  func effectiveStyle(for accountID: String) -> WidgetStyleSettings {
    let providerStyle = providerStyle(for: accountID)

    guard providerStyle.useCustomStyle else {
      return widgetStyle
    }

    // Limit-kind colors are global identity; per-account styling only
    // customizes the background and the menu bar status colors.
    return WidgetStyleSettings(
      backgroundHexColor: providerStyle.style.backgroundHexColor ?? widgetStyle.backgroundHexColor,
      ringColors: providerStyle.style.ringColors,
      limitKindColors: widgetStyle.limitKindColors,
      useTransparentBackground: providerStyle.style.useTransparentBackground
    )
  }

  func providerOverrideEnabledBinding(for accountID: String) -> Binding<Bool> {
    Binding(
      get: { self.providerStyle(for: accountID).useCustomStyle },
      set: { newValue in
        self.updateProviderStyle(for: accountID) { style in
          style.useCustomStyle = newValue
        }
      }
    )
  }

  func providerBackgroundColorBinding(for accountID: String) -> Binding<Color> {
    Binding(
      get: {
        let providerStyle = self.providerStyle(for: accountID).style
        let resolvedHex = providerStyle.backgroundHexColor ?? self.widgetStyle.backgroundHexColor
        return Self.color(fromHex: resolvedHex)
      },
      set: { newValue in
        self.updateProviderStyle(for: accountID) { style in
          style.style.backgroundHexColor = Self.hexColor(from: newValue, allowTransparency: true)
          style.style.useTransparentBackground = false
        }
      }
    )
  }

  func providerTransparentBackgroundBinding(for accountID: String) -> Binding<Bool> {
    Binding(
      get: { self.providerStyle(for: accountID).style.useTransparentBackground },
      set: { newValue in
        self.updateProviderStyle(for: accountID) { style in
          style.style.useTransparentBackground = newValue
        }
      }
    )
  }

  private func updateAccount(
    accountID: String,
    mutate: (inout ProviderAccount) -> Void
  ) {
    guard let index = providerAccounts.firstIndex(where: { $0.id == accountID }) else {
      return
    }

    let previousAccount = providerAccounts[index]
    mutate(&providerAccounts[index])

    let updatedAccount = providerAccounts[index]
    let wasActive = previousAccount.isEnabled && previousAccount.hasRequiredCredentials
    let isActive = updatedAccount.isEnabled && updatedAccount.hasRequiredCredentials
    if wasActive != isActive || previousAccount.resolvedDisplayName != updatedAccount.resolvedDisplayName {
      reconcileSnapshotWithCurrentAccounts()
    }
    reloadAccountStatuses()
    saveConfiguration()
  }

  private func updateProviderStyle(
    for accountID: String,
    mutate: (inout ProviderStyleSettings) -> Void
  ) {
    var style = providerStyle(for: accountID)
    style.provider = account(withID: accountID)?.provider
    mutate(&style)
    providerStyleSettings[accountID] = style
    saveConfiguration()
  }

  private func updateWidgetBackgroundOverride(
    for target: WidgetBackgroundTarget,
    mutate: (inout WidgetBackgroundOverride) -> Void
  ) {
    switch target {
    case .dashboard:
      var override = widgetBackgroundSettings.dashboard
      mutate(&override)
      widgetBackgroundSettings.dashboard = override
    case .trend:
      var override = widgetBackgroundSettings.trend
      mutate(&override)
      widgetBackgroundSettings.trend = override
    }

    saveConfiguration()
  }

  private func nextDisplayName(for provider: QuotaProvider) -> String {
    let existingNames = Set(
      providerAccounts
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

  private func emptyCredentials(for provider: QuotaProvider) -> [String: String] {
    Dictionary(uniqueKeysWithValues: provider.credentialFields.map { ($0.key, "") })
  }

  private func runtimeConfigurations() -> [ProviderRuntimeConfiguration] {
    providerAccounts.map { account in
      ProviderRuntimeConfiguration(
        accountID: account.id,
        provider: account.provider,
        displayName: account.resolvedDisplayName,
        isEnabled: account.isEnabled,
        credentials: account.credentials
      )
    }
  }

  private func loadSettingsFromPreferredStore() throws -> AppSettings {
    return try settingsStore.load()
  }

  private func loadSnapshotFromPreferredStore() throws -> QuotaSnapshot? {
    return try snapshotStore.load()
  }

  private func currentSettings() -> AppSettings {
    AppSettings(
      refreshIntervalMinutes: refreshIntervalMinutes,
      accounts: providerAccounts,
      widgetStyle: widgetStyle,
      widgetBackgroundSettings: widgetBackgroundSettings,
      providerStyleSettings: providerAccounts.map { account in
        providerStyle(for: account.id)
      },
      widgetVisibility: widgetVisibility,
      providerTileSlots: providerTileSlots
    )
  }

  private func reconcileSnapshotWithCurrentAccounts() {
    guard let currentSnapshot = snapshot else { return }

    let activeAccounts = providerAccounts.filter { $0.isEnabled && $0.hasRequiredCredentials }
    let reconciled = currentSnapshot.reconciled(with: activeAccounts)
    guard reconciled != currentSnapshot else { return }

    snapshot = reconciled
    do {
      try snapshotStore.save(reconciled)
    } catch {
      print("[LLimit] Snapshot reconciliation save failed: \(error.localizedDescription)")
    }

    if syncSnapshotToWidgetStore(reconciled) {
      reloadWidgetTimelines()
    }
  }

  private func purgeHistory(for account: ProviderAccount?) {
    guard let account else { return }

    var accountIDs: Set<String> = [account.id]
    if !providerAccounts.contains(where: { $0.provider == account.provider }) {
      accountIDs.insert(account.provider.rawValue)
    }

    do {
      try historyStore.remove(accountIDs: accountIDs)
    } catch {
      print("[LLimit] Local history purge failed: \(error.localizedDescription)")
    }
    reloadRecentHistory()

    do {
      guard let widgetHistoryStore = appGroupHistoryStore() else {
        print("[LLimit] Widget history purge failed: no App Group history store available")
        return
      }
      try widgetHistoryStore.remove(accountIDs: accountIDs)
      reloadWidgetTimelines()
    } catch {
      print("[LLimit] Widget history purge failed: \(error.localizedDescription)")
      invalidateAppGroupStores()
    }
  }

  private func reloadRecentHistory(now: Date = Date()) {
    recentHistory = (try? historyStore.loadRecent(days: 2, now: now)) ?? []
  }

  private func restartAutoRefreshLoop() {
    autoRefreshTask?.cancel()

    autoRefreshTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else {
          return
        }

        let intervalNanoseconds = self.autoRefreshIntervalNanoseconds()
        do {
          try await Task.sleep(nanoseconds: intervalNanoseconds)
        } catch {
          return
        }

        if Task.isCancelled {
          return
        }

        await self.refreshNow()
      }
    }
  }

  private func autoRefreshIntervalNanoseconds() -> UInt64 {
    let clampedMinutes = min(
      max(refreshIntervalMinutes, AppSettings.refreshIntervalRange.lowerBound),
      AppSettings.refreshIntervalRange.upperBound
    )
    let seconds = UInt64(clampedMinutes * 60)
    return seconds * 1_000_000_000
  }

  private func shouldRefreshOnBootstrap(now: Date = Date()) -> Bool {
    guard !providerAccounts.isEmpty else {
      return false
    }

    guard let snapshot else {
      return true
    }

    let clampedMinutes = min(
      max(refreshIntervalMinutes, AppSettings.refreshIntervalRange.lowerBound),
      AppSettings.refreshIntervalRange.upperBound
    )
    let maxAgeSeconds = TimeInterval(clampedMinutes * 60)
    return now.timeIntervalSince(snapshot.generatedAt) >= maxAgeSeconds
  }

  private static func color(fromHex hex: String?) -> Color {
    guard let components = parseHexColor(hex) else {
      return .clear
    }

    return Color(
      red: components.red,
      green: components.green,
      blue: components.blue,
      opacity: components.alpha
    )
  }

  private static func hexColor(from color: Color, allowTransparency: Bool) -> String? {
    guard let components = rgbaComponents(from: color) else {
      return nil
    }

    if allowTransparency && components.alpha <= 0.01 {
      return nil
    }

    let red = clampColorByte(components.red)
    let green = clampColorByte(components.green)
    let blue = clampColorByte(components.blue)

    if allowTransparency {
      let alpha = clampColorByte(components.alpha)
      return String(format: "#%02X%02X%02X%02X", red, green, blue, alpha)
    }

    return String(format: "#%02X%02X%02X", red, green, blue)
  }

  private static func rgbaComponents(from color: Color) -> (
    red: Double,
    green: Double,
    blue: Double,
    alpha: Double
  )? {
    let nsColor = NSColor(color)
    guard let converted = nsColor.usingColorSpace(.extendedSRGB) ?? nsColor.usingColorSpace(.sRGB) else {
      return nil
    }

    return (
      red: Double(converted.redComponent),
      green: Double(converted.greenComponent),
      blue: Double(converted.blueComponent),
      alpha: Double(converted.alphaComponent)
    )
  }

  private static func parseHexColor(_ value: String?) -> (
    red: Double,
    green: Double,
    blue: Double,
    alpha: Double
  )? {
    guard var raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      return nil
    }

    if raw.hasPrefix("#") {
      raw.removeFirst()
    }

    if raw.count == 3 || raw.count == 4 {
      raw = raw.map { "\($0)\($0)" }.joined()
    }

    guard raw.count == 6 || raw.count == 8, let parsed = UInt64(raw, radix: 16) else {
      return nil
    }

    if raw.count == 6 {
      let red = Double((parsed >> 16) & 0xFF) / 255.0
      let green = Double((parsed >> 8) & 0xFF) / 255.0
      let blue = Double(parsed & 0xFF) / 255.0
      return (red: red, green: green, blue: blue, alpha: 1)
    }

    let red = Double((parsed >> 24) & 0xFF) / 255.0
    let green = Double((parsed >> 16) & 0xFF) / 255.0
    let blue = Double((parsed >> 8) & 0xFF) / 255.0
    let alpha = Double(parsed & 0xFF) / 255.0
    return (red: red, green: green, blue: blue, alpha: alpha)
  }

  private static func clampColorByte(_ value: Double) -> Int {
    Int((max(0, min(1, value)) * 255.0).rounded())
  }

  @discardableResult
  private func syncSettingsToWidgetStore(_ settings: AppSettings) -> Bool {
    for attempt in 1...2 {
      guard let appGroupStore = appGroupSettingsStore() else {
        print("[LLimit] Settings sync failed: no App Group settings store available")
        invalidateAppGroupStores()
        continue
      }

      do {
        try appGroupStore.save(settings)
        print("[LLimit] Settings synced to widget store successfully")
        return true
      } catch {
        print("[LLimit] Settings sync attempt \(attempt) failed: \(error.localizedDescription)")
        invalidateAppGroupStores()
      }
    }

    return false
  }

  @discardableResult
  private func syncSnapshotToWidgetStore(_ snapshot: QuotaSnapshot) -> Bool {
    for attempt in 1...2 {
      guard let appGroupStore = appGroupSnapshotStore() else {
        print("[LLimit] Widget sync failed: no App Group store available")
        invalidateAppGroupStores()
        continue
      }

      do {
        try appGroupStore.save(snapshot)
        print("[LLimit] Snapshot synced to widget store successfully")
        print("[LLimit] Debug info:\n\(appGroupStore.debugInfo())")
        return true
      } catch {
        print("[LLimit] Widget sync attempt \(attempt) failed: \(error.localizedDescription)")
        invalidateAppGroupStores()
      }
    }

    return false
  }

  private func appGroupSettingsStore() -> SettingsStore? {
    resolveAppGroupStoresIfNeeded()
    return cachedAppGroupSettingsStore
  }

  private func appGroupSnapshotStore() -> SnapshotStore? {
    resolveAppGroupStoresIfNeeded()
    return cachedAppGroupSnapshotStore
  }

  private func appGroupHistoryStore() -> QuotaHistoryStore? {
    resolveAppGroupStoresIfNeeded()
    return cachedAppGroupHistoryStore
  }

  private func resolveAppGroupStoresIfNeeded() {
    guard
      cachedAppGroupSettingsStore == nil
        || cachedAppGroupSnapshotStore == nil
        || cachedAppGroupHistoryStore == nil
    else {
      return
    }

    do {
      let settingsURL = try SharedPaths.settingsFileURL()
      let snapshotURL = try SharedPaths.snapshotFileURL()
      let historyURL = try SharedPaths.historyFileURL()
      cachedAppGroupSettingsStore = SettingsStore(fileURL: settingsURL)
      cachedAppGroupSnapshotStore = SnapshotStore(
        fileURL: snapshotURL,
        appGroupIdentifier: SharedConstants.appGroupIdentifier
      )
      cachedAppGroupHistoryStore = QuotaHistoryStore(fileURL: historyURL)
      print("[LLimit] App Group container resolved: \(snapshotURL.deletingLastPathComponent().path)")
    } catch {
      print("[LLimit] Failed to resolve App Group container: \(error.localizedDescription)")
      invalidateAppGroupStores()
    }
  }

  private func invalidateAppGroupStores() {
    cachedAppGroupSettingsStore = nil
    cachedAppGroupSnapshotStore = nil
    cachedAppGroupHistoryStore = nil
  }

  @discardableResult
  private func syncHistoryToWidgetStore(_ snapshot: QuotaSnapshot) -> Bool {
    for attempt in 1...2 {
      guard let appGroupStore = appGroupHistoryStore() else {
        print("[LLimit] History sync failed: no App Group history store available")
        invalidateAppGroupStores()
        continue
      }

      do {
        try appGroupStore.append(snapshot)
        return true
      } catch {
        print("[LLimit] History sync attempt \(attempt) failed: \(error.localizedDescription)")
        invalidateAppGroupStores()
      }
    }

    return false
  }

  /// Coalesces widget reloads. `saveConfiguration()` runs on every keystroke in Settings
  /// (each edit to a name/credential field), and WidgetKit budgets `reloadAllTimelines()`
  /// aggressively — hammering it during typing gets later, meaningful reloads dropped and
  /// leaves the widgets stuck on stale data. Debouncing means a burst of edits triggers a
  /// single reload once the user pauses.
  private func reloadWidgetTimelines() {
    widgetReloadTask?.cancel()
    widgetReloadTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 800_000_000)
      if Task.isCancelled { return }
      WidgetCenter.shared.reloadAllTimelines()
      self?.widgetReloadTask = nil
    }
  }
}
