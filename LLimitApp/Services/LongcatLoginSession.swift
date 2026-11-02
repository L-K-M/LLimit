import Foundation
import WebKit
import QuotaCore

/// Each connection owns a temporary browser. Only scoped authentication cookies
/// leave it, after the caller verifies the account and token balance.
@MainActor
final class LongcatLoginSession: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
  let id = UUID()
  let accountID: String
  let webView: WKWebView
  @Published private(set) var isConnecting = false
  @Published private(set) var message = "Sign in to Longcat, then choose Connect Account."
  private var connection: Task<Void, Never>?
  private var cancelled = false
  private let onConnect: @MainActor (UUID, LongcatBrowserSession) async throws -> Void

  init(accountID: String, startURL: URL = LongcatSignInPolicy.startURL,
       onConnect: @escaping @MainActor (UUID, LongcatBrowserSession) async throws -> Void) {
    self.accountID = accountID
    self.onConnect = onConnect
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    webView = WKWebView(frame: .zero, configuration: configuration)
    super.init()
    webView.navigationDelegate = self
    webView.uiDelegate = self
    if LongcatSignInPolicy.allowsNavigation(to: startURL) { webView.load(URLRequest(url: startURL)) }
  }

  func connect() {
    guard !cancelled, !isConnecting else { return }
    guard let url = webView.url, LongcatSignInPolicy.allowsNavigation(to: url),
          url.scheme == "https", url.host == LongcatSignInPolicy.startURL.host else {
      message = "Finish signing in and return to the Longcat API Platform first."
      return
    }
    isConnecting = true
    message = "Verifying your sign-in and token balance…"
    connection = Task { [weak self] in
      guard let self else { return }
      do {
        let cookies = await withCheckedContinuation { continuation in
          self.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        let session = try LongcatBrowserSession(cookies: cookies)
        try await onConnect(id, session)
      } catch is CancellationError {
      } catch let error as ProviderClientError {
        message = error.message
      } catch {
        message = "Could not save this Longcat login. Check LLimit’s storage permissions and try again."
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
            ? LongcatSignInPolicy.allowsSubframeNavigation(to: url) : LongcatSignInPolicy.allowsNavigation(to: url)) else {
      message = "That link cannot be opened in this sign-in window. Continue with Longcat sign-in."
      decisionHandler(.cancel)
      return
    }
    decisionHandler(.allow)
  }

  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
               for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    guard let url = navigationAction.request.url, LongcatSignInPolicy.allowsNavigation(to: url) else { return nil }
    webView.load(navigationAction.request)
    return nil
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    guard (error as NSError).code != NSURLErrorCancelled else { return }
    message = "The Longcat sign-in page could not load. Check your connection and try again."
  }
}
