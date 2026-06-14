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
    MenuBarExtra {
      MenuBarContent(model: model)
    } label: {
      MenuBarIcon(
        snapshot: model.snapshot,
        widgetStyle: model.widgetStyle,
        providerStyleSettings: model.providerStyleSettings
      )
    }

    Settings {
      SettingsView(model: model)
    }
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

private struct MenuBarContent: View {
  @ObservedObject var model: AppModel
  @Environment(\.openSettings) private var openSettings

  private static let relativeTimeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
  }()

  var body: some View {
    if let snapshot = model.snapshot, !snapshot.providers.isEmpty {
      let providers = providersForMenu(from: snapshot)

      ForEach(providers) { provider in
        Section {
          ForEach(provider.metrics) { metric in
            Text(primaryLine(for: metric))

            if let secondary = secondaryLine(for: metric) {
              Text(secondary)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }

          if let warning = provider.warning, !warning.isEmpty {
            Text("Warning: \(warning)")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        } header: {
          Text(providerHeader(for: provider))
        }
      }

      if !snapshot.failures.isEmpty {
        Divider()
        ForEach(snapshot.failures.sorted(by: { $0.accountID < $1.accountID })) { failure in
          Text("\(failure.provider.displayName): \(failure.message)")
            .font(.caption)
        }
      }

      Divider()
      Text("Updated \(relativeTimeString(from: snapshot.generatedAt))")
        .font(.caption)
        .foregroundStyle(.secondary)
    } else {
      Text("No quota data yet")
        .font(.caption)
      Text("Use Refresh Now to fetch quotas")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    Divider()

    Button("Refresh Now") {
      Task {
        await model.refreshNow()
      }
    }
    .keyboardShortcut("r", modifiers: .command)
    .disabled(model.isRefreshing)

    Button("Open Settings") {
      openSettings()
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
    .keyboardShortcut(",", modifiers: .command)

    Divider()

    Toggle("Launch at Login", isOn: model.launchAtLoginBinding())

    Divider()

    Button("Quit LLimit") {
      NSApplication.shared.terminate(nil)
    }
    .keyboardShortcut("q", modifiers: .command)
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

  private func providerHeader(for provider: ProviderUsage) -> String {
    var title = provider.title

    if let subtitle = provider.subtitle, !subtitle.isEmpty {
      title += " (\(subtitle))"
    }

    if provider.metrics.contains(where: { !$0.isUnlimited }) {
      if let remaining = MenuBarQuotaStyling.remainingPercent(for: provider) {
        title += " - \(remaining)% left"
      }
    } else if provider.metrics.contains(where: \.isUnlimited) {
      title += " - Unlimited"
    }

    return title
  }

  private func primaryLine(for metric: UsageMetric) -> String {
    if metric.isUnlimited {
      return "\(metric.label): Unlimited"
    }

    if let remaining = metric.remainingPercent {
      if let usageLine = metric.usageLine {
        return "\(metric.label): \(remaining)% left (\(usageLine))"
      }
      return "\(metric.label): \(remaining)% left"
    }

    if let usageLine = metric.usageLine {
      return "\(metric.label): \(usageLine)"
    }

    return metric.label
  }

  private func secondaryLine(for metric: UsageMetric) -> String? {
    guard let resetIn = metric.resetIn, !resetIn.isEmpty else {
      return nil
    }

    return "Resets in \(resetIn)"
  }

  private func relativeTimeString(from date: Date) -> String {
    Self.relativeTimeFormatter.localizedString(for: date, relativeTo: Date())
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
