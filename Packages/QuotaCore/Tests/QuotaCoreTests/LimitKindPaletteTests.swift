import XCTest
@testable import QuotaCore

final class LimitKindPaletteTests: XCTestCase {
  func testStandardPaletteIsTheDefaultColors() {
    XCTAssertEqual(LimitKindPalette.standard.colors, LimitKindColors.default)
  }

  func testEveryPaletteIsDistinct() {
    let colors = LimitKindPalette.allCases.map(\.colors)
    XCTAssertEqual(Set(colors).count, colors.count, "two palettes resolve to the same colors")
  }

  func testMatchingRoundTripsEveryPalette() {
    for palette in LimitKindPalette.allCases {
      XCTAssertEqual(palette.colors.palette, palette, "\(palette.rawValue) did not round-trip")
    }
  }

  func testCustomColorsMatchNoPalette() {
    var custom = LimitKindColors.default
    custom.sessionHexColor = "#123456"
    XCTAssertNil(custom.palette)
  }

  func testLowercasedHexStillResolvesToItsPalette() {
    // The public setters do not normalize, so a value written directly can differ
    // in case from the palette it visually matches; matching must see through it.
    // Flip the case unconditionally, so the test cannot pass vacuously if the
    // palette's literal is already lowercase.
    var recolored = LimitKindPalette.ocean.colors
    let original = recolored.dailyHexColor
    recolored.dailyHexColor = original == original.lowercased() ? original.uppercased() : original.lowercased()
    XCTAssertNotEqual(
      recolored.dailyHexColor, original,
      "Case flip was a no-op: dailyHexColor must contain letters (or the setter now normalizes case), so the palette assertion below would pass vacuously"
    )
    XCTAssertEqual(recolored.palette, .ocean)
  }

  func testThemedPalettesActuallyChangeTheHues() {
    // A typo'd hex would silently fall back to the standard color; assert each
    // non-standard palette moved every window off the default.
    for palette in LimitKindPalette.allCases where palette != .standard {
      let colors = palette.colors
      XCTAssertNotEqual(colors.sessionHexColor, LimitKindColors.defaultSessionHexColor, "\(palette.rawValue) session")
      XCTAssertNotEqual(colors.dailyHexColor, LimitKindColors.defaultDailyHexColor, "\(palette.rawValue) daily")
      XCTAssertNotEqual(colors.weeklyHexColor, LimitKindColors.defaultWeeklyHexColor, "\(palette.rawValue) weekly")
      XCTAssertNotEqual(colors.monthlyHexColor, LimitKindColors.defaultMonthlyHexColor, "\(palette.rawValue) monthly")
      XCTAssertNotEqual(colors.unlimitedHexColor, LimitKindColors.defaultUnlimitedHexColor, "\(palette.rawValue) unlimited")
      XCTAssertNotEqual(colors.otherHexColors, LimitKindColors.defaultOtherHexColors, "\(palette.rawValue) other")
    }
  }

  func testPalettesProvideBothAuxiliaryOtherColors() {
    for palette in LimitKindPalette.allCases {
      XCTAssertEqual(palette.colors.otherHexColors.count, 2, "\(palette.rawValue) needs two 'other' hues")
    }
  }
}
