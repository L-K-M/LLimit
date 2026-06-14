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
  @Published var accountStatuses: [ProviderAccountStatus] = []
  @Published var snapshot: QuotaSnapshot?
  @Published var statusMessage: String = ""
  @Published var isRefreshing = false
  @Published var launchAtLogin = false
  @Published var discoveryDiagnostics: [String] = []
  @Published var discoveredCredentials: [DiscoveredCredential] = []

  private let settingsStore: SettingsStore
  private let snapshotStore: SnapshotStore
  private let historyStore: QuotaHistoryStore
  private let refreshService: RefreshService
  /// Persisted per-source preferences (enabled / custom name), keyed by stable source ID.
  /// Credentials are NEVER persisted — they are re-discovered from local tools on each launch.
  private var savedPreferences: [String: ProviderAccount] = [:]
  private var cachedAppGroupSettingsStore: SettingsStore?
  private var cachedAppGroupSnapshotStore: SnapshotStore?
  private var cachedAppGroupHistoryStore: QuotaHistoryStore?
  private var autoRefreshTask: Task<Void, Never>?
  private var hasBootstrapped = false

  init() {
    let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let baseDirectory = appSupportDirectory.appendingPathComponent("LLimit", isDirectory: true)

    let settingsStore = SettingsStore(fileURL: baseDirectory.appendingPathComponent(SharedConstants.settingsFileName))
    let snapshotStore = SnapshotStore(fileURL: baseDirectory.appendingPathComponent(SharedConstants.snapshotFileName))
    let historyStore = QuotaHistoryStore(fileURL: baseDirectory.appendingPathComponent(SharedConstants.historyFileName))

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

  // MARK: - Lifecycle

  func bootstrap() async {
    guard !hasBootstrapped else { return }
    hasBootstrapped = true

    loadConfiguration()
    rescanSources(persist: false)

    do {
      snapshot = try snapshotStore.load()
    } catch {
      statusMessage = "Could not load saved snapshot: \(error.localizedDescription)"
    }

    restartAutoRefreshLoop()

    if shouldRefreshOnBootstrap() {
      await refreshNow()
    }
  }

  private func loadConfiguration() {
    let settings: AppSettings
    do {
      settings = try settingsStore.load()
    } catch {
      settings = .default
      statusMessage = "Could not load settings. Using defaults."
    }

    refreshIntervalMinutes = max(15, settings.refreshIntervalMinutes)
    widgetStyle = settings.widgetStyle
    widgetBackgroundSettings = settings.widgetBackgroundSettings
    widgetVisibility = settings.widgetVisibility
    savedPreferences = Dictionary(uniqueKeysWithValues: settings.accounts.map { ($0.id, $0) })
  }

  // MARK: - Credential discovery

  /// Re-scans local AI tools for credentials and rebuilds the account list, preserving
  /// the user's enabled/name preferences. This is the "no tokens to paste" core of LLimit.
  func rescanSources(persist: Bool = true) {
    let result = discoverCredentials()
    discoveryDiagnostics = result.diagnostics
    discoveredCredentials = result.credentials

    providerAccounts = result.credentials.map { discovered in
      let pref = savedPreferences[discovered.stableID]
      return ProviderAccount(
        id: discovered.stableID,
        provider: discovered.provider,
        displayName: pref?.displayName ?? discovered.suggestedName,
        isEnabled: pref?.isEnabled ?? true,
        credentials: discovered.credentials
      )
    }

    reloadAccountStatuses()

    if persist {
      saveConfiguration()
    }
  }

  private func discoverCredentials() -> CredentialDiscoveryResult {
    var result = CredentialDiscovery().discover()

    #if canImport(Security)
    // Claude Code stores its token in the macOS Keychain by default; fall back to it
    // when no file-based Claude credential was found.
    if !result.credentials.contains(where: { $0.provider == .anthropic }) {
      if let token = Self.readClaudeKeychainToken() {
        result.credentials.append(
          DiscoveredCredential(
            stableID: "anthropic:keychain",
            provider: .anthropic,
            suggestedName: "Claude",
            sourceLabel: "Claude Code (macOS Keychain)",
            credentials: [CredentialField.anthropicAccessToken: token]
          )
        )
        result.diagnostics.append("Claude Code: found OAuth token (macOS Keychain)")
      } else {
        result.diagnostics.append("Claude Code: no token found in ~/.claude or Keychain")
      }
    }
    #endif

    return result
  }

  #if canImport(Security)
  private static func readClaudeKeychainToken() -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "Claude Code-credentials",
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]

    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }

    let oauth = (object["claudeAiOauth"] as? [String: Any]) ?? object
    let token = (oauth["accessToken"] as? String) ?? (oauth["access_token"] as? String)
    let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (trimmed?.isEmpty == false) ? trimmed : nil
  }
  #endif

  // MARK: - Refresh

  func refreshNow() async {
    guard !isRefreshing else { return }

    isRefreshing = true
    defer { isRefreshing = false }

    let enabledConfigs = runtimeConfigurations().filter { configuration in
      configuration.isEnabled && configuration.provider.hasRequiredCredentials(configuration.credentials)
    }

    guard !enabledConfigs.isEmpty else {
      statusMessage = "No enabled sources detected. Sign in to a supported AI tool, then Rescan."
      return
    }

    do {
      let refreshed = try await refreshService.refresh(configurations: enabledConfigs)
      try? historyStore.append(refreshed)

      let widgetSynced = syncSnapshotToWidgetStore(refreshed)
      syncHistoryToWidgetStore(refreshed)
      if widgetSynced {
        reloadWidgetTimelines()
      }

      snapshot = refreshed
      statusMessage = "Refreshed \(refreshed.providers.count) source(s), \(refreshed.failures.count) failure(s)"
    } catch {
      statusMessage = "Refresh failed: \(error.localizedDescription)"
    }
  }

  func reloadAccountStatuses() {
    accountStatuses = providerAccounts.map { account in
      let missing = account.missingCredentialLabels
      let detail: String
      if !account.isEnabled {
        detail = "Disabled"
      } else if missing.isEmpty {
        detail = "Ready"
      } else {
        detail = "Missing: \(missing.joined(separator: ", "))"
      }

      return ProviderAccountStatus(
        accountID: account.id,
        provider: account.provider,
        available: missing.isEmpty,
        enabled: account.isEnabled,
        detail: detail
      )
    }
  }

  // MARK: - Account accessors

  func account(withID accountID: String) -> ProviderAccount? {
    providerAccounts.first(where: { $0.id == accountID })
  }

  func status(for accountID: String) -> ProviderAccountStatus? {
    accountStatuses.first(where: { $0.accountID == accountID })
  }

  func isAccountAvailable(_ accountID: String) -> Bool {
    status(for: accountID)?.available ?? false
  }

  func sourceLabel(for accountID: String) -> String {
    discoveredCredentials.first(where: { $0.stableID == accountID })?.sourceLabel ?? "Detected source"
  }

  func accountUsage(for accountID: String) -> ProviderUsage? {
    snapshot?.providers.first(where: { $0.accountID == accountID })
  }

  func accountFailure(for accountID: String) -> ProviderFailure? {
    snapshot?.failures.first(where: { $0.accountID == accountID })
  }

  func accountDisplayNameBinding(for accountID: String) -> Binding<String> {
    Binding(
      get: { self.account(withID: accountID)?.displayName ?? "" },
      set: { newValue in self.updateAccount(accountID: accountID) { $0.displayName = newValue } }
    )
  }

  func accountEnabledBinding(for accountID: String) -> Binding<Bool> {
    Binding(
      get: { self.account(withID: accountID)?.isEnabled ?? false },
      set: { newValue in self.updateAccount(accountID: accountID) { $0.isEnabled = newValue } }
    )
  }

  private func updateAccount(accountID: String, mutate: (inout ProviderAccount) -> Void) {
    guard let index = providerAccounts.firstIndex(where: { $0.id == accountID }) else { return }
    mutate(&providerAccounts[index])
    // Persist the preference (without credentials).
    savedPreferences[accountID] = providerAccounts[index].redactedCredentials()
    reloadAccountStatuses()
    saveConfiguration()
  }

  // MARK: - Launch at login

  func launchAtLoginBinding() -> Binding<Bool> {
    Binding(
      get: { self.launchAtLogin },
      set: { newValue in self.setLaunchAtLogin(newValue) }
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
        self.refreshIntervalMinutes = max(15, newValue)
        self.saveConfiguration()
        self.restartAutoRefreshLoop()
      }
    )
  }

  // MARK: - Widget visibility bindings

  func widgetVisibilityBinding(for keyPath: WritableKeyPath<WidgetVisibilitySettings, Bool>) -> Binding<Bool> {
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
        self.widgetVisibility[keyPath: keyPath] = min(max(newValue, range.lowerBound), range.upperBound)
        self.saveConfiguration()
      }
    )
  }

  // MARK: - Style bindings (global)

  var stylePresets: [WidgetStylePreset] { WidgetStylePreset.all }
  var customStylePresetID: String { WidgetStylePreset.customID }

  func widgetStylePresetBinding() -> Binding<String> {
    Binding(
      get: { WidgetStylePreset.id(for: self.widgetStyle) },
      set: { newValue in
        guard let preset = WidgetStylePreset.preset(withID: newValue) else { return }
        self.widgetStyle = preset.style
        self.saveConfiguration()
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

  func widgetRingColorBinding(for role: WidgetRingColorRole, layer: WidgetRingLayer) -> Binding<Color> {
    Binding(
      get: { Self.color(fromHex: self.widgetStyle.ringColors.hexColor(for: role, layer: layer)) },
      set: { newValue in
        guard let hex = Self.hexColor(from: newValue, allowTransparency: false) else { return }
        self.widgetStyle.ringColors.setHexColor(hex, for: role, layer: layer)
        self.saveConfiguration()
      }
    )
  }

  // MARK: - Persistence

  func saveConfiguration() {
    let settings = currentSettings()
    do {
      try settingsStore.save(settings)
    } catch {
      statusMessage = "Save failed: \(error.localizedDescription)"
    }

    if syncSettingsToWidgetStore(settings) {
      reloadWidgetTimelines()
    }
  }

  private func currentSettings() -> AppSettings {
    AppSettings(
      refreshIntervalMinutes: refreshIntervalMinutes,
      accounts: providerAccounts.map { $0.redactedCredentials() },
      widgetStyle: widgetStyle,
      widgetBackgroundSettings: widgetBackgroundSettings,
      providerStyleSettings: [],
      widgetVisibility: widgetVisibility
    )
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

  // MARK: - Auto refresh loop

  private func restartAutoRefreshLoop() {
    autoRefreshTask?.cancel()
    autoRefreshTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        let nanoseconds = UInt64(max(15, self.refreshIntervalMinutes) * 60) * 1_000_000_000
        do {
          try await Task.sleep(nanoseconds: nanoseconds)
        } catch {
          return
        }
        if Task.isCancelled { return }
        // Re-scan in case the user logged into a new tool, then refresh.
        self.rescanSources(persist: false)
        await self.refreshNow()
      }
    }
  }

  private func shouldRefreshOnBootstrap(now: Date = Date()) -> Bool {
    guard !providerAccounts.isEmpty else { return false }
    guard let snapshot else { return true }
    let maxAge = TimeInterval(max(15, refreshIntervalMinutes) * 60)
    return now.timeIntervalSince(snapshot.generatedAt) >= maxAge
  }

  // MARK: - App Group sync

  @discardableResult
  private func syncSettingsToWidgetStore(_ settings: AppSettings) -> Bool {
    guard let store = appGroupSettingsStore() else { return false }
    do {
      try store.save(settings)
      return true
    } catch {
      invalidateAppGroupStores()
      return false
    }
  }

  @discardableResult
  private func syncSnapshotToWidgetStore(_ snapshot: QuotaSnapshot) -> Bool {
    guard let store = appGroupSnapshotStore() else { return false }
    do {
      try store.save(snapshot)
      return true
    } catch {
      invalidateAppGroupStores()
      return false
    }
  }

  @discardableResult
  private func syncHistoryToWidgetStore(_ snapshot: QuotaSnapshot) -> Bool {
    guard let store = appGroupHistoryStore() else { return false }
    do {
      try store.append(snapshot)
      return true
    } catch {
      invalidateAppGroupStores()
      return false
    }
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
    guard cachedAppGroupSettingsStore == nil
      || cachedAppGroupSnapshotStore == nil
      || cachedAppGroupHistoryStore == nil
    else { return }

    do {
      cachedAppGroupSettingsStore = SettingsStore(fileURL: try SharedPaths.settingsFileURL())
      cachedAppGroupSnapshotStore = SnapshotStore(
        fileURL: try SharedPaths.snapshotFileURL(),
        appGroupIdentifier: SharedConstants.appGroupIdentifier
      )
      cachedAppGroupHistoryStore = QuotaHistoryStore(fileURL: try SharedPaths.historyFileURL())
    } catch {
      invalidateAppGroupStores()
    }
  }

  private func invalidateAppGroupStores() {
    cachedAppGroupSettingsStore = nil
    cachedAppGroupSnapshotStore = nil
    cachedAppGroupHistoryStore = nil
  }

  private func reloadWidgetTimelines() {
    WidgetCenter.shared.reloadAllTimelines()
  }

  // MARK: - Color helpers

  private static func color(fromHex hex: String?) -> Color {
    guard let components = parseHexColor(hex) else { return .clear }
    return Color(red: components.red, green: components.green, blue: components.blue, opacity: components.alpha)
  }

  private static func hexColor(from color: Color, allowTransparency: Bool) -> String? {
    guard let components = rgbaComponents(from: color) else { return nil }
    if allowTransparency && components.alpha <= 0.01 { return nil }

    let red = clampColorByte(components.red)
    let green = clampColorByte(components.green)
    let blue = clampColorByte(components.blue)

    if allowTransparency {
      return String(format: "#%02X%02X%02X%02X", red, green, blue, clampColorByte(components.alpha))
    }
    return String(format: "#%02X%02X%02X", red, green, blue)
  }

  private static func rgbaComponents(from color: Color) -> (red: Double, green: Double, blue: Double, alpha: Double)? {
    let nsColor = NSColor(color)
    guard let converted = nsColor.usingColorSpace(.extendedSRGB) ?? nsColor.usingColorSpace(.sRGB) else { return nil }
    return (
      red: Double(converted.redComponent),
      green: Double(converted.greenComponent),
      blue: Double(converted.blueComponent),
      alpha: Double(converted.alphaComponent)
    )
  }

  private static func parseHexColor(_ value: String?) -> (red: Double, green: Double, blue: Double, alpha: Double)? {
    guard var raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
    if raw.hasPrefix("#") { raw.removeFirst() }
    if raw.count == 3 || raw.count == 4 { raw = raw.map { "\($0)\($0)" }.joined() }
    guard raw.count == 6 || raw.count == 8, let parsed = UInt64(raw, radix: 16) else { return nil }

    if raw.count == 6 {
      return (
        red: Double((parsed >> 16) & 0xFF) / 255.0,
        green: Double((parsed >> 8) & 0xFF) / 255.0,
        blue: Double(parsed & 0xFF) / 255.0,
        alpha: 1
      )
    }
    return (
      red: Double((parsed >> 24) & 0xFF) / 255.0,
      green: Double((parsed >> 16) & 0xFF) / 255.0,
      blue: Double((parsed >> 8) & 0xFF) / 255.0,
      alpha: Double(parsed & 0xFF) / 255.0
    )
  }

  private static func clampColorByte(_ value: Double) -> Int {
    Int((max(0, min(1, value)) * 255.0).rounded())
  }
}
