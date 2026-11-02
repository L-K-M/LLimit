import SwiftUI
import WebKit

struct LongcatLoginView: View {
  @ObservedObject var session: LongcatLoginSession
  let onClose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Connect Longcat").font(.title2.weight(.semibold))
        Spacer()
        Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
      }
      Text("Sign in to the Longcat API Platform, then choose Connect Account. Tracks your remaining token allowance and pack expiry. When no allowance is reported, each token increase sets a new estimated 100% baseline. Sign in again if Longcat expires the session.")
        .font(.caption).foregroundStyle(.secondary)
      LongcatBrowserView(webView: session.webView)
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

private struct LongcatBrowserView: NSViewRepresentable {
  let webView: WKWebView
  func makeNSView(context: Context) -> WKWebView { webView }
  func updateNSView(_ nsView: WKWebView, context: Context) {}
}
