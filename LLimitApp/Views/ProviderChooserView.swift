import SwiftUI
import QuotaCore

/// Browsing and inspecting providers never creates an account. Only the setup action does.
struct ProviderChooserView: View {
  let isRefreshing: Bool
  let onAdd: (QuotaProvider) -> Void
  @State private var query = ""
  @State private var selectedProvider: QuotaProvider?
  @FocusState private var searchFocused: Bool
  @FocusState private var focusedProvider: QuotaProvider?

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Add Account")
          .font(.title2.weight(.semibold))
        Text("Choose the service you subscribe to. You can add more than one account for each provider.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let selectedProvider {
        setup(for: selectedProvider)
      } else {
        catalog
      }
    }
  }

  private var catalog: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        TextField("Search services, companies, or plans", text: $query)
          .textFieldStyle(.plain)
          .focused($searchFocused)
          .accessibilityLabel("Search providers")
          .onSubmit {
            let matches = ProviderCatalog.search(query)
            guard matches.count == 1 else { return }
            searchFocused = false
            selectedProvider = matches[0].provider
          }
        if !query.isEmpty {
          Button {
            query = ""
            searchFocused = true
          } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Clear provider search")
        }
      }
      .padding(10)
      .background(.background, in: RoundedRectangle(cornerRadius: 8))
      .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary) }

      let matches = ProviderCatalog.search(query)
      Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "All providers" : (matches.count == 1 ? "1 provider found" : "\(matches.count) providers found"))
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)

      if matches.isEmpty {
        ContentUnavailableView {
          Label("No matching providers", systemImage: "magnifyingglass")
        } description: {
          Text("Try a service name like Codex, a company like Cognition, or a plan like GLM.")
        } actions: {
          Button("Show All Providers") { query = "" }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
      } else {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 10)], spacing: 10) {
          ForEach(matches) { entry in
            Button {
              searchFocused = false
              selectedProvider = entry.provider
            } label: {
              HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                  Text(entry.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                  Text(entry.context)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.tertiary)
                  .accessibilityHidden(true)
              }
              .frame(minHeight: 46)
              .padding(12)
              .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(ProviderCardStyle())
            .focused($focusedProvider, equals: entry.provider)
            .overlay {
              if focusedProvider == entry.provider {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2)
                  .allowsHitTesting(false)
              }
            }
            .accessibilityLabel("\(entry.title), \(entry.context)")
            .accessibilityHint("Show account setup")
          }
        }
      }
    }
  }

  private func setup(for provider: QuotaProvider) -> some View {
    let entry = ProviderCatalog.entry(for: provider)
    return VStack(alignment: .leading, spacing: 18) {
      Button {
        selectedProvider = nil
      } label: {
        Label("Choose Another Provider", systemImage: "chevron.left")
      }
      .buttonStyle(.borderless)

      VStack(alignment: .leading, spacing: 8) {
        Text(entry.title).font(.title3.weight(.semibold))
        Text(entry.context).font(.subheadline).foregroundStyle(.secondary)
        Text(entry.summary)
          .font(.subheadline)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 4)

        Text(connectionHelp(for: provider))
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 6)

        Button(usesSignIn(provider) ? "Connect Account" : "Add Account") { onAdd(provider) }
          .buttonStyle(.borderedProminent)
          .disabled(usesSignIn(provider) && isRefreshing)
          .padding(.top, 8)

        if usesSignIn(provider) && isRefreshing {
          Text("Wait for the current refresh to finish before connecting.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(18)
      .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
  }

  private func usesSignIn(_ provider: QuotaProvider) -> Bool {
    [.anthropic, .openAI, .xiaomiMiMo, .stepFun].contains(provider)
  }

  private func connectionHelp(for provider: QuotaProvider) -> String {
    switch provider {
    case .anthropic:
      return "Sign in inside LLimit with Claude Code installed on this Mac. Each account has its own login and renews automatically."
    case .openAI:
      return "Sign in with ChatGPT in your browser, using Codex installed on this Mac. Each account stays signed in separately."
    case .xiaomiMiMo:
      return "Sign in to the MiMo API Platform inside LLimit. LLimit renews the saved login automatically when possible."
    case .stepFun:
      return "Sign in to StepFun inside LLimit. LLimit renews the saved login automatically when possible."
    default:
      return "Add the account, then enter its credentials. You can also import an existing login from Detected on this Mac below."
    }
  }
}

private struct ProviderCardStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(configuration.isPressed ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035),
                  in: RoundedRectangle(cornerRadius: 10))
      .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary) }
      .opacity(isEnabled ? 1 : 0.5)
  }
}
