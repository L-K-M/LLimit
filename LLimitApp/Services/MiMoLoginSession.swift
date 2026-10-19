import Foundation
import WebKit
import QuotaCore

/// Each attempt owns an ephemeral browser. Only this browser's platform service
/// cookies can be adopted; Safari, Chrome, and Xiaomi SSO storage are never read.
@MainActor
final class MiMoLoginSession: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
  let id = UUID()
  let accountID: String
  let webView: WKWebView
  @Published private(set) var isConnecting = false
  @Published private(set) var message = "Sign in to the MiMo API Platform, then choose Connect Account."
  private var connection: Task<Void, Never>?
  private var cancelled = false
  private let onConnect: @MainActor (UUID, MiMoSessionCookies) async throws -> Void

  init(accountID: String, startURL: URL = MiMoSignInPolicy.startURL,
       onConnect: @escaping @MainActor (UUID, MiMoSessionCookies) async throws -> Void) {
    self.accountID = accountID
    self.onConnect = onConnect
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    webView = WKWebView(frame: .zero, configuration: configuration)
    super.init()
    webView.navigationDelegate = self
    webView.uiDelegate = self
    if MiMoSignInPolicy.allowsNavigation(to: startURL) { webView.load(URLRequest(url: startURL)) }
  }

  func connect() {
    guard !cancelled, !isConnecting else { return }
    guard webView.url?.scheme == "https", webView.url?.host == MiMoSessionCookies.consoleHost else {
      message = "Finish signing in and return to the MiMo API Platform first."
      return
    }
    isConnecting = true
    message = "Checking your Token Plan…"
    connection = Task { [weak self] in
      guard let self else { return }
      do {
        let cookies = await withCheckedContinuation { continuation in
          self.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        try Task.checkCancellation()
        let session = try MiMoSessionCookies(cookies: cookies)
        try await onConnect(id, session)
      } catch is CancellationError {
      } catch let error as ProviderClientError {
        // QuotaCore errors contain fixed copy, never a web response or cookies.
        message = error.message
      } catch {
        message = "Could not save this MiMo login. Check LLimit’s storage permissions and try again."
      }
      isConnecting = false
    }
  }

  func cancel() {
    cancelled = true
    connection?.cancel()
    connection = nil
    webView.stopLoading()
    webView.navigationDelegate = nil
    webView.uiDelegate = nil
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = navigationAction.request.url, MiMoSignInPolicy.allowsNavigation(to: url) else {
      message = "That link cannot be opened in this sign-in window. Continue with Xiaomi account sign-in."
      decisionHandler(.cancel)
      return
    }
    decisionHandler(.allow)
  }

  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
               for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    guard let url = navigationAction.request.url, MiMoSignInPolicy.allowsNavigation(to: url) else { return nil }
    webView.load(navigationAction.request)
    return nil
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    guard (error as NSError).code != NSURLErrorCancelled else { return }
    message = "The MiMo sign-in page could not load. Check your connection and try again."
  }
}
