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
