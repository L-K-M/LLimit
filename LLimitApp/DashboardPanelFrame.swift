import SwiftUI

enum DashboardPresentation {
  case menuBar
  case floating
}

/// Supplies an opening size without restricting AppKit's live window size.
struct DashboardPanelFrame: ViewModifier {
  let presentation: DashboardPresentation
  let menuBarSize: CGSize

  func body(content: Content) -> some View {
    content.frame(
      minWidth: MenuBarPanelSize.minimumWidth,
      idealWidth: presentation == .menuBar ? menuBarSize.width : 430,
      maxWidth: .infinity,
      minHeight: presentation == .floating ? 440 : MenuBarPanelSize.minimumHeight,
      idealHeight: presentation == .menuBar ? menuBarSize.height : nil,
      maxHeight: .infinity
    )
  }
}
