import SwiftUI
import QuotaCore

/// Presents discovery results without exposing their credential values.
struct DetectedAccountsView: View {
  let credentials: [DiscoveredCredential]
  let addedCredentialIDs: Set<String>
  let isScanning: Bool
  let hasScanned: Bool
  let query: String
  let diagnostics: [String]
  let errorMessage: String?
  let onScan: () -> Void
  let onAdd: (DiscoveredCredential) -> Void
  let onOpen: (DiscoveredCredential) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        Text("Found on this Mac")
          .font(.title3.weight(.semibold))
        Spacer(minLength: 8)
        Button(action: onScan) {
          Label("Scan Again", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .disabled(isScanning)
        .help("Check supported local tools for existing logins.")
      }

      Text("Credentials are copied into LLimit’s local storage. Imported sessions may need to be imported again when they expire.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Text("Missing a login? Scan Again also checks Claude Code in Keychain.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if isScanning {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small).accessibilityHidden(true)
          Text("Checking supported tools…")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }

      if let errorMessage {
        Label {
          Text(errorMessage).fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .font(.caption)
        .foregroundStyle(.red)
      }

      if !credentials.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(credentials) { detected in
            accountRow(detected)
          }
        }
      } else if !isScanning && errorMessage == nil {
        Text(emptyMessage)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
          .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
      }

      if !diagnostics.isEmpty {
        DisclosureGroup("Scan details") {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(diagnostics.indices, id: \.self) { index in
              Text(verbatim: diagnostics[index])
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .padding(.top, 4)
        }
        .font(.caption)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var emptyMessage: String {
    if !hasScanned {
      return "Detected logins will appear here after the automatic scan."
    }
    if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "No matching detected logins."
    }
    return "No supported local logins found. Choose a provider below to connect or enter credentials."
  }

  private func accountRow(_ detected: DiscoveredCredential) -> some View {
    let entry = ProviderCatalog.entry(for: detected.provider)
    let isAdded = addedCredentialIDs.contains(detected.stableID)
    let missing = detected.provider.missingCredentialLabels(in: detected.credentials)

    return HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(detected.suggestedName)
          .font(.subheadline.weight(.semibold))
          .fixedSize(horizontal: false, vertical: true)
        Text("\(entry.title) · \(entry.context)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Text(detected.sourceLabel)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if !missing.isEmpty {
          Text(isAdded
            ? "Not included in this detected login: \(missing.joined(separator: ", "))."
            : "Finish setup after adding: \(missing.joined(separator: ", ")).")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if isAdded {
        VStack(alignment: .trailing, spacing: 6) {
          Label("Added", systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.green)
          Button("Open") { onOpen(detected) }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Open \(detected.suggestedName) account")
        }
        .fixedSize()
      } else {
        Button("Add") { onAdd(detected) }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .disabled(isScanning)
          .accessibilityLabel("Add \(detected.suggestedName) from \(detected.sourceLabel)")
          .fixedSize()
      }
    }
    .padding(12)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
  }
}
