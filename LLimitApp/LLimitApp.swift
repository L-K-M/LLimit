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

private enum DashboardPalette {
  static let backgroundTop = Color(red: 0.10, green: 0.11, blue: 0.23)
  static let backgroundBottom = Color(red: 0.16, green: 0.18, blue: 0.36)
  static let card = Color.white.opacity(0.055)
  static let emphasizedCard = Color.white.opacity(0.075)
  static let hairline = Color.white.opacity(0.12)
  static let sectionTitle = Color(red: 0.70, green: 0.92, blue: 0.24)
  static let secondaryText = Color.white.opacity(0.62)
}

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
        startPoint: .topLeading,
        endPoint: .bottomTrailing
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
        ScrollView {
          LazyVStack(spacing: 10) {
            QuotaSummaryStrip(
              providers: providers,
              accountCount: accountCount,
              failureCount: snapshot.failures.count,
              tint: summaryTint(for: providers),
              globalStyle: model.widgetStyle,
              providerStyleSettings: model.providerStyleSettings
            )

            ForEach(providers) { provider in
              ProviderQuotaCard(
                usage: provider,
                accountName: model.account(withID: provider.accountID)?.displayName,
                failure: failuresByAccount[provider.accountID],
                globalStyle: model.widgetStyle,
                providerStyleSettings: model.providerStyleSettings,
                now: now
              )
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
        .scrollIndicators(.visible)
      }
    } else {
      emptyState
    }
  }

  private func dashboardHeader(now: Date) -> some View {
    HStack(spacing: 12) {
      ZStack {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .fill(
            LinearGradient(
              colors: [.cyan, .blue],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
        Image(systemName: "chart.bar.xaxis")
          .font(.system(size: 18, weight: .bold))
          .foregroundStyle(.white)
      }
      .frame(width: 40, height: 40)
      .shadow(color: .blue.opacity(0.35), radius: 8, y: 3)

      VStack(alignment: .leading, spacing: 1) {
        Text("LLimit")
          .font(.system(size: 18, weight: .bold, design: .rounded))

        if model.isRefreshing {
          Text("Updating quotas...")
            .foregroundStyle(DashboardPalette.secondaryText)
        } else if let snapshot = model.snapshot {
          Text("Updated \(relativeTimeString(from: snapshot.generatedAt, relativeTo: now))")
            .foregroundStyle(DashboardPalette.secondaryText)
        } else {
          Text("Waiting for quota data")
            .foregroundStyle(DashboardPalette.secondaryText)
        }
      }
      .font(.caption)

      Spacer()

      if model.isRefreshing {
        ProgressView()
          .controlSize(.small)
      } else if let snapshot = model.snapshot {
        Label(
          snapshot.failures.isEmpty ? "No reported issues" : "\(snapshot.failures.count) issue(s)",
          systemImage: snapshot.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .labelStyle(.iconOnly)
        .foregroundStyle(snapshot.failures.isEmpty ? .green : .orange)
        .help(snapshot.failures.isEmpty ? "No reported issues" : "\(snapshot.failures.count) account issue(s)")
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
    .padding(.vertical, 12)
    .background(Color.black.opacity(0.08))
  }

  private var emptyState: some View {
    VStack(spacing: 9) {
      Image(systemName: "gauge.with.dots.needle.0percent")
        .font(.system(size: 30, weight: .light))
        .foregroundStyle(DashboardPalette.sectionTitle)
      Text("No quota data yet")
        .font(.headline)
      Text("Refresh now to fetch your current limits.")
        .font(.caption)
        .foregroundStyle(DashboardPalette.secondaryText)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 280)
    }
    .frame(maxWidth: .infinity, minHeight: 190)
    .padding(20)
  }

  private var actionBar: some View {
    HStack(spacing: 8) {
      Button {
        Task {
          await model.refreshNow()
        }
      } label: {
        Label(model.isRefreshing ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
      }
      .keyboardShortcut("r", modifiers: .command)
      .disabled(model.isRefreshing)

      Spacer()

      Button {
        SettingsWindowController.shared.show(model: model)
      } label: {
        Label("Settings", systemImage: "gearshape")
      }
      .keyboardShortcut(",", modifiers: .command)

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
    .padding(.vertical, 11)
    .background(Color.black.opacity(0.08))
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
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(isHovering ? .white : DashboardPalette.secondaryText)
        .frame(width: 30, height: 30)
        .background(Color.white.opacity(isHovering ? 0.11 : 0.05), in: RoundedRectangle(cornerRadius: 8))
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

private struct QuotaSummaryStrip: View {
  let providers: [ProviderUsage]
  let accountCount: Int
  let failureCount: Int
  let tint: Color
  let globalStyle: WidgetStyleSettings
  let providerStyleSettings: [String: ProviderStyleSettings]

  private var lowestRemaining: Int? {
    providers.compactMap(MenuBarQuotaStyling.remainingPercent).min()
  }

  private var metricCount: Int {
    providers.reduce(0) { $0 + $1.metrics.count }
  }

  var body: some View {
    VStack(spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text("OVERVIEW")
          .font(.system(size: 11, weight: .bold))
          .tracking(0.8)
          .foregroundStyle(DashboardPalette.sectionTitle)
        Spacer()
        Text("\(metricCount) METRICS")
          .font(.system(size: 9, weight: .semibold))
          .tracking(0.6)
          .foregroundStyle(DashboardPalette.secondaryText)
      }

      HStack(spacing: 0) {
        SummaryValue(
          label: "LOWEST",
          value: lowestRemaining.map { "\($0)%" } ?? "--",
          tint: tint
        )
        SummaryValue(label: "ACCOUNTS", value: "\(accountCount)", tint: .white)
        SummaryValue(
          label: "ISSUES",
          value: "\(failureCount)",
          tint: failureCount == 0 ? .green : .orange
        )
      }

      if !providers.isEmpty {
        Rectangle()
          .fill(DashboardPalette.hairline)
          .frame(height: 1)

        HStack(alignment: .top, spacing: 6) {
          ForEach(Array(providers.prefix(5))) { provider in
            VStack(spacing: 5) {
              QuotaGauge(
                remaining: MenuBarQuotaStyling.remainingPercent(for: provider),
                unlimited: provider.metrics.allSatisfy(\.isUnlimited) && !provider.metrics.isEmpty,
                tint: Color(nsColor: MenuBarQuotaStyling.color(
                  for: provider,
                  globalStyle: globalStyle,
                  providerStyleSettings: providerStyleSettings
                ))
              )
              Text(provider.title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(DashboardPalette.secondaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accountGaugeAccessibilityLabel(for: provider))
          }
        }
      }
    }
    .padding(13)
    .background(DashboardPalette.emphasizedCard, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 13, style: .continuous)
        .strokeBorder(DashboardPalette.hairline, lineWidth: 1)
    }
  }

  private func accountGaugeAccessibilityLabel(for provider: ProviderUsage) -> String {
    if provider.metrics.allSatisfy(\.isUnlimited), !provider.metrics.isEmpty {
      return "\(provider.title), unlimited"
    }
    if let remaining = MenuBarQuotaStyling.remainingPercent(for: provider) {
      return "\(provider.title), \(remaining) percent remaining"
    }
    return "\(provider.title), quota unavailable"
  }
}

private struct SummaryValue: View {
  let label: String
  let value: String
  let tint: Color

  var body: some View {
    VStack(spacing: 2) {
      Text(value)
        .font(.system(size: 18, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(tint)
      Text(label)
        .font(.system(size: 9, weight: .semibold))
        .tracking(0.7)
        .foregroundStyle(DashboardPalette.secondaryText)
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }
}

private struct ProviderQuotaCard: View {
  let usage: ProviderUsage
  let accountName: String?
  let failure: ProviderFailure?
  let globalStyle: WidgetStyleSettings
  let providerStyleSettings: [String: ProviderStyleSettings]
  let now: Date

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
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        ProviderMark(provider: usage.provider, tint: accent)

        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(displayName)
              .font(.subheadline.weight(.semibold))
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
            .font(.caption)
            .foregroundStyle(DashboardPalette.secondaryText)
            .lineLimit(1)
        }

        Spacer(minLength: 8)

        QuotaGauge(
          remaining: MenuBarQuotaStyling.remainingPercent(for: usage),
          unlimited: usage.metrics.allSatisfy(\.isUnlimited) && !usage.metrics.isEmpty,
          tint: accent
        )
      }

      VStack(spacing: 9) {
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
            now: now
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
    .background(DashboardPalette.card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 13, style: .continuous)
        .strokeBorder(accent.opacity(0.2), lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
  }

  private var accountDetail: String {
    var parts = [usage.provider.displayName]
    if let subtitle = usage.subtitle, !subtitle.isEmpty, subtitle != accountName {
      parts.append(subtitle)
    }
    parts.append("fetched \(usage.fetchedAt.formatted(.relative(presentation: .named)))")
    return parts.joined(separator: "  |  ")
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
      .font(.system(size: 15, weight: .semibold))
      .foregroundStyle(tint)
      .frame(width: 32, height: 32)
      .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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

private struct QuotaGauge: View {
  let remaining: Int?
  let unlimited: Bool
  let tint: Color

  private var progress: Double {
    Double(max(0, min(100, remaining ?? 0))) / 100
  }

  var body: some View {
    ZStack {
      Circle()
        .stroke(tint.opacity(0.14), lineWidth: 5)
      Circle()
        .trim(from: 0, to: unlimited ? 1 : progress)
        .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
        .rotationEffect(.degrees(-90))

      Text(gaugeText)
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(tint)
    }
    .frame(width: 48, height: 48)
    .accessibilityLabel(accessibilityText)
  }

  private var gaugeText: String {
    if unlimited { return "ALL" }
    guard let remaining else { return "--" }
    return "\(max(0, min(100, remaining)))%"
  }

  private var accessibilityText: String {
    if unlimited { return "Unlimited" }
    guard let remaining else { return "Quota unavailable" }
    return "\(max(0, min(100, remaining))) percent remaining"
  }
}

private struct MetricQuotaRow: View {
  let metric: UsageMetric
  let tint: Color
  let now: Date

  private var remaining: Int? {
    metric.remainingPercent.map { max(0, min(100, $0)) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(metric.label)
          .font(.caption.weight(.medium))
          .lineLimit(1)
        Spacer()
        Text(valueText)
          .font(.caption.weight(.bold))
          .monospacedDigit()
          .foregroundStyle(metric.isUnlimited ? tint : .primary)
      }

      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          Capsule()
            .fill(tint.opacity(0.12))
          Capsule()
            .fill(tint.gradient)
            .frame(width: geometry.size.width * barProgress)
        }
      }
      .frame(height: 6)

      if secondaryUsageLine != nil || resetText != nil {
        HStack(spacing: 8) {
          if let usageLine = secondaryUsageLine {
            Text(usageLine)
              .lineLimit(1)
          }
          Spacer(minLength: 4)
          if let reset = resetText {
            Text(reset)
              .lineLimit(1)
          }
        }
        .font(.caption2)
        .foregroundStyle(DashboardPalette.secondaryText)
      }

      if let detail = metric.detail, !detail.isEmpty {
        Text(detail)
          .font(.caption2)
          .foregroundStyle(DashboardPalette.secondaryText)
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

  private var resetText: String? {
    guard let countdown = metric.resetCountdown(at: now) else { return nil }
    return countdown == "reset" ? "Reset due" : "Resets in \(countdown)"
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
          .font(.subheadline.weight(.semibold))
        Text(failure.provider.displayName)
          .font(.caption2)
          .foregroundStyle(DashboardPalette.secondaryText)
        Text(failure.message)
          .font(.caption)
          .foregroundStyle(.orange)
          .lineLimit(3)
      }

      Spacer(minLength: 0)
    }
    .padding(13)
    .background(DashboardPalette.card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 13, style: .continuous)
        .strokeBorder(.orange.opacity(0.22), lineWidth: 1)
    }
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
