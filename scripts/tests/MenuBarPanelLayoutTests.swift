import AppKit
import SwiftUI

@main
private struct MenuBarPanelLayoutTests {
  private struct Failure: Error, CustomStringConvertible {
    let description: String
  }

  private final class BoundsView: NSView {}

  private struct BoundsReader: NSViewRepresentable {
    let view: BoundsView
    func makeNSView(context: Context) -> BoundsView { view }
    func updateNSView(_ view: BoundsView, context: Context) {}
  }

  @MainActor
  static func main() throws {
    let openingSize = CGSize(width: 420, height: 610)
    let boundsView = BoundsView()
    let root = Color.clear
      .modifier(DashboardPanelFrame(presentation: .menuBar, menuBarSize: openingSize))
      .background(BoundsReader(view: boundsView))
    let host = NSHostingView(rootView: root)
    host.sizingOptions = [.intrinsicContentSize]

    // AppKit changes the proposal while the SwiftUI opening size stays fixed.
    // The old maximum frame kept the content (and grips) at 420x610 on growth.
    for size in [openingSize, CGSize(width: 620, height: 710),
                 CGSize(width: 370, height: 470), CGSize(width: 560, height: 680)] {
      host.setFrameSize(size)
      host.layoutSubtreeIfNeeded()
      guard boundsView.frame.size == size else {
        throw Failure(description: "Content must follow the native window: expected \(size), got \(boundsView.frame.size)")
      }
      guard host.fittingSize == openingSize else {
        throw Failure(description: "Live resizing changed the ideal opening size: \(host.fittingSize)")
      }
    }

    print("Menu bar panel native layout checks passed: 8")
  }
}
