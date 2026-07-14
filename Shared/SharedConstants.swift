import Foundation
import Security
import QuotaCore

enum SharedConstants {
  static let appGroupSuffix = "group.ch.lkmc.llimit"
  static let fallbackAppGroupIdentifier = appGroupSuffix
  static let appGroupIdentifier = AppGroupIdentifierResolver.current
  static let snapshotFileName = "quota-snapshot.json"
  static let historyFileName = "quota-history.json"
  static let settingsFileName = "quota-settings.json"
  static let widgetKind = "LLimitWidget"
  static let trendWidgetKind = "ch.lkmc.llimit.widget.trend"
  // One kind per provider-tile slot; the account for each slot is assigned in the
  // app's settings, never via the widget Edit flow. Kinds are frozen once placed.
  // Spelled out as literals (not interpolated) so the full strings exist as bytes
  // in the compiled extension — scripts/build.sh greps the binary for them.
  static let providerSlotWidgetKinds: [String] = {
    let kinds = [
      "ch.lkmc.llimit.widget.provider-tile.slot1",
      "ch.lkmc.llimit.widget.provider-tile.slot2",
      "ch.lkmc.llimit.widget.provider-tile.slot3",
      "ch.lkmc.llimit.widget.provider-tile.slot4",
      "ch.lkmc.llimit.widget.provider-tile.slot5",
      "ch.lkmc.llimit.widget.provider-tile.slot6",
      "ch.lkmc.llimit.widget.provider-tile.slot7",
      "ch.lkmc.llimit.widget.provider-tile.slot8"
    ]
    assert(kinds.count == AppSettings.providerTileSlotCount)
    return kinds
  }()

  static let allWidgetKinds: [String] = [
    widgetKind,
    trendWidgetKind
  ] + providerSlotWidgetKinds
}

private enum AppGroupIdentifierResolver {
  static let current: String = {
    if let configuredGroup = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
      !configuredGroup.isEmpty,
      !configuredGroup.contains("$(")
    {
      return configuredGroup
    }

    if let group = entitlementAppGroupIdentifier() {
      return group
    }

    if let teamIdentifier = entitlementTeamIdentifier() {
      return "\(teamIdentifier).\(SharedConstants.appGroupSuffix)"
    }

    return SharedConstants.fallbackAppGroupIdentifier
  }()

  private static func entitlementAppGroupIdentifier() -> String? {
    guard let task = SecTaskCreateFromSelf(nil) else {
      return nil
    }

    guard let value = SecTaskCopyValueForEntitlement(
      task,
      "com.apple.security.application-groups" as CFString,
      nil
    ) else {
      return nil
    }

    let groups = value as? [String] ?? []
    return groups.first(where: {
      !$0.isEmpty && !$0.contains("$(")
    })
  }

  private static func entitlementTeamIdentifier() -> String? {
    guard let task = SecTaskCreateFromSelf(nil) else {
      return nil
    }

    if let team = SecTaskCopyValueForEntitlement(
      task,
      "com.apple.developer.team-identifier" as CFString,
      nil
    ) as? String,
      !team.isEmpty
    {
      return team
    }

    if let appID = SecTaskCopyValueForEntitlement(
      task,
      "application-identifier" as CFString,
      nil
    ) as? String,
      !appID.isEmpty,
      let team = appID.split(separator: ".", maxSplits: 1).first,
      !team.isEmpty
    {
      return String(team)
    }

    return nil
  }
}

enum SharedPaths {
  static func appGroupDirectory() throws -> URL {
    guard let containerURL = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: SharedConstants.appGroupIdentifier
    ) else {
      throw NSError(
        domain: "LLimit",
        code: 1001,
        userInfo: [NSLocalizedDescriptionKey: "Unable to resolve App Group container."]
      )
    }
    return containerURL
  }

  static func snapshotFileURL() throws -> URL {
    try appGroupDirectory().appendingPathComponent(SharedConstants.snapshotFileName)
  }

  static func historyFileURL() throws -> URL {
    try appGroupDirectory().appendingPathComponent(SharedConstants.historyFileName)
  }

  static func settingsFileURL() throws -> URL {
    try appGroupDirectory().appendingPathComponent(SharedConstants.settingsFileName)
  }
}
