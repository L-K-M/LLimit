import SwiftUI
import WebKit

struct MiMoLoginView: View {
  @ObservedObject var session: MiMoLoginSession
  let onClose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Connect MiMo").font(.title2.weight(.semibold))
        Spacer()
        Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
      }
      Text("Each LLimit account signs in separately. Sign in again if your MiMo session expires.")
        .font(.caption).foregroundStyle(.secondary)
      MiMoBrowserView(webView: session.webView)
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

private struct MiMoBrowserView: NSViewRepresentable {
  let webView: WKWebView
  func makeNSView(context: Context) -> WKWebView { webView }
  func updateNSView(_ nsView: WKWebView, context: Context) {}
}
