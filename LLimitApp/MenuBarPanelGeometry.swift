import Foundation
// CGRect's geometry members and Equatable come from CoreGraphics on Apple
// platforms; Foundation provides them on Linux.
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Corner of the menu bar panel a resize grip sits in.
enum MenuBarPanelCorner {
  case bottomLeading
  case bottomTrailing
}

/// Size of the menu bar dropdown, which the user sets by dragging a corner grip.
///
/// MenuBarExtra sizes its panel to the content's ideal frame when it opens, so
/// the remembered size becomes that frame. While open, the panel grows with its
/// content but never shrinks, so a drag also sets the panel's frame directly.
///
///     menu bar ──────────[status item]──────
///              ┌─────────────────────────┐   top edge stays pinned
///              │ dashboard               │
///              ├─────────────────────────┤
///              │ ⋱ Refresh   Settings  ⋰ │   either corner grip
///              └─────────────────────────┘
///
/// The edge opposite the grabbed grip stays put. The leading grip lets a panel
/// already against the screen's trailing edge widen.
enum MenuBarPanelSize {
  static let widthKey = "MenuBarPanelWidth"
  static let heightKey = "MenuBarPanelHeight"
  static let defaultWidth: Double = 420
  // Approximate height of the header, action bar, and dividers around the dashboard.
  private static let chromeHeight: CGFloat = 100
  // The dashboard's former fixed 510pt menu bar height.
  static let defaultHeight = Double(510 + chromeHeight)
  static let minimumWidth: CGFloat = 360
  // The dashboard's 320pt minimum menu bar height.
  static let minimumHeight: CGFloat = 320 + chromeHeight
  // Gap kept between the panel and the edges of the visible screen area.
  static let screenMargin: CGFloat = 12

  /// Panel frame and remembered size after a grip drag.
  struct Resize: Equatable {
    let frame: CGRect
    let size: CGSize
  }

  /// The remembered size limited to the visible screen area, so the action bar
  /// and grips stay reachable after a move from a large display to a laptop.
  /// Callers keep the remembered size itself for the next larger screen.
  static func fitted(_ size: CGSize, within visibleSize: CGSize?) -> CGSize {
    let maximumWidth = visibleSize.map { max(minimumWidth, $0.width - screenMargin * 2) } ?? .infinity
    let maximumHeight = visibleSize.map { max(minimumHeight, $0.height - screenMargin) } ?? .infinity

    return CGSize(
      width: min(max(size.width, minimumWidth), maximumWidth),
      height: min(max(size.height, minimumHeight), maximumHeight)
    )
  }

  /// Resizes the panel for a pointer moved by `pointerDelta` since the drag
  /// began, in screen coordinates (y grows upward). `frame` and `size` are the
  /// panel frame and remembered size at that moment.
  ///
  /// The grabbed corner follows the pointer until the minimum size or the
  /// visible screen edge stops it. A panel that already overflows the screen
  /// cannot grow further but is not yanked back on the first move.
  static func resize(
    frame: CGRect,
    size: CGSize,
    corner: MenuBarPanelCorner,
    pointerDelta: CGSize,
    visibleFrame: CGRect
  ) -> Resize {
    let requestedWidthChange = corner == .bottomTrailing ? pointerDelta.width : -pointerDelta.width
    let widthRoom = corner == .bottomTrailing
      ? visibleFrame.maxX - screenMargin - frame.maxX
      : frame.minX - (visibleFrame.minX + screenMargin)
    let heightRoom = frame.minY - (visibleFrame.minY + screenMargin)

    let widthChange = max(minimumWidth - size.width, min(requestedWidthChange, max(0, widthRoom)))
    let heightChange = max(minimumHeight - size.height, min(-pointerDelta.height, max(0, heightRoom)))

    return Resize(
      frame: CGRect(
        x: corner == .bottomTrailing ? frame.minX : frame.minX - widthChange,
        y: frame.minY - heightChange,
        width: frame.width + widthChange,
        height: frame.height + heightChange
      ),
      size: CGSize(width: size.width + widthChange, height: size.height + heightChange)
    )
  }
}

/// Rows of account gauges on the dashboard's Overview card.
///
/// Columns are capped at the gauge count, so a few accounts spread across the
/// card instead of packing into the leading cells of a fixed grid. Wrapped rows
/// differ by at most one gauge: seven gauges that fit six per row become 4 + 3,
/// not 6 + 1. Every cell has the same width, and shorter rows are centered.
enum OverviewGaugeLayout {
  static let minimumCellWidth: CGFloat = 54
  static let columnSpacing: CGFloat = 6

  /// Number of gauges in each row, longest first, for `count` gauges across
  /// `width` points. An unbounded width, as in an ideal-size query, fits every
  /// gauge in one row; no room at all still gives each gauge its own row.
  static func rows(count: Int, width: CGFloat) -> [Int] {
    guard count > 0 else { return [] }

    let fitting = ((width + columnSpacing) / (minimumCellWidth + columnSpacing)).rounded(.down)
    let columnLimit = fitting.isNaN ? 1 : Int(max(1, min(fitting, CGFloat(count))))
    let rowCount = (count + columnLimit - 1) / columnLimit
    let shortRowLength = count / rowCount
    let longRowCount = count % rowCount

    return (0..<rowCount).map { $0 < longRowCount ? shortRowLength + 1 : shortRowLength }
  }

  /// Width of each gauge cell when `columns` cells and their gaps share `width` points.
  static func cellWidth(columns: Int, width: CGFloat) -> CGFloat {
    guard columns > 0 else { return 0 }
    guard width.isFinite else { return minimumCellWidth }

    return max(0, (width - columnSpacing * CGFloat(columns - 1)) / CGFloat(columns))
  }
}
