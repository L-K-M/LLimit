import SwiftUI
import AppKit
import QuotaCore

final class AppDelegate: NSObject, NSApplicationDelegate {
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
  @StateObject private var model = AppModel()

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
        accounts: model.providerAccounts
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

/// Owns the optional always-on-top quota dashboard detached from the menu bar.
@MainActor
final class DashboardWindowController {
  static let shared = DashboardWindowController()
  private var window: NSPanel?

  func show(model: AppModel, near screenPoint: NSPoint? = nil, activate: Bool = true) {
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

  var body: some View {
    Image(nsImage: iconImage())
      .accessibilityLabel("LLimit")
  }

  private func iconImage() -> NSImage {
    let barWidth: CGFloat = 3
    let barSpacing: CGFloat = 1.5
    let iconHeight: CGFloat = 16
    let cornerRadius: CGFloat = 1

    let providers = orderedProviders()
    guard !providers.isEmpty else {
      return fallbackIcon()
    }

    let totalWidth = CGFloat(providers.count) * barWidth + CGFloat(max(0, providers.count - 1)) * barSpacing

    let image = NSImage(size: NSSize(width: totalWidth, height: iconHeight), flipped: false) { _ in
      for (index, provider) in providers.enumerated() {
        let x = CGFloat(index) * (barWidth + barSpacing)
        // Height carries the level; color matches the account's primary ring
        // and chart line regardless of which limit is most constrained.
        let accent = LimitKindColorScheme.primaryAccountAccent(
          for: provider.metrics,
          colors: kindColors,
          step: accountColorStep(forAccountID: provider.accountID, in: accounts),
          primaryHexColor: primaryColors[provider.accountID]
        )
        if let remaining = MenuBarQuotaStyling.remainingPercent(for: provider) {
          let normalized = CGFloat(max(0, min(100, remaining))) / 100.0
          let barHeight = max(2, normalized * iconHeight)
          let barRect = NSRect(x: x, y: 0, width: barWidth, height: barHeight)
          let barPath = NSBezierPath(roundedRect: barRect, xRadius: cornerRadius, yRadius: cornerRadius)
          NSColor(accent).setFill()
          barPath.fill()
        } else {
          // A balance without a quota total has no meaningful bar height.
          let marker = NSBezierPath(ovalIn: NSRect(x: x + 0.5, y: 6.5, width: barWidth - 1, height: 3))
          marker.lineWidth = 1
          NSColor(accent).setStroke()
          marker.stroke()
        }
      }
      return true
    }

    image.isTemplate = false
    return image
  }

  private func orderedProviders() -> [ProviderUsage] {
    guard let snapshot else {
      return []
    }

    return orderedUsageForAccounts(snapshot.providers, accounts: accounts)
  }

  private func fallbackIcon() -> NSImage {
    let image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "LLimit")
      ?? NSImage(size: NSSize(width: 18, height: 16))
    image.isTemplate = true
    return image
  }
}

// MARK: - Dashboard design system

/// Graphite-glass palette for the dropdown/floating dashboard. Accent colors
/// come from the limit-kind identity palette (LimitKindColorScheme); nothing
/// here should compete with those signal colors.
private enum DashboardPalette {
  static let backgroundTop = Color(red: 0.114, green: 0.122, blue: 0.153)
  static let backgroundBottom = Color(red: 0.062, green: 0.066, blue: 0.086)
  static let card = Color.white.opacity(0.055)
  static let cardHover = Color.white.opacity(0.085)
  static let hairline = Color.white.opacity(0.10)
  static let rimBottom = Color.white.opacity(0.03)
  static let sectionTitle = Color.white.opacity(0.48)
  static let secondaryText = Color.white.opacity(0.62)
  static let tertiaryText = Color.white.opacity(0.42)
  static let barTrack = Color.white.opacity(0.09)
  static let brandGradient = [Color(red: 0.33, green: 0.53, blue: 0.98), Color(red: 0.58, green: 0.40, blue: 0.95)]
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
                (accent ?? .white).opacity(accent == nil ? 0.14 : 0.30),
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

  var body: some View {
    ZStack {
      Circle()
        .stroke(Color.white.opacity(0.08), lineWidth: lineWidth)

      if progress > 0.001 {
        Circle()
          .trim(from: 0, to: progress)
          .stroke(
            AngularGradient(
              gradient: Gradient(colors: [tint.opacity(0.45), tint]),
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
        .font(.system(size: diameter * 0.27, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.94))
        .contentTransition(.numericText())
        .minimumScaleFactor(0.6)
        .lineLimit(1)
        .frame(width: diameter - lineWidth * 2.6)
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
            .fill(
              LinearGradient(colors: [tint.opacity(0.78), tint], startPoint: .leading, endPoint: .trailing)
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

/// Projects shared source observations into per-metric sparklines.
private struct SparkSeriesBuilder {
  let observations: [ProviderUsage]

  func points(
    accountID: String,
    provider: QuotaProvider,
    metricID: String,
    metricLabel: String
  ) -> [SparkPoint] {
    let resolvedID = Self.resolvedMetricID(id: metricID, label: metricLabel)
    var result: [SparkPoint] = []

    for usage in observations {
      guard usage.accountID == accountID, usage.provider == provider else { continue }
      guard let metric = usage.metrics.first(where: { metric in
        Self.resolvedMetricID(id: metric.id, label: metric.label) == resolvedID
      }) else { continue }

      if metric.isUnlimited {
        result.append(SparkPoint(date: usage.fetchedAt, remaining: 100))
      } else if let remaining = metric.remainingPercent {
        result.append(SparkPoint(date: usage.fetchedAt, remaining: Double(max(0, min(100, remaining)))))
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
    .foregroundStyle(isDue ? Color.orange : DashboardPalette.tertiaryText)
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

  private static let relativeTimeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
  }()

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
    .foregroundStyle(.white)
    .background {
      LinearGradient(
        colors: [DashboardPalette.backgroundTop, DashboardPalette.backgroundBottom],
        startPoint: .top,
        endPoint: .bottom
      )
    }
    .environment(\.colorScheme, .dark)
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
      let failuresByAccount = snapshot.failures.reduce(into: [String: ProviderFailure]()) { failures, failure in
        failures[failure.accountID] = failure
      }
      let providerIDs = Set(providers.map(\.accountID))
      let standaloneFailures = snapshot.failures
        .filter { !providerIDs.contains($0.accountID) }
        .sorted { failureTitle(for: $0) < failureTitle(for: $1) }
      let resultAccountCount = providerIDs.union(snapshot.failures.map(\.accountID)).count
      let accountCount = max(model.providerAccounts.filter(\.isEnabled).count, resultAccountCount)

      if providers.isEmpty && standaloneFailures.isEmpty {
        emptyState
      } else {
        let sparkBuilder = SparkSeriesBuilder(
          observations: QuotaObservations.extract(
            from: model.recentHistory + [snapshot],
            accounts: model.providerAccounts,
            window: now.addingTimeInterval(-24 * 3_600)...now
          )
        )

        ScrollViewReader { proxy in
          ScrollView {
            VStack(spacing: 10) {
              OverviewCard(
                providers: providers,
                accountCount: accountCount,
                failureCount: snapshot.failures.count,
                tint: summaryTint(for: providers),
                kindColors: model.widgetStyle.limitKindColors,
                primaryColors: model.primaryColorsByAccountID,
                accounts: model.providerAccounts,
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
            .padding(12)
          }
          .scrollIndicators(.automatic)
        }
      }
    } else {
      emptyState
    }
  }

  private func dashboardHeader(now: Date) -> some View {
    HStack(spacing: 10) {
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
            Text("Updating quotas...")
          } else if let snapshot = model.snapshot {
            Text("Updated \(relativeTimeString(from: snapshot.generatedAt, relativeTo: now))")
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
      } else if let snapshot = model.snapshot {
        if snapshot.failures.isEmpty {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.green.opacity(0.9))
            .help("All accounts reporting")
            .accessibilityLabel("All accounts reporting")
        } else {
          HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.system(size: 9, weight: .bold))
            Text("\(snapshot.failures.count)")
              .font(.system(size: 10.5, weight: .bold))
              .monospacedDigit()
          }
          .foregroundStyle(.orange)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(.orange.opacity(0.15), in: Capsule())
          .help("\(snapshot.failures.count) account issue(s)")
          .accessibilityLabel("\(snapshot.failures.count) account issues")
        }
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
    .background(Color.black.opacity(0.10))
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
          .foregroundStyle(.white.opacity(0.85))
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
    }
    .buttonStyle(.borderless)
    .font(.system(size: 13, weight: .medium))
    .foregroundStyle(.white.opacity(0.88))
    // Keeps the buttons clear of the menu bar panel's corner resize grips.
    .padding(.horizontal, presentation == .menuBar ? PanelResizeGrip.footprint + 4 : 14)
    .padding(.vertical, 10)
    .background(Color.black.opacity(0.10))
  }

  private func providersForMenu(from snapshot: QuotaSnapshot) -> [ProviderUsage] {
    snapshot.providers.sorted { lhs, rhs in
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

  private func relativeTimeString(from date: Date, relativeTo now: Date) -> String {
    Self.relativeTimeFormatter.localizedString(for: date, relativeTo: now)
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
          Color.white.opacity(isHovering && !isDisabled ? 0.09 : 0),
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
        .foregroundStyle(isHovering ? .white : DashboardPalette.secondaryText)
        .frame(width: 28, height: 28)
        .background(Color.white.opacity(isHovering ? 0.11 : 0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
  let onSelect: (String) -> Void

  // Six gauges per row at the default 420pt panel width.
  private static let gaugeColumns = [GridItem(.adaptive(minimum: 54), spacing: 6, alignment: .top)]

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
        Text("\(metricCount) METRICS")
          .font(.system(size: 9, weight: .semibold))
          .tracking(0.6)
          .foregroundStyle(DashboardPalette.tertiaryText)
      }

      if !providers.isEmpty {
        // Every account gets a gauge. Rows wrap, so a wider panel fits more per row.
        LazyVGrid(columns: Self.gaugeColumns, spacing: 10) {
          ForEach(providers) { provider in
            Button {
              onSelect(provider.accountID)
            } label: {
              VStack(spacing: 5) {
                if MenuBarQuotaStyling.remainingPercent(for: provider) == nil,
                   let balance = provider.metrics.compactMap(\.usageLine).first {
                  Text(balance)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(height: 40)
                } else {
                  GlossRing(
                    remaining: MenuBarQuotaStyling.remainingPercent(for: provider),
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
                  .font(.system(size: 9, weight: .medium))
                  .foregroundStyle(DashboardPalette.secondaryText)
                  .lineLimit(1)
                  .frame(maxWidth: .infinity)
              }
              .frame(maxWidth: .infinity)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Jump to \(provider.title)")
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
        StatCell(label: "ACCOUNTS", value: "\(accountCount)", tint: .white.opacity(0.92))
        statDivider
        StatCell(
          label: "ISSUES",
          value: "\(failureCount)",
          tint: failureCount == 0 ? .green : .orange
        )
      }
    }
    .padding(13)
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
    if let remaining = MenuBarQuotaStyling.remainingPercent(for: provider) {
      let qualifier = MenuBarQuotaStyling.isPercentageEstimated(for: provider) ? "estimated " : ""
      return "\(provider.title), \(qualifier)\(remaining) percent remaining. Jump to card."
    }
    let balances = provider.metrics.compactMap { metric in
      metric.usageLine.map { "\(metric.label) \($0)" }
    }
    if !balances.isEmpty {
      return "\(provider.title), \(balances.joined(separator: ", ")). Jump to card."
    }
    return "\(provider.title), quota unavailable. Jump to card."
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
        .foregroundStyle(tint)
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
                .foregroundStyle(.orange)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.orange.opacity(0.13), in: Capsule())
            }
          }

          Text(accountDetail)
            .font(.system(size: 10.5))
            .foregroundStyle(DashboardPalette.secondaryText)
            .lineLimit(1)
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
        statusLine(warning, systemImage: "exclamationmark.triangle.fill", color: .orange)
      }

      if let failure {
        statusLine(failure.message, systemImage: "arrow.triangle.2.circlepath", color: .orange)
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

    return sparkBuilder.points(
      accountID: usage.accountID,
      provider: usage.provider,
      metricID: metric.id,
      metricLabel: metric.label
    )
  }

  private var accountDetail: String {
    var parts = [usage.provider.displayName]
    if let subtitle = usage.subtitle, !subtitle.isEmpty, subtitle != accountName {
      parts.append(subtitle)
    }
    parts.append("fetched \(usage.fetchedAt.formatted(.relative(presentation: .named)))")
    return parts.joined(separator: " · ")
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
      .foregroundStyle(.white.opacity(0.95))
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
      return "chevron.left.forwardslash.chevron.right"
    case .zhipu, .zai:
      return "bolt.fill"
    case .kimi:
      return "moon.fill"
    case .googleAntigravity:
      return "cloud.fill"
    case .devin:
      return "terminal.fill"
    case .metaMuse:
      return "wand.and.stars"
    case .openCodeGo:
      return "chevron.left.forwardslash.chevron.right"
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
    if metric.isUnlimited { return tint }
    guard let remaining else { return .white.opacity(0.92) }
    if remaining <= 10 { return Color(red: 1.0, green: 0.36, blue: 0.32) }
    if remaining <= 25 { return .orange }
    return .white.opacity(0.92)
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
      ProviderMark(provider: failure.provider, tint: .orange)

      VStack(alignment: .leading, spacing: 3) {
        Text(displayName)
          .font(.system(size: 13, weight: .semibold))
        Text(failure.provider.displayName)
          .font(.system(size: 10))
          .foregroundStyle(DashboardPalette.tertiaryText)
        Text(failure.message)
          .font(.caption)
          .foregroundStyle(.orange)
          .lineLimit(3)
      }

      Spacer(minLength: 0)
    }
    .padding(13)
    .dashboardCard(accent: .orange)
  }
}

private enum MenuBarQuotaStyling {
  static func isPercentageEstimated(for provider: ProviderUsage) -> Bool {
    guard let remaining = remainingPercent(for: provider) else { return false }
    return provider.metrics.contains {
      !$0.isUnlimited && $0.remainingPercent == remaining && $0.isPercentageEstimated
    }
  }

  static func remainingPercent(for provider: ProviderUsage) -> Int? {
    let boundedRemaining = provider.metrics
      .filter { !$0.isUnlimited }
      .compactMap(\.remainingPercent)

    if let minimumRemaining = boundedRemaining.min() {
      return clampPercent(minimumRemaining)
    }

    if provider.metrics.contains(where: \.isUnlimited) {
      return 100
    }

    if let maxUsagePercent = provider.maxUsagePercent {
      return clampPercent(100 - maxUsagePercent)
    }

    return nil
  }

  private static func clampPercent(_ value: Int) -> Int {
    max(0, min(100, value))
  }
}

