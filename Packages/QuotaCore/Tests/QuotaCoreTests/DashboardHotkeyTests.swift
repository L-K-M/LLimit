import XCTest
@testable import QuotaCore
#if canImport(Carbon)
import Carbon.HIToolbox
#endif

final class DashboardHotkeyTests: XCTestCase {
  func testStoredRawValuesStayStable() {
    XCTAssertEqual(DashboardHotkey.allCases.map(\.rawValue), [
      "off",
      "control-option-command-l",
      "control-option-l",
      "control-option-shift-command-l"
    ])
    XCTAssertEqual(DashboardHotkey.defaultsKey, "DashboardHotkey")
  }

  func testMissingOrUnknownStoredValueMeansOff() {
    XCTAssertEqual(DashboardHotkey(storedValue: nil), .off)
    XCTAssertEqual(DashboardHotkey(storedValue: ""), .off)
    XCTAssertEqual(DashboardHotkey(storedValue: "option-command-l"), .off)
    XCTAssertEqual(DashboardHotkey(storedValue: "CONTROL-OPTION-L"), .off)
  }

  func testEveryStoredValueRoundTrips() {
    for hotkey in DashboardHotkey.allCases {
      XCTAssertEqual(DashboardHotkey(storedValue: hotkey.rawValue), hotkey)
    }
  }

  func testDisplayNamesUseMacModifierOrder() {
    XCTAssertEqual(DashboardHotkey.off.displayName, "Off")
    XCTAssertEqual(DashboardHotkey.controlOptionCommandL.displayName, "⌃⌥⌘L")
    XCTAssertEqual(DashboardHotkey.controlOptionL.displayName, "⌃⌥L")
    XCTAssertEqual(DashboardHotkey.controlOptionShiftCommandL.displayName, "⌃⌥⇧⌘L")
  }

  func testKeyCodeMatchesKeySymbol() {
    XCTAssertEqual(DashboardHotkey.keySymbol, "L")
    #if canImport(Carbon)
    XCTAssertEqual(DashboardHotkey.keyCode, UInt32(kVK_ANSI_L))
    #else
    // kVK_ANSI_L in HIToolbox's Events.h, which only Apple platforms have.
    XCTAssertEqual(DashboardHotkey.keyCode, 0x25)
    #endif
  }

  func testOnlyOffHasNoCombination() {
    XCTAssertNil(DashboardHotkey.off.modifiers)

    let combinations = DashboardHotkey.allCases.compactMap(\.modifiers)
    XCTAssertEqual(combinations.count, DashboardHotkey.allCases.count - 1)
    XCTAssertEqual(Set(combinations).count, combinations.count, "presets must not share a combination")
  }

  func testEveryPresetHoldsControlAndOption() {
    // A bare Command or Option-Command combination collides with app menu
    // shortcuts, such as Option-Command-L for Downloads in Finder and Safari.
    for modifiers in DashboardHotkey.allCases.compactMap(\.modifiers) {
      XCTAssertTrue(modifiers.isSuperset(of: [.control, .option]), "\(modifiers)")
    }
  }
}
