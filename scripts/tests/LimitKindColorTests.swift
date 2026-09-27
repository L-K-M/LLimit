import AppKit
import SwiftUI
import QuotaCore

@main
private struct LimitKindColorTests {
  private struct Failure: Error, CustomStringConvertible {
    let description: String
  }

  private static var checksPassed = 0

  static func main() throws {
    let palette = LimitKindColors.default
    let customHex = "#369ACF"
    let expectedCustom = NSColor(srgbRed: 54.0 / 255, green: 154.0 / 255, blue: 207.0 / 255, alpha: 1)
    let metrics = [
      UsageMetric(id: "five_hour", label: "5-hour limit", remainingPercent: 80),
      UsageMetric(id: "seven_day", label: "Weekly limit", remainingPercent: 25),
      UsageMetric(id: "monthly_unlimited", label: "Monthly limit", isUnlimited: true)
    ]
    let slots = limitSeriesSlots(for: metrics)
    let primarySlot = primaryLimitSlot(for: metrics)
    guard primarySlot == slots[1] else {
      throw Failure(description: "The fixture must select the bounded weekly limit")
    }

    for step in 0..<accountColorVariantCount {
      let defaults = LimitKindColorScheme.colors(for: metrics, colors: palette, step: step)
      let custom = LimitKindColorScheme.colors(
        for: metrics, colors: palette, step: step, primaryHexColor: customHex)
      try assertColor(custom[1], equals: expectedCustom, "Custom weekly color must be exact at step \(step)")
      let trend = LimitKindColorScheme.color(
        for: slots[1], colors: palette, step: step, primarySlot: primarySlot, primaryHexColor: customHex)
      try assertColor(custom[1], equals: NSColor(trend), "Weekly ring and trend must match at step \(step)")
      try assertColor(custom[0], equals: NSColor(defaults[0]), "Session color must stay stepped at step \(step)")
      try assertColor(custom[2], equals: NSColor(defaults[2]), "Unlimited color must remain unchanged at step \(step)")

      for override in [nil, "invalid-color"] as [String?] {
        let fallback = LimitKindColorScheme.colors(
          for: metrics, colors: palette, step: step, primaryHexColor: override)
        for index in metrics.indices {
          try assertColor(fallback[index], equals: NSColor(defaults[index]),
                          "Missing or invalid override must keep metric \(index) unchanged at step \(step)")
        }
      }

      let weeklyAccent = LimitKindColorScheme.accountAccent(
        for: metrics, colors: palette, step: step, primaryHexColor: customHex)
      try assertColor(weeklyAccent, equals: expectedCustom, "Constrained weekly accent must use custom color at step \(step)")
      var sessionConstrained = metrics
      sessionConstrained[0].remainingPercent = 10
      let sessionAccent = LimitKindColorScheme.accountAccent(
        for: sessionConstrained, colors: palette, step: step, primaryHexColor: customHex)
      try assertColor(sessionAccent, equals: NSColor(defaults[0]), "Constrained session accent must keep its color at step \(step)")

      let menuBarAccent = LimitKindColorScheme.primaryAccountAccent(
        for: sessionConstrained, colors: palette, step: step, primaryHexColor: customHex)
      try assertColor(menuBarAccent, equals: expectedCustom,
                      "Menu bar must use the selected primary color even when the session is lower at step \(step)")
      let automaticMenuBarAccent = LimitKindColorScheme.primaryAccountAccent(
        for: sessionConstrained, colors: palette, step: step)
      try assertColor(automaticMenuBarAccent, equals: NSColor(defaults[1]),
                      "Automatic menu bar color must identify the primary window at step \(step)")
      var unavailablePrimary = sessionConstrained
      unavailablePrimary[1].remainingPercent = nil
      let unavailableAccent = LimitKindColorScheme.primaryAccountAccent(
        for: unavailablePrimary, colors: palette, step: step, primaryHexColor: customHex)
      try assertColor(unavailableAccent, equals: expectedCustom,
                      "Missing primary usage must not recolor the account at step \(step)")

      let unlimitedOnly = [metrics[2]]
      let unlimitedAccent = LimitKindColorScheme.accountAccent(
        for: unlimitedOnly, colors: palette, step: step, primaryHexColor: customHex)
      let defaultUnlimitedAccent = LimitKindColorScheme.accountAccent(for: unlimitedOnly, colors: palette, step: step)
      try assertColor(unlimitedAccent, equals: NSColor(defaultUnlimitedAccent), "Unlimited accent must ignore custom color at step \(step)")
      let unlimitedMenuBarAccent = LimitKindColorScheme.primaryAccountAccent(
        for: unlimitedOnly, colors: palette, step: step, primaryHexColor: customHex)
      try assertColor(unlimitedMenuBarAccent, equals: NSColor(defaultUnlimitedAccent),
                      "Unlimited menu bar accent must keep its reserved color at step \(step)")
    }

    print("Passed \(checksPassed) limit color integration checks.")
  }

  private static func assertColor(_ actual: Color, equals expected: NSColor, _ message: String) throws {
    guard let actual = NSColor(actual).usingColorSpace(.sRGB),
          let expected = expected.usingColorSpace(.sRGB) else {
      throw Failure(description: "\(message): could not resolve sRGB components")
    }
    let actualComponents = [actual.redComponent, actual.greenComponent, actual.blueComponent, actual.alphaComponent]
    let expectedComponents = [expected.redComponent, expected.greenComponent, expected.blueComponent, expected.alphaComponent]
    guard zip(actualComponents, expectedComponents).allSatisfy({ abs($0 - $1) < 0.00001 }) else {
      throw Failure(description: "\(message): got \(actualComponents), expected \(expectedComponents)")
    }
    checksPassed += 1
  }
}
