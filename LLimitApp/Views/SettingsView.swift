import SwiftUI
import QuotaCore

struct SettingsView: View {
  private enum SettingsTab: Hashable {
    case accounts
    case settings
    case style
    case account(String)
  }

  private struct TabDescriptor: Identifiable {
    let tab: SettingsTab
    let title: String
    let accountID: String?

    var id: String {
      switch tab {
      case .accounts:
        return "accounts"
      case .settings:
        return "settings"
      case .style:
        return "style"
      case .account(let accountID):
        return "account:\(accountID)"
      }
    }
  }

  @ObservedObject var model: AppModel
  @State private var selectedTab: SettingsTab = .accounts
  @State private var providerToAdd: QuotaProvider = .openAI

  private let refreshIntervalOptions = [15, 30, 45, 60, 90, 120, 180]
  private let settingsLabelWidth: CGFloat = 180
  private let tabGridColumns = [GridItem(.adaptive(minimum: 120), spacing: 6)]

  private var tabDescriptors: [TabDescriptor] {
    let fixedTabs: [TabDescriptor] = [
      TabDescriptor(tab: .accounts, title: "Accounts", accountID: nil),
      TabDescriptor(tab: .settings, title: "Settings", accountID: nil),
      TabDescriptor(tab: .style, title: "Style", accountID: nil)
    ]

    let accountTabs = model.providerAccounts.map { account in
      TabDescriptor(tab: .account(account.id), title: tabTitle(for: account), accountID: account.id)
    }

    return fixedTabs + accountTabs
  }

  private var availableRefreshIntervalOptions: [Int] {
    Array(Set(refreshIntervalOptions + [model.refreshIntervalMinutes])).sorted()
  }

  var body: some View {
    VStack(spacing: 0) {
      tabsHeader
      currentTabContent
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .navigationTitle("LLimit")
    .onChange(of: model.providerAccounts.map(\.id)) { _, accountIDs in
      if case .account(let accountID) = selectedTab, !accountIDs.contains(accountID) {
        selectedTab = .accounts
      }
    }
  }

  private var tabsHeader: some View {
    ZStack(alignment: .bottom) {
      Rectangle()
        .fill(Color.secondary.opacity(0.24))
        .frame(height: 1)

      LazyVGrid(columns: tabGridColumns, spacing: 6) {
        ForEach(tabDescriptors) { descriptor in
          tabButton(
            for: descriptor.tab,
            title: descriptor.title,
            accountID: descriptor.accountID
          )
        }
      }
      .padding(.horizontal, 14)
      .padding(.top, 10)
      .padding(.bottom, 0)
    }
    .background(.regularMaterial)
  }

  @ViewBuilder
  private var currentTabContent: some View {
    switch selectedTab {
    case .accounts:
      accountsTab
    case .settings:
      settingsTab
    case .style:
      styleTab
    case .account(let accountID):
      accountTab(for: accountID)
    }
  }

  private func tabButton(
    for tab: SettingsTab,
    title: String,
    accountID: String? = nil
  ) -> some View {
    let isSelected = selectedTab == tab

    return Button {
      selectedTab = tab
    } label: {
      HStack(spacing: 6) {
        if let accountID {
          Circle()
            .fill(tabDotColor(for: accountID))
            .frame(width: 6, height: 6)
        }

        Text(title)
          .font(.system(size: 14, weight: .semibold))
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.horizontal, 10)
      .padding(.vertical, 9)
      .frame(minHeight: 36, maxHeight: 36)
      .contentShape(Rectangle())
      .background {
        if isSelected {
          TopTabFillShape(cornerRadius: 9)
            .fill(.background)
        }
      }
      .overlay {
        TopTabBorderShape(cornerRadius: 9)
          .stroke(
            isSelected ? Color.secondary.opacity(0.38) : Color.secondary.opacity(0.24),
            lineWidth: 1
          )
      }
      .overlay(alignment: .bottom) {
        if isSelected {
          Rectangle()
            .fill(.background)
            .frame(height: 3)
            .padding(.horizontal, -1)
            .offset(y: 1)
        }
      }
    }
    .buttonStyle(.plain)
    .foregroundStyle(isSelected ? Color.primary : Color.secondary.opacity(0.92))
  }

  private var accountsTab: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        accountsSection
        detectedSourcesSection
        actionsSection
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(24)
    }
    .onAppear {
      if model.detectedCredentials.isEmpty {
        model.scanForDetectedCredentials()
      }
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
          selectedTab = .account(account.id)
        }
        .buttonStyle(.bordered)
      }
    }
    .padding(12)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private var settingsTab: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        generalSettingsSection
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(24)
    }
  }

  private var styleTab: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        styleSettingsSection
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(24)
    }
  }

  private var accountsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Provider Accounts")
        .font(.title3.weight(.semibold))

      Text("Add each LLM quota source manually. You can add multiple accounts for the same provider, such as two separate OpenAI accounts.")
        .font(.subheadline)
        .foregroundStyle(.secondary)

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
          selectedTab = .account(account.id)
        }
        .buttonStyle(.borderedProminent)
      }

      if model.providerAccounts.isEmpty {
        emptyAccountsCard
      } else {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(model.providerAccounts) { account in
            accountSummaryCard(account)
          }
        }
      }
    }
  }

  private var emptyAccountsCard: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("No accounts configured")
        .font(.subheadline.weight(.semibold))
      Text("Add a provider account, enter its credentials, then refresh to populate the widget.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private func accountSummaryCard(_ account: ProviderAccount) -> some View {
    let status = model.status(for: account.id)
    let failure = accountFailure(for: account.id)
    let hasData = accountUsage(for: account.id) != nil
    let isReady = status?.available == true && failure == nil
    let detail = accountSummaryDetail(status: status, hasData: hasData, failure: failure)

    return HStack(spacing: 12) {
      Circle()
        .fill(account.isEnabled ? (isReady ? Color.green : Color.red) : Color.secondary)
        .frame(width: 9, height: 9)

      VStack(alignment: .leading, spacing: 3) {
        Text(account.resolvedDisplayName)
          .font(.subheadline.weight(.semibold))
        Text("\(account.provider.displayName), \(detail)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      Spacer()

      Toggle("", isOn: model.accountEnabledBinding(for: account.id))
        .labelsHidden()
        .toggleStyle(.switch)

      Button("Configure") {
        selectedTab = .account(account.id)
      }
      .buttonStyle(.bordered)

      Button("Remove", role: .destructive) {
        model.removeProviderAccount(accountID: account.id)
      }
      .buttonStyle(.bordered)
    }
    .padding(12)
    .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private func accountSummaryDetail(
    status: ProviderAccountStatus?,
    hasData: Bool,
    failure: ProviderFailure?
  ) -> String {
    if let failure {
      return "Refresh failed: \(failure.message)"
    }

    if hasData {
      return "Data loaded"
    }

    return status?.detail ?? "Not checked"
  }

  private var generalSettingsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("General Settings")
        .font(.title3.weight(.semibold))

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

  private var styleSettingsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Widget Style")
        .font(.title3.weight(.semibold))

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

        settingsRow(title: "Circle graph colors") {
          HStack(alignment: .top, spacing: 24) {
            ringColorLayerColumn(
              layer: .outer,
              high: model.widgetRingColorBinding(for: .high, layer: .outer),
              medium: model.widgetRingColorBinding(for: .medium, layer: .outer),
              low: model.widgetRingColorBinding(for: .low, layer: .outer),
              unlimited: model.widgetRingColorBinding(for: .unlimited, layer: .outer)
            )

            ringColorLayerColumn(
              layer: .inner,
              high: model.widgetRingColorBinding(for: .high, layer: .inner),
              medium: model.widgetRingColorBinding(for: .medium, layer: .inner),
              low: model.widgetRingColorBinding(for: .low, layer: .inner),
              unlimited: model.widgetRingColorBinding(for: .unlimited, layer: .inner)
            )
          }
        }
      }
    }
  }

  private var actionsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Actions")
        .font(.title3.weight(.semibold))

      HStack(spacing: 10) {
        Button("Check Account Configuration") {
          model.reloadAccountStatuses()
        }
        .buttonStyle(.bordered)

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
      }

      latestSnapshotCard

      if !model.statusMessage.isEmpty {
        Text(model.statusMessage)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
  }

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
            ForEach(Array(snapshot.providers.prefix(5))) { usage in
              HStack {
                Text(shortName(for: usage))
                  .font(.caption.weight(.semibold))
                  .frame(width: 82, alignment: .leading)

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
            ForEach(Array(snapshot.failures.prefix(3))) { failure in
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

            Divider()

            settingsRow(title: "Circle graph colors") {
              HStack(alignment: .top, spacing: 24) {
                ringColorLayerColumn(
                  layer: .outer,
                  high: model.providerRingColorBinding(for: accountID, role: .high, layer: .outer),
                  medium: model.providerRingColorBinding(for: accountID, role: .medium, layer: .outer),
                  low: model.providerRingColorBinding(for: accountID, role: .low, layer: .outer),
                  unlimited: model.providerRingColorBinding(for: accountID, role: .unlimited, layer: .outer)
                )

                ringColorLayerColumn(
                  layer: .inner,
                  high: model.providerRingColorBinding(for: accountID, role: .high, layer: .inner),
                  medium: model.providerRingColorBinding(for: accountID, role: .medium, layer: .inner),
                  low: model.providerRingColorBinding(for: accountID, role: .low, layer: .inner),
                  unlimited: model.providerRingColorBinding(for: accountID, role: .unlimited, layer: .inner)
                )
              }
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

  private func ringColorLayerColumn(
    layer: WidgetRingLayer,
    high: Binding<Color>,
    medium: Binding<Color>,
    low: Binding<Color>,
    unlimited: Binding<Color>
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(layer.displayName)
        .font(.caption.weight(.semibold))

      ringColorPickerRow(title: WidgetRingColorRole.high.displayName, binding: high)
      ringColorPickerRow(title: WidgetRingColorRole.medium.displayName, binding: medium)
      ringColorPickerRow(title: WidgetRingColorRole.low.displayName, binding: low)
      ringColorPickerRow(title: WidgetRingColorRole.unlimited.displayName, binding: unlimited)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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

  private func tabDotColor(for accountID: String) -> Color {
    guard let account = model.account(withID: accountID), account.isEnabled else {
      return .secondary
    }

    return model.isAccountAvailable(accountID) ? .green : .red
  }

  private func tabTitle(for account: ProviderAccount) -> String {
    let title = account.resolvedDisplayName
    return title.count <= 16 ? title : String(title.prefix(15)) + "..."
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

    guard let snapshot = model.snapshot else {
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

    if snapshot.providers.isEmpty && !snapshot.failures.isEmpty {
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

private struct TopTabFillShape: Shape {
  var cornerRadius: CGFloat

  func path(in rect: CGRect) -> Path {
    let radius = max(0, min(cornerRadius, rect.width / 2, rect.height))

    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
    path.addQuadCurve(
      to: CGPoint(x: rect.minX + radius, y: rect.minY),
      control: CGPoint(x: rect.minX, y: rect.minY)
    )
    path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
    path.addQuadCurve(
      to: CGPoint(x: rect.maxX, y: rect.minY + radius),
      control: CGPoint(x: rect.maxX, y: rect.minY)
    )
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
    path.closeSubpath()
    return path
  }
}

private struct TopTabBorderShape: Shape {
  var cornerRadius: CGFloat

  func path(in rect: CGRect) -> Path {
    let radius = max(0, min(cornerRadius, rect.width / 2, rect.height))

    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
    path.addQuadCurve(
      to: CGPoint(x: rect.minX + radius, y: rect.minY),
      control: CGPoint(x: rect.minX, y: rect.minY)
    )
    path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
    path.addQuadCurve(
      to: CGPoint(x: rect.maxX, y: rect.minY + radius),
      control: CGPoint(x: rect.maxX, y: rect.minY)
    )
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    return path
  }
}
