import XCTest
@testable import QuotaCore

final class StoreRoundTripTests: XCTestCase {
  func testSnapshotStoreRoundTrip() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fileURL = tempDir.appendingPathComponent("snapshot.json")
    let store = SnapshotStore(fileURL: fileURL)

    let snapshot = QuotaSnapshot(
      generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      providers: [
        ProviderUsage(
          provider: .openAI,
          title: "OpenAI",
          subtitle: "plus",
          metrics: [UsageMetric(id: "primary", label: "3-hour limit", remainingPercent: 70)],
          maxUsagePercent: 30,
          fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
      ],
      failures: []
    )

    try store.save(snapshot)
    let loaded = try store.load()

    XCTAssertEqual(loaded?.providers.first?.provider, .openAI)
    XCTAssertEqual(loaded?.providers.first?.metrics.first?.remainingPercent, 70)
  }

  func testSettingsStoreDefaultsWhenMissing() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fileURL = tempDir.appendingPathComponent("settings.json")
    let store = SettingsStore(fileURL: fileURL)

    let settings = try store.load()
    XCTAssertEqual(settings.refreshIntervalMinutes, 30)
    XCTAssertTrue(settings.accounts.isEmpty)
    XCTAssertFalse(settings.widgetStyle.useTransparentBackground)
    XCTAssertFalse(settings.widgetBackgroundSettings.dashboard.useCustomBackground)
    XCTAssertFalse(settings.widgetBackgroundSettings.trend.useCustomBackground)
    XCTAssertTrue(settings.widgetVisibility.showTimestamp)
    XCTAssertTrue(settings.widgetVisibility.showFailureCount)
    XCTAssertTrue(settings.widgetVisibility.showResetInfo)
    XCTAssertTrue(settings.widgetVisibility.showOverviewMetricSummary)
    XCTAssertTrue(settings.widgetVisibility.showPercentageValues)
    XCTAssertTrue(settings.widgetVisibility.showDualLimitPercentagesInDashboard)
    XCTAssertTrue(settings.widgetVisibility.showMediumProgressBars)
    XCTAssertEqual(settings.widgetVisibility.smallDashboardProviderLimit, 2)
    XCTAssertEqual(settings.widgetVisibility.mediumProviderLimit, 6)
    XCTAssertEqual(settings.widgetVisibility.trendHistoryDays, 7)
  }

  func testSettingsStoreRoundTripPersistsWidgetVisibility() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fileURL = tempDir.appendingPathComponent("settings.json")
    let store = SettingsStore(fileURL: fileURL)

    let settings = AppSettings(
      refreshIntervalMinutes: 45,
      accounts: [
        ProviderAccount(
          id: "openai-primary",
          provider: .openAI,
          displayName: "OpenAI Primary",
          isEnabled: true,
          credentials: [CredentialField.openAIAccessToken: "token"]
        )
      ],
      widgetStyle: WidgetStyleSettings(useTransparentBackground: true),
      widgetBackgroundSettings: WidgetBackgroundSettings(
        dashboard: WidgetBackgroundOverride(
          useCustomBackground: true,
          backgroundHexColor: "#223344",
          useTransparentBackground: false
        ),
        trend: WidgetBackgroundOverride(
          useCustomBackground: true,
          backgroundHexColor: "#445566",
          useTransparentBackground: true
        )
      ),
      providerStyleSettings: [ProviderStyleSettings.defaultValue(for: "openai-primary", provider: .openAI)],
      widgetVisibility: WidgetVisibilitySettings(
        showTimestamp: false,
        showFailureCount: true,
        showResetInfo: false,
        showOverviewMetricSummary: true,
        showPercentageValues: false,
        showDualLimitPercentagesInDashboard: false,
        showMediumProgressBars: false,
        smallDashboardProviderLimit: 3,
        mediumProviderLimit: 4,
        trendHistoryDays: 14
      )
    )

    try store.save(settings)
    let loaded = try store.load()

    XCTAssertTrue(loaded.widgetStyle.useTransparentBackground)
    XCTAssertEqual(loaded.accounts.count, 1)
    XCTAssertEqual(loaded.accounts.first?.id, "openai-primary")
    XCTAssertEqual(loaded.accounts.first?.credentials[CredentialField.openAIAccessToken], "token")
    XCTAssertTrue(loaded.widgetBackgroundSettings.dashboard.useCustomBackground)
    XCTAssertEqual(loaded.widgetBackgroundSettings.dashboard.backgroundHexColor, "#223344")
    XCTAssertFalse(loaded.widgetBackgroundSettings.dashboard.useTransparentBackground)
    XCTAssertTrue(loaded.widgetBackgroundSettings.trend.useCustomBackground)
    XCTAssertEqual(loaded.widgetBackgroundSettings.trend.backgroundHexColor, "#445566")
    XCTAssertTrue(loaded.widgetBackgroundSettings.trend.useTransparentBackground)
    XCTAssertFalse(loaded.widgetVisibility.showTimestamp)
    XCTAssertTrue(loaded.widgetVisibility.showFailureCount)
    XCTAssertFalse(loaded.widgetVisibility.showResetInfo)
    XCTAssertTrue(loaded.widgetVisibility.showOverviewMetricSummary)
    XCTAssertFalse(loaded.widgetVisibility.showPercentageValues)
    XCTAssertFalse(loaded.widgetVisibility.showDualLimitPercentagesInDashboard)
    XCTAssertFalse(loaded.widgetVisibility.showMediumProgressBars)
    XCTAssertEqual(loaded.widgetVisibility.smallDashboardProviderLimit, 3)
    XCTAssertEqual(loaded.widgetVisibility.mediumProviderLimit, 4)
    XCTAssertEqual(loaded.widgetVisibility.trendHistoryDays, 14)
  }

  func testRefreshIntervalIsClampedAtModelAndDecodeBoundaries() throws {
    XCTAssertEqual(AppSettings(refreshIntervalMinutes: 0).refreshIntervalMinutes, 15)
    XCTAssertEqual(AppSettings(refreshIntervalMinutes: 10_000).refreshIntervalMinutes, 180)

    let tooSmall = try JSONDecoder().decode(
      AppSettings.self,
      from: Data("{ \"refreshIntervalMinutes\": -1 }".utf8)
    )
    let tooLarge = try JSONDecoder().decode(
      AppSettings.self,
      from: Data("{ \"refreshIntervalMinutes\": 9223372036854775807 }".utf8)
    )

    XCTAssertEqual(tooSmall.refreshIntervalMinutes, 15)
    XCTAssertEqual(tooLarge.refreshIntervalMinutes, 180)
  }

  func testQuotaHistoryStoreRoundTripAndRetention() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fileURL = tempDir.appendingPathComponent("history.json")
    let store = QuotaHistoryStore(fileURL: fileURL)

    let dayStart = Date(timeIntervalSince1970: 1_700_000_000)
    let oldSnapshot = QuotaSnapshot(generatedAt: dayStart, providers: [], failures: [])
    let newSnapshot = QuotaSnapshot(generatedAt: dayStart.addingTimeInterval(3 * 86_400), providers: [], failures: [])

    try store.save([oldSnapshot])
    try store.append(newSnapshot, keepDays: 2, maxEntries: 10)

    let loaded = try store.load()
    XCTAssertEqual(loaded.count, 1)
    XCTAssertEqual(loaded.first?.generatedAt, newSnapshot.generatedAt)
  }
}
