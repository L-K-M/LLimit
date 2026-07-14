import SwiftUI
import AppKit
import QuotaCore

struct SettingsView: View {
  private enum SettingsItem: Hashable {
    case overview
    case general
    case appearance
    case widgets
    case addAccount
    case account(String)
  }

  @ObservedObject var model: AppModel
  @State private var selection: SettingsItem? = .overview
  @State private var providerToAdd: QuotaProvider = .openAI

  private let refreshIntervalOptions = [15, 30, 45, 60, 90, 120, 180]
  private let settingsLabelWidth: CGFloat = 180

  private var availableRefreshIntervalOptions: [Int] {
    Array(Set(refreshIntervalOptions + [model.refreshIntervalMinutes])).sorted()
  }

  var body: some View {
    HSplitView {
      sidebar
        .frame(minWidth: 210, idealWidth: 240, maxWidth: 340, maxHeight: .infinity)

      detail
        .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(
      minWidth: 720, idealWidth: 960, maxWidth: .infinity,
      minHeight: 480, idealHeight: 680, maxHeight: .infinity
    )
    .background(WindowAccessor { window in
      // The SwiftUI `Settings` window ships without the resizable style mask and with
      // its max size pinned to the content size. Force it open so the window can grow.
      window.styleMask.insert(.resizable)
      window.minSize = NSSize(width: 720, height: 480)
      window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    })
    .navigationTitle("LLimit")
    .onAppear {
      if model.detectedCredentials.isEmpty {
        model.scanForDetectedCredentials()
      }
    }
    .onChange(of: model.providerAccounts.map(\.id)) { _, accountIDs in
      if case .account(let accountID) = selection, !accountIDs.contains(accountID) {
        selection = .overview
      }
    }
  }

  // MARK: - Sidebar

  private var sidebar: some View {
    List(selection: $selection) {
      Section {
        Label("Overview", systemImage: "gauge.with.dots.needle.bottom.50percent")
          .tag(SettingsItem.overview)
      }

      Section("Accounts") {
        ForEach(model.providerAccounts) { account in
          accountSidebarRow(account)
            .tag(SettingsItem.account(account.id))
        }
        Label("Add Account…", systemImage: "plus.circle")
          .tag(SettingsItem.addAccount)
      }

      Section("Settings") {
        Label("General", systemImage: "gearshape")
          .tag(SettingsItem.general)
        Label("Appearance", systemImage: "paintpalette")
          .tag(SettingsItem.appearance)
        Label("Widgets", systemImage: "square.grid.2x2")
          .tag(SettingsItem.widgets)
      }
    }
    .listStyle(.sidebar)
  }

  private func accountSidebarRow(_ account: ProviderAccount) -> some View {
    HStack(spacing: 8) {
      Circle()
        .fill(accountStatusColor(for: account.id))
        .frame(width: 8, height: 8)

      VStack(alignment: .leading, spacing: 1) {
        Text(account.resolvedDisplayName)
          .lineLimit(1)
        Text(account.provider.displayName)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .padding(.vertical, 2)
  }

  // MARK: - Detail router

  @ViewBuilder
  private var detail: some View {
    switch selection ?? .overview {
    case .overview:
      overviewDetail
    case .general:
      scrollSection { generalSettingsSection }
    case .appearance:
      scrollSection { styleSettingsSection }
    case .widgets:
      scrollSection { widgetTilesSection }
    case .addAccount:
      addAccountDetail
    case .account(let accountID):
      accountTab(for: accountID)
    }
  }

  private func scrollSection<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    ScrollView {
      content()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
    }
  }

  // MARK: - Overview

  private var overviewDetail: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack {
          Text("Overview")
            .font(.title2.weight(.semibold))
          Spacer()
          Button {
            Task { await model.refreshNow() }
          } label: {
            if model.isRefreshing {
              ProgressView().controlSize(.small)
            } else {
              Label("Refresh Now", systemImage: "arrow.clockwise")
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(model.isRefreshing)
        }

        if model.providerAccounts.isEmpty {
          emptyAccountsCard
        }

        latestSnapshotCard

        if !model.statusMessage.isEmpty {
          Text(model.statusMessage)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(24)
    }
  }

  private var emptyAccountsCard: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("No accounts yet")
        .font(.subheadline.weight(.semibold))
      Text("Use “Add Account…” in the sidebar to add a provider — enter its credentials or import a login detected on this Mac, then Refresh.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  // MARK: - Add account

  private var addAccountDetail: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 12) {
          Text("Add Account")
            .font(.title2.weight(.semibold))
          Text("Add an account manually, or import one detected on this Mac. You can add the same provider more than once to track multiple subscriptions.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

          HStack(spacing: 10) {
            Picker("Provider", selection: $providerToAdd) {
              ForEach(QuotaProvider.allCases, id: \.self) { provider in
                Text(provider.displayName).tag(provider)
              }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 220, alignment: .leading)

            Button("Add Account") {
              let account = model.addProviderAccount(provider: providerToAdd)
              selection = .account(account.id)
            }
            .buttonStyle(.borderedProminent)
          }
        }

        Divider()

        detectedSourcesSection
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(24)
    }
  }

  private var detectedSourcesSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Detected on this Mac")
          .font(.title3.weight(.semibold))
        Spacer()
        Button {
          model.scanForDetectedCredentials()
        } label: {
          Label("Scan", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
      }

      Text("Optional shortcut: import a login from a tool you're already signed in to (Claude Code, Codex, GitHub Copilot, OpenCode) instead of pasting a token. Imported accounts are copied into and owned by LLimit.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if model.detectedCredentials.isEmpty {
        Text("Nothing detected yet. Sign in to a supported tool and tap Scan, or add an account manually above.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
          .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      } else {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(model.detectedCredentials) { detected in
            detectedSourceCard(detected)
          }
        }
      }

      if !model.discoveryDiagnostics.isEmpty {
        DisclosureGroup("Scan details") {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(model.discoveryDiagnostics.indices, id: \.self) { index in
              Text(model.discoveryDiagnostics[index])
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .padding(.top, 4)
        }
        .font(.subheadline)
      }
    }
  }

  private func detectedSourceCard(_ detected: DiscoveredCredential) -> some View {
    let alreadyImported = model.isDetectedCredentialImported(detected)

    return HStack(spacing: 12) {
      Image(systemName: "sparkles")
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 3) {
        Text(detected.suggestedName)
          .font(.subheadline.weight(.semibold))
        Text("\(detected.provider.displayName) · \(detected.sourceLabel)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      Spacer()

      if alreadyImported {
        Label("Added", systemImage: "checkmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.green)
      } else {
        Button("Import") {
          let account = model.importAccount(from: detected)
          selection = .account(account.id)
        }
        .buttonStyle(.bordered)
      }
    }
    .padding(12)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  // MARK: - General

  private var generalSettingsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("General")
        .font(.title2.weight(.semibold))

      VStack(spacing: 0) {
        settingsRow(title: "Refresh interval") {
          Picker("", selection: model.refreshIntervalBinding()) {
            ForEach(availableRefreshIntervalOptions, id: \.self) { minutes in
              Text("\(minutes) min").tag(minutes)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .frame(minWidth: 160, maxWidth: 220, alignment: .leading)
        }

        Divider()

        settingsRow(title: "Launch at Login") {
          Toggle("", isOn: model.launchAtLoginBinding())
            .labelsHidden()
            .toggleStyle(.switch)
        }

        Divider()

        settingsRow(title: "Visible information") {
          VStack(alignment: .leading, spacing: 10) {
            settingsGroupCard(title: "All Widgets") {
              Toggle(
                "Show percentages in widgets",
                isOn: model.widgetVisibilityBinding(for: \.showPercentageValues)
              )
            }

            settingsGroupCard(title: "Dashboard Widgets") {
              Toggle(
                "Show both limits in dashboard rows",
                isOn: model.widgetVisibilityBinding(for: \.showDualLimitPercentagesInDashboard)
              )
              Toggle(
                "Show progress bars in medium dashboard",
                isOn: model.widgetVisibilityBinding(for: \.showMediumProgressBars)
              )
              Toggle(
                "Show timestamp in dashboard widgets",
                isOn: model.widgetVisibilityBinding(for: \.showTimestamp)
              )
              Toggle(
                "Show failure count in dashboard widgets",
                isOn: model.widgetVisibilityBinding(for: \.showFailureCount)
              )
              Toggle(
                "Show summary in small dashboard",
                isOn: model.widgetVisibilityBinding(for: \.showOverviewMetricSummary)
              )

              visibilityStepperRow(
                title: "Accounts shown in small dashboard",
                value: model.widgetVisibilityIntBinding(for: \.smallDashboardProviderLimit, range: 1...4),
                range: 1...4,
                displayedValue: model.widgetVisibility.smallDashboardProviderLimit
              )

              visibilityStepperRow(
                title: "Accounts shown in medium dashboard",
                value: model.widgetVisibilityIntBinding(for: \.mediumProviderLimit, range: 1...12),
                range: 1...12,
                displayedValue: model.widgetVisibility.mediumProviderLimit
              )
            }

            settingsGroupCard(title: "Trend Widget") {
              visibilityStepperRow(
                title: "Days shown in trend chart",
                value: model.widgetVisibilityIntBinding(for: \.trendHistoryDays, range: 1...30),
                range: 1...30,
                displayedValue: model.widgetVisibility.trendHistoryDays
              )
            }
          }
          .toggleStyle(.switch)
        }
      }
    }
  }

  // MARK: - Widgets

  private var widgetTilesSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Widgets")
        .font(.title2.weight(.semibold))

      Text("""
        Each numbered Provider Tile widget shows one account's quota rings. \
        Tiles left on Automatic fill with the accounts that aren't pinned to \
        another tile — place tiles 1 through \(AppSettings.providerTileSlotCount) \
        and they cover your accounts with no setup. Assignments here update the \
        desktop tiles immediately; the widgets themselves are not editable.
        """)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      VStack(spacing: 0) {
        ForEach(0..<AppSettings.providerTileSlotCount, id: \.self) { index in
          if index > 0 {
            Divider()
          }

          settingsRow(title: "Provider Tile \(index + 1)") {
            Picker("", selection: model.providerTileSlotBinding(for: index)) {
              Text(automaticLabel(forSlot: index)).tag("")
              ForEach(model.providerAccounts) { account in
                Text(tileAccountLabel(for: account))
                  .tag(account.id)
              }
              if let dangling = danglingTileAssignment(forSlot: index) {
                Text("Missing account").tag(dangling)
              }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(minWidth: 220, maxWidth: 320, alignment: .leading)
          }
        }
      }
    }
  }

  /// Mirrors the widgets' resolution exactly, so the "Automatic" label names
  /// the account an unassigned tile will actually show.
  private var tileSettings: AppSettings {
    AppSettings(accounts: model.providerAccounts, providerTileSlots: model.providerTileSlots)
  }

  private func automaticLabel(forSlot index: Int) -> String {
    // Rank as if this slot were unassigned, since the label describes what
    // choosing "Automatic" would do.
    var settings = tileSettings
    if settings.providerTileSlots.indices.contains(index) {
      settings.providerTileSlots[index] = ""
    }
    let rank = settings.providerTileAutoRank(forSlot: index) ?? 0
    let candidates = settings.providerTileAutoCandidates()
    guard candidates.indices.contains(rank) else {
      return "Automatic (no account left)"
    }
    return "Automatic (\(candidates[rank].resolvedDisplayName))"
  }

  private func tileAccountLabel(for account: ProviderAccount) -> String {
    var label = "\(account.resolvedDisplayName) — \(account.provider.displayName)"
    if !account.isEnabled {
      label += " (disabled)"
    }
    return label
  }

  /// A stored assignment pointing at an account that no longer exists; surfaced
  /// so the picker doesn't render an empty selection.
  private func danglingTileAssignment(forSlot index: Int) -> String? {
    guard model.providerTileSlots.indices.contains(index) else { return nil }
    let value = model.providerTileSlots[index]
    guard !value.isEmpty else { return nil }
    return model.providerAccounts.contains(where: { $0.id == value }) ? nil : value
  }

  // MARK: - Appearance

  private var styleSettingsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Appearance")
        .font(.title2.weight(.semibold))

      VStack(spacing: 0) {
        settingsRow(title: "Style preset") {
          Picker("", selection: model.widgetStylePresetBinding()) {
            Text("Custom").tag(model.customStylePresetID)
            ForEach(model.stylePresets) { preset in
              Text(preset.displayName).tag(preset.id)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .frame(minWidth: 180, maxWidth: 260, alignment: .leading)
        }

        Divider()

        settingsRow(title: "Transparent background") {
          Toggle("", isOn: model.widgetTransparentBackgroundBinding())
            .labelsHidden()
            .toggleStyle(.switch)
        }

        Divider()

        settingsRow(title: "Background color") {
          ColorPicker("", selection: model.widgetBackgroundColorBinding(), supportsOpacity: true)
            .labelsHidden()
            .frame(width: 48)
            .disabled(model.widgetStyle.useTransparentBackground)
        }

        Divider()

        settingsRow(title: "Dashboard background") {
          VStack(alignment: .leading, spacing: 8) {
            Toggle("Override global background", isOn: model.widgetBackgroundOverrideBinding(for: .dashboard))

            if model.widgetBackgroundOverride(for: .dashboard).useCustomBackground {
              HStack(spacing: 10) {
                Toggle("Transparent", isOn: model.widgetTransparentBackgroundBinding(for: .dashboard))
                  .toggleStyle(.switch)
                Spacer()
                ColorPicker("", selection: model.widgetBackgroundColorBinding(for: .dashboard), supportsOpacity: true)
                  .labelsHidden()
                  .frame(width: 48)
                  .disabled(model.widgetBackgroundOverride(for: .dashboard).useTransparentBackground)
              }
            }
          }
          .toggleStyle(.switch)
        }

        Divider()

        settingsRow(title: "Trend background") {
          VStack(alignment: .leading, spacing: 8) {
            Toggle("Override global background", isOn: model.widgetBackgroundOverrideBinding(for: .trend))

            if model.widgetBackgroundOverride(for: .trend).useCustomBackground {
              HStack(spacing: 10) {
                Toggle("Transparent", isOn: model.widgetTransparentBackgroundBinding(for: .trend))
                  .toggleStyle(.switch)
                Spacer()
                ColorPicker("", selection: model.widgetBackgroundColorBinding(for: .trend), supportsOpacity: true)
                  .labelsHidden()
                  .frame(width: 48)
                  .disabled(model.widgetBackgroundOverride(for: .trend).useTransparentBackground)
              }
            }
          }
          .toggleStyle(.switch)
        }

        Divider()

        settingsRow(title: "Limit colors") {
          VStack(alignment: .leading, spacing: 6) {
            Text("Each limit window keeps one color everywhere — rings, bars, sparklines, and the trend chart.")
              .font(.caption)
              .foregroundStyle(.secondary)

            ringColorPickerRow(
              title: QuotaWindowKind.session.displayName,
              binding: model.limitKindColorBinding(for: .session)
            )
            ringColorPickerRow(
              title: QuotaWindowKind.daily.displayName,
              binding: model.limitKindColorBinding(for: .daily)
            )
            ringColorPickerRow(
              title: QuotaWindowKind.weekly.displayName,
              binding: model.limitKindColorBinding(for: .weekly)
            )
            ringColorPickerRow(
              title: QuotaWindowKind.monthly.displayName,
              binding: model.limitKindColorBinding(for: .monthly)
            )
            ringColorPickerRow(
              title: "Other A",
              binding: model.limitKindColorBinding(for: .other, otherSlot: 0)
            )
            ringColorPickerRow(
              title: "Other B",
              binding: model.limitKindColorBinding(for: .other, otherSlot: 1)
            )
            ringColorPickerRow(
              title: "Unlimited",
              binding: model.limitKindUnlimitedColorBinding()
            )

            Button("Reset to defaults") {
              model.resetLimitKindColors()
            }
            .buttonStyle(.link)
            .font(.caption)
          }
        }

      }
    }
  }

  // MARK: - Latest snapshot card

  private var latestSnapshotCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Latest Snapshot")
          .font(.headline)
        Spacer()

        if let snapshot = model.snapshot {
          Text(snapshot.generatedAt.formatted(date: .abbreviated, time: .shortened))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      if let snapshot = model.snapshot {
        HStack(spacing: 8) {
          summaryPill(title: "Loaded", value: "\(snapshot.providers.count)", tint: .blue)
          summaryPill(
            title: "Failures",
            value: "\(snapshot.failures.count)",
            tint: snapshot.failures.isEmpty ? .green : .orange
          )
        }

        if snapshot.providers.isEmpty {
          Text(snapshot.failures.isEmpty
            ? "No account data in latest snapshot."
            : "Latest refresh returned failures only. No account data was loaded."
          )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        } else {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(snapshot.providers) { usage in
              HStack {
                Text(shortName(for: usage))
                  .font(.caption.weight(.semibold))
                  .frame(width: 110, alignment: .leading)
                  .lineLimit(1)

                if let metric = usage.metrics.first {
                  Text(metric.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                  Spacer()

                  Text(percentText(metric))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                } else {
                  Spacer()
                  Text("No metrics")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
            }
          }
        }

        if !snapshot.failures.isEmpty {
          Divider()
          VStack(alignment: .leading, spacing: 6) {
            ForEach(snapshot.failures) { failure in
              Text("\(failureTitle(for: failure)): \(failure.message)")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
            }
          }
        }
      } else {
        Text("No snapshot available yet. Use Refresh Now to fetch usage.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .padding(14)
    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  // MARK: - Account detail

  @ViewBuilder
  private func accountTab(for accountID: String) -> some View {
    if let account = model.account(withID: accountID) {
      let providerStyle = model.providerStyle(for: accountID)
      let credentialsAvailable = model.isAccountAvailable(accountID)
      let dataStatus = accountDataStatus(for: accountID)

      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          settingsRow(title: "Display name") {
            TextField("Account name", text: model.accountDisplayNameBinding(for: accountID))
              .textFieldStyle(.roundedBorder)
              .frame(maxWidth: 340)
          }

          Divider()

          settingsRow(title: "Provider") {
            Text(account.provider.displayName)
              .font(.subheadline)
          }

          Divider()

          settingsRow(title: "Enabled") {
            Toggle("", isOn: model.accountEnabledBinding(for: accountID))
              .labelsHidden()
              .toggleStyle(.switch)
          }

          Divider()

          providerStatusRow(
            title: "Credentials",
            message: model.status(for: accountID)?.detail ?? "Not checked",
            isPositive: credentialsAvailable
          )

          Divider()

          providerStatusRow(
            title: "Data",
            message: dataStatus.message,
            isPositive: dataStatus.isPositive
          )

          Divider()

          settingsRow(title: "Credentials") {
            VStack(alignment: .leading, spacing: 12) {
              HStack(spacing: 10) {
                Button {
                  model.autofillCredentials(forAccountID: accountID)
                } label: {
                  Label("Auto-fill from this Mac", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)

                Text("Detects a \(account.provider.displayName) login from a local tool.")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }

              ForEach(account.provider.credentialFields) { field in
                credentialField(field, accountID: accountID)
              }
            }
          }

          Divider()

          settingsRow(title: "Override global styling") {
            Toggle("", isOn: model.providerOverrideEnabledBinding(for: accountID))
              .labelsHidden()
              .toggleStyle(.switch)
          }

          if providerStyle.useCustomStyle {
            Divider()

            settingsRow(title: "Style preset") {
              Picker("", selection: model.providerStylePresetBinding(for: accountID)) {
                Text("Custom").tag(model.customStylePresetID)
                ForEach(model.stylePresets) { preset in
                  Text(preset.displayName).tag(preset.id)
                }
              }
              .labelsHidden()
              .pickerStyle(.menu)
              .frame(minWidth: 180, maxWidth: 260, alignment: .leading)
            }

            Divider()

            settingsRow(title: "Transparent background") {
              Toggle("", isOn: model.providerTransparentBackgroundBinding(for: accountID))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            Divider()

            settingsRow(title: "Background color") {
              ColorPicker("", selection: model.providerBackgroundColorBinding(for: accountID), supportsOpacity: true)
                .labelsHidden()
                .frame(width: 48)
                .disabled(providerStyle.style.useTransparentBackground)
            }

          }

          Divider()

          settingsRow(title: "Actions") {
            HStack(spacing: 10) {
              Button {
                Task { await model.refreshNow() }
              } label: {
                if model.isRefreshing {
                  ProgressView()
                    .controlSize(.small)
                } else {
                  Text("Refresh Now")
                }
              }
              .buttonStyle(.borderedProminent)
              .disabled(model.isRefreshing)

              Button("Remove Account", role: .destructive) {
                model.removeProviderAccount(accountID: accountID)
              }
              .buttonStyle(.bordered)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
      }
    } else {
      Text("Account not found")
        .font(.headline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func credentialField(_ field: CredentialFieldDescriptor, accountID: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(field.label)
          .font(.caption.weight(.semibold))
        if !field.isRequired {
          Text("Optional")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }

      if field.isSecret {
        SecureField(field.label, text: model.credentialBinding(for: accountID, fieldKey: field.key))
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 520)
      } else {
        TextField(field.label, text: model.credentialBinding(for: accountID, fieldKey: field.key))
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 520)
      }

      if let help = field.help, !help.isEmpty {
        Text(help)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Shared row helpers

  private func providerStatusRow(
    title: String,
    message: String,
    isPositive: Bool
  ) -> some View {
    HStack(spacing: 16) {
      Text(title)
        .frame(width: settingsLabelWidth, alignment: .leading)

      HStack(spacing: 8) {
        Circle()
          .fill(isPositive ? Color.green : Color.red)
          .frame(width: 8, height: 8)
        Text(message)
          .font(.subheadline)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 8)
  }

  private func settingsRow<Content: View>(
    title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(alignment: .top, spacing: 16) {
      Text(title)
        .frame(width: settingsLabelWidth, alignment: .leading)
      content()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 8)
  }

  private func settingsGroupCard<Content: View>(
    title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 8) {
        content()
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private func visibilityStepperRow(
    title: String,
    value: Binding<Int>,
    range: ClosedRange<Int>,
    displayedValue: Int
  ) -> some View {
    HStack(spacing: 10) {
      Text(title)
      Spacer()

      Stepper("", value: value, in: range)
        .labelsHidden()

      Text("\(displayedValue)")
        .font(.subheadline.weight(.semibold))
        .monospacedDigit()
        .frame(minWidth: 24, alignment: .trailing)
    }
  }

  private func ringColorPickerRow(title: String, binding: Binding<Color>) -> some View {
    HStack(spacing: 10) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 130, alignment: .leading)

      ColorPicker("", selection: binding, supportsOpacity: false)
        .labelsHidden()
        .frame(width: 48)
    }
  }

  private func summaryPill(title: String, value: String, tint: Color) -> some View {
    HStack(spacing: 6) {
      Text(title)
      Text(value)
        .fontWeight(.semibold)
    }
    .font(.caption)
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .background(tint.opacity(0.16), in: Capsule())
    .foregroundStyle(tint)
  }

  // MARK: - Status helpers

  private func accountStatusColor(for accountID: String) -> Color {
    guard let account = model.account(withID: accountID), account.isEnabled else {
      return .secondary
    }
    if accountFailure(for: accountID) != nil {
      return .orange
    }
    return model.isAccountAvailable(accountID) ? .green : .red
  }

  private func shortName(for usage: ProviderUsage) -> String {
    if !usage.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return usage.title
    }
    return usage.provider.displayName
  }

  private func failureTitle(for failure: ProviderFailure) -> String {
    if let account = model.account(withID: failure.accountID) {
      return account.resolvedDisplayName
    }

    if let account = soleConfiguredAccount(for: failure.provider), failure.accountID == failure.provider.rawValue {
      return account.resolvedDisplayName
    }

    return failure.provider.displayName
  }

  private func accountDataStatus(for accountID: String) -> (message: String, isPositive: Bool) {
    guard let account = model.account(withID: accountID) else {
      return ("Account not found", false)
    }

    guard model.snapshot != nil else {
      return ("No snapshot available", false)
    }

    if accountUsage(for: accountID) != nil {
      return ("Data loaded", true)
    }

    if let failure = accountFailure(for: accountID) {
      return ("Refresh failed: \(failure.message)", false)
    }

    if !account.isEnabled {
      return ("Account disabled", false)
    }

    if !account.hasRequiredCredentials {
      return ("Credentials incomplete", false)
    }

    if hasAmbiguousProviderKeyedSnapshotEntry(for: account) {
      return ("Refresh again to match this account", false)
    }

    if let snapshot = model.snapshot, snapshot.providers.isEmpty, !snapshot.failures.isEmpty {
      return ("Latest refresh returned failures only", false)
    }

    return ("No data in latest snapshot", false)
  }

  private func accountUsage(for accountID: String) -> ProviderUsage? {
    guard let snapshot = model.snapshot else {
      return nil
    }

    if let exactMatch = snapshot.providers.first(where: { $0.accountID == accountID }) {
      return exactMatch
    }

    guard
      let account = model.account(withID: accountID),
      soleConfiguredAccount(for: account.provider) != nil
    else {
      return nil
    }

    return snapshot.providers.first { usage in
      usage.provider == account.provider && usage.accountID == account.provider.rawValue
    }
  }

  private func accountFailure(for accountID: String) -> ProviderFailure? {
    guard let snapshot = model.snapshot else {
      return nil
    }

    if let exactMatch = snapshot.failures.first(where: { $0.accountID == accountID }) {
      return exactMatch
    }

    guard
      let account = model.account(withID: accountID),
      soleConfiguredAccount(for: account.provider) != nil
    else {
      return nil
    }

    return snapshot.failures.first { failure in
      failure.provider == account.provider && failure.accountID == account.provider.rawValue
    }
  }

  private func soleConfiguredAccount(for provider: QuotaProvider) -> ProviderAccount? {
    let accounts = model.providerAccounts.filter { $0.provider == provider }
    return accounts.count == 1 ? accounts[0] : nil
  }

  private func hasAmbiguousProviderKeyedSnapshotEntry(for account: ProviderAccount) -> Bool {
    guard soleConfiguredAccount(for: account.provider) == nil, let snapshot = model.snapshot else {
      return false
    }

    return snapshot.providers.contains { usage in
      usage.provider == account.provider && usage.accountID == account.provider.rawValue
    } || snapshot.failures.contains { failure in
      failure.provider == account.provider && failure.accountID == account.provider.rawValue
    }
  }

  private func percentText(_ metric: UsageMetric?) -> String {
    guard let metric else {
      return "--"
    }

    if metric.isUnlimited {
      return "INF"
    }

    guard let remaining = metric.remainingPercent else {
      return "--"
    }

    return "\(remaining)%"
  }
}

/// Reaches the AppKit `NSWindow` hosting a SwiftUI view so we can adjust window-level
/// properties SwiftUI doesn't expose (here: making the Settings window resizable).
private struct WindowAccessor: NSViewRepresentable {
  let configure: (NSWindow) -> Void

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async { [weak view] in
      if let window = view?.window { configure(window) }
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    DispatchQueue.main.async { [weak nsView] in
      if let window = nsView?.window { configure(window) }
    }
  }
}
