import SwiftUI
import WebKit

struct StepFunLoginView: View {
  @ObservedObject var session: StepFunLoginSession
  let onClose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Connect StepFun").font(.title2.weight(.semibold))
        Spacer()
        Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
      }
      Text("Sign in to StepFun, then choose Connect Account. LLimit keeps a separate saved sign-in and renews automatically when possible. Reconnect if StepFun requires it.")
        .font(.caption).foregroundStyle(.secondary)
      StepFunBrowserView(webView: session.webView)
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

private struct StepFunBrowserView: NSViewRepresentable {
  let webView: WKWebView
  func makeNSView(context: Context) -> WKWebView { webView }
  func updateNSView(_ nsView: WKWebView, context: Context) {}
}
