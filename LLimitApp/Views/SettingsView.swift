import SwiftUI
import QuotaCore

struct SettingsView: View {
  @ObservedObject var model: AppModel

  private let refreshIntervalOptions = [15, 30, 45, 60, 90, 120, 180]

  var body: some View {
    TabView {
      sourcesTab
        .tabItem { Label("Sources", systemImage: "key.fill") }
      generalTab
        .tabItem { Label("General", systemImage: "gearshape") }
      appearanceTab
        .tabItem { Label("Appearance", systemImage: "paintpalette") }
    }
    .frame(minWidth: 560, minHeight: 540)
  }

  // MARK: - Sources

  private var sourcesTab: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Detected accounts")
            .font(.title3.weight(.semibold))
          Text("LLimit reads usage from AI tools you're already signed in to — no tokens to paste. Sign in with Claude Code, Codex, GitHub Copilot or OpenCode, then Rescan.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        HStack(spacing: 10) {
          Button {
            model.rescanSources()
          } label: {
            Label("Rescan", systemImage: "arrow.clockwise")
          }

          Button {
            Task { await model.refreshNow() }
          } label: {
            if model.isRefreshing {
              ProgressView().controlSize(.small)
            } else {
              Label("Refresh now", systemImage: "arrow.down.circle")
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(model.isRefreshing)
        }

        if model.providerAccounts.isEmpty {
          emptySourcesCard
        } else {
          VStack(spacing: 10) {
            ForEach(model.providerAccounts) { account in
              sourceRow(account)
            }
          }
        }

        if !model.statusMessage.isEmpty {
          Text(model.statusMessage)
            .font(.callout)
            .foregroundStyle(.secondary)
        }

        if !model.discoveryDiagnostics.isEmpty {
          DisclosureGroup("Scan details") {
            VStack(alignment: .leading, spacing: 4) {
              ForEach(model.discoveryDiagnostics.indices, id: \.self) { index in
                Text(model.discoveryDiagnostics[index])
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
            .padding(.top, 4)
          }
          .font(.subheadline)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(20)
    }
  }

  private var emptySourcesCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("No accounts detected yet")
        .font(.subheadline.weight(.semibold))
      Text("Make sure at least one supported tool is logged in:")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 3) {
        Label("Claude Code — `claude` then sign in", systemImage: "circle.fill")
        Label("Codex CLI — `codex login`", systemImage: "circle.fill")
        Label("GitHub Copilot (CLI or editor)", systemImage: "circle.fill")
        Label("OpenCode — `opencode auth login`", systemImage: "circle.fill")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .labelStyle(.titleOnly)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private func sourceRow(_ account: ProviderAccount) -> some View {
    let usage = model.accountUsage(for: account.id)
    let failure = model.accountFailure(for: account.id)
    let ready = model.isAccountAvailable(account.id)

    return HStack(alignment: .top, spacing: 12) {
      Circle()
        .fill(account.isEnabled ? (failure == nil && ready ? Color.green : Color.orange) : Color.secondary)
        .frame(width: 9, height: 9)
        .padding(.top, 5)

      VStack(alignment: .leading, spacing: 4) {
        TextField("Name", text: model.accountDisplayNameBinding(for: account.id))
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 260)

        Text("\(account.provider.displayName) · \(model.sourceLabel(for: account.id))")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)

        Text(detail(usage: usage, failure: failure, account: account))
          .font(.caption)
          .foregroundStyle(failure == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
          .lineLimit(2)
      }

      Spacer()

      Toggle("", isOn: model.accountEnabledBinding(for: account.id))
        .labelsHidden()
        .toggleStyle(.switch)
    }
    .padding(12)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private func detail(usage: ProviderUsage?, failure: ProviderFailure?, account: ProviderAccount) -> String {
    if !account.isEnabled { return "Disabled" }
    if let failure { return "Couldn't refresh: \(failure.message)" }
    guard let usage else { return "Waiting for first refresh" }

    let parts = usage.metrics.prefix(2).compactMap { metric -> String? in
      if metric.isUnlimited { return "\(metric.label): unlimited" }
      guard let remaining = metric.remainingPercent else { return nil }
      return "\(metric.label): \(remaining)% left"
    }
    return parts.isEmpty ? "Data loaded" : parts.joined(separator: " · ")
  }

  // MARK: - General

  private var generalTab: some View {
    Form {
      Section {
        Picker("Refresh interval", selection: model.refreshIntervalBinding()) {
          ForEach(availableRefreshIntervalOptions, id: \.self) { minutes in
            Text("\(minutes) min").tag(minutes)
          }
        }
        Toggle("Launch at login", isOn: model.launchAtLoginBinding())
      }

      Section("Widget contents") {
        Toggle("Show percentages", isOn: model.widgetVisibilityBinding(for: \.showPercentageValues))
        Toggle("Show both limits per source", isOn: model.widgetVisibilityBinding(for: \.showDualLimitPercentagesInDashboard))
        Toggle("Show progress bars (medium widget)", isOn: model.widgetVisibilityBinding(for: \.showMediumProgressBars))
        Toggle("Show last-updated time", isOn: model.widgetVisibilityBinding(for: \.showTimestamp))
        Toggle("Show unavailable count", isOn: model.widgetVisibilityBinding(for: \.showFailureCount))
        Stepper(
          "Accounts in small widget: \(model.widgetVisibility.smallDashboardProviderLimit)",
          value: model.widgetVisibilityIntBinding(for: \.smallDashboardProviderLimit, range: 1...4),
          in: 1...4
        )
        Stepper(
          "Accounts in medium widget: \(model.widgetVisibility.mediumProviderLimit)",
          value: model.widgetVisibilityIntBinding(for: \.mediumProviderLimit, range: 1...12),
          in: 1...12
        )
        Stepper(
          "Days in trend widget: \(model.widgetVisibility.trendHistoryDays)",
          value: model.widgetVisibilityIntBinding(for: \.trendHistoryDays, range: 1...30),
          in: 1...30
        )
      }
    }
    .formStyle(.grouped)
  }

  private var availableRefreshIntervalOptions: [Int] {
    Array(Set(refreshIntervalOptions + [model.refreshIntervalMinutes])).sorted()
  }

  // MARK: - Appearance

  private var appearanceTab: some View {
    Form {
      Section("Widget background") {
        Picker("Theme", selection: model.widgetStylePresetBinding()) {
          Text("Custom").tag(model.customStylePresetID)
          ForEach(model.stylePresets) { preset in
            Text(preset.displayName).tag(preset.id)
          }
        }
        Toggle("Transparent background", isOn: model.widgetTransparentBackgroundBinding())
        ColorPicker("Background color", selection: model.widgetBackgroundColorBinding(), supportsOpacity: true)
          .disabled(model.widgetStyle.useTransparentBackground)
      }

      Section("Ring colors (by remaining quota)") {
        ColorPicker("High (≥70%)", selection: model.widgetRingColorBinding(for: .high, layer: .outer), supportsOpacity: false)
        ColorPicker("Medium (40–69%)", selection: model.widgetRingColorBinding(for: .medium, layer: .outer), supportsOpacity: false)
        ColorPicker("Low (<40%)", selection: model.widgetRingColorBinding(for: .low, layer: .outer), supportsOpacity: false)
        ColorPicker("Unlimited", selection: model.widgetRingColorBinding(for: .unlimited, layer: .outer), supportsOpacity: false)
      }
    }
    .formStyle(.grouped)
  }
}
