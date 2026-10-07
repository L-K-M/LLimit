import SwiftUI
import AppKit
import Combine
import QuotaCore

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    GlobalHotkeyService.shared.start {
      DashboardWindowController.shared.toggleFromShortcut(model: AppModel.shared)
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    GlobalHotkeyService.shared.stop()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    !SettingsWindowController.shared.restoreOpenWindow()
  }
}

@main
struct LLimitApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var model = AppModel.shared

  var body: some Scene {
    // Menu-bar-only app. The settings window is a normal, freely resizable AppKit
    // NSWindow opened on demand (see SettingsWindowController) rather than the SwiftUI
    // `Settings` scene, which forces itself non-resizable, or a `Window` scene, which
    // would auto-open at launch.
    MenuBarExtra {
      MenuBarContent(model: model, presentation: .menuBar)
    } label: {
      MenuBarIcon(
        snapshot: model.snapshot,
        kindColors: model.widgetStyle.limitKindColors,
        primaryColors: model.primaryColorsByAccountID,
        accounts: model.providerAccounts,
        refreshIntervalMinutes: model.refreshIntervalMinutes
      )
    }
    .menuBarExtraStyle(.window)
  }
}

private enum DashboardPresentation {
  case menuBar
  case floating
}

/// Hosts `SettingsView` in a standard resizable AppKit window, created on first use and
/// reused thereafter. Avoids the SwiftUI `Settings` scene (non-resizable) entirely.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
  static let shared = SettingsWindowController()
  private var window: NSWindow?
  private var isOpen = false

  func show(model: AppModel) {
    if window == nil {
      let hosting = NSHostingController(rootView: SettingsView(model: model))
      hosting.sizingOptions = []

      let window = NSWindow(contentViewController: hosting)
      window.title = "LLimit"
      window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
      window.isReleasedWhenClosed = false
      window.delegate = self
      window.setContentSize(NSSize(width: 960, height: 680))
      window.contentMinSize = NSSize(width: 720, height: 480)
      window.setFrameAutosaveName("LLimitSettingsWindow")
      window.center()
      self.window = window
    }

    isOpen = true
    restoreOpenWindow()
  }

  /// A Settings window stays discoverable in Cmd-Tab and the Dock until it is
  /// closed. Losing focus to browser sign-in, hiding, or minimizing is not closing.
  @discardableResult
  func restoreOpenWindow() -> Bool {
    guard isOpen, let window else { return false }
    NSApp.setActivationPolicy(.regular)
    if window.isMiniaturized {
      window.deminiaturize(nil)
    }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    return true
  }

  func windowWillClose(_ notification: Notification) {
    guard let closedWindow = notification.object as? NSWindow, closedWindow === window else { return }
    isOpen = false
    NSApp.setActivationPolicy(.accessory)
  }
}

extension AppModel {
  /// Menu bar, settings and shortcut share one refresh owner.
  @MainActor static let shared = AppModel()
}

/// Owns the optional always-on-top quota dashboard detached from the menu bar.
@MainActor
final class DashboardWindowController {
  static let shared = DashboardWindowController()
  private var window: NSPanel?
  /// App that was frontmost when the dashboard came forward while LLimit was
  /// inactive. A shortcut press that puts the dashboard away hands focus back.
  private var appToRestore: NSRunningApplication?

  private func makeWindowIfNeeded(model: AppModel) {
    if window == nil {
      let hosting = NSHostingController(
        rootView: MenuBarContent(model: model, presentation: .floating)
      )
      hosting.sizingOptions = []

      let panel = NSPanel(contentViewController: hosting)
      panel.title = "LLimit Dashboard"
      panel.styleMask = [.titled, .closable, .miniaturizable, .resizable, .utilityWindow]
      panel.isFloatingPanel = true
      panel.level = .floating
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      panel.hidesOnDeactivate = false
      panel.isReleasedWhenClosed = false
      panel.setContentSize(NSSize(width: 430, height: 700))
      panel.contentMinSize = NSSize(width: 390, height: 500)
      if !panel.setFrameUsingName("LLimitFloatingDashboard") {
        panel.center()
      }
      panel.setFrameAutosaveName("LLimitFloatingDashboard")
      window = panel
    }
  }

  func show(model: AppModel, near screenPoint: NSPoint? = nil, activate: Bool = true) {
    makeWindowIfNeeded(model: model)
    // Read before activating, which makes LLimit the frontmost app. Nothing is
    // restored when LLimit was already active, such as from Settings.
    let previous = NSWorkspace.shared.frontmostApplication
    appToRestore = NSApp.isActive || previous?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : previous

    if let screenPoint {
      positionWindow(near: screenPoint)
    }

    if window?.isMiniaturized == true {
      window?.deminiaturize(nil)
    }

    if activate {
      activateWindow()
    } else {
      window?.orderFrontRegardless()
    }
  }

  func move(near screenPoint: NSPoint) {
    positionWindow(near: screenPoint)
  }

  func activateWindow() {
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }

  /// The dashboard shortcut. A dashboard you are using goes away. A hidden one,
  /// or one left visible while you work in another app, comes forward on the
  /// screen under the pointer with keyboard focus, so Cmd-R and Cmd-, work.
  func toggleFromShortcut(model: AppModel) {
    if NSApp.isActive, let window, window.isKeyWindow {
      dismissFromShortcut(window)
      return
    }

    makeWindowIfNeeded(model: model)
    moveOntoScreen(containing: NSEvent.mouseLocation)
    show(model: model)
  }

  private func dismissFromShortcut(_ window: NSPanel) {
    let heldFocus = NSApp.isActive && window.isKeyWindow
      && NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    window.orderOut(nil)

    // Ordering the panel out leaves LLimit active with nothing to type into,
    // so hand focus back to the app you were in when the dashboard came forward.
    // Only restore when LLimit still holds focus; if the user already moved
    // elsewhere, leave their current app alone.
    if heldFocus, NSApp.isActive, NSApp.keyWindow == nil,
       let appToRestore, !appToRestore.isTerminated {
      appToRestore.activate(options: [])
    }
    appToRestore = nil
  }

  /// Leaves the dashboard where you put it when that is on the pointer's
  /// screen. Otherwise centers it on that screen.
  private func moveOntoScreen(containing point: NSPoint) {
    guard let window,
          let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else {
      return
    }

    let frame = window.frame
    guard !screen.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) else { return }

    let visibleFrame = screen.visibleFrame
    let centered = NSRect(
      x: visibleFrame.midX - frame.width / 2,
      y: visibleFrame.midY - frame.height / 2,
      width: frame.width,
      height: frame.height
    )
    window.setFrame(window.constrainFrameRect(centered, to: screen), display: false)
  }

  private func positionWindow(near screenPoint: NSPoint) {
    guard let window else { return }

    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) }) ?? NSScreen.main else {
      return
    }

    var frame = window.frame
    let proposedX = screenPoint.x - frame.width / 2
    let proposedY = screenPoint.y - frame.height - 14
    frame.origin = NSPoint(x: proposedX, y: proposedY)
    window.setFrame(window.constrainFrameRect(frame, to: screen), display: false)
  }
}

private struct MenuBarIcon: View {
  let snapshot: QuotaSnapshot?
  let kindColors: LimitKindColors
  let primaryColors: [String: String]
  let accounts: [ProviderAccount]
  let refreshIntervalMinutes: Int
  private static let ticks = Timer.publish(every: 60, tolerance: 15, on: .main, in: .common).autoconnect()
  @State private var checkedAt = Date()

  var body: some View {
    let bars = projectedBars(at: max(checkedAt, Date()))
    let label = MenuBarGraph.accessibilityLabel(for: bars)
    let tooltip = MenuBarGraph.tooltip(for: bars)

    Image(nsImage: iconImage(for: bars, accessibilityLabel: label))
      .accessibilityLabel(label)
      .help(tooltip)
      .onChange(of: [tooltip, label], initial: true) {
        StatusItemButtonSummary.apply(toolTip: tooltip, accessibilityLabel: label)
      }
      .onReceive(Self.ticks) { date in
        if projectedBars(at: date).map(\.freshness) != projectedBars(at: checkedAt).map(\.freshness) {
          checkedAt = date
        }
      }
  }

  private func projectedBars(at date: Date) -> [MenuBarGraph.Bar] {
    MenuBarGraph.bars(snapshot: snapshot, accounts: accounts, now: date,
                      staleAfter: QuotaFreshness.maxAge(refreshIntervalMinutes: refreshIntervalMinutes))
  }

  private func iconImage(for bars: [MenuBarGraph.Bar], accessibilityLabel: String) -> NSImage {
    guard !bars.isEmpty else {
      return fallbackIcon(accessibilityLabel: accessibilityLabel)
    }

    let accents = bars.map { bar in
      NSColor(LimitKindColorScheme.primaryAccountAccent(
        for: bar.usage?.metrics ?? [], colors: kindColors,
        step: accountColorStep(forAccountID: bar.accountID, in: accounts),
        primaryHexColor: primaryColors[bar.accountID]
      ))
    }
    let image = NSImage(size: MenuBarBarRenderer.imageSize(barCount: bars.count), flipped: false) { _ in
      for (index, bar) in bars.enumerated() {
        MenuBarBarRenderer.draw(bar, accent: accents[index], in: MenuBarBarRenderer.column(at: index))
      }
      return true
    }

    image.isTemplate = false
    image.accessibilityDescription = accessibilityLabel
    return image
  }

  private func fallbackIcon(accessibilityLabel: String) -> NSImage {
    let image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: accessibilityLabel)
      ?? NSImage(size: NSSize(width: 18, height: 16))
    image.isTemplate = true
    return image
  }
}

/// Identity fills carry level; stems and dashed frames carry freshness/failure.
private enum MenuBarBarRenderer {
  private static let barWidth: CGFloat = 3
  private static let barSpacing: CGFloat = 1.5
  private static let iconHeight: CGFloat = 16
  private static let cornerRadius: CGFloat = 1
  private static let outlineWidth: CGFloat = 1
  private static let stemWidth: CGFloat = 1
  private static let failingDash: [CGFloat] = [2, 1.5]
  private static let amountDash: [CGFloat] = [1, 1.5]
  private static let track = NSColor(white: 0.5, alpha: 0.35)
  private static let failing = NSColor(srgbRed: 1, green: 159 / 255, blue: 10 / 255, alpha: 1)
  private static let exhausted = NSColor(srgbRed: 1, green: 0.36, blue: 0.32, alpha: 1)

  static func imageSize(barCount: Int) -> NSSize {
    NSSize(width: CGFloat(barCount) * barWidth + CGFloat(max(0, barCount - 1)) * barSpacing, height: iconHeight)
  }

  static func column(at index: Int) -> NSRect {
    NSRect(x: CGFloat(index) * (barWidth + barSpacing), y: 0, width: barWidth, height: iconHeight)
  }

  static func draw(_ bar: MenuBarGraph.Bar, accent: NSColor, in column: NSRect) {
    if bar.freshness.isFailing {
      stroke(column, color: failing, dash: failingDash)
    } else {
      fill(column, color: track)
    }

    guard let height = MenuBarGraph.barHeight(for: bar.level, fullHeight: Double(column.height)) else {
      if bar.level == .amountOnly, !bar.freshness.isFailing {
        stroke(column, color: accent, dash: amountDash)
      }
      return
    }

    guard height > 0 else {
      if !bar.freshness.isFailing { stroke(column, color: exhausted, dash: nil) }
      return
    }

    let width = bar.freshness == .current ? column.width : stemWidth
    fill(NSRect(x: column.midX - width / 2, y: column.minY, width: width, height: CGFloat(height)), color: accent)
  }

  private static func fill(_ rect: NSRect, color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
  }

  private static func stroke(_ rect: NSRect, color: NSColor, dash: [CGFloat]?) {
    let path = NSBezierPath(roundedRect: rect.insetBy(dx: outlineWidth / 2, dy: outlineWidth / 2),
                            xRadius: cornerRadius, yRadius: cornerRadius)
    path.lineWidth = outlineWidth
    if let dash { path.setLineDash(dash, count: dash.count, phase: 0) }
    color.setStroke()
    path.stroke()
  }
}

/// MenuBarExtra can discard label modifiers when building its status button.
/// LLimit owns the process's only status item; use public AppKit APIs to label it.
@MainActor
private enum StatusItemButtonSummary {
  private static let attemptDelays: [Duration] = [.zero, .milliseconds(250), .seconds(1), .seconds(3), .seconds(10)]
  private static var pendingApply: Task<Void, Never>?

  static func apply(toolTip: String, accessibilityLabel: String) {
    pendingApply?.cancel()
    pendingApply = Task {
      for delay in attemptDelays {
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled else { return }
        let buttons = NSApp.windows.compactMap(\.contentView).flatMap(statusBarButtons)
        guard !buttons.isEmpty else { continue }
        for button in buttons {
          button.toolTip = toolTip
          button.setAccessibilityLabel(accessibilityLabel)
        }
        return
      }
    }
  }

  private static func statusBarButtons(in view: NSView) -> [NSStatusBarButton] {
    if let button = view as? NSStatusBarButton { return [button] }
    return view.subviews.flatMap(statusBarButtons)
  }
}

// MARK: - Dashboard design system

/// Graphite-glass palette for the dropdown/floating dashboard. Accent colors
/// come from the limit-kind identity palette (LimitKindColorScheme); nothing
/// here should compete with those signal colors.
private enum DashboardPalette {
  static let backgroundTop = adaptive(\.backgroundTopHex)
  static let backgroundBottom = adaptive(\.backgroundBottomHex)
  static let primaryText = adaptive(\.primaryTextHex)
  static let card = adaptive(\.cardHex)
  static let cardHover = adaptive(\.cardHoverHex)
  static let hairline = primaryText.opacity(0.14)
  static let rimBottom = primaryText.opacity(0.04)
  static let sectionTitle = adaptive(\.tertiaryTextHex)
  static let secondaryText = adaptive(\.secondaryTextHex)
  static let tertiaryText = adaptive(\.tertiaryTextHex)
  static let warning = adaptive(\.warningHex)
  static let danger = adaptive(\.dangerHex)
  static let success = adaptive(\.successHex)
  static let barTrack = primaryText.opacity(0.12)
  static let markBacking = Color(red: 29 / 255, green: 31 / 255, blue: 39 / 255)
  static let brandGradient = [Color(red: 52 / 255, green: 107 / 255, blue: 194 / 255),
                              Color(red: 123 / 255, green: 73 / 255, blue: 184 / 255)]

  private static func adaptive(_ key: KeyPath<DashboardAppearance, String>) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
      let scheme: DashboardAppearance = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
      return NSColor(LimitKindColorScheme.color(hex: scheme[keyPath: key]) ?? .primary)
    })
  }
}

/// Card chrome shared by every dashboard tile: soft fill, top-lit rim, drop shadow.
/// The rim gradient is what makes cards read as "glass" on the dark background.
private struct DashboardCardChrome: ViewModifier {
  var accent: Color?
  var isHovered = false

  func body(content: Content) -> some View {
    content
      .background(
        isHovered ? DashboardPalette.cardHover : DashboardPalette.card,
        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(
            LinearGradient(
              colors: [
                (accent ?? DashboardPalette.primaryText).opacity(accent == nil ? 0.14 : 0.30),
                DashboardPalette.rimBottom
              ],
              startPoint: .top,
              endPoint: .bottom
            ),
            lineWidth: 1
          )
      }
      .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
  }
}

private extension View {
  func dashboardCard(accent: Color? = nil, isHovered: Bool = false) -> some View {
    modifier(DashboardCardChrome(accent: accent, isHovered: isHovered))
  }
}

private struct SectionTitle: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(size: 10, weight: .semibold))
      .tracking(1.1)
      .foregroundStyle(DashboardPalette.sectionTitle)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 2)
      .accessibilityAddTraits(.isHeader)
  }
}

/// Circular gauge with a gradient arc and a soft glow — the dashboard's signature mark.
private struct GlossRing: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let remaining: Int?
  let unlimited: Bool
  let tint: Color
  var isEstimated: Bool = false
  var diameter: CGFloat = 46
  var lineWidth: CGFloat = 5

  private var progress: Double {
    if unlimited { return 1 }
    return Double(max(0, min(100, remaining ?? 0))) / 100
  }

  private var innerDiameter: CGFloat { diameter - lineWidth * 2 }

  var body: some View {
    ZStack {
      Circle()
        .inset(by: lineWidth / 2)
        .stroke(DashboardPalette.barTrack, lineWidth: lineWidth)

      if progress > 0.001 {
        Circle()
          .inset(by: lineWidth / 2)
          .trim(from: 0, to: progress)
          .stroke(DashboardPalette.markBacking, style: StrokeStyle(lineWidth: lineWidth + 1.5, lineCap: .round))
          .rotationEffect(.degrees(-90))

        Circle()
          .inset(by: lineWidth / 2)
          .trim(from: 0, to: progress)
          .stroke(
            AngularGradient(
              gradient: Gradient(colors: [tint, tint]),
              center: .center,
              startAngle: .degrees(0),
              endAngle: .degrees(360 * progress)
            ),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
          )
          .rotationEffect(.degrees(-90))
          .shadow(color: tint.opacity(0.55), radius: 3.5)
          .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.8), value: progress)
      }

      Text(centerText)
        .font(.system(size: innerDiameter * 0.33, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(DashboardPalette.primaryText)
        .contentTransition(.numericText())
        .minimumScaleFactor(0.6)
        .lineLimit(1)
        .frame(width: innerDiameter * 0.88)
    }
    .frame(width: diameter, height: diameter)
    .accessibilityLabel(accessibilityText)
  }

  private var centerText: String {
    if unlimited { return "∞" }
    guard let remaining else { return "--" }
    return "\(isEstimated ? "≈" : "")\(max(0, min(100, remaining)))%"
  }

  private var accessibilityText: String {
    if unlimited { return "Unlimited" }
    guard let remaining else { return "Quota unavailable" }
    return "\(isEstimated ? "Estimated " : "")\(max(0, min(100, remaining))) percent remaining"
  }
}

/// Capsule progress bar with a gradient fill and a glossy top highlight.
private struct GlossBar: View {
  let progress: Double
  let tint: Color

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(DashboardPalette.barTrack)

        if progress > 0 {
          Capsule()
            .fill(DashboardPalette.markBacking)
            .frame(width: max(6, geometry.size.width * min(1, progress)))

          Capsule()
            .fill(
              LinearGradient(colors: [tint, tint], startPoint: .leading, endPoint: .trailing)
            )
            .overlay(alignment: .top) {
              Capsule()
                .fill(
                  LinearGradient(colors: [.white.opacity(0.30), .clear], startPoint: .top, endPoint: .bottom)
                )
                .frame(height: 2.5)
                .padding(.horizontal, 1)
            }
            .frame(width: max(6, geometry.size.width * min(1, progress)))
            .shadow(color: tint.opacity(0.35), radius: 2)
            .overlay(Capsule().strokeBorder(DashboardPalette.markBacking, lineWidth: 0.75))
        }
      }
    }
    .frame(height: 5)
    .animation(.spring(response: 0.55, dampingFraction: 0.85), value: progress)
    .accessibilityHidden(true)
  }
}

private struct SparkPoint {
  let date: Date
  let remaining: Double
}

/// Builds per-metric history series for the sparklines from the app's recent
/// local history. Matching mirrors the trend widget: by accountID, with the
/// pre-multi-account fallback (accountID == provider raw value) honored only
/// while that provider still has exactly one enabled account.
private struct SparkSeriesBuilder {
  let history: [QuotaSnapshot]
  let soleAccountProviders: Set<QuotaProvider>

  func points(
    accountID: String,
    provider: QuotaProvider,
    metricID: String,
    metricLabel: String,
    window: ClosedRange<Date>
  ) -> [SparkPoint] {
    let resolvedID = Self.resolvedMetricID(id: metricID, label: metricLabel)
    var result: [SparkPoint] = []

    for snapshot in history {
      guard window.contains(snapshot.generatedAt) else { continue }
      guard let usage = snapshot.providers.first(where: { usage in
        usage.accountID == accountID
          || (usage.provider == provider
            && usage.accountID == usage.provider.rawValue
            && soleAccountProviders.contains(provider))
      }) else { continue }
      guard let metric = usage.metrics.first(where: { metric in
        Self.resolvedMetricID(id: metric.id, label: metric.label) == resolvedID
      }) else { continue }

      if metric.isUnlimited {
        result.append(SparkPoint(date: snapshot.generatedAt, remaining: 100))
      } else if let remaining = metric.remainingPercent {
        result.append(SparkPoint(date: snapshot.generatedAt, remaining: Double(max(0, min(100, remaining)))))
      }
    }

    return result
  }

  private static func resolvedMetricID(id: String, label: String) -> String {
    let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? label : trimmed
  }
}

/// Tiny fixed-domain (0-100%) line chart of the last day of quota history.
private struct Sparkline: View {
  let points: [SparkPoint]
  let tint: Color
  let start: Date
  let end: Date

  var body: some View {
    Canvas { context, size in
      let duration = end.timeIntervalSince(start)
      guard duration > 0, points.count >= 2 else { return }

      // Inset vertically so the 1.5pt stroke and end dot never clip at 0/100%.
      let insetY: CGFloat = 2.5
      let plotHeight = max(1, size.height - insetY * 2)

      func position(for point: SparkPoint) -> CGPoint {
        let x = CGFloat(min(max(point.date.timeIntervalSince(start) / duration, 0), 1)) * size.width
        let y = insetY + (1 - CGFloat(min(max(point.remaining, 0), 100) / 100)) * plotHeight
        return CGPoint(x: x, y: y)
      }

      let positions = points.map(position(for:))

      var line = Path()
      line.move(to: positions[0])
      for position in positions.dropFirst() {
        line.addLine(to: position)
      }

      var area = line
      area.addLine(to: CGPoint(x: positions[positions.count - 1].x, y: size.height))
      area.addLine(to: CGPoint(x: positions[0].x, y: size.height))
      area.closeSubpath()

      context.fill(
        area,
        with: .linearGradient(
          Gradient(colors: [tint.opacity(0.22), tint.opacity(0.02)]),
          startPoint: CGPoint(x: 0, y: 0),
          endPoint: CGPoint(x: 0, y: size.height)
        )
      )
      context.stroke(
        line,
        with: .color(tint.opacity(0.9)),
        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
      )

      if let last = positions.last {
        let dot = Path(ellipseIn: CGRect(x: last.x - 2, y: last.y - 2, width: 4, height: 4))
        context.fill(dot, with: .color(tint))
      }
    }
    .accessibilityHidden(true)
  }
}

private struct ResetChip: View {
  let countdown: String

  private var isDue: Bool { countdown == "reset" }

  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: "clock.arrow.circlepath")
        .font(.system(size: 8, weight: .semibold))
      Text(isDue ? "reset due" : countdown)
        .font(.system(size: 10, weight: .semibold))
        .monospacedDigit()
    }
    .foregroundStyle(isDue ? DashboardPalette.warning : DashboardPalette.tertiaryText)
    .lineLimit(1)
    .accessibilityLabel(isDue ? "Reset due" : "Resets in \(countdown)")
  }
}

// MARK: - Dashboard

private struct MenuBarContent: View {
  @ObservedObject var model: AppModel
  let presentation: DashboardPresentation

  @AppStorage(MenuBarPanelSize.widthKey) private var panelWidth = MenuBarPanelSize.defaultWidth
  @AppStorage(MenuBarPanelSize.heightKey) private var panelHeight = MenuBarPanelSize.defaultHeight
  @State private var panelAnchor = WindowAnchor()
  @State private var panelScreenSize: CGSize?

  var body: some View {
    // Fitted to the panel's own screen. NSScreen.main follows keyboard focus and
    // can be another display; it only stands in until the panel first opens.
    let menuBarSize = MenuBarPanelSize.fitted(
      CGSize(width: panelWidth, height: panelHeight),
      within: panelScreenSize ?? NSScreen.main?.visibleFrame.size
    )

    VStack(spacing: 0) {
      TimelineView(.periodic(from: .now, by: 60)) { context in
        VStack(spacing: 0) {
          dashboardHeader(now: context.date)
          dashboardDivider
          dashboard(now: context.date)
            .frame(minHeight: presentation == .menuBar ? 320 : 380, maxHeight: .infinity)
        }
      }

      dashboardDivider
      actionBar
    }
    // One flexible frame, never a fixed width: the macOS 26 menu panel proposes a
    // content width slightly narrower than the window, and a hard 420pt layout
    // overflows it on both sides. Every card adapts, so compressing is safe.
    // The menu bar panel sizes itself to the ideal frame, which is the size the
    // user last dragged it to.
    .frame(
      minWidth: MenuBarPanelSize.minimumWidth,
      idealWidth: presentation == .menuBar ? menuBarSize.width : 430,
      maxWidth: presentation == .floating ? .infinity : menuBarSize.width,
      minHeight: presentation == .floating ? 440 : nil,
      idealHeight: presentation == .menuBar ? menuBarSize.height : nil,
      maxHeight: presentation == .floating ? .infinity : menuBarSize.height
    )
    .overlay(alignment: .bottom) {
      // The floating dashboard is a titled window AppKit already resizes.
      if presentation == .menuBar {
        HStack {
          PanelResizeGrip(corner: .bottomLeading, panel: panelAnchor, width: $panelWidth, height: $panelHeight)
          Spacer()
          PanelResizeGrip(corner: .bottomTrailing, panel: panelAnchor, width: $panelWidth, height: $panelHeight)
        }
        .background(PanelWindowReader(anchor: panelAnchor) { panelScreenSize = $0 })
      }
    }
    .foregroundStyle(DashboardPalette.primaryText)
    .background {
      LinearGradient(
        colors: [DashboardPalette.backgroundTop, DashboardPalette.backgroundBottom],
        startPoint: .top,
        endPoint: .bottom
      )
    }
  }

  private var dashboardDivider: some View {
    Rectangle()
      .fill(DashboardPalette.hairline)
      .frame(height: 1)
  }

  @ViewBuilder
  private func dashboard(now: Date) -> some View {
    if let snapshot = model.snapshot {
      let providers = providersForMenu(from: snapshot)
      let currentFailures = orderedFailuresForAccounts(snapshot.failures, accounts: model.providerAccounts)
      let failuresByAccount = currentFailures.reduce(into: [String: ProviderFailure]()) { failures, failure in
        failures[failure.accountID] = failure
      }
      let providerIDs = Set(providers.map(\.accountID))
      let standaloneFailures = currentFailures
        .filter { !providerIDs.contains($0.accountID) }
        .sorted { failureTitle(for: $0) < failureTitle(for: $1) }
      let accountCount = model.providerAccounts.filter(\.isEnabled).count

      if providers.isEmpty && standaloneFailures.isEmpty {
        emptyState
      } else {
        let enabledByProvider = Dictionary(grouping: model.providerAccounts.filter(\.isEnabled), by: \.provider)
        let sparkBuilder = SparkSeriesBuilder(
          history: model.recentHistory,
          soleAccountProviders: Set(enabledByProvider.filter { $0.value.count == 1 }.map(\.key))
        )

        ScrollViewReader { proxy in
          ScrollView {
            VStack(spacing: 10) {
              OverviewCard(
                providers: providers,
                accountCount: accountCount,
                failureCount: currentFailures.count,
                tint: summaryTint(for: providers),
                kindColors: model.widgetStyle.limitKindColors,
                primaryColors: model.primaryColorsByAccountID,
                accounts: model.providerAccounts,
                now: now,
                bestAccount: DashboardBestAccount.best(snapshot: snapshot, accounts: model.providerAccounts, now: now,
                                                       staleAfter: QuotaFreshness.maxAge(refreshIntervalMinutes: model.refreshIntervalMinutes)),
                onSelect: { accountID in
                  withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                    proxy.scrollTo(accountID, anchor: .top)
                  }
                }
              )

              if !providers.isEmpty {
                SectionTitle(text: "ACCOUNTS")
                  .padding(.top, 4)
              }

              ForEach(providers) { provider in
                ProviderQuotaCard(
                  usage: provider,
                  accountName: model.account(withID: provider.accountID)?.displayName,
                  failure: failuresByAccount[provider.accountID],
                  kindColors: model.widgetStyle.limitKindColors,
                  colorStep: accountColorStep(forAccountID: provider.accountID, in: model.providerAccounts),
                  primaryHexColor: model.primaryColorsByAccountID[provider.accountID],
                  now: now,
                  sparkBuilder: sparkBuilder
                )
                .id(provider.accountID)
              }

              if !standaloneFailures.isEmpty {
                SectionTitle(text: "UNAVAILABLE")
                  .padding(.top, 4)
              }

              ForEach(standaloneFailures) { failure in
                ProviderFailureCard(
                  failure: failure,
                  accountName: model.account(withID: failure.accountID)?.displayName
                )
              }
            }
            .padding(OverviewGaugeLayout.dashboardPadding)
          }
          .scrollIndicators(.automatic)
        }
      }
    } else {
      emptyState
    }
  }

  private func dashboardHeader(now: Date) -> some View {
    let current = model.snapshot.map { snapshot -> QuotaSnapshot in
      var projected = snapshot
      projected.providers = orderedUsageForAccounts(snapshot.providers, accounts: model.providerAccounts)
      projected.failures = orderedFailuresForAccounts(snapshot.failures, accounts: model.providerAccounts)
      return projected
    }

    return HStack(spacing: 10) {
      ZStack {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(
            LinearGradient(
              colors: DashboardPalette.brandGradient,
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
        Image(systemName: "gauge.with.dots.needle.67percent")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(.white)
      }
      .frame(width: 30, height: 30)
      .shadow(color: DashboardPalette.brandGradient[0].opacity(0.35), radius: 5, y: 2)
      .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 1) {
        Text("LLimit")
          .font(.system(size: 14.5, weight: .semibold, design: .rounded))

        Group {
          if model.isRefreshing {
            Text("Refreshing…")
          } else if let snapshot = model.snapshot {
            Text("Updated \(QuotaDisplayText.relativeAge(snapshot.generatedAt, now: now))")
          } else {
            Text("Waiting for quota data")
          }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(DashboardPalette.secondaryText)
      }

      Spacer()

      if model.isRefreshing {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Refreshing")
      } else {
        let weather = QuotaWeather.forSnapshot(current, now: now,
          staleAfter: QuotaFreshness.maxAge(refreshIntervalMinutes: model.refreshIntervalMinutes))
        let issues = current?.failures.count ?? 0
        let description = "Quota weather: \(weather.rawValue). " +
          QuotaDisplayText.countPhrase(issues, singular: "account issue", plural: "account issues")

        Label(weather.rawValue, systemImage: weather.iconName)
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(weatherTint(weather))
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(weatherTint(weather).opacity(0.12), in: Capsule())
          .help(description)
          .accessibilityLabel(description)
      }

      if presentation == .menuBar {
        DetachDashboardControl(
          onOpen: {
            DashboardWindowController.shared.show(model: model)
          },
          onDragStart: { point in
            DashboardWindowController.shared.show(model: model, near: point, activate: false)
          },
          onMove: { point in
            DashboardWindowController.shared.move(near: point)
          },
          onDragEnd: {
            DashboardWindowController.shared.activateWindow()
          }
        )
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
    .background(DashboardPalette.card)
  }

  private func weatherTint(_ weather: QuotaWeather) -> Color {
    switch weather {
    case .calm: return DashboardPalette.success
    case .cloudy, .stale: return DashboardPalette.warning
    case .stormy: return DashboardPalette.danger
    case .unknown, .estimated: return DashboardPalette.secondaryText
    }
  }

  private var emptyState: some View {
    VStack(spacing: 10) {
      ZStack {
        Circle()
          .fill(
            LinearGradient(
              colors: DashboardPalette.brandGradient.map { $0.opacity(0.18) },
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
          .frame(width: 64, height: 64)
        Image(systemName: "gauge.with.dots.needle.0percent")
          .font(.system(size: 26, weight: .light))
          .foregroundStyle(DashboardPalette.primaryText)
      }
      .accessibilityHidden(true)

      Text("No quota data yet")
        .font(.headline)
      Text("Refresh now to fetch your current limits.")
        .font(.caption)
        .foregroundStyle(DashboardPalette.secondaryText)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 280)

      Button {
        Task {
          await model.refreshNow()
        }
      } label: {
        Label("Refresh Now", systemImage: "arrow.clockwise")
          .font(.system(size: 12, weight: .semibold))
          .padding(.horizontal, 14)
          .padding(.vertical, 7)
          .background(
            LinearGradient(
              colors: DashboardPalette.brandGradient,
              startPoint: .leading,
              endPoint: .trailing
            ),
            in: Capsule()
          )
          .foregroundStyle(.white)
      }
      .buttonStyle(.plain)
      .disabled(model.isRefreshing)
      .padding(.top, 4)
    }
    .frame(maxWidth: .infinity, minHeight: 220)
    .padding(20)
  }

  private var actionBar: some View {
    HStack(spacing: 8) {
      ActionBarButton(
        title: model.isRefreshing ? "Refreshing" : "Refresh",
        systemImage: "arrow.clockwise",
        isDisabled: model.isRefreshing,
        shortcut: KeyboardShortcut("r", modifiers: .command)
      ) {
        Task {
          await model.refreshNow()
        }
      }

      Spacer()

      ActionBarButton(
        title: "Settings",
        systemImage: "gearshape",
        shortcut: KeyboardShortcut(",", modifiers: .command)
      ) {
        SettingsWindowController.shared.show(model: model)
      }

      Menu {
        if presentation == .menuBar {
          Button {
            DashboardWindowController.shared.show(model: model)
          } label: {
            Label("Open Floating Dashboard", systemImage: "macwindow")
          }

          Divider()
        }

        Toggle("Launch at Login", isOn: model.launchAtLoginBinding())

        Divider()

        Button("Quit LLimit") {
          NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
      } label: {
        Image(systemName: "ellipsis")
          .frame(width: 18)
      }
      .help("More")
      .accessibilityLabel("More actions")
    }
    .buttonStyle(.borderless)
    .font(.system(size: 13, weight: .medium))
    .foregroundStyle(DashboardPalette.primaryText)
    // Keeps the buttons clear of the menu bar panel's corner resize grips.
    .padding(.horizontal, presentation == .menuBar ? PanelResizeGrip.footprint + 4 : 14)
    .padding(.vertical, 10)
    .background(Color.black.opacity(0.10))
  }

  private func providersForMenu(from snapshot: QuotaSnapshot) -> [ProviderUsage] {
    orderedUsageForAccounts(snapshot.providers, accounts: model.providerAccounts).sorted { lhs, rhs in
      let lhsRemaining = MenuBarQuotaStyling.remainingPercent(for: lhs) ?? Int.max
      let rhsRemaining = MenuBarQuotaStyling.remainingPercent(for: rhs) ?? Int.max

      if lhsRemaining != rhsRemaining {
        return lhsRemaining < rhsRemaining
      }

      return lhs.title < rhs.title
    }
  }

  private func summaryTint(for providers: [ProviderUsage]) -> Color {
    guard let provider = providers.min(by: {
      (MenuBarQuotaStyling.remainingPercent(for: $0) ?? Int.max)
        < (MenuBarQuotaStyling.remainingPercent(for: $1) ?? Int.max)
    }) else {
      return .secondary
    }

    // The LOWEST stat wears the accent of the account it reports, pointing at
    // that account's gauge and card.
    return LimitKindColorScheme.accountAccent(
      for: provider.metrics,
      colors: model.widgetStyle.limitKindColors,
      step: accountColorStep(forAccountID: provider.accountID, in: model.providerAccounts),
      primaryHexColor: model.primaryColorsByAccountID[provider.accountID]
    )
  }

  private func failureTitle(for failure: ProviderFailure) -> String {
    model.account(withID: failure.accountID)?.displayName ?? failure.provider.displayName
  }

}

private struct ActionBarButton: View {
  let title: String
  let systemImage: String
  var isDisabled = false
  var shortcut: KeyboardShortcut?
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
          DashboardPalette.primaryText.opacity(isHovering && !isDisabled ? 0.09 : 0),
          in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .keyboardShortcut(shortcut)
    .disabled(isDisabled)
    .opacity(isDisabled ? 0.5 : 1)
    .onHover { isHovering = $0 }
  }
}

/// Corner grip that resizes the open menu bar panel and remembers its size.
/// Sizes follow screen-space pointer deltas since the drag began: the grip
/// moves with the panel, so translations in its own coordinates would feed
/// back into the size.
private struct PanelResizeGrip: View {
  static let footprint: CGFloat = gripSize + gripInset * 2

  private static let gripSize: CGFloat = 10
  // Keeps the strokes inside the panel's rounded corner mask.
  private static let gripInset: CGFloat = 6

  let corner: MenuBarPanelCorner
  let panel: WindowAnchor
  @Binding var width: Double
  @Binding var height: Double

  // Gesture state resets on its own when a drag is cancelled, e.g. by the
  // panel closing mid-drag, so a stale origin never leaks into the next drag.
  @GestureState private var dragStart: DragStart?

  private struct DragStart {
    let pointer: NSPoint
    let frame: NSRect
    let size: CGSize
  }

  var body: some View {
    Canvas { context, size in
      // Classic window grip: three diagonals, shortest nearest the corner.
      let leading = corner == .bottomLeading
      for fraction in [0.3, 0.65, 1.0] {
        let length = size.width * fraction
        var stroke = Path()
        stroke.move(to: CGPoint(x: leading ? 0 : size.width, y: size.height - length))
        stroke.addLine(to: CGPoint(x: leading ? length : size.width - length, y: size.height))
        context.stroke(stroke, with: .color(DashboardPalette.tertiaryText), lineWidth: 1)
      }
    }
    .frame(width: Self.gripSize, height: Self.gripSize)
    .padding(Self.gripInset)
    .contentShape(Rectangle())
    .modifier(FrameResizeCursor(corner: corner))
    .gesture(
      DragGesture(minimumDistance: 0)
        .updating($dragStart) { _, start, _ in
          guard start == nil, let window = panel.window else { return }
          let remembered = CGSize(width: width, height: height)
          start = DragStart(
            pointer: NSEvent.mouseLocation,
            frame: window.frame,
            size: MenuBarPanelSize.fitted(remembered, within: window.screen?.visibleFrame.size)
          )
        }
        .onChanged { _ in resize(following: NSEvent.mouseLocation) }
    )
    .help("Drag to resize")
    .accessibilityHidden(true)
  }

  private func resize(following pointer: NSPoint) {
    guard let start = dragStart,
      let window = panel.window,
      let screen = window.screen ?? NSScreen.main
    else { return }

    let resized = MenuBarPanelSize.resize(
      frame: start.frame,
      size: start.size,
      corner: corner,
      pointerDelta: CGSize(width: pointer.x - start.pointer.x, height: pointer.y - start.pointer.y),
      visibleFrame: screen.visibleFrame
    )
    width = Double(resized.size.width)
    height = Double(resized.size.height)
    // The panel only grows on its own when its content does, so set the frame
    // directly to shrink it and to keep the top edge under the menu bar.
    window.setFrame(resized.frame, display: true)
  }
}

/// Looks up the window hosting a view on demand, here the MenuBarExtra panel.
private final class WindowAnchor {
  weak var view: NSView?

  var window: NSWindow? { view?.window }
}

/// Anchors the MenuBarExtra panel and reports the visible size of the screen it
/// is on whenever it opens, moves to another display, or that display's visible
/// area changes (Dock resize, resolution change).
private struct PanelWindowReader: NSViewRepresentable {
  let anchor: WindowAnchor
  let onScreenChange: (CGSize?) -> Void

  func makeNSView(context: Context) -> ReportingView {
    let view = ReportingView()
    view.onScreenChange = onScreenChange
    anchor.view = view
    return view
  }

  func updateNSView(_ view: ReportingView, context: Context) {
    view.onScreenChange = onScreenChange
    anchor.view = view
  }

  final class ReportingView: NSView {
    var onScreenChange: ((CGSize?) -> Void)?

    /// Never takes clicks, so the grips' drag gestures receive them.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
      super.viewWillMove(toWindow: newWindow)
      NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window else { return }

      let center = NotificationCenter.default
      center.addObserver(
        self,
        selector: #selector(screenDidChange),
        name: NSWindow.didChangeScreenNotification,
        object: window
      )
      center.addObserver(
        self,
        selector: #selector(screenDidChange),
        name: NSApplication.didChangeScreenParametersNotification,
        object: nil
      )
      // Deferred: the view can join its window during a SwiftUI update, which
      // must not write view state.
      DispatchQueue.main.async { [weak self] in
        self?.reportScreen()
      }
    }

    @objc private func screenDidChange(_ notification: Notification) {
      reportScreen()
    }

    private func reportScreen() {
      onScreenChange?(window?.screen?.visibleFrame.size)
    }
  }
}

/// Diagonal resize pointer where macOS offers one (15+); older systems keep the arrow.
private struct FrameResizeCursor: ViewModifier {
  let corner: MenuBarPanelCorner

  func body(content: Content) -> some View {
    if #available(macOS 15.0, *) {
      content.pointerStyle(
        .frameResize(position: corner == .bottomLeading ? .bottomLeading : .bottomTrailing, directions: .all)
      )
    } else {
      content
    }
  }
}

private struct DetachDashboardControl: View {
  let onOpen: () -> Void
  let onDragStart: (NSPoint) -> Void
  let onMove: (NSPoint) -> Void
  let onDragEnd: () -> Void

  @State private var isHovering = false
  @State private var hasDetached = false
  @State private var suppressOpen = false

  var body: some View {
    Button {
      if !suppressOpen {
        onOpen()
      }
    } label: {
      Image(systemName: "macwindow")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(isHovering ? DashboardPalette.primaryText : DashboardPalette.secondaryText)
        .frame(width: 28, height: 28)
        .background(DashboardPalette.primaryText.opacity(isHovering ? 0.11 : 0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .simultaneousGesture(
      DragGesture(minimumDistance: 6)
        .onChanged { _ in
          let point = NSEvent.mouseLocation
          if hasDetached {
            onMove(point)
          } else {
            hasDetached = true
            suppressOpen = true
            onDragStart(point)
          }
        }
        .onEnded { _ in
          hasDetached = false
          onDragEnd()
          DispatchQueue.main.async {
            suppressOpen = false
          }
        }
    )
    .help("Click or drag to detach the dashboard")
    .accessibilityLabel("Detach dashboard")
  }
}

// MARK: - Overview

private struct OverviewCard: View {
  let providers: [ProviderUsage]
  let accountCount: Int
  let failureCount: Int
  let tint: Color
  let kindColors: LimitKindColors
  let primaryColors: [String: String]
  let accounts: [ProviderAccount]
  let now: Date
  let bestAccount: HeadroomRanking.Candidate?
  let onSelect: (String) -> Void

  private static let captionFontSize: CGFloat = 11
  private static let metricLabelSuffixes = [" remaining", " limit", " quota"]
  private static let resetDue = "reset"

  private var lowestRemaining: Int? {
    providers.compactMap(MenuBarQuotaStyling.remainingPercent).min()
  }

  private var metricCount: Int {
    providers.reduce(0) { $0 + $1.metrics.count }
  }

  var body: some View {
    VStack(spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        SectionTitle(text: "OVERVIEW")
        Text(QuotaDisplayText.countPhrase(metricCount, singular: "METRIC", plural: "METRICS"))
          .font(.system(size: 9, weight: .semibold))
          .tracking(0.6)
          .foregroundStyle(DashboardPalette.tertiaryText)
      }

      if !providers.isEmpty {
        // Every account gets a gauge. Rows wrap, so a wider panel fits more per row.
        OverviewGaugeGrid(rowSpacing: 10) {
          ForEach(providers) { provider in
            let remaining = MenuBarQuotaStyling.remainingPercent(for: provider)
            let metric = MenuBarQuotaStyling.constrainingMetric(for: provider)
            let caption = accountGaugeCaption(for: provider)
            let reset = metric?.resetCountdown(at: now)

            Button {
              onSelect(provider.accountID)
            } label: {
              VStack(spacing: 5) {
                if remaining == nil,
                   let balance = provider.metrics.first(where: { !$0.isUnlimited && $0.usageLine != nil })?.usageLine {
                  Text(balance)
                    .font(.system(size: Self.captionFontSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(height: 40)
                } else {
                  GlossRing(
                    remaining: remaining,
                    unlimited: provider.metrics.allSatisfy(\.isUnlimited) && !provider.metrics.isEmpty,
                    tint: LimitKindColorScheme.accountAccent(
                      for: provider.metrics,
                      colors: kindColors,
                      step: accountColorStep(forAccountID: provider.accountID, in: accounts),
                      primaryHexColor: primaryColors[provider.accountID]
                    ),
                    isEstimated: MenuBarQuotaStyling.isPercentageEstimated(for: provider),
                    diameter: 40,
                    lineWidth: 4.5
                  )
                }
                Text(provider.title)
                  .font(.system(size: Self.captionFontSize, weight: .medium))
                  .foregroundStyle(DashboardPalette.secondaryText)
                  .lineLimit(2, reservesSpace: true)
                  .multilineTextAlignment(.center)
                  .fixedSize(horizontal: false, vertical: true)
                  .frame(maxWidth: .infinity)

                ViewThatFits(in: .horizontal) {
                  if let reset {
                    Text("\(caption) · \(reset == Self.resetDue ? "Reset due" : reset)")
                      .lineLimit(1)
                      .fixedSize(horizontal: true, vertical: true)
                  }
                  Text(caption)
                    .lineLimit(2, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: Self.captionFontSize))
                .foregroundStyle(DashboardPalette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
              }
              .frame(maxWidth: .infinity)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(accountGaugeAccessibilityLabel(for: provider))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accountGaugeAccessibilityLabel(for: provider))
          }
        }

        Rectangle()
          .fill(DashboardPalette.hairline)
          .frame(height: 1)
      }

      HStack(spacing: 0) {
        StatCell(
          label: "LOWEST",
          value: lowestRemaining.map { remaining in
            let estimated = providers.contains {
              MenuBarQuotaStyling.remainingPercent(for: $0) == remaining
                && MenuBarQuotaStyling.isPercentageEstimated(for: $0)
            }
            return "\(estimated ? "≈" : "")\(remaining)%"
          } ?? "--",
          tint: tint
        )
        statDivider
        StatCell(label: accountCount == 1 ? "ACCOUNT" : "ACCOUNTS", value: "\(accountCount)", tint: DashboardPalette.primaryText)
        statDivider
        StatCell(
          label: failureCount == 1 ? "ISSUE" : "ISSUES",
          value: "\(failureCount)",
          tint: failureCount == 0 ? DashboardPalette.success : DashboardPalette.warning
        )
      }

      if let bestAccount, case .percent(let remaining) = bestAccount.headroom {
        Rectangle().fill(DashboardPalette.hairline).frame(height: 1)
        HStack(spacing: 6) {
          Image(systemName: "trophy.fill").accessibilityHidden(true)
          Text("Best to burn")
          Spacer(minLength: 4)
          Text(bestAccount.usage.title).lineLimit(2)
          Text("\(bestAccount.isEstimated ? "≈" : "")\(max(0, min(100, remaining)))%")
            .monospacedDigit()
        }
        .font(.system(size: Self.captionFontSize, weight: .semibold))
        .foregroundStyle(DashboardPalette.secondaryText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Best account to use: \(bestAccount.usage.title), \(bestAccount.isEstimated ? "estimated " : "")\(remaining) percent remaining")
      }
    }
    .padding(OverviewGaugeLayout.cardPadding)
    .dashboardCard()
  }

  private var statDivider: some View {
    Rectangle()
      .fill(DashboardPalette.hairline)
      .frame(width: 1, height: 26)
  }

  private func accountGaugeAccessibilityLabel(for provider: ProviderUsage) -> String {
    if provider.metrics.allSatisfy(\.isUnlimited), !provider.metrics.isEmpty {
      return "\(provider.title), unlimited. Jump to card."
    }
    if let metric = MenuBarQuotaStyling.constrainingMetric(for: provider),
       let remaining = MenuBarQuotaStyling.remainingPercent(for: provider) {
      let qualifier = MenuBarQuotaStyling.isPercentageEstimated(for: provider) ? "estimated " : ""
      return "\(provider.title), limiting metric: \(metric.label), \(qualifier)\(remaining) percent remaining. "
        + accountGaugeResetDescription(for: metric) + " Jump to card."
    }
    let balances = provider.metrics.filter { !$0.isUnlimited }.compactMap { metric in
      metric.usageLine.map { "\(metric.label) \($0)" }
    }
    if !balances.isEmpty {
      return "\(provider.title), \(balances.joined(separator: ", ")). Jump to card."
    }
    return "\(provider.title), quota unavailable. Jump to card."
  }

  private func accountGaugeCaption(for provider: ProviderUsage) -> String {
    if let metric = MenuBarQuotaStyling.constrainingMetric(for: provider) {
      let label = metric.label.trimmingCharacters(in: .whitespacesAndNewlines)
      let shortened = Self.metricLabelSuffixes.first(where: { label.lowercased().hasSuffix($0) })
        .map { String(label.dropLast($0.count)) } ?? label
      return (MenuBarQuotaStyling.isPercentageEstimated(for: provider) ? "≈ " : "")
        + (shortened.isEmpty ? "Quota" : shortened)
    }
    if !provider.metrics.isEmpty, provider.metrics.allSatisfy(\.isUnlimited) { return "Unlimited" }
    return provider.metrics.first(where: { !$0.isUnlimited && $0.usageLine != nil })?.label ?? "Unavailable"
  }

  private func accountGaugeResetDescription(for metric: UsageMetric) -> String {
    guard let countdown = metric.resetCountdown(at: now) else { return "Reset unavailable." }
    let description = countdown == Self.resetDue ? "Reset due" : "Resets in \(countdown)"
    guard let resetAt = metric.resetAt else { return description + "." }
    return "\(description) (\(resetAt.formatted(date: .abbreviated, time: .shortened)))."
  }
}

/// Uses the geometry harness's balanced rows for native placement.
private struct OverviewGaugeGrid: Layout {
  let rowSpacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    let rows = OverviewGaugeLayout.rows(count: subviews.count, width: width)
    let cellWidth = OverviewGaugeLayout.cellWidth(columns: rows.first ?? 0, width: width)
    let heights = rowHeights(rows, subviews: subviews, cellWidth: cellWidth)
    return CGSize(width: width.isFinite ? width : rowWidth(rows.first ?? 0, cellWidth: cellWidth),
                  height: heights.reduce(0, +) + rowSpacing * CGFloat(max(0, rows.count - 1)))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let rows = OverviewGaugeLayout.rows(count: subviews.count, width: bounds.width)
    let cellWidth = OverviewGaugeLayout.cellWidth(columns: rows.first ?? 0, width: bounds.width)
    let heights = rowHeights(rows, subviews: subviews, cellWidth: cellWidth)
    var start = 0
    var y = bounds.minY
    for (row, length) in rows.enumerated() {
      var x = bounds.midX - rowWidth(length, cellWidth: cellWidth) / 2
      for view in subviews[start..<(start + length)] {
        view.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                   proposal: ProposedViewSize(width: cellWidth, height: heights[row]))
        x += cellWidth + OverviewGaugeLayout.columnSpacing
      }
      start += length
      y += heights[row] + rowSpacing
    }
  }

  private func rowHeights(_ rows: [Int], subviews: Subviews, cellWidth: CGFloat) -> [CGFloat] {
    var start = 0
    return rows.map { length in
      defer { start += length }
      return subviews[start..<(start + length)].map {
        $0.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height
      }.max() ?? 0
    }
  }

  private func rowWidth(_ length: Int, cellWidth: CGFloat) -> CGFloat {
    CGFloat(length) * cellWidth + OverviewGaugeLayout.columnSpacing * CGFloat(max(0, length - 1))
  }
}

private struct StatCell: View {
  let label: String
  let value: String
  let tint: Color

  var body: some View {
    VStack(spacing: 2) {
      Text(value)
        .font(.system(size: 18, weight: .bold, design: .rounded))
        .monospacedDigit()
        .contentTransition(.numericText())
        .foregroundStyle(DashboardPalette.primaryText)
      Circle().fill(tint)
        .overlay(Circle().stroke(DashboardPalette.markBacking, lineWidth: 0.75))
        .frame(width: 4, height: 4).accessibilityHidden(true)
      Text(label)
        .font(.system(size: 9, weight: .semibold))
        .tracking(0.7)
        .foregroundStyle(DashboardPalette.tertiaryText)
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Provider cards

private struct ProviderQuotaCard: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let usage: ProviderUsage
  let accountName: String?
  let failure: ProviderFailure?
  let kindColors: LimitKindColors
  let colorStep: Int
  let primaryHexColor: String?
  let now: Date
  let sparkBuilder: SparkSeriesBuilder

  @State private var isHovered = false

  private static let detailSeparator = " · "

  private var accent: Color {
    LimitKindColorScheme.accountAccent(for: usage.metrics, colors: kindColors, step: colorStep, primaryHexColor: primaryHexColor)
  }

  private var displayName: String {
    guard let accountName, !accountName.isEmpty else { return usage.title }
    return accountName
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack(spacing: 10) {
        ProviderMark(provider: usage.provider, tint: accent)

        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(displayName)
              .font(.system(size: 13, weight: .semibold))
              .lineLimit(1)

            if failure != nil {
              Text("LAST KNOWN")
                .font(.system(size: 8, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(DashboardPalette.warning)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(DashboardPalette.warning.opacity(0.13), in: Capsule())
            }
          }

          HStack(spacing: 0) {
            if !detailParts.isEmpty {
              Text(detailParts.joined(separator: Self.detailSeparator)).truncationMode(.middle)
            }
            Text(detailParts.isEmpty ? fetchedAge : Self.detailSeparator + fetchedAge)
              .fixedSize()
              .layoutPriority(1)
          }
          .font(.system(size: 10.5))
          .foregroundStyle(DashboardPalette.secondaryText)
          .lineLimit(1)
          .help((detailParts + [fetchedAge]).joined(separator: Self.detailSeparator))
          .accessibilityElement(children: .combine)
        }

        Spacer(minLength: 8)

        if MenuBarQuotaStyling.remainingPercent(for: usage) != nil
          || usage.metrics.allSatisfy({ $0.usageLine == nil }) {
          GlossRing(
            remaining: MenuBarQuotaStyling.remainingPercent(for: usage),
            unlimited: usage.metrics.allSatisfy(\.isUnlimited) && !usage.metrics.isEmpty,
            tint: accent,
            isEstimated: MenuBarQuotaStyling.isPercentageEstimated(for: usage)
          )
        }
      }

      let metricColors = LimitKindColorScheme.colors(for: usage.metrics, colors: kindColors, step: colorStep, primaryHexColor: primaryHexColor)

      VStack(spacing: 10) {
        ForEach(Array(usage.metrics.enumerated()), id: \.element.id) { index, metric in
          MetricQuotaRow(
            metric: metric,
            tint: metricColors[index],
            now: now,
            sparkPoints: sparkPoints(for: metric)
          )
        }
      }

      if let warning = usage.warning, !warning.isEmpty {
        statusLine(warning, systemImage: "exclamationmark.triangle.fill", color: DashboardPalette.warning)
      }

      if let failure {
        statusLine(failure.message, systemImage: "arrow.triangle.2.circlepath", color: DashboardPalette.warning)
      }
    }
    .padding(13)
    .dashboardCard(accent: accent, isHovered: isHovered)
    .scaleEffect(isHovered && !reduceMotion ? 1.006 : 1)
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.15)) {
        isHovered = hovering
      }
    }
    .accessibilityElement(children: .contain)
  }

  private func sparkPoints(for metric: UsageMetric) -> [SparkPoint] {
    guard !metric.isUnlimited else { return [] }

    var points = sparkBuilder.points(
      accountID: usage.accountID,
      provider: usage.provider,
      metricID: metric.id,
      metricLabel: metric.label,
      window: now.addingTimeInterval(-24 * 3_600)...now
    )
    // Extend the line to "now" at the live value so the spark never ends mid-window.
    if let remaining = metric.remainingPercent {
      points.append(SparkPoint(date: now, remaining: Double(max(0, min(100, remaining)))))
    }
    return points
  }

  private var detailParts: [String] {
    QuotaDisplayText.accountDetailParts(providerName: usage.provider.displayName, accountName: displayName, subtitle: usage.subtitle)
  }

  private var fetchedAge: String {
    "fetched \(QuotaDisplayText.relativeAge(usage.fetchedAt, now: now))"
  }

  private func statusLine(_ text: String, systemImage: String, color: Color) -> some View {
    Label {
      Text(text)
        .lineLimit(2)
    } icon: {
      Image(systemName: systemImage)
    }
    .font(.caption)
    .foregroundStyle(color)
  }
}

private struct ProviderMark: View {
  let provider: QuotaProvider
  let tint: Color

  var body: some View {
    Image(systemName: symbolName)
      .font(.system(size: 14, weight: .semibold))
      .foregroundStyle(DashboardPalette.primaryText)
      .frame(width: 30, height: 30)
      .background(
        LinearGradient(
          colors: [tint.opacity(0.34), tint.opacity(0.16)],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        ),
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(tint.opacity(0.35), lineWidth: 1)
      }
      .accessibilityHidden(true)
  }

  private var symbolName: String {
    switch provider {
    case .anthropic:
      return "text.bubble.fill"
    case .openAI:
      return "sparkles"
    case .gitHubCopilot:
      return "brain.head.profile"
    case .zhipu:
      return "bolt.fill"
    case .zai:
      return "bolt.horizontal.fill"
    case .kimi:
      return "moon.fill"
    case .googleAntigravity:
      return "cloud.fill"
    case .devin:
      return "terminal.fill"
    case .metaMuse:
      return "wand.and.stars"
    case .openCodeGo:
      return "curlybraces"
    case .venice:
      return "water.waves"
    case .cline:
      return "chevron.left.forwardslash.chevron.right"
    }
  }
}

private struct MetricQuotaRow: View {
  let metric: UsageMetric
  let tint: Color
  let now: Date
  let sparkPoints: [SparkPoint]

  private var remaining: Int? {
    metric.remainingPercent.map { max(0, min(100, $0)) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Text(metric.label)
          .font(.system(size: 11, weight: .medium))
          .lineLimit(1)

        Spacer(minLength: 4)

        if sparkPoints.count >= 3 {
          Sparkline(
            points: sparkPoints,
            tint: tint,
            start: now.addingTimeInterval(-24 * 3_600),
            end: now
          )
          .frame(width: 88, height: 15)
          .help("Last 24 hours")
        }

        Text(valueText)
          .font(.system(size: 11.5, weight: .bold, design: .rounded))
          .monospacedDigit()
          .contentTransition(.numericText())
          .foregroundStyle(valueColor)
          .accessibilityLabel(valueAccessibilityText)
      }

      if remaining != nil || metric.isUnlimited {
        GlossBar(progress: barProgress, tint: tint)
      }

      if secondaryUsageLine != nil || resetCountdown != nil {
        HStack(spacing: 8) {
          if let usageLine = secondaryUsageLine {
            Text(usageLine)
              .font(.system(size: 10))
              .foregroundStyle(DashboardPalette.tertiaryText)
              .lineLimit(1)
          }
          Spacer(minLength: 4)
          if let resetCountdown {
            ResetChip(countdown: resetCountdown)
          }
        }
      }

      if let detail = metric.detail, !detail.isEmpty {
        Text(detail)
          .font(.system(size: 10))
          .foregroundStyle(DashboardPalette.tertiaryText)
          .lineLimit(2)
          // Two lines is the budget here, so hovering recovers anything the
          // row had to truncate.
          .help(detail)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var valueText: String {
    if metric.isUnlimited { return "Unlimited" }
    guard let remaining else { return metric.usageLine ?? "Unavailable" }
    return "\(metric.isPercentageEstimated ? "≈" : "")\(remaining)% left"
  }

  private var valueAccessibilityText: String {
    guard let remaining, !metric.isUnlimited else { return valueText }
    return "\(metric.isPercentageEstimated ? "Estimated " : "")\(remaining) percent remaining"
  }

  /// Row colors carry identity (which limit), so danger gets its own channel:
  /// the value text shifts to the reserved status accents when a limit runs
  /// low. The number itself is the label that makes the color readable.
  private var valueColor: Color {
    if metric.isUnlimited { return DashboardPalette.primaryText }
    guard let remaining else { return DashboardPalette.primaryText }
    return MenuBarQuotaStyling.dangerTierColor(for: remaining, healthy: DashboardPalette.primaryText)
  }

  private var secondaryUsageLine: String? {
    guard !metric.isUnlimited, remaining != nil else { return nil }
    return metric.usageLine
  }

  private var barProgress: Double {
    if metric.isUnlimited { return 1 }
    return Double(remaining ?? 0) / 100
  }

  private var resetCountdown: String? {
    metric.resetCountdown(at: now)
  }
}

private struct ProviderFailureCard: View {
  let failure: ProviderFailure
  let accountName: String?

  private var displayName: String {
    guard let accountName, !accountName.isEmpty else { return failure.provider.displayName }
    return accountName
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      ProviderMark(provider: failure.provider, tint: DashboardPalette.warning)

      VStack(alignment: .leading, spacing: 3) {
        Text(displayName)
          .font(.system(size: 13, weight: .semibold))
        if let providerName = QuotaDisplayText.accountDetailParts(providerName: failure.provider.displayName,
                                                                  accountName: displayName, subtitle: nil).first {
          Text(providerName)
            .font(.system(size: 10))
            .foregroundStyle(DashboardPalette.tertiaryText)
        }
        Text(failure.message)
          .font(.caption)
          .foregroundStyle(DashboardPalette.warning)
          .lineLimit(3)
      }

      Spacer(minLength: 0)
    }
    .padding(13)
    .dashboardCard(accent: DashboardPalette.warning)
  }
}

private enum MenuBarQuotaStyling {
  private static let criticalRemainingThreshold = 10
  private static let warningRemainingThreshold = 25
  static func constrainingMetric(for provider: ProviderUsage) -> UsageMetric? {
    guard let metric = dashboardPrimaryMetric(for: provider), !metric.isUnlimited, metric.remainingPercent != nil else { return nil }
    return metric
  }

  static func isPercentageEstimated(for provider: ProviderUsage) -> Bool {
    guard let remaining = constrainingMetric(for: provider)?.remainingPercent else { return false }
    return provider.metrics.contains {
      !$0.isUnlimited && $0.remainingPercent == remaining && $0.isPercentageEstimated
    }
  }

  static func remainingPercent(for provider: ProviderUsage) -> Int? {
    dashboardRemainingPercent(for: provider)
  }

  static func dangerTierColor(for remaining: Int, healthy: Color) -> Color {
    if remaining <= criticalRemainingThreshold { return DashboardPalette.danger }
    if remaining <= warningRemainingThreshold { return DashboardPalette.warning }
    return healthy
  }
}
