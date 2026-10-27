import Foundation
import WebKit
import QuotaCore

/// Each connection owns its own temporary browser; only the console's two
/// authentication cookies leave it, after the caller verifies login and quota.
@MainActor
final class StepFunLoginSession: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
  let id = UUID()
  let accountID: String
  let webView: WKWebView
  @Published private(set) var isConnecting = false
  @Published private(set) var message = "Sign in to StepFun, then choose Connect Account."
  private var connection: Task<Void, Never>?
  private var cancelled = false
  private let onConnect: @MainActor (UUID, StepFunBrowserSession) async throws -> Void

  init(accountID: String, startURL: URL = StepFunSignInPolicy.startURL,
       onConnect: @escaping @MainActor (UUID, StepFunBrowserSession) async throws -> Void) {
    self.accountID = accountID
    self.onConnect = onConnect
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    webView = WKWebView(frame: .zero, configuration: configuration)
    super.init()
    webView.navigationDelegate = self
    webView.uiDelegate = self
    if StepFunSignInPolicy.allowsNavigation(to: startURL) { webView.load(URLRequest(url: startURL)) }
  }

  func connect() {
    guard !cancelled, !isConnecting else { return }
    guard webView.url?.scheme == "https", webView.url?.host == StepFunBrowserSession.consoleHost else {
      message = "Finish signing in and return to the StepFun platform first."
      return
    }
    isConnecting = true
    message = "Verifying your sign-in and Step Plan…"
    connection = Task { [weak self] in
      guard let self else { return }
      do {
        let cookies = await withCheckedContinuation { continuation in
          self.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        let session = try StepFunBrowserSession(cookies: cookies)
        try await onConnect(id, session)
      } catch is CancellationError {
      } catch let error as ProviderClientError {
        message = error.message
      } catch {
        message = "Could not save this StepFun login. Check LLimit’s storage permissions and try again."
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
    guard let url = navigationAction.request.url,
          (navigationAction.targetFrame?.isMainFrame == false
            ? StepFunSignInPolicy.allowsSubframeNavigation(to: url) : StepFunSignInPolicy.allowsNavigation(to: url)) else {
      message = "That link cannot be opened in this sign-in window. Continue with StepFun sign-in."
      decisionHandler(.cancel)
      return
    }
    decisionHandler(.allow)
  }

  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
               for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    guard let url = navigationAction.request.url, StepFunSignInPolicy.allowsNavigation(to: url) else { return nil }
    webView.load(navigationAction.request)
    return nil
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    guard (error as NSError).code != NSURLErrorCancelled else { return }
    message = "The StepFun sign-in page could not load. Check your connection and try again."
  }
}
