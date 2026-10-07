import Foundation
// CGRect's geometry members and Equatable come from CoreGraphics on Apple
// platforms; Foundation provides them on Linux.
#if canImport(CoreGraphics)
import CoreGraphics
#endif

@main
private struct MenuBarPanelGeometryTests {
  private struct Failure: Error, CustomStringConvertible {
    let description: String
  }

  // A 1512x945 laptop screen below a 33pt menu bar; the panel hangs from the
  // menu bar under a status item.
  private static let visibleFrame = CGRect(x: 0, y: 0, width: 1512, height: 912)
  private static let panelFrame = CGRect(x: 900, y: 302, width: 420, height: 610)
  private static let panelSize = CGSize(width: 420, height: 610)

  private static var checksPassed = 0

  static func main() throws {
    try trailingGripPinsTheTopLeadingCorner()
    try leadingGripPinsTheTopTrailingCorner()
    try shrinkingStopsAtTheMinimumSize()
    try growingStopsAtTheVisibleScreenEdge()
    try overflowingPanelIsNotYankedOnTheFirstMove()
    try rememberedSizeFitsTheVisibleScreen()
    try overviewRowsLeaveCaptionWidth()
    print("Menu bar panel geometry checks passed: \(checksPassed)")
  }

  private static func trailingGripPinsTheTopLeadingCorner() throws {
    // Pointer moves right 40 and down 50 (screen y grows upward).
    let resized = drag(corner: .bottomTrailing, pointerDelta: CGSize(width: 40, height: -50))

    try expect(resized.frame, equals: CGRect(x: 900, y: 252, width: 460, height: 660), "Trailing grip frame")
    try expect(resized.size, equals: CGSize(width: 460, height: 660), "Trailing grip size")
    try expect(resized.frame.maxY, equals: panelFrame.maxY, "Top edge stays under the menu bar")
  }

  private static func leadingGripPinsTheTopTrailingCorner() throws {
    // Pointer moves left 100: the leading edge follows, the trailing edge stays.
    let resized = drag(corner: .bottomLeading, pointerDelta: CGSize(width: -100, height: 0))

    try expect(resized.frame, equals: CGRect(x: 800, y: 302, width: 520, height: 610), "Leading grip frame")
    try expect(resized.frame.maxX, equals: panelFrame.maxX, "Trailing edge stays put")
    try expect(resized.size, equals: CGSize(width: 520, height: 610), "Leading grip size")
  }

  private static func shrinkingStopsAtTheMinimumSize() throws {
    let resized = drag(corner: .bottomTrailing, pointerDelta: CGSize(width: -500, height: 500))

    try expect(
      resized.size,
      equals: CGSize(width: MenuBarPanelSize.minimumWidth, height: MenuBarPanelSize.minimumHeight),
      "Minimum size"
    )
    try expect(resized.frame.maxY, equals: panelFrame.maxY, "Top edge stays under the menu bar while shrinking")
  }

  private static func growingStopsAtTheVisibleScreenEdge() throws {
    let resized = drag(corner: .bottomTrailing, pointerDelta: CGSize(width: 1000, height: -1000))
    let margin = MenuBarPanelSize.screenMargin

    try expect(resized.frame.maxX, equals: visibleFrame.maxX - margin, "Trailing growth stops at the screen edge")
    try expect(resized.frame.minY, equals: visibleFrame.minY + margin, "Downward growth stops at the screen edge")
  }

  private static func overflowingPanelIsNotYankedOnTheFirstMove() throws {
    // Against the trailing screen edge, only the leading grip can widen.
    let flush = CGRect(x: 1092, y: 302, width: 420, height: 610)
    let still = MenuBarPanelSize.resize(
      frame: flush, size: panelSize, corner: .bottomTrailing,
      pointerDelta: .zero, visibleFrame: visibleFrame
    )
    try expect(still.frame, equals: flush, "No movement keeps an overflowing panel in place")

    let blocked = MenuBarPanelSize.resize(
      frame: flush, size: panelSize, corner: .bottomTrailing,
      pointerDelta: CGSize(width: 30, height: 0), visibleFrame: visibleFrame
    )
    try expect(blocked.frame, equals: flush, "Trailing grip cannot widen past the screen edge")

    let widened = MenuBarPanelSize.resize(
      frame: flush, size: panelSize, corner: .bottomLeading,
      pointerDelta: CGSize(width: -30, height: 0), visibleFrame: visibleFrame
    )
    try expect(widened.frame, equals: CGRect(x: 1062, y: 302, width: 450, height: 610), "Leading grip widens")
  }

  private static func rememberedSizeFitsTheVisibleScreen() throws {
    let margin = MenuBarPanelSize.screenMargin
    let large = CGSize(width: 2400, height: 1400)

    try expect(
      MenuBarPanelSize.fitted(large, within: visibleFrame.size),
      equals: CGSize(width: visibleFrame.width - margin * 2, height: visibleFrame.height - margin),
      "Large remembered size fits the screen"
    )
    try expect(
      MenuBarPanelSize.fitted(CGSize(width: 100, height: 100), within: visibleFrame.size),
      equals: CGSize(width: MenuBarPanelSize.minimumWidth, height: MenuBarPanelSize.minimumHeight),
      "Small remembered size grows to the minimum"
    )
    try expect(MenuBarPanelSize.fitted(large, within: nil), equals: large, "Unknown screen keeps the size")
  }

  private static func drag(corner: MenuBarPanelCorner, pointerDelta: CGSize) -> MenuBarPanelSize.Resize {
    MenuBarPanelSize.resize(
      frame: panelFrame,
      size: panelSize,
      corner: corner,
      pointerDelta: pointerDelta,
      visibleFrame: visibleFrame
    )
  }

  private static func overviewRowsLeaveCaptionWidth() throws {
    for panelWidth in [360, 390, 420, 700, 970] as [CGFloat] {
      let width = panelWidth - 2 * (OverviewGaugeLayout.dashboardPadding + OverviewGaugeLayout.cardPadding)
      for count in 1...13 {
        let rows = OverviewGaugeLayout.rows(count: count, width: width)
        let cellWidth = OverviewGaugeLayout.cellWidth(columns: rows[0], width: width)
        try expect(rows.reduce(0, +), equals: count, "Every gauge appears")
        try expect((rows.max() ?? 0) - (rows.min() ?? 0) <= 1, equals: true, "Balanced rows")
        try expect(cellWidth >= 104, equals: true, "Caption width at \(panelWidth)pt for \(count) accounts")
      }
    }
    try expect(OverviewGaugeLayout.rows(count: 0, width: 370), equals: [], "Empty board")
    try expect(OverviewGaugeLayout.rows(count: 13, width: .infinity), equals: [13], "Ideal width")
    try expect(OverviewGaugeLayout.rows(count: 3, width: 0), equals: [1, 1, 1], "Zero width")
  }

  private static func expect<Value: Equatable>(_ actual: Value, equals expected: Value, _ message: String) throws {
    guard actual == expected else {
      throw Failure(description: "\(message): expected \(expected), got \(actual)")
    }
    checksPassed += 1
  }
}
