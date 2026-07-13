import SwiftUI
import AppKit
import QuotaCore

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
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
        widgetStyle: model.widgetStyle,
        providerStyleSettings: model.providerStyleSettings
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
final class SettingsWindowController {
  static let shared = SettingsWindowController()
  private var window: NSWindow?

  func show(model: AppModel) {
    if window == nil {
      let hosting = NSHostingController(rootView: SettingsView(model: model))
      hosting.sizingOptions = []

      let window = NSWindow(contentViewController: hosting)
      window.title = "LLimit"
      window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
      window.isReleasedWhenClosed = false
      window.setContentSize(NSSize(width: 960, height: 680))
      window.contentMinSize = NSSize(width: 720, height: 480)
      window.setFrameAutosaveName("LLimitSettingsWindow")
      window.center()
      self.window = window
    }

    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
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
  let widgetStyle: WidgetStyleSettings
  let providerStyleSettings: [String: ProviderStyleSettings]

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
        let remaining = MenuBarQuotaStyling.remainingPercent(for: provider) ?? 0
        let normalized = CGFloat(max(0, min(100, remaining))) / 100.0
        let barHeight = max(2, normalized * iconHeight)

        let barRect = NSRect(x: x, y: 0, width: barWidth, height: barHeight)
        let barPath = NSBezierPath(roundedRect: barRect, xRadius: cornerRadius, yRadius: cornerRadius)

        MenuBarQuotaStyling
          .color(for: provider, globalStyle: widgetStyle, providerStyleSettings: providerStyleSettings)
          .setFill()
        barPath.fill()
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

    return snapshot.providers.sorted { lhs, rhs in
      let lhsRemaining = MenuBarQuotaStyling.remainingPercent(for: lhs) ?? Int.max
      let rhsRemaining = MenuBarQuotaStyling.remainingPercent(for: rhs) ?? Int.max

      if lhsRemaining != rhsRemaining {
        return lhsRemaining < rhsRemaining
      }

      return lhs.title < rhs.title
    }
  }

  private func fallbackIcon() -> NSImage {
    let image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "LLimit")
      ?? NSImage(size: NSSize(width: 18, height: 16))
    image.isTemplate = true
    return image
  }
}

// MARK: - Dashboard design system

/// Graphite-glass palette for the dropdown/floating dashboard. Accent color always
/// comes from the user's quota style settings (see MenuBarQuotaStyling); nothing
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
    return "\(max(0, min(100, remaining)))%"
  }

  private var accessibilityText: String {
    if unlimited { return "Unlimited" }
    guard let remaining else { return "Quota unavailable" }
    return "\(max(0, min(100, remaining))) percent remaining"
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
    .foregroundStyle(isDue ? Color.orange : DashboardPalette.tertiaryText)
    .lineLimit(1)
    .accessibilityLabel(isDue ? "Reset due" : "Resets in \(countdown)")
  }
}

// MARK: - Dashboard

private struct MenuBarContent: View {
  @ObservedObject var model: AppModel
  let presentation: DashboardPresentation

  private static let relativeTimeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
  }()

  var body: some View {
    VStack(spacing: 0) {
      TimelineView(.periodic(from: .now, by: 60)) { context in
        VStack(spacing: 0) {
          dashboardHeader(now: context.date)
          dashboardDivider
          dashboard(now: context.date)
            .frame(
              minHeight: presentation == .menuBar ? 320 : 380,
              idealHeight: presentation == .menuBar ? 510 : nil,
              maxHeight: presentation == .menuBar ? 510 : .infinity
            )
        }
      }

      dashboardDivider
      actionBar
    }
    .frame(width: presentation == .menuBar ? 420 : nil)
    .frame(minWidth: 390, idealWidth: 430, maxWidth: presentation == .floating ? .infinity : 420)
    .frame(minHeight: presentation == .floating ? 440 : nil, maxHeight: presentation == .floating ? .infinity : nil)
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
                failureCount: snapshot.failures.count,
                tint: summaryTint(for: providers),
                globalStyle: model.widgetStyle,
                providerStyleSettings: model.providerStyleSettings,
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
                  globalStyle: model.widgetStyle,
                  providerStyleSettings: model.providerStyleSettings,
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
    .padding(.horizontal, 14)
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

    return Color(nsColor: MenuBarQuotaStyling.color(
      for: provider,
      globalStyle: model.widgetStyle,
      providerStyleSettings: model.providerStyleSettings
    ))
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
  let globalStyle: WidgetStyleSettings
  let providerStyleSettings: [String: ProviderStyleSettings]
  let onSelect: (String) -> Void

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
        HStack(alignment: .top, spacing: 6) {
          ForEach(Array(providers.prefix(5))) { provider in
            Button {
              onSelect(provider.accountID)
            } label: {
              VStack(spacing: 5) {
                GlossRing(
                  remaining: MenuBarQuotaStyling.remainingPercent(for: provider),
                  unlimited: provider.metrics.allSatisfy(\.isUnlimited) && !provider.metrics.isEmpty,
                  tint: Color(nsColor: MenuBarQuotaStyling.color(
                    for: provider,
                    globalStyle: globalStyle,
                    providerStyleSettings: providerStyleSettings
                  )),
                  diameter: 40,
                  lineWidth: 4.5
                )
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

          if providers.count > 5 {
            VStack(spacing: 5) {
              ZStack {
                Circle()
                  .stroke(Color.white.opacity(0.08), lineWidth: 4.5)
                Text("+\(providers.count - 5)")
                  .font(.system(size: 11, weight: .bold, design: .rounded))
                  .foregroundStyle(DashboardPalette.secondaryText)
              }
              .frame(width: 40, height: 40)
              Text("more")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(DashboardPalette.tertiaryText)
            }
            .frame(maxWidth: .infinity)
          }
        }

        Rectangle()
          .fill(DashboardPalette.hairline)
          .frame(height: 1)
      }

      HStack(spacing: 0) {
        StatCell(
          label: "LOWEST",
          value: lowestRemaining.map { "\($0)%" } ?? "--",
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
      return "\(provider.title), \(remaining) percent remaining. Jump to card."
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
  let globalStyle: WidgetStyleSettings
  let providerStyleSettings: [String: ProviderStyleSettings]
  let now: Date
  let sparkBuilder: SparkSeriesBuilder

  @State private var isHovered = false

  private var accent: Color {
    Color(nsColor: MenuBarQuotaStyling.color(
      for: usage,
      globalStyle: globalStyle,
      providerStyleSettings: providerStyleSettings
    ))
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

        GlossRing(
          remaining: MenuBarQuotaStyling.remainingPercent(for: usage),
          unlimited: usage.metrics.allSatisfy(\.isUnlimited) && !usage.metrics.isEmpty,
          tint: accent
        )
      }

      VStack(spacing: 10) {
        ForEach(Array(usage.metrics.enumerated()), id: \.element.id) { index, metric in
          MetricQuotaRow(
            metric: metric,
            tint: Color(nsColor: MenuBarQuotaStyling.color(
              for: metric,
              accountID: usage.accountID,
              layer: index == 0 ? .outer : .inner,
              globalStyle: globalStyle,
              providerStyleSettings: providerStyleSettings
            )),
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
    case .googleAntigravity:
      return "cloud.fill"
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
          .foregroundStyle(metric.isUnlimited ? tint : .white.opacity(0.92))
      }

      GlossBar(progress: barProgress, tint: tint)

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
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var valueText: String {
    if metric.isUnlimited { return "Unlimited" }
    guard let remaining else { return metric.usageLine ?? "Unavailable" }
    return "\(remaining)% left"
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

  static func color(
    for provider: ProviderUsage,
    globalStyle: WidgetStyleSettings,
    providerStyleSettings: [String: ProviderStyleSettings]
  ) -> NSColor {
    let style = effectiveStyle(for: provider.accountID, globalStyle: globalStyle, providerStyleSettings: providerStyleSettings)

    guard let role = colorRole(for: provider) else {
      return .systemGray
    }

    let hex = style.ringColors.hexColor(for: role, layer: .outer)
    return NSColor(hexString: hex) ?? .systemGray
  }

  static func color(
    for metric: UsageMetric,
    accountID: String,
    layer: WidgetRingLayer,
    globalStyle: WidgetStyleSettings,
    providerStyleSettings: [String: ProviderStyleSettings]
  ) -> NSColor {
    let style = effectiveStyle(for: accountID, globalStyle: globalStyle, providerStyleSettings: providerStyleSettings)

    guard let role = colorRole(for: metric) else {
      return .systemGray
    }

    let hex = style.ringColors.hexColor(for: role, layer: layer)
    return NSColor(hexString: hex) ?? .systemGray
  }

  private static func colorRole(for provider: ProviderUsage) -> WidgetRingColorRole? {
    let boundedRemaining = provider.metrics
      .filter { !$0.isUnlimited }
      .compactMap(\.remainingPercent)

    if let minimumRemaining = boundedRemaining.min() {
      let remaining = clampPercent(minimumRemaining)
      if remaining >= 70 { return .high }
      if remaining >= 40 { return .medium }
      return .low
    }

    if provider.metrics.contains(where: \.isUnlimited) {
      return .unlimited
    }

    if let maxUsagePercent = provider.maxUsagePercent {
      let remaining = clampPercent(100 - maxUsagePercent)
      if remaining >= 70 { return .high }
      if remaining >= 40 { return .medium }
      return .low
    }

    return nil
  }

  private static func colorRole(for metric: UsageMetric) -> WidgetRingColorRole? {
    if metric.isUnlimited {
      return .unlimited
    }

    guard let value = metric.remainingPercent else {
      return nil
    }

    let remaining = clampPercent(value)
    if remaining >= 70 { return .high }
    if remaining >= 40 { return .medium }
    return .low
  }

  private static func effectiveStyle(
    for accountID: String,
    globalStyle: WidgetStyleSettings,
    providerStyleSettings: [String: ProviderStyleSettings]
  ) -> WidgetStyleSettings {
    guard let styleOverride = providerStyleSettings[accountID], styleOverride.useCustomStyle else {
      return globalStyle
    }

    return WidgetStyleSettings(
      backgroundHexColor: styleOverride.style.backgroundHexColor ?? globalStyle.backgroundHexColor,
      ringColors: styleOverride.style.ringColors,
      useTransparentBackground: styleOverride.style.useTransparentBackground
    )
  }

  private static func clampPercent(_ value: Int) -> Int {
    max(0, min(100, value))
  }
}

private extension NSColor {
  convenience init?(hexString: String) {
    var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
    if hex.hasPrefix("#") {
      hex.removeFirst()
    }

    if hex.count == 3 || hex.count == 4 {
      hex = hex.map { "\($0)\($0)" }.joined()
    }

    guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else {
      return nil
    }

    if hex.count == 6 {
      self.init(
        red: CGFloat((value >> 16) & 0xFF) / 255,
        green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255,
        alpha: 1
      )
    } else {
      self.init(
        red: CGFloat((value >> 24) & 0xFF) / 255,
        green: CGFloat((value >> 16) & 0xFF) / 255,
        blue: CGFloat((value >> 8) & 0xFF) / 255,
        alpha: CGFloat(value & 0xFF) / 255
      )
    }
  }
}
