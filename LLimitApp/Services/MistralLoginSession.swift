import Foundation
import WebKit
import QuotaCore

/// Each connection owns a temporary browser. Only scoped authentication cookies
/// leave it, after the caller verifies the account, organization, and quota.
@MainActor
final class MistralLoginSession: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
  let id = UUID()
  let accountID: String
  let webView: WKWebView
  @Published private(set) var isConnecting = false
  @Published private(set) var message = "Sign in to Mistral, then choose Connect Account."
  private var connection: Task<Void, Never>?
  private var cancelled = false
  private var hasRedirectedStudioSignIn = false
  private let onConnect: @MainActor (UUID, MistralBrowserSession) async throws -> Void

  init(accountID: String, startURL: URL = MistralSignInPolicy.startURL,
       onConnect: @escaping @MainActor (UUID, MistralBrowserSession) async throws -> Void) {
    self.accountID = accountID
    self.onConnect = onConnect
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    webView = WKWebView(frame: .zero, configuration: configuration)
    super.init()
    webView.navigationDelegate = self
    webView.uiDelegate = self
    if MistralSignInPolicy.allowsNavigation(to: startURL) { webView.load(URLRequest(url: startURL)) }
  }

  func connect() {
    guard !cancelled, !isConnecting else { return }
    guard let url = webView.url, MistralSignInPolicy.allowsNavigation(to: url),
          url.scheme == "https", url.host == MistralSignInPolicy.startURL.host else {
      message = "Finish signing in and return to Mistral Admin first."
      return
    }
    isConnecting = true
    message = "Verifying your sign-in and monthly allowances…"
    connection = Task { [weak self] in
      guard let self else { return }
      do {
        let cookies = await withCheckedContinuation { continuation in
          self.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        let session = try MistralBrowserSession(cookies: cookies)
        try await onConnect(id, session)
      } catch is CancellationError {
      } catch let error as ProviderClientError {
        message = error.message
      } catch {
        message = "Could not save this Mistral login. Check LLimit’s storage permissions and try again."
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
            ? MistralSignInPolicy.allowsSubframeNavigation(to: url) : MistralSignInPolicy.allowsNavigation(to: url)) else {
      message = "That link cannot be opened in this sign-in window. Continue with Mistral sign-in."
      decisionHandler(.cancel)
      return
    }
    decisionHandler(.allow)
  }

  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
               for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    guard let url = navigationAction.request.url, MistralSignInPolicy.allowsNavigation(to: url) else { return nil }
    webView.load(navigationAction.request)
    return nil
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard !cancelled, !hasRedirectedStudioSignIn, let url = webView.url,
          let subscription = MistralSignInPolicy.subscriptionRedirect(after: url) else { return }
    // Some sign-ins discard return_to and land in Studio. Return to the quota
    // page once; an account without Admin access must not enter a redirect loop.
    hasRedirectedStudioSignIn = true
    webView.load(URLRequest(url: subscription))
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    guard (error as NSError).code != NSURLErrorCancelled else { return }
    message = "The Mistral sign-in page could not load. Check your connection and try again."
  }
}
