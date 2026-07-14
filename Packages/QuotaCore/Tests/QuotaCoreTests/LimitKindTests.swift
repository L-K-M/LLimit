import XCTest
@testable import QuotaCore

final class LimitKindTests: XCTestCase {
  // Every metric id/label pair the provider clients actually emit today.
  func testClassifyKnownProviderMetrics() {
    // Anthropic
    XCTAssertEqual(QuotaWindowKind.classify(metricID: "five_hour", label: "5-hour limit"), .session)
    XCTAssertEqual(QuotaWindowKind.classify(metricID: "seven_day", label: "Weekly limit"), .weekly)
    XCTAssertEqual(QuotaWindowKind.classify(metricID: "seven_day_opus", label: "Weekly (Opus)"), .weekly)

    // OpenAI windows are named from the reported window length in seconds.
    XCTAssertEqual(QuotaWindowKind.classify(metricID: "primary", label: "3-hour limit"), .session)
    XCTAssertEqual(QuotaWindowKind.classify(metricID: "primary", label: "5-hour limit"), .session)
    XCTAssertEqual(QuotaWindowKind.classify(metricID: "secondary", label: "7-day limit"), .weekly)
    XCTAssertEqual(QuotaWindowKind.classify(metricID: "secondary", label: "30-day limit"), .monthly)
    XCTAssertEqual(QuotaWindowKind.classify(metricID: "primary", label: "1-day limit"), .daily)
    XCTAssertEqual(QuotaWindowKind.classify(metricID: "primary", label: "24-hour limit"), .daily)

    // Copilot's premium pool resets monthly but never says so in text.
    XCTAssertEqual(QuotaWindowKind.classify(metricID: "premium", label: "Premium requests"), .monthly)

    // Zhipu / Z.ai
    XCTAssertEqual(QuotaWindowKind.classify(metricID: "tokens", label: "5-hour token limit"), .session)
    XCTAssertEqual(QuotaWindowKind.classify(metricID: "mcp", label: "MCP monthly quota"), .monthly)
    XCTAssertEqual(QuotaWindowKind.classify(metricID: "tokens", label: "Token limit"), .other)

    // Google Antigravity reports per-model quotas with no window wording.
    XCTAssertEqual(QuotaWindowKind.classify(metricID: "gemini-3-flash", label: "G3 Flash"), .other)
    XCTAssertEqual(QuotaWindowKind.classify(metricID: "gemini-3-pro-image", label: "G3 Image"), .other)
    XCTAssertEqual(QuotaWindowKind.classify(metricID: "claude-opus-4-5-thinking", label: "Claude"), .other)
  }

  func testClassifyWordFallbacksAndBoundaries() {
    XCTAssertEqual(QuotaWindowKind.classify(metricID: "x", label: "Daily quota"), .daily)
    XCTAssertEqual(QuotaWindowKind.classify(metricID: "x", label: "Session budget"), .session)
    XCTAssertEqual(QuotaWindowKind.classify(metricID: "x", label: "Per month"), .monthly)
    XCTAssertEqual(QuotaWindowKind.classify(metricID: "x", label: "13-day limit"), .weekly)
    XCTAssertEqual(QuotaWindowKind.classify(metricID: "x", label: "14-day limit"), .monthly)
    XCTAssertEqual(QuotaWindowKind.classify(metricID: "x", label: "90-day limit"), .monthly)
    XCTAssertEqual(QuotaWindowKind.classify(metricID: "x", label: "20-hour limit"), .daily)
    XCTAssertEqual(QuotaWindowKind.classify(metricID: "empty", label: "No quota data available"), .other)
  }

  func testLimitKindColorsDefaultsAndSanitization() {
    let defaults = LimitKindColors.default
    XCTAssertEqual(defaults.hexColor(for: .session), "#3ED8F0")
    XCTAssertEqual(defaults.hexColor(for: .weekly), "#FFC145")
    XCTAssertEqual(defaults.hexColor(for: .other, otherSlot: 0), "#B8A8FF")
    XCTAssertEqual(defaults.hexColor(for: .other, otherSlot: 1), "#F2734D")
    // Slots beyond the table cycle instead of crashing or going blank.
    XCTAssertEqual(defaults.hexColor(for: .other, otherSlot: 2), "#B8A8FF")

    let sanitized = LimitKindColors(
      sessionHexColor: "not-a-color",
      otherHexColors: ["also-bad"],
      unlimitedHexColor: ""
    )
    XCTAssertEqual(sanitized.sessionHexColor, LimitKindColors.defaultSessionHexColor)
    XCTAssertEqual(sanitized.otherHexColors, LimitKindColors.defaultOtherHexColors)
    XCTAssertEqual(sanitized.unlimitedHexColor, LimitKindColors.defaultUnlimitedHexColor)

    var custom = LimitKindColors.default
    custom.setHexColor("#123456", for: .weekly)
    custom.setHexColor("#654321", for: .other, otherSlot: 1)
    custom.setHexColor("garbage", for: .monthly)
    XCTAssertEqual(custom.weeklyHexColor, "#123456")
    XCTAssertEqual(custom.otherHexColors[1], "#654321")
    XCTAssertEqual(custom.monthlyHexColor, LimitKindColors.defaultMonthlyHexColor)
  }

  func testLimitSeriesSlotsAssignStableAuxiliarySlots() {
    let google = [
      UsageMetric(id: "gemini-3-pro-image", label: "G3 Image", remainingPercent: 80),
      UsageMetric(id: "gemini-3-flash", label: "G3 Flash", remainingPercent: 60),
      UsageMetric(id: "claude-opus-4-5-thinking", label: "Claude", remainingPercent: 40)
    ]

    let slots = limitSeriesSlots(for: google)
    XCTAssertEqual(slots.map(\.kind), [.other, .other, .other])
    XCTAssertEqual(slots.map(\.otherSlot), [0, 1, 2])

    let colors = LimitKindColors.default
    XCTAssertEqual(colors.hexColor(for: slots[0]), "#B8A8FF")
    XCTAssertEqual(colors.hexColor(for: slots[1]), "#F2734D")
    XCTAssertEqual(colors.hexColor(for: slots[2]), "#B8A8FF")
  }

  func testLimitSeriesSlotsSkipUnlimitedAndClassifiedMetrics() {
    // Copilot-shaped account: an unlimited chat metric must not consume an
    // auxiliary slot (it renders with the unlimited tint), and classified
    // kinds never take one.
    let metrics = [
      UsageMetric(id: "premium", label: "Premium requests", remainingPercent: 55),
      UsageMetric(id: "chat", label: "Chat messages", isUnlimited: true),
      UsageMetric(id: "custom", label: "Team pool", remainingPercent: 70)
    ]

    let slots = limitSeriesSlots(for: metrics)
    XCTAssertEqual(slots[0], LimitSeriesSlot(kind: .monthly))
    XCTAssertEqual(slots[1], LimitSeriesSlot(kind: .other, otherSlot: 0))
    XCTAssertEqual(slots[2], LimitSeriesSlot(kind: .other, otherSlot: 0))
  }

  func testAccountColorStepsAreMutuallyExclusiveAndStable() {
    let accounts = [
      ProviderAccount(id: "o2", provider: .openAI, displayName: "GPT B", isEnabled: true, credentials: [:]),
      ProviderAccount(id: "o1", provider: .openAI, displayName: "GPT A", isEnabled: true, credentials: [:]),
      ProviderAccount(id: "a1", provider: .anthropic, displayName: "Claude", isEnabled: false, credentials: [:])
    ]

    // Stable order: anthropic before openai, then display name. Steps follow it.
    XCTAssertEqual(accountColorStep(forAccountID: "a1", in: accounts), 0)
    XCTAssertEqual(accountColorStep(forAccountID: "o1", in: accounts), 1)
    XCTAssertEqual(accountColorStep(forAccountID: "o2", in: accounts), 2)

    // Disabling an account must not recolor the others: the rank counts ALL
    // accounts, so o1/o2 keep their steps whether a1 is enabled or not.
    let enabledClaude = accounts.map { account in
      var copy = account
      copy.isEnabled = true
      return copy
    }
    XCTAssertEqual(accountColorStep(forAccountID: "o1", in: enabledClaude), 1)
    XCTAssertEqual(accountColorStep(forAccountID: "o2", in: enabledClaude), 2)

    // A fourth account wraps to the base variant; unknown ids fall back to it.
    let four = accounts + [ProviderAccount(id: "z9", provider: .zai, displayName: "Z", isEnabled: true, credentials: [:])]
    XCTAssertEqual(accountColorStep(forAccountID: "z9", in: four), 0)
    XCTAssertEqual(accountColorStep(forAccountID: "missing", in: accounts), 0)

    // Legacy sole-account usages identify as the provider raw value.
    XCTAssertEqual(
      accountColorStep(forAccountID: QuotaProvider.anthropic.rawValue, in: accounts),
      accountColorStep(forAccountID: "a1", in: accounts)
    )
  }

  func testWidgetStyleSettingsDecodesWithoutLimitKindColors() throws {
    // Settings written by builds <= 17 have no limitKindColors key.
    let legacyJSON = Data("""
    {"ringColors":{"outerHighHexColor":"#34C759","outerMediumHexColor":"#FFCC00","outerLowHexColor":"#FF3B30","outerUnlimitedHexColor":"#0A84FF","innerHighHexColor":"#34C759","innerMediumHexColor":"#FFCC00","innerLowHexColor":"#FF3B30","innerUnlimitedHexColor":"#0A84FF"},"useTransparentBackground":false}
    """.utf8)

    let decoded = try JSONDecoder().decode(WidgetStyleSettings.self, from: legacyJSON)
    XCTAssertEqual(decoded.limitKindColors, .default)
  }

  func testWidgetStyleSettingsRoundTripsCustomLimitKindColors() throws {
    var style = WidgetStyleSettings()
    style.limitKindColors.setHexColor("#0011FF", for: .session)
    style.limitKindColors.setHexColor("#AA00BB", for: .other, otherSlot: 1)

    let encoded = try JSONEncoder().encode(style)
    let decoded = try JSONDecoder().decode(WidgetStyleSettings.self, from: encoded)

    XCTAssertEqual(decoded.limitKindColors.sessionHexColor, "#0011FF")
    XCTAssertEqual(decoded.limitKindColors.otherHexColors[1], "#AA00BB")
    XCTAssertEqual(decoded.limitKindColors.weeklyHexColor, LimitKindColors.defaultWeeklyHexColor)
  }
}
