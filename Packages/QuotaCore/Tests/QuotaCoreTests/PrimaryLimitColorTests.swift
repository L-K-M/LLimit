import XCTest
@testable import QuotaCore

final class PrimaryLimitColorTests: XCTestCase {
  func testPrimaryColorRoundTripsWithoutEnablingCustomStyle() throws {
    let style = ProviderStyleSettings(accountID: "first", provider: .openAI, primaryHexColor: " abc ")
    XCTAssertEqual(style.primaryHexColor, "#AABBCC")

    let decoded = try JSONDecoder().decode(ProviderStyleSettings.self, from: JSONEncoder().encode(style))
    XCTAssertEqual(decoded, style)
    XCTAssertFalse(decoded.useCustomStyle)
    XCTAssertEqual(decoded.style, .default)
  }

  func testMissingAndInvalidPrimaryColorsKeepAutomaticAppearance() throws {
    let inputs = [
      #"{"accountID":"first"}"#,
      #"{"accountID":"first","primaryHexColor":null}"#,
      #"{"accountID":"first","primaryHexColor":"not a color"}"#,
      #"{"accountID":"first","primaryHexColor":42}"#
    ]
    for input in inputs {
      let style = try JSONDecoder().decode(ProviderStyleSettings.self, from: Data(input.utf8))
      XCTAssertNil(style.primaryHexColor)
      XCTAssertFalse(style.useCustomStyle)
      let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(style)) as? [String: Any])
      XCTAssertNil(encoded["primaryHexColor"])
    }
    XCTAssertNil(ProviderStyleSettings(accountID: "first", primaryHexColor: "invalid").primaryHexColor)
    XCTAssertNil(ProviderStyleSettings.defaultValue(for: "first").primaryHexColor)
  }

  func testSettingsStorePersistsColorAndRedactionKeepsOnlyDisplayMetadata() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
    let account = ProviderAccount(id: "first", provider: .openAI, credentials: [CredentialField.openAIAccessToken: "private-token"])
    let settings = AppSettings(accounts: [account], providerStyleSettings: [
      ProviderStyleSettings(accountID: account.id, provider: .openAI, primaryHexColor: "#123456")
    ])
    try store.save(settings)
    let loaded = try store.load()
    XCTAssertEqual(loaded.primaryHexColor(for: account.id), "#123456")
    XCTAssertFalse(loaded.styleOverride(for: account.id).useCustomStyle)

    let redactedData = try JSONEncoder().encode(loaded.redactedCredentials())
    let redacted = try JSONDecoder().decode(AppSettings.self, from: redactedData)
    XCTAssertEqual(redacted.primaryHexColor(for: account.id), "#123456")
    XCTAssertTrue(redacted.accounts[0].credentials.isEmpty)
    XCTAssertFalse(String(decoding: redactedData, as: UTF8.self).contains("private-token"))
  }

  func testSiblingAccountDoesNotInheritExplicitPrimaryColor() throws {
    let accounts = [account("first"), account("second")]
    let settings = AppSettings(accounts: accounts, providerStyleSettings: [
      ProviderStyleSettings(accountID: "first", provider: .openAI, useCustomStyle: true,
                            style: WidgetStyleSettings(backgroundHexColor: "#654321"), primaryHexColor: "#123456")
    ])
    XCTAssertEqual(settings.primaryHexColor(for: "first"), "#123456")
    XCTAssertNil(settings.primaryHexColor(for: "second"))
    // Existing background migration remains unchanged.
    XCTAssertEqual(settings.styleOverride(for: "second").style.backgroundHexColor, "#654321")
    XCTAssertTrue(settings.styleOverride(for: "second").useCustomStyle)

    let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    XCTAssertEqual(decoded.primaryHexColor(for: "first"), "#123456")
    XCTAssertNil(decoded.primaryHexColor(for: "second"))
  }

  func testProviderKeyedLegacyStyleStillMigratesToAccounts() {
    let settings = AppSettings(accounts: [account("first"), account("second")], providerStyleSettings: [
      ProviderStyleSettings(accountID: QuotaProvider.openAI.rawValue, provider: .openAI, primaryHexColor: "#123456")
    ])
    XCTAssertEqual(settings.primaryHexColor(for: "first"), "#123456")
    XCTAssertEqual(settings.primaryHexColor(for: "second"), "#123456")
  }

  func testPrimaryColorResolvesOnlyUnambiguousLegacyAccountAliases() {
    let style = ProviderStyleSettings(accountID: "first", provider: .openAI, primaryHexColor: "#123456")
    let soleAccount = AppSettings(accounts: [account("first")], providerStyleSettings: [style])
    XCTAssertEqual(soleAccount.primaryHexColor(for: QuotaProvider.openAI.rawValue), "#123456")
    XCTAssertNil(soleAccount.primaryHexColor(for: "missing"))
    XCTAssertNil(soleAccount.primaryHexColor(for: QuotaProvider.anthropic.rawValue))

    var disabledSibling = account("second")
    disabledSibling.isEnabled = false
    let multipleAccounts = AppSettings(accounts: [account("first"), disabledSibling], providerStyleSettings: [style])
    XCTAssertNil(multipleAccounts.primaryHexColor(for: QuotaProvider.openAI.rawValue))
    XCTAssertEqual(multipleAccounts.primaryHexColor(for: "first"), "#123456")
  }

  func testExactAccountIDTakesPrecedenceOverLegacyAlias() {
    let providerID = QuotaProvider.openAI.rawValue
    let settings = AppSettings(accounts: [account(providerID), account("second")], providerStyleSettings: [
      ProviderStyleSettings(accountID: providerID, provider: .openAI, primaryHexColor: "#123456"),
      ProviderStyleSettings(accountID: "second", provider: .openAI, primaryHexColor: "#654321")
    ])
    XCTAssertEqual(settings.primaryHexColor(for: providerID), "#123456")
    XCTAssertEqual(settings.primaryHexColor(for: "second"), "#654321")

    let missingSiblingStyle = AppSettings(accounts: settings.accounts, providerStyleSettings: [settings.styleOverride(for: providerID)])
    XCTAssertNil(missingSiblingStyle.primaryHexColor(for: "second"))
  }

  func testPrimarySlotPrefersLongerWindowsRegardlessOfUsageAndOrder() {
    let metrics = [
      metric("five_hour", "5-hour limit", remaining: 1),
      metric("daily", "Daily quota", remaining: 2),
      metric("custom", "Model quota", remaining: 3),
      metric("seven_day", "Weekly limit", remaining: 4),
      metric("premium", "Premium requests", remaining: 95)
    ]
    XCTAssertEqual(primaryLimitSlot(for: metrics), LimitSeriesSlot(kind: .monthly))
    XCTAssertEqual(primaryLimitSlot(for: metrics.reversed()), LimitSeriesSlot(kind: .monthly))
    XCTAssertEqual(primaryLimitSlot(for: Array(metrics.dropLast())), LimitSeriesSlot(kind: .weekly))
    XCTAssertEqual(primaryLimitSlot(for: Array(metrics.prefix(3))), LimitSeriesSlot(kind: .other))
    XCTAssertEqual(primaryLimitSlot(for: Array(metrics.prefix(2))), LimitSeriesSlot(kind: .daily))
    XCTAssertEqual(primaryLimitSlot(for: Array(metrics.prefix(1))), LimitSeriesSlot(kind: .session))
  }

  func testTemporarilyMissingPercentageDoesNotMovePrimarySlot() {
    let metrics = [
      metric("primary", "5-hour limit", remaining: 30),
      metric("secondary", "7-day limit", remaining: nil)
    ]
    XCTAssertEqual(primaryLimitSlot(for: metrics), LimitSeriesSlot(kind: .weekly))
    XCTAssertEqual(primaryLimitSlot(for: [metric("secondary", "30-day limit", remaining: nil)]), LimitSeriesSlot(kind: .monthly))

    let resettingModel = UsageMetric(id: "model", label: "Model quota", resetAt: Date(timeIntervalSince1970: 1_800_000_000))
    XCTAssertEqual(primaryLimitSlot(for: [metric("daily", "Daily quota"), resettingModel]), LimitSeriesSlot(kind: .other))
  }

  func testNonQuotaDetailsDoNotTakePrimaryColorFromShortWindow() {
    let details = [
      UsageMetric(id: "empty", label: "No quota data available"),
      UsageMetric(id: "balance", label: "Extra usage balance", usedDisplay: "15"),
      UsageMetric(id: "count", label: "Requests", usedDisplay: "12")
    ]
    XCTAssertEqual(primaryLimitSlot(for: details + [metric("quota-daily", "Daily quota")]), LimitSeriesSlot(kind: .daily))
    XCTAssertNil(primaryLimitSlot(for: details))
  }

  func testWeekliesSharePrimarySlotWhileUnclassifiedLimitsKeepSeparateSlots() {
    let weeklies = [metric("seven_day", "Weekly limit"), metric("seven_day_opus", "Weekly (Opus)")]
    let primaryWeekly = primaryLimitSlot(for: weeklies)
    XCTAssertEqual(primaryWeekly, LimitSeriesSlot(kind: .weekly))
    XCTAssertTrue(limitSeriesSlots(for: weeklies).allSatisfy { $0 == primaryWeekly })

    let models = [metric("model-a", "Model A"), metric("model-b", "Model B"), metric("model-c", "Model C")]
    let primaryModel = primaryLimitSlot(for: models)
    XCTAssertEqual(primaryModel, LimitSeriesSlot(kind: .other, otherSlot: 0))
    XCTAssertEqual(limitSeriesSlots(for: models).filter { $0 == primaryModel }.count, 1)
  }

  func testUnlimitedMetricsNeverOwnOrConsumePrimarySlot() {
    let unlimitedMonthly = UsageMetric(id: "premium", label: "Premium requests", isUnlimited: true)
    let unlimitedOther = UsageMetric(id: "chat", label: "Chat", isUnlimited: true)
    XCTAssertEqual(primaryLimitSlot(for: [unlimitedMonthly, metric("weekly", "Weekly limit")]), LimitSeriesSlot(kind: .weekly))
    XCTAssertEqual(primaryLimitSlot(for: [unlimitedOther, metric("model", "Model quota")]), LimitSeriesSlot(kind: .other, otherSlot: 0))
    XCTAssertNil(primaryLimitSlot(for: [unlimitedMonthly, unlimitedOther]))
    XCTAssertNil(primaryLimitSlot(for: []))
  }

  private func account(_ id: String) -> ProviderAccount {
    ProviderAccount(id: id, provider: .openAI, credentials: [:])
  }

  private func metric(_ id: String, _ label: String, remaining: Int? = 50) -> UsageMetric {
    UsageMetric(id: id, label: label, remainingPercent: remaining)
  }
}
