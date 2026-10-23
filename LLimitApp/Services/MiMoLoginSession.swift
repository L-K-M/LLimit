import Foundation
import WebKit
import QuotaCore

/// Each attempt owns an ephemeral browser. Only allowlisted authentication
/// cookies are saved; ordinary browser profiles and analytics are never adopted.
@MainActor
final class MiMoLoginSession: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
  let id = UUID()
  let accountID: String
  let webView: WKWebView
  @Published private(set) var isConnecting = false
  @Published private(set) var message = "Sign in to the MiMo API Platform, then choose Connect Account."
  private var connection: Task<Void, Never>?
  private var cancelled = false
  private let onConnect: @MainActor (UUID, MiMoBrowserLogin) async throws -> Void

  init(accountID: String, startURL: URL = MiMoSignInPolicy.startURL,
       onConnect: @escaping @MainActor (UUID, MiMoBrowserLogin) async throws -> Void) {
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
        let session = try MiMoBrowserLogin(cookies: cookies)
        guard session.browser != nil else {
          throw ProviderClientError(kind: .auth, message: "Xiaomi did not provide a saved login for automatic renewal. Cancel and sign in again.")
        }
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

/// Replays the console's own sign-in redirect using only this account's saved
/// Xiaomi login. No UI, shared cookie store, or old platform token is involved.
@MainActor
final class MiMoSessionRenewal: NSObject, WKNavigationDelegate, WKUIDelegate {
  let webView: WKWebView
  private let browser: MiMoBrowserSession
  private let startURL: URL
  private let timeout: TimeInterval
  private var continuation: CheckedContinuation<MiMoBrowserLogin, Error>?
  private var deadline: Task<Void, Never>?
  private var loading: Task<Void, Never>?
  private var capturing = false
  private var started = false

  init(browser: MiMoBrowserSession, startURL: URL = MiMoSignInPolicy.renewalURL, timeout: TimeInterval = 30) {
    self.browser = browser
    self.startURL = startURL
    self.timeout = timeout
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    webView = WKWebView(frame: .zero, configuration: configuration)
    super.init()
    webView.navigationDelegate = self
    webView.uiDelegate = self
  }

  func renew() async throws -> MiMoBrowserLogin {
    guard !started, !browser.cookies().isEmpty, MiMoSignInPolicy.allowsNavigation(to: startURL) else { throw Self.reconnect }
    started = true
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        deadline = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(self?.timeout ?? 30)) }
          catch { return }
          self?.finish(.failure(Self.reconnect))
        }
        loading = Task { [weak self] in
          guard let self else { return }
          for cookie in browser.cookies() {
            await withCheckedContinuation { continuation in
              self.webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { continuation.resume() }
            }
            guard !Task.isCancelled, self.continuation != nil else { return }
          }
          webView.load(URLRequest(url: startURL))
        }
      }
    } onCancel: {
      Task { @MainActor in self.finish(.failure(CancellationError())) }
    }
  }

  private func finish(_ result: Result<MiMoBrowserLogin, Error>) {
    guard let continuation else { return }
    self.continuation = nil
    deadline?.cancel()
    loading?.cancel()
    deadline = nil
    loading = nil
    webView.stopLoading()
    webView.navigationDelegate = nil
    webView.uiDelegate = nil
    continuation.resume(with: result)
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = navigationAction.request.url, MiMoSignInPolicy.allowsNavigation(to: url) else {
      decisionHandler(.cancel)
      finish(.failure(Self.reconnect))
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

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard continuation != nil, !capturing, let url = webView.url,
          url.scheme == "https", url.host == MiMoSessionCookies.consoleHost,
          url.path == "/console/plan-manage" else { return }
    capturing = true
    webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
      guard let self, self.continuation != nil else { return }
      do {
        let login = try MiMoBrowserLogin(cookies: cookies)
        guard login.browser != nil, self.browser.matches(login.console) else { throw Self.reconnect }
        self.finish(.success(login))
      } catch { self.finish(.failure(Self.reconnect)) }
    }
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    navigationFailed(error)
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    navigationFailed(error)
  }

  private func navigationFailed(_ error: Error) {
    guard (error as NSError).code != NSURLErrorCancelled else { return }
    finish(.failure(ProviderClientError(kind: .network, message: "Could not renew the MiMo session. Check your connection and try again.")))
  }

  private static var reconnect: ProviderClientError {
    ProviderClientError(kind: .auth, message: "Xiaomi needs you to sign in again. Connect MiMo to renew this account's login.")
  }
}
