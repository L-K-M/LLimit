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
    let flipped = original == original.lowercased() ? original.uppercased() : original.lowercased()
    XCTAssertNotEqual(
      flipped, original,
      "Precondition broken: dailyHexColor must contain letters, otherwise the case flip is a no-op and this test cannot be meaningful"
    )
    recolored.dailyHexColor = flipped
    XCTAssertEqual(recolored.dailyHexColor, flipped, "the setter must not normalize case")
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

  // Normal-vision Lab/contrast guard. The Python validator additionally checks
  // Machado CVD and OKLCH chroma against the actual Swift literals and formula.

  private func rgb(_ hex: String) -> (Double, Double, Double) {
    var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.hasPrefix("#") { raw.removeFirst() }
    let v = UInt64(raw, radix: 16) ?? 0
    return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
  }

  private func linear(_ c: Double) -> Double {
    c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
  }

  private func lab(_ hex: String) -> (Double, Double, Double) {
    let (r, g, b) = rgb(hex)
    let rl = linear(r), gl = linear(g), bl = linear(b)
    let x = rl * 0.4124564 + gl * 0.3575761 + bl * 0.1804375
    let y = rl * 0.2126729 + gl * 0.7151522 + bl * 0.0721750
    let z = rl * 0.0193339 + gl * 0.1191920 + bl * 0.9503041
    func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3.0) : 7.787 * t + 16 / 116 }
    return (116 * f(y) - 16, 500 * (f(x / 0.95047) - f(y)), 200 * (f(y) - f(z / 1.08883)))
  }

  private func deltaE(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
    sqrt(pow(a.0 - b.0, 2) + pow(a.1 - b.1, 2) + pow(a.2 - b.2, 2))
  }

  private func luminance(_ hex: String) -> Double {
    let (r, g, b) = rgb(hex)
    return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
  }

  private func contrast(_ a: String, _ b: String) -> Double {
    let l1 = luminance(a), l2 = luminance(b)
    return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
  }

  private func deep(_ hex: String) -> String {
    let (r, g, b) = rgb(hex)
    let f = 0.36
    var dr = r * (1 - f) + 0.02 * f
    var dg = g * (1 - f) + 0.03 * f
    var db = b * (1 - f) + 0.06 * f
    let mean = (dr + dg + db) / 3
    func spread(_ v: Double) -> Double { max(0, min(1, mean + (v - mean) * 1.5)) }
    dr = spread(dr); dg = spread(dg); db = spread(db)
    return String(format: "#%02X%02X%02X", Int((dr * 255).rounded()), Int((dg * 255).rounded()), Int((db * 255).rounded()))
  }

  private func baseHexes(_ colors: LimitKindColors) -> [String] {
    [colors.sessionHexColor, colors.dailyHexColor, colors.weeklyHexColor, colors.monthlyHexColor] + colors.otherHexColors
  }

  func testPalettesMeetLabSeparationAndGraphiteContrast() {
    let graphite = "#1D1F27"
    for palette in LimitKindPalette.allCases {
      let base = baseHexes(palette.colors)
      XCTAssertEqual(base.count, 6, "\(palette.rawValue) needs six base hues")
      let labs = base.map(lab)
      var minBase = Double.greatestFiniteMagnitude
      for i in 0..<6 {
        for j in (i + 1)..<6 {
          minBase = min(minBase, deltaE(labs[i], labs[j]))
        }
      }
      XCTAssertGreaterThanOrEqual(minBase, 12, "\(palette.rawValue) base all-pairs dE \(minBase) < 12")

      let deepHexes = base.map(deep)
      let allLabs = (base + deepHexes).map(lab)
      var min12 = Double.greatestFiniteMagnitude
      for i in 0..<12 {
        for j in (i + 1)..<12 {
          min12 = min(min12, deltaE(allLabs[i], allLabs[j]))
        }
      }
      XCTAssertGreaterThanOrEqual(min12, 8, "\(palette.rawValue) base+deep dE \(min12) < 8")

      for hex in base + deepHexes {
        XCTAssertGreaterThanOrEqual(
          contrast(hex, graphite), 3.0,
          "\(palette.rawValue) \(hex) contrast on graphite below 3:1"
        )
      }
    }
  }
}
