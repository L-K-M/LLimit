import SwiftUI
import WebKit
import QuotaCore

@MainActor
final class VeniceLoginSession: ObservableObject, Identifiable {
  let id = UUID()
  let accountID: String
  let browser: VeniceWebBrowser
  @Published private(set) var message = ""
  @Published private(set) var isConnecting = false
  private var connection: Task<Void, Never>?
  private let finish: (UUID, VeniceWebBrowser.Reading) throws -> Void

  init(accountID: String, finish: @escaping (UUID, VeniceWebBrowser.Reading) throws -> Void) {
    self.accountID = accountID
    self.finish = finish
    browser = VeniceWebBrowser(profileID: id, interactive: true)
  }

  func connect() {
    guard connection == nil else { return }
    isConnecting = true
    message = ""
    connection = Task { [weak self] in
      guard let self else { return }
      defer { connection = nil; isConnecting = false }
      do {
        let reading = try await browser.read()
        _ = try reading.subscription?.metric(asOf: Date())
        try Task.checkCancellation()
        try finish(id, reading)
      } catch is CancellationError {
        return
      } catch let failure as VeniceWebBrowser.Failure {
        message = failure.localizedDescription
      } catch let failure as ProviderClientError {
        message = failure.message
      } catch {
        message = "Could not save the Venice web connection. Check LLimit’s storage permissions and try again."
      }
    }
  }

  func cancel() {
    connection?.cancel()
    browser.stop()
  }
}

struct VeniceLoginView: View {
  @ObservedObject var session: VeniceLoginSession
  let onClose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Connect Venice").font(.title2.weight(.semibold))
        Spacer()
        Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
      }
      Text("Sign in to the Venice account you want to track, then choose Connect Account. If you added an API key, sign in to the same Venice account.")
        .font(.caption).foregroundStyle(.secondary)
      VeniceBrowserView(webView: session.browser.webView)
        .frame(minWidth: 720, minHeight: 500)
      HStack {
        Text(session.message).font(.caption).fixedSize(horizontal: false, vertical: true)
        Spacer()
        if session.isConnecting { ProgressView().controlSize(.small) }
        Button("Connect Account") { session.connect() }
          .buttonStyle(.borderedProminent)
          .disabled(session.isConnecting)
      }
    }
    .padding(20)
    .frame(width: 860, height: 680)
  }
}

private struct VeniceBrowserView: NSViewRepresentable {
  let webView: WKWebView
  func makeNSView(context: Context) -> WKWebView { webView }
  func updateNSView(_ nsView: WKWebView, context: Context) {}
}
