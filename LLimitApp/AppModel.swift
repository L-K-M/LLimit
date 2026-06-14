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
  /// Credentials detected on this Mac from local AI tools, offered as one-click imports.
  /// This is a convenience only — imported accounts are fully owned and stored by LLimit.
  @Published var detectedCredentials: [DiscoveredCredential] = []

  private let settingsStore: SettingsStore
  private let snapshotStore: SnapshotStore
  private let historyStore: QuotaHistoryStore
  private let refreshService: RefreshService
  private var cachedAppGroupSettingsStore: SettingsStore?
  private var cachedAppGroupSnapshotStore: SnapshotStore?
  private var cachedAppGroupHistoryStore: QuotaHistoryStore?
  private var autoRefreshTask: Task<Void, Never>?
  private var hasBootstrapped = false

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
    } catch {
      statusMessage = "Could not load snapshot: \(error.localizedDescription)"
    }

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
    } catch {
      settings = .default
      statusMessage = "Could not load settings. Using defaults."
    }

    refreshIntervalMinutes = max(15, settings.refreshIntervalMinutes)
    widgetStyle = settings.widgetStyle
    widgetBackgroundSettings = settings.widgetBackgroundSettings
    widgetVisibility = settings.widgetVisibility
    providerAccounts = settings.accounts
    providerStyleSettings = Dictionary(
      uniqueKeysWithValues: providerAccounts.map { account in
        (account.id, settings.styleOverride(for: account.id))
      }
    )
    reloadAccountStatuses()
  }

  func saveConfiguration(showSuccessMessage: Bool = false) {
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

    reloadAccountStatuses()

    let enabledConfigs = runtimeConfigurations().filter { configuration in
      configuration.isEnabled && configuration.provider.hasRequiredCredentials(configuration.credentials)
    }

    guard !enabledConfigs.isEmpty else {
      statusMessage = "No enabled provider accounts with complete credentials configured."
      return
    }

    do {
      let refreshed = try await refreshService.refresh(configurations: enabledConfigs)
      do {
        try historyStore.append(refreshed)
      } catch {
        print("[LLimit] Local history append failed: \(error.localizedDescription)")
      }

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
    } catch {
      statusMessage = "Refresh failed: \(error.localizedDescription)"
    }
  }

  func reloadAccountStatuses() {
    accountStatuses = providerAccounts.map { account in
      let missing = account.missingCredentialLabels
      let detail: String
      if missing.isEmpty {
        detail = account.isEnabled ? "Ready" : "Disabled"
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
    providerAccounts.removeAll { $0.id == accountID }
    providerStyleSettings.removeValue(forKey: accountID)
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
      }
    }
    #endif

    detectedCredentials = result.credentials
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
        self.updateAccount(accountID: accountID) { account in
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
        self.refreshIntervalMinutes = max(15, newValue)
        self.saveConfiguration()
        self.restartAutoRefreshLoop()
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

        self.widgetStyle = preset.style
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

  func widgetRingColorBinding(
    for role: WidgetRingColorRole,
    layer: WidgetRingLayer
  ) -> Binding<Color> {
    Binding(
      get: {
        let hex = self.widgetStyle.ringColors.hexColor(for: role, layer: layer)
        return Self.color(fromHex: hex)
      },
      set: { newValue in
        guard let hex = Self.hexColor(from: newValue, allowTransparency: false) else {
          return
        }

        self.widgetStyle.ringColors.setHexColor(hex, for: role, layer: layer)
        self.saveConfiguration()
      }
    )
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

    return WidgetStyleSettings(
      backgroundHexColor: providerStyle.style.backgroundHexColor ?? widgetStyle.backgroundHexColor,
      ringColors: providerStyle.style.ringColors,
      useTransparentBackground: providerStyle.style.useTransparentBackground
    )
  }

  func providerOverrideEnabledBinding(for accountID: String) -> Binding<Bool> {
    Binding(
      get: { self.providerStyle(for: accountID).useCustomStyle },
      set: { newValue in
        self.updateProviderStyle(for: accountID) { style in
          style.useCustomStyle = newValue
          if newValue {
            style.style = self.widgetStyle
          }
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

  func providerRingColorBinding(
    for accountID: String,
    role: WidgetRingColorRole,
    layer: WidgetRingLayer
  ) -> Binding<Color> {
    Binding(
      get: {
        let hex = self.providerStyle(for: accountID).style.ringColors.hexColor(for: role, layer: layer)
        return Self.color(fromHex: hex)
      },
      set: { newValue in
        guard let hex = Self.hexColor(from: newValue, allowTransparency: false) else {
          return
        }

        self.updateProviderStyle(for: accountID) { style in
          style.style.ringColors.setHexColor(hex, for: role, layer: layer)
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

    mutate(&providerAccounts[index])
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
    let existingCount = providerAccounts.filter { $0.provider == provider }.count
    if existingCount == 0 {
      return provider.displayName
    }
    return "\(provider.displayName) \(existingCount + 1)"
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
      widgetVisibility: widgetVisibility
    )
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
    let seconds = UInt64(max(15, refreshIntervalMinutes) * 60)
    return seconds * 1_000_000_000
  }

  private func shouldRefreshOnBootstrap(now: Date = Date()) -> Bool {
    guard !providerAccounts.isEmpty else {
      return false
    }

    guard let snapshot else {
      return true
    }

    let maxAgeSeconds = TimeInterval(max(15, refreshIntervalMinutes) * 60)
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

  private func reloadWidgetTimelines() {
    WidgetCenter.shared.reloadAllTimelines()
  }
}
